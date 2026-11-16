use rama_core::{
    bytes::Bytes,
    extensions::{Extensions, ExtensionsRef},
};
use rama_net::tls::ApplicationProtocol;
use rama_quic::qlog::ConnectionQlogControl;
use rama_quic_proto::{ConnectionError, Dir, Side, StreamId, VarInt};
use rama_utils::reactive::ChangeListener;
use std::{
    sync::Weak,
    task::{Context, Poll},
    time::Duration,
};

use super::{
    BiReservation, BoxedStreamHandle, ClosedStream, Connection, EarlyData, ReadError, RecvStream,
    ReserveBiStreams, SendStream, StoppedError, WriteError,
};

/// Run HTTP/3 in the opposite role of the QUIC connection it wraps: the QUIC client serves
/// HTTP/3 and the QUIC server sends the requests, e.g. for a device behind NAT that dials out.
///
/// The stream IDs h3 sees have their initiator flipped, also the IDs inside GOAWAY and
/// PRIORITY_UPDATE and in h3 qlog events. So both ends must wrap their connection.
/// [draft-thomson-ptth-potato] is prior art that keeps the real IDs instead, but is not
/// implemented in Rama since this is still an early draft.
///
/// - Negotiate [`Reversed::application_protocol`] and set it as [`Config::application_protocol`]
///   on both ends, so a plain h3 peer fails fast.
/// - Requests go on streams the QUIC server opens: the QUIC client must grant it bidirectional
///   stream credit.
/// - Nests with [`BoxedConnection`] in either order, e.g.
///   `BoxedConnection::new(Reversed::new(connection))`.
///
/// [draft-thomson-ptth-potato]: https://datatracker.ietf.org/doc/draft-thomson-ptth-potato/
/// [`Config::application_protocol`]: crate::h3::connection::Config::application_protocol
/// [`BoxedConnection`]: super::BoxedConnection
#[derive(Clone, Debug)]
pub struct Reversed<T>(T);

impl<T> Reversed<T> {
    pub fn new(inner: T) -> Self {
        Self(inner)
    }

    pub fn get_ref(&self) -> &T {
        &self.0
    }

    pub fn into_inner(self) -> T {
        self.0
    }
}

// Own impl block, so `Reversed::application_protocol()` needs no type for the wrapped value.
impl Reversed<()> {
    /// The ALPN of reversed HTTP/3. Not potato's token: the stream IDs differ.
    pub fn application_protocol() -> ApplicationProtocol {
        ApplicationProtocol::from(b"rama-h3-reversed")
    }
}

fn reverse(id: StreamId) -> StreamId {
    StreamId::new(!id.initiator(), id.dir(), id.index())
}

fn reverse_bi<S, R>((send, recv): (S, R)) -> (Reversed<S>, Reversed<R>) {
    (Reversed(send), Reversed(recv))
}

impl<C: ExtensionsRef> ExtensionsRef for Reversed<C> {
    fn extensions(&self) -> &Extensions {
        self.0.extensions()
    }
}

impl<C: Connection> Connection for Reversed<C> {
    type SendStream = Reversed<C::SendStream>;
    type RecvStream = Reversed<C::RecvStream>;
    type CloseLease = C::CloseLease;

    async fn open_bi(&self) -> Result<(Self::SendStream, Self::RecvStream), ConnectionError> {
        self.0.open_bi().await.map(reverse_bi)
    }

    async fn open_uni(&self) -> Result<Self::SendStream, ConnectionError> {
        self.0.open_uni().await.map(Reversed)
    }

    async fn accept_bi(&self) -> Result<(Self::SendStream, Self::RecvStream), ConnectionError> {
        self.0.accept_bi().await.map(reverse_bi)
    }

    async fn accept_uni(&self) -> Result<Self::RecvStream, ConnectionError> {
        self.0.accept_uni().await.map(Reversed)
    }

    fn side(&self) -> Side {
        !self.0.side()
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

    // Only the QUIC client can send 0-RTT, and here it serves HTTP/3: an h3 server opens its
    // control and QPACK streams only after `handshake_confirmed`. Reporting none also keeps the
    // h3 client on the QUIC server from treating anything as early.
    fn early_data(&self) -> EarlyData {
        EarlyData::Unavailable
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

    fn datagram_send_ready(&self) -> impl Future<Output = ()> + Send + 'static + use<C> {
        self.0.datagram_send_ready()
    }

    fn close_lease(&self) -> C::CloseLease {
        self.0.close_lease()
    }

    fn rtt(&self) -> Duration {
        self.0.rtt()
    }
}

impl<C: ReserveBiStreams> ReserveBiStreams for Reversed<C> {
    type Reservation = Reversed<C::Reservation>;

    fn try_reserve_bi(&self) -> Result<Option<Self::Reservation>, ConnectionError> {
        self.0
            .try_reserve_bi()
            .map(|reservation| reservation.map(Reversed))
    }

    fn subscribe_bi_stream_budget(&self, listener: Weak<dyn ChangeListener>) {
        self.0.subscribe_bi_stream_budget(listener);
    }
}

impl<R: BiReservation> BiReservation for Reversed<R> {
    type SendStream = Reversed<R::SendStream>;
    type RecvStream = Reversed<R::RecvStream>;

    fn open(self) -> Result<(Self::SendStream, Self::RecvStream), ConnectionError> {
        self.0.open().map(reverse_bi)
    }
}

impl<S: SendStream> SendStream for Reversed<S> {
    type Handle = S::Handle;

    fn id(&self) -> StreamId {
        reverse(self.0.id())
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
        self.0.try_write_generated(reserve, generate)
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
    ) -> impl Future<Output = Result<Option<VarInt>, StoppedError>> + Send + Sync + 'static + use<S>
    {
        self.0.stopped()
    }

    fn handle(&self) -> Self::Handle {
        self.0.handle()
    }

    fn boxed_handle(&self) -> BoxedStreamHandle {
        self.0.boxed_handle()
    }
}

impl<R: RecvStream> RecvStream for Reversed<R> {
    fn id(&self) -> StreamId {
        reverse(self.0.id())
    }

    fn poll_read_chunk(
        &mut self,
        cx: &mut Context<'_>,
        max_length: usize,
    ) -> Poll<Result<Option<Bytes>, ReadError>> {
        self.0.poll_read_chunk(cx, max_length)
    }

    fn stop(&mut self, error_code: VarInt) -> Result<(), ClosedStream> {
        self.0.stop(error_code)
    }

    fn is_0rtt(&self) -> bool {
        self.0.is_0rtt()
    }
}
