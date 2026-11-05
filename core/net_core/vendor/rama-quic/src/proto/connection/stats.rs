//! Connection statistics

use crate::proto::Duration;
use rama_quic_proto::{Dir, frame::Frame};

/// Statistics about UDP datagrams transmitted or received on a connection
///
/// All QUIC packets are carried by UDP datagrams. Hence, these statistics cover all traffic on a connection.
#[derive(Default, Debug, Copy, Clone)]
#[non_exhaustive]
pub struct UdpStats {
    /// The amount of UDP datagrams observed
    pub datagrams: u64,
    /// The total amount of bytes which have been transferred inside UDP datagrams
    pub bytes: u64,
    /// The amount of I/O operations executed
    ///
    /// Can be less than `datagrams` when GSO, GRO, and/or batched system calls are in use.
    pub ios: u64,
}

impl UdpStats {
    pub(crate) fn on_sent(&mut self, datagrams: u64, bytes: usize) {
        self.datagrams += datagrams;
        self.bytes += bytes as u64;
        self.ios += 1;
    }
}

/// Number of frames transmitted or received of each frame type
#[derive(Default, Copy, Clone)]
#[non_exhaustive]
pub struct FrameStats {
    /// ACK frames (RFC 9000 §19.3).
    pub acks: u64,
    /// ACK_FREQUENCY frames, from the ack-frequency extension.
    pub ack_frequency: u64,
    /// CRYPTO frames carrying handshake data (§19.6).
    pub crypto: u64,
    /// CONNECTION_CLOSE frames of either kind (§19.19).
    pub connection_close: u64,
    /// DATA_BLOCKED frames, saying the connection's data limit was reached (§19.12).
    pub data_blocked: u64,
    /// DATAGRAM frames, from the unreliable-datagram extension (RFC 9221).
    pub datagram: u64,
    /// HANDSHAKE_DONE frames counted as they pass, retransmissions included (§19.20).
    /// Saturates at [`u8::MAX`].
    pub handshake_done: u8,
    /// IMMEDIATE_ACK frames, from the ack-frequency extension.
    pub immediate_ack: u64,
    /// MAX_DATA frames, raising the connection's data limit (§19.9).
    pub max_data: u64,
    /// MAX_STREAM_DATA frames, raising one stream's limit (§19.10).
    pub max_stream_data: u64,
    /// MAX_STREAMS frames for bidirectional streams (§19.11).
    pub max_streams_bidi: u64,
    /// MAX_STREAMS frames for unidirectional streams (§19.11).
    pub max_streams_uni: u64,
    /// NEW_CONNECTION_ID frames offering another identifier (§19.15).
    pub new_connection_id: u64,
    /// NEW_TOKEN frames carrying an address-validation token (§19.7).
    pub new_token: u64,
    /// NEW_TOKEN frames that were not sent because the token could not be sealed. Never
    /// received: it counts a local failure.
    pub new_token_failed: u64,
    /// PATH_CHALLENGE frames probing a path (§19.17).
    pub path_challenge: u64,
    /// PATH_RESPONSE frames answering a probe (§19.18).
    pub path_response: u64,
    /// PING frames (§19.2).
    pub ping: u64,
    /// RESET_STREAM frames giving up on a stream (§19.4).
    pub reset_stream: u64,
    /// RETIRE_CONNECTION_ID frames dropping an identifier (§19.16).
    pub retire_connection_id: u64,
    /// STREAM_DATA_BLOCKED frames, saying one stream's limit was reached (§19.13).
    pub stream_data_blocked: u64,
    /// STREAMS_BLOCKED frames for bidirectional streams (§19.14).
    pub streams_blocked_bidi: u64,
    /// STREAMS_BLOCKED frames for unidirectional streams (§19.14).
    pub streams_blocked_uni: u64,
    /// STOP_SENDING frames asking a peer to stop writing a stream (§19.5).
    pub stop_sending: u64,
    /// STREAM frames carrying application data (§19.8).
    pub stream: u64,
}

impl FrameStats {
    pub(crate) fn record(&mut self, frame: &Frame) {
        match frame {
            Frame::Padding => {}
            Frame::Ping => self.ping += 1,
            Frame::Ack(_) => self.acks += 1,
            Frame::ResetStream(_) => self.reset_stream += 1,
            Frame::StopSending(_) => self.stop_sending += 1,
            Frame::Crypto(_) => self.crypto += 1,
            Frame::Datagram(_) => self.datagram += 1,
            Frame::NewToken(_) => self.new_token += 1,
            Frame::MaxData(_) => self.max_data += 1,
            Frame::MaxStreamData { .. } => self.max_stream_data += 1,
            Frame::MaxStreams { dir, .. } => {
                if *dir == Dir::Bi {
                    self.max_streams_bidi += 1;
                } else {
                    self.max_streams_uni += 1;
                }
            }
            Frame::DataBlocked { .. } => self.data_blocked += 1,
            Frame::Stream(_) => self.stream += 1,
            Frame::StreamDataBlocked { .. } => self.stream_data_blocked += 1,
            Frame::StreamsBlocked { dir, .. } => {
                if *dir == Dir::Bi {
                    self.streams_blocked_bidi += 1;
                } else {
                    self.streams_blocked_uni += 1;
                }
            }
            Frame::NewConnectionId(_) => self.new_connection_id += 1,
            Frame::RetireConnectionId { .. } => self.retire_connection_id += 1,
            Frame::PathChallenge(_) => self.path_challenge += 1,
            Frame::PathResponse(_) => self.path_response += 1,
            Frame::Close(_) => self.connection_close += 1,
            Frame::AckFrequency(_) => self.ack_frequency += 1,
            Frame::ImmediateAck => self.immediate_ack += 1,
            Frame::HandshakeDone => self.handshake_done = self.handshake_done.saturating_add(1),
        }
    }
}

impl std::fmt::Debug for FrameStats {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FrameStats")
            .field("ACK", &self.acks)
            .field("ACK_FREQUENCY", &self.ack_frequency)
            .field("CONNECTION_CLOSE", &self.connection_close)
            .field("CRYPTO", &self.crypto)
            .field("DATA_BLOCKED", &self.data_blocked)
            .field("DATAGRAM", &self.datagram)
            .field("HANDSHAKE_DONE", &self.handshake_done)
            .field("IMMEDIATE_ACK", &self.immediate_ack)
            .field("MAX_DATA", &self.max_data)
            .field("MAX_STREAM_DATA", &self.max_stream_data)
            .field("MAX_STREAMS_BIDI", &self.max_streams_bidi)
            .field("MAX_STREAMS_UNI", &self.max_streams_uni)
            .field("NEW_CONNECTION_ID", &self.new_connection_id)
            .field("NEW_TOKEN", &self.new_token)
            .field("PATH_CHALLENGE", &self.path_challenge)
            .field("PATH_RESPONSE", &self.path_response)
            .field("PING", &self.ping)
            .field("RESET_STREAM", &self.reset_stream)
            .field("RETIRE_CONNECTION_ID", &self.retire_connection_id)
            .field("STREAM_DATA_BLOCKED", &self.stream_data_blocked)
            .field("STREAMS_BLOCKED_BIDI", &self.streams_blocked_bidi)
            .field("STREAMS_BLOCKED_UNI", &self.streams_blocked_uni)
            .field("STOP_SENDING", &self.stop_sending)
            .field("STREAM", &self.stream)
            .finish()
    }
}

/// Statistics related to a transmission path
#[derive(Debug, Default, Copy, Clone)]
#[non_exhaustive]
pub struct PathStats {
    /// Current best estimate of this connection's latency (round-trip-time)
    pub rtt: Duration,
    /// Minimum RTT seen on this path, ignoring ack delay
    pub min_rtt: Duration,
    /// Current congestion window of the connection
    pub cwnd: u64,
    /// The window at which the controller leaves slow start, when it has one. BBR paces
    /// instead and reports none.
    pub ssthresh: Option<u64>,
    /// The rate the controller paces at, in bits per second, when it paces.
    pub pacing_rate: Option<u64>,
    /// Congestion events on the connection
    pub congestion_events: u64,
    /// The amount of packets lost on this path
    pub lost_packets: u64,
    /// Peer moves deferred because no unused destination connection ID was available
    pub deferred_migrations: u64,
    /// PATH_CHALLENGE probes transmitted towards a server's preferred address
    pub preferred_address_probes: u64,
    /// PATH_CHALLENGEs from a path this connection has no connection ID for, so their answers
    /// were dropped rather than sent with an identifier used elsewhere
    pub unanswered_off_path_challenges: u64,
    /// The amount of bytes lost on this path
    pub lost_bytes: u64,
    /// The amount of packets sent on this path
    pub sent_packets: u64,
    /// The amount of PLPMTUD probe packets sent on this path (also counted by `sent_packets`)
    pub sent_plpmtud_probes: u64,
    /// The amount of PLPMTUD probe packets lost on this path (ignored by `lost_packets` and
    /// `lost_bytes`)
    pub lost_plpmtud_probes: u64,
    /// The number of times a black hole was detected in the path
    pub black_holes_detected: u64,
    /// Largest UDP payload size the path currently supports
    pub current_mtu: u16,
}

/// Connection statistics
#[derive(Debug, Default, Copy, Clone)]
#[non_exhaustive]
pub struct ConnectionStats {
    /// Statistics about UDP datagrams transmitted on a connection
    pub udp_tx: UdpStats,
    /// Statistics about UDP datagrams received on a connection
    pub udp_rx: UdpStats,
    /// How many frames of each kind this connection has sent.
    pub frame_tx: FrameStats,
    /// How many frames of each kind it has received.
    pub frame_rx: FrameStats,
    /// Statistics related to the current transmission path
    pub path: PathStats,
    /// How many times this connection's traffic keys were updated (RFC 9001 §6), whether the
    /// update was asked for locally, forced by the usage limit, or started by the peer.
    pub key_updates: u64,
    /// Datagrams the connection's datagram gates dropped.
    pub gated_datagrams: GatedDatagramStats,
}

/// Datagrams dropped by a connection's datagram gates
/// ([`Connection::add_datagram_gates`](crate::Connection::add_datagram_gates)).
#[derive(Debug, Default, Copy, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub struct GatedDatagramStats {
    /// Received from the peer and dropped before the application read them.
    pub received: u64,
    /// Sent by the application and dropped before they were queued.
    pub sent: u64,
}
