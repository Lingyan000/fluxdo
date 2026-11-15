use pin_project_lite::pin_project;
use rama_utils::guard::DropGuard;
use std::pin::Pin;
use std::task::{Context, Poll};

use super::{Frame, SizeHint, StreamingBody};

pin_project! {
    /// A [`StreamingBody`] wrapper that calls a closure as soon as it is known
    /// the body will not complete: an error frame is observed, or the body is
    /// dropped before end-of-stream.
    ///
    /// Unlike [`OnDropBody`](super::OnDropBody) (which only reacts to drops),
    /// this fires at error-observation time and treats a body whose
    /// [`StreamingBody::is_end_stream`] already reports completion as complete,
    /// both at construction (e.g. an empty body that is never polled) and after
    /// its final frame (e.g. a content-length body read to its last byte, or a
    /// chunked body whose terminal trailers frame was read, dropped before the
    /// trailing `poll_frame -> Ready(None)`).
    ///
    /// The closure is called at most once. The motivating use is connection
    /// reuse: a transport whose response was abandoned or errored mid-message
    /// must be marked non-reusable *synchronously*, before whatever guard
    /// releases it (e.g. back into a connection pool) runs — an asynchronous
    /// observer on the connection task loses that race to the next request.
    #[must_use = "dropping an OnIncompleteBody before it completes invokes its callback; poll it as a response body"]
    pub struct OnIncompleteBody<B, F: FnOnce()> {
        #[pin]
        body: B,
        guard: DropGuard<F>,
    }
}

impl<B: StreamingBody, F: FnOnce()> OnIncompleteBody<B, F> {
    /// Wrap `body`, calling `on_incomplete` once if it errors or is abandoned
    /// before end-of-stream.
    pub fn new(body: B, on_incomplete: F) -> Self {
        let mut guard = DropGuard::new(on_incomplete);
        if body.is_end_stream() {
            guard.disarm();
        }
        Self { body, guard }
    }
}

impl<B, F> StreamingBody for OnIncompleteBody<B, F>
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
        let mut this = self.project();
        let result = this.body.as_mut().poll_frame(cx);
        match &result {
            // stream exhausted normally: disarm
            Poll::Ready(None) => this.guard.disarm(),
            // fire now: a guard around this body (releasing e.g. a pool lease)
            // typically runs right after this poll returns
            Poll::Ready(Some(Err(_))) => this.guard.fire(),
            Poll::Ready(Some(Ok(frame))) => {
                // trailers are by contract the final frame; also disarm once the
                // body reports end-of-stream (e.g. a content-length body whose
                // last bytes were just read)
                if frame.is_trailers() || this.body.is_end_stream() {
                    this.guard.disarm();
                }
            }
            Poll::Pending => {}
        }
        result
    }

    #[inline(always)]
    fn is_end_stream(&self) -> bool {
        self.body.is_end_stream()
    }

    #[inline(always)]
    fn size_hint(&self) -> SizeHint {
        self.body.size_hint()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::body::util::{BodyExt, Empty, Full};
    use rama_core::bytes::Bytes;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn make_counter() -> (Arc<AtomicUsize>, impl FnOnce()) {
        let count = Arc::new(AtomicUsize::new(0));
        let count2 = count.clone();
        (count, move || {
            count2.fetch_add(1, Ordering::Relaxed);
        })
    }

    /// Yields one data frame, then an error frame; never reaches end-of-stream.
    struct DataThenError {
        polls: usize,
    }

    impl StreamingBody for DataThenError {
        type Data = Bytes;
        type Error = std::io::Error;

        fn poll_frame(
            mut self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
        ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
            self.polls += 1;
            match self.polls {
                1 => Poll::Ready(Some(Ok(Frame::data(Bytes::from("hello"))))),
                _ => Poll::Ready(Some(Err(std::io::Error::other("mid-stream failure")))),
            }
        }

        fn is_end_stream(&self) -> bool {
            false
        }
    }

    /// Yields one data frame, then terminal trailers, then end-of-stream —
    /// while never reporting `is_end_stream` (like a chunked h1 body).
    struct DataThenTrailers {
        polls: usize,
    }

    impl StreamingBody for DataThenTrailers {
        type Data = Bytes;
        type Error = std::io::Error;

        fn poll_frame(
            mut self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
        ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
            self.polls += 1;
            match self.polls {
                1 => Poll::Ready(Some(Ok(Frame::data(Bytes::from("hello"))))),
                2 => Poll::Ready(Some(Ok(Frame::trailers(crate::HeaderMap::new())))),
                _ => Poll::Ready(None),
            }
        }

        fn is_end_stream(&self) -> bool {
            false
        }
    }

    #[tokio::test]
    async fn does_not_fire_after_terminal_trailers_frame() {
        let (fired, cb) = make_counter();
        let mut body = OnIncompleteBody::new(DataThenTrailers { polls: 0 }, cb);
        body.frame().await.unwrap().unwrap();
        let trailers = body.frame().await.unwrap().unwrap();
        assert!(trailers.is_trailers());
        // dropped after the terminal trailers frame, without polling the final
        // `None`: the body is fully consumed and must not count as incomplete
        drop(body);
        assert_eq!(fired.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn fires_on_early_drop() {
        let (fired, cb) = make_counter();
        drop(OnIncompleteBody::new(
            Full::<Bytes>::from(Bytes::from("hello")),
            cb,
        ));
        assert_eq!(fired.load(Ordering::Relaxed), 1);
    }

    #[tokio::test]
    async fn does_not_fire_when_exhausted() {
        let (fired, cb) = make_counter();
        OnIncompleteBody::new(Full::<Bytes>::from(Bytes::from("hello")), cb)
            .collect()
            .await
            .unwrap();
        assert_eq!(fired.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn does_not_fire_on_empty_body_never_polled() {
        let (fired, cb) = make_counter();
        drop(OnIncompleteBody::new(Empty::<Bytes>::new(), cb));
        assert_eq!(fired.load(Ordering::Relaxed), 0);
    }

    #[tokio::test]
    async fn does_not_fire_when_end_stream_reached_without_polling_none() {
        let (fired, cb) = make_counter();
        // Full reports is_end_stream after its single data frame is consumed:
        // dropping without polling the final `None` still counts as complete.
        let mut body = OnIncompleteBody::new(Full::<Bytes>::from(Bytes::from("hello")), cb);
        let _ = body.frame().await;
        drop(body);
        assert_eq!(fired.load(Ordering::Relaxed), 0);
    }

    #[tokio::test]
    async fn fires_once_at_error_observation() {
        let (fired, cb) = make_counter();
        let mut body = OnIncompleteBody::new(DataThenError { polls: 0 }, cb);
        body.frame().await.unwrap().unwrap();
        assert_eq!(fired.load(Ordering::Relaxed), 0);
        body.frame().await.unwrap().unwrap_err();
        assert_eq!(
            fired.load(Ordering::Relaxed),
            1,
            "must fire at error observation, before the body is dropped"
        );
        drop(body);
        assert_eq!(fired.load(Ordering::Relaxed), 1, "must fire only once");
    }
}
