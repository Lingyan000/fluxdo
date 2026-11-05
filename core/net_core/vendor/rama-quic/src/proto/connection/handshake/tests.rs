use crate::proto::{Duration, connection::handshake::negotiate_max_idle_timeout};
use rama_quic_proto::{VarInt, Version, frame, packet::SpaceId};

#[test]
fn negotiate_max_idle_timeout_commutative() {
    let test_params = [
        (None, None, None),
        (None, Some(VarInt::from_u32(0)), None),
        (
            None,
            Some(VarInt::from_u32(2)),
            Some(Duration::from_millis(2)),
        ),
        (Some(VarInt::from_u32(0)), Some(VarInt::from_u32(0)), None),
        (
            Some(VarInt::from_u32(2)),
            Some(VarInt::from_u32(0)),
            Some(Duration::from_millis(2)),
        ),
        (
            Some(VarInt::from_u32(1)),
            Some(VarInt::from_u32(4)),
            Some(Duration::from_millis(1)),
        ),
    ];

    for (left, right, result) in test_params {
        assert_eq!(negotiate_max_idle_timeout(left, right), result);
        assert_eq!(negotiate_max_idle_timeout(right, left), result);
    }
}
impl super::Connection {
    pub(crate) fn assert_key_retirement_does_not_authorize_an_update(
        &mut self,
        now: crate::proto::Instant,
    ) {
        self.skip_no_packet_number();
        assert!(self.force_key_update(now));
        self.ping();
        let mut buf = Vec::new();
        assert!(self.poll_transmit(now, 1, &mut buf).is_some());
        let sent = self.spaces[SpaceId::Data].next_packet_number - 1;

        // A peer packet with new keys permits read-key retirement even when its
        // ACK was lost or it carried no ACK. Run that timer's retirement action.
        self.prev_crypto.as_mut().unwrap().end_packet = Some((1, now));
        self.qlog_discard_retired_keys(now);
        assert!(!self.force_key_update(now));

        let mut ranges = rama_quic_proto::range_set::ArrayRangeSet::new();
        ranges.insert_one(sent);
        self.on_ack_received(
            now + crate::proto::Duration::from_millis(1),
            SpaceId::Data,
            &frame::Ack::from_ranges(0, &ranges, None).unwrap(),
        )
        .unwrap();
        assert!(self.force_key_update(now));
    }

    pub(crate) fn assert_early_packet_is_not_decrypted(
        &mut self,
        now: crate::proto::Instant,
        packet: rama_core::bytes::BytesMut,
    ) {
        use rama_quic_proto::packet::{FixedLengthConnectionIdParser, PartialDecode, SpaceId};
        assert!(self.spaces[SpaceId::Data].crypto.is_some() || self.zero_rtt_crypto.is_some());
        let (packet, remaining) = PartialDecode::new(
            packet,
            &FixedLengthConnectionIdParser::new(8),
            &[Version::V1],
            true,
        )
        .unwrap();
        assert!(remaining.is_none());
        let failures = self.authentication_failures;
        let authenticated = self.total_authed_packets;
        self.handle_decode(now, self.path.remote, self.path.local, None, packet);
        assert_eq!(self.authentication_failures, failures);
        assert_eq!(self.total_authed_packets, authenticated);
        assert!(!self.is_closed());
    }
}
