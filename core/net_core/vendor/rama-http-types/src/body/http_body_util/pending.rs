use std::{
    fmt,
    marker::PhantomData,
    pin::Pin,
    task::{Context, Poll},
};

use crate::body::http_body::{Body, Frame, SizeHint};
use bytes::Buf;

/// A [`Body`] that never yields a frame, the body counterpart of [`std::future::Pending`].
///
/// The `D` and `E` generics set its [`Body::Data`] and [`Body::Error`]. Chained behind
/// data via [`BodyExt::chain`] it makes a body that hangs mid-stream, e.g. to exercise
/// timeouts.
///
/// [`BodyExt::chain`]: crate::body::util::BodyExt::chain
pub struct Pending<D, E> {
    _marker: PhantomData<fn() -> (D, E)>,
}

impl<D, E> Pending<D, E> {
    /// Create a new [`Pending`] body.
    ///
    /// # Example
    ///
    /// ```
    /// use std::pin::Pin;
    /// use std::task::{Context, Waker};
    ///
    /// use rama_core::bytes::Bytes;
    /// use rama_core::error::BoxError;
    /// use rama_http_types::body::{StreamingBody, util::Pending};
    ///
    /// let mut body = Pending::<Bytes, BoxError>::new();
    /// let mut cx = Context::from_waker(Waker::noop());
    /// assert!(Pin::new(&mut body).poll_frame(&mut cx).is_pending());
    /// ```
    pub const fn new() -> Self {
        Self {
            _marker: PhantomData,
        }
    }
}

impl<D: Buf, E> Body for Pending<D, E> {
    type Data = D;
    type Error = E;

    fn poll_frame(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        Poll::Pending
    }

    fn is_end_stream(&self) -> bool {
        false
    }

    fn size_hint(&self) -> SizeHint {
        SizeHint::new()
    }
}

impl<D, E> fmt::Debug for Pending<D, E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Pending").finish()
    }
}

impl<D, E> Default for Pending<D, E> {
    fn default() -> Self {
        Self::new()
    }
}

impl<D, E> Clone for Pending<D, E> {
    fn clone(&self) -> Self {
        *self
    }
}

impl<D, E> Copy for Pending<D, E> {}

#[cfg(test)]
mod tests {
    use std::task::Waker;

    use super::*;
    use crate::body::http_body_util::{BodyExt, Full};
    use bytes::Bytes;
    use rama_core::error::BoxError;

    #[test]
    fn yields_poll_pending() {
        let mut body = Pending::<Bytes, &'static str>::new();
        assert!(!body.is_end_stream());
        assert_eq!(body.size_hint().lower(), 0);
        assert_eq!(body.size_hint().upper(), None);

        let mut cx = Context::from_waker(Waker::noop());
        for _ in 0..2 {
            match Pin::new(&mut body).poll_frame(&mut cx) {
                Poll::Pending => {}
                other => panic!("unexpected poll outcome: {other:?}"),
            }
        }
    }

    #[test]
    fn chained_after_data_hangs() {
        let mut body =
            Full::new(Bytes::from_static(b"head")).chain(Pending::<Bytes, BoxError>::new());
        let mut cx = Context::from_waker(Waker::noop());

        match Pin::new(&mut body).poll_frame(&mut cx) {
            Poll::Ready(Some(Ok(frame))) => assert_eq!(frame.into_data().unwrap(), "head"),
            other => panic!("unexpected poll outcome: {other:?}"),
        }
        assert!(Pin::new(&mut body).poll_frame(&mut cx).is_pending());
        assert!(!body.is_end_stream());
    }
}
