use std::sync::Arc;

use crate::proto::{
    Endpoint, EndpointConfig, Instant, MIN_INITIAL_CONGESTION_WINDOW, MIN_INITIAL_SIZE,
    connection::{packet_builder::PacketBuilder, transmit::SentFrames},
    tests::util::Pair,
};
use rama_quic_proto::{
    Version,
    packet::{FixedLengthConnectionIdParser, PartialDecode, SpaceId},
    profile::{PacketizationProfile, QuicProfile},
    version::ClientVersionPolicy,
};

fn decode_varint_at(bytes: &[u8], at: usize) -> (usize, u64) {
    let width = 1usize << (bytes[at] >> 6);
    let mut value = u64::from(bytes[at] & 0x3f);
    for &byte in &bytes[at + 1..at + width] {
        value = (value << 8) | u64::from(byte);
    }
    (width, value)
}

fn initial_length_field(bytes: &[u8]) -> Option<(usize, usize, u64)> {
    let mut at = 5;
    let dst_cid_len = usize::from(bytes[at]);
    at += 1 + dst_cid_len;
    let src_cid_len = usize::from(bytes[at]);
    at += 1 + src_cid_len;
    let (token_len_width, token_len) = decode_varint_at(bytes, at);
    at += token_len_width + usize::try_from(token_len).ok()?;
    let (length_width, length) = decode_varint_at(bytes, at);
    Some((at + length_width, length_width, length))
}

#[test]
fn jumbo_initial_uses_wide_length_varint() {
    for version in [Version::V1, Version::V2] {
        for (datagram_size, expected_length_width) in [(1200, 2), (32_768, 4)] {
            let profile = QuicProfile::standard()
                .with_versions(ClientVersionPolicy::new(version).unwrap())
                .with_packetization(
                    PacketizationProfile::standard()
                        .try_with_initial_datagram_size(datagram_size)
                        .unwrap(),
                );
            let mut config = crate::test_helpers::client(&crate::test_helpers::identity());
            config.apply_quic_profile(&profile).unwrap();
            Arc::get_mut(&mut config.transport)
                .unwrap()
                .try_set_initial_congestion_window(
                    u64::from(datagram_size).max(MIN_INITIAL_CONGESTION_WINDOW),
                )
                .unwrap();

            let mut endpoint = Endpoint::new(
                Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
                None,
                true,
                None,
            );
            let now = Instant::now();
            let (_, mut conn) = endpoint
                .connect(now, config, "[::1]:4433".parse().unwrap(), "localhost")
                .unwrap();
            let mut buffer = Vec::new();
            let transmit = conn
                .poll_transmit(now, 1, &mut buffer)
                .expect("client should send its Initial");

            assert_eq!(transmit.size, usize::from(datagram_size));
            assert_eq!(buffer.len(), usize::from(datagram_size));
            let (partial, rest) = PartialDecode::new(
                buffer.as_slice().into(),
                &FixedLengthConnectionIdParser::new(0),
                &[version],
                false,
            )
            .unwrap();
            assert!(rest.is_none());
            assert!(partial.is_initial());
            assert_eq!(partial.version(), Some(version));
            let expected_length = partial.initial_header().unwrap().len;
            let (length_end, length_width, wire_length) = initial_length_field(&buffer).unwrap();
            assert_eq!(length_width, expected_length_width);
            assert_eq!(wire_length, expected_length);
            assert_eq!(wire_length, (buffer.len() - length_end) as u64);
        }
    }
}

/// A datagram's size is its own, not the buffer's.
///
/// Datagrams after the first in a GSO batch start at a nonzero offset, so a buffer that has
/// already passed 1200 bytes says nothing about the datagram being finished. A challenge in
/// that datagram is only proof of the path's minimum MTU if *it* reached 1200
/// (RFC 9000 §8.2.1).
///
/// The amplification limit makes this unreachable in an ordinary pass — a limit small enough
/// to keep a challenge undersized clamps the whole pass to the same allowance — so the
/// builder is driven directly here.
#[test]
fn a_challenge_is_sized_by_its_own_datagram_not_the_buffer_before_it() {
    let mut pair = Pair::default();
    let (client_ch, _) = pair.connect();
    let now = pair.time;
    let conn = pair.client_conn_mut(client_ch);
    let token = 0x0102_0304_0506_0708;
    conn.set_challenge(token);

    // A buffer already past 1200 bytes, and a short datagram beginning after it.
    let mut buf = vec![0u8; usize::from(MIN_INITIAL_SIZE) + 64];
    let datagram_start = buf.len();
    let capacity = datagram_start + 200;
    let dst_cid = conn.active_rem_cid();
    let builder = PacketBuilder::new(
        now,
        SpaceId::Data,
        dst_cid,
        (conn.path.remote, conn.path.local),
        &mut buf,
        capacity,
        datagram_start,
        true,
        conn,
    )
    .expect("a 1-RTT packet can be built");
    let sent = SentFrames {
        challenge: Some(token),
        ..SentFrames::default()
    };
    builder
        .finish_and_track(now, conn, Some(sent), &mut buf)
        .unwrap();

    assert!(
        buf.len() > usize::from(MIN_INITIAL_SIZE),
        "the buffer as a whole is past {MIN_INITIAL_SIZE}: {}",
        buf.len()
    );
    assert!(
        !conn.challenge_proves_mtu(),
        "but the datagram that carried the token is {} bytes, so it proves no MTU",
        buf.len() - datagram_start
    );
}

/// A validation that exists to prove the minimum MTU is written only into a datagram that can
/// still reach it. The rule lives on the token; this is the sender honouring it.
#[test]
fn the_sender_withholds_an_mtu_challenge_from_a_datagram_that_cannot_expand() {
    let mut pair = Pair::default();
    let (client_ch, _) = pair.connect();
    let now = pair.time;
    let conn = pair.client_conn_mut(client_ch);
    conn.set_mtu_challenge(0x1111_2222_3333_4444);
    let before = conn.stats().frame_tx.path_challenge;

    let mut buf = Vec::new();
    conn.populate_for_tests(now, &mut buf, 1200, false);
    assert_eq!(
        conn.stats().frame_tx.path_challenge,
        before,
        "a datagram that cannot reach the minimum size carries no MTU challenge"
    );

    let mut buf = Vec::new();
    conn.populate_for_tests(now, &mut buf, 1200, true);
    assert_eq!(
        conn.stats().frame_tx.path_challenge,
        before + 1,
        "and one that can, does"
    );
}
