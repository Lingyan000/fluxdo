use crate::proto::{
    Duration, Instant,
    connection::{recovery::persistent_congestion_period, spaces::SentPacket},
};
use rama_core::bytes::Bytes;
use rama_quic_proto::{
    frame::{self, EcnCounts},
    packet::SpaceId,
    range_set::ArrayRangeSet,
};

#[test]
fn persistent_congestion_period_saturates() {
    assert_eq!(
        persistent_congestion_period(Duration::from_millis(500), 3),
        Duration::from_millis(1500)
    );
    assert_eq!(
        persistent_congestion_period(Duration::MAX, 0),
        Duration::ZERO
    );
    assert_eq!(
        persistent_congestion_period(Duration::MAX, 1),
        Duration::MAX
    );
    let pto = Duration::from_secs(u64::MAX / u64::from(u32::MAX) + 1);
    assert!(pto.checked_mul(u32::MAX).is_none());
    assert_eq!(persistent_congestion_period(pto, u32::MAX), Duration::MAX);
}

#[test]
fn loss_delay_respects_granularity_and_saturates_extreme_factors() {
    use super::loss_delay;
    use crate::proto::TIMER_GRANULARITY;

    assert_eq!(
        loss_delay(Duration::from_millis(8), 1.125),
        Duration::from_millis(9)
    );
    for factor in [0.0, f32::MIN_POSITIVE, 0.01] {
        assert_eq!(
            loss_delay(Duration::from_millis(1), factor),
            TIMER_GRANULARITY
        );
    }
    assert_eq!(loss_delay(Duration::from_secs(1), f32::MAX), Duration::MAX);
    assert_eq!(loss_delay(Duration::MAX, f32::MAX), Duration::MAX);
}

impl super::Connection {
    pub(crate) fn assert_client_finished_recovery_limits(&mut self, now: Instant, late_ack: bool) {
        assert!(self.side.is_client() && self.state.is_established());
        assert!(!self.handshake_confirmed());
        let original = self.spaces[SpaceId::Handshake]
            .sent_packets
            .iter()
            .find(|(_, packet)| {
                packet
                    .retransmits
                    .get()
                    .is_some_and(|r| !r.crypto.is_empty())
            })
            .map(|(&number, _)| number)
            .unwrap();
        let consumed = self.spaces[SpaceId::Handshake].crypto_stream.bytes_read();
        assert!(consumed > 0);
        let duplicate = frame::Crypto {
            offset: consumed - 1,
            data: Bytes::from_static(b"x"), // An already-consumed byte never re-enters TLS.
        };
        let backoff = self.pto_count;
        for attempt in 0..5 {
            self.owe_acks(
                now,
                SpaceId::Handshake,
                [100 + attempt * 2, 101 + attempt * 2],
            );
            self.read_crypto(SpaceId::Handshake, &duplicate, 1).unwrap();
            self.read_crypto(SpaceId::Handshake, &duplicate, 1).unwrap();
            let should_recover = attempt < 3 && !(late_ack && attempt > 0);
            let before = self.stats.frame_tx.crypto;
            let mut buffer = Vec::new();
            if attempt == 0 {
                let in_flight = self.path.in_flight.bytes;
                self.path.in_flight.bytes = self.path.congestion.window();
                let _ack = self.poll_transmit(now, 1, &mut buffer);
                assert_eq!(
                    self.stats.frame_tx.crypto, before,
                    "no congestion exemption"
                );
                assert!(!self.spaces[SpaceId::Handshake].pending.crypto.is_empty());
                assert_eq!(self.path.in_flight.bytes, self.path.congestion.window());
                self.path.in_flight.bytes = in_flight;
                buffer.clear();
            }
            let _transmit = self.poll_transmit(now, 1, &mut buffer);
            assert_eq!(self.stats.frame_tx.crypto > before, should_recover);
            assert_eq!(
                self.pto_count, backoff,
                "early sends do not reset PTO backoff"
            );
            assert_eq!(self.loss_probe_budget, 0);
            assert!(self.loss_detection_timer().is_some());
            if late_ack && attempt == 0 {
                let mut ranges = ArrayRangeSet::new();
                ranges.insert_one(original);
                self.on_ack_received(
                    now,
                    SpaceId::Handshake,
                    &frame::Ack::from_ranges(0, &ranges, None).unwrap(),
                )
                .unwrap();
                assert!(
                    !self.handshake_confirmed(),
                    "a Handshake ACK alone is not confirmation"
                );
            }
        }
        assert_eq!(
            self.spaces[SpaceId::Handshake].early_crypto_retransmits,
            if late_ack { 1 } else { 3 },
        );
        assert!(self.spaces[SpaceId::Handshake].pending.crypto.is_empty());
    }

    pub(crate) fn fill_initial_window_with_lost_pings(&mut self, now: Instant) {
        assert_eq!(self.highest_space, SpaceId::Initial);
        let window = self.path.congestion.window();
        for _ in 0..32 {
            if self.path.in_flight.bytes + 1200 > window {
                break;
            }
            self.spaces[SpaceId::Initial].ping_pending = true;
            let mut buf = Vec::new();
            let tx = self
                .poll_transmit(now, 1, &mut buf)
                .expect("initial burst credit");
            assert_eq!(tx.size, 1200);
            // Deliberately lose the wire packet; keep its real recovery metadata.
        }
        assert_eq!(self.path.in_flight.bytes, window);
    }

    pub(crate) fn assert_padded_initial_ack_waits_for_pto(&mut self, now: Instant) {
        assert_eq!(self.path.in_flight.bytes, self.path.congestion.window());
        assert!(self.spaces[SpaceId::Initial].pending_acks.can_send());
        let before = self.stats.frame_tx.acks;
        let mut buf = Vec::new();
        assert!(self.poll_transmit(now, 10, &mut buf).is_none());
        assert_eq!(self.stats.frame_tx.acks, before);
        assert!(self.loss_detection_timer().is_some());
    }

    pub(crate) fn assert_acks_escape_full_window(&mut self, now: Instant) {
        self.spaces[SpaceId::Initial].maybe_queue_early_crypto();
        assert!(!self.spaces[SpaceId::Initial].pending.crypto.is_empty());
        assert!(self.streams.can_send_stream_data());
        self.owe_acks(now, SpaceId::Initial, [100, 101]);
        self.owe_acks(now, SpaceId::Handshake, [100, 101]);
        let crypto = self.spaces[SpaceId::Handshake]
            .sent_packets
            .values()
            .find_map(|packet| packet.retransmits.get().map(|r| r.crypto.clone()))
            .unwrap();
        self.spaces[SpaceId::Handshake]
            .pending
            .crypto
            .extend(crypto);
        self.path.validated = true;
        self.path.in_flight.bytes = self.path.congestion.window();
        let before = self.stats.frame_tx;
        let mut buf = Vec::new();
        let transmit = self
            .poll_transmit(now, 10, &mut buf)
            .expect("ACK must escape congestion");
        assert!(transmit.segment_size.is_none());
        let frames = self.sent_datagram_frames_for_test(&buf);
        assert_eq!(self.path.in_flight.bytes, self.path.congestion.window());
        assert!(frames.iter().any(|f| matches!(f, frame::Frame::Ack(_))));
        assert!(
            frames
                .iter()
                .all(|f| matches!(f, frame::Frame::Ack(_) | frame::Frame::Padding))
        );
        assert_eq!(self.stats.frame_tx.crypto, before.crypto);
        assert_eq!(self.stats.frame_tx.stream, before.stream);
        assert!(!self.spaces[SpaceId::Initial].pending.crypto.is_empty());
        assert_eq!(self.loss_probe_budget, 0);
    }

    pub(crate) fn assert_mtu_progress_with_a_full_window(&mut self, now: Instant) {
        use super::super::{mtud::MtuDiscovery, pacing::Pacer, paths::RttEstimator};
        assert!(self.handshake_confirmed());
        assert!(self.streams.can_send_stream_data());
        self.path.mtud = MtuDiscovery::new(1200, 1200, Some(1452), Default::default());
        let rtt = Duration::from_millis(20);
        self.path.rtt = RttEstimator::new(rtt);
        let probes = self.stats.path.sent_plpmtud_probes;
        let streams = self.stats.frame_tx.stream;
        let mut buf = Vec::new();
        for step in 0..4 {
            let sent_at = now + rtt * step;
            let window = self.path.congestion.window();
            self.path.in_flight.bytes = window;
            self.path.pacing = Pacer::new(rtt, window, self.path.current_mtu(), sent_at);
            self.path.pacing.on_transmit(u16::MAX);
            buf.clear();
            let tx = self
                .poll_transmit(sent_at, 10, &mut buf)
                .expect("PLPMTUD must progress while queued streams fill the window");
            assert!(tx.size > usize::from(self.path.current_mtu()) && tx.size <= 1452);
            assert!(tx.segment_size.is_none(), "probe is a separate datagram");
            assert_eq!(
                self.stats.path.sent_plpmtud_probes,
                probes + u64::from(step) + 1
            );
            assert_eq!(self.path.in_flight.bytes, window + tx.size as u64);
            assert_eq!(self.stats.frame_tx.stream, streams);
            assert!(!self.app_limited, "application data remains queued");
            let pn = self.path.mtud.in_flight_mtu_probe().unwrap();
            buf.clear();
            assert!(
                self.poll_transmit(sent_at + rtt / 2, 10, &mut buf)
                    .is_none()
            );
            assert_eq!(
                self.stats.path.sent_plpmtud_probes,
                probes + u64::from(step) + 1
            );
            let mut acked = ArrayRangeSet::new();
            acked.insert_one(pn);
            self.on_ack_received(
                sent_at + rtt,
                SpaceId::Data,
                &frame::Ack::from_ranges(0, &acked, None).unwrap(),
            )
            .unwrap();
        }
        assert_eq!(self.path.current_mtu(), 1452, "converges within four RTTs");
        self.path.in_flight.bytes = 0;
        self.path.pacing = Pacer::starting(rtt, self.path.congestion.window(), 1452, now + rtt * 4);
        buf.clear();
        assert!(self.poll_transmit(now + rtt * 4, 10, &mut buf).is_some());
        assert!(
            self.stats.frame_tx.stream > streams,
            "application data resumes"
        );
    }

    pub(crate) fn assert_initial_probe_with_pending_stream(&mut self, now: Instant) {
        // The original CRYPTO was delivered, but other Initial packets occupy
        // the window. Application data is queued in a different number space.
        let mut acked = ArrayRangeSet::new();
        for packet in self.spaces[SpaceId::Initial].sent_packets.values() {
            if let Some(retransmits) = packet.retransmits.get() {
                for frame in &retransmits.crypto {
                    acked.insert(frame.offset..frame.offset + frame.data.len() as u64);
                }
            }
        }
        self.spaces[SpaceId::Initial].crypto_acked = acked;
        self.spaces[SpaceId::Initial].deduplicate_crypto();
        assert!(self.streams.can_send_stream_data());
        self.path.validated = true;
        self.path.in_flight.bytes = self.path.congestion.window();
        self.loss_probe_budget = 2;
        self.spaces[SpaceId::Initial].loss_probes = 2;
        let before = self.stats.frame_tx.ping;
        let mut buffer = Vec::new();
        let transmit = self
            .poll_transmit(now, 2, &mut buffer)
            .expect("Initial PTO must not be suppressed by a queued application stream");
        assert!(transmit.size <= 2400);
        assert!(self.stats.frame_tx.ping > before);
        let first_packet = self.sent_frames_for_test(&buffer);
        assert!(first_packet.iter().any(|f| matches!(f, frame::Frame::Ping)));
        assert!(
            first_packet
                .iter()
                .all(|f| !matches!(f, frame::Frame::Stream(_))),
            "STREAM may coalesce in 1-RTT, but never belongs in Initial"
        );
    }

    pub(crate) fn assert_challenge_retry_survives_packet_ack(&mut self, now: Instant) {
        let retry = self.path.challenge.unwrap().retry_at().unwrap();
        let mut ranges = ArrayRangeSet::new();
        for &number in self.spaces[SpaceId::Data].sent_packets.keys() {
            ranges.insert_one(number);
        }
        self.on_ack_received(
            now,
            SpaceId::Data,
            &frame::Ack::from_ranges(0, &ranges, None).unwrap(),
        )
        .unwrap();
        assert!(
            self.loss_detection_timer().is_none(),
            "the challenge packet was acknowledged"
        );
        let before = self.stats.frame_tx.path_challenge;
        let mut buffer = Vec::new();
        let _transmit = self.poll_transmit(now, 1, &mut buffer);
        assert_eq!(self.stats.frame_tx.path_challenge, before);
        self.handle_timeout(retry);
        buffer.clear();
        assert!(self.poll_transmit(retry, 1, &mut buffer).is_some());
        assert_eq!(self.stats.frame_tx.path_challenge, before + 1);
        assert_eq!(self.loss_probe_budget, 0, "validation has its own timer");
    }

    pub(crate) fn assert_early_crypto_obeys_send_limits(&mut self, now: Instant) {
        self.spaces[SpaceId::Initial].maybe_queue_early_crypto();
        assert!(!self.spaces[SpaceId::Initial].pending.crypto.is_empty());
        let before = self.stats.frame_tx.crypto;
        let in_flight = self.path.in_flight.bytes;
        self.path.validated = true;
        self.path.in_flight.bytes = self.path.congestion.window();
        let mut buffer = Vec::new();
        let _transmit = self.poll_transmit(now, 1, &mut buffer);
        assert_eq!(self.stats.frame_tx.crypto, before, "congestion admission");
        assert!(!self.spaces[SpaceId::Initial].pending.crypto.is_empty());

        self.path.in_flight.bytes = in_flight;
        self.path.validated = false;
        self.path.total_recvd = 0;
        self.path.total_sent = 0;
        buffer.clear();
        assert!(self.poll_transmit(now, 1, &mut buffer).is_none());
        assert_eq!(
            self.stats.frame_tx.crypto, before,
            "amplification admission"
        );
        assert!(!self.spaces[SpaceId::Initial].pending.crypto.is_empty());

        self.path.total_recvd = 1200;
        buffer.clear();
        let transmit = self.poll_transmit(now, 1, &mut buffer).unwrap();
        assert!(transmit.size <= 3600);
        assert!(self.stats.frame_tx.crypto > before);
        assert_eq!(self.loss_probe_budget, 0);
    }

    pub(crate) fn assert_handshake_probe_datagram_budget(
        &mut self,
        initial_size: usize,
        max_datagrams: usize,
    ) {
        // Isolate the sender's congestion exemption with CRYPTO spanning
        // different packet layouts, including a hybrid-sized ServerHello.
        // These synthetic bytes are never delivered to the TLS receiver.
        self.path.validated = true;
        self.path.in_flight.bytes = self.path.congestion.window();
        for (space, size) in [(SpaceId::Initial, initial_size), (SpaceId::Handshake, 2400)] {
            self.spaces[space].pending.crypto.clear();
            self.spaces[space].pending.crypto.push_back(frame::Crypto {
                offset: 0,
                data: Bytes::from(vec![0; size]),
            });
        }
        let now = self.loss_detection_timer().unwrap();
        self.on_loss_detection_timeout(now);
        let mut datagrams = 0;
        let mut bytes = 0;
        loop {
            let mut buffer = Vec::new();
            let Some(transmit) = self.poll_transmit(now, max_datagrams, &mut buffer) else {
                break;
            };
            datagrams += transmit
                .size
                .div_ceil(transmit.segment_size.map_or(transmit.size, usize::from));
            bytes += transmit.size;
            assert!(
                datagrams <= 2,
                "{initial_size}-byte Initial exceeded the PTO budget"
            );
        }
        assert_eq!(datagrams, 2);
        assert!(bytes <= 2 * usize::from(self.config.min_mtu));
        if initial_size == 2400 {
            let handshake_number = self.spaces[SpaceId::Handshake].next_packet_number;
            let now = self.loss_detection_timer().unwrap();
            self.on_loss_detection_timeout(now);
            let mut datagrams = 0;
            loop {
                let mut buffer = Vec::new();
                let Some(transmit) = self.poll_transmit(now, max_datagrams, &mut buffer) else {
                    break;
                };
                datagrams += transmit
                    .size
                    .div_ceil(transmit.segment_size.map_or(transmit.size, usize::from));
                assert!(datagrams <= 2);
            }
            assert!(
                self.spaces[SpaceId::Handshake].next_packet_number > handshake_number,
                "a fragmented Initial must not starve Handshake probes next round"
            );
        }
    }

    pub(crate) fn assert_pto_backoff(&self, space: SpaceId, expected_count: u32) {
        assert_eq!(self.pto_count, expected_count);
        let sent_at = self.spaces[space]
            .time_of_last_ack_eliciting_packet
            .expect("an outstanding probe or handshake flight");
        assert_eq!(
            self.loss_detection_timer(),
            Some(sent_at + self.pto(space) * 2u32.pow(expected_count))
        );
        if space == SpaceId::Handshake {
            assert!(self.spaces[SpaceId::Initial].crypto.is_none());
        }
    }

    pub(crate) fn acknowledge_handshake_for_pto_test(&mut self, now: crate::proto::Instant) {
        let Some((&largest, _)) = self.spaces[SpaceId::Handshake]
            .sent_packets
            .last_key_value()
        else {
            return;
        };
        let mut ranges = rama_quic_proto::range_set::ArrayRangeSet::new();
        ranges.insert(0..largest + 1);
        self.on_ack_received(
            now,
            SpaceId::Handshake,
            &frame::Ack::from_ranges(0, &ranges, None).unwrap(),
        )
        .unwrap();
    }

    /// Simulate the recovery-state replacement at completion of path validation while
    /// retaining connection-wide sent packets, just as migration does.
    pub(crate) fn replace_recovery_path_for_test(&mut self, now: crate::proto::Instant) {
        self.path_counter += 1;
        self.path = crate::proto::connection::paths::PathData::new(
            self.path.remote,
            self.path.local,
            false,
            None,
            self.path_counter,
            now,
            &self.config,
        );
        self.path.validated = true;
        self.path.mtu_validated = true;
        // A busy new path must not grow its congestion window from old-path ACKs.
        self.app_limited = false;
    }

    pub(crate) fn assert_rebinding_restarts_pending_mtu_probe(
        &mut self,
        now: crate::proto::Instant,
    ) {
        let mut mtud = crate::proto::connection::mtud::MtuDiscovery::new(
            1300,
            1200,
            Some(1400),
            crate::proto::MtuDiscoveryConfig::default(),
        );
        assert!(mtud.poll_transmit(now, 100).is_some());
        assert_eq!(mtud.in_flight_mtu_probe(), Some(100));
        self.path.mtud = mtud;
        let mut next = crate::proto::connection::paths::PathData::from_previous(
            self.path.remote,
            self.path.local,
            &self.path,
            self.path.generation() + 1,
            now,
        );
        assert_eq!(next.current_mtu(), 1300);
        assert_eq!(next.mtud.in_flight_mtu_probe(), None);
        let size = next.mtud.poll_transmit(now, 101).unwrap();
        assert!((1301..=1400).contains(&size));
        assert_eq!(next.mtud.in_flight_mtu_probe(), Some(101));
        assert_eq!(self.path.mtud.in_flight_mtu_probe(), Some(100));
    }
}

type RecordedLoss = (crate::proto::Instant, bool, u64);

#[derive(Clone, Default)]
struct LossRecorder(std::sync::Arc<parking_lot::Mutex<Vec<RecordedLoss>>>);

impl crate::proto::congestion::Controller for LossRecorder {
    fn on_congestion_event(
        &mut self,
        _: crate::proto::Instant,
        sent: crate::proto::Instant,
        persistent: bool,
        bytes: u64,
    ) {
        self.0.lock().push((sent, persistent, bytes));
    }

    fn on_mtu_update(&mut self, _: u16) {}

    fn window(&self) -> u64 {
        12000
    }

    fn initial_window(&self) -> u64 {
        12000
    }

    fn clone_box(&self) -> Box<dyn crate::proto::congestion::Controller> {
        Box::new(self.clone())
    }
}

impl super::Connection {
    pub(crate) fn assert_mixed_path_loss_is_scoped(&mut self, now: crate::proto::Instant) {
        use crate::proto::connection::spaces::SentPacket;
        self.replace_recovery_path_for_test(now);
        let recorder = LossRecorder::default();
        self.path.congestion = Box::new(recorder.clone());
        let space = SpaceId::Data;
        let base = self.spaces[space].next_packet_number;
        let current_sent = now.checked_sub(Duration::from_millis(3)).unwrap();
        let old_sent = now.checked_sub(Duration::from_millis(1)).unwrap();
        let lost_probes = self.stats.path.lost_plpmtud_probes;
        for (offset, generation, sent, probe, size) in [
            (0, self.path.generation(), current_sent, false, 1200),
            (1, self.path.generation() - 1, old_sent, false, 1300),
            (2, self.path.generation() - 1, old_sent, true, 1400),
        ] {
            let info = SentPacket {
                path_generation: generation,
                time_sent: sent,
                size,
                ack_eliciting: true,
                is_0rtt: false,
                is_mtu_probe_packet: probe,
                largest_acked: None,
                retransmits: Default::default(),
                stream_frames: Default::default(),
            };
            self.in_flight_ack_eliciting += 1;
            if generation == self.path.generation() {
                self.path.sent(base + offset, info, &mut self.spaces[space]);
            } else {
                assert!(self.spaces[space].sent(base + offset, info).is_none());
            }
        }
        self.spaces[space].next_packet_number = base + 11;
        self.spaces[space].largest_acked_packet = Some(base + 10);
        self.detect_lost_packets(now, space, true);
        assert_eq!(*recorder.0.lock(), vec![(current_sent, false, 1200)]);
        assert_eq!(self.path.in_flight.bytes, 0);
        assert_eq!(self.stats.path.lost_plpmtud_probes, lost_probes + 1);
        for pn in base..base + 3 {
            assert!(!self.spaces[space].sent_packets.contains_key(&pn));
        }
    }
}

impl super::Connection {
    pub(crate) fn assert_old_path_ecn_only_advances_feedback(
        &mut self,
        now: crate::proto::Instant,
    ) {
        self.replace_recovery_path_for_test(now);
        let recorder = LossRecorder::default();
        self.path.congestion = Box::new(recorder.clone());
        let space = SpaceId::Data;
        let mut counts = self.spaces[space].ecn_feedback;

        // Two old-path packets were acknowledged, but only one retained its ECN
        // marking. Count verification fails; its monotonic CE observation must
        // still be consumed before a clean current-path ACK arrives.
        counts.ce += 1;
        self.process_ecn(now, space, 2, counts, None);
        assert!(self.path.sending_ecn);
        assert_eq!(self.spaces[space].ecn_feedback.ce, counts.ce);
        counts.ect0 += 1;
        self.process_ecn(now, space, 1, counts, Some(now));
        assert!(recorder.0.lock().is_empty());

        counts.ce += 1;
        self.process_ecn(now, space, 1, counts, None);
        assert!(recorder.0.lock().is_empty());
        assert!(self.path.sending_ecn);
        assert_eq!(self.spaces[space].ecn_feedback.ce, counts.ce);

        // Invalid old-path feedback must not disable ECN on the replacement path.
        self.process_ecn(now, space, 1, EcnCounts::ZERO, None);
        assert!(self.path.sending_ecn);
        assert_eq!(self.spaces[space].ecn_feedback.ce, counts.ce);

        // A subsequent clean current-path ACK does not rediscover the old CE mark.
        counts.ect0 += 1;
        self.process_ecn(now, space, 1, counts, Some(now));
        assert!(recorder.0.lock().is_empty());
        counts.ce += 1;
        self.process_ecn(now, space, 1, counts, Some(now));
        assert_eq!(*recorder.0.lock(), vec![(now, false, 0)]);
    }
}
impl super::Connection {
    pub(crate) fn assert_ack_delay_tracks_handshake_confirmation(
        &mut self,
        now: crate::proto::Instant,
    ) {
        use crate::proto::connection::{paths::RttEstimator, spaces::SentPacket};

        self.skip_no_packet_number();
        self.path.rtt = RttEstimator::new(Duration::from_millis(50));
        self.path
            .rtt
            .update(Duration::ZERO, Duration::from_millis(50));
        self.ack_frequency.peer_max_ack_delay = Duration::from_millis(25);
        self.peer_params.ack_delay_exponent = rama_quic_proto::VarInt::from_u32(3);
        let packet = self.spaces[SpaceId::Data].get_tx_number();
        self.path.sent(
            packet,
            SentPacket {
                path_generation: self.path.generation(),
                time_sent: now.checked_sub(Duration::from_millis(150)).unwrap(),
                size: 1200,
                ack_eliciting: true,
                is_0rtt: false,
                is_mtu_probe_packet: false,
                largest_acked: None,
                retransmits: Default::default(),
                stream_frames: Default::default(),
            },
            &mut self.spaces[SpaceId::Data],
        );
        self.in_flight_ack_eliciting += 1;
        let mut ranges = rama_quic_proto::range_set::ArrayRangeSet::new();
        ranges.insert_one(packet);
        self.on_ack_received(
            now,
            SpaceId::Data,
            // 12_500 µs delay = 100 ms with exponent 3.
            &frame::Ack::from_ranges(12_500, &ranges, None).unwrap(),
        )
        .unwrap();
        let expected = if self.handshake_confirmed() {
            Duration::from_micros(59_375) // (7 * 50 + (150 - 25)) / 8
        } else {
            Duration::from_millis(50) // (7 * 50 + (150 - 100)) / 8
        };
        assert_eq!(self.path.rtt.get(), expected);
        assert_eq!(self.path.rtt.min(), Duration::from_millis(50));
    }
}

impl super::Connection {
    /// Exercise real ACK processing after the fixture handshake, with sent packet
    /// numbers chosen explicitly so random optimistic-ACK skips cannot mask the case.
    pub(crate) fn assert_ecn_feedback(
        &mut self,
        now: Instant,
        offsets: &[u64],
        counts: Option<EcnCounts>,
        expected_enabled: bool,
    ) {
        self.skip_no_packet_number();
        self.path.sending_ecn = true;
        self.spaces[SpaceId::Data].ecn_feedback = EcnCounts::ZERO;
        let first = self.spaces[SpaceId::Data].next_packet_number;
        let mut ranges = ArrayRangeSet::new();

        for &offset in offsets {
            // Gaps represent packets absent from this ACK, not additional packets
            // whose markings can justify its ECN counts.
            let number = first + offset;
            self.spaces[SpaceId::Data].next_packet_number = number + 1;
            self.path.sent(
                number,
                SentPacket {
                    path_generation: self.path.generation(),
                    time_sent: now,
                    size: 0,
                    ack_eliciting: false,
                    is_0rtt: false,
                    is_mtu_probe_packet: false,
                    largest_acked: None,
                    retransmits: Default::default(),
                    stream_frames: Default::default(),
                },
                &mut self.spaces[SpaceId::Data],
            );
            ranges.insert_one(number);
        }

        let ack = frame::Ack::from_ranges(0, &ranges, counts).unwrap();
        self.on_ack_received(now, SpaceId::Data, &ack).unwrap();
        assert_eq!(
            self.path.sending_ecn, expected_enabled,
            "offsets={offsets:?}, feedback={counts:?}"
        );

        // A duplicate ACK has no newly acknowledged packets. It must not require
        // another counter increase or disable otherwise valid ECN feedback.
        self.on_ack_received(now, SpaceId::Data, &ack).unwrap();
        assert_eq!(self.path.sending_ecn, expected_enabled);
    }
}

#[cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
mod ack_history {
    use crate::proto::{
        DEFAULT_SUPPORTED_VERSIONS, Duration, Instant,
        connection::{pacing::Pacer, paths::RttEstimator},
        tests::{Pair, util::client_config},
    };
    use rama_quic_proto::{
        Version, frame,
        packet::{FixedLengthConnectionIdParser, PartialDecode, SpaceId},
    };

    // Synthetic receive events isolate the ACK-only sender. Each packet below goes
    // through poll_transmit and authenticated decryption; no receive-path assertion
    // is inferred from these tests.
    fn prepare_ack_history(connection: &mut super::super::Connection, now: Instant) {
        // In-memory handshakes have zero RTT; use a fixed nonzero network sample
        // when testing round-trip spacing and pacing.
        connection.path.rtt = RttEstimator::new(Duration::from_millis(100));
        for space in [SpaceId::Initial, SpaceId::Handshake, SpaceId::Data] {
            for (_, packet) in connection.spaces[space].take_sent_packets() {
                connection.remove_in_flight(&packet);
            }
        }
        assert_eq!(connection.in_flight_ack_eliciting, 0);
        let space = &mut connection.spaces[SpaceId::Data];
        space.time_of_last_ack_eliciting_packet = None;
        space.pending_acks.acks_sent();
        space.ping_pending = false;
        space.immediate_ack_pending = false;
        assert!(space.pending.is_empty(&connection.streams));

        for index in 0..32 {
            let sent = now + Duration::from_millis(index + 1);
            assert!(!emit_ack_history_packet(connection, sent, index));
        }
        assert_eq!(
            connection.spaces[SpaceId::Data]
                .non_ack_eliciting_sent
                .len(),
            32
        );
    }

    fn emit_ack_history_packet(
        connection: &mut super::super::Connection,
        now: Instant,
        received: u64,
    ) -> bool {
        let space = &mut connection.spaces[SpaceId::Data];
        space.pending_acks.insert_one(received, now);
        space.pending_acks.set_immediate_ack_required();
        let mut buffer = Vec::new();
        let transmit = connection.poll_transmit(now, 1, &mut buffer).unwrap();
        assert_eq!(transmit.size, buffer.len());

        let space = &connection.spaces[SpaceId::Data];
        let (&number, sent) = space.sent_packets.last_key_value().unwrap();
        let keys = &space.crypto.as_ref().unwrap().local;
        let (partial, rest) = PartialDecode::new(
            buffer.as_slice().into(),
            &FixedLengthConnectionIdParser::new(connection.rem_cids.active().len()),
            DEFAULT_SUPPORTED_VERSIONS,
            true, // The connected fixture negotiates QUIC-bit greasing.
        )
        .unwrap();
        assert!(rest.is_none());
        let mut packet = partial.finish_protected(&*keys.header).unwrap();
        keys.packet
            .decrypt(number, &packet.header_data, &mut packet.payload)
            .unwrap();
        let mut ping = false;
        let mut ack = false;
        for frame in frame::Iter::new(packet.payload.freeze()).unwrap() {
            match frame.unwrap() {
                frame::Frame::Ping => ping = true,
                frame::Frame::Ack(_) => ack = true,
                frame::Frame::Padding => {}
                other => panic!("unexpected ACK-history frame: {other:?}"),
            }
        }
        assert!(ack);
        assert_eq!(sent.ack_eliciting, ping);
        ping
    }

    #[test]
    fn ack_history_ping_is_occasional_on_both_sides_and_versions() {
        for version in [Version::V1, Version::V2] {
            for server in [false, true] {
                let mut pair = Pair::default();
                let mut config = client_config();
                config.set_version(version).unwrap();
                let (client, remote) = pair.connect_with(config);
                let start = pair.time + Duration::from_secs(1);
                let connection = if server {
                    pair.server_conn_mut(remote)
                } else {
                    pair.client_conn_mut(client)
                };
                prepare_ack_history(connection, start);

                let now = start + Duration::from_secs(1);
                assert!(emit_ack_history_packet(connection, now, 100));
                assert!(!emit_ack_history_packet(
                    connection,
                    now + Duration::from_secs(1),
                    101
                ));

                // Selectively acknowledge only the PING. Older ACK-only entries may
                // remain, but the remembered eliciting timestamp still limits probing.
                let ping_number = connection.spaces[SpaceId::Data]
                    .sent_packets
                    .iter()
                    .find_map(|(&number, sent)| sent.ack_eliciting.then_some(number))
                    .unwrap();
                let ping = connection.spaces[SpaceId::Data].take(ping_number).unwrap();
                connection.remove_in_flight(&ping);
                assert!(emit_ack_history_packet(
                    connection,
                    now + Duration::from_secs(2),
                    102
                ));
                let ping_number = *connection.spaces[SpaceId::Data]
                    .sent_packets
                    .last_key_value()
                    .unwrap()
                    .0;
                let ping = connection.spaces[SpaceId::Data].take(ping_number).unwrap();
                connection.remove_in_flight(&ping);
                assert!(!emit_ack_history_packet(
                    connection,
                    now + Duration::from_secs(3),
                    103
                ));
            }
        }
    }

    #[test]
    fn ack_history_ping_never_blocks_congestion_exempt_ack() {
        for pacing in [false, true] {
            let mut pair = Pair::default();
            let (client, _) = pair.connect();
            let start = pair.time + Duration::from_secs(1);
            let connection = pair.client_conn_mut(client);
            prepare_ack_history(connection, start);
            let now = start + Duration::from_secs(1);
            if pacing {
                let window = connection.path.congestion.window();
                let mtu = connection.path.current_mtu();
                connection.path.pacing = Pacer::new(connection.path.rtt.get(), window, mtu, now);
                connection.path.pacing.on_transmit(u16::MAX);
                assert!(
                    connection
                        .path
                        .pacing
                        .delay(connection.path.rtt.get(), u64::from(mtu), mtu, window, now)
                        .is_some()
                );
            } else {
                // Model a full congestion window independently of the feedback probe.
                connection.path.in_flight.bytes = connection.path.congestion.window();
            }
            assert!(!emit_ack_history_packet(connection, now, 100));
            assert!(!connection.spaces[SpaceId::Data].ping_pending);
        }
    }

    #[test]
    fn ack_history_ping_waits_a_round_trip_and_does_not_wake_idle_sender() {
        let mut pair = Pair::default();
        let (client, _) = pair.connect();
        let start = pair.time + Duration::from_secs(1);
        let connection = pair.client_conn_mut(client);
        prepare_ack_history(connection, start);
        let now = start + Duration::from_secs(1);
        let mut buffer = Vec::new();
        assert!(connection.poll_transmit(now, 1, &mut buffer).is_none());
        assert!(emit_ack_history_packet(connection, now, 100));
        let ping_number = *connection.spaces[SpaceId::Data]
            .sent_packets
            .last_key_value()
            .unwrap()
            .0;
        let ping = connection.spaces[SpaceId::Data].take(ping_number).unwrap();
        connection.remove_in_flight(&ping);
        assert!(!emit_ack_history_packet(
            connection,
            now + Duration::from_nanos(1),
            101
        ));
        assert!(!emit_ack_history_packet(
            connection,
            now + Duration::from_nanos(2),
            102
        ));
        assert!(emit_ack_history_packet(
            connection,
            now + Duration::from_secs(1),
            103
        ));
    }
}
