use std::{cmp, net::SocketAddr};

use rama_core::telemetry::tracing::trace;
use rama_quic_proto::{ConnectionId, packet::SpaceId};

use super::{
    mtud::MtuDiscovery,
    pacing::Pacer,
    qlog::event::RecoveryMetricsUpdated,
    spaces::{PacketSpace, SentPacket},
};
use crate::proto::{
    Duration, Instant, MIN_INITIAL_SIZE, TIMER_GRANULARITY, TransportConfig, congestion,
};

/// Description of a particular network path
pub(super) struct PathData {
    pub(super) remote: SocketAddr,
    /// The local socket address (ip and port) this path's packets arrive on and leave from, when
    /// known; an endpoint with several sockets keeps each path on its own.
    pub(super) local: Option<SocketAddr>,
    /// The destination connection ID the peer last used on this path (our local CID), which
    /// tells a NAT rebinding (same ID from a new address) from a deliberate move.
    pub(super) received_dcid: Option<ConnectionId>,
    pub(super) rtt: RttEstimator,
    /// Whether we're enabling ECN on outgoing packets
    pub(super) sending_ecn: bool,
    /// Congestion controller state
    pub(super) congestion: Box<dyn congestion::Controller>,
    /// Pacing state
    pub(super) pacing: Pacer,
    /// The validation this side has outstanding on this path, if any.
    pub(super) challenge: Option<Challenge>,
    /// Whether we're certain the peer can both send and receive on this address
    ///
    /// Initially equal to `use_stateless_retry` for servers, and becomes false again on every
    /// migration. Always true for clients.
    pub(super) validated: bool,
    /// Expanded validations attempted on this path, bounding how long a path whose address
    /// answers keeps spending full-size datagrams on proving its minimum MTU.
    pub(super) mtu_validations: u8,
    /// Whether this path is known to carry a datagram of [`MIN_INITIAL_SIZE`].
    ///
    /// Separate from `validated`: an address validated by an undersized challenge says
    /// nothing about the path's minimum MTU (RFC 9000 §8.2.3). MTU discovery waits on this.
    pub(super) mtu_validated: bool,
    /// Total size of all UDP datagrams sent on this path
    pub(super) total_sent: u64,
    /// Total size of all UDP datagrams received on this path
    pub(super) total_recvd: u64,
    /// The state of the MTU discovery process
    pub(super) mtud: MtuDiscovery,
    /// Packet number of the first packet sent after an RTT sample was collected on this path
    ///
    /// Used in persistent congestion determination.
    pub(super) first_packet_after_rtt_sample: Option<(SpaceId, u64)>,
    pub(super) in_flight: InFlight,
    /// Number of the first packet sent on this path
    ///
    /// Used to determine whether a packet was sent on an earlier path. Insufficient to determine if
    /// a packet was sent on a later path.
    first_packet: Option<u64>,

    /// Snapshot allocated on the first recorded recovery event.
    qlog_recording_generation: (u64, u64),
    recovery_metrics: Option<Box<RecoveryMetrics>>,

    /// Tag uniquely identifying a path in a connection
    generation: u64,
}

/// A path validation this side is waiting on (RFC 9000 §8.2).
///
/// A response names only the token, never which transmission of it answered. So what a token
/// can prove is decided by the first datagram that carried it and never revised, and a token
/// whose first datagram was expanded is never written into a smaller one afterwards — either
/// direction of that aliasing would certify an MTU the path has not shown.
///
/// The fields are private: `Proves`, the optional size and the pending flag admit
/// combinations the sender must not produce, so they are reached through the operations
/// below rather than set directly.
#[derive(Debug, Clone, Copy)]
pub(super) struct Challenge {
    token: u64,
    proves: Proves,
    sent: Option<Sent>,
    generation: u64,
    pending: bool,
    retry_at: Option<Instant>,
    attempts: u8,
}

/// What answering a token would establish.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Proves {
    /// That the peer is at this address, and its minimum MTU too when the datagram that
    /// carried the token reached [`MIN_INITIAL_SIZE`].
    Address,
    /// The minimum MTU, after an undersized challenge already proved the address
    /// (RFC 9000 §8.2.3).
    Mtu,
}

/// How large the first datagram carrying a token turned out to be.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Sent {
    /// Under [`MIN_INITIAL_SIZE`], because the anti-amplification limit did not allow more
    /// (RFC 9000 §8.2.1). A response proves the address and not the path's MTU.
    Undersized,
    /// [`MIN_INITIAL_SIZE`] or more, so a response proves both.
    Expanded,
}

impl Challenge {
    /// A first validation of a path, which proves its MTU too when the limit leaves room to
    /// expand the datagram.
    pub(super) fn of_address(token: u64, generation: u64) -> Self {
        Self {
            token,
            proves: Proves::Address,
            sent: None,
            generation,
            pending: true,
            retry_at: None,
            attempts: 0,
        }
    }

    /// The second validation RFC 9000 §8.2.3 requires once an undersized challenge has proved
    /// the address. Its token is fresh, so no earlier response can answer it.
    pub(super) fn of_mtu(token: u64, generation: u64) -> Self {
        Self {
            proves: Proves::Mtu,
            ..Self::of_address(token, generation)
        }
    }

    pub(super) fn token(&self) -> u64 {
        self.token
    }

    /// Whether a packet may still go out for the sole purpose of carrying this.
    pub(super) fn pending(&self) -> bool {
        self.pending
    }

    /// Whether this validation is the one that has to prove the minimum MTU.
    pub(super) fn is_for_mtu(&self) -> bool {
        self.proves == Proves::Mtu
    }

    /// Whether this token may go into a datagram that `expands` to [`MIN_INITIAL_SIZE`],
    /// or not.
    ///
    /// A token that is out to prove the MTU is only ever sent expanded, and so is one whose
    /// first datagram already was: a smaller copy of it could be the one a response answers,
    /// and the response could not say which.
    pub(super) fn may_go_in(&self, expands: bool) -> bool {
        expands || !(self.proves == Proves::Mtu || self.sent == Some(Sent::Expanded))
    }

    /// Whether a response to this token proves the path carries [`MIN_INITIAL_SIZE`].
    pub(super) fn proves_mtu(&self) -> bool {
        self.sent == Some(Sent::Expanded)
    }

    /// Whether a response naming `token` on a path at `generation` answers this validation.
    ///
    /// A token nothing has sent answers nothing, and one from a path the connection has since
    /// left validates nothing on the path that replaced it.
    pub(super) fn is_answered_by(&self, token: u64, generation: u64) -> bool {
        self.token == token && self.sent.is_some() && self.generation == generation
    }

    /// Note that a packet carrying this token has gone into the buffer, so no further packet
    /// is owed for that purpose alone.
    pub(super) fn written(&mut self, now: Instant, retry_after: Duration) {
        self.pending = false;
        self.attempts += 1;
        // The validation deadline is fixed when the path changes. ACKs may
        // shorten its RTT meanwhile, but must not create an unbounded train of
        // challenges before that deadline.
        self.retry_at = (self.attempts < 3)
            .then(|| now.checked_add(retry_after))
            .flatten();
    }

    pub(super) fn retry_at(&self) -> Option<Instant> {
        self.retry_at
    }

    pub(super) fn rearm(&mut self, now: Instant) {
        if self.retry_at.is_some_and(|at| at <= now) {
            self.retry_at = None;
            self.pending = true;
        }
    }

    /// Record how large the first datagram carrying this token turned out.
    ///
    /// Only the first counts, which is what makes the evidence stable across retransmission.
    pub(super) fn note_sent(&mut self, bytes: usize) {
        if self.sent.is_none() {
            self.sent = Some(match bytes >= usize::from(MIN_INITIAL_SIZE) {
                true => Sent::Expanded,
                false => Sent::Undersized,
            });
        }
    }
}

impl PathData {
    pub(super) fn new(
        remote: SocketAddr,
        local: Option<SocketAddr>,
        allow_mtud: bool,
        peer_max_udp_payload_size: Option<u16>,
        generation: u64,
        now: Instant,
        config: &TransportConfig,
    ) -> Self {
        let congestion = config
            .congestion_factory()
            .build(now, config.get_initial_mtu());
        Self {
            remote,
            local,
            received_dcid: None,
            rtt: RttEstimator::new(config.initial_rtt),
            sending_ecn: true,
            pacing: Pacer::starting(
                config.initial_rtt,
                congestion.initial_window(),
                config.get_initial_mtu(),
                now,
            ),
            congestion,
            challenge: None,
            validated: false,
            mtu_validations: 0,
            mtu_validated: false,
            total_sent: 0,
            total_recvd: 0,
            mtud: config
                .mtu_discovery_config
                .as_ref()
                .filter(|_| allow_mtud)
                .map_or(
                    MtuDiscovery::disabled(config.get_initial_mtu(), config.min_mtu),
                    |mtud_config| {
                        MtuDiscovery::new(
                            config.get_initial_mtu(),
                            config.min_mtu,
                            peer_max_udp_payload_size,
                            mtud_config.clone(),
                        )
                    },
                ),
            first_packet_after_rtt_sample: None,
            in_flight: InFlight::new(),
            first_packet: None,
            qlog_recording_generation: (0, 0),
            recovery_metrics: None,
            generation,
        }
    }

    pub(super) fn from_previous(
        remote: SocketAddr,
        local: Option<SocketAddr>,
        prev: &Self,
        generation: u64,
        now: Instant,
    ) -> Self {
        let congestion = prev.congestion.clone_box();
        let smoothed_rtt = prev.rtt.get();
        let mut mtud = prev.mtud.clone();
        mtud.reset_for_new_path();
        Self {
            remote,
            local,
            received_dcid: None,
            rtt: prev.rtt,
            pacing: Pacer::new(smoothed_rtt, congestion.window(), prev.current_mtu(), now),
            sending_ecn: true,
            congestion,
            challenge: None,
            validated: false,
            mtu_validations: 0,
            mtu_validated: false,
            total_sent: 0,
            total_recvd: 0,
            mtud,
            first_packet_after_rtt_sample: prev.first_packet_after_rtt_sample,
            in_flight: InFlight::new(),
            first_packet: None,
            qlog_recording_generation: prev.qlog_recording_generation,
            recovery_metrics: prev.recovery_metrics.clone(),
            generation,
        }
    }

    /// Resets RTT, congestion control and MTU states.
    ///
    /// This is useful when it is known the underlying path has changed.
    pub(super) fn reset(&mut self, now: Instant, config: &TransportConfig) {
        self.rtt = RttEstimator::new(config.initial_rtt);
        self.congestion = config
            .congestion_factory()
            .build(now, config.get_initial_mtu());
        self.mtud.reset(config.get_initial_mtu(), config.min_mtu);
        // A budget spent on the old path would hold back the first sends on the new one.
        self.pacing = Pacer::starting(
            self.rtt.get(),
            self.congestion.initial_window(),
            self.current_mtu(),
            now,
        );
    }

    /// Indicates whether we're a server that hasn't validated the peer's address and hasn't
    /// received enough data from the peer to permit sending `bytes_to_send` additional bytes
    pub(super) fn anti_amplification_blocked(&self, bytes_to_send: u64) -> bool {
        self.anti_amplification_remaining()
            .is_some_and(|remaining| remaining < bytes_to_send)
    }

    /// Bytes that may still go towards an address this side has not validated, or `None` when
    /// the address is validated and nothing bounds what may be sent to it (RFC 9000 §8).
    pub(super) fn anti_amplification_remaining(&self) -> Option<u64> {
        (!self.validated).then(|| {
            self.total_recvd
                .saturating_mul(3)
                .saturating_sub(self.total_sent)
        })
    }

    /// Returns the path's current MTU
    pub(super) fn current_mtu(&self) -> u16 {
        self.mtud.current_mtu()
    }

    /// The largest UDP payload this path may carry, which an MTU probe may reach and no
    /// datagram may exceed.
    #[cfg(test)]
    pub(super) fn max_payload(&self) -> u16 {
        self.mtud.max_payload()
    }

    /// Account for transmission of `packet` with number `pn` in `space`
    pub(super) fn sent(&mut self, pn: u64, packet: SentPacket, space: &mut PacketSpace) {
        self.in_flight.insert(&packet);
        if self.first_packet.is_none() {
            self.first_packet = Some(pn);
        }
        if let Some(forgotten) = space.sent(pn, packet) {
            self.remove_in_flight(&forgotten);
        }
    }

    /// Remove `packet` with number `pn` from this path's congestion control counters, or return
    /// `false` if `pn` was sent before this path was established.
    pub(super) fn remove_in_flight(&mut self, packet: &SentPacket) -> bool {
        if packet.path_generation != self.generation {
            return false;
        }
        self.in_flight.remove(packet);
        true
    }

    pub(super) fn qlog_reset_metrics(&mut self) {
        if let Some(metrics) = &mut self.recovery_metrics {
            **metrics = RecoveryMetrics::default();
        }
    }

    pub(super) fn qlog_reset_on_toggle(&mut self, generation: (u64, u64)) {
        if self.qlog_recording_generation != generation {
            self.qlog_recording_generation = generation;
            self.qlog_reset_metrics();
        }
    }

    pub(super) fn qlog_recovery_metrics(
        &mut self,
        pto_count: u32,
    ) -> Option<RecoveryMetricsUpdated> {
        let controller_metrics = self.congestion.metrics();

        let metrics = RecoveryMetrics {
            min_rtt: Some(self.rtt.min),
            smoothed_rtt: Some(self.rtt.get()),
            latest_rtt: Some(self.rtt.latest),
            rtt_variance: Some(self.rtt.var),
            pto_count: Some(pto_count),
            bytes_in_flight: Some(self.in_flight.bytes),

            congestion_window: Some(controller_metrics.congestion_window),
            ssthresh: controller_metrics.ssthresh,
            pacing_rate: controller_metrics.pacing_rate,
        };

        let previous = self.recovery_metrics.get_or_insert_with(Box::default);
        let event = metrics.to_qlog_event(previous);
        **previous = metrics;
        event
    }

    pub(super) fn generation(&self) -> u64 {
        self.generation
    }
}

/// Congestion metrics as described in [`recovery_metrics_updated`].
///
/// [`recovery_metrics_updated`]: https://datatracker.ietf.org/doc/html/draft-ietf-quic-qlog-quic-events.html#name-recovery_metrics_updated
#[derive(Default, Clone, PartialEq)]
#[non_exhaustive]
struct RecoveryMetrics {
    pub(crate) min_rtt: Option<Duration>,
    pub(crate) smoothed_rtt: Option<Duration>,
    pub(crate) latest_rtt: Option<Duration>,
    pub(crate) rtt_variance: Option<Duration>,
    pub(crate) pto_count: Option<u32>,
    pub(crate) bytes_in_flight: Option<u64>,
    pub(crate) congestion_window: Option<u64>,
    pub(crate) ssthresh: Option<u64>,
    pub(crate) pacing_rate: Option<u64>,
}

impl RecoveryMetrics {
    /// Retain only values that have been updated since the last snapshot.
    fn retain_updated(&self, previous: &Self) -> Self {
        macro_rules! keep_if_changed {
            ($name:ident) => {
                if previous.$name == self.$name {
                    None
                } else {
                    self.$name
                }
            };
        }

        Self {
            min_rtt: keep_if_changed!(min_rtt),
            smoothed_rtt: keep_if_changed!(smoothed_rtt),
            latest_rtt: keep_if_changed!(latest_rtt),
            rtt_variance: keep_if_changed!(rtt_variance),
            pto_count: keep_if_changed!(pto_count),
            bytes_in_flight: keep_if_changed!(bytes_in_flight),
            congestion_window: keep_if_changed!(congestion_window),
            ssthresh: keep_if_changed!(ssthresh),
            pacing_rate: keep_if_changed!(pacing_rate),
        }
    }

    /// Emit a `RecoveryMetricsUpdated` event containing only updated values
    fn to_qlog_event(&self, previous: &Self) -> Option<RecoveryMetricsUpdated> {
        let updated = self.retain_updated(previous);

        if updated == Self::default() {
            return None;
        }

        Some(RecoveryMetricsUpdated {
            min_rtt: updated.min_rtt.map(|rtt| rtt.as_secs_f32() * 1000.0),
            smoothed_rtt: updated.smoothed_rtt.map(|rtt| rtt.as_secs_f32() * 1000.0),
            latest_rtt: updated.latest_rtt.map(|rtt| rtt.as_secs_f32() * 1000.0),
            rtt_variance: updated.rtt_variance.map(|rtt| rtt.as_secs_f32() * 1000.0),
            pto_count: updated
                .pto_count
                .map(|count| count.try_into().unwrap_or(u16::MAX)),
            bytes_in_flight: updated.bytes_in_flight,
            congestion_window: updated.congestion_window,
            ssthresh: updated.ssthresh,
            pacing_rate: updated.pacing_rate,
        })
    }
}

/// RTT estimation for a particular network path
#[derive(Copy, Clone)]
pub(crate) struct RttEstimator {
    /// The most recent RTT measurement made when receiving an ack for a previously unacked packet
    latest: Duration,
    /// The smoothed RTT of the connection, computed as described in RFC6298
    smoothed: Option<Duration>,
    /// The RTT variance, computed as described in RFC6298
    var: Duration,
    /// The minimum RTT seen in the connection, ignoring ack delay.
    min: Duration,
}

impl RttEstimator {
    pub(crate) fn new(initial_rtt: Duration) -> Self {
        Self {
            latest: initial_rtt,
            smoothed: None,
            var: initial_rtt / 2,
            min: initial_rtt,
        }
    }

    /// The current best RTT estimation.
    pub(crate) fn get(&self) -> Duration {
        self.smoothed.unwrap_or(self.latest)
    }

    /// Conservative estimate of RTT
    ///
    /// Takes the maximum of smoothed and latest RTT, as recommended
    /// in 6.1.2 of the recovery spec (draft 29).
    pub(crate) fn conservative(&self) -> Duration {
        self.get().max(self.latest)
    }

    /// Minimum RTT registered so far for this estimator.
    pub(crate) fn min(&self) -> Duration {
        self.min
    }

    // PTO computed as described in RFC9002#6.2.1
    pub(crate) fn pto_base(&self) -> Duration {
        self.get() + cmp::max(4 * self.var, TIMER_GRANULARITY)
    }

    pub(crate) fn update(&mut self, ack_delay: Duration, rtt: Duration) {
        self.latest = rtt;
        // min_rtt ignores ack delay.
        self.min = cmp::min(self.min, self.latest);
        // Based on RFC6298.
        if let Some(smoothed) = self.smoothed {
            let adjusted_rtt = if self.min + ack_delay <= self.latest {
                self.latest.saturating_sub(ack_delay)
            } else {
                self.latest
            };
            let var_sample = smoothed.abs_diff(adjusted_rtt);
            self.var = (3 * self.var + var_sample) / 4;
            self.smoothed = Some((7 * smoothed + adjusted_rtt) / 8);
        } else {
            self.smoothed = Some(self.latest);
            self.var = self.latest / 2;
            self.min = self.latest;
        }
    }
}

#[derive(Default)]
pub(crate) struct PathResponses {
    pending: Vec<PathResponse>,
}

impl PathResponses {
    /// Whether this path still has a queued answer and therefore retains spin state.
    pub(super) fn contains_path(&self, remote: SocketAddr, local: Option<SocketAddr>) -> bool {
        self.pending
            .iter()
            .any(|response| response.remote == remote && response.local == local)
    }

    /// Queue a response to a challenge received from `remote` on the local socket `local`; the
    /// response must leave on that same path (RFC 9000 §8.2.2).
    pub(crate) fn push(
        &mut self,
        packet: u64,
        token: u64,
        remote: SocketAddr,
        local: Option<SocketAddr>,
        received_bytes: usize,
    ) {
        /// Arbitrary permissive limit to prevent abuse
        const MAX_PATH_RESPONSES: usize = 16;
        const MAX_RESPONSES_PER_PATH: usize = 4;
        let response = PathResponse {
            packet,
            token,
            remote,
            local,
            max_response_size: received_bytes.saturating_mul(3).min(1200),
        };
        let existing = self
            .pending
            .iter_mut()
            .find(|x| x.remote == remote && x.local == local && x.token == token);
        if let Some(existing) = existing {
            // Coalesce retransmissions of the same challenge only. Distinct
            // tokens on one path each need a response (RFC 9000 §8.2.2), even
            // when their packets arrive in one receive batch or out of order.
            existing.packet = existing.packet.max(packet);
            existing.max_response_size = existing.max_response_size.max(response.max_response_size);
            return;
        }
        if self
            .pending
            .iter()
            .filter(|x| x.remote == remote && x.local == local)
            .count()
            >= MAX_RESPONSES_PER_PATH
            && let Some(oldest) = self
                .pending
                .iter()
                .position(|x| x.remote == remote && x.local == local)
        {
            self.pending.remove(oldest);
        }
        if self.pending.len() < MAX_PATH_RESPONSES {
            self.pending.push(response);
        } else {
            // We don't expect to ever hit this with well-behaved peers, so we don't bother dropping
            // older challenges.
            trace!("ignoring excessive PATH_CHALLENGE");
        }
    }

    /// The next response that must leave on a path other than (`remote`, `local`): its token and
    /// the path it must leave on.
    /// Whether an answer is queued for a path other than the one in use, without taking it.
    pub(crate) fn has_off_path(&self, remote: SocketAddr, local: Option<SocketAddr>) -> bool {
        self.pending
            .last()
            .is_some_and(|response| !response.on_path(remote, local))
    }

    pub(crate) fn pop_off_path(
        &mut self,
        remote: SocketAddr,
        local: Option<SocketAddr>,
    ) -> Option<(Vec<u64>, SocketAddr, Option<SocketAddr>, usize)> {
        let response = *self.pending.last()?;
        if response.on_path(remote, local) {
            // We don't bother searching further because we expect that the on-path response will
            // get drained in the immediate future by a call to `pop_on_path`
            return None;
        }
        let mut tokens = Vec::new();
        let mut max_response_size = 0;
        self.pending.retain(|pending| {
            if pending.remote != response.remote || pending.local != response.local {
                return true;
            }
            tokens.push(pending.token);
            // Several challenges can share one received datagram. Spend only
            // one packet's credit for this whole path batch, never the sum of
            // per-token credits, which would multiply amplification.
            max_response_size = max_response_size.max(pending.max_response_size);
            false
        });
        Some((tokens, response.remote, response.local, max_response_size))
    }

    pub(crate) fn pop_on_path(
        &mut self,
        remote: SocketAddr,
        local: Option<SocketAddr>,
    ) -> Option<u64> {
        // Answer the oldest queued challenge first. All answers for this path
        // can share the packet, without delaying the peer's earliest probe.
        let index = self
            .pending
            .iter()
            .position(|response| response.on_path(remote, local))?;
        Some(self.pending.remove(index).token)
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }
}

#[derive(Copy, Clone)]
struct PathResponse {
    /// The packet number the corresponding PATH_CHALLENGE was received in
    packet: u64,
    token: u64,
    /// The address the corresponding PATH_CHALLENGE was received from
    remote: SocketAddr,
    /// The local socket address the corresponding PATH_CHALLENGE was received on
    local: Option<SocketAddr>,
    // Each queued response spends at most this challenge packet's own receive credit.
    max_response_size: usize,
}

impl PathResponse {
    /// Whether this response belongs to the path (`remote`, `local`). A challenge received without
    /// local provenance belongs to whatever path shares its remote.
    fn on_path(&self, remote: SocketAddr, local: Option<SocketAddr>) -> bool {
        self.remote == remote && (self.local.is_none() || local.is_none() || self.local == local)
    }
}

/// Summary statistics of packets that have been sent on a particular path, but which have not yet
/// been acked or deemed lost
pub(super) struct InFlight {
    /// Sum of the sizes of all sent packets considered "in flight" by congestion control
    ///
    /// The size does not include IP or UDP overhead. Packets only containing ACK frames do not
    /// count towards this to ensure congestion control does not impede congestion feedback.
    pub(super) bytes: u64,
    /// Number of packets in flight containing frames other than ACK and PADDING
    ///
    /// This can be 0 even when bytes is not 0 because PADDING frames cause a packet to be
    /// considered "in flight" by congestion control. However, if this is nonzero, bytes will always
    /// also be nonzero.
    pub(super) ack_eliciting: u64,
}

impl InFlight {
    fn new() -> Self {
        Self {
            bytes: 0,
            ack_eliciting: 0,
        }
    }

    fn insert(&mut self, packet: &SentPacket) {
        self.bytes += u64::from(packet.size);
        self.ack_eliciting += u64::from(packet.ack_eliciting);
    }

    /// Update counters to account for a packet becoming acknowledged, lost, or abandoned
    fn remove(&mut self, packet: &SentPacket) {
        self.bytes -= u64::from(packet.size);
        self.ack_eliciting -= u64::from(packet.ack_eliciting);
    }
}

#[cfg(test)]
mod challenge_tests;

#[cfg(test)]
mod tests {
    use super::*;

    /// A path reset starts pacing afresh: a budget exhausted on the path being left would
    /// otherwise delay the first sends on the new one.
    #[test]
    fn reset_refreshes_pacer_budget() {
        let now = Instant::now();
        let config = TransportConfig::default();
        let mut path = PathData::new(addr(4433), None, true, None, 0, now, &config);
        let mtu = path.current_mtu();
        let window = path.congestion.window();
        for _ in 0..1000 {
            if path
                .pacing
                .delay(path.rtt.get(), mtu.into(), mtu, window, now)
                .is_some()
            {
                break;
            }
            path.pacing.on_transmit(mtu);
        }
        assert!(
            path.pacing
                .delay(path.rtt.get(), mtu.into(), mtu, window, now)
                .is_some(),
            "the budget is spent"
        );

        path.reset(now, &config);

        assert_eq!(
            path.pacing.delay(
                path.rtt.get(),
                path.current_mtu().into(),
                path.current_mtu(),
                path.congestion.window(),
                now
            ),
            None,
            "and the reset path may send at once"
        );
    }

    #[test]
    fn qlog_recovery_snapshot_is_only_allocated_when_recording() {
        let now = Instant::now();
        let mut path = PathData::new(
            addr(443),
            None,
            false,
            None,
            0,
            now,
            &TransportConfig::default(),
        );
        crate::proto::connection::qlog::ConnectionQlog::default().emit_recovery_metrics(
            0,
            &mut path,
            now,
            ConnectionId::new(&[]),
        );
        assert!(path.recovery_metrics.is_none());
        let untraced = PathData::from_previous(addr(444), None, &path, 1, now);
        assert!(untraced.recovery_metrics.is_none());

        assert!(path.qlog_recovery_metrics(0).is_some());
        assert!(path.recovery_metrics.is_some());
        assert!(path.qlog_recovery_metrics(0).is_none());
        let mut migrated = PathData::from_previous(addr(444), None, &path, 1, now);
        assert!(migrated.qlog_recovery_metrics(0).is_none());
        assert_eq!(
            migrated.qlog_recovery_metrics(1).unwrap().pto_count,
            Some(1)
        );
        assert!(
            path.qlog_recovery_metrics(0).is_none(),
            "the new path owns its snapshot"
        );
    }

    #[test]
    fn qlog_rejected_snapshot_reset_reuses_storage_and_recreates_full_metrics() {
        let now = Instant::now();
        let mut path = PathData::new(
            addr(443),
            None,
            false,
            None,
            0,
            now,
            &TransportConfig::default(),
        );
        let initial = serde_json::to_value(path.qlog_recovery_metrics(0).unwrap()).unwrap();
        let storage = std::ptr::from_ref(path.recovery_metrics.as_deref().unwrap());
        for _ in 0..3 {
            path.qlog_reset_metrics();
            assert_eq!(
                std::ptr::from_ref(path.recovery_metrics.as_deref().unwrap()),
                storage
            );
            let snapshot = serde_json::to_value(path.qlog_recovery_metrics(0).unwrap()).unwrap();
            assert_eq!(snapshot, initial, "a rejection must retry all metrics");
            assert_eq!(
                std::ptr::from_ref(path.recovery_metrics.as_deref().unwrap()),
                storage
            );
            assert!(path.qlog_recovery_metrics(0).is_none());
        }
    }

    #[test]
    fn qlog_rtt_metrics_use_milliseconds_and_only_report_changes() {
        let metrics = RecoveryMetrics {
            min_rtt: Some(Duration::from_micros(1250)),
            smoothed_rtt: Some(Duration::from_micros(2500)),
            latest_rtt: Some(Duration::from_micros(3750)),
            rtt_variance: Some(Duration::from_micros(500)),
            pto_count: Some(u32::MAX),
            ..Default::default()
        };
        let event = metrics.to_qlog_event(&RecoveryMetrics::default()).unwrap();
        assert_eq!(event.min_rtt, Some(1.25));
        assert_eq!(event.smoothed_rtt, Some(2.5));
        assert_eq!(event.latest_rtt, Some(3.75));
        assert_eq!(event.rtt_variance, Some(0.5));
        assert_eq!(event.pto_count, Some(u16::MAX));
        assert!(metrics.to_qlog_event(&metrics).is_none());

        let changed = RecoveryMetrics {
            pto_count: Some(1),
            ..metrics
        };
        let event = changed.to_qlog_event(&metrics).unwrap();
        assert_eq!(event.pto_count, Some(1));
        assert!(event.min_rtt.is_none());
        assert!(event.smoothed_rtt.is_none());
        assert!(event.latest_rtt.is_none());
        assert!(event.rtt_variance.is_none());
    }

    fn addr(port: u16) -> SocketAddr {
        SocketAddr::new(std::net::Ipv4Addr::LOCALHOST.into(), port)
    }

    /// A challenge is answered on the path it arrived on, so responses are kept per path and a
    /// second local address does not overwrite the first one's answer.
    #[test]
    fn responses_are_kept_per_path() {
        let (peer, first, second) = (addr(1), addr(10), addr(20));
        let mut responses = PathResponses::default();
        responses.push(0, 0xAA, peer, Some(first), 1200);
        responses.push(1, 0xBB, peer, Some(second), 1200);
        // Sending on `first`: the answer for `second` must leave on its own path.
        let (token, remote, local, _) = responses
            .pop_off_path(peer, Some(first))
            .expect("the other path's answer is off-path here");
        assert_eq!((token, remote, local), (vec![0xBB], peer, Some(second)));
        assert_eq!(responses.pop_on_path(peer, Some(first)), Some(0xAA));
        assert!(responses.is_empty());
    }

    /// A challenge that arrived without local provenance belongs to any path with its remote; one
    /// from another remote never belongs to this path.
    #[test]
    fn a_response_without_provenance_belongs_to_its_remote() {
        let (peer, other, local) = (addr(1), addr(2), addr(10));
        let mut responses = PathResponses::default();
        responses.push(0, 0xAA, peer, None, 1200);
        assert!(
            responses.pop_off_path(peer, Some(local)).is_none(),
            "an answer without provenance is on the path with its remote"
        );
        assert_eq!(responses.pop_on_path(peer, Some(local)), Some(0xAA));
        responses.push(1, 0xBB, other, Some(local), 1200);
        assert_eq!(
            responses.pop_on_path(peer, Some(local)),
            None,
            "another remote is another path"
        );
        let (token, remote, _, _) = responses
            .pop_off_path(peer, Some(local))
            .expect("the other remote's answer is off-path here");
        assert_eq!((token, remote), (vec![0xBB], other));
    }

    /// Distinct challenges must each get a response, including reordered packets.
    #[test]
    fn distinct_challenges_on_one_path_all_get_responses() {
        let (peer, local) = (addr(1), addr(10));
        let mut responses = PathResponses::default();
        for (packet, token) in [(5, 0xAA), (4, 0xBB), (6, 0xCC), (6, 0xDD)] {
            responses.push(packet, token, peer, Some(local), 1200);
        }
        let mut tokens = Vec::new();
        while let Some(token) = responses.pop_on_path(peer, Some(local)) {
            tokens.push(token);
        }
        tokens.sort_unstable();
        assert_eq!(tokens, [0xAA, 0xBB, 0xCC, 0xDD]);
    }

    /// Repeated challenges retain the largest packet's credit without displacing other tokens.
    #[test]
    fn repeated_challenges_coalesce_without_losing_receive_credit() {
        let (peer, local) = (addr(1), addr(10));
        let mut responses = PathResponses::default();
        responses.push(5, 0xAA, peer, Some(local), 100);
        responses.push(4, 0xAA, peer, Some(local), 20);
        assert_eq!(
            responses.pop_off_path(peer, Some(addr(20))),
            Some((vec![0xAA], peer, Some(local), 300))
        );
        assert!(responses.is_empty());
        for packets in [[(5, 100), (6, 20)], [(5, 20), (4, 100)]] {
            for (packet, bytes) in packets {
                responses.push(packet, 0xAA, peer, Some(local), bytes);
            }
            assert_eq!(
                responses.pop_off_path(peer, Some(addr(20))),
                Some((vec![0xAA], peer, Some(local), 300))
            );
        }
        responses.push(5, 0xAA, peer, Some(local), 100);
        responses.push(6, 0xAA, peer, Some(local), 1200);
        assert_eq!(
            responses.pop_off_path(peer, Some(addr(20))),
            Some((vec![0xAA], peer, Some(local), 1200))
        );
        assert!(responses.is_empty());
    }

    /// The queue is bounded: challenges beyond the limit are ignored rather than buffered.
    #[test]
    fn queued_responses_are_bounded() {
        let peer = addr(1);
        let mut responses = PathResponses::default();
        for i in 0..40u16 {
            responses.push(u64::from(i), u64::from(i), peer, Some(addr(100 + i)), 1200);
        }
        let mut popped = 0;
        while responses
            .pop_off_path(peer, Some(addr(1)))
            .map(|_| ())
            .or_else(|| responses.pop_on_path(peer, Some(addr(1))).map(|_| ()))
            .is_some()
        {
            popped += 1;
            assert!(popped <= 16, "the queue is bounded at sixteen");
        }
        assert_eq!(popped, 16);
    }

    #[test]
    fn one_path_cannot_fill_the_response_queue() {
        let peer = addr(1);
        let mut responses = PathResponses::default();
        for token in 0..20 {
            responses.push(token, token, peer, Some(addr(10)), 1200);
        }
        responses.push(0, 99, peer, Some(addr(20)), 1200);
        assert_eq!(responses.pending.len(), 5);
        assert_eq!(responses.pop_on_path(peer, Some(addr(20))), Some(99));
        let mut tokens = Vec::new();
        while let Some(token) = responses.pop_on_path(peer, Some(addr(10))) {
            tokens.push(token);
        }
        tokens.sort_unstable();
        assert_eq!(tokens, [16, 17, 18, 19]);
    }

    #[cfg(any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    ))]
    #[test]
    fn off_path_challenges_in_one_packet_share_amplification_credit() {
        let mut pair = crate::proto::tests::Pair::default();
        let (_, server) = pair.connect();
        pair.drive();
        let now = pair.time;
        let conn = pair.server_conn_mut(server);
        let remote = addr(conn.path.remote.port().wrapping_add(1));
        let local = conn.path.local;
        for received_bytes in [64, 200] {
            let before = conn.stats.frame_tx.path_response;
            for token in 0..4 {
                // All four tokens come from the same received packet. Each
                // receives the same datagram length from process_payload.
                conn.path_responses
                    .push(10, token, remote, local, received_bytes);
            }
            let mut buffer = Vec::new();
            let sent = conn.poll_transmit(now, 1, &mut buffer).unwrap();
            assert_eq!(sent.destination, remote);
            assert_eq!(sent.size, received_bytes * 3);
            assert_eq!(conn.stats.frame_tx.path_response - before, 4);
            assert!(conn.path_responses.is_empty());
            buffer.clear();
            assert!(conn.poll_transmit(now, 1, &mut buffer).is_none());
        }
    }

    #[cfg(any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    ))]
    #[test]
    fn off_path_responses_respect_their_own_receive_credit() {
        let mut pair = crate::proto::tests::Pair::default();
        let (_, server) = pair.connect();
        pair.drive();
        let now = pair.time;
        let conn = pair.server_conn_mut(server);
        let remote = addr(conn.path.remote.port().wrapping_add(1));
        let local = conn.path.local;
        for (number, bytes) in [(10, 64usize), (11, 1200)] {
            conn.path_responses
                .push(number, number, remote, local, bytes);
            let mut buffer = Vec::new();
            let sent = conn.poll_transmit(now, 1, &mut buffer).unwrap();
            assert_eq!(sent.destination, remote);
            assert!(sent.size <= bytes * 3);
            assert_eq!(sent.size, (bytes * 3).min(1200));
            assert!(conn.path_responses.is_empty());
        }
    }
}
