use std::{
    fmt,
    future::ready,
    pin::Pin,
    task::{Context, Poll, ready},
};

use parking_lot::Mutex;
use pin_project_lite::pin_project;
use rama_core::bytes::{Bytes, BytesMut};
use sync_wrapper::SyncWrapper;
use tokio::sync::oneshot;

use super::{Body, Frame, SizeHint, StreamingBody};
use crate::HeaderMap;

/// How an observed body stream terminated.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CaptureOutcome {
    /// The body returned its normal end-of-stream marker.
    Complete,
    /// The body yielded an error.
    Error,
    /// The wrapper was dropped before observing a normal end or error.
    ///
    /// This does not necessarily imply missing bytes: a consumer can stop
    /// polling after receiving all expected data without polling the terminal
    /// `None`. A custom sink can also record a frame before its future finishes,
    /// even if cancellation prevents that frame from reaching the downstream
    /// consumer.
    Aborted,
}

impl CaptureOutcome {
    /// Stable label for the observed completion state.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Complete => "complete",
            Self::Error => "error",
            Self::Aborted => "aborted",
        }
    }
}

/// An owned event emitted while a body streams.
///
/// Data frames contain a reference-counted clone of the original [`Bytes`].
/// The original frame continues downstream unchanged after the capture sink's
/// future completes.
#[derive(Clone, Debug)]
pub enum BodyCaptureEvent {
    /// A data or trailers frame.
    Frame(Frame<Bytes>),
    /// The capture reached a normal end or observed an error.
    ///
    /// Error outcomes intentionally carry no error value so events remain
    /// cloneable without constraining the wrapped body's error type.
    End(CaptureOutcome),
}

/// Asynchronously observes owned body events.
///
/// The future returned by [`capture`](Self::capture) is polled before the
/// original frame or terminal state is forwarded. Implementations therefore
/// choose their own flow-control policy: they can perform work directly, await
/// a bounded queue, enqueue without waiting, or return immediately.
pub trait BodyCaptureSink: Send + Sync + 'static {
    /// Capture one body event.
    ///
    /// The returned future must own everything it needs because it can outlive
    /// the borrow of `self`.
    fn capture(&self, event: BodyCaptureEvent) -> impl Future<Output = ()> + Send + 'static;

    /// Notify the sink synchronously when the body is abandoned.
    ///
    /// Destructors cannot await. Implementations that need asynchronous work
    /// can perform a non-blocking send or arrange for their own guard to finish
    /// that work.
    fn aborted(&self) {}
}

impl<F, Fut> BodyCaptureSink for F
where
    F: Fn(BodyCaptureEvent) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = ()> + Send + 'static,
{
    fn capture(&self, event: BodyCaptureEvent) -> impl Future<Output = ()> + Send + 'static {
        self(event)
    }
}

impl BodyCaptureSink for tokio::sync::mpsc::Sender<BodyCaptureEvent> {
    fn capture(&self, event: BodyCaptureEvent) -> impl Future<Output = ()> + Send + 'static {
        let sender = self.clone();
        async move {
            drop(sender.send(event).await);
        }
    }

    fn aborted(&self) {
        // Drop cannot wait for bounded capacity. Consumers that require a
        // guaranteed abort outcome should provide a sink with its own guard.
        drop(self.try_send(BodyCaptureEvent::End(CaptureOutcome::Aborted)));
    }
}

impl BodyCaptureSink for tokio::sync::mpsc::UnboundedSender<BodyCaptureEvent> {
    fn capture(&self, event: BodyCaptureEvent) -> impl Future<Output = ()> + Send + 'static {
        let result = self.send(event);
        async move {
            drop(result);
        }
    }

    fn aborted(&self) {
        drop(self.send(BodyCaptureEvent::End(CaptureOutcome::Aborted)));
    }
}

type CaptureFuture = Pin<Box<dyn Future<Output = ()> + Send + 'static>>;

enum PendingOutput<E> {
    Frame(Frame<Bytes>),
    Error(E),
    End,
}

struct CaptureGuard<S: BodyCaptureSink> {
    sink: S,
    finished: bool,
}

impl<S: BodyCaptureSink> CaptureGuard<S> {
    fn finish(&mut self) {
        self.finished = true;
    }
}

impl<S: BodyCaptureSink> Drop for CaptureGuard<S> {
    fn drop(&mut self) {
        if !self.finished {
            self.sink.aborted();
        }
    }
}

pin_project! {
    /// A body that asynchronously sends an owned copy of each frame to a sink.
    ///
    /// At most one original frame and its reference-counted capture copy are
    /// retained while the sink future is pending. No whole-body buffering or
    /// internal channel is used.
    #[must_use = "a captured body does nothing unless polled"]
    pub struct CaptureBody<B, S>
    where
        B: StreamingBody<Data = Bytes>,
        S: BodyCaptureSink,
    {
        #[pin]
        inner: B,
        guard: CaptureGuard<S>,
        pending: SyncWrapper<Option<CaptureFuture>>,
        pending_output: Option<PendingOutput<B::Error>>,
    }
}

impl<B, S> CaptureBody<B, S>
where
    B: StreamingBody<Data = Bytes>,
    S: BodyCaptureSink,
{
    /// Wrap a body with an asynchronous capture sink.
    pub fn new(inner: B, sink: S) -> Self {
        Self {
            inner,
            guard: CaptureGuard {
                sink,
                finished: false,
            },
            pending: SyncWrapper::new(None),
            pending_output: None,
        }
    }

    /// Return a reference to the wrapped body.
    pub const fn get_ref(&self) -> &B {
        &self.inner
    }

    /// Return a mutable reference to the wrapped body.
    pub fn get_mut(&mut self) -> &mut B {
        &mut self.inner
    }

    /// Return a pinned mutable reference to the wrapped body.
    pub fn get_pin_mut(self: Pin<&mut Self>) -> Pin<&mut B> {
        self.project().inner
    }

    /// Consume the wrapper and return the inner body.
    ///
    /// The sink receives [`BodyCaptureSink::aborted`].
    pub fn into_inner(self) -> B {
        self.inner
    }
}

impl<B> CaptureBody<B, BufferedBodyCapture>
where
    B: StreamingBody<Data = Bytes>,
{
    /// Wrap a body and retain a bounded or unlimited copy in memory.
    pub fn buffered(inner: B, limit: CaptureLimit) -> (Self, CaptureHandle) {
        let (sink, handle) = BufferedBodyCapture::new(limit);
        (Self::new(inner, sink), handle)
    }
}

impl<B, S> StreamingBody for CaptureBody<B, S>
where
    B: StreamingBody<Data = Bytes>,
    S: BodyCaptureSink,
{
    type Data = Bytes;
    type Error = B::Error;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        let mut this = self.project();

        loop {
            if let Some(future) = this.pending.get_mut().as_mut() {
                ready!(future.as_mut().poll(cx));
                *this.pending.get_mut() = None;

                #[expect(
                    clippy::expect_used,
                    reason = "missing output means the CaptureBody state machine is invalid"
                )]
                let output = this
                    .pending_output
                    .take()
                    .expect("a capture future always has a pending output");
                match output {
                    PendingOutput::Frame(frame) => return Poll::Ready(Some(Ok(frame))),
                    PendingOutput::Error(error) => {
                        this.guard.finish();
                        return Poll::Ready(Some(Err(error)));
                    }
                    PendingOutput::End => {
                        this.guard.finish();
                        return Poll::Ready(None);
                    }
                }
            }

            if this.guard.finished {
                return this.inner.poll_frame(cx);
            }

            match this.inner.as_mut().poll_frame(cx) {
                Poll::Pending => return Poll::Pending,
                Poll::Ready(Some(Ok(frame))) => {
                    let future = this
                        .guard
                        .sink
                        .capture(BodyCaptureEvent::Frame(frame.clone()));
                    *this.pending.get_mut() = Some(Box::pin(future));
                    *this.pending_output = Some(PendingOutput::Frame(frame));
                }
                Poll::Ready(Some(Err(error))) => {
                    let future = this
                        .guard
                        .sink
                        .capture(BodyCaptureEvent::End(CaptureOutcome::Error));
                    *this.pending.get_mut() = Some(Box::pin(future));
                    *this.pending_output = Some(PendingOutput::Error(error));
                }
                Poll::Ready(None) => {
                    let future = this
                        .guard
                        .sink
                        .capture(BodyCaptureEvent::End(CaptureOutcome::Complete));
                    *this.pending.get_mut() = Some(Box::pin(future));
                    *this.pending_output = Some(PendingOutput::End);
                }
            }
        }
    }

    fn is_end_stream(&self) -> bool {
        self.guard.finished && self.inner.is_end_stream()
    }

    fn size_hint(&self) -> SizeHint {
        let pending = match &self.pending_output {
            Some(PendingOutput::Frame(frame)) => frame
                .data_ref()
                .map_or(0, |data| u64::try_from(data.len()).unwrap_or(u64::MAX)),
            _ => 0,
        };
        self.inner.size_hint() + SizeHint::with_exact(pending)
    }
}

impl<B, S> fmt::Debug for CaptureBody<B, S>
where
    B: StreamingBody<Data = Bytes> + fmt::Debug,
    S: BodyCaptureSink,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CaptureBody")
            .field("inner", &self.inner)
            .field("sink", &std::any::type_name::<S>())
            .field("capture_pending", &self.pending_output.is_some())
            .field("finished", &self.guard.finished)
            .finish()
    }
}

/// Maximum number of body bytes retained by a [`BufferedBodyCapture`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct CaptureLimit(Option<usize>);

impl CaptureLimit {
    /// Retain at most `max_bytes`.
    #[must_use]
    pub const fn max_bytes(max_bytes: usize) -> Self {
        Self(Some(max_bytes))
    }

    /// Retain the complete body without a size bound.
    #[must_use]
    pub const fn unlimited() -> Self {
        Self(None)
    }

    /// Return the configured byte limit, or `None` for an unlimited capture.
    #[must_use]
    pub const fn get(self) -> Option<usize> {
        self.0
    }
}

impl From<usize> for CaptureLimit {
    fn from(value: usize) -> Self {
        Self::max_bytes(value)
    }
}

/// The final output produced by [`BufferedBodyCapture`].
#[derive(Debug)]
pub struct CapturedBody {
    bytes: Bytes,
    trailers: Option<HeaderMap>,
    outcome: CaptureOutcome,
    total_bytes: u64,
    truncated: bool,
}

impl CapturedBody {
    /// Return the retained body bytes.
    #[must_use]
    pub const fn bytes(&self) -> &Bytes {
        &self.bytes
    }

    /// Return all observed trailer fields.
    ///
    /// The byte limit applies only to data frames; trailer storage is not
    /// bounded. Fields from multiple trailer frames are merged in observation
    /// order using [`HeaderMap::extend`].
    #[must_use]
    pub const fn trailers(&self) -> Option<&HeaderMap> {
        self.trailers.as_ref()
    }

    /// Return how the stream terminated.
    #[must_use]
    pub const fn outcome(&self) -> CaptureOutcome {
        self.outcome
    }

    /// Return the total number of data bytes observed.
    #[must_use]
    pub const fn total_bytes(&self) -> u64 {
        self.total_bytes
    }

    /// Return whether bytes were omitted because the capture limit was hit.
    #[must_use]
    pub const fn is_truncated(&self) -> bool {
        self.truncated
    }

    /// Consume the capture and return its retained bytes and trailers.
    #[must_use]
    pub fn into_parts(self) -> (Bytes, Option<HeaderMap>) {
        (self.bytes, self.trailers)
    }

    /// Rebuild a forwardable body from the retained bytes and trailers.
    pub fn into_body(self) -> Body {
        let (bytes, trailers) = self.into_parts();
        match trailers {
            Some(trailers) => Body::from(bytes).with_trailer_headers(trailers),
            None => Body::from(bytes),
        }
    }
}

/// Returned if a buffered capture producer disappears without finalizing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CaptureCanceled;

impl fmt::Display for CaptureCanceled {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("body capture producer was canceled")
    }
}

impl std::error::Error for CaptureCanceled {}

/// An exactly-once completion handle for a [`BufferedBodyCapture`].
#[derive(Debug)]
#[must_use = "drop the handle explicitly if the buffered body is not needed"]
pub struct CaptureHandle {
    receiver: oneshot::Receiver<CapturedBody>,
}

impl CaptureHandle {
    /// Wait until the body completes, errors, or is dropped early.
    pub async fn wait(self) -> Result<CapturedBody, CaptureCanceled> {
        self.receiver.await.map_err(|_error| CaptureCanceled)
    }
}

struct BufferState {
    bytes: BytesMut,
    trailers: Option<HeaderMap>,
    limit: CaptureLimit,
    total_bytes: u64,
    truncated: bool,
    sender: Option<oneshot::Sender<CapturedBody>>,
}

impl BufferState {
    fn is_observed(&mut self) -> bool {
        if self.sender.as_ref().is_some_and(oneshot::Sender::is_closed) {
            self.sender = None;
            self.bytes.clear();
            self.trailers = None;
        }
        self.sender.is_some()
    }

    fn observe_frame(&mut self, frame: Frame<Bytes>) {
        if !self.is_observed() {
            return;
        }

        match frame.into_data() {
            Ok(data) => {
                self.total_bytes = self
                    .total_bytes
                    .saturating_add(u64::try_from(data.len()).unwrap_or(u64::MAX));
                let remaining = self
                    .limit
                    .get()
                    .map_or(data.len(), |limit| limit.saturating_sub(self.bytes.len()));
                let take = remaining.min(data.len());
                self.bytes.extend_from_slice(&data[..take]);
                self.truncated |= take < data.len();
            }
            Err(frame) => {
                if let Ok(trailers) = frame.into_trailers() {
                    if let Some(current) = &mut self.trailers {
                        current.extend(trailers);
                    } else {
                        self.trailers = Some(trailers);
                    }
                }
            }
        }
    }

    fn finish(&mut self, outcome: CaptureOutcome) {
        let Some(sender) = self.sender.take() else {
            return;
        };
        let captured = CapturedBody {
            bytes: std::mem::take(&mut self.bytes).freeze(),
            trailers: self.trailers.take(),
            outcome,
            total_bytes: self.total_bytes,
            truncated: self.truncated,
        };
        drop(sender.send(captured));
    }
}

impl Drop for BufferState {
    fn drop(&mut self) {
        self.finish(CaptureOutcome::Aborted);
    }
}

/// A capture sink that retains body data and trailers in memory.
///
/// The associated [`CaptureHandle`] resolves exactly once with the buffered
/// body and its terminal outcome. This is an explicit collection utility on
/// top of streaming [`CaptureBody`], rather than part of the forwarding path.
pub struct BufferedBodyCapture {
    state: Mutex<BufferState>,
}

impl BufferedBodyCapture {
    /// Create a buffered sink and its exactly-once completion handle.
    pub fn new(limit: CaptureLimit) -> (Self, CaptureHandle) {
        let (sender, receiver) = oneshot::channel();
        (
            Self {
                state: Mutex::new(BufferState {
                    bytes: BytesMut::new(),
                    trailers: None,
                    limit,
                    total_bytes: 0,
                    truncated: false,
                    sender: Some(sender),
                }),
            },
            CaptureHandle { receiver },
        )
    }

    fn state(&self) -> parking_lot::MutexGuard<'_, BufferState> {
        self.state.lock()
    }
}

impl BodyCaptureSink for BufferedBodyCapture {
    fn capture(&self, event: BodyCaptureEvent) -> impl Future<Output = ()> + Send + 'static {
        let mut state = self.state();
        match event {
            BodyCaptureEvent::Frame(frame) => state.observe_frame(frame),
            BodyCaptureEvent::End(outcome) => state.finish(outcome),
        }
        ready(())
    }

    fn aborted(&self) {
        self.state().finish(CaptureOutcome::Aborted);
    }
}

impl fmt::Debug for BufferedBodyCapture {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let state = self.state();
        f.debug_struct("BufferedBodyCapture")
            .field("limit", &state.limit)
            .field("captured_bytes", &state.bytes.len())
            .field("total_bytes", &state.total_bytes)
            .field("truncated", &state.truncated)
            .finish_non_exhaustive()
    }
}

impl std::fmt::Display for CaptureOutcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

#[cfg(test)]
mod tests {
    use std::assert_matches;
    use std::{
        convert::Infallible,
        io,
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        },
    };

    use rama_core::bytes::Bytes;

    use super::*;
    use crate::body::util::{BodyExt as _, StreamBody};

    async fn wait_for_capture(handle: CaptureHandle) -> CapturedBody {
        tokio::time::timeout(std::time::Duration::from_secs(1), handle.wait())
            .await
            .expect("capture should finish promptly")
            .expect("capture producer should finalize")
    }

    #[tokio::test]
    async fn sink_future_applies_backpressure_before_forwarding() {
        let gate = Arc::new(tokio::sync::Notify::new());
        let sink_gate = Arc::clone(&gate);
        let sink = move |event: BodyCaptureEvent| {
            let gate = Arc::clone(&sink_gate);
            async move {
                if matches!(event, BodyCaptureEvent::Frame(_)) {
                    gate.notified().await;
                }
            }
        };
        let mut body = CaptureBody::new(Body::from("held"), sink);
        let mut frame = Box::pin(body.frame());

        tokio::time::timeout(std::time::Duration::ZERO, &mut frame)
            .await
            .expect_err("the frame must wait for its capture future");
        drop(frame);
        assert_eq!(body.size_hint().exact(), Some(4));
        assert!(!body.is_end_stream());
        gate.notify_one();
        assert_eq!(
            body.frame().await.unwrap().unwrap().into_data().unwrap(),
            Bytes::from_static(b"held")
        );
    }

    #[tokio::test]
    async fn channel_sinks_report_abort_when_capacity_is_available() {
        let (bounded, mut bounded_events) = tokio::sync::mpsc::channel(1);
        bounded.aborted();
        assert_matches!(
            tokio::time::timeout(std::time::Duration::from_secs(1), bounded_events.recv())
                .await
                .expect("bounded abort should arrive promptly"),
            Some(BodyCaptureEvent::End(CaptureOutcome::Aborted)),
        );

        let (unbounded, mut unbounded_events) = tokio::sync::mpsc::unbounded_channel();
        unbounded.aborted();
        assert_matches!(
            tokio::time::timeout(std::time::Duration::from_secs(1), unbounded_events.recv())
                .await
                .expect("unbounded abort should arrive promptly"),
            Some(BodyCaptureEvent::End(CaptureOutcome::Aborted)),
        );
    }

    #[tokio::test]
    async fn bounded_channel_drops_abort_notification_when_full() {
        let (bounded, mut events) = tokio::sync::mpsc::channel(1);
        bounded
            .send(BodyCaptureEvent::Frame(Frame::data(Bytes::from_static(
                b"queued",
            ))))
            .await
            .unwrap();

        bounded.aborted();
        drop(bounded);

        assert_matches!(events.recv().await, Some(BodyCaptureEvent::Frame(_)));
        assert!(events.recv().await.is_none());
    }

    #[tokio::test]
    async fn buffered_capture_forwards_frames_and_finishes_once() {
        let mut trailers = HeaderMap::new();
        trailers.insert("x-finished", "yes".parse().unwrap());
        let source = StreamBody::new(rama_core::futures::stream::iter([
            Ok::<_, Infallible>(Frame::data(Bytes::from_static(b"hello"))),
            Ok(Frame::data(Bytes::from_static(b" world"))),
            Ok(Frame::trailers(trailers.clone())),
        ]));
        let (mut body, handle) = CaptureBody::buffered(source, CaptureLimit::max_bytes(7));

        let mut forwarded = Vec::new();
        while let Some(frame) = body.frame().await {
            let frame = frame.unwrap();
            if let Some(data) = frame.data_ref() {
                forwarded.extend_from_slice(data);
            } else {
                assert_eq!(frame.trailers_ref().unwrap(), &trailers);
            }
        }

        let captured = wait_for_capture(handle).await;
        assert_eq!(forwarded, b"hello world");
        assert_eq!(captured.bytes(), &Bytes::from_static(b"hello w"));
        assert_eq!(captured.trailers(), Some(&trailers));
        assert_eq!(captured.outcome(), CaptureOutcome::Complete);
        assert_eq!(captured.total_bytes(), 11);
        assert!(captured.is_truncated());
    }

    #[tokio::test]
    async fn zero_byte_limit_records_length_without_retaining_data() {
        let (body, handle) =
            CaptureBody::buffered(Body::from("not retained"), CaptureLimit::max_bytes(0));
        body.collect().await.unwrap();

        let captured = wait_for_capture(handle).await;
        assert!(captured.bytes().is_empty());
        assert_eq!(captured.total_bytes(), 12);
        assert!(captured.is_truncated());
        assert_eq!(captured.outcome(), CaptureOutcome::Complete);
    }

    #[tokio::test]
    async fn buffered_capture_reports_error_and_partial_body() {
        let source = StreamBody::new(rama_core::futures::stream::iter([
            Ok(Frame::data(Bytes::from_static(b"before"))),
            Err(io::Error::other("broken body")),
        ]));
        let (mut body, handle) = CaptureBody::buffered(source, CaptureLimit::unlimited());

        assert_eq!(
            body.frame().await.unwrap().unwrap().into_data().unwrap(),
            Bytes::from_static(b"before")
        );
        assert_eq!(
            body.frame().await.unwrap().unwrap_err().to_string(),
            "broken body"
        );

        let captured = wait_for_capture(handle).await;
        assert_eq!(captured.bytes(), &Bytes::from_static(b"before"));
        assert_eq!(captured.outcome(), CaptureOutcome::Error);
    }

    #[tokio::test]
    async fn unlimited_buffer_can_rebuild_data_and_trailers() {
        let mut trailers = HeaderMap::new();
        trailers.insert("x-finished", "yes".parse().unwrap());
        let source = StreamBody::new(rama_core::futures::stream::iter([
            Ok::<_, Infallible>(Frame::data(Bytes::from_static(b"complete"))),
            Ok(Frame::trailers(trailers.clone())),
        ]));
        let (body, handle) = CaptureBody::buffered(source, CaptureLimit::unlimited());
        body.collect().await.unwrap();

        let captured = wait_for_capture(handle).await;
        assert_eq!(captured.outcome(), CaptureOutcome::Complete);
        assert!(!captured.is_truncated());
        let rebuilt = captured.into_body().collect().await.unwrap();
        assert_eq!(rebuilt.trailers(), Some(&trailers));
        assert_eq!(rebuilt.to_bytes(), Bytes::from_static(b"complete"));
    }

    #[tokio::test]
    async fn dropping_buffer_handle_stops_retaining_frames() {
        let (sink, handle) = BufferedBodyCapture::new(CaptureLimit::unlimited());
        drop(handle);
        sink.capture(BodyCaptureEvent::Frame(Frame::data(Bytes::from_static(
            b"ignored",
        ))))
        .await;

        let state = sink.state();
        assert!(state.sender.is_none());
        assert!(state.bytes.is_empty());
        assert_eq!(state.total_bytes, 0);
    }

    #[tokio::test]
    async fn dropping_buffer_sink_reports_abort() {
        let (sink, handle) = BufferedBodyCapture::new(CaptureLimit::unlimited());
        drop(sink);

        let captured = wait_for_capture(handle).await;
        assert_eq!(captured.outcome(), CaptureOutcome::Aborted);
    }

    #[tokio::test]
    async fn explicit_buffer_abort_finishes_before_the_sink_is_dropped() {
        let (sink, handle) = BufferedBodyCapture::new(CaptureLimit::unlimited());
        sink.aborted();

        let captured = wait_for_capture(handle).await;
        assert_eq!(captured.outcome(), CaptureOutcome::Aborted);
        drop(sink);
    }

    #[tokio::test]
    async fn buffered_capture_reports_abort_once() {
        let source = StreamBody::new(rama_core::futures::stream::iter([
            Ok::<_, Infallible>(Frame::data(Bytes::from_static(b"first"))),
            Ok(Frame::data(Bytes::from_static(b"second"))),
        ]));
        let (mut body, handle) = CaptureBody::buffered(source, CaptureLimit::unlimited());
        assert_eq!(
            body.frame().await.unwrap().unwrap().into_data().unwrap(),
            Bytes::from_static(b"first")
        );
        drop(body);

        let captured = wait_for_capture(handle).await;
        assert_eq!(captured.bytes(), &Bytes::from_static(b"first"));
        assert_eq!(captured.outcome(), CaptureOutcome::Aborted);
    }

    struct PendingSink {
        events: tokio::sync::mpsc::UnboundedSender<BodyCaptureEvent>,
        aborts: Arc<AtomicUsize>,
    }

    impl BodyCaptureSink for PendingSink {
        fn capture(&self, event: BodyCaptureEvent) -> impl Future<Output = ()> + Send + 'static {
            self.events.send(event).unwrap();
            std::future::pending()
        }

        fn aborted(&self) {
            self.aborts.fetch_add(1, Ordering::Relaxed);
        }
    }

    #[tokio::test]
    async fn dropping_while_sink_is_pending_reports_abort_without_forwarding() {
        let (events, mut captured) = tokio::sync::mpsc::unbounded_channel();
        let aborts = Arc::new(AtomicUsize::new(0));
        let mut body = CaptureBody::new(
            Body::from("captured first"),
            PendingSink {
                events,
                aborts: Arc::clone(&aborts),
            },
        );
        let mut frame = Box::pin(body.frame());

        tokio::time::timeout(std::time::Duration::ZERO, &mut frame)
            .await
            .expect_err("the sink future should remain pending");
        drop(frame);
        assert_matches!(captured.recv().await, Some(BodyCaptureEvent::Frame(_)));
        drop(body);
        assert_eq!(aborts.load(Ordering::Relaxed), 1);
    }

    struct AbortSink(Arc<AtomicUsize>);

    impl BodyCaptureSink for AbortSink {
        fn capture(&self, _event: BodyCaptureEvent) -> impl Future<Output = ()> + Send + 'static {
            ready(())
        }

        fn aborted(&self) {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }

    #[test]
    fn into_inner_notifies_sink_of_abort() {
        let aborted = Arc::new(AtomicUsize::new(0));
        let body = CaptureBody::new(Body::from("body"), AbortSink(Arc::clone(&aborted)));
        let _inner = body.into_inner();
        assert_eq!(aborted.load(Ordering::Relaxed), 1);
    }

    struct CompletionSink {
        endings: Arc<AtomicUsize>,
        aborts: Arc<AtomicUsize>,
    }

    impl BodyCaptureSink for CompletionSink {
        fn capture(&self, event: BodyCaptureEvent) -> impl Future<Output = ()> + Send + 'static {
            if matches!(event, BodyCaptureEvent::End(CaptureOutcome::Complete)) {
                self.endings.fetch_add(1, Ordering::Relaxed);
            }
            ready(())
        }

        fn aborted(&self) {
            self.aborts.fetch_add(1, Ordering::Relaxed);
        }
    }

    #[tokio::test]
    async fn normal_completion_finishes_once_without_abort() {
        let endings = Arc::new(AtomicUsize::new(0));
        let aborts = Arc::new(AtomicUsize::new(0));
        let mut body = CaptureBody::new(
            Body::empty(),
            CompletionSink {
                endings: Arc::clone(&endings),
                aborts: Arc::clone(&aborts),
            },
        );

        assert!(body.frame().await.is_none());
        assert!(body.is_end_stream());
        drop(body);

        assert_eq!(endings.load(Ordering::Relaxed), 1);
        assert_eq!(aborts.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn delegates_stream_metadata_without_hiding_pending_completion() {
        let (body, handle) = CaptureBody::buffered(Body::from("abc"), CaptureLimit::unlimited());
        assert!(!body.is_end_stream());
        assert_eq!(body.size_hint().exact(), Some(3));
        drop(handle);

        let (body, handle) = CaptureBody::buffered(Body::empty(), CaptureLimit::unlimited());
        assert!(!body.is_end_stream());
        assert_eq!(body.size_hint().exact(), Some(0));
        drop(handle);
    }

    #[test]
    fn capture_debug_and_canceled_display_are_informative() {
        let (sink, handle) = BufferedBodyCapture::new(CaptureLimit::max_bytes(8));
        assert!(format!("{sink:?}").contains("BufferedBodyCapture"));
        let body = CaptureBody::new(Body::empty(), sink);
        assert!(format!("{body:?}").contains("CaptureBody"));
        assert_eq!(
            CaptureCanceled.to_string(),
            "body capture producer was canceled"
        );
        drop(handle);
    }
}
