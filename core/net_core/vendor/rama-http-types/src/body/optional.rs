use std::{
    pin::Pin,
    task::{Context, Poll},
};

use pin_project_lite::pin_project;

use super::{Frame, SizeHint, StreamingBody};

pin_project! {
    /// An optional [`StreamingBody`].
    #[derive(Debug, Clone)]
    pub struct OptionalBody<B> {
        #[pin]
        inner: Option<B>,
    }
}

impl<B> Default for OptionalBody<B> {
    #[inline(always)]
    fn default() -> Self {
        Self::none()
    }
}

impl<B> From<B> for OptionalBody<B> {
    #[inline(always)]
    fn from(value: B) -> Self {
        Self::some(value)
    }
}

impl<B> OptionalBody<B> {
    #[inline(always)]
    /// Create an [`OptionalBody`] using the given inner [`StreamingBody`].
    pub const fn some(inner: B) -> Self {
        Self { inner: Some(inner) }
    }

    #[inline(always)]
    /// Create an empty [`OptionalBody`] which will return zero [`Frame`]s.
    pub const fn none() -> Self {
        Self { inner: None }
    }

    /// Get an optional shared reference to the inner
    /// [`StreamingBody`] if there's any.
    #[inline(always)]
    pub const fn as_ref(&self) -> Option<&B> {
        self.inner.as_ref()
    }

    /// Get an optional exclusive reference to the inner
    /// [`StreamingBody`] if there's any.
    #[inline(always)]
    pub const fn as_mut(&mut self) -> Option<&mut B> {
        self.inner.as_mut()
    }
}

impl<B> StreamingBody for OptionalBody<B>
where
    B: StreamingBody,
{
    type Data = B::Data;
    type Error = B::Error;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        match self.project().inner.as_pin_mut() {
            Some(b) => b.poll_frame(cx),
            None => Poll::Ready(None),
        }
    }

    fn is_end_stream(&self) -> bool {
        match &self.inner {
            Some(b) => b.is_end_stream(),
            None => true,
        }
    }

    fn size_hint(&self) -> SizeHint {
        match &self.inner {
            Some(body) => body.size_hint(),
            None => SizeHint::with_exact(0),
        }
    }
}
