//! Request-stream framing and message sequencing.

use std::{
    future::poll_fn,
    pin::{Pin, pin},
    sync::Arc,
    task::{Context, Poll, ready},
};

use crate::server::conn::timeout::{HeadBudget, LazyDeadline, deadline_after};
use rama_core::bytes::Bytes;
use rama_http_types::{
    HeaderMap,
    header::trailer::ForbiddenTrailers,
    proto::h3::{Code, FrameType, VarInt},
};
use rama_net::uri::Uri;
use tokio::time::{Instant, Sleep};

use super::{
    Error,
    client::ClientLifetime,
    connection::Shared,
    frame::{FrameDecoder, FrameEvent},
    headers, qlog,
    qpack::EncodeField,
    quic::RecvStream,
    transport::BoxedStreamHandle,
};

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Phase {
    Headers,
    Body,
    Trailers,
    Tunnel,
    Finished,
}

pub(crate) struct Reader<R: RecvStream> {
    pub(crate) stream: R,
    pub(crate) shared: Arc<Shared>,
    pub(crate) id: u64,
    pub(crate) phase: Phase,
    pub(crate) cancel_code: Code,
    pub(crate) abort: Option<BoxedStreamHandle>,
    pub(crate) client_lifetime: Option<Arc<dyn ClientLifetime>>,
    frames: FrameDecoder,
    head_bytes: u64,
    pub(crate) push_id: Option<u64>,
    pub(crate) origin: Option<Uri>,
    /// The request's datagram demux entry while this connection receives datagrams.
    pub(crate) datagrams: Option<Arc<super::datagram::Registration>>,
    // A tunnel's peer reset or a lost connection, returned again instead of reading past it.
    terminal: Option<Error>,
    push_cancelled: Option<Pin<Box<dyn Future<Output = Error> + Send + Sync>>>,
    promise: Option<Pin<Box<dyn Future<Output = Result<(), Error>> + Send + Sync>>>,
}

impl<R: RecvStream> Reader<R> {
    /// The peer ended the stream in order; later datagrams for it are dropped (RFC 9297 §2.1).
    pub(crate) fn finish(&mut self) {
        self.phase = Phase::Finished;
        if let Some(datagrams) = &self.datagrams {
            datagrams.finished();
        }
    }

    /// Ready once a finished stream's datagrams received before its end are queued.
    pub(crate) fn poll_datagrams_finished(&self, cx: &Context<'_>) -> Poll<()> {
        match &self.datagrams {
            Some(datagrams) => datagrams.poll_finished(cx),
            None => Poll::Ready(()),
        }
    }

    pub(crate) fn new(stream: R, shared: Arc<Shared>, id: u64) -> Self {
        let frames = FrameDecoder::with_input_limit(
            shared.config.max_frame_size,
            shared.config.read_chunk_size,
        )
        .with_header_events();
        qlog::request_stream(shared.qlog.as_ref(), shared.role, id);
        Self {
            stream,
            shared,
            id,
            phase: Phase::Headers,
            cancel_code: Code::H3_REQUEST_CANCELLED,
            abort: None,
            client_lifetime: None,
            frames,
            head_bytes: 0,
            origin: None,
            datagrams: None,
            terminal: None,
            push_id: None,
            promise: None,
            push_cancelled: None,
        }
    }

    pub(crate) fn with_prefix(
        stream: R,
        shared: Arc<Shared>,
        id: u64,
        push_id: u64,
        mut prefix: Bytes,
    ) -> Result<Self, Error> {
        let cancel = shared.clone();
        let mut reader = Self::new(stream, shared, id);
        reader.push_id = Some(push_id);
        reader.push_cancelled = Some(Box::pin(
            async move { cancel.push_cancelled(push_id).await },
        ));
        reader.frames.feed_bytes(&mut prefix).map_err(|_error| {
            Error::connection(Code::H3_INTERNAL_ERROR, "invalid buffered stream prefix")
        })?;
        Ok(reader)
    }

    pub(crate) fn reject(&mut self, error: Error) -> Error {
        self.cancel_code = error.code();
        if let Some(abort) = &self.abort
            && let Ok(code) = VarInt::from_u64(error.code().value())
        {
            abort.abort(code);
        } else {
            self.stream.stop(error.code());
        }
        if error.scope() == super::qpack::ErrorScope::Connection {
            self.shared.fail(error);
        }
        error
    }

    pub(crate) fn poll_event(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<Result<Option<FrameEvent>, Error>> {
        if let Some(error) = self.terminal {
            return Poll::Ready(Err(error));
        }
        match self.poll_event_inner(cx) {
            Poll::Ready(Err(error)) => {
                let code = error.code().value();
                if error.is_peer_reset() {
                    if let Some(datagrams) = &self.datagrams {
                        // Unknown codes keep their wire value for diagnostics.
                        let raw = error.raw_code().value();
                        datagrams.receive_ended(super::datagram::ReceiveEnd::Reset(raw));
                    }
                    // Only the peer's direction ended: a tunnel keeps sending (RFC 9000 §3.5).
                    // The reset is terminal for receiving: never read past it into EOF.
                    if self.phase == Phase::Tunnel {
                        self.terminal = Some(error);
                        return Poll::Ready(Err(error));
                    }
                } else if error.is_connection_loss() {
                    // Nothing to abort on a lost connection: aborting would turn later reads
                    // into fresh stream errors instead of the loss the demux reports.
                    self.terminal = Some(error);
                    if error.scope() == super::qpack::ErrorScope::Connection {
                        self.shared.fail(error);
                    }
                    return Poll::Ready(Err(error));
                } else if error.scope() == super::qpack::ErrorScope::Stream
                    && let Some(datagrams) = &self.datagrams
                {
                    // Rejected below: this endpoint aborts the stream.
                    datagrams.receive_ended(super::datagram::ReceiveEnd::Aborted(code));
                }
                Poll::Ready(Err(self.reject(error)))
            }
            result => result,
        }
    }

    fn poll_event_inner(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<Result<Option<FrameEvent>, Error>> {
        if let Some(cancelled) = &mut self.push_cancelled
            && let Poll::Ready(error) = cancelled.as_mut().poll(cx)
        {
            return Poll::Ready(Err(error));
        }
        if self.phase == Phase::Finished {
            return Poll::Ready(Ok(None));
        }
        for _ in 0..super::cooperative::OPERATIONS_PER_QUANTUM {
            // RFC 9297 §2: the driver aborted a request that received datagrams without semantics.
            if self
                .datagrams
                .as_ref()
                .is_some_and(|datagrams| datagrams.violated())
            {
                return Poll::Ready(Err(Error::stream(
                    Code::H3_DATAGRAM_ERROR,
                    "datagram for a request without datagram semantics",
                )
                .remote()));
            }
            if let Some(promise) = &mut self.promise {
                ready!(promise.as_mut().poll(cx))?;
                self.promise = None;
            }
            let request_id = (self.shared.role == super::control::Role::Client
                && self.push_id.is_none())
            .then_some(self.id);
            if let Some(error) = self.shared.receive_error_for_stream(request_id) {
                return Poll::Ready(Err(error));
            }
            let event = self.frames.poll().map_err(|e| {
                Error::from_frame(&e)
                    .map(Error::remote)
                    .unwrap_or(Error::connection(
                        Code::H3_INTERNAL_ERROR,
                        "frame input backpressure",
                    ))
            })?;
            if self.phase == Phase::Headers {
                // Only field-section bytes earn time; unread DATA and extension frames do not.
                self.head_bytes = match &event {
                    Some(FrameEvent::Headers(bytes)) => bytes.len() as u64,
                    _ => self.frames.buffered_headers_len() as u64,
                };
            }
            match event {
                Some(FrameEvent::Header(header)) => {
                    let ty = header.ty;
                    if ty.is_h2_reserved()
                        || matches!(
                            ty,
                            FrameType::PRIORITY_UPDATE_REQUEST
                                | FrameType::PRIORITY_UPDATE_PUSH
                                | FrameType::SETTINGS
                                | FrameType::GOAWAY
                                | FrameType::MAX_PUSH_ID
                                | FrameType::CANCEL_PUSH
                        )
                        || (ty == FrameType::DATA
                            && !matches!(self.phase, Phase::Body | Phase::Tunnel))
                        || (ty == FrameType::HEADERS
                            && matches!(self.phase, Phase::Trailers | Phase::Tunnel))
                        || (ty == FrameType::PUSH_PROMISE
                            && (self.phase == Phase::Tunnel
                                || self.shared.role == super::control::Role::Server
                                || !self.id.is_multiple_of(4)))
                    {
                        return Poll::Ready(Err(Error::connection(
                            Code::H3_FRAME_UNEXPECTED,
                            "frame forbidden in request stream phase",
                        )
                        .remote()));
                    }
                }
                Some(FrameEvent::PushPromise {
                    push_id,
                    encoded_headers,
                }) => {
                    let shared = self.shared.clone();
                    let carrier = self.id;
                    let origin = self.origin.clone();
                    self.promise = Some(Box::pin(async move {
                        shared
                            .promise(carrier, push_id, encoded_headers, origin)
                            .await
                    }));
                }
                Some(FrameEvent::Ignored { .. }) => (),
                Some(event) => return Poll::Ready(Ok(Some(event))),
                None => {
                    if let Some(mut bytes) = ready!(
                        self.stream
                            .poll_chunk(cx, self.shared.config.read_chunk_size)
                    )
                    .map_err(|error| {
                        if error.is_clean_close() {
                            error.incomplete("connection closed before stream FIN")
                        } else {
                            error
                        }
                    })? {
                        self.frames.feed_bytes(&mut bytes).map_err(|_error| {
                            Error::connection(Code::H3_INTERNAL_ERROR, "frame input not drained")
                        })?
                    } else {
                        if !self.frames.is_at_frame_boundary() {
                            return Poll::Ready(Err(Error::connection(
                                Code::H3_FRAME_ERROR,
                                "truncated frame",
                            )
                            .remote()));
                        }
                        if self.phase == Phase::Headers {
                            return Poll::Ready(Err(Error::stream(
                                Code::H3_REQUEST_INCOMPLETE,
                                "stream ended before final headers",
                            )
                            .remote()));
                        }
                        self.finish();
                        return Poll::Ready(Ok(None));
                    }
                }
            }
        }
        cx.waker().wake_by_ref();
        Poll::Pending
    }

    pub(crate) async fn headers(&mut self) -> Result<Vec<super::qpack::FieldPair>, Error> {
        self.headers_within(None).await
    }

    /// Receive and decode a field section, within `deadline` when one applies.
    ///
    /// A request head's budget includes waiting for referenced QPACK inserts.
    pub(crate) async fn headers_within(
        &mut self,
        deadline: Option<HeadDeadline>,
    ) -> Result<Vec<super::qpack::FieldPair>, Error> {
        let mut lazy = LazyDeadline::default();
        let mut sleep = pin!(None::<Sleep>);
        let event = poll_fn(|cx| {
            let result = self.poll_event(cx);
            let at = deadline.map(|deadline| deadline.at(self.head_bytes));
            within(result, at, &mut lazy, &mut sleep, cx)
        })
        .await?;
        let Some(FrameEvent::Headers(bytes)) = event else {
            return Err(Error::connection(
                Code::H3_FRAME_UNEXPECTED,
                "expected field section",
            ));
        };
        let at = deadline.map(|deadline| deadline.at(self.head_bytes));
        let result = {
            let decode = async {
                if self.shared.role == super::control::Role::Server && self.phase == Phase::Headers
                {
                    self.shared.decode_request(self.id, bytes).await
                } else {
                    self.shared
                        .decode_for_stream(self.id, self.push_id, bytes)
                        .await
                }
            };
            let mut decode = pin!(decode);
            poll_fn(|cx| within(decode.as_mut().poll(cx), at, &mut lazy, &mut sleep, cx)).await
        };
        result.map_err(|error| self.reject(error))
    }
}

/// The error of a request head that did not arrive in time.
pub(crate) const HEAD_TIMEOUT: Error =
    Error::stream(Code::H3_REQUEST_REJECTED, "request head timeout");

/// A request head's budget, counted from the acceptance of its stream.
#[derive(Debug, Clone, Copy)]
pub(crate) struct HeadDeadline {
    pub(crate) accepted: Instant,
    pub(crate) budget: HeadBudget,
}

impl HeadDeadline {
    fn at(self, bytes: u64) -> Instant {
        deadline_after(self.accepted, self.budget.allowance(bytes))
    }
}

/// `result`, unless `deadline` passed: a ready result cannot revive an expired head.
fn within<T>(
    result: Poll<Result<T, Error>>,
    deadline: Option<Instant>,
    lazy: &mut LazyDeadline,
    sleep: &mut Pin<&mut Option<Sleep>>,
    cx: &mut Context<'_>,
) -> Poll<Result<T, Error>> {
    let Some(deadline) = deadline else {
        return result;
    };
    match result {
        Poll::Ready(_) if Instant::now() >= deadline => Poll::Ready(Err(HEAD_TIMEOUT)),
        Poll::Ready(result) => Poll::Ready(result),
        Poll::Pending => lazy.poll(sleep, cx, deadline).map(|()| Err(HEAD_TIMEOUT)),
    }
}

impl<R: RecvStream> Drop for Reader<R> {
    fn drop(&mut self) {
        if self.phase != Phase::Finished {
            self.stream.stop(self.cancel_code);
            self.shared.cancel(self.id);
        }
    }
}

/// Outbound field sections are generated from borrowed header values by QPACK.
pub(crate) fn encode_trailers(
    shared: &Shared,
    id: u64,
    headers: &HeaderMap,
    allowed: Option<&ForbiddenTrailers>,
) -> Result<Bytes, Error> {
    headers::validate_outgoing_trailers(headers, allowed)?;
    shared.encode(
        id,
        headers::outgoing_trailer_fields(headers, allowed)
            .map(|(name, value)| EncodeField::from_header(name, value)),
        None,
    )
}
