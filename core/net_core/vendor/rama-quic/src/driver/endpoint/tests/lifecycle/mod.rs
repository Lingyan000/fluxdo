//! Connection and endpoint lifecycle tests.

use std::{
    assert_matches,
    collections::VecDeque,
    net::{IpAddr, Ipv4Addr},
    num::NonZeroUsize,
    sync::atomic::AtomicBool,
    task::Wake,
};

use rama_core::extensions::ExtensionsRef;
use rama_crypto::hmac::HmacSha2;
use rama_net::stream::SocketInfo;
use rama_quic_proto::Version;
use rama_tls::{
    client::{NegotiatedTlsParameters, TlsClientConfig},
    server::{GeneratedServerAuthConfig, ServerAuthData, TlsServerConfig},
};
use rama_udp::{DatagramCapabilities, DatagramError, DatagramSender, DatagramSocket};

use super::{Captured, TestSocket, WakeCount, pin_active_socket, release_lease};
use crate::{
    driver::{
        connection::{MAX_TRANSMIT_DATAGRAMS, MAX_TRANSMIT_SEGMENTS, RETAINED_DESCRIPTORS},
        endpoint::*,
        lifecycle::ShutdownOutcome,
        queue::{MIN_RETAINED, QUIET_DRAINS_BEFORE_SHRINK},
        sockets::MAX_RETAINED_SOCKETS,
    },
    proto::{CongestionControl, RetryRefused, TransportConfig},
};

pub(super) fn configs() -> (ClientConfig, ServerConfig) {
    configs_with_options(crate::test_helpers::options())
}

pub(super) fn configs_with_options(
    options: crate::tls::TlsOptions,
) -> (ClientConfig, ServerConfig) {
    let auth = ServerAuthData::new_generated(GeneratedServerAuthConfig::default()).unwrap();
    let alpn = || {
        [rama_net::tls::ApplicationProtocol::from(
            b"shutdown-test".as_slice(),
        )]
        .into_iter()
        .collect()
    };
    let client = TlsClientConfig::new()
        .with_alpn(alpn())
        .try_with_server_trust_anchors([auth.cert_chain.last().unwrap().clone()])
        .unwrap();
    let server = TlsServerConfig::new()
        .with_alpn(alpn())
        .with_server_auth(auth);
    (
        ClientConfig::try_from_rama_tls(&client, options).unwrap(),
        ServerConfig::try_from_rama_tls(&server, options).unwrap(),
    )
}

fn endpoint(config: Option<ServerConfig>, executor: Executor, budget: Duration) -> Endpoint {
    let socket =
        Socket::from_std(std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap()).unwrap();
    Endpoint::new_with_advertised(
        EndpointConfig::try_with_rand_key().unwrap(),
        config,
        socket,
        Vec::new(),
        executor,
        budget,
    )
    .unwrap()
}

fn deadline_endpoint(config: Option<ServerConfig>, timeout: Duration) -> Endpoint {
    let socket =
        Socket::from_std(std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap()).unwrap();
    let mut endpoint_config = EndpointConfig::try_with_rand_key().unwrap();
    endpoint_config.handshake_timeout(timeout).unwrap();
    Endpoint::new_with_advertised(
        endpoint_config,
        config,
        socket,
        Vec::new(),
        Executor::new(),
        Duration::from_millis(10),
    )
    .unwrap()
}

fn limited_config(
    handshake_timeout: Duration,
    connection: ReceiveQueueLimits,
    endpoint: ReceiveQueueLimits,
) -> EndpointConfig {
    let mut config = EndpointConfig::try_with_rand_key().unwrap();
    config.handshake_timeout(handshake_timeout).unwrap();
    config.set_receive_queue_limits(connection, endpoint);
    config
}

fn small_limits() -> (ReceiveQueueLimits, ReceiveQueueLimits) {
    (
        ReceiveQueueLimits::new(4, 4 * (1500 + PACKET_OVERHEAD)).unwrap(),
        ReceiveQueueLimits::new(16, 16 * (1500 + INCOMING_OVERHEAD)).unwrap(),
    )
}

pub(super) fn endpoint_with(
    config: EndpointConfig,
    server: Option<ServerConfig>,
    socket: Socket,
) -> Endpoint {
    Endpoint::new_with_advertised(
        config,
        server,
        socket,
        Vec::new(),
        Executor::new(),
        Duration::from_secs(1),
    )
    .unwrap()
}

fn loopback_socket() -> Socket {
    Socket::from_std(std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap()).unwrap()
}

/// The receive budget of the endpoint's only connection.
fn connection_budget(endpoint: &Endpoint) -> PacketBudget {
    let state = endpoint.inner.state.lock();
    let mut channels = state.recv_state.connections.channels.values();
    let budget = channels.next().expect("one connection").budget.clone();
    assert!(channels.next().is_none(), "exactly one connection expected");
    budget
}

/// Hold every slot of `budget`, as queued but unprocessed packets would.
///
/// Exactly the configured slot count is taken, so no synthetic rejection is ever counted
/// and every later drop on the budget is a real received datagram.
fn saturate(budget: &PacketBudget) -> Vec<PacketPermit> {
    let held: Vec<_> = (0..budget.limits().datagrams())
        .map(|_| budget.reserve(0).expect("slot within the configured limit"))
        .collect();
    assert_eq!(budget.stats().queued_datagrams, budget.limits().datagrams());
    held
}

#[derive(Debug, Clone, Copy)]
enum Fault {
    TooLarge,
    Refused,
}

/// A real UDP socket whose senders fail the next queued faults before passing sends
/// through, and persistently reject datagrams larger than `max_payload` as too large.
#[derive(Debug)]
struct FaultySocket {
    inner: rama_udp::UdpPacketSocket,
    faults: Arc<Mutex<VecDeque<Fault>>>,
    max_payload: Arc<AtomicUsize>,
    /// Datagrams successfully handed to the network stack.
    sent: Arc<AtomicUsize>,
    /// Advertise a single send segment so one send is one datagram.
    single_segment: bool,
    /// While closed, sends stay `Pending` (the waker is kept and woken on open).
    gate: Arc<SendGate>,
    /// Injected receive failure: at once, or right after the next successful batch.
    recv_fault: Arc<Mutex<Option<RecvFault>>>,
    /// Reports every send handle's destruction and the locks held at that moment.
    probe: Option<Arc<SenderProbe>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum RecvFault {
    Now,
    AfterNextBatch,
}

/// Counts destroyed send handles and those destroyed while the endpoint lock or any
/// connection lock was held: such a destructor would block a real socket's teardown. The
/// check is nonblocking, so a violation fails the test instead of wedging it.
#[derive(Debug, Default)]
pub(super) struct SenderProbe {
    endpoint: std::sync::OnceLock<std::sync::Weak<EndpointInner>>,
    drops: AtomicUsize,
    under_lock: AtomicUsize,
}

impl SenderProbe {
    fn attach(&self, endpoint: &Endpoint) {
        let _installed = self.endpoint.set(Arc::downgrade(&endpoint.inner.0));
    }

    fn record(&self) {
        self.drops.fetch_add(1, Ordering::SeqCst);
        let Some(endpoint) = self.endpoint.get().and_then(std::sync::Weak::upgrade) else {
            return;
        };
        match endpoint.state.try_lock() {
            None => {
                self.under_lock.fetch_add(1, Ordering::SeqCst);
            }
            Some(state) => {
                for channel in state.recv_state.connections.channels.values() {
                    if channel.inner.state.try_lock().is_none() {
                        self.under_lock.fetch_add(1, Ordering::SeqCst);
                    }
                }
            }
        }
    }
}

/// Holds a socket's sends pending until opened; deterministic "socket not ready" state.
#[derive(Debug, Default)]
pub(super) struct SendGate {
    closed: AtomicBool,
    /// While set, only datagrams for this address are held; the rest go through.
    only: Mutex<Option<SocketAddress>>,
    wakers: Mutex<Vec<Waker>>,
    /// Sends that were held at least once.
    held: AtomicUsize,
}

impl SendGate {
    fn close(&self) {
        *self.only.lock() = None;
        self.closed.store(true, Ordering::SeqCst);
    }

    /// Hold only what is addressed to `destination`, so the rest of the connection keeps
    /// working while one datagram waits.
    fn close_for(&self, destination: SocketAddress) {
        *self.only.lock() = Some(destination);
        self.closed.store(true, Ordering::SeqCst);
    }

    fn open(&self) {
        *self.only.lock() = None;
        self.closed.store(false, Ordering::SeqCst);
        for waker in self.wakers.lock().drain(..) {
            waker.wake();
        }
    }

    #[expect(
        clippy::needless_pass_by_ref_mut,
        reason = "the sender trait this stands in for takes the poll context by exclusive reference"
    )]
    fn hold(&self, cx: &mut Context<'_>, destination: SocketAddress) -> bool {
        if !self.closed.load(Ordering::SeqCst) {
            return false;
        }
        if self.only.lock().is_some_and(|only| only != destination) {
            return false;
        }
        self.held.fetch_add(1, Ordering::Relaxed);
        self.wakers.lock().push(cx.waker().clone());
        true
    }
}

impl rama_net::stream::Socket for FaultySocket {
    fn local_addr(&self) -> io::Result<SocketAddress> {
        self.inner.local_addr()
    }

    fn peer_addr(&self) -> io::Result<SocketAddress> {
        self.inner.peer_addr()
    }
}

impl DatagramSocket for FaultySocket {
    type Sender = FaultySender;
    fn create_sender(&self) -> FaultySender {
        FaultySender {
            inner: self.inner.create_sender(),
            faults: self.faults.clone(),
            max_payload: self.max_payload.clone(),
            sent: self.sent.clone(),
            single_segment: self.single_segment,
            gate: self.gate.clone(),
            probe: self.probe.clone(),
        }
    }

    fn poll_recv(
        &mut self,
        cx: &mut Context<'_>,
        buffers: &mut [IoSliceMut<'_>],
        metadata: &mut [DatagramMetadata],
    ) -> Poll<Result<usize, DatagramError>> {
        let fault = *self.recv_fault.lock();
        if fault == Some(RecvFault::Now) {
            return Poll::Ready(Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "injected receive fault",
            )
            .into()));
        }
        let result = self.inner.poll_recv(cx, buffers, metadata);
        if fault == Some(RecvFault::AfterNextBatch) && matches!(result, Poll::Ready(Ok(_))) {
            *self.recv_fault.lock() = Some(RecvFault::Now);
        }
        result
    }

    fn capabilities(&self) -> DatagramCapabilities {
        let mut caps = self.inner.capabilities();
        if self.single_segment {
            caps.max_send_segments = 1;
        }
        caps
    }
}

#[derive(Debug)]
struct FaultySender {
    inner: rama_udp::UdpPacketSender,
    faults: Arc<Mutex<VecDeque<Fault>>>,
    max_payload: Arc<AtomicUsize>,
    sent: Arc<AtomicUsize>,
    single_segment: bool,
    gate: Arc<SendGate>,
    probe: Option<Arc<SenderProbe>>,
}

impl Drop for FaultySender {
    fn drop(&mut self) {
        if let Some(probe) = &self.probe {
            probe.record();
        }
    }
}

impl DatagramSender for FaultySender {
    fn poll_send(
        &mut self,
        cx: &mut Context<'_>,
        datagram: &rama_udp::SendDatagram<'_>,
    ) -> Poll<Result<(), DatagramError>> {
        if self.gate.hold(cx, datagram.destination()) {
            return Poll::Pending;
        }
        let largest_datagram = datagram
            .segment_size()
            .map_or(datagram.payload().len(), |size| {
                size.get().min(datagram.payload().len())
            });
        if largest_datagram > self.max_payload.load(Ordering::Relaxed) {
            return Poll::Ready(Err(rama_udp::test_utils::message_too_large_error().into()));
        }
        let fault = self.faults.lock().pop_front();
        match fault {
            Some(Fault::TooLarge) => {
                Poll::Ready(Err(rama_udp::test_utils::message_too_large_error().into()))
            }
            Some(Fault::Refused) => Poll::Ready(Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "injected refusal",
            )
            .into())),
            None => {
                let result = self.inner.poll_send(cx, datagram);
                if matches!(result, Poll::Ready(Ok(()))) {
                    self.sent.fetch_add(1, Ordering::Relaxed);
                }
                result
            }
        }
    }

    fn capabilities(&self) -> DatagramCapabilities {
        let mut caps = self.inner.capabilities();
        if self.single_segment {
            caps.max_send_segments = 1;
        }
        caps
    }
}

fn faulty_endpoint(server: Option<ServerConfig>, faults: Arc<Mutex<VecDeque<Fault>>>) -> Endpoint {
    faulty_endpoint_with_threshold(server, faults, Arc::new(AtomicUsize::new(usize::MAX)))
}

fn faulty_endpoint_with_threshold(
    server: Option<ServerConfig>,
    faults: Arc<Mutex<VecDeque<Fault>>>,
    max_payload: Arc<AtomicUsize>,
) -> Endpoint {
    let std_socket = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    std_socket.set_nonblocking(true).unwrap();
    let inner = rama_udp::UdpPacketSocket::from_socket(
        tokio::net::UdpSocket::from_std(std_socket).unwrap(),
    )
    .unwrap();
    // MTU discovery is only active when the socket prevents fragmentation.
    assert!(
        !inner.capabilities().may_fragment,
        "this host's UDP socket must set don't-fragment for the PMTU tests"
    );
    let socket = Socket::new(FaultySocket {
        inner,
        faults,
        max_payload,
        sent: Arc::new(AtomicUsize::new(0)),
        single_segment: false,
        gate: Arc::default(),
        recv_fault: Arc::default(),
        probe: None,
    })
    .unwrap();
    endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), server, socket)
}

/// A real loopback socket whose sends can be held pending through the returned gate.
fn gated_socket() -> (Socket, Arc<SendGate>) {
    let (socket, gate, _fault, _sent) = breakable_socket(None);
    (socket, gate)
}

/// A real loopback socket, one datagram per send, whose sends can be held pending through
/// the gate, whose receive path can be failed on demand, and whose send handles report
/// their destruction to `probe`.
pub(super) fn breakable_socket(
    probe: Option<Arc<SenderProbe>>,
) -> (
    Socket,
    Arc<SendGate>,
    Arc<Mutex<Option<RecvFault>>>,
    Arc<AtomicUsize>,
) {
    let std_socket = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    std_socket.set_nonblocking(true).unwrap();
    let inner = rama_udp::UdpPacketSocket::from_socket(
        tokio::net::UdpSocket::from_std(std_socket).unwrap(),
    )
    .unwrap();
    let gate = Arc::new(SendGate::default());
    let recv_fault = Arc::new(Mutex::new(None));
    let sent = Arc::new(AtomicUsize::new(0));
    let socket = Socket::new(FaultySocket {
        inner,
        faults: Arc::new(Mutex::new(VecDeque::new())),
        max_payload: Arc::new(AtomicUsize::new(usize::MAX)),
        sent: sent.clone(),
        single_segment: true,
        gate: gate.clone(),
        recv_fault: recv_fault.clone(),
        probe,
    })
    .unwrap();
    (socket, gate, recv_fault, sent)
}

/// Fail `socket`'s receive path and make sure the endpoint driver looks at it.
pub(super) fn fail_receiver(endpoint: &Endpoint, fault: &Mutex<Option<RecvFault>>) {
    *fault.lock() = Some(RecvFault::Now);
    endpoint.inner.state.lock().wake_driver();
}

/// The next attempt from `port` whose address is validated (a Retry token was presented);
/// retransmitted token-less Initials and other peers' attempts are ignored.
async fn accept_validated_from(server: &Endpoint, port: u16) -> Incoming {
    for _ in 0..16 {
        let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
            .await
            .unwrap()
            .unwrap();
        if incoming.remote_address().port() == port && incoming.remote_address_validated() {
            return incoming;
        }
        incoming.ignore();
    }
    panic!("no validated attempt from port {port}");
}

/// Complete the handshake for `connecting` against `incoming` and wait until the client has
/// confirmed it (HANDSHAKE_DONE received), all within a bounded time. Confirmation, not
/// completion, is what active migration requires.
pub(super) async fn handshake(
    connecting: Connecting,
    incoming: Incoming,
) -> (
    crate::driver::connection::Connection,
    crate::driver::connection::Connection,
) {
    let (c, s) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(connecting, incoming.accept().unwrap())
    })
    .await
    .expect("handshake");
    let (c, s) = (c.unwrap(), s.unwrap());
    tokio::time::timeout(Duration::from_secs(5), c.handshake_confirmed())
        .await
        .expect("handshake confirmation")
        .unwrap();
    (c, s)
}

/// The client's current destination connection ID, as it appears on the wire.
fn active_dcid(c: &crate::driver::connection::Connection) -> Vec<u8> {
    c.active_dcid()
}

/// Destination connection IDs of the short-header datagrams in `sent`, in order.
fn short_header_dcids(sent: &[SentDatagram], len: usize) -> Vec<Vec<u8>> {
    sent.iter()
        .filter(|d| d.bytes.first().is_some_and(|b| b & 0x80 == 0))
        .filter_map(|d| d.bytes.get(1..1 + len).map(<[u8]>::to_vec))
        .collect()
}

/// Send `payload` on a fresh unidirectional stream from `from` and read it back on `to`.
pub(super) async fn exchange(
    from: &crate::driver::connection::Connection,
    to: &crate::driver::connection::Connection,
    payload: &[u8],
) {
    let mut stream = from.open_uni().await.unwrap();
    stream.write_all(payload).await.unwrap();
    stream.finish().unwrap();
    let mut stream = tokio::time::timeout(Duration::from_secs(5), to.accept_uni())
        .await
        .unwrap()
        .unwrap();
    let data = tokio::time::timeout(Duration::from_secs(5), stream.read_to_end(payload.len()))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(data, payload);
}

/// A waker that records having been woken, and lets a test await that.
#[derive(Default)]
struct WakeFlag {
    woken: AtomicBool,
    notify: tokio::sync::Notify,
}

impl WakeFlag {
    async fn fired(&self) {
        loop {
            // Register before reading the flag, and use a notification that keeps a permit, so a
            // wake between the two is not lost.
            let notified = self.notify.notified();
            if self.woken.load(Ordering::SeqCst) {
                return;
            }
            notified.await;
        }
    }
}

impl std::task::Wake for WakeFlag {
    fn wake(self: Arc<Self>) {
        self.wake_by_ref();
    }

    fn wake_by_ref(self: &Arc<Self>) {
        self.woken.store(true, Ordering::SeqCst);
        self.notify.notify_one();
    }
}

/// Wait until `condition` holds; returns how long it took.
pub(super) async fn wait_for(
    what: &str,
    limit: Duration,
    mut condition: impl FnMut() -> bool,
) -> Duration {
    let started = Instant::now();
    tokio::time::timeout(limit, async {
        while !condition() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("{what}: not within {limit:?}"));
    started.elapsed()
}

/// Like [`wait_for`], but the failure carries what the caller can say about what it was waiting
/// on, so a timeout says more than that time passed.
pub(super) async fn wait_for_with(
    what: &str,
    limit: Duration,
    mut condition: impl FnMut() -> bool,
    state: impl Fn() -> String,
) -> Duration {
    let started = Instant::now();
    tokio::time::timeout(limit, async {
        while !condition() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("{what}: not within {limit:?}; {}", state()));
    started.elapsed()
}

/// A real loopback endpoint whose socket counts sent datagrams and sends one segment at a time.
fn counting_endpoint(server: Option<ServerConfig>, sent: Arc<AtomicUsize>) -> Endpoint {
    let std_socket = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    std_socket.set_nonblocking(true).unwrap();
    let inner = rama_udp::UdpPacketSocket::from_socket(
        tokio::net::UdpSocket::from_std(std_socket).unwrap(),
    )
    .unwrap();
    let socket = Socket::new(FaultySocket {
        inner,
        faults: Arc::new(Mutex::new(VecDeque::new())),
        max_payload: Arc::new(AtomicUsize::new(usize::MAX)),
        sent,
        single_segment: true,
        gate: Arc::default(),
        recv_fault: Arc::default(),
        probe: None,
    })
    .unwrap();
    endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), server, socket)
}

/// Keep application data flowing from `client` to `server` until `done` holds or the
/// deadline passes; returns whether `done` was reached.
async fn drive_until(
    client: &crate::driver::connection::Connection,
    server: &crate::driver::connection::Connection,
    deadline: Duration,
    mut done: impl FnMut() -> bool,
) -> bool {
    let payload = vec![0x42u8; octets::kib(32)];
    // The outer deadline also bounds a stream operation that never completes.
    tokio::time::timeout(deadline, async {
        while !done() {
            let mut send = client.open_uni().await.unwrap();
            send.write_all(&payload).await.unwrap();
            send.finish().unwrap();
            let mut recv = server.accept_uni().await.unwrap();
            assert_eq!(
                recv.read_to_end(payload.len()).await.unwrap().len(),
                payload.len()
            );
        }
    })
    .await
    .is_ok()
}

/// A handle to a Tokio runtime that has already shut down: spawning through it destroys
/// the submitted future inline, exactly as the shared spawn path sees during shutdown.
fn stopped_runtime_handle() -> tokio::runtime::Handle {
    // Built and dropped off the test runtime: a runtime cannot be dropped inside one.
    std::thread::spawn(|| {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let handle = runtime.handle().clone();
        drop(runtime);
        handle
    })
    .join()
    .unwrap()
}

/// Pause every submitter between registration and tracking until the guard drops; the
/// guard reopens the gate and removes the hook on drop, including during a panic unwind.
struct SubmitGate {
    lifecycle: Lifecycle,
    gate: Arc<(parking_lot::Mutex<bool>, parking_lot::Condvar)>,
}

impl SubmitGate {
    fn close(lifecycle: &Lifecycle) -> Self {
        let gate = Arc::new((parking_lot::Mutex::new(false), parking_lot::Condvar::new()));
        let waiter = gate.clone();
        lifecycle.set_submit_hook(Some(Arc::new(move || {
            let mut open = waiter.0.lock();
            while !*open {
                waiter.1.wait(&mut open);
            }
        })));
        Self {
            lifecycle: lifecycle.clone(),
            gate,
        }
    }
}

impl Drop for SubmitGate {
    fn drop(&mut self) {
        self.lifecycle.set_submit_hook(None);
        *self.gate.0.lock() = true;
        self.gate.1.notify_all();
    }
}

/// Run an async scenario on its own multi-thread runtime living on a detached thread, and
/// wait for the result with an outer deadline from the plain test thread. If anything in
/// the scenario wedges (a re-entered mutex, a stuck driver), the deadline fails the test
/// while the runtime and its threads are simply abandoned: no teardown ever touches them.
fn detached_scenario<T, F>(what: &str, scenario: impl FnOnce() -> F + Send + 'static) -> T
where
    T: Send + 'static,
    F: std::future::Future<Output = T>,
{
    let (result, done) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .unwrap();
        let output = runtime.block_on(scenario());
        // A healthy scenario tears its runtime down here; a wedged one blocks this thread
        // forever while the outer deadline fails the test without touching it.
        drop(runtime);
        let _sent = result.send(output);
    });
    done.recv_timeout(Duration::from_secs(20))
        .unwrap_or_else(|_| panic!("{what} did not complete: a lock cycle or hang"))
}

/// Run a blocking call on a detached thread (with the given runtime entered) and wait for
/// its result with an outer deadline. A wedged call leaks the thread instead of hanging
/// the runtime's teardown; the caller must not touch the wedged endpoint afterwards.
async fn watchdog<T: Send + 'static>(
    what: &str,
    handle: tokio::runtime::Handle,
    call: impl FnOnce() -> T + Send + 'static,
) -> T {
    let (result, done) = tokio::sync::oneshot::channel();
    std::thread::spawn(move || {
        let _entered = handle.enter();
        let _sent = result.send(call());
    });
    tokio::time::timeout(Duration::from_secs(3), done)
        .await
        .unwrap_or_else(|_| panic!("{what} did not return: lock re-entered during spawn"))
        .expect("watchdog thread panicked")
}

async fn wait_until(mut condition: impl FnMut() -> bool) {
    tokio::time::timeout(Duration::from_secs(3), async {
        while !condition() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn handshake_deadline_runs_without_polling_connecting() {
    let mut client_config = configs().0;
    let mut transport = crate::TransportConfig::default();
    transport.maybe_set_max_idle_timeout(None);
    client_config.set_transport_config(Arc::new(transport));
    let blackhole = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let endpoint = deadline_endpoint(None, Duration::from_millis(100));
    let connecting = endpoint
        .connect_with(client_config, blackhole.local_addr().unwrap(), "localhost")
        .unwrap();
    assert_eq!(endpoint.open_connections(), 1);
    wait_until(|| endpoint.open_connections() == 0).await;
    assert_matches!(connecting.await, Err(ConnectionError::TimedOut));
    assert_eq!(endpoint.shutdown().await, ShutdownOutcome::Drained);
}

#[tokio::test]
async fn admission_expires_without_polling_accept() {
    let (client_config, server_config) = configs();
    let server = deadline_endpoint(Some(server_config), Duration::from_millis(300));
    let client = deadline_endpoint(None, Duration::from_secs(2));
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    wait_until(|| server.inner.state.lock().inner.pending_incoming() == 1).await;
    wait_until(|| server.inner.state.lock().stats.expired_incoming > 0).await;
    {
        let state = server.inner.state.lock();
        assert_eq!(state.inner.pending_incoming(), 0);
        assert_eq!(state.inner.incoming_buffer_bytes(), 0);
        assert!(state.recv_state.incoming.is_empty());
        assert!(state.inner.poll_incoming_timeout().is_none());
    }
    drop(connecting);
    tokio::join!(client.shutdown(), server.shutdown());
}

#[tokio::test]
async fn held_incoming_expires_and_late_accept_fails() {
    let (client_config, server_config) = configs();
    let server = deadline_endpoint(Some(server_config), Duration::from_millis(300));
    let client = deadline_endpoint(None, Duration::from_secs(2));
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(1), server.accept())
        .await
        .unwrap()
        .unwrap();
    wait_until(|| server.inner.state.lock().stats.expired_incoming > 0).await;
    assert!(incoming.is_expired());
    assert!(!incoming.may_retry());
    assert_matches!(incoming.accept(), Err(ConnectionError::TimedOut));
    assert_eq!(server.inner.state.lock().inner.pending_incoming(), 0);
    drop(connecting);
    tokio::join!(client.shutdown(), server.shutdown());
}

#[tokio::test]
async fn shutdown_retires_held_incoming_before_reporting_completion() {
    let (client_config, server_config) = configs();
    let server = deadline_endpoint(Some(server_config), Duration::from_secs(2));
    let client = deadline_endpoint(None, Duration::from_secs(2));
    let address = server.local_addr().unwrap();
    let connecting = client
        .connect_with(client_config, address, "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(1), server.accept())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(server.shutdown().await, ShutdownOutcome::Drained);
    assert_eq!(server.inner.state.lock().inner.pending_incoming(), 0);
    assert!(incoming.is_expired());
    assert_matches!(incoming.accept(), Err(ConnectionError::LocallyClosed));
    let _rebound = std::net::UdpSocket::bind(address).unwrap();
    drop(connecting);
    client.shutdown().await;
}

#[tokio::test]
async fn completed_handshake_cancels_deadline() {
    let (mut client_config, mut server_config) = configs();
    let mut transport = crate::TransportConfig::default();
    transport.maybe_set_max_idle_timeout(None);
    let transport = Arc::new(transport);
    client_config.set_transport_config(transport.clone());
    server_config.set_transport_config(transport);
    let deadline = Duration::from_millis(300);
    let server = deadline_endpoint(Some(server_config), deadline);
    let client = deadline_endpoint(None, deadline);
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let (client_conn, server_conn) = tokio::time::timeout(Duration::from_secs(1), async {
        tokio::join!(connecting, async { server.accept().await.unwrap().await })
    })
    .await
    .unwrap();
    let client_conn = client_conn.unwrap();
    let server_conn = server_conn.unwrap();
    tokio::time::sleep(deadline * 2).await;
    assert!(client_conn.close_reason().is_none());
    assert!(server_conn.close_reason().is_none());
    tokio::join!(client.shutdown(), server.shutdown());
}

#[tokio::test]
async fn invalid_handshake_deadlines_fail_before_spawning() {
    let mut config = EndpointConfig::try_with_rand_key().unwrap();
    config
        .handshake_timeout(Duration::ZERO)
        .expect_err("a zero handshake timeout is refused");
    for duration in [Duration::ZERO, Duration::MAX] {
        config.handshake_timeout = duration;
        let socket =
            Socket::from_std(std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap()).unwrap();
        let error = Endpoint::new_with_advertised(
            config.clone(),
            None,
            socket,
            Vec::new(),
            Executor::new(),
            Duration::from_secs(1),
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
    }
}

#[tokio::test]
async fn idle_shutdown_releases_socket_with_retained_handles() {
    let endpoint = endpoint(Some(configs().1), Executor::new(), Duration::from_secs(1));
    let clone = endpoint.clone();
    let addr = endpoint.local_addr().unwrap();
    let (outcome, accepted) = tokio::time::timeout(Duration::from_secs(2), async {
        tokio::join!(endpoint.shutdown(), clone.accept())
    })
    .await
    .unwrap();
    assert_eq!(outcome, ShutdownOutcome::Drained);
    assert!(accepted.is_none());
    assert_eq!(clone.shutdown().await, outcome);
    assert_eq!(endpoint.inner.shared.ref_count.load(Ordering::Relaxed), 2);
    drop(clone.clone());
    assert_eq!(endpoint.inner.shared.ref_count.load(Ordering::Relaxed), 2);
    assert_eq!(
        clone.local_addr().unwrap_err().kind(),
        io::ErrorKind::NotConnected
    );
    let _rebound = std::net::UdpSocket::bind(addr).unwrap();
}

#[tokio::test]
async fn graceful_executor_joins_without_guard_cycles() {
    let shutdown = rama_core::graceful::Shutdown::no_signal();
    let endpoint = endpoint(
        Some(configs().1),
        Executor::graceful(shutdown.guard()),
        Duration::from_secs(1),
    );
    let addr = endpoint.local_addr().unwrap();
    let clone = endpoint.clone();
    tokio::time::timeout(Duration::from_secs(2), shutdown.shutdown())
        .await
        .unwrap();
    assert_eq!(endpoint.shutdown().await, ShutdownOutcome::Drained);
    assert!(clone.accept().await.is_none());
    let _rebound = std::net::UdpSocket::bind(addr).unwrap();
}

/// A shutdown that starts when its sender fires.
fn triggered_shutdown() -> (
    tokio::sync::oneshot::Sender<()>,
    rama_core::graceful::Shutdown,
) {
    let (trigger, triggered) = tokio::sync::oneshot::channel::<()>();
    let shutdown = rama_core::graceful::Shutdown::new(async move {
        _ = triggered.await;
    });
    (trigger, shutdown)
}

/// Two client connections to `server` on an endpoint stopped by `shutdown`'s cancellation,
/// with the server's ends kept open.
async fn graceful_client_pair(
    client_config: &ClientConfig,
    server: &Endpoint,
    shutdown: &rama_core::graceful::Shutdown,
    budget: Duration,
) -> (
    Endpoint,
    crate::driver::connection::Connection,
    crate::driver::connection::Connection,
    Vec<crate::driver::connection::Connection>,
) {
    let client = endpoint(None, Executor::graceful(shutdown.guard()), budget);
    let mut connections = Vec::new();
    let mut server_sides = Vec::new();
    for _ in 0..2 {
        let connecting = client
            .connect_with(
                client_config.clone(),
                server.local_addr().unwrap(),
                "localhost",
            )
            .unwrap();
        let (connection, server_side) = handshake(connecting, server.accept().await.unwrap()).await;
        connections.push(connection);
        server_sides.push(server_side);
    }
    let leased = connections.pop().unwrap();
    let plain = connections.pop().unwrap();
    (client, plain, leased, server_sides)
}

/// A graceful shutdown closes an unleased connection at once and a leased one once its lease
/// is dropped; the shutdown then completes within its budget.
#[tokio::test]
async fn graceful_shutdown_closes_a_leased_connection_after_its_lease() {
    tokio::time::timeout(Duration::from_secs(10), async {
        let (client_config, server_config) = configs();
        let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
        let (trigger, shutdown) = triggered_shutdown();
        let (client, plain, leased, _server_sides) =
            graceful_client_pair(&client_config, &server, &shutdown, Duration::from_secs(4)).await;
        let lease = leased.close_lease();
        _ = trigger.send(());
        let stopping = tokio::spawn(shutdown.shutdown());
        tokio::time::timeout(Duration::from_millis(500), plain.closed())
            .await
            .expect("the unleased connection closes at once");
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(leased.close_reason().is_none(), "closed under its lease");
        drop(lease);
        assert_matches!(
            tokio::time::timeout(Duration::from_millis(500), leased.closed())
                .await
                .expect("the leased connection closes once let go"),
            ConnectionError::LocallyClosed
        );
        stopping.await.unwrap();
        assert_eq!(client.open_connections(), 0);
    })
    .await
    .unwrap();
}

/// A lease never dropped holds the close for half the shutdown budget, not past it; an
/// explicit shutdown does not wait for leases at all.
#[tokio::test]
async fn a_held_lease_delays_only_a_graceful_close_and_within_its_budget() {
    tokio::time::timeout(Duration::from_secs(10), async {
        let (client_config, server_config) = configs();
        let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
        let (trigger, shutdown) = triggered_shutdown();
        let (_client, _plain, leased, _server_sides) =
            graceful_client_pair(&client_config, &server, &shutdown, Duration::from_secs(1)).await;
        let _lease = leased.close_lease();
        let started = tokio::time::Instant::now();
        _ = trigger.send(());
        let stopping = tokio::spawn(shutdown.shutdown());
        leased.closed().await;
        let waited = started.elapsed();
        assert!(
            waited >= Duration::from_millis(400) && waited < Duration::from_secs(1),
            "{waited:?}"
        );
        stopping.await.unwrap();

        let (_trigger, explicit) = triggered_shutdown();
        let (client, _plain, leased, _explicit_server_sides) =
            graceful_client_pair(&client_config, &server, &explicit, Duration::from_secs(4)).await;
        let _lease = leased.close_lease();
        assert_eq!(client.shutdown().await, ShutdownOutcome::Drained);
        assert!(leased.close_reason().is_some());
    })
    .await
    .unwrap();
}

/// Each leased connection closes as soon as its own lease goes, whatever other leases remain.
#[tokio::test]
async fn each_leased_connection_closes_when_its_own_lease_goes() {
    tokio::time::timeout(Duration::from_secs(10), async {
        let (client_config, server_config) = configs();
        let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
        let (trigger, shutdown) = triggered_shutdown();
        let (_client, first, second, _server_sides) =
            graceful_client_pair(&client_config, &server, &shutdown, Duration::from_secs(4)).await;
        let first_lease = first.close_lease();
        let second_lease = second.close_lease();
        _ = trigger.send(());
        let stopping = tokio::spawn(shutdown.shutdown());
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(first.close_reason().is_none() && second.close_reason().is_none());
        drop(first_lease);
        tokio::time::timeout(Duration::from_millis(500), first.closed())
            .await
            .expect("closed once its own lease went");
        assert!(second.close_reason().is_none(), "closed under its lease");
        drop(second_lease);
        tokio::time::timeout(Duration::from_millis(500), second.closed())
            .await
            .expect("closed once its own lease went");
        stopping.await.unwrap();
    })
    .await
    .unwrap();
}

/// An explicit shutdown during a graceful one's lease wait closes the leased connections at
/// once.
#[tokio::test]
async fn an_explicit_shutdown_ends_the_lease_wait() {
    tokio::time::timeout(Duration::from_secs(10), async {
        let (client_config, server_config) = configs();
        let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
        let (trigger, shutdown) = triggered_shutdown();
        let (client, _plain, leased, _server_sides) =
            graceful_client_pair(&client_config, &server, &shutdown, Duration::from_secs(8)).await;
        let _lease = leased.close_lease();
        _ = trigger.send(());
        let stopping = tokio::spawn(shutdown.shutdown());
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(leased.close_reason().is_none(), "closed under its lease");
        let started = tokio::time::Instant::now();
        assert_eq!(client.shutdown().await, ShutdownOutcome::Drained);
        assert!(leased.close_reason().is_some());
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "{:?}",
            started.elapsed()
        );
        stopping.await.unwrap();
    })
    .await
    .unwrap();
}

/// An explicit close during a graceful shutdown's lease wait closes the leased connections at
/// once, as [`Endpoint::close`] always does.
#[tokio::test]
async fn an_explicit_close_during_the_lease_wait_closes_leased_connections() {
    tokio::time::timeout(Duration::from_secs(10), async {
        let (client_config, server_config) = configs();
        let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
        let (trigger, shutdown) = triggered_shutdown();
        let (client, _plain, leased, server_sides) =
            graceful_client_pair(&client_config, &server, &shutdown, Duration::from_secs(8)).await;
        let _lease = leased.close_lease();
        _ = trigger.send(());
        let stopping = tokio::spawn(shutdown.shutdown());
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(leased.close_reason().is_none(), "closed under its lease");
        client.close(7u32, b"explicit");
        assert_matches!(
            tokio::time::timeout(Duration::from_millis(500), leased.closed())
                .await
                .expect("an explicit close does not wait for leases"),
            ConnectionError::LocallyClosed
        );
        // The peer learns the caller's code and reason.
        assert_matches!(
            tokio::time::timeout(Duration::from_millis(500), server_sides[1].closed())
                .await
                .expect("the peer learns of the close"),
            ConnectionError::ApplicationClosed(close)
                if close.error_code == VarInt::from_u32(7) && close.reason.as_ref() == b"explicit"
        );
        // Nothing is left to wait for: the graceful shutdown ends well before its lease budget.
        tokio::time::timeout(Duration::from_secs(1), stopping)
            .await
            .expect("no lease wait after an explicit close")
            .unwrap();
    })
    .await
    .unwrap();
}

/// An attempt nobody answers still puts a close on the wire when the endpoint shuts down, and
/// leaves as soon as it has (RFC 9000 §10.2), so even a 1 ms budget is not exceeded; the
/// attempt's unpolled future learns it was closed locally.
#[tokio::test]
async fn forced_shutdown_joins_an_unpolled_connection_attempt() {
    let mut client_config = configs().0;
    let mut transport = crate::TransportConfig::default();
    transport.maybe_set_max_idle_timeout(None);
    client_config.set_transport_config(Arc::new(transport));
    let blackhole = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let endpoint = endpoint(None, Executor::new(), Duration::from_millis(1));
    let addr = endpoint.local_addr().unwrap();
    let connecting = endpoint
        .connect_with(client_config, blackhole.local_addr().unwrap(), "localhost")
        .unwrap();
    tokio::task::yield_now().await;
    let outcome = tokio::time::timeout(Duration::from_secs(1), endpoint.shutdown())
        .await
        .unwrap();
    assert_eq!(outcome, ShutdownOutcome::Drained);
    assert_matches!(connecting.await, Err(ConnectionError::LocallyClosed));
    assert_eq!(endpoint.open_connections(), 0);
    let _rebound = std::net::UdpSocket::bind(addr).unwrap();
}

#[tokio::test]
async fn connected_shutdown_releases_sockets_with_retained_streams() {
    tokio::time::timeout(Duration::from_secs(3), async {
        let (client_config, server_config) = configs();
        let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
        let client = endpoint(None, Executor::new(), Duration::from_secs(1));
        let server_addr = server.local_addr().unwrap();
        let client_addr = client.local_addr().unwrap();
        let connecting = client
            .connect_with(client_config, server_addr, "localhost")
            .unwrap();
        let (client_conn, server_conn) =
            tokio::join!(connecting, async { server.accept().await.unwrap().await });
        let client_conn = client_conn.unwrap();
        let server_conn = server_conn.unwrap();
        let mut send = client_conn.open_uni().await.unwrap();
        send.write_all(b"held stream").await.unwrap();
        let mut recv = server_conn.accept_uni().await.unwrap();
        let (a, b) = tokio::join!(client.shutdown(), server.shutdown());
        assert_eq!((a, b), (ShutdownOutcome::Drained, ShutdownOutcome::Drained));
        send.write_all(b"closed").await.unwrap_err();
        let _read = recv.read_to_end(32).await;
        assert!(client_conn.close_reason().is_some());
        assert!(server_conn.close_reason().is_some());
        assert_eq!(
            (client.open_connections(), server.open_connections()),
            (0, 0)
        );
        let _rebound_client = std::net::UdpSocket::bind(client_addr).unwrap();
        let _rebound_server = std::net::UdpSocket::bind(server_addr).unwrap();
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn queued_incoming_attempt_is_charged_until_the_application_takes_it() {
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let client = endpoint(None, Executor::new(), Duration::from_secs(1));
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    wait_until(|| server.stats().receive_queue.queued_datagrams == 1).await;
    let queued = server.stats().receive_queue;
    assert!(queued.queued_bytes >= INCOMING_OVERHEAD);
    assert!(
        server.stats().incoming_queue_capacity >= 1,
        "a queued attempt occupies the incoming container"
    );
    assert_eq!(
        queued.queued_bytes,
        1200 + INCOMING_OVERHEAD,
        "one padded Initial plus the incoming overhead"
    );
    let incoming = server.accept().await.unwrap();
    let stats = server.stats();
    assert_eq!(stats.receive_queue.queued_datagrams, 0);
    assert_eq!(stats.receive_queue.queued_bytes, 0);
    assert!(stats.received_datagrams >= 1);
    assert_eq!(stats.truncated_receive_entries, 0);
    assert_eq!((stats.dropped_responses, stats.failed_responses), (0, 0));
    let (client_conn, server_conn) = tokio::join!(connecting, incoming);
    client_conn.unwrap();
    server_conn.unwrap();
    // Identifiers the engine asked for during the handshake were delivered synchronously.
    assert!(
        server.inner.state.lock().inner.known_cids() > 1,
        "NeedIdentifiers must reach the endpoint and issue CIDs"
    );
    tokio::join!(client.shutdown(), server.shutdown());
}

#[tokio::test]
async fn closed_endpoint_refuses_new_connects_and_accepts() {
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let client = endpoint(None, Executor::new(), Duration::from_secs(1));
    let connecting = client
        .connect_with(
            client_config.clone(),
            server.local_addr().unwrap(),
            "localhost",
        )
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    // Close without stopping the drivers: the close flag alone must refuse admission.
    server.close(VarInt::from_u32(1), b"closing");
    client.close(VarInt::from_u32(1), b"closing");
    assert_matches!(incoming.accept(), Err(ConnectionError::LocallyClosed));
    assert_matches!(
        client.connect_with(client_config, server.local_addr().unwrap(), "localhost"),
        Err(ConnectError::EndpointStopping),
    );
    assert!(server.accept().await.is_none());
    drop(connecting);
    tokio::join!(client.shutdown(), server.shutdown());
}

#[tokio::test]
async fn close_reaches_a_connection_whose_packet_queue_is_saturated() {
    let (client_config, _) = configs();
    let (connection, endpoint_limits) = small_limits();
    let captured = Captured::default();
    let socket = Socket::new(TestSocket {
        captured: captured.clone(),
        ..TestSocket::default()
    })
    .unwrap();
    let endpoint = endpoint_with(
        limited_config(Duration::from_secs(5), connection, endpoint_limits),
        None,
        socket,
    );
    let connecting = endpoint
        .connect_with(client_config, ([127, 0, 0, 2], 443).into(), "localhost")
        .unwrap();
    wait_until(|| !captured.lock().is_empty()).await;
    let budget = connection_budget(&endpoint);
    let held = saturate(&budget);
    assert_eq!(held.len(), connection.datagrams());

    endpoint.close(VarInt::from_u32(7), b"bye");
    assert_matches!(
        tokio::time::timeout(Duration::from_secs(1), connecting)
            .await
            .expect("close is applied directly, not queued behind packets"),
        Err(ConnectionError::LocallyClosed),
    );
    drop(held);
    assert_eq!(budget.stats().queued_datagrams, 0);
    assert_ne!(endpoint.shutdown().await, ShutdownOutcome::DriverFailed);
    assert_eq!(endpoint.stats().receive_queue.queued_datagrams, 0);
}

/// Endpoint control reaches a connection whose packet queue is saturated. Both test sockets
/// report the same bound address, so the switch is a same-address replacement that needs no
/// migration and happens even before the handshake is confirmed.
#[tokio::test]
async fn rebind_reaches_a_connection_whose_packet_queue_is_saturated() {
    let (client_config, _) = configs();
    let (connection, endpoint_limits) = small_limits();
    let first = Captured::default();
    let socket = Socket::new(TestSocket {
        captured: first.clone(),
        ..TestSocket::default()
    })
    .unwrap();
    let endpoint = endpoint_with(
        limited_config(Duration::from_secs(10), connection, endpoint_limits),
        None,
        socket,
    );
    let connecting = endpoint
        .connect_with(client_config, ([127, 0, 0, 2], 443).into(), "localhost")
        .unwrap();
    wait_until(|| !first.lock().is_empty()).await;
    let budget = connection_budget(&endpoint);
    let held = saturate(&budget);

    let second = Captured::default();
    endpoint
        .rebind_abstract(
            Socket::new(TestSocket {
                captured: second.clone(),
                ..TestSocket::default()
            })
            .unwrap(),
        )
        .unwrap();
    // The next retransmission leaves through the replacement socket.
    wait_until(|| !second.lock().is_empty()).await;
    drop(held);
    endpoint.close(VarInt::from_u32(0), b"");
    connecting.await.unwrap_err();
    assert_ne!(endpoint.shutdown().await, ShutdownOutcome::DriverFailed);
}

#[tokio::test]
async fn saturated_receive_queue_drops_and_the_transfer_still_completes() {
    let (client_config, server_config) = configs();
    let (connection, endpoint_limits) = small_limits();
    let server = endpoint_with(
        limited_config(Duration::from_secs(5), connection, endpoint_limits),
        Some(server_config),
        loopback_socket(),
    );
    let client = endpoint_with(
        limited_config(Duration::from_secs(5), connection, endpoint_limits),
        None,
        loopback_socket(),
    );
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let (client_conn, server_conn) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(connecting, async { server.accept().await.unwrap().await })
    })
    .await
    .unwrap();
    let client_conn = client_conn.unwrap();
    let server_conn = server_conn.unwrap();

    let budget = connection_budget(&client);
    let held = saturate(&budget);
    let connection_baseline = client_conn.driver_stats().receive_queue.dropped_datagrams;
    let endpoint_baseline = client.stats().dropped_packets;
    let payload = vec![0x5a; octets::kib(64)];
    let writer = tokio::spawn({
        let server_conn = server_conn.clone();
        let payload = payload.clone();
        async move {
            let mut stream = server_conn.open_uni().await.unwrap();
            stream.write_all(&payload).await.unwrap();
            stream.finish().unwrap();
        }
    });
    // Wait for real received datagrams to be refused by the full queue.
    wait_until(|| {
        client_conn.driver_stats().receive_queue.dropped_datagrams > connection_baseline
            && client.stats().dropped_packets > endpoint_baseline
    })
    .await;
    let connection_dropped =
        client_conn.driver_stats().receive_queue.dropped_datagrams - connection_baseline;
    let endpoint_dropped = client.stats().dropped_packets - endpoint_baseline;
    assert!(connection_dropped > 0 && endpoint_dropped > 0);
    drop(held);

    let mut stream = tokio::time::timeout(Duration::from_secs(5), client_conn.accept_uni())
        .await
        .expect("retransmissions resume once the queue has room")
        .unwrap();
    let received = tokio::time::timeout(Duration::from_secs(10), stream.read_to_end(payload.len()))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(received, payload);
    writer.await.unwrap();
    // Every refused packet was counted once at the endpoint and once at the connection.
    assert_eq!(
        client.stats().dropped_packets - endpoint_baseline,
        client_conn.driver_stats().receive_queue.dropped_datagrams - connection_baseline
    );
    assert!(client_conn.close_reason().is_none());
    assert_eq!(client_conn.driver_stats().receive_queue.queued_datagrams, 0);
    tokio::join!(client.shutdown(), server.shutdown());
}

#[tokio::test]
async fn refused_packet_storage_is_counted_as_a_receive_drop() {
    let (client_config, server_config) = configs();
    let (connection, endpoint_limits) = small_limits();
    let server = endpoint_with(
        limited_config(Duration::from_secs(5), connection, endpoint_limits),
        Some(server_config),
        loopback_socket(),
    );
    let client = endpoint_with(
        limited_config(Duration::from_secs(5), connection, endpoint_limits),
        None,
        loopback_socket(),
    );
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let (client_conn, server_conn) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(connecting, async { server.accept().await.unwrap().await })
    })
    .await
    .unwrap();
    let client_conn = client_conn.unwrap();
    let server_conn = server_conn.unwrap();

    // Swap the client's channel for a queue that has a live receiver but can never hold
    // an entry: every send is refused as `Full` while the connection budget still accepts
    // the packet. The real sender is kept alive so the driver never sees its queue end.
    let (refusing, _live_receiver) = bounded_queue::<QueuedPacket>(0);
    let real_sender = {
        let mut state = client.inner.state.lock();
        let channel = state
            .recv_state
            .connections
            .channels
            .values_mut()
            .next()
            .expect("one connection");
        std::mem::replace(&mut channel.packets, refusing)
    };
    let budget = connection_budget(&client);
    let connection_baseline = budget.stats().dropped_datagrams;
    let endpoint_baseline = client.stats().dropped_packets;
    let writer = tokio::spawn({
        let server_conn = server_conn.clone();
        async move {
            let mut stream = server_conn.open_uni().await.unwrap();
            stream.write_all(&[0x5a; 4096]).await.unwrap();
            stream.finish().unwrap();
        }
    });
    wait_until(|| client.stats().dropped_packets >= endpoint_baseline + 2).await;
    let endpoint_dropped = client.stats().dropped_packets - endpoint_baseline;
    assert_eq!(
        budget.stats().dropped_datagrams - connection_baseline,
        endpoint_dropped,
        "each refused packet is counted once at the endpoint and once on the connection"
    );
    assert_eq!(
        budget.stats().queued_datagrams,
        0,
        "a refused packet releases its connection charge"
    );
    assert_eq!(client.stats().receive_queue.queued_datagrams, 0);
    // Restore the real channel: the transfer completes from retransmissions.
    {
        let mut state = client.inner.state.lock();
        let channel = state
            .recv_state
            .connections
            .channels
            .values_mut()
            .next()
            .expect("one connection");
        channel.packets = real_sender;
    }
    let mut stream = tokio::time::timeout(Duration::from_secs(5), client_conn.accept_uni())
        .await
        .unwrap()
        .unwrap();
    let received = tokio::time::timeout(Duration::from_secs(10), stream.read_to_end(4096))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(received.len(), 4096);
    writer.await.unwrap();
    assert!(client_conn.close_reason().is_none());
    tokio::join!(client.shutdown(), server.shutdown());
}

#[tokio::test]
async fn an_attempt_that_cannot_widen_its_permit_is_ignored_and_counted() {
    let (client_config, server_config) = configs();
    let (connection, endpoint_limits) = small_limits();
    let server = endpoint_with(
        limited_config(Duration::from_secs(5), connection, endpoint_limits),
        Some(server_config),
        loopback_socket(),
    );
    let client = endpoint_with(
        limited_config(Duration::from_secs(5), connection, endpoint_limits),
        None,
        loopback_socket(),
    );
    // Leave room for the Initial datagram itself but not for the incoming widening.
    let budget = server.inner.state.lock().packet_budget.clone();
    let free = 1200 + PACKET_OVERHEAD + (INCOMING_OVERHEAD - PACKET_OVERHEAD) / 2;
    let held = budget
        .reserve(endpoint_limits.bytes() - free - PACKET_OVERHEAD)
        .unwrap();
    let dropped_baseline = server.stats().dropped_packets;
    let budget_baseline = budget.stats().dropped_datagrams;
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    // The first flight may span several Initial datagrams, all leaving at once: each refused
    // widening is counted once, as the budget's drop.
    wait_until(|| {
        let dropped = server.stats().dropped_packets - dropped_baseline;
        dropped > 0 && budget.stats().dropped_datagrams - budget_baseline == dropped
    })
    .await;
    assert_eq!(
        budget.stats().queued_datagrams,
        1,
        "only the held reservation remains charged"
    );
    assert_eq!(server.stats().incoming_queue_capacity, 0);
    // Once the room is back, the client's retransmitted Initial is admitted.
    drop(held);
    let incoming = tokio::time::timeout(Duration::from_secs(5), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (client_conn, server_conn) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(connecting, incoming)
    })
    .await
    .unwrap();
    client_conn.unwrap();
    server_conn.unwrap();
    tokio::join!(client.shutdown(), server.shutdown());
}

#[tokio::test]
async fn each_admission_guard_alone_refuses_new_connections() {
    let (client_config, server_config) = configs();
    for flag in ["driver_lost", "shutdown"] {
        let server = endpoint(
            Some(server_config.clone()),
            Executor::new(),
            Duration::from_secs(1),
        );
        let client = endpoint(None, Executor::new(), Duration::from_secs(1));
        let connecting = client
            .connect_with(
                client_config.clone(),
                server.local_addr().unwrap(),
                "localhost",
            )
            .unwrap();
        let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
            .await
            .unwrap()
            .unwrap();
        {
            let mut state = server.inner.state.lock();
            match flag {
                "driver_lost" => state.driver_lost = true,
                _ => state.shutdown = true,
            }
        }
        {
            let mut state = client.inner.state.lock();
            match flag {
                "driver_lost" => state.driver_lost = true,
                _ => state.shutdown = true,
            }
        }
        assert_matches!(
            incoming.accept(),
            Err(ConnectionError::LocallyClosed),
            "{flag} alone refuses accept",
        );
        // `shutdown` is only ever set together with `close`, so connect checks the latter.
        if flag == "driver_lost" {
            assert_matches!(
                client.connect_with(
                    client_config.clone(),
                    server.local_addr().unwrap(),
                    "localhost"
                ),
                Err(ConnectError::EndpointStopping),
                "{flag} alone refuses connect",
            );
        }
        drop(connecting);
    }
}

fn queued_attempts(endpoint: &Endpoint) -> usize {
    endpoint.inner.state.lock().recv_state.incoming.len()
}

/// Repeated rebinds A→B→C while a connection's transmit is still pending on A: the pending
/// datagram completes on A, B is superseded before any connection used it, every connection
/// then sends from C (observed by the peer), traffic flows both ways, and A retires once its
/// last sender is gone.
#[tokio::test]
async fn repeated_rebind_switches_connections_after_their_pending_send_and_retires_old_sockets() {
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket_a, gate_a) = gated_socket();
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket_a);
    let addr_a = client.local_addr().unwrap();
    let mut conns = Vec::new();
    for _ in 0..2 {
        let connecting = client
            .connect_with(
                client_config.clone(),
                server.local_addr().unwrap(),
                "localhost",
            )
            .unwrap();
        let (c, s) = tokio::time::timeout(Duration::from_secs(5), async {
            tokio::join!(connecting, async { server.accept().await.unwrap().await })
        })
        .await
        .unwrap();
        conns.push((c.unwrap(), s.unwrap()));
    }
    for (_, s) in &conns {
        assert_eq!(s.remote_address(), addr_a);
    }
    // Hold A's sends: the next client transmit on each connection stays pending on A.
    gate_a.close();
    for (c, _) in &conns {
        let mut stream = c.open_uni().await.unwrap();
        stream.write_all(b"held on A").await.unwrap();
        stream.finish().unwrap();
    }
    wait_until(|| gate_a.held.load(Ordering::Relaxed) >= 2).await;

    let (socket_b, _gate_b) = gated_socket();
    client.rebind_abstract(socket_b).unwrap();
    let addr_b = client.local_addr().unwrap();
    assert_eq!(
        client.stats().retained_sockets,
        2,
        "A is kept for the pending sends"
    );
    let (socket_c, _gate_c) = gated_socket();
    client.rebind_abstract(socket_c).unwrap();
    let addr_c = client.local_addr().unwrap();
    // B was superseded before any connection switched to it: once the connection drivers
    // hand back B's unused senders, B is retired and only A and C remain.
    tokio::time::timeout(Duration::from_secs(3), async {
        wait_until(|| client.stats().retained_sockets == 2).await
    })
    .await
    .expect("the superseded socket B must be retired");
    assert_eq!(client.local_addrs(), vec![addr_c, addr_a]);
    assert!(
        gate_a.held.load(Ordering::Relaxed) >= 2,
        "the sends are still held on A"
    );

    gate_a.open();
    // The held datagrams complete on A (the server reads them from A), then every
    // connection continues from C.
    for (_, s) in &conns {
        let mut stream = tokio::time::timeout(Duration::from_secs(5), s.accept_uni())
            .await
            .unwrap()
            .unwrap();
        let data = tokio::time::timeout(Duration::from_secs(5), stream.read_to_end(64))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(data, b"held on A");
    }
    for (c, s) in &conns {
        let mut stream = s.open_uni().await.unwrap();
        stream.write_all(b"from server").await.unwrap();
        stream.finish().unwrap();
        let mut stream = tokio::time::timeout(Duration::from_secs(5), c.accept_uni())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(stream.read_to_end(64).await.unwrap(), b"from server");
        let mut stream = c.open_uni().await.unwrap();
        stream.write_all(b"from C").await.unwrap();
        stream.finish().unwrap();
        let mut stream = tokio::time::timeout(Duration::from_secs(5), s.accept_uni())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(stream.read_to_end(64).await.unwrap(), b"from C");
    }
    tokio::time::timeout(Duration::from_secs(5), async {
        wait_until(|| conns.iter().all(|(_, s)| s.remote_address() == addr_c)).await
    })
    .await
    .expect("the server must observe the client's new source address");
    assert_ne!(addr_c, addr_b);
    tokio::time::timeout(Duration::from_secs(5), async {
        wait_until(|| client.stats().retained_sockets == 1).await
    })
    .await
    .expect("A retires once its last sender switched");
    assert_eq!(client.stats().retired_sockets, 2);
    tokio::join!(client.shutdown(), server.shutdown());
}

/// Attempts received on A stay answerable on A after the server rebinds A→B→C: accept,
/// Retry, Retry-error retention, refuse and expiry all use A, nothing leaks, and no retained
/// handle keeps a port bound after shutdown. Each attempt comes from its own client endpoint
/// so the server-side handle is matched to its client by remote port.
#[tokio::test]
async fn attempts_received_before_rebinding_are_answered_on_their_own_socket() {
    let (client_config, server_config) = configs();
    let defaults = EndpointConfig::try_with_rand_key().unwrap();
    let server = endpoint_with(
        limited_config(
            Duration::from_secs(3),
            defaults.connection_receive_queue,
            defaults.endpoint_receive_queue,
        ),
        Some(server_config),
        loopback_socket(),
    );
    let addr_a = server.local_addr().unwrap();
    const ROLES: [&str; 6] = [
        "accept",
        "retry",
        "refuse",
        "expire",
        "retry_error",
        "retained",
    ];
    let mut clients = FxHashMap::default();
    let mut connecting = FxHashMap::default();
    for role in ROLES {
        let client = endpoint(None, Executor::new(), Duration::from_secs(1));
        connecting.insert(
            role,
            client
                .connect_with(client_config.clone(), addr_a, "localhost")
                .unwrap(),
        );
        clients.insert(role, client);
    }
    let port_of = |role: &str| clients[role].local_addr().unwrap().port();
    wait_until(|| queued_attempts(&server) == ROLES.len()).await;

    server.rebind_abstract(loopback_socket()).unwrap();
    server.rebind_abstract(loopback_socket()).unwrap();
    let addr_c = server.local_addr().unwrap();
    assert_ne!(addr_c, addr_a);
    assert_eq!(
        server.stats().retained_sockets,
        2,
        "A (queued attempts) and C; B was never depended on"
    );

    // Clients retransmit their Initial while they wait, and a retransmission after the
    // attempt was taken is admitted as a new attempt; those duplicates are ignored here so
    // every role is matched to exactly one handle by remote port. After a Retry only the
    // token-bearing (validated) attempt from that port counts: a retransmission of the
    // original token-less Initial may still arrive first.
    let mut handles: FxHashMap<&str, Incoming> = FxHashMap::default();
    while handles.len() < ROLES.len() {
        let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(incoming.local_ip(), Some(addr_a.ip()));
        let role = ROLES
            .into_iter()
            .find(|role| port_of(role) == incoming.remote_address().port())
            .expect("every attempt belongs to one client");
        if handles.contains_key(role) {
            incoming.ignore();
        } else {
            handles.insert(role, incoming);
        }
    }
    let mut take = |role: &str| handles.remove(role).unwrap();
    let mut await_client = |role: &str| connecting.remove(role).unwrap();

    // accept: the connection is served from A, which the client observes as its peer.
    let i_accept = take("accept");
    assert!(
        !i_accept.remote_address_validated(),
        "a first Initial is unvalidated"
    );
    assert!(
        i_accept.may_retry(),
        "an unvalidated attempt may be retried"
    );
    assert!(!i_accept.is_expired());
    assert_eq!(i_accept.remote_address().port(), port_of("accept"));
    let accepted = i_accept.accept().unwrap();
    let (c, s) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(await_client("accept"), accepted)
    })
    .await
    .expect("handshake via A");
    let (c, s) = (c.unwrap(), s.unwrap());
    assert_eq!(c.remote_address(), addr_a);

    // Retry: leaves from A; the client's token-bearing Initial comes back to A.
    take("retry").retry().unwrap();
    let retried = accept_validated_from(&server, port_of("retry")).await;
    assert!(retried.remote_address_validated());
    assert!(!retried.may_retry());
    let (c2, s2) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(await_client("retry"), retried.accept().unwrap())
    })
    .await
    .expect("handshake via A after Retry");
    let (c2, s2) = (c2.unwrap(), s2.unwrap());
    assert_eq!(c2.remote_address(), addr_a);

    // refuse: the client is told CONNECTION_REFUSED by A.
    take("refuse").refuse();
    let error = tokio::time::timeout(Duration::from_secs(5), await_client("refuse"))
        .await
        .unwrap()
        .unwrap_err();
    assert_matches!(
        error,
        ConnectionError::ConnectionClosed(ref close)
            if close.error_code == rama_quic_proto::TransportErrorCode::CONNECTION_REFUSED,
        "{error:?}",
    );

    // Retry error keeps the attempt (and its socket) with the caller; accepting it works.
    take("retry_error").retry().unwrap();
    let retried_again = accept_validated_from(&server, port_of("retry_error")).await;
    let back = retried_again.retry().unwrap_err();
    assert_eq!(back.reason(), RetryRefused::AlreadyRetried);
    let retried_again = back.into_incoming();
    let (c3, s3) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(await_client("retry_error"), retried_again.accept().unwrap())
    })
    .await
    .expect("handshake via A after a refused Retry");
    let (c3, s3) = (c3.unwrap(), s3.unwrap());
    assert_eq!(c3.remote_address(), addr_a);

    // expiry: an attempt nobody accepts times out and releases everything it held.
    let i_expire = take("expire");
    let expired = tokio::time::timeout(Duration::from_secs(6), async {
        loop {
            if i_expire.is_expired() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await;
    assert!(expired.is_ok(), "the unaccepted attempt did not expire");
    assert_matches!(
        i_expire.accept(),
        Err(ConnectionError::TimedOut | ConnectionError::LocallyClosed),
    );
    assert!(server.stats().expired_incoming >= 1);

    // Every connection still sends from A; A stays retained while they live.
    assert_eq!(server.stats().retained_sockets, 2);
    for (client_conn, server_conn) in [(&c, &s), (&c2, &s2), (&c3, &s3)] {
        let mut stream = server_conn.open_uni().await.unwrap();
        stream.write_all(b"via A").await.unwrap();
        stream.finish().unwrap();
        let mut stream = tokio::time::timeout(Duration::from_secs(5), client_conn.accept_uni())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(stream.read_to_end(16).await.unwrap(), b"via A");
    }
    drop((c, s, c2, s2, c3, s3));
    let i_retained = take("retained");
    drop(connecting);
    // Shutdown with an application-held attempt from A: the ports are free afterwards and
    // the retained handle cannot keep A bound; its later use is a refused no-op.
    for client in clients.values() {
        client.shutdown().await;
    }
    server.shutdown().await;
    let _a = std::net::UdpSocket::bind(addr_a).expect("A's port is free after shutdown");
    let _c = std::net::UdpSocket::bind(addr_c).expect("C's port is free after shutdown");
    assert_matches!(i_retained.accept(), Err(ConnectionError::LocallyClosed));
    let stats = server.stats();
    assert_eq!(
        stats.receive_queue.queued_datagrams, 0,
        "no admission charge leaked"
    );
    assert_eq!(stats.retained_sockets, 0);
    assert_eq!(server.inner.state.lock().inner.pending_incoming(), 0);
}

/// Dropping an application-held attempt refuses it (the client is told CONNECTION_REFUSED),
/// ignoring one answers nothing (the client times out on its own), and both release the
/// attempt's socket dependence so a replaced socket can retire.
#[tokio::test]
async fn dropped_and_ignored_attempts_release_their_socket() {
    let (client_config, server_config) = configs();
    let server = endpoint_with(
        limited_config(
            Duration::from_secs(1),
            EndpointConfig::try_with_rand_key()
                .unwrap()
                .connection_receive_queue,
            EndpointConfig::try_with_rand_key()
                .unwrap()
                .endpoint_receive_queue,
        ),
        Some(server_config),
        loopback_socket(),
    );
    let addr_a = server.local_addr().unwrap();
    let dropper = endpoint(None, Executor::new(), Duration::from_secs(1));
    let ignored = endpoint(None, Executor::new(), Duration::from_secs(1));
    let c_drop = dropper
        .connect_with(client_config.clone(), addr_a, "localhost")
        .unwrap();
    let c_ignore = ignored
        .connect_with(client_config, addr_a, "localhost")
        .unwrap();
    wait_until(|| queued_attempts(&server) == 2).await;
    server.rebind_abstract(loopback_socket()).unwrap();
    assert_eq!(
        server.stats().retained_sockets,
        2,
        "A is kept for the two attempts"
    );
    let mut by_port = FxHashMap::default();
    for _ in 0..2 {
        let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
            .await
            .unwrap()
            .unwrap();
        by_port.insert(incoming.remote_address().port(), incoming);
    }
    let i_drop = by_port
        .remove(&dropper.local_addr().unwrap().port())
        .unwrap();
    let i_ignore = by_port
        .remove(&ignored.local_addr().unwrap().port())
        .unwrap();
    let refused_before = server.stats().refused_handshakes;
    let ignored_before = server.stats().ignored_handshakes;
    drop(i_drop);
    let error = tokio::time::timeout(Duration::from_secs(5), c_drop)
        .await
        .expect("a dropped attempt is refused promptly")
        .unwrap_err();
    assert_matches!(
        error,
        ConnectionError::ConnectionClosed(ref close)
            if close.error_code == rama_quic_proto::TransportErrorCode::CONNECTION_REFUSED,
        "{error:?}",
    );
    assert_eq!(server.stats().refused_handshakes, refused_before + 1);
    i_ignore.ignore();
    assert_eq!(server.stats().ignored_handshakes, ignored_before + 1);
    // Nothing is sent for an ignored attempt: the client only gives up on its own timeout.
    assert!(
        tokio::time::timeout(Duration::from_millis(300), &mut std::pin::pin!(c_ignore))
            .await
            .is_err(),
        "an ignored attempt gets no answer"
    );
    tokio::time::timeout(Duration::from_secs(3), async {
        wait_until(|| server.stats().retained_sockets == 1).await
    })
    .await
    .expect("A retires once both attempts released it");
    assert_eq!(server.stats().retired_sockets, 1);
    assert_eq!(server.stats().receive_queue.queued_datagrams, 0);
    tokio::join!(dropper.shutdown(), ignored.shutdown(), server.shutdown());
}

/// Each rebind while a connection is still pinned to its socket (its Initial held, its
/// handshake unconfirmed) adds a retained socket; at the bound the next rebind is refused and
/// nothing changes. Opening the gates lets the handshakes complete; once confirmed, every
/// client connection migrates to the active socket and the registry drains back to it.
#[tokio::test]
async fn rebinding_past_the_retained_bound_is_refused_without_change() {
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let server_addr = server.local_addr().unwrap();
    let acceptor = server.clone();
    let accepting = tokio::spawn(async move {
        while let Some(incoming) = acceptor.accept().await {
            if let Ok(connecting) = incoming.accept() {
                tokio::spawn(connecting);
            }
        }
    });
    let (socket, gate) = gated_socket();
    gate.close();
    let mut gates = vec![gate];
    let client = endpoint_with(
        limited_config(
            Duration::from_secs(30),
            EndpointConfig::try_with_rand_key()
                .unwrap()
                .connection_receive_queue,
            EndpointConfig::try_with_rand_key()
                .unwrap()
                .endpoint_receive_queue,
        ),
        None,
        socket,
    );
    let mut attempts = Vec::new();
    for round in 1..MAX_RETAINED_SOCKETS {
        attempts.push(
            client
                .connect_with(client_config.clone(), server_addr, "localhost")
                .unwrap(),
        );
        let held = gates.last().unwrap().clone();
        tokio::time::timeout(Duration::from_secs(3), async {
            wait_until(|| held.held.load(Ordering::Relaxed) >= 1).await
        })
        .await
        .unwrap_or_else(|_| {
            panic!(
                "round {round}: no send was held on the active socket: {:?}",
                client.stats()
            )
        });
        let (next, gate) = gated_socket();
        gate.close();
        gates.push(gate);
        client.rebind_abstract(next).unwrap();
        assert_eq!(client.stats().retained_sockets, round + 1);
    }
    assert_eq!(client.stats().retained_sockets, MAX_RETAINED_SOCKETS);
    attempts.push(
        client
            .connect_with(client_config.clone(), server_addr, "localhost")
            .unwrap(),
    );
    let held = gates.last().unwrap().clone();
    tokio::time::timeout(Duration::from_secs(3), async {
        wait_until(|| held.held.load(Ordering::Relaxed) >= 1).await
    })
    .await
    .unwrap_or_else(|_| panic!("final connect: no send was held: {:?}", client.stats()));
    let active = client.local_addr().unwrap();
    let addrs = client.local_addrs();
    let (refused, _gate) = gated_socket();
    let error = client.rebind_abstract(refused).unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::QuotaExceeded);
    assert_eq!(
        client.local_addr().unwrap(),
        active,
        "the active socket is unchanged"
    );
    assert_eq!(client.local_addrs(), addrs, "the retained set is unchanged");
    assert_eq!(client.stats().retained_sockets, MAX_RETAINED_SOCKETS);
    // Opening the gates lets every handshake complete; each confirmed connection then
    // migrates to the active socket.
    for gate in &gates {
        gate.open();
    }
    let drained = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            if client.stats().retained_sockets == 1 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await;
    assert!(
        drained.is_ok(),
        "retiring sockets did not drain: {:?} addrs {:?}",
        client.stats(),
        client.local_addrs()
    );
    assert_eq!(
        client.stats().retired_sockets,
        (MAX_RETAINED_SOCKETS - 1) as u64
    );
    let (again, _gate) = gated_socket();
    client.rebind_abstract(again).unwrap();
    drop(attempts);
    client.close(VarInt::from_u32(0), b"");
    assert_ne!(client.shutdown().await, ShutdownOutcome::DriverFailed);
    server.shutdown().await;
    accepting.abort();
}

/// Two attempts from one client endpoint, connected in sequence so the server's queue order
/// is deterministic: accepting the first while the second stays pending completes the first
/// client's handshake.
#[tokio::test]
async fn first_of_two_queued_attempts_from_one_endpoint_completes_while_the_other_waits() {
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let addr = server.local_addr().unwrap();
    let client = endpoint(None, Executor::new(), Duration::from_secs(1));
    let first = client
        .connect_with(client_config.clone(), addr, "localhost")
        .unwrap();
    wait_until(|| queued_attempts(&server) == 1).await;
    let second = client
        .connect_with(client_config, addr, "localhost")
        .unwrap();
    wait_until(|| queued_attempts(&server) == 2).await;
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let accepted = incoming.accept().unwrap();
    let (c, s) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(first, accepted)
    })
    .await
    .expect("the accepted first attempt's handshake completes while the second waits");
    c.unwrap();
    s.unwrap();
    assert_eq!(
        queued_attempts(&server),
        1,
        "the second attempt is still queued"
    );
    // The second attempt is served afterwards on the same endpoint.
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c2, s2) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(second, incoming.accept().unwrap())
    })
    .await
    .unwrap();
    c2.unwrap();
    s2.unwrap();
    tokio::join!(client.shutdown(), server.shutdown());
}

#[tokio::test]
async fn handshake_deadline_holds_while_the_receive_queue_is_saturated() {
    let (client_config, server_config) = configs();
    let (connection, endpoint_limits) = small_limits();
    let server = endpoint_with(
        limited_config(Duration::from_secs(5), connection, endpoint_limits),
        Some(server_config),
        loopback_socket(),
    );
    let client = endpoint_with(
        limited_config(Duration::from_millis(300), connection, endpoint_limits),
        None,
        loopback_socket(),
    );
    let connecting = client
        .connect_with(
            client_config.clone(),
            server.local_addr().unwrap(),
            "localhost",
        )
        .unwrap();
    let budget = connection_budget(&client);
    let held = saturate(&budget);
    let endpoint_baseline = client.stats().dropped_packets;
    // The server accepts and replies; every reply is refused by the saturated client queue.
    let abandoned = tokio::spawn({
        let server = server.clone();
        async move { server.accept().await.unwrap().await }
    });
    assert_matches!(
        tokio::time::timeout(Duration::from_secs(2), connecting)
            .await
            .unwrap(),
        Err(ConnectionError::TimedOut),
    );
    assert!(
        client.stats().dropped_packets > endpoint_baseline,
        "the server's replies were refused"
    );
    drop(held);
    abandoned.abort();

    // The abandoned attempt may still be queued on the server if the aborted task never
    // got to take it; only the attempt belonging to the new connect completes.
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let (client_conn, server_conn) = tokio::time::timeout(Duration::from_secs(10), async {
        tokio::join!(connecting, async {
            loop {
                let incoming = server.accept().await.unwrap();
                if let Ok(connection) = incoming.await {
                    break connection;
                }
            }
        })
    })
    .await
    .unwrap();
    client_conn.unwrap();
    drop(server_conn);
    tokio::join!(client.shutdown(), server.shutdown());
}

#[tokio::test]
async fn refused_and_oversized_sends_recover_on_real_sockets() {
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let faults = Arc::new(Mutex::new(VecDeque::from([
        Fault::TooLarge,
        Fault::Refused,
    ])));
    let client = faulty_endpoint(None, faults.clone());
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let (client_conn, server_conn) = tokio::time::timeout(Duration::from_secs(10), async {
        tokio::join!(connecting, async { server.accept().await.unwrap().await })
    })
    .await
    .expect("bounded retransmission recovers from two rejected datagrams");
    let client_conn = client_conn.unwrap();
    let server_conn = server_conn.unwrap();
    assert!(faults.lock().is_empty());
    let stats = client_conn.driver_stats();
    assert_eq!((stats.oversized_sends, stats.send_failures), (1, 1));
    assert!(client_conn.close_reason().is_none());

    let mut send = client_conn.open_uni().await.unwrap();
    send.write_all(b"after the faults").await.unwrap();
    send.finish().unwrap();
    let mut recv = server_conn.accept_uni().await.unwrap();
    assert_eq!(recv.read_to_end(64).await.unwrap(), b"after the faults");
    tokio::join!(client.shutdown(), server.shutdown());
}

#[tokio::test]
async fn refused_stateless_response_leaves_the_endpoint_serving_others() {
    let (client_config, server_config) = configs();
    let faults = Arc::new(Mutex::new(VecDeque::from([Fault::Refused])));
    let server = faulty_endpoint(Some(server_config), faults.clone());
    let address = server.local_addr().unwrap();
    // A long header with an unknown version elicits a Version Negotiation response.
    let probe = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    probe
        .send_to(&super::tests::version_negotiation_probe(), address)
        .unwrap();
    wait_until(|| server.stats().failed_responses == 1).await;
    assert!(faults.lock().is_empty());

    let client = endpoint(None, Executor::new(), Duration::from_secs(1));
    let connecting = client
        .connect_with(client_config, address, "localhost")
        .unwrap();
    let (client_conn, server_conn) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(connecting, async { server.accept().await.unwrap().await })
    })
    .await
    .expect("the endpoint keeps serving after a refused response");
    client_conn.unwrap();
    server_conn.unwrap();
    assert_eq!(server.stats().failed_responses, 1);
    assert_eq!(
        tokio::join!(client.shutdown(), server.shutdown()),
        (ShutdownOutcome::Drained, ShutdownOutcome::Drained)
    );
}

#[test]
fn shutdown_reports_failure_and_releases_admissions_when_the_deadline_index_is_lost() {
    // Isolated runtime: a supervisor that spins instead of reporting the failure must fail
    // this test at the inner deadline (with the runtime torn down on success), never hang it.
    detached_scenario("D1 drain scenario", || async {
        let (client_config, server_config) = configs();
        let server = deadline_endpoint(Some(server_config), Duration::from_secs(5));
        let client = deadline_endpoint(None, Duration::from_secs(5));
        let address = server.local_addr().unwrap();
        let connecting = client
            .connect_with(client_config, address, "localhost")
            .unwrap();
        let incoming = tokio::time::timeout(Duration::from_secs(1), server.accept())
            .await
            .unwrap()
            .unwrap();
        server.inner.state.lock().inner.forget_incoming_deadlines();
        let outcome = tokio::time::timeout(Duration::from_secs(5), server.shutdown())
            .await
            .expect("shutdown must finish: the drain guard must report, not spin");
        assert_eq!(outcome, ShutdownOutcome::DriverFailed);
        {
            let state = server.inner.state.lock();
            assert_eq!(state.inner.pending_incoming(), 0);
            assert_eq!(state.inner.incoming_buffer_bytes(), 0);
        }
        assert!(incoming.is_expired());
        assert_matches!(incoming.accept(), Err(ConnectionError::LocallyClosed));
        let _rebound = std::net::UdpSocket::bind(address).unwrap();
        drop(connecting);
        client.shutdown().await;
    });
}

#[tokio::test]
async fn incoming_storage_refusal_after_budget_acceptance_is_counted_once() {
    let (client_config, server_config) = configs();
    let (connection, endpoint_limits) = small_limits();
    let server = endpoint_with(
        limited_config(Duration::from_secs(5), connection, endpoint_limits),
        Some(server_config),
        loopback_socket(),
    );
    let client = endpoint_with(
        limited_config(Duration::from_secs(5), connection, endpoint_limits),
        None,
        loopback_socket(),
    );
    // The budget accepts the packet and the widening; only the container refuses storage.
    server.inner.state.lock().recv_state.incoming.set_limit(0);
    let budget = server.inner.state.lock().packet_budget.clone();
    let drop_baseline = server.stats().dropped_packets;
    let received_baseline = server.stats().received_datagrams;
    let budget_drop_baseline = budget.stats().dropped_datagrams;
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    wait_until(|| server.stats().dropped_packets > drop_baseline).await;
    // The first flight can span several Initial datagrams, sent together (a boring
    // ClientHello does); let all of them land before counting.
    tokio::time::sleep(Duration::from_millis(50)).await;
    let stats = server.stats();
    let dropped = stats.dropped_packets - drop_baseline;
    let received = stats.received_datagrams - received_baseline;
    // Each refused attempt is one drop: datagrams received in one pass join the same attempt,
    // while one received after its refusal is an attempt, and a refusal, of its own.
    assert!(
        (1..=received).contains(&dropped),
        "{dropped} receive drops for {received} datagrams"
    );
    assert_eq!(
        budget.stats().dropped_datagrams,
        budget_drop_baseline,
        "storage refusal is not a quota refusal"
    );
    assert_eq!(
        budget.stats().queued_datagrams,
        0,
        "the permit was released"
    );
    assert_eq!(budget.stats().queued_bytes, 0);
    {
        let state = server.inner.state.lock();
        assert_eq!(state.inner.pending_incoming(), 0, "no admission retained");
        assert_eq!(state.inner.incoming_buffer_bytes(), 0);
        assert!(state.recv_state.incoming.is_empty());
    }
    assert_eq!(server.stats().incoming_queue_capacity, 0);
    // Restoring the container lets the client's retransmitted Initial in.
    server
        .inner
        .state
        .lock()
        .recv_state
        .incoming
        .set_limit(endpoint_limits.datagrams());
    let incoming = tokio::time::timeout(Duration::from_secs(5), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (client_conn, server_conn) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(connecting, incoming)
    })
    .await
    .unwrap();
    client_conn.unwrap();
    server_conn.unwrap();
    assert_eq!(server.stats().dropped_packets, drop_baseline + dropped);
    tokio::join!(client.shutdown(), server.shutdown());
}

/// Records every poll of a wrapped driver future: how many datagrams the observed socket
/// sent during it and whether the driver woke its own task synchronously (a continuation).
struct PollLog {
    sent: Arc<AtomicUsize>,
    in_poll: AtomicBool,
    woke_during_poll: AtomicBool,
    wakes: AtomicUsize,
    records: Mutex<Vec<PollRecord>>,
}

#[derive(Debug, Clone, Copy)]
struct PollRecord {
    /// Datagrams handed to the socket during this poll.
    sent: usize,
    /// The driver called `wake_by_ref` on its own waker while being polled.
    self_wake: bool,
}

impl PollLog {
    fn new(sent: Arc<AtomicUsize>) -> Arc<Self> {
        Arc::new(Self {
            sent,
            in_poll: AtomicBool::new(false),
            woke_during_poll: AtomicBool::new(false),
            wakes: AtomicUsize::new(0),
            records: Mutex::new(Vec::new()),
        })
    }

    fn records(&self) -> Vec<PollRecord> {
        self.records.lock().clone()
    }
}

/// Forwards to the task's real waker while noting wakes that happen during a poll.
struct RecordingWaker {
    inner: Waker,
    log: Arc<PollLog>,
}

impl Wake for RecordingWaker {
    fn wake(self: Arc<Self>) {
        self.wake_by_ref();
    }

    fn wake_by_ref(self: &Arc<Self>) {
        self.log.wakes.fetch_add(1, Ordering::Relaxed);
        if self.log.in_poll.load(Ordering::Relaxed) {
            self.log.woke_during_poll.store(true, Ordering::Relaxed);
        }
        self.inner.wake_by_ref();
    }
}

/// The submitted driver future, polled through a recording waker.
struct Observed {
    inner: crate::driver::lifecycle::DriverFuture,
    log: Arc<PollLog>,
}

impl Future for Observed {
    type Output = ();

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        let log = self.log.clone();
        let waker = Waker::from(Arc::new(RecordingWaker {
            inner: cx.waker().clone(),
            log: log.clone(),
        }));
        let mut cx = Context::from_waker(&waker);
        let before = log.sent.load(Ordering::Relaxed);
        log.woke_during_poll.store(false, Ordering::Relaxed);
        log.in_poll.store(true, Ordering::Relaxed);
        let result = self.inner.as_mut().poll(&mut cx);
        log.in_poll.store(false, Ordering::Relaxed);
        log.records.lock().push(PollRecord {
            sent: log.sent.load(Ordering::Relaxed) - before,
            self_wake: log.woke_during_poll.load(Ordering::Relaxed),
        });
        result
    }
}

/// Wrap the next driver submitted through `lifecycle` so its polls are recorded.
fn observe_next_driver(lifecycle: &Lifecycle, log: Arc<PollLog>) {
    lifecycle.set_submit_wrapper(Some(Arc::new(move |inner| {
        Box::pin(Observed {
            inner,
            log: log.clone(),
        })
    })));
}

/// Per-poll transmit bound and continuation wakes, observed on the real driver task: with
/// one segment per send, a poll never hands more than `MAX_TRANSMIT_DATAGRAMS` datagrams to
/// the socket, and every poll that stops at that bound wakes its own task so the remaining
/// ready work continues because of that wake. A second connection on the same endpoints
/// completes its handshake before the bulk stream is drained.
#[tokio::test]
async fn bulk_transmit_yields_at_the_quota_and_lets_another_connection_progress() {
    let (mut client_config, mut server_config) = configs();
    let transport = Arc::new(
        TransportConfig::default()
            .with_congestion_control(CongestionControl::NewReno)
            .try_with_initial_congestion_window(octets::mib_u64(4))
            .expect("four mebibytes is above the minimum window"),
    );
    client_config.set_transport_config(transport.clone());
    server_config.set_transport_config(transport);
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    // The client socket counts datagrams and advertises a single send segment, so one send
    // is one datagram and the transmit bound is exactly `MAX_TRANSMIT_DATAGRAMS`.
    let sent = Arc::new(AtomicUsize::new(0));
    let client = counting_endpoint(None, sent.clone());
    let log = PollLog::new(sent.clone());
    observe_next_driver(&client.inner.shared.lifecycle, log.clone());
    let connecting = client
        .connect_with(
            client_config.clone(),
            server.local_addr().unwrap(),
            "localhost",
        )
        .unwrap();
    client.inner.shared.lifecycle.set_submit_wrapper(None);
    let (bulk, bulk_server) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(connecting, async { server.accept().await.unwrap().await })
    })
    .await
    .unwrap();
    let bulk = bulk.unwrap();
    let bulk_server = bulk_server.unwrap();

    let payload = vec![0x42u8; octets::mib(2)];
    let writer = tokio::spawn({
        let bulk = bulk.clone();
        let payload = payload.clone();
        async move {
            let mut stream = bulk.open_uni().await.unwrap();
            stream.write_all(&payload).await.unwrap();
            stream.finish().unwrap();
        }
    });
    // Start the second connection after bulk sending begins. The unread stream can exhaust
    // its receive credit here, independently of the larger congestion window.
    wait_until(|| sent.load(Ordering::Relaxed) >= 200).await;
    let other = tokio::time::timeout(Duration::from_secs(5), async {
        let connecting = client
            .connect_with(client_config, server.local_addr().unwrap(), "localhost")
            .unwrap();
        tokio::join!(connecting, async { server.accept().await.unwrap().await })
    })
    .await
    .expect("the second connection must not be starved by the bulk sender");
    other.0.unwrap();
    other.1.unwrap();

    let mut stream = tokio::time::timeout(Duration::from_secs(5), bulk_server.accept_uni())
        .await
        .unwrap()
        .unwrap();
    let received = tokio::time::timeout(Duration::from_secs(20), stream.read_to_end(payload.len()))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(received.len(), payload.len());
    writer.await.unwrap();

    let records = log.records();
    let max_sent = records.iter().map(|r| r.sent).max().unwrap_or(0);
    assert!(
        max_sent <= MAX_TRANSMIT_DATAGRAMS,
        "a poll sent {max_sent} datagrams, above the bound of {MAX_TRANSMIT_DATAGRAMS}"
    );
    let at_bound: Vec<_> = records
        .iter()
        .filter(|r| r.sent == MAX_TRANSMIT_DATAGRAMS)
        .collect();
    assert!(
        !at_bound.is_empty(),
        "the bulk transfer never filled a poll's transmit bound ({} polls, max {max_sent})",
        records.len()
    );
    assert!(
        at_bound.iter().all(|r| r.self_wake),
        "a poll that stopped at the bound did not wake its task: {at_bound:?}"
    );
    tokio::join!(client.shutdown(), server.shutdown());
}

/// An application that keeps its stream open without reading exhausts receive credit.
/// Other connections keep transferring, and reading again wakes the original writer.
#[tokio::test]
async fn a_non_reading_peer_bounds_resources_and_recovers_while_other_connections_progress() {
    const CREDIT: u32 = octets::kib_u32(32);
    const SEND_WINDOW: u64 = octets::kib_u64(64);

    fn resource_probe(endpoint: &Endpoint) -> impl Fn() -> proto::StreamResourceUsage + use<> {
        let state = endpoint.inner.state.lock();
        assert_eq!(state.recv_state.connections.channels.len(), 1);
        let inner = state
            .recv_state
            .connections
            .channels
            .values()
            .next()
            .unwrap()
            .inner
            .clone();
        move || inner.state.lock().inner.streams().resource_usage()
    }

    tokio::time::timeout(Duration::from_secs(20), async {
        let (mut client_config, mut server_config) = configs();
        let transport = Arc::new(
            TransportConfig::default()
                .with_receive_window(CREDIT)
                .with_stream_receive_window(CREDIT)
                .with_send_window(SEND_WINDOW),
        );
        client_config.set_transport_config(transport.clone());
        server_config.set_transport_config(transport);
        let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
        let client = endpoint(None, Executor::new(), Duration::from_secs(1));
        let (bulk, peer) = tokio::join!(
            client
                .connect_with(
                    client_config.clone(),
                    server.local_addr().unwrap(),
                    "localhost"
                )
                .unwrap(),
            async { server.accept().await.unwrap().await.unwrap() }
        );
        let bulk = bulk.unwrap();
        let client_usage = resource_probe(&client);
        let server_usage = resource_probe(&server);
        let payload: Vec<u8> = (0..octets::kib(256)).map(|i| (i % 251) as u8).collect();
        let mut send = bulk.open_uni().await.unwrap();
        send.write_all(&payload[..CREDIT as usize]).await.unwrap();
        let mut recv = peer.accept_uni().await.unwrap();
        // Receipt and acknowledgement distinguish peer credit from congestion or local buffering.
        wait_until(|| {
            server_usage().received_offset == u64::from(CREDIT)
                && client_usage().unacknowledged_bytes == 0
        })
        .await;
        let (blocked_tx, blocked_rx) = tokio::sync::oneshot::channel();
        let writer = tokio::spawn({
            let payload = payload.clone();
            async move {
                {
                    let mut write = std::pin::pin!(send.write_all(&payload[CREDIT as usize..]));
                    std::future::poll_fn(|cx| {
                        assert!(
                            write.as_mut().poll(cx).is_pending(),
                            "unread credit must block the writer"
                        );
                        Poll::Ready(())
                    })
                    .await;
                    blocked_tx.send(()).unwrap();
                    write.await.unwrap();
                }
                send.finish().unwrap();
            }
        });
        blocked_rx.await.unwrap();
        let assert_bounds = || {
            let client_resources = client_usage();
            assert_eq!(client_resources.sent_offset, u64::from(CREDIT));
            assert_eq!(client_resources.peer_credit, u64::from(CREDIT));
            assert!(client_resources.unacknowledged_bytes <= SEND_WINDOW);
            let server_resources = server_usage();
            assert_eq!(server_resources.received_offset, u64::from(CREDIT));
            assert!(server_resources.retained_receive_bytes >= CREDIT as usize);
            // The assembler compacts when allocation overhead exceeds 1.5 times buffered bytes.
            assert!(
                server_resources.retained_receive_bytes <= CREDIT as usize * 5 / 2,
                "receive allocation: {server_resources:?}"
            );
            for conn in [&bulk, &peer] {
                let held = conn.retained_send_bytes();
                let mtu = conn.max_datagram_payload();
                assert!(held.buffer <= 2 * MAX_TRANSMIT_SEGMENTS * mtu);
                assert!(held.owned <= (RETAINED_DESCRIPTORS - 1) * MAX_TRANSMIT_SEGMENTS * mtu);
                assert!(held.slots < RETAINED_DESCRIPTORS);
            }
        };
        assert_bounds();
        // Keep every competing connection alive on the same pair of endpoint drivers.
        let mut others = Vec::new();
        for round in 0..3u8 {
            let (other, other_peer) = tokio::join!(
                client
                    .connect_with(
                        client_config.clone(),
                        server.local_addr().unwrap(),
                        "localhost"
                    )
                    .unwrap(),
                async { server.accept().await.unwrap().await.unwrap() }
            );
            let other = other.unwrap();
            let message = vec![round; octets::kib(4)];
            let mut other_send = other.open_uni().await.unwrap();
            other_send.write_all(&message).await.unwrap();
            other_send.finish().unwrap();
            let mut other_recv = other_peer.accept_uni().await.unwrap();
            assert_eq!(
                other_recv.read_to_end(message.len()).await.unwrap(),
                message
            );
            assert!(!writer.is_finished(), "the unread writer remains blocked");
            assert_bounds();
            others.push((other, other_peer));
            assert_eq!(server.open_connections(), others.len() + 1);
            assert_eq!(client.stats().retained_sockets, 1);
            assert_eq!(server.stats().retained_sockets, 1);
        }
        let received = recv.read_to_end(payload.len()).await.unwrap();
        writer.await.unwrap();
        assert_eq!(received, payload);
        wait_until(|| client_usage().unacknowledged_bytes == 0).await;
        assert_eq!(
            server_usage().retained_receive_bytes,
            0,
            "reading releases the receive allocation"
        );
        tokio::join!(client.shutdown(), server.shutdown());
    })
    .await
    .expect("credit recovery and independent connections complete");
}

/// The endpoint driver's own deadline decision: while an admission is queued and its
/// handshake deadline lies ahead, a poll must not wake itself (no busy re-poll); at the
/// deadline the timer wakes the task and the poll expires and releases the attempt.
#[tokio::test]
async fn queued_admission_deadline_does_not_busy_poll_and_expires_on_time() {
    let (client_config, server_config) = configs();
    let handshake_timeout = Duration::from_millis(300);
    // Unspawned server: the test polls its driver by hand with a recording waker.
    let mut endpoint_config = EndpointConfig::try_with_rand_key().unwrap();
    endpoint_config
        .handshake_timeout(handshake_timeout)
        .unwrap();
    let socket =
        Socket::from_std(std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap()).unwrap();
    let engine = proto::Endpoint::new(
        Arc::new(endpoint_config),
        Some(Arc::new(server_config)),
        false,
        None,
    );
    let server = Endpoint {
        inner: EndpointRef::new(socket, engine, false, u16::MAX, false),
        default_client_config: None,
    };
    let mut driver = std::pin::pin!(EndpointDriver(server.inner.0.clone()));
    let log = PollLog::new(Arc::new(AtomicUsize::new(0)));
    let waker = Waker::from(Arc::new(RecordingWaker {
        inner: Waker::noop().clone(),
        log: log.clone(),
    }));
    let poll = |driver: &mut Pin<&mut EndpointDriver>| {
        let mut cx = Context::from_waker(&waker);
        log.woke_during_poll.store(false, Ordering::Relaxed);
        log.in_poll.store(true, Ordering::Relaxed);
        let result = driver.as_mut().poll(&mut cx);
        log.in_poll.store(false, Ordering::Relaxed);
        (result, log.woke_during_poll.load(Ordering::Relaxed))
    };

    let client = endpoint(None, Executor::new(), Duration::from_secs(1));
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    // Poll until the Initial has been admitted and queued (the application never accepts).
    let started = Instant::now();
    loop {
        let (result, _) = poll(&mut driver);
        assert!(result.is_pending());
        if !server.inner.state.lock().recv_state.incoming.is_empty() {
            break;
        }
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "no attempt was queued"
        );
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    // Deadline ahead: a poll that has no datagram to process must not request a
    // continuation. (A poll that did receive a datagram may legitimately ask for one when
    // the receive work limiter stopped it, so only idle polls are judged.)
    let mut idle_polls = 0;
    let judged_from = Instant::now();
    while idle_polls < 5 {
        let received_before = server.stats().received_datagrams;
        let (result, self_wake) = poll(&mut driver);
        assert!(result.is_pending());
        assert_eq!(server.stats().expired_incoming, 0);
        if server.stats().received_datagrams == received_before {
            assert!(
                !self_wake,
                "the endpoint woke itself although the admission deadline lies ahead"
            );
            idle_polls += 1;
        }
        assert!(
            judged_from.elapsed() < Duration::from_millis(200),
            "could not observe five idle polls before the deadline"
        );
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    // At the deadline the timer wakes the task and the poll expires the attempt.
    let wakes_before = log.wakes.load(Ordering::Relaxed);
    tokio::time::sleep_until((started + handshake_timeout + Duration::from_millis(100)).into())
        .await;
    assert!(
        log.wakes.load(Ordering::Relaxed) > wakes_before,
        "the task was not woken by the deadline"
    );
    let (result, _) = poll(&mut driver);
    assert!(result.is_pending());
    assert_eq!(
        server.stats().expired_incoming,
        1,
        "the queued attempt expired"
    );
    assert!(server.inner.state.lock().recv_state.incoming.is_empty());
    assert_eq!(server.inner.state.lock().inner.pending_incoming(), 0);
    drop(connecting);
    client.shutdown().await;
}

#[tokio::test]
async fn rejected_mtu_probes_settle_below_a_fixed_path_threshold() {
    const THRESHOLD: usize = 1300;
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let threshold = Arc::new(AtomicUsize::new(THRESHOLD));
    let client = faulty_endpoint_with_threshold(
        None,
        Arc::new(Mutex::new(VecDeque::new())),
        threshold.clone(),
    );
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let (client_conn, server_conn) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(connecting, async { server.accept().await.unwrap().await })
    })
    .await
    .unwrap();
    let client_conn = client_conn.unwrap();
    let server_conn = server_conn.unwrap();
    assert_eq!(client_conn.stats().path.current_mtu, 1200);

    // Search until at least one probe size above the threshold was fully given up on and a
    // smaller probe succeeded, then let the remaining search steps run.
    let settled = drive_until(&client_conn, &server_conn, Duration::from_secs(15), || {
        let path = client_conn.stats().path;
        path.lost_plpmtud_probes >= 3 && path.current_mtu > 1200
    })
    .await;
    assert!(
        settled,
        "the MTU search must make progress past rejected probes"
    );
    drive_until(&client_conn, &server_conn, Duration::from_secs(5), || {
        client_conn.stats().path.sent_plpmtud_probes >= 8
    })
    .await;

    let path = client_conn.stats().path;
    let stats = client_conn.driver_stats();
    assert!(
        (1201..=THRESHOLD as u16).contains(&path.current_mtu),
        "current MTU {} must lie in the admitted range",
        path.current_mtu
    );
    // Every oversized send is a rejected probe: at most three transmissions per size and the
    // binary search visits only a few sizes above the threshold.
    assert!(
        (3..=12).contains(&stats.oversized_sends),
        "oversized sends {} must be bounded by the probe schedule",
        stats.oversized_sends
    );
    // Loss detection may still trail the most recent rejected probe by one.
    assert!(
        stats.oversized_sends >= path.lost_plpmtud_probes
            && stats.oversized_sends - path.lost_plpmtud_probes <= 1,
        "rejected probes {} vs probes declared lost {}",
        stats.oversized_sends,
        path.lost_plpmtud_probes
    );
    assert_eq!(stats.send_failures, 0);
    assert_eq!(path.black_holes_detected, 0);
    assert!(client_conn.close_reason().is_none());
    assert!(server_conn.close_reason().is_none());
    assert_eq!(
        tokio::join!(client.shutdown(), server.shutdown()),
        (ShutdownOutcome::Drained, ShutdownOutcome::Drained)
    );
}

/// The path shrinks after a larger MTU was learned: every full-size packet is rejected while
/// smaller ones still pass. Black-hole detection must shrink the MTU within a bounded number
/// of rejected sends and the transfer must complete; unrelated handshakes on the same
/// endpoint keep working.
#[tokio::test]
async fn path_size_decrease_after_a_larger_mtu_was_learned() {
    let (mut client_config, mut server_config) = configs();
    let mut transport = crate::TransportConfig::default();
    transport.set_max_idle_timeout(Duration::from_secs(3).try_into().unwrap());
    let transport = Arc::new(transport);
    client_config.set_transport_config(transport.clone());
    server_config.set_transport_config(transport);
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let threshold = Arc::new(AtomicUsize::new(usize::MAX));
    let client = faulty_endpoint_with_threshold(
        None,
        Arc::new(Mutex::new(VecDeque::new())),
        threshold.clone(),
    );
    let connecting = client
        .connect_with(
            client_config.clone(),
            server.local_addr().unwrap(),
            "localhost",
        )
        .unwrap();
    let (client_conn, server_conn) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(connecting, async { server.accept().await.unwrap().await })
    })
    .await
    .unwrap();
    let client_conn = client_conn.unwrap();
    let server_conn = server_conn.unwrap();
    let learned = drive_until(&client_conn, &server_conn, Duration::from_secs(15), || {
        client_conn.stats().path.current_mtu == 1452
    })
    .await;
    assert!(
        learned,
        "the search must reach the configured upper bound on loopback"
    );

    // The path now admits 1300 bytes at most; every learned-size packet is rejected.
    threshold.store(1300, Ordering::Relaxed);
    let payload = vec![0x42u8; octets::kib(64)];
    let received = tokio::time::timeout(Duration::from_secs(10), async {
        let mut send = client_conn.open_uni().await.unwrap();
        send.write_all(&payload).await.unwrap();
        send.finish().unwrap();
        let mut recv = server_conn.accept_uni().await.unwrap();
        recv.read_to_end(payload.len()).await.unwrap()
    })
    .await
    .expect("black-hole detection must restore progress well within the idle timeout");
    assert_eq!(received.len(), payload.len());
    let path = client_conn.stats().path;
    let stats = client_conn.driver_stats();
    assert!(path.black_holes_detected >= 1);
    assert!(
        path.current_mtu <= 1300,
        "recovery must shrink the MTU, got {}",
        path.current_mtu
    );
    // Rejected sends are bounded by the loss bursts needed to judge a black hole.
    assert!(
        (1..=200).contains(&stats.oversized_sends),
        "oversized sends {} before recovery",
        stats.oversized_sends
    );
    assert!(client_conn.close_reason().is_none());
    // Unrelated: a new handshake on the same endpoint still works at 1200 bytes.
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let (fresh_client, fresh_server) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(connecting, async { server.accept().await.unwrap().await })
    })
    .await
    .unwrap();
    fresh_client.unwrap();
    fresh_server.unwrap();
    drop((client_conn, server_conn));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// RFC 9000 §8.2.1 requires a datagram carrying a PATH_CHALLENGE to be expanded to at least the
/// smallest allowed maximum datagram size, subject to the anti-amplification limit; it sets no
/// upper bound. What this pins is the policy above that requirement: the probe is built as a
/// packet of its own, padded to exactly that size, with nothing coalesced into it.
///
/// Observe this client's accepted sends rather than everything arriving at the destination:
/// parallel tests can leave late traffic for a reused loopback port. The recording socket
/// disables segmentation, so each recorded send is one UDP datagram.
#[tokio::test]
async fn a_path_validation_probe_is_a_dedicated_packet_padded_to_the_smallest_allowed_datagram() {
    let (mut client_config, mut server_config) = configs();
    let silent = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    silent.set_nonblocking(true).unwrap();
    let preferred = match silent.local_addr().unwrap() {
        SocketAddr::V4(addr) => addr,
        SocketAddr::V6(addr) => panic!("expected an IPv4 loopback address, got {addr}"),
    };
    server_config.set_preferred_address_v4(preferred);
    // Without discovery there is no MTU probe to confuse with a challenge.
    let mut transport = crate::TransportConfig::default();
    transport.maybe_set_mtu_discovery_config(None);
    let transport = Arc::new(transport);
    client_config.set_transport_config(transport.clone());
    server_config.set_transport_config(transport);
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket, log) = recording_socket();
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket);
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;

    wait_for(
        "all three probes towards the preferred address",
        Duration::from_secs(5),
        || c.stats().path.preferred_address_probes == 3,
    )
    .await;

    // Model a late packet from another test after the OS reuses a loopback port.
    let unrelated = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    unrelated
        .send_to(b"unrelated loopback traffic", preferred)
        .unwrap();

    // The completed probe sequence makes the send log and counter stable, without a sleep.
    let destination = SocketAddress::from(SocketAddr::from(preferred));
    let sizes: Vec<_> = log
        .lock()
        .sent
        .iter()
        .filter(|datagram| datagram.destination == destination)
        .map(|datagram| datagram.bytes.len())
        .collect();
    assert!(!sizes.is_empty(), "the probes were transmitted");
    assert_eq!(
        sizes.len() as u64,
        c.stats().path.preferred_address_probes,
        "one datagram per transmitted probe, so every size below is one of them"
    );
    for size in &sizes {
        assert_eq!(
            *size,
            usize::from(crate::proto::MIN_INITIAL_SIZE),
            "the probe is a packet of its own padded to the smallest allowed datagram"
        );
    }
    assert_eq!(
        c.stats().path.sent_plpmtud_probes,
        0,
        "and none of these is an MTU probe"
    );

    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// Without MTU discovery, no datagram exceeds the confirmed MTU, including while loss recovery
/// is running. Datagrams are dropped for a while so recovery has work to do, and every datagram
/// the socket was handed is measured on its own; the socket takes one segment at a time, so each
/// record is one UDP datagram rather than a descriptor's aggregate.
///
/// The counters here witness loss activity, not the decision that sends a probe: nothing below
/// identifies which datagram loss recovery chose to send. A direct observation of that decision,
/// and a fault aimed at the size it uses, are open.
#[tokio::test]
async fn no_datagram_exceeds_the_confirmed_mtu_while_loss_recovery_runs() {
    let (mut client_config, mut server_config) = configs();
    let mut transport = crate::TransportConfig::default();
    transport.maybe_set_mtu_discovery_config(None);
    transport.set_max_idle_timeout(Duration::from_secs(10).try_into().unwrap());
    let transport = Arc::new(transport);
    client_config.set_transport_config(transport.clone());
    server_config.set_transport_config(transport);
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket, log) = recording_socket();
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket);
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    let confirmed = usize::from(c.stats().path.current_mtu);

    // Ordinary traffic first.
    let payload = vec![0x37u8; octets::kib(32)];
    tokio::time::timeout(Duration::from_secs(10), async {
        let mut send = c.open_uni().await.unwrap();
        send.write_all(&payload).await.unwrap();
        send.finish().unwrap();
        let mut recv = s.accept_uni().await.unwrap();
        assert_eq!(recv.read_to_end(payload.len()).await.unwrap(), payload);
    })
    .await
    .expect("the transfer completes");

    // Now what the socket is handed never reaches the network, so recovery declares loss and
    // sends its own probes. Those are still recorded here.
    log.lock().blackhole = true;
    let dark_at = c.stats().path.sent_packets;
    let mut send = c.open_uni().await.unwrap();
    send.write_all(b"into the dark").await.unwrap();
    // Nothing is acknowledged while the socket swallows everything, so recovery reaches its
    // timeout and sends probes of its own; those are what grow the sent count here.
    wait_for(
        "recovery timed out and sent probes into the dark",
        Duration::from_secs(10),
        || c.stats().path.sent_packets > dark_at + 2,
    )
    .await;
    log.lock().blackhole = false;
    // Once acknowledgements flow again, what was swallowed is declared lost.
    wait_for(
        "the swallowed packets are declared lost",
        Duration::from_secs(10),
        || c.stats().path.lost_packets > 0,
    )
    .await;

    let recorded = log.lock().sent.len();
    let oversized: Vec<usize> = log
        .lock()
        .sent
        .iter()
        .map(|datagram| datagram.bytes.len())
        .filter(|size| *size > confirmed)
        .collect();
    assert!(recorded > 8, "enough datagrams to judge: {recorded}");
    assert_eq!(
        c.stats().path.sent_plpmtud_probes,
        0,
        "MTU discovery is off, so nothing here may search above the confirmed size"
    );
    assert!(
        oversized.is_empty(),
        "no ordinary or loss-probe datagram exceeds the confirmed MTU of {confirmed}: {oversized:?}"
    );

    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// MTU discovery searches above the confirmed MTU, so the confirmed size is not its limit. What
/// bounds it is the configured search ceiling clamped by the peer's `max_udp_payload_size`. Each
/// recorded datagram is one UDP datagram.
///
/// Which datagram is a probe is not established here: these are sizes on the wire, and telling a
/// probe from ordinary traffic at the moment it is emitted is open work.
#[tokio::test]
async fn mtu_discovery_probes_search_above_the_confirmed_mtu_within_the_configured_ceiling() {
    const CEILING: u16 = 1400;
    let (mut client_config, mut server_config) = configs();
    let mut transport = crate::TransportConfig::default();
    let mut discovery = crate::proto::MtuDiscoveryConfig::default();
    discovery.set_upper_bound(CEILING);
    transport.maybe_set_mtu_discovery_config(Some(discovery));
    transport.set_max_idle_timeout(Duration::from_secs(10).try_into().unwrap());
    let transport = Arc::new(transport);
    client_config.set_transport_config(transport.clone());
    server_config.set_transport_config(transport);
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket, log) = recording_socket();
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket);
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    let at_first = usize::from(c.stats().path.current_mtu);
    let ceiling = c.max_datagram_payload();
    assert_eq!(
        ceiling,
        usize::from(CEILING),
        "the ceiling is the configured one, the peer allowing at least that much"
    );
    assert!(ceiling > at_first, "and it is above the confirmed size");

    wait_for("the search sends probes", Duration::from_secs(15), || {
        c.stats().path.sent_plpmtud_probes >= 2
    })
    .await;
    exchange(&c, &s, b"after the search started").await;

    let sizes: Vec<usize> = log
        .lock()
        .sent
        .iter()
        .map(|datagram| datagram.bytes.len())
        .collect();
    let above_first: Vec<usize> = sizes.iter().copied().filter(|s| *s > at_first).collect();

    assert!(
        !above_first.is_empty(),
        "the search really went above the size confirmed at the start: {at_first}"
    );
    assert!(
        sizes.iter().all(|size| *size <= ceiling),
        "every datagram is within the configured ceiling of {ceiling}: {:?}",
        sizes
            .iter()
            .filter(|size| **size > ceiling)
            .collect::<Vec<_>>()
    );
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

#[tokio::test]
async fn mtu_discovery_respects_a_smaller_peer_receive_limit_on_the_wire() {
    const PEER_LIMIT: u16 = 1300;
    let (mut client_config, server_config) = configs();
    let mut transport = TransportConfig::default();
    let mut discovery = crate::proto::MtuDiscoveryConfig::default();
    discovery.set_upper_bound(9000);
    transport.maybe_set_mtu_discovery_config(Some(discovery));
    client_config.set_transport_config(Arc::new(transport));
    let mut server_endpoint_config = EndpointConfig::try_with_rand_key().unwrap();
    server_endpoint_config
        .max_udp_payload_size(PEER_LIMIT)
        .unwrap();
    let server = endpoint_with(
        server_endpoint_config,
        Some(server_config),
        loopback_socket(),
    );
    let (socket, log) = recording_socket();
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket);
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    assert!(
        drive_until(&c, &s, Duration::from_secs(5), || {
            c.stats().path.current_mtu == PEER_LIMIT
        })
        .await,
        "discovery reaches the peer's receive limit"
    );
    exchange(&c, &s, &vec![0x62; 8192]).await;
    {
        let log = log.lock();
        assert!(
            log.sent
                .iter()
                .any(|datagram| datagram.bytes.len() == usize::from(PEER_LIMIT))
        );
        assert!(
            log.sent
                .iter()
                .all(|datagram| datagram.bytes.len() <= usize::from(PEER_LIMIT)),
            "all actual UDP datagrams, including probes, respect the advertised limit"
        );
    }
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// The engine's write buffer is reused after the confirmed MTU collapses. The path learns a
/// larger MTU, then loses it to a black hole, and the buffer keeps the storage the larger
/// datagrams needed instead of shrinking to what is now being sent.
///
/// The bound checked alongside is composed here rather than read off the connection: the buffer
/// holds capacity a former, larger path put there, so the term is the largest payload observed
/// rather than the current one. A segmented descriptor is held after one accepted segment
/// while the path ceiling falls; its remaining bytes must be recovered and delivered.
#[tokio::test]
async fn the_write_buffer_is_reused_after_the_confirmed_mtu_collapses() {
    // A descriptor is at most this many datagrams of at most the payload the path admits; a
    // connection keeps at most `RETAINED_DESCRIPTORS` of those, one of which is the engine's
    // write buffer. That buffer is grown by `Vec`, which doubles, hence the factor for it; the
    // others are exact copies of a slice and carry no slack.
    fn buffer_bound(payload: usize) -> usize {
        2 * MAX_TRANSMIT_SEGMENTS * payload
    }

    fn owned_bound(payload: usize) -> usize {
        (RETAINED_DESCRIPTORS - 1) * MAX_TRANSMIT_SEGMENTS * payload
    }

    let (mut client_config, mut server_config) = configs();
    let mut transport = crate::TransportConfig::default()
        .try_with_initial_congestion_window(u64::from(u32::MAX) + 1)
        .unwrap();
    transport.set_max_idle_timeout(Duration::from_secs(3).try_into().unwrap());
    let transport = Arc::new(transport);
    client_config.set_transport_config(transport.clone());
    server_config.set_transport_config(transport);
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket, log, segments) = segmenting_socket(1);
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket);
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let (client_conn, server_conn) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(connecting, async { server.accept().await.unwrap().await })
    })
    .await
    .unwrap();
    let client_conn = client_conn.unwrap();
    let server_conn = server_conn.unwrap();
    // Every payload this connection admits, so the bound follows the widest path it ever had
    // rather than the one in force when it is checked.
    let mut widest = client_conn.max_datagram_payload();

    let learned = drive_until(&client_conn, &server_conn, Duration::from_secs(15), || {
        client_conn.stats().path.current_mtu == 1452
    })
    .await;
    assert!(learned, "the search must reach the upper bound on loopback");
    widest = widest.max(client_conn.max_datagram_payload());

    segments.arm();
    let payload: Vec<u8> = (0..octets::kib(64)).map(|i| (i % 251) as u8).collect();
    let mut send = client_conn.open_uni().await.unwrap();
    send.write_all(&payload).await.unwrap();
    send.finish().unwrap();
    wait_for(
        "a segmented descriptor has an accepted prefix and a pending suffix",
        Duration::from_secs(5),
        || {
            let log = log.lock();
            log.rejected.is_some() && log.fallback().len() == 1
        },
    )
    .await;
    let held = client_conn.held_transmit().expect("the suffix is retained");
    let descriptor_bytes = {
        let log = log.lock();
        let (descriptor, size) = log.rejected.as_ref().unwrap();
        assert_eq!(*size, 1452, "segmentation uses the learned MTU");
        assert!(
            descriptor.bytes.len() >= 3 * size,
            "a real multi-segment offer"
        );
        assert_eq!(
            held.0, descriptor.bytes,
            "the partially accepted descriptor remains owned"
        );
        descriptor.bytes.len()
    };
    widest = widest.max(client_conn.max_datagram_payload());
    let peak = client_conn.retained_send_bytes();
    assert!(
        peak.buffer >= descriptor_bytes,
        "the reusable allocation held the complete descriptor: {peak:?}"
    );
    assert!(
        peak.owned <= owned_bound(widest) && peak.slots < RETAINED_DESCRIPTORS,
        "descriptor copies remain bounded while the partial send borrows the write buffer: {peak:?}"
    );
    assert!(
        peak.buffer <= buffer_bound(widest),
        "buffer {} over {} for a widest payload of {widest}",
        peak.buffer,
        buffer_bound(widest)
    );

    // The path now admits 1300 bytes at most, so the learned size black-holes and the MTU
    // collapses under what the buffer already holds.
    log.lock().payload_ceiling = Some(1300);
    open_segment_hold(&log);
    let mut recv = server_conn.accept_uni().await.unwrap();
    let received =
        tokio::time::timeout(Duration::from_secs(10), recv.read_to_end(payload.len() + 1))
            .await
            .expect("black-hole detection must restore progress")
            .expect("the stream completes");
    assert_eq!(
        received, payload,
        "the accepted prefix and recovered suffix arrive exactly once"
    );
    let path = client_conn.stats().path;
    assert!(path.black_holes_detected >= 1);
    assert!(
        path.current_mtu <= 1300,
        "the MTU collapsed: {}",
        path.current_mtu
    );

    // Let the transfer drain: nothing waits on a handle, so no descriptor keeps a copy.
    wait_for_with(
        "every descriptor was placed or given up",
        Duration::from_secs(5),
        || client_conn.retained_send_bytes().slots == 0,
        || format!("{:?} still held", client_conn.retained_send_bytes()),
    )
    .await;
    let after = client_conn.retained_send_bytes();
    assert_eq!(
        (after.owned, after.slots),
        (0, 0),
        "a drained connection holds no descriptor's bytes: {after:?}"
    );
    assert!(
        after.buffer >= peak.buffer,
        "the larger buffer is kept for reuse rather than shrunk on the drain: {after:?} was \
         {peak:?}"
    );
    assert!(
        after.buffer <= buffer_bound(widest) && after.owned <= owned_bound(widest),
        "retained {after:?} over the bound for a widest payload of {widest}"
    );
    assert!(
        after.buffer > usize::from(path.current_mtu),
        "the buffer outlasts the MTU that now applies: {} against {}",
        after.buffer,
        path.current_mtu
    );

    assert!(client_conn.close_reason().is_none());
    drop((client_conn, server_conn));
    tokio::join!(client.shutdown(), server.shutdown());
}

#[test]
fn inline_dropped_connection_driver_fails_the_attempt_and_retires_it() {
    detached_scenario("inline-drop connect scenario", || async {
        let (client_config, _) = configs();
        let endpoint = endpoint(None, Executor::new(), Duration::from_secs(1));
        // Held without an implicit drop: if the guarded call wedges the endpoint mutex, an
        // unwinding drop of this handle would block on it. It is dropped explicitly on success.
        let endpoint = std::mem::ManuallyDrop::new(endpoint);
        // The submitter runs with a stopped runtime entered, so its driver is destroyed inline.
        let connecting = watchdog("connect_with", stopped_runtime_handle(), {
            let endpoint = std::mem::ManuallyDrop::new((*endpoint).clone());
            move || {
                let connecting = endpoint
                    .connect_with(client_config, ([127, 0, 0, 2], 443).into(), "localhost")
                    .unwrap();
                drop(std::mem::ManuallyDrop::into_inner(endpoint));
                connecting
            }
        })
        .await;
        // The driver was destroyed before it ever ran: the attempt fails observably, the
        // engine connection and the endpoint's table entry are retired.
        let error = tokio::time::timeout(Duration::from_secs(1), connecting)
            .await
            .unwrap()
            .unwrap_err();
        assert_matches!(error, ConnectionError::TransportError(_), "{error:?}");
        assert_eq!(endpoint.open_connections(), 0);
        assert!(
            endpoint
                .inner
                .state
                .lock()
                .recv_state
                .connections
                .is_empty()
        );
        assert_eq!(endpoint.stats().outgoing_handshakes, 1);
        assert_eq!(endpoint.shutdown().await, ShutdownOutcome::Drained);
        drop(std::mem::ManuallyDrop::into_inner(endpoint));
    });
}

#[test]
fn inline_dropped_accepted_driver_fails_the_attempt_and_retires_it() {
    detached_scenario("inline-drop accept scenario", || async {
        let (client_config, server_config) = configs();
        let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
        let server = std::mem::ManuallyDrop::new(server);
        let client = endpoint(None, Executor::new(), Duration::from_secs(1));
        let connecting = client
            .connect_with(client_config, server.local_addr().unwrap(), "localhost")
            .unwrap();
        let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
            .await
            .unwrap()
            .unwrap();
        // `Incoming` holds its own endpoint reference; on a wedge it stays on the leaked thread.
        let accepted = watchdog("Incoming::accept", stopped_runtime_handle(), move || {
            incoming.accept().unwrap()
        })
        .await;
        let error = tokio::time::timeout(Duration::from_secs(1), accepted)
            .await
            .unwrap()
            .unwrap_err();
        assert_matches!(error, ConnectionError::TransportError(_), "{error:?}");
        assert_eq!(server.open_connections(), 0);
        assert!(server.inner.state.lock().recv_state.connections.is_empty());
        assert_eq!(server.stats().accepted_handshakes, 1);
        drop(connecting);
        tokio::join!(client.shutdown(), server.shutdown());
        drop(std::mem::ManuallyDrop::into_inner(server));
    });
}

#[tokio::test]
async fn receive_queue_limits_accept_the_exact_boundary() {
    let payload = usize::try_from(
        EndpointConfig::try_with_rand_key()
            .unwrap()
            .get_max_udp_payload_size(),
    )
    .unwrap();
    let connection = ReceiveQueueLimits::new(1, payload + PACKET_OVERHEAD).unwrap();
    let endpoint_limits = ReceiveQueueLimits::new(1, payload + INCOMING_OVERHEAD).unwrap();
    let mut config = EndpointConfig::try_with_rand_key().unwrap();
    config.set_receive_queue_limits(connection, endpoint_limits);
    let socket =
        Socket::from_std(std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap()).unwrap();
    let endpoint = Endpoint::new_with_advertised(
        config,
        None,
        socket,
        Vec::new(),
        Executor::new(),
        Duration::from_secs(1),
    )
    .unwrap();
    assert_eq!(endpoint.shutdown().await, ShutdownOutcome::Drained);
    let mut config = EndpointConfig::try_with_rand_key().unwrap();
    config.set_receive_queue_limits(
        ReceiveQueueLimits::new(1, payload + PACKET_OVERHEAD - 1).unwrap(),
        endpoint_limits,
    );
    let socket =
        Socket::from_std(std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap()).unwrap();
    Endpoint::new_with_advertised(
        config,
        None,
        socket,
        Vec::new(),
        Executor::new(),
        Duration::from_secs(1),
    )
    .unwrap_err();
    // The endpoint budget must be able to hold one whole connection budget: equal is
    // accepted, one byte or one datagram less is refused.
    let build = |connection: ReceiveQueueLimits, endpoint_limits: ReceiveQueueLimits| {
        let mut config = EndpointConfig::try_with_rand_key().unwrap();
        config.set_receive_queue_limits(connection, endpoint_limits);
        let socket =
            Socket::from_std(std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap()).unwrap();
        Endpoint::new_with_advertised(
            config,
            None,
            socket,
            Vec::new(),
            Executor::new(),
            Duration::from_secs(1),
        )
    };
    let big = payload + INCOMING_OVERHEAD;
    let equal = build(
        ReceiveQueueLimits::new(2, big).unwrap(),
        ReceiveQueueLimits::new(2, big).unwrap(),
    )
    .unwrap();
    assert_eq!(equal.shutdown().await, ShutdownOutcome::Drained);
    build(
        ReceiveQueueLimits::new(2, big).unwrap(),
        ReceiveQueueLimits::new(2, big - 1).unwrap(),
    )
    .unwrap_err();
    build(
        ReceiveQueueLimits::new(2, big).unwrap(),
        ReceiveQueueLimits::new(1, big).unwrap(),
    )
    .unwrap_err();
}

#[test]
fn forced_shutdown_waits_for_a_registered_driver_that_is_still_being_submitted() {
    detached_scenario("gated submission scenario", || async {
        let (client_config, _) = configs();
        let endpoint = endpoint(None, Executor::new(), Duration::from_millis(100));
        let address = endpoint.local_addr().unwrap();
        // Pause the next submitter after it registered the connection and reserved its slot.
        // The guard reopens the gate on any exit, so the submitter never outlives the test.
        let gate = SubmitGate::close(&endpoint.inner.shared.lifecycle);
        let (submitted, submitter) = tokio::sync::oneshot::channel();
        std::thread::spawn({
            let endpoint = endpoint.clone();
            let handle = tokio::runtime::Handle::current();
            move || {
                let _entered = handle.enter();
                let connecting = endpoint
                    .connect_with(client_config, ([127, 0, 0, 2], 443).into(), "localhost")
                    .unwrap();
                let _sent = submitted.send(connecting);
            }
        });
        wait_until(|| endpoint.inner.shared.lifecycle.pending_submissions() == 1).await;
        assert_eq!(endpoint.open_connections(), 1);

        // Shutdown runs its forced path but must not complete while the driver is unsupervised.
        let mut shutdown = std::pin::pin!(endpoint.shutdown());
        assert!(
            tokio::time::timeout(Duration::from_millis(500), &mut shutdown)
                .await
                .is_err(),
            "shutdown completed while a registered driver was still being submitted"
        );
        drop(gate);
        let outcome = tokio::time::timeout(Duration::from_secs(3), &mut shutdown)
            .await
            .expect("shutdown must finish once the late submission is tracked");
        assert_eq!(outcome, ShutdownOutcome::Forced);
        // The late driver was aborted on submission and delivered Drained; nothing is left.
        let connecting = tokio::time::timeout(Duration::from_secs(3), submitter)
            .await
            .expect("the released submitter must return")
            .unwrap();
        let error = tokio::time::timeout(Duration::from_secs(1), connecting)
            .await
            .unwrap()
            .unwrap_err();
        assert_matches!(
            error,
            ConnectionError::LocallyClosed | ConnectionError::TransportError(_),
        );
        assert_eq!(endpoint.open_connections(), 0);
        assert!(
            endpoint
                .inner
                .state
                .lock()
                .recv_state
                .connections
                .is_empty()
        );
        assert_eq!(endpoint.inner.shared.lifecycle.pending_submissions(), 0);
        let _rebound = std::net::UdpSocket::bind(address).unwrap();
    });
}

#[test]
fn dropped_reservation_releases_supervision_and_wakes_the_joiner() {
    let lifecycle = crate::driver::lifecycle::Lifecycle::default();
    let slot = lifecycle.reserve();
    assert_eq!(lifecycle.pending_submissions(), 1);
    let mut join = std::pin::pin!(lifecycle.join());
    let wake = Arc::new(super::tests::WakeCount::default());
    let waker = Waker::from(wake.clone());
    assert!(
        join.as_mut()
            .poll(&mut Context::from_waker(&waker))
            .is_pending()
    );
    assert_eq!(wake.0.load(Ordering::Relaxed), 0);
    drop(slot);
    assert_eq!(lifecycle.pending_submissions(), 0);
    assert_eq!(
        wake.0.load(Ordering::Relaxed),
        1,
        "the joiner must be woken"
    );
    assert!(
        join.as_mut()
            .poll(&mut Context::from_waker(&waker))
            .is_ready()
    );
}

#[test]
fn incoming_container_gives_back_burst_capacity_after_sustained_quiet_cycles() {
    let mut queue: BoundedDeque<[u8; 64]> = BoundedDeque::new(8192);
    assert_eq!(queue.capacity(), 0);
    for _ in 0..512 {
        queue.push_back([0; 64]).unwrap();
    }
    let peak = queue.capacity();
    assert!((512..=1024).contains(&peak), "{peak}");
    while queue.len() > 1 {
        queue.pop_front();
        assert_eq!(queue.capacity(), peak, "ordinary pops keep the storage");
    }
    queue.pop_front();
    assert_eq!(queue.capacity(), peak, "a recent burst keeps its capacity");
    for round in 1..=QUIET_DRAINS_BEFORE_SHRINK {
        queue.push_back([0; 64]).unwrap();
        queue.pop_front();
        assert_eq!(
            queue.capacity(),
            if round < QUIET_DRAINS_BEFORE_SHRINK {
                peak
            } else {
                MIN_RETAINED
            },
            "only sustained quiet drain cycles release burst storage"
        );
    }
}

/// The shared spawn path is the only way driver tasks are created, so an attached dial9
/// recorder sees them; without a recorder the same path stays a plain Tokio spawn.
mod accept;
#[cfg(feature = "boring")]
mod async_handshake;
#[cfg(feature = "dial9")]
mod dial9;
/// One attempt on A and nothing else depending on A: the server rebinds A→B→C, then sends
/// the Retry from A. The Retry route keeps A receiving so
/// the client's token-bearing Initial is answered and the handshake completes on A. Once the
/// connection closes, A stays only until the route hold expires (the token lifetime), then
/// the timer retires it without any peer activity.
#[tokio::test]
async fn a_retry_sent_from_a_replaced_socket_is_answered_there_until_its_route_expires() {
    let (client_config, mut server_config) = configs();
    let lifetime = Duration::from_millis(1500);
    server_config.set_retry_token_lifetime(lifetime);
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let addr_a = server.local_addr().unwrap();
    let client = endpoint(None, Executor::new(), Duration::from_secs(1));
    let connecting = client
        .connect_with(client_config, addr_a, "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    server.rebind_abstract(loopback_socket()).unwrap();
    server.rebind_abstract(loopback_socket()).unwrap();
    let addr_c = server.local_addr().unwrap();
    assert_eq!(server.stats().retained_sockets, 2, "A (the attempt) and C");
    let retried_at = Instant::now();
    incoming.retry().unwrap();
    assert_eq!(
        server.stats().retained_sockets,
        2,
        "the Retry route keeps A although no lease or response depends on it any more"
    );
    let validated = accept_validated_from(&server, client.local_addr().unwrap().port()).await;
    assert!(validated.remote_address_validated());
    let (c, s) = handshake(connecting, validated).await;
    assert_eq!(c.remote_address(), addr_a, "the client is served from A");
    exchange(&s, &c, b"via A after Retry").await;
    drop((c, s));
    let elapsed = wait_for(
        "A retires after the route hold",
        Duration::from_secs(6),
        || server.stats().retained_sockets == 1,
    )
    .await;
    assert!(
        retried_at.elapsed() >= lifetime,
        "A retired {elapsed:?} after the connection closed, before the hold expired"
    );
    assert_eq!(server.stats().retired_sockets, 2, "B (superseded) and A");
    assert_eq!(server.local_addrs(), vec![addr_c]);
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A Retry nobody answers keeps its socket exactly for the token lifetime, then the expiry
/// timer retires it; shutting down during a hold releases the socket at once and frees the
/// port.
#[tokio::test]
async fn an_unanswered_retry_route_expires_on_its_own_and_shutdown_releases_it_early() {
    let (client_config, mut server_config) = configs();
    let lifetime = Duration::from_millis(700);
    server_config.set_retry_token_lifetime(lifetime);

    // Expiry: the client is gone before the Retry leaves, so nothing ever comes back to A.
    let server = endpoint(
        Some(server_config.clone()),
        Executor::new(),
        Duration::from_secs(1),
    );
    let addr_a = server.local_addr().unwrap();
    let client = endpoint(None, Executor::new(), Duration::from_secs(1));
    let connecting = client
        .connect_with(client_config.clone(), addr_a, "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let before_close = server.stats().received_datagrams;
    drop(connecting);
    client.shutdown().await;
    // The client's close went to A on its way out; it belongs to the pending attempt, and a
    // Retry issued before it is taken in would meet it as a fresh attempt holding A instead.
    wait_for(
        "the client's close reaches A",
        Duration::from_secs(2),
        || server.stats().received_datagrams > before_close,
    )
    .await;
    server.rebind_abstract(loopback_socket()).unwrap();
    let addr_b = server.local_addr().unwrap();
    let retried_at = Instant::now();
    incoming.retry().unwrap();
    assert_eq!(server.stats().retained_sockets, 2);
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert_eq!(
        server.stats().retained_sockets,
        2,
        "the route hold outlives the sent Retry"
    );
    wait_for("expiry retires A", Duration::from_secs(5), || {
        server.stats().retained_sockets == 1
    })
    .await;
    assert!(retried_at.elapsed() >= lifetime);
    assert_eq!(server.stats().retired_sockets, 1);
    assert_eq!(server.local_addrs(), vec![addr_b]);
    assert_eq!(server.inner.state.lock().inner.pending_incoming(), 0);
    server.shutdown().await;

    // Shutdown during a hold: no retained handle keeps A bound.
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let addr_a = server.local_addr().unwrap();
    let client = endpoint(None, Executor::new(), Duration::from_secs(1));
    let connecting = client
        .connect_with(client_config, addr_a, "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let before_close = server.stats().received_datagrams;
    drop(connecting);
    client.shutdown().await;
    wait_for(
        "the client's close reaches A",
        Duration::from_secs(2),
        || server.stats().received_datagrams > before_close,
    )
    .await;
    server.rebind_abstract(loopback_socket()).unwrap();
    let addr_b = server.local_addr().unwrap();
    incoming.retry().unwrap();
    assert_eq!(server.stats().retained_sockets, 2);
    assert_ne!(server.shutdown().await, ShutdownOutcome::DriverFailed);
    let _a = std::net::UdpSocket::bind(addr_a).expect("A's port is free after shutdown");
    let _b = std::net::UdpSocket::bind(addr_b).expect("B's port is free after shutdown");
    assert_eq!(server.stats().retained_sockets, 0);
}

/// Send handles are destroyed outside the endpoint lock and every connection lock on each
/// path that gives one up: a superseded rebind, the switch after a held send completes, a
/// connect that fails after taking a handle, connection close, and endpoint shutdown.
#[tokio::test]
async fn send_handles_are_destroyed_outside_every_lock_on_each_release_path() {
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let probe = Arc::new(SenderProbe::default());
    let (socket_a, gate_a, _, _) = breakable_socket(Some(probe.clone()));
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket_a);
    probe.attach(&client);
    let connecting = client
        .connect_with(
            client_config.clone(),
            server.local_addr().unwrap(),
            "localhost",
        )
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    gate_a.close();
    let mut stream = c.open_uni().await.unwrap();
    stream.write_all(b"held").await.unwrap();
    stream.finish().unwrap();
    wait_until(|| gate_a.held.load(Ordering::Relaxed) >= 1).await;

    // Supersession: B's handle is handed back and destroyed, then B itself.
    let (socket_b, _, _, _) = breakable_socket(Some(probe.clone()));
    client.rebind_abstract(socket_b).unwrap();
    let (socket_c, _, _, _) = breakable_socket(Some(probe.clone()));
    client.rebind_abstract(socket_c).unwrap();
    wait_for("B's handles are destroyed", Duration::from_secs(3), || {
        probe.drops.load(Ordering::SeqCst) >= 2
    })
    .await;
    assert_eq!(client.stats().retained_sockets, 2);

    // Replacement: the held send completes on A, the connection switches to C and A's
    // handle is destroyed, then A.
    gate_a.open();
    wait_for("A's handles are destroyed", Duration::from_secs(3), || {
        probe.drops.load(Ordering::SeqCst) >= 4
    })
    .await;
    assert_eq!(client.stats().retained_sockets, 1);
    let mut held = tokio::time::timeout(Duration::from_secs(5), s.accept_uni())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(held.read_to_end(16).await.unwrap(), b"held");
    exchange(&c, &s, b"from C").await;

    // A connect that fails after taking a handle destroys it on the way out.
    assert_matches!(
        client.connect_with(
            client_config,
            server.local_addr().unwrap(),
            "not a valid server name"
        ),
        Err(ConnectError::InvalidServerName(_)),
    );
    assert_eq!(probe.drops.load(Ordering::SeqCst), 5);

    // Close: once every handle and stream is gone, the driver hands its C handle back.
    drop((stream, held, c, s));
    wait_for(
        "the closed connection's handle is destroyed",
        Duration::from_secs(5),
        || probe.drops.load(Ordering::SeqCst) >= 6,
    )
    .await;
    client.shutdown().await;
    assert_eq!(
        probe.drops.load(Ordering::SeqCst),
        7,
        "B, A, failed connect and connection handles plus the three sockets' own response handles"
    );
    assert_eq!(
        probe.under_lock.load(Ordering::SeqCst),
        0,
        "a send handle was destroyed while a driver lock was held"
    );
    server.shutdown().await;
}

/// The old socket's receive path fails while a connection still sends from it with a send
/// held pending and a newer healthy socket already pending for it: the connection leaves
/// the dead socket at once, the held datagram is lost like any other (recovery resends it),
/// traffic continues from the new socket, and the failed socket retires.
#[tokio::test]
async fn a_failed_retiring_receiver_moves_its_connection_to_the_pending_socket() {
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket_a, gate_a, fault_a, sent_a) = breakable_socket(None);
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket_a);
    let addr_a = client.local_addr().unwrap();
    let (socket_b, log_b) = recording_socket();
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    assert_eq!(s.remote_address(), addr_a);
    gate_a.close();
    let mut stream = c.open_uni().await.unwrap();
    stream.write_all(b"held on A").await.unwrap();
    stream.finish().unwrap();
    wait_until(|| gate_a.held.load(Ordering::Relaxed) >= 1).await;
    let cid_a = active_dcid(&c);
    client.rebind_abstract(socket_b).unwrap();
    let addr_b = client.local_addr().unwrap();
    assert_eq!(client.stats().retained_sockets, 2, "the held send pins A");

    fail_receiver(&client, &fault_a);
    wait_for("A fails and retires", Duration::from_secs(3), || {
        client.stats().retained_sockets == 1
    })
    .await;
    let sent_on_a = sent_a.load(Ordering::Relaxed);
    assert_eq!(client.stats().retired_sockets, 1);
    assert!(
        c.close_reason().is_none(),
        "a path failure is not a connection failure"
    );
    // The held datagram never left A; the stream still arrives, resent from B.
    let mut stream = tokio::time::timeout(Duration::from_secs(5), s.accept_uni())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(stream.read_to_end(64).await.unwrap(), b"held on A");
    exchange(&s, &c, b"from server").await;
    exchange(&c, &s, b"from B").await;
    wait_for("the server sees B", Duration::from_secs(5), || {
        s.remote_address() == addr_b
    })
    .await;
    // The recovery switch is a migration too: a fresh destination connection ID from B's
    // first datagram on, never one that A used (RFC 9000 §9.5).
    let cid_b = active_dcid(&c);
    assert_ne!(
        cid_b, cid_a,
        "the switch rotated the destination connection ID"
    );
    let on_b = short_header_dcids(&log_b.lock().sent, cid_a.len());
    assert!(!on_b.is_empty());
    assert!(
        on_b.iter().all(|cid| *cid != cid_a),
        "A's connection ID never appears on B"
    );
    assert_eq!(on_b[0], cid_b, "B's first datagram already uses the new ID");
    gate_a.open();
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert_eq!(
        sent_a.load(Ordering::Relaxed),
        sent_on_a,
        "nothing left A after it failed; the held datagram was dropped with the handle"
    );
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// The local path error a connection ends with when its socket failed and it may not send
/// from any other address (RFC 9000 §9).
fn assert_local_path_error(error: &ConnectionError) {
    let ConnectionError::TransportError(transport) = error else {
        panic!("not a local transport error: {error:?}");
    };
    assert_eq!(
        transport.code,
        rama_quic_proto::TransportErrorCode::INTERNAL_ERROR
    );
    assert!(
        transport.reason.contains("may not migrate"),
        "the reason names the policy, not a generic send failure: {}",
        transport.reason
    );
    let source = std::error::Error::source(error)
        .and_then(std::error::Error::source)
        .and_then(|source| source.downcast_ref::<io::Error>())
        .expect("the failed socket is the error's source");
    assert_eq!(source.kind(), io::ErrorKind::NotConnected);
}

/// A server cannot change the address a connection uses (the preferred-address mechanism
/// aside; a client discards packets from an unknown server address). A connection accepted
/// on A keeps sending from A when the server rebinds, and when A then fails it is terminated
/// with a local path error that wakes its waiters, instead of being moved to an address the
/// client would ignore or left stuck. A retires with it.
#[tokio::test]
async fn a_server_connection_keeps_its_socket_on_rebind_and_ends_with_it_when_it_fails() {
    let (client_config, server_config) = configs();
    let (socket_a, _gate, fault_a, _) = breakable_socket(None);
    let server = endpoint_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        Some(server_config),
        socket_a,
    );
    let addr_a = server.local_addr().unwrap();
    let client = endpoint(None, Executor::new(), Duration::from_secs(1));
    let connecting = client
        .connect_with(client_config, addr_a, "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    assert_eq!(c.remote_address(), addr_a);
    // The endpoint's default address changes; the established server route stays on A.
    server.rebind_abstract(loopback_socket()).unwrap();
    let addr_b = server.local_addr().unwrap();
    exchange(&c, &s, b"to A").await;
    exchange(&s, &c, b"from A").await;
    assert_eq!(c.remote_address(), addr_a, "the client still talks to A");
    assert_eq!(
        server.stats().retained_sockets,
        2,
        "A is kept for the connection; the offer of B was handed back"
    );
    assert_eq!(server.local_addrs(), vec![addr_b, addr_a]);

    let closed = tokio::spawn({
        let s = s.clone();
        async move { s.closed().await }
    });
    let accept = tokio::spawn({
        let s = s.clone();
        async move { s.accept_uni().await }
    });
    fail_receiver(&server, &fault_a);
    let error = tokio::time::timeout(Duration::from_secs(3), closed)
        .await
        .expect("the connection ends when its only path fails")
        .unwrap();
    assert_local_path_error(&error);
    tokio::time::timeout(Duration::from_secs(3), accept)
        .await
        .expect("blocked work is woken")
        .unwrap()
        .expect_err("the blocked attempt is refused");
    wait_for(
        "A retires and the connection is gone",
        Duration::from_secs(5),
        || server.stats().retained_sockets == 1 && server.open_connections() == 0,
    )
    .await;
    assert_eq!(server.stats().retired_sockets, 1);
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A client may not migrate before its handshake is confirmed. A rebind during the handshake
/// is held as a pending offer: the connection keeps its socket until HANDSHAKE_DONE arrives,
/// then switches, and the old socket retires.
#[tokio::test]
async fn a_client_defers_its_migration_until_the_handshake_is_confirmed() {
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket_a, gate_a) = gated_socket();
    gate_a.close();
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket_a);
    let addr_a = client.local_addr().unwrap();
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    wait_until(|| gate_a.held.load(Ordering::Relaxed) >= 1).await;
    client.rebind_abstract(loopback_socket()).unwrap();
    let addr_b = client.local_addr().unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert_eq!(
        client.stats().retained_sockets,
        2,
        "the unconfirmed connection stays on A with B pending"
    );
    assert_eq!(queued_attempts(&server), 0, "nothing left A yet");
    gate_a.open();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(incoming.remote_address(), addr_a, "the Initial left from A");
    let (c, s) = handshake(connecting, incoming).await;
    exchange(&c, &s, b"after confirmation").await;
    wait_for(
        "the confirmed client migrates to B",
        Duration::from_secs(5),
        || s.remote_address() == addr_b,
    )
    .await;
    wait_for("A retires", Duration::from_secs(3), || {
        client.stats().retained_sockets == 1
    })
    .await;
    exchange(&s, &c, b"via B").await;
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A peer that disables active migration pins the client to its socket: a rebind hands the
/// new socket's offer straight back and the connection keeps A. When A then fails there is
/// no address the connection may use, so it ends with a local path error and A retires.
#[tokio::test]
async fn a_client_whose_peer_disables_migration_keeps_its_socket_and_ends_with_it() {
    let (client_config, mut server_config) = configs();
    server_config.set_migration(false);
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket_a, _gate, fault_a, _) = breakable_socket(None);
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket_a);
    let addr_a = client.local_addr().unwrap();
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    client.rebind_abstract(loopback_socket()).unwrap();
    let addr_b = client.local_addr().unwrap();
    exchange(&c, &s, b"still A").await;
    exchange(&s, &c, b"to A").await;
    assert_eq!(
        s.remote_address(),
        addr_a,
        "no migration against the peer's wishes"
    );
    assert_eq!(
        client.stats().retained_sockets,
        2,
        "A is kept for the connection"
    );
    assert_eq!(client.local_addrs(), vec![addr_b, addr_a]);

    let closed = tokio::spawn({
        let c = c.clone();
        async move { c.closed().await }
    });
    fail_receiver(&client, &fault_a);
    let error = tokio::time::timeout(Duration::from_secs(3), closed)
        .await
        .expect("the pinned connection ends with its socket")
        .unwrap();
    assert_local_path_error(&error);
    wait_for("A retires", Duration::from_secs(5), || {
        client.stats().retained_sockets == 1 && client.open_connections() == 0
    })
    .await;
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// An unconfirmed client whose socket fails cannot migrate yet: the attempt ends with a
/// local path error instead of hanging until the handshake deadline, and the socket retires.
#[tokio::test]
async fn an_unconfirmed_client_whose_socket_fails_is_terminated() {
    let (client_config, server_config) = configs();
    // The server never accepts, so the client's handshake is never confirmed.
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket_a, _gate, fault_a, _) = breakable_socket(None);
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket_a);
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    wait_until(|| queued_attempts(&server) == 1).await;
    client.rebind_abstract(loopback_socket()).unwrap();
    assert_eq!(client.stats().retained_sockets, 2);
    fail_receiver(&client, &fault_a);
    let error = tokio::time::timeout(Duration::from_secs(3), connecting)
        .await
        .expect("the attempt ends with its socket")
        .unwrap_err();
    assert_local_path_error(&error);
    wait_for("A retires", Duration::from_secs(5), || {
        client.stats().retained_sockets == 1 && client.open_connections() == 0
    })
    .await;
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A Retry token lifetime the monotonic clock cannot represent is refused before any Retry
/// is issued: the attempt and its socket stay with the caller, who can still accept it.
#[tokio::test]
async fn a_retry_lifetime_beyond_the_clock_is_refused_and_the_attempt_is_kept() {
    let (client_config, mut server_config) = configs();
    server_config.set_retry_token_lifetime(Duration::MAX);
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let addr_a = server.local_addr().unwrap();
    let client = endpoint(None, Executor::new(), Duration::from_secs(1));
    let connecting = client
        .connect_with(client_config, addr_a, "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    server.rebind_abstract(loopback_socket()).unwrap();
    let refused = incoming.retry().unwrap_err();
    assert_eq!(refused.reason(), RetryRefused::LifetimeUnrepresentable);
    assert_eq!(
        server.stats().retained_sockets,
        2,
        "the kept attempt keeps its socket"
    );
    let incoming = refused.into_incoming();
    assert!(incoming.may_retry(), "nothing was issued");
    let (c, s) = handshake(connecting, incoming).await;
    assert_eq!(c.remote_address(), addr_a);
    exchange(&c, &s, b"accepted instead").await;
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// Attempts still queued on a socket that fails can no longer be answered: they are released
/// at failure time (no engine state, no lease). An attempt the application already holds
/// from that socket is refused with `LocallyClosed` when accepted, and its release lets the
/// failed socket retire.
#[tokio::test]
async fn attempts_queued_on_a_socket_that_fails_are_released_and_a_held_one_is_refused() {
    let (client_config, server_config) = configs();
    let (socket_a, _gate, fault_a, _) = breakable_socket(None);
    let server = endpoint_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        Some(server_config),
        socket_a,
    );
    let addr_a = server.local_addr().unwrap();
    let held_client = endpoint(None, Executor::new(), Duration::from_secs(1));
    let queued_client = endpoint(None, Executor::new(), Duration::from_secs(1));
    let held_connecting = held_client
        .connect_with(client_config.clone(), addr_a, "localhost")
        .unwrap();
    let held = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let queued_connecting = queued_client
        .connect_with(client_config, addr_a, "localhost")
        .unwrap();
    wait_until(|| queued_attempts(&server) == 1).await;
    server.rebind_abstract(loopback_socket()).unwrap();
    assert_eq!(server.stats().retained_sockets, 2);
    assert_eq!(server.inner.state.lock().inner.pending_incoming(), 2);

    fail_receiver(&server, &fault_a);
    wait_for(
        "the queued attempt is released",
        Duration::from_secs(3),
        || queued_attempts(&server) == 0,
    )
    .await;
    {
        let state = server.inner.state.lock();
        assert_eq!(
            state.inner.pending_incoming(),
            1,
            "only the held attempt remains in the engine"
        );
        assert_eq!(state.recv_state.incoming.len(), 0);
    }
    assert_eq!(server.stats().receive_queue.queued_datagrams, 0);
    assert_eq!(
        server.stats().retained_sockets,
        2,
        "the held attempt still pins the failed socket"
    );
    assert_matches!(held.accept(), Err(ConnectionError::LocallyClosed));
    assert_eq!(server.inner.state.lock().inner.pending_incoming(), 0);
    wait_for(
        "A retires with its last lease",
        Duration::from_secs(3),
        || server.stats().retained_sockets == 1,
    )
    .await;
    drop((held_connecting, queued_connecting));
    tokio::join!(
        held_client.shutdown(),
        queued_client.shutdown(),
        server.shutdown()
    );
}

/// An Initial admitted in a receive pass that then fails: the attempt is released (no
/// engine state, no queue charge) before the failure is judged. On the active socket the
/// failure ends the driver; on a retiring socket it is isolated and the endpoint continues.
#[tokio::test]
async fn an_attempt_admitted_before_a_receive_fault_in_the_same_pass_is_released_cleanly() {
    let (client_config, server_config) = configs();

    let (socket, _gate, fault, _) = breakable_socket(None);
    *fault.lock() = Some(RecvFault::AfterNextBatch);
    let fatal = endpoint_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        Some(server_config.clone()),
        socket,
    );
    // One pass must see both the Initial and the fault: the measured allowance could end it
    // in between, which is the separate queued-attempt case tested below.
    fatal.inner.state.lock().recv_state.forced_recv_allowance = Some(usize::MAX);
    let client = endpoint(None, Executor::new(), Duration::from_secs(1));
    let connecting = client
        .connect_with(
            client_config.clone(),
            fatal.local_addr().unwrap(),
            "localhost",
        )
        .unwrap();
    wait_for("the failing driver is gone", Duration::from_secs(3), || {
        fatal.inner.state.lock().driver_lost
    })
    .await;
    {
        let state = fatal.inner.state.lock();
        assert_eq!(state.inner.pending_incoming(), 0, "no orphan attempt");
        assert_eq!(state.recv_state.incoming.len(), 0);
    }
    assert_eq!(fatal.stats().receive_queue.queued_datagrams, 0);
    assert_eq!(fatal.shutdown().await, ShutdownOutcome::DriverFailed);
    drop(connecting);

    let (socket, _gate, fault, _) = breakable_socket(None);
    let server = endpoint_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        Some(server_config),
        socket,
    );
    server.inner.state.lock().recv_state.forced_recv_allowance = Some(usize::MAX);
    let addr_a = server.local_addr().unwrap();
    let pin = pin_active_socket(&server);
    server.rebind_abstract(loopback_socket()).unwrap();
    *fault.lock() = Some(RecvFault::AfterNextBatch);
    let connecting = client
        .connect_with(client_config, addr_a, "localhost")
        .unwrap();
    wait_for("A fails", Duration::from_secs(3), || {
        server.stats().received_datagrams >= 1
            && !server
                .inner
                .state
                .lock()
                .sockets
                .live()
                .is_some_and(|s| s.is_usable(pin.id()))
    })
    .await;
    {
        let state = server.inner.state.lock();
        assert_eq!(
            state.inner.pending_incoming(),
            0,
            "the attempt admitted on the failing socket was released"
        );
        assert_eq!(state.recv_state.incoming.len(), 0);
    }
    assert_eq!(server.stats().receive_queue.queued_datagrams, 0);
    assert_eq!(server.stats().retained_sockets, 2, "pinned");
    release_lease(&server, pin);
    assert_eq!(server.stats().retained_sockets, 1);
    drop(connecting);
    assert_ne!(server.shutdown().await, ShutdownOutcome::DriverFailed);
    client.shutdown().await;
}

/// One datagram handed to the network by a [`SegmentingSocket`], with its metadata.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct SentDatagram {
    pub(super) bytes: Vec<u8>,
    pub(super) ecn: Option<rama_udp::EcnCodepoint>,
    pub(super) source: Option<IpAddr>,
    pub(super) destination: SocketAddress,
}

impl SentDatagram {
    fn of(datagram: &rama_udp::SendDatagram<'_>) -> Self {
        Self {
            bytes: datagram.payload().to_vec(),
            ecn: datagram.ecn(),
            source: datagram.source_ip(),
            destination: datagram.destination(),
        }
    }
}

/// What a [`SegmentingSocket`] saw: the one segmented descriptor it rejected and every
/// datagram it sent, plus a count-based hold on the fallback datagrams.
#[derive(Debug, Default)]
pub(super) struct SegmentLog {
    /// The rejected segmented descriptor and its segment size.
    pub(super) rejected: Option<(SentDatagram, usize)>,
    /// How many segments each segmented descriptor offered, so a test that never saw the batch
    /// it needs says so rather than reporting a missing report.
    pub(super) segmented_offers: Vec<usize>,
    /// Index into `sent` at which the rejection happened.
    rejected_at: usize,
    pub(super) sent: Vec<SentDatagram>,
    /// Optional hard bound for small wire-observation tests.
    pub(super) capture_limit: Option<usize>,
    /// Sends stay pending once this many fallback datagrams were accepted, until `open`.
    hold_after: usize,
    /// Limit the fallback hold to one peer, allowing unrelated connections to send.
    pub(super) hold_destination: Option<SocketAddress>,
    open: bool,
    wakers: Vec<Waker>,
    /// Errors reported after part of a short descriptor was already accepted.
    /// While set, plain datagrams are recorded as sent but never reach the network.
    blackhole: bool,
    /// Simulated path ceiling: larger datagrams leave the sender but do not reach the peer.
    payload_ceiling: Option<usize>,
    /// While set, datagrams for this destination are not accepted and the sender is told to wait.
    blocked: Option<SocketAddress>,
    /// While set, this many more datagrams are accepted and then the sender is told to wait. It
    /// makes "the next datagram to leave" observable.
    credit: Option<usize>,
    /// While set, the sender is refused once this many datagrams have been accepted, so a
    /// descriptor can fail after leaving a prefix.
    fail_after: Option<usize>,
    /// While set, arrivals are not delivered to the endpoint and the receiving task's waker is
    /// kept. The kernel keeps buffering meanwhile, so opening the gate delivers what arrived. It
    /// lets a test order what the endpoint sees without touching any send path.
    receive_closed: bool,
    receive_wakers: Vec<Waker>,
}

impl SegmentLog {
    fn record(&mut self, datagram: &rama_udp::SendDatagram<'_>) {
        assert!(
            self.capture_limit
                .is_none_or(|limit| self.sent.len() < limit),
            "packet capture limit exceeded"
        );
        self.sent.push(SentDatagram::of(datagram));
    }

    /// Charge one accepted datagram against the credit, when one is set.
    fn spend_credit(&mut self) {
        if let Some(left) = self.credit.as_mut() {
            *left = left.saturating_sub(1);
        }
    }

    pub(super) fn fallback(&self) -> &[SentDatagram] {
        &self.sent[self.rejected_at..]
    }
}

/// A real loopback socket that, once armed, advertises eight send segments and rejects the
/// first segmented descriptor of three or more segments (downgrading to one segment, as an
/// offload path that turns out to be unavailable does). Smaller segmented descriptors are
/// forwarded segment by segment, so the rejected descriptor always has a suffix to hold.
/// Ordinary datagrams are forwarded one by one; every datagram's bytes and metadata are
/// recorded, and the fallback can be held pending after a given number of datagrams.
#[derive(Debug)]
struct SegmentingSocket {
    inner: rama_udp::UdpPacketSocket,
    log: Arc<Mutex<SegmentLog>>,
    segments: Arc<Segments>,
    /// Injected receive failure, as [`FaultySocket`] takes one, so [`fail_receiver`] can retire
    /// a socket that is part-way through a descriptor.
    recv_fault: Arc<Mutex<Option<RecvFault>>>,
}

/// Whether a [`SegmentingSocket`] offers segmentation: not before it is armed, never after
/// the downgrade.
#[derive(Debug, Default)]
pub(super) struct Segments {
    armed: AtomicBool,
    downgraded: AtomicBool,
}

impl Segments {
    pub(super) fn arm(&self) {
        self.armed.store(true, Ordering::SeqCst);
    }

    fn caps(&self, inner: DatagramCapabilities) -> DatagramCapabilities {
        let mut caps = inner;
        caps.max_send_segments =
            if self.armed.load(Ordering::SeqCst) && !self.downgraded.load(Ordering::SeqCst) {
                8
            } else {
                1
            };
        caps
    }
}

impl rama_net::stream::Socket for SegmentingSocket {
    fn local_addr(&self) -> io::Result<SocketAddress> {
        self.inner.local_addr()
    }

    fn peer_addr(&self) -> io::Result<SocketAddress> {
        self.inner.peer_addr()
    }
}

impl DatagramSocket for SegmentingSocket {
    type Sender = SegmentingSender;
    fn create_sender(&self) -> SegmentingSender {
        SegmentingSender {
            inner: self.inner.create_sender(),
            log: self.log.clone(),
            segments: self.segments.clone(),
        }
    }

    fn poll_recv(
        &mut self,
        cx: &mut Context<'_>,
        buffers: &mut [IoSliceMut<'_>],
        metadata: &mut [DatagramMetadata],
    ) -> Poll<Result<usize, DatagramError>> {
        let fault = *self.recv_fault.lock();
        if fault == Some(RecvFault::Now) {
            return Poll::Ready(Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "injected receive fault",
            )
            .into()));
        }
        {
            let mut log = self.log.lock();
            if log.receive_closed {
                log.receive_wakers.push(cx.waker().clone());
                return Poll::Pending;
            }
        }
        let result = self.inner.poll_recv(cx, buffers, metadata);
        if fault == Some(RecvFault::AfterNextBatch) && matches!(result, Poll::Ready(Ok(_))) {
            *self.recv_fault.lock() = Some(RecvFault::Now);
        }
        result
    }

    fn capabilities(&self) -> DatagramCapabilities {
        self.segments.caps(self.inner.capabilities())
    }
}

#[derive(Debug)]
struct SegmentingSender<S = rama_udp::UdpPacketSender> {
    inner: S,
    log: Arc<Mutex<SegmentLog>>,
    segments: Arc<Segments>,
}

impl<S: DatagramSender> DatagramSender for SegmentingSender<S> {
    fn poll_send(
        &mut self,
        cx: &mut Context<'_>,
        datagram: &rama_udp::SendDatagram<'_>,
    ) -> Poll<Result<(), DatagramError>> {
        let mut log = self.log.lock();
        if log.blocked == Some(datagram.destination()) {
            log.wakers.push(cx.waker().clone());
            return Poll::Pending;
        }
        // Credit is charged per datagram the backend accepts, below. A rejection or a Pending
        // must leave it untouched, or a retry would find nothing left and the send would stall.
        if log.credit == Some(0) {
            log.wakers.push(cx.waker().clone());
            return Poll::Pending;
        }
        if let Some(size) = datagram.segment_size() {
            assert!(
                log.rejected.is_none(),
                "segmentation is never advertised again after the downgrade"
            );
            log.segmented_offers.push(datagram.segment_count());
            if datagram.segment_count() < 3 {
                // Too small to leave a suffix: this stands in for an offload, and an offload is
                // one call to the kernel. It takes every segment or none: `Pending` and `Err`
                // both tell the sender its descriptor was untouched, so bytes that left under
                // either answer would be on the wire with nothing accounting for them. Whatever
                // could stop the batch is settled before its first segment goes — the credit and
                // a scripted refusal that would fall inside it — and if the socket underneath
                // stops part-way anyway, that is a state this fixture cannot report and it says
                // so rather than hiding it.
                let payload = datagram.payload();
                let segments = payload.len().div_ceil(size.get());
                if log.credit.is_some_and(|credit| credit < segments) {
                    log.wakers.push(cx.waker().clone());
                    return Poll::Pending;
                }
                if log
                    .fail_after
                    .is_some_and(|at| (log.sent.len()..log.sent.len() + segments).contains(&at))
                {
                    return Poll::Ready(Err(io::Error::new(
                        io::ErrorKind::PermissionDenied,
                        "scripted refusal of a batch",
                    )
                    .into()));
                }
                let mut offset = 0;
                while offset < payload.len() {
                    let end = (offset + size.get()).min(payload.len());
                    let mut one =
                        rama_udp::SendDatagram::new(datagram.destination(), &payload[offset..end]);
                    if let Some(ecn) = datagram.ecn() {
                        one.set_ecn(ecn);
                    }
                    if let Some(source) = datagram.source_ip() {
                        one.set_source_ip(source);
                    }
                    match self.inner.poll_send(cx, &one) {
                        Poll::Ready(Ok(())) => {
                            log.record(&one);
                            log.spend_credit();
                            offset = end;
                        }
                        stopped => {
                            assert_eq!(
                                offset, 0,
                                "the socket under the fixture stopped after {offset} bytes of a \
                                 batch: neither Pending nor Err can say a prefix left, so this \
                                 batch cannot be reported to the sender"
                            );
                            return stopped;
                        }
                    }
                }
                return Poll::Ready(Ok(()));
            }
            log.rejected_at = log.sent.len();
            log.rejected = Some((SentDatagram::of(datagram), size.get()));
            self.segments.downgraded.store(true, Ordering::SeqCst);
            return Poll::Ready(Err(DatagramError::Unsupported(
                rama_udp::DatagramFeature::Segmentation,
            )));
        }
        if log.rejected.is_some()
            && !log.open
            && log.fallback().len() >= log.hold_after
            && log
                .hold_destination
                .is_none_or(|destination| destination == datagram.destination())
        {
            log.wakers.push(cx.waker().clone());
            return Poll::Pending;
        }
        if log.fail_after == Some(log.sent.len()) {
            return Poll::Ready(Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "scripted refusal after an accepted prefix",
            )
            .into()));
        }
        if log.blackhole
            || log
                .payload_ceiling
                .is_some_and(|ceiling| datagram.payload().len() > ceiling)
        {
            log.record(datagram);
            log.spend_credit();
            return Poll::Ready(Ok(()));
        }
        let result = self.inner.poll_send(cx, datagram);
        if matches!(result, Poll::Ready(Ok(()))) {
            log.record(datagram);
            log.spend_credit();
        }
        result
    }

    fn capabilities(&self) -> DatagramCapabilities {
        self.segments.caps(self.inner.capabilities())
    }
}

/// A real loopback socket that never offers segmentation and records every datagram it sends.
pub(super) fn recording_socket() -> (Socket, Arc<Mutex<SegmentLog>>) {
    let std_socket = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    recording_socket_from(std_socket)
}

pub(super) fn recording_socket_from(
    std_socket: std::net::UdpSocket,
) -> (Socket, Arc<Mutex<SegmentLog>>) {
    let (socket, log, _segments) = segmenting_socket_from(std_socket, usize::MAX);
    (socket, log)
}

pub(super) fn recording_packet_socket(
    inner: rama_udp::UdpPacketSocket,
) -> (Socket, Arc<Mutex<SegmentLog>>) {
    let (socket, log, _, _) = breakable_segmenting_packet_socket(inner, usize::MAX);
    (socket, log)
}

pub(super) fn segmenting_socket(
    hold_after: usize,
) -> (Socket, Arc<Mutex<SegmentLog>>, Arc<Segments>) {
    let std_socket = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    segmenting_socket_from(std_socket, hold_after)
}

pub(super) fn segmenting_socket_from(
    std_socket: std::net::UdpSocket,
    hold_after: usize,
) -> (Socket, Arc<Mutex<SegmentLog>>, Arc<Segments>) {
    let (socket, log, segments, _fault) = breakable_segmenting_socket_from(std_socket, hold_after);
    (socket, log, segments)
}

/// A segmenting socket whose receive side can be failed, so a socket can be retired while it
/// holds part of a descriptor.
pub(super) fn breakable_segmenting_socket(
    hold_after: usize,
) -> (
    Socket,
    Arc<Mutex<SegmentLog>>,
    Arc<Segments>,
    Arc<Mutex<Option<RecvFault>>>,
) {
    let std_socket = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    breakable_segmenting_socket_from(std_socket, hold_after)
}

fn breakable_segmenting_socket_from(
    std_socket: std::net::UdpSocket,
    hold_after: usize,
) -> (
    Socket,
    Arc<Mutex<SegmentLog>>,
    Arc<Segments>,
    Arc<Mutex<Option<RecvFault>>>,
) {
    std_socket.set_nonblocking(true).unwrap();
    let inner = rama_udp::UdpPacketSocket::from_socket(
        tokio::net::UdpSocket::from_std(std_socket).unwrap(),
    )
    .unwrap();
    breakable_segmenting_packet_socket(inner, hold_after)
}

fn breakable_segmenting_packet_socket(
    inner: rama_udp::UdpPacketSocket,
    hold_after: usize,
) -> (
    Socket,
    Arc<Mutex<SegmentLog>>,
    Arc<Segments>,
    Arc<Mutex<Option<RecvFault>>>,
) {
    let log = Arc::new(Mutex::new(SegmentLog {
        hold_after,
        ..SegmentLog::default()
    }));
    let segments = Arc::new(Segments::default());
    let recv_fault = Arc::new(Mutex::new(None));
    let socket = Socket::new(SegmentingSocket {
        inner,
        log: log.clone(),
        segments: segments.clone(),
        recv_fault: recv_fault.clone(),
    })
    .unwrap();
    (socket, log, segments, recv_fault)
}

/// Stop accepting datagrams for `destination`; the sender is told to wait.
/// Stop delivering arrivals to the endpoint; what arrives waits in the kernel.
pub(super) fn close_receive(log: &Mutex<SegmentLog>) {
    log.lock().receive_closed = true;
}

/// Deliver again, waking whatever was waiting to receive.
pub(super) fn open_receive(log: &Mutex<SegmentLog>) {
    let wakers = {
        let mut log = log.lock();
        log.receive_closed = false;
        std::mem::take(&mut log.receive_wakers)
    };
    for waker in wakers {
        waker.wake();
    }
}

pub(super) fn block_segments_for(log: &Mutex<SegmentLog>, destination: SocketAddress) {
    log.lock().blocked = Some(destination);
}

/// Accept `datagrams` more datagrams, then wait.
pub(super) fn credit_segments(log: &Mutex<SegmentLog>, datagrams: usize) {
    log.lock().credit = Some(datagrams);
}

/// Accept datagrams without counting them.
pub(super) fn uncredit_segments(log: &Mutex<SegmentLog>) {
    let wakers = {
        let mut log = log.lock();
        log.credit = None;
        std::mem::take(&mut log.wakers)
    };
    for waker in wakers {
        waker.wake();
    }
}

/// Accept datagrams for every destination again.
pub(super) fn unblock_segments(log: &Mutex<SegmentLog>) {
    let wakers = {
        let mut log = log.lock();
        log.blocked = None;
        std::mem::take(&mut log.wakers)
    };
    for waker in wakers {
        waker.wake();
    }
}

pub(super) fn open_segment_hold(log: &Mutex<SegmentLog>) {
    let wakers = {
        let mut log = log.lock();
        log.open = true;
        std::mem::take(&mut log.wakers)
    };
    for waker in wakers {
        waker.wake();
    }
}

/// After the handshake the socket starts advertising segmentation; the first segmented
/// transmit of three or more segments is rejected, falls back to one datagram per segment on
/// the same handle, and is held after two of them. The client rebinds A→B→C during that
/// partial descriptor. When the hold opens, exactly the
/// remaining original segments leave A with the descriptor's ECN, source and destination,
/// nothing else follows on A, the connection then switches to C (B was superseded unused),
/// the server receives the whole stream and sees C, and A and B retire.
#[tokio::test]
async fn a_partial_segmented_send_completes_on_its_socket_across_repeated_rebinds() {
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket_a, log, segments) = segmenting_socket(2);
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket_a);
    let addr_a = client.local_addr().unwrap();
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    assert_eq!(s.remote_address(), addr_a);
    assert!(
        log.lock().rejected.is_none(),
        "segmentation was not offered during the handshake"
    );
    // Segmentation is offered from here on; the bulk write below is the first candidate.
    segments.arm();

    let payload: Vec<u8> = (0..octets::kib(16)).map(|i| (i % 251) as u8).collect();
    let mut stream = c.open_uni().await.unwrap();
    stream.write_all(&payload).await.unwrap();
    stream.finish().unwrap();
    wait_for(
        "the fallback is held after two segments",
        Duration::from_secs(3),
        || {
            let log = log.lock();
            log.rejected.is_some() && log.fallback().len() == 2
        },
    )
    .await;
    let (rejected, segment_size) = log.lock().rejected.clone().unwrap();
    assert!(
        rejected.bytes.len() > segment_size,
        "a segmented descriptor"
    );
    let segments = rejected.bytes.len().div_ceil(segment_size);
    assert!(
        segments > 2,
        "segments {segments} of {}",
        rejected.bytes.len()
    );

    client.rebind_abstract(loopback_socket()).unwrap();
    client.rebind_abstract(loopback_socket()).unwrap();
    let addr_c = client.local_addr().unwrap();
    wait_for("B is superseded unused", Duration::from_secs(3), || {
        client.stats().retained_sockets == 2
    })
    .await;
    assert_eq!(client.local_addrs(), vec![addr_c, addr_a]);
    assert_eq!(log.lock().fallback().len(), 2, "still held");

    open_segment_hold(&log);
    wait_for(
        "the descriptor completes on A",
        Duration::from_secs(3),
        || log.lock().fallback().len() >= segments,
    )
    .await;
    wait_for(
        "A retires once the connection switched",
        Duration::from_secs(3),
        || client.stats().retained_sockets == 1,
    )
    .await;
    {
        let log = log.lock();
        let fallback = log.fallback();
        assert_eq!(
            fallback.len(),
            segments,
            "the original segments left A exactly once and nothing followed on A"
        );
        let mut bytes = Vec::new();
        for (i, datagram) in fallback.iter().enumerate() {
            bytes.extend_from_slice(&datagram.bytes);
            assert_eq!(datagram.ecn, rejected.ecn, "segment {i} ECN");
            assert_eq!(datagram.source, rejected.source, "segment {i} source");
            assert_eq!(datagram.destination, rejected.destination);
            if i + 1 < fallback.len() {
                assert_eq!(datagram.bytes.len(), segment_size, "segment {i} size");
            }
        }
        assert_eq!(
            bytes, rejected.bytes,
            "the fallback is the descriptor, byte for byte"
        );
    }
    let mut stream = tokio::time::timeout(Duration::from_secs(5), s.accept_uni())
        .await
        .unwrap()
        .unwrap();
    let data = tokio::time::timeout(Duration::from_secs(5), stream.read_to_end(payload.len()))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(data, payload, "the stream arrived whole");
    exchange(&s, &c, b"from server").await;
    exchange(&c, &s, b"from C").await;
    wait_for("the server sees C", Duration::from_secs(5), || {
        s.remote_address() == addr_c
    })
    .await;
    assert_eq!(client.stats().retired_sockets, 2, "B and A");
    assert_eq!(client.local_addrs(), vec![addr_c]);
    assert_eq!(
        log.lock().fallback().len(),
        segments,
        "nothing else ever left A"
    );
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// RFC 9000 §10.3.1 ordering: a datagram carrying a connection ID whose stateless reset route the
/// endpoint has not installed does not reach the socket, and is not discarded. It is sent once the
/// route is confirmed, and the connection keeps receiving while it waits.
///
/// Verifies that the descriptor is built and held (its bytes are read from the connection, so the
/// gate is observed rather than inferred from absence), that no datagram carries the identifier
/// while it waits, that nothing is counted as abandoned, that the identifier is not treated as
/// used, that a stream still arrives, and that those exact bytes are then sent once. Later traffic
/// may carry the same identifier after installation, so the count is of the retained bytes.
#[tokio::test]
async fn a_datagram_waits_for_its_route_and_is_neither_dropped_nor_replayed() {
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket, log) = recording_socket();
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket);
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    exchange(&c, &s, b"before").await;
    let len = active_dcid(&c).len();
    assert!(len > 0, "the server issues non-zero-length connection IDs");

    // Nothing more may be installed from here on.
    client.inner.hold_route_installs();
    let before = active_dcid(&c);
    let sent_before = log.lock().sent.len();

    // Make the peer retire every identifier below the next one, so the connection has to
    // switch to an unused one whose route is not installed.
    // Retiring everything below the next sequence number is what forces the switch; the peer
    // may only name one past what it has issued.
    // Retire everything below the identifier in use plus one, so the connection must switch.
    // Waiting for the descriptor to be held is bounded by wait_for, not by a budget per attempt.
    s.rotate_local_cid(c.active_dcid_seq() + 1);
    wait_for(
        "a datagram is held for its route",
        Duration::from_secs(5),
        || c.held_transmit().is_some(),
    )
    .await;
    // The gate itself is the observation: a datagram is built and held, not merely absent.
    let (held_bytes, held_to, held_seq) = c
        .held_transmit()
        .expect("a datagram is held back for its route");
    let after = active_dcid(&c);
    assert_ne!(after, before, "the connection switched identifier");
    assert_eq!(held_to, server.local_addr().unwrap());
    assert!(held_seq.is_some(), "the held datagram names its identifier");

    // The datagram carrying it is waiting, not gone: nothing on the wire carries the new
    // identifier, and nothing was given up either.
    let carried = |sent: &[SentDatagram]| -> usize {
        short_header_dcids(sent, len)
            .into_iter()
            .filter(|dcid| *dcid == after)
            .count()
    };
    {
        let log = log.lock();
        assert_eq!(
            carried(&log.sent),
            0,
            "a datagram left before its route was installed"
        );
    }
    assert_eq!(
        c.stale_transmits(),
        0,
        "a datagram waiting for a route must not be counted as abandoned"
    );
    assert!(
        !c.active_cid_confirmed(),
        "so the identifier is not used yet"
    );

    // Receiving still works while it waits: the peer's stream arrives.
    exchange(&s, &c, b"while waiting").await;

    // Now let the installation through. Exactly one datagram carries the identifier.
    client.inner.release_route_installs();
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    let carried_now = loop {
        let carried_now = carried(&log.lock().sent);
        if carried_now > 0 {
            break carried_now;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "the datagram never left after its route was installed"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    };
    assert!(carried_now >= 1, "the identifier reached the wire");
    // The datagram that left is the one that was held: same bytes, not a rebuild.
    assert_eq!(
        log.lock()
            .sent
            .iter()
            .filter(|d| d.bytes == held_bytes)
            .count(),
        1,
        "the exact datagram that was held left, once"
    );
    assert!(
        c.held_transmit().is_none(),
        "and nothing is held back any more"
    );
    // Nothing was replayed: no two datagrams carrying this identifier are byte-identical, so
    // the one that waited was sent rather than rebuilt alongside a copy of itself.
    {
        let log = log.lock();
        let mut carrying: Vec<&Vec<u8>> = log
            .sent
            .iter()
            .filter(|d| {
                d.bytes.first().is_some_and(|b| b & 0x80 == 0)
                    && d.bytes
                        .get(1..1 + len)
                        .is_some_and(|dcid| dcid == &after[..])
            })
            .map(|d| &d.bytes)
            .collect();
        let total = carrying.len();
        carrying.sort();
        carrying.dedup();
        assert_eq!(total, carrying.len(), "a datagram was sent twice");
    }
    assert!(
        c.active_cid_confirmed(),
        "and the identifier counts as used only now"
    );
    assert_eq!(c.stale_transmits(), 0, "nothing was abandoned");
    assert!(
        log.lock().sent.len() > sent_before,
        "the wire moved on from where it was held"
    );
    exchange(&c, &s, b"after").await;
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// Verify that a route which cannot be installed does not leave the connection waiting: on
/// refusal the connection closes with the cause it raised, reports it once, wakes a task waiting
/// on a stream, and releases the bytes it was holding, without relying on an idle timeout.
#[tokio::test]
async fn a_refused_route_closes_the_connection_with_its_cause() {
    let (client_config, server_config) = configs();
    let server = endpoint(
        Some(server_config),
        Executor::new(),
        Duration::from_secs(60),
    );
    let (socket, _log) = recording_socket();
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket);
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    exchange(&c, &s, b"before").await;

    // A task waits on this connection. It is polled to Pending against its own waker and is
    // polled again only after that waker fires, so the wake itself is verified rather than a
    // re-poll that observes the error after another future wakes this task.
    let woke = Arc::new(WakeFlag::default());
    let waker = std::task::Waker::from(woke.clone());
    let mut accept = std::pin::pin!(c.accept_uni());
    assert!(
        accept
            .as_mut()
            .poll(&mut Context::from_waker(&waker))
            .is_pending(),
        "the accept future is waiting, not already resolved"
    );

    client.inner.hold_route_installs();
    // Retire everything below the identifier in use plus one, so the connection must switch.
    // Waiting for the descriptor to be held is bounded by wait_for, not by a budget per attempt.
    s.rotate_local_cid(c.active_dcid_seq() + 1);
    wait_for(
        "a datagram is held for its route",
        Duration::from_secs(5),
        || c.held_transmit().is_some(),
    )
    .await;
    assert!(
        c.held_transmit().is_some(),
        "a datagram is held for a route"
    );

    // The endpoint has no room for it. The connection must fail, not wait.
    client.inner.refuse_route_installs();
    let closed = tokio::time::timeout(Duration::from_secs(2), c.closed())
        .await
        .expect("a refused route closed the connection without waiting for a timeout");
    // Equality on `TransportError` compares only the code, so a substituted INTERNAL_ERROR
    // would pass a code check. The diagnostic is what tells them apart.
    match &closed {
        ConnectionError::TransportError(error) => {
            assert_eq!(
                error.code,
                rama_quic_proto::TransportErrorCode::INTERNAL_ERROR,
                "{error:?}"
            );
            assert_eq!(
                error.reason, "no room to route a stateless reset for a connection ID",
                "the diagnostic the refusal raised"
            );
        }
        other => panic!("expected the original transport error, got {other:?}"),
    }

    // Verify that the waiter receives the refusal reason.
    // Its own waker has to fire before it is polled again.
    tokio::time::timeout(Duration::from_secs(2), woke.fired())
        .await
        .expect("the waiting reader's waker fired");
    let woken = match accept.as_mut().poll(&mut Context::from_waker(&waker)) {
        Poll::Ready(Err(error)) => error,
        other => panic!("after the wake the reader had {other:?}"),
    };
    match &woken {
        ConnectionError::TransportError(error) => assert_eq!(
            error.reason, "no room to route a stateless reset for a connection ID",
            "the waiter was given the same diagnostic"
        ),
        other => panic!("the waiter was given {other:?}"),
    }
    assert!(
        c.held_transmit().is_none(),
        "the descriptor that was held is released; this says nothing about the sender's own \
         buffers, which the partial-prefix composition covers"
    );
    assert_eq!(
        c.closed().await.to_string(),
        closed.to_string(),
        "the same reason every time it is asked"
    );
    // `c` is already closed by the refusal and its accept future borrows it, so it goes out
    // of scope here rather than being dropped early.
    drop(s);
    tokio::join!(client.shutdown(), server.shutdown());
}

/// Shutting down while a descriptor is partly accepted completes rather than waiting for the
/// remainder: one segment has been taken, the rest is still held by the sender, and both endpoints
/// finish shutting down within their budget.
#[tokio::test]
async fn shutdown_completes_while_a_descriptor_is_partly_accepted() {
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket, log, segments) = segmenting_socket(1);
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket);
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    exchange(&c, &s, b"before").await;
    segments.arm();

    let payload: Vec<u8> = (0..octets::kib(16)).map(|i| (i % 251) as u8).collect();
    let mut stream = c.open_uni().await.unwrap();
    stream.write_all(&payload).await.unwrap();
    stream.finish().unwrap();
    wait_for(
        "the descriptor is held after one accepted segment",
        Duration::from_secs(5),
        || {
            let log = log.lock();
            log.rejected.is_some() && log.fallback().len() == 1
        },
    )
    .await;
    let (rejected, segment_size) = log.lock().rejected.clone().unwrap();
    assert!(
        rejected.bytes.len() > segment_size,
        "part of the descriptor is still unsent"
    );
    let accepted = log.lock().fallback().len();
    assert_eq!(accepted, 1);

    // A stream is still open on the connection. `write_all` only buffers, so it succeeds here;
    // what shutting down has to do is terminate the connection so nothing is left waiting.
    let mut live = c.open_uni().await.unwrap();
    live.write_all(b"buffered before the shutdown")
        .await
        .unwrap();

    // Register a reader before the shutdown and check its wakeup and close error.
    let waker = Arc::new(WakeCount(AtomicUsize::new(0)));
    let task: Waker = waker.clone().into();
    let mut cx = Context::from_waker(&task);
    let mut accept = Box::pin({
        let c = c.clone();
        async move { c.accept_uni().await }
    });
    assert!(
        accept.as_mut().poll(&mut cx).is_pending(),
        "no stream has arrived, so the reader waits"
    );

    // Shut down with the remainder still in the sender's hands.
    drop(s);
    let (client_outcome, server_outcome) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(client.shutdown(), server.shutdown())
    })
    .await
    .expect("both endpoints shut down while a descriptor was partly accepted");
    // Both drain: a sender still holding part of a descriptor does not stop the endpoint from
    // shutting down cleanly, and neither side is forced.
    assert_eq!(client_outcome, ShutdownOutcome::Drained, "the client");
    assert_eq!(server_outcome, ShutdownOutcome::Drained, "the server");
    // The connection is terminated, and the stream that was open reports it rather than hanging.
    tokio::time::timeout(Duration::from_secs(5), c.closed())
        .await
        .expect("the connection reports its termination");
    assert!(
        tokio::time::timeout(Duration::from_secs(5), live.write_all(b"after"))
            .await
            .expect("the write resolves rather than waiting")
            .is_err(),
        "a write after the shutdown fails"
    );
    assert!(
        tokio::time::timeout(Duration::from_secs(5), c.open_uni())
            .await
            .expect("opening resolves rather than waiting")
            .is_err(),
        "and no new stream can be opened"
    );
    assert_eq!(
        log.lock().fallback().len(),
        accepted,
        "the held remainder was not sent by the shutdown"
    );
    assert!(
        waker.0.load(Ordering::SeqCst) > 0,
        "the waiting reader was woken by the shutdown, not left for someone else's poll"
    );
    match accept.as_mut().poll(&mut cx) {
        Poll::Ready(Err(error)) => assert_matches!(
            error,
            ConnectionError::LocallyClosed,
            "the reader is given the connection's own cause: {error:?}",
        ),
        other => panic!("the waiting reader resolves once the connection is gone: {other:?}"),
    }
    assert_eq!(
        client.stats().retained_sockets,
        0,
        "the endpoint's registry holds no socket"
    );

    // The fixture Arc is owned by the socket and each sender, so one reference left is the
    // test's own.
    drop(accept);
    drop(live);
    drop(c);
    wait_for(
        "the socket and every sender made from it are destroyed",
        Duration::from_secs(5),
        || Arc::strong_count(&segments) == 1,
    )
    .await;
}

/// What the fixture was offered, for a wait that did not get the batch it needed.
fn offers(log: &Mutex<SegmentLog>) -> String {
    let log = log.lock();
    format!(
        "segmented offers {:?}, {} datagrams sent, rejected {}",
        log.segmented_offers,
        log.sent.len(),
        log.rejected.is_some()
    )
}

/// The connection counts an identifier as used from the first segment the socket accepted, not
/// from the completion of the descriptor that carried it. The descriptor is deliberately left
/// unfinished: one segment is accepted and the rest is held, and the identifier is already
/// recognised for that address.
///
/// This fails if `drive_transmit` reports `cid_sent` only when the sender returns `Ready(Ok)`.
#[tokio::test]
async fn an_accepted_prefix_is_reported_before_its_descriptor_completes() {
    let (mut client_config, server_config) = configs();
    // This window disables pacing so RTT cannot prevent the segmented descriptor we inspect.
    client_config.set_transport_config(Arc::new(
        TransportConfig::default()
            .try_with_initial_congestion_window(u64::from(u32::MAX) + 1)
            .unwrap(),
    ));
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket, log, segments) = segmenting_socket(1);
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket);
    let server_addr = server.local_addr().unwrap();
    let connecting = client
        .connect_with(client_config, server_addr, "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    exchange(&c, &s, b"before").await;
    let seq = c.active_dcid_seq();
    segments.arm();
    // A bulk write becomes a segmented descriptor, is downgraded, and is held after one segment.
    let payload: Vec<u8> = (0..octets::kib(16)).map(|i| (i % 251) as u8).collect();
    let mut stream = c.open_uni().await.unwrap();
    stream.write_all(&payload).await.unwrap();
    stream.finish().unwrap();
    wait_for_with(
        "one segment is accepted and the rest is held",
        Duration::from_secs(10),
        || {
            let log = log.lock();
            log.rejected.is_some() && log.fallback().len() == 1
        },
        || offers(&log),
    )
    .await;
    let (rejected, segment_size) = log.lock().rejected.clone().unwrap();
    assert!(
        rejected.bytes.len() > segment_size,
        "the descriptor is unfinished: it has segments left"
    );
    assert!(
        c.held_transmit().is_some(),
        "and the driver is still holding it"
    );

    // The report is tied to the descriptor that was held, not to the window: the offer recorded
    // as Pending for this identifier and destination is the one that must have reported. A
    // control descriptor completing in the same window cannot stand in for it.
    // Several descriptors share this identifier and destination, so the record is selected by the
    // descriptor's own bytes: the one the fixture rejected and is now holding.
    let held_offer = c
        .descriptors()
        .into_iter()
        .rev()
        .find(|d| {
            d.outcome == crate::driver::connection::Outcome::Pending
                && d.cid_used == Some(seq)
                && d.destination == server_addr
                && d.bytes == rejected.bytes
        })
        .expect("the held descriptor is on record as Pending with its own bytes");
    assert_eq!(
        held_offer.size,
        rejected.bytes.len(),
        "and with its own size"
    );
    assert!(
        held_offer.reported,
        "the partially accepted descriptor did not report its identifier: id {} size {} cid {:?} \
         to {} outcome {:?}",
        held_offer.id,
        held_offer.size,
        held_offer.cid_used,
        held_offer.destination,
        held_offer.outcome
    );
    assert!(c.cid_confirmed_to(seq, server_addr));

    open_segment_hold(&log);
    let mut incoming = tokio::time::timeout(Duration::from_secs(5), s.accept_uni())
        .await
        .expect("the stream arrives")
        .expect("the connection is alive");
    let received = tokio::time::timeout(
        Duration::from_secs(5),
        incoming.read_to_end(payload.len() + 1),
    )
    .await
    .expect("the stream completes")
    .expect("it is not truncated");
    assert_eq!(received, payload);
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// The error path carries the same guarantee as the Pending path: a prefix the sender accepted has
/// left, so the connection is told its identifier reached the network even though the descriptor
/// then failed. The offer's own record is the observation, so a report for some other descriptor
/// cannot stand in for it.
#[tokio::test]
async fn an_accepted_prefix_is_reported_when_the_descriptor_then_fails() {
    let (mut client_config, server_config) = configs();
    // Disable pacing so RTT cannot keep offers below the fixture's three-segment threshold.
    client_config.set_transport_config(Arc::new(
        TransportConfig::default()
            .try_with_initial_congestion_window(u64::from(u32::MAX) + 1)
            .unwrap(),
    ));
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket, log, segments) = segmenting_socket(1);
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket);
    let server_addr = server.local_addr().unwrap();
    let connecting = client
        .connect_with(client_config, server_addr, "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    exchange(&c, &s, b"before").await;
    let seq = c.active_dcid_seq();
    segments.arm();

    let payload: Vec<u8> = (0..octets::kib(16)).map(|i| (i % 251) as u8).collect();
    let mut stream = c.open_uni().await.unwrap();
    stream.write_all(&payload).await.unwrap();
    stream.finish().unwrap();
    // Let the descriptor be downgraded and leave one segment, then hold.
    wait_for_with(
        "one segment of the descriptor is accepted",
        Duration::from_secs(10),
        || {
            let log = log.lock();
            log.rejected.is_some() && log.fallback().len() == 1
        },
        || offers(&log),
    )
    .await;
    let (rejected, _) = log.lock().rejected.clone().unwrap();

    // Refuse the very next datagram, which is this descriptor's second segment, and let it run.
    {
        let mut log = log.lock();
        log.fail_after = Some(log.sent.len());
    }
    open_segment_hold(&log);
    wait_for(
        "the descriptor fails after its accepted prefix",
        Duration::from_secs(10),
        || {
            c.descriptors().iter().any(|d| {
                d.outcome == crate::driver::connection::Outcome::Failed && d.bytes == rejected.bytes
            })
        },
    )
    .await;

    let failed = c
        .descriptors()
        .into_iter()
        .rev()
        .find(|d| {
            d.outcome == crate::driver::connection::Outcome::Failed && d.bytes == rejected.bytes
        })
        .expect("the failed offer is on record with its own bytes");
    assert_eq!(failed.cid_used, Some(seq));
    assert_eq!(failed.destination, server_addr);
    assert!(
        failed.reported,
        "the descriptor that failed after a prefix did not report its identifier: id {} size {}",
        failed.id, failed.size
    );
    assert!(c.cid_confirmed_to(seq, server_addr));
    // One segment of this descriptor was accepted before the refusal, and no more.
    assert_eq!(
        log.lock().fallback().len(),
        1,
        "the prefix left and the refusal stopped the rest"
    );

    // The connection recovers: the stream still completes once the refusal is lifted.
    log.lock().fail_after = None;
    let mut incoming = tokio::time::timeout(Duration::from_secs(5), s.accept_uni())
        .await
        .expect("the stream arrives")
        .expect("the connection is alive");
    let received = tokio::time::timeout(
        Duration::from_secs(5),
        incoming.read_to_end(payload.len() + 1),
    )
    .await
    .expect("the stream completes")
    .expect("it is not truncated");
    assert_eq!(received, payload);
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// The credit the segmenting fixture uses counts datagrams the backend accepted, not attempts.
/// A rejection, a Pending, and each datagram of an emulated segmented descriptor are charged the
/// way the tests below rely on, so the determinism mechanism itself is not the thing under test.
#[test]
fn the_segment_credit_charges_accepted_datagrams_only() {
    #[derive(Debug)]
    struct StepSender(std::collections::VecDeque<Poll<Result<(), DatagramError>>>);
    impl DatagramSender for StepSender {
        fn poll_send(
            &mut self,
            _: &mut Context<'_>,
            _: &rama_udp::SendDatagram<'_>,
        ) -> Poll<Result<(), DatagramError>> {
            self.0.pop_front().expect("scripted response")
        }
        fn capabilities(&self) -> DatagramCapabilities {
            DatagramCapabilities::portable()
        }
    }
    let to = SocketAddress::from(([127, 0, 0, 2], 9));
    let plain = |payload: &'static [u8]| rama_udp::SendDatagram::new(to, payload);
    let mut cx = Context::from_waker(Waker::noop());

    // A rejection and a Pending leave the credit alone, so the retry still has it.
    let log = Arc::new(Mutex::new(SegmentLog {
        credit: Some(1),
        ..SegmentLog::default()
    }));
    let mut sender = SegmentingSender {
        inner: StepSender(
            [
                Poll::Ready(Err(io::Error::other("refused").into())),
                Poll::Pending,
                Poll::Ready(Ok(())),
                Poll::Ready(Ok(())),
            ]
            .into(),
        ),
        log: log.clone(),
        segments: Arc::new(Segments::default()),
    };
    assert_matches!(sender.poll_send(&mut cx, &plain(b"a")), Poll::Ready(Err(_)));
    assert_eq!(log.lock().credit, Some(1), "a rejection charges nothing");
    assert!(sender.poll_send(&mut cx, &plain(b"a")).is_pending());
    assert_eq!(log.lock().credit, Some(1), "a Pending charges nothing");
    assert_matches!(sender.poll_send(&mut cx, &plain(b"a")), Poll::Ready(Ok(())));
    assert_eq!(
        log.lock().credit,
        Some(0),
        "an accepted datagram charges one"
    );
    assert_eq!(log.lock().sent.len(), 1);
    // With none left the sender waits, and does not consume the scripted acceptance.
    assert!(sender.poll_send(&mut cx, &plain(b"a")).is_pending());
    assert_eq!(log.lock().sent.len(), 1, "nothing more was sent");

    // A segmented descriptor is taken whole or not at all. `Pending` tells the sender its
    // descriptor was untouched, and no backend can put part of a batch on the wire under that
    // answer: one `sendmsg` accepts every segment or none. Bytes that left with the sender
    // believing nothing had would never be accounted for.
    let log = Arc::new(Mutex::new(SegmentLog {
        credit: Some(1),
        ..SegmentLog::default()
    }));
    let segments = Arc::new(Segments::default());
    segments.arm();
    let mut sender = SegmentingSender {
        inner: StepSender([Poll::Ready(Ok(())), Poll::Ready(Ok(()))].into()),
        log: log.clone(),
        segments,
    };
    let payload = [1u8, 1, 2, 2];
    let mut segmented = rama_udp::SendDatagram::new(to, &payload[..]);
    segmented.set_segment_size(NonZeroUsize::new(2).unwrap());
    assert!(
        sender.poll_send(&mut cx, &segmented).is_pending(),
        "one credit is not enough for a batch of two"
    );
    assert_eq!(log.lock().sent.len(), 0, "and nothing left the socket");
    assert_eq!(log.lock().credit, Some(1), "the credit is untouched");
    // With credit for the whole batch it goes, one datagram at a time as an offload would.
    log.lock().credit = Some(2);
    assert_matches!(sender.poll_send(&mut cx, &segmented), Poll::Ready(Ok(())));
    let log = log.lock();
    assert_eq!(log.sent.len(), 2);
    assert_eq!(log.sent[0].bytes, [1, 1]);
    assert_eq!(log.sent[1].bytes, [2, 2]);
    assert_eq!(log.credit, Some(0), "and each datagram was charged");
}

/// A pass that spends its allowance on a descriptor that was already waiting asks for another
/// turn. Bytes that left leave no waker behind, so a pass that ends there without asking would
/// leave the engine's remaining work until some unrelated event came along. The allowance is
/// lowered for this test so the end of a pass is reachable with one datagram.
#[tokio::test]
async fn a_pass_that_spends_its_allowance_on_bytes_that_left_asks_for_another_turn() {
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket, log, _segments) = segmenting_socket(usize::MAX);
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket);
    let server_addr = server.local_addr().unwrap();
    let connecting = client
        .connect_with(client_config, server_addr, "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(5), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    exchange(&c, &s, b"before").await;
    c.set_pass_allowance(1);

    // Nothing leaves until this test says so, so what follows is a descriptor already waiting on
    // the handle rather than one the pass just produced.
    credit_segments(&log, 0);
    let payload = vec![0x5a; octets::kib(32)];
    let mut stream = c.open_uni().await.unwrap();
    stream.write_all(&payload).await.unwrap();
    stream.finish().unwrap();
    wait_for(
        "a descriptor waits on the handle",
        Duration::from_secs(5),
        || c.held_transmit().is_some(),
    )
    .await;
    assert_eq!(
        c.retry_allowance_ends(),
        (0, 0),
        "no pass has spent its allowance on a waiting descriptor yet"
    );

    uncredit_segments(&log);
    wait_for(
        "a pass spends its allowance sending what waited, and asks for another turn",
        Duration::from_secs(10),
        || c.retry_allowance_ends().0 > 0,
    )
    .await;
    assert_eq!(
        c.retry_allowance_ends().1,
        0,
        "and no such pass parked instead"
    );

    // The peer gets every byte, in order.
    let mut incoming = tokio::time::timeout(Duration::from_secs(10), s.accept_uni())
        .await
        .expect("the stream arrives")
        .expect("the connection is alive");
    let received = tokio::time::timeout(
        Duration::from_secs(10),
        incoming.read_to_end(payload.len() + 1),
    )
    .await
    .expect("the stream completes")
    .expect("it is not truncated");
    assert_eq!(received, payload);
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// The other half of that rule: a pass that spends its allowance waiting does not ask for another
/// turn, because what it waits on holds this task's waker. With the socket taking nothing, the
/// connection must not poll in a loop.
#[tokio::test]
async fn a_pass_that_spends_its_allowance_waiting_does_not_poll_in_a_loop() {
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket, log, _segments) = segmenting_socket(usize::MAX);
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket);
    let server_addr = server.local_addr().unwrap();
    let connecting = client
        .connect_with(client_config, server_addr, "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(5), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    exchange(&c, &s, b"before").await;
    c.set_pass_allowance(1);

    credit_segments(&log, 0);
    let payload = vec![0x5a; octets::kib(32)];
    let mut stream = c.open_uni().await.unwrap();
    stream.write_all(&payload).await.unwrap();
    stream.finish().unwrap();
    wait_for(
        "a descriptor waits on the handle",
        Duration::from_secs(5),
        || c.held_transmit().is_some(),
    )
    .await;

    // The socket keeps taking nothing. Every pass from here offers what waits, is told to wait,
    // and gives the task back; the sender holds the waker, so nothing should schedule the
    // connection again by itself.
    let passes = c.send_passes();
    tokio::time::sleep(Duration::from_millis(300)).await;
    let spun = c.send_passes() - passes;
    assert!(
        spun < 50,
        "the connection ran {spun} send passes in 300ms while its socket took nothing"
    );
    assert_eq!(
        c.retry_allowance_ends().1,
        0,
        "and no pass that only waited counted as one that sent"
    );

    uncredit_segments(&log);
    let mut incoming = tokio::time::timeout(Duration::from_secs(10), s.accept_uni())
        .await
        .expect("the stream arrives")
        .expect("the connection is alive");
    let received = tokio::time::timeout(
        Duration::from_secs(10),
        incoming.read_to_end(payload.len() + 1),
    )
    .await
    .expect("the stream completes")
    .expect("it is not truncated");
    assert_eq!(received, payload);
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// RFC 9001 §6.1: an endpoint does not initiate a key update before the handshake is confirmed.
/// A client is established once its own TLS handshake finishes, which is earlier: it is confirmed
/// only once HANDSHAKE_DONE arrives. Between the two, asking for an update changes nothing; after
/// it, the update happens and traffic keeps flowing.
#[tokio::test]
async fn a_client_updates_keys_only_once_its_handshake_is_confirmed() {
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let client = endpoint(None, Executor::new(), Duration::from_secs(1));
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(5), server.accept())
        .await
        .unwrap()
        .unwrap();
    let server_connecting = incoming.accept().unwrap();
    // The server holds HANDSHAKE_DONE, so the client finishes its own handshake and waits for
    // the confirmation that would let it update keys.
    server_connecting.hold_handshake_done(true);
    let (c, s) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(connecting, server_connecting)
    })
    .await
    .expect("both sides complete the handshake");
    let (c, s) = (c.unwrap(), s.unwrap());

    assert!(
        !c.force_key_update(),
        "an unconfirmed client does not initiate a key update"
    );
    assert_eq!(
        c.stats().key_updates,
        0,
        "and its keys are the ones it started with"
    );

    s.hold_handshake_done(false);
    tokio::time::timeout(Duration::from_secs(5), c.handshake_confirmed())
        .await
        .expect("the confirmation arrives")
        .unwrap();

    assert!(
        c.force_key_update(),
        "a confirmed client initiates the update"
    );
    assert_eq!(c.stats().key_updates, 1, "and counts it");
    assert!(
        !c.force_key_update(),
        "a second one waits for the first to be acknowledged"
    );
    assert_eq!(c.stats().key_updates, 1, "so the count does not move");

    // Traffic after the update arrives, which is what the update must not disturb.
    exchange(&c, &s, b"after the key update").await;
    exchange(&s, &c, b"and back").await;
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// RFC 9000 §10.3.1 at the first acceptance: an identifier whose route is installed but which
/// nothing has been sent with is not one this connection has used. The first datagram the socket
/// accepts for it makes it used, for that datagram's address.
///
/// The socket is credited with exactly one accepted datagram, so which acceptance grants the
/// history is not a race. In this scenario that datagram is the connection's own control traffic
/// rather than the bulk descriptor's opening segment. What this does *not* cover is the
/// connection reporting a partially accepted descriptor: the sender-level test
/// `a_prefix_accepted_before_an_error_counts_and_leaves_no_offset` covers the sender's own
/// accounting, not `drive_transmit`'s call to `cid_sent`.
#[tokio::test]
async fn the_first_accepted_datagram_grants_a_fresh_identifier_its_history() {
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket, log, segments) = segmenting_socket(1);
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket);
    let server_addr = server.local_addr().unwrap();
    let connecting = client
        .connect_with(client_config, server_addr, "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    exchange(&c, &s, b"before").await;
    let before_seq = c.active_dcid_seq();

    // Segmentation stays off until the observation below is done: it counts datagrams one at a
    // time, which is only the same thing as counting descriptors while a descriptor is one
    // datagram. Under load the engine has enough to say to fill a batch.
    // Nothing can leave from here, so the identifier the connection switches to stays unused.
    block_segments_for(&log, SocketAddress::from(server_addr));
    let payload: Vec<u8> = (0..octets::kib(16)).map(|i| (i % 251) as u8).collect();
    let mut stream = c.open_uni().await.unwrap();
    stream.write_all(&payload).await.unwrap();
    stream.finish().unwrap();
    s.rotate_local_cid(before_seq + 1);
    wait_for(
        "the connection switches to an unused identifier",
        Duration::from_secs(5),
        || c.active_dcid_seq() != before_seq,
    )
    .await;
    let fresh_seq = c.active_dcid_seq();
    let fresh_dcid = active_dcid(&c);
    assert!(
        !c.cid_confirmed(fresh_seq),
        "nothing has been sent with the identifier the connection switched to"
    );
    assert!(
        !c.cid_confirmed_to(fresh_seq, server_addr),
        "and nothing towards this address in particular"
    );
    // The route is installed while the send is blocked, and the descriptor waiting on the socket
    // already names the fresh identifier, so what follows is that descriptor's own first segment.
    let held = c
        .held_transmit()
        .expect("a descriptor is waiting on the blocked socket");
    assert_eq!(
        held.2,
        Some(fresh_seq),
        "the held descriptor carries the fresh identifier"
    );
    // The route is installed: the permit says the identifier may be sent to this address, which
    // is what installation means. It is held by the socket, not by the gate.
    assert_eq!(
        c.send_permit(fresh_seq, server_addr),
        crate::proto::SendPermit::Sendable,
        "the fresh identifier's route is installed while the socket is blocked"
    );
    assert!(
        short_header_dcids(&log.lock().sent, fresh_dcid.len())
            .iter()
            .all(|dcid| *dcid != fresh_dcid),
        "no datagram used the fresh identifier before the descriptor under test"
    );

    // Datagrams are released one at a time, so the first acceptance carrying this identifier is
    // observable whichever datagram wins a slot. Before that one the identifier is not used
    // towards the address; the report follows it. The report is waited for separately: the socket
    // records a datagram inside its send call, before the driver reports the identifier.
    // These waits are for a driver task to be scheduled after a socket-level event, so they are
    // given a budget that survives a saturated host; the conditions themselves are unchanged.
    const SCHEDULED: Duration = Duration::from_secs(20);
    let mut released = 0;
    loop {
        assert!(
            released < 8,
            "the identifier reached the wire within {released} datagrams"
        );
        let accepted = log.lock().sent.len();
        credit_segments(&log, 1);
        unblock_segments(&log);
        wait_for("one datagram is accepted", SCHEDULED, || {
            log.lock().sent.len() > accepted
        })
        .await;
        released += 1;
        let carried = {
            let log = log.lock();
            short_header_dcids(&log.sent, fresh_dcid.len()).contains(&fresh_dcid)
        };
        if carried {
            break;
        }
        assert!(
            !c.cid_confirmed_to(fresh_seq, server_addr),
            "nothing carrying the identifier has been accepted yet"
        );
    }
    wait_for_with(
        "the identifier is used towards that address",
        SCHEDULED,
        || c.cid_confirmed_to(fresh_seq, server_addr),
        || {
            let offered = c
                .descriptors()
                .iter()
                .map(|d| {
                    format!(
                        "#{} size {} seg {:?} cid {:?} {:?} reported {}",
                        d.id, d.size, d.segment_size, d.cid_used, d.outcome, d.reported
                    )
                })
                .collect::<Vec<_>>();
            format!(
                "fresh_seq {fresh_seq}, active_seq {}, permit {:?}, used anywhere {}, \
                 reports {}, released {released}, wire dcids {:?}, fresh dcid {:?}, \
                 peer {server_addr}, offered {offered:?}",
                c.active_dcid_seq(),
                c.send_permit(fresh_seq, server_addr),
                c.cid_confirmed(fresh_seq),
                c.cid_sent_calls(),
                short_header_dcids(&log.lock().sent, fresh_dcid.len()),
                fresh_dcid,
            )
        },
    )
    .await;
    // That first acceptance is the prefix under test: the first datagram carrying the fresh
    // identifier is the one the socket took after unblocking, and nothing carried it before.
    let carrying: Vec<Vec<u8>> = {
        let log = log.lock();
        short_header_dcids(&log.sent, fresh_dcid.len())
            .into_iter()
            .filter(|dcid| *dcid == fresh_dcid)
            .collect()
    };
    assert_eq!(
        carrying.len(),
        1,
        "exactly one datagram has carried the fresh identifier so far"
    );
    let last = log
        .lock()
        .sent
        .last()
        .cloned()
        .expect("a datagram was sent");
    assert_eq!(
        short_header_dcids(std::slice::from_ref(&last), fresh_dcid.len()),
        vec![fresh_dcid.clone()],
        "and it is the datagram the socket last took"
    );
    assert_eq!(
        last.destination,
        SocketAddress::from(server_addr),
        "it went to the address the identifier is recognised at"
    );

    // The rest follows once segmentation, the credit and the hold are lifted, and the peer
    // receives every byte.
    segments.arm();
    uncredit_segments(&log);
    open_segment_hold(&log);
    let mut incoming = tokio::time::timeout(Duration::from_secs(5), s.accept_uni())
        .await
        .expect("the stream arrives")
        .expect("the connection is alive");
    let received = tokio::time::timeout(
        Duration::from_secs(5),
        incoming.read_to_end(payload.len() + 1),
    )
    .await
    .expect("the stream completes")
    .expect("it is not truncated");
    assert_eq!(received, payload);
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A prefix the sender accepted has been sent and is not offered again. When the identifier that
/// descriptor carries is retired while the remainder is held, only the unsent suffix is given up,
/// and a following descriptor shorter than the offset the abandoned one reached is sent whole
/// rather than spliced at that offset.
#[tokio::test]
async fn a_retirement_mid_descriptor_gives_up_only_the_unsent_suffix() {
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket, log, segments) = segmenting_socket(2);
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket);
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    exchange(&c, &s, b"before").await;
    let doomed = active_dcid(&c);
    let doomed_seq = c.active_dcid_seq();
    assert!(!doomed.is_empty(), "non-zero-length connection IDs");
    assert!(
        c.cid_confirmed(doomed_seq),
        "it has been carrying traffic, so it counts as used before any of this"
    );
    segments.arm();

    // A bulk write becomes a segmented descriptor, is downgraded to one datagram per segment,
    // and is held after two of them.
    let payload: Vec<u8> = (0..octets::kib(16)).map(|i| (i % 251) as u8).collect();
    let mut stream = c.open_uni().await.unwrap();
    stream.write_all(&payload).await.unwrap();
    stream.finish().unwrap();
    wait_for(
        "the fallback is held after two segments",
        Duration::from_secs(3),
        || {
            let log = log.lock();
            log.rejected.is_some() && log.fallback().len() == 2
        },
    )
    .await;
    let (rejected, segment_size) = log.lock().rejected.clone().unwrap();
    let total = rejected.bytes.len().div_ceil(segment_size);
    assert!(total > 2, "the descriptor has a suffix left to abandon");
    let accepted: Vec<Vec<u8>> = log
        .lock()
        .fallback()
        .iter()
        .map(|d| d.bytes.clone())
        .collect();
    assert_eq!(accepted.len(), 2);
    let offset: usize = accepted.iter().map(Vec::len).sum();

    // The peer retires that identifier while the remainder is still held.
    s.rotate_local_cid(c.active_dcid_seq() + 1);
    wait_for(
        "the identifier the held descriptor carries is retired",
        Duration::from_secs(5),
        || active_dcid(&c) != doomed,
    )
    .await;
    assert_ne!(active_dcid(&c), doomed, "the identifier was retired");
    assert!(
        !c.cid_confirmed(doomed_seq),
        "retirement ends its history: there is no route left to recognise a reset by"
    );

    // Let the socket go: the unsent suffix is given up, and only it.
    open_segment_hold(&log);
    wait_for(
        "the abandoned descriptor is accounted for",
        Duration::from_secs(3),
        || c.stale_transmits() >= 1,
    )
    .await;
    assert_eq!(
        c.stale_transmits(),
        1,
        "exactly one descriptor was given up, not a stream of them"
    );

    // The stream survives: what the abandoned suffix carried is retransmitted under the
    // identifier now in use, so the peer still receives every byte in order.
    let mut incoming = tokio::time::timeout(Duration::from_secs(5), s.accept_uni())
        .await
        .expect("the bulk stream arrives")
        .expect("the connection is alive");
    let received = tokio::time::timeout(
        Duration::from_secs(5),
        incoming.read_to_end(payload.len() + 1),
    )
    .await
    .expect("the bulk stream completes")
    .expect("it is not truncated");
    assert_eq!(received, payload, "every byte, in order");

    // The descriptor the driver offered after the abandoned one, named by its own id rather than
    // inferred from datagram sizes. It has to be shorter than the offset the abandoned one
    // reached, which is the case a retained offset used to corrupt, and it has to have been sent.
    let offered = c.descriptors();
    let abandoned = offered
        .iter()
        .rposition(|d| d.outcome == crate::driver::connection::Outcome::Obsolete)
        .expect("the abandoned descriptor is on record");
    assert_eq!(
        offered[abandoned].cid_used,
        Some(doomed_seq),
        "the abandoned descriptor carried the retired identifier"
    );
    let successor = offered[abandoned + 1..]
        .iter()
        .find(|d| d.id != offered[abandoned].id)
        .expect("a descriptor followed it");
    assert!(
        successor.size < offset,
        "the successor descriptor is {} bytes, not shorter than the abandoned offset {offset}",
        successor.size
    );
    assert_ne!(
        successor.cid_used,
        Some(doomed_seq),
        "the successor carries an identifier that is still usable"
    );
    // A descriptor may be held for its route before it is taken, so what matters is that this
    // one was taken in the end, under its own id.
    let taken = offered
        .iter()
        .filter(|d| d.id == successor.id)
        .find(|d| d.outcome == crate::driver::connection::Outcome::Sent)
        .unwrap_or_else(|| {
            panic!(
                "the successor descriptor was never taken: {:?}",
                offered
                    .iter()
                    .filter(|d| d.id == successor.id)
                    .collect::<Vec<_>>()
            )
        });
    // `Sent` only says the sender returned Ok, which a stale offset could also do. Compare what
    // the connection built with what the socket accepted, including its destination. The
    // successor is one datagram, so its bytes appear exactly once.
    assert!(
        taken.segment_size.is_none_or(|size| size >= taken.size),
        "the successor is a single datagram, not a segmented descriptor"
    );
    {
        // The socket's record is read under its lock, which is released before the shutdown
        // below writes to it.
        {
            let log = log.lock();
            let matching: Vec<&SentDatagram> =
                log.sent.iter().filter(|d| d.bytes == taken.bytes).collect();
            assert_eq!(
                matching.len(),
                1,
                "the successor's bytes reached the socket exactly once"
            );
            assert_eq!(
                matching[0].destination,
                SocketAddress::from(taken.destination),
                "at the destination it was built for"
            );
        }

        let log = log.lock();
        for bytes in &accepted {
            assert_eq!(
                log.sent.iter().filter(|d| &d.bytes == bytes).count(),
                1,
                "an accepted datagram was sent twice"
            );
        }
        // The suffix is several datagrams, not one: each unsent segment has to be absent on its
        // own, or a single forbidden segment could slip through a comparison against their
        // concatenation.
        let segments: Vec<&[u8]> = rejected.bytes.chunks(segment_size).collect();
        assert_eq!(segments.len(), total, "the descriptor's own segmentation");
        for (i, segment) in segments.iter().enumerate().take(accepted.len()) {
            assert_eq!(
                accepted[i], *segment,
                "the accepted prefix is the descriptor's first segments, in order"
            );
        }
        for (i, segment) in segments.iter().enumerate().skip(accepted.len()) {
            assert!(
                !log.sent.iter().any(|d| d.bytes == *segment),
                "unsent segment {i} of the abandoned descriptor reached the wire"
            );
        }
        // And nothing at all went out under the retired identifier after it was retired.
        assert!(
            !short_header_dcids(&log.sent[log.rejected_at + accepted.len()..], doomed.len())
                .contains(&doomed),
            "a datagram used the retired identifier after it was retired"
        );
    }
    drop((c, s));
    tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(client.shutdown(), server.shutdown());
    })
    .await
    .expect("both endpoints shut down after a descriptor was abandoned mid-send");
}

/// The stand-in for an offload is one call to the socket underneath: it takes every segment of a
/// batch or none. A socket that is not ready takes nothing, and the batch waits whole.
#[test]
fn the_segmentation_fixture_takes_a_batch_whole_or_not_at_all() {
    #[derive(Debug)]
    struct StepSender(VecDeque<Poll<Result<(), DatagramError>>>);
    impl DatagramSender for StepSender {
        fn poll_send(
            &mut self,
            _: &mut Context<'_>,
            _: &rama_udp::SendDatagram<'_>,
        ) -> Poll<Result<(), DatagramError>> {
            self.0.pop_front().expect("scripted response")
        }
        fn capabilities(&self) -> DatagramCapabilities {
            DatagramCapabilities::portable()
        }
    }
    let segments = Arc::new(Segments::default());
    segments.arm();
    let log = Arc::new(Mutex::new(SegmentLog::default()));
    let mut sender = SegmentingSender {
        inner: StepSender([Poll::Pending, Poll::Ready(Ok(())), Poll::Ready(Ok(()))].into()),
        log: log.clone(),
        segments,
    };
    let payload = [1u8, 1, 1, 2, 2];
    let mut descriptor = rama_udp::SendDatagram::new(([127, 0, 0, 2], 9), &payload[..]);
    descriptor.set_segment_size(NonZeroUsize::new(3).unwrap());
    let mut cx = Context::from_waker(Waker::noop());
    assert!(sender.poll_send(&mut cx, &descriptor).is_pending());
    assert_eq!(
        log.lock().sent.len(),
        0,
        "nothing left while the socket was not ready"
    );
    assert_matches!(sender.poll_send(&mut cx, &descriptor), Poll::Ready(Ok(())));
    let log = log.lock();
    assert_eq!(log.sent.len(), 2, "the whole batch went on the retry");
    assert_eq!(log.sent[0].bytes, [1, 1, 1]);
    assert_eq!(log.sent[1].bytes, [2, 2]);
}

/// A socket that stops after part of a batch is a state the fixture cannot report: `Pending` and
/// `Err` both tell the sender its descriptor was untouched, so bytes already on the wire would
/// have nothing accounting for them (RFC 9000 §10.3.1 counts an identifier from the first byte
/// that left). The fixture fails loudly instead of hiding it.
#[test]
#[should_panic = "cannot be reported to the sender"]
fn the_segmentation_fixture_refuses_to_hide_a_half_sent_batch() {
    #[derive(Debug)]
    struct StepSender(VecDeque<Poll<Result<(), DatagramError>>>);
    impl DatagramSender for StepSender {
        fn poll_send(
            &mut self,
            _: &mut Context<'_>,
            _: &rama_udp::SendDatagram<'_>,
        ) -> Poll<Result<(), DatagramError>> {
            self.0.pop_front().expect("scripted response")
        }
        fn capabilities(&self) -> DatagramCapabilities {
            DatagramCapabilities::portable()
        }
    }
    let segments = Arc::new(Segments::default());
    segments.arm();
    let log = Arc::new(Mutex::new(SegmentLog::default()));
    let mut sender = SegmentingSender {
        inner: StepSender([Poll::Ready(Ok(())), Poll::Pending].into()),
        log,
        segments,
    };
    let payload = [1u8, 1, 1, 2, 2];
    let mut descriptor = rama_udp::SendDatagram::new(([127, 0, 0, 2], 9), &payload[..]);
    descriptor.set_segment_size(NonZeroUsize::new(3).unwrap());
    let mut cx = Context::from_waker(Waker::noop());
    let _polled = sender.poll_send(&mut cx, &descriptor);
}

/// An address-changing migration commits an unused destination connection ID first: every
/// datagram on the new socket carries the new ID and none of the old socket's datagrams ever
/// used it (RFC 9000 §9.5). A replacement socket bound to the same address is no migration:
/// the destination connection ID stays.
#[tokio::test]
async fn a_migration_switches_to_an_unused_destination_cid_and_a_same_address_replacement_keeps_it()
{
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket_a, log_a) = recording_socket();
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket_a);
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    exchange(&c, &s, b"on A").await;
    let cid_a = active_dcid(&c);
    let len = cid_a.len();
    assert!(len > 0, "the server issues non-zero-length connection IDs");

    let std_b = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let std_b_again = std_b.try_clone().unwrap();
    let (socket_b, log_b) = recording_socket_from(std_b);
    client.rebind_abstract(socket_b).unwrap();
    let addr_b = client.local_addr().unwrap();
    wait_for("the server sees B", Duration::from_secs(5), || {
        s.remote_address() == addr_b
    })
    .await;
    exchange(&c, &s, b"on B").await;
    let cid_b = active_dcid(&c);
    assert_ne!(cid_b, cid_a, "the migration switched connection IDs");
    let on_a = short_header_dcids(&log_a.lock().sent, len);
    let on_b = short_header_dcids(&log_b.lock().sent, len);
    assert!(!on_a.is_empty() && !on_b.is_empty());
    assert!(
        on_a.iter().all(|cid| *cid == cid_a),
        "A only ever used its own ID"
    );
    assert!(
        on_b.iter().all(|cid| *cid == cid_b),
        "B uses the new ID from its first datagram"
    );

    // Same address, different socket: a replacement, so the connection ID is kept.
    client
        .rebind_abstract(Socket::from_std(std_b_again).unwrap())
        .unwrap();
    assert_eq!(client.local_addr().unwrap(), addr_b);
    wait_for(
        "B's original handle retires",
        Duration::from_secs(5),
        || client.stats().retained_sockets == 1,
    )
    .await;
    exchange(&c, &s, b"on B again").await;
    exchange(&s, &c, b"back").await;
    assert_eq!(
        active_dcid(&c),
        cid_b,
        "no connection ID switch without an address change"
    );
    assert_eq!(s.remote_address(), addr_b);
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A client migrates only while it holds an unused destination connection ID. The client
/// moves through sockets whose datagrams never reach the server (a dark stretch), so every
/// move consumes a spare and no replacement can arrive: the moves up to the last spare
/// happen, the next one waits on the current socket (nothing is sent from the new one, no ID
/// is reused), and the client proceeds as soon as the peer's NEW_CONNECTION_ID gets
/// through, once the current socket reaches the server again. Every ID the client uses is
/// used from exactly one local address, and the server, supplied with spares throughout,
/// follows each move it sees without deferring one.
#[tokio::test]
async fn a_migration_waits_for_an_unused_destination_cid_and_proceeds_when_one_arrives() {
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket_a, log_a) = recording_socket();
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket_a);
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    // Let the server's initial batch of spare connection IDs arrive.
    exchange(&c, &s, b"settle").await;
    exchange(&s, &c, b"settle").await;
    let len = active_dcid(&c).len();
    let mut logs = vec![log_a];
    let mut used: Vec<Vec<u8>> = vec![active_dcid(&c)];

    // Migrate while spares last: each move needs a fresh ID on the client side. The new
    // sockets swallow what they send, so the server learns nothing and replaces nothing.
    let mut spares = 0;
    loop {
        let (socket, log) = recording_socket();
        log.lock().blackhole = true;
        client.rebind_abstract(socket).unwrap();
        let before = active_dcid(&c);
        let moved = tokio::time::timeout(Duration::from_millis(400), async {
            wait_until(|| active_dcid(&c) != before && !log.lock().sent.is_empty()).await
        })
        .await
        .is_ok();
        logs.push(log);
        if !moved {
            break;
        }
        let cid = active_dcid(&c);
        assert!(!used.contains(&cid), "a fresh ID for each address");
        used.push(cid);
        spares += 1;
        assert!(spares < 8, "the peer's ID budget is bounded");
    }
    assert!(
        spares >= 1,
        "at least one spare ID was available after the handshake"
    );
    let waiting_log = logs.last().unwrap().clone();
    let dark_log = logs[logs.len() - 2].clone();
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert!(
        waiting_log.lock().sent.is_empty(),
        "nothing leaves the new socket before an unused connection ID exists"
    );
    assert_eq!(
        active_dcid(&c),
        *used.last().unwrap(),
        "the current ID stays in use"
    );
    assert!(c.close_reason().is_none());
    // The waiting socket is the one that will carry the connection: it must reach the server.
    waiting_log.lock().blackhole = false;

    // The current socket reaches the server again: the client's probes get through, the
    // server follows that move and replaces the retired IDs, and the deferred migration
    // proceeds with a fresh ID, observed on the new socket's own datagrams.
    dark_log.lock().blackhole = false;
    wait_for(
        "the client's deferred migration proceeds",
        Duration::from_secs(5),
        || !waiting_log.lock().sent.is_empty(),
    )
    .await;
    let cid = active_dcid(&c);
    assert!(
        !used.contains(&cid),
        "the waiting socket starts with a fresh ID"
    );
    used.push(cid);
    let waiting_addr = client.local_addr().unwrap();
    wait_for(
        "the server follows the completed move",
        Duration::from_secs(5),
        || s.remote_address() == waiting_addr,
    )
    .await;
    exchange(&c, &s, b"after").await;
    exchange(&s, &c, b"after").await;
    assert_eq!(
        s.stats().path.deferred_migrations,
        0,
        "a server kept supplied with spare IDs defers no move"
    );
    // Every short-header datagram on every client socket (swallowed ones included) used an
    // ID no other socket used.
    let mut seen: FxHashMap<Vec<u8>, usize> = FxHashMap::default();
    for (index, log) in logs.iter().enumerate() {
        for cid in short_header_dcids(&log.lock().sent, len) {
            assert_eq!(
                *seen.entry(cid.clone()).or_insert(index),
                index,
                "connection ID {cid:?} was used from two local addresses"
            );
        }
    }
    // Bounded end: the client closes; its handles and the sockets are released.
    c.close(VarInt::from_u32(0), b"done");
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A pair whose server prefers an address served by a socket that never answers, with a known
/// reset key so the test can build the server's stateless resets, and a client whose sends can
/// be held per destination. The server's HANDSHAKE_DONE is held back, so nothing is probed
/// until the test releases it.
async fn preferring_pair(
    gate_probe: bool,
) -> (
    Endpoint,
    Endpoint,
    crate::driver::connection::Connection,
    crate::driver::connection::Connection,
    std::net::UdpSocket,
    SocketAddr,
    HmacSha2,
    Arc<SendGate>,
) {
    let (client_config, mut server_config) = configs();
    let silent = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let preferred = match silent.local_addr().unwrap() {
        SocketAddr::V4(addr) => addr,
        SocketAddr::V6(addr) => panic!("expected an IPv4 loopback address, got {addr}"),
    };
    server_config.set_preferred_address_v4(preferred);
    let key = HmacSha2::new_256(&[0x55; 32]);
    let key_copy = HmacSha2::new_256(&[0x55; 32]);
    let server_socket =
        Socket::from_std(std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap())
            .expect("a loopback socket");
    let server = Endpoint::new_with_advertised(
        EndpointConfig::new(key),
        Some(server_config),
        server_socket,
        Vec::new(),
        Executor::new(),
        Duration::from_secs(1),
    )
    .unwrap();
    let (client_socket, gate, _, _) = breakable_socket(None);
    let client = endpoint_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        None,
        client_socket,
    );
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let server_connecting = incoming.accept().unwrap();
    server_connecting.hold_handshake_done(true);
    let (c, s) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(connecting, server_connecting)
    })
    .await
    .expect("both sides complete the handshake");
    let (c, s) = (c.unwrap(), s.unwrap());
    assert!(
        c.reserved_dcid().is_none(),
        "nothing is probed before the handshake is confirmed"
    );
    if gate_probe {
        gate.close_for(SocketAddress::from(SocketAddr::from(preferred)));
    }
    s.hold_handshake_done(false);
    (
        client,
        server,
        c,
        s,
        silent,
        SocketAddr::from(preferred),
        key_copy,
        gate,
    )
}

/// RFC 9000 §10.3.1 for the identifier a connection is on: switching to one is not using it.
/// The peer retires what the client is addressing it with while the client's socket takes
/// nothing, so the datagram that would carry the replacement waits in the sender's hands. The
/// switch has happened and no datagram has left with that identifier, so it is not one this
/// connection has used; the send path stays on that one datagram rather than piling up more.
/// Once the socket accepts, the datagram leaves and the identifier counts.
#[tokio::test]
async fn switching_to_an_identifier_is_not_using_it_until_a_datagram_leaves() {
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (client_socket, gate, _, sent) = breakable_socket(None);
    let client = endpoint_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        None,
        client_socket,
    );
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(connecting, incoming.accept().unwrap())
    })
    .await
    .expect("both sides complete the handshake");
    let (c, s) = (c.unwrap(), s.unwrap());
    exchange(&c, &s, b"before the switch").await;
    let (before, before_seq) = (c.active_dcid(), c.active_dcid_seq());
    assert!(
        c.active_cid_confirmed(),
        "the identifier in use carried that traffic"
    );

    // Nothing the client writes to its peer can leave from now on.
    gate.close_for(SocketAddress::from(server.local_addr().unwrap()));
    s.rotate_local_cid(before_seq + 1);
    wait_for(
        "the client moves off the retired identifier",
        Duration::from_secs(5),
        || c.active_dcid() != before,
    )
    .await;
    assert!(
        c.active_dcid_seq() > before_seq,
        "onto one the retirement left it"
    );
    let switched = c.active_dcid();
    let left = sent.load(Ordering::SeqCst);
    let refused = gate.held.load(Ordering::SeqCst);
    for _ in 0..12 {
        tokio::time::sleep(Duration::from_millis(5)).await;
        assert!(
            !c.active_cid_confirmed(),
            "a switch with nothing sent is not an identifier we have used"
        );
        assert!(c.close_reason().is_none(), "{:?}", c.close_reason());
    }
    assert_eq!(
        sent.load(Ordering::SeqCst),
        left,
        "nothing left the socket while it took nothing"
    );
    // The send path waits on the datagram it wrote rather than spinning out new ones: over
    // 60ms it offers the socket single digits of retries (8 as this is written), not thousands.
    let retries = gate.held.load(Ordering::SeqCst) - refused;
    assert!(
        retries < 64,
        "the blocked send path offered {retries} datagrams in 60ms"
    );

    // The socket accepts again: that datagram leaves, and the identifier is one we have used.
    gate.open();
    wait_for(
        "the datagram carrying it leaves",
        Duration::from_secs(5),
        || c.active_cid_confirmed(),
    )
    .await;
    exchange(&c, &s, b"after the switch").await;
    assert_eq!(
        c.active_dcid(),
        switched,
        "and the traffic that followed went out with it"
    );
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A replacement endpoint has no connection state; only the persisted reset key lets it
/// terminate connections established by its predecessor.
#[tokio::test]
async fn a_restarted_endpoint_uses_its_configured_reset_key() {
    use crate::proto::{HashedConnectionIdGenerator, StatelessResetKey};

    let (client_config, server_config) = configs();
    let mut config = EndpointConfig::try_with_rand_key().unwrap();
    config
        .set_stateless_reset_key(StatelessResetKey::from_seed(&[0x71; 32]))
        .set_cid_generator(Arc::new(|| {
            Box::new(HashedConnectionIdGenerator::from_key(7))
        }));
    let (socket, old_log) = recording_socket();
    let server = endpoint_with(config.clone(), Some(server_config), socket);
    let addr = server.local_addr().unwrap();
    let client = endpoint(None, Executor::new(), Duration::from_secs(1));
    let connecting = client
        .connect_with(client_config, addr, "localhost")
        .unwrap();
    let incoming = server.accept().await.unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    exchange(&c, &s, b"before restart").await;

    // Suppress shutdown traffic to model losing the endpoint without notifying its peer.
    old_log.lock().blackhole = true;
    drop(s);
    server.shutdown().await;
    drop(server);
    assert!(c.close_reason().is_none());

    for preserved in [false, true] {
        let mut restarted_config = config.clone();
        if !preserved {
            restarted_config.set_stateless_reset_key(StatelessResetKey::from_seed(&[0x29; 32]));
        }
        let (socket, resets) = recording_socket_from(std::net::UdpSocket::bind(addr).unwrap());
        let restarted = endpoint_with(restarted_config, None, socket);
        let received_before = client.stats().received_datagrams;
        c.send_datagram(vec![0x5a; 256].into()).unwrap();
        wait_for(
            "replacement endpoint sent a response",
            Duration::from_secs(2),
            || !resets.lock().sent.is_empty(),
        )
        .await;
        if preserved {
            let reason = tokio::time::timeout(Duration::from_secs(2), c.closed())
                .await
                .expect("the preserved reset key terminates the old connection");
            assert_matches!(reason, ConnectionError::Reset, "{reason:?}");
        } else {
            wait_for(
                "client processed the foreign reset",
                Duration::from_secs(2),
                || {
                    client.stats().received_datagrams > received_before
                        && c.driver_stats().receive_queue.queued_datagrams == 0
                },
            )
            .await;
            assert!(
                c.close_reason().is_none(),
                "a changed key cannot reset the old connection"
            );
        }
        restarted.shutdown().await;
        drop(restarted);
    }
    drop(c);
    client.shutdown().await;
}

/// A stateless reset for `cid` under `key`, shaped like the server's.
fn stateless_reset_for(key: &HmacSha2, cid: &[u8]) -> Vec<u8> {
    let mut datagram = vec![0x40u8];
    datagram.extend_from_slice(&[0xab; 40]);
    datagram.extend_from_slice(&crate::proto::reset_token(
        key,
        rama_quic_proto::ConnectionId::new(cid),
    ));
    datagram
}

/// RFC 9000 §10.3.1 at the boundary that decides it: writing a probe does not make its
/// identifier one this connection has used. The client's socket refuses what is addressed to
/// the preferred address, so the probe is written and waits; nothing counts, and a stateless
/// reset carrying that identifier's token is not ours.
#[tokio::test]
async fn a_probe_the_socket_holds_makes_no_identifier_used() {
    let (client, server, c, s, silent, _preferred, key, gate) = preferring_pair(true).await;
    wait_for(
        "the probe is written and refused",
        Duration::from_secs(5),
        || c.reserved_dcid().is_some() && gate.held.load(Ordering::SeqCst) > 0,
    )
    .await;
    let probed = c.reserved_dcid().expect("an identifier is reserved");
    assert_eq!(
        c.stats().path.preferred_address_probes,
        0,
        "a datagram the socket has not taken is not a probe that was sent"
    );
    let reset = stateless_reset_for(&key, &probed);
    silent
        .send_to(&reset, client.local_addr().unwrap())
        .unwrap();
    // Long enough for the endpoint to have handled the datagram, short enough that the
    // attempt has not yet given up: either way the reset must do nothing.
    for _ in 0..12 {
        tokio::time::sleep(Duration::from_millis(5)).await;
        assert!(
            c.close_reason().is_none(),
            "an identifier whose probe never left is not one we have used: {:?}",
            c.close_reason()
        );
    }
    assert_eq!(c.stats().path.preferred_address_probes, 0);
    assert_eq!(c.remote_address(), server.local_addr().unwrap());
    drop((c, s));
    gate.open();
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A probe the socket never takes ends the attempt at its own interval: the reservation is
/// given up and nothing ever reaches the preferred address. The datagram itself stays in the
/// sender's hands, which is what blocks this connection's send path until the socket accepts
/// it; once it does, the abandoned probe leaves and traffic resumes.
#[tokio::test]
async fn a_probe_that_cannot_leave_ends_the_attempt() {
    let (client, server, c, s, silent, _preferred, _key, gate) = preferring_pair(true).await;
    wait_for(
        "the probe is written and refused",
        Duration::from_secs(5),
        || c.reserved_dcid().is_some() && gate.held.load(Ordering::SeqCst) > 0,
    )
    .await;
    wait_for("the attempt gives up", Duration::from_secs(5), || {
        c.reserved_dcid().is_none()
    })
    .await;
    assert_eq!(
        c.stats().path.preferred_address_probes,
        0,
        "no probe ever left, so none counts"
    );
    assert_eq!(c.remote_address(), server.local_addr().unwrap());
    assert!(c.close_reason().is_none());
    silent.set_nonblocking(true).unwrap();
    let mut buffer = [0u8; 2048];
    assert!(
        silent.recv_from(&mut buffer).is_err(),
        "nothing reached the preferred address"
    );
    // The socket accepts again: the abandoned datagram leaves without counting, and the
    // connection carries data as before.
    gate.open();
    exchange(&c, &s, b"still here").await;
    assert_eq!(
        c.stats().path.preferred_address_probes,
        0,
        "a datagram whose attempt is over is not a probe that counts"
    );
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// The other half of that boundary: once the socket takes the datagram, the probe counts, it
/// arrives at the preferred address carrying the reserved identifier, and a stateless reset
/// from there carrying its token ends the connection.
#[tokio::test]
async fn a_probed_identifier_counts_when_its_datagram_leaves() {
    let (client, server, c, s, silent, _preferred, key, _gate) = preferring_pair(false).await;
    wait_for("the probe leaves", Duration::from_secs(5), || {
        c.stats().path.preferred_address_probes >= 1
    })
    .await;
    silent.set_nonblocking(true).unwrap();
    let mut buffer = [0u8; 2048];
    let (size, from) = silent.recv_from(&mut buffer).expect("the probe arrived");
    assert_eq!(from, client.local_addr().unwrap());
    assert!(size >= 1200, "a probe is expanded: {size} bytes");
    let probed = c.reserved_dcid().expect("an identifier is reserved");
    assert_eq!(
        buffer.get(1..1 + probed.len()),
        Some(&probed[..]),
        "the probe carries the reserved identifier"
    );
    assert_eq!(c.remote_address(), server.local_addr().unwrap());

    let reset = stateless_reset_for(&key, &probed);
    silent
        .send_to(&reset, client.local_addr().unwrap())
        .unwrap();
    wait_for("the reset is recognised", Duration::from_secs(5), || {
        c.close_reason().is_some()
    })
    .await;
    assert_matches!(
        c.close_reason(),
        Some(ConnectionError::Reset),
        "a reset for an identifier we have used ends the connection: {:?}",
        c.close_reason(),
    );
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// RFC 9000 §9.6 through the driver: a client probes the address its server advertises as
/// preferred, from its own socket and with the connection ID the server bound to that address,
/// at most three times. With nothing answering there the connection stays where it is and
/// keeps carrying data. A server that actually listens at its preferred address is not part
/// of this: only the client's side of the exchange is exercised here.
#[tokio::test]
async fn a_client_probes_a_preferred_address_at_most_three_times() {
    let (client_config, mut server_config) = configs();
    // A real socket that never answers, so every probe is delivered and none is replied to.
    let silent = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    silent.set_nonblocking(true).unwrap();
    let preferred = match silent.local_addr().unwrap() {
        SocketAddr::V4(addr) => addr,
        SocketAddr::V6(addr) => panic!("expected an IPv4 loopback address, got {addr}"),
    };
    server_config.set_preferred_address_v4(preferred);
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket, log) = recording_socket();
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket);
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    let len = active_dcid(&c).len();
    let current = active_dcid(&c);

    // Three probes are transmitted, and no more.
    wait_for(
        "three probes towards the preferred address",
        Duration::from_secs(5),
        || c.stats().path.preferred_address_probes == 3,
    )
    .await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(c.stats().path.preferred_address_probes, 3);

    // Each of them arrived there: expanded to the smallest allowed datagram and carrying one
    // connection ID of its own, which the connection itself never used.
    let mut probes = Vec::new();
    let mut buffer = [0u8; 2048];
    while let Ok((size, from)) = silent.recv_from(&mut buffer) {
        assert_eq!(from, client.local_addr().unwrap());
        probes.push(buffer[..size].to_vec());
    }
    assert_eq!(probes.len(), 3, "one datagram per transmitted probe");
    let probe_cids: Vec<Vec<u8>> = probes
        .iter()
        .map(|probe| {
            assert!(
                probe.len() >= 1200,
                "a probe is expanded: {} bytes",
                probe.len()
            );
            assert_eq!(probe[0] & 0x80, 0, "a short-header packet");
            probe[1..1 + len].to_vec()
        })
        .collect();
    assert!(
        probe_cids.windows(2).all(|pair| pair[0] == pair[1]),
        "every probe of one attempt uses the identifier reserved for it: {probe_cids:?}"
    );
    assert!(
        !probe_cids.contains(&current) && !probe_cids.contains(&active_dcid(&c)),
        "the reserved identifier is not one the connection sends elsewhere"
    );
    assert!(
        short_header_dcids(&log.lock().sent, len)
            .iter()
            .filter(|cid| *cid == &probe_cids[0])
            .count()
            == 3,
        "the probes are the only use of that identifier on this socket"
    );

    // The connection stayed where it was and still works both ways.
    assert_eq!(c.remote_address(), server.local_addr().unwrap());
    assert!(c.close_reason().is_none());
    exchange(&c, &s, b"still here").await;
    exchange(&s, &c, b"and back").await;
    c.close(VarInt::from_u32(0), b"done");
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// Between handshake completion and confirmation (the client has the server's Finished but
/// no HANDSHAKE_DONE yet) a client may not migrate. The server holds its HANDSHAKE_DONE
/// through a test seam: in that interval a rebind is deferred and `handshake_confirmed()`
/// stays pending; once HANDSHAKE_DONE is released both complete and the migration goes ahead.
#[tokio::test]
async fn a_client_completes_before_it_confirms_and_migrates_only_once_confirmed() {
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let (socket_a, _gate_a, _, _) = breakable_socket(None);
    let client = endpoint_with(EndpointConfig::try_with_rand_key().unwrap(), None, socket_a);
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let server_connecting = incoming.accept().unwrap();
    server_connecting.hold_handshake_done(true);
    let (c, s) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(connecting, server_connecting)
    })
    .await
    .expect("both sides complete the handshake");
    let (c, s) = (c.unwrap(), s.unwrap());
    assert!(
        tokio::time::timeout(Duration::from_millis(200), c.handshake_confirmed())
            .await
            .is_err(),
        "complete but not confirmed"
    );
    let (socket_b, _gate_b, _, sent_b) = breakable_socket(None);
    client.rebind_abstract(socket_b).unwrap();
    let addr_b = client.local_addr().unwrap();
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert_eq!(
        sent_b.load(Ordering::Relaxed),
        0,
        "no migration before confirmation"
    );
    assert_eq!(
        client.stats().retained_sockets,
        2,
        "A stays for the pending offer"
    );

    s.hold_handshake_done(false);
    tokio::time::timeout(Duration::from_secs(5), c.handshake_confirmed())
        .await
        .expect("HANDSHAKE_DONE arrives")
        .unwrap();
    wait_for(
        "the confirmed client migrates",
        Duration::from_secs(5),
        || s.remote_address() == addr_b,
    )
    .await;
    assert!(sent_b.load(Ordering::Relaxed) >= 1);
    exchange(&c, &s, b"via B").await;
    wait_for("A retires", Duration::from_secs(3), || {
        client.stats().retained_sockets == 1
    })
    .await;
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// `handshake_confirmed()` on a connection that ends before confirmation reports the error
/// instead of waiting forever.
#[tokio::test]
async fn handshake_confirmed_fails_when_the_connection_ends_unconfirmed() {
    let (client_config, server_config) = configs();
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let client = endpoint(None, Executor::new(), Duration::from_secs(1));
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let server_connecting = incoming.accept().unwrap();
    server_connecting.hold_handshake_done(true);
    let (c, s) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(connecting, server_connecting)
    })
    .await
    .unwrap();
    let (c, s) = (c.unwrap(), s.unwrap());
    let confirmed = tokio::spawn({
        let c = c.clone();
        async move { c.handshake_confirmed().await }
    });
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(!confirmed.is_finished(), "pending while unconfirmed");
    c.close(VarInt::from_u32(7), b"gave up");
    let error = tokio::time::timeout(Duration::from_secs(3), confirmed)
        .await
        .expect("woken by the close")
        .unwrap()
        .unwrap_err();
    assert_matches!(error, ConnectionError::LocallyClosed, "{error:?}");
    drop((c, s));
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A rejection produced while accepting must schedule the endpoint just like an explicit
/// refusal: its response otherwise waits for an unrelated receive or admission timer.
#[tokio::test]
async fn an_accept_error_wakes_the_parked_endpoint_to_send_its_response() {
    struct FailingServer(Arc<dyn crate::proto::crypto::ServerConfig>);
    impl crate::proto::crypto::InitialServerConfig for FailingServer {
        fn initial_keys(
            &self,
            version: Version,
            cid: &rama_quic_proto::ConnectionId,
        ) -> Result<crate::proto::crypto::Keys, crate::proto::crypto::InitialKeysError> {
            self.0.initial_keys(version, cid)
        }
        fn retry_tag(
            &self,
            version: Version,
            cid: &rama_quic_proto::ConnectionId,
            packet: &[u8],
        ) -> Result<[u8; 16], rama_quic_proto::crypto::CryptoError> {
            self.0.retry_tag(version, cid, packet)
        }
    }
    impl crate::proto::crypto::ServerConfig for FailingServer {
        fn start_session(
            self: Arc<Self>,
            _: Version,
            _: &rama_quic_proto::transport_parameters::TransportParameters,
        ) -> Result<Box<dyn crate::proto::crypto::Session>, rama_quic_proto::TransportError>
        {
            Err(rama_quic_proto::TransportError::INTERNAL_ERROR(
                "injected accept failure",
            ))
        }
        fn supports_compatible_negotiation(&self) -> bool {
            false
        }
        fn start_negotiated_session(
            self: Arc<Self>,
            _: Version,
            _: Version,
            _: &rama_quic_proto::transport_parameters::TransportParameters,
        ) -> Result<Box<dyn crate::proto::crypto::Session>, rama_quic_proto::TransportError>
        {
            Err(rama_quic_proto::TransportError::INTERNAL_ERROR(
                "injected accept failure",
            ))
        }
    }
    struct ObservedWake {
        count: Arc<AtomicUsize>,
        driver: Waker,
    }
    impl Wake for ObservedWake {
        fn wake(self: Arc<Self>) {
            self.count.fetch_add(1, Ordering::Relaxed);
            self.driver.wake_by_ref();
        }
    }

    let (client_config, mut server_config) = configs();
    server_config.crypto = crate::proto::ServerCrypto::Fixed(Arc::new(FailingServer(
        server_config.crypto.into_fixed(),
    )));
    let server = endpoint(Some(server_config), Executor::new(), Duration::from_secs(1));
    let client = endpoint(None, Executor::new(), Duration::from_secs(1));
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let wakes = Arc::new(AtomicUsize::new(0));
    {
        let mut state = server.inner.state.lock();
        let driver = state
            .driver
            .take()
            .expect("the endpoint registered its waker");
        state.driver = Some(Waker::from(Arc::new(ObservedWake {
            count: wakes.clone(),
            driver,
        })));
    }
    // There is no await between installing the observer and checking it, so no receive or
    // timer can be mistaken for the accept operation's wake on this current-thread runtime.
    assert_matches!(incoming.accept(), Err(ConnectionError::TransportError(_)));
    assert_eq!(
        wakes.load(Ordering::Relaxed),
        1,
        "accept must wake its response sender"
    );
    let error = tokio::time::timeout(Duration::from_secs(2), connecting)
        .await
        .expect("the peer receives the rejection")
        .unwrap_err();
    assert_matches!(
        error,
        ConnectionError::ConnectionClosed(ref close)
            if close.error_code == rama_quic_proto::TransportErrorCode::INTERNAL_ERROR,
    );
    tokio::time::timeout(Duration::from_secs(3), async {
        tokio::join!(client.shutdown(), server.shutdown());
    })
    .await
    .expect("both endpoints release their drivers");
}

#[tokio::test]
async fn retained_sockets_are_bounded_across_address_families_while_another_connection_progresses()
{
    let (client_config, server_config) = configs();
    let server_v4 = Endpoint::bind_server(
        Executor::new(),
        server_config.clone(),
        SocketAddress::local_ipv4(0),
    )
    .await
    .unwrap();
    let server_v6 = Endpoint::bind_server(
        Executor::new(),
        server_config.clone(),
        SocketAddress::local_ipv6(0),
    )
    .await
    .unwrap();
    let control_server =
        Endpoint::bind_server(Executor::new(), server_config, SocketAddress::local_ipv6(0))
            .await
            .unwrap();
    let mut pending = Vec::new();
    let mut held_logs = Vec::new();
    let mut client = None;
    for index in 0..MAX_RETAINED_SOCKETS {
        let ipv6 = index % 2 == 1;
        let bind = if ipv6 {
            SocketAddress::local_ipv6(0)
        } else {
            SocketAddress::local_ipv4(0)
        };
        let destination = if ipv6 {
            server_v6.local_addr().unwrap()
        } else {
            server_v4.local_addr().unwrap()
        };
        let (socket, log, _) = segmenting_socket_from(
            std::net::UdpSocket::bind(bind.into_std()).unwrap(),
            usize::MAX,
        );
        block_segments_for(&log, SocketAddress::from(destination));
        if let Some(endpoint) = &client {
            let endpoint: &Endpoint = endpoint;
            endpoint.rebind_abstract(socket).unwrap();
        } else {
            client = Some(endpoint_with(
                EndpointConfig::try_with_rand_key().unwrap(),
                None,
                socket,
            ));
        }
        let endpoint = client.as_ref().unwrap();
        pending.push(
            endpoint
                .connect_with(client_config.clone(), destination, "localhost")
                .unwrap(),
        );
        wait_for(
            "the Initial waits on its own socket",
            Duration::from_secs(3),
            || !log.lock().wakers.is_empty(),
        )
        .await;
        assert_eq!(endpoint.stats().retained_sockets, index + 1);
        held_logs.push(log);
    }
    let client = client.unwrap();
    let before = client.local_addrs();
    assert!(before.iter().any(SocketAddr::is_ipv4) && before.iter().any(SocketAddr::is_ipv6));
    let refused = client.rebind_abstract(recording_socket().0).unwrap_err();
    assert_eq!(refused.kind(), io::ErrorKind::QuotaExceeded);
    assert_eq!(client.local_addrs(), before);

    let control = client
        .connect_with(
            client_config,
            control_server.local_addr().unwrap(),
            "localhost",
        )
        .unwrap();
    let incoming = control_server.accept().await.unwrap();
    let (c, s) = handshake(control, incoming).await;
    exchange(&c, &s, b"progress with eight retained mixed-family sockets").await;
    assert_eq!(client.stats().retained_sockets, MAX_RETAINED_SOCKETS);
    assert!(
        held_logs.iter().all(|log| {
            let log = log.lock();
            log.sent
                .iter()
                .all(|packet| Some(packet.destination) != log.blocked)
        }),
        "all original handshakes remain held"
    );

    let accept = |server: Endpoint| async move {
        let mut connections = Vec::new();
        for _ in 0..MAX_RETAINED_SOCKETS / 2 {
            connections.push(server.accept().await.unwrap().await.unwrap());
        }
        connections
    };
    let mut accepting = tokio::task::JoinSet::new();
    accepting.spawn(accept(server_v4.clone()));
    accepting.spawn(accept(server_v6.clone()));
    for log in &held_logs {
        unblock_segments(log);
    }
    tokio::time::timeout(Duration::from_secs(10), async {
        let mut connections = Vec::new();
        for attempt in pending {
            connections.push(attempt.await.unwrap());
        }
        while let Some(result) = accepting.join_next().await {
            connections.extend(result.unwrap());
        }
        for connection in &connections {
            connection.close(0u32, b"done");
        }
    })
    .await
    .expect("both address families complete their held handshakes");
    wait_for(
        "retiring sockets drain after their connections close",
        Duration::from_secs(5),
        || client.stats().retained_sockets == 1,
    )
    .await;
    exchange(
        &s,
        &c,
        b"the independent connection still works after drain",
    )
    .await;
    drop((c, s));
    tokio::join!(
        client.shutdown(),
        control_server.shutdown(),
        server_v4.shutdown(),
        server_v6.shutdown()
    );
}

#[tokio::test]
async fn socket_info_waits_for_the_new_path_to_be_validated() {
    let (client_config, server_config) = configs();
    let (server_socket, gate) = gated_socket();
    let server = endpoint_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        Some(server_config),
        server_socket,
    );
    let client = endpoint_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        None,
        loopback_socket(),
    );
    let connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let (c, s) = handshake(connecting, incoming).await;
    exchange(&c, &s, b"before the move").await;
    let socket_info = s.extensions().get_arc::<SocketInfo>().unwrap();
    let before = socket_info.peer_addr();

    // The server follows the client's new address but cannot validate it: its challenge waits.
    let moved = loopback_socket();
    let moved_addr = moved.local_addr();
    gate.close_for(SocketAddress::from(moved_addr));
    client.rebind_abstract(moved).unwrap();
    let mut stream = c.open_uni().await.unwrap();
    stream.write_all(b"from the new address").await.unwrap();
    wait_for(
        "the server follows the new address",
        Duration::from_secs(5),
        || s.remote_address() == moved_addr,
    )
    .await;
    for _ in 0..10 {
        tokio::time::sleep(Duration::from_millis(5)).await;
        assert_eq!(
            socket_info.peer_addr(),
            before,
            "an unvalidated path is not published"
        );
    }

    gate.open();
    wait_for(
        "the validated path is published",
        Duration::from_secs(5),
        || socket_info.peer_addr() == SocketAddress::from(moved_addr),
    )
    .await;
}

#[tokio::test]
async fn tls_parameters_are_published_before_the_handshake_completes() {
    let (client_config, server_config) = configs();
    let (server_socket, gate) = gated_socket();
    let server = endpoint_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        Some(server_config),
        server_socket,
    );
    let client = endpoint_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        None,
        loopback_socket(),
    );
    // The server reads the ClientHello but none of its answers leave: no handshake completes.
    gate.close();
    let _connecting = client
        .connect_with(client_config, server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = tokio::time::timeout(Duration::from_secs(2), server.accept())
        .await
        .unwrap()
        .unwrap();
    let Ok((s, _established)) = incoming.accept().unwrap().into_0rtt() else {
        panic!("server connections permit early data handles");
    };
    wait_for(
        "the negotiated protocol is published",
        Duration::from_secs(5),
        || {
            s.extensions()
                .get_ref::<NegotiatedTlsParameters>()
                .is_some_and(|parameters| parameters.application_layer_protocol.is_some())
        },
    )
    .await;
    assert!(!s.is_handshake_confirmed());
}
