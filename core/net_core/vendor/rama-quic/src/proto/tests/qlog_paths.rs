use super::qlog::Capture;
use super::*;
use rama_quic_proto::{Dir, TransportErrorCode};
use std::assert_matches;

#[test]
fn qlog_paths_follow_actual_migration_and_mtu_changes() {
    let _guard = subscribe();
    let capture = Capture::default();
    let mut server = server_config();
    server.transport = capture.transport(Instant::now());
    let transport = Arc::get_mut(&mut server.transport).unwrap();
    transport.set_initial_rtt(Duration::from_micros(123_456));
    transport.set_packet_threshold(7);
    transport.try_set_time_threshold(1.25).unwrap();
    transport.set_persistent_congestion_threshold(4);
    transport.set_initial_mtu(1250);
    transport.try_set_initial_congestion_window(18_000).unwrap();
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    pair.mtu = 1300;
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    let recovery = capture.events("quic:recovery_parameters_set");
    assert_eq!(recovery.len(), 1);
    assert_eq!(recovery[0]["data"]["timer_granularity"], 1);
    assert_eq!(recovery[0]["data"]["reordering_threshold"], 7);
    assert_eq!(recovery[0]["data"]["time_threshold"], 1.25);
    assert_eq!(recovery[0]["data"]["persistent_congestion_threshold"], 4);
    assert_eq!(recovery[0]["data"]["max_datagram_size"], 1250);
    assert_eq!(recovery[0]["data"]["initial_congestion_window"], 18_000);
    // qlog uses milliseconds, retaining the fraction from the configured microseconds.
    let initial_rtt_ms = recovery[0]["data"]["initial_rtt"].as_f64().unwrap();
    assert!(
        (initial_rtt_ms - 123.456).abs() < 0.00002,
        "{initial_rtt_ms}"
    );
    let mtus = capture.events("quic:mtu_updated");
    assert!(!mtus.is_empty());
    assert!(
        mtus.iter()
            .all(|event| event["data"]["old"] != event["data"]["new"])
    );
    assert_eq!(
        mtus.last().unwrap()["data"]["new"],
        pair.server_conn_mut(server_ch).path_mtu()
    );
    assert!(capture.events("quic:migration_state_updated").is_empty());

    pair.client.addr = SocketAddr::new(
        Ipv4Addr::LOCALHOST.into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    pair.client_conn_mut(client_ch).ping();
    pair.drive();
    assert_eq!(
        pair.server_conn_mut(server_ch).remote_address(),
        pair.client.addr
    );
    let migrations = capture.events("quic:migration_state_updated");
    let states: Vec<_> = migrations
        .iter()
        .map(|event| event["data"]["new"].as_str().unwrap())
        .collect();
    assert_eq!(states, ["migration_started", "migration_complete"]);
    let assignments = capture.events("quic:tuple_assigned");
    for migration in migrations {
        assert_eq!(migration["tuple"], migration["data"]["tuple_id"]);
        assert!(
            assignments
                .iter()
                .any(|assigned| assigned["data"]["tuple_id"] == migration["data"]["tuple_id"])
        );
    }
    assert!(
        assignments
            .iter()
            .any(|event| event["data"]["tuple_remote"]["ip_v4"] == "127.0.0.1")
    );
}

#[test]
fn qlog_paths_cid_rotation_has_remote_and_local_perspectives() {
    let _guard = subscribe();
    let client_capture = Capture::default();
    let server_capture = Capture::default();
    let mut server = server_config();
    server.transport = server_capture.transport(Instant::now());
    let mut client = client_config();
    client.transport = client_capture.transport(Instant::now());
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    let (client_ch, _) = pair.connect_with(client);
    pair.drive();
    client_capture.clear();
    server_capture.clear();
    let now = pair.time;
    assert!(pair.client_conn_mut(client_ch).migrate_local_address(now));
    pair.drive();
    let client = client_capture.events("quic:connection_id_updated");
    assert!(
        client
            .iter()
            .any(|event| event["data"]["initiator"] == "remote"
                && event["data"]["old"] != event["data"]["new"])
    );
    let server = server_capture.events("quic:connection_id_updated");
    assert!(
        server
            .iter()
            .any(|event| event["data"]["initiator"] == "local"
                && event["data"]["old"] != event["data"]["new"])
    );
}

#[test]
fn qlog_paths_preferred_address_records_success_and_abandonment() {
    let _guard = subscribe();
    for reachable in [true, false] {
        let capture = Capture::default();
        let (mut pair, preferred) = pair_preferring(reachable);
        let mut client = client_config();
        client.transport = capture.transport(Instant::now());
        let (client_ch, _) = pair.connect_with(client);
        drive_settled(&mut pair);
        let migrations = capture.events("quic:migration_state_updated");
        let states: Vec<_> = migrations
            .iter()
            .map(|event| event["data"]["new"].as_str().unwrap())
            .collect();
        if reachable {
            assert_eq!(pair.client_conn_mut(client_ch).remote_address(), preferred);
            assert_eq!(
                states,
                [
                    "probing_started",
                    "probing_successful",
                    "migration_started",
                    "migration_complete"
                ]
            );
        } else {
            assert_ne!(pair.client_conn_mut(client_ch).remote_address(), preferred);
            assert_eq!(states, ["probing_started", "probing_abandoned"]);
        }
        let tuples = capture.events("quic:tuple_assigned");
        assert!(migrations.iter().all(|migration| {
            tuples
                .iter()
                .any(|tuple| tuple["data"]["tuple_id"] == migration["data"]["tuple_id"])
        }));
    }
}

#[test]
fn qlog_paths_mtu_black_hole_logs_reduction() {
    let _guard = subscribe();
    let capture = Capture::default();
    let mut client = client_config();
    client.transport = capture.transport(Instant::now());
    let mut pair = Pair::default();
    pair.mtu = 1500;
    let (client_ch, server_ch) = pair.connect_with(client);
    pair.drive();
    let old_mtu = pair.client_conn_mut(client_ch).path_mtu();
    assert!(old_mtu > 1200);
    capture.clear();
    pair.mtu = 1200;
    let stream = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    // Probes recover single-write tails early; detection needs >3 independent bursts across writes.
    for _ in 0..4 {
        pair.client_send(client_ch, stream)
            .write(&[42; 1300])
            .unwrap();
        assert!(!pair.drive_bounded());
    }
    assert_eq!(
        stream_chunks(pair.server_recv(server_ch, stream)).len(),
        4 * 1300
    );
    assert_eq!(
        pair.client_conn_mut(client_ch)
            .stats()
            .path
            .black_holes_detected,
        1
    );
    let updates = capture.events("quic:mtu_updated");
    assert!(
        updates
            .iter()
            .any(|event| event["data"]["old"] == old_mtu && event["data"]["new"] == 1200)
    );
}

#[test]
fn qlog_paths_failed_migration_restores_both_connection_ids() {
    let _guard = subscribe();
    let capture = Capture::default();
    let mut server = server_config();
    server.transport = capture.transport(Instant::now());
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    let original_address = pair.client.addr;
    let original_remote_cid = pair.server_conn_mut(server_ch).active_rem_cid();
    let original_cwnd = pair.server_conn_mut(server_ch).stats().path.cwnd;
    let original_rtt = pair.server_conn_mut(server_ch).rtt().as_secs_f64() * 1000.0;
    capture.clear();

    // Deliver a fresh-CID packet from a different address, then lose every validation
    // challenge. The server adopts the move but must return to its validated fallback.
    let unreachable = SocketAddr::new(
        Ipv4Addr::new(127, 0, 0, 7).into(),
        CLIENT_PORTS.lock().next().unwrap(),
    );
    pair.client.addr = unreachable;
    let now = pair.time;
    assert!(pair.client_conn_mut(client_ch).migrate_local_address(now));
    pair.drive_client();
    pair.server.drive(pair.time, unreachable);
    pair.client.addr = original_address;
    assert_eq!(
        pair.server_conn_mut(server_ch).remote_address(),
        unreachable
    );
    assert_ne!(
        pair.server_conn_mut(server_ch).active_rem_cid(),
        original_remote_cid
    );

    for _ in 0..64 {
        if pair.server_conn_mut(server_ch).remote_address() != unreachable {
            break;
        }
        pair.server.outbound.clear();
        let next = pair
            .server
            .next_wakeup()
            .expect("pending validation deadline");
        pair.time = pair.time.max(next);
        pair.server.drive(pair.time, original_address);
    }
    assert_eq!(
        pair.server_conn_mut(server_ch).remote_address(),
        original_address
    );
    assert_eq!(
        pair.server_conn_mut(server_ch).active_rem_cid(),
        original_remote_cid
    );

    let updates = capture.events("quic:connection_id_updated");
    for initiator in ["local", "remote"] {
        let changes: Vec<_> = updates
            .iter()
            .filter(|event| event["data"]["initiator"] == initiator)
            .collect();
        assert_eq!(
            changes.len(),
            2,
            "{initiator} ID must change on adoption and rollback: {changes:?}"
        );
        assert_ne!(changes[0]["data"]["old"], changes[0]["data"]["new"]);
        assert_eq!(changes[1]["data"]["old"], changes[0]["data"]["new"]);
        assert_eq!(changes[1]["data"]["new"], changes[0]["data"]["old"]);
    }
    let migrations = capture.events("quic:migration_state_updated");
    let states: Vec<_> = migrations
        .iter()
        .map(|event| event["data"]["new"].as_str().unwrap())
        .collect();
    assert_eq!(states, ["migration_started", "migration_abandoned"]);
    assert_eq!(migrations[0]["tuple"], migrations[1]["tuple"]);

    pair.server_conn_mut(server_ch).ping();
    pair.server.drive_outgoing(pair.time);
    let records = capture.records();
    let abandoned = records
        .iter()
        .position(|event| {
            event["name"] == "quic:migration_state_updated"
                && event["data"]["new"] == "migration_abandoned"
        })
        .unwrap();
    let restored = records[abandoned + 1..]
        .iter()
        .find(|event| event["name"] == "quic:recovery_metrics_updated")
        .expect("the restored path reports its recovery state");
    assert!(
        restored.get("tuple").is_none(),
        "restored the original tuple"
    );
    assert_eq!(restored["data"]["congestion_window"], original_cwnd);
    let restored_rtt = restored["data"]["smoothed_rtt"].as_f64().unwrap();
    assert!((restored_rtt - original_rtt).abs() < 0.00002);
    assert!(
        capture
            .events("quic:recovery_metrics_updated")
            .iter()
            .any(|event| {
                event.get("tuple").is_some()
                    && event["data"]
                        .get("smoothed_rtt")
                        .is_some_and(|rtt| *rtt != original_rtt)
            }),
        "the abandoned path had a different RTT baseline"
    );
}

#[test]
fn qlog_paths_reset_starts_a_complete_recovery_snapshot() {
    let _guard = subscribe();
    let capture = Capture::default();
    let mut client = client_config();
    client.transport = capture.transport(Instant::now());
    let mut pair = Pair::default();
    let (client_ch, _) = pair.connect_with(client);
    pair.drive();

    for _ in 0..2 {
        capture.clear();
        pair.time += Duration::from_secs(1);
        let now = pair.time;
        let connection = pair.client_conn_mut(client_ch);
        connection.path_changed(now);
        let cwnd = connection.stats().path.cwnd;
        let rtt = connection.rtt().as_secs_f64() * 1000.0;
        connection.ping();
        pair.client.drive_outgoing(now);
        let metrics = capture.events("quic:recovery_metrics_updated");
        let data = &metrics.first().expect("the reset path sends a ping")["data"];
        assert_eq!(data["congestion_window"], cwnd);
        assert!((data["smoothed_rtt"].as_f64().unwrap() - rtt).abs() < 0.00002);
        for field in [
            "min_rtt",
            "latest_rtt",
            "rtt_variance",
            "pto_count",
            "bytes_in_flight",
        ] {
            assert!(
                data.get(field).is_some(),
                "reset snapshot missing {field}: {data}"
            );
        }
        pair.client.outbound.clear();
    }
}

#[test]
fn qlog_paths_validation_timeout_without_fallback_keeps_current_path() {
    let _guard = subscribe();
    let capture = Capture::default();
    let mut server = server_config();
    server.transport = capture.transport(Instant::now());
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    capture.clear();
    pair.client
        .addr
        .set_port(CLIENT_PORTS.lock().next().unwrap());
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();
    pair.server.drive(pair.time, pair.client.addr);
    let moved_to = pair.client.addr;
    assert!(pair.server_conn_mut(server_ch).challenge_token().is_some());
    pair.server_conn_mut(server_ch).abandon_the_fallback();
    assert_eq!(pair.server_conn_mut(server_ch).previous_path_remote(), None);

    pair.server.outbound.clear();
    pair.time = pair
        .server_conn_mut(server_ch)
        .path_validation_deadline()
        .expect("pending validation deadline");
    pair.server.drive(pair.time, moved_to);
    let connection = pair.server_conn_mut(server_ch);
    assert!(
        connection.challenge_token().is_none(),
        "validation timed out"
    );
    assert_eq!(connection.remote_address(), moved_to);
    assert!(!connection.is_closed());
    let migrations = capture.events("quic:migration_state_updated");
    assert_eq!(
        migrations.len(),
        1,
        "a retained path is not abandoned: {migrations:?}"
    );
    assert_eq!(migrations[0]["data"]["new"], "migration_started");
}

#[test]
fn qlog_paths_mtu_validation_without_fallback_logs_abandonment_on_close() {
    let _guard = subscribe();
    let capture = Capture::default();
    let mut server = server_config();
    server.transport = capture.transport(Instant::now());
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    let (client_ch, server_ch) = pair.connect();
    pair.drive();
    capture.clear();
    pair.client
        .addr
        .set_port(CLIENT_PORTS.lock().next().unwrap());
    pair.client_conn_mut(client_ch).ping();
    pair.drive_client();
    pair.drive_server();
    pair.drive_client();
    pair.drive_server();
    assert!(pair.server_conn_mut(server_ch).challenge_is_for_mtu());
    pair.server_conn_mut(server_ch).abandon_the_fallback();
    pair.client.inbound.clear();

    for _ in 0..3 {
        pair.time = pair
            .server_conn_mut(server_ch)
            .path_validation_deadline()
            .expect("pending expanded validation deadline");
        pair.server.drive(pair.time, pair.client.addr);
        pair.server.outbound.clear();
    }
    assert_matches!(
        pair.server_conn_mut(server_ch).ended_because(),
        Some(ConnectionError::TransportError(error)) if error.code == TransportErrorCode::NO_VIABLE_PATH,
    );
    let migrations = capture.events("quic:migration_state_updated");
    assert_eq!(migrations.len(), 2);
    assert_eq!(migrations[0]["data"]["new"], "migration_started");
    assert_eq!(migrations[1]["data"]["new"], "migration_abandoned");
    assert_eq!(migrations[1]["tuple"], migrations[0]["tuple"]);
}
