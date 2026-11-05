//! Rama's h3 transport trait over a Quinn connection, for the HTTP/3 interop scenarios.
//!
//! Test-only. Quinn does not expose everything the trait asks for, so the adapter fills the
//! gaps from what the test configures ([`Limits`]) and approximates the rest:
//! - the handshake counts as confirmed once the connection is established, and no early data
//!   is sent;
//! - Quinn has no stream reservations: a reservation opens the stream up front and puts it back
//!   in a spare queue when dropped unused, and credit is noticed by waiting on a Quinn open;
//! - the peer's bidirectional stream limit is unknown, so client priorities are not checked
//!   against it;
//! - queued datagrams are not counted, so a closing connection does not drain datagrams, and
//!   room on the datagram send queue is polled for;
//! - a graceful endpoint shutdown is not held off for tunnels, and there is no h3 qlog;
//! - QPACK gets no send credit, so it encodes literals only;
//! - a stream handle sends plain connection datagrams, without the atomic check that the stream
//!   is still open;
//! - connection errors other than application closes map onto a generic transport error.

use std::{
    collections::VecDeque,
    future::Future,
    pin::{Pin, pin},
    sync::{
        Arc, Weak,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    task::{Context, Poll, Waker, ready},
    time::Duration,
};

use parking_lot::Mutex;
use rama::{
    bytes::Bytes,
    extensions::{Extensions, ExtensionsRef},
    http::core::h3::transport::{
        self, ClosedStream, ReadError, SendDatagramError, StoppedError, WriteError,
    },
    net::{address::Domain, stream::SocketInfo, tls::ApplicationProtocol},
    quic::{
        self as rq,
        proto::{
            Dir, Side, StreamId, TransportError, TransportErrorCode, VarInt,
            coding::Codec as _,
            frame::{ApplicationClose, ConnectionClose},
        },
        qlog::ConnectionQlogControl,
    },
    rt::spawn,
    tls::{
        ProtocolVersion,
        client::{NegotiatedTlsAlgorithms, NegotiatedTlsParameters},
    },
    utils::reactive::{Change, ChangeListener, ChangeSignal},
};
use tokio::sync::Notify;

pub const H3: &[u8] = b"h3";

pub fn anchor(
    identity: &rama::tls::server::ServerAuthData,
) -> rama::crypto::pki_types::CertificateDer<'static> {
    identity.cert_chain.last().expect("a chain").clone()
}

pub fn h3_rama_server_config(identity: &rama::tls::server::ServerAuthData) -> rq::ServerConfig {
    super::rama_server_config_with_alpn(identity, H3)
}

pub fn h3_rama_client_config(
    anchor: rama::crypto::pki_types::CertificateDer<'static>,
) -> rq::ClientConfig {
    super::rama_client_config_with_alpn(anchor, H3)
}

pub fn h3_quinn_server_config(identity: &rama::tls::server::ServerAuthData) -> quinn::ServerConfig {
    super::quinn_server_config_with_alpn(identity, H3)
}

pub fn h3_quinn_client_config(
    anchor: rama::crypto::pki_types::CertificateDer<'static>,
) -> quinn::ClientConfig {
    super::quinn_client_config_with_alpn(anchor, H3)
}

/// What the Quinn side allows and what its peer allows: Quinn has setters for these but no
/// getters, and never reports the peer's stream credit.
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    pub local_bi: u64,
    pub local_uni: u64,
    pub peer_uni: u64,
    pub datagrams: bool,
}

impl Limits {
    /// Quinn's and rama's default transport configurations: 100 streams each way, datagrams on.
    pub const DEFAULTS: Self = Self {
        local_bi: 100,
        local_uni: 100,
        peer_uni: 100,
        datagrams: true,
    };
}

#[derive(Debug, Clone)]
pub struct Quinn {
    connection: quinn::Connection,
    extensions: Extensions,
    limits: Limits,
    accepted_bi: Arc<AtomicU64>,
    accepted_uni: Arc<AtomicU64>,
    spare: Arc<Mutex<VecDeque<(quinn::SendStream, quinn::RecvStream)>>>,
    budget: Arc<Budget>,
}

#[derive(Debug, Default)]
struct Budget {
    listeners: ChangeSignal,
    spare_taken: Notify,
    watching: AtomicBool,
}

impl Quinn {
    pub fn new(connection: quinn::Connection, limits: Limits) -> Self {
        let extensions = Extensions::new();
        extensions.insert(SocketInfo::new(None, connection.remote_address().into()));
        let handshake = connection
            .handshake_data()
            .and_then(|data| data.downcast::<quinn::crypto::rustls::HandshakeData>().ok());
        extensions.insert(NegotiatedTlsParameters {
            protocol_version: ProtocolVersion::TLSv1_3,
            application_layer_protocol: handshake
                .as_ref()
                .and_then(|data| data.protocol.as_deref())
                .map(ApplicationProtocol::from),
            peer_certificate_chain: None,
            server_name: handshake
                .as_ref()
                .and_then(|data| data.server_name.as_deref())
                .and_then(|name| Domain::try_from(name).ok()),
            resumed: None,
            algorithms: NegotiatedTlsAlgorithms::default(),
            server_hello: None,
        });
        Self {
            connection,
            extensions,
            limits,
            accepted_bi: Arc::new(AtomicU64::new(0)),
            accepted_uni: Arc::new(AtomicU64::new(0)),
            spare: Arc::default(),
            budget: Arc::default(),
        }
    }

    fn bi(&self, (send, recv): (quinn::SendStream, quinn::RecvStream)) -> (QuinnSend, QuinnRecv) {
        let recv = Arc::new(Mutex::new(recv));
        (
            QuinnSend {
                stream: Arc::new(Mutex::new(send)),
                recv: Some(recv.clone()),
                connection: self.connection.clone(),
            },
            QuinnRecv(recv),
        )
    }

    fn uni_send(&self, send: quinn::SendStream) -> QuinnSend {
        QuinnSend {
            stream: Arc::new(Mutex::new(send)),
            recv: None,
            connection: self.connection.clone(),
        }
    }
}

impl ExtensionsRef for Quinn {
    fn extensions(&self) -> &Extensions {
        &self.extensions
    }
}

impl transport::Connection for Quinn {
    type SendStream = QuinnSend;
    type RecvStream = QuinnRecv;
    type CloseLease = ();

    async fn open_bi(&self) -> Result<(QuinnSend, QuinnRecv), rq::ConnectionError> {
        let pair = self.connection.open_bi().await.map_err(connection_error)?;
        Ok(self.bi(pair))
    }

    async fn open_uni(&self) -> Result<QuinnSend, rq::ConnectionError> {
        let send = self.connection.open_uni().await.map_err(connection_error)?;
        Ok(self.uni_send(send))
    }

    async fn accept_bi(&self) -> Result<(QuinnSend, QuinnRecv), rq::ConnectionError> {
        let pair = self
            .connection
            .accept_bi()
            .await
            .map_err(connection_error)?;
        self.accepted_bi.fetch_add(1, Ordering::Relaxed);
        Ok(self.bi(pair))
    }

    async fn accept_uni(&self) -> Result<QuinnRecv, rq::ConnectionError> {
        let recv = self
            .connection
            .accept_uni()
            .await
            .map_err(connection_error)?;
        self.accepted_uni.fetch_add(1, Ordering::Relaxed);
        Ok(QuinnRecv(Arc::new(Mutex::new(recv))))
    }

    fn side(&self) -> Side {
        match self.connection.side() {
            quinn::Side::Client => Side::Client,
            quinn::Side::Server => Side::Server,
        }
    }

    async fn handshake_confirmed(&self) -> Result<(), rq::ConnectionError> {
        self.connection
            .close_reason()
            .map_or(Ok(()), |error| Err(connection_error(error)))
    }

    fn is_handshake_confirmed(&self) -> bool {
        true
    }

    fn close(&self, error_code: VarInt, reason: &[u8]) {
        self.connection.close(quinn_varint(error_code), reason);
    }

    async fn closed(&self) -> rq::ConnectionError {
        connection_error(self.connection.closed().await)
    }

    fn close_reason(&self) -> Option<rq::ConnectionError> {
        self.connection.close_reason().map(connection_error)
    }

    fn available_streams(&self, dir: Dir) -> u64 {
        match dir {
            Dir::Uni => self.limits.peer_uni,
            Dir::Bi => u64::MAX,
        }
    }

    fn max_concurrent_streams(&self, dir: Dir) -> u64 {
        match dir {
            Dir::Uni => self.limits.local_uni,
            Dir::Bi => self.limits.local_bi,
        }
    }

    fn remote_stream_limit(&self, dir: Dir) -> u64 {
        match dir {
            Dir::Uni => self.limits.local_uni + self.accepted_uni.load(Ordering::Relaxed),
            Dir::Bi => self.limits.local_bi + self.accepted_bi.load(Ordering::Relaxed),
        }
    }

    fn local_stream_limit(&self, _dir: Dir) -> u64 {
        u64::MAX
    }

    fn early_data(&self) -> transport::EarlyData {
        transport::EarlyData::Unavailable
    }

    fn qlog_control(&self) -> Option<ConnectionQlogControl> {
        None
    }

    async fn read_datagram(&self) -> Result<Bytes, rq::ConnectionError> {
        self.connection
            .read_datagram()
            .await
            .map_err(connection_error)
    }

    fn max_datagram_size(&self) -> Option<usize> {
        self.connection.max_datagram_size()
    }

    fn datagram_receive_enabled(&self) -> bool {
        self.limits.datagrams
    }

    fn received_datagrams(&self) -> usize {
        0
    }

    fn datagram_send_ready(&self) -> impl Future<Output = ()> + Send + 'static + use<> {
        let connection = self.connection.clone();
        // Quinn has no wait for room without sending, so poll for it.
        async move {
            while connection.datagram_send_buffer_space() == 0
                && connection.close_reason().is_none()
            {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        }
    }

    fn close_lease(&self) {}

    fn rtt(&self) -> Duration {
        self.connection.rtt()
    }
}

impl transport::ReserveBiStreams for Quinn {
    type Reservation = QuinnReservation;

    fn try_reserve_bi(&self) -> Result<Option<QuinnReservation>, rq::ConnectionError> {
        let spare = self.spare.lock().pop_front();
        if let Some(pair) = spare {
            self.budget.spare_taken.notify_waiters();
            return Ok(Some(self.reservation(pair)));
        }
        let mut open = pin!(self.connection.open_bi());
        match open.as_mut().poll(&mut Context::from_waker(Waker::noop())) {
            Poll::Ready(Ok(pair)) => Ok(Some(self.reservation(pair))),
            Poll::Ready(Err(error)) => Err(connection_error(error)),
            Poll::Pending => Ok(None),
        }
    }

    fn subscribe_bi_stream_budget(&self, listener: Weak<dyn ChangeListener>) {
        self.budget.listeners.subscribe(listener);
        if !self.budget.watching.swap(true, Ordering::Relaxed) {
            spawn(watch_bi_credit(
                self.connection.clone(),
                self.spare.clone(),
                self.budget.clone(),
            ));
        }
    }
}

/// Quinn reports credit only by finishing an open: the opened stream waits as a spare, and the
/// next open starts once it is taken.
async fn watch_bi_credit(
    connection: quinn::Connection,
    spare: Arc<Mutex<VecDeque<(quinn::SendStream, quinn::RecvStream)>>>,
    budget: Arc<Budget>,
) {
    loop {
        let mut taken = pin!(budget.spare_taken.notified());
        taken.as_mut().enable();
        if !spare.lock().is_empty() {
            tokio::select! {
                () = taken => continue,
                _ = connection.closed() => break,
            }
        }
        match connection.open_bi().await {
            Ok(pair) => {
                spare.lock().push_back(pair);
                budget.listeners.notify(Change::Freed);
            }
            Err(_) => break,
        }
    }
    budget.listeners.notify(Change::Other);
}

impl Quinn {
    fn reservation(&self, pair: (quinn::SendStream, quinn::RecvStream)) -> QuinnReservation {
        QuinnReservation {
            pair: Some(pair),
            quinn: self.clone(),
        }
    }
}

/// An already opened Quinn stream pair, back in the spare queue when dropped unused.
pub struct QuinnReservation {
    pair: Option<(quinn::SendStream, quinn::RecvStream)>,
    quinn: Quinn,
}

impl transport::BiReservation for QuinnReservation {
    type SendStream = QuinnSend;
    type RecvStream = QuinnRecv;

    fn open(mut self) -> Result<(QuinnSend, QuinnRecv), rq::ConnectionError> {
        let pair = self.pair.take().expect("a reservation opens once");
        Ok(self.quinn.bi(pair))
    }
}

impl Drop for QuinnReservation {
    fn drop(&mut self) {
        if let Some(pair) = self.pair.take() {
            self.quinn.spare.lock().push_back(pair);
            self.quinn.budget.listeners.notify(Change::Freed);
        }
    }
}

pub struct QuinnSend {
    stream: Arc<Mutex<quinn::SendStream>>,
    recv: Option<Arc<Mutex<quinn::RecvStream>>>,
    connection: quinn::Connection,
}

impl transport::SendStream for QuinnSend {
    type Handle = QuinnHandle;

    fn id(&self) -> StreamId {
        stream_id(self.stream.lock().id())
    }

    fn poll_write_chunks(
        &mut self,
        cx: &mut Context<'_>,
        chunks: &mut [Bytes],
        _reserve: u64,
    ) -> Poll<Result<(), WriteError>> {
        let Some(chunk) = chunks.iter_mut().find(|chunk| !chunk.is_empty()) else {
            return Poll::Ready(Ok(()));
        };
        let mut stream = self.stream.lock();
        let written = ready!(Pin::new(&mut *stream).poll_write(cx, chunk)).map_err(write_error)?;
        _ = chunk.split_to(written);
        Poll::Ready(Ok(()))
    }

    fn try_write_generated(
        &mut self,
        _reserve: u64,
        generate: impl FnOnce(usize) -> Bytes,
    ) -> Result<(), WriteError> {
        if generate(0).is_empty() {
            Ok(())
        } else {
            Err(WriteError::Closed)
        }
    }

    fn finish(&mut self) -> Result<(), ClosedStream> {
        self.stream.lock().finish().map_err(|_| ClosedStream)
    }

    fn reset(&mut self, error_code: VarInt) -> Result<(), ClosedStream> {
        self.stream
            .lock()
            .reset(quinn_varint(error_code))
            .map_err(|_| ClosedStream)
    }

    fn set_priority(&self, priority: i32) -> Result<(), ClosedStream> {
        self.stream
            .lock()
            .set_priority(priority)
            .map_err(|_| ClosedStream)
    }

    fn stopped(
        &self,
    ) -> impl Future<Output = Result<Option<VarInt>, StoppedError>> + Send + Sync + 'static + use<>
    {
        let stopped = self.stream.lock().stopped();
        async move {
            match stopped.await {
                Ok(code) => Ok(code.map(rama_varint)),
                Err(quinn::StoppedError::ConnectionLost(error)) => {
                    Err(StoppedError::ConnectionLost(connection_error(error)))
                }
                Err(_) => Err(StoppedError::ZeroRttRejected),
            }
        }
    }

    fn handle(&self) -> QuinnHandle {
        QuinnHandle {
            send: self.stream.clone(),
            recv: self.recv.clone(),
            connection: self.connection.clone(),
        }
    }
}

pub struct QuinnRecv(Arc<Mutex<quinn::RecvStream>>);

impl transport::RecvStream for QuinnRecv {
    fn id(&self) -> StreamId {
        stream_id(self.0.lock().id())
    }

    fn poll_read_chunk(
        &mut self,
        cx: &mut Context<'_>,
        max_length: usize,
    ) -> Poll<Result<Option<Bytes>, ReadError>> {
        let mut stream = self.0.lock();
        // Cancel safe: a fresh read polled once takes no data unless it is ready.
        let chunk =
            ready!(pin!(stream.read_chunk(max_length, true)).poll(cx)).map_err(read_error)?;
        Poll::Ready(Ok(chunk.map(|chunk| chunk.bytes)))
    }

    fn stop(&mut self, error_code: VarInt) -> Result<(), ClosedStream> {
        self.0
            .lock()
            .stop(quinn_varint(error_code))
            .map_err(|_| ClosedStream)
    }

    fn is_0rtt(&self) -> bool {
        self.0.lock().is_0rtt()
    }
}

pub struct QuinnHandle {
    send: Arc<Mutex<quinn::SendStream>>,
    recv: Option<Arc<Mutex<quinn::RecvStream>>>,
    connection: quinn::Connection,
}

impl transport::StreamHandle for QuinnHandle {
    fn abort(&self, error_code: VarInt) {
        _ = self.send.lock().reset(quinn_varint(error_code));
        if let Some(recv) = &self.recv {
            _ = recv.lock().stop(quinn_varint(error_code));
        }
    }

    fn send_datagram(&self, data: Bytes) -> Result<(), SendDatagramError> {
        self.connection.send_datagram(data).map_err(datagram_error)
    }

    fn try_send_datagram(&self, data: Bytes) -> Result<(), SendDatagramError> {
        // Quinn's waiting send, polled once: still waiting means the queue is full.
        let mut send = pin!(self.connection.send_datagram_wait(data));
        match send.as_mut().poll(&mut Context::from_waker(Waker::noop())) {
            Poll::Ready(result) => result.map_err(datagram_error),
            Poll::Pending => Err(SendDatagramError::Blocked),
        }
    }
}

fn quinn_varint(value: VarInt) -> quinn::VarInt {
    quinn::VarInt::from_u64(value.into_inner()).expect("a QUIC varint fits a QUIC varint")
}

fn rama_varint(value: quinn::VarInt) -> VarInt {
    VarInt::from_u64(value.into_inner()).expect("a QUIC varint fits a QUIC varint")
}

fn stream_id(id: quinn::StreamId) -> StreamId {
    StreamId::from(rama_varint(quinn::VarInt::from(id)))
}

fn connection_error(error: quinn::ConnectionError) -> rq::ConnectionError {
    match error {
        quinn::ConnectionError::ApplicationClosed(close) => {
            rq::ConnectionError::ApplicationClosed(ApplicationClose {
                error_code: rama_varint(close.error_code),
                reason: close.reason,
            })
        }
        quinn::ConnectionError::ConnectionClosed(close) => {
            rq::ConnectionError::ConnectionClosed(ConnectionClose {
                error_code: transport_error_code(close.error_code),
                // Quinn does not expose the frame type's value.
                frame_type: None,
                reason: close.reason,
            })
        }
        quinn::ConnectionError::Reset => rq::ConnectionError::Reset,
        quinn::ConnectionError::TimedOut => rq::ConnectionError::TimedOut,
        quinn::ConnectionError::LocallyClosed => rq::ConnectionError::LocallyClosed,
        quinn::ConnectionError::CidsExhausted => rq::ConnectionError::CidsExhausted,
        other => rq::ConnectionError::TransportError(TransportError::PROTOCOL_VIOLATION(
            other.to_string(),
        )),
    }
}

fn transport_error_code(code: quinn::TransportErrorCode) -> TransportErrorCode {
    let mut wire = Vec::new();
    VarInt::from_u64(u64::from(code))
        .expect("a transport error code is a varint")
        .encode(&mut wire);
    TransportErrorCode::decode(&mut wire.as_slice()).expect("a varint decodes as a code")
}

fn write_error(error: quinn::WriteError) -> WriteError {
    match error {
        quinn::WriteError::Stopped(code) => WriteError::Stopped(rama_varint(code)),
        quinn::WriteError::ConnectionLost(error) => {
            WriteError::ConnectionLost(connection_error(error))
        }
        _ => WriteError::Closed,
    }
}

fn read_error(error: quinn::ReadError) -> ReadError {
    match error {
        quinn::ReadError::Reset(code) => ReadError::Reset(rama_varint(code)),
        quinn::ReadError::ConnectionLost(error) => {
            ReadError::ConnectionLost(connection_error(error))
        }
        _ => ReadError::Closed,
    }
}

fn datagram_error(error: quinn::SendDatagramError) -> SendDatagramError {
    match error {
        quinn::SendDatagramError::UnsupportedByPeer | quinn::SendDatagramError::Disabled => {
            SendDatagramError::Unavailable
        }
        quinn::SendDatagramError::TooLarge => SendDatagramError::TooLarge,
        quinn::SendDatagramError::ConnectionLost(_) => SendDatagramError::Closed,
    }
}
