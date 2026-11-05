//! Protected-packet reproductions of external peers' preferred-address behavior.

use super::*;

#[test]
fn unanswered_preferred_validation_preserves_limits_and_fallback() {
    for close in [false, true] {
        let (mut pair, preferred) = pair_preferring(true);
        let (client, server) = connect_armed(&mut pair);
        let original = pair.server.addr;
        let cid = pair.client_conn_mut(client).active_rem_cid();
        let now = pair.time;
        let packet = pair
            .client_conn_mut(client)
            .encode_peer_packet_for_test(now, cid, &[1]); // PING
        pair.server.inbound.push_back(Inbound {
            at: now,
            ecn: None,
            packet,
            from: Some(pair.client.addr),
            to: Some(preferred),
        });
        pair.server.drive(now, pair.client.addr);
        assert_eq!(pair.server_conn_mut(server).path_local(), Some(original));
        let stream = pair.server_streams(server).open(Dir::Uni).unwrap();
        pair.server_send(server, stream)
            .write(b"fallback remains usable")
            .unwrap();
        pair.server_send(server, stream).finish().unwrap();
        if close {
            pair.server.outbound.clear();
            pair.server_conn_mut(server)
                .close(now, 0u32.into(), Bytes::new());
            pair.server.drive(now, pair.client.addr);
            assert_eq!(pair.server_conn_mut(server).stats().frame_tx.stream, 0);
            assert_eq!(
                pair.server_conn_mut(server)
                    .stats()
                    .frame_tx
                    .connection_close,
                1
            );
            assert!(
                pair.server
                    .outbound
                    .iter()
                    .all(|(tx, _)| tx.local == Some(original))
            );
        } else {
            let mut sent_on_preferred = 0;
            for _ in 0..128 {
                pair.server.drive(pair.time, pair.client.addr);
                let sent: Vec<_> = pair.server.outbound.drain(..).collect();
                for (tx, bytes) in sent {
                    if tx.local == Some(preferred) {
                        sent_on_preferred += tx.size;
                        assert!(
                            pair.server_conn_mut(server)
                                .sent_frames_for_test(&bytes)
                                .iter()
                                .all(|f| matches!(
                                    f,
                                    frame::Frame::Padding
                                        | frame::Frame::PathChallenge(_)
                                        | frame::Frame::PathResponse(_)
                                ))
                        );
                        continue; // Only validation packets are lost.
                    }
                    assert_eq!(tx.local, Some(original));
                    pair.client.inbound.push_back(Inbound {
                        at: pair.time,
                        ecn: tx.ecn,
                        packet: bytes.as_ref().into(),
                        from: tx.local,
                        to: Some(pair.client.addr),
                    });
                }
                pair.drive_client();
                if !pair.server_conn_mut(server).server_candidate_pending() {
                    break;
                }
                pair.time = pair
                    .server
                    .next_wakeup()
                    .into_iter()
                    .chain(pair.client.next_wakeup())
                    .min()
                    .unwrap()
                    .max(pair.time);
            }
            assert!(!pair.server_conn_mut(server).server_candidate_pending());
            assert!(pair.server_conn_mut(server).stats().frame_tx.stream > 0);
            assert!(
                sent_on_preferred <= 3600,
                "three times the sole received datagram: {sent_on_preferred}"
            );
            assert_eq!(pair.server_conn_mut(server).path_local(), Some(original));
            drive_settled(&mut pair);
            let mut recv = pair.client_recv(client, stream);
            let mut chunks = recv.read(true).unwrap();
            assert_eq!(
                chunks.next(usize::MAX).unwrap().unwrap().bytes,
                b"fallback remains usable"[..]
            );
            assert!(chunks.next(usize::MAX).unwrap().is_none());
            let _transmit = chunks.finalize();
        }
    }
}

#[test]
fn preferred_address_validation_survives_reused_cid_ack_traffic() {
    let (mut pair, preferred) = pair_preferring(true);
    let (client, server) = connect_armed(&mut pair);
    let original = pair.server.addr;
    let reused_cid = pair.client_conn_mut(client).active_rem_cid();
    probe_once(&mut pair, server);
    assert!(pair.client_conn_mut(client).reserved_rem_cid().is_some());

    let stream = pair.server_streams(server).open(Dir::Uni).unwrap();
    let body = vec![0x5a; 1800];
    pair.server_send(server, stream).write(&body).unwrap();
    pair.server_send(server, stream).finish().unwrap();
    let before = pair.server_conn_mut(server).stats().frame_tx.stream;
    let mut acked = rama_quic_proto::range_set::ArrayRangeSet::new();
    acked.insert_one(pair.server_conn_mut(server).packet_numbers().1 - 1);
    let mut ack = Vec::new();
    frame::Ack::encode(0, &acked, None, &mut ack);

    // The peer probes using its fresh preferred CID, but sends ACKs on both
    // destinations using the original CID before receiving the probe response.
    // This is the sequence observed from ngtcp2 in the Docker matrix.
    for local in [preferred, original, preferred, original] {
        let now = pair.time;
        let packet = pair
            .client_conn_mut(client)
            .encode_peer_packet_for_test(now, reused_cid, &ack);
        pair.server.inbound.push_back(Inbound {
            at: now,
            ecn: None,
            packet,
            from: Some(pair.client.addr),
            to: Some(local),
        });
        pair.server.drive(now, pair.client.addr);
        assert_eq!(
            pair.server_conn_mut(server).path_local(),
            Some(original),
            "the validated original path remains active during preferred probing"
        );
        assert!(
            pair.server_conn_mut(server).stats().frame_tx.stream > before,
            "original-path traffic must progress during validation"
        );
        let emitted: Vec<_> = pair
            .server
            .outbound
            .iter()
            .map(|(tx, bytes)| (tx.local, bytes.clone()))
            .collect();
        for (local, bytes) in emitted {
            let frames = pair.server_conn_mut(server).sent_frames_for_test(&bytes);
            if local == Some(preferred) {
                assert!(
                    frames.iter().all(|f| matches!(
                        f,
                        frame::Frame::Padding
                            | frame::Frame::PathChallenge(_)
                            | frame::Frame::PathResponse(_)
                    )),
                    "only probes may leave the unvalidated preferred address: {frames:?}"
                );
            } else {
                assert_eq!(local, Some(original));
            }
        }
        assert!(!pair.server_conn_mut(server).is_closed());
    }
    assert!(pair.server_conn_mut(server).path_validated());
    let challenges = pair.server_conn_mut(server).stats().frame_tx.path_challenge;
    let client_stream = pair.client_streams(client).open(Dir::Uni).unwrap();
    pair.client_send(client, client_stream)
        .write(b"still on the original path")
        .unwrap();
    pair.client_send(client, client_stream).finish().unwrap();
    pair.drive_client();
    pair.server.drive(pair.time, pair.client.addr);
    assert_eq!(pair.server_conn_mut(server).path_local(), Some(original));
    assert!(pair.server_conn_mut(server).path_validated());
    assert_eq!(
        pair.server_conn_mut(server).stats().frame_tx.path_challenge,
        challenges,
        "original-path data must not restart validation"
    );
    let mut recv = pair.server_recv(server, client_stream);
    let mut chunks = recv.read(true).unwrap();
    assert_eq!(
        chunks.next(usize::MAX).unwrap().unwrap().bytes,
        b"still on the original path"[..]
    );
    assert!(chunks.next(usize::MAX).unwrap().is_none());
    let _transmit = chunks.finalize();
    let started = pair.time;
    // Deliver the held responses and validation probes. Both endpoints must
    // settle on the preferred path and deliver the entire queued stream.
    drive_settled(&mut pair);
    assert_eq!(pair.client_conn_mut(client).remote_address(), preferred);
    assert_eq!(pair.server_conn_mut(server).path_local(), Some(preferred));
    assert!(pair.server_conn_mut(server).path_validated());
    assert_eq!(pair.server_conn_mut(server).pto_count_for_test(), 0);
    assert!(pair.time - started < Duration::from_millis(100));
    let mut recv = pair.client_recv(client, stream);
    let mut chunks = recv.read(true).unwrap();
    let mut received = Vec::new();
    while let Some(chunk) = chunks.next(usize::MAX).unwrap() {
        received.extend_from_slice(&chunk.bytes);
    }
    let _transmit = chunks.finalize();
    assert_eq!(received, body);
}

#[test]
fn real_client_rebinding_during_preferred_probing_keeps_the_stream_usable() {
    let (mut pair, preferred) = pair_preferring(true);
    let (client, server) = connect_armed(&mut pair);
    let original = pair.server.addr;
    probe_once(&mut pair, server);
    let (old_cid, old_seq) = pair
        .server_conn_mut(server)
        .server_candidate_id_for_test()
        .unwrap();
    pair.server.outbound.clear(); // Lose the preferred response.
    pair.client
        .addr
        .set_port(CLIENT_PORTS.lock().next().unwrap());
    let rebound = pair.client.addr;
    let stream = pair.client_streams(client).open(Dir::Uni).unwrap();
    pair.client_send(client, stream)
        .write(b"rebinding during preferred validation")
        .unwrap();
    pair.client_send(client, stream).finish().unwrap();
    pair.drive_client();
    pair.server.drive(pair.time, rebound);
    assert_eq!(pair.server_conn_mut(server).remote_address(), rebound);
    assert_eq!(pair.server_conn_mut(server).path_local(), Some(original));
    assert!(!pair.server_conn_mut(server).server_candidate_pending());
    let retired = pair
        .server
        .outbound
        .iter()
        .map(|(_, bytes)| bytes.clone())
        .collect::<Vec<_>>();
    assert!(
        retired
            .iter()
            .flat_map(|bytes| pair.server_conn_mut(server).sent_frames_for_test(bytes))
            .any(|frame| matches!(frame, Frame::RetireConnectionId { sequence } if sequence == old_seq))
    );
    let fresh =
        probe_from(&mut pair, rebound, preferred, old_cid.len()).expect("fresh probe response");
    assert_ne!(fresh, old_cid.as_ref());
    assert_eq!(pair.server_conn_mut(server).remote_address(), rebound);
    let responses = pair.server.outbound.drain(..).collect();
    deliver_to_client(&mut pair, responses);
    drive_settled(&mut pair);
    assert!(!pair.client_conn_mut(client).is_closed());
    assert!(!pair.server_conn_mut(server).is_closed());
    let mut recv = pair.server_recv(server, stream);
    let mut chunks = recv.read(true).unwrap();
    assert_eq!(
        chunks.next(usize::MAX).unwrap().unwrap().bytes,
        b"rebinding during preferred validation"[..]
    );
    assert!(chunks.next(usize::MAX).unwrap().is_none());
    let _transmit = chunks.finalize();
}

#[test]
fn peer_retiring_server_candidate_cancels_its_probe_and_uses_a_fresh_cid() {
    let _guard = subscribe();
    let (mut pair, preferred) = pair_preferring(true);
    let (client, server) = connect_armed(&mut pair);
    probe_once(&mut pair, server);
    let (old_cid, old_seq) = pair
        .server_conn_mut(server)
        .server_candidate_id_for_test()
        .unwrap();
    pair.server.outbound.clear();
    let now = pair.time;
    pair.client_conn_mut(client)
        .rotate_local_cid(old_seq + 1, now);
    pair.drive_client();
    pair.server.drive(now, pair.client.addr);
    assert_ne!(
        pair.server_conn_mut(server).reserved_rem_cid(),
        Some(old_cid)
    );
    assert!(!pair.server_conn_mut(server).server_candidate_pending());
    let from = pair.client.addr;
    let fresh = probe_from(&mut pair, from, preferred, old_cid.len())
        .expect("client retries preferred probe after retirement");
    assert_ne!(fresh, old_cid.as_ref());
    let (_, new_seq) = pair
        .server_conn_mut(server)
        .server_candidate_id_for_test()
        .unwrap();
    assert!(new_seq > old_seq);
    let responses = pair.server.outbound.drain(..).collect();
    deliver_to_client(&mut pair, responses);
    drive_settled(&mut pair);
    assert!(!pair.client_conn_mut(client).is_closed());
    assert!(!pair.server_conn_mut(server).is_closed());
}

#[test]
fn repeated_unanswered_preferred_attempts_do_not_consume_cids_forever() {
    let (mut pair, preferred) = pair_preferring(true);
    let (client, server) = connect_armed(&mut pair);
    let original = pair.server.addr;
    let dcid = pair.client_conn_mut(client).active_rem_cid();
    let mut reserved = Vec::new();
    for attempt in 0..6 {
        let now = pair.time;
        let packet = pair
            .client_conn_mut(client)
            .encode_peer_packet_for_test(now, dcid, &[1]);
        pair.server.inbound.push_back(Inbound {
            at: now,
            ecn: None,
            packet,
            from: Some(pair.client.addr),
            to: Some(preferred),
        });
        pair.server.drive(now, pair.client.addr);
        if attempt < 3 {
            let (cid, _) = pair
                .server_conn_mut(server)
                .server_candidate_id_for_test()
                .unwrap();
            assert!(!reserved.contains(&cid));
            reserved.push(cid);
        } else {
            assert!(!pair.server_conn_mut(server).server_candidate_pending());
        }
        for _ in 0..64 {
            pair.server.outbound.clear();
            if !pair.server_conn_mut(server).server_candidate_pending() {
                break;
            }
            pair.time = pair.server.next_wakeup().unwrap().max(pair.time);
            pair.server.drive(pair.time, pair.client.addr);
        }
        assert!(!pair.server_conn_mut(server).server_candidate_pending());
        assert_eq!(pair.server_conn_mut(server).path_local(), Some(original));
        assert!(!pair.server_conn_mut(server).is_closed());
    }
    assert_eq!(reserved.len(), 3);
}

#[test]
fn simultaneous_preferred_and_source_move_keeps_old_cid_until_validation_expires() {
    let (mut pair, preferred) = pair_preferring(true);
    let (client, server) = connect_armed(&mut pair);
    let original = pair.server.addr;
    let old_source = pair.client.addr;
    let new_source = SocketAddr::new(old_source.ip(), old_source.port() + 1000);
    let old_cid = pair.server_conn_mut(server).active_rem_cid();
    let destination_cid = pair.client_conn_mut(client).active_rem_cid();
    let now = pair.time;
    let packet =
        pair.client_conn_mut(client)
            .encode_peer_packet_for_test(now, destination_cid, &[1]);
    pair.server.inbound.push_back(Inbound {
        at: now,
        ecn: None,
        packet,
        from: Some(new_source),
        to: Some(preferred),
    });
    pair.server.drive(now, old_source);
    let probe = pair
        .server
        .outbound
        .iter()
        .find(|(tx, _)| tx.local == Some(preferred))
        .unwrap()
        .1
        .clone();
    let challenge = pair
        .server_conn_mut(server)
        .sent_frames_for_test(&probe)
        .into_iter()
        .find_map(|f| match f {
            frame::Frame::PathChallenge(token) => Some(token),
            _ => None,
        })
        .unwrap();
    let reserved = pair.server_conn_mut(server).reserved_rem_cid().unwrap();
    assert_ne!(reserved, old_cid);
    pair.server.outbound.clear();
    let mut frames = vec![0x1b]; // PATH_RESPONSE followed by a newest non-probing PING.
    frames.extend_from_slice(&challenge.to_be_bytes());
    frames.push(1);
    let packet =
        pair.client_conn_mut(client)
            .encode_peer_packet_for_test(now, destination_cid, &frames);
    pair.server.inbound.push_back(Inbound {
        at: now,
        ecn: None,
        packet,
        from: Some(new_source),
        to: Some(preferred),
    });
    pair.server.drive(now, old_source);
    assert_eq!(pair.server_conn_mut(server).path_local(), Some(preferred));
    assert_eq!(pair.server_conn_mut(server).remote_address(), new_source);
    assert!(pair.server_conn_mut(server).path_validated());
    assert_eq!(pair.server_conn_mut(server).active_rem_cid(), reserved);
    assert_eq!(pair.server_conn_mut(server).held_rem_cid(), Some(old_cid));
    let old_probe = pair
        .server
        .outbound
        .iter()
        .find(|(tx, _)| tx.local == Some(original) && tx.destination == old_source)
        .expect("a source move challenges the original path")
        .1
        .clone();
    assert!(
        pair.server_conn_mut(server)
            .sent_frames_for_test(&old_probe)
            .iter()
            .any(|f| matches!(f, frame::Frame::PathChallenge(_)))
    );
    // Lose the old-path proof. Its independent deadline must retire the held
    // identifier without undoing the already validated preferred path.
    pair.server.outbound.clear();
    pair.time = pair
        .server_conn_mut(server)
        .path_validation_deadline()
        .unwrap();
    pair.server.drive(pair.time, old_source);
    assert_eq!(pair.server_conn_mut(server).held_rem_cid(), None);
    assert_eq!(pair.server_conn_mut(server).path_local(), Some(preferred));
    assert_eq!(pair.server_conn_mut(server).remote_address(), new_source);
    assert!(pair.server_conn_mut(server).path_validated());
    assert!(!pair.server_conn_mut(server).is_closed());
}

#[test]
fn preferred_probe_retry_does_not_displace_original_challenge_or_pto() {
    let (mut pair, preferred) = pair_preferring(true);
    let (client, server) = connect_armed(&mut pair);
    let original = pair.server.addr;
    let stream = pair.server_streams(server).open(Dir::Uni).unwrap();
    pair.server_send(server, stream)
        .write(b"recover original path")
        .unwrap();
    pair.server_conn_mut(server).set_challenge(0x1234);
    pair.drive_server();
    pair.client.inbound.clear(); // Lose original-path challenge and STREAM.
    let cid = pair.client_conn_mut(client).active_rem_cid();
    let now = pair.time;
    let packet = pair
        .client_conn_mut(client)
        .encode_peer_packet_for_test(now, cid, &[1]);
    pair.server.inbound.push_back(Inbound {
        at: now,
        ecn: None,
        packet,
        from: Some(pair.client.addr),
        to: Some(preferred),
    });
    pair.server.drive(now, pair.client.addr);
    pair.server.outbound.clear(); // Lose the candidate probe too.
    let (challenge_at, probe_at) = pair.server_conn_mut(server).validation_timers_for_test();
    let probe_at = probe_at.unwrap();
    assert!(challenge_at.is_some_and(|at| at <= probe_at));
    assert!(
        pair.server_conn_mut(server)
            .loss_detection_timer()
            .is_some_and(|at| at <= probe_at)
    );
    pair.time = probe_at;
    let before = pair.server_conn_mut(server).stats().frame_tx;
    pair.server.drive(pair.time, pair.client.addr);
    let after = pair.server_conn_mut(server).stats().frame_tx;
    assert!(
        after.stream > before.stream,
        "original data PTO remains live"
    );
    assert!(
        after.path_challenge >= before.path_challenge + 2,
        "both original and candidate validation retry"
    );
    assert!(
        pair.server
            .outbound
            .iter()
            .any(|(tx, _)| tx.local == Some(original))
    );
    assert!(
        pair.server
            .outbound
            .iter()
            .any(|(tx, _)| tx.local == Some(preferred))
    );
    let (challenge_at, probe_at) = pair.server_conn_mut(server).validation_timers_for_test();
    assert!(challenge_at.is_some_and(|at| at > pair.time));
    assert!(probe_at.is_some_and(|at| at > pair.time));
    assert!(
        pair.server_conn_mut(server)
            .loss_detection_timer()
            .is_some_and(|at| at > pair.time)
    );
    assert_eq!(pair.server_conn_mut(server).path_local(), Some(original));
    assert!(!pair.server_conn_mut(server).is_closed());
}

#[test]
fn sent_packets_decode_across_a_local_key_update() {
    let mut pair = Pair::default();
    let (_client, server) = pair.connect();
    // Early key updates fire after a random packet count; force one mid-stream.
    let sent = pair.server_conn_mut(server).packets_sent_with_keys();
    pair.server_conn_mut(server).set_key_phase_size(sent + 2);
    let stream = pair.server_streams(server).open(Dir::Uni).unwrap();
    pair.server_send(server, stream)
        .write(&[0x5a; 6000])
        .unwrap();
    pair.server_send(server, stream).finish().unwrap();
    pair.server.drive(pair.time, pair.client.addr);
    assert_eq!(pair.server_conn_mut(server).stats().key_updates, 1);
    let sent: Vec<_> = pair
        .server
        .outbound
        .iter()
        .map(|(_tx, bytes)| bytes.clone())
        .collect();
    assert!(sent.len() > 2, "packets on both sides of the update");
    let streamed = sent
        .iter()
        .flat_map(|bytes| pair.server_conn_mut(server).sent_frames_for_test(bytes))
        .filter(|frame| matches!(frame, frame::Frame::Stream(_)))
        .count();
    assert!(streamed > 2);
}
