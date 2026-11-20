use std::{
    future::Future,
    pin::Pin,
    task::{Context, Poll},
};

use crate::HeaderMap;
use crate::body::http_body::{Body, Frame};
use futures_core::ready;
use pin_project_lite::pin_project;

pin_project! {
    /// Adds trailers to a body.
    ///
    /// See [`BodyExt::with_trailers`] for more details.
    pub struct WithTrailers<T, F> {
        #[pin]
        state: State<T, F>,
    }
}

impl<T, F> WithTrailers<T, F> {
    pub(crate) fn new(body: T, trailers: F) -> Self {
        Self {
            state: State::PollBody {
                body,
                trailers: Some(trailers),
            },
        }
    }
}

pin_project! {
    #[project = StateProj]
    enum State<T, F> {
        PollBody {
            #[pin]
            body: T,
            trailers: Option<F>,
        },
        PollTrailers {
            #[pin]
            trailers: F,
            prev_trailers: Option<HeaderMap>,
        },
        Done,
    }
}

impl<T, F> Body for WithTrailers<T, F>
where
    T: Body,
    F: Future<Output = Option<Result<HeaderMap, T::Error>>>,
{
    type Data = T::Data;
    type Error = T::Error;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        loop {
            let mut this = self.as_mut().project();

            match this.state.as_mut().project() {
                StateProj::PollBody { body, trailers } => match ready!(body.poll_frame(cx)?) {
                    Some(frame) => match frame.into_trailers() {
                        Ok(prev_trailers) => {
                            let trailers = trailers.take().unwrap();
                            this.state.set(State::PollTrailers {
                                trailers,
                                prev_trailers: Some(prev_trailers),
                            });
                        }
                        Err(frame) => {
                            return Poll::Ready(Some(Ok(frame)));
                        }
                    },
                    None => {
                        let trailers = trailers.take().unwrap();
                        this.state.set(State::PollTrailers {
                            trailers,
                            prev_trailers: None,
                        });
                    }
                },
                StateProj::PollTrailers {
                    trailers,
                    prev_trailers,
                } => {
                    let trailers = ready!(trailers.poll(cx));
                    let prev_trailers = prev_trailers.take();
                    // done on every outcome, a resolved future must not be polled again
                    this.state.set(State::Done);
                    let trailers = match (trailers, prev_trailers) {
                        (Some(Err(err)), _) => return Poll::Ready(Some(Err(err))),
                        (None, None) => return Poll::Ready(None),
                        (None, Some(trailers)) | (Some(Ok(trailers)), None) => trailers,
                        (Some(Ok(new_trailers)), Some(mut prev_trailers)) => {
                            prev_trailers.extend(new_trailers);
                            prev_trailers
                        }
                    };
                    return Poll::Ready(Some(Ok(Frame::trailers(trailers))));
                }
                StateProj::Done => {
                    return Poll::Ready(None);
                }
            }
        }
    }

    #[inline]
    fn size_hint(&self) -> crate::body::http_body::SizeHint {
        match &self.state {
            State::PollBody { body, .. } => body.size_hint(),
            State::PollTrailers { .. } | State::Done => Default::default(),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::convert::Infallible;
    use std::io;
    use std::task::Waker;

    use crate::{HeaderName, HeaderValue};
    use bytes::Bytes;

    use crate::body::http_body_util::{BodyExt, Empty, Full};

    #[allow(unused_imports)]
    use super::*;

    #[tokio::test]
    async fn works() {
        let mut trailers = HeaderMap::new();
        trailers.insert(
            HeaderName::from_static("foo"),
            HeaderValue::from_static("bar"),
        );

        let body =
            Full::<Bytes>::from("hello").with_trailers(std::future::ready(Some(
                Ok::<_, Infallible>(trailers.clone()),
            )));

        rama_core::futures::pin_mut!(body);
        let waker = rama_core::futures::task::noop_waker();
        let mut cx = Context::from_waker(&waker);

        let data = unwrap_ready(body.as_mut().poll_frame(&mut cx))
            .unwrap()
            .unwrap()
            .into_data()
            .unwrap();
        assert_eq!(data, "hello");

        let body_trailers = unwrap_ready(body.as_mut().poll_frame(&mut cx))
            .unwrap()
            .unwrap()
            .into_trailers()
            .unwrap();
        assert_eq!(body_trailers, trailers);

        assert!(unwrap_ready(body.as_mut().poll_frame(&mut cx)).is_none());
    }

    #[tokio::test]
    async fn merges_trailers() {
        let mut trailers_1 = HeaderMap::new();
        trailers_1.insert(
            HeaderName::from_static("foo"),
            HeaderValue::from_static("bar"),
        );

        let mut trailers_2 = HeaderMap::new();
        trailers_2.insert(
            HeaderName::from_static("baz"),
            HeaderValue::from_static("qux"),
        );

        let body = Empty::<Bytes>::new()
            .with_trailers(std::future::ready(Some(Ok::<_, Infallible>(
                trailers_1.clone(),
            ))))
            .with_trailers(std::future::ready(Some(Ok::<_, Infallible>(
                trailers_2.clone(),
            ))));

        rama_core::futures::pin_mut!(body);
        let waker = rama_core::futures::task::noop_waker();
        let mut cx = Context::from_waker(&waker);

        let body_trailers = unwrap_ready(body.as_mut().poll_frame(&mut cx))
            .unwrap()
            .unwrap()
            .into_trailers()
            .unwrap();

        let mut all_trailers = HeaderMap::new();
        all_trailers.extend(trailers_1);
        all_trailers.extend(trailers_2);
        assert_eq!(body_trailers, all_trailers);

        assert!(unwrap_ready(body.as_mut().poll_frame(&mut cx)).is_none());
    }

    #[test]
    fn repoll_after_end_does_not_poll_trailers_again() {
        let body = Empty::<Bytes>::new().with_trailers(std::future::ready(None));

        rama_core::futures::pin_mut!(body);
        let mut cx = Context::from_waker(Waker::noop());

        assert!(unwrap_ready(body.as_mut().poll_frame(&mut cx)).is_none());
        // `Ready` panics when polled after completion
        assert!(unwrap_ready(body.as_mut().poll_frame(&mut cx)).is_none());
    }

    #[test]
    fn repoll_after_trailers_error_does_not_poll_trailers_again() {
        let body = Empty::<Bytes>::new()
            .map_err(|never| -> io::Error { match never {} })
            .with_trailers(std::future::ready(Some(Err(io::Error::other(
                "no trailers",
            )))));

        rama_core::futures::pin_mut!(body);
        let mut cx = Context::from_waker(Waker::noop());

        let err = unwrap_ready(body.as_mut().poll_frame(&mut cx))
            .unwrap()
            .unwrap_err();
        assert_eq!(err.to_string(), "no trailers");
        assert!(unwrap_ready(body.as_mut().poll_frame(&mut cx)).is_none());
    }

    fn unwrap_ready<T>(poll: Poll<T>) -> T {
        match poll {
            Poll::Ready(t) => t,
            Poll::Pending => panic!("pending"),
        }
    }
}
