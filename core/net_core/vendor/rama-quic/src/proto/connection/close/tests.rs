use crate::proto::connection::close::CloseResponses;

#[test]
fn each_close_response_costs_twice_the_last() {
    // From a fresh counter, with an answer taken every time one is earned. The connection
    // arms its first close itself, so its own sequence starts one answer further on; that
    // is asserted at the connection level.
    let mut responses = CloseResponses::new();
    let mut earned_at = Vec::new();
    for input in 1..=16u32 {
        if responses.arrived() {
            earned_at.push(input);
            responses.answered();
        }
    }
    assert_eq!(earned_at, vec![1, 3, 7, 15]);
}

#[test]
fn the_gap_between_close_responses_saturates() {
    let mut responses = CloseResponses::new();
    for _ in 0..64 {
        responses.answered();
    }
    assert_eq!(
        responses.gap.get(),
        u32::MAX,
        "it stops rather than wrapping"
    );
    // The count towards it saturates too, so a long run of input cannot wrap into an answer
    // it did not earn.
    responses.seen = u32::MAX - 2;
    assert!(!responses.arrived(), "one short of the gap is still short");
    assert!(responses.arrived(), "and the next one meets it exactly");
    assert_eq!(responses.seen, 0, "which starts the count again");
}

#[cfg(all(
    test,
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "ring", feature = "aws-lc"))
    )
))]
mod packet_budget_tests {
    use crate::proto::{
        DEFAULT_SUPPORTED_VERSIONS, Endpoint, EndpointConfig, Instant, StoredToken, UNIX_EPOCH,
    };
    use rama_core::bytes::Bytes;
    use rama_quic_proto::{
        Side, TransportErrorCode, Version,
        frame::{self, Close, Frame},
        packet::{FixedLengthConnectionIdParser, PartialDecode, SpaceId},
        version::ClientVersionPolicy,
    };
    use std::sync::Arc;
    #[test]
    fn large_initial_token_leaves_room_for_close() {
        let base = crate::test_helpers::client(&crate::test_helpers::identity());
        for version in [Version::V1, Version::V2] {
            let mut config = base.clone();
            config
                .set_versions(ClientVersionPolicy::new(version).unwrap())
                .unwrap();
            // The boundary cases reserve a close frame beside a 35-byte ACK.
            for (token_len, ack_fits) in [
                (1083, true),
                (1084, true),
                (1085, false),
                (1100, false),
                // Exactly enough frame space for CONNECTION_CLOSE alone.
                (1119, false),
            ] {
                config.token_store.insert(
                    "localhost",
                    version,
                    StoredToken::new(vec![0; token_len].into(), UNIX_EPOCH),
                );
                let mut endpoint = Endpoint::new(
                    Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
                    None,
                    true,
                    None,
                );
                let now = Instant::now();
                let (_, mut conn) = endpoint
                    .connect(
                        now,
                        config.clone(),
                        "[::1]:4433".parse().unwrap(),
                        "localhost",
                    )
                    .unwrap();
                let keys = conn
                    .crypto
                    .initial_keys(version, &conn.initial_dst_cid, Side::Server)
                    .unwrap();
                let space = &mut conn.spaces[SpaceId::Initial];
                for pn in (0..32).step_by(2) {
                    space.pending_acks.insert_one(pn, now);
                    space.dedup.insert(pn);
                    space
                        .pending_acks
                        .packet_received(now, pn, true, &space.dedup);
                }
                conn.close(now, 0u32.into(), Bytes::new());
                let mut buf = Vec::new();
                assert!(conn.poll_transmit(now, 1, &mut buf).is_some());
                assert!(buf.len() <= 1200);
                assert!(!conn.close);

                let (packet, rest) = PartialDecode::new(
                    buf.as_slice().into(),
                    &FixedLengthConnectionIdParser::new(0),
                    DEFAULT_SUPPORTED_VERSIONS,
                    false,
                )
                .unwrap();
                assert!(rest.is_none());
                let mut packet = packet
                    .finish_protected(&*keys.remote.as_ref().unwrap().header)
                    .unwrap();
                assert_eq!(packet.header_data.len(), 40 + token_len);
                keys.remote
                    .as_ref()
                    .unwrap()
                    .packet
                    .decrypt(0, &packet.header_data, &mut packet.payload)
                    .unwrap();
                let mut frames = frame::Iter::new(packet.payload.freeze())
                    .unwrap()
                    .map(Result::unwrap)
                    .filter(|frame| !matches!(frame, Frame::Padding));
                if ack_fits {
                    assert!(
                        matches!(frames.next(), Some(Frame::Ack(_))),
                        "token {token_len}"
                    );
                }
                assert!(
                    matches!(
                        frames.next(),
                        Some(Frame::Close(Close::Connection(frame::ConnectionClose {
                            error_code: TransportErrorCode::APPLICATION_ERROR,
                            ..
                        })))
                    ),
                    "token {token_len}"
                );
                assert!(frames.next().is_none());
            }
        }
    }
}
