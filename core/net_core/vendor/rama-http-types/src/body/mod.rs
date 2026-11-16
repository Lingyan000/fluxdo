//! Asynchronous HTTP request or response body.
//!
//! See [`StreamingBody`] for more details.

use crate::body::util::BodyExt;
use pin_project_lite::pin_project;
use rama_core::bytes::Bytes;
use rama_core::error::BoxError;
use rama_core::futures::TryStream;
use rama_core::futures::stream::Stream;
use rama_core::stream::json;
use rama_utils::str::arcstr::ArcStr;
use serde::de::DeserializeOwned;
use sse::{EventDataRead, EventStream};
use std::pin::Pin;
use std::task::{Context, Poll};
use sync_wrapper::SyncWrapper;

#[cfg(test)]
use std::assert_matches;

// Forked `http-body` / `http-body-util` (see fork README), relocated under
// `body` so the module path matches the file layout.
pub mod http_body;
mod http_body_util;

pub use http_body::Body as StreamingBody;
pub use http_body::Frame;
pub use http_body::SizeHint;

// `http_body_util` is private; its API is surfaced through this curated alias.
pub mod util {
    pub use super::http_body_util::*;
}

mod limit;
pub use limit::BodyLimit;

mod ext;
pub use ext::BodyExtractExt;

#[doc(inline)]
pub use util::{CollectError, CollectErrorKind, CollectOptions};

pub mod sse;

mod infinite;
pub use infinite::InfiniteReader;

mod on_drop;
pub use on_drop::OnDropBody;

mod incomplete;
pub use incomplete::OnIncompleteBody;

mod guarded;
pub use guarded::GuardedBody;

mod optional;
pub use optional::OptionalBody;

mod capture;
pub use capture::{
    BodyCaptureEvent, BodyCaptureSink, BufferedBodyCapture, CaptureBody, CaptureCanceled,
    CaptureHandle, CaptureLimit, CaptureOutcome, CapturedBody,
};

// Implementations copied over from http-body but addapted to work with our Requests/Response types

impl<B: StreamingBody> StreamingBody for crate::Request<B> {
    type Data = B::Data;
    type Error = B::Error;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        // SAFETY: `Pin::map_unchecked_mut` requires that the returned
        // reference does not move while `self` stays pinned and that the
        // closure does not move out of its argument. `body_mut` returns the
        // `body` field and moves nothing (its safety-usable invariant), and
        // pinning is structural for that field (the `body` safety invariant of
        // `Request`), so the body stays pinned until it is dropped in place.
        unsafe { self.map_unchecked_mut(Self::body_mut).poll_frame(cx) }
    }

    fn is_end_stream(&self) -> bool {
        self.body().is_end_stream()
    }

    fn size_hint(&self) -> SizeHint {
        self.body().size_hint()
    }
}

impl<B: StreamingBody> StreamingBody for crate::Response<B> {
    type Data = B::Data;
    type Error = B::Error;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        // SAFETY: `Pin::map_unchecked_mut` requires that the returned
        // reference does not move while `self` stays pinned and that the
        // closure does not move out of its argument. `body_mut` returns the
        // `body` field and moves nothing (its safety-usable invariant), and
        // pinning is structural for that field (the `body` safety invariant of
        // `Response`), so the body stays pinned until it is dropped in place.
        unsafe { self.map_unchecked_mut(Self::body_mut).poll_frame(cx) }
    }

    fn is_end_stream(&self) -> bool {
        self.body().is_end_stream()
    }

    fn size_hint(&self) -> SizeHint {
        self.body().size_hint()
    }
}

// Rama specific stuff

type BoxBody = util::combinators::BoxBody<Bytes, BoxError>;

fn boxed<B>(body: B) -> BoxBody
where
    B: StreamingBody<Data = Bytes, Error: Into<BoxError>> + Send + Sync + 'static,
{
    try_downcast(body).unwrap_or_else(|body| body.map_err(Into::into).boxed())
}

#[expect(clippy::unwrap_used)]
pub(crate) fn try_downcast<T, K>(k: K) -> Result<T, K>
where
    T: 'static,
    K: Send + 'static,
{
    let mut k = Some(k);
    if let Some(k) = <dyn std::any::Any>::downcast_mut::<Option<T>>(&mut k) {
        Ok(k.take().unwrap())
    } else {
        Err(k.unwrap())
    }
}

/// The body type used in rama requests and responses.
#[must_use]
#[derive(Debug)]
pub struct Body(BoxBody);

impl Body {
    /// Create a new `Body` that wraps another [`Body`].
    pub fn new<B>(body: B) -> Self
    where
        B: StreamingBody<Data = Bytes, Error: Into<BoxError>> + Send + Sync + 'static,
    {
        try_downcast(body).unwrap_or_else(|body| Self(boxed(body)))
    }

    /// Create a new `Body` with a maximum size limit.
    pub fn with_limit<B>(body: B, limit: usize) -> Self
    where
        B: StreamingBody<Data = Bytes, Error: Into<BoxError>> + Send + Sync + 'static,
    {
        Self::new(util::Limited::new(body, limit))
    }

    /// Create an empty body.
    pub fn empty() -> Self {
        Self::new(util::Empty::new())
    }

    /// Create a new `Body` from a [`Stream`].
    ///
    /// [`Stream`]: https://docs.rs/futures/latest/futures/stream/trait.Stream.html
    pub fn from_stream<S>(stream: S) -> Self
    where
        S: TryStream<Ok: Into<Bytes>, Error: Into<BoxError>> + Send + 'static,
    {
        Self::new(StreamBody {
            stream: SyncWrapper::new(stream),
        })
    }

    /// Create a new `Body` from a stream of data and trailer frames.
    ///
    /// Unlike [`from_stream`](Self::from_stream), this preserves HTTP
    /// trailer frames produced by the stream.
    pub fn from_frame_stream<S, E>(stream: S) -> Self
    where
        S: TryStream<Ok = Frame<Bytes>, Error = E> + Send + 'static,
        E: Into<BoxError> + 'static,
    {
        Self::new(FrameStreamBody {
            stream: SyncWrapper::new(stream),
        })
    }

    /// Create a new [`Body`] from a [`Stream`] with a maximum size limit.
    pub fn limited(self, limit: usize) -> Self {
        Self::new(util::Limited::new(self.0, limit))
    }

    /// Wrap this body so that `on_drop` is called if the body is dropped before
    /// being fully consumed (e.g. because the client disconnected mid-response).
    ///
    /// The closure fires exactly once and only on early drops — it is disarmed
    /// when [`StreamingBody::poll_frame`] returns `Poll::Ready(None)`.
    pub fn on_drop<F>(self, on_drop: F) -> Self
    where
        F: FnOnce() + Send + Sync + 'static,
    {
        Self::new(OnDropBody::new(self.0, on_drop))
    }

    /// Wrap this body so that `on_incomplete` is called as soon as it is known
    /// the body will not complete: an error frame is observed, or the body is
    /// dropped before end-of-stream.
    ///
    /// The closure fires at most once. See [`OnIncompleteBody`] for how this
    /// differs from [`Self::on_drop`].
    pub fn on_incomplete<F>(self, on_incomplete: F) -> Self
    where
        F: FnOnce() + Send + Sync + 'static,
    {
        Self::new(OnIncompleteBody::new(self.0, on_incomplete))
    }

    /// Forward this body while asynchronously sending owned frame copies to a sink.
    pub fn capture<S>(self, sink: S) -> Self
    where
        S: BodyCaptureSink,
    {
        Self::new(CaptureBody::new(self.0, sink))
    }

    /// Forward this body while retaining a bounded or unlimited copy in memory.
    ///
    /// The returned handle resolves exactly once after the forwarding body
    /// completes, errors, or is dropped:
    ///
    /// ```
    /// use rama_http_types::{Body, CaptureLimit, CaptureOutcome, body::util::BodyExt as _};
    ///
    /// # #[tokio::main]
    /// # async fn main() {
    /// let (body, capture) = Body::from("hello").capture_buffered(CaptureLimit::max_bytes(1024));
    /// body.collect().await.unwrap();
    ///
    /// let captured = capture.wait().await.unwrap();
    /// assert_eq!(captured.bytes(), "hello");
    /// assert_eq!(captured.outcome(), CaptureOutcome::Complete);
    /// assert!(!captured.is_truncated());
    /// # }
    /// ```
    pub fn capture_buffered(self, limit: CaptureLimit) -> (Self, CaptureHandle) {
        let (body, handle) = CaptureBody::buffered(self.0, limit);
        (Self::new(body), handle)
    }

    /// Attach a headermap as trailer headers to this body.
    ///
    /// In case you want this is also available as `with_trailer`,
    /// provided by a body extension which allows you to use
    /// a [`Future`] with as output an option of a result of a headermap.
    /// This method is a shortcut of that function.
    pub fn with_trailer_headers(self, headers: crate::HeaderMap) -> Self {
        Self::new(self.0.with_trailers(std::future::ready(Some(Ok(headers)))))
    }

    /// Convert the body into a [`Stream`] of data frames.
    ///
    /// Non-data frames (such as trailers) will be discarded. Use [`http_body_util::BodyStream`] if
    /// you need a [`Stream`] of all frame types.
    ///
    /// [`http_body_util::BodyStream`]: https://docs.rs/http-body-util/latest/http_body_util/struct.BodyStream.html
    pub fn into_data_stream(self) -> BodyDataStream {
        BodyDataStream { inner: self }
    }

    /// Convert the body into a [`Stream`] of [`sse::Event`]s.
    ///
    /// <https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events>.
    #[must_use]
    pub fn into_event_stream<T: EventDataRead>(self) -> EventStream<BodyDataStream, T> {
        EventStream::new(self.into_data_stream())
    }

    /// Convert the body into a [`JsonReadStream`][json::JsonReadStream].
    ///
    /// Stream of json objects, each object separated by a newline (`\n`).
    #[must_use]
    pub fn into_json_stream<T: DeserializeOwned>(self) -> json::JsonReadStream<T, BodyDataStream> {
        let stream = self.into_data_stream();
        json::JsonReadStream::new(stream)
    }

    /// Convert the body into a [`JsonReadStream`][json::JsonReadStream].
    ///
    /// Stream of json objects, each object separated by a newline (`\n`).
    #[must_use]
    pub fn into_json_stream_with_config<T: DeserializeOwned>(
        self,
        cfg: json::ParseConfig,
    ) -> json::JsonReadStream<T, BodyDataStream> {
        let stream = self.into_data_stream();
        json::JsonReadStream::new_with_config(stream, cfg)
    }

    /// Convert the body into a [`Stream`] of [`sse::Event`]s with optional string data.
    ///
    /// <https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events>.
    #[must_use]
    pub fn into_string_data_event_stream(self) -> EventStream<BodyDataStream> {
        EventStream::new(self.into_data_stream())
    }

    /// Stream a chunk of the response body.
    ///
    /// When the response body has been exhausted, this will return `None`.
    pub async fn chunk(&mut self) -> Result<Option<Bytes>, BoxError> {
        // loop to ignore unrecognized frames
        loop {
            if let Some(res) = self.frame().await {
                let frame = res?;
                if let Ok(buf) = frame.into_data() {
                    return Ok(Some(buf));
                }
                // else continue
            } else {
                return Ok(None);
            }
        }
    }
}

impl Default for Body {
    fn default() -> Self {
        Self::empty()
    }
}

impl From<()> for Body {
    fn from(_: ()) -> Self {
        Self::empty()
    }
}

macro_rules! body_from_impl {
    ($ty:ty) => {
        impl From<$ty> for Body {
            fn from(buf: $ty) -> Self {
                Self::new(crate::body::util::Full::from(buf))
            }
        }
    };
}

body_from_impl!(&'static [u8]);
body_from_impl!(std::borrow::Cow<'static, [u8]>);
body_from_impl!(Vec<u8>);

body_from_impl!(&'static str);
body_from_impl!(std::borrow::Cow<'static, str>);
body_from_impl!(String);

impl From<&ArcStr> for Body {
    fn from(buf: &ArcStr) -> Self {
        Self::new(if let Some(s) = ArcStr::as_static(buf) {
            crate::body::util::Full::from(s)
        } else {
            crate::body::util::Full::from(buf.to_string())
        })
    }
}

impl From<ArcStr> for Body {
    #[inline(always)]
    fn from(buf: ArcStr) -> Self {
        Self::from(&buf)
    }
}

body_from_impl!(Bytes);

impl StreamingBody for Body {
    type Data = Bytes;
    type Error = BoxError;

    #[inline]
    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        Pin::new(&mut self.0).poll_frame(cx)
    }

    #[inline]
    fn size_hint(&self) -> SizeHint {
        self.0.size_hint()
    }

    #[inline]
    fn is_end_stream(&self) -> bool {
        self.0.is_end_stream()
    }
}

/// A stream of data frames.
///
/// Created with [`Body::into_data_stream`].
#[derive(Debug)]
#[must_use]
pub struct BodyDataStream {
    inner: Body,
}

impl Stream for BodyDataStream {
    type Item = Result<Bytes, BoxError>;

    #[inline]
    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        loop {
            match rama_core::futures::ready!(Pin::new(&mut self.inner).poll_frame(cx)?) {
                Some(frame) => match frame.into_data() {
                    Ok(data) => return Poll::Ready(Some(Ok(data))),
                    Err(_frame) => {}
                },
                None => return Poll::Ready(None),
            }
        }
    }
}

impl StreamingBody for BodyDataStream {
    type Data = Bytes;
    type Error = BoxError;

    #[inline]
    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        Pin::new(&mut self.inner).poll_frame(cx)
    }

    #[inline]
    fn is_end_stream(&self) -> bool {
        self.inner.is_end_stream()
    }

    #[inline]
    fn size_hint(&self) -> SizeHint {
        self.inner.size_hint()
    }
}

pin_project! {
    struct StreamBody<S> {
        #[pin]
        stream: SyncWrapper<S>,
    }
}

pin_project! {
    struct FrameStreamBody<S> {
        #[pin]
        stream: SyncWrapper<S>,
    }
}

impl<S, E> StreamingBody for FrameStreamBody<S>
where
    S: TryStream<Ok = Frame<Bytes>, Error = E>,
    E: Into<BoxError>,
{
    type Data = Bytes;
    type Error = BoxError;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        let stream = self.project().stream.get_pin_mut();
        match rama_core::futures::ready!(stream.try_poll_next(cx)) {
            Some(Ok(frame)) => Poll::Ready(Some(Ok(frame))),
            Some(Err(error)) => Poll::Ready(Some(Err(error.into()))),
            None => Poll::Ready(None),
        }
    }
}

impl<S> StreamingBody for StreamBody<S>
where
    S: TryStream<Ok: Into<Bytes>, Error: Into<BoxError>>,
{
    type Data = Bytes;
    type Error = BoxError;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        let stream = self.project().stream.get_pin_mut();
        match rama_core::futures::ready!(stream.try_poll_next(cx)) {
            Some(Ok(chunk)) => Poll::Ready(Some(Ok(Frame::data(chunk.into())))),
            Some(Err(err)) => Poll::Ready(Some(Err(err.into()))),
            None => Poll::Ready(None),
        }
    }
}

#[test]
fn test_try_downcast() {
    assert_eq!(try_downcast::<i32, _>(5_u32), Err(5_u32));
    assert_eq!(try_downcast::<i32, _>(5_i32), Ok(5_i32));
}

#[tokio::test]
async fn capture_convenience_forwards_and_observes_body() {
    let (sink, mut events) = tokio::sync::mpsc::unbounded_channel();
    let forwarded = Body::from("captured").capture(sink);

    assert_eq!(
        forwarded.collect().await.unwrap().to_bytes(),
        Bytes::from_static(b"captured")
    );
    let BodyCaptureEvent::Frame(frame) = events.recv().await.unwrap() else {
        panic!("the first capture event must contain the data frame");
    };
    assert_eq!(frame.into_data().unwrap(), Bytes::from_static(b"captured"));
    assert_matches!(
        events.recv().await,
        Some(BodyCaptureEvent::End(CaptureOutcome::Complete)),
    );
}

#[tokio::test]
async fn frame_stream_constructor_preserves_trailers() {
    let mut trailers = crate::HeaderMap::new();
    trailers.insert("x-end", "yes".parse().unwrap());
    let stream = rama_core::futures::stream::iter([
        Ok::<_, std::convert::Infallible>(Frame::data(Bytes::from_static(b"data"))),
        Ok(Frame::trailers(trailers.clone())),
    ]);
    let mut body = Body::from_frame_stream(stream);

    assert_eq!(
        body.frame().await.unwrap().unwrap().into_data().unwrap(),
        "data"
    );
    assert_eq!(
        body.frame()
            .await
            .unwrap()
            .unwrap()
            .into_trailers()
            .unwrap(),
        trailers,
    );
    assert!(body.frame().await.is_none());
}
