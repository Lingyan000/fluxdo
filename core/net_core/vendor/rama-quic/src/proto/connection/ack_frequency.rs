use rama_quic_proto::{
    TransportError, VarInt, frame::AckFrequency, transport_parameters::TransportParameters,
};

use crate::proto::{
    AckFrequencyConfig, Duration, TIMER_GRANULARITY, connection::spaces::PendingAcks,
};

/// State associated to ACK frequency
pub(super) struct AckFrequencyState {
    // Sending ACK_FREQUENCY frames
    in_flight_ack_frequency_frame: Option<(u64, Duration)>,
    next_outgoing_sequence_number: VarInt,
    pub(super) peer_max_ack_delay: Duration,

    // Receiving ACK_FREQUENCY frames
    last_ack_frequency_frame: Option<u64>,
    pub(super) max_ack_delay: Duration,
}

impl AckFrequencyState {
    pub(super) fn new(default_max_ack_delay: Duration) -> Self {
        Self {
            in_flight_ack_frequency_frame: None,
            next_outgoing_sequence_number: VarInt::from_u32(0),
            peer_max_ack_delay: default_max_ack_delay,

            last_ack_frequency_frame: None,
            max_ack_delay: default_max_ack_delay,
        }
    }

    /// Returns the `max_ack_delay` that should be requested of the peer when sending an
    /// ACK_FREQUENCY frame
    pub(super) fn candidate_max_ack_delay(
        &self,
        rtt: Duration,
        config: &AckFrequencyConfig,
        peer_params: &TransportParameters,
    ) -> Duration {
        // Use the peer's max_ack_delay if no custom max_ack_delay was provided in the config
        let min_ack_delay =
            Duration::from_micros(peer_params.min_ack_delay.map_or(0, |x| x.into()));
        config
            .max_ack_delay
            .unwrap_or(self.peer_max_ack_delay)
            .clamp(
                min_ack_delay,
                rtt.max(MIN_AUTOMATIC_ACK_DELAY)
                    .max(min_ack_delay)
                    .min(MAX_ACK_DELAY.saturating_sub(Duration::from_micros(1))),
            )
    }

    /// Returns the `max_ack_delay` for the purposes of calculating the PTO
    ///
    /// This `max_ack_delay` is defined as the maximum of the peer's current `max_ack_delay` and all
    /// in-flight `max_ack_delay`s (i.e. proposed values that haven't been acknowledged yet, but
    /// might be already in use by the peer).
    pub(super) fn max_ack_delay_for_pto(&self) -> Duration {
        // Note: we have at most one in-flight ACK_FREQUENCY frame
        if let Some((_, max_ack_delay)) = self.in_flight_ack_frequency_frame {
            self.peer_max_ack_delay.max(max_ack_delay)
        } else {
            self.peer_max_ack_delay
        }
    }

    /// Returns the next sequence number for an ACK_FREQUENCY frame
    pub(super) fn next_sequence_number(&mut self) -> VarInt {
        let seq = self.next_outgoing_sequence_number;
        // Sequence numbers stay well below `VarInt::MAX` in practice; saturate defensively rather
        // than construct an out-of-range value.
        self.next_outgoing_sequence_number =
            VarInt::from_u64(seq.into_inner().saturating_add(1)).unwrap_or(VarInt::MAX);
        seq
    }

    /// Returns true if we should send an ACK_FREQUENCY frame
    pub(super) fn should_send_ack_frequency(
        &self,
        rtt: Duration,
        config: &AckFrequencyConfig,
        peer_params: &TransportParameters,
    ) -> bool {
        if self.next_outgoing_sequence_number == 0 {
            // Always send at startup
            return true;
        }
        let current = self
            .in_flight_ack_frequency_frame
            .map_or(self.peer_max_ack_delay, |(_, pending)| pending);
        let desired = self.candidate_max_ack_delay(rtt, config, peer_params);
        let error = (desired.as_secs_f32() / current.as_secs_f32()) - 1.0;
        error.abs() > MAX_RTT_ERROR
    }

    /// Notifies the [`AckFrequencyState`] that a packet containing an ACK_FREQUENCY frame was sent
    pub(super) fn ack_frequency_sent(&mut self, pn: u64, requested_max_ack_delay: Duration) {
        self.in_flight_ack_frequency_frame = Some((pn, requested_max_ack_delay));
    }

    /// Notifies the [`AckFrequencyState`] that a packet has been ACKed
    pub(super) fn on_acked(&mut self, pn: u64) {
        if let Some((number, requested_max_ack_delay)) = self.in_flight_ack_frequency_frame
            && number == pn
        {
            self.in_flight_ack_frequency_frame = None;
            self.peer_max_ack_delay = requested_max_ack_delay;
        }
    }

    /// Notifies the [`AckFrequencyState`] that an ACK_FREQUENCY frame was received
    ///
    /// Updates the endpoint's params according to the payload of the ACK_FREQUENCY frame, or
    /// returns an error in case the requested `max_ack_delay` is invalid.
    ///
    /// Returns `true` if the frame was processed and `false` if it was ignored because of being
    /// stale.
    pub(super) fn ack_frequency_received(
        &mut self,
        frame: &AckFrequency,
        pending_acks: &mut PendingAcks,
    ) -> Result<bool, TransportError> {
        if self
            .last_ack_frequency_frame
            .is_some_and(|highest_sequence_nr| frame.sequence <= highest_sequence_nr)
        {
            return Ok(false);
        }

        self.last_ack_frequency_frame = Some(frame.sequence.into_inner());

        // Update max_ack_delay
        let max_ack_delay = Duration::from_micros(frame.request_max_ack_delay.into_inner());
        if max_ack_delay < TIMER_GRANULARITY {
            return Err(TransportError::PROTOCOL_VIOLATION(
                "Requested Max Ack Delay in ACK_FREQUENCY frame is less than min_ack_delay",
            ));
        }
        if max_ack_delay >= MAX_ACK_DELAY {
            return Err(TransportError::PROTOCOL_VIOLATION(
                "Requested Max Ack Delay in ACK_FREQUENCY frame is too large",
            ));
        }
        self.max_ack_delay = max_ack_delay;

        // Update the rest of the params
        pending_acks.set_ack_frequency_params(frame);

        Ok(true)
    }
}

/// Maximum proportion difference between the most recently requested max ACK delay and the
/// currently desired one before a new request is sent, when the peer supports the ACK frequency
/// extension and an explicit max ACK delay is not configured.
const MAX_RTT_ERROR: f32 = 0.2;

/// Minimum value to request the peer set max ACK delay to when the peer supports the ACK frequency
/// extension and an explicit max ACK delay is not configured.
// Keep in sync with `AckFrequencyConfig::max_ack_delay` documentation
const MIN_AUTOMATIC_ACK_DELAY: Duration = Duration::from_millis(25);

// The ACK_FREQUENCY field uses microseconds, but retains the 2^14 millisecond limit.
const MAX_ACK_DELAY: Duration = Duration::from_millis(1 << 14);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requested_delay_respects_a_peer_minimum_above_the_rtt() {
        let params = TransportParameters {
            max_ack_delay: 100u32.into(),
            min_ack_delay: Some(100_000u32.into()),
            ..TransportParameters::default()
        };
        let mut wire = Vec::new();
        params.write(&mut wire);
        let params =
            TransportParameters::read(rama_quic_proto::Side::Client, &mut wire.as_slice()).unwrap();
        let state = AckFrequencyState::new(Duration::from_millis(25));
        assert_eq!(
            state.candidate_max_ack_delay(
                Duration::from_millis(1),
                &AckFrequencyConfig::default(),
                &params
            ),
            Duration::from_millis(100)
        );
    }

    /// The largest peer minimum the transport parameters admit, 16,383 ms in microseconds, still
    /// leaves the request's lower bound at or below its upper bound, at any RTT.
    #[test]
    fn the_largest_admissible_peer_minimum_still_yields_a_request() {
        let params = TransportParameters {
            max_ack_delay: 16_383u32.into(),
            min_ack_delay: Some(16_383_000u32.into()),
            ..TransportParameters::default()
        };
        let mut wire = Vec::new();
        params.write(&mut wire);
        let params =
            TransportParameters::read(rama_quic_proto::Side::Client, &mut wire.as_slice()).unwrap();
        let state = AckFrequencyState::new(Duration::from_millis(25));
        for rtt in [Duration::ZERO, Duration::from_millis(5), Duration::MAX] {
            for config in [
                AckFrequencyConfig::default(),
                AckFrequencyConfig {
                    max_ack_delay: Some(Duration::from_millis(1)),
                    ..AckFrequencyConfig::default()
                },
            ] {
                assert_eq!(
                    state.candidate_max_ack_delay(rtt, &config, &params),
                    Duration::from_micros(16_383_000),
                    "rtt {rtt:?}"
                );
            }
        }
    }

    #[test]
    fn requested_delays_stay_within_the_wire_limit() {
        let state = AckFrequencyState::new(Duration::from_millis(25));
        let config = AckFrequencyConfig {
            max_ack_delay: Some(Duration::MAX),
            ..AckFrequencyConfig::default()
        };
        let delay =
            state.candidate_max_ack_delay(Duration::MAX, &config, &TransportParameters::default());
        assert_eq!(delay, Duration::from_micros(16_383_999));
    }

    #[test]
    fn received_delays_enforce_microsecond_boundaries_and_ignore_stale_frames() {
        use crate::proto::{Instant, connection::spaces::PacketSpace};

        for micros in [
            0,
            999,
            1_000,
            25_000,
            16_383_999,
            16_384_000,
            VarInt::MAX.into_inner(),
        ] {
            let mut state = AckFrequencyState::new(Duration::from_millis(25));
            let mut pending = PacketSpace::new(Instant::now()).pending_acks;
            let frame = AckFrequency {
                sequence: 1u32.into(),
                ack_eliciting_threshold: 1u32.into(),
                request_max_ack_delay: VarInt::from_u64(micros).unwrap(),
                reordering_threshold: 1u32.into(),
            };
            let result = state.ack_frequency_received(&frame, &mut pending);
            if (1_000..16_384_000).contains(&micros) {
                assert!(result.unwrap());
                assert_eq!(state.max_ack_delay, Duration::from_micros(micros));
                let stale = AckFrequency {
                    sequence: 0u32.into(),
                    request_max_ack_delay: VarInt::MAX,
                    ..frame
                };
                assert!(!state.ack_frequency_received(&stale, &mut pending).unwrap());
                assert_eq!(state.max_ack_delay, Duration::from_micros(micros));
            } else {
                assert_eq!(
                    result.unwrap_err().code(),
                    rama_quic_proto::TransportErrorCode::PROTOCOL_VIOLATION
                );
            }
        }
    }
}
