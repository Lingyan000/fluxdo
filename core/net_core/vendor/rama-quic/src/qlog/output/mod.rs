use super::{EventSchema, NamedQlogEventView, QlogEventView};
use rama_utils::str::arcstr::ArcStr;
use std::{io, time::Instant};

/// Metadata shared by the events in a recorder's output.
#[derive(Debug, Clone)]
pub struct TraceInfo {
    /// Short label for the output trace. Static labels can use `arcstr!`.
    pub title: Option<ArcStr>,
    /// Optional context for the trace, shared across metadata clones.
    pub description: Option<ArcStr>,
    /// Monotonic epoch used to express event timestamps as elapsed milliseconds.
    pub start_time: Instant,
    /// Event schemas declared in addition to QUIC.
    pub event_schemas: &'static [EventSchema],
}

/// Asynchronous storage, invoked by the recording task after event admission.
/// Methods may wait for I/O. Synchronous computation and destruction must finish promptly.
/// An error ends the recorder; partially written records are never retried automatically.
/// One task owns the output exclusively; `Send` permits executor migration.
/// Implementations remain concrete inside the task, without boxing a future per event.
pub trait QlogOutput: Send + 'static {
    /// Initialize output once, before processing events or flush requests.
    fn begin(&mut self, info: &TraceInfo) -> impl Future<Output = io::Result<()>> + Send;

    /// Write one named event in admission order; an error terminates recording.
    fn named_event(
        &mut self,
        event: &NamedQlogEventView<'_>,
    ) -> impl Future<Output = io::Result<()>> + Send;

    /// Write one observation in admission order; an error terminates recording.
    fn event(&mut self, event: &QlogEventView<'_>) -> impl Future<Output = io::Result<()>> + Send;

    /// Flush buffered output after all earlier admitted commands.
    fn flush(&mut self) -> impl Future<Output = io::Result<()>> + Send;

    /// Finalize output after draining accepted events. Defaults to flushing.
    fn finish(&mut self) -> impl Future<Output = io::Result<()>> + Send {
        self.flush()
    }
}

/// Streaming asynchronous serialization of borrowed events to caller-provided output.
/// Encoders can suspend at I/O backpressure without blocking an executor thread.
pub trait QlogEncoder: Send {
    /// Write trace metadata before the first event.
    fn begin<W: tokio::io::AsyncWrite + Unpin + Send>(
        &mut self,
        info: &TraceInfo,
        output: &mut W,
    ) -> impl Future<Output = io::Result<()>> + Send;

    /// Write one named event, whose data is an already encoded JSON object.
    fn named_event<W: tokio::io::AsyncWrite + Unpin + Send>(
        &mut self,
        info: &TraceInfo,
        event: &NamedQlogEventView<'_>,
        output: &mut W,
    ) -> impl Future<Output = io::Result<()>> + Send;

    /// Encode one borrowed observation, awaiting destination capacity as needed.
    fn event<W: tokio::io::AsyncWrite + Unpin + Send>(
        &mut self,
        info: &TraceInfo,
        event: &QlogEventView<'_>,
        output: &mut W,
    ) -> impl Future<Output = io::Result<()>> + Send;

    /// Write format-specific closing data. The owning output then flushes and shuts down the destination.
    fn finish<W: tokio::io::AsyncWrite + Unpin + Send>(
        &mut self,
        _output: &mut W,
    ) -> impl Future<Output = io::Result<()>> + Send {
        async { Ok(()) }
    }
}

mod async_json;
pub use async_json::AsyncJsonSeqEncoder as JsonSeqEncoder;
pub(super) use async_json::RetryInterrupted;

/// Combine an asynchronous writer with a streaming encoder.
/// The writer is used directly; supply an `AsyncWrite` buffer when small writes are costly.
/// Finishing writes encoder trailers, flushes, then shuts down the writer, even on errors.
/// Cancellation while the encoder writes trailers cannot be retried; drop the output.
/// Cancellation during writer flush or shutdown resumes that phase. Successful finishes are idempotent.
pub struct EncodedWriter<W, E> {
    writer: W,
    encoder: E,
    info: Option<TraceInfo>,
    state: OutputState,
    finish_error: Option<io::Error>,
}

#[derive(PartialEq, Eq)]
enum OutputState {
    Active,
    Encoding,
    Flushing,
    ShuttingDown,
    Finished,
    Failed,
}

impl<W, E> EncodedWriter<W, E> {
    /// Pair a destination and encoder; initialization occurs when recording starts.
    pub fn new(writer: W, encoder: E) -> Self {
        Self {
            writer,
            encoder,
            info: None,
            state: OutputState::Active,
            finish_error: None,
        }
    }

    fn ensure_active(&self) -> io::Result<()> {
        if self.state == OutputState::Active {
            Ok(())
        } else {
            Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "qlog output is finalized",
            ))
        }
    }
}

impl<W, E> QlogOutput for EncodedWriter<W, E>
where
    W: tokio::io::AsyncWrite + Unpin + Send + 'static,
    E: QlogEncoder + 'static,
{
    async fn begin(&mut self, info: &TraceInfo) -> io::Result<()> {
        self.ensure_active()?;
        self.encoder.begin(info, &mut self.writer).await?;
        self.info = Some(info.clone());
        Ok(())
    }

    async fn named_event(&mut self, event: &NamedQlogEventView<'_>) -> io::Result<()> {
        self.ensure_active()?;
        self.encoder
            .named_event(
                self.info
                    .as_ref()
                    .ok_or_else(|| io::Error::other("qlog output was not initialized"))?,
                event,
                &mut self.writer,
            )
            .await
    }

    async fn event(&mut self, event: &QlogEventView<'_>) -> io::Result<()> {
        self.ensure_active()?;
        self.encoder
            .event(
                self.info
                    .as_ref()
                    .ok_or_else(|| io::Error::other("qlog output was not initialized"))?,
                event,
                &mut self.writer,
            )
            .await
    }

    async fn flush(&mut self) -> io::Result<()> {
        self.ensure_active()?;
        tokio::io::AsyncWriteExt::flush(&mut self.writer).await
    }

    async fn finish(&mut self) -> io::Result<()> {
        match self.state {
            OutputState::Active => {
                self.state = OutputState::Encoding;
                self.finish_error = self.encoder.finish(&mut self.writer).await.err();
                self.state = OutputState::Flushing;
            }
            OutputState::Encoding => {
                return Err(io::Error::new(
                    io::ErrorKind::BrokenPipe,
                    "qlog encoder finalization was cancelled and cannot be retried",
                ));
            }
            OutputState::Failed => return self.ensure_active(),
            OutputState::Finished => return Ok(()),
            OutputState::Flushing | OutputState::ShuttingDown => {}
        }
        if self.state == OutputState::Flushing {
            let error = tokio::io::AsyncWriteExt::flush(&mut self.writer)
                .await
                .err();
            self.finish_error = self.finish_error.take().or(error);
            self.state = OutputState::ShuttingDown;
        }
        let error = tokio::io::AsyncWriteExt::shutdown(&mut self.writer)
            .await
            .err();
        if let Some(error) = self.finish_error.take().or(error) {
            self.state = OutputState::Failed;
            Err(error)
        } else {
            self.state = OutputState::Finished;
            Ok(())
        }
    }
}

#[cfg(test)]
pub(crate) mod reference;

#[cfg(test)]
mod tests;
