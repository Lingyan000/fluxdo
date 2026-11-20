use std::pin::Pin;
use std::task::{Context, Poll};

use futures_core::ready;
use pin_project_lite::pin_project;
use rama_core::error::BoxError;

use crate::HeaderMap;
use crate::body::http_body::{Body, Frame, SizeHint};

pin_project! {
    /// A [`Body`] that yields every frame of `first`, then every frame of `second`.
    ///
    /// Trailers of `first` are held back and merged into those of `second` (whose
    /// values win on conflicts), as trailers must end the stream. An error of either
    /// body ends the chain, so `second` is never polled after `first` failed.
    ///
    /// This is also what makes a bounded collect reversible: the bytes already read
    /// can be re-prepended in front of the unread remainder so the original
    /// body can be forwarded untouched (see [`CollectError::into_full_body`]).
    ///
    /// See [`BodyExt::chain`] for more information.
    ///
    /// [`CollectError::into_full_body`]: crate::body::util::CollectError::into_full_body
    /// [`BodyExt::chain`]: crate::body::util::BodyExt::chain
    pub struct Chain<A, B> {
        #[pin]
        inner: Inner<A, B>,
    }
}

pin_project! {
    #[project = InnerProj]
    enum Inner<A, B> {
        First {
            #[pin]
            first: A,
            second: Option<B>,
        },
        Second {
            #[pin]
            second: B,
            trailers: Option<HeaderMap>,
        },
        Finished,
    }
}

impl<A, B> Chain<A, B> {
    /// Create a new [`Chain`] yielding all of `first` before all of `second`.
    pub fn new(first: A, second: B) -> Self {
        Self {
            inner: Inner::First {
                first,
                second: Some(second),
            },
        }
    }
}

impl<A, B> Body for Chain<A, B>
where
    A: Body,
    B: Body<Data = A::Data>,
    A::Error: Into<BoxError>,
    B::Error: Into<BoxError>,
{
    type Data = A::Data;
    type Error = BoxError;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        let mut inner = self.project().inner;
        loop {
            match inner.as_mut().project() {
                InnerProj::First { first, second } => {
                    let trailers = match ready!(first.poll_frame(cx)) {
                        Some(Ok(frame)) => match frame.into_trailers() {
                            Ok(trailers) => Some(trailers),
                            Err(frame) => return Poll::Ready(Some(Ok(frame))),
                        },
                        Some(Err(err)) => {
                            inner.set(Inner::Finished);
                            return Poll::Ready(Some(Err(err.into())));
                        }
                        None => None,
                    };
                    // trailers end `first`, so it is dropped without being polled again
                    match second.take() {
                        Some(second) => inner.set(Inner::Second { second, trailers }),
                        None => inner.set(Inner::Finished),
                    }
                }
                InnerProj::Second { second, trailers } => {
                    let last = match ready!(second.poll_frame(cx)) {
                        Some(Ok(frame)) => match frame.into_trailers() {
                            Ok(second_trailers) => match trailers.take() {
                                Some(mut first_trailers) => {
                                    first_trailers.extend(second_trailers);
                                    Some(Ok(Frame::trailers(first_trailers)))
                                }
                                None => Some(Ok(Frame::trailers(second_trailers))),
                            },
                            Err(frame) => return Poll::Ready(Some(Ok(frame))),
                        },
                        Some(Err(err)) => Some(Err(err.into())),
                        None => trailers
                            .take()
                            .map(|trailers| Ok(Frame::trailers(trailers))),
                    };
                    inner.set(Inner::Finished);
                    return Poll::Ready(last);
                }
                InnerProj::Finished => return Poll::Ready(None),
            }
        }
    }

    fn is_end_stream(&self) -> bool {
        match &self.inner {
            Inner::First { first, second } => {
                first.is_end_stream() && second.as_ref().is_none_or(Body::is_end_stream)
            }
            Inner::Second { second, trailers } => trailers.is_none() && second.is_end_stream(),
            Inner::Finished => true,
        }
    }

    fn size_hint(&self) -> SizeHint {
        match &self.inner {
            Inner::First { first, second } => {
                first.size_hint() + second.as_ref().map(Body::size_hint).unwrap_or_default()
            }
            Inner::Second { second, .. } => second.size_hint(),
            Inner::Finished => SizeHint::with_exact(0),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::future::ready;
    use std::io;
    use std::task::Waker;

    use super::*;
    use crate::body::http_body_util::{BodyExt, Empty, ErrorBody, Full};
    use crate::{HeaderName, HeaderValue};
    use bytes::Bytes;

    type PolledFrame = Poll<Option<Result<Frame<Bytes>, BoxError>>>;

    fn poll<B>(body: &mut B) -> PolledFrame
    where
        B: Body<Data = Bytes, Error = BoxError> + Unpin,
    {
        Pin::new(body).poll_frame(&mut Context::from_waker(Waker::noop()))
    }

    fn expect_data<B>(body: &mut B) -> Bytes
    where
        B: Body<Data = Bytes, Error = BoxError> + Unpin,
    {
        match poll(body) {
            Poll::Ready(Some(Ok(frame))) => frame.into_data().expect("data frame"),
            other => panic!("unexpected poll outcome: {other:?}"),
        }
    }

    fn expect_trailers<B>(body: &mut B) -> HeaderMap
    where
        B: Body<Data = Bytes, Error = BoxError> + Unpin,
    {
        match poll(body) {
            Poll::Ready(Some(Ok(frame))) => frame.into_trailers().expect("trailers frame"),
            other => panic!("unexpected poll outcome: {other:?}"),
        }
    }

    fn expect_error<B>(body: &mut B) -> BoxError
    where
        B: Body<Data = Bytes, Error = BoxError> + Unpin,
    {
        match poll(body) {
            Poll::Ready(Some(Err(err))) => err,
            other => panic!("unexpected poll outcome: {other:?}"),
        }
    }

    fn expect_end<B>(body: &mut B)
    where
        B: Body<Data = Bytes, Error = BoxError> + Unpin,
    {
        match poll(body) {
            Poll::Ready(None) => {}
            other => panic!("unexpected poll outcome: {other:?}"),
        }
    }

    fn full(data: &'static str) -> Full<Bytes> {
        Full::new(Bytes::from_static(data.as_bytes()))
    }

    fn failing(msg: &'static str) -> ErrorBody<Bytes, io::Error> {
        ErrorBody::new(io::Error::other(msg))
    }

    fn trailers(pairs: &[(&'static str, &'static str)]) -> HeaderMap {
        let mut map = HeaderMap::new();
        for &(name, value) in pairs {
            map.insert(
                HeaderName::from_static(name),
                HeaderValue::from_static(value),
            );
        }
        map
    }

    #[tokio::test]
    async fn chains_two_full_bodies() {
        let body = Chain::new(
            Full::new(Bytes::from("hello ")),
            Full::new(Bytes::from("world")),
        );
        let out = body.collect().await.unwrap().to_bytes();
        assert_eq!(&out[..], b"hello world");
    }

    #[tokio::test]
    async fn empty_first_yields_only_second() {
        let body = Chain::new(Empty::<Bytes>::new(), Full::new(Bytes::from("tail")));
        let out = body.collect().await.unwrap().to_bytes();
        assert_eq!(&out[..], b"tail");
    }

    #[tokio::test]
    async fn empty_second_yields_only_first() {
        let body = Chain::new(Full::new(Bytes::from("head")), Empty::<Bytes>::new());
        let out = body.collect().await.unwrap().to_bytes();
        assert_eq!(&out[..], b"head");
    }

    #[test]
    fn two_empty() {
        let mut body = Empty::<Bytes>::new().chain(Empty::<Bytes>::new());
        assert!(body.is_end_stream(), "both bodies report their end");
        assert_eq!(body.size_hint().exact(), Some(0));

        expect_end(&mut body);
        assert!(body.is_end_stream());
    }

    #[test]
    fn full_then_empty() {
        let mut body = full("hello ").chain(Empty::<Bytes>::new());
        assert!(!body.is_end_stream());
        assert_eq!(body.size_hint().exact(), Some(6));

        assert_eq!(expect_data(&mut body), "hello ");
        assert!(body.is_end_stream(), "both bodies report their end");

        expect_end(&mut body);
        assert!(body.is_end_stream());
    }

    #[test]
    fn empty_then_full() {
        let mut body = Empty::<Bytes>::new().chain(full("world!"));
        assert!(!body.is_end_stream());
        assert_eq!(body.size_hint().exact(), Some(6));

        assert_eq!(expect_data(&mut body), "world!");
        assert!(body.is_end_stream());

        expect_end(&mut body);
        assert!(body.is_end_stream());
    }

    #[test]
    fn two_bodies_chain() {
        let mut body = full("hello ").chain(full("world!"));
        assert!(!body.is_end_stream());
        assert_eq!(body.size_hint().exact(), Some(12));

        assert_eq!(expect_data(&mut body), "hello ");
        assert!(!body.is_end_stream(), "second body still has data");
        assert_eq!(body.size_hint().exact(), Some(6));

        assert_eq!(expect_data(&mut body), "world!");
        assert!(body.is_end_stream());

        expect_end(&mut body);
        assert_eq!(body.size_hint().exact(), Some(0));
    }

    #[test]
    fn second_body_error_ends_chain() {
        let mut body = full("hello ").chain(failing("failure"));

        assert_eq!(expect_data(&mut body), "hello ");
        assert_eq!(expect_error(&mut body).to_string(), "failure");
        assert!(body.is_end_stream(), "finished after returning an error");
        assert_eq!(body.size_hint().exact(), Some(0));

        expect_end(&mut body);
    }

    #[test]
    fn first_body_error_skips_second() {
        let mut body = failing("failure").chain(full("world!"));

        assert_eq!(expect_error(&mut body).to_string(), "failure");
        assert!(body.is_end_stream(), "finished after returning an error");

        expect_end(&mut body);
    }

    #[test]
    fn first_body_trailers_are_held_back() {
        let mut body = full("hello ")
            .with_trailers(ready(Some(Ok(trailers(&[("fourty-two", "42")])))))
            .chain(full("world!"));

        assert_eq!(expect_data(&mut body), "hello ");
        assert_eq!(expect_data(&mut body), "world!");
        assert!(!body.is_end_stream(), "held back trailers are still due");

        assert_eq!(expect_trailers(&mut body)["fourty-two"], "42");
        assert!(body.is_end_stream());

        expect_end(&mut body);
    }

    #[test]
    fn second_body_trailers_are_propagated() {
        let mut body = full("hello ").chain(
            full("world!").with_trailers(ready(Some(Ok(trailers(&[("fourty-two", "42")]))))),
        );

        assert_eq!(expect_data(&mut body), "hello ");
        assert_eq!(expect_data(&mut body), "world!");
        assert_eq!(expect_trailers(&mut body)["fourty-two"], "42");
        assert!(body.is_end_stream());

        expect_end(&mut body);
    }

    #[test]
    fn body_trailers_are_consolidated() {
        let first = full("hello ").with_trailers(ready(Some(Ok(trailers(&[
            ("fourty-two", "42"),
            ("both", "alpha"),
        ])))));
        let second = full("world!").with_trailers(ready(Some(Ok(trailers(&[
            ("ten", "10"),
            ("both", "beta"),
        ])))));
        let mut body = first.chain(second);

        assert_eq!(expect_data(&mut body), "hello ");
        assert_eq!(expect_data(&mut body), "world!");

        let merged = expect_trailers(&mut body);
        assert_eq!(merged.len(), 3);
        assert_eq!(merged["fourty-two"], "42");
        assert_eq!(merged["ten"], "10");
        // on conflicts the second body's trailers win
        let mut both = merged.get_all("both").iter();
        assert_eq!(both.next().unwrap(), "beta");
        assert!(both.next().is_none());

        expect_end(&mut body);
    }
}
