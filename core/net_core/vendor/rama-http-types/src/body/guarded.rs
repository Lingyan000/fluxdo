use pin_project_lite::pin_project;
use std::pin::Pin;
use std::task::{Context, Poll};

use super::{Frame, SizeHint, StreamingBody};

pin_project! {
    /// A [`StreamingBody`] wrapper that owns an opaque `guard` and releases it
    /// when the body is **fully consumed on the wire** ([`StreamingBody::poll_frame`]
    /// returns `Poll::Ready(None)`), or on drop if the body is abandoned early.
    ///
    /// This ties the guard's lifetime to the body it accompanies rather than to
    /// the response headers. The motivating use is a pooled connection handle: the
    /// connector returns the response at headers and immediately drops its handle,
    /// but the connection is logically still in use until the body has been read.
    /// By moving the handle in here, its release (e.g. freeing a stream slot or
    /// returning the connection to the pool) happens when the body is done.
    ///
    /// The guard is released exactly once: either at end-of-stream or, for an
    /// early drop (e.g. a cancelled/aborted read), when this body is dropped.
    #[must_use = "GuardedBody does nothing unless polled as a response body"]
    pub struct GuardedBody<B, G> {
        // field order is load-bearing: `inner` drops before `guard`, so a body
        // wrapper reacting to an early drop (e.g. marking the connection
        // broken) runs before the guard releases the connection to a pool.
        #[pin]
        inner: B,
        guard: Option<G>,
    }
}

impl<B, G> GuardedBody<B, G> {
    /// Wrap `inner`, holding `guard` until the body reaches end-of-stream or is dropped.
    pub fn new(inner: B, guard: G) -> Self {
        Self {
            inner,
            guard: Some(guard),
        }
    }
}

impl<B, G> StreamingBody for GuardedBody<B, G>
where
    B: StreamingBody,
{
    type Data = B::Data;
    type Error = B::Error;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        let this = self.project();
        let result = this.inner.poll_frame(cx);
        if matches!(result, Poll::Ready(None | Some(Err(_)))) {
            // Fully consumed (or errored) on the wire: release the guard now,
            // rather than waiting for this body to be dropped.
            *this.guard = None;
        }
        result
    }

    #[inline(always)]
    fn is_end_stream(&self) -> bool {
        self.inner.is_end_stream()
    }

    #[inline(always)]
    fn size_hint(&self) -> SizeHint {
        self.inner.size_hint()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::body::util::{BodyExt, Empty, Full};
    use parking_lot::Mutex;
    use rama_core::bytes::Bytes;
    use std::convert::Infallible;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    /// A guard whose drop flips a shared flag, so tests can observe release timing.
    struct ReleaseFlag(Arc<AtomicBool>);
    impl Drop for ReleaseFlag {
        fn drop(&mut self) {
            self.0.store(true, Ordering::Relaxed);
        }
    }

    #[tokio::test]
    async fn releases_at_end_of_stream() {
        let released = Arc::new(AtomicBool::new(false));
        let body = GuardedBody::new(
            Full::<Bytes>::from(Bytes::from("hello")),
            ReleaseFlag(released.clone()),
        );
        // Not released until the stream is actually exhausted.
        assert!(!released.load(Ordering::Relaxed));
        body.collect().await.unwrap();
        assert!(released.load(Ordering::Relaxed));
    }

    #[tokio::test]
    async fn releases_on_early_drop() {
        let released = Arc::new(AtomicBool::new(false));
        // Consume only the single data frame, then drop before end-of-stream.
        let mut body = GuardedBody::new(
            Full::<Bytes>::from(Bytes::from("hello")),
            ReleaseFlag(released.clone()),
        );
        let _ = body.frame().await;
        assert!(!released.load(Ordering::Relaxed));
        drop(body);
        assert!(released.load(Ordering::Relaxed));
    }

    #[tokio::test]
    async fn releases_once_on_empty_body() {
        let released = Arc::new(AtomicBool::new(false));
        GuardedBody::new(Empty::<Bytes>::new(), ReleaseFlag(released.clone()))
            .collect()
            .await
            .unwrap();
        assert!(released.load(Ordering::Relaxed));
    }

    struct DropOrderBody(Arc<Mutex<Vec<&'static str>>>);

    impl Drop for DropOrderBody {
        fn drop(&mut self) {
            self.0.lock().push("body");
        }
    }

    impl StreamingBody for DropOrderBody {
        type Data = Bytes;
        type Error = Infallible;

        fn poll_frame(
            self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
        ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
            Poll::Pending
        }
    }

    struct DropOrderGuard(Arc<Mutex<Vec<&'static str>>>);

    impl Drop for DropOrderGuard {
        fn drop(&mut self) {
            self.0.lock().push("guard");
        }
    }

    #[test]
    fn drops_body_before_releasing_guard() {
        let order = Arc::new(Mutex::new(Vec::new()));
        drop(GuardedBody::new(
            DropOrderBody(order.clone()),
            DropOrderGuard(order.clone()),
        ));
        assert_eq!(*order.lock(), ["body", "guard"]);
    }
}
