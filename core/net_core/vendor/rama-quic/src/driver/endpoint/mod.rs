use std::{
    fmt,
    future::Future,
    io,
    io::IoSliceMut,
    net::SocketAddr,
    pin::Pin,
    str,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    task::{Context, Poll, Waker},
};

use parking_lot::Mutex;
use pin_project_lite::pin_project;
use rama_core::{
    bytes::{Bytes, BytesMut},
    rt::Executor,
    telemetry::tracing::{Instrument, Span},
};
use rama_net::address::{SocketAddress, ip::IntoCanonicalIpAddr as _};
use rama_quic_proto::VarInt;
use rama_udp::{
    DatagramError, DatagramMetadata, UdpPacketSocket, UdpSocketConfig, UdpSocketFactory,
};
use rama_utils::octets;
use rustc_hash::FxHashMap;
use tokio::sync::{Notify, futures::Notified};

#[cfg(all(test, any(feature = "boring", feature = "aws-lc", feature = "ring")))]
use crate::proto::{self as proto};
use crate::{
    driver::{
        Duration, EndpointConfig, IO_LOOP_BOUND, Instant, QueuedPacket, RECV_TIME_BOUND,
        connection::{Connecting, ConnectionDriver, ConnectionInner, Control, EndpointLink},
        incoming::Incoming,
        lifecycle::{Lifecycle, ShutdownOutcome},
        now,
        queue::{
            BoundedDeque, BoundedSender, INCOMING_OVERHEAD, PACKET_OVERHEAD, PacketBudget,
            PacketPermit, PacketQueueStats, Refusal, bounded_queue,
        },
        sockets::{Lease, RebindRefused, SocketId, SocketRegistry, Sockets},
        timer::{Deadline, DeadlineTimer},
        udp::{Sender, Socket, proto_ecn},
        work_limiter::{WorkCycle, WorkLimiter},
    },
    proto::{
        AdmissionLease, ClientConfig, ClientHelloPeek, ConnectError, ConnectionError,
        ConnectionHandle, DatagramEvent, EndpointEvent, PreferredAddressPolicy, ReceiveQueueLimits,
        ServerConfig,
    },
};

mod builder;
pub(crate) mod ceiling;
mod serve;
pub use builder::{DEFAULT_SHUTDOWN_BUDGET, EndpointBuilder};

const BATCH_SIZE: usize = 32;
// Per-entry receive memory ceiling, independent of backend capability claims.
const MAX_RECEIVE_SEGMENTS: usize = 64;

/// A QUIC endpoint.
///
/// An endpoint corresponds to a single UDP socket, may host many connections, and may act as both
/// client and server for different connections.
///
/// May be cloned to obtain another handle to the same endpoint.
#[derive(Debug, Clone)]
pub struct Endpoint {
    pub(crate) inner: EndpointRef,
    pub(crate) default_client_config: Option<ClientConfig>,
}

impl Endpoint {
    /// Configure an endpoint whose drivers run through `exec` on the current Tokio runtime.
    ///
    /// An executor carrying a graceful guard ties the endpoint to the application's
    /// shutdown. All convenience constructors accept the same executor explicitly.
    #[must_use]
    pub fn build(exec: Executor) -> EndpointBuilder {
        EndpointBuilder::new(exec)
    }

    /// Create a client endpoint on a bound standard UDP socket.
    ///
    /// This does not configure packet metadata. Use [`Self::new_client_with_packet_socket`]
    /// for a prepared socket, or [`Self::build`] for custom endpoint settings.
    pub fn new_client_with_std_socket(
        exec: Executor,
        socket: std::net::UdpSocket,
    ) -> Result<Self, DatagramError> {
        EndpointBuilder::new(exec).with_std_socket(socket)
    }

    /// Create a client endpoint on a prepared packet socket, preserving its configuration.
    ///
    /// Use [`Self::build`] for custom endpoint settings.
    pub fn new_client_with_packet_socket(
        exec: Executor,
        socket: UdpPacketSocket,
    ) -> Result<Self, DatagramError> {
        EndpointBuilder::new(exec).with_packet_socket(socket)
    }

    /// Bind a client endpoint, requesting best-effort dual-stack operation for IPv6.
    ///
    /// Use [`Self::build`] to customise the endpoint or UDP socket configuration.
    pub async fn bind_client(
        exec: Executor,
        address: impl Into<SocketAddress>,
    ) -> Result<Self, DatagramError> {
        let address = address.into();
        EndpointBuilder::new(exec)
            .bind_client_address(address)
            .await
    }

    /// Create a server endpoint on a bound standard UDP socket.
    ///
    /// This does not configure packet metadata or bind preferred-address sockets.
    /// Use [`Self::new_server_with_packet_socket`] for a prepared socket, or
    /// [`Self::build`] for custom endpoint settings.
    pub fn new_server_with_std_socket(
        exec: Executor,
        config: ServerConfig,
        socket: std::net::UdpSocket,
    ) -> Result<Self, DatagramError> {
        EndpointBuilder::new(exec)
            .with_server_config(config)
            .with_std_socket(socket)
    }

    /// Create a server endpoint on a prepared packet socket, preserving its configuration.
    ///
    /// This does not bind preferred-address sockets. Use [`Self::build`] for custom settings.
    pub fn new_server_with_packet_socket(
        exec: Executor,
        config: ServerConfig,
        socket: UdpPacketSocket,
    ) -> Result<Self, DatagramError> {
        EndpointBuilder::new(exec)
            .with_server_config(config)
            .with_packet_socket(socket)
    }

    /// Bind a server endpoint and any configured preferred-address sockets.
    ///
    /// Use [`Self::build`] to customise the endpoint or UDP socket configuration.
    pub async fn bind_server(
        exec: Executor,
        config: ServerConfig,
        address: impl Into<SocketAddress>,
    ) -> Result<Self, DatagramError> {
        EndpointBuilder::new(exec)
            .with_server_config(config)
            .bind_address(address)
            .await
    }

    /// Take ownership of a packet socket the caller prepared, bound to an address this endpoint
    /// advertises as its preferred one (RFC 9000 §9.6). Datagrams for a connection that moved
    /// there leave from this socket.
    pub fn advertise_socket(&self, socket: UdpPacketSocket) -> Result<(), DatagramError> {
        self.advertise_abstract(Socket::new(socket).map_err(DatagramError::from)?)
    }

    /// Take ownership of one socket bound to an address this endpoint advertises, given as our
    /// own abstraction: a socket with state of its own, or a test socket.
    pub(crate) fn advertise_abstract(&self, socket: Socket) -> Result<(), DatagramError> {
        let mut state = self.inner.state.lock();
        let Some(registry) = state.sockets.live_mut() else {
            drop(state);
            drop(socket);
            return Err(DatagramError::Io(io::ErrorKind::NotConnected.into()));
        };
        match registry.advertise(socket) {
            Ok(_) => {
                // A driver that has already parked has never polled this socket, so traffic
                // arriving only there would wake nothing.
                state.wake_driver();
                Ok(())
            }
            Err(refused) => {
                // The refused socket is dropped outside the endpoint lock.
                drop(state);
                drop(refused.socket);
                Err(DatagramError::Io(refused.error))
            }
        }
    }

    /// Tests: the addresses this endpoint still advertises as preferred.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn advertised_preferred(&self) -> Vec<SocketAddr> {
        self.inner.state.lock().inner.advertised_preferred()
    }

    /// Count this endpoint in `metrics`, and record the connections it creates from now on.
    #[cfg(feature = "opentelemetry")]
    pub(crate) fn attach_metrics(&self, metrics: &crate::telemetry::QuicMetrics) {
        let endpoint: std::sync::Weak<EndpointInner> = Arc::downgrade(&self.inner.0);
        // Registered before the endpoint is locked: collection takes the registry first.
        let slot = metrics.register(endpoint);
        let mut state = self.inner.state.lock();
        let replaced = state.metrics.replace(slot);
        state.recv_state.connections.metrics = Some(metrics.clone());
        drop(state);
        drop(replaced);
    }

    /// Returns relevant stats from this Endpoint
    pub fn stats(&self) -> EndpointStats {
        let state = self.inner.state.lock();
        let (handshakes_in_progress, retry_threshold) = state.inner.admission_load(now());
        let admission = state.inner.admission_stats();
        EndpointStats {
            retried_under_load: admission.retried,
            refused_at_limit: admission.refused_at_limit,
            refused_per_source: admission.refused_per_source,
            refused_unvalidated: admission.refused_unvalidated,
            handshakes_in_progress,
            retry_threshold,
            received_datagrams: state.recv_state.received_datagrams,
            truncated_receive_entries: state.recv_state.truncated_receive_entries,
            ignored_receive_errors: state.recv_state.ignored_receive_errors,
            dropped_responses: state.sockets.dropped_responses(),
            failed_responses: state.sockets.failed_responses(),
            dropped_packets: state.recv_state.dropped_packets,
            receive_queue: state.packet_budget.stats(),
            incoming_queue_capacity: state.recv_state.incoming.capacity(),
            retained_sockets: state.sockets.retained_sockets(),
            retired_sockets: state.sockets.retired_sockets(),
            ..state.stats
        }
    }

    /// The same, with sockets bound to the addresses this endpoint advertises as preferred. They
    /// are in the registry before the driver is spawned, so its first poll covers them and
    /// traffic that arrives only there needs no wake to be seen.
    pub(crate) fn new_with_advertised(
        mut config: EndpointConfig,
        server_config: Option<ServerConfig>,
        socket: Socket,
        advertised: Vec<Socket>,
        executor: Executor,
        shutdown_budget: Duration,
    ) -> io::Result<Self> {
        if tokio::runtime::Handle::try_current().is_err() {
            return Err(io::Error::other("no async runtime found"));
        }
        if config.handshake_timeout.is_zero()
            || now().checked_add(config.handshake_timeout).is_none()
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid QUIC handshake timeout",
            ));
        }
        // Zero is a shutdown that forces at once, which is a choice; a budget no clock can
        // reach is not, and refusing it here is what keeps the supervisor's timeout sound.
        if now().checked_add(shutdown_budget).is_none() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "QUIC shutdown budget is further away than this clock can reach",
            ));
        }
        let capabilities = socket.capabilities();
        let ceiling = ceiling::payload_ceiling(&capabilities).map_err(io::Error::other)?;
        let fixed_peer = socket.fixed_peer().is_some();
        ceiling::fit_endpoint(
            &mut config,
            ceiling::receive_ceiling(&capabilities, ceiling),
        );
        let server_config = server_config.map(|config| ceiling::fit_server(config, ceiling));
        let largest_payload =
            usize::try_from(config.get_max_udp_payload_size()).unwrap_or(usize::MAX);
        let connection = config.connection_receive_queue;
        let endpoint = config.endpoint_receive_queue;
        if connection.bytes() < largest_payload.saturating_add(PACKET_OVERHEAD)
            || endpoint.bytes() < connection.bytes()
            || endpoint.bytes() < largest_payload.saturating_add(INCOMING_OVERHEAD)
            || endpoint.datagrams() < connection.datagrams()
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "QUIC receive queue limits must hold one maximum-size datagram per connection and one incoming attempt",
            ));
        }
        let addr = socket.local_addr();
        let allow_mtud = !socket.capabilities().may_fragment;
        let rc = EndpointRef::new(
            socket,
            crate::proto::Endpoint::new(
                Arc::new(config),
                server_config.map(Arc::new),
                allow_mtud,
                None,
            ),
            addr.is_ipv6(),
            ceiling,
            fixed_peer,
        );
        {
            let mut state = rc.0.state.lock();
            let mut refused = Vec::new();
            let mut error = None;
            if let Some(registry) = state.sockets.live_mut() {
                for socket in advertised {
                    match registry.advertise(socket) {
                        Ok(_) => {}
                        Err(rejected) => {
                            refused.push(rejected.socket);
                            error = Some(rejected.error);
                        }
                    }
                }
            } else {
                refused.extend(advertised);
                error = Some(io::Error::from(io::ErrorKind::NotConnected));
            }
            drop(state);
            // A refused socket is dropped outside the endpoint lock, and the endpoint is not
            // built: it would otherwise advertise an address it does not own.
            drop(refused);
            if let Some(error) = error {
                return Err(error);
            }
        }
        let driver = EndpointDriver(rc.0.clone());
        let driver_lifecycle = rc.shared.lifecycle.clone();
        rc.shared.lifecycle.spawn(Box::pin(
            async move {
                if let Err(e) = driver.await {
                    driver_lifecycle.failed();
                    rama_core::telemetry::tracing::error!("I/O error: {}", e);
                }
            }
            .instrument(Span::current()),
        ));
        let lifecycle = rc.shared.lifecycle.clone();
        let inner = rc.0.clone();
        let cancellation = executor.guard().map(|guard| guard.clone_weak());
        executor.into_spawn_task(async move {
            let cancel = async {
                match cancellation {
                    Some(guard) => guard.cancelled().await,
                    None => std::future::pending().await,
                }
            };
            // `Some(graceful)` once the endpoint stops: graceful when shutdown cancelled it.
            let stop = tokio::select! {
                _ = lifecycle.join() => None,
                _ = lifecycle.requested() => Some(false),
                _ = cancel => Some(true),
            };
            let mut forced = false;
            if let Some(graceful) = stop {
                let started = tokio::time::Instant::now();
                {
                    let mut state = inner.state.lock();
                    state.shutdown = true;
                    if graceful {
                        state.close_unleased(VarInt::from_u32(0), &Bytes::new(), &inner.shared);
                    } else {
                        state.close(VarInt::from_u32(0), &Bytes::new(), &inner.shared, true);
                    }
                }
                if graceful {
                    // Each leased connection closes once let go, within half the budget (the
                    // rest is for the closes), or at once when shutdown is requested meanwhile.
                    let leases = async {
                        loop {
                            let released = inner.shared.close_leases_released.notified();
                            let mut released = std::pin::pin!(released);
                            released.as_mut().enable();
                            {
                                let mut state = inner.state.lock();
                                state.close_unleased(
                                    VarInt::from_u32(0),
                                    &Bytes::new(),
                                    &inner.shared,
                                );
                                if !state.has_leased_connections() {
                                    break;
                                }
                            }
                            released.await;
                        }
                    };
                    _ = tokio::time::timeout(shutdown_budget / 2, async {
                        tokio::select! {
                            () = leases => (),
                            () = lifecycle.requested() => (),
                        }
                    })
                    .await;
                    inner.state.lock().close(
                        VarInt::from_u32(0),
                        &Bytes::new(),
                        &inner.shared,
                        true,
                    );
                }
                let remaining = shutdown_budget.saturating_sub(started.elapsed());
                if tokio::time::timeout(remaining, lifecycle.join())
                    .await
                    .is_err()
                {
                    forced = true;
                    lifecycle.abort();
                    lifecycle.join().await;
                }
            }
            // Drivers deliver their Drained events synchronously, so every engine connection
            // is already retired once all drivers have joined.
            loop {
                {
                    let mut state = inner.state.lock();
                    let before = state.inner.pending_incoming();
                    state.inner.discard_incoming(IO_LOOP_BOUND);
                    let after = state.inner.pending_incoming();
                    if after == 0 {
                        break;
                    }
                    if after >= before {
                        // The deadline index lost track of live admissions: release everything
                        // that is left in one pass and report the failure instead of spinning.
                        state.inner.discard_all_incoming();
                        lifecycle.failed();
                        break;
                    }
                }
                tokio::task::yield_now().await;
            }
            lifecycle.finish(forced);
        });
        Ok(Self {
            inner: rc,
            default_client_config: None,
        })
    }

    /// Get the next incoming connection attempt from a client
    ///
    /// Yields [`Incoming`]s, or `None` if the endpoint is [`close`](Self::close)d. [`Incoming`]
    /// can be `await`ed to obtain the final [`Connection`](crate::driver::Connection), or used to e.g.
    /// filter connection attempts or force address validation, or converted into an intermediate
    /// `Connecting` future which can be used to e.g. send 0.5-RTT data.
    pub fn accept(&self) -> Accept<'_> {
        Accept {
            endpoint: self,
            notify: self.inner.shared.incoming.notified(),
        }
    }

    /// Set the client configuration used by `connect`
    pub fn set_default_client_config(&mut self, config: ClientConfig) {
        self.default_client_config = Some(config);
    }

    /// Connect to a remote endpoint
    ///
    /// `server_name` must be covered by the certificate presented by the server. This prevents a
    /// connection from being intercepted by an attacker with a valid certificate for some other
    /// server.
    ///
    /// May fail immediately due to configuration errors, or in the future if the connection could
    /// not be established.
    pub fn connect(&self, addr: SocketAddr, server_name: &str) -> Result<Connecting, ConnectError> {
        let config = match &self.default_client_config {
            Some(config) => config.clone(),
            None => return Err(ConnectError::NoDefaultClientConfig),
        };

        self.connect_with(config, addr, server_name)
    }

    /// Connect to a remote endpoint using a custom configuration.
    ///
    /// See [`connect()`] for details.
    ///
    /// [`connect()`]: Endpoint::connect
    pub fn connect_with(
        &self,
        config: ClientConfig,
        addr: SocketAddr,
        server_name: &str,
    ) -> Result<Connecting, ConnectError> {
        let mut endpoint = self.inner.state.lock();
        if endpoint.driver_lost || endpoint.recv_state.connections.close.is_some() {
            return Err(ConnectError::EndpointStopping);
        }
        let mut config = ceiling::fit_client(config, endpoint.payload_ceiling);
        if endpoint.fixed_peer {
            // A server's preferred address is unreachable from a socket fixed to one peer.
            config.preferred_address_policy = PreferredAddressPolicy::Decline;
        }
        let addr: SocketAddr = SocketAddress::from(addr).into_canonical_ip_addr().into();
        if addr.is_ipv6() && !endpoint.ipv6 {
            return Err(ConnectError::InvalidRemoteAddress(addr));
        }

        // New connections send from the active socket; the sender registers its dependence.
        let socket = endpoint
            .sockets
            .live_mut()
            .and_then(|sockets| {
                let id = sockets.active_id();
                sockets.sender(id)
            })
            .ok_or(ConnectError::EndpointStopping)?;
        let now = now();
        // A first attempt may be restarted once in another version (RFC 9368 §2.1).
        let restart = config.negotiation_offer.is_none().then(|| config.clone());
        let (ch, conn) = match endpoint.inner.connect(now, config, addr, server_name) {
            Ok(registered) => registered,
            Err(error) => {
                // The unused send handle and any socket it retired are dropped after unlocking.
                let mut socket = socket;
                let retired = socket
                    .take_lease()
                    .and_then(|lease| endpoint.sockets.release(lease, now));
                drop(endpoint);
                drop(retired);
                drop(socket);
                return Err(error);
            }
        };

        endpoint.stats.outgoing_handshakes += 1;
        let (connecting, driver) = endpoint.recv_state.connections.insert(
            ch,
            conn,
            socket,
            EndpointLink::new(Arc::downgrade(&self.inner.0), ch),
            None,
        );
        // Supervision is reserved before the registration lock is released, and the driver
        // is submitted with no lock held (see `ConnectionDriver::spawn`).
        let slot = self.inner.shared.lifecycle.reserve();
        drop(endpoint);
        driver.spawn(slot);
        Ok(match restart {
            Some(config) => connecting.with_restart(self.clone(), config, addr, server_name),
            None => connecting,
        })
    }

    /// Bind a new socket through Rama's shared UDP construction and switch to it.
    ///
    /// New connections and attempts use the new socket at once. Each existing connection moves
    /// to it only when QUIC allows the address change (RFC 9000 §9): a socket bound to the same
    /// address is adopted right away; a client whose handshake is confirmed, whose peer allows
    /// active migration and that holds an unused destination connection ID migrates after
    /// finishing any partially sent transmit; a client still handshaking or without an unused
    /// connection ID migrates once it has both; server connections and clients whose peer
    /// disabled active migration keep sending from their current socket.
    /// A replaced socket stays open while connections, queued attempts, queued responses or a
    /// recent Retry depend on it, up to a bounded number of retained sockets.
    ///
    /// On error, nothing changes and the previous socket stays active.
    pub async fn rebind(
        &self,
        address: impl Into<SocketAddress>,
        socket: UdpSocketConfig,
    ) -> Result<(), DatagramError> {
        let socket = UdpSocketFactory::new(socket).bind(address.into()).await?;
        self.rebind_packet_socket(socket)
            .map_err(DatagramError::from)
    }

    /// Switch to a packet socket the caller prepared. [`Endpoint::rebind`] describes what the
    /// switch means for existing connections.
    pub fn rebind_packet_socket(&self, socket: UdpPacketSocket) -> io::Result<()> {
        self.rebind_abstract(Socket::new(socket)?)
    }

    /// Switch to a bound standard socket. [`Endpoint::rebind`] describes what the switch means
    /// for existing connections.
    pub fn rebind_std_socket(&self, socket: std::net::UdpSocket) -> io::Result<()> {
        self.rebind_abstract(Socket::from_std(socket)?)
    }

    /// Switch to a new UDP socket, as [`Endpoint::rebind`] describes.
    pub(crate) fn rebind_abstract(&self, socket: Socket) -> io::Result<()> {
        let addr = socket.local_addr();
        // New connections follow the active socket's limits and reach.
        let ceiling = ceiling::payload_ceiling(&socket.capabilities()).map_err(io::Error::other)?;
        let fixed_peer = socket.fixed_peer().is_some();
        let mut inner = self.inner.state.lock();
        let now = now();
        // A refused socket is dropped only after the lock is released (see below).
        if inner.driver_lost || inner.shutdown {
            drop(inner);
            drop(socket);
            return Err(io::ErrorKind::NotConnected.into());
        }
        let State {
            sockets,
            recv_state,
            ..
        } = &mut *inner;
        let Some(sockets) = sockets.live_mut() else {
            drop(inner);
            drop(socket);
            return Err(io::ErrorKind::NotConnected.into());
        };
        // The previous socket stays registered while connections, queued attempts, queued
        // responses or a Retry route depend on it; a rebind beyond the retained bound fails
        // without any change.
        let (id, retired) = match sockets.activate(socket, now) {
            Ok(activated) => activated,
            Err(RebindRefused { error, socket }) => {
                drop(inner);
                drop(socket);
                return Err(error);
            }
        };
        let mut senders = Vec::with_capacity(recv_state.connections.channels.len());
        for handle in recv_state.connections.channels.keys() {
            if let Some(sender) = sockets.sender(id) {
                senders.push((*handle, sender));
            }
        }
        // Each connection completes its in-flight transmit on its current sender before it
        // switches, and releases the old socket once it has switched.
        for (handle, sender) in senders {
            if let Some(channel) = inner.recv_state.connections.channels.get(&handle) {
                channel.inner.control(Control::Rebind(sender));
            }
        }
        inner.ipv6 = addr.is_ipv6();
        inner.payload_ceiling = ceiling;
        inner.fixed_peer = fixed_peer;
        if let Some(driver) = inner.driver.take() {
            // Ensure the driver can register for wake-ups from the new socket
            driver.wake();
        }
        drop(inner);
        // A previous socket nothing depended on is dropped here, outside the endpoint lock.
        drop(retired);
        Ok(())
    }

    /// Replace the server configuration, affecting new incoming connections only
    ///
    /// Useful for e.g. refreshing TLS certificates without disrupting existing connections.
    pub fn set_server_config(&self, server_config: Option<ServerConfig>) {
        let mut state = self.inner.state.lock();
        let ceiling = state.payload_ceiling;
        state.inner.set_server_config(
            server_config.map(|config| Arc::new(ceiling::fit_server(config, ceiling))),
        );
    }

    /// Get the local `SocketAddr` the underlying socket is bound to
    pub fn local_addr(&self) -> io::Result<SocketAddr> {
        self.inner
            .state
            .lock()
            .sockets
            .live()
            .map(|sockets| sockets.active().local_addr())
            .ok_or_else(|| io::ErrorKind::NotConnected.into())
    }

    /// Local addresses of every retained socket, the active one first.
    pub fn local_addrs(&self) -> Vec<SocketAddr> {
        let state = self.inner.state.lock();
        state
            .sockets
            .live()
            .map(|sockets| {
                sockets
                    .ids()
                    .filter_map(|id| sockets.local_addr(id))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Local addresses this endpoint advertises as its preferred ones (RFC 9000 §9.6), in the
    /// order they were bound. Empty unless [`advertise_socket`](Self::advertise_socket) was
    /// used.
    pub fn advertised_addrs(&self) -> Vec<SocketAddr> {
        let state = self.inner.state.lock();
        state
            .sockets
            .live()
            .map(|sockets| sockets.advertised_addrs().collect())
            .unwrap_or_default()
    }

    /// Get the number of connections that are currently open
    pub fn open_connections(&self) -> usize {
        self.inner.state.lock().inner.open_connections()
    }

    /// Whether this endpoint has stopped accepting new connections.
    ///
    /// This includes explicit closure, graceful shutdown and loss of its runtime driver.
    /// Once closed, an endpoint cannot be reopened; create a new one to connect again.
    pub fn is_closed(&self) -> bool {
        let state = self.inner.state.lock();
        state.driver_lost || state.shutdown || state.recv_state.connections.close.is_some()
    }

    /// Close all of this endpoint's connections immediately and cease accepting new connections.
    ///
    /// See [`Connection::close()`] for details.
    ///
    /// [`Connection::close()`]: crate::driver::Connection::close
    pub fn close(&self, error_code: impl Into<VarInt>, reason: &[u8]) {
        self.inner.state.lock().close(
            error_code.into(),
            &Bytes::copy_from_slice(reason),
            &self.inner.shared,
            false,
        );
    }

    /// Stop the endpoint and join all drivers, releasing sockets even with retained handles.
    ///
    /// Connections still open are closed. A connection leaves as soon as its peer has been
    /// told, that is once its CONNECTION_CLOSE went out or the peer's own close arrived; the
    /// closing period that would otherwise follow (RFC 9000 §10.2) only serves to answer late
    /// packets, which a stopping endpoint will not do. A peer whose copy of the close was lost
    /// waits out its idle timeout instead. To give every close the full closing period first,
    /// call [`close()`](Self::close) and then [`wait_idle()`](Self::wait_idle) before this.
    pub async fn shutdown(&self) -> ShutdownOutcome {
        self.inner.shared.lifecycle.request();
        self.inner.shared.lifecycle.completed().await
    }

    /// Wait for all connections on the endpoint to be cleanly shut down
    ///
    /// Waiting for this condition before exiting ensures that a good-faith effort is made to notify
    /// peers of recent connection closes, whereas exiting immediately could force them to wait out
    /// the idle timeout period.
    ///
    /// Does not proactively close existing connections or cause incoming connections to be
    /// rejected. Consider calling [`close()`] if that is desired.
    ///
    /// [`close()`]: Endpoint::close
    pub async fn wait_idle(&self) {
        loop {
            {
                let endpoint = &mut *self.inner.state.lock();
                if endpoint.is_idle() {
                    break;
                }
                // Construct future while lock is held to avoid race
                self.inner.shared.idle.notified()
            }
            .await;
        }
    }
}

/// Statistics on [Endpoint] activity
#[non_exhaustive]
#[derive(Debug, Default, Copy, Clone)]
pub struct EndpointStats {
    /// Cumulative number of Quic handshakes accepted by this [Endpoint]
    pub accepted_handshakes: u64,
    /// Cumulative number of Quic handshakees sent from this [Endpoint]
    pub outgoing_handshakes: u64,
    /// Cumulative number of Quic handshakes refused on this [Endpoint]
    pub refused_handshakes: u64,
    /// Cumulative number of Quic handshakes ignored on this [Endpoint]
    pub ignored_handshakes: u64,
    /// UDP datagrams passed to the protocol engine, including malformed QUIC packets.
    pub received_datagrams: u64,
    /// Entire receive entries discarded because at least one datagram was truncated.
    pub truncated_receive_entries: u64,
    /// Receive attempts that failed with a connection-reset error, ignored as attacker-injectable
    /// noise; counted apart from received datagrams.
    pub ignored_receive_errors: u64,
    /// Stateless responses dropped at the bounded outgoing queue.
    pub dropped_responses: u64,
    /// Stateless responses the socket refused for their destination.
    pub failed_responses: u64,
    /// Pending incoming handshakes expired before application acceptance.
    pub expired_incoming: u64,
    /// Retries issued to unvalidated attempts because the endpoint was under load (see
    /// [`AdmissionConfig`](crate::AdmissionConfig)); one its response queue dropped is also
    /// counted in `dropped_responses`.
    pub retried_under_load: u64,
    /// Attempts refused because the endpoint held as many in progress as it allows.
    pub refused_at_limit: u64,
    /// Attempts refused because their source held as many in progress as it may.
    pub refused_per_source: u64,
    /// Unvalidated attempts refused under load, as an endpoint without local connection IDs
    /// cannot answer them with a Retry.
    pub refused_unvalidated: u64,
    /// Incoming attempts in progress: admitted, and not yet established, failed, timed out or
    /// abandoned.
    pub handshakes_in_progress: usize,
    /// In-progress attempts at which unvalidated ones are answered with a Retry; zero while
    /// admission is disabled.
    pub retry_threshold: usize,
    /// Received datagrams dropped because a receive queue was saturated.
    pub dropped_packets: u64,
    /// Occupancy and drop counters of the endpoint-wide receive queue budget.
    pub receive_queue: PacketQueueStats,
    /// Entries the queued-incoming container currently retains storage for.
    pub incoming_queue_capacity: usize,
    /// Sockets currently owned: the active one plus those still serving earlier work.
    pub retained_sockets: usize,
    /// Sockets retired so far after their last dependent went away.
    pub retired_sockets: u64,
}

/// A future that drives IO on an endpoint
///
/// This task functions as the switch point between the UDP socket object and the
/// `Endpoint` responsible for routing datagrams to their owning `Connection`.
/// In order to do so, it also facilitates the exchange of different types of events
/// flowing between the `Endpoint` and the tasks managing `Connection`s. As such,
/// running this task is necessary to keep the endpoint's connections running.
///
/// `EndpointDriver` futures terminate when all clones of the `Endpoint` have been dropped, or when
/// an I/O error occurs.
#[must_use = "endpoint drivers must be spawned for I/O to occur"]
#[derive(Debug)]
pub(crate) struct EndpointDriver(pub(crate) Arc<EndpointInner>);

impl Future for EndpointDriver {
    type Output = Result<(), io::Error>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context) -> Poll<Self::Output> {
        // Sockets retired during this poll outlive the lock: they are dropped here, after the
        // locked part returned, on the success and the error path alike.
        let mut retired = Vec::new();
        let outcome = self.poll_locked(cx, &mut retired);
        drop(retired);
        match outcome {
            Ok(Some(keep_going)) => {
                // If there is more work to do schedule the endpoint task again.
                // `wake_by_ref()` is called outside the lock to minimize
                // lock contention on a multithreaded runtime.
                if keep_going {
                    cx.waker().wake_by_ref();
                }
                Poll::Pending
            }
            Ok(None) => Poll::Ready(Ok(())),
            Err(error) => Poll::Ready(Err(error)),
        }
    }
}

impl EndpointDriver {
    /// One poll under the endpoint lock. `Ok(Some(keep_going))` keeps the driver alive,
    /// `Ok(None)` finishes it. Retired sockets are pushed to `retired` for the caller to drop
    /// outside the lock, which this method never holds when it returns.
    fn poll_locked(&self, cx: &mut Context, retired: &mut Vec<Socket>) -> io::Result<Option<bool>> {
        let mut endpoint = self.0.state.lock();
        // The task polling the driver may change; a waker kept from an earlier poll would wake
        // the wrong one.
        match endpoint.driver.as_mut() {
            Some(waker) => waker.clone_from(cx.waker()),
            None => endpoint.driver = Some(cx.waker().clone()),
        }

        let now = now();
        let mut keep_going = false;
        keep_going |= match endpoint.drive_recv(cx, now, retired) {
            Ok(keep_going) => keep_going,
            // A stopping endpoint only answers late packets: losing its socket ends it.
            Err(_) if endpoint.shutdown => return Ok(None),
            Err(error) => return Err(error),
        };
        keep_going |= endpoint.drive_incoming_timeout(cx, now, retired);
        keep_going |= endpoint.drive_route_expiry(cx, now, retired);
        if let Some(sockets) = endpoint.sockets.live_mut() {
            let driven = sockets.drive_responses(cx, now)?;
            keep_going |= driven.keep_going;
            retired.extend(driven.retired);
        }
        endpoint.leave_failed_sockets(now, retired);

        if !endpoint.recv_state.incoming.is_empty() {
            self.0.shared.incoming.notify_waiters();
        }

        let finished = (self.0.shared.ref_count.load(Ordering::Relaxed) == 0 || endpoint.shutdown)
            && endpoint.recv_state.connections.is_empty();
        Ok((!finished).then_some(keep_going))
    }
}

impl Drop for EndpointDriver {
    fn drop(&mut self) {
        let mut endpoint = self.0.state.lock();
        endpoint.driver_lost = true;
        endpoint.incoming_timer.clear();
        endpoint.route_timer.clear();
        // Every socket is released here regardless of retained handles: nothing may keep a
        // bound port alive after the driver is gone.
        let sockets = endpoint.sockets.release_all();
        while let Some(queued) = endpoint.recv_state.incoming.pop_front() {
            endpoint.inner.ignore(queued.incoming);
        }
        self.0.shared.idle.notify_waiters();
        self.0.shared.incoming.notify_waiters();
        endpoint.inner.wake_pending_incoming();
        // Closing the packet channels tells every connection driver that the endpoint is gone.
        // Connection state is released outside the endpoint lock (lock order).
        let channels = std::mem::take(&mut endpoint.recv_state.connections.channels);
        drop(endpoint);
        drop(channels);
        drop(sockets);
    }
}

/// The address a bound packet socket has.
fn bound_address(socket: &UdpPacketSocket) -> Result<SocketAddr, DatagramError> {
    rama_net::stream::Socket::local_addr(socket)
        .map(SocketAddr::from)
        .map_err(DatagramError::Io)
}

/// Bind a socket for each preferred address this server configuration advertises, and return the
/// configuration with those addresses replaced by the ones the sockets are bound to.
///
/// A configured address that cannot be bound fails: it is an explicit option, and advertising an
/// address this endpoint does not own would send clients somewhere nothing answers.
async fn bind_advertised(
    factory: &UdpSocketFactory,
    server_config: Option<ServerConfig>,
) -> Result<(Option<ServerConfig>, Vec<UdpPacketSocket>), DatagramError> {
    let Some(mut server_config) = server_config else {
        return Ok((None, Vec::new()));
    };
    let mut sockets = Vec::new();
    if let Some(address) = server_config.preferred_address_v4 {
        // A wildcard address is not a destination a client can be sent to: resolving the port
        // leaves the address unspecified, so it is refused rather than advertised.
        if address.ip().is_unspecified() {
            return Err(DatagramError::Io(io::Error::new(
                io::ErrorKind::InvalidInput,
                "a preferred address must be a concrete address a peer can reach, not a wildcard",
            )));
        }
        let socket = factory.bind(SocketAddr::from(address)).await?;
        match bound_address(&socket)? {
            SocketAddr::V4(bound) if !bound.ip().is_unspecified() => {
                server_config.preferred_address_v4 = Some(bound);
            }
            SocketAddr::V4(bound) => {
                return Err(DatagramError::Io(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("the preferred IPv4 address bound as the unspecified {bound}"),
                )));
            }
            SocketAddr::V6(bound) => {
                return Err(DatagramError::Io(io::Error::other(format!(
                    "the preferred IPv4 address bound as {bound}"
                ))));
            }
        }
        sockets.push(socket);
    }
    if let Some(address) = server_config.preferred_address_v6 {
        if address.ip().is_unspecified() {
            return Err(DatagramError::Io(io::Error::new(
                io::ErrorKind::InvalidInput,
                "a preferred address must be a concrete address a peer can reach, not a wildcard",
            )));
        }
        let socket = factory.bind(SocketAddr::from(address)).await?;
        match bound_address(&socket)? {
            SocketAddr::V6(bound) if !bound.ip().is_unspecified() => {
                server_config.preferred_address_v6 = Some(bound);
            }
            SocketAddr::V6(bound) => {
                return Err(DatagramError::Io(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("the preferred IPv6 address bound as the unspecified {bound}"),
                )));
            }
            SocketAddr::V4(bound) => {
                return Err(DatagramError::Io(io::Error::other(format!(
                    "the preferred IPv6 address bound as {bound}"
                ))));
            }
        }
        sockets.push(socket);
    }
    Ok((Some(server_config), sockets))
}

/// The kernel receive and send buffer an endpoint asks for on the sockets it binds itself.
///
/// QUIC arrives in bursts of coalesced datagrams and the endpoint drains its socket from one
/// task; the platform's default of a few hundred KiB is under a millisecond of a fast transfer
/// and drops packets before the endpoint sees them. This floor is best effort: a platform limit
/// caps it silently and a bind never fails on it (see `UdpSocketConfig::with_min_buffer_size`).
/// Pass a `UdpSocketConfig` of your own to bind without it.
pub const DEFAULT_SOCKET_BUFFER_SIZE: usize = octets::mib(7);

/// Rama's UDP defaults with the endpoint's buffer floor.
pub(crate) fn default_socket_config() -> UdpSocketConfig {
    UdpSocketConfig::default().with_min_buffer_size(DEFAULT_SOCKET_BUFFER_SIZE)
}

/// The socket configuration a client binds with: the endpoint defaults, plus a request for a
/// dual-stack socket on an IPv6 address that the platform may refuse. A refusal leaves the
/// platform's own `IPV6_V6ONLY` default in place and the socket bound.
fn client_socket_config(address: SocketAddress) -> UdpSocketConfig {
    let mut config = default_socket_config();
    if address.ip_addr.is_ipv6() {
        let mut options = config.socket_options().clone();
        options.only_v6_best_effort = Some(false);
        config.set_socket_options(options);
    }
    config
}

#[derive(Debug)]
pub(crate) struct EndpointInner {
    pub(crate) state: Mutex<State>,
    pub(crate) shared: Shared,
}

impl EndpointInner {
    /// Apply events a connection driver produced, after that driver released its own lock.
    ///
    /// Nothing is queued: identifiers issued in response reach the connection through
    /// [`ConnectionInner::control`] before this returns, and Drained retires the connection
    /// from the table exactly once.
    pub(crate) fn connection_events(&self, handle: ConnectionHandle, events: Vec<EndpointEvent>) {
        let mut state = self.state.lock();
        let mut retired = None;
        for event in events {
            #[cfg(test)]
            if state.hold_route_installs && event.is_reset_route() {
                state.held_route_installs.push((handle, event));
                continue;
            }
            if event.is_drained() {
                retired = state.recv_state.connections.channels.remove(&handle);
                if state.recv_state.connections.is_empty() {
                    if state.is_idle() {
                        self.shared.idle.notify_waiters();
                    }
                    if let Some(driver) = state.driver.take() {
                        driver.wake();
                    }
                }
            }
            if let Some(control) = state.inner.handle_event(handle, event)
                && let Some(channel) = state.recv_state.connections.channels.get(&handle)
            {
                channel.inner.control(Control::Proto(control));
            }
        }
        drop(state);
        // The retired connection's state is released outside the endpoint lock (lock order).
        drop(retired);
    }
}

/// What this endpoint can offer a connection whose path has moved to a local address.
#[derive(Debug)]
pub(crate) enum LocalSocket {
    /// A socket bound to exactly that address; the handle owns a lease on it.
    Owned(crate::driver::udp::Sender),
    /// No socket is bound to that address, but the one the connection already sends from is
    /// bound to a wildcard of that port and family and can select a source address per datagram,
    /// so it can carry that path.
    Covered,
    /// This endpoint owns no socket that can send from that address.
    Unowned,
}

impl EndpointInner {
    /// What this endpoint can offer for sending from `local`, given that the connection currently
    /// sends from the socket named `current`.
    pub(crate) fn socket_for_local(&self, local: SocketAddr, current: SocketId) -> LocalSocket {
        let mut state = self.state.lock();
        let Some(registry) = state.sockets.live_mut() else {
            return LocalSocket::Unowned;
        };
        if let Some(id) = registry.id_for_local(local)
            && let Some(sender) = registry.sender(id)
        {
            return LocalSocket::Owned(sender);
        }
        // The socket in use may already cover the address, in which case nothing changes. A
        // delayed datagram for a path this connection has left names an address another retained
        // socket covers instead, and that socket is the one it must leave from.
        if registry.covers_local(current, local) {
            return LocalSocket::Covered;
        }
        if let Some(id) = registry.only_cover_for(local)
            && let Some(sender) = registry.sender(id)
        {
            return LocalSocket::Owned(sender);
        }
        LocalSocket::Unowned
    }
}

impl EndpointRef {
    /// The address of socket `id`, while the endpoint still holds it.
    pub(crate) fn socket_addr(&self, id: SocketId) -> Option<SocketAddr> {
        self.state.lock().sockets.live()?.local_addr(id)
    }

    /// Whether the endpoint accepts no more work, which ends every pending attempt.
    pub(crate) fn is_closing(&self) -> bool {
        self.state.lock().is_closing()
    }

    /// How much of a pending attempt's ClientHello has arrived, and the attempt's progress
    /// generation that was current when looking.
    pub(crate) fn client_hello_progress(
        &self,
        incoming: &crate::proto::Incoming,
    ) -> Result<(ClientHelloPeek, u64), ConnectionError> {
        let mut state = self.state.lock();
        if state.is_closing() {
            return Err(ConnectionError::LocallyClosed);
        }
        let generation = incoming.progress().generation();
        Ok((state.inner.client_hello(incoming), generation))
    }

    /// Tests: stop applying route installations, so a datagram that needs one can be observed
    /// waiting instead of leaving.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn hold_route_installs(&self) {
        self.0.state.lock().hold_route_installs = true;
    }

    /// Tests: answer the route installations put aside with a refusal, as a full routing table
    /// does, so the connection fails rather than waiting for a route that cannot exist.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn refuse_route_installs(&self) {
        let mut state = self.0.state.lock();
        state.hold_route_installs = false;
        let held = std::mem::take(&mut state.held_route_installs);
        for (handle, event) in held {
            let Some(refusal) = event.route_refusal() else {
                continue;
            };
            if let Some(channel) = state.recv_state.connections.channels.get(&handle) {
                channel.inner.control(Control::Proto(refusal));
            }
        }
    }

    /// Tests: apply the route installations put aside, and hand each connection the
    /// acknowledgement the endpoint answers with, as it would have received it otherwise.
    #[cfg(all(
        test,
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    ))]
    pub(crate) fn release_route_installs(&self) {
        let mut state = self.0.state.lock();
        state.hold_route_installs = false;
        let held = std::mem::take(&mut state.held_route_installs);
        for (handle, event) in held {
            if let Some(control) = state.inner.handle_event(handle, event)
                && let Some(channel) = state.recv_state.connections.channels.get(&handle)
            {
                channel.inner.control(Control::Proto(control));
            }
        }
    }

    /// Accept an attempt that arrived on socket `received_on`: the connection sends from that
    /// socket, and a refusal response leaves from it too. The attempt's socket dependence is
    /// released here on every path.
    ///
    /// TLS setup and first-flight processing, the costly part, run between two holds of the
    /// endpoint lock so they do not hold up datagram routing for established connections; the
    /// first hold reserves the attempt's routes and the second registers the connection, or
    /// releases the reservation when the handshake failed or the endpoint stopped meanwhile.
    pub(crate) fn accept(
        &self,
        incoming: crate::proto::Incoming,
        lease: Lease,
        server_config: Option<Arc<ServerConfig>>,
    ) -> Result<Connecting, ConnectionError> {
        let received_on = lease.id();
        let mut response_buffer = Vec::new();
        let mut state = self.state.lock();
        let started = now();
        if state.is_closing()
            || !state
                .sockets
                .live()
                .is_some_and(|sockets| sockets.is_usable(received_on))
        {
            // Closing, or the receiving socket is gone or unusable: the attempt cannot be
            // answered on it.
            state.inner.ignore(incoming);
            let retired = state.sockets.release(lease, started);
            drop(state);
            drop(retired);
            return Err(ConnectionError::LocallyClosed);
        }
        let accepting =
            match state
                .inner
                .start_accept(incoming, started, &mut response_buffer, server_config)
            {
                Ok(accepting) => accepting,
                Err(error) => {
                    if let Some(transmit) = error.response {
                        state
                            .sockets
                            .respond(received_on, transmit, &response_buffer);
                        state.wake_driver();
                    }
                    let retired = state.sockets.release(lease, started);
                    drop(state);
                    drop(retired);
                    return Err(error.cause);
                }
            };
        let in_flight = AcceptInFlight::begin(self, &mut state);
        drop(state);

        let accepted = accepting.accept();

        let mut state = self.state.lock();
        in_flight.end(&mut state);
        let now = now();
        let mut retired = Vec::new();
        let sender = if state.is_closing() {
            None
        } else {
            state
                .sockets
                .live_mut()
                .and_then(|sockets| sockets.sender(received_on))
        };
        // An unused send handle is dropped after unlocking, like the sockets it retires.
        let mut unused_sender = None;
        let registered = match sender {
            None => {
                state.inner.abandon_accept(accepted);
                Err(ConnectionError::LocallyClosed)
            }
            Some(mut socket) => match state.inner.finish_accept(accepted, &mut response_buffer) {
                Ok(registered) => {
                    state.stats.accepted_handshakes += 1;
                    let (connecting, driver) = state.recv_state.connections.insert(
                        registered.handle,
                        registered.connection,
                        socket,
                        EndpointLink::new(Arc::downgrade(&self.0), registered.handle),
                        Some(registered.admission),
                    );
                    Ok((connecting, driver, registered.late))
                }
                Err(error) => {
                    if let Some(sender_lease) = socket.take_lease() {
                        retired.extend(state.sockets.release(sender_lease, now));
                    }
                    unused_sender = Some(socket);
                    if let Some(transmit) = error.response {
                        state
                            .sockets
                            .respond(received_on, transmit, &response_buffer);
                        state.wake_driver();
                    }
                    Err(error.cause)
                }
            },
        };
        retired.extend(state.sockets.release(lease, now));
        // An accept that ends without a connection may have been all that kept the endpoint
        // from idle, and no Drained event follows it.
        if registered.is_err() && state.is_idle() {
            self.shared.idle.notify_waiters();
        }
        // Supervision is reserved before the registration lock is released, and the driver
        // is submitted with no lock held (see `ConnectionDriver::spawn`).
        let slot = registered
            .as_ref()
            .ok()
            .map(|_| self.shared.lifecycle.reserve());
        drop(state);
        drop(retired);
        drop(unused_sender);
        registered.map(|(connecting, driver, late)| {
            // What arrived while the handshake ran may complete the ClientHello: it is processed
            // under the connection's lock, ahead of the queue its driver drains, not the endpoint's.
            if !late.is_empty() {
                let inner = connecting.inner();
                let mut conn = inner.state.lock();
                for event in late {
                    conn.inner.handle_event(event);
                }
            }
            if let Some(slot) = slot {
                driver.spawn(slot);
            }
            connecting
        })
    }
}

/// An accept between its two holds of the endpoint lock. It keeps the endpoint from idle,
/// since it may still become a connection, and is uncounted under the lock however the
/// handshake work between the holds ends, unwinding included.
struct AcceptInFlight<'a> {
    endpoint: &'a EndpointInner,
    counted: bool,
}

impl<'a> AcceptInFlight<'a> {
    fn begin(endpoint: &'a EndpointInner, state: &mut State) -> Self {
        state.accepting += 1;
        Self {
            endpoint,
            counted: true,
        }
    }

    fn end(mut self, state: &mut State) {
        state.accepting -= 1;
        self.counted = false;
    }
}

impl Drop for AcceptInFlight<'_> {
    fn drop(&mut self) {
        if self.counted {
            let mut state = self.endpoint.state.lock();
            state.accepting -= 1;
            if state.is_idle() {
                self.endpoint.shared.idle.notify_waiters();
            }
        }
    }
}

impl EndpointInner {
    pub(crate) fn refuse(&self, incoming: crate::proto::Incoming, lease: Lease) {
        let received_on = lease.id();
        let mut state = self.state.lock();
        if incoming.is_expired() {
            state.inner.ignore(incoming);
        } else {
            state.stats.refused_handshakes += 1;
            let mut response_buffer = Vec::new();
            if let Some(transmit) = state.inner.refuse(incoming, &mut response_buffer) {
                state
                    .sockets
                    .respond(received_on, transmit, &response_buffer);
            }
        }
        let retired = state.sockets.release(lease, now());
        state.wake_driver();
        drop(state);
        drop(retired);
    }

    /// Send a Retry on the attempt's receiving socket. The peer is told to come back to that
    /// socket's address, so the socket keeps receiving even when it has been replaced meanwhile.
    ///
    /// The hold lasts the configured Retry token lifetime, measured on the driver's monotonic
    /// clock from the moment the Retry is issued under the lock, and ends at that instant (the
    /// endpoint's timer is scheduled for it). It is a bounded retention policy, not the token's
    /// validity: the token is checked, inclusively, against the configured wall-clock time source
    /// with a whole-second issue time, so the two can differ by up to a second plus any
    /// wall-clock adjustment. A lifetime the monotonic clock cannot represent is refused before
    /// any Retry is issued (`RetryRefused::LifetimeUnrepresentable`). On error the attempt and
    /// its lease stay with the caller.
    pub(crate) fn retry(
        &self,
        incoming: crate::proto::Incoming,
        lease: Lease,
    ) -> Result<(), (crate::proto::RetryError, Lease)> {
        let received_on = lease.id();
        let mut state = self.state.lock();
        let now = now();
        let hold_until = match state.inner.retry_token_lifetime() {
            Some(lifetime) => match now.checked_add(lifetime) {
                Some(until) => Some(until),
                None => {
                    return Err((
                        crate::proto::RetryError::new(
                            incoming,
                            crate::proto::RetryRefused::LifetimeUnrepresentable,
                        ),
                        lease,
                    ));
                }
            },
            None => None,
        };
        let mut response_buffer = Vec::new();
        let transmit = match state.inner.retry(incoming, &mut response_buffer) {
            Ok(transmit) => transmit,
            Err(error) => return Err((error, lease)),
        };
        if let Some(until) = hold_until
            && let Some(sockets) = state.sockets.live_mut()
        {
            sockets.hold_route(received_on, until);
        }
        state
            .sockets
            .respond(received_on, transmit, &response_buffer);
        let retired = state.sockets.release(lease, now);
        state.wake_driver();
        drop(state);
        drop(retired);
        Ok(())
    }

    pub(crate) fn ignore(&self, incoming: crate::proto::Incoming, lease: Lease) {
        let mut state = self.state.lock();
        state.stats.ignored_handshakes += 1;
        state.inner.ignore(incoming);
        let retired = state.sockets.release(lease, now());
        drop(state);
        drop(retired);
    }

    /// Connection drivers hand back the send handles they gave up, after dropping their own
    /// lock. Their socket leases are released here; the handles and any socket retired as a
    /// result are dropped outside the endpoint lock.
    pub(crate) fn release_senders(&self, mut senders: Vec<Sender>) {
        let mut state = self.state.lock();
        let now = now();
        let retired: Vec<Socket> = senders
            .iter_mut()
            .filter_map(Sender::take_lease)
            .filter_map(|lease| state.sockets.release(lease, now))
            .collect();
        drop(state);
        drop(retired);
        drop(senders);
    }
}

#[derive(Debug)]
pub(crate) struct State {
    /// The sockets this endpoint owns: the active one and earlier ones that connections, queued
    /// attempts or queued responses still depend on (see [`SocketRegistry`]).
    sockets: Sockets,
    inner: crate::proto::Endpoint,
    recv_state: RecvState,
    driver: Option<Waker>,
    ipv6: bool,
    /// The largest UDP payload the socket carries; connections start within it.
    payload_ceiling: u16,
    /// The socket reaches one remote only, so connections cannot move to another address.
    fixed_peer: bool,
    driver_lost: bool,
    shutdown: bool,
    /// A graceful shutdown closed only the unleased connections so far: the next
    /// [`State::close`] still reaches every connection.
    leased_close_pending: bool,
    /// Accepts between their two holds of this lock (see [`EndpointRef::accept`]).
    accepting: usize,
    incoming_timer: DeadlineTimer,
    /// Fires when a replaced socket's Retry route hold expires (see [`SocketRegistry::hold_route`]).
    route_timer: DeadlineTimer,
    stats: EndpointStats,
    /// Endpoint-wide budget shared by every queued packet and queued incoming attempt.
    packet_budget: PacketBudget,
    /// This endpoint's place in the endpoint metrics it was built with.
    #[cfg(feature = "opentelemetry")]
    metrics: Option<crate::telemetry::EndpointSlot>,
    /// Tests: while set, a route installation is put aside instead of applied, so a test can
    /// attempt a send in the window before the connection learns its route exists.
    #[cfg(test)]
    hold_route_installs: bool,
    #[cfg(test)]
    held_route_installs: Vec<(ConnectionHandle, EndpointEvent)>,
}

#[derive(Debug)]
pub(crate) struct Shared {
    incoming: Notify,
    idle: Notify,
    /// A connection's last [`CloseLease`](crate::CloseLease) was dropped.
    pub(crate) close_leases_released: Notify,
    lifecycle: Lifecycle,
    /// Number of live handles that can be used to initiate or handle I/O; excludes the driver
    ref_count: AtomicUsize,
}

impl State {
    /// Whether this endpoint accepts no more work: closed, shut down or without its driver.
    fn is_closing(&self) -> bool {
        self.driver_lost || self.shutdown || self.recv_state.connections.close.is_some()
    }

    /// No connection is open and none is being accepted.
    fn is_idle(&self) -> bool {
        self.recv_state.connections.is_empty() && self.accepting == 0
    }

    /// A graceful shutdown closes every connection without a
    /// [`CloseLease`](crate::CloseLease), each once: at the start and as their leases go. The
    /// still leased ones follow with [`Self::close`].
    fn close_unleased(&mut self, error_code: VarInt, reason: &Bytes, shared: &Shared) {
        self.recv_state.connections.close = Some((error_code, reason.clone(), true));
        self.leased_close_pending = true;
        for channel in self.recv_state.connections.channels.values_mut() {
            if !channel.shutdown_closed
                && channel.inner.shared.close_leases.load(Ordering::Acquire) == 0
            {
                channel.shutdown_closed = true;
                channel.inner.control(Control::Close {
                    error_code,
                    reason: reason.clone(),
                    abandon: true,
                });
            }
        }
        shared.incoming.notify_waiters();
        self.inner.wake_pending_incoming();
        if let Some(driver) = self.driver.take() {
            driver.wake();
        }
    }

    /// Connections a graceful shutdown has not closed yet: the still leased ones.
    fn has_leased_connections(&self) -> bool {
        self.recv_state
            .connections
            .channels
            .values()
            .any(|channel| !channel.shutdown_closed)
    }

    fn close(&mut self, error_code: VarInt, reason: &Bytes, shared: &Shared, abandon: bool) {
        let first = self.recv_state.connections.close.is_none()
            || std::mem::take(&mut self.leased_close_pending);
        if first {
            self.recv_state.connections.close = Some((error_code, reason.clone(), abandon));
        } else if abandon && let Some(close) = self.recv_state.connections.close.as_mut() {
            close.2 = true;
        }
        // A shutdown after a plain close still lets every connection leave early.
        if first || abandon {
            for channel in self.recv_state.connections.channels.values_mut() {
                channel.shutdown_closed = true;
                channel.inner.control(Control::Close {
                    error_code,
                    reason: reason.clone(),
                    abandon,
                });
            }
            // A graceful shutdown waiting on leases has nothing left to wait for.
            shared.close_leases_released.notify_waiters();
        }
        shared.incoming.notify_waiters();
        self.inner.wake_pending_incoming();
        if let Some(driver) = self.driver.take() {
            driver.wake();
        }
    }

    fn drive_incoming_timeout(
        &mut self,
        cx: &mut Context<'_>,
        now: Instant,
        retired: &mut Vec<Socket>,
    ) -> bool {
        let expired = self.inner.expire_incoming(now, IO_LOOP_BOUND);
        self.stats.expired_incoming = self.stats.expired_incoming.saturating_add(expired as u64);
        // Arrival order and a fixed endpoint timeout make expired queued handles a prefix.
        for _ in 0..IO_LOOP_BOUND {
            if !self
                .recv_state
                .incoming
                .front()
                .is_some_and(|queued| queued.incoming.is_expired())
            {
                break;
            }
            if let Some(queued) = self.recv_state.incoming.pop_front() {
                self.inner.ignore(queued.incoming);
                retired.extend(self.sockets.release(queued.lease, now));
            }
        }
        let Some(deadline) = self.inner.poll_incoming_timeout() else {
            self.incoming_timer.clear();
            return self
                .recv_state
                .incoming
                .front()
                .is_some_and(|queued| queued.incoming.is_expired());
        };
        self.incoming_timer.poll(deadline, now, cx) == Deadline::Elapsed
    }

    /// Retire replaced sockets whose Retry route hold has expired, and arm the timer for the
    /// next hold so an unanswered Retry never keeps a socket for good. Returns whether the
    /// driver must poll again: the timer may fire after `now` was read, and that hold is only
    /// judged against a fresh clock on the next poll, which also re-arms the next deadline.
    fn drive_route_expiry(
        &mut self,
        cx: &mut Context<'_>,
        now: Instant,
        retired: &mut Vec<Socket>,
    ) -> bool {
        let Some(sockets) = self.sockets.live_mut() else {
            self.route_timer.clear();
            return false;
        };
        retired.extend(sockets.expire_routes(now));
        if let Some(deadline) = sockets.next_route_expiry() {
            self.route_timer.poll(deadline, now, cx) == Deadline::Elapsed
        } else {
            self.route_timer.clear();
            false
        }
    }

    /// A socket failed: its dependents are told once. Each connection still sending from it
    /// moves to a path it may use or is terminated with a local path error (see
    /// [`ConnectionInner::path_failed`]). Attempts still queued on it can no longer be answered
    /// and are released here (engine state cleaned, lease returned); an attempt the application
    /// already holds is refused with `LocallyClosed` when it is accepted, its responses dropped.
    fn leave_failed_sockets(&mut self, now: Instant, retired: &mut Vec<Socket>) {
        let Self {
            sockets,
            recv_state,
            inner,
            ..
        } = self;
        let Some(sockets) = sockets.live_mut() else {
            return;
        };
        // An address this endpoint advertised as preferred but no longer has a usable socket for
        // is not offered to connections that have yet to handshake. Recorded when the failure was
        // marked, so it holds whether or not the entry has been retired since.
        for address in sockets.take_withdrawn() {
            inner.stop_advertising(address);
        }
        let failed = sockets.take_failed_to_announce();
        if failed.iter().next().is_none() {
            return;
        }
        for id in failed.iter() {
            for channel in recv_state.connections.channels.values() {
                channel.inner.path_failed(id);
            }
        }
        for _ in 0..recv_state.incoming.len() {
            let Some(queued) = recv_state.incoming.pop_front() else {
                break;
            };
            if failed.iter().any(|id| id == queued.lease.id()) {
                inner.ignore(queued.incoming);
                retired.extend(sockets.release(queued.lease, now));
            } else if let Err(refused) = recv_state.incoming.push_back(queued) {
                // Re-queueing what was just popped cannot exceed the bound; refusal is treated
                // like any other refused admission.
                recv_state.dropped_packets += 1;
                inner.ignore(refused.incoming);
                retired.extend(sockets.release(refused.lease, now));
            }
        }
    }

    /// Queue a stateless response on the active socket (tests).
    #[cfg(all(test, any(feature = "boring", feature = "aws-lc", feature = "ring")))]
    fn respond_active(&mut self, transmit: proto::Transmit, response_buffer: &[u8]) {
        let Some(id) = self.sockets.live().map(SocketRegistry::active_id) else {
            return;
        };
        self.respond(id, transmit, response_buffer);
    }

    #[cfg(all(test, any(feature = "boring", feature = "aws-lc", feature = "ring")))]
    /// Queue a stateless response on socket `on` and wake the driver to send it.
    fn respond(&mut self, on: SocketId, transmit: proto::Transmit, response_buffer: &[u8]) {
        self.sockets.respond(on, transmit, response_buffer);
        self.wake_driver();
    }

    fn wake_driver(&self) {
        if let Some(waker) = &self.driver {
            waker.wake_by_ref();
        }
    }

    /// Receive from every usable socket in rotation order under one work budget. A failing
    /// active socket is fatal; a failing retiring socket is marked and skipped from then on.
    fn drive_recv(
        &mut self,
        cx: &mut Context,
        now: Instant,
        retired: &mut Vec<Socket>,
    ) -> Result<bool, io::Error> {
        let Self {
            sockets,
            recv_state,
            inner,
            packet_budget,
            ..
        } = self;
        let Some(sockets) = sockets.live_mut() else {
            return Ok(false);
        };
        let mut cycle = recv_state.start_recv_cycle();
        let mut keep_going = false;
        let mut outcome = Ok(());
        let mut visited = false;
        for id in sockets.receive_order().iter() {
            // One allowance covers every socket: the ones not reached this poll are served first
            // by the next one, which the continuation wake requests. The first socket of a pass
            // is always polled, so a budget already spent by the time the pass starts (the task
            // was preempted) still yields one batch of progress instead of an idle spin.
            if visited && !cycle.allow_work(crate::driver::now) {
                sockets.continue_receive_from(id);
                keep_going = true;
                break;
            }
            let Some(socket) = sockets.socket_mut(id) else {
                continue;
            };
            visited = true;
            let progress =
                recv_state.poll_socket(cx, inner, socket, now, packet_budget, &mut cycle);
            keep_going |= progress.keep_going;
            // A client answered with a Retry returns to this socket's address.
            if progress.retried
                && let Some(until) = inner
                    .retry_token_lifetime()
                    .and_then(|lifetime| now.checked_add(lifetime))
            {
                sockets.hold_route(id, until);
            }
            // Attempts admitted from this socket are queued now that the socket borrow is over:
            // each takes a lease on it, or is ignored when no room is left or the socket failed.
            let failed = progress.error.is_some();
            for (incoming, permit) in progress.admitted {
                let lease = (!failed).then(|| sockets.acquire_attempt(id)).flatten();
                let Some(lease) = lease else {
                    inner.ignore(incoming);
                    continue;
                };
                if let Err(refused) = recv_state.incoming.push_back(QueuedIncoming {
                    incoming,
                    lease,
                    _permit: permit,
                }) {
                    recv_state.dropped_packets += 1;
                    inner.ignore(refused.incoming);
                    retired.extend(sockets.release(refused.lease, now));
                }
            }
            if let Some(error) = progress.error {
                match sockets.receive_failed(id, error, now) {
                    Ok(retired_socket) => retired.extend(retired_socket),
                    Err(fatal) => {
                        outcome = Err(fatal);
                        break;
                    }
                }
            }
        }
        recv_state
            .recv_limiter
            .finish_cycle(cycle, crate::driver::now);
        outcome?;
        Ok(keep_going)
    }
}

impl Drop for State {
    fn drop(&mut self) {
        for queued in self.recv_state.incoming.drain_all() {
            self.inner.ignore(queued.incoming);
        }
        #[cfg(feature = "opentelemetry")]
        if let Some(slot) = &self.metrics {
            slot.hand_in(self.counters());
        }
    }
}

#[cfg(feature = "opentelemetry")]
impl State {
    /// The cumulative counters endpoint metrics export, as [`Endpoint::stats`] reports them.
    fn counters(&self) -> crate::telemetry::EndpointCounters {
        let admission = self.inner.admission_stats();
        crate::telemetry::EndpointCounters {
            accepted: self.stats.accepted_handshakes,
            outgoing: self.stats.outgoing_handshakes,
            refused: self.stats.refused_handshakes,
            ignored: self.stats.ignored_handshakes,
            expired: self.stats.expired_incoming,
            refused_at_limit: admission.refused_at_limit,
            refused_per_source: admission.refused_per_source,
            refused_unvalidated: admission.refused_unvalidated,
            retried: admission.retried,
            received: self.recv_state.received_datagrams,
            dropped: self.recv_state.dropped_packets,
            truncated_entries: self.recv_state.truncated_receive_entries,
            errors_ignored: self.recv_state.ignored_receive_errors,
            responses_queue_full: self.sockets.dropped_responses(),
            responses_send_failed: self.sockets.failed_responses(),
        }
    }
}

#[cfg(feature = "opentelemetry")]
impl crate::telemetry::CountedEndpoint for EndpointInner {
    fn counters(&self) -> crate::telemetry::EndpointCounters {
        self.state.lock().counters()
    }
}

/// Queue a stateless response on `socket`; false when its bounded queue dropped it.
fn respond(transmit: crate::proto::Transmit, response_buffer: &[u8], socket: &mut Socket) -> bool {
    socket.queue_response(transmit, response_buffer)
}

/// An incoming connection attempt awaiting the application, charged to the endpoint budget.
#[derive(Debug)]
pub(crate) struct QueuedIncoming {
    incoming: crate::proto::Incoming,
    /// The attempt's hold on the socket the Initial arrived on; responses and the accepted
    /// connection use that socket.
    lease: Lease,
    _permit: PacketPermit,
}

/// The endpoint's side of one live connection.
#[derive(Debug)]
struct ConnectionChannel {
    /// Received packets, each holding a permit from `budget` and the endpoint budget. Storage
    /// follows use within the connection's datagram limit.
    packets: BoundedSender<QueuedPacket>,
    budget: PacketBudget,
    /// Kept until Drained so control can be applied directly; the connection never
    /// references the endpoint strongly, so there is no cycle.
    inner: Arc<ConnectionInner>,
    /// Closed by a graceful shutdown already, see [`State::close_unleased`].
    shutdown_closed: bool,
}

#[derive(Debug)]
struct ConnectionSet {
    channels: FxHashMap<ConnectionHandle, ConnectionChannel>,
    connection_limits: ReceiveQueueLimits,
    /// Set if the endpoint has been manually closed
    /// The close every connection is given, and whether it leaves its closing period early.
    close: Option<(VarInt, Bytes, bool)>,
    /// What connections created from now on are recorded in.
    #[cfg(feature = "opentelemetry")]
    metrics: Option<crate::telemetry::QuicMetrics>,
}

impl ConnectionSet {
    /// Register a connection. The returned driver must be spawned by the caller after the
    /// endpoint lock is released.
    fn insert(
        &mut self,
        handle: ConnectionHandle,
        conn: crate::proto::Connection,
        socket: Sender,
        link: EndpointLink,
        admission: Option<AdmissionLease>,
    ) -> (Connecting, ConnectionDriver) {
        let (packets, receiver) = bounded_queue(self.connection_limits.datagrams());
        let budget = PacketBudget::new(self.connection_limits);
        let (connecting, driver) = Connecting::new(
            handle,
            conn,
            link,
            receiver,
            socket,
            budget.clone(),
            admission,
        );
        let inner = connecting.inner();
        #[cfg(feature = "opentelemetry")]
        if let Some(metrics) = &self.metrics {
            inner.state.lock().metrics = Some(metrics.connection());
        }
        if let Some((error_code, ref reason, abandon)) = self.close {
            inner.control(Control::Close {
                error_code,
                reason: reason.clone(),
                abandon,
            });
        }
        self.channels.insert(
            handle,
            ConnectionChannel {
                packets,
                budget,
                inner,
                shutdown_closed: false,
            },
        );
        (connecting, driver)
    }

    fn is_empty(&self) -> bool {
        self.channels.is_empty()
    }
}

pin_project! {
    /// Future produced by [`Endpoint::accept`]
    pub struct Accept<'a> {
        endpoint: &'a Endpoint,
        #[pin]
        notify: Notified<'a>,
    }
}

impl Future for Accept<'_> {
    type Output = Option<Incoming>;
    fn poll(self: Pin<&mut Self>, ctx: &mut Context<'_>) -> Poll<Self::Output> {
        let mut this = self.project();
        let mut endpoint = this.endpoint.inner.state.lock();
        if endpoint.driver_lost {
            return Poll::Ready(None);
        }
        if let Some(QueuedIncoming {
            incoming,
            lease,
            _permit,
        }) = endpoint.recv_state.incoming.pop_front()
        {
            // Release the mutex lock on endpoint so cloning it doesn't deadlock
            drop(endpoint);
            // The attempt now belongs to the application; its queue charge ends here, its
            // socket lease travels with the handle.
            drop(_permit);
            let incoming = Incoming::new(incoming, this.endpoint.inner.clone(), lease);
            return Poll::Ready(Some(incoming));
        }
        if endpoint.recv_state.connections.close.is_some() {
            return Poll::Ready(None);
        }
        loop {
            match this.notify.as_mut().poll(ctx) {
                // `state` lock ensures we didn't race with readiness
                Poll::Pending => return Poll::Pending,
                // Spurious wakeup, get a new future
                Poll::Ready(()) => this
                    .notify
                    .set(this.endpoint.inner.shared.incoming.notified()),
            }
        }
    }
}

#[derive(Debug)]
pub(crate) struct EndpointRef(Arc<EndpointInner>);

impl EndpointRef {
    pub(crate) fn new(
        socket: Socket,
        inner: crate::proto::Endpoint,
        ipv6: bool,
        payload_ceiling: u16,
        fixed_peer: bool,
    ) -> Self {
        let packet_budget = PacketBudget::new(inner.config().endpoint_receive_queue);
        let recv_state = RecvState::new(
            socket.capabilities().max_receive_segments.clamp(1, 64),
            &inner,
        );
        Self(Arc::new(EndpointInner {
            shared: Shared {
                incoming: Notify::new(),
                idle: Notify::new(),
                close_leases_released: Notify::new(),
                lifecycle: Lifecycle::default(),
                ref_count: AtomicUsize::new(1),
            },
            state: Mutex::new(State {
                sockets: Sockets::Live(SocketRegistry::new(socket)),
                inner,
                ipv6,
                payload_ceiling,
                fixed_peer,
                driver: None,
                driver_lost: false,
                shutdown: false,
                leased_close_pending: false,
                accepting: 0,
                incoming_timer: DeadlineTimer::default(),
                route_timer: DeadlineTimer::default(),
                recv_state,
                stats: EndpointStats::default(),
                packet_budget,
                #[cfg(feature = "opentelemetry")]
                metrics: None,
                #[cfg(test)]
                hold_route_installs: false,
                #[cfg(test)]
                held_route_installs: Vec::new(),
            }),
        }))
    }
}

impl Clone for EndpointRef {
    fn clone(&self) -> Self {
        self.0.shared.ref_count.fetch_add(1, Ordering::Relaxed);
        Self(self.0.clone())
    }
}

impl Drop for EndpointRef {
    fn drop(&mut self) {
        if self.shared.ref_count.fetch_sub(1, Ordering::Relaxed) > 1 {
            return;
        }

        let endpoint = &mut *self.0.state.lock();
        // If the driver is about to be on its own, ensure it can shut down if the last
        // connection is gone.
        if let Some(task) = endpoint.driver.take() {
            task.wake();
        }
    }
}

impl std::ops::Deref for EndpointRef {
    type Target = EndpointInner;
    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

/// State directly involved in handling incoming packets
struct RecvState {
    /// Attempts awaiting `accept`; storage follows use within the endpoint datagram limit.
    incoming: BoundedDeque<QueuedIncoming>,
    connections: ConnectionSet,
    recv_buf: Box<[u8]>,
    recv_limiter: WorkLimiter,
    received_datagrams: u64,
    truncated_receive_entries: u64,
    /// Ignored connection-reset receive errors (work, not datagrams).
    ignored_receive_errors: u64,
    /// Datagrams refused by a saturated endpoint or connection budget before any engine work.
    dropped_packets: u64,
    /// Tests: a fixed per-poll receive allowance in place of the measured one.
    #[cfg(test)]
    forced_recv_allowance: Option<usize>,
}

impl RecvState {
    fn start_recv_cycle(&self) -> WorkCycle {
        #[cfg(test)]
        if let Some(allowed) = self.forced_recv_allowance {
            return WorkCycle::with_allowance(allowed);
        }
        self.recv_limiter.start_cycle(crate::driver::now)
    }

    fn new(max_receive_segments: usize, endpoint: &crate::proto::Endpoint) -> Self {
        let recv_buf = vec![0; Self::buffer_len(max_receive_segments, endpoint)];
        Self {
            connections: ConnectionSet {
                channels: FxHashMap::default(),
                connection_limits: endpoint.config().connection_receive_queue,
                close: None,
                #[cfg(feature = "opentelemetry")]
                metrics: None,
            },
            incoming: BoundedDeque::new(endpoint.config().endpoint_receive_queue.datagrams()),
            recv_buf: recv_buf.into(),
            recv_limiter: WorkLimiter::new(RECV_TIME_BOUND),
            received_datagrams: 0,
            truncated_receive_entries: 0,
            ignored_receive_errors: 0,
            dropped_packets: 0,
            #[cfg(test)]
            forced_recv_allowance: None,
        }
    }

    fn buffer_len(max_receive_segments: usize, endpoint: &crate::proto::Endpoint) -> usize {
        endpoint
            .config()
            .get_max_udp_payload_size()
            .min(octets::kib_u64(64)) as usize
            * max_receive_segments.clamp(1, MAX_RECEIVE_SEGMENTS)
            * BATCH_SIZE
    }

    /// Receive from one socket until it is pending, the allowance is spent or it fails. Packets
    /// received before a failure are delivered; the failure travels in the result so the
    /// caller queues the attempts admitted first and then judges the socket.
    fn poll_socket(
        &mut self,
        cx: &mut Context,
        endpoint: &mut crate::proto::Endpoint,
        socket: &mut Socket,
        now: Instant,
        budget: &PacketBudget,
        cycle: &mut WorkCycle,
    ) -> PollProgress {
        let capabilities = socket.capabilities();
        if capabilities.min_receive_buffer_size > octets::kib(64) {
            return PollProgress {
                error: Some(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "retained datagram exceeds the UDP receive bound",
                )),
                ..PollProgress::default()
            };
        }
        // Rebinding and retained sockets can have different GRO capabilities.
        // Grow before receiving a group; a buffer sized for the first socket
        // would truncate valid groups from a later one. Keep the allocation for
        // subsequent polls and smaller-capability sockets.
        let required = Self::buffer_len(capabilities.max_receive_segments, endpoint);
        if self.recv_buf.len() < required {
            self.recv_buf = vec![0; required].into_boxed_slice();
        }

        let mut progress = PollProgress::default();
        let mut metas = [DatagramMetadata::empty(); BATCH_SIZE];
        // A peeked datagram can predate the peer's advertised receive limit.
        // Give it one temporary slot for this bounded receive pass, without
        // enlarging every batch slot for the lifetime of the endpoint.
        let mut retained_buf = (capabilities.min_receive_buffer_size
            > self.recv_buf.len() / BATCH_SIZE)
            .then(|| vec![0; capabilities.min_receive_buffer_size]);
        let mut retained_iov = retained_buf
            .as_deref_mut()
            .map(|buf| [IoSliceMut::new(buf)]);
        #[expect(
            clippy::expect_used,
            reason = "recv_buf is allocated as BATCH_SIZE equal chunks, and from_fn consumes exactly that many"
        )]
        let mut iovs: [IoSliceMut; BATCH_SIZE] = {
            let mut bufs = self
                .recv_buf
                .chunks_mut(self.recv_buf.len() / BATCH_SIZE)
                .map(IoSliceMut::new);

            // expect() safe as self.recv_buf is chunked into BATCH_SIZE items
            // and iovs will be of size BATCH_SIZE, thus from_fn is called
            // exactly BATCH_SIZE times.
            std::array::from_fn(|_| bufs.next().expect("BATCH_SIZE elements"))
        };
        let iovs = retained_iov
            .as_mut()
            .map_or(iovs.as_mut_slice(), |iovs| iovs.as_mut_slice());
        let metas = &mut metas[..iovs.len()];
        loop {
            match socket.poll_recv(cx, iovs, metas) {
                Poll::Ready(Ok(msgs)) => {
                    if msgs == 0 || msgs > iovs.len() {
                        progress.error = Some(io::Error::new(
                            io::ErrorKind::InvalidData,
                            "invalid UDP receive entry count",
                        ));
                        return progress;
                    }
                    cycle.record_work(msgs);
                    for (meta, buf) in metas.iter().zip(iovs.iter()).take(msgs) {
                        if meta.truncated || meta.original_len > meta.len {
                            self.truncated_receive_entries += 1;
                            continue;
                        }
                        let Some(data) = buf.get(..meta.len) else {
                            progress.error = Some(io::Error::new(
                                io::ErrorKind::InvalidData,
                                "UDP receive length exceeds buffer",
                            ));
                            return progress;
                        };
                        if data.is_empty() {
                            continue;
                        }
                        for segment in
                            data.chunks(meta.segment_size.map_or(data.len(), |size| size.get()))
                        {
                            self.received_datagrams += 1;
                            // Charge the packet before parsing: a refused packet costs no engine
                            // work. Each admitted packet owns its backing bytes, so retaining one
                            // small packet never retains a whole coalesced receive allocation.
                            let Some(mut permit) = budget.reserve(segment.len()) else {
                                self.dropped_packets += 1;
                                continue;
                            };
                            let buf = BytesMut::from(segment);
                            let mut response_buffer = Vec::new();
                            // The receiving socket identifies the path's local side: its bound
                            // port, and the datagram's destination ip when the platform reports
                            // one (a wildcard bind without that metadata keeps an unspecified ip).
                            let local = SocketAddr::new(
                                SocketAddress::from((meta.local.ip_addr, 0))
                                    .into_canonical_ip_addr()
                                    .ip_addr,
                                socket.local_addr().port(),
                            );
                            match endpoint.handle(
                                now,
                                meta.peer.into_canonical_ip_addr().into(),
                                Some(local),
                                meta.ecn.and_then(proto_ecn),
                                buf,
                                &mut response_buffer,
                            ) {
                                Some(DatagramEvent::NewConnection(incoming)) => {
                                    if self.connections.close.is_some() {
                                        if let Some(transmit) =
                                            endpoint.refuse(incoming, &mut response_buffer)
                                        {
                                            respond(transmit, &response_buffer, socket);
                                        }
                                    } else if permit.widen(INCOMING_OVERHEAD - PACKET_OVERHEAD) {
                                        // Charged until the application takes the attempt; it is
                                        // queued by the caller once this socket is released.
                                        progress.admitted.push((incoming, permit));
                                    } else {
                                        // No room to hold the attempt; the peer retries.
                                        self.dropped_packets += 1;
                                        endpoint.ignore(incoming);
                                    }
                                }
                                Some(DatagramEvent::ConnectionEvent(handle, event)) => {
                                    progress.received_connection_packet = true;
                                    // A connection that already drained has no channel; a
                                    // saturated connection budget drops the packet here.
                                    if let Some(channel) = self.connections.channels.get(&handle) {
                                        match permit.for_connection(&channel.budget) {
                                            Ok(permit) => {
                                                match channel.packets.send(QueuedPacket {
                                                    event,
                                                    _permit: permit,
                                                }) {
                                                    Ok(()) => {}
                                                    // The driver closed its queue on the way
                                                    // out: the packet is for a connection that
                                                    // is gone, not a receive drop.
                                                    Err((_packet, Refusal::Closed)) => {}
                                                    // Storage was refused although the budget
                                                    // accepted the packet: a real receive drop,
                                                    // counted once here and on the connection.
                                                    Err((_packet, Refusal::Full)) => {
                                                        self.dropped_packets += 1;
                                                        channel.budget.count_drop();
                                                    }
                                                }
                                            }
                                            Err(_permit) => self.dropped_packets += 1,
                                        }
                                    }
                                }
                                Some(DatagramEvent::Response(transmit)) => {
                                    respond(transmit, &response_buffer, socket);
                                }
                                Some(DatagramEvent::Retry(transmit)) => {
                                    // Only a Retry that leaves needs its route kept for the return.
                                    progress.retried |= respond(transmit, &response_buffer, socket);
                                }
                                None => {}
                            }
                        }
                    }
                }
                Poll::Pending => return progress,
                // Ignore ECONNRESET as it's undefined in QUIC and may be injected by an
                // attacker. Each ignored error is still work under the shared allowance, so a
                // stream of them cannot hold the pass; it is counted apart from received data.
                Poll::Ready(Err(ref e)) if e.kind() == io::ErrorKind::ConnectionReset => {
                    self.ignored_receive_errors += 1;
                    cycle.record_work(1);
                    if !cycle.allow_work(crate::driver::now) {
                        progress.keep_going = true;
                        return progress;
                    }
                    continue;
                }
                Poll::Ready(Err(ref error))
                    if error.get_ref().is_some_and(|error| {
                        matches!(
                            error.downcast_ref::<DatagramError>(),
                            Some(DatagramError::PayloadTooLarge { .. })
                        )
                    }) =>
                {
                    // A non-retaining socket already discarded the packet. Do
                    // not let network input enlarge the endpoint's allocation.
                    self.dropped_packets += 1;
                    cycle.record_work(1);
                    if !cycle.allow_work(crate::driver::now) {
                        progress.keep_going = true;
                        return progress;
                    }
                    continue;
                }
                Poll::Ready(Err(e)) => {
                    progress.error = Some(e);
                    return progress;
                }
            }
            if !cycle.allow_work(crate::driver::now) {
                progress.keep_going = true;
                return progress;
            }
        }
    }
}

impl fmt::Debug for RecvState {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.debug_struct("RecvState")
            .field("incoming", &self.incoming.len())
            .field("connections", &self.connections)
            // recv_buf too large
            .field("recv_limiter", &self.recv_limiter)
            .finish_non_exhaustive()
    }
}

#[derive(Debug, Default)]
struct PollProgress {
    /// Whether a datagram was routed to an existing connection
    received_connection_packet: bool,
    /// Whether datagram handling was interrupted early by the work limiter for fairness
    keep_going: bool,
    /// Whether an attempt was answered with a Retry, which holds the socket's route.
    retried: bool,
    /// Attempts admitted during this poll, still to be queued with a lease on the socket.
    admitted: Vec<(crate::proto::Incoming, PacketPermit)>,
    /// The receive error that ended this poll, after everything received before it.
    error: Option<io::Error>,
}

#[cfg(all(test, any(feature = "boring", feature = "aws-lc", feature = "ring")))]
impl PollProgress {
    /// Tests: the poll as a result, discarding progress when the socket failed.
    fn into_result(self) -> io::Result<Self> {
        match self.error {
            Some(error) => Err(error),
            None => Ok(self),
        }
    }
}

#[cfg(test)]
#[cfg(any(feature = "boring", feature = "ring", feature = "aws-lc"))]
mod tests;
