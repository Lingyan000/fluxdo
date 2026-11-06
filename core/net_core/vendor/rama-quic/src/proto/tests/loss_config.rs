use super::*;
use rama_quic_proto::{Dir, packet::SpaceId, version::LongKind};

#[test]
fn padded_initial_ack_at_a_full_window_recovers_on_pto() {
    for gso in [false, true] {
        let mut config = client_config();
        Arc::get_mut(&mut config.transport)
            .unwrap()
            .set_enable_segmentation_offload(gso)
            .maybe_set_mtu_discovery_config(None);
        let mut pair = Pair::default();
        let client = pair.begin_connect(config);
        pair.drive_client();
        pair.drive_server();
        let server = pair.server.assert_accept();
        pair.client.inbound.clear(); // Lose the server's complete first flight.
        let now = pair.time;
        pair.client_conn_mut(client)
            .fill_initial_window_with_lost_pings(now);
        // A PING-only Initial creates ACK debt without acknowledging any of our
        // lost packets or delivering TLS keys. Its required padding costs window.
        let packet = pair.server_conn_mut(server).initial_ping_for_test(now);
        pair.client
            .inbound
            .push_back(Inbound::plain(now, None, packet));
        pair.drive_client();
        pair.client_conn_mut(client)
            .assert_padded_initial_ack_waits_for_pto(now);
        pair.time = pair.client_conn_mut(client).loss_detection_timer().unwrap();
        pair.drive_client();
        assert!(
            !pair.server.inbound.is_empty(),
            "PTO bypasses the full window"
        );
        pair.drive();
        assert!(!pair.client_conn_mut(client).is_handshaking());
        assert!(!pair.server_conn_mut(server).is_handshaking());
        let stream = pair.client_streams(client).open(Dir::Uni).unwrap();
        pair.client_send(client, stream)
            .write(b"recovered")
            .unwrap();
        pair.client_send(client, stream).finish().unwrap();
        pair.drive();
        let mut recv = pair.server_recv(server, stream);
        let mut chunks = recv.read(true).unwrap();
        assert_eq!(
            chunks.next(usize::MAX).unwrap().unwrap().bytes,
            b"recovered"[..]
        );
        assert!(chunks.next(usize::MAX).unwrap().is_none());
        let _transmit = chunks.finalize();
    }
}

#[test]
fn handshake_acks_are_not_suppressed_by_congested_crypto_or_streams() {
    for gso in [false, true] {
        let mut config = server_config();
        Arc::get_mut(&mut config.transport)
            .unwrap()
            .set_enable_segmentation_offload(gso);
        let mut pair = Pair::new(
            Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
            config,
        );
        pair.begin_connect(client_config());
        pair.drive_client();
        pair.drive_server();
        let server = pair.server.assert_accept();
        let stream = pair.server_streams(server).open(Dir::Uni).unwrap();
        pair.server_send(server, stream)
            .write(b"queued response")
            .unwrap();
        let now = pair.time;
        pair.server_conn_mut(server)
            .assert_acks_escape_full_window(now);
    }
}

#[test]
fn mtu_probes_wait_for_handshake_confirmation() {
    let mut pair = Pair::default();
    let client = pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    pair.drive_client();
    assert!(!pair.client_conn_mut(client).is_handshaking());
    assert_eq!(
        pair.client_conn_mut(client)
            .stats()
            .path
            .sent_plpmtud_probes,
        0,
        "TLS completion alone does not confirm the QUIC handshake"
    );
    pair.drive();
    assert!(
        pair.client_conn_mut(client)
            .stats()
            .path
            .sent_plpmtud_probes
            > 0
    );
}

#[test]
fn mtu_discovery_progresses_with_a_full_window_and_busy_streams() {
    for gso in [false, true] {
        let mut config = server_config();
        Arc::get_mut(&mut config.transport)
            .unwrap()
            .set_enable_segmentation_offload(gso);
        let mut pair = Pair::new(
            Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
            config,
        );
        let (_client, server) = pair.connect();
        pair.drive();
        let stream = pair.server_streams(server).open(Dir::Uni).unwrap();
        pair.server_send(server, stream)
            .write(&vec![0x5a; 32 * 1024])
            .unwrap();
        let now = pair.time;
        pair.server_conn_mut(server)
            .assert_mtu_progress_with_a_full_window(now);
    }
}

#[test]
fn either_pto_datagram_recovers_a_small_stream_tail() {
    for gso in [false, true] {
        let mut config = server_config();
        Arc::get_mut(&mut config.transport)
            .unwrap()
            .set_enable_segmentation_offload(gso)
            .maybe_set_mtu_discovery_config(None);
        let mut pair = Pair::new(
            Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
            config,
        );
        let (client, server) = pair.connect();
        pair.drive();
        let stream = pair.server_streams(server).open(Dir::Uni).unwrap();
        pair.server_send(server, stream)
            .write(b"small tail")
            .unwrap();
        pair.server_send(server, stream).finish().unwrap();
        pair.drive_server();
        pair.client.inbound.clear();
        pair.time = pair.server_conn_mut(server).loss_detection_timer().unwrap();
        pair.drive_server();
        assert_eq!(pair.client.inbound.len(), 2);
        pair.client.inbound.pop_front();
        pair.drive_client();
        let mut recv = pair.client_recv(client, stream);
        let mut chunks = recv.read(true).unwrap();
        assert_eq!(
            chunks.next(usize::MAX).unwrap().unwrap().bytes,
            b"small tail"[..]
        );
        assert!(chunks.next(usize::MAX).unwrap().is_none());
        let _transmit = chunks.finalize();
        pair.drive();
    }
}

#[test]
fn second_handshake_probe_recovers_when_the_first_is_lost() {
    for gso in [false, true] {
        let mut config = server_config();
        Arc::get_mut(&mut config.transport)
            .unwrap()
            .set_enable_segmentation_offload(gso)
            .maybe_set_mtu_discovery_config(None);
        let mut pair = Pair::new(
            Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
            config,
        );
        let client = pair.begin_connect(client_config());
        pair.drive_client();
        pair.drive_server();
        let server = pair.server.assert_accept();
        assert_eq!(
            pair.client.inbound.len(),
            1,
            "one server flight; standalone 0.5-RTT controls must not consume amplification credit"
        );
        pair.client.inbound.clear();
        pair.time = pair.server_conn_mut(server).loss_detection_timer().unwrap();
        pair.drive_server();
        assert_eq!(
            pair.client.inbound.len(),
            2,
            "one PTO has credit for two complete flights"
        );
        pair.client.inbound.pop_front();
        pair.drive_client();
        assert!(
            !pair.client_conn_mut(client).is_handshaking(),
            "the second probe must independently supply Initial and Handshake CRYPTO"
        );
        pair.drive();
        assert!(!pair.server_conn_mut(server).is_handshaking());
    }
}

#[test]
fn pending_application_data_does_not_suppress_initial_pto() {
    let mut pair = Pair::default();
    pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    let server = pair.server.assert_accept();
    let stream = pair.server_streams(server).open(Dir::Uni).unwrap();
    pair.server_send(server, stream)
        .write(b"waiting for the handshake")
        .unwrap();
    let now = pair.time;
    pair.server_conn_mut(server)
        .assert_initial_probe_with_pending_stream(now);
}

#[test]
fn early_initial_recovery_obeys_congestion_and_amplification_limits() {
    let mut pair = Pair::default();
    pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    let server = pair.server.assert_accept();
    let now = pair.time;
    pair.server_conn_mut(server)
        .assert_early_crypto_obeys_send_limits(now);
}

#[test]
fn client_finished_early_recovery_is_bounded_and_ack_aware() {
    for late_ack in [false, true] {
        let mut pair = Pair::default();
        let client = pair.begin_connect(client_config());
        pair.drive_client();
        pair.drive_server();
        pair.drive_client();
        pair.server.inbound.clear(); // Finished is in flight, not delivered.
        let now = pair.time;
        pair.client_conn_mut(client)
            .assert_client_finished_recovery_limits(now, late_ack);
    }
}

#[test]
fn repeated_server_handshake_recovers_lost_finished_before_client_pto() {
    for gso in [false, true] {
        let mut server_config = server_config();
        Arc::get_mut(&mut server_config.transport)
            .unwrap()
            .set_initial_rtt(Duration::from_micros(100))
            .set_enable_segmentation_offload(gso)
            .maybe_set_mtu_discovery_config(None);
        let mut config = client_config();
        Arc::get_mut(&mut config.transport)
            .unwrap()
            .set_enable_segmentation_offload(gso)
            .maybe_set_mtu_discovery_config(None);
        let mut pair = Pair::new(
            Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
            server_config,
        );
        let client = pair.begin_connect(config);
        pair.drive_client();
        pair.drive_server();
        let server = pair.server.assert_accept();
        pair.drive_client();
        assert!(!pair.client_conn_mut(client).is_handshaking());
        assert!(!pair.client_conn_mut(client).handshake_confirmed());
        pair.server.inbound.clear(); // Lose the client's Finished and ACK.

        pair.time = pair.client_conn_mut(client).loss_detection_timer().unwrap();
        pair.drive_client();
        pair.server.inbound.clear(); // Lose both first-PTO recovery probes.
        let next_client_pto = pair.client_conn_mut(client).loss_detection_timer().unwrap();
        let backoff = pair.client_conn_mut(client).pto_count_for_test();
        assert_eq!(backoff, 1);
        let before = pair.client_conn_mut(client).stats().frame_tx.crypto;
        pair.time = pair.server_conn_mut(server).loss_detection_timer().unwrap();
        assert!(pair.time < next_client_pto);
        pair.drive_server(); // Retransmit the already-consumed server flight.
        pair.drive_client();
        assert!(
            pair.client_conn_mut(client).stats().frame_tx.crypto > before,
            "repeat the unacknowledged Finished with the ACK before another PTO"
        );
        assert_eq!(pair.client_conn_mut(client).pto_count_for_test(), backoff);
        let replies: Vec<_> = pair
            .server
            .inbound
            .iter()
            .map(|p| p.packet.clone())
            .collect();
        assert!(
            replies.iter().any(|packet| {
                let frames = pair
                    .client_conn_mut(client)
                    .sent_datagram_frames_for_test(packet);
                frames.iter().any(|f| matches!(f, frame::Frame::Crypto(_)))
                    && frames.iter().any(|f| matches!(f, frame::Frame::Ack(_)))
            }),
            "Finished and ACK share the same datagram"
        );
        pair.drive_server();
        pair.drive_client();
        assert!(pair.client_conn_mut(client).handshake_confirmed());
        assert!(!pair.server_conn_mut(server).is_handshaking());
        assert!(pair.time < next_client_pto);
        pair.drive();
    }
}

#[test]
fn duplicate_client_hello_recovers_initial_crypto_before_server_pto() {
    let mut pair = Pair::default();
    let client = pair.begin_connect(client_config());
    pair.drive_client();
    // Offset the server's first flight so the client's PTO occurs first.
    pair.time += Duration::from_millis(100);
    pair.drive_server();
    let server = pair.server.assert_accept();
    pair.client.inbound.clear(); // Lose the complete server flight.
    pair.server_sent.clear();
    let before = pair.server_conn_mut(server).stats().frame_tx.crypto;
    let server_pto = pair.server_conn_mut(server).loss_detection_timer().unwrap();
    pair.time = pair.client_conn_mut(client).loss_detection_timer().unwrap();
    assert!(pair.time < server_pto);
    pair.drive_client();
    pair.drive_server();
    assert!(
        pair.server_conn_mut(server).stats().frame_tx.crypto > before,
        "duplicate ClientHello should recover unacknowledged CRYPTO before the server PTO"
    );
    assert!(pair.server_sent.iter().any(|datagram| {
        datagram
            .packets
            .iter()
            .any(|packet| packet.long_kind() == Some(LongKind::Initial))
    }));
    pair.drive();
    assert!(!pair.client_conn_mut(client).is_handshaking());
    assert!(!pair.server_conn_mut(server).is_handshaking());
}

#[test]
fn path_challenges_are_spaced_across_a_transmit_burst() {
    let mut pair = Pair::default();
    let (_, server) = pair.connect();
    pair.drive();
    let stream = pair.server_streams(server).open(Dir::Uni).unwrap();
    pair.server_send(server, stream)
        .write(&vec![0x5a; 8000])
        .unwrap();
    pair.server_conn_mut(server).set_challenge(0x1234);
    let before = pair.server_conn_mut(server).stats().frame_tx;
    pair.drive_server();
    let after = pair.server_conn_mut(server).stats().frame_tx;
    assert!(after.stream - before.stream >= 4, "a real packet burst");
    assert_eq!(after.path_challenge - before.path_challenge, 1);
    let now = pair.time;
    pair.server_conn_mut(server)
        .assert_challenge_retry_survives_packet_ack(now);
}

#[test]
fn one_pto_recovers_distinct_tail_packets_with_and_without_gso() {
    for gso in [false, true] {
        let mut config = server_config();
        let mut transport = TransportConfig::default();
        transport
            .maybe_set_mtu_discovery_config(None)
            .set_enable_segmentation_offload(gso);
        config.set_transport_config(Arc::new(transport));
        let mut pair = Pair::new(
            Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
            config,
        );
        let (client, server) = pair.connect();
        pair.drive();
        let stream = pair.server_streams(server).open(Dir::Uni).unwrap();
        let body = vec![0x5a; 1800];
        pair.server_send(server, stream).write(&body).unwrap();
        pair.server_send(server, stream).finish().unwrap();
        pair.drive_server();
        pair.client.inbound.clear();
        pair.client.capture_inbound_packets = true;
        pair.time = pair.server_conn_mut(server).loss_detection_timer().unwrap();
        pair.drive_server();
        pair.client.drive(pair.time, pair.server.addr);
        let mut received = Vec::new();
        for packet in &pair.client.captured_packets {
            for frame in frame::Iter::new(packet.clone().into()).unwrap() {
                if let Frame::Stream(frame) = frame.unwrap() {
                    received.push(frame.offset..frame.offset + frame.data.len() as u64);
                }
            }
        }
        assert!(
            received.len() >= 2,
            "both probes should carry tail data: {received:?}"
        );
        assert_eq!(received[0].start, 0);
        assert_eq!(
            received[0].end, received[1].start,
            "distinct probes: {received:?}"
        );
        assert_eq!(received.last().unwrap().end, body.len() as u64);
        let mut recv = pair.client_recv(client, stream);
        let mut chunks = recv.read(true).unwrap();
        let mut delivered = Vec::new();
        while let Some(chunk) = chunks.next(usize::MAX).unwrap() {
            delivered.extend_from_slice(&chunk.bytes);
        }
        let _transmit = chunks.finalize();
        assert_eq!(delivered, body);
    }
}

#[test]
fn pto_remains_ack_eliciting_when_fin_waits_for_a_large_datagram() {
    let mut config = client_config();
    let mut transport = TransportConfig::default();
    transport
        .maybe_set_mtu_discovery_config(None)
        .set_initial_mtu(1452);
    config.transport = Arc::new(transport);
    let mut pair = Pair::default();
    pair.mtu = 1500;
    let (client, _) = pair.connect_with(config);
    pair.drive();
    pair.client_conn_mut(client).ping();
    pair.drive_client();
    pair.server.inbound.clear();

    let stream = pair.client_streams(client).open(Dir::Uni).unwrap();
    pair.client_datagrams(client)
        .send(vec![0x5a; 1300].into(), false)
        .unwrap();
    let position = pair.client_datagrams(client).send_queue_end();
    pair.client_send(client, stream).track_datagram(position);
    pair.client_send(client, stream).finish().unwrap();
    pair.client_conn_mut(client)
        .exhaust_congestion_window_for_probe();
    let before = pair.client_conn_mut(client).stats().frame_tx;
    pair.server.capture_inbound_packets = true;
    pair.time = pair.client_conn_mut(client).loss_detection_timer().unwrap();
    pair.drive_client();
    pair.server.drive_incoming(pair.time, pair.client.addr);

    let after = pair.client_conn_mut(client).stats().frame_tx;
    assert_eq!(after.ping - before.ping, 2, "both probes must elicit ACKs");
    assert_eq!(
        after.datagram, before.datagram,
        "the datagram cannot fit the probe"
    );
    assert_eq!(
        after.stream, before.stream,
        "FIN remains behind the datagram"
    );
    assert!(
        pair.server.captured_packets.iter().any(|packet| {
            frame::Iter::new(packet.clone().into())
                .unwrap()
                .any(|frame| matches!(frame.unwrap(), Frame::Ping))
        }),
        "a deferred FIN must not suppress the probe's PING"
    );
}

#[test]
fn tail_stream_and_fin_recover_from_pto_without_any_ack() {
    for allow_spin in [true, false] {
        let (mut pair, client, server) = (0u8..=255)
            .find_map(|seed| {
                let mut config = server_config();
                let mut transport = TransportConfig::default();
                transport.set_allow_spin(allow_spin);
                transport.maybe_set_mtu_discovery_config(None);
                config.set_transport_config(Arc::new(transport));
                let mut pair = Pair::new(
                    Arc::new(
                        EndpointConfig::try_with_rand_key()
                            .unwrap()
                            .with_rng_seed([seed; 32]),
                    ),
                    config,
                );
                let mut client_config = client_config();
                Arc::make_mut(&mut client_config.transport).set_allow_spin(allow_spin);
                let (client, server) = pair.connect_with(client_config);
                (pair.client_conn_mut(client).spin_enabled_for_test() == allow_spin
                    && pair.server_conn_mut(server).spin_enabled_for_test() == allow_spin)
                    .then_some((pair, client, server))
            })
            .expect("fixed-seed fixture with requested activation");
        pair.drive();
        let stream = pair.server_streams(server).open(Dir::Uni).unwrap();
        let body = vec![0x5a; 1024];
        pair.server_send(server, stream).write(&body).unwrap();
        pair.server_send(server, stream).finish().unwrap();
        pair.drive_server();
        pair.client.inbound.clear();

        // Lose the tail, then every returning ACK. A probe itself must deliver the
        // bytes and FIN; a PING depending on a future ACK cannot recover this loss.
        let before = pair.server_conn_mut(server).stats().frame_tx.stream;
        pair.time = pair.server_conn_mut(server).loss_detection_timer().unwrap();
        pair.drive_server();
        assert!(pair.server_conn_mut(server).stats().frame_tx.stream > before);
        pair.client.drive(pair.time, pair.server.addr);
        pair.client.outbound.clear();
        let mut recv = pair.client_recv(client, stream);
        let mut chunks = recv.read(true).unwrap();
        let chunk = chunks.next(usize::MAX).unwrap().unwrap();
        assert_eq!(chunk.bytes.as_ref(), body);
        assert!(chunks.next(usize::MAX).unwrap().is_none());
        let _transmit = chunks.finalize();
        assert_eq!(pair.server_conn_mut(server).stats().path.lost_packets, 0);

        // A later PTO must still carry unacknowledged stream data. It must not
        // reopen a receiver that already consumed the FIN, or duplicate the data.
        pair.time = pair.server_conn_mut(server).loss_detection_timer().unwrap();
        pair.drive_server();
        assert!(pair.server_conn_mut(server).stats().frame_tx.stream > before + 1);
        pair.client.drive(pair.time, pair.server.addr);
        assert!(!pair.client_conn_mut(client).is_closed());
        // Finally allow ACKs to settle either copy and free the sender exactly once.
        pair.drive();
        assert_eq!(pair.server_streams(server).send_streams(), 0);
    }
}

#[test]
fn handshake_pto_shares_two_datagram_budget_across_spaces() {
    for initial_size in [90, 1178, 2400] {
        for max_datagrams in [1, 10] {
            let mut pair = Pair::default();
            pair.begin_connect(client_config());
            pair.drive_client();
            pair.drive_server();
            let server = pair.server.assert_accept();
            pair.server_conn_mut(server)
                .assert_handshake_probe_datagram_budget(initial_size, max_datagrams);
        }
    }
}

#[test]
fn tail_probe_keeps_original_ack_and_respects_reset() {
    for reset in [false, true] {
        let mut config = server_config();
        let mut transport = TransportConfig::default();
        transport.maybe_set_mtu_discovery_config(None);
        config.set_transport_config(Arc::new(transport));
        let mut pair = Pair::new(
            Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
            config,
        );
        let (_, server) = pair.connect();
        pair.drive();
        let stream = pair.server_streams(server).open(Dir::Uni).unwrap();
        pair.server_send(server, stream)
            .write(b"original copy")
            .unwrap();
        pair.server_send(server, stream).finish().unwrap();
        pair.drive_server();
        pair.client.drive(pair.time, pair.server.addr);
        pair.time += Duration::from_millis(30);
        pair.client.drive(pair.time, pair.server.addr);
        assert!(!pair.client.outbound.is_empty());
        let before = pair.server_conn_mut(server).stats().frame_tx.stream;
        pair.time = pair.server_conn_mut(server).loss_detection_timer().unwrap();
        let now = pair.time;
        pair.server_conn_mut(server).handle_timeout(now);
        if reset {
            pair.server_send(server, stream).reset(0u32.into()).unwrap();
        }
        pair.drive_server();
        let after = pair.server_conn_mut(server).stats().frame_tx.stream;
        assert_eq!(after > before, !reset);
        pair.client.inbound.clear(); // No ACK of any probe can reach the server.
        pair.drive_client(); // Deliver only the original copy's delayed ACK.
        pair.drive_server();
        if !reset {
            assert_eq!(pair.server_streams(server).send_streams(), 0);
        }
        assert!(!pair.server_conn_mut(server).is_closed());
    }
}

#[test]
fn handshake_pto_probes_both_spaces_and_coalesces() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let client = pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    let server = pair.server.assert_accept();
    pair.client.inbound.clear();
    pair.server_sent.clear();

    // Lose the entire server flight. The client needs both ServerHello and the
    // Handshake CRYPTO, so a PTO must repair both spaces in the same round.
    pair.time = pair.server_conn_mut(server).loss_detection_timer().unwrap();
    pair.drive_server();
    assert!(
        pair.server_sent.iter().any(|datagram| {
            datagram
                .packets
                .iter()
                .any(|packet| packet.long_kind() == Some(LongKind::Initial))
                && datagram
                    .packets
                    .iter()
                    .any(|packet| packet.long_kind() == Some(LongKind::Handshake))
        }),
        "a probe should coalesce Initial and Handshake instead of padding"
    );
    // Only PTO probes reached the client. Completing TLS now proves those
    // probes carried both spaces' CRYPTO, not just ACKs or empty PINGs.
    pair.client.drive(pair.time, pair.server.addr);
    assert!(!pair.client_conn_mut(client).is_handshaking());
}

#[test]
fn batched_path_challenges_each_receive_one_wire_response() {
    for client_answers in [true, false] {
        let mut pair = Pair::default();
        let (client, server) = pair.connect();
        pair.drive();

        // Two authenticated packets arrive before the receiving endpoint is
        // driven, as some peers send paired validation probes after NAT rebinding.
        for token in [0xAA, 0xBB] {
            if client_answers {
                pair.server_conn_mut(server).set_challenge(token);
                pair.drive_server();
            } else {
                pair.client_conn_mut(client).set_challenge(token);
                pair.drive_client();
            }
        }
        let packets = if client_answers {
            assert!(pair.client.inbound.len() >= 2);
            assert!(pair.client.outbound.is_empty());
            pair.server.capture_inbound_packets = true;
            pair.drive_client();
            pair.server.drive_incoming(pair.time, pair.client.addr);
            &pair.server.captured_packets
        } else {
            assert!(pair.server.inbound.len() >= 2);
            assert!(pair.server.outbound.is_empty());
            pair.client.capture_inbound_packets = true;
            pair.drive_server();
            pair.client.drive_incoming(pair.time, pair.server.addr);
            &pair.client.captured_packets
        };
        let mut responses = Vec::new();
        let mut response_packets = 0;
        for packet in packets {
            let before = responses.len();
            for frame in frame::Iter::new(packet.clone().into()).unwrap() {
                if let Frame::PathResponse(token) = frame.unwrap() {
                    responses.push(token);
                }
            }
            response_packets += usize::from(responses.len() > before);
        }
        assert_eq!(responses, [0xAA, 0xBB]);
        assert_eq!(
            response_packets, 1,
            "queued answers share one padded packet"
        );
    }
}

#[test]
fn discarding_initial_keys_resets_pto_backoff() {
    let mut pair = Pair::default();
    let client = pair.begin_connect(client_config());
    pair.client.drive(pair.time, pair.server.addr);

    // Lose two Initial flights before the server receives anything. No ACK or
    // RTT sample can reset the client's exponential backoff in this phase.
    for count in 1..=2 {
        assert!(!pair.client.outbound.is_empty());
        pair.client.outbound.clear();
        pair.time = pair.client_conn_mut(client).loss_detection_timer().unwrap();
        pair.client.drive(pair.time, pair.server.addr);
        pair.client_conn_mut(client)
            .assert_pto_backoff(SpaceId::Initial, count);
    }

    // Deliver the next flight and the server's response, but lose the client's
    // Finished. Discarding Initial keys must start Handshake PTO without the
    // inherited 4x delay, even though no Handshake ACK has reached the client.
    pair.drive_client();
    pair.drive_server();
    pair.client.drive(pair.time, pair.server.addr);
    pair.client_conn_mut(client)
        .assert_pto_backoff(SpaceId::Handshake, 0);
    pair.client.outbound.clear();
    pair.time = pair.client_conn_mut(client).loss_detection_timer().unwrap();
    pair.client.drive(pair.time, pair.server.addr);
    assert!(!pair.client.outbound.is_empty());
    pair.client_conn_mut(client)
        .assert_pto_backoff(SpaceId::Handshake, 1);

    pair.drive();
    assert!(pair.client_conn_mut(client).handshake_confirmed());
}

#[test]
fn ack_delay_limit_applies_after_handshake_confirmation() {
    let mut pair = Pair::default();
    let client = pair.begin_connect(client_config());
    pair.step();
    let server = pair.server.assert_accept();
    pair.server_conn_mut(server).hold_handshake_done(true);
    drive_settled(&mut pair);
    assert!(!pair.client_conn_mut(client).handshake_confirmed());
    let now = pair.time;
    pair.client_conn_mut(client)
        .assert_ack_delay_tracks_handshake_confirmation(now);

    pair.server_conn_mut(server).hold_handshake_done(false);
    drive_settled(&mut pair);
    assert!(pair.client_conn_mut(client).handshake_confirmed());
    let now = pair.time;
    pair.client_conn_mut(client)
        .assert_ack_delay_tracks_handshake_confirmation(now);
}

#[test]
fn application_data_pto_waits_for_handshake_confirmation() {
    let mut pair = Pair::default();
    let client = pair.begin_connect(client_config());
    pair.step();
    let server = pair.server.assert_accept();
    pair.server_conn_mut(server).hold_handshake_done(true);
    drive_settled(&mut pair);
    assert!(!pair.client_conn_mut(client).is_handshaking());
    assert!(!pair.client_conn_mut(client).handshake_confirmed());

    // A peer may ACK the client's Finished separately from HANDSHAKE_DONE.
    // Rama's server discards its Handshake keys at completion, so supply that
    // valid ACK explicitly to isolate the Data timer from Handshake PTO.
    let now = pair.time;
    pair.client_conn_mut(client)
        .acknowledge_handshake_for_pto_test(now);

    let stream = pair.client_streams(client).open(Dir::Uni).unwrap();
    pair.client_send(client, stream)
        .write(b"waiting for confirmation")
        .unwrap();
    pair.client.drive(pair.time, pair.server.addr);
    assert!(!pair.client.outbound.is_empty());
    pair.client.outbound.clear();
    assert!(
        pair.client_conn_mut(client)
            .loss_detection_timer()
            .is_none()
    );

    // HANDSHAKE_DONE enables Data PTO for the same still-outstanding packet.
    pair.server_conn_mut(server).hold_handshake_done(false);
    pair.drive_server();
    pair.client.drive(pair.time, pair.server.addr);
    assert!(pair.client_conn_mut(client).handshake_confirmed());
    assert!(
        pair.client_conn_mut(client)
            .loss_detection_timer()
            .is_some()
    );
}

#[test]
fn extreme_time_threshold_preserves_packet_loss_detection_and_pto() {
    let mut config = server_config();
    let mut transport = TransportConfig::default();
    transport.try_set_time_threshold(f32::MAX).unwrap();
    transport.set_packet_threshold(1);
    transport.maybe_set_mtu_discovery_config(None);
    config.set_transport_config(Arc::new(transport));
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        config,
    );
    let (client, server) = pair.connect();
    pair.drive();

    let stream = pair.server_streams(server).open(Dir::Uni).unwrap();
    pair.server_send(server, stream)
        .write(b"recover me")
        .unwrap();
    pair.server.drive(pair.time, pair.client.addr);
    assert!(!pair.server.outbound.is_empty());
    pair.server.outbound.clear();
    let deadline = pair.server_conn_mut(server).loss_detection_timer().unwrap();
    let before = pair.server_conn_mut(server).stats().frame_tx;
    pair.time = deadline;
    pair.drive_server();
    let after = pair.server_conn_mut(server).stats().frame_tx;
    // A peer supporting ACK frequency is probed with IMMEDIATE_ACK; otherwise the
    // empty PTO probe uses PING. Both elicit the ACK needed for packet-threshold loss.
    assert!(after.immediate_ack + after.ping > before.immediate_ack + before.ping);
    pair.drive();

    assert!(pair.server_conn_mut(server).stats().path.lost_packets > 0);
    assert!(!pair.server_conn_mut(server).is_closed());
    assert!(!pair.client_conn_mut(client).is_closed());
    let mut recv = pair.client_recv(client, stream);
    let mut chunks = recv.read(true).unwrap();
    let chunk = chunks.next(usize::MAX).unwrap().unwrap();
    assert_eq!(chunk.bytes.as_ref(), b"recover me");
    let _transmit = chunks.finalize();
}

#[test]
fn old_path_ack_settles_stream_without_training_replacement_path() {
    let mut config = server_config();
    let mut transport = TransportConfig::default();
    transport.maybe_set_mtu_discovery_config(None);
    config.set_transport_config(Arc::new(transport));
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        config,
    );
    let (_, server) = pair.connect();
    pair.drive();
    let stream = pair.server_streams(server).open(Dir::Uni).unwrap();
    pair.server_send(server, stream)
        .write(b"old path delivery")
        .unwrap();
    pair.server_send(server, stream).finish().unwrap();
    pair.drive_server();
    pair.client.drive(pair.time, pair.server.addr);
    pair.time += Duration::from_millis(30);
    pair.client.drive(pair.time, pair.server.addr);
    assert!(!pair.client.outbound.is_empty());
    assert_eq!(pair.server_streams(server).send_streams(), 1);

    let now = pair.time;
    pair.server_conn_mut(server)
        .replace_recovery_path_for_test(now);
    let before_rtt = pair.server_conn_mut(server).rtt();
    let before_cwnd = pair.server_conn_mut(server).stats().path.cwnd;
    pair.drive_client();
    pair.server.drive(pair.time, pair.client.addr);
    assert_eq!(pair.server_streams(server).send_streams(), 0);
    assert_eq!(pair.server_conn_mut(server).rtt(), before_rtt);
    assert_eq!(pair.server_conn_mut(server).stats().path.cwnd, before_cwnd);
}

#[test]
fn rebinding_restarts_pending_mtu_probe() {
    let mut pair = Pair::default();
    let (_, server) = pair.connect();
    let now = pair.time;
    pair.server_conn_mut(server)
        .assert_rebinding_restarts_pending_mtu_probe(now);
}

#[test]
fn mixed_path_losses_train_only_current_path_and_retire_old_probes() {
    let mut pair = Pair::default();
    let (_, server) = pair.connect();
    pair.drive();
    let now = pair.time;
    pair.server_conn_mut(server)
        .assert_mixed_path_loss_is_scoped(now);
}

#[test]
fn old_path_ecn_advances_feedback_without_penalizing_current_path() {
    let mut pair = Pair::default();
    let (_, server) = pair.connect();
    pair.drive();
    let now = pair.time;
    pair.server_conn_mut(server)
        .assert_old_path_ecn_only_advances_feedback(now);
}

#[test]
fn ecn_validation_counts_packets_instead_of_contiguous_runs() {
    for offsets in [&[0, 1, 2, 3][..], &[0, 2, 3, 7][..]] {
        for (reported, expected_enabled) in [(3, false), (4, true), (9, true)] {
            let mut pair = Pair::default();
            let (client, server) = pair.connect();
            pair.drive();
            let now = pair.time;
            let counts = Some(rama_quic_proto::frame::EcnCounts {
                ect0: reported,
                ect1: 0,
                ce: 0,
            });
            pair.client_conn_mut(client).assert_ecn_feedback(
                now,
                offsets,
                counts,
                expected_enabled,
            );
            pair.server_conn_mut(server).assert_ecn_feedback(
                now,
                offsets,
                counts,
                expected_enabled,
            );
        }
    }
}

#[test]
fn current_path_ecn_rejects_bleaching_corruption_and_missing_feedback() {
    use rama_quic_proto::frame::EcnCounts;

    for counts in [
        None,
        Some(EcnCounts::ZERO),
        Some(EcnCounts {
            ect0: 1,
            ect1: 0,
            ce: 0,
        }),
        Some(EcnCounts {
            ect0: 0,
            ect1: 2,
            ce: 0,
        }),
        Some(EcnCounts {
            ect0: 2,
            ect1: 1,
            ce: 0,
        }),
    ] {
        let mut pair = Pair::default();
        let (client, server) = pair.connect();
        pair.drive();
        let now = pair.time;
        pair.client_conn_mut(client)
            .assert_ecn_feedback(now, &[0, 1], counts, false);
        pair.server_conn_mut(server)
            .assert_ecn_feedback(now, &[0, 1], counts, false);
    }
}

#[test]
fn current_path_ecn_accepts_congestion_marks_and_lost_ack_counts() {
    use rama_quic_proto::frame::EcnCounts;

    for counts in [
        EcnCounts {
            ect0: 1,
            ect1: 0,
            ce: 1,
        },
        EcnCounts {
            ect0: 0,
            ect1: 0,
            ce: 2,
        },
        EcnCounts {
            ect0: 4,
            ect1: 0,
            ce: 2,
        },
    ] {
        let mut pair = Pair::default();
        let (client, server) = pair.connect();
        pair.drive();
        let now = pair.time;
        pair.client_conn_mut(client)
            .assert_ecn_feedback(now, &[0, 1], Some(counts), true);
        pair.server_conn_mut(server)
            .assert_ecn_feedback(now, &[0, 1], Some(counts), true);
    }
}
