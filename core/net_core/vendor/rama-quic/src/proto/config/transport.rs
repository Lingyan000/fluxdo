use rama_utils::octets;
use std::{fmt, sync::Arc};

use crate::proto::{
    ConfigError, Duration, INITIAL_MTU, MAX_UDP_PAYLOAD, cid_queue::CidQueue, congestion,
    connection::qlog::ConnectionQlog,
};
use rama_quic_proto::{VarInt, VarIntBoundsExceeded};

/// The smallest initial congestion window this crate accepts: two datagrams of the size every
/// QUIC path carries (RFC 9000 §14.1). It is a policy floor, not a protocol one; a window of
/// zero was measured to leave a connection unable to complete its handshake.
pub const MIN_INITIAL_CONGESTION_WINDOW: u64 = 2 * congestion::BASE_DATAGRAM_SIZE;

/// Which congestion controller a connection's paths use.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum CongestionControl {
    /// CUBIC (RFC 9438). The default.
    #[default]
    Cubic,
    /// NewReno (RFC 6582), the algorithm RFC 9002 §7 describes as the baseline.
    NewReno,
    /// Experimental BBR-style bandwidth and round-trip-time controller.
    /// Uses the shared congestion-window-based pacer; dedicated BBR pacing is not implemented.
    Bbr,
}

/// Parameters governing the core QUIC state machine
///
/// Default values should be suitable for most internet applications. Applications protocols which
/// forbid remotely-initiated streams should set `max_concurrent_bidi_streams` and
/// `max_concurrent_uni_streams` to zero.
///
/// In some cases, performance or resource requirements can be improved by tuning these values to
/// suit a particular application and/or network connection. In particular, data window sizes can be
/// tuned for a particular expected round trip time, link capacity, and memory availability. Tuning
/// for higher bandwidths and latencies increases worst-case memory consumption, but does not impair
/// performance at lower bandwidths and latencies. The default configuration is tuned for a 100Mbps
/// link with a 100ms round trip time.
#[derive(Clone)]
pub struct TransportConfig {
    pub(crate) max_concurrent_bidi_streams: VarInt,
    pub(crate) max_concurrent_uni_streams: VarInt,
    pub(crate) max_idle_timeout: Option<VarInt>,
    pub(crate) stream_receive_window: VarInt,
    pub(crate) stream_receive_window_bidi_remote: Option<VarInt>,
    pub(crate) stream_receive_window_uni: Option<VarInt>,
    pub(crate) receive_window: VarInt,
    pub(crate) active_connection_id_limit: Option<VarInt>,
    pub(crate) max_ack_delay: Duration,
    pub(crate) wire: crate::profile::WireProfile,
    pub(crate) send_window: u64,
    pub(crate) send_fairness: bool,

    pub(crate) packet_threshold: u32,
    pub(crate) time_threshold: f32,
    pub(crate) initial_rtt: Duration,
    pub(crate) initial_mtu: u16,
    pub(crate) min_mtu: u16,
    pub(crate) mtu_discovery_config: Option<MtuDiscoveryConfig>,
    pub(crate) pad_to_mtu: bool,
    pub(crate) ack_frequency_config: Option<AckFrequencyConfig>,

    pub(crate) persistent_congestion_threshold: u32,
    pub(crate) keep_alive_interval: Option<Duration>,
    pub(crate) crypto_buffer_size: usize,
    pub(crate) early_packet_buffer_packets: usize,
    pub(crate) early_packet_buffer_size: usize,
    pub(crate) allow_spin: bool,
    pub(crate) early_key_update: bool,
    pub(crate) datagram_receive_buffer_size: Option<usize>,
    pub(crate) datagram_send_buffer_size: usize,
    #[cfg(test)]
    pub(crate) deterministic_packet_numbers: bool,

    pub(crate) congestion_control: CongestionControl,
    pub(crate) initial_congestion_window: Option<u64>,

    pub(crate) enable_segmentation_offload: bool,

    pub(crate) qlog_sink: ConnectionQlog,
}

impl TransportConfig {
    /// The encoded DATAGRAM frame limit advertised to the peer.
    ///
    /// A profile can separate this wire limit from the local retention budget.
    /// Disabling reception removes the parameter, including any profile override.
    pub(crate) fn max_datagram_frame_size(&self) -> Option<VarInt> {
        let window = self.datagram_receive_buffer_size?;
        Some(self.wire.parameters.max_datagram_frame_size().map_or_else(
            || VarInt::from_u32(window.min(usize::from(u16::MAX)) as u32),
            |size| VarInt::from_u64(size).unwrap_or(VarInt::MAX),
        ))
    }

    /// Whether this configuration advertises a nonzero QUIC DATAGRAM receive limit.
    /// Queue capacity remains a separate local retention budget.
    #[must_use]
    pub fn datagram_receive_enabled(&self) -> bool {
        self.max_datagram_frame_size()
            .is_some_and(|size| size.into_inner() > 0)
    }

    rama_utils::macros::generate_set_and_with! {
        /// Maximum number of incoming bidirectional streams that may be open concurrently
        ///
        /// Must be nonzero for the peer to open any bidirectional streams.
        ///
        /// Worst-case memory use is directly proportional to `max_concurrent_bidi_streams *
        /// stream_receive_window`, with an upper bound proportional to `receive_window`.
        pub fn max_concurrent_bidi_streams(mut self, value: impl Into<VarInt>) -> Self {
            self.max_concurrent_bidi_streams = value.into();
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Variant of `max_concurrent_bidi_streams` affecting unidirectional streams
        pub fn max_concurrent_uni_streams(mut self, value: impl Into<VarInt>) -> Self {
            self.max_concurrent_uni_streams = value.into();
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Maximum duration of inactivity to accept before timing out the connection.
        ///
        /// The true idle timeout is the minimum of this and the peer's own max idle timeout. `None`
        /// represents an infinite timeout. Defaults to 30 seconds.
        ///
        /// **WARNING**: If a peer or its network path malfunctions or acts maliciously, an infinite
        /// idle timeout can result in permanently hung futures!
        ///
        /// ```
        /// # use std::{convert::TryInto, time::Duration};
        /// # use rama_quic::TransportConfig;
        /// # use rama_quic_proto::{VarInt, VarIntBoundsExceeded};
        /// # fn main() -> Result<(), VarIntBoundsExceeded> {
        /// let mut config = TransportConfig::default();
        ///
        /// // Set the idle timeout as `VarInt`-encoded milliseconds
        /// config.set_max_idle_timeout(VarInt::from(10_000u32).into());
        ///
        /// // Set the idle timeout as a `Duration`
        /// config.set_max_idle_timeout(Duration::from_secs(10).try_into()?);
        /// # Ok(())
        /// # }
        /// ```
        pub fn max_idle_timeout(mut self, value: Option<IdleTimeout>) -> Self {
            self.max_idle_timeout = value.map(|t| t.0);
            self
        }
    }

    /// The local idle timeout, [`Self::set_max_idle_timeout`]; `None` when disabled.
    #[must_use]
    pub fn get_max_idle_timeout(&self) -> Option<Duration> {
        self.max_idle_timeout
            .map(|millis| Duration::from_millis(millis.into_inner()))
    }

    rama_utils::macros::generate_set_and_with! {
        /// Maximum number of bytes the peer may transmit without acknowledgement on any one stream
        /// before becoming blocked.
        ///
        /// This should be set to at least the expected connection latency multiplied by the maximum
        /// desired throughput. Setting this smaller than `receive_window` helps ensure that a single
        /// stream doesn't monopolize receive buffers, which may otherwise occur if the application
        /// chooses not to read from a large stream for a time while still requiring data on other
        /// streams.
        pub fn stream_receive_window(mut self, value: impl Into<VarInt>) -> Self {
            self.stream_receive_window = value.into();
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// The receive window of bidirectional streams the peer opens, when different from
        /// [`Self::stream_receive_window`], which then applies to locally opened ones.
        pub fn stream_receive_window_bidi_remote(mut self, value: Option<VarInt>) -> Self {
            self.stream_receive_window_bidi_remote = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// The receive window of unidirectional streams, when different from
        /// [`Self::stream_receive_window`].
        pub fn stream_receive_window_uni(mut self, value: Option<VarInt>) -> Self {
            self.stream_receive_window_uni = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// The maximum number of peer-issued connection IDs retained at once.
        ///
        /// The value must be between 2 and
        /// [`MAX_ACTIVE_CONNECTION_ID_LIMIT`](crate::profile::MAX_ACTIVE_CONNECTION_ID_LIMIT);
        /// unsupported values are rejected without changing the configuration. `None` advertises 2 for
        /// zero-length local IDs and 5 otherwise. Receive processing enforces the
        /// advertised value independently of internal storage capacity.
        pub fn active_connection_id_limit(mut self, value: Option<VarInt>) -> Result<Self, ConfigError> {
            // RFC 9000 §18.2 requires at least two; the queue bounds storage.
            if value.is_some_and(|limit| !(2..=CidQueue::LIMIT).contains(&limit.into_inner())) {
                return Err(ConfigError::OutOfBounds);
            }
            self.active_connection_id_limit = value;
            Ok(self)
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// How long this endpoint may delay an acknowledgement, advertised as `max_ack_delay`
        /// and honoured by its ACK timer. Must be below 2^14 ms (RFC 9000 §18.2). Defaults to
        /// 25 ms.
        pub fn max_ack_delay(mut self, value: Duration) -> Result<Self, ConfigError> {
            if value.as_millis() >= 1 << 14 {
                return Err(ConfigError::OutOfBounds);
            }
            self.max_ack_delay = value;
            Ok(self)
        }
    }

    /// The wire profile a connection with this configuration follows.
    #[must_use]
    pub(crate) fn with_wire(mut self, wire: crate::profile::WireProfile) -> Self {
        self.wire = wire;
        self
    }

    rama_utils::macros::generate_set_and_with! {
        /// Maximum number of bytes the peer may transmit across all streams of a connection before
        /// becoming blocked.
        ///
        /// This should be set to at least the expected connection latency multiplied by the maximum
        /// desired throughput. Larger values can be useful to allow maximum throughput within a
        /// stream while another is blocked.
        pub fn receive_window(mut self, value: impl Into<VarInt>) -> Self {
            self.receive_window = value.into();
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Maximum number of bytes to transmit to a peer without acknowledgment
        ///
        /// Provides an upper bound on memory when communicating with peers that issue large amounts of
        /// flow control credit. Endpoints that wish to handle large numbers of connections robustly
        /// should take care to set this low enough to guarantee memory exhaustion does not occur if
        /// every connection uses the entire window.
        pub fn send_window(mut self, value: u64) -> Self {
            self.send_window = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Whether to implement fair queuing for send streams having the same priority.
        ///
        /// When enabled, connections schedule data from outgoing streams having the same priority in a
        /// round-robin fashion. When disabled, streams are scheduled in the order they are written to.
        ///
        /// Note that this only affects streams with the same priority. Higher priority streams always
        /// take precedence over lower priority streams.
        ///
        /// Disabling fairness can reduce fragmentation and protocol overhead for workloads that use
        /// many small streams.
        pub fn send_fairness(mut self, value: bool) -> Self {
            self.send_fairness = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Maximum reordering in packet number space before FACK style loss detection considers a
        /// packet lost. Should not be less than 3, per RFC5681.
        pub fn packet_threshold(mut self, value: u32) -> Self {
            self.packet_threshold = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Maximum reordering in time space before time based loss detection considers a packet lost,
        /// as a factor of RTT. Must be finite and nonnegative; the resulting duration is
        /// at least the timer granularity. Defaults to 9/8.
        pub fn time_threshold(mut self, value: f32) -> Result<Self, ConfigError> {
            if !value.is_finite() || value < 0.0 {
                return Err(ConfigError::OutOfBounds);
            }
            self.time_threshold = value;
            Ok(self)
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// The RTT used before an RTT sample is taken
        pub fn initial_rtt(mut self, value: Duration) -> Self {
            self.initial_rtt = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// The initial value to be used as the maximum UDP payload size before running MTU discovery
        /// (see [`TransportConfig::mtu_discovery_config`]).
        ///
        /// Must be at least 1200, which is the default, and known to be safe for typical internet
        /// applications. Larger values are more efficient, but increase the risk of packet loss due to
        /// exceeding the network path's IP MTU. If the provided value is higher than what the network
        /// path actually supports, packet loss will eventually trigger black hole detection and bring
        /// it down to [`TransportConfig::min_mtu`].
        pub fn initial_mtu(mut self, value: u16) -> Self {
            self.initial_mtu = value.max(INITIAL_MTU);
            self
        }
    }

    /// The maximum UDP payload size used before MTU discovery: [`Self::set_initial_mtu`],
    /// raised to [`Self::set_min_mtu`] when that is larger.
    #[must_use]
    pub fn get_initial_mtu(&self) -> u16 {
        self.initial_mtu.max(self.min_mtu)
    }

    rama_utils::macros::generate_set_and_with! {
        /// The maximum UDP payload size guaranteed to be supported by the network.
        ///
        /// Must be at least 1200, which is the default, and lower than or equal to
        /// [`TransportConfig::set_initial_mtu`].
        ///
        /// Real-world MTUs can vary according to ISP, VPN, and properties of intermediate network links
        /// outside of either endpoint's control. Extreme care should be used when raising this value
        /// outside of private networks where these factors are fully controlled. If the provided value
        /// is higher than what the network path actually supports, the result will be unpredictable and
        /// catastrophic packet loss, without a possibility of repair. Prefer
        /// [`TransportConfig::set_initial_mtu`] together with
        /// [`TransportConfig::mtu_discovery_config`] to set a maximum UDP payload size that robustly
        /// adapts to the network.
        pub fn min_mtu(mut self, value: u16) -> Self {
            self.min_mtu = value.max(INITIAL_MTU);
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Specifies the MTU discovery config (see [`MtuDiscoveryConfig`] for details).
        ///
        /// Enabled by default.
        pub fn mtu_discovery_config(mut self, value: Option<MtuDiscoveryConfig>) -> Self {
            self.mtu_discovery_config = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Pad UDP datagrams carrying application data to current maximum UDP payload size
        ///
        /// Disabled by default. UDP datagrams containing loss probes are exempt from padding.
        ///
        /// Enabling this helps mitigate traffic analysis by network observers, but it increases
        /// bandwidth usage. Without this mitigation precise plain text size of application datagrams as
        /// well as the total size of stream write bursts can be inferred by observers under certain
        /// conditions. This analysis requires either an uncongested connection or application datagrams
        /// too large to be coalesced.
        pub fn pad_to_mtu(mut self, value: bool) -> Self {
            self.pad_to_mtu = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Specifies the ACK frequency config (see [`AckFrequencyConfig`] for details)
        ///
        /// The provided configuration will be ignored if the peer does not support the acknowledgement
        /// frequency QUIC extension.
        ///
        /// Defaults to `None`, which disables controlling the peer's acknowledgement frequency. Even
        /// if set to `None`, the local side still supports the acknowledgement frequency QUIC
        /// extension and may use it in other ways.
        pub fn ack_frequency_config(mut self, value: Option<AckFrequencyConfig>) -> Self {
            self.ack_frequency_config = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Number of consecutive PTOs after which network is considered to be experiencing persistent congestion.
        pub fn persistent_congestion_threshold(mut self, value: u32) -> Self {
            self.persistent_congestion_threshold = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Period of inactivity before sending a keep-alive packet
        ///
        /// Keep-alive packets prevent an inactive but otherwise healthy connection from timing out.
        ///
        /// `None` to disable, which is the default. Only one side of any given connection needs keep-alive
        /// enabled for the connection to be preserved. Must be set lower than the idle_timeout of both
        /// peers to be effective.
        pub fn keep_alive_interval(mut self, value: Option<Duration>) -> Self {
            self.keep_alive_interval = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Maximum quantity of out-of-order crypto layer data to buffer
        pub fn crypto_buffer_size(mut self, value: usize) -> Self {
            self.crypto_buffer_size = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Maximum number of packets held during the handshake because their keys are not
        /// available yet (default: 32), processed once they are (RFC 9001 §4.1.4).
        ///
        /// Reordering or loss can deliver the peer's Handshake or 1-RTT packets, or a client's
        /// 0-RTT packets, before the packet whose keys open them. Holding them saves waiting
        /// for the peer to resend. Zero disables holding; such packets are then dropped.
        pub fn early_packet_buffer_packets(mut self, value: usize) -> Self {
            self.early_packet_buffer_packets = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Maximum number of bytes held for packets that wait on their keys during the
        /// handshake (default: 64 KiB), see
        /// [`early_packet_buffer_packets`](Self::early_packet_buffer_packets).
        /// Zero disables holding.
        pub fn early_packet_buffer_size(mut self, value: usize) -> Self {
            self.early_packet_buffer_size = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Permit passive latency spin signaling (default: true).
        ///
        /// Permission does not guarantee activation: each endpoint independently suppresses
        /// signaling on a random one in eight connections. That choice lasts for the whole
        /// connection, including CID rotation and migration. Set this to false on either role
        /// to opt out administratively. Disabled endpoints ignore received spin values and
        /// choose an independent random bit for each outgoing 1-RTT packet.
        ///
        /// Enabled signaling reflects (server) or inverts (client) newer authenticated 1-RTT
        /// packets on each path. It lets passive observers estimate RTT, with limits under
        /// loss, reordering and idle periods. A constant or random bit does not indicate a
        /// failed connection and does not disable the endpoint's own ACK-based RTT estimates.
        /// Separately terminated relay hops have independent policies and signals.
        /// See [RFC 9000 §17.4](https://www.rfc-editor.org/rfc/rfc9000.html#section-17.4).
        pub fn allow_spin(mut self, value: bool) -> Self {
            self.allow_spin = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Whether the first key update comes early, after a random 10 to 999 packets, so a
        /// peer that mishandles key updates fails fast (default: true). Without it the first
        /// update waits for the confidentiality limit, like every later one.
        ///
        /// For interop test fixtures only: a peer with a known key-update bug (quic-go on
        /// QUIC v2) would otherwise fail at a random point. Production keeps the default.
        #[doc(hidden)]
        pub fn early_key_update(mut self, value: bool) -> Self {
            self.early_key_update = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Maximum number of incoming application datagram bytes to buffer, or None to disable
        /// incoming datagrams
        ///
        /// Without a profile override, this also bounds the encoded frame size advertised
        /// to the peer (capped at 65535). A profile can advertise a different frame limit;
        /// this budget then controls retention only. If the aggregate size
        /// of all datagrams that have been received from the peer but not consumed by the application
        /// exceeds this value, old datagrams are dropped until it is no longer exceeded.
        ///
        /// The amount of payload data buffered may be smaller than `value` due to overhead.
        pub fn datagram_receive_buffer_size(mut self, value: Option<usize>) -> Self {
            self.datagram_receive_buffer_size = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Maximum number of outgoing application datagram bytes to buffer
        ///
        /// While datagrams are sent ASAP, it is possible for an application to generate data faster
        /// than the link, or even the underlying hardware, can transmit them. This limits the amount of
        /// memory that may be consumed in that case. When the send buffer is full and a new datagram is
        /// sent, older datagrams are dropped until sufficient space is available.
        ///
        /// The amount of payload data buffered may be smaller than `value` due to overhead.
        pub fn datagram_send_buffer_size(mut self, value: usize) -> Self {
            self.datagram_send_buffer_size = value;
            self
        }
    }

    /// Whether to force every packet number to be used
    ///
    /// By default, packet numbers are occasionally skipped to ensure peers aren't ACKing packets
    /// before they see them.
    #[cfg(test)]
    pub(crate) fn deterministic_packet_numbers(&mut self, enabled: bool) -> &mut Self {
        self.deterministic_packet_numbers = enabled;
        self
    }

    rama_utils::macros::generate_set_and_with! {
        /// Which congestion controller connections use.
        ///
        /// Defaults to [`CongestionControl::Cubic`].
        pub fn congestion_control(mut self, value: CongestionControl) -> Self {
            self.congestion_control = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Limit on the data in flight before the first acknowledgement, in bytes.
        ///
        /// `None`, the default, leaves each controller the window it computes from the
        /// 1200-byte datagram size QUIC guarantees (RFC 9000 §14.1), not from the configured
        /// MTU: CUBIC and NewReno start from the value RFC 9002 §7.2 recommends for that size,
        /// and BBR starts higher.
        ///
        /// Fails below [`MIN_INITIAL_CONGESTION_WINDOW`], which includes zero.
        pub fn initial_congestion_window(mut self, value: Option<u64>) -> Result<Self, ConfigError> {
            if let Some(window) = value
                && window < MIN_INITIAL_CONGESTION_WINDOW
            {
                return Err(ConfigError::OutOfBounds);
            }
            self.initial_congestion_window = value;
            Ok(self)
        }
    }

    /// The controller factory the current settings describe.
    pub(crate) fn congestion_factory(
        &self,
    ) -> Arc<dyn congestion::ControllerFactory + Send + Sync + 'static> {
        let window = self.initial_congestion_window;
        match self.congestion_control {
            CongestionControl::Cubic => {
                let mut config = congestion::CubicConfig::default();
                if let Some(window) = window {
                    config.initial_window(window);
                }
                Arc::new(config)
            }
            CongestionControl::NewReno => {
                let mut config = congestion::NewRenoConfig::default();
                if let Some(window) = window {
                    config.initial_window(window);
                }
                Arc::new(config)
            }
            CongestionControl::Bbr => {
                let mut config = congestion::BbrConfig::default();
                if let Some(window) = window {
                    config.initial_window(window);
                }
                Arc::new(config)
            }
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Whether to use "Generic Segmentation Offload" to accelerate transmits, when supported by the
        /// environment
        ///
        /// Defaults to `true`.
        ///
        /// GSO dramatically reduces CPU consumption when sending large numbers of packets with the same
        /// headers, such as when transmitting bulk data on a connection. However, it is not supported
        /// by all network interface drivers or packet inspection tools. The UDP layer will attempt to
        /// disable GSO automatically when unavailable, but this can lead to spurious packet loss at
        /// startup, temporarily degrading performance.
        pub fn enable_segmentation_offload(mut self, enabled: bool) -> Self {
            self.enable_segmentation_offload = enabled;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Attach an explicitly started recorder. Call `QlogConfig::start` first to handle
        /// configuration/runtime errors. Replaces the previously configured sink.
        /// Retain a handle to inspect failures, trigger history, or await completion.
        pub fn qlog_recorder(mut self, recorder: Option<crate::qlog::QlogRecorder>) -> Self {
            self.qlog_sink = recorder.into();
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Observe borrowed events inline. Sink callbacks run inside the transport
        /// state machine and must be cheap and nonblocking. Use `qlog_recorder` for background
        /// output, or compose a recorder with a lightweight sink as `(recorder, sink)`.
        /// Replaces the previously configured sink; `unset_qlog_sink` detaches diagnostics.
        pub fn qlog_sink(mut self, sink: Option<Arc<dyn crate::qlog::QlogSink>>) -> Self {
            self.qlog_sink = ConnectionQlog::from_sink(sink);
            self
        }
    }
}

impl Default for TransportConfig {
    fn default() -> Self {
        const EXPECTED_RTT: u32 = 100; // ms
        const MAX_STREAM_BANDWIDTH: u32 = 12500 * 1000; // bytes/s
        // Window size needed to avoid pipeline
        // stalls
        const STREAM_RWND: u32 = MAX_STREAM_BANDWIDTH / 1000 * EXPECTED_RTT;

        Self {
            max_concurrent_bidi_streams: 100u32.into(),
            max_concurrent_uni_streams: 100u32.into(),
            // 30 second default recommended by RFC 9308 § 3.2
            max_idle_timeout: Some(VarInt::from_u32(30_000)),
            stream_receive_window: STREAM_RWND.into(),
            stream_receive_window_bidi_remote: None,
            stream_receive_window_uni: None,
            receive_window: VarInt::MAX,
            active_connection_id_limit: None,
            max_ack_delay: Duration::from_millis(25),
            wire: crate::profile::WireProfile::default(),
            send_window: (8 * STREAM_RWND).into(),
            send_fairness: true,

            packet_threshold: 3,
            time_threshold: 9.0 / 8.0,
            initial_rtt: Duration::from_millis(333), // per spec, intentionally distinct from EXPECTED_RTT
            initial_mtu: INITIAL_MTU,
            min_mtu: INITIAL_MTU,
            mtu_discovery_config: Some(MtuDiscoveryConfig::default()),
            pad_to_mtu: false,
            ack_frequency_config: None,

            persistent_congestion_threshold: 3,
            keep_alive_interval: None,
            crypto_buffer_size: octets::kib(16),
            early_packet_buffer_packets: 32,
            early_packet_buffer_size: octets::kib(64),
            allow_spin: true,
            early_key_update: true,
            datagram_receive_buffer_size: Some(STREAM_RWND as usize),
            datagram_send_buffer_size: octets::mib(1),
            #[cfg(test)]
            deterministic_packet_numbers: false,

            congestion_control: CongestionControl::default(),
            initial_congestion_window: None,

            enable_segmentation_offload: true,

            qlog_sink: ConnectionQlog::default(),
        }
    }
}

impl fmt::Debug for TransportConfig {
    fn fmt(&self, fmt: &mut fmt::Formatter<'_>) -> fmt::Result {
        let Self {
            max_concurrent_bidi_streams,
            max_concurrent_uni_streams,
            max_idle_timeout,
            stream_receive_window,
            stream_receive_window_bidi_remote,
            stream_receive_window_uni,
            receive_window,
            active_connection_id_limit,
            max_ack_delay,
            wire,
            send_window,
            send_fairness,
            packet_threshold,
            time_threshold,
            initial_rtt,
            initial_mtu,
            min_mtu,
            mtu_discovery_config,
            pad_to_mtu,
            ack_frequency_config,
            persistent_congestion_threshold,
            keep_alive_interval,
            crypto_buffer_size,
            early_packet_buffer_packets,
            early_packet_buffer_size,
            allow_spin,
            early_key_update,
            datagram_receive_buffer_size,
            datagram_send_buffer_size,
            #[cfg(test)]
                deterministic_packet_numbers: _,
            congestion_control,
            initial_congestion_window,
            enable_segmentation_offload,
            qlog_sink,
        } = self;
        let mut s = fmt.debug_struct("TransportConfig");

        s.field("max_concurrent_bidi_streams", max_concurrent_bidi_streams)
            .field("max_concurrent_uni_streams", max_concurrent_uni_streams)
            .field("max_idle_timeout", max_idle_timeout)
            .field("stream_receive_window", stream_receive_window)
            .field(
                "stream_receive_window_bidi_remote",
                stream_receive_window_bidi_remote,
            )
            .field("stream_receive_window_uni", stream_receive_window_uni)
            .field("active_connection_id_limit", active_connection_id_limit)
            .field("max_ack_delay", max_ack_delay)
            .field("wire", wire)
            .field("receive_window", receive_window)
            .field("send_window", send_window)
            .field("send_fairness", send_fairness)
            .field("packet_threshold", packet_threshold)
            .field("time_threshold", time_threshold)
            .field("initial_rtt", initial_rtt)
            .field("initial_mtu", initial_mtu)
            .field("min_mtu", min_mtu)
            .field("mtu_discovery_config", mtu_discovery_config)
            .field("pad_to_mtu", pad_to_mtu)
            .field("ack_frequency_config", ack_frequency_config)
            .field(
                "persistent_congestion_threshold",
                persistent_congestion_threshold,
            )
            .field("keep_alive_interval", keep_alive_interval)
            .field("crypto_buffer_size", crypto_buffer_size)
            .field("early_packet_buffer_packets", early_packet_buffer_packets)
            .field("early_packet_buffer_size", early_packet_buffer_size)
            .field("allow_spin", allow_spin)
            .field("early_key_update", early_key_update)
            .field("datagram_receive_buffer_size", datagram_receive_buffer_size)
            .field("datagram_send_buffer_size", datagram_send_buffer_size)
            .field("congestion_control", congestion_control)
            .field("initial_congestion_window", initial_congestion_window)
            .field("enable_segmentation_offload", enable_segmentation_offload);
        s.field("qlog_stream", &qlog_sink.is_enabled());

        s.finish_non_exhaustive()
    }
}

/// Parameters for controlling the peer's acknowledgement frequency
///
/// The parameters provided in this config will be sent to the peer at the beginning of the
/// connection, so it can take them into account when sending acknowledgements (see each parameter's
/// description for details on how it influences acknowledgement frequency).
///
/// This implementation follows the fourth draft of the
/// [QUIC Acknowledgement Frequency extension](https://datatracker.ietf.org/doc/html/draft-ietf-quic-ack-frequency-04).
/// The defaults produce behavior slightly different than the behavior without this extension,
/// because they change the way reordered packets are handled (see
/// [`AckFrequencyConfig::set_reordering_threshold`] for details).
#[derive(Clone, Debug)]
pub struct AckFrequencyConfig {
    pub(crate) ack_eliciting_threshold: VarInt,
    pub(crate) max_ack_delay: Option<Duration>,
    pub(crate) reordering_threshold: VarInt,
}

impl AckFrequencyConfig {
    rama_utils::macros::generate_set_and_with! {
        /// The ack-eliciting threshold we will request the peer to use
        ///
        /// This threshold represents the number of ack-eliciting packets an endpoint may receive
        /// without immediately sending an ACK.
        ///
        /// The remote peer should send at least one ACK frame when more than this number of
        /// ack-eliciting packets have been received. A value of 0 results in a receiver immediately
        /// acknowledging every ack-eliciting packet.
        ///
        /// Defaults to 1, which sends ACK frames for every other ack-eliciting packet.
        pub fn ack_eliciting_threshold(mut self, value: impl Into<VarInt>) -> Self {
            self.ack_eliciting_threshold = value.into();
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// The `max_ack_delay` we will request the peer to use
        ///
        /// This parameter represents the maximum amount of time that an endpoint waits before sending
        /// an ACK when the ack-eliciting threshold hasn't been reached.
        ///
        /// The effective `max_ack_delay` will be clamped to be at least the peer's `min_ack_delay`
        /// transport parameter, and at most the greater of the current path RTT or 25ms.
        ///
        /// Defaults to `None`, in which case the peer's original `max_ack_delay` will be used, as
        /// obtained from its transport parameters.
        pub fn max_ack_delay(mut self, value: Option<Duration>) -> Self {
            self.max_ack_delay = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// The reordering threshold we will request the peer to use
        ///
        /// This threshold represents the amount of out-of-order packets that will trigger an endpoint
        /// to send an ACK, without waiting for `ack_eliciting_threshold` to be exceeded or for
        /// `max_ack_delay` to be elapsed.
        ///
        /// A value of 0 indicates out-of-order packets do not elicit an immediate ACK. A value of 1
        /// immediately acknowledges any packets that are received out of order (this is also the
        /// behavior when the extension is disabled).
        ///
        /// It is recommended to set this value to [`TransportConfig::packet_threshold`] minus one.
        /// Since the default value for [`TransportConfig::packet_threshold`] is 3, this value defaults
        /// to 2.
        pub fn reordering_threshold(mut self, value: impl Into<VarInt>) -> Self {
            self.reordering_threshold = value.into();
            self
        }
    }
}

impl Default for AckFrequencyConfig {
    fn default() -> Self {
        Self {
            ack_eliciting_threshold: VarInt::from_u32(1),
            max_ack_delay: None,
            reordering_threshold: VarInt::from_u32(2),
        }
    }
}

/// Parameters governing MTU discovery.
///
/// # The why of MTU discovery
///
/// By design, QUIC ensures during the handshake that the network path between the client and the
/// server is able to transmit unfragmented UDP packets with a body of 1200 bytes. In other words,
/// once the connection is established, we know that the network path's maximum transmission unit
/// (MTU) is of at least 1200 bytes (plus IP and UDP headers). Because of this, a QUIC endpoint can
/// split outgoing data in packets of 1200 bytes, with confidence that the network will be able to
/// deliver them (if the endpoint were to send bigger packets, they could prove too big and end up
/// being dropped).
///
/// There is, however, a significant overhead associated to sending a packet. If the same
/// information can be sent in fewer packets, that results in higher throughput. The amount of
/// packets that need to be sent is inversely proportional to the MTU: the higher the MTU, the
/// bigger the packets that can be sent, and the fewer packets that are needed to transmit a given
/// amount of bytes.
///
/// Most networks have an MTU higher than 1200. Through MTU discovery, endpoints can detect the
/// path's MTU and, if it turns out to be higher, start sending bigger packets.
///
/// # MTU discovery internals
///
/// MTU discovery is implemented through DPLPMTUD (Datagram Packetization Layer Path MTU
/// Discovery), described in [section 14.3 of RFC
/// 9000](https://www.rfc-editor.org/rfc/rfc9000.html#section-14.3). This method consists of sending
/// QUIC packets padded to a particular size (called PMTU probes), and waiting to see if the remote
/// peer responds with an ACK. If an ACK is received, that means the probe arrived at the remote
/// peer, which in turn means that the network path's MTU is of at least the packet's size. If the
/// probe is lost, it is sent another 2 times before concluding that the MTU is lower than the
/// packet's size.
///
/// MTU discovery runs on a schedule (e.g. every 600 seconds) specified through
/// [`MtuDiscoveryConfig::set_interval`]. The first run happens right after the handshake, and
/// subsequent discoveries are scheduled to run when the interval has elapsed, starting from the
/// last time when MTU discovery completed.
///
/// Since the search space for MTUs is quite big (the smallest possible MTU is 1200, and the highest
/// is 65527), the discovery performs a binary search to keep the number of probes as low as possible. The
/// lower bound of the search is equal to [`TransportConfig::set_initial_mtu`] in the
/// initial MTU discovery run, and is equal to the currently discovered MTU in subsequent runs. The
/// upper bound is determined by the minimum of [`MtuDiscoveryConfig::set_upper_bound`] and the
/// `max_udp_payload_size` transport parameter received from the peer during the handshake.
///
/// # Black hole detection
///
/// If, at some point, the network path no longer accepts packets of the detected size, packet loss
/// will eventually trigger black hole detection and reset the detected MTU to 1200. In that case,
/// MTU discovery will be triggered after [`MtuDiscoveryConfig::set_black_hole_cooldown`] (ignoring the
/// timer that was set based on [`MtuDiscoveryConfig::set_interval`]).
///
/// # Interaction between peers
///
/// There is no guarantee that the MTU on the path between A and B is the same as the MTU of the
/// path between B and A. Therefore, each peer in the connection needs to run MTU discovery
/// independently in order to discover the path's MTU.
#[derive(Clone, Debug)]
pub struct MtuDiscoveryConfig {
    pub(crate) interval: Duration,
    pub(crate) upper_bound: u16,
    pub(crate) minimum_change: u16,
    pub(crate) black_hole_cooldown: Duration,
}

impl MtuDiscoveryConfig {
    rama_utils::macros::generate_set_and_with! {
        /// Specifies the time to wait after completing MTU discovery before starting a new MTU
        /// discovery run.
        ///
        /// Defaults to 600 seconds, as recommended by [RFC
        /// 8899](https://www.rfc-editor.org/rfc/rfc8899).
        pub fn interval(mut self, value: Duration) -> Self {
            self.interval = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Specifies the upper bound to the max UDP payload size that MTU discovery will search for.
        ///
        /// Defaults to 1452, to stay within Ethernet's MTU when using IPv4 and IPv6. The highest
        /// allowed value is 65527, which corresponds to the maximum permitted UDP payload on IPv6.
        ///
        /// It is safe to use an arbitrarily high upper bound, regardless of the network path's MTU. The
        /// only drawback is that MTU discovery might take more time to finish.
        pub fn upper_bound(mut self, value: u16) -> Self {
            self.upper_bound = value.min(MAX_UDP_PAYLOAD);
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Specifies the amount of time that MTU discovery should wait after a black hole was detected
        /// before running again. Defaults to one minute.
        ///
        /// Black hole detection can be spuriously triggered in case of congestion, so it makes sense to
        /// try MTU discovery again after a short period of time.
        pub fn black_hole_cooldown(mut self, value: Duration) -> Self {
            self.black_hole_cooldown = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Specifies the minimum MTU change to stop the MTU discovery phase.
        /// Defaults to 20.
        pub fn minimum_change(mut self, value: u16) -> Self {
            self.minimum_change = value;
            self
        }
    }
}

impl Default for MtuDiscoveryConfig {
    fn default() -> Self {
        Self {
            interval: Duration::from_secs(600),
            upper_bound: 1452,
            black_hole_cooldown: Duration::from_secs(60),
            minimum_change: 20,
        }
    }
}

/// Maximum duration of inactivity to accept before timing out the connection
///
/// This wraps an underlying [`VarInt`], representing the duration in milliseconds. Values can be
/// constructed by converting directly from `VarInt`, or using `TryFrom<Duration>`.
///
/// ```
/// # use std::{convert::TryFrom, time::Duration};
/// # use rama_quic::IdleTimeout;
/// # use rama_quic_proto::{VarInt, VarIntBoundsExceeded};
/// # fn main() -> Result<(), VarIntBoundsExceeded> {
/// // A `VarInt`-encoded value in milliseconds
/// let timeout = IdleTimeout::from(VarInt::from(10_000u32));
///
/// // Try to convert a `Duration` into a `VarInt`-encoded timeout
/// let timeout = IdleTimeout::try_from(Duration::from_secs(10))?;
/// # Ok(())
/// # }
/// ```
#[derive(Default, Copy, Clone, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct IdleTimeout(VarInt);

impl From<VarInt> for IdleTimeout {
    fn from(inner: VarInt) -> Self {
        Self(inner)
    }
}

impl std::convert::TryFrom<Duration> for IdleTimeout {
    type Error = VarIntBoundsExceeded;

    fn try_from(timeout: Duration) -> Result<Self, Self::Error> {
        let inner = VarInt::try_from(timeout.as_millis())?;
        Ok(Self(inner))
    }
}

impl fmt::Debug for IdleTimeout {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

#[cfg(test)]
#[test]
fn active_cid_limit_rejects_unsupported_configuration_atomically() {
    let mut config = TransportConfig::default();
    config
        .try_set_active_connection_id_limit(VarInt::from_u32(4))
        .unwrap();
    for value in [0, 1, CidQueue::LIMIT + 1, VarInt::MAX.into_inner()] {
        let result = config.try_set_active_connection_id_limit(VarInt::from_u64(value).unwrap());
        assert!(matches!(result, Err(ConfigError::OutOfBounds)));
        assert_eq!(config.active_connection_id_limit, Some(VarInt::from_u32(4)));
    }
    for value in [2, CidQueue::LIMIT] {
        config
            .try_set_active_connection_id_limit(VarInt::from_u64(value).unwrap())
            .unwrap();
        assert_eq!(
            config.active_connection_id_limit.unwrap().into_inner(),
            value
        );
    }
    config.try_unset_active_connection_id_limit().unwrap();
    assert_eq!(config.active_connection_id_limit, None);
}
