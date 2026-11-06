//! A reusable Tokio deadline timer shared by the connection and endpoint drivers.

use std::{
    future::Future,
    pin::Pin,
    task::{Context, Poll},
};

use crate::driver::Instant;

/// One reusable [`tokio::time::Sleep`] that follows a moving deadline.
///
/// The clock, not the sleep, decides expiry: `Sleep::poll` honours Tokio's cooperative budget
/// and may report `Pending` for an elapsed deadline, so [`poll`](Self::poll) compares `now` with
/// the deadline first and only then arms and polls the sleep. A changed deadline resets the one
/// boxed sleep instead of allocating another.
#[derive(Debug, Default)]
pub(crate) struct DeadlineTimer {
    sleep: Option<Pin<Box<tokio::time::Sleep>>>,
    armed: Option<Instant>,
}

/// Outcome of [`DeadlineTimer::poll`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Deadline {
    /// `now` reached the deadline (or the sleep completed): the caller runs its timeout work.
    Elapsed,
    /// The deadline lies ahead; the task is woken when it arrives.
    Pending,
}

impl DeadlineTimer {
    /// Report whether `deadline` has arrived at `now`, arming the timer for it otherwise.
    pub(crate) fn poll(
        &mut self,
        deadline: Instant,
        now: Instant,
        cx: &mut Context<'_>,
    ) -> Deadline {
        if now >= deadline {
            self.armed = None;
            return Deadline::Elapsed;
        }
        let sleep = self
            .sleep
            .get_or_insert_with(|| Box::pin(tokio::time::sleep_until(deadline.into())));
        if self.armed != Some(deadline) {
            sleep.as_mut().reset(deadline.into());
            self.armed = Some(deadline);
        }
        match sleep.as_mut().poll(cx) {
            Poll::Pending => Deadline::Pending,
            // The deadline elapsed between the clock check and the poll.
            Poll::Ready(()) => {
                self.armed = None;
                Deadline::Elapsed
            }
        }
    }

    /// Forget the current deadline; the sleep is kept for reuse.
    pub(crate) fn clear(&mut self) {
        self.armed = None;
    }

    /// The deadline the timer is currently armed for, if any.
    #[cfg(test)]
    pub(crate) fn armed(&self) -> Option<Instant> {
        self.armed
    }

    /// Whether a sleep has ever been allocated.
    #[cfg(test)]
    pub(crate) fn has_sleep(&self) -> bool {
        self.sleep.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::driver::Duration;
    use std::{
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        },
        task::{Wake, Waker},
    };

    struct CountWake(AtomicUsize);

    impl Wake for CountWake {
        fn wake(self: Arc<Self>) {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }

    fn now() -> Instant {
        crate::driver::now()
    }

    #[tokio::test(start_paused = true)]
    async fn pending_before_the_deadline_and_woken_exactly_at_it() {
        let mut timer = DeadlineTimer::default();
        let wake = Arc::new(CountWake(AtomicUsize::new(0)));
        let waker = Waker::from(wake.clone());
        let mut cx = Context::from_waker(&waker);
        let deadline = now() + Duration::from_millis(100);

        assert_eq!(timer.poll(deadline, now(), &mut cx), Deadline::Pending);
        assert!(timer.has_sleep());
        assert_eq!(timer.armed(), Some(deadline));
        // Advancing to just before the deadline wakes nobody.
        tokio::time::advance(Duration::from_millis(99)).await;
        assert_eq!(wake.0.load(Ordering::Relaxed), 0, "no early wake");
        assert_eq!(timer.poll(deadline, now(), &mut cx), Deadline::Pending);
        // Reaching the deadline wakes the task exactly once, and the poll reports it elapsed.
        tokio::time::advance(Duration::from_millis(1)).await;
        assert_eq!(
            wake.0.load(Ordering::Relaxed),
            1,
            "one wake at the deadline"
        );
        assert_eq!(timer.poll(deadline, now(), &mut cx), Deadline::Elapsed);
        assert_eq!(timer.armed(), None);
    }

    #[tokio::test(start_paused = true)]
    async fn an_elapsed_deadline_is_reported_from_the_clock_without_a_sleep() {
        let mut timer = DeadlineTimer::default();
        let mut cx = Context::from_waker(Waker::noop());
        let start = now();
        // A deadline already in the past never allocates or polls a sleep.
        assert_eq!(timer.poll(start, start, &mut cx), Deadline::Elapsed);
        assert_eq!(
            timer.poll(start, start + Duration::from_secs(1), &mut cx),
            Deadline::Elapsed
        );
        assert!(!timer.has_sleep());
    }

    #[tokio::test(start_paused = true)]
    async fn rearming_later_moves_the_wake_and_rearming_earlier_brings_it_forward() {
        let mut timer = DeadlineTimer::default();
        let wake = Arc::new(CountWake(AtomicUsize::new(0)));
        let waker = Waker::from(wake.clone());
        let mut cx = Context::from_waker(&waker);
        let start = now();
        let first = start + Duration::from_millis(100);
        assert_eq!(timer.poll(first, now(), &mut cx), Deadline::Pending);

        // Later deadline: the old one passes without a wake, the same sleep is reused.
        let later = start + Duration::from_millis(300);
        assert_eq!(timer.poll(later, now(), &mut cx), Deadline::Pending);
        assert_eq!(timer.armed(), Some(later));
        tokio::time::advance(Duration::from_millis(150)).await;
        assert_eq!(
            wake.0.load(Ordering::Relaxed),
            0,
            "the superseded deadline is silent"
        );
        assert_eq!(timer.poll(later, now(), &mut cx), Deadline::Pending);

        // Earlier deadline: the wake comes forward to it.
        let earlier = now() + Duration::from_millis(20);
        assert_eq!(timer.poll(earlier, now(), &mut cx), Deadline::Pending);
        assert_eq!(timer.armed(), Some(earlier));
        tokio::time::advance(Duration::from_millis(20)).await;
        assert_eq!(
            wake.0.load(Ordering::Relaxed),
            1,
            "woken at the earlier deadline"
        );
        assert_eq!(timer.poll(earlier, now(), &mut cx), Deadline::Elapsed);

        // The later deadline is armed again after the timer fired: no stale state.
        assert_eq!(timer.poll(later, now(), &mut cx), Deadline::Pending);
        tokio::time::advance(Duration::from_millis(200)).await;
        assert_eq!(wake.0.load(Ordering::Relaxed), 2);
        assert_eq!(timer.poll(later, now(), &mut cx), Deadline::Elapsed);
    }

    #[tokio::test(start_paused = true)]
    async fn an_unchanged_deadline_does_not_reset_or_double_wake() {
        let mut timer = DeadlineTimer::default();
        let wake = Arc::new(CountWake(AtomicUsize::new(0)));
        let waker = Waker::from(wake.clone());
        let mut cx = Context::from_waker(&waker);
        let deadline = now() + Duration::from_millis(50);
        for _ in 0..5 {
            assert_eq!(timer.poll(deadline, now(), &mut cx), Deadline::Pending);
            tokio::time::advance(Duration::from_millis(5)).await;
        }
        assert_eq!(wake.0.load(Ordering::Relaxed), 0);
        tokio::time::advance(Duration::from_millis(25)).await;
        assert_eq!(wake.0.load(Ordering::Relaxed), 1);
        timer.clear();
        assert_eq!(timer.armed(), None);
        assert!(timer.has_sleep(), "the sleep survives a clear for reuse");
    }
}
