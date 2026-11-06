use parking_lot::Mutex;
use rama_core::futures::{StreamExt as _, future::poll_fn, stream::FuturesUnordered};
use std::{
    future::Future,
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    task::{Poll, Waker},
};
use tokio::{sync::Notify, task::JoinHandle};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShutdownOutcome {
    Drained,
    Forced,
    DriverFailed,
}

/// Driver ownership shared with the endpoint's lifecycle supervisor.
/// Only the supervisor polls joins; application handles observe its completion.
#[derive(Debug, Clone, Default)]
pub(crate) struct Lifecycle(Arc<Shared>);

#[derive(Default)]
struct Shared {
    tasks: Mutex<Tasks>,
    requested: AtomicBool,
    request: Notify,
    failed: AtomicBool,
    outcome: Mutex<Option<ShutdownOutcome>>,
    complete: Notify,
    /// Test seam run by `SpawnSlot::submit` right before the runtime call, with no lock held.
    #[cfg(test)]
    submit_hook: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    /// Test seam: wrap the next submitted driver future (e.g. to observe its polls and wakes).
    #[cfg(test)]
    submit_wrapper: Mutex<Option<SubmitWrapper>>,
}

#[cfg(test)]
pub(crate) type DriverFuture = Pin<Box<dyn Future<Output = ()> + Send>>;
#[cfg(test)]
pub(crate) type SubmitWrapper = Arc<dyn Fn(DriverFuture) -> DriverFuture + Send + Sync>;

impl std::fmt::Debug for Shared {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Shared")
            .field("tasks", &self.tasks)
            .field("requested", &self.requested)
            .field("failed", &self.failed)
            .field("outcome", &self.outcome)
            .finish_non_exhaustive()
    }
}

/// Supervised drivers: tracked join handles plus reservations for drivers that are
/// registered but not yet submitted to the runtime.
#[derive(Debug, Default)]
struct Tasks {
    set: FuturesUnordered<JoinHandle<()>>,
    /// Drivers reserved with [`Lifecycle::reserve`] whose handle is not yet in `set`.
    pending: usize,
    /// Once set, late submissions are aborted immediately so a forced join still completes.
    aborted: bool,
    joiner: Option<Waker>,
}

impl Tasks {
    fn wake_joiner(&mut self) {
        if let Some(waker) = self.joiner.take() {
            waker.wake();
        }
    }
}

/// A reserved place in the supervised task set for a driver that is about to be submitted.
///
/// Taken while the caller still holds its registration lock, so shutdown cannot complete
/// between registering a connection and tracking its driver. Dropping an unsubmitted slot
/// (rollback, unwind) releases the reservation and wakes the joiner.
#[derive(Debug)]
pub(crate) struct SpawnSlot {
    lifecycle: Lifecycle,
    armed: bool,
}

impl SpawnSlot {
    /// Submit the driver through the shared Rama spawn path. The runtime is called with no
    /// lifecycle lock held: a runtime that discards the future inline (for example one that is
    /// shutting down) runs the driver's `Drop`, which reaches the endpoint state.
    pub(crate) fn submit(mut self, future: Pin<Box<dyn Future<Output = ()> + Send>>) {
        #[cfg(test)]
        {
            let hook = self.lifecycle.0.submit_hook.lock().clone();
            if let Some(hook) = hook {
                hook();
            }
        }
        #[cfg(test)]
        let future = match self.lifecycle.0.submit_wrapper.lock().clone() {
            Some(wrap) => wrap(future),
            None => future,
        };
        let handle = rama_core::rt::spawn(future);
        let mut tasks = self.lifecycle.0.tasks.lock();
        if tasks.aborted {
            handle.abort();
        }
        tasks.set.push(handle);
        tasks.pending -= 1;
        tasks.wake_joiner();
        self.armed = false;
    }
}

impl Drop for SpawnSlot {
    fn drop(&mut self) {
        if self.armed {
            let mut tasks = self.lifecycle.0.tasks.lock();
            tasks.pending -= 1;
            tasks.wake_joiner();
        }
    }
}

impl Lifecycle {
    /// Reserve supervision for a driver that will be submitted after the caller releases its
    /// registration lock.
    pub(crate) fn reserve(&self) -> SpawnSlot {
        self.0.tasks.lock().pending += 1;
        SpawnSlot {
            lifecycle: self.clone(),
            armed: true,
        }
    }

    /// Reserve and submit in one step, for callers that hold no registration lock.
    pub(crate) fn spawn(&self, future: Pin<Box<dyn Future<Output = ()> + Send>>) {
        self.reserve().submit(future);
    }

    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn pending_submissions(&self) -> usize {
        self.0.tasks.lock().pending
    }

    /// Install a closure that runs before every submission's runtime call (test seam for
    /// pausing a submitter between registration and tracking).
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn set_submit_hook(&self, hook: Option<Arc<dyn Fn() + Send + Sync>>) {
        *self.0.submit_hook.lock() = hook;
    }

    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn set_submit_wrapper(&self, wrapper: Option<SubmitWrapper>) {
        *self.0.submit_wrapper.lock() = wrapper;
    }

    pub(crate) fn request(&self) {
        self.0.requested.store(true, Ordering::Release);
        self.0.request.notify_waiters();
    }

    pub(crate) async fn requested(&self) {
        loop {
            let notified = self.0.request.notified();
            if self.0.requested.load(Ordering::Acquire) {
                return;
            }
            notified.await;
        }
    }

    /// Abort every tracked driver; drivers submitted afterwards are aborted on submission.
    pub(crate) fn abort(&self) {
        let mut tasks = self.0.tasks.lock();
        tasks.aborted = true;
        for task in tasks.set.iter() {
            task.abort();
        }
    }

    /// Join every driver, including destruction of its future and owned socket handles, and
    /// wait for every reserved submission to be tracked and joined too.
    pub(crate) async fn join(&self) {
        poll_fn(|cx| {
            let mut tasks = self.0.tasks.lock();
            for _ in 0..super::IO_LOOP_BOUND {
                match tasks.set.poll_next_unpin(cx) {
                    Poll::Ready(Some(Err(error))) => {
                        if !error.is_cancelled() {
                            self.0.failed.store(true, Ordering::Release);
                        }
                    }
                    Poll::Ready(Some(Ok(()))) => {}
                    Poll::Ready(None) => {
                        if tasks.pending == 0 {
                            return Poll::Ready(());
                        }
                        // A registered driver is still being submitted; its slot wakes us.
                        tasks.joiner = Some(cx.waker().clone());
                        return Poll::Pending;
                    }
                    Poll::Pending => return Poll::Pending,
                }
            }
            cx.waker().wake_by_ref();
            Poll::Pending
        })
        .await;
    }

    pub(crate) fn failed(&self) {
        self.0.failed.store(true, Ordering::Release);
        self.request();
    }

    /// A recorded failure is reported even when the drain budget also expired.
    pub(crate) fn finish(&self, forced: bool) {
        let outcome = if self.0.failed.load(Ordering::Acquire) {
            ShutdownOutcome::DriverFailed
        } else if forced {
            ShutdownOutcome::Forced
        } else {
            ShutdownOutcome::Drained
        };
        *self.0.outcome.lock() = Some(outcome);
        self.0.complete.notify_waiters();
    }

    pub(crate) async fn completed(&self) -> ShutdownOutcome {
        loop {
            let notified = self.0.complete.notified();
            if let Some(outcome) = *self.0.outcome.lock() {
                return outcome;
            }
            notified.await;
        }
    }
}
