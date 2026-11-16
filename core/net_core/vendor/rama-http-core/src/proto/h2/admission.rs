//! Exact request admission for pooled HTTP/2 connections.
//!
//! The connection's h2 layer counts every local stream from creation until it really closes,
//! sends buffered behind flow control included (RFC 9113 §5.1.2), whoever sent the request. A
//! pool checkout reserves a stream on top of that count until its request is handed to h2,
//! which then counts it. A connection admits while both together stay below the peer's limit;
//! concurrent checkouts can overshoot it by one, which h2 then queues until a stream frees.

use crate::h2::LocalStreams;
use rama_core::{
    error::{BoxError, BoxErrorExt as _},
    extensions::{Extension, Extensions},
};
use rama_net::{
    client::{
        ConnectionError, ConnectionErrorKind,
        pool::{ConnectionAdmission, ConnectionAdmissionLease, ConnectionAdmissionPolicy},
    },
    conn::MaxConcurrency,
};
use rama_utils::reactive::{Change, ChangeListener, ChangeSignal};
use std::sync::{
    Arc, Weak,
    atomic::{AtomicBool, AtomicUsize, Ordering},
};

/// Per-connection admission state, shared by the connection task and its senders.
#[derive(Debug)]
pub(crate) struct Admission {
    // Checkouts whose request has not reached h2 yet.
    reserved: AtomicUsize,
    streams: Arc<LocalStreams>,
    max: Arc<MaxConcurrency>,
    released: ChangeSignal,
}

impl Admission {
    fn bump(&self) {
        self.released.notify(Change::Freed);
    }
}

/// Held by the connection task, the state's only owner: once the task ends, the pool's weak
/// policy admits nothing more, and its subscribers wake as the release signal goes away.
#[derive(Debug)]
pub(crate) struct AdmissionOwner(Arc<Admission>);

impl AdmissionOwner {
    pub(crate) fn new(streams: Arc<LocalStreams>, max: Arc<MaxConcurrency>) -> Self {
        Self(Arc::new(Admission {
            reserved: AtomicUsize::new(0),
            streams,
            max,
            released: ChangeSignal::new(),
        }))
    }

    /// The pool-facing policy; it holds the state weakly, so it never keeps a connection alive.
    pub(crate) fn policy(&self) -> ConnectionAdmission {
        ConnectionAdmission::new(AdmissionPolicy(Arc::downgrade(&self.0)))
    }

    /// The checkout a request carries, if it was made on this connection.
    pub(crate) fn checkout(&self, extensions: &Extensions) -> Option<Checkout> {
        let reservation = extensions.get_ref::<ReservationBinding>()?.0.upgrade()?;
        reservation
            .state
            .upgrade()
            .is_some_and(|state| Arc::ptr_eq(&state, &self.0))
            .then_some(Checkout(reservation))
    }
}

/// A request's checkout, spent once h2 counts its stream.
#[derive(Debug)]
pub(crate) struct Checkout(Arc<Reservation>);

impl Checkout {
    pub(crate) fn dispatched(self) {
        self.0.release();
    }
}

/// One checkout's reserved stream, released at dispatch or when the checkout drops unused.
#[derive(Debug)]
struct Reservation {
    state: Weak<Admission>,
    released: AtomicBool,
}

impl Reservation {
    fn release(&self) {
        if self.released.swap(true, Ordering::AcqRel) {
            return;
        }
        // Release first, then wake: a woken acquirer must see the returned reservation. A
        // dispatch only moves the stream into h2's count, so nobody is woken unless a
        // stream already retired meanwhile.
        if let Some(state) = self.state.upgrade() {
            let reserved = state.reserved.fetch_sub(1, Ordering::AcqRel) - 1;
            let held = state.streams.live() + reserved;
            // Nothing held is a change too: a peer limit lowered to zero hides
            // it from the first test, and the pool would keep its busy answer.
            if held < state.max.get() || held == 0 {
                state.bump();
            }
        }
    }
}

impl Drop for Reservation {
    fn drop(&mut self) {
        self.release();
    }
}

/// Published in the request's extensions; weak, so cloned request metadata never keeps an
/// unused checkout's reservation alive.
#[derive(Clone, Debug, Extension)]
#[extension(tags(http))]
struct ReservationBinding(Weak<Reservation>);

#[derive(Debug)]
struct AdmissionPolicy(Weak<Admission>);

fn unavailable(reason: &'static str) -> BoxError {
    ConnectionError::application(
        BoxError::from_static_str(reason),
        ConnectionErrorKind::Unavailable,
    )
    .into()
}

impl ConnectionAdmissionPolicy for AdmissionPolicy {
    fn try_acquire(
        &self,
        _input: &Extensions,
    ) -> Result<Option<ConnectionAdmissionLease>, BoxError> {
        let state = self
            .0
            .upgrade()
            .ok_or_else(|| unavailable("HTTP/2 connection released"))?;
        let max = state.max.get();
        if state
            .reserved
            .try_update(Ordering::AcqRel, Ordering::Acquire, |reserved| {
                (state.streams.live() + reserved < max).then_some(reserved + 1)
            })
            .is_err()
        {
            return Ok(None);
        }
        let reservation = Arc::new(Reservation {
            state: Arc::downgrade(&state),
            released: AtomicBool::new(false),
        });
        let binding = ReservationBinding(Arc::downgrade(&reservation));
        Ok(Some(ConnectionAdmissionLease::new(reservation, binding)))
    }

    fn subscribe(&self, listener: Weak<dyn ChangeListener>) {
        // The connection ended: nothing changes any more, and its broken marking frees the
        // waiters.
        let Some(state) = self.0.upgrade() else {
            return;
        };
        // Releases, retirements, limit changes and the end of the connection (the release
        // signal's owner drops) all push to the listener.
        state.released.subscribe(listener.clone());
        state.streams.subscribe(listener.clone());
        state.max.subscribe(listener);
    }

    fn in_use(&self) -> bool {
        self.0.upgrade().is_some_and(|state| {
            state.streams.live() > 0 || state.reserved.load(Ordering::Acquire) > 0
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[tokio::test]
    async fn a_limit_raise_wakes_admission_subscribers() {
        let max = Arc::new(MaxConcurrency::new(0));
        let owner = AdmissionOwner::new(Arc::new(LocalStreams::new()), max.clone());
        let admission = owner.policy();
        let input = Extensions::new();
        assert!(admission.try_acquire(&input).unwrap().is_none());
        let changed = admission.changed();
        max.set(1);
        tokio::time::timeout(Duration::from_secs(5), changed)
            .await
            .expect("a raised peer limit wakes subscribers");
        assert!(admission.try_acquire(&input).unwrap().is_some());
    }

    #[tokio::test]
    async fn the_last_release_under_a_zero_limit_wakes_admission_subscribers() {
        let max = Arc::new(MaxConcurrency::new(1));
        let owner = AdmissionOwner::new(Arc::new(LocalStreams::new()), max.clone());
        let admission = owner.policy();
        let lease = admission.try_acquire(&Extensions::new()).unwrap().unwrap();
        // The peer lowers its limit to zero while a checkout holds its reservation.
        max.set(0);
        let changed = admission.changed();
        assert!(admission.in_use());
        drop(lease);
        tokio::time::timeout(Duration::from_secs(1), changed)
            .await
            .expect("nothing in use any more is a change");
        assert!(!admission.in_use());
    }
}
