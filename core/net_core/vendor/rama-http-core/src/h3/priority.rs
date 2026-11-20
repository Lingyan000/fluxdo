//! Bounded extensible-priority scheduling independent of frame parsing.

use super::{Error, connection::Shared};
use parking_lot::Mutex;
use rama_http::headers::Priority;
use rama_http_types::proto::h3::Code;
use std::{
    cmp::Reverse,
    collections::{BTreeMap, BinaryHeap},
    fmt,
    sync::{Arc, Weak},
    task::{Context, Poll, Waker},
};

use tokio::sync::OwnedSemaphorePermit;

/// HTTP urgency runs from most to least urgent; QUIC schedules larger values
/// first. Reserve priorities above this range for connection-critical streams.
pub(super) fn transport_priority(priority: Priority) -> i32 {
    const LEAST_URGENT: u8 = 7;
    i32::from(LEAST_URGENT - priority.urgency())
}

/// Update the peer's response scheduling through RFC 9218 PRIORITY_UPDATE.
/// Available in client response extensions, including informational responses.
/// This weak handle does not keep the connection or response body alive.
#[derive(Clone, rama_core::extensions::Extension)]
pub struct PriorityHandle {
    shared: Weak<Shared>,
    id: u64,
    push: bool,
}

impl fmt::Debug for PriorityHandle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PriorityHandle")
            .field("id", &self.id)
            .field("push", &self.push)
            .finish_non_exhaustive()
    }
}

impl PriorityHandle {
    pub(crate) fn new(shared: &Arc<Shared>, id: u64, push: bool) -> Self {
        Self {
            shared: Arc::downgrade(shared),
            id,
            push,
        }
    }

    /// Queue a bounded priority update. Scheduling remains advisory to the peer.
    pub fn update(&self, priority: Priority) -> Result<(), Error> {
        self.shared
            .upgrade()
            .ok_or(Error::stream(
                Code::H3_REQUEST_CANCELLED,
                "connection closed",
            ))?
            .send_priority(self.id, self.push, priority)
    }
}

/// Opt-in observation of a server request's effective response priority.
/// Uses the scheduler and control-stream notifications already maintained by
/// HTTP/3; creating ordinary requests does not allocate an observer.
///
/// Updates coalesce to the latest effective priority. Cancel an outstanding wait
/// when the request/response completes: completion alone need not wake it.
/// The weak handle does not keep the response body or connection alive.
#[derive(Clone, rama_core::extensions::Extension)]
pub struct PriorityObserver {
    shared: Weak<Shared>,
    id: u64,
    last: Option<Priority>,
}

impl fmt::Debug for PriorityObserver {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PriorityObserver")
            .field("id", &self.id)
            .finish_non_exhaustive()
    }
}

impl PriorityObserver {
    pub(crate) fn new(shared: &Arc<Shared>, id: u64) -> Self {
        Self {
            shared: Arc::downgrade(shared),
            id,
            last: None,
        }
    }

    /// Return the current priority on the first call, then wait for a change.
    /// Run the H3 driver concurrently. Cancellation leaves the last delivered
    /// priority intact and does not consume a later update.
    pub async fn changed(&mut self) -> Result<Priority, Error> {
        let shared = self.shared.upgrade().ok_or_else(|| {
            Error::stream(Code::H3_REQUEST_CANCELLED, "priority connection released")
        })?;
        let priority = shared.wait_priority(self.id, self.last).await?;
        self.last = Some(priority);
        Ok(priority)
    }
}

struct Entry {
    priority: Priority,
    overridden: bool,
    peer_updated: bool,
    ready: bool,
    order: u64,
    waker: Option<Waker>,
    revision: u64,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct Ready {
    urgency: u8,
    incremental: bool,
    order: u64,
    id: u64,
    revision: u64,
}

impl Entry {
    fn key(&self, id: u64) -> Ready {
        Ready {
            urgency: self.priority.urgency(),
            incremental: self.priority.incremental(),
            order: self.order,
            id,
            revision: self.revision,
        }
    }
}

/// Own the lock so caller-provided wakers are always invoked after unlocking.
pub(crate) struct Schedule {
    state: Mutex<State>,
}

impl Schedule {
    pub(crate) fn new(limit: usize) -> Self {
        Self {
            state: Mutex::new(State::new(limit)),
        }
    }

    fn access<T>(&self, operation: impl FnOnce(&mut State) -> T) -> T {
        let (result, wake, repoll) = {
            let mut state = self.state.lock();
            let result = operation(&mut state);
            (result, state.wake.take(), state.repoll.take())
        };
        if let Some(waker) = wake {
            waker.wake();
        }
        if let Some(waker) = repoll {
            waker.wake();
        }
        result
    }

    pub(crate) fn register(&self, id: u64, priority: Priority) -> Result<(), Error> {
        self.access(|state| state.register(id, priority))
    }

    pub(crate) fn update(&self, id: u64, priority: Priority) -> Result<(), Error> {
        self.access(|state| state.update(id, priority))
    }

    /// Buffer permitted future requests independently of application admission.
    pub(crate) fn update_pending_limit(&self, advertised: u64) {
        self.access(|state| {
            state.pending_limit = usize::try_from(advertised).unwrap_or(usize::MAX);
        });
    }

    pub(crate) fn initial_priority(&self, id: u64, priority: Priority) {
        self.access(|state| state.initial_priority(id, priority));
    }

    pub(crate) fn peer_priority(&self, id: u64, priority: Priority) {
        self.access(|state| state.peer_priority(id, priority));
    }

    pub(crate) fn override_priority(&self, id: u64, priority: Priority) {
        self.access(|state| state.override_priority(id, priority));
    }

    pub(crate) fn current_priority(&self, id: u64) -> Option<Priority> {
        self.state
            .lock()
            .active
            .get(&id)
            .map(|entry| entry.priority)
    }

    pub(crate) fn poll_turn(&self, id: u64, cx: &Context<'_>) -> Poll<Priority> {
        self.access(|state| state.poll_turn(id, cx))
    }

    pub(crate) fn release(&self, id: u64) {
        self.access(|state| state.release(id));
    }

    pub(crate) fn complete(&self, id: u64) {
        self.access(|state| state.complete(id));
    }
}

struct State {
    active: BTreeMap<u64, Entry>,
    pending: BTreeMap<u64, Priority>,
    // Request streams are admitted in increasing QUIC stream-ID order.
    // Older inactive IDs can never become future priority targets.
    accepted_until: u64,
    limit: usize,
    pending_limit: usize,
    clock: u64,
    ready: BinaryHeap<Reverse<Ready>>,
    wake: Option<Waker>,
    repoll: Option<Waker>,
}

impl State {
    pub(crate) fn new(limit: usize) -> Self {
        Self {
            active: BTreeMap::new(),
            pending: BTreeMap::new(),
            accepted_until: 0,
            limit,
            pending_limit: limit,
            clock: 0,
            ready: BinaryHeap::new(),
            wake: None,
            repoll: None,
        }
    }

    pub(crate) fn register(&mut self, id: u64, priority: Priority) -> Result<(), Error> {
        if self.active.len() >= self.limit {
            return Err(Error::connection(
                Code::H3_EXCESSIVE_LOAD,
                "priority active stream budget exceeded",
            ));
        }
        let pending = self.pending.remove(&id);
        let priority = pending.unwrap_or(priority);
        if id.is_multiple_of(4) {
            self.accepted_until = self.accepted_until.max(id.saturating_add(4));
            while self
                .pending
                .first_key_value()
                .is_some_and(|(id, _)| *id < self.accepted_until)
            {
                self.pending.pop_first();
            }
        }
        self.active.insert(
            id,
            Entry {
                priority,
                overridden: false,
                peer_updated: pending.is_some(),
                ready: false,
                order: self.clock,
                waker: None,
                revision: 0,
            },
        );
        self.clock = self.clock.saturating_add(1);
        Ok(())
    }

    pub(crate) fn update(&mut self, id: u64, priority: Priority) -> Result<(), Error> {
        if !id.is_multiple_of(4) {
            return Err(Error::connection(
                Code::H3_ID_ERROR,
                "priority target is not a request stream",
            ));
        }
        if let Some(entry) = self.active.get_mut(&id) {
            if !entry.overridden {
                entry.priority = priority;
                entry.peer_updated = true;
            }
        } else if id >= self.accepted_until {
            if self.pending.len() >= self.pending_limit && !self.pending.contains_key(&id) {
                return Err(Error::connection(
                    Code::H3_EXCESSIVE_LOAD,
                    "pending priority budget exceeded",
                ));
            }
            self.pending.insert(id, priority);
        }
        self.index_ready(id);
        self.wake_next();
        Ok(())
    }

    /// The field is the initial priority; an earlier PRIORITY_UPDATE takes precedence.
    pub(crate) fn initial_priority(&mut self, id: u64, priority: Priority) {
        if let Some(entry) = self.active.get_mut(&id)
            && !entry.overridden
            && !entry.peer_updated
        {
            entry.priority = priority;
        }
        self.index_ready(id);
        self.wake_next();
    }

    pub(crate) fn peer_priority(&mut self, id: u64, priority: Priority) {
        if let Some(entry) = self.active.get_mut(&id)
            && !entry.overridden
        {
            entry.priority = priority;
        }
        self.index_ready(id);
        self.wake_next();
    }

    pub(crate) fn override_priority(&mut self, id: u64, priority: Priority) {
        if let Some(entry) = self.active.get_mut(&id) {
            entry.priority = priority;
            entry.overridden = true;
        }
        self.index_ready(id);
        self.wake_next();
    }

    fn index_ready(&mut self, id: u64) {
        if let Some(entry) = self.active.get_mut(&id)
            && entry.ready
        {
            entry.revision = entry.revision.wrapping_add(1);
            self.ready.push(Reverse(entry.key(id)));
        }
        // Priority changes invalidate old tickets lazily. Keep churn bounded;
        // BinaryHeap::retain reuses its storage and rebuilds in linear time.
        if self.ready.len() > self.active.len().saturating_mul(2) {
            self.ready.retain(|Reverse(key)| {
                self.active
                    .get(&key.id)
                    .is_some_and(|entry| entry.ready && entry.key(key.id) == *key)
            });
        }
    }

    fn next(&mut self) -> Option<u64> {
        while let Some(Reverse(key)) = self.ready.peek() {
            if self
                .active
                .get(&key.id)
                .is_some_and(|entry| entry.ready && entry.key(key.id) == *key)
            {
                return Some(key.id);
            }
            self.ready.pop();
        }
        None
    }

    fn wake_next(&mut self) {
        self.wake = self.next().and_then(|id| self.active[&id].waker.clone());
    }

    pub(crate) fn poll_turn(&mut self, id: u64, cx: &Context<'_>) -> Poll<Priority> {
        let Some(entry) = self.active.get_mut(&id) else {
            return Poll::Ready(Priority::default());
        };
        let enqueue = !entry.ready;
        entry.ready = true;
        match &mut entry.waker {
            Some(waker) => waker.clone_from(cx.waker()),
            None => entry.waker = Some(cx.waker().clone()),
        }
        let priority = entry.priority;
        if enqueue {
            self.index_ready(id);
        }
        if self.next() == Some(id) {
            Poll::Ready(priority)
        } else {
            // AsyncWrite futures can be dropped while the tunnel remains alive.
            // A wake is a one-shot invitation, never ownership of the scheduler:
            // retire the chosen ticket, wake its writer, then repoll this writer.
            // If that write was abandoned, another stream can immediately advance.
            if let Some(Reverse(key)) = self.ready.pop()
                && let Some(entry) = self.active.get_mut(&key.id)
            {
                entry.ready = false;
                self.wake = entry.waker.clone();
            }
            self.repoll = Some(cx.waker().clone());
            Poll::Pending
        }
    }

    /// A blocked writer must let another stream progress. Incremental writers move
    /// behind other ready streams after each bounded payload quantum.
    pub(crate) fn release(&mut self, id: u64) {
        if let Some(entry) = self.active.get_mut(&id) {
            entry.ready = false;
            if entry.priority.incremental() {
                entry.order = self.clock;
                self.clock = self.clock.saturating_add(1);
            }
        }
        self.wake_next();
    }

    pub(crate) fn complete(&mut self, id: u64) {
        self.active.remove(&id);
        self.pending.remove(&id);
        self.wake_next();
    }
}

pub(crate) struct Lease {
    pub(crate) shared: Arc<Shared>,
    pub(crate) id: u64,
    // Release admission only after Drop removes this stream from the scheduler.
    pub(crate) permit: Arc<OwnedSemaphorePermit>,
}

impl Drop for Lease {
    fn drop(&mut self) {
        self.shared.schedule.complete(self.id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::h3::{connection::Config, control::Role};
    use std::{
        pin::pin,
        sync::atomic::{AtomicUsize, Ordering},
        task::Wake,
    };
    use tokio::sync::Semaphore;

    #[test]
    fn admission_wake_observes_completed_scheduler_lease() {
        struct AdmitOnWake(Arc<Shared>);

        impl Wake for AdmitOnWake {
            fn wake(self: Arc<Self>) {
                self.0.schedule.register(4, Priority::default()).unwrap();
            }
        }

        let shared = Shared::new(
            Config {
                max_requests: 1,
                ..Config::default()
            },
            Role::Server,
            Default::default(),
        )
        .unwrap();
        shared.schedule.register(0, Priority::default()).unwrap();
        let admission = Arc::new(Semaphore::new(1));
        let lease = Lease {
            shared: shared.clone(),
            id: 0,
            permit: Arc::new(admission.clone().try_acquire_owned().unwrap()),
        };
        let mut next = pin!(admission.acquire_owned());
        let waker = Waker::from(Arc::new(AdmitOnWake(shared.clone())));
        let mut cx = Context::from_waker(&waker);
        assert!(next.as_mut().poll(&mut cx).is_pending());
        // Semaphore release may synchronously wake a receiver on another thread.
        // Even a reentrant wake must see the old scheduler slot already removed.
        drop(lease);
        assert!(next.as_mut().poll(&mut cx).is_ready());
        assert!(shared.schedule.state.lock().active.contains_key(&4));
    }

    #[test]
    fn priority_churn_retains_a_bounded_ready_index() {
        let schedule = Schedule::new(1);
        schedule.register(0, Priority::default()).unwrap();
        let cx = Context::from_waker(Waker::noop());
        assert!(schedule.poll_turn(0, &cx).is_ready());
        for _ in 0..1000 {
            // Repeating the identical value must invalidate its old ticket too.
            schedule.update(0, Priority::default()).unwrap();
            assert!(schedule.state.lock().ready.len() <= 2);
        }
    }

    #[test]
    fn caller_wakers_run_after_unlocking() {
        struct InspectWake {
            schedule: Weak<Schedule>,
            calls: AtomicUsize,
        }
        impl Wake for InspectWake {
            fn wake(self: Arc<Self>) {
                let schedule = self.schedule.upgrade().unwrap();
                assert!(
                    schedule.state.try_lock().is_some(),
                    "waker invoked while scheduler locked"
                );
                self.calls.fetch_add(1, Ordering::Relaxed);
            }
        }
        let schedule = Arc::new(Schedule::new(2));
        schedule.register(0, Priority::default()).unwrap();
        schedule.register(4, Priority::default()).unwrap();
        let wake = Arc::new(InspectWake {
            schedule: Arc::downgrade(&schedule),
            calls: AtomicUsize::new(0),
        });
        let waker = Waker::from(wake.clone());
        let cx = Context::from_waker(&waker);
        assert!(schedule.poll_turn(0, &cx).is_ready());
        assert!(schedule.poll_turn(4, &cx).is_pending());
        schedule.release(0);
        assert!(wake.calls.load(Ordering::Relaxed) >= 2);
    }

    #[test]
    fn abandoned_ready_ticket_does_not_own_the_next_turn() {
        let schedule = Schedule::new(3);
        for id in [0, 4, 8] {
            schedule.register(id, Priority::default()).unwrap();
        }
        let cx = Context::from_waker(Waker::noop());
        assert!(schedule.poll_turn(0, &cx).is_ready());
        assert!(schedule.poll_turn(4, &cx).is_pending());
        // Stream 4's write future is abandoned, but its stream stays registered.
        schedule.release(0);
        assert!(schedule.poll_turn(8, &cx).is_pending());
        assert!(schedule.poll_turn(8, &cx).is_ready());
        schedule.release(8);
        assert!(schedule.poll_turn(4, &cx).is_ready());
    }

    #[test]
    fn transport_priority_preserves_http_urgency_order() {
        for urgency in 0..=7 {
            let priority = transport_priority(Priority::new(urgency, false).unwrap());
            assert!((0..=7).contains(&priority));
            assert!(priority < i32::MAX);
            if urgency != 7 {
                assert!(priority > transport_priority(Priority::new(urgency + 1, true).unwrap()));
            }
        }
    }

    #[test]
    fn pre_stream_updates_coalesce_and_are_bounded() {
        let schedule = Schedule::new(1);
        schedule.update(4, Priority::new(1, true).unwrap()).unwrap();
        schedule.update(4, Priority::new(2, true).unwrap()).unwrap();
        schedule.update(8, Priority::default()).unwrap_err();
        schedule.register(4, Priority::default()).unwrap();
        let cx = Context::from_waker(Waker::noop());
        assert_eq!(
            schedule.poll_turn(4, &cx),
            Poll::Ready(Priority::new(2, true).unwrap())
        );
        schedule.complete(4);
        schedule.update(4, Priority::default()).unwrap();
        assert!(schedule.state.lock().pending.is_empty());
        schedule.update(1, Priority::default()).unwrap_err();
    }

    #[test]
    fn skipped_requests_do_not_retain_history_or_late_updates() {
        let schedule = Schedule::new(1);
        for id in (4..4000).step_by(8) {
            schedule.update(id - 4, Priority::default()).unwrap();
            schedule.register(id, Priority::default()).unwrap();
            schedule.complete(id);
            schedule.update(id, Priority::default()).unwrap();
            schedule.update(id - 4, Priority::default()).unwrap();
            assert!(schedule.state.lock().pending.is_empty());
            assert!(schedule.state.lock().active.is_empty());
        }
    }

    #[test]
    fn priority_updates_precede_initial_header_even_before_decoding() {
        let schedule = Schedule::new(2);
        let peer = Priority::new(1, true).unwrap();
        let header = Priority::new(5, false).unwrap();
        schedule.update(0, peer).unwrap();
        schedule.register(0, Priority::default()).unwrap();
        schedule.initial_priority(0, header);
        schedule.register(4, Priority::default()).unwrap();
        schedule.update(4, peer).unwrap();
        schedule.initial_priority(4, header);
        assert_eq!(schedule.state.lock().active[&0].priority, peer);
        assert_eq!(schedule.state.lock().active[&4].priority, peer);
    }

    #[test]
    fn urgency_incremental_and_stalled_writer_progress() {
        let schedule = Schedule::new(3);
        let incremental = Priority::new(3, true).unwrap();
        schedule.register(0, incremental).unwrap();
        schedule.register(4, incremental).unwrap();
        schedule
            .register(8, Priority::new(0, false).unwrap())
            .unwrap();
        let cx = Context::from_waker(Waker::noop());
        assert!(schedule.poll_turn(0, &cx).is_ready());
        assert!(schedule.poll_turn(4, &cx).is_pending());
        assert!(schedule.poll_turn(8, &cx).is_ready());
        schedule.release(8);
        schedule.release(0);
        assert!(schedule.poll_turn(4, &cx).is_ready());
        assert!(schedule.poll_turn(0, &cx).is_pending());
    }
}
