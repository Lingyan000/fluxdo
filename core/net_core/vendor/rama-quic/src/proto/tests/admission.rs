use super::*;
use crate::proto::endpoint::incoming_datagram_charge;
use std::assert_matches;

const LIMIT: Duration = Duration::from_millis(100);

fn pair() -> Pair {
    let mut config = EndpointConfig::try_with_rand_key().unwrap();
    config.handshake_timeout(LIMIT).unwrap();
    let mut pair = Pair::new(Arc::new(config), server_config());
    pair.server.handle_incoming = Box::new(|_| IncomingConnectionBehavior::Wait);
    pair
}

fn incoming(pair: &mut Pair) -> (ConnectionHandle, Incoming) {
    let client = pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    (client, pair.server.waiting_incoming.pop().unwrap())
}

#[test]
fn expired_handles_cannot_remove_a_reused_admission_slot() {
    #[derive(Debug)]
    enum Action {
        Ignore,
        Accept,
        Retry,
        Refuse,
    }
    for action in [
        Action::Ignore,
        Action::Accept,
        Action::Retry,
        Action::Refuse,
    ] {
        let mut pair = pair();
        let (old_client, stale) = incoming(&mut pair);
        pair.time += LIMIT;
        assert_eq!(pair.server.expire_incoming(pair.time, 1), 1);
        assert!(stale.is_expired());
        assert!(!stale.may_retry());
        // Only the server-side stale handle participates in the slot reuse test.
        pair.client.connections.remove(&old_client);
        let (client, current) = incoming(&mut pair);
        assert_eq!(pair.server.pending_incoming(), 1);
        match action {
            Action::Ignore => pair.server.ignore(stale),
            Action::Accept => {
                let mut buf = Vec::new();
                assert_matches!(
                    pair.server.accept(stale, pair.time, &mut buf, None),
                    Err(AcceptError {
                        cause: ConnectionError::TimedOut,
                        ..
                    }),
                );
            }
            Action::Retry => {
                let stale = Endpoint::retry(&mut pair.server, stale, &mut Vec::new())
                    .unwrap_err()
                    .into_incoming();
                pair.server.ignore(stale);
            }
            Action::Refuse => {
                let _refused = pair.server.refuse(stale, &mut Vec::new());
            }
        }
        assert_eq!(pair.server.pending_incoming(), 1);
        assert!(!current.is_expired());
        pair.server.try_accept(current, pair.time).unwrap();
        assert_eq!(pair.server.pending_incoming(), 0);
        assert!(pair.server.poll_incoming_timeout().is_none());
        pair.drive();
        let event = pair.client_conn_mut(client).poll();
        assert_matches!(
            event,
            Some(Event::HandshakeDataReady),
            "action {action:?}: {event:?}",
        );
        assert_matches!(pair.client_conn_mut(client).poll(), Some(Event::Connected));
    }
}

#[test]
fn expiration_work_and_timer_storage_are_bounded_by_live_admissions() {
    let mut pair = pair();
    let mut handles = Vec::new();
    for _ in 0..3 {
        handles.push(incoming(&mut pair).1);
    }
    assert_eq!(pair.server.pending_incoming(), 3);
    pair.time += LIMIT;
    assert_eq!(pair.server.expire_incoming(pair.time, 2), 2);
    assert_eq!(pair.server.pending_incoming(), 1);
    assert!(pair.server.poll_incoming_timeout().unwrap() <= pair.time);
    assert_eq!(pair.server.expire_incoming(pair.time, 2), 1);
    assert!(pair.server.poll_incoming_timeout().is_none());
    for incoming in handles {
        pair.server.ignore(incoming);
    }
    for _ in 0..20 {
        let (_, handle) = incoming(&mut pair);
        pair.server.ignore(handle);
        assert_eq!(pair.server.pending_incoming(), 0);
        assert!(pair.server.poll_incoming_timeout().is_none());
    }
}

#[test]
fn acceptance_does_not_restart_the_handshake_deadline() {
    let mut pair = pair();
    let started = pair.time;
    let (_, incoming) = incoming(&mut pair);
    pair.time += LIMIT.checked_sub(Duration::from_millis(1)).unwrap();
    let server = pair.server.try_accept(incoming, pair.time).unwrap();
    pair.server_conn_mut(server).handle_timeout(started + LIMIT);
    let conn = pair.server_conn_mut(server);
    assert_matches!(conn.poll(), Some(Event::HandshakeDataReady));
    assert_matches!(
        conn.poll(),
        Some(Event::ConnectionLost {
            reason: ConnectionError::TimedOut
        }),
    );
}

#[test]
fn removing_server_config_while_holding_incoming_does_not_panic() {
    let mut pair = pair();
    let (_, incoming) = incoming(&mut pair);
    pair.server.set_server_config(None);
    assert_matches!(
        pair.server
            .accept(incoming, pair.time, &mut Vec::new(), None),
        Err(AcceptError {
            cause: ConnectionError::LocallyClosed,
            ..
        }),
    );
    assert_eq!(pair.server.pending_incoming(), 0);
    assert!(pair.server.poll_incoming_timeout().is_none());
}

#[test]
fn accept_replays_datagrams_buffered_while_pending() {
    let mut pair = pair();
    let client = pair.begin_connect(client_config());
    pair.drive_client();
    let retransmitted = pair.server.inbound.front().unwrap().clone();
    pair.drive_server();
    let incoming = pair.server.waiting_incoming.pop().unwrap();
    assert_eq!(pair.server.open_connections(), 0);
    assert_eq!(pair.server.incoming_buffer_bytes(), 0);

    let bytes = incoming_datagram_charge(retransmitted.packet.len());
    pair.server.inbound.push_back(retransmitted);
    pair.drive_server();
    assert_eq!(pair.server.incoming_buffer_bytes(), bytes);
    let server = pair.server.try_accept(incoming, pair.time).unwrap();
    assert_eq!(pair.server.incoming_buffer_bytes(), 0);
    assert_eq!(pair.server.pending_incoming(), 0);
    assert_eq!(pair.server.open_connections(), 1);
    assert_eq!(pair.server_conn_mut(server).stats().udp_rx.datagrams, 1);
    pair.drive();
    assert_matches!(
        pair.client_conn_mut(client).poll(),
        Some(Event::HandshakeDataReady)
    );
    assert_matches!(pair.client_conn_mut(client).poll(), Some(Event::Connected));
}

#[test]
fn duplicate_initial_reuses_live_state_but_can_recreate_expired_state() {
    let mut pair = pair();
    pair.begin_connect(client_config());
    pair.drive_client();
    let initial = pair.server.inbound.front().unwrap().clone();
    pair.drive_server();
    let incoming = pair.server.waiting_incoming.pop().unwrap();
    let original_cid = *incoming.orig_dst_cid();
    let server = pair.server.try_accept(incoming, pair.time).unwrap();
    pair.drive_server();
    pair.client.inbound.clear(); // The client never receives the server's chosen CID.

    pair.server.inbound.push_back(initial.clone());
    pair.drive_server();
    assert!(pair.server.waiting_incoming.is_empty());
    assert_eq!(pair.server.open_connections(), 1);
    assert!(!pair.server_conn_mut(server).is_closed());

    pair.time += LIMIT;
    pair.drive_server();
    assert!(pair.server_conn_mut(server).is_closed());
    assert_eq!(pair.server.open_connections(), 0);
    assert_eq!(pair.server.known_cids(), 0);

    // Once the old allocation has expired, this same unacknowledged Initial
    // is a new incoming attempt, not a duplicate live connection.
    pair.server.inbound.push_back(Inbound {
        at: pair.time,
        ..initial
    });
    pair.drive_server();
    assert_eq!(pair.server.waiting_incoming.len(), 1);
    let incoming = pair.server.waiting_incoming.pop().unwrap();
    assert_eq!(*incoming.orig_dst_cid(), original_cid);
    pair.server.try_accept(incoming, pair.time).unwrap();
    assert_eq!(pair.server.open_connections(), 1);
}

/// Without local connection IDs a Retry's follow-up Initials could not find their pending
/// attempt, so an unvalidated attempt under load is refused instead.
#[test]
fn without_local_cids_an_unvalidated_attempt_under_load_is_refused_not_retried() {
    let cid_generator_factory: fn() -> Box<dyn ConnectionIdGenerator> =
        || Box::new(RandomConnectionIdGenerator::new(0).expect("zero is a length"));
    let endpoint_config = Arc::new(EndpointConfig {
        connection_id_generator_factory: Arc::new(cid_generator_factory),
        ..EndpointConfig::try_with_rand_key().unwrap()
    });
    let always_retry = AdmissionConfig::default()
        .with_retry_threshold_min(0)
        .with_retry_threshold_max(0);
    let mut pair = Pair::new(
        endpoint_config,
        server_config().with_admission(always_retry),
    );
    let client = pair.begin_connect(client_config());
    pair.drive();
    let stats = pair.server.admission_stats();
    assert_eq!(stats.retried, 0);
    assert_eq!(stats.refused_unvalidated, 1);
    assert_matches!(
        pair.client_conn_mut(client).poll(),
        Some(Event::ConnectionLost {
            reason: ConnectionError::ConnectionClosed(close)
        }) if close.error_code == TransportErrorCode::CONNECTION_REFUSED
    );
}

#[test]
fn a_configured_client_deadline_allows_recovery_after_an_initial_blackout() {
    let _guard = subscribe();
    for gso in [false, true] {
        for extended in [false, true] {
            let mut endpoint = EndpointConfig::try_with_rand_key().unwrap();
            if extended {
                endpoint.handshake_timeout(Duration::from_secs(60)).unwrap();
            }
            let mut pair = Pair::new(Arc::new(endpoint), server_config());
            let mut config = client_config();
            Arc::make_mut(&mut config.transport).set_enable_segmentation_offload(gso);
            let client = pair.begin_connect(config);
            let started = pair.time;
            // No reply arrives before the default ten-second deadline. Preserve
            // PTO backoff: the next usable flight is sent around fifteen seconds.
            for seconds in [0, 1, 3, 7, 11] {
                pair.time = started + Duration::from_secs(seconds);
                pair.drive_client();
                pair.server.inbound.clear();
            }
            assert!(pair.server.connections.is_empty());
            if !extended {
                assert_matches!(
                    pair.client_conn_mut(client).poll(),
                    Some(Event::ConnectionLost {
                        reason: ConnectionError::TimedOut
                    })
                );
                continue;
            }
            assert!(!pair.client_conn_mut(client).is_closed());
            pair.drive();
            pair.server.assert_accept();
            assert_matches!(
                pair.client_conn_mut(client).poll(),
                Some(Event::HandshakeDataReady)
            );
            assert_matches!(pair.client_conn_mut(client).poll(), Some(Event::Connected));
            assert!(pair.time > started + Duration::from_secs(11));
            assert_eq!(pair.client.connections.len(), 1, "same attempt recovers");
        }
    }
}

#[test]
fn a_configured_server_deadline_allows_a_delayed_client_finished() {
    for gso in [false, true] {
        for extended in [false, true] {
            let mut endpoint = EndpointConfig::try_with_rand_key().unwrap();
            if extended {
                endpoint.handshake_timeout(Duration::from_secs(60)).unwrap();
            }
            let mut pair = Pair::new(Arc::new(endpoint), server_config());
            let mut config = client_config();
            Arc::make_mut(&mut config.transport).set_enable_segmentation_offload(gso);
            let client = pair.begin_connect(config);
            pair.drive_client();
            pair.drive_server();
            pair.drive_client();
            let server = pair.server.assert_accept();
            assert!(!pair.client_conn_mut(client).is_handshaking());
            assert!(pair.server_conn_mut(server).is_handshaking());
            let mut finished = std::mem::take(&mut pair.server.inbound);
            assert!(!finished.is_empty());

            // The client has the server's keys and CID, but its Finished cannot
            // reach the server until after the default ten-second deadline.
            pair.time += Duration::from_secs(11);
            pair.drive_server();
            if !extended {
                assert!(pair.server_conn_mut(server).is_closed());
                assert_eq!(pair.server.open_connections(), 0);
                continue;
            }
            assert!(!pair.server_conn_mut(server).is_closed());
            for datagram in &mut finished {
                datagram.at = pair.time;
            }
            pair.server.inbound.extend(finished);
            pair.drive();
            assert!(pair.server_conn_mut(server).handshake_confirmed());
            assert!(pair.client_conn_mut(client).handshake_confirmed());
            assert_eq!(pair.server.open_connections(), 1);
        }
    }
}
