use std::{
    cmp,
    collections::VecDeque,
    env,
    io::{self, Write},
    mem,
    net::{Ipv6Addr, SocketAddr, UdpSocket},
    ops::RangeFrom,
    str,
    sync::{Arc, LazyLock},
};

use ahash::{HashMap, HashSet};
use parking_lot::Mutex;
use rama_core::{
    bytes::BytesMut,
    telemetry::tracing::{info_span, trace},
};
use rama_crypto::pki_types::{CertificateDer, PrivateKeyDer};
use rama_quic_proto::{StreamId, Version, packet};
#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
use rama_tls_rustls::dep::rustls::{self, KeyLogFile, client::WebPkiServerVerifier};

#[cfg(not(all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))))]
use super::crypto::boring::{QuicClientConfig, QuicServerConfig};
#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
use super::crypto::rustls::{QuicClientConfig, QuicServerConfig, configured_provider};
use super::*;
use crate::proto::{Duration, Instant, endpoint::Accepted};

pub(super) const DEFAULT_MTU: usize = 1452;

pub(crate) struct Pair {
    pub(crate) server: TestEndpoint,
    pub(super) client: TestEndpoint,
    /// Start time
    epoch: Instant,
    /// Current time
    pub(crate) time: Instant,
    /// Simulates the maximum size allowed for UDP payloads by the link (packets exceeding this size will be dropped)
    pub(super) mtu: usize,
    /// Simulates explicit congestion notification
    pub(super) congestion_experienced: bool,
    // One-way
    pub(super) latency: Duration,
    /// Number of spin bit flips
    pub(super) spins: u64,
    /// Every address the client sent a datagram to, in order.
    /// Every datagram the client put on the wire, as the engine emitted it.
    pub(super) client_sent: Vec<Sent>,
    /// What the server put on the wire, recorded as it is drained. Every drive empties the
    /// queue, so an assertion made on the queue afterwards would inspect nothing.
    pub(super) server_sent: Vec<Sent>,
    last_spin: bool,
}

impl Pair {
    pub(super) fn default_with_deterministic_pns() -> Self {
        let mut cfg = server_config();
        let mut transport = TransportConfig::default();
        transport.deterministic_packet_numbers(true);
        cfg.transport = Arc::new(transport);
        Self::new(Arc::new(EndpointConfig::try_with_rand_key().unwrap()), cfg)
    }

    pub(crate) fn new(endpoint_config: Arc<EndpointConfig>, server_config: ServerConfig) -> Self {
        let server = Endpoint::new(
            endpoint_config.clone(),
            Some(Arc::new(server_config)),
            true,
            None,
        );
        let client = Endpoint::new(endpoint_config, None, true, None);

        Self::new_from_endpoint(client, server)
    }

    pub(crate) fn new_from_endpoint(client: Endpoint, server: Endpoint) -> Self {
        let server_addr = SocketAddr::new(
            Ipv6Addr::LOCALHOST.into(),
            SERVER_PORTS.lock().next().unwrap(),
        );
        let client_addr = SocketAddr::new(
            Ipv6Addr::LOCALHOST.into(),
            CLIENT_PORTS.lock().next().unwrap(),
        );
        let now = Instant::now();
        Self {
            server: TestEndpoint::new(server, server_addr),
            client: TestEndpoint::new(client, client_addr),
            epoch: now,
            time: now,
            mtu: DEFAULT_MTU,
            latency: Duration::ZERO,
            spins: 0,
            client_sent: Vec::new(),
            server_sent: Vec::new(),
            last_spin: false,
            congestion_experienced: false,
        }
    }

    /// Returns whether the connection is not idle
    pub(super) fn step(&mut self) -> bool {
        self.drive_client();
        self.drive_server();
        if self.client.is_idle() && self.server.is_idle() {
            return false;
        }

        let client_t = self.client.next_wakeup();
        let server_t = self.server.next_wakeup();
        match min_opt(client_t, server_t) {
            Some(t) if Some(t) == client_t => {
                if t != self.time {
                    self.time = self.time.max(t);
                    trace!("advancing to {:?} for client", self.time - self.epoch);
                }
                true
            }
            Some(t) if Some(t) == server_t => {
                if t != self.time {
                    self.time = self.time.max(t);
                    trace!("advancing to {:?} for server", self.time - self.epoch);
                }
                true
            }
            Some(_) => {
                panic!("the simulator only advances time to the next client or server timeout")
            }
            None => false,
        }
    }

    /// Advance time until both endpoints are idle. Bounded: a pair that never settles is a stuck
    /// test rather than one that needs longer, and an unbounded loop here would hang instead of
    /// reporting.
    pub(crate) fn drive(&mut self) {
        for _ in 0..Self::DRIVE_STEPS {
            if !self.step() {
                return;
            }
        }
        panic!("the pair never became idle in {} steps", Self::DRIVE_STEPS);
    }

    /// How many steps `drive` allows before it treats the pair as stuck.
    const DRIVE_STEPS: usize = 1_000;

    /// Advance time until both connections are idle, or after 100 steps have been executed
    ///
    /// Returns true if the amount of steps exceeds the bounds, because the connections never became
    /// idle
    pub(super) fn drive_bounded(&mut self) -> bool {
        for _ in 0..100 {
            if !self.step() {
                return false;
            }
        }

        true
    }

    pub(super) fn drive_client(&mut self) {
        let span = info_span!("client");
        let _guard = span.enter();
        self.client.drive(self.time, self.server.addr);
        for (packet, buffer) in self.client.outbound.drain(..) {
            let packet_size = packet_size(&packet, &buffer);
            self.client_sent.push(Sent::record(&packet, &buffer));
            if packet_size > self.mtu {
                info!(packet_size, "dropping packet (max size exceeded)");
                continue;
            }
            if buffer[0] & packet::LONG_HEADER_FORM == 0 {
                let spin = buffer[0] & packet::SPIN_BIT != 0;
                self.spins += (spin == self.last_spin) as u64;
                self.last_spin = spin;
            }
            if let Some(ref socket) = self.client.socket {
                socket.send_to(&buffer, packet.destination).unwrap();
            }
            if self.server.accepts(packet.destination) {
                let ecn = set_congestion_experienced(packet.ecn, self.congestion_experienced);
                let to = (!self.server.hide_local).then_some(packet.destination);
                let mut datagram: BytesMut = buffer.as_ref().into();
                if let Some(tamper) = self.server.tamper_inbound.as_mut() {
                    tamper(&mut datagram);
                }
                self.server.inbound.push_back(Inbound {
                    at: self.time + self.latency,
                    ecn,
                    packet: datagram,
                    from: packet.local,
                    to,
                });
            }
        }
    }

    pub(super) fn drive_server(&mut self) {
        let span = info_span!("server");
        let _guard = span.enter();
        self.server.drive(self.time, self.client.addr);
        for (packet, buffer) in self.server.outbound.drain(..) {
            let packet_size = packet_size(&packet, &buffer);
            self.server_sent.push(Sent::record(&packet, &buffer));
            if packet_size > self.mtu {
                info!(packet_size, "dropping packet (max size exceeded)");
                continue;
            }
            if let Some(ref socket) = self.server.socket {
                socket.send_to(&buffer, packet.destination).unwrap();
            }
            if self.client.accepts(packet.destination) {
                let ecn = set_congestion_experienced(packet.ecn, self.congestion_experienced);
                let to = (!self.client.hide_local).then_some(packet.destination);
                let mut datagram: BytesMut = buffer.as_ref().into();
                if let Some(tamper) = self.client.tamper_inbound.as_mut() {
                    tamper(&mut datagram);
                }
                self.client.inbound.push_back(Inbound {
                    at: self.time + self.latency,
                    ecn,
                    packet: datagram,
                    from: packet.local,
                    to,
                });
            }
        }
    }

    pub(crate) fn connect(&mut self) -> (ConnectionHandle, ConnectionHandle) {
        self.connect_with(client_config())
    }

    pub(crate) fn connect_with(
        &mut self,
        config: ClientConfig,
    ) -> (ConnectionHandle, ConnectionHandle) {
        info!("connecting");
        let client_ch = self.begin_connect(config);
        self.drive();
        let server_ch = self.server.assert_accept();
        self.finish_connect(client_ch, server_ch);
        (client_ch, server_ch)
    }

    /// Deliver a fresh attempt's first Initial to the server from the client's address, as a
    /// client that restarted on the same port sends it. A separate endpoint builds it: one
    /// endpoint cannot hold two zero-CID connections to the same remote.
    pub(super) fn fresh_attempt_from_client_address(&mut self, config: ClientConfig) {
        let mut endpoint = Endpoint::new(
            Arc::new(self.client.endpoint.config().clone()),
            None,
            true,
            None,
        );
        let (_, mut conn) = endpoint
            .connect(self.time, config, self.server.addr, "localhost")
            .unwrap();
        let mut buf = Vec::new();
        let transmit = conn.poll_transmit(self.time, 1, &mut buf).unwrap();
        self.server.inbound.push_back(Inbound {
            at: self.time + self.latency,
            ecn: None,
            packet: buf[..transmit.size].into(),
            from: None,
            to: (!self.server.hide_local).then_some(self.server.addr),
        });
    }

    /// Just start connecting the client
    pub(super) fn begin_connect(&mut self, config: ClientConfig) -> ConnectionHandle {
        let span = info_span!("client");
        let _guard = span.enter();
        let (client_ch, client_conn) = self
            .client
            .connect(self.time, config, self.server.addr, "localhost")
            .unwrap();
        self.client.connections.insert(client_ch, client_conn);
        client_ch
    }

    fn finish_connect(&mut self, client_ch: ConnectionHandle, server_ch: ConnectionHandle) {
        match self.client_conn_mut(client_ch).poll() {
            Some(Event::HandshakeDataReady) => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`"
            ),
        }
        match self.client_conn_mut(client_ch).poll() {
            Some(Event::Connected) => {}
            other => {
                panic!("assertion failed: `{other:?}` does not match `Some(Event::Connected)`")
            }
        }
        match self.server_conn_mut(server_ch).poll() {
            Some(Event::HandshakeDataReady) => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(Event::HandshakeDataReady)`"
            ),
        }
        match self.server_conn_mut(server_ch).poll() {
            Some(Event::HandshakeConfirmed) => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(Event::HandshakeConfirmed)`"
            ),
        }
        match self.server_conn_mut(server_ch).poll() {
            Some(Event::Connected) => {}
            other => {
                panic!("assertion failed: `{other:?}` does not match `Some(Event::Connected)`")
            }
        }
        match self.client_conn_mut(client_ch).poll() {
            Some(Event::HandshakeConfirmed) => {}
            other => panic!(
                "assertion failed: `{other:?}` does not match `Some(Event::HandshakeConfirmed)`"
            ),
        }
    }

    pub(crate) fn client_conn_mut(&mut self, ch: ConnectionHandle) -> &mut Connection {
        self.client.connections.get_mut(&ch).unwrap()
    }

    pub(super) fn client_force_key_update(&mut self, ch: ConnectionHandle) -> bool {
        let now = self.time;
        self.client_conn_mut(ch).force_key_update(now)
    }

    pub(super) fn client_migrate_local_address(&mut self, ch: ConnectionHandle) -> bool {
        let now = self.time;
        self.client_conn_mut(ch).migrate_local_address(now)
    }

    pub(super) fn client_streams(&mut self, ch: ConnectionHandle) -> Streams<'_> {
        self.client_conn_mut(ch).streams()
    }

    pub(super) fn client_send(&mut self, ch: ConnectionHandle, s: StreamId) -> SendStream<'_> {
        self.client_conn_mut(ch).send_stream(s)
    }

    pub(super) fn client_recv(&mut self, ch: ConnectionHandle, s: StreamId) -> RecvStream<'_> {
        self.client_conn_mut(ch).recv_stream(s)
    }

    pub(super) fn client_datagrams(&mut self, ch: ConnectionHandle) -> Datagrams<'_> {
        self.client_conn_mut(ch).datagrams()
    }

    pub(crate) fn server_conn_mut(&mut self, ch: ConnectionHandle) -> &mut Connection {
        self.server.connections.get_mut(&ch).unwrap()
    }

    pub(super) fn server_streams(&mut self, ch: ConnectionHandle) -> Streams<'_> {
        self.server_conn_mut(ch).streams()
    }

    pub(super) fn server_send(&mut self, ch: ConnectionHandle, s: StreamId) -> SendStream<'_> {
        self.server_conn_mut(ch).send_stream(s)
    }

    pub(super) fn server_recv(&mut self, ch: ConnectionHandle, s: StreamId) -> RecvStream<'_> {
        self.server_conn_mut(ch).recv_stream(s)
    }

    pub(super) fn server_datagrams(&mut self, ch: ConnectionHandle) -> Datagrams<'_> {
        self.server_conn_mut(ch).datagrams()
    }
}

impl Default for Pair {
    fn default() -> Self {
        Self::new(
            Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
            server_config(),
        )
    }
}

/// One datagram an endpoint put on the wire: the local address it belongs to, where it went, and
/// the sequence number of the destination connection ID it carried.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Sent {
    pub(super) local: Option<SocketAddr>,
    pub(super) to: SocketAddr,
    pub(super) cid: Option<u64>,
    /// The datagram's size on the wire, for a case counting bytes against a limit.
    pub(super) bytes: usize,
    /// The first byte of the datagram's first packet: header form, fixed bit and type bits.
    pub(super) first_byte: u8,
    /// The version of the first packet, when it has a long header.
    pub(super) version: Option<Version>,
    /// Every packet in the datagram, coalesced ones included: first byte and version.
    pub(super) packets: Vec<SentPacket>,
}

/// One packet of a sent datagram, as an observer without keys sees it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct SentPacket {
    pub(super) first_byte: u8,
    pub(super) version: Option<Version>,
}

impl SentPacket {
    /// The long header kind, read with the type table of the packet's own version.
    pub(super) fn long_kind(&self) -> Option<rama_quic_proto::version::LongKind> {
        Some(self.version?.wire()?.long_kind(self.first_byte))
    }
}

impl Sent {
    fn record(packet: &Transmit, buffer: &Bytes) -> Self {
        let packets = walk_packets(buffer);
        Self {
            local: packet.local,
            to: packet.destination,
            cid: packet.cid_used,
            bytes: packet_size(packet, buffer),
            first_byte: buffer[0],
            version: packets.first().and_then(|packet| packet.version),
            packets,
        }
    }
}

/// Split a datagram into its packets using only the invariant long-header layout and the
/// Length field (RFC 8999 §5.1, RFC 9000 §17.2); a short header runs to the end.
fn walk_packets(buffer: &[u8]) -> Vec<SentPacket> {
    fn varint(buf: &[u8], at: &mut usize) -> Option<u64> {
        let first = *buf.get(*at)?;
        let len = 1usize << (first >> 6);
        let bytes = buf.get(*at..*at + len)?;
        *at += len;
        let mut value = u64::from(first & 0x3f);
        for byte in &bytes[1..] {
            value = value << 8 | u64::from(*byte);
        }
        Some(value)
    }
    let mut packets = Vec::new();
    let mut at = 0;
    while at < buffer.len() {
        let first_byte = buffer[at];
        if first_byte & packet::LONG_HEADER_FORM == 0 {
            packets.push(SentPacket {
                first_byte,
                version: None,
            });
            break;
        }
        let Some(bytes) = buffer.get(at + 1..at + 5) else {
            break;
        };
        let version = Version::from_be_bytes(bytes.try_into().unwrap());
        packets.push(SentPacket {
            first_byte,
            version: Some(version),
        });
        let Some(wire) = version.wire() else {
            break;
        };
        let mut cursor = at + 5;
        for _ in 0..2 {
            let Some(len) = buffer.get(cursor) else {
                return packets;
            };
            cursor += 1 + usize::from(*len);
        }
        match wire.long_kind(first_byte) {
            rama_quic_proto::version::LongKind::Retry => break,
            rama_quic_proto::version::LongKind::Initial => {
                let Some(token_len) = varint(buffer, &mut cursor) else {
                    break;
                };
                cursor += token_len as usize;
            }
            _ => {}
        }
        let Some(length) = varint(buffer, &mut cursor) else {
            break;
        };
        at = cursor + length as usize;
    }
    packets
}

pub(crate) struct TestEndpoint {
    pub(super) endpoint: Endpoint,
    pub(crate) addr: SocketAddr,
    socket: Option<UdpSocket>,
    /// Each connection's own next deadline. One shared cell would let one connection's timer fire
    /// for another, and would overwrite one deadline with another's.
    timeouts: HashMap<ConnectionHandle, Instant>,
    pub(super) outbound: VecDeque<(Transmit, Bytes)>,
    delayed: VecDeque<(Transmit, Bytes)>,
    pub(super) inbound: VecDeque<Inbound>,
    /// A second address this endpoint receives at, such as a server's preferred one.
    pub(crate) alt_addr: Option<SocketAddr>,
    /// While set, datagrams reach this endpoint without local provenance, as they do on a host
    /// whose socket cannot report which address received them.
    pub(super) hide_local: bool,
    accepted: Option<Result<ConnectionHandle, ConnectionError>>,
    pub(super) connections: HashMap<ConnectionHandle, Connection>,
    conn_events: HashMap<ConnectionHandle, VecDeque<ConnectionEvent>>,
    /// Per connection, the drives that ended with one of its datagrams waiting for a route and
    /// nothing left to install, since that connection last sent. A route that is never installed
    /// would otherwise be invisible. The count belongs to the connection: one connection's
    /// progress must not clear another's stall.
    waiting_drives: HashMap<ConnectionHandle, u32>,
    /// A datagram that was built but may not be sent yet because the endpoint has not confirmed
    /// the route its identifier needs. It is kept exactly as it is, as the driver keeps its
    /// buffered transmit, so nothing is rebuilt and no protocol counter advances twice.
    pending_transmit: HashMap<ConnectionHandle, (Transmit, Vec<u8>)>,
    /// Retries this endpoint has sent, so a test can tell a token that was read from one that
    /// was not.
    pub(super) retries_sent: u32,
    pub(super) captured_packets: Vec<Vec<u8>>,
    pub(super) capture_inbound_packets: bool,
    pub(super) handle_incoming: Box<dyn FnMut(&Incoming) -> IncomingConnectionBehavior>,
    /// While set, every datagram arriving at this endpoint is handed to this hook first, which
    /// may rewrite it in place: a test's stand-in for an on-path attacker or a lossy link.
    pub(super) tamper_inbound: Option<Box<dyn FnMut(&mut BytesMut)>>,
    pub(super) waiting_incoming: Vec<Incoming>,
    /// While set, connection IDs the endpoint issues are kept from the connection (the peer sees
    /// no NEW_CONNECTION_ID) until `release_held_identifiers`: a peer slow to issue.
    pub(super) hold_identifiers: bool,
    held_identifiers: Vec<(ConnectionHandle, ConnectionEvent)>,
    /// While a connection's handle is listed here, the endpoint is not asked to install the
    /// route a stateless reset for one of its identifiers would arrive by, so a datagram of that
    /// connection which needs the route keeps waiting instead of leaving. Naming the connection
    /// is what lets one connection wait while another on the same endpoint keeps sending.
    pub(super) hold_route_installs: Vec<ConnectionHandle>,
    held_route_installs: Vec<(ConnectionHandle, EndpointEvent)>,
}

/// A datagram waiting for an endpoint's receive path.
#[derive(Debug, Clone)]
pub(super) struct Inbound {
    pub(super) at: Instant,
    pub(super) ecn: Option<EcnCodepoint>,
    pub(super) packet: BytesMut,
    /// Source address to hand the endpoint; the peer's primary address when unset.
    pub(super) from: Option<SocketAddr>,
    /// The local address the datagram was addressed to.
    pub(super) to: Option<SocketAddr>,
}

impl Inbound {
    /// A datagram from the peer's primary address, addressed to this endpoint's own.
    pub(super) fn plain(at: Instant, ecn: Option<EcnCodepoint>, packet: BytesMut) -> Self {
        Self {
            at,
            ecn,
            packet,
            from: None,
            to: None,
        }
    }
}

#[derive(Debug, Copy, Clone)]
pub(super) enum IncomingConnectionBehavior {
    Accept,
    Reject,
    Retry,
    Wait,
}

pub(super) fn validate_incoming(incoming: &Incoming) -> IncomingConnectionBehavior {
    if incoming.remote_address_validated() {
        IncomingConnectionBehavior::Accept
    } else {
        IncomingConnectionBehavior::Retry
    }
}

/// Store a connection's next deadline, or clear it when it has none. Every live connection has to
/// pass through this on every drive, including one whose send is waiting for a route.
fn refresh_timeout(
    timeouts: &mut HashMap<ConnectionHandle, Instant>,
    ch: ConnectionHandle,
    conn: &Connection,
) {
    match conn.poll_timeout() {
        Some(at) => {
            timeouts.insert(ch, at);
        }
        None => {
            timeouts.remove(&ch);
        }
    }
}

impl TestEndpoint {
    fn new(endpoint: Endpoint, addr: SocketAddr) -> Self {
        let socket = if env::var_os("SSLKEYLOGFILE").is_some() {
            let socket = UdpSocket::bind(addr).expect("failed to bind UDP socket");
            socket
                .set_read_timeout(Some(Duration::from_millis(10)))
                .unwrap();
            Some(socket)
        } else {
            None
        };
        Self {
            endpoint,
            addr,
            socket,
            timeouts: HashMap::default(),
            outbound: VecDeque::new(),
            delayed: VecDeque::new(),
            inbound: VecDeque::new(),
            alt_addr: None,
            hide_local: false,
            accepted: None,
            connections: HashMap::default(),
            conn_events: HashMap::default(),
            pending_transmit: HashMap::default(),
            waiting_drives: HashMap::default(),
            retries_sent: 0,
            captured_packets: Vec::new(),
            capture_inbound_packets: false,
            handle_incoming: Box::new(|_| IncomingConnectionBehavior::Accept),
            tamper_inbound: None,
            waiting_incoming: Vec::new(),
            hold_identifiers: false,
            held_identifiers: Vec::new(),
            hold_route_installs: Vec::new(),
            held_route_installs: Vec::new(),
        }
    }

    pub(super) fn drive(&mut self, now: Instant, remote: SocketAddr) {
        self.drive_incoming(now, remote);
        self.drive_outgoing(now);
    }

    /// Whether a datagram addressed to `destination` reaches this endpoint.
    pub(super) fn accepts(&self, destination: SocketAddr) -> bool {
        self.addr == destination || self.alt_addr == Some(destination)
    }

    pub(super) fn drive_incoming(&mut self, now: Instant, remote: SocketAddr) {
        if let Some(ref socket) = self.socket {
            loop {
                let mut buf = [0; 8192];
                if socket.recv_from(&mut buf).is_err() {
                    break;
                }
            }
        }
        let buffer_size = self.endpoint.config().get_max_udp_payload_size() as usize;
        let mut buf = Vec::with_capacity(buffer_size);

        while self.inbound.front().is_some_and(|x| x.at <= now) {
            let Some(datagram) = self.inbound.pop_front() else {
                break;
            };
            let source = datagram.from.unwrap_or(remote);
            if let Some(event) = self.endpoint.handle(
                datagram.at,
                source,
                datagram.to,
                datagram.ecn,
                datagram.packet,
                &mut buf,
            ) {
                match event {
                    DatagramEvent::NewConnection(incoming) => {
                        match (self.handle_incoming)(&incoming) {
                            IncomingConnectionBehavior::Accept => {
                                let _accepted = self.try_accept(incoming, now);
                            }
                            IncomingConnectionBehavior::Reject => {
                                self.reject(incoming);
                            }
                            IncomingConnectionBehavior::Retry => {
                                self.retry(incoming);
                            }
                            IncomingConnectionBehavior::Wait => {
                                self.waiting_incoming.push(incoming);
                            }
                        }
                    }
                    DatagramEvent::ConnectionEvent(ch, event) => {
                        if self.capture_inbound_packets {
                            let packet = self.connections[&ch].decode_packet(&event);
                            self.captured_packets.extend(packet);
                        }

                        self.conn_events.entry(ch).or_default().push_back(event);
                    }
                    DatagramEvent::Response(transmit) => {
                        let size = transmit.size;
                        self.outbound.extend(split_transmit(transmit, &buf[..size]));
                        buf.clear();
                    }
                    DatagramEvent::Retry(transmit) => {
                        self.retries_sent += 1;
                        let size = transmit.size;
                        self.outbound.extend(split_transmit(transmit, &buf[..size]));
                        buf.clear();
                    }
                }
            }
        }
    }

    /// How many drives in a row a datagram may wait for a route that nothing is installing.
    const WAITING_DRIVES: u32 = 8;

    pub(super) fn drive_outgoing(&mut self, now: Instant) {
        let buffer_size = self.endpoint.config().get_max_udp_payload_size() as usize;
        let mut buf = Vec::with_capacity(buffer_size);

        loop {
            // Arrivals and timers, then the wire, then everything the connections asked the
            // endpoint for — in the order they asked. Nothing is applied early: a datagram that
            // needs a route is *kept*, so the next pass sends it once the route is in, and the
            // release of a displaced route can never be reordered behind the installation that
            // displaced it.
            let mut endpoint_events: Vec<(ConnectionHandle, EndpointEvent)> = vec![];
            self.timeouts
                .retain(|ch, _| self.connections.contains_key(ch));
            self.waiting_drives
                .retain(|ch, _| self.connections.contains_key(ch));
            for (ch, conn) in self.connections.iter_mut() {
                if self.timeouts.get(ch).is_some_and(|&at| at <= now) {
                    self.timeouts.remove(ch);
                    conn.handle_timeout(now);
                }
                // Only this connection's events: draining every handle's here would hand one
                // connection another's packets.
                if let Some(events) = self.conn_events.get_mut(ch) {
                    for event in events.drain(..) {
                        conn.handle_event(event);
                    }
                }
                while let Some(event) = conn.poll_endpoint_events() {
                    endpoint_events.push((*ch, event));
                }
            }
            // Now the wire.
            let mut waiting: Vec<ConnectionHandle> = vec![];
            for (ch, conn) in self.connections.iter_mut() {
                // Whatever was waiting for a route goes first, and is offered as it was built.
                if let Some((transmit, bytes)) = self.pending_transmit.remove(ch) {
                    match transmit.cid_used.map_or(SendPermit::Sendable, |seq| {
                        conn.may_send_cid(seq, transmit.destination)
                    }) {
                        SendPermit::Sendable => {
                            let (cid_used, destination) = (transmit.cid_used, transmit.destination);
                            self.outbound.extend(split_transmit(transmit, &bytes));
                            // The datagram that was held has left, which is this connection's
                            // progress: a datagram that waits after it starts its own count.
                            self.waiting_drives.remove(ch);
                            if let Some(seq) = cid_used {
                                conn.cid_sent(seq, destination);
                            }
                        }
                        SendPermit::AwaitingInstallation => {
                            self.pending_transmit.insert(*ch, (transmit, bytes));
                            waiting.push(*ch);
                            // This connection's deadline still has to be refreshed: the expired
                            // one was consumed above, and arrivals may have set a new one.
                            refresh_timeout(&mut self.timeouts, *ch, conn);
                            continue;
                        }
                        // Never sendable again: only this datagram is given up.
                        SendPermit::Obsolete => {}
                    }
                }
                let mut transmits = 0;
                while let Some(transmit) = conn.poll_transmit(now, MAX_DATAGRAMS, &mut buf) {
                    transmits += 1;
                    assert!(
                        transmits < 100_000,
                        "a connection produced packets without end: something announces frames \
                         to send that it never writes"
                    );
                    let size = transmit.size;
                    let cid_used = transmit.cid_used;
                    let destination = transmit.destination;
                    // The driver holds a datagram whose route the endpoint has not confirmed and
                    // drops one whose identifier may never be sent again (RFC 9000 §9.5); so does
                    // this. A held one is kept as it is and offered again once the route is in.
                    match cid_used.map_or(SendPermit::Sendable, |seq| {
                        conn.may_send_cid(seq, destination)
                    }) {
                        SendPermit::Sendable => {}
                        SendPermit::AwaitingInstallation => {
                            self.pending_transmit
                                .insert(*ch, (transmit, buf[..size].to_vec()));
                            buf.clear();
                            waiting.push(*ch);
                            break;
                        }
                        SendPermit::Obsolete => {
                            buf.clear();
                            continue;
                        }
                    }
                    self.outbound.extend(split_transmit(transmit, &buf[..size]));
                    buf.clear();
                    // Something left for this connection, so it is not stuck: this is the
                    // progress its waiting count below is measured against.
                    self.waiting_drives.remove(ch);
                    // The datagram is on its way, which is the boundary the driver reports.
                    if let Some(seq) = cid_used {
                        conn.cid_sent(seq, destination);
                    }
                }
                refresh_timeout(&mut self.timeouts, *ch, conn);
                while let Some(event) = conn.poll_endpoint_events() {
                    endpoint_events.push((*ch, event));
                }
            }
            let more = !endpoint_events.is_empty();
            self.apply_endpoint_events(endpoint_events);
            if !more {
                // Nothing was asked of the endpoint, so nothing can change for a datagram that is
                // waiting: another pass would only rebuild the same state. A held datagram stays
                // held for the next drive, which is what the driver does when it returns to the
                // scheduler. How long it may stay held is counted across drives, below.
                self.waiting_drives.retain(|ch, _| waiting.contains(ch));
                for ch in &waiting {
                    let drives = self.waiting_drives.entry(*ch).or_default();
                    *drives += 1;
                    assert!(
                        *drives <= Self::WAITING_DRIVES,
                        "a datagram of {ch:?} has waited for a route across {drives} drives with \
                         nothing left to install: its installation was refused or never asked for"
                    );
                }
                break;
            }
        }
    }

    /// Hand each event to the endpoint and give the connection back whatever it answers.
    fn apply_endpoint_events(&mut self, events: Vec<(ConnectionHandle, EndpointEvent)>) {
        for (ch, event) in events {
            if self.hold_route_installs.contains(&ch) && event.is_reset_route() {
                self.held_route_installs.push((ch, event));
                continue;
            }
            if let Some(event) = self.handle_event(ch, event) {
                // Only identifier issuance is held by that seam, however it was asked for; a
                // route acknowledgement withheld here would stop the connection sending at all.
                if self.hold_identifiers && event.is_new_identifiers() {
                    self.held_identifiers.push((ch, event));
                } else if let Some(conn) = self.connections.get_mut(&ch) {
                    conn.handle_event(event);
                }
            }
        }
    }

    /// Tests: the deadline stored for `ch`, if it has one.
    pub(super) fn deadline_for(&self, ch: ConnectionHandle) -> Option<Instant> {
        self.timeouts.get(&ch).copied()
    }

    /// Hand the connection the identifiers held back so far; the next drive sends them.
    pub(super) fn release_held_identifiers(&mut self) {
        self.hold_identifiers = false;
        for (ch, event) in std::mem::take(&mut self.held_identifiers) {
            if let Some(conn) = self.connections.get_mut(&ch) {
                conn.handle_event(event);
            }
        }
    }

    /// Hand the endpoint the route installations put aside, and give each connection the
    /// acknowledgement the endpoint answers with.
    pub(super) fn release_route_installs(&mut self) {
        self.hold_route_installs.clear();
        for (ch, event) in std::mem::take(&mut self.held_route_installs) {
            if let Some(event) = self.handle_event(ch, event)
                && let Some(conn) = self.connections.get_mut(&ch)
            {
                conn.handle_event(event);
            }
        }
    }

    /// Tests: how many drives in a row ended with a datagram of `ch` waiting for a route.
    pub(super) fn waiting_drives_for(&self, ch: ConnectionHandle) -> u32 {
        self.waiting_drives.get(&ch).copied().unwrap_or(0)
    }

    /// Tests: whether a datagram of `ch` is being kept until its route is installed.
    pub(super) fn awaiting_route(&self, ch: ConnectionHandle) -> bool {
        self.pending_transmit.contains_key(&ch)
    }

    pub(super) fn next_wakeup(&self) -> Option<Instant> {
        let next_inbound = self.inbound.front().map(|x| x.at);
        // A connection removed from the map takes its deadline with it; a stale one would keep
        // being reported as the next wakeup for ever.
        let next_timeout = self
            .timeouts
            .iter()
            .filter(|(ch, _)| self.connections.contains_key(ch))
            .map(|(_, at)| *at)
            .min();
        min_opt(next_timeout, next_inbound)
    }

    /// Idle: no datagram waits to be received and every connection is idle.
    pub(super) fn is_idle(&self) -> bool {
        self.inbound.is_empty() && self.connections.values().all(|x| x.is_idle())
    }

    pub(super) fn delay_outbound(&mut self) {
        assert!(self.delayed.is_empty());
        mem::swap(&mut self.delayed, &mut self.outbound);
    }

    /// Tests: how many datagrams are held back.
    pub(super) fn delayed_len(&self) -> usize {
        self.delayed.len()
    }

    pub(super) fn finish_delay(&mut self) {
        self.outbound.extend(self.delayed.drain(..));
    }

    pub(super) fn try_accept(
        &mut self,
        incoming: Incoming,
        now: Instant,
    ) -> Result<ConnectionHandle, ConnectionError> {
        let mut buf = Vec::new();
        let outcome = self.endpoint.accept(incoming, now, &mut buf, None);
        self.settle(outcome, &buf)
    }

    /// Complete an accept begun with `start_accept`, as `try_accept` does in one go.
    pub(super) fn finish(
        &mut self,
        accepted: Accepted,
    ) -> Result<ConnectionHandle, ConnectionError> {
        let mut buf = Vec::new();
        let outcome = self
            .endpoint
            .finish_accept(accepted, &mut buf)
            .map(|registered| registered.replayed());
        self.settle(outcome, &buf)
    }

    fn settle(
        &mut self,
        outcome: Result<(ConnectionHandle, Connection, AdmissionLease), AcceptError>,
        buf: &[u8],
    ) -> Result<ConnectionHandle, ConnectionError> {
        match outcome {
            Ok((ch, conn, _admission)) => {
                self.connections.insert(ch, conn);
                self.accepted = Some(Ok(ch));
                Ok(ch)
            }
            Err(error) => {
                if let Some(transmit) = error.response {
                    let size = transmit.size;
                    self.outbound.extend(split_transmit(transmit, &buf[..size]));
                }
                self.accepted = Some(Err(error.cause.clone()));
                Err(error.cause)
            }
        }
    }

    pub(super) fn retry(&mut self, incoming: Incoming) {
        self.retries_sent += 1;
        let mut buf = Vec::new();
        let transmit = self.endpoint.retry(incoming, &mut buf).unwrap();
        let size = transmit.size;
        self.outbound.extend(split_transmit(transmit, &buf[..size]));
    }

    pub(super) fn reject(&mut self, incoming: Incoming) {
        let mut buf = Vec::new();
        let transmit = self.endpoint.refuse(incoming, &mut buf).unwrap();
        let size = transmit.size;
        self.outbound.extend(split_transmit(transmit, &buf[..size]));
    }

    pub(super) fn assert_accept(&mut self) -> ConnectionHandle {
        self.accepted
            .take()
            .expect("server didn't try connecting")
            .expect("server experienced error connecting")
    }

    pub(super) fn assert_accept_error(&mut self) -> ConnectionError {
        self.accepted
            .take()
            .expect("server didn't try connecting")
            .expect_err("server did unexpectedly connect without error")
    }

    pub(super) fn assert_no_accept(&self) {
        assert!(self.accepted.is_none(), "server did unexpectedly connect")
    }
}

impl ::std::ops::Deref for TestEndpoint {
    type Target = Endpoint;
    fn deref(&self) -> &Endpoint {
        &self.endpoint
    }
}

impl ::std::ops::DerefMut for TestEndpoint {
    fn deref_mut(&mut self) -> &mut Endpoint {
        &mut self.endpoint
    }
}

pub(super) fn subscribe() -> rama_core::telemetry::tracing::subscriber::DefaultGuard {
    let builder = tracing_subscriber::FmtSubscriber::builder()
        .with_max_level(rama_core::telemetry::tracing::Level::TRACE)
        .with_writer(|| TestWriter);
    // tracing uses std::time to trace time, which panics in wasm.
    #[cfg(all(target_family = "wasm", target_os = "unknown"))]
    let builder = builder.without_time();
    rama_core::telemetry::tracing::subscriber::set_default(builder.finish())
}

struct TestWriter;

impl Write for TestWriter {
    #[expect(clippy::print_stdout, reason = "test log output")]
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        print!(
            "{}",
            str::from_utf8(buf).expect("tried to log invalid UTF-8")
        );
        Ok(buf.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        io::stdout().flush()
    }
}

pub(crate) fn server_config() -> ServerConfig {
    ServerConfig::with_crypto(Arc::new(server_crypto()))
}

pub(super) fn server_config_with_cert(
    cert: CertificateDer<'static>,
    key: PrivateKeyDer<'static>,
) -> ServerConfig {
    let mut config = ServerConfig::with_crypto(Arc::new(server_crypto_with_cert(cert, key)));
    config
        .validation_token
        .set_sent(2)
        .set_log(Arc::new(SimpleTokenLog::default()));
    config
}

pub(super) fn server_crypto() -> QuicServerConfig {
    server_crypto_inner(None, None)
}

pub(super) fn server_crypto_with_alpn(alpn: Vec<Vec<u8>>) -> QuicServerConfig {
    server_crypto_inner(None, Some(alpn))
}

pub(super) fn server_crypto_with_cert(
    cert: CertificateDer<'static>,
    key: PrivateKeyDer<'static>,
) -> QuicServerConfig {
    server_crypto_inner(Some((cert, key)), None)
}

#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
fn server_crypto_inner(
    identity: Option<(CertificateDer<'static>, PrivateKeyDer<'static>)>,
    alpn: Option<Vec<Vec<u8>>>,
) -> QuicServerConfig {
    server_crypto_with_provider(test_provider(), identity, alpn)
}

#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
pub(super) fn server_crypto_with_provider(
    provider: Arc<rustls::crypto::CryptoProvider>,
    identity: Option<(CertificateDer<'static>, PrivateKeyDer<'static>)>,
    alpn: Option<Vec<Vec<u8>>>,
) -> QuicServerConfig {
    let (cert, key) = identity.unwrap_or_else(|| {
        (
            CERTIFIED_KEY.cert_chain[0].clone(),
            CERTIFIED_KEY.private_key.clone_key(),
        )
    });

    let mut config = rustls::ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(vec![cert], key)
        .unwrap();
    config.max_early_data_size = u32::MAX;
    if let Some(alpn) = alpn {
        config.alpn_protocols = alpn;
    }

    config.try_into().unwrap()
}

/// The configured provider restricted to a classic X25519 key exchange
///
/// The simulator tests assert exact packet/event sequences, which depend on handshake flight
/// sizes; post-quantum key shares (preferred by the `aws-lc` provider) roughly double the
/// ClientHello and would make those sequences provider dependent.
#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
pub(super) fn test_provider() -> Arc<rustls::crypto::CryptoProvider> {
    let mut provider = Arc::unwrap_or_clone(configured_provider());
    #[cfg(all(feature = "aws-lc", not(feature = "ring")))]
    let x25519 = rustls::crypto::aws_lc_rs::kx_group::X25519;
    #[cfg(feature = "ring")]
    let x25519 = rustls::crypto::ring::kx_group::X25519;
    provider.kx_groups = vec![x25519];
    Arc::new(provider)
}

pub(crate) fn client_config() -> ClientConfig {
    ClientConfig::new(Arc::new(client_crypto()))
}

/// A client that pings after `interval` of quiet, which gives its connection a deadline of its own.
pub(super) fn client_config_with_keep_alive(interval: Duration) -> ClientConfig {
    let mut cfg = ClientConfig::new(Arc::new(client_crypto()));
    let mut transport = TransportConfig::default();
    transport.set_keep_alive_interval(interval);
    cfg.transport = Arc::new(transport);
    cfg
}

pub(super) fn client_config_with_deterministic_pns() -> ClientConfig {
    let mut cfg = ClientConfig::new(Arc::new(client_crypto()));
    let mut transport = TransportConfig::default();
    transport.deterministic_packet_numbers(true);
    cfg.transport = Arc::new(transport);
    cfg
}

pub(super) fn client_config_with_certs(certs: Vec<CertificateDer<'static>>) -> ClientConfig {
    ClientConfig::new(Arc::new(client_crypto_inner(Some(certs), None)))
}

pub(super) fn client_crypto() -> QuicClientConfig {
    client_crypto_inner(None, None)
}

pub(super) fn client_crypto_with_alpn(protocols: Vec<Vec<u8>>) -> QuicClientConfig {
    client_crypto_inner(None, Some(protocols))
}

#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
fn client_crypto_inner(
    certs: Option<Vec<CertificateDer<'static>>>,
    alpn: Option<Vec<Vec<u8>>>,
) -> QuicClientConfig {
    client_crypto_with_provider(test_provider(), certs, alpn)
}

#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
pub(super) fn client_crypto_with_provider(
    provider: Arc<rustls::crypto::CryptoProvider>,
    certs: Option<Vec<CertificateDer<'static>>>,
    alpn: Option<Vec<Vec<u8>>>,
) -> QuicClientConfig {
    let mut roots = rustls::RootCertStore::empty();
    for cert in certs.unwrap_or_else(|| vec![CERTIFIED_KEY.cert_chain[0].clone()]) {
        roots.add(cert).unwrap();
    }

    let verifier = WebPkiServerVerifier::builder_with_provider(Arc::new(roots), provider.clone())
        .build()
        .unwrap();
    let mut inner = rustls::ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .unwrap()
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_no_client_auth();
    inner.enable_early_data = true;
    inner.key_log = Arc::new(KeyLogFile::new());
    if let Some(alpn) = alpn {
        inner.alpn_protocols = alpn;
    }

    inner.try_into().unwrap()
}

pub(super) fn min_opt<T: Ord>(x: Option<T>, y: Option<T>) -> Option<T> {
    match (x, y) {
        (Some(x), Some(y)) => Some(cmp::min(x, y)),
        (Some(x), _) => Some(x),
        (_, Some(y)) => Some(y),
        _ => None,
    }
}

/// The maximum of datagrams TestEndpoint will produce via `poll_transmit`
const MAX_DATAGRAMS: usize = 10;

fn split_transmit(transmit: Transmit, buffer: &[u8]) -> Vec<(Transmit, Bytes)> {
    let mut buffer = Bytes::copy_from_slice(buffer);
    let Some(segment_size) = transmit.segment_size else {
        return vec![(transmit, buffer)];
    };

    let mut transmits = Vec::new();
    while !buffer.is_empty() {
        let end = segment_size.get().min(buffer.len());

        let contents = buffer.split_to(end);
        transmits.push((
            Transmit {
                destination: transmit.destination,
                size: contents.len(),
                ecn: transmit.ecn,
                segment_size: None,
                local: transmit.local,
                cid_used: transmit.cid_used,
            },
            contents,
        ));
    }

    transmits
}

fn packet_size(transmit: &Transmit, buffer: &Bytes) -> usize {
    if transmit.segment_size.is_some() {
        panic!("This transmit is meant to be split into multiple packets!");
    }

    buffer.len()
}

fn set_congestion_experienced(
    x: Option<EcnCodepoint>,
    congestion_experienced: bool,
) -> Option<EcnCodepoint> {
    x.map(|codepoint| match congestion_experienced {
        true => EcnCodepoint::Ce,
        false => codepoint,
    })
}

#[derive(Default)]
struct SimpleTokenLog(Mutex<HashSet<u128>>);

impl TokenLog for SimpleTokenLog {
    fn check_and_insert(
        &self,
        nonce: u128,
        _issued: SystemTime,
        _lifetime: Duration,
    ) -> Result<(), TokenReuseError> {
        if self.0.lock().insert(nonce) {
            Ok(())
        } else {
            Err(TokenReuseError::new())
        }
    }
}

pub(crate) static SERVER_PORTS: LazyLock<Mutex<RangeFrom<u16>>> =
    LazyLock::new(|| Mutex::new(4433..));
pub(crate) static CLIENT_PORTS: LazyLock<Mutex<RangeFrom<u16>>> =
    LazyLock::new(|| Mutex::new(44433..));
pub(crate) static CERTIFIED_KEY: LazyLock<rama_tls::server::ServerAuthData> =
    LazyLock::new(crate::test_helpers::identity);

#[cfg(not(all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))))]
fn server_crypto_inner(
    identity: Option<(CertificateDer<'static>, PrivateKeyDer<'static>)>,
    alpn: Option<Vec<Vec<u8>>>,
) -> QuicServerConfig {
    let identity = identity.map_or_else(
        || CERTIFIED_KEY.clone(),
        |(cert, key)| rama_tls::server::ServerAuthData::new(vec![cert], key),
    );
    let tls = rama_tls::server::TlsServerConfig::new()
        .with_server_auth(identity)
        .with_alpn(
            alpn.unwrap_or_else(|| vec![b"rama-quic-test".to_vec()])
                .into_iter()
                .map(Into::into)
                .collect(),
        );
    QuicServerConfig::from_rama(&tls, crate::test_helpers::options()).unwrap()
}

#[cfg(not(all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))))]
fn client_crypto_inner(
    certs: Option<Vec<CertificateDer<'static>>>,
    alpn: Option<Vec<Vec<u8>>>,
) -> QuicClientConfig {
    use rama_tls_boring::client::BoringClientConfigExt;
    let tls = rama_tls::client::TlsClientConfig::new()
        .with_supported_groups(vec![rama_tls::SupportedGroup::X25519])
        .with_alpn(
            alpn.unwrap_or_else(|| vec![b"rama-quic-test".to_vec()])
                .into_iter()
                .map(Into::into)
                .collect(),
        )
        .try_with_server_trust_anchors(
            certs.unwrap_or_else(|| vec![CERTIFIED_KEY.cert_chain[0].clone()]),
        )
        .unwrap();
    QuicClientConfig::from_rama(&tls, crate::test_helpers::options()).unwrap()
}
