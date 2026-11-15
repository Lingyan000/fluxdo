use std::mem::ManuallyDrop;
use std::pin::Pin;
use std::sync::atomic::{self, AtomicBool};
use std::task::{Context, Poll, ready};

use pin_project_lite::pin_project;
use rama_core::error::BoxError;
use rama_core::telemetry::tracing::{self, trace};
use rama_http_types::{Request, Response, StreamingBody};
use tokio::sync::{mpsc, oneshot};

use crate::{body::Incoming, proto::h2::client::ResponseFutMap};

pub(crate) type RetryPromise<T, U> = oneshot::Receiver<Result<U, TrySendError<T>>>;
pub(crate) type Promise<T> = oneshot::Receiver<Result<T, crate::Error>>;

/// An error when calling `try_send_request`.
///
/// There is a possibility of an error occurring on a connection in-between the
/// time that a request is queued and when it is actually written to the IO
/// transport. If that happens, it is safe to return the request back to the
/// caller, as it was never fully sent.
#[derive(Debug)]
pub struct TrySendError<T> {
    pub(crate) error: crate::Error,
    pub(crate) message: Option<T>,
}

pub(crate) fn channel<T, U>() -> (Sender<T, U>, Receiver<T, U>) {
    let (tx, rx) = mpsc::unbounded_channel();
    let (giver, taker) = want::new();
    let tx = Sender {
        buffered_once: AtomicBool::new(false),
        giver,
        inner: tx,
    };
    let rx = Receiver { inner: rx, taker };
    (tx, rx)
}

/// A bounded sender of requests and callbacks for when responses are ready.
///
/// While the inner sender is unbounded, the Giver is used to determine
/// if the Receiver is ready for another request.
pub(crate) struct Sender<T, U> {
    /// One message is always allowed, even if the Receiver hasn't asked
    /// for it yet. This boolean keeps track of whether we've sent one
    /// without notice.
    buffered_once: AtomicBool,
    /// The Giver helps watch that the Receiver side has been polled
    /// when the queue is empty. This helps us know when a request and
    /// response have been fully processed, and a connection is ready
    /// for more.
    giver: want::Giver,
    /// Actually bounded by the Giver, plus `buffered_once`.
    inner: mpsc::UnboundedSender<Envelope<T, U>>,
}

/// An unbounded version.
///
/// Cannot poll the Giver, but can still use it to determine if the Receiver
/// has been dropped. However, this version can be cloned.
pub(crate) struct UnboundedSender<T, U> {
    /// Only used for `is_closed`, since `mpsc::UnboundedSender` cannot be checked.
    giver: want::SharedGiver,
    inner: mpsc::UnboundedSender<Envelope<T, U>>,
}

impl<T, U> Sender<T, U> {
    pub(crate) fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<crate::Result<()>> {
        self.giver
            .poll_want(cx)
            .map_err(|_| crate::Error::new_closed())
    }

    pub(crate) fn is_ready(&self) -> bool {
        self.giver.is_wanting()
    }

    pub(crate) fn is_closed(&self) -> bool {
        self.giver.is_canceled()
    }

    fn can_send(&self) -> bool {
        // If the receiver is ready *now*, then of course we can send.
        //
        // If the receiver isn't ready yet, but we don't have anything
        // in the channel yet, then allow one message.
        self.giver.give() || !self.buffered_once.swap(true, atomic::Ordering::AcqRel)
    }

    #[expect(clippy::needless_pass_by_ref_mut)]
    pub(crate) fn try_send(&mut self, val: T) -> Result<RetryPromise<T, U>, T> {
        if !self.can_send() {
            return Err(val);
        }
        let (tx, rx) = oneshot::channel();
        self.inner
            .send(Envelope::new(val, Callback::retry(tx)))
            .map(move |_| rx)
            .map_err(|mpsc::error::SendError(env)| env.into_value())
    }

    pub(crate) fn send(&self, val: T) -> Result<Promise<U>, T> {
        if !self.can_send() {
            return Err(val);
        }
        let (tx, rx) = oneshot::channel();
        self.inner
            .send(Envelope::new(val, Callback::no_retry(tx)))
            .map(move |_| rx)
            .map_err(|mpsc::error::SendError(env)| env.into_value())
    }

    pub(crate) fn unbound(self) -> UnboundedSender<T, U> {
        UnboundedSender {
            giver: self.giver.shared(),
            inner: self.inner,
        }
    }
}

impl<T, U> UnboundedSender<T, U> {
    pub(crate) fn is_ready(&self) -> bool {
        !self.giver.is_canceled()
    }

    pub(crate) fn is_closed(&self) -> bool {
        self.giver.is_canceled()
    }

    #[expect(clippy::needless_pass_by_ref_mut)]
    pub(crate) fn try_send(&mut self, val: T) -> Result<RetryPromise<T, U>, T> {
        let (tx, rx) = oneshot::channel();
        self.inner
            .send(Envelope::new(val, Callback::retry(tx)))
            .map(move |_| rx)
            .map_err(|mpsc::error::SendError(env)| env.into_value())
    }

    pub(crate) fn send(&self, val: T) -> Result<Promise<U>, T> {
        let (tx, rx) = oneshot::channel();
        self.inner
            .send(Envelope::new(val, Callback::no_retry(tx)))
            .map(move |_| rx)
            .map_err(|mpsc::error::SendError(env)| env.into_value())
    }
}

impl<T, U> Clone for UnboundedSender<T, U> {
    fn clone(&self) -> Self {
        Self {
            giver: self.giver.clone(),
            inner: self.inner.clone(),
        }
    }
}

pub(crate) struct Receiver<T, U> {
    inner: mpsc::UnboundedReceiver<Envelope<T, U>>,
    taker: want::Taker,
}

impl<T, U> Receiver<T, U> {
    pub(crate) fn poll_recv(&mut self, cx: &mut Context<'_>) -> Poll<Option<(T, Callback<T, U>)>> {
        match self.inner.poll_recv(cx) {
            Poll::Ready(item) => {
                // A want signaled on an empty or budget-starved poll can outlive the message
                // taken here and report the busy connection as ready.
                self.taker.unwant();
                Poll::Ready(item.map(|env| env.into_inner()))
            }
            Poll::Pending => {
                self.taker.want();
                Poll::Pending
            }
        }
    }

    pub(crate) fn close(&mut self) {
        self.taker.cancel();
        self.inner.close();
    }

    /// Closes the queue and cancels what it holds, including messages whose send began before
    /// the close: their callers may hold a sender while awaiting the response.
    pub(crate) fn poll_close(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        self.close();
        while ready!(self.inner.poll_recv(cx)).is_some() {}
        Poll::Ready(())
    }

    pub(crate) fn try_recv(&mut self) -> Option<(T, Callback<T, U>)> {
        match rama_core::rt::future::now_or_never(self.inner.recv()) {
            Some(Some(env)) => Some(env.into_inner()),
            _ => None,
        }
    }
}

impl<T, U> Drop for Receiver<T, U> {
    fn drop(&mut self) {
        // Notify the giver about the closure first, before dropping
        // the mpsc::Receiver.
        self.taker.cancel();
    }
}

struct Envelope<T, U> {
    // Safety invariant: `data` holds a value that was not taken iff `used` is
    // false. Once `used` is true, `self` is only dropped.
    data: ManuallyDrop<(T, Callback<T, U>)>,
    used: bool,
}

impl<T, U> Envelope<T, U> {
    fn new(val: T, cb: Callback<T, U>) -> Self {
        Self {
            data: ManuallyDrop::new((val, cb)),
            used: false,
        }
    }

    #[inline(always)]
    fn into_inner(mut self) -> (T, Callback<T, U>) {
        debug_assert!(!self.used, "data taken before into_inner");
        // Keeps the field invariant: `data` is taken right below, and `self` is
        // then only dropped.
        self.used = true;
        // SAFETY: `ManuallyDrop::take` needs `data` to hold a value and not be used
        // again. `self` is used here, not dropped, so `used` was false on entry and
        // `data` holds a value (field invariant). After this `self` is only dropped,
        // and `Drop` skips `data` as `used` is now true.
        unsafe { ManuallyDrop::take(&mut self.data) }
    }

    #[inline(always)]
    fn into_value(self) -> T {
        self.into_inner().0
    }
}

impl<T, U> Drop for Envelope<T, U> {
    fn drop(&mut self) {
        if !self.used {
            // SAFETY: `ManuallyDrop::take` needs `data` to hold a value and not be
            // used again. `used` is false, so `data` holds a value (field
            // invariant), and this is `Drop`, so nothing uses `data` afterwards.
            let (val, cb) = unsafe { ManuallyDrop::take(&mut self.data) };
            cb.send(Err(TrySendError {
                error: crate::Error::new_canceled().with("connection closed"),
                message: Some(val),
            }));
        }
    }
}

pub(crate) struct Callback<T, U> {
    // Safety invariant: `cb` holds a value that was not taken iff `used` is
    // false. Once `used` is true, `self` is only dropped.
    cb: ManuallyDrop<InnerCallback<T, U>>,
    used: bool,
}

impl<T, U> Callback<T, U> {
    pub(crate) fn retry(tx: oneshot::Sender<Result<U, TrySendError<T>>>) -> Self {
        Self {
            cb: ManuallyDrop::new(InnerCallback::Retry(tx)),
            used: false,
        }
    }

    pub(crate) fn no_retry(tx: oneshot::Sender<Result<U, crate::Error>>) -> Self {
        Self {
            cb: ManuallyDrop::new(InnerCallback::NoRetry(tx)),
            used: false,
        }
    }
}

pub(crate) enum InnerCallback<T, U> {
    Retry(oneshot::Sender<Result<U, TrySendError<T>>>),
    NoRetry(oneshot::Sender<Result<U, crate::Error>>),
}

impl<T, U> Drop for Callback<T, U> {
    fn drop(&mut self) {
        if !self.used {
            // SAFETY: `ManuallyDrop::take` needs `cb` to hold a value and not be
            // used again. `used` is false, so `cb` holds a value (field invariant),
            // and this is `Drop`, so nothing uses `cb` afterwards.
            let cb = unsafe { ManuallyDrop::take(&mut self.cb) };
            cb.send(Err(TrySendError {
                error: dispatch_gone(),
                message: None,
            }));
        }
    }
}

#[cold]
fn dispatch_gone() -> crate::Error {
    // FIXME(nox): What errors do we want here?
    crate::Error::new_user_dispatch_gone().with(if std::thread::panicking() {
        "user code panicked"
    } else {
        "runtime dropped the dispatch task"
    })
}

impl<T, U> Callback<T, U> {
    pub(crate) fn is_canceled(&self) -> bool {
        match &*self.cb {
            InnerCallback::Retry(tx) => tx.is_closed(),
            InnerCallback::NoRetry(tx) => tx.is_closed(),
        }
    }

    pub(crate) fn poll_canceled(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        match &mut *self.cb {
            InnerCallback::Retry(tx) => tx.poll_closed(cx),
            InnerCallback::NoRetry(tx) => tx.poll_closed(cx),
        }
    }

    #[inline(always)]
    pub(crate) fn send(mut self, val: Result<U, TrySendError<T>>) {
        debug_assert!(!self.used, "cb taken before send");
        // Keeps the field invariant: `cb` is taken right below, and `self` is
        // then only dropped.
        self.used = true;
        // SAFETY: `ManuallyDrop::take` needs `cb` to hold a value and not be used
        // again. `self` is used here, not dropped, so `used` was false on entry and
        // `cb` holds a value (field invariant). After this `self` is only dropped,
        // and `Drop` skips `cb` as `used` is now true.
        let cb = unsafe { ManuallyDrop::take(&mut self.cb) };
        cb.send(val);
    }
}

impl<T, U> InnerCallback<T, U> {
    fn send(self, val: Result<U, TrySendError<T>>) {
        match self {
            Self::Retry(tx) => {
                if tx.send(val).is_err() {
                    tracing::debug!("client dispatch Callback::Retry: failed to send");
                }
            }
            Self::NoRetry(tx) => {
                if tx.send(val.map_err(|e| e.error)).is_err() {
                    tracing::debug!("client dispatch Callback::NoRetry: failed to send");
                }
            }
        }
    }
}

impl<T> TrySendError<T> {
    /// Take the message from this error.
    ///
    /// The message will not always have been recovered. If an error occurs
    /// after the message has been serialized onto the connection, it will not
    /// be available here.
    pub fn take_message(&mut self) -> Option<T> {
        self.message.take()
    }

    /// Consumes this to return the inner error.
    pub fn into_error(self) -> crate::Error {
        self.error
    }
}

pin_project! {
    pub struct SendWhen<B>
    where
        B: StreamingBody,
        B: Send,
        B: 'static,
        B: Unpin,
        B::Data: Send,
        B::Data: 'static,
        B::Error: Into<BoxError>,
    {
        #[pin]
        pub(crate) when: ResponseFutMap<B>,
        #[pin]
        pub(crate) call_back: Option<Callback<Request<B>, Response<Incoming>>>,
    }
}

impl<B> Future for SendWhen<B>
where
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
{
    type Output = ();

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let mut this = self.project();

        let Some(mut call_back) = this.call_back.take() else {
            tracing::warn!(
                "client::SendWhen: polled after complete: please report bug in rama repo"
            );
            return Poll::Ready(());
        };

        match Pin::new(&mut this.when).poll(cx) {
            Poll::Ready(Ok(res)) => {
                call_back.send(Ok(res));
                Poll::Ready(())
            }
            Poll::Pending => {
                // check if the callback is canceled
                match call_back.poll_canceled(cx) {
                    Poll::Ready(v) => v,
                    Poll::Pending => {
                        // Move call_back back to struct before return
                        this.call_back.set(Some(call_back));
                        return Poll::Pending;
                    }
                }
                trace!("send_when canceled");
                // Tell pipe_task to reset the h2 stream so that
                // RST_STREAM is sent and flow-control capacity freed.
                this.when.as_mut().cancel();
                Poll::Ready(())
            }
            Poll::Ready(Err((error, message))) => {
                call_back.send(Err(TrySendError { error, message }));
                Poll::Ready(())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::future::poll_fn;
    use std::pin::Pin;
    use std::task::{Context, Poll};

    use tokio::task::{coop, yield_now};

    use super::{Callback, Receiver, channel};

    #[derive(Debug)]
    struct Custom(#[expect(dead_code)] i32);

    impl<T, U> Future for Receiver<T, U> {
        type Output = Option<(T, Callback<T, U>)>;

        fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
            self.poll_recv(cx)
        }
    }

    /// Helper to check if the future is ready after polling once.
    struct PollOnce<'a, F>(&'a mut F);

    impl<F, T> Future for PollOnce<'_, F>
    where
        F: Future<Output = T> + Unpin,
    {
        type Output = Option<()>;

        fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
            match Pin::new(&mut self.0).poll(cx) {
                Poll::Ready(_) => Poll::Ready(Some(())),
                Poll::Pending => Poll::Ready(None),
            }
        }
    }

    #[cfg(not(miri))]
    #[tokio::test]
    async fn drop_receiver_sends_cancel_errors() {
        let (mut tx, mut rx) = channel::<Custom, ()>();

        // must poll once for try_send to succeed
        assert!(PollOnce(&mut rx).await.is_none(), "rx empty");

        let promise = tx.try_send(Custom(43)).unwrap();
        drop(rx);

        let fulfilled = promise.await;
        let err = fulfilled
            .expect("fulfilled")
            .expect_err("promise should error");
        match (err.error.is_canceled(), err.message) {
            (true, Some(_)) => (),
            e => panic!("expected Error::Cancel(_), found {e:?}"),
        }
    }

    #[cfg(not(miri))]
    #[tokio::test]
    async fn poll_close_cancels_queued_messages_without_a_drop() {
        let (tx, mut rx) = channel::<Custom, ()>();
        let mut tx = tx.unbound();
        let promise = tx.try_send(Custom(1)).unwrap();

        // Out of coop budget a closed queue still reports Pending, as it does
        // for a send that began before the close and has yet to publish.
        let closed = poll_fn(|cx| {
            while let Poll::Ready(restore) = coop::poll_proceed(cx) {
                restore.made_progress();
            }
            Poll::Ready(rx.poll_close(cx).is_ready())
        })
        .await;
        assert!(!closed, "must drain what was sent before completing");
        assert!(tx.is_closed(), "must reject new messages while draining");

        yield_now().await;
        assert!(poll_fn(|cx| Poll::Ready(rx.poll_close(cx).is_ready())).await);

        // Both halves stay alive: the cancel must not depend on a destructor.
        let err = promise
            .await
            .expect("fulfilled")
            .expect_err("promise should error");
        assert!(err.error.is_canceled(), "{err:?}");
        assert!(err.message.is_some(), "a message never sent is returned");
        drop((tx, rx));
    }

    #[cfg(not(miri))]
    #[tokio::test]
    async fn sender_checks_for_want_on_send() {
        let (mut tx, mut rx) = channel::<Custom, ()>();

        // one is allowed to buffer, second is rejected
        tx.try_send(Custom(1)).expect("1 buffered");
        tx.try_send(Custom(2)).expect_err("2 not ready");

        assert!(PollOnce(&mut rx).await.is_some(), "rx once");

        // Even though 1 has been popped, only 1 could be buffered for the
        // lifetime of the channel.
        tx.try_send(Custom(2)).expect_err("2 still not ready");

        assert!(PollOnce(&mut rx).await.is_none(), "rx empty");

        tx.try_send(Custom(2)).expect("2 ready");
    }

    #[test]
    fn unbounded_sender_doesnt_bound_on_want() {
        let (tx, rx) = channel::<Custom, ()>();
        let mut tx = tx.unbound();

        tx.try_send(Custom(1)).unwrap();
        tx.try_send(Custom(2)).unwrap();
        tx.try_send(Custom(3)).unwrap();

        drop(rx);

        tx.try_send(Custom(4)).unwrap_err();
    }
}
