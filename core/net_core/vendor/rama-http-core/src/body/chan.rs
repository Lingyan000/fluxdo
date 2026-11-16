//! The channel feeding an HTTP/1 [`Incoming`](super::Incoming) body: data, an
//! error, trailers and the expect-continue want share a single allocation.

use std::fmt;
use std::mem;
use std::sync::Arc;
use std::task::{Context, Poll};

use atomic_waker::AtomicWaker;
use parking_lot::Mutex;
use rama_core::bytes::Bytes;
use rama_http_types::HeaderMap;

#[cfg(test)]
use std::future::poll_fn;

/// With `wanter` set, the sender is not ready before the body is first polled.
pub(crate) fn channel(wanter: bool) -> (Sender, Receiver) {
    let shared = Arc::new(Shared {
        state: Mutex::new(State {
            item: None,
            pending_error: None,
            trailers: None,
            sender_open: true,
            receiver_open: true,
            want: !wanter,
        }),
        sender_waker: AtomicWaker::new(),
        receiver_waker: AtomicWaker::new(),
    });

    (
        Sender {
            shared: shared.clone(),
            trailers_sent: false,
        },
        Receiver {
            shared,
            terminated: false,
        },
    )
}

/// The sender half of an [`Incoming`](super::Incoming) channel body.
///
/// Dropping it ends the body normally; send an error first to end it abnormally.
#[must_use = "Sender does nothing unless sent on"]
pub(crate) struct Sender {
    shared: Arc<Shared>,
    trailers_sent: bool,
}

pub(crate) struct Receiver {
    shared: Arc<Shared>,
    terminated: bool,
}

struct Shared {
    state: Mutex<State>,
    sender_waker: AtomicWaker,
    receiver_waker: AtomicWaker,
}

struct State {
    item: Option<Result<Bytes, crate::Error>>,
    // An error must not displace data the receiver has yet to take.
    pending_error: Option<crate::Error>,
    trailers: Option<HeaderMap>,
    sender_open: bool,
    receiver_open: bool,
    want: bool,
}

#[expect(
    clippy::needless_pass_by_ref_mut,
    reason = "a body has a single sender, even though the state it writes is shared"
)]
impl Sender {
    /// Ready once the body is wanted and the receiver took what was sent before.
    pub(crate) fn poll_ready(&mut self, cx: &Context<'_>) -> Poll<crate::Result<()>> {
        self.shared.sender_waker.register(cx.waker());
        let state = self.shared.state.lock();
        if !state.receiver_open {
            Poll::Ready(Err(crate::Error::new_closed()))
        } else if state.want && state.item.is_none() && state.pending_error.is_none() {
            Poll::Ready(Ok(()))
        } else {
            Poll::Pending
        }
    }

    #[cfg(test)]
    pub(crate) async fn ready(&mut self) -> crate::Result<()> {
        poll_fn(|cx| self.poll_ready(cx)).await
    }

    /// Returns the chunk back when the channel cannot take it now.
    pub(crate) fn try_send_data(&mut self, chunk: Bytes) -> Result<(), Bytes> {
        let mut state = self.shared.state.lock();
        if !state.receiver_open
            || !state.want
            || state.item.is_some()
            || state.pending_error.is_some()
        {
            return Err(chunk);
        }
        state.item = Some(Ok(chunk));
        drop(state);
        self.shared.receiver_waker.wake();
        Ok(())
    }

    /// Returns the trailers back when the receiver is gone, or `None` for a second send.
    pub(crate) fn try_send_trailers(
        &mut self,
        trailers: HeaderMap,
    ) -> Result<(), Option<HeaderMap>> {
        if self.trailers_sent {
            return Err(None);
        }
        self.trailers_sent = true;

        let mut state = self.shared.state.lock();
        if !state.receiver_open {
            return Err(Some(trailers));
        }
        // No wake: they are read once the data ends, which dropping the sender signals.
        state.trailers = Some(trailers);
        Ok(())
    }

    pub(crate) fn send_error(&mut self, err: crate::Error) {
        let mut state = self.shared.state.lock();
        if !state.receiver_open {
            return;
        }
        if state.item.is_none() {
            state.item = Some(Err(err));
        } else if state.pending_error.is_none() {
            state.pending_error = Some(err);
        }
        drop(state);
        self.shared.receiver_waker.wake();
    }

    #[cfg(test)]
    pub(crate) fn abort(mut self) {
        self.send_error(crate::Error::new_body_write_aborted());
    }
}

impl Receiver {
    pub(crate) fn poll_next(
        &mut self,
        cx: &Context<'_>,
    ) -> Poll<Option<Result<Bytes, crate::Error>>> {
        if self.terminated {
            return Poll::Ready(None);
        }

        self.shared.receiver_waker.register(cx.waker());
        let mut state = self.shared.state.lock();
        // The first poll is what a wanter's sender waits for.
        let wanted = mem::replace(&mut state.want, true);
        let item = state
            .item
            .take()
            .or_else(|| state.pending_error.take().map(Err));
        let sender_open = state.sender_open;
        drop(state);

        // Taking an item frees the slot the sender waits on.
        if !wanted || item.is_some() {
            self.shared.sender_waker.wake();
        }
        match item {
            Some(item) => Poll::Ready(Some(item)),
            None if sender_open => Poll::Pending,
            None => {
                self.terminated = true;
                Poll::Ready(None)
            }
        }
    }

    pub(crate) fn take_trailers(&self) -> Option<HeaderMap> {
        debug_assert!(
            self.terminated,
            "trailers are only read once the data ended"
        );
        self.shared.state.lock().trailers.take()
    }
}

impl Drop for Sender {
    fn drop(&mut self) {
        let mut state = self.shared.state.lock();
        state.sender_open = false;
        let receiver_open = state.receiver_open;
        drop(state);
        if receiver_open {
            self.shared.receiver_waker.wake();
        }
    }
}

impl Drop for Receiver {
    fn drop(&mut self) {
        let mut state = self.shared.state.lock();
        state.receiver_open = false;
        let sender_open = state.sender_open;
        drop(state);
        if sender_open {
            self.shared.sender_waker.wake();
        }
    }
}

impl fmt::Debug for Sender {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.shared.state.lock().receiver_open {
            f.write_str("Sender(Open)")
        } else {
            f.write_str("Sender(Closed)")
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::task::{Wake, Waker};

    use rama_http_types::HeaderValue;

    use super::*;

    async fn recv(rx: &mut Receiver) -> Option<Result<Bytes, crate::Error>> {
        poll_fn(|cx| rx.poll_next(cx)).await
    }

    struct CountWakes(AtomicUsize);

    impl Wake for CountWakes {
        fn wake(self: Arc<Self>) {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }

    #[cfg(not(miri))]
    #[tokio::test]
    async fn error_queued_behind_accepted_data() {
        let (mut tx, mut rx) = channel(false);
        tx.try_send_data(Bytes::from_static(b"data")).unwrap();
        tx.send_error(crate::Error::new_incomplete());
        drop(tx);

        assert_eq!(recv(&mut rx).await.unwrap().unwrap(), "data");
        recv(&mut rx).await.unwrap().unwrap_err();
        assert!(recv(&mut rx).await.is_none());
    }

    #[cfg(not(miri))]
    #[tokio::test]
    async fn trailers_follow_data_close() {
        let (mut tx, mut rx) = channel(false);
        let mut trailers = HeaderMap::new();
        trailers.insert("x-trailer", HeaderValue::from_static("value"));
        tx.try_send_trailers(trailers).unwrap();
        drop(tx);

        assert!(recv(&mut rx).await.is_none());
        assert_eq!(rx.take_trailers().unwrap()["x-trailer"], "value");
        assert!(rx.take_trailers().is_none(), "trailers are taken once");
    }

    #[test]
    fn taking_a_pending_error_wakes_the_sender() {
        let wakes = Arc::new(CountWakes(AtomicUsize::new(0)));
        let waker = Waker::from(wakes.clone());
        let cx = Context::from_waker(&waker);

        let (mut tx, mut rx) = channel(false);
        tx.try_send_data(Bytes::from_static(b"data")).unwrap();
        tx.send_error(crate::Error::new_incomplete());
        assert!(rx.poll_next(&cx).is_ready());
        assert!(tx.poll_ready(&cx).is_pending(), "an error is still queued");
        let before = wakes.0.load(Ordering::Relaxed);
        assert!(rx.poll_next(&cx).is_ready());
        assert_eq!(wakes.0.load(Ordering::Relaxed), before + 1);
        assert!(tx.poll_ready(&cx).is_ready());
    }

    #[test]
    fn drop_wakes_only_an_open_peer() {
        let wakes = Arc::new(CountWakes(AtomicUsize::new(0)));
        let waker = Waker::from(wakes.clone());
        let cx = Context::from_waker(&waker);
        let count = || wakes.0.load(Ordering::Relaxed);

        // A receiver dropped after the sender does not wake the sender's stale waker.
        let (mut tx, rx) = channel(true);
        assert!(tx.poll_ready(&cx).is_pending());
        drop(tx);
        drop(rx);
        assert_eq!(count(), 0);

        // Nor does a sender dropped after the receiver.
        let (tx, mut rx) = channel(false);
        assert!(rx.poll_next(&cx).is_pending());
        drop(rx);
        drop(tx);
        assert_eq!(count(), 0);

        // An open peer is still woken to observe the close.
        let (mut tx, rx) = channel(true);
        assert!(tx.poll_ready(&cx).is_pending());
        drop(rx);
        assert_eq!(count(), 1);
        drop(tx);

        let (tx, mut rx) = channel(false);
        assert!(rx.poll_next(&cx).is_pending());
        drop(tx);
        assert_eq!(count(), 2);
    }
}
