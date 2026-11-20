use pin_project_lite::pin_project;
use rama_utils::guard::DropGuard;
use std::pin::Pin;
use std::task::{Context, Poll};

use super::{Frame, SizeHint, StreamingBody};

pin_project! {
    /// A [`StreamingBody`] wrapper that calls a closure when dropped before the body
    /// is fully consumed.
    ///
    /// The closure fires if the body is dropped before [`StreamingBody::poll_frame`]
    /// returns `Poll::Ready(None)`. A common cause is a client disconnecting
    /// mid-response (e.g. during a streaming or SSE endpoint).
    ///
    /// The closure is called exactly once: it is disarmed when the stream is
    /// exhausted normally, so it only fires on early drops.
    ///
    /// # Example
    ///
    /// ```rust
    /// use rama_http_types::body::{Body, OnDropBody};
    ///
    /// let body = Body::from("hello world");
    /// let wrapped = Body::new(OnDropBody::new(body, || {
    ///     // client disconnected before the response was fully sent
    /// }));
    /// ```
    ///
    /// Or via the [`Body::on_drop`] convenience method:
    ///
    /// ```rust
    /// use rama_http_types::body::Body;
    ///
    /// let body = Body::from("hello world").on_drop(|| {
    ///     // client disconnected before the response was fully sent
    /// });
    /// ```
    #[must_use = "OnDropBody does nothing unless polled as a response body"]
    pub struct OnDropBody<B, F: FnOnce()> {
        #[pin]
        inner: B,
        guard: DropGuard<F>,
    }
}

impl<B, F: FnOnce()> OnDropBody<B, F> {
    /// Wrap `inner` with a drop callback.
    ///
    /// `on_drop` is called once if the body is dropped before
    /// [`StreamingBody::poll_frame`] returns `Poll::Ready(None)`.
    pub fn new(inner: B, on_drop: F) -> Self {
        Self {
            inner,
            guard: DropGuard::new(on_drop),
        }
    }
}

impl<B, F> StreamingBody for OnDropBody<B, F>
where
    B: StreamingBody,
    F: FnOnce(),
{
    type Data = B::Data;
    type Error = B::Error;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        let this = self.project();
        let result = this.inner.poll_frame(cx);
        if matches!(result, Poll::Ready(None)) {
            // Stream exhausted normally — disarm the callback.
            this.guard.disarm();
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
    use rama_core::bytes::Bytes;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    fn make_flag() -> (Arc<AtomicBool>, impl FnOnce()) {
        let flag = Arc::new(AtomicBool::new(false));
        let flag2 = flag.clone();
        (flag, move || flag2.store(true, Ordering::Relaxed))
    }

    #[test]
    fn fires_on_early_drop() {
        let (fired, cb) = make_flag();
        drop(OnDropBody::new(
            Full::<Bytes>::from(Bytes::from("hello")),
            cb,
        ));
        assert!(fired.load(Ordering::Relaxed));
    }

    #[tokio::test]
    async fn does_not_fire_when_exhausted() {
        let (fired, cb) = make_flag();
        OnDropBody::new(Full::<Bytes>::from(Bytes::from("hello")), cb)
            .collect()
            .await
            .unwrap();
        assert!(!fired.load(Ordering::Relaxed));
    }

    #[tokio::test]
    async fn does_not_fire_on_empty_body() {
        let (fired, cb) = make_flag();
        OnDropBody::new(Empty::<Bytes>::new(), cb)
            .collect()
            .await
            .unwrap();
        assert!(!fired.load(Ordering::Relaxed));
    }

    #[tokio::test]
    async fn fires_mid_stream() {
        let (fired, cb) = make_flag();
        // Full<Bytes> emits one data frame then Poll::Ready(None).
        // Consuming only the data frame leaves the stream incomplete.
        let mut wrapped = OnDropBody::new(Full::<Bytes>::from(Bytes::from("hello")), cb);
        let _ = wrapped.frame().await; // data frame — not end-of-stream
        drop(wrapped);
        assert!(fired.load(Ordering::Relaxed));
    }
}
