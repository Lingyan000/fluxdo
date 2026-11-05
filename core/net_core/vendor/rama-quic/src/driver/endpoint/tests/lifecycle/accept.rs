//! An accept releases the endpoint lock for its handshake work: the endpoint keeps routing
//! meanwhile, and whatever happened to the endpoint by the time the accept takes the lock
//! again is settled then, exactly once.

use std::{
    pin::pin,
    sync::{OnceLock, Weak},
    task::Context,
    thread,
};

use parking_lot::Condvar;
use rama_net::tls::ApplicationProtocol;
use rama_quic_proto::{
    ConnectionId, Side, TransportError,
    crypto::{CryptoError, HeaderKey, PacketKey},
    packet::SpaceId,
    transport_parameters::TransportParameters,
};
use tokio::task::JoinHandle;

use super::*;
use crate::proto::{
    ExportKeyingMaterialError, NegotiatedTlsParameters, ServerCrypto,
    crypto::{self, HandshakeEvent, InitialKeysError, KeyPair, Keys, Session, UnsupportedVersion},
};

const LIMIT: Duration = Duration::from_secs(5);

/// What a held session start does once its gate opens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Release {
    Start,
    Fail,
    Unwind,
}

/// Holds every server session start while closed, so a test can act while an accept is
/// between its two holds of the endpoint lock.
#[derive(Default)]
struct Gate {
    state: Mutex<GateState>,
    changed: Condvar,
}

#[derive(Default)]
struct GateState {
    closed: bool,
    held: usize,
    release: Option<Release>,
}

impl Gate {
    /// Close the gate. It opens again when the returned opener says so or is dropped, and
    /// after a while regardless, so an accept held under a lock it should not hold fails the
    /// test instead of hanging it.
    fn close(self: &Arc<Self>) -> Opener {
        self.state.lock().closed = true;
        let gate = Arc::downgrade(self);
        thread::spawn(move || {
            thread::sleep(3 * LIMIT);
            if let Some(gate) = gate.upgrade() {
                gate.open(Release::Start);
            }
        });
        Opener(self.clone())
    }

    fn held(&self) -> usize {
        self.state.lock().held
    }

    fn open(&self, release: Release) {
        let mut state = self.state.lock();
        state.closed = false;
        state.release = Some(release);
        self.changed.notify_all();
    }

    fn pass(&self) -> Release {
        let mut state = self.state.lock();
        state.held += 1;
        self.changed.notify_all();
        while state.closed {
            self.changed.wait(&mut state);
        }
        state.held -= 1;
        let release = state.release.unwrap_or(Release::Start);
        drop(state);
        assert!(release != Release::Unwind, "session start unwinds");
        release
    }

    /// Wait, off the runtime, until a session start is held.
    async fn holding(self: &Arc<Self>) {
        let gate = self.clone();
        tokio::task::spawn_blocking(move || {
            let mut state = gate.state.lock();
            while state.held == 0 {
                assert!(
                    !gate.changed.wait_for(&mut state, LIMIT).timed_out(),
                    "no session start was held"
                );
            }
        })
        .await
        .unwrap();
    }
}

/// Opens its gate when dropped, so a failing test never leaves an accept held.
struct Opener(Arc<Gate>);

impl Opener {
    fn open(&self, release: Release) {
        self.0.open(release);
    }
}

impl Drop for Opener {
    fn drop(&mut self) {
        self.0.open(Release::Start);
    }
}

/// Counts the handshake reads of server sessions and those made while the endpoint lock was
/// held. A lock another thread holds is free again within moments; one held by the reading
/// thread itself never is.
#[derive(Default)]
struct LockObserver {
    endpoint: OnceLock<Weak<EndpointInner>>,
    reads: AtomicUsize,
    under_lock: AtomicUsize,
}

impl LockObserver {
    fn watch(&self, endpoint: &Endpoint) {
        _ = self.endpoint.set(Arc::downgrade(&endpoint.inner.0));
    }

    fn read(&self) {
        let Some(endpoint) = self.endpoint.get().and_then(Weak::upgrade) else {
            return;
        };
        self.reads.fetch_add(1, Ordering::SeqCst);
        let free = (0..200).any(|_| {
            endpoint.state.try_lock().is_some() || {
                thread::sleep(Duration::from_millis(1));
                false
            }
        });
        if !free {
            self.under_lock.fetch_add(1, Ordering::SeqCst);
        }
    }
}

struct GatedServer {
    inner: Arc<dyn crypto::ServerConfig>,
    gate: Arc<Gate>,
    observer: Arc<LockObserver>,
}

impl GatedServer {
    fn start(
        &self,
        start: impl FnOnce() -> Result<Box<dyn Session>, TransportError>,
    ) -> Result<Box<dyn Session>, TransportError> {
        if self.gate.pass() == Release::Fail {
            return Err(TransportError::INTERNAL_ERROR("session start refused"));
        }
        Ok(Box::new(ObservedSession {
            inner: start()?,
            observer: self.observer.clone(),
        }))
    }
}

impl crypto::InitialServerConfig for GatedServer {
    fn initial_keys(
        &self,
        version: Version,
        dst_cid: &ConnectionId,
    ) -> Result<Keys, InitialKeysError> {
        self.inner.initial_keys(version, dst_cid)
    }

    fn retry_tag(
        &self,
        version: Version,
        orig_dst_cid: &ConnectionId,
        packet: &[u8],
    ) -> Result<[u8; 16], CryptoError> {
        self.inner.retry_tag(version, orig_dst_cid, packet)
    }
}

impl crypto::ServerConfig for GatedServer {
    fn start_session(
        self: Arc<Self>,
        version: Version,
        params: &TransportParameters,
    ) -> Result<Box<dyn Session>, TransportError> {
        self.start(|| self.inner.clone().start_session(version, params))
    }

    fn supports_compatible_negotiation(&self) -> bool {
        self.inner.supports_compatible_negotiation()
    }

    fn start_negotiated_session(
        self: Arc<Self>,
        original: Version,
        negotiated: Version,
        params: &TransportParameters,
    ) -> Result<Box<dyn Session>, TransportError> {
        self.start(|| {
            self.inner
                .clone()
                .start_negotiated_session(original, negotiated, params)
        })
    }
}

/// A server session that reports each handshake read to its observer.
struct ObservedSession {
    inner: Box<dyn Session>,
    observer: Arc<LockObserver>,
}

impl Session for ObservedSession {
    fn initial_keys(
        &self,
        version: Version,
        dst_cid: &ConnectionId,
        side: Side,
    ) -> Result<Keys, TransportError> {
        self.inner.initial_keys(version, dst_cid, side)
    }

    fn switch_version(&mut self, version: Version) -> Result<(), UnsupportedVersion> {
        self.inner.switch_version(version)
    }

    fn handshake_summary(&self) -> Option<NegotiatedTlsParameters> {
        self.inner.handshake_summary()
    }

    fn negotiated_alpn(&self) -> Option<&[u8]> {
        self.inner.negotiated_alpn()
    }

    fn negotiated_key_exchange_group(&self) -> Option<u16> {
        self.inner.negotiated_key_exchange_group()
    }

    fn early_crypto(&self) -> Option<(Box<dyn HeaderKey>, Box<dyn PacketKey>)> {
        self.inner.early_crypto()
    }

    fn early_data_accepted(&self) -> Option<bool> {
        self.inner.early_data_accepted()
    }

    fn is_handshaking(&self) -> bool {
        self.inner.is_handshaking()
    }

    fn poll_pending_callbacks(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Result<Option<bool>, TransportError> {
        self.inner.poll_pending_callbacks(cx)
    }

    fn cancel_pending_callbacks(&mut self) {
        self.inner.cancel_pending_callbacks();
    }

    fn read_handshake(&mut self, level: SpaceId, buf: &[u8]) -> Result<bool, TransportError> {
        self.observer.read();
        self.inner.read_handshake(level, buf)
    }

    fn transport_parameters(&self) -> Result<Option<TransportParameters>, TransportError> {
        self.inner.transport_parameters()
    }

    fn poll_handshake(&mut self) -> Result<Option<HandshakeEvent>, TransportError> {
        self.inner.poll_handshake()
    }

    fn next_1rtt_keys(&mut self) -> Result<Option<KeyPair<Box<dyn PacketKey>>>, TransportError> {
        self.inner.next_1rtt_keys()
    }

    fn is_valid_retry(&self, orig_dst_cid: &ConnectionId, header: &[u8], payload: &[u8]) -> bool {
        self.inner.is_valid_retry(orig_dst_cid, header, payload)
    }

    fn export_keying_material(
        &self,
        output: &mut [u8],
        label: &[u8],
        context: &[u8],
    ) -> Result<(), ExportKeyingMaterialError> {
        self.inner.export_keying_material(output, label, context)
    }
}

/// A client configuration offering `padding` ALPN protocols before the one the server speaks,
/// and a server configuration whose session starts pass `gate`.
fn gated_with(
    gate: &Arc<Gate>,
    observer: &Arc<LockObserver>,
    padding: u32,
) -> (ClientConfig, ServerConfig) {
    let auth = ServerAuthData::new_generated(GeneratedServerAuthConfig::default()).unwrap();
    let alpn = ApplicationProtocol::from(b"shutdown-test".as_slice());
    let offered = (0..padding)
        .map(|n| ApplicationProtocol::from(n.to_be_bytes().to_vec()))
        .chain([alpn.clone()])
        .collect();
    let client = TlsClientConfig::new()
        .with_alpn(offered)
        .try_with_server_trust_anchors([auth.cert_chain.last().unwrap().clone()])
        .unwrap();
    let server = TlsServerConfig::new()
        .with_alpn([alpn].into_iter().collect())
        .with_server_auth(auth);
    let client = ClientConfig::try_from_rama_tls(&client, crate::test_helpers::options()).unwrap();
    let mut server =
        ServerConfig::try_from_rama_tls(&server, crate::test_helpers::options()).unwrap();
    server.crypto = ServerCrypto::Fixed(Arc::new(GatedServer {
        inner: server.crypto.into_fixed(),
        gate: gate.clone(),
        observer: observer.clone(),
    }));
    (client, server)
}

fn gated(gate: &Arc<Gate>, observer: &Arc<LockObserver>) -> (ClientConfig, ServerConfig) {
    gated_with(gate, observer, 0)
}

fn server_endpoint(server: ServerConfig, handshake_timeout: Duration) -> Endpoint {
    let mut config = EndpointConfig::try_with_rand_key().unwrap();
    config.handshake_timeout(handshake_timeout).unwrap();
    endpoint_with(config, Some(server), loopback_socket())
}

/// Take the next attempt and accept it off the runtime; returns once its session start is
/// held by the gate.
async fn accept_held(
    server: &Endpoint,
    gate: &Arc<Gate>,
) -> JoinHandle<Result<Connecting, ConnectionError>> {
    let incoming = tokio::time::timeout(LIMIT, server.accept())
        .await
        .unwrap()
        .unwrap();
    let accept = tokio::task::spawn_blocking(move || incoming.accept());
    gate.holding().await;
    accept
}

fn accepting(endpoint: &Endpoint) -> usize {
    endpoint.inner.state.lock().accepting
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn established_traffic_flows_while_an_accept_runs_its_handshake() {
    let (gate, observer) = (Arc::default(), Arc::default());
    let (client_config, server_config) = gated(&gate, &observer);
    let server = server_endpoint(server_config, LIMIT);
    let client = endpoint(None, Executor::new(), Duration::from_secs(1));
    let address = server.local_addr().unwrap();
    let connecting = client
        .connect_with(client_config.clone(), address, "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(LIMIT, server.accept())
        .await
        .unwrap()
        .unwrap();
    let (established_client, established_server) = handshake(connecting, incoming).await;

    let opener = gate.close();
    let fresh = client
        .connect_with(client_config, address, "localhost")
        .unwrap();
    let accept = accept_held(&server, &gate).await;
    assert_eq!(accepting(&server), 1);
    exchange(
        &established_client,
        &established_server,
        b"routed during a handshake",
    )
    .await;
    exchange(&established_server, &established_client, b"both ways").await;
    assert_eq!(
        gate.held(),
        1,
        "traffic flowed while the accept was still held"
    );
    assert_eq!(
        server.open_connections(),
        1,
        "the accept is not a connection yet"
    );

    opener.open(Release::Start);
    let connecting = accept.await.unwrap().unwrap();
    let (fresh, accepted) = tokio::time::timeout(LIMIT, async { tokio::join!(fresh, connecting) })
        .await
        .unwrap();
    let (_fresh, _accepted) = (fresh.unwrap(), accepted.unwrap());
    assert_eq!(accepting(&server), 0);
    assert_eq!(server.open_connections(), 2);
    tokio::join!(client.shutdown(), server.shutdown());
}

/// An accept between its phases may still become a connection, so the endpoint is not idle;
/// one that then fails was the last thing keeping it from idle, and no Drained event follows.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_accept_between_phases_keeps_the_endpoint_from_idle() {
    for release in [Release::Start, Release::Fail] {
        let (gate, observer) = (Arc::default(), Arc::default());
        let (client_config, server_config) = gated(&gate, &observer);
        let server = server_endpoint(server_config, LIMIT);
        let client = endpoint(None, Executor::new(), Duration::from_secs(1));
        let opener = gate.close();
        let connecting = client
            .connect_with(client_config, server.local_addr().unwrap(), "localhost")
            .unwrap();
        let accept = accept_held(&server, &gate).await;
        assert_eq!(server.open_connections(), 0, "{release:?}");
        assert_eq!(server.stats().handshakes_in_progress, 1, "{release:?}");

        let woken = Arc::new(WakeFlag::default());
        let waker = Waker::from(woken.clone());
        let mut idle = pin!(server.wait_idle());
        assert!(
            idle.as_mut()
                .poll(&mut Context::from_waker(&waker))
                .is_pending(),
            "{release:?}: an accept between phases is not idle"
        );

        opener.open(release);
        let accepted = accept.await.unwrap();
        if release == Release::Fail {
            assert_matches!(accepted, Err(ConnectionError::TransportError(_)));
            tokio::time::timeout(LIMIT, woken.fired()).await.unwrap();
            tokio::time::timeout(LIMIT, idle).await.unwrap();
            assert_eq!(server.stats().handshakes_in_progress, 0);
            drop(connecting);
        } else {
            let (client_conn, server_conn) =
                tokio::time::timeout(LIMIT, async { tokio::join!(connecting, accepted.unwrap()) })
                    .await
                    .unwrap();
            let (client_conn, server_conn) = (client_conn.unwrap(), server_conn.unwrap());
            assert!(
                idle.as_mut()
                    .poll(&mut Context::from_waker(&waker))
                    .is_pending(),
                "a connection is open"
            );
            client_conn.close(0u32, b"done");
            _ = tokio::time::timeout(LIMIT, server_conn.closed())
                .await
                .unwrap();
            tokio::time::timeout(LIMIT, idle).await.unwrap();
        }
        assert_eq!(accepting(&server), 0, "{release:?}");
        tokio::join!(client.shutdown(), server.shutdown());
    }
}

#[derive(Debug, Clone, Copy)]
enum Stop {
    Close,
    Shutdown,
    DriverLost,
    SocketFailed,
}

/// Whatever stops the endpoint, or the attempt's socket, while an accept is between its phases
/// refuses the accept once it resumes: nothing is registered, its admission is released, and
/// the endpoint can go idle.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stopping_between_phases_refuses_the_accept_and_releases_it() {
    for stop in [
        Stop::Close,
        Stop::Shutdown,
        Stop::DriverLost,
        Stop::SocketFailed,
    ] {
        let (gate, observer) = (Arc::default(), Arc::default());
        let (client_config, server_config) = gated(&gate, &observer);
        let (socket, _sends, receive_fault, _sent) = breakable_socket(None);
        let mut endpoint_config = EndpointConfig::try_with_rand_key().unwrap();
        endpoint_config.handshake_timeout(LIMIT).unwrap();
        let server = endpoint_with(endpoint_config, Some(server_config), socket);
        let client = endpoint(None, Executor::new(), Duration::from_secs(1));
        let opener = gate.close();
        let connecting = client
            .connect_with(client_config, server.local_addr().unwrap(), "localhost")
            .unwrap();
        let accept = accept_held(&server, &gate).await;

        let woken = Arc::new(WakeFlag::default());
        let waker = Waker::from(woken.clone());
        let mut idle = pin!(server.wait_idle());
        assert!(
            idle.as_mut()
                .poll(&mut Context::from_waker(&waker))
                .is_pending(),
            "{stop:?}"
        );
        match stop {
            Stop::Close => server.close(0u32, b"stop"),
            Stop::Shutdown => assert_eq!(
                tokio::time::timeout(LIMIT, server.shutdown())
                    .await
                    .unwrap(),
                ShutdownOutcome::Drained,
                "shutdown completes while the accept is held"
            ),
            Stop::DriverLost => {
                fail_receiver(&server, &receive_fault);
                wait_until(|| server.inner.state.lock().driver_lost).await;
            }
            Stop::SocketFailed => {
                let received_on = super::super::active_socket_id(&server);
                server
                    .rebind_std_socket(std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap())
                    .unwrap();
                fail_receiver(&server, &receive_fault);
                wait_until(|| {
                    server
                        .inner
                        .state
                        .lock()
                        .sockets
                        .live()
                        .is_some_and(|sockets| !sockets.is_usable(received_on))
                })
                .await;
            }
        }

        opener.open(Release::Start);
        assert_matches!(
            accept.await.unwrap(),
            Err(ConnectionError::LocallyClosed),
            "{stop:?}"
        );
        tokio::time::timeout(LIMIT, woken.fired()).await.unwrap();
        tokio::time::timeout(LIMIT, idle).await.unwrap();
        {
            let state = server.inner.state.lock();
            assert_eq!(state.accepting, 0, "{stop:?}");
            assert_eq!(state.inner.pending_incoming(), 0, "{stop:?}");
            assert_eq!(state.inner.open_connections(), 0, "{stop:?}");
            assert_eq!(state.inner.admission_load(Instant::now()).0, 0, "{stop:?}");
        }
        drop(connecting);
        tokio::join!(client.shutdown(), server.shutdown());
    }
}

/// An attempt whose deadline passes while its accept is between phases expires like any
/// other: its admission is released then, and the accept times out when it resumes.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_accept_outliving_its_deadline_between_phases_times_out() {
    let (gate, observer) = (Arc::default(), Arc::default());
    let (client_config, server_config) = gated(&gate, &observer);
    let server = server_endpoint(server_config, Duration::from_millis(300));
    let client = endpoint(None, Executor::new(), Duration::from_secs(1));
    let opener = gate.close();
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let accept = accept_held(&server, &gate).await;
    wait_until(|| server.stats().expired_incoming == 1).await;
    assert_eq!(server.stats().handshakes_in_progress, 0);
    assert_eq!(server.inner.state.lock().inner.pending_incoming(), 0);

    opener.open(Release::Start);
    assert_matches!(accept.await.unwrap(), Err(ConnectionError::TimedOut));
    assert_eq!(server.open_connections(), 0);
    assert_eq!(accepting(&server), 0);
    tokio::time::timeout(LIMIT, server.wait_idle())
        .await
        .unwrap();
    drop(connecting);
    tokio::join!(client.shutdown(), server.shutdown());
}

/// Handshake work that unwinds between the phases still ends the accept: idle waiters are
/// woken at once, and the attempt's admission is released at its deadline.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_handshake_unwinding_between_phases_settles_the_accept() {
    let (gate, observer) = (Arc::default(), Arc::default());
    let (client_config, server_config) = gated(&gate, &observer);
    let server = server_endpoint(server_config, Duration::from_millis(300));
    let client = endpoint(None, Executor::new(), Duration::from_secs(1));
    let opener = gate.close();
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let accept = accept_held(&server, &gate).await;
    let woken = Arc::new(WakeFlag::default());
    let waker = Waker::from(woken.clone());
    let mut idle = pin!(server.wait_idle());
    assert!(
        idle.as_mut()
            .poll(&mut Context::from_waker(&waker))
            .is_pending()
    );

    opener.open(Release::Unwind);
    assert!(accept.await.unwrap_err().is_panic());
    tokio::time::timeout(LIMIT, woken.fired()).await.unwrap();
    tokio::time::timeout(LIMIT, idle).await.unwrap();
    assert_eq!(accepting(&server), 0);
    wait_until(|| server.stats().handshakes_in_progress == 0).await;
    assert_eq!(server.inner.state.lock().inner.pending_incoming(), 0);
    drop(connecting);
    tokio::join!(client.shutdown(), server.shutdown());
}

/// The server reads the client's handshake data without the endpoint lock, including the rest
/// of a ClientHello that spans several Initials and was buffered before the accept began: that
/// read is where the server builds and signs its first flight.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn no_handshake_data_is_read_under_the_endpoint_lock() {
    let (gate, observer) = (Arc::<Gate>::default(), Arc::<LockObserver>::default());
    // Enough ALPN protocols for the ClientHello to span several Initials.
    let (client_config, server_config) = gated_with(&gate, &observer, 300);
    let server = server_endpoint(server_config, LIMIT);
    observer.watch(&server);
    let client = endpoint(None, Executor::new(), Duration::from_secs(1));
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(LIMIT, server.accept())
        .await
        .unwrap()
        .unwrap();
    // The rest of the ClientHello is buffered before the accept begins.
    wait_until(|| server.inner.state.lock().inner.incoming_buffer_bytes() > 0).await;
    let (client_conn, server_conn) = tokio::time::timeout(LIMIT, async {
        tokio::join!(connecting, incoming.accept().unwrap())
    })
    .await
    .unwrap();
    let (_client_conn, _server_conn) = (client_conn.unwrap(), server_conn.unwrap());
    assert!(observer.reads.load(Ordering::SeqCst) >= 2);
    assert_eq!(observer.under_lock.load(Ordering::SeqCst), 0);
    tokio::join!(client.shutdown(), server.shutdown());
}
