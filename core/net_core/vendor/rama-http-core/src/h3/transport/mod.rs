//! What HTTP/3 needs from QUIC. h1/h2 are generic over a byte stream, h3 over a [`Connection`],
//! because it takes its streams, flow control and datagrams from QUIC itself.

use rama_core::{bytes::Bytes, extensions::ExtensionsRef};
use rama_quic::qlog::ConnectionQlogControl;
use rama_quic_proto::{ConnectionError, Dir, Side, StreamId, VarInt};
use rama_utils::reactive::ChangeListener;
use std::{
    fmt::Debug,
    sync::{Arc, Weak},
    task::{Context, Poll},
    time::Duration,
};

mod error;
pub use error::{ClosedStream, ReadError, SendDatagramError, StoppedError, WriteError};

mod boxed;
pub use boxed::{BoxedBiReservation, BoxedConnection, BoxedSendStream};

mod reversed;
pub use reversed::Reversed;

/// A QUIC connection carrying HTTP/3.
///
/// Clones share one connection and its live extensions. h3 races opens and accepts in
/// `select!`, so dropping a pending one must not lose stream credit or an incoming stream.
pub trait Connection: Clone + Debug + ExtensionsRef + Send + Sync + 'static {
    type SendStream: SendStream;
    type RecvStream: RecvStream;
    type CloseLease: Send + Sync + Unpin + 'static;

    fn open_bi(
        &self,
    ) -> impl Future<Output = Result<(Self::SendStream, Self::RecvStream), ConnectionError>> + Send;
    fn open_uni(&self) -> impl Future<Output = Result<Self::SendStream, ConnectionError>> + Send;
    /// Accept the next peer-initiated bidirectional stream.
    /// Queued incoming streams remain available after connection closure, before the terminal error.
    fn accept_bi(
        &self,
    ) -> impl Future<Output = Result<(Self::SendStream, Self::RecvStream), ConnectionError>> + Send;
    /// Accept the next peer-initiated unidirectional stream.
    /// Queued incoming streams remain available after connection closure, before the terminal error,
    /// so HTTP/3 can drain buffered control and QPACK data.
    fn accept_uni(&self) -> impl Future<Output = Result<Self::RecvStream, ConnectionError>> + Send;

    /// Which stream IDs are locally initiated. Must match the IDs the streams report.
    fn side(&self) -> Side;
    /// Application data can be sent without 0-RTT replay risk.
    /// Before resolving successfully, publish the negotiated
    /// [`Config::application_protocol`](super::connection::Config::application_protocol) in
    /// [`NegotiatedTlsParameters`](rama_quic::NegotiatedTlsParameters) in the shared extensions.
    fn handshake_confirmed(&self) -> impl Future<Output = Result<(), ConnectionError>> + Send;
    /// Whether [`Self::handshake_confirmed`] resolved successfully; stays true after closing.
    fn is_handshake_confirmed(&self) -> bool;
    fn close(&self, error_code: VarInt, reason: &[u8]);
    fn closed(&self) -> impl Future<Output = ConnectionError> + Send;
    fn close_reason(&self) -> Option<ConnectionError>;

    /// Locally initiated streams that can be opened now.
    fn available_streams(&self, dir: Dir) -> u64;
    /// Streams this endpoint allows the peer to have open at once.
    fn max_concurrent_streams(&self, dir: Dir) -> u64;
    /// Cumulative count of streams this endpoint allows the peer to open.
    fn remote_stream_limit(&self, dir: Dir) -> u64;
    /// Cumulative count of streams the peer allows this endpoint to open.
    fn local_stream_limit(&self, dir: Dir) -> u64;

    /// Where this client's early data stands.
    fn early_data(&self) -> EarlyData;

    /// The qlog sink HTTP/3 events are written to.
    fn qlog_control(&self) -> Option<ConnectionQlogControl>;

    /// Receive the next QUIC DATAGRAM payload.
    /// Dropping a pending future must not discard a datagram; HTTP/3 selects this future
    /// alongside other connection work.
    fn read_datagram(&self) -> impl Future<Output = Result<Bytes, ConnectionError>> + Send;
    fn max_datagram_size(&self) -> Option<usize>;
    /// The peer may send QUIC DATAGRAM frames to this endpoint.
    fn datagram_receive_enabled(&self) -> bool;
    /// Datagrams received and not yet taken by [`Self::read_datagram`].
    fn received_datagrams(&self) -> usize;
    /// Room on the datagram send queue, or the connection closed. Registered when called:
    /// create it before a send that may be refused as blocked and await it after the refusal.
    fn datagram_send_ready(&self) -> impl Future<Output = ()> + Send + 'static + use<Self>;

    /// Holds off this connection's close at a graceful shutdown until dropped, so a tunnel
    /// can still send what it carries.
    fn close_lease(&self) -> Self::CloseLease;
    /// Bounds how long a datagram waits for its request stream.
    fn rtt(&self) -> Duration;
}

/// Early data (0-RTT) of a client connection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EarlyData {
    /// Not attempted: no 0-RTT keys, or a server connection.
    Unavailable,
    /// Sent, and the server has not decided yet.
    Pending,
    Accepted,
    /// The server discarded it: streams opened before the decision are gone.
    Rejected,
}

/// Exact stream credit for a multiplexing connection pool, see
/// [`SendRequest::connection_admission`](super::client::SendRequest::connection_admission).
pub trait ReserveBiStreams: Connection {
    type Reservation: BiReservation<SendStream = Self::SendStream, RecvStream = Self::RecvStream>;

    /// `None` before the handshake completes or while credit is exhausted.
    fn try_reserve_bi(&self) -> Result<Option<Self::Reservation>, ConnectionError>;
    /// Notify `listener` when locally initiated bidirectional stream credit becomes available,
    /// the handshake completes, or the connection closes, until the listener is dropped.
    /// Acquiring or consuming a reservation need not notify listeners. Subscribe before trying
    /// to reserve credit to avoid missing a notification.
    fn subscribe_bi_stream_budget(&self, listener: Weak<dyn ChangeListener>);
}

/// Credit for one bidirectional stream, returned when dropped unopened.
pub trait BiReservation: Send + Sync + 'static {
    type SendStream: SendStream;
    type RecvStream: RecvStream;

    fn open(self) -> Result<(Self::SendStream, Self::RecvStream), ConnectionError>;
}

pub trait SendStream: Send + Sync + Unpin + 'static {
    type Handle: StreamHandle;

    fn id(&self) -> StreamId;

    /// Write a prefix of `chunks`, consuming what was written.
    /// All accepted bytes must be removed from `chunks`, including partial chunks, on every
    /// poll. When returning `Pending`, arrange to wake `cx` when writing can make progress.
    ///
    /// `reserve` bytes of connection send credit stay unused, so the control and QPACK streams
    /// can still send behind large bodies. A transport may ignore it.
    fn poll_write_chunks(
        &mut self,
        cx: &mut Context<'_>,
        chunks: &mut [Bytes],
        reserve: u64,
    ) -> Poll<Result<(), WriteError>>;

    /// Write the chunk `generate` builds for the credit available now (minus `reserve`, 0 if
    /// unknown), calling it exactly once and atomically: QPACK commits encoder state inside it.
    fn try_write_generated(
        &mut self,
        reserve: u64,
        generate: impl FnOnce(usize) -> Bytes,
    ) -> Result<(), WriteError>;

    /// Finish this [`SendStream`]
    fn finish(&mut self) -> Result<(), ClosedStream>;

    /// Reset this [`SendStream`] with the given error_code
    fn reset(&mut self, error_code: VarInt) -> Result<(), ClosedStream>;

    /// Set priority of this stream
    fn set_priority(&self, priority: i32) -> Result<(), ClosedStream>;

    /// Resolves with the peer's STOP_SENDING code, or `None` once all data is acknowledged.
    fn stopped(
        &self,
    ) -> impl Future<Output = Result<Option<VarInt>, StoppedError>> + Send + Sync + 'static + use<Self>;
    fn handle(&self) -> Self::Handle;

    /// Erase the stream handle's type, reusing an existing shared handle when available.
    fn boxed_handle(&self) -> BoxedStreamHandle {
        Arc::new(self.handle())
    }
}

pub trait RecvStream: Send + Sync + Unpin + 'static {
    fn id(&self) -> StreamId;

    /// Read the next in-order chunk of at most `max_length` bytes; `None` at the end of the stream.
    /// Deliver already received, contiguous bytes before reporting connection loss, including
    /// after a clean connection close, so HTTP/3 can drain buffered control and QPACK data.
    /// Returning `Pending` must not consume bytes and must arrange to wake `cx` when data or
    /// a terminal result becomes available.
    fn poll_read_chunk(
        &mut self,
        cx: &mut Context<'_>,
        max_length: usize,
    ) -> Poll<Result<Option<Bytes>, ReadError>>;

    /// Stop this [`RecvStream`] with error_code
    fn stop(&mut self, error_code: VarInt) -> Result<(), ClosedStream>;

    /// Opened during 0-RTT, so its data may be replayed.
    fn is_0rtt(&self) -> bool;

    /// Erase the stream's type, without boxing an already boxed stream.
    fn boxed(self) -> BoxedRecvStream
    where
        Self: Sized,
    {
        Box::new(self)
    }
}

/// A receive stream behind dynamic dispatch.
pub type BoxedRecvStream = Box<dyn RecvStream>;

/// A shared stream handle behind dynamic dispatch.
pub type BoxedStreamHandle = Arc<dyn StreamHandle>;

/// Shared control over a stream whose [`SendStream`] moved to its writer: abort both
/// directions, or send datagrams bound to the stream.
pub trait StreamHandle: Send + Sync + 'static {
    /// Abort both available directions. Already closed directions are harmless.
    fn abort(&self, error_code: VarInt);

    /// Queue a datagram bound to this stream, dropping the oldest queued ones for space.
    ///
    /// The send side state is checked atomically with queueing: fails with
    /// [`SendDatagramError::Closed`] once it ended.
    fn send_datagram(&self, data: Bytes) -> Result<(), SendDatagramError>;

    /// As [`Self::send_datagram`], but a full send buffer fails instead.
    fn try_send_datagram(&self, data: Bytes) -> Result<(), SendDatagramError>;
}

impl Connection for rama_quic::Connection {
    type SendStream = rama_quic::SendStream;
    type RecvStream = rama_quic::RecvStream;
    type CloseLease = rama_quic::CloseLease;

    fn open_bi(
        &self,
    ) -> impl Future<Output = Result<(Self::SendStream, Self::RecvStream), ConnectionError>> + Send
    {
        Self::open_bi(self)
    }

    fn open_uni(&self) -> impl Future<Output = Result<Self::SendStream, ConnectionError>> + Send {
        Self::open_uni(self)
    }

    fn accept_bi(
        &self,
    ) -> impl Future<Output = Result<(Self::SendStream, Self::RecvStream), ConnectionError>> + Send
    {
        Self::accept_bi(self)
    }

    fn accept_uni(&self) -> impl Future<Output = Result<Self::RecvStream, ConnectionError>> + Send {
        Self::accept_uni(self)
    }

    fn side(&self) -> Side {
        Self::side(self)
    }

    fn handshake_confirmed(&self) -> impl Future<Output = Result<(), ConnectionError>> + Send {
        Self::handshake_confirmed(self)
    }

    fn is_handshake_confirmed(&self) -> bool {
        Self::is_handshake_confirmed(self)
    }

    fn close(&self, error_code: VarInt, reason: &[u8]) {
        Self::close(self, error_code, reason);
    }

    fn closed(&self) -> impl Future<Output = ConnectionError> + Send {
        Self::closed(self)
    }

    fn close_reason(&self) -> Option<ConnectionError> {
        Self::close_reason(self)
    }

    fn available_streams(&self, dir: Dir) -> u64 {
        Self::available_streams(self, dir)
    }

    fn max_concurrent_streams(&self, dir: Dir) -> u64 {
        Self::max_concurrent_streams(self, dir)
    }

    fn remote_stream_limit(&self, dir: Dir) -> u64 {
        Self::remote_stream_limit(self, dir)
    }

    fn local_stream_limit(&self, dir: Dir) -> u64 {
        Self::local_stream_limit(self, dir)
    }

    fn early_data(&self) -> EarlyData {
        if !self.early_data_keys_enabled() {
            return EarlyData::Unavailable;
        }
        match self.early_data_accepted() {
            None => EarlyData::Pending,
            Some(true) => EarlyData::Accepted,
            Some(false) => EarlyData::Rejected,
        }
    }

    fn qlog_control(&self) -> Option<ConnectionQlogControl> {
        Self::qlog_control(self)
    }

    fn read_datagram(&self) -> impl Future<Output = Result<Bytes, ConnectionError>> + Send {
        Self::read_datagram(self)
    }

    fn max_datagram_size(&self) -> Option<usize> {
        Self::max_datagram_size(self)
    }

    fn datagram_receive_enabled(&self) -> bool {
        Self::datagram_receive_enabled(self)
    }

    fn received_datagrams(&self) -> usize {
        Self::received_datagrams(self)
    }

    fn datagram_send_ready(&self) -> impl Future<Output = ()> + Send + 'static + use<> {
        Self::datagram_send_ready(self)
    }

    fn close_lease(&self) -> rama_quic::CloseLease {
        Self::close_lease(self)
    }

    fn rtt(&self) -> Duration {
        Self::rtt(self)
    }
}

impl ReserveBiStreams for rama_quic::Connection {
    type Reservation = rama_quic::BiStreamReservation;

    fn try_reserve_bi(&self) -> Result<Option<Self::Reservation>, ConnectionError> {
        Self::try_reserve_bi(self)
    }

    fn subscribe_bi_stream_budget(&self, listener: Weak<dyn ChangeListener>) {
        self.stream_budget_subscribe(Dir::Bi, listener);
    }
}

impl BiReservation for rama_quic::BiStreamReservation {
    type SendStream = rama_quic::SendStream;
    type RecvStream = rama_quic::RecvStream;

    fn open(self) -> Result<(Self::SendStream, Self::RecvStream), ConnectionError> {
        Self::open(self)
    }
}

impl SendStream for rama_quic::SendStream {
    type Handle = rama_quic::StreamHandle;

    fn id(&self) -> StreamId {
        Self::id(self)
    }

    fn poll_write_chunks(
        &mut self,
        cx: &mut Context<'_>,
        chunks: &mut [Bytes],
        reserve: u64,
    ) -> Poll<Result<(), WriteError>> {
        self.poll_write_chunks_with_reserve(cx, chunks, reserve)
            .map_ok(|_written| ())
            .map_err(write_error)
    }

    fn try_write_generated(
        &mut self,
        reserve: u64,
        generate: impl FnOnce(usize) -> Bytes,
    ) -> Result<(), WriteError> {
        Self::try_write_generated(self, reserve, |credit| (generate(credit), ()))
            .map_err(write_error)
    }

    fn finish(&mut self) -> Result<(), ClosedStream> {
        Self::finish(self).map_err(|_closed| ClosedStream)
    }

    fn reset(&mut self, error_code: VarInt) -> Result<(), ClosedStream> {
        Self::reset(self, error_code).map_err(|_closed| ClosedStream)
    }

    fn set_priority(&self, priority: i32) -> Result<(), ClosedStream> {
        Self::set_priority(self, priority).map_err(|_closed| ClosedStream)
    }

    fn stopped(
        &self,
    ) -> impl Future<Output = Result<Option<VarInt>, StoppedError>> + Send + Sync + 'static + use<>
    {
        let stopped = Self::stopped(self);
        async move { stopped.await.map_err(stopped_error) }
    }

    fn handle(&self) -> Self::Handle {
        self.handle()
    }
}

impl RecvStream for rama_quic::RecvStream {
    fn id(&self) -> StreamId {
        Self::id(self)
    }

    fn poll_read_chunk(
        &mut self,
        cx: &mut Context<'_>,
        max_length: usize,
    ) -> Poll<Result<Option<Bytes>, ReadError>> {
        Self::poll_read_chunk(self, cx, max_length, true)
            .map_ok(|chunk| chunk.map(|chunk| chunk.bytes))
            .map_err(read_error)
    }

    fn is_0rtt(&self) -> bool {
        Self::is_0rtt(self)
    }

    fn stop(&mut self, error_code: VarInt) -> Result<(), ClosedStream> {
        Self::stop(self, error_code).map_err(|_closed| ClosedStream)
    }
}

impl RecvStream for BoxedRecvStream {
    fn id(&self) -> StreamId {
        (**self).id()
    }

    fn poll_read_chunk(
        &mut self,
        cx: &mut Context<'_>,
        max_length: usize,
    ) -> Poll<Result<Option<Bytes>, ReadError>> {
        (**self).poll_read_chunk(cx, max_length)
    }

    fn is_0rtt(&self) -> bool {
        (**self).is_0rtt()
    }

    fn stop(&mut self, error_code: VarInt) -> Result<(), ClosedStream> {
        (**self).stop(error_code)
    }

    fn boxed(self) -> BoxedRecvStream {
        self
    }
}

impl StreamHandle for rama_quic::StreamHandle {
    fn abort(&self, error_code: VarInt) {
        Self::abort(self, error_code);
    }

    fn send_datagram(&self, data: Bytes) -> Result<(), SendDatagramError> {
        Self::send_datagram(self, data).map_err(|error| send_datagram_error(&error))
    }

    fn try_send_datagram(&self, data: Bytes) -> Result<(), SendDatagramError> {
        Self::try_send_datagram(self, data).map_err(|error| send_datagram_error(&error))
    }
}

fn write_error(error: rama_quic::WriteError) -> WriteError {
    match error {
        rama_quic::WriteError::Stopped(code) => WriteError::Stopped(code),
        rama_quic::WriteError::ConnectionLost(error) => WriteError::ConnectionLost(error),
        rama_quic::WriteError::ClosedStream | rama_quic::WriteError::ZeroRttRejected => {
            WriteError::Closed
        }
    }
}

fn read_error(error: rama_quic::ReadError) -> ReadError {
    match error {
        rama_quic::ReadError::Reset(code) => ReadError::Reset(code),
        rama_quic::ReadError::ConnectionLost(error) => ReadError::ConnectionLost(error),
        rama_quic::ReadError::ClosedStream
        | rama_quic::ReadError::IllegalOrderedRead
        | rama_quic::ReadError::ZeroRttRejected => ReadError::Closed,
    }
}

fn stopped_error(error: rama_quic::StoppedError) -> StoppedError {
    match error {
        rama_quic::StoppedError::LocallyReset(code) => StoppedError::LocallyReset(code),
        rama_quic::StoppedError::ConnectionLost(error) => StoppedError::ConnectionLost(error),
        rama_quic::StoppedError::ZeroRttRejected => StoppedError::ZeroRttRejected,
    }
}

fn send_datagram_error(error: &rama_quic::SendDatagramError) -> SendDatagramError {
    match error {
        rama_quic::SendDatagramError::UnsupportedByPeer
        | rama_quic::SendDatagramError::Disabled => SendDatagramError::Unavailable,
        rama_quic::SendDatagramError::TooLarge => SendDatagramError::TooLarge,
        rama_quic::SendDatagramError::Blocked => SendDatagramError::Blocked,
        rama_quic::SendDatagramError::StreamClosed
        | rama_quic::SendDatagramError::ConnectionLost(_) => SendDatagramError::Closed,
    }
}
