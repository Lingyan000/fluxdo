use crate::h3::quic::GeneratedWrite;

use super::{
    BiReservation, BoxedStreamHandle, ClosedStream, Connection, EarlyData, RecvStream,
    ReserveBiStreams, SendDatagramError, SendStream, StoppedError, StreamHandle, WriteError,
};
use rama_core::{
    bytes::Bytes,
    extensions::{Extensions, ExtensionsRef},
};
use rama_quic::qlog::ConnectionQlogControl;
use rama_quic_proto::{ConnectionError, Dir, Side, StreamId, VarInt};
use rama_utils::reactive::ChangeListener;
use std::{
    fmt,
    pin::Pin,
    sync::{Arc, Weak},
    task::{Context, Poll},
    time::Duration,
};

type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;
type BoxedStreams = (BoxedSendStream, Box<dyn RecvStream>);
type BoxedReservation = BoxedBiReservation<BoxedSendStream, Box<dyn RecvStream>>;

/// A [`Connection`] behind dynamic dispatch, for where one type has to carry any transport.
///
/// Its streams, futures and reservations are boxed as well.
#[derive(Clone)]
pub struct BoxedConnection(Arc<dyn DynConnection>);

impl BoxedConnection {
    pub fn new<C: ReserveBiStreams>(connection: C) -> Self {
        Self(Arc::new(connection))
    }
}

impl fmt::Debug for BoxedConnection {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(&*self.0, f)
    }
}

impl ExtensionsRef for BoxedConnection {
    fn extensions(&self) -> &Extensions {
        self.0.extensions()
    }
}

impl Connection for BoxedConnection {
    type SendStream = BoxedSendStream;
    type RecvStream = Box<dyn RecvStream>;
    type CloseLease = Box<dyn Send + Sync>;

    fn open_bi(&self) -> impl Future<Output = Result<BoxedStreams, ConnectionError>> + Send {
        self.0.open_bi()
    }

    fn open_uni(&self) -> impl Future<Output = Result<BoxedSendStream, ConnectionError>> + Send {
        self.0.open_uni()
    }

    fn accept_bi(&self) -> impl Future<Output = Result<BoxedStreams, ConnectionError>> + Send {
        self.0.accept_bi()
    }

    fn accept_uni(
        &self,
    ) -> impl Future<Output = Result<Box<dyn RecvStream>, ConnectionError>> + Send {
        self.0.accept_uni()
    }

    fn side(&self) -> Side {
        self.0.side()
    }

    fn handshake_confirmed(&self) -> impl Future<Output = Result<(), ConnectionError>> + Send {
        self.0.handshake_confirmed()
    }

    fn is_handshake_confirmed(&self) -> bool {
        self.0.is_handshake_confirmed()
    }

    fn close(&self, error_code: VarInt, reason: &[u8]) {
        self.0.close(error_code, reason);
    }

    fn closed(&self) -> impl Future<Output = ConnectionError> + Send {
        self.0.closed()
    }

    fn close_reason(&self) -> Option<ConnectionError> {
        self.0.close_reason()
    }

    fn available_streams(&self, dir: Dir) -> u64 {
        self.0.available_streams(dir)
    }

    fn max_concurrent_streams(&self, dir: Dir) -> u64 {
        self.0.max_concurrent_streams(dir)
    }

    fn remote_stream_limit(&self, dir: Dir) -> u64 {
        self.0.remote_stream_limit(dir)
    }

    fn local_stream_limit(&self, dir: Dir) -> u64 {
        self.0.local_stream_limit(dir)
    }

    fn early_data(&self) -> EarlyData {
        self.0.early_data()
    }

    fn qlog_control(&self) -> Option<ConnectionQlogControl> {
        self.0.qlog_control()
    }

    fn read_datagram(&self) -> impl Future<Output = Result<Bytes, ConnectionError>> + Send {
        self.0.read_datagram()
    }

    fn max_datagram_size(&self) -> Option<usize> {
        self.0.max_datagram_size()
    }

    fn datagram_receive_enabled(&self) -> bool {
        self.0.datagram_receive_enabled()
    }

    fn received_datagrams(&self) -> usize {
        self.0.received_datagrams()
    }

    fn datagram_send_ready(&self) -> impl Future<Output = ()> + Send + 'static + use<> {
        self.0.datagram_send_ready()
    }

    fn close_lease(&self) -> Box<dyn Send + Sync> {
        self.0.close_lease()
    }

    fn rtt(&self) -> Duration {
        self.0.rtt()
    }
}

impl ReserveBiStreams for BoxedConnection {
    type Reservation = BoxedBiReservation<BoxedSendStream, Box<dyn RecvStream>>;

    fn try_reserve_bi(&self) -> Result<Option<Self::Reservation>, ConnectionError> {
        self.0.try_reserve_bi()
    }

    fn subscribe_bi_stream_budget(&self, listener: Weak<dyn ChangeListener>) {
        self.0.subscribe_bi_stream_budget(listener);
    }
}

trait DynConnection: ExtensionsRef + fmt::Debug + Send + Sync + 'static {
    fn open_bi(&self) -> BoxFuture<'_, Result<BoxedStreams, ConnectionError>>;
    fn open_uni(&self) -> BoxFuture<'_, Result<BoxedSendStream, ConnectionError>>;
    fn accept_bi(&self) -> BoxFuture<'_, Result<BoxedStreams, ConnectionError>>;
    fn accept_uni(&self) -> BoxFuture<'_, Result<Box<dyn RecvStream>, ConnectionError>>;
    fn side(&self) -> Side;
    fn handshake_confirmed(&self) -> BoxFuture<'_, Result<(), ConnectionError>>;
    fn is_handshake_confirmed(&self) -> bool;
    fn close(&self, error_code: VarInt, reason: &[u8]);
    fn closed(&self) -> BoxFuture<'_, ConnectionError>;
    fn close_reason(&self) -> Option<ConnectionError>;
    fn available_streams(&self, dir: Dir) -> u64;
    fn max_concurrent_streams(&self, dir: Dir) -> u64;
    fn remote_stream_limit(&self, dir: Dir) -> u64;
    fn local_stream_limit(&self, dir: Dir) -> u64;
    fn early_data(&self) -> EarlyData;
    fn qlog_control(&self) -> Option<ConnectionQlogControl>;
    fn read_datagram(&self) -> BoxFuture<'_, Result<Bytes, ConnectionError>>;
    fn max_datagram_size(&self) -> Option<usize>;
    fn datagram_receive_enabled(&self) -> bool;
    fn received_datagrams(&self) -> usize;
    fn datagram_send_ready(&self) -> BoxFuture<'static, ()>;
    fn close_lease(&self) -> Box<dyn Send + Sync>;
    fn rtt(&self) -> Duration;
    fn try_reserve_bi(&self) -> Result<Option<BoxedReservation>, ConnectionError>;
    fn subscribe_bi_stream_budget(&self, listener: Weak<dyn ChangeListener>);
}

fn box_streams<S: SendStream, R: RecvStream>((send, recv): (S, R)) -> BoxedStreams {
    (BoxedSendStream(Box::new(send)), recv.boxed())
}

impl<C: ReserveBiStreams> DynConnection for C {
    fn open_bi(&self) -> BoxFuture<'_, Result<BoxedStreams, ConnectionError>> {
        let open = Connection::open_bi(self);
        Box::pin(async move { open.await.map(box_streams) })
    }

    fn open_uni(&self) -> BoxFuture<'_, Result<BoxedSendStream, ConnectionError>> {
        let open = Connection::open_uni(self);
        Box::pin(async move { open.await.map(|send| BoxedSendStream(Box::new(send))) })
    }

    fn accept_bi(&self) -> BoxFuture<'_, Result<BoxedStreams, ConnectionError>> {
        let accept = Connection::accept_bi(self);
        Box::pin(async move { accept.await.map(box_streams) })
    }

    fn accept_uni(&self) -> BoxFuture<'_, Result<Box<dyn RecvStream>, ConnectionError>> {
        let accept = Connection::accept_uni(self);
        Box::pin(async move { accept.await.map(|recv| recv.boxed()) })
    }

    fn side(&self) -> Side {
        Connection::side(self)
    }

    fn handshake_confirmed(&self) -> BoxFuture<'_, Result<(), ConnectionError>> {
        Box::pin(Connection::handshake_confirmed(self))
    }

    fn is_handshake_confirmed(&self) -> bool {
        Connection::is_handshake_confirmed(self)
    }

    fn close(&self, error_code: VarInt, reason: &[u8]) {
        Connection::close(self, error_code, reason);
    }

    fn closed(&self) -> BoxFuture<'_, ConnectionError> {
        Box::pin(Connection::closed(self))
    }

    fn close_reason(&self) -> Option<ConnectionError> {
        Connection::close_reason(self)
    }

    fn available_streams(&self, dir: Dir) -> u64 {
        Connection::available_streams(self, dir)
    }

    fn max_concurrent_streams(&self, dir: Dir) -> u64 {
        Connection::max_concurrent_streams(self, dir)
    }

    fn remote_stream_limit(&self, dir: Dir) -> u64 {
        Connection::remote_stream_limit(self, dir)
    }

    fn local_stream_limit(&self, dir: Dir) -> u64 {
        Connection::local_stream_limit(self, dir)
    }

    fn early_data(&self) -> EarlyData {
        Connection::early_data(self)
    }

    fn qlog_control(&self) -> Option<ConnectionQlogControl> {
        Connection::qlog_control(self)
    }

    fn read_datagram(&self) -> BoxFuture<'_, Result<Bytes, ConnectionError>> {
        Box::pin(Connection::read_datagram(self))
    }

    fn max_datagram_size(&self) -> Option<usize> {
        Connection::max_datagram_size(self)
    }

    fn datagram_receive_enabled(&self) -> bool {
        Connection::datagram_receive_enabled(self)
    }

    fn received_datagrams(&self) -> usize {
        Connection::received_datagrams(self)
    }

    fn datagram_send_ready(&self) -> BoxFuture<'static, ()> {
        Box::pin(Connection::datagram_send_ready(self))
    }

    fn close_lease(&self) -> Box<dyn Send + Sync> {
        Box::new(Connection::close_lease(self))
    }

    fn rtt(&self) -> Duration {
        Connection::rtt(self)
    }

    fn try_reserve_bi(&self) -> Result<Option<BoxedReservation>, ConnectionError> {
        ReserveBiStreams::try_reserve_bi(self).map(|reservation| {
            reservation.map(|reservation| BoxedBiReservation::new(BoxingReservation(reservation)))
        })
    }

    fn subscribe_bi_stream_budget(&self, listener: Weak<dyn ChangeListener>) {
        ReserveBiStreams::subscribe_bi_stream_budget(self, listener);
    }
}

/// The [`SendStream`] of a [`BoxedConnection`].
pub struct BoxedSendStream(Box<dyn DynSendStream>);

impl SendStream for BoxedSendStream {
    type Handle = BoxedStreamHandle;

    fn id(&self) -> StreamId {
        self.0.id()
    }

    fn poll_write_chunks(
        &mut self,
        cx: &mut Context<'_>,
        chunks: &mut [Bytes],
        reserve: u64,
    ) -> Poll<Result<(), WriteError>> {
        self.0.poll_write_chunks(cx, chunks, reserve)
    }

    fn try_write_generated(
        &mut self,
        reserve: u64,
        generate: impl FnOnce(usize) -> Bytes,
    ) -> Result<(), WriteError> {
        let mut generate = Some(generate);
        self.0.try_write_generated(reserve, &mut |credit| {
            generate
                .take()
                .map_or_else(Bytes::new, |generate| generate(credit))
        })
    }

    fn finish(&mut self) -> Result<(), ClosedStream> {
        self.0.finish()
    }

    fn reset(&mut self, error_code: VarInt) -> Result<(), ClosedStream> {
        self.0.reset(error_code)
    }

    fn set_priority(&self, priority: i32) -> Result<(), ClosedStream> {
        self.0.set_priority(priority)
    }

    fn stopped(
        &self,
    ) -> impl Future<Output = Result<Option<VarInt>, StoppedError>> + Send + Sync + 'static + use<>
    {
        self.0.stopped()
    }

    fn handle(&self) -> BoxedStreamHandle {
        self.0.handle()
    }

    fn boxed_handle(&self) -> BoxedStreamHandle {
        self.0.handle()
    }
}

type BoxedStopped =
    Pin<Box<dyn Future<Output = Result<Option<VarInt>, StoppedError>> + Send + Sync>>;

trait DynSendStream: GeneratedWrite + Unpin + 'static {
    fn id(&self) -> StreamId;
    fn poll_write_chunks(
        &mut self,
        cx: &mut Context<'_>,
        chunks: &mut [Bytes],
        reserve: u64,
    ) -> Poll<Result<(), WriteError>>;
    fn finish(&mut self) -> Result<(), ClosedStream>;
    fn reset(&mut self, error_code: VarInt) -> Result<(), ClosedStream>;
    fn set_priority(&self, priority: i32) -> Result<(), ClosedStream>;
    fn stopped(&self) -> BoxedStopped;
    fn handle(&self) -> BoxedStreamHandle;
}

impl<S: SendStream> DynSendStream for S {
    fn id(&self) -> StreamId {
        SendStream::id(self)
    }

    fn poll_write_chunks(
        &mut self,
        cx: &mut Context<'_>,
        chunks: &mut [Bytes],
        reserve: u64,
    ) -> Poll<Result<(), WriteError>> {
        SendStream::poll_write_chunks(self, cx, chunks, reserve)
    }

    fn finish(&mut self) -> Result<(), ClosedStream> {
        SendStream::finish(self)
    }

    fn reset(&mut self, error_code: VarInt) -> Result<(), ClosedStream> {
        SendStream::reset(self, error_code)
    }

    fn set_priority(&self, priority: i32) -> Result<(), ClosedStream> {
        SendStream::set_priority(self, priority)
    }

    fn stopped(&self) -> BoxedStopped {
        Box::pin(SendStream::stopped(self))
    }

    fn handle(&self) -> BoxedStreamHandle {
        SendStream::boxed_handle(self)
    }
}

/// A [`BiReservation`] behind dynamic dispatch, opening `S` and `R` streams.
pub struct BoxedBiReservation<S, R>(Box<dyn DynBiReservation<S, R>>);

impl<S: SendStream, R: RecvStream> BoxedBiReservation<S, R> {
    pub fn new<B: BiReservation<SendStream = S, RecvStream = R>>(reservation: B) -> Self {
        Self(Box::new(reservation))
    }
}

impl<S: SendStream, R: RecvStream> BiReservation for BoxedBiReservation<S, R> {
    type SendStream = S;
    type RecvStream = R;

    fn open(self) -> Result<(S, R), ConnectionError> {
        self.0.open()
    }
}

trait DynBiReservation<S, R>: Send + Sync + 'static {
    fn open(self: Box<Self>) -> Result<(S, R), ConnectionError>;
}

impl<B: BiReservation> DynBiReservation<B::SendStream, B::RecvStream> for B {
    fn open(self: Box<Self>) -> Result<(B::SendStream, B::RecvStream), ConnectionError> {
        BiReservation::open(*self)
    }
}

/// Opens the streams of `B` boxed, as a [`BoxedConnection`] hands them out.
struct BoxingReservation<B>(B);

impl<B: BiReservation> BiReservation for BoxingReservation<B> {
    type SendStream = BoxedSendStream;
    type RecvStream = Box<dyn RecvStream>;

    fn open(self) -> Result<BoxedStreams, ConnectionError> {
        self.0.open().map(box_streams)
    }
}

impl<H: StreamHandle + ?Sized> StreamHandle for Arc<H> {
    fn abort(&self, error_code: VarInt) {
        (**self).abort(error_code);
    }

    fn send_datagram(&self, data: Bytes) -> Result<(), SendDatagramError> {
        (**self).send_datagram(data)
    }

    fn try_send_datagram(&self, data: Bytes) -> Result<(), SendDatagramError> {
        (**self).try_send_datagram(data)
    }
}
