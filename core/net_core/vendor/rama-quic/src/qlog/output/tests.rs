use super::*;
use parking_lot::Mutex;
use std::{
    fmt,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
};
use tokio::io::{AsyncWrite, AsyncWriteExt};

#[derive(Debug)]
struct Failure(&'static str);

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.0)
    }
}

impl std::error::Error for Failure {}

#[derive(Default)]
struct Observations {
    bytes: Vec<u8>,
    writes: usize,
    interruptions: usize,
    calls: Vec<&'static str>,
}

#[derive(Default)]
struct Writer {
    observed: Arc<Mutex<Observations>>,
    stutter: bool,
    interrupt_writes: bool,
    interrupted: bool,
    persist_interruption: bool,
    flush_interruptions: usize,
    shutdown_interruptions: usize,
    pending: bool,
    flush_pending: bool,
    shutdown_pending: bool,
    fail_flush: bool,
    fail_shutdown: bool,
}

impl AsyncWrite for Writer {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        if self.pending {
            self.pending = false;
            cx.waker().wake_by_ref();
            return Poll::Pending;
        }
        if self.persist_interruption || (self.interrupt_writes && !self.interrupted) {
            self.interrupted = true;
            self.observed.lock().interruptions += 1;
            if self.persist_interruption {
                assert!(
                    self.observed.lock().interruptions <= 9,
                    "retry budget exceeded"
                );
            }
            return Poll::Ready(Err(io::Error::new(
                io::ErrorKind::Interrupted,
                Failure("persistent write interruption"),
            )));
        }
        self.interrupted = false;
        self.pending = self.stutter;
        let count = if self.stutter {
            bytes.len().min(2)
        } else {
            bytes.len()
        };
        let mut observed = self.observed.lock();
        observed.bytes.extend_from_slice(&bytes[..count]);
        observed.writes += 1;
        Poll::Ready(Ok(count))
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        if self.flush_pending {
            self.flush_pending = false;
            cx.waker().wake_by_ref();
            return Poll::Pending;
        }
        if self.flush_interruptions > 0 {
            self.flush_interruptions -= 1;
            return Poll::Ready(Err(io::Error::new(
                io::ErrorKind::Interrupted,
                Failure("flush interruption"),
            )));
        }
        self.observed.lock().calls.push("flush");
        Poll::Ready(if self.fail_flush {
            Err(io::Error::other(Failure("flush")))
        } else {
            Ok(())
        })
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        if self.shutdown_pending {
            self.shutdown_pending = false;
            cx.waker().wake_by_ref();
            return Poll::Pending;
        }
        if self.shutdown_interruptions > 0 {
            self.shutdown_interruptions -= 1;
            return Poll::Ready(Err(io::Error::new(
                io::ErrorKind::Interrupted,
                Failure("shutdown interruption"),
            )));
        }
        let mut observed = self.observed.lock();
        observed.calls.push("shutdown");
        observed.bytes.extend_from_slice(b"EOF");
        Poll::Ready(if self.fail_shutdown {
            Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                Failure("shutdown"),
            ))
        } else {
            Ok(())
        })
    }
}

#[derive(Default)]
struct Encoder {
    finishes: usize,
    fail_finish: bool,
}

impl QlogEncoder for Encoder {
    async fn named_event<W: AsyncWrite + Unpin + Send>(
        &mut self,
        _info: &TraceInfo,
        _event: &NamedQlogEventView<'_>,
        _output: &mut W,
    ) -> io::Result<()> {
        Ok(())
    }

    async fn begin<W: AsyncWrite + Unpin + Send>(
        &mut self,
        _info: &TraceInfo,
        output: &mut W,
    ) -> io::Result<()> {
        output.write_all(b"header").await
    }

    async fn event<W: AsyncWrite + Unpin + Send>(
        &mut self,
        _info: &TraceInfo,
        _event: &QlogEventView<'_>,
        output: &mut W,
    ) -> io::Result<()> {
        output.write_all(b"event").await
    }

    async fn finish<W: AsyncWrite + Unpin + Send>(&mut self, output: &mut W) -> io::Result<()> {
        self.finishes += 1;
        output.write_all(b"trailer").await?;
        if self.fail_finish {
            Err(io::Error::new(
                io::ErrorKind::InvalidData,
                Failure("encoder"),
            ))
        } else {
            Ok(())
        }
    }
}

fn trace_info() -> TraceInfo {
    TraceInfo {
        event_schemas: &[],
        title: None,
        description: None,
        start_time: Instant::now(),
    }
}

#[tokio::test]
async fn finish_drains_trailers_then_flushes_and_shuts_down_once() {
    let writer = Writer {
        stutter: true,
        flush_pending: true,
        shutdown_pending: true,
        ..Default::default()
    };
    let mut output = EncodedWriter::new(writer, Encoder::default());
    output.begin(&trace_info()).await.unwrap();
    output.finish().await.unwrap();
    output.finish().await.unwrap();
    assert_eq!(output.encoder.finishes, 1);
    {
        let observed = output.writer.observed.lock();
        assert_eq!(observed.bytes, b"headertrailerEOF");
        assert_eq!(observed.calls, ["flush", "shutdown"]);
    }
    assert_eq!(
        output.begin(&trace_info()).await.unwrap_err().kind(),
        io::ErrorKind::BrokenPipe
    );
}

#[tokio::test]
async fn finish_attempts_cleanup_and_preserves_first_error_source() {
    for (fail_finish, fail_flush, fail_shutdown, expected) in [
        (true, false, false, "encoder"),
        (true, true, true, "encoder"),
        (false, true, false, "flush"),
        (false, true, true, "flush"),
        (false, false, true, "shutdown"),
    ] {
        let writer = Writer {
            fail_flush,
            fail_shutdown,
            ..Default::default()
        };
        let encoder = Encoder {
            fail_finish,
            ..Default::default()
        };
        let mut output = EncodedWriter::new(writer, encoder);
        let error = output.finish().await.unwrap_err();
        assert_eq!(
            error
                .get_ref()
                .unwrap()
                .downcast_ref::<Failure>()
                .unwrap()
                .0,
            expected
        );
        assert_eq!(output.writer.observed.lock().calls, ["flush", "shutdown"]);
        assert_eq!(
            output.finish().await.unwrap_err().kind(),
            io::ErrorKind::BrokenPipe
        );
        assert_eq!(output.encoder.finishes, 1);
    }
}

#[tokio::test]
async fn cancelled_finish_does_not_replay_a_partial_trailer() {
    let writer = Writer {
        stutter: true,
        ..Default::default()
    };
    let mut output = EncodedWriter::new(writer, Encoder::default());
    {
        let mut finish = std::pin::pin!(output.finish());
        let mut cx = Context::from_waker(std::task::Waker::noop());
        assert!(finish.as_mut().poll(&mut cx).is_pending());
    }
    assert_eq!(output.writer.observed.lock().bytes, b"tr");
    assert_eq!(
        output.finish().await.unwrap_err().kind(),
        io::ErrorKind::BrokenPipe
    );
    assert_eq!(output.encoder.finishes, 1);
    assert_eq!(output.writer.observed.lock().bytes, b"tr");
}

#[tokio::test]
async fn cancelled_writer_finalization_resumes_without_repeating_completed_phases() {
    for (flush_pending, shutdown_pending, fail_finish) in [
        (true, false, false),
        (false, true, false),
        (true, true, true),
    ] {
        let writer = Writer {
            flush_pending,
            shutdown_pending,
            ..Default::default()
        };
        let mut output = EncodedWriter::new(
            writer,
            Encoder {
                fail_finish,
                ..Default::default()
            },
        );
        {
            let mut finish = std::pin::pin!(output.finish());
            let mut cx = Context::from_waker(std::task::Waker::noop());
            assert!(finish.as_mut().poll(&mut cx).is_pending());
        }
        let result = output.finish().await;
        if fail_finish {
            assert_eq!(
                result
                    .unwrap_err()
                    .get_ref()
                    .unwrap()
                    .downcast_ref::<Failure>()
                    .unwrap()
                    .0,
                "encoder"
            );
        } else {
            result.unwrap();
        }
        assert_eq!(output.encoder.finishes, 1);
        let observed = output.writer.observed.lock();
        assert_eq!(observed.bytes, b"trailerEOF");
        assert_eq!(observed.calls, ["flush", "shutdown"]);
    }
}

#[tokio::test]
async fn config_writer_batches_json_fragments_and_shutdown_emits_eof() {
    let writer = Writer::default();
    let observed = writer.observed.clone();
    let recorder = crate::qlog::QlogConfig::default()
        .with_writer(writer)
        .start()
        .unwrap();
    recorder.flush().await.unwrap();
    {
        let observed = observed.lock();
        assert!(observed.bytes.starts_with(b"\x1e{"));
        assert!(observed.bytes.ends_with(b"\n"));
        assert_eq!(observed.writes, 1);
    }
    recorder.shutdown().await.unwrap();
    let observed = observed.lock();
    assert!(observed.bytes.ends_with(b"\nEOF"));
    assert_eq!(observed.calls, ["flush", "flush", "shutdown"]);
}

#[tokio::test]
async fn buffered_writer_retries_interruptions_at_each_actual_short_write() {
    let writer = Writer {
        stutter: true,
        interrupt_writes: true,
        flush_interruptions: 1,
        shutdown_interruptions: 1,
        ..Default::default()
    };
    let observed = writer.observed.clone();
    let recorder = crate::qlog::QlogConfig::default()
        .with_writer(writer)
        .start()
        .unwrap();
    recorder.flush().await.unwrap();
    recorder.shutdown().await.unwrap();
    let observed = observed.lock();
    assert!(observed.interruptions > 8);
    assert!(observed.bytes.starts_with(b"\x1e{"));
    assert!(observed.bytes.ends_with(b"\nEOF"));
    serde_json::from_slice::<serde_json::Value>(&observed.bytes[1..observed.bytes.len() - 4])
        .unwrap();
    assert_eq!(observed.calls, ["flush", "flush", "shutdown"]);
}

#[tokio::test]
async fn buffered_writer_exhausts_one_retry_budget_during_flush_and_encoding() {
    for title in [None, Some("x".repeat(rama_utils::octets::kib(16)).into())] {
        let writer = Writer {
            persist_interruption: true,
            ..Default::default()
        };
        let observed = writer.observed.clone();
        let recorder = crate::qlog::QlogConfig::default()
            .with_writer(writer)
            .maybe_with_title(title)
            .start()
            .unwrap();
        let error = recorder.flush().await.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::Other);
        assert!(error.to_string().contains("persistent write interruption"));
        assert!(recorder.shutdown().await.is_err());
        assert_eq!(observed.lock().interruptions, 9);
    }
}

#[tokio::test]
async fn writer_flush_and_shutdown_interruptions_are_bounded() {
    for shutdown in [false, true] {
        let writer = Writer {
            flush_interruptions: if shutdown { 0 } else { 100 },
            shutdown_interruptions: if shutdown { 100 } else { 0 },
            ..Default::default()
        };
        let mut writer = RetryInterrupted::new(writer);
        let error = if shutdown {
            writer.shutdown().await.unwrap_err()
        } else {
            writer.flush().await.unwrap_err()
        };
        assert_eq!(error.kind(), io::ErrorKind::Other);
        assert_eq!(
            error.to_string(),
            if shutdown {
                "shutdown interruption"
            } else {
                "flush interruption"
            }
        );
    }
}

#[derive(Debug)]
struct WriterFailure(Arc<Failure>);

impl fmt::Display for WriterFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

impl std::error::Error for WriterFailure {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(self.0.as_ref())
    }
}

struct FailingWriter {
    kind: io::ErrorKind,
    attempts: usize,
    source: Arc<Failure>,
}

impl FailingWriter {
    fn fail(&mut self) -> io::Error {
        self.attempts += 1;
        assert!(self.attempts <= 9, "retry budget exceeded");
        io::Error::new(self.kind, WriterFailure(self.source.clone()))
    }
}

impl AsyncWrite for FailingWriter {
    fn poll_write(
        mut self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        _bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        Poll::Ready(Err(self.fail()))
    }

    fn poll_flush(mut self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Err(self.fail()))
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Err(self.fail()))
    }
}

#[tokio::test]
async fn retry_exhaustion_keeps_original_error_and_custom_source_chain() {
    use std::error::Error as _;

    for operation in ["write", "flush", "shutdown"] {
        let source = Arc::new(Failure("original writer cause"));
        let mut writer = FailingWriter {
            kind: io::ErrorKind::Interrupted,
            attempts: 0,
            source: source.clone(),
        };
        let mut retrying = RetryInterrupted::new(&mut writer);
        let error = match operation {
            "write" => retrying.write_all(b"qlog").await.unwrap_err(),
            "flush" => retrying.flush().await.unwrap_err(),
            _ => retrying.shutdown().await.unwrap_err(),
        };
        assert_eq!(writer.attempts, 9);
        assert_eq!(error.kind(), io::ErrorKind::Other);
        let original = error.source().unwrap().downcast_ref::<io::Error>().unwrap();
        assert_eq!(original.kind(), io::ErrorKind::Interrupted);
        let wrapped = original
            .get_ref()
            .unwrap()
            .downcast_ref::<WriterFailure>()
            .unwrap();
        assert!(Arc::ptr_eq(&wrapped.0, &source));
        let cause = original
            .source()
            .unwrap()
            .downcast_ref::<Failure>()
            .unwrap();
        assert!(std::ptr::eq(cause, source.as_ref()));
        assert_eq!(cause.to_string(), "original writer cause");
        assert!(cause.source().is_none());
    }
}

#[tokio::test]
async fn non_interrupted_writer_errors_preserve_exact_source_without_retry() {
    use std::error::Error as _;

    for kind in [
        io::ErrorKind::PermissionDenied,
        io::ErrorKind::WouldBlock,
        io::ErrorKind::BrokenPipe,
    ] {
        for operation in ["write", "flush", "shutdown"] {
            let source = Arc::new(Failure("original writer cause"));
            let mut writer = FailingWriter {
                kind,
                attempts: 0,
                source: source.clone(),
            };
            let mut retrying = RetryInterrupted::new(&mut writer);
            let error = match operation {
                "write" => retrying.write_all(b"qlog").await.unwrap_err(),
                "flush" => retrying.flush().await.unwrap_err(),
                _ => retrying.shutdown().await.unwrap_err(),
            };
            assert_eq!(writer.attempts, 1);
            assert_eq!(error.kind(), kind);
            let wrapped = error
                .get_ref()
                .unwrap()
                .downcast_ref::<WriterFailure>()
                .unwrap();
            assert!(Arc::ptr_eq(&wrapped.0, &source));
            let cause = error.source().unwrap().downcast_ref::<Failure>().unwrap();
            assert!(std::ptr::eq(cause, source.as_ref()));
            assert!(cause.source().is_none());
        }
    }
}
