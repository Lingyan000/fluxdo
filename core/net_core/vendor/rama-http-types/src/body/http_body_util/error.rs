use std::{
    fmt,
    marker::PhantomData,
    pin::Pin,
    task::{Context, Poll},
};

use crate::body::http_body::{Body, Frame, SizeHint};
use bytes::Buf;

/// A [`Body`] that yields a single error when polled, and ends after that.
///
/// The `D` generic sets the [`Body::Data`] type it would yield were it not to fail,
/// which makes it handy to exercise the error handling of body middleware.
pub struct ErrorBody<D, E> {
    error: Option<E>,
    _marker: PhantomData<fn() -> D>,
}

impl<D, E> ErrorBody<D, E> {
    /// Create a new [`ErrorBody`] that will yield the provided error.
    ///
    /// # Example
    ///
    /// ```
    /// use rama_core::bytes::Bytes;
    /// use rama_http_types::body::util::{BodyExt, ErrorBody};
    ///
    /// # #[tokio::main]
    /// # async fn main() {
    /// let mut body = ErrorBody::<Bytes, &str>::new("problem");
    /// assert_eq!(body.frame().await.unwrap().unwrap_err(), "problem");
    /// assert!(body.frame().await.is_none());
    /// # }
    /// ```
    pub fn new(error: E) -> Self {
        Self {
            error: Some(error),
            _marker: PhantomData,
        }
    }
}

impl<D: Buf, E> Body for ErrorBody<D, E> {
    type Data = D;
    type Error = E;

    fn poll_frame(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        Poll::Ready(self.get_mut().error.take().map(Err))
    }

    fn is_end_stream(&self) -> bool {
        self.error.is_none()
    }

    fn size_hint(&self) -> SizeHint {
        // unknown until failed, so consumers keep polling for the error
        if self.error.is_none() {
            SizeHint::with_exact(0)
        } else {
            SizeHint::new()
        }
    }
}

// The error is never pinned.
impl<D, E> Unpin for ErrorBody<D, E> {}

impl<D, E: fmt::Debug> fmt::Debug for ErrorBody<D, E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ErrorBody")
            .field("error", &self.error)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use std::task::Waker;

    use super::*;
    use bytes::Bytes;

    #[test]
    fn returns_error_once() {
        let mut body = ErrorBody::<Bytes, &'static str>::new("problem");
        assert!(!body.is_end_stream(), "body is not finished until polled");
        assert_eq!(body.size_hint().lower(), 0);
        assert_eq!(body.size_hint().upper(), None);

        let mut cx = Context::from_waker(Waker::noop());

        match Pin::new(&mut body).poll_frame(&mut cx) {
            Poll::Ready(Some(Err("problem"))) => {}
            other => panic!("unexpected poll outcome: {other:?}"),
        }

        assert!(body.is_end_stream(), "body is finished after being polled");
        assert_eq!(body.size_hint().exact(), Some(0));

        match Pin::new(&mut body).poll_frame(&mut cx) {
            Poll::Ready(None) => {}
            other => panic!("unexpected poll outcome: {other:?}"),
        }
    }
}
