use super::qlog::Capture;
use super::*;
use rama_quic_proto::VarInt;

impl Capture {
    fn assert_handshake_starts_on_first_handshake_packet(&self) {
        // State updates are emitted immediately before the packet event they describe.
        // Keep packet events in the projection so an Initial or 0-RTT trigger cannot
        // accidentally pass just because the eventual state sequence looks correct.
        let progression: Vec<_> = self
            .records()
            .into_iter()
            .filter(|event| {
                event["name"] == "quic:packet_sent"
                    || event["name"] == "quic:packet_received"
                    || (event["name"] == "quic:connection_state_updated"
                        && event["data"]["new"] == "handshake_started")
            })
            .collect();
        let marker = progression
            .iter()
            .position(|event| event["name"] == "quic:connection_state_updated")
            .unwrap();
        assert!(
            marker > 0,
            "Initial traffic precedes the first Handshake packet"
        );
        assert!(
            progression[..marker]
                .iter()
                .all(|event| event["data"]["header"]["packet_type"] != "handshake")
        );
        let first_handshake = &progression[marker + 1];
        assert_eq!(
            first_handshake["data"]["header"]["packet_type"],
            "handshake"
        );
        assert_eq!(progression[marker]["time"], first_handshake["time"]);
    }

    fn states(&self) -> Vec<String> {
        let events = self.events("quic:connection_state_updated");
        for pair in events.windows(2) {
            assert_eq!(pair[0]["data"]["new"], pair[1]["data"]["old"]);
            assert!(pair[0]["time"].as_f64().unwrap() <= pair[1]["time"].as_f64().unwrap());
        }
        events
            .iter()
            .map(|event| event["data"]["new"].as_str().unwrap().to_owned())
            .collect()
    }
}

#[test]
fn qlog_lifecycle_handshake_and_application_close() {
    let client_log = Capture::default();
    let server_log = Capture::default();
    let mut pair = Pair::default();
    let start = pair.time;
    let mut server = server_config();
    server.transport = server_log.transport(start);
    pair.server
        .endpoint
        .set_server_config(Some(Arc::new(server)));
    let mut client = client_config();
    client.transport = client_log.transport(start);
    let (client_ch, _) = pair.connect_with(client);
    for log in [&client_log, &server_log] {
        assert_eq!(
            log.states(),
            [
                "attempted",
                "handshake_started",
                "handshake_complete",
                "handshake_confirmed"
            ]
        );
        assert_eq!(log.events("quic:connection_started").len(), 1);
        log.assert_handshake_starts_on_first_handshake_packet();
    }
    let client_started = client_log.events("quic:connection_started");
    let server_started = server_log.events("quic:connection_started");
    assert_eq!(client_started[0]["group_id"], server_started[0]["group_id"]);
    assert_eq!(
        client_started[0]["data"]["remote"]["port_v6"],
        pair.server.addr.port()
    );
    assert_eq!(
        server_started[0]["data"]["remote"]["connection_ids"],
        client_started[0]["data"]["local"]["connection_ids"]
    );

    let now = pair.time;
    pair.client_conn_mut(client_ch)
        .close(now, VarInt::from_u32(42), Bytes::from_static(b"done"));
    pair.client_conn_mut(client_ch).close(
        now,
        VarInt::from_u32(99),
        Bytes::from_static(b"duplicate"),
    );
    pair.drive();
    pair.time += Duration::from_secs(10);
    pair.drive();
    for (log, initiator) in [(&client_log, "local"), (&server_log, "remote")] {
        let closed = log.events("quic:connection_closed");
        assert_eq!(closed.len(), 1);
        assert_eq!(closed[0]["data"]["initiator"], initiator);
        assert_eq!(closed[0]["data"]["trigger"], "application");
        assert_eq!(closed[0]["data"]["application_error"], "unknown");
        assert_eq!(closed[0]["data"]["error_code"], 42);
        assert_eq!(closed[0]["data"]["reason"], "done");
        let states = log.states();
        assert!(
            states.contains(
                &if initiator == "local" {
                    "closing"
                } else {
                    "draining"
                }
                .to_owned()
            )
        );
        assert_eq!(states.last().unwrap(), "closed");
    }
}

#[test]
fn qlog_lifecycle_distinguishes_handshake_deadline_and_idle_timeout() {
    for handshake in [true, false] {
        let log = Capture::default();
        let mut pair = Pair::default();
        let start = pair.time;
        let mut client = client_config();
        client.transport = log.transport(start);
        let ch = if handshake {
            pair.begin_connect(client)
        } else {
            pair.connect_with(client).0
        };
        let now = pair.time + Duration::from_secs(3600);
        if handshake {
            pair.client_conn_mut(ch).expire_handshake(now);
            pair.client_conn_mut(ch).expire_handshake(now);
        } else {
            pair.client_conn_mut(ch).handle_timeout(now);
            pair.client_conn_mut(ch).handle_timeout(now);
        }
        let closed = log.events("quic:connection_closed");
        assert_eq!(closed.len(), 1);
        assert_eq!(closed[0]["data"]["initiator"], "local");
        assert_eq!(
            closed[0]["data"]["trigger"],
            if handshake { "error" } else { "idle_timeout" }
        );
        assert_eq!(
            closed[0]["data"]["reason"],
            if handshake {
                "handshake timeout"
            } else {
                "timed out"
            }
        );
        assert_eq!(closed[0]["time"], (now - start).as_secs_f64() * 1000.0);
        assert_eq!(log.states().last().unwrap(), "closed");
        if handshake {
            assert_eq!(log.states(), ["attempted", "closed"]);
        }
    }
}

#[test]
fn qlog_lifecycle_stateless_reset_closes_once_without_closing_period() {
    let log = Capture::default();
    let mut endpoint = EndpointConfig::new(HmacSha2::new_256(&[37; 32]));
    endpoint.set_cid_generator(Arc::new(|| {
        Box::new(HashedConnectionIdGenerator::from_key(0))
    }));
    let endpoint = Arc::new(endpoint);
    let mut pair = Pair::new(endpoint.clone(), server_config());
    let mut client = client_config();
    client.transport = log.transport(pair.time);
    let (ch, _) = pair.connect_with(client);
    pair.drive();
    pair.server.endpoint = Endpoint::new(endpoint, Some(Arc::new(server_config())), true, None);
    pair.client_conn_mut(ch).ping();
    pair.drive();
    let closed = log.events("quic:connection_closed");
    assert_eq!(closed.len(), 1);
    assert_eq!(closed[0]["data"]["initiator"], "remote");
    assert_eq!(closed[0]["data"]["trigger"], "stateless_reset");
    assert!(closed[0]["data"].get("error_code").is_none());
    assert_eq!(
        log.states(),
        [
            "attempted",
            "handshake_started",
            "handshake_complete",
            "handshake_confirmed",
            "closed"
        ]
    );
}
