use std::{
    future::Future,
    pin::Pin,
    task::{Context, Poll},
};

use crate::body::http_body::Body;
use crate::body::util::CollectError;
use futures_core::ready;
use pin_project_lite::pin_project;
use rama_core::error::BoxError;

pin_project! {
    /// Future that resolves into a [`Collected`].
    ///
    /// On a body stream error it yields a [`CollectError`] which still carries
    /// the bytes read before the failure (the remainder is unrecoverable). Use
    /// [`BodyExt::collect_with`] when you also want to cap size or time and keep
    /// the unread remainder forwardable.
    ///
    /// [`Collected`]: crate::body::http_body_util::Collected
    /// [`BodyExt::collect_with`]: crate::body::http_body_util::BodyExt::collect_with
    pub struct Collect<T>
    where
        T: Body,
        T: ?Sized,
    {
        pub(crate) collected: Option<crate::body::http_body_util::Collected<T::Data>>,
        #[pin]
        pub(crate) body: T,
    }
}

impl<T: Body + ?Sized> Future for Collect<T>
where
    T::Error: Into<BoxError>,
{
    type Output = Result<crate::body::http_body_util::Collected<T::Data>, CollectError>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> std::task::Poll<Self::Output> {
        let mut me = self.project();

        loop {
            match ready!(me.body.as_mut().poll_frame(cx)) {
                Some(Ok(frame)) => me.collected.as_mut().unwrap().push_frame(frame),
                Some(Err(err)) => {
                    // Hand back what we managed to read; the body itself is faulty
                    // and cannot be turned back into a forwardable remainder.
                    let read = me.collected.take().expect("polled after complete");
                    return Poll::Ready(Err(CollectError::stream(read.to_bytes(), err.into())));
                }
                None => {
                    return Poll::Ready(Ok(me.collected.take().expect("polled after complete")));
                }
            }
        }
    }
}
