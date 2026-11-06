#[cfg(all(
    any(fuzzing, test),
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )
))]
mod datagram_sequence;
#[cfg(all(
    any(fuzzing, test),
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )
))]
mod fuzz_pair;
#[cfg(all(
    any(fuzzing, test),
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )
))]
mod token_sequence;
#[cfg(all(
    fuzzing,
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )
))]
pub use datagram_sequence::datagram_sequence;
#[cfg(all(
    fuzzing,
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )
))]
pub use token_sequence::token_sequence;

#[cfg(feature = "test-utils")]
pub(crate) mod benchmarks;

use std::{collections::VecDeque, fmt, net::SocketAddr, sync::Arc};

use rama_core::bytes::Bytes;

use rand::{RngExt, SeedableRng, rngs::StdRng};

use crate::proto::{
    Duration, EndpointConfig, Instant,
    cid_queue::CidQueue,
    config::TransportConfig,
    crypto::{self, KeyPair},
    observation::ServerObservation,
    shared::EndpointEventInner,
    transport_parameters,
};
use rama_quic_proto::{
    ConnectionId, Dir, Side, StreamId, TransportError, VarInt, Version, crypto::PacketKey,
    packet::SpaceId, transport_parameters::TransportParameters, version::WireVersion,
};

mod ack_frequency;
mod assembler;
mod cid_state;
mod cids;
mod close;
mod datagrams;
mod early_packets;
mod events;
mod frames;
mod handshake;
mod initial_replay;
mod lifecycle;
mod migration;
mod mtud;
mod pacing;
mod packet_builder;
mod packet_crypto;
mod paths;
mod payload;
mod preferred;
mod preferred_local;
pub(crate) mod qlog;
mod receive;
mod recovery;
mod retained;
mod send_buffer;
mod spaces;
mod spin;
mod stats;
mod streams;
#[cfg(test)]
mod testing;
mod timer;
mod transmit;

pub use assembler::Chunk;
pub use rama_quic_proto::ConnectionError;
#[cfg(fuzzing)]
pub use spaces::Retransmits;
pub use stats::{ConnectionStats, FrameStats, GatedDatagramStats, PathStats, UdpStats};
#[cfg(fuzzing)]
pub use streams::StreamsState;
pub use streams::{ClosedStream, Written};
#[cfg(fuzzing)]
pub use streams::{SendStream, Streams};

pub(crate) use datagrams::{Datagrams, SendDatagramError};
pub(crate) use lifecycle::{Event, SideArgs};
// `State` is re-exported under `fuzzing`, which is what its own declaration is written for.
#[cfg_attr(
    not(fuzzing),
    expect(
        unreachable_pub,
        reason = "reachable through `fuzzing` under cfg(fuzzing)"
    )
)]
pub use lifecycle::State;
pub(crate) use paths::RttEstimator;
pub(crate) use preferred::PreferredAddressState;
#[cfg(all(
    test,
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )
))]
pub(crate) use streams::StreamResourceUsage;
pub(crate) use streams::{
    Chunks, FinishError, ReadError, ReadableError, RecvStream, StreamEvent, WriteError,
};
#[cfg(not(fuzzing))]
pub(crate) use streams::{SendStream, Streams};

use ack_frequency::AckFrequencyState;
use cid_state::CidState;
use close::CloseResponses;
use datagrams::DatagramState;
use lifecycle::{ConnectionSide, state};
use migration::{DeferredMigration, PATH_CIDS, PathCid, PrevPath};
use packet_crypto::{PrevCrypto, ZeroRttCrypto};
use paths::{PathData, PathResponses};
use preferred::PreferredCandidate;
use spaces::{PacketNumberFilter, PacketSpace, PacketSpaces, SentPacket};
#[cfg(not(fuzzing))]
use streams::StreamsState;
use timer::{Timer, TimerTable};

/// Protocol state and logic for a single QUIC connection
///
/// Objects of this type receive [`ConnectionEvent`](crate::proto::shared::ConnectionEvent)s and emit \
/// [`EndpointEvent`](crate::proto::shared::EndpointEvent)s and application
/// [`Event`]s to make progress. To handle timeouts, a `Connection` returns timer updates and
/// expects timeouts through various methods. A number of simple getter methods are exposed
/// to allow callers to inspect some of the connection state.
///
/// `Connection` has roughly 4 types of methods:
///
/// - A. Simple getters, taking `&self`
/// - B. Handlers for incoming events from the network or system, named `handle_*`.
/// - C. State machine mutators, for incoming commands from the application. For convenience we
///   refer to this as "performing I/O" below, however as per the design of this library none of the
///   functions actually perform system-level I/O. For example, [`read`](RecvStream::read) and
///   [`write`](SendStream::write), but also things like [`reset`](SendStream::reset).
/// - D. Polling functions for outgoing events or actions for the caller to
///   take, named `poll_*`.
///
/// The simplest way to use this API correctly is to call (B) and (C) whenever
/// appropriate, then after each of those calls, as soon as feasible call all
/// polling methods (D) and deal with their outputs appropriately, e.g. by
/// passing it to the application or by making a system-level I/O call. You
/// should call the polling functions in this order:
///
/// 1. [`poll_transmit`](Self::poll_transmit)
/// 2. [`poll_timeout`](Self::poll_timeout)
/// 3. [`poll_endpoint_events`](Self::poll_endpoint_events)
/// 4. [`poll`](Self::poll)
///
/// Currently the only actual dependency is from (2) to (1), however additional
/// dependencies may be added in future, so the above order is recommended.
///
/// (A) may be called whenever desired.
///
/// Care should be made to ensure that the input events represent monotonically
/// increasing time. Specifically, calling [`handle_timeout`](Self::handle_timeout)
/// with events of the same [`Instant`] may be interleaved in any order with a
/// call to [`handle_event`](Self::handle_event) at that same instant; however
/// events or timeouts with different instants must not be interleaved.
pub(crate) struct Connection {
    pub(crate) observation: Option<Box<ServerObservation>>,
    endpoint_config: Arc<EndpointConfig>,
    config: Arc<TransportConfig>,
    rng: StdRng,
    crypto: Box<dyn crypto::Session>,
    /// The CID we initially chose, for use during the handshake
    handshake_cid: ConnectionId,
    /// The CID the peer initially chose, for use during the handshake
    rem_handshake_cid: ConnectionId,
    path: PathData,
    /// Incremented every time we see a new path
    ///
    /// Stored separately from `path.generation` to account for aborted migrations
    path_counter: u64,
    /// Whether MTU detection is supported in this environment
    allow_mtud: bool,
    /// The path sent on before the current one, kept while the current one is validated.
    prev_path: Option<PrevPath>,
    /// A peer move that could not be followed yet because no unused destination connection ID
    /// was available (RFC 9000 §9.5); completed when the peer issues one, unless newer traffic
    /// superseded it meanwhile.
    deferred_migration: Option<DeferredMigration>,
    /// The server's preferred address for the family in use, once advertised (client only).
    preferred_address: Option<SocketAddr>,
    /// How far this client got with that address.
    preferred_state: PreferredAddressState,
    /// The candidate path while it is being probed.
    candidate: Option<PreferredCandidate>,
    server_candidate: Option<Box<preferred_local::ServerCandidate>>,
    server_candidate_attempts: u8,
    /// Identifiers bound to a path this connection does not otherwise send on, so an answer
    /// there carries one that is sent from no other local address (RFC 9000 §9.5).
    path_cids: [Option<PathCid>; PATH_CIDS],
    /// A protocol error raised where the caller cannot return one, such as a retirement queue
    /// reaching its bound during a timer. The connection closes with it at the next transmit.
    deferred_error: Option<TransportError>,
    /// Names each route installation, so a release or an acknowledgement in flight cannot be
    /// applied to a later one that reuses the same identifier and address.
    reset_generation: u64,
    /// Tests: how many times the sender has reported a datagram as having reached the network.
    #[cfg(test)]
    cid_sent_calls: u64,
    /// Ack-eliciting packets sent and neither acknowledged, declared lost nor abandoned, across
    /// every packet number space and every path they were sent on, including paths since
    /// discarded. Loss recovery (RFC 9002 §6.2) is a connection-wide matter; the per-path
    /// `InFlight` counters serve congestion control and vanish with their path.
    in_flight_ack_eliciting: u64,
    state: State,
    side: ConnectionSide,
    /// Whether or not 0-RTT was enabled during the handshake. Does not imply acceptance.
    zero_rtt_enabled: bool,
    /// Set if 0-RTT is supported, then cleared when no longer needed.
    zero_rtt_crypto: Option<ZeroRttCrypto>,
    key_phase: bool,
    /// First outgoing packet number of the latest key update. Read-key retirement does
    /// not establish that the peer acknowledged a packet from this phase.
    key_update_start_packet: Option<u64>,
    /// The lowest space whose CONNECTION_CLOSE has still to go out. A close this side makes
    /// goes in every space that has keys (RFC 9000 §10.2.3), one datagram each; a pass that
    /// encodes none leaves this where it was.
    close_from: SpaceId,
    /// How many packets are in the current key phase. Used only for `Data` space.
    key_phase_size: u64,
    /// Transport parameters set by the peer
    peer_params: TransportParameters,
    /// Tests: keep HANDSHAKE_DONE from the peer (see [`hold_handshake_done`](Self::hold_handshake_done)).
    #[cfg(test)]
    hold_handshake_done: bool,
    /// Tests: HANDSHAKE_DONE that the seam above took out of the pending set.
    #[cfg(test)]
    withheld_handshake_done: bool,
    /// Source ConnectionId of the first packet received from the peer
    orig_rem_cid: ConnectionId,
    /// Destination ConnectionId sent by the client on the first Initial
    initial_dst_cid: ConnectionId,
    /// The identifier both ends name this connection by in a trace: the destination of the
    /// client's very first Initial, before any Retry. Packet protection, routing and handshake
    /// validation use `initial_dst_cid`, which a Retry moves; this one does not move.
    trace_cid: ConnectionId,
    /// The value that the server included in the Source Connection ID field of a Retry packet, if
    /// one was received
    retry_src_cid: Option<ConnectionId>,
    events: VecDeque<Event>,
    endpoint_events: VecDeque<EndpointEventInner>,
    /// Whether the spin bit is in use for this connection
    spin_enabled: bool,
    /// Passive signaling state for the paths this connection still uses.
    spins: Vec<spin::PathSpin>,
    spin_local: Option<SocketAddr>,
    /// Packet number spaces: initial, handshake, 1-RTT
    spaces: PacketSpaces,
    /// Highest usable packet number space
    highest_space: SpaceId,
    /// 1-RTT keys used prior to a key update
    prev_crypto: Option<PrevCrypto>,
    /// 1-RTT keys to be used for the next key update
    ///
    /// These are generated in advance to prevent timing attacks and/or DoS by third-party attackers
    /// spoofing key updates.
    next_crypto: Option<KeyPair<Box<dyn PacketKey>>>,
    /// The server's early-data decision, recorded by clients that offered early data.
    early_data: Option<bool>,
    /// Whether the idle timer should be reset the next time an ack-eliciting packet is transmitted.
    permit_idle_reset: bool,
    /// Negotiated idle timeout
    idle_timeout: Option<Duration>,
    /// The time we send next bundled ACK
    ///
    /// The goal is to wait long enough for the peer to acknowledge our previous
    /// bundled ACK (see `next_bundled_ack_delay`).
    /// A packet-count threshold would over- or under-shoot this depending on how fast we happen
    /// to be sending, so a time threshold is used instead.
    next_bundled_ack_time: Option<Instant>,
    timers: TimerTable,
    /// Number of packets received which could not be authenticated
    authentication_failures: u64,
    /// Packets received before the handshake produced their keys.
    early_packets: early_packets::EarlyPackets,
    /// Why the connection was lost, if it has been
    error: Option<ConnectionError>,
    /// Identifies Data-space packet numbers to skip. Not used in earlier spaces.
    packet_number_filter: PacketNumberFilter,

    // Queued non-retransmittable 1-RTT data
    /// Responses to PATH_CHALLENGE frames
    path_responses: PathResponses,
    close: bool,
    /// How often the closing state answers the peer.
    close_responses: CloseResponses,

    // ACK frequency
    ack_frequency: AckFrequencyState,

    // Loss Detection
    /// The number of times a PTO has been sent without receiving an ack.
    pto_count: u32,
    /// UDP datagrams still permitted to bypass congestion control for this PTO.
    /// All packet-number spaces share the allowance (RFC 9002 §6.2.4).
    loss_probe_budget: u32,

    // Congestion Control
    /// Whether the most recently received packet had an ECN codepoint set
    receiving_ecn: bool,
    /// Number of packets authenticated
    total_authed_packets: u64,
    /// Whether the last `poll_transmit` call yielded no data because there was
    /// no outgoing application data.
    app_limited: bool,

    streams: StreamsState,
    /// Surplus remote CIDs for future use on new paths
    rem_cids: CidQueue,
    // Attributes of CIDs generated by local peer
    local_cid_state: CidState,
    /// State of the unreliable datagram extension
    datagrams: DatagramState,
    /// Last lifecycle state written to qlog, if recording is enabled.
    qlog_sink: qlog::ConnectionQlog,
    qlog_state: Option<qlog::lifecycle::ConnectionState>,
    qlog_closed: bool,
    /// Connection level statistics
    stats: ConnectionStats,
    /// Whether a recorded Initial layout is used; cleared when it does not fit.
    recorded_initial: bool,
    /// QUIC version the connection's packets currently carry.
    wire_version: WireVersion,
    /// QUIC version of the client's first flight, before any compatible negotiation
    /// (RFC 9368 §1.2, "Chosen Version").
    original_wire_version: WireVersion,
    /// Initial keys for `original_version` while `version` differs from it: a server keeps
    /// reading the client's first flight with them, a client keeps reading what the server sent
    /// before it processed the client's parameters (RFC 9369 §4.1). Gone with the Initial space.
    original_initial_crypto: Option<crypto::Keys>,
    /// The connection ID the Initial keys derive from: the first destination, or the Retry's
    /// source afterwards (RFC 9001 §5.2).
    initial_keys_cid: ConnectionId,
    /// Whether `peer_params` came from the peer in this handshake, rather than being remembered
    /// from an earlier one for 0-RTT.
    peer_params_received: bool,
}

impl Connection {
    pub(crate) fn new(
        endpoint_config: Arc<EndpointConfig>,
        config: Arc<TransportConfig>,
        init_cid: ConnectionId,
        loc_cid: ConnectionId,
        rem_cid: ConnectionId,
        remote: SocketAddr,
        local: Option<SocketAddr>,
        crypto: Box<dyn crypto::Session>,
        cid_len: usize,
        cid_lifetime: Option<Duration>,
        now: Instant,
        version: Version,
        allow_mtud: bool,
        rng_seed: [u8; 32],
        side_args: SideArgs,
    ) -> Result<Self, TransportError> {
        let pref_addr_cid = side_args.pref_addr_cid();
        let path_validated = side_args.path_validated();
        let trace_cid = side_args.trace_cid(init_cid);
        let original_version = side_args.original_version(version);
        let connection_side = ConnectionSide::from(side_args);
        let side = connection_side.side();
        let initial_space = PacketSpace {
            crypto: Some(crypto.initial_keys(version, &init_cid, side)?),
            ..PacketSpace::new(now)
        };
        let original_initial_crypto = (original_version != version)
            .then(|| crypto.initial_keys(original_version, &init_cid, side))
            .transpose()?;
        // The endpoint only starts a connection in a version it negotiated, which is one this
        // crate implements; proving that here lets every header this connection forms carry the
        // version without a fallible wire lookup.
        let version = version.to_wire().ok_or_else(|| {
            TransportError::INTERNAL_ERROR("connection started in an unimplemented QUIC version")
        })?;
        let original_version = original_version.to_wire().ok_or_else(|| {
            TransportError::INTERNAL_ERROR("connection started in an unimplemented QUIC version")
        })?;
        let state = State::Handshake(state::Handshake {
            rem_cid_set: side.is_server(),
            expected_token: Bytes::new(),
            client_hello: None,
        });
        let rem_cids = CidQueue::new(
            rem_cid,
            transport_parameters::active_connection_id_limit(&config, cid_len).into_inner(),
        )?;
        let mut rng = StdRng::from_seed(rng_seed);
        let mut this = Self {
            observation: None,
            endpoint_config,
            crypto,
            handshake_cid: loc_cid,
            rem_handshake_cid: rem_cid,
            local_cid_state: CidState::new(cid_len, cid_lifetime, now, loc_cid, pref_addr_cid),
            path: PathData::new(remote, local, allow_mtud, None, 0, now, &config),
            path_counter: 0,
            allow_mtud,
            prev_path: None,
            deferred_migration: None,
            preferred_address: None,
            preferred_state: PreferredAddressState::Unused,
            candidate: None,
            server_candidate: None,
            server_candidate_attempts: 0,
            deferred_error: None,
            reset_generation: 0,
            #[cfg(test)]
            cid_sent_calls: 0,
            // The handshake goes out with the identifier the peer chose for it.
            path_cids: [None; PATH_CIDS],
            in_flight_ack_eliciting: 0,
            state,
            side: connection_side,
            zero_rtt_enabled: false,
            zero_rtt_crypto: None,
            key_phase: false,
            key_update_start_packet: None,
            close_from: SpaceId::Initial,
            // A small initial key phase size ensures peers that don't handle key updates correctly
            // fail sooner rather than later. It's okay for both peers to do this, as the first one
            // to perform an update will reset the other's key phase size in `update_keys`, and a
            // simultaneous key update by both is just like a regular key update with a really fast
            // response. Other implementations similarly perform the first key update early (for
            // example at the 100th short-header packet).
            // Without the early update, the 1-RTT keys set the first phase (`upgrade_crypto`).
            key_phase_size: if config.early_key_update {
                rng.random_range(10..1000)
            } else {
                u64::MAX
            },
            peer_params: TransportParameters::default(),
            #[cfg(test)]
            hold_handshake_done: false,
            #[cfg(test)]
            withheld_handshake_done: false,
            orig_rem_cid: rem_cid,
            initial_dst_cid: init_cid,
            trace_cid,
            retry_src_cid: None,
            events: VecDeque::new(),
            endpoint_events: VecDeque::new(),
            spin_enabled: config.allow_spin && rng.random_ratio(7, 8),
            spins: Vec::new(),
            spin_local: None,
            spaces: PacketSpaces([initial_space, PacketSpace::new(now), PacketSpace::new(now)]),
            highest_space: SpaceId::Initial,
            prev_crypto: None,
            next_crypto: None,
            early_data: None,
            permit_idle_reset: true,
            idle_timeout: match config.max_idle_timeout.map(VarInt::into_inner) {
                None | Some(0) => None,
                Some(dur) => Some(Duration::from_millis(dur)),
            },
            timers: TimerTable::default(),
            authentication_failures: 0,
            early_packets: Default::default(),
            error: None,
            #[cfg(test)]
            packet_number_filter: match config.deterministic_packet_numbers {
                false => PacketNumberFilter::new(&mut rng),
                true => PacketNumberFilter::disabled(),
            },
            #[cfg(not(test))]
            packet_number_filter: PacketNumberFilter::new(&mut rng),

            path_responses: PathResponses::default(),
            close: false,
            close_responses: CloseResponses::new(),

            ack_frequency: AckFrequencyState::new(config.max_ack_delay),
            next_bundled_ack_time: None,

            pto_count: 0,
            loss_probe_budget: 0,

            app_limited: false,
            receiving_ecn: false,
            total_authed_packets: 0,

            streams: StreamsState::new(
                side,
                config.max_concurrent_uni_streams,
                config.max_concurrent_bidi_streams,
                config.send_window,
                config.receive_window,
                config.stream_receive_window,
            ),
            datagrams: DatagramState::default(),
            qlog_sink: config.qlog_sink.for_connection(trace_cid),
            config,
            rem_cids,
            rng,
            qlog_state: None,
            qlog_closed: false,
            stats: ConnectionStats::default(),
            recorded_initial: true,
            wire_version: version,
            original_wire_version: original_version,
            original_initial_crypto,
            initial_keys_cid: init_cid,
            peer_params_received: false,
        };
        this.streams
            .set_receive_windows(streams::StreamReceiveWindows {
                bidi_local: this.config.stream_receive_window.into(),
                bidi_remote: this
                    .config
                    .stream_receive_window_bidi_remote
                    .unwrap_or(this.config.stream_receive_window)
                    .into(),
                uni: this
                    .config
                    .stream_receive_window_uni
                    .unwrap_or(this.config.stream_receive_window)
                    .into(),
            });
        let first_packet_number = this.config.wire.packetization.first_packet_number();
        for space in &mut this.spaces.0 {
            space.next_packet_number = first_packet_number;
        }
        this.qlog_connection_started(now);
        this.qlog_init_negotiation(now);
        this.qlog_init_recovery(now);
        this.qlog_assign_current_tuple(now);
        if let Some(deadline) = now.checked_add(this.endpoint_config.handshake_timeout) {
            this.timers.set(Timer::Handshake, deadline);
        } else {
            this.kill(
                now,
                TransportError::INTERNAL_ERROR("handshake timeout exceeds clock range").into(),
            );
            return Ok(this);
        }
        if path_validated {
            this.on_path_validated();
        }
        if side.is_client() {
            // Kick off the connection
            this.write_crypto(now);
            if this.error.is_none() {
                this.prepare_recorded_initial()?;
            }
            this.init_0rtt(now);
        }
        Ok(this)
    }

    /// Provide control over streams
    #[must_use]
    pub(crate) fn streams(&mut self) -> Streams<'_> {
        Streams {
            state: &mut self.streams,
            conn_state: &self.state,
        }
    }

    /// Provide control over streams
    #[must_use]
    pub(crate) fn recv_stream(&mut self, id: StreamId) -> RecvStream<'_> {
        assert!(id.dir() == Dir::Bi || id.initiator() != self.side.side());
        RecvStream {
            id,
            state: &mut self.streams,
            pending: &mut self.spaces[SpaceId::Data].pending,
        }
    }

    /// Provide control over streams
    #[must_use]
    pub(crate) fn send_stream(&mut self, id: StreamId) -> SendStream<'_> {
        assert!(id.dir() == Dir::Bi || id.initiator() == self.side.side());
        SendStream {
            id,
            state: &mut self.streams,
            pending: &mut self.spaces[SpaceId::Data].pending,
            conn_state: &self.state,
        }
    }

    /// Control datagrams
    pub(crate) fn datagrams(&mut self) -> Datagrams<'_> {
        Datagrams { conn: self }
    }

    /// Returns connection statistics
    /// The QUIC version the connection's packets carry (RFC 9368 §4: the negotiated version).
    pub(crate) fn version(&self) -> Version {
        self.wire_version.version()
    }

    /// The QUIC version of the client's first flight.
    pub(crate) fn original_version(&self) -> Version {
        self.original_wire_version.version()
    }

    /// The transport parameters the peer sent, as this connection applied them.
    #[cfg(test)]
    pub(crate) fn peer_params(&self) -> &TransportParameters {
        &self.peer_params
    }

    /// RFC 9287 §3.1: the QUIC bit may be cleared once the peer's parameters for this
    /// handshake say it accepts that. Before they arrive, only a client holding a recent token
    /// from a server that greased may clear it; parameters remembered for 0-RTT do not count.
    /// Greasing is off altogether when this endpoint does not grease.
    pub(crate) fn may_grease_quic_bit(&self) -> bool {
        if !self.endpoint_config.grease_quic_bit {
            return false;
        }
        if self.peer_params_received {
            return self.peer_params.grease_quic_bit;
        }
        matches!(
            self.side,
            ConnectionSide::Client {
                grease_quic_bit_early: true,
                ..
            }
        )
    }

    /// Tests: how many received packets wait on keys the handshake has yet to produce.
    #[cfg(test)]
    pub(crate) fn held_early_packets(&self) -> usize {
        self.early_packets.len()
    }

    /// Tests: the highest packet number space this connection has keys for.
    #[cfg(test)]
    pub(crate) fn highest_space(&self) -> SpaceId {
        self.highest_space
    }

    /// Tests: whether this client clears the QUIC bit before the server's parameters arrive.
    #[cfg(test)]
    pub(crate) fn greases_quic_bit_early(&self) -> bool {
        matches!(
            self.side,
            ConnectionSide::Client {
                grease_quic_bit_early: true,
                ..
            }
        )
    }

    pub(crate) fn stats(&self) -> ConnectionStats {
        let mut stats = self.stats;
        stats.path.rtt = self.path.rtt.get();
        stats.path.min_rtt = self.path.rtt.min();
        let congestion = self.path.congestion.metrics();
        stats.path.cwnd = congestion.congestion_window;
        stats.path.ssthresh = congestion.ssthresh;
        stats.path.pacing_rate = congestion.pacing_rate;
        stats.path.current_mtu = self.path.mtud.current_mtu();

        stats
    }

    /// Ping the remote endpoint
    ///
    /// Causes an ACK-eliciting packet to be transmitted.
    pub(crate) fn ping(&mut self) {
        self.spaces[self.highest_space].ping_pending = true;
    }

    /// The identifier the client chose for its first Initial, which both ends know and neither
    /// changes. It is the group a qlog trace records this connection under.
    pub(crate) fn qlog_control(&self) -> Option<crate::qlog::ConnectionQlogControl> {
        self.qlog_sink.control()
    }

    pub(crate) fn trace_id(&self) -> ConnectionId {
        self.trace_cid
    }

    /// Look up whether we're the client or server of this Connection
    pub(crate) fn side(&self) -> Side {
        self.side.side()
    }

    /// Current best estimate of this connection's latency (round-trip-time)
    pub(crate) fn rtt(&self) -> Duration {
        self.path.rtt.get()
    }

    /// Minimum RTT seen on this path, ignoring ack delay
    pub(crate) fn min_rtt(&self) -> Duration {
        self.path.rtt.min()
    }

    /// Modify the number of remotely initiated streams that may be concurrently open
    ///
    /// No streams may be opened by the peer unless fewer than `count` are already open. Large
    /// `count`s increase both minimum and worst-case memory consumption.
    pub(crate) fn set_max_concurrent_streams(&mut self, dir: Dir, count: VarInt) {
        self.streams.set_max_concurrent(dir, count);
        // If the limit was reduced, then a flow control update previously deemed insignificant may
        // now be significant.
        let pending = &mut self.spaces[SpaceId::Data].pending;
        self.streams.queue_max_stream_id(pending);
    }

    /// Current number of remotely initiated streams that may be concurrently open
    ///
    /// If the target for this limit is reduced using [`set_max_concurrent_streams`](Self::set_max_concurrent_streams),
    /// it will not change immediately, even if fewer streams are open. Instead, it will
    /// decrement by one for each time a remotely initiated stream of matching directionality is closed.
    pub(crate) fn max_concurrent_streams(&self, dir: Dir) -> u64 {
        self.streams.max_concurrent(dir)
    }

    /// See [`TransportConfig::send_window`]
    pub(crate) fn set_send_window(&mut self, send_window: u64) {
        self.streams.set_send_window(send_window);
    }

    /// See [`TransportConfig::receive_window`]
    pub(crate) fn set_receive_window(&mut self, receive_window: VarInt) {
        if self.streams.set_receive_window(receive_window) {
            self.spaces[SpaceId::Data].pending.max_data = true;
        }
    }
}

impl fmt::Debug for Connection {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.debug_struct("Connection")
            .field("handshake_cid", &self.handshake_cid)
            .finish()
    }
}
