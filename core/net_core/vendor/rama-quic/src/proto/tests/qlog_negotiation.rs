use std::assert_matches;

use rama_quic_proto::VarInt;

use super::{qlog::Capture, *};

fn trace_config(capture: &Capture, now: Instant) -> Arc<TransportConfig> {
    let mut transport = TransportConfig::default();
    transport.set_qlog_recorder(capture.config(now));
    Arc::new(transport)
}

#[test]
fn qlog_negotiation_records_actual_parameters_alpn_and_key_generations() {
    let _guard = subscribe();
    let mut server = server_config();
    server.crypto = ServerCrypto::Fixed(Arc::new(server_crypto_with_alpn(vec![vec![
        0xff, 0x00, b'h',
    ]])));
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    let capture = Capture::default();
    let start = pair.time;
    let mut config = ClientConfig::new(Arc::new(client_crypto_with_alpn(vec![vec![
        0xff, 0x00, b'h',
    ]])));
    config.transport = trace_config(&capture, start);
    let (client, server) = pair.connect_with(config);
    let versions = capture.events("quic:version_information");
    assert_eq!(versions.len(), 1);
    assert_eq!(versions[0]["data"]["chosen_version"], "00000001");
    assert_eq!(versions[0]["time"], 0.0);
    assert!(versions[0]["data"].get("server_versions").is_none());
    let alpns = capture.events("quic:alpn_information");
    assert_eq!(alpns.len(), 1);
    assert_eq!(alpns[0]["data"]["chosen_alpn"]["byte_value"], "ff0068");
    assert!(alpns[0]["data"].get("server_alpns").is_none());
    let params = capture.events("quic:parameters_set");
    let local = params
        .iter()
        .find(|event| event["data"]["initiator"] == "local")
        .unwrap();
    let remote = params
        .iter()
        .find(|event| event["data"]["initiator"] == "remote")
        .unwrap();
    assert_eq!(
        local["data"]["initial_max_data"],
        TransportConfig::default().receive_window.into_inner()
    );
    assert!(local["data"]["initial_source_connection_id"].is_string());
    assert!(
        local["data"]
            .get("original_destination_connection_id")
            .is_none()
    );
    assert!(remote["data"]["original_destination_connection_id"].is_string());
    assert!(remote["data"].get("stateless_reset_token").is_none());

    for phase in 1..=3 {
        let now = pair.time;
        let remote_update = phase == 2;
        if remote_update {
            assert!(pair.server_conn_mut(server).force_key_update(now));
            pair.server_conn_mut(server).ping();
        } else {
            assert!(pair.client_conn_mut(client).force_key_update(now));
            pair.client_conn_mut(client).ping();
        }
        pair.drive();
        // The responder may have sent only an ACK in the new phase. Have both
        // sides send ack-eliciting packets so either can initiate the next
        // update after actual acknowledgment, independently of key retirement.
        pair.client_conn_mut(client).ping();
        pair.server_conn_mut(server).ping();
        pair.drive();
        let updates = capture.events("quic:key_updated");
        for key_type in ["client_1rtt_secret", "server_1rtt_secret"] {
            let event = updates
                .iter()
                .find(|event| {
                    event["data"]["key_type"] == key_type && event["data"]["key_phase"] == phase
                })
                .unwrap();
            assert_eq!(
                event["data"]["trigger"],
                if remote_update {
                    "remote_update"
                } else {
                    "local_update"
                }
            );
            assert!(event["data"].get("new").is_none());
            assert!(event["data"].get("old").is_none());
        }
        // An idle simulator does not advance to key-retirement-only deadlines.
        pair.time += Duration::from_secs(1);
        pair.drive();
        let discards = capture.events("quic:key_discarded");
        assert!(
            discards
                .iter()
                .any(|event| event["data"]["key_type"] == "client_1rtt_secret"
                    && event["data"]["key_phase"] == phase - 1)
        );
    }
    let discards = capture.events("quic:key_discarded");
    for key_type in [
        "client_initial_secret",
        "server_initial_secret",
        "client_handshake_secret",
        "server_handshake_secret",
    ] {
        assert_eq!(
            discards
                .iter()
                .filter(|event| event["data"]["key_type"] == key_type)
                .count(),
            1
        );
    }
}

#[test]
fn qlog_negotiation_resumption_uses_restored_parameters_and_one_client_early_key() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    pair.server.handle_incoming = Box::new(validate_incoming);
    let mut config = client_config();
    let (client, _) = pair.connect_with(config.clone());
    let now = pair.time;
    pair.client_conn_mut(client)
        .close(now, VarInt::from_u32(0), Bytes::new());
    pair.drive();
    pair.client
        .addr
        .set_port(CLIENT_PORTS.lock().next().unwrap());
    let capture = Capture::default();
    config.transport = trace_config(&capture, pair.time);
    let client = pair.begin_connect(config);
    assert!(pair.client_conn_mut(client).has_0rtt());
    let restored = capture.events("quic:parameters_restored");
    assert_eq!(restored.len(), 1);
    let data = restored[0]["data"].as_object().unwrap();
    for prohibited in [
        "initiator",
        "initial_source_connection_id",
        "original_destination_connection_id",
        "retry_source_connection_id",
        "stateless_reset_token",
        "preferred_address",
        "max_ack_delay",
        "ack_delay_exponent",
    ] {
        assert!(
            !data.contains_key(prohibited),
            "{prohibited} was not restored"
        );
    }
    pair.drive();
    let keys = capture.events("quic:key_updated");
    assert_eq!(
        keys.iter()
            .filter(|event| event["data"]["key_type"] == "client_0rtt_secret")
            .count(),
        1
    );
    assert!(
        keys.iter()
            .all(|event| event["data"]["key_type"] != "server_0rtt_secret")
    );
    let discards = capture.events("quic:key_discarded");
    assert_eq!(
        discards
            .iter()
            .filter(|event| event["data"]["key_type"] == "client_0rtt_secret")
            .count(),
        1
    );
    assert!(
        capture
            .events("quic:parameters_set")
            .iter()
            .any(|event| event["data"]["initiator"] == "remote")
    );
}

#[test]
fn qlog_negotiation_incompatible_versions_record_the_offer_and_close_cause() {
    let _guard = subscribe();
    let capture = Capture::default();
    let start = Instant::now();
    let server_addr = SocketAddr::from(([0, 0, 0, 0, 0, 0, 0, 2], 7890));
    // An empty local CID makes the response destination independent of randomness.
    let cid_factory: fn() -> Box<dyn ConnectionIdGenerator> =
        || Box::new(RandomConnectionIdGenerator::new(0).unwrap());
    let mut endpoint = Endpoint::new(
        Arc::new(EndpointConfig {
            connection_id_generator_factory: Arc::new(cid_factory),
            ..EndpointConfig::try_with_rand_key().unwrap()
        }),
        None,
        true,
        None,
    );
    let mut config = client_config();
    config.transport = trace_config(&capture, start);
    let (_, mut connection) = endpoint
        .connect(start, config, server_addr, "localhost")
        .unwrap();
    let now = start + Duration::from_millis(15);
    let mut response = Vec::new();
    let received = endpoint.handle(
        now,
        server_addr,
        None,
        None,
        // Version Negotiation offers two reserved versions, neither of which we implement.
        [
            0x80, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0x0a, 0x1a, 0x2a, 0x3a, 0x4a, 0x5a, 0x6a, 0x7a,
        ][..]
            .into(),
        &mut response,
    );
    let Some(DatagramEvent::ConnectionEvent(_, event)) = received else {
        panic!("Version Negotiation must reach the pending connection");
    };
    connection.handle_event(event);
    assert_matches!(
        connection.poll(),
        Some(Event::ConnectionLost {
            reason: ConnectionError::VersionMismatch { .. },
        }),
    );
    let versions = capture.events("quic:version_information");
    assert_eq!(versions.len(), 2);
    assert_eq!(versions[1]["time"], 15.0);
    assert_eq!(
        versions[1]["data"],
        serde_json::json!({
            "client_versions": ["00000001", "6b3343cf"],
            "server_versions": ["0a1a2a3a", "4a5a6a7a"]
        })
    );
    let closed = capture.events("quic:connection_closed");
    assert_eq!(closed.len(), 1);
    assert_eq!(closed[0]["time"], 15.0);
    assert_eq!(closed[0]["data"]["trigger"], "version_mismatch");
    assert_eq!(closed[0]["data"]["initiator"], "local");
}
