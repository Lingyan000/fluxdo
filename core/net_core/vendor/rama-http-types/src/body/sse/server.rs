//! SSE types for servers.

use crate::body::{Frame, StreamingBody};
use pin_project_lite::pin_project;
use rama_core::bytes::Bytes;
use rama_core::error::{BoxError, ErrorContext};
use rama_core::futures::Stream;
use rama_utils::macros::generate_set_and_with;
use rama_utils::str::smol_str::SmolStr;
use std::{
    pin::Pin,
    task::{Context, Poll, ready},
    time::Duration,
};
use sync_wrapper::SyncWrapper;

use super::{Event, EventDataWrite};

pin_project! {
    /// An SSE body stream that can be used for SSE events by the server.
    pub struct SseResponseBody<S> {
        #[pin]
        event_stream: SyncWrapper<S>,
    }
}

impl<S> SseResponseBody<S> {
    /// Create a new `SseBody` from a [`Stream`].
    ///
    /// [`Stream`]: https://docs.rs/futures/latest/futures/stream/trait.Stream.html
    pub fn new<T, E>(stream: S) -> Self
    where
        S: Stream<Item = Result<Event<T>, E>>,
        T: EventDataWrite,
        E: Into<BoxError>,
    {
        Self {
            event_stream: SyncWrapper::new(stream),
        }
    }
}

impl<S, E, T> StreamingBody for SseResponseBody<S>
where
    S: Stream<Item = Result<Event<T>, E>>,
    E: Into<BoxError>,
    T: EventDataWrite,
{
    type Data = Bytes;
    type Error = BoxError;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        let this = self.project();

        match ready!(this.event_stream.get_pin_mut().poll_next(cx)) {
            Some(Ok(event)) => Poll::Ready(Some(Ok(Frame::data(event.serialize()?)))),
            Some(Err(error)) => Poll::Ready(Some(Err(error.into()))),
            None => Poll::Ready(None),
        }
    }
}

/// Configure the interval between keep-alive messages, the content
/// of each message, and the associated stream.
#[derive(Debug, Clone)]
#[must_use]
pub struct KeepAlive<T = String> {
    event: Event<T>,
    max_interval: Duration,
}

impl<T> KeepAlive<T> {
    /// Create a new `KeepAlive`.
    ///
    /// The default frame is a single empty comment, which serializes to
    /// `:\n\n` on the wire — the canonical SSE keep-alive payload. A fully
    /// empty `Event` would serialize to zero bytes and convey nothing to
    /// the client (some HTTP/2 stacks also reject empty data frames).
    pub fn new() -> Self {
        Self {
            event: Event {
                comments: Some(vec![SmolStr::default()]),
                ..Event::default()
            },
            max_interval: Duration::from_secs(15),
        }
    }
}

impl<T: EventDataWrite> KeepAlive<T> {
    generate_set_and_with! {
        /// Customize the interval between keep-alive messages.
        ///
        /// Default is 15 seconds.
        pub fn interval(mut self, time: Duration) -> Self {
            self.max_interval = time;
            self
        }
    }

    generate_set_and_with! {
        /// Customize the text of the keep-alive message.
        ///
        /// Default is an empty comment.
        pub fn text(mut self, text: impl Into<SmolStr>) -> Result<Self, BoxError>
        {
            self.event = Event::default().try_with_comment(text).context("build default event with comment")?;
            Ok(self)
        }
    }

    generate_set_and_with! {
        /// Customize the event of the keep-alive message.
        ///
        /// Default is an empty event.
        pub fn event(mut self, event: Event<T>) -> Self {
            self.event = event;
            self
        }
    }
}

impl<T> Default for KeepAlive<T> {
    fn default() -> Self {
        Self::new()
    }
}

pin_project! {
    /// A wrapper around a stream that produces keep-alive events
    #[derive(Debug)]
    pub struct KeepAliveStream<S, T = String> {
        #[pin]
        alive_timer: tokio::time::Sleep,
        #[pin]
        inner: S,
        keep_alive: KeepAlive<T>,
    }
}

impl<S, T, E> KeepAliveStream<S, T>
where
    S: Stream<Item = Result<Event<T>, E>>,
    E: Into<BoxError>,
    T: EventDataWrite,
{
    pub fn new(keep_alive: KeepAlive<T>, inner: S) -> Self {
        Self {
            alive_timer: tokio::time::sleep(keep_alive.max_interval),
            inner,
            keep_alive,
        }
    }

    fn reset(self: Pin<&mut Self>) {
        let this = self.project();
        this.alive_timer
            .reset(tokio::time::Instant::now() + this.keep_alive.max_interval);
    }
}

impl<S, E, T> Stream for KeepAliveStream<S, T>
where
    S: Stream<Item = Result<Event<T>, E>>,
    E: Into<BoxError>,
    T: EventDataWrite + Clone,
{
    type Item = Result<Event<T>, E>;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let mut this = self.as_mut().project();
        match this.inner.as_mut().poll_next(cx) {
            Poll::Ready(Some(Ok(event))) => {
                self.reset();
                Poll::Ready(Some(Ok(event)))
            }
            Poll::Ready(Some(Err(error))) => Poll::Ready(Some(Err(error))),
            Poll::Ready(None) => Poll::Ready(None),
            Poll::Pending => {
                ready!(this.alive_timer.poll(cx));
                let event = this.keep_alive.event.clone();
                self.reset();
                Poll::Ready(Some(Ok(event)))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rama_core::error::BoxErrorExt as _;
    use rama_core::futures::{StreamExt as _, stream};
    use std::convert::Infallible;

    #[test]
    fn keep_alive_default_frame_is_canonical_comment() {
        // `:\n\n` is the canonical SSE keep-alive payload (a single empty
        // comment line, terminated by the blank line that dispatches the
        // event). Earlier versions emitted zero bytes here.
        let keep_alive = KeepAlive::<String>::default();
        let bytes = keep_alive.event.serialize().unwrap();
        assert_eq!(&bytes[..], b": \n\n");
    }

    #[tokio::test]
    async fn response_body_serializes_events_and_errors() {
        let event = Event::new()
            .try_with_event("message")
            .unwrap()
            .with_data("hello".to_owned());
        let mut body = SseResponseBody::new(stream::iter([Ok::<_, Infallible>(event)]));

        let frame = std::future::poll_fn(|cx| Pin::new(&mut body).poll_frame(cx))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            frame.into_data().unwrap(),
            Bytes::from_static(b"event: message\ndata: hello\n\n")
        );
        assert!(
            std::future::poll_fn(|cx| Pin::new(&mut body).poll_frame(cx))
                .await
                .is_none()
        );

        let error = BoxError::from_static_str("stream failed");
        let mut body = SseResponseBody::<_>::new(stream::iter([Err::<Event, _>(error)]));
        let error = std::future::poll_fn(|cx| Pin::new(&mut body).poll_frame(cx))
            .await
            .unwrap()
            .unwrap_err();
        assert_eq!(error.to_string(), "stream failed");
    }

    #[tokio::test]
    async fn keep_alive_stream_emits_custom_event_after_interval() {
        let keep_alive = KeepAlive::new()
            .with_interval(Duration::from_millis(1))
            .try_with_text("still here")
            .unwrap();
        let stream = KeepAliveStream::new(
            keep_alive,
            stream::pending::<Result<Event<String>, Infallible>>(),
        );
        let mut stream = std::pin::pin!(stream);

        let event = stream.as_mut().next().await.unwrap().unwrap();

        assert_eq!(event.comment().collect::<Vec<_>>(), ["still here"]);
    }

    #[tokio::test]
    async fn keep_alive_stream_forwards_inner_results() {
        let event = Event::new().with_data("hello".to_owned());
        let error = BoxError::from_static_str("stream failed");
        let inner = stream::iter([Ok(event.clone()), Err(error)]);
        let stream = KeepAliveStream::new(KeepAlive::new(), inner);
        let mut stream = std::pin::pin!(stream);

        assert_eq!(stream.as_mut().next().await.unwrap().unwrap(), event);
        assert_eq!(
            stream
                .as_mut()
                .next()
                .await
                .unwrap()
                .unwrap_err()
                .to_string(),
            "stream failed"
        );
        assert!(stream.as_mut().next().await.is_none());
    }
}
