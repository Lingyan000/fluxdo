use std::{
    future::Future,
    pin::Pin,
    task::{Context, Poll},
};

use crate::body::http_body::{Body, Frame, SizeHint};
use futures_core::ready;
use pin_project_lite::pin_project;

pin_project! {
    /// A [`Body`] backed by a fallible [`Future`] that resolves into the actual body.
    ///
    /// The future is polled until it yields either a `B` body, whose frames are then
    /// yielded, or an error, which is yielded as the only frame. This is handy when a
    /// body is produced asynchronously, e.g. received over a oneshot channel or read
    /// from the filesystem.
    pub struct TryFutureBody<F, B> {
        #[pin]
        inner: Inner<F, B>,
    }
}

pin_project! {
    #[project = InnerProj]
    enum Inner<F, B> {
        Future {
            #[pin]
            future: F,
        },
        Body {
            #[pin]
            body: B,
        },
        Failed,
    }
}

impl<F, B> TryFutureBody<F, B> {
    /// Create a new [`TryFutureBody`] wrapping the provided future.
    pub fn new(future: F) -> Self {
        Self {
            inner: Inner::Future { future },
        }
    }
}

impl<F, B, E> Body for TryFutureBody<F, B>
where
    F: Future<Output = Result<B, E>>,
    B: Body,
    E: Into<B::Error>,
{
    type Data = B::Data;
    type Error = B::Error;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        let mut inner = self.project().inner;
        loop {
            match inner.as_mut().project() {
                InnerProj::Future { future } => match ready!(future.poll(cx)) {
                    Ok(body) => inner.set(Inner::Body { body }),
                    Err(err) => {
                        inner.set(Inner::Failed);
                        return Poll::Ready(Some(Err(err.into())));
                    }
                },
                InnerProj::Body { body } => return body.poll_frame(cx),
                InnerProj::Failed => return Poll::Ready(None),
            }
        }
    }

    fn is_end_stream(&self) -> bool {
        match &self.inner {
            Inner::Future { .. } => false,
            Inner::Body { body } => body.is_end_stream(),
            Inner::Failed => true,
        }
    }

    fn size_hint(&self) -> SizeHint {
        match &self.inner {
            Inner::Future { .. } => SizeHint::new(),
            Inner::Body { body } => body.size_hint(),
            Inner::Failed => SizeHint::with_exact(0),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::convert::Infallible;
    use std::future::ready;
    use std::task::Waker;

    use super::*;
    use crate::body::http_body_util::{ErrorBody, Full};
    use bytes::Bytes;

    fn assert_unresolved_hints<T: Body>(body: &T) {
        assert!(!body.is_end_stream(), "not over before the future resolves");
        let hint = body.size_hint();
        assert_eq!(hint.lower(), 0, "no lower bound before the future resolves");
        assert_eq!(
            hint.upper(),
            None,
            "no upper bound before the future resolves"
        );
    }

    fn assert_finished_hints<T: Body>(body: &T) {
        assert!(body.is_end_stream(), "over once finished");
        assert_eq!(
            body.size_hint().exact(),
            Some(0),
            "nothing left once finished"
        );
    }

    #[test]
    fn full_ready_body() {
        let inner = Full::new(Bytes::from_static(b"hello"));
        let mut body = TryFutureBody::new(ready(Ok::<_, Infallible>(inner)));
        assert_unresolved_hints(&body);

        let mut cx = Context::from_waker(Waker::noop());

        let Poll::Ready(Some(Ok(frame))) = Pin::new(&mut body).poll_frame(&mut cx) else {
            panic!("body should yield a frame when polled");
        };
        let data = frame.into_data().expect("frame should contain data");
        assert_eq!(data, "hello", "underlying body frames are returned");

        let Poll::Ready(None) = Pin::new(&mut body).poll_frame(&mut cx) else {
            panic!("body should be `Ready(None)` when polled");
        };
        assert_finished_hints(&body);
    }

    #[test]
    fn error_body() {
        const ERROR: &str = "houston we have a problem";

        let inner = ErrorBody::<Bytes, &'static str>::new(ERROR);
        let mut body = TryFutureBody::new(ready(Ok::<_, &'static str>(inner)));
        assert_unresolved_hints(&body);

        let mut cx = Context::from_waker(Waker::noop());

        let Poll::Ready(Some(Err(err))) = Pin::new(&mut body).poll_frame(&mut cx) else {
            panic!("body should yield an error when polled");
        };
        assert_eq!(err, ERROR, "inner body errors are returned");
        assert_finished_hints(&body);
    }

    #[test]
    fn error_future() {
        const ERROR: &str = "there is no body";

        let future = ready(Err::<ErrorBody<Bytes, String>, _>(ERROR.to_owned()));
        let mut body = TryFutureBody::new(future);
        assert_unresolved_hints(&body);

        let mut cx = Context::from_waker(Waker::noop());

        let Poll::Ready(Some(Err(err))) = Pin::new(&mut body).poll_frame(&mut cx) else {
            panic!("body should yield an error when polled");
        };
        assert_eq!(err, ERROR, "future errors are returned");
        assert_finished_hints(&body);

        let Poll::Ready(None) = Pin::new(&mut body).poll_frame(&mut cx) else {
            panic!("body should be `Ready(None)` after the future failed");
        };
    }
}
