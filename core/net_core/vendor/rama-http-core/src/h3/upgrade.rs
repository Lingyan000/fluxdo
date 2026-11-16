//! Ordinary CONNECT uses Rama's existing upgrade API and bounded DATA framing.

use super::{
    Error,
    control::Role,
    datagram::{Association, H3DatagramChannel, ReceiveEnd},
    frame::FrameEvent,
    qlog::capsule_observation,
    quic::{RecvStream, SendStream, Writer},
    stream::{Phase, Reader},
    transport::{self, StreamHandle as _},
};
use rama_core::{
    bytes::Bytes,
    extensions::{Extensions, ExtensionsRef},
    io::AbortIo,
};
use rama_http::{
    datagram::NativeDatagrams,
    io::upgrade::{OnMalformedMessage, Upgraded},
};
use rama_http_types::proto::h3::{Code, FrameType, VarInt};
use std::{
    io,
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    task::{Context, Poll, Wake, Waker, ready},
};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

/// `extended` marks an Extended CONNECT tunnel (RFC 9220), else a CONNECT one (RFC 9114 §4.4).
/// `association` is the request's claimed datagram association, carried by `connection`.
pub(crate) fn new<C: transport::Connection>(
    mut reader: Reader<C::RecvStream>,
    writer: Writer<C::SendStream>,
    permit: Arc<dyn Send + Sync>,
    priority: Option<super::priority::Lease>,
    connection: &C,
    association: Option<Arc<Association>>,
    extended: bool,
) -> Upgraded {
    reader.phase = Phase::Tunnel;
    let extensions = reader.shared.transport_extensions.fork();
    // Reliable Capsules exist independently of QUIC DATAGRAM negotiation.
    if let Some(control) = &reader.shared.qlog {
        extensions.insert(capsule_observation(control, reader.id));
    }
    // A local abort fails both directions at once, independent of any later I/O poll.
    let aborted = Arc::new(AtomicU64::new(0));
    let registration = reader.datagrams.as_ref().map(Arc::downgrade);
    // A TCP RST maps to H3_REQUEST_CANCELLED (RFC 9220 §3) or H3_CONNECT_ERROR (RFC 9114 §4.4).
    let abort_code = if extended {
        Code::H3_REQUEST_CANCELLED
    } else {
        Code::H3_CONNECT_ERROR
    };
    for (code, malformed) in [(abort_code, false), (Code::H3_MESSAGE_ERROR, true)] {
        let handle = writer.handle();
        let aborted = aborted.clone();
        let registration = registration.clone();
        let abort = move || {
            _ = aborted.compare_exchange(0, code.value(), Ordering::AcqRel, Ordering::Acquire);
            if let Some(registration) = registration.as_ref().and_then(|weak| weak.upgrade()) {
                registration.receive_ended(ReceiveEnd::Aborted(code.value()));
            }
            handle.abort(VarInt::from_u32(code.value() as u32));
        };
        if malformed {
            extensions.insert(OnMalformedMessage::new(abort));
        } else {
            extensions.insert(AbortIo::new(abort));
        }
    }
    let association = association.and_then(|association| {
        let channel = H3DatagramChannel::new(association.clone(), connection.clone())?;
        extensions.insert(NativeDatagrams::new(channel));
        Some(association)
    });
    Upgraded::new(
        Tunnel {
            reader,
            writer,
            buffer: Bytes::new(),
            extensions,
            priority_lease: priority,
            permit: Some(permit),
            // What the tunnel still sends, such as the close of a connection it carries, leaves
            // before a graceful endpoint shutdown closes the connection under it.
            close_lease: Some(Box::new(connection.close_lease())),
            write_waker: None,
            shutdown: None,
            send_closed: false,
            acknowledged: None,
            association,
            aborted,
        },
        Bytes::new(),
    )
}

type Acknowledged = Pin<Box<dyn Future<Output = Result<(), Error>> + Send + Sync>>;

struct Tunnel<R: RecvStream, S: SendStream> {
    reader: Reader<R>,
    writer: Writer<S>,
    buffer: Bytes,
    extensions: Extensions,
    permit: Option<Arc<dyn Send + Sync>>,
    close_lease: Option<Box<dyn Send + Sync>>,
    // The last writer's task: a read's flush takes over the stream's write registration.
    write_waker: Option<Waker>,
    shutdown: Option<Result<(), Error>>,
    // Shutdown began: nothing more may be written.
    send_closed: bool,
    acknowledged: Option<Acknowledged>,
    priority_lease: Option<super::priority::Lease>,
    association: Option<Arc<Association>>,
    // The code of a local abort through the tunnel's hooks, zero while open.
    aborted: Arc<AtomicU64>,
}

impl<R: RecvStream, S: SendStream> Drop for Tunnel<R, S> {
    fn drop(&mut self) {
        if let Some(association) = &self.association {
            association.close();
        }
    }
}

impl<R: RecvStream, S: SendStream> Tunnel<R, S> {
    /// Fail I/O, including still-buffered data, once a hook aborted the tunnel.
    fn check_aborted(&self) -> io::Result<()> {
        match self.aborted.load(Ordering::Acquire) {
            0 => Ok(()),
            code => {
                let code = Code::new(code);
                // As on HTTP/2: a malformed data stream is invalid data, other aborts are local.
                let kind = if code == Code::H3_MESSAGE_ERROR {
                    io::ErrorKind::InvalidData
                } else {
                    io::ErrorKind::ConnectionAborted
                };
                Err(io::Error::new(
                    kind,
                    Error::stream(code, "tunnel aborted locally"),
                ))
            }
        }
    }

    fn release_finished(&mut self) {
        if self.shutdown == Some(Ok(())) && self.reader.phase == Phase::Finished {
            self.priority_lease.take();
            self.permit.take();
            self.close_lease.take();
        }
    }

    fn flush(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), super::Error>> {
        let shared = &self.reader.shared;
        let id = self.reader.id;
        let priority = ready!(shared.schedule.poll_turn(id, cx));
        let result = match self
            .writer
            .priority(super::priority::transport_priority(priority))
        {
            Ok(()) => self.writer.poll_flush(cx),
            Err(error) => Poll::Ready(Err(error)),
        };
        shared.schedule.release(id);
        result
    }

    /// Send what a write queued without waiting for it, as TCP and HTTP/2 do: a caller that
    /// writes and then reads must not stall on a flush it never asked for. Errors return with
    /// the next write or flush.
    fn flush_queued(&mut self, cx: &mut Context<'_>) {
        if !self.send_closed && !self.writer.is_flushed() {
            _ = self.flush(cx);
        }
    }

    /// [`Self::flush_queued`] from a read. The stream wakes the one task registered last
    /// when it can take more, so this flush registers both the reader and the last writer: a
    /// writer waiting on the queued data must not lose its wake to the reader.
    fn flush_queued_for_reader(&mut self, cx: &mut Context<'_>) {
        if self.send_closed || self.writer.is_flushed() {
            return;
        }
        let Some(writer) = self
            .write_waker
            .as_ref()
            .filter(|writer| !writer.will_wake(cx.waker()))
        else {
            _ = self.flush(cx);
            return;
        };
        let both = Waker::from(Arc::new(BothWakers(cx.waker().clone(), writer.clone())));
        _ = self.flush(&mut Context::from_waker(&both));
    }

    fn remember_writer(&mut self, cx: &Context<'_>) {
        match &mut self.write_waker {
            Some(waker) => waker.clone_from(cx.waker()),
            None => self.write_waker = Some(cx.waker().clone()),
        }
    }
}

/// Wakes a reader and a writer waiting on the same stream registration.
struct BothWakers(Waker, Waker);

impl Wake for BothWakers {
    fn wake(self: Arc<Self>) {
        self.wake_by_ref();
    }

    fn wake_by_ref(self: &Arc<Self>) {
        self.0.wake_by_ref();
        self.1.wake_by_ref();
    }
}

impl<R: RecvStream, S: SendStream> ExtensionsRef for Tunnel<R, S> {
    fn extensions(&self) -> &Extensions {
        &self.extensions
    }
}

impl<R: RecvStream + Unpin, S: SendStream + Unpin> AsyncRead for Tunnel<R, S> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        dst: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        self.check_aborted()?;
        if dst.remaining() == 0 {
            return Poll::Ready(Ok(()));
        }
        self.flush_queued_for_reader(cx);
        for _ in 0..super::cooperative::OPERATIONS_PER_QUANTUM {
            if !self.buffer.is_empty() {
                let count = dst.remaining().min(self.buffer.len());
                dst.put_slice(&self.buffer.split_to(count));
                return Poll::Ready(Ok(()));
            }
            let event = match ready!(self.reader.poll_event(cx)) {
                // A reset without error ends the stream as a FIN would, ownership included.
                Err(error) if error.is_peer_reset() && error.code() == Code::H3_NO_ERROR => {
                    self.reader.finish();
                    ready!(self.reader.poll_datagrams_finished(cx));
                    self.release_finished();
                    return Poll::Ready(Ok(()));
                }
                event => event.map_err(tunnel_io_error)?,
            };
            match event {
                Some(FrameEvent::DataChunk(bytes)) => self.buffer = bytes,
                Some(FrameEvent::DataHeader { .. }) => (),
                None => {
                    // The end follows the datagrams received before it, for the session's drain.
                    ready!(self.reader.poll_datagrams_finished(cx));
                    self.release_finished();
                    return Poll::Ready(Ok(()));
                }
                Some(_) => {
                    let error = super::Error::connection(
                        Code::H3_FRAME_UNEXPECTED,
                        "frame forbidden in CONNECT tunnel",
                    );
                    return Poll::Ready(Err(io::Error::other(self.reader.reject(error))));
                }
            }
        }
        cx.waker().wake_by_ref();
        Poll::Pending
    }
}

impl<R: RecvStream + Unpin, S: SendStream + Unpin> AsyncWrite for Tunnel<R, S> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        src: &[u8],
    ) -> Poll<io::Result<usize>> {
        self.check_aborted()?;
        if self.send_closed {
            return Poll::Ready(Err(io::ErrorKind::BrokenPipe.into()));
        }
        self.remember_writer(cx);
        ready!(self.flush(cx)).map_err(tunnel_write_error)?;
        let count = src.len().min(self.reader.shared.config.read_chunk_size);
        if count != 0 {
            self.writer
                .queue(FrameType::DATA, Bytes::copy_from_slice(&src[..count]))
                .map_err(tunnel_write_error)?;
            self.flush_queued(cx);
        }
        // Ownership has transferred: report acceptance before any subsequent Pending.
        Poll::Ready(Ok(count))
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.check_aborted()?;
        self.remember_writer(cx);
        self.flush(cx).map_err(tunnel_write_error)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        if let Some(result) = self.shutdown {
            return Poll::Ready(result.map_err(tunnel_write_error));
        }
        self.check_aborted()?;
        self.remember_writer(cx);
        self.send_closed = true;
        // RFC 9297 §2.1: no datagrams once the end of the send side is committed.
        if let Some(association) = &self.association {
            association.close_send();
        }
        ready!(self.flush(cx)).map_err(tunnel_write_error)?;
        ready!(self.writer.poll_finish(cx)).map_err(tunnel_write_error)?;
        let Self {
            writer,
            acknowledged,
            ..
        } = &mut *self;
        let wait = acknowledged.get_or_insert_with(|| Box::pin(writer.acknowledged()));
        let result = ready!(wait.as_mut().poll(cx));
        self.acknowledged = None;
        self.shutdown = Some(result);
        match result {
            Ok(()) => {
                self.writer.mark_acknowledged();
                // RFC 9114 §4.1: once a server's response is complete, not reading the
                // rest of the request is H3_NO_ERROR, not a cancellation.
                if self.reader.shared.role == Role::Server {
                    self.reader.cancel_code = Code::H3_NO_ERROR;
                }
            }
            Err(error) => self.writer.reset(error.code()),
        }
        self.release_finished();
        Poll::Ready(result.map_err(tunnel_write_error))
    }
}

// A clean connection close ends writing, but its buffered receive side remains readable.
fn tunnel_write_error(error: Error) -> io::Error {
    if error.is_connection_loss() && error.code() == Code::H3_NO_ERROR {
        io::Error::new(io::ErrorKind::BrokenPipe, error)
    } else {
        tunnel_io_error(error)
    }
}

/// Peer resets and stops are a `ConnectionReset` carrying their code, so a relay can reflect
/// them (RFC 9114 §4.4); a stop without error is a `BrokenPipe`, as on HTTP/2.
fn tunnel_io_error(error: Error) -> io::Error {
    let kind = if error.is_peer_stop() && error.code() == Code::H3_NO_ERROR {
        io::ErrorKind::BrokenPipe
    } else if error.is_peer_stop() || error.is_peer_reset() {
        io::ErrorKind::ConnectionReset
    } else if error.is_connection_loss() {
        io::ErrorKind::ConnectionAborted
    } else {
        io::ErrorKind::Other
    };
    io::Error::new(kind, error)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::h3::{
        Error,
        connection::{Config, Shared},
        control::Role,
        priority::Lease,
    };
    use parking_lot::Mutex;
    use rama_http::headers::Priority;
    use std::assert_matches;
    use std::{
        future::Future as _,
        pin::pin,
        sync::atomic::{AtomicBool, Ordering},
        task::Waker,
    };
    use tokio::io::AsyncWriteExt as _;
    use tokio::sync::Semaphore;

    struct IdleRecv;

    impl RecvStream for IdleRecv {
        fn poll_chunk(
            &mut self,
            _: &mut Context<'_>,
            _: usize,
        ) -> Poll<Result<Option<Bytes>, Error>> {
            Poll::Pending
        }

        fn stop(&mut self, _: Code) {}
    }

    struct ReadySend(Arc<Mutex<Vec<u8>>>, Arc<AtomicBool>, Option<Error>);

    impl SendStream for ReadySend {
        fn acknowledged(&self) -> impl Future<Output = Result<(), Error>> + Send + Sync + 'static {
            let acknowledged = self.1.clone();
            let error = self.2;
            async move {
                std::future::poll_fn(move |_| {
                    if acknowledged.load(Ordering::Relaxed) {
                        Poll::Ready(())
                    } else {
                        Poll::Pending
                    }
                })
                .await;
                error.map_or(Ok(()), Err)
            }
        }

        fn poll_chunks(
            &mut self,
            _: &mut Context<'_>,
            chunks: &mut [Bytes],
        ) -> Poll<Result<(), Error>> {
            let mut written = self.0.lock();
            for chunk in chunks {
                written.extend_from_slice(chunk);
                *chunk = Bytes::new();
            }
            Poll::Ready(Ok(()))
        }

        fn finish(&mut self) -> Result<(), Error> {
            Ok(())
        }
        fn reset(&mut self, _: Code) {}
        fn priority(&mut self, _: i32) -> Result<(), Error> {
            Ok(())
        }
    }

    /// A receive stream the peer reset with an error.
    struct FailedRecv(Error);

    impl RecvStream for FailedRecv {
        fn poll_chunk(
            &mut self,
            _: &mut Context<'_>,
            _: usize,
        ) -> Poll<Result<Option<Bytes>, Error>> {
            Poll::Ready(Err(self.0))
        }

        fn stop(&mut self, _: Code) {}
    }

    /// A send stream the peer stopped with an error.
    struct FailedSend(Error);

    impl SendStream for FailedSend {
        fn acknowledged(&self) -> impl Future<Output = Result<(), Error>> + Send + Sync + 'static {
            std::future::ready(Err(self.0))
        }

        fn poll_chunks(&mut self, _: &mut Context<'_>, _: &mut [Bytes]) -> Poll<Result<(), Error>> {
            Poll::Ready(Err(self.0))
        }

        fn finish(&mut self) -> Result<(), Error> {
            Err(self.0)
        }
        fn reset(&mut self, _: Code) {}
        fn priority(&mut self, _: i32) -> Result<(), Error> {
            Ok(())
        }
    }

    fn tunnel_over<R: RecvStream, S: SendStream>(
        recv: R,
        send: S,
        shared: Arc<Shared>,
        id: u64,
    ) -> Tunnel<R, S> {
        let mut reader = Reader::new(recv, shared, id);
        reader.phase = Phase::Tunnel;
        Tunnel {
            reader,
            writer: Writer::new(send),
            buffer: Bytes::new(),
            extensions: Extensions::new(),
            permit: None,
            close_lease: None,
            write_waker: None,
            shutdown: None,
            send_closed: false,
            acknowledged: None,
            priority_lease: None,
            association: None,
            aborted: Arc::new(AtomicU64::new(0)),
        }
    }

    /// A send stream that is not ready on its first poll, then takes everything.
    struct SlowSend(Arc<Mutex<Vec<u8>>>, bool);

    impl SendStream for SlowSend {
        fn acknowledged(&self) -> impl Future<Output = Result<(), Error>> + Send + Sync + 'static {
            std::future::ready(Ok(()))
        }

        fn poll_chunks(
            &mut self,
            cx: &mut Context<'_>,
            chunks: &mut [Bytes],
        ) -> Poll<Result<(), Error>> {
            if !std::mem::replace(&mut self.1, true) {
                cx.waker().wake_by_ref();
                return Poll::Pending;
            }
            let mut written = self.0.lock();
            for chunk in chunks {
                written.extend_from_slice(chunk);
                *chunk = Bytes::new();
            }
            Poll::Ready(Ok(()))
        }

        fn finish(&mut self) -> Result<(), Error> {
            Ok(())
        }
        fn reset(&mut self, _: Code) {}
        fn priority(&mut self, _: i32) -> Result<(), Error> {
            Ok(())
        }
    }

    /// A write the transport could not take at once is sent by a later read, without a flush.
    #[test]
    fn a_read_sends_what_an_earlier_write_could_not() {
        let shared = Shared::new(Config::default(), Role::Client, Extensions::new()).unwrap();
        shared.schedule.register(0, Priority::default()).unwrap();
        let output = Arc::new(Mutex::new(Vec::new()));
        let mut tunnel = tunnel_over(IdleRecv, SlowSend(output.clone(), false), shared, 0);
        let mut cx = Context::from_waker(Waker::noop());
        let Poll::Ready(Ok(4)) = Pin::new(&mut tunnel).poll_write(&mut cx, b"ping") else {
            panic!("the write is queued");
        };
        assert!(output.lock().is_empty());
        let mut buf = [0; 4];
        assert!(
            Pin::new(&mut tunnel)
                .poll_read(&mut cx, &mut ReadBuf::new(&mut buf))
                .is_pending()
        );
        assert!(output.lock().ends_with(b"ping"));
    }

    /// A reset or stop without error ends the stream as a FIN would (a `BrokenPipe` for
    /// writes); any other is a `ConnectionReset` carrying its code, for a relay to reflect.
    #[test]
    fn peer_resets_and_stops_map_by_their_code() {
        let shared = Shared::new(Config::default(), Role::Client, Extensions::new()).unwrap();
        let mut cx = Context::from_waker(Waker::noop());
        for code in [
            Code::H3_NO_ERROR,
            Code::H3_REQUEST_CANCELLED,
            Code::H3_CONNECT_ERROR,
        ] {
            shared.schedule.register(0, Priority::default()).unwrap();
            let mut tunnel = tunnel_over(
                FailedRecv(Error::peer_reset(code)),
                FailedSend(Error::peer_stopped(code)),
                shared.clone(),
                0,
            );
            let mut buf = [0; 8];
            let mut read = ReadBuf::new(&mut buf);
            let result = Pin::new(&mut tunnel).poll_read(&mut cx, &mut read);
            if code == Code::H3_NO_ERROR {
                assert_matches!(result, Poll::Ready(Ok(())));
                assert!(read.filled().is_empty());
            } else {
                let Poll::Ready(Err(error)) = result else {
                    panic!("{code:?}: a reset with error must fail the read");
                };
                assert_eq!(error.kind(), io::ErrorKind::ConnectionReset, "{code:?}");
                let cause = error.get_ref().unwrap().downcast_ref::<Error>().unwrap();
                assert_eq!(cause.code(), code);
            }
            let Poll::Ready(Ok(_)) = Pin::new(&mut tunnel).poll_write(&mut cx, b"data") else {
                panic!("{code:?}: the first write is only queued");
            };
            let Poll::Ready(Err(error)) = Pin::new(&mut tunnel).poll_flush(&mut cx) else {
                panic!("{code:?}: a stopped stream must fail the flush");
            };
            let expected = if code == Code::H3_NO_ERROR {
                io::ErrorKind::BrokenPipe
            } else {
                io::ErrorKind::ConnectionReset
            };
            assert_eq!(error.kind(), expected, "{code:?}");
            drop(tunnel);
            shared.schedule.release(0);
        }
    }

    fn tunnel(
        shared: Arc<Shared>,
        id: u64,
        output: Arc<Mutex<Vec<u8>>>,
    ) -> Tunnel<IdleRecv, ReadySend> {
        Tunnel {
            reader: Reader::new(IdleRecv, shared, id),
            writer: Writer::new(ReadySend(output, Arc::new(AtomicBool::new(false)), None)),
            buffer: Bytes::new(),
            extensions: Extensions::new(),
            permit: None,
            close_lease: None,
            write_waker: None,
            shutdown: None,
            send_closed: false,
            acknowledged: None,
            priority_lease: None,
            association: None,
            aborted: Arc::new(AtomicU64::new(0)),
        }
    }

    #[test]
    fn repeated_tunnel_shutdown_preserves_peer_stop_without_repolling_future() {
        let shared = Shared::new(Config::default(), Role::Server, Default::default()).unwrap();
        shared.schedule.register(0, Priority::default()).unwrap();
        let output = Arc::new(Mutex::new(Vec::new()));
        let mut tunnel = tunnel(shared, 0, output.clone());
        let error = Error::peer_stopped(Code::H3_REQUEST_CANCELLED);
        tunnel.writer = Writer::new(ReadySend(
            output,
            Arc::new(AtomicBool::new(true)),
            Some(error),
        ));
        let mut cx = Context::from_waker(Waker::noop());
        for _ in 0..3 {
            let Poll::Ready(Err(actual)) = Pin::new(&mut tunnel).poll_shutdown(&mut cx) else {
                panic!("shutdown must preserve its terminal error");
            };
            assert_eq!(
                actual.get_ref().unwrap().downcast_ref::<Error>(),
                Some(&error)
            );
        }
    }

    #[test]
    fn tunnel_shutdown_retains_admission_until_fin_acknowledgement() {
        let shared = Shared::new(
            Config {
                max_requests: 1,
                ..Config::default()
            },
            Role::Server,
            Default::default(),
        )
        .unwrap();
        shared.schedule.register(0, Priority::default()).unwrap();
        let admission = Arc::new(Semaphore::new(1));
        let permit = Arc::new(admission.clone().try_acquire_owned().unwrap());
        let output = Arc::new(Mutex::new(Vec::new()));
        let mut tunnel = tunnel(shared.clone(), 0, output.clone());
        let acknowledged = Arc::new(AtomicBool::new(false));
        tunnel.writer = Writer::new(ReadySend(output, acknowledged.clone(), None));
        tunnel.reader.phase = Phase::Finished;
        tunnel.permit = Some(permit.clone());
        tunnel.priority_lease = Some(Lease {
            shared: shared.clone(),
            id: 0,
            permit,
        });
        let mut cx = Context::from_waker(Waker::noop());
        assert!(Pin::new(&mut tunnel).poll_shutdown(&mut cx).is_pending());
        assert_eq!(admission.available_permits(), 0);
        acknowledged.store(true, Ordering::Relaxed);
        assert_matches!(
            Pin::new(&mut tunnel).poll_shutdown(&mut cx),
            Poll::Ready(Ok(())),
        );
        assert_eq!(admission.available_permits(), 1);
        shared.schedule.register(4, Priority::default()).unwrap();
        assert_matches!(
            Pin::new(&mut tunnel).poll_shutdown(&mut cx),
            Poll::Ready(Ok(())),
        );
    }

    /// A receive side that ends once with `end`, then stays ended.
    struct EndedRecv(Option<Error>);

    impl RecvStream for EndedRecv {
        fn poll_chunk(
            &mut self,
            _: &mut Context<'_>,
            _: usize,
        ) -> Poll<Result<Option<Bytes>, Error>> {
            Poll::Ready(self.0.map_or(Ok(None), Err))
        }

        fn stop(&mut self, _: Code) {}
    }

    /// A completed tunnel releases its admission once both directions ended in order, its
    /// receive side by FIN or by a reset without error, whichever ends first; one reset with an
    /// error keeps it until dropped. A retained tunnel keeps reading as ended.
    #[test]
    fn tunnels_release_admission_once_both_directions_ended_in_order() {
        for (end, releases) in [
            (None, true),
            (Some(Error::peer_reset(Code::H3_NO_ERROR)), true),
            (Some(Error::peer_reset(Code::H3_REQUEST_CANCELLED)), false),
        ] {
            for read_first in [true, false] {
                let case = format!("{end:?} read_first={read_first}");
                let shared = Shared::new(
                    Config {
                        max_requests: 1,
                        ..Config::default()
                    },
                    Role::Client,
                    Extensions::new(),
                )
                .unwrap();
                shared.schedule.register(0, Priority::default()).unwrap();
                let admission = Arc::new(Semaphore::new(1));
                let permit = Arc::new(admission.clone().try_acquire_owned().unwrap());
                let output = Arc::new(Mutex::new(Vec::new()));
                let mut tunnel = tunnel_over(
                    EndedRecv(end),
                    ReadySend(output, Arc::new(AtomicBool::new(true)), None),
                    shared.clone(),
                    0,
                );
                tunnel.permit = Some(permit.clone());
                tunnel.priority_lease = Some(Lease {
                    shared,
                    id: 0,
                    permit,
                });
                let mut cx = Context::from_waker(Waker::noop());
                let mut read = |tunnel: &mut Tunnel<EndedRecv, ReadySend>| {
                    let mut buf = [0; 8];
                    let mut buf = ReadBuf::new(&mut buf);
                    let Poll::Ready(result) = Pin::new(tunnel).poll_read(&mut cx, &mut buf) else {
                        panic!("{case}: an ended stream reads at once");
                    };
                    result.map(|()| buf.filled().len())
                };
                let shutdown = |tunnel: &mut Tunnel<EndedRecv, ReadySend>| {
                    let mut cx = Context::from_waker(Waker::noop());
                    assert_matches!(
                        Pin::new(tunnel).poll_shutdown(&mut cx),
                        Poll::Ready(Ok(())),
                        "{case}"
                    );
                };
                if !read_first {
                    shutdown(&mut tunnel);
                }
                for _ in 0..2 {
                    match read(&mut tunnel) {
                        Ok(read) => assert_eq!(read, 0, "{case}"),
                        Err(error) => {
                            assert!(!releases, "{case}: {error}");
                            assert_eq!(error.kind(), io::ErrorKind::ConnectionReset, "{case}");
                        }
                    }
                }
                if read_first {
                    shutdown(&mut tunnel);
                }
                let available = usize::from(releases);
                assert_eq!(admission.available_permits(), available, "{case}");
                drop(tunnel);
                // The next request is admitted, at the latest once the tunnel is gone.
                assert_eq!(admission.available_permits(), 1, "{case}");
            }
        }
    }

    #[test]
    fn cancelling_a_write_future_preserves_other_tunnel_progress() {
        let shared = Shared::new(Config::default(), Role::Server, Extensions::new()).unwrap();
        for (id, urgency) in [(0, 0), (4, 1), (8, 7)] {
            shared
                .schedule
                .register(id, Priority::new(urgency, true).unwrap())
                .unwrap();
        }
        let abandoned_output = Arc::new(Mutex::new(Vec::new()));
        let active_output = Arc::new(Mutex::new(Vec::new()));
        let mut abandoned = tunnel(shared.clone(), 4, abandoned_output.clone());
        let mut active = tunnel(shared.clone(), 8, active_output.clone());
        let mut cx = Context::from_waker(Waker::noop());
        // An in-progress writer initially owns the preferred turn.
        assert!(shared.schedule.poll_turn(0, &cx).is_ready());
        {
            let mut write = pin!(abandoned.write(b"cancelled"));
            assert!(write.as_mut().poll(&mut cx).is_pending());
        }
        shared.schedule.release(0);
        // Keep the abandoned tunnel alive, as after a timeout or select branch.
        // Its lower-priority peer must nevertheless send actual DATA promptly.
        {
            let mut write = pin!(active.write(b"progress"));
            assert!(write.as_mut().poll(&mut cx).is_pending());
            assert_matches!(write.as_mut().poll(&mut cx), Poll::Ready(Ok(8)));
        }
        assert!(Pin::new(&mut active).poll_flush(&mut cx).is_ready());
        assert_eq!(*active_output.lock(), b"\x00\x08progress");
        assert!(abandoned_output.lock().is_empty());
        {
            let mut write = pin!(abandoned.write(b"retry"));
            assert_matches!(write.as_mut().poll(&mut cx), Poll::Ready(Ok(5)));
        }
        assert!(Pin::new(&mut abandoned).poll_flush(&mut cx).is_ready());
        assert_eq!(*abandoned_output.lock(), b"\x00\x05retry");
    }
}
