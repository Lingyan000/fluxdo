use super::*;
use rama_core::extensions::Extensions;
use rama_quic_proto::{
    capture::{CaptureLimits, ObservedFrame, QuicObservation},
    packet::{FixedLengthConnectionIdParser, PartialDecode},
    version::ClientVersionPolicy,
};
use rama_tls::SecureTransport;

#[test]
fn server_observation_retains_tls_parameters_and_attempt_identity() {
    for version in [Version::V1, Version::V2] {
        let mut server = server_config();
        server.set_capture(CaptureLimits::default());
        let mut pair = Pair::new(
            Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
            server,
        );
        let mut client = client_config();
        client
            .set_versions(ClientVersionPolicy::new(version).unwrap())
            .unwrap();
        let (_, server) = pair.connect_with(client);
        let extensions = Extensions::new();
        pair.server_conn_mut(server)
            .publish_observation(&extensions, true, false);
        let recorded = extensions.get_ref::<QuicObservation>().unwrap();
        assert!(recorded.completeness.is_complete(), "{recorded:?}");
        assert!(!recorded.transport_parameters.is_empty());
        assert!(!recorded.client_hello_message.is_empty());
        assert!(!recorded.attempt_id.is_empty());
        assert!(recorded.retry_parent.is_none());
        assert_eq!(recorded.first_flight.as_ref().unwrap().version, version);
        assert!(
            extensions
                .get_ref::<SecureTransport>()
                .unwrap()
                .client_hello()
                .is_some()
        );
    }
}

#[test]
fn exhausting_observation_budgets_does_not_reject_the_handshake() {
    for limits in [
        CaptureLimits {
            datagrams: 0,
            ..CaptureLimits::default()
        },
        CaptureLimits {
            bytes: 1,
            ..CaptureLimits::default()
        },
        CaptureLimits {
            packets: 0,
            ..CaptureLimits::default()
        },
        CaptureLimits {
            frames: 0,
            ..CaptureLimits::default()
        },
        CaptureLimits {
            crypto_fragments: 0,
            ..CaptureLimits::default()
        },
        CaptureLimits {
            client_hello_bytes: 1,
            ..CaptureLimits::default()
        },
        CaptureLimits {
            parameters: 0,
            ..CaptureLimits::default()
        },
    ] {
        let mut server = server_config();
        server.set_capture(limits);
        let mut pair = Pair::new(
            Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
            server,
        );
        let (_, server) = pair.connect();
        let extensions = Extensions::new();
        pair.server_conn_mut(server)
            .publish_observation(&extensions, true, false);
        let recorded = extensions.get_ref::<QuicObservation>().unwrap();
        assert!(
            !recorded.completeness.is_complete(),
            "{limits:?}: {recorded:?}"
        );
        let completeness = recorded.completeness;
        assert_eq!(
            completeness.datagrams,
            limits.datagrams > 0 && limits.bytes > 1 && limits.packets > 0,
            "{limits:?}: {recorded:?}"
        );
        assert_eq!(
            completeness.frames,
            limits.packets > 0 && limits.frames > 0 && limits.crypto_fragments > 0,
            "{limits:?}: {recorded:?}"
        );
        assert_eq!(completeness.client_hello, limits.parameters == 0);
        assert!(!completeness.transport_parameters);
        assert!(recorded.client_hello_message.len() <= limits.client_hello_bytes);
        assert!(recorded.transport_parameters.len() <= limits.parameters);
        if let Some(flight) = &recorded.first_flight {
            assert!(flight.datagram_sizes.len() <= limits.datagrams);
            assert!(flight.datagram_sizes.iter().sum::<usize>() <= limits.bytes);
            assert!(flight.packet_numbers.len() <= limits.packets);
            assert!(flight.frames.iter().map(Vec::len).sum::<usize>() <= limits.frames);
            assert!(
                flight
                    .frames
                    .iter()
                    .flatten()
                    .filter(|frame| matches!(frame, ObservedFrame::Crypto { .. }))
                    .count()
                    <= limits.crypto_fragments
            );
        }
    }
}

#[test]
fn disabled_capture_has_no_recorder_or_retained_observation() {
    let mut pair = Pair::default();
    let (_, server) = pair.connect();
    assert!(pair.server_conn_mut(server).observation.is_none());
}

#[test]
fn server_observation_reports_retry_lineage_without_claiming_original_flight() {
    let mut server = server_config();
    server.set_capture(CaptureLimits::default());
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    pair.server.handle_incoming = Box::new(validate_incoming);
    let (_, server) = pair.connect();
    let extensions = Extensions::new();
    pair.server_conn_mut(server)
        .publish_observation(&extensions, true, false);
    let observed = extensions.get_ref::<QuicObservation>().unwrap();
    assert!(observed.retry_parent.is_some());
    assert_ne!(
        observed.retry_parent.as_deref(),
        Some(observed.attempt_id.as_slice())
    );
    assert!(!observed.completeness.original_attempt);
    assert!(!observed.completeness.is_complete());
    assert!(observed.completeness.client_hello);
}

#[test]
fn server_observation_retains_buffered_retransmissions_before_accept() {
    let mut server = server_config();
    server.set_capture(CaptureLimits::default());
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    pair.server.handle_incoming = Box::new(|_| IncomingConnectionBehavior::Wait);
    pair.begin_connect(client_config());
    pair.drive_client();
    let duplicate = pair.server.inbound.front().unwrap().clone();
    pair.server.inbound.push_back(duplicate);
    pair.drive_server();
    let incoming = pair.server.waiting_incoming.pop().unwrap();
    let server = pair.server.try_accept(incoming, pair.time).unwrap();
    let extensions = Extensions::new();
    pair.server_conn_mut(server)
        .publish_observation(&extensions, true, false);
    let observed = extensions.get_ref::<QuicObservation>().unwrap();
    let flight = observed.first_flight.as_ref().unwrap();
    assert_eq!(flight.datagram_sizes.len(), 2);
    assert_eq!(flight.packet_numbers, [0, 0]);
    assert_eq!(flight.frames.len(), 1);
    assert!(observed.completeness.is_complete());
}

// Re-protect a real Initial after changing its authenticated frame layout or token.
fn rewrite_initial(wire: &mut BytesMut, reverse: bool, token: bool) -> usize {
    let dcid_len = usize::from(wire[5]);
    let dcid = ConnectionId::new(&wire[6..6 + dcid_len]);
    let version = Version::from_be_bytes(wire[1..5].try_into().unwrap());
    let keys = server_config()
        .crypto
        .initial()
        .initial_keys(version, &dcid)
        .unwrap();
    let keys = keys.remote.as_ref().unwrap();
    let (decode, rest) = PartialDecode::new(
        wire.clone(),
        &FixedLengthConnectionIdParser::new(8),
        &[version],
        true,
    )
    .unwrap();
    assert!(rest.is_none());
    let mut packet = decode.finish_protected(keys.header.as_ref()).unwrap();
    let Header::Initial(mut header) = packet.header else {
        panic!("expected Initial");
    };
    let number = header.number.expand(0);
    keys.packet
        .decrypt(number, &packet.header_data, &mut packet.payload)
        .unwrap();
    if token {
        header.token = Bytes::from_static(b"different-token");
    }
    let mut output = Vec::new();
    let partial = Header::Initial(header).encode(&mut output);
    let mut count = 0;
    if reverse {
        for frame in frame::Iter::new(packet.payload.freeze()).unwrap() {
            match frame.unwrap() {
                Frame::Crypto(crypto) => {
                    let chunks = crypto.data.chunks(8).collect::<Vec<_>>();
                    count += chunks.len();
                    for (index, chunk) in chunks.into_iter().enumerate().rev() {
                        frame::Crypto {
                            offset: crypto.offset + (index * 8) as u64,
                            data: Bytes::copy_from_slice(chunk),
                        }
                        .encode(&mut output);
                    }
                }
                Frame::Padding => (),
                other => panic!("unexpected first-flight frame: {other:?}"),
            }
        }
    } else {
        output.extend_from_slice(&packet.payload);
    }
    let size = wire.len().max(output.len() + keys.packet.tag_len());
    output.resize(size, 0);
    partial
        .finish(
            &mut output,
            keys.header.as_ref(),
            Some((number, keys.packet.as_ref())),
        )
        .unwrap();
    *wire = BytesMut::from(output.as_slice());
    count
}

#[test]
fn observation_reverse_fragments_complete_within_the_fragment_budget() {
    let mut server = server_config();
    server.set_capture(CaptureLimits::default());
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    let client = pair.begin_connect(client_config());
    pair.drive_client();
    let count = rewrite_initial(
        &mut pair.server.inbound.front_mut().unwrap().packet,
        true,
        false,
    );
    assert!(count > 32 && count < CaptureLimits::default().crypto_fragments);
    pair.drive();
    let server = pair.server.assert_accept();
    assert!(pair.client_conn_mut(client).handshake_confirmed());
    let conn = pair.server_conn_mut(server);
    assert!(conn.handshake_confirmed());
    assert!(!conn.is_closed());
    let extensions = Extensions::new();
    conn.publish_observation(&extensions, false, false);
    assert!(
        conn.observation.is_none(),
        "final publication must release all assembly and recorder storage"
    );
    let observed = extensions.get_ref::<QuicObservation>().unwrap();
    assert!(observed.completeness.client_hello);
    assert!(observed.completeness.frames);
    assert!(extensions.contains::<SecureTransport>());
}

#[test]
fn observation_completes_after_accept_and_excludes_mismatched_token() {
    for mismatch in [false, true] {
        let mut server =
            ServerConfig::with_crypto(Arc::new(server_crypto_with_alpn(vec![b"h3".to_vec()])));
        server.set_capture(CaptureLimits::default());
        let mut pair = Pair::new(
            Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
            server,
        );
        let mut protocols: Vec<_> = (0..24u8).map(|n| vec![b'a' + n; 96]).collect();
        protocols.push(b"h3".to_vec());
        let client = pair.begin_connect(ClientConfig::new(Arc::new(client_crypto_with_alpn(
            protocols,
        ))));
        pair.drive_client();
        assert!(pair.server.inbound.len() > 1);
        let rest = pair.server.inbound.split_off(1);
        pair.drive_server();
        let server = pair.server.assert_accept();
        let extensions = Extensions::new();
        pair.server_conn_mut(server)
            .publish_observation(&extensions, true, false);
        assert!(
            !extensions
                .get_ref::<QuicObservation>()
                .unwrap()
                .completeness
                .client_hello
        );
        if mismatch {
            let mut wrong = rest.front().unwrap().clone();
            rewrite_initial(&mut wrong.packet, false, true);
            pair.server.inbound.push_back(wrong);
            pair.drive_server();
        }
        pair.server.inbound.extend(rest);
        pair.drive();
        assert!(pair.client_conn_mut(client).handshake_confirmed());
        let conn = pair.server_conn_mut(server);
        conn.publish_observation(&extensions, false, false);
        assert!(conn.observation.is_none());
        let observed = extensions.get_ref::<QuicObservation>().unwrap();
        assert!(observed.completeness.client_hello);
        assert!(
            extensions
                .get_ref::<SecureTransport>()
                .unwrap()
                .client_hello()
                .is_some()
        );
        let numbers = &observed.first_flight.as_ref().unwrap().packet_numbers;
        assert_eq!(numbers.iter().filter(|&&number| number == 1).count(), 1);
    }
}

#[test]
fn observation_reports_incoming_buffer_drops() {
    let mut server = server_config();
    server.set_capture(CaptureLimits::default());
    server.incoming_buffer_size = 0;
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    pair.server.handle_incoming = Box::new(|_| IncomingConnectionBehavior::Wait);
    pair.begin_connect(client_config());
    pair.drive_client();
    let duplicate = pair.server.inbound.front().unwrap().clone();
    pair.server.inbound.push_back(duplicate);
    pair.drive_server();
    let incoming = pair.server.waiting_incoming.pop().unwrap();
    let server = pair.server.try_accept(incoming, pair.time).unwrap();
    pair.drive();
    let extensions = Extensions::new();
    pair.server_conn_mut(server)
        .publish_observation(&extensions, true, false);
    let observed = extensions.get_ref::<QuicObservation>().unwrap();
    assert!(!observed.completeness.datagrams);
    assert!(observed.completeness.client_hello);
}

#[test]
fn observation_accept_configuration_controls_retention() {
    for limits in [
        None,
        Some(CaptureLimits {
            client_hello_bytes: 1,
            ..CaptureLimits::default()
        }),
    ] {
        let mut config = server_config();
        config.set_capture(CaptureLimits::default());
        let mut override_config = config.clone();
        override_config.capture = limits;
        let mut pair = Pair::new(
            Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
            config,
        );
        pair.server.handle_incoming = Box::new(|_| IncomingConnectionBehavior::Wait);
        pair.begin_connect(client_config());
        pair.drive_client();
        pair.drive_server();
        let incoming = pair.server.waiting_incoming.pop().unwrap();
        let (_, mut conn, _admission) = pair
            .server
            .endpoint
            .accept(
                incoming,
                pair.time,
                &mut Vec::new(),
                Some(Arc::new(override_config)),
            )
            .unwrap();
        let extensions = Extensions::new();
        conn.publish_observation(&extensions, true, false);
        assert!(conn.observation.is_none());
        assert!(!extensions.contains::<SecureTransport>());
        if limits.is_some() {
            assert!(
                !extensions
                    .get_ref::<QuicObservation>()
                    .unwrap()
                    .completeness
                    .client_hello
            );
        } else {
            assert!(!extensions.contains::<QuicObservation>());
        }
    }
}

// The Boring provider limits the Initial handshake flight to 16 KiB.
#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
#[test]
fn observation_client_hello_limit_above_sixteen_kib_is_honored() {
    let mut server =
        ServerConfig::with_crypto(Arc::new(server_crypto_with_alpn(vec![b"h3".to_vec()])));
    server.set_capture(CaptureLimits {
        bytes: octets::mib(1),
        datagrams: 128,
        client_hello_bytes: octets::kib(32),
        ..CaptureLimits::default()
    });
    let mut transport = TransportConfig::default();
    transport.set_crypto_buffer_size(octets::kib(64));
    server.set_transport_config(Arc::new(transport));
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    let mut protocols: Vec<_> = (0..180u8).map(|n| vec![n; 100]).collect();
    protocols.push(b"h3".to_vec());
    let (_, server) = pair.connect_with(ClientConfig::new(Arc::new(client_crypto_with_alpn(
        protocols,
    ))));
    let extensions = Extensions::new();
    pair.server_conn_mut(server)
        .publish_observation(&extensions, true, false);
    let observed = extensions.get_ref::<QuicObservation>().unwrap();
    assert!(observed.completeness.client_hello, "{observed:?}");
    assert!(observed.client_hello_message.len() > octets::kib(16));
    assert!(extensions.contains::<SecureTransport>());
}
