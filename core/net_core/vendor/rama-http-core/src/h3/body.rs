//! Private H3 implementation behind the common core Incoming body.

use std::{
    pin::{Pin, pin},
    sync::Arc,
    task::{Context, Poll, Waker, ready},
};

use rama_core::{
    bytes::{Buf, Bytes},
    error::BoxError,
};
use rama_http_types::{
    HeaderMap,
    body::{Frame, SizeHint, StreamingBody},
    header::trailer::ForbiddenTrailers,
    proto::h3::{Code, FrameType},
};

use super::{
    Error,
    connection::Shared,
    frame::FrameEvent,
    headers,
    quic::{RecvStream, SendStream, Writer},
    stream::{Phase, Reader},
};

type Trailers = Pin<Box<dyn Future<Output = Result<HeaderMap, Error>> + Send + Sync>>;

pub(crate) struct Body<R: RecvStream> {
    reader: Reader<R>,
    remaining: Option<u64>,
    payload_remaining: Option<u64>,
    trailers: Option<Trailers>,
    failed: bool,
    push: Option<super::push::Lease>,
    upload: Option<tokio::task::JoinHandle<Result<(), Error>>>,
    // Holds the request's admission permit until both body directions finish.
    _permit: Option<Arc<dyn Send + Sync>>,
}

impl<R: RecvStream> Body<R> {
    pub(crate) fn new(
        reader: Reader<R>,
        remaining: Option<u64>,
        permit: Arc<dyn Send + Sync>,
    ) -> Self {
        Self {
            reader,
            remaining,
            payload_remaining: remaining,
            trailers: None,
            failed: false,
            push: None,
            upload: None,
            _permit: Some(permit),
        }
    }

    pub(crate) fn with_push(mut self, lease: super::push::Lease) -> Self {
        self.push = Some(lease);
        self
    }

    pub(crate) fn with_upload(
        mut self,
        upload: Option<tokio::task::JoinHandle<Result<(), Error>>>,
    ) -> Self {
        self.upload = upload;
        self
    }

    /// A message whose content ends before its declared length is malformed (RFC 9114 §4.1.2).
    fn check_content_length_met(&self) -> Result<(), Error> {
        if self.remaining.is_some_and(|len| len != 0) {
            return Err(
                Error::stream(Code::H3_MESSAGE_ERROR, "body shorter than content-length").remote(),
            );
        }
        Ok(())
    }

    fn poll_inner(&mut self, cx: &mut Context<'_>) -> Poll<Option<Result<Frame<Bytes>, Error>>> {
        if self.failed {
            return Poll::Ready(None);
        }
        if let Some(upload) = &mut self.upload
            && let Poll::Ready(result) = Pin::new(upload).poll(cx)
        {
            self.upload = None;
            if let Err(error) = result
                .map_err(|_error| Error::stream(Code::H3_INTERNAL_ERROR, "upload task failed"))?
                && !error.is_peer_stop()
                && !error.is_clean_close()
            {
                return Poll::Ready(Some(Err(error)));
            }
        }
        if let Some(trailers) = &mut self.trailers {
            let fields = ready!(trailers.as_mut().poll(cx))?;
            self.trailers = None;
            return Poll::Ready(Some(Ok(Frame::trailers(fields))));
        }
        for _ in 0..super::cooperative::OPERATIONS_PER_QUANTUM {
            match ready!(self.reader.poll_event(cx))? {
                Some(FrameEvent::DataHeader { len }) => {
                    if let Some(remaining) = &mut self.remaining {
                        *remaining = remaining.checked_sub(len).ok_or(
                            Error::stream(Code::H3_MESSAGE_ERROR, "body exceeds content-length")
                                .remote(),
                        )?;
                    }
                }
                Some(FrameEvent::DataChunk(bytes)) => {
                    if let Some(remaining) = &mut self.payload_remaining {
                        *remaining -= bytes.len() as u64;
                    }
                    return Poll::Ready(Some(Ok(Frame::data(bytes))));
                }
                Some(FrameEvent::Headers(bytes)) => {
                    // Trailers start on a frame boundary, so the declared length must be met.
                    self.check_content_length_met()?;
                    self.reader.phase = Phase::Trailers;
                    let shared = self.reader.shared.clone();
                    let id = self.reader.id;
                    let push = self.reader.push_id;
                    self.trailers = Some(Box::pin(async move {
                        headers::trailers(shared.decode_for_stream(id, push, bytes).await?)
                            .map_err(Error::remote)
                    }));
                    return self.poll_inner(cx);
                }
                None => {
                    self.check_content_length_met()?;
                    if let Some(push) = &mut self.push {
                        push.finished = true;
                    }
                    self._permit.take();
                    return Poll::Ready(None);
                }
                _ => {
                    return Poll::Ready(Some(Err(Error::connection(
                        Code::H3_FRAME_UNEXPECTED,
                        "unexpected body frame",
                    )
                    .remote())));
                }
            }
        }
        cx.waker().wake_by_ref();
        Poll::Pending
    }
}

impl<R: RecvStream + Unpin> StreamingBody for Body<R> {
    type Data = Bytes;
    type Error = crate::Error;
    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, crate::Error>>> {
        match self.poll_inner(cx) {
            Poll::Ready(Some(Err(error))) => {
                self.failed = true;
                self._permit.take();
                self.reader.reject(error);
                Poll::Ready(Some(Err(crate::Error::new_body(error))))
            }
            result => result.map(|frame| frame.map(|frame| frame.map_err(crate::Error::new_body))),
        }
    }

    fn is_end_stream(&self) -> bool {
        self.failed || self.reader.phase == Phase::Finished
    }

    fn size_hint(&self) -> SizeHint {
        if self.is_end_stream() {
            SizeHint::with_exact(0)
        } else {
            self.payload_remaining
                .map_or_else(SizeHint::default, SizeHint::with_exact)
        }
    }
}

pub(crate) async fn send<B, S>(
    mut writer: Writer<S>,
    body: B,
    shared: Arc<Shared>,
    id: u64,
    remaining: Option<u64>,
    allowed_trailers: Option<Arc<ForbiddenTrailers>>,
) -> Result<(), Error>
where
    B: StreamingBody + Unpin,
    B::Error: Into<BoxError>,
    S: SendStream,
{
    let acknowledged = writer.acknowledged();
    let mut acknowledged = pin!(acknowledged);
    // An idle application body must not retain a request's admission permit
    // after STOP_SENDING or connection failure. Watching write readiness alone
    // misses cancellation while awaiting the next application frame.
    let result = tokio::select! {
        biased;
        result = send_inner(&mut writer, body, shared.clone(), id, remaining, allowed_trailers.as_deref()) => {
            match result {
                // RFC 9114 Appendix A.1: queued FIN is not stream completion.
                // Keep server admission alive while QUIC transmits and retries it.
                // A peer that stops acknowledging does not hold a draining server's response.
                Ok(()) => {
                    let since = tokio::time::Instant::now();
                    tokio::select! {
                        result = &mut acknowledged => result,
                        () = shared.goaway_drain_expired(since) => Ok(()),
                    }
                }
                Err(error) => Err(error),
            }
        },
        result = &mut acknowledged => result,
        error = shared.failed() => Err(error),
    };
    match result {
        Ok(()) => writer.mark_acknowledged(),
        Err(error) => writer.reset(error.code()),
    }
    result
}

async fn send_inner<B, S>(
    writer: &mut Writer<S>,
    mut body: B,
    shared: Arc<Shared>,
    id: u64,
    mut remaining: Option<u64>,
    allowed_trailers: Option<&ForbiddenTrailers>,
) -> Result<(), Error>
where
    B: StreamingBody + Unpin,
    B::Error: Into<BoxError>,
    S: SendStream,
{
    flush(&shared, id, writer).await?;
    let mut trailers_seen = false;
    let mut budget = super::cooperative::Budget::default();
    while let Some(frame) = std::future::poll_fn(|cx| {
        Pin::new(&mut body).poll_frame(cx).map(|frame| {
            frame.map(|frame| {
                frame.map_err(|_error| {
                    Error::stream(Code::H3_INTERNAL_ERROR, "application body failed")
                })
            })
        })
    })
    .await
    {
        budget.consume().await;
        let frame = frame?;
        match frame.into_data() {
            Ok(mut data) => {
                if trailers_seen {
                    return Err(Error::stream(
                        Code::H3_INTERNAL_ERROR,
                        "application data after trailers",
                    ));
                }
                if let Some(remaining) = &mut remaining {
                    *remaining =
                        remaining
                            .checked_sub(data.remaining() as u64)
                            .ok_or(Error::stream(
                                Code::H3_MESSAGE_ERROR,
                                "outgoing body exceeds content-length",
                            ))?;
                }
                while data.has_remaining() {
                    let len = data.remaining().min(shared.config.read_chunk_size);
                    budget.consume().await;
                    writer.queue(FrameType::DATA, data.copy_to_bytes(len))?;
                    flush(&shared, id, writer).await?;
                }
            }
            Err(frame) => {
                if let Ok(trailers) = frame.into_trailers() {
                    if trailers_seen {
                        return Err(Error::stream(
                            Code::H3_INTERNAL_ERROR,
                            "duplicate application trailers",
                        ));
                    }
                    trailers_seen = true;
                    let bytes =
                        super::stream::encode_trailers(&shared, id, &trailers, allowed_trailers)?;
                    writer.queue(FrameType::HEADERS, bytes)?;
                    flush(&shared, id, writer).await?;
                }
            }
        }
    }
    if remaining.is_some_and(|len| len != 0) {
        return Err(Error::stream(
            Code::H3_MESSAGE_ERROR,
            "outgoing body shorter than content-length",
        ));
    }
    std::future::poll_fn(|cx| writer.poll_finish(cx)).await
}

impl<R: RecvStream> Drop for Body<R> {
    fn drop(&mut self) {
        // Bodyless responses (and the last consumed DATA frame) need no extra
        // application poll to preserve an upload. Observe an already buffered
        // FIN without waiting or draining an abandoned response body.
        if !self.failed && self.payload_remaining == Some(0) && self.reader.phase == Phase::Body {
            let mut cx = Context::from_waker(Waker::noop());
            if let Poll::Ready(Err(_)) = self.reader.poll_event(&mut cx) {
                self.failed = true;
            }
        }
        // The response and request body are independent stream directions.
        // A fully consumed response must not cancel a still-running upload.
        if (self.failed || self.reader.phase != Phase::Finished)
            && let Some(upload) = &self.upload
        {
            upload.abort();
        }
    }
}

async fn flush<S: SendStream>(
    shared: &Shared,
    id: u64,
    writer: &mut Writer<S>,
) -> Result<(), Error> {
    std::future::poll_fn(|cx| {
        let priority = ready!(shared.schedule.poll_turn(id, cx));
        let result = match writer.priority(super::priority::transport_priority(priority)) {
            Ok(()) => writer.poll_flush(cx),
            Err(error) => Poll::Ready(Err(error)),
        };
        shared.schedule.release(id);
        result
    })
    .await
}
