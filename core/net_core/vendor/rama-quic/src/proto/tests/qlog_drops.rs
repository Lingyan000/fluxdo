use std::assert_matches;

use rama_quic_proto::{
    ConnectionId, Dir, TransportError, TransportErrorCode, VarInt,
    packet::{FixedLengthConnectionIdParser, PartialDecode},
};

use super::{qlog::Capture, *};
use crate::proto::shared::{ConnectionEvent, ConnectionEventInner, DatagramConnectionEvent};

fn traced_client(pair: &Pair, capture: &Capture) -> ClientConfig {
    let mut config = client_config_with_deterministic_pns();
    let mut transport = TransportConfig::default();
    transport.deterministic_packet_numbers(true);
    transport.set_qlog_recorder(capture.config(pair.time));
    config.transport = Arc::new(transport);
    config
}

fn deliver(pair: &mut Pair, client: ConnectionHandle, packet: BytesMut) {
    deliver_from(pair, client, packet, pair.server.addr);
}

fn deliver_from(pair: &mut Pair, client: ConnectionHandle, packet: BytesMut, remote: SocketAddr) {
    let (first_decode, remaining) = PartialDecode::new(
        packet,
        &FixedLengthConnectionIdParser::new(8),
        DEFAULT_SUPPORTED_VERSIONS,
        true,
    )
    .unwrap();
    let now = pair.time;
    let local = Some(pair.client.addr);
    pair.client_conn_mut(client)
        .handle_event(ConnectionEvent(ConnectionEventInner::Datagram(
            DatagramConnectionEvent {
                now,
                remote,
                local,
                ecn: None,
                first_decode,
                remaining,
            },
        )));
}

#[test]
fn malformed_corrupted_and_duplicate_packets_have_distinct_drop_reasons() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let capture = Capture::default();
    let config = traced_client(&pair, &capture);
    let (client, server) = pair.connect_with(config);
    let stream = pair.server_streams(server).open(Dir::Uni).unwrap();
    pair.server_send(server, stream).write(&[42; 128]).unwrap();
    pair.drive_server();
    let datagram = pair
        .client
        .inbound
        .pop_front()
        .expect("server sent stream data");
    assert!(
        pair.client.inbound.is_empty(),
        "one server datagram expected"
    );
    let wire_len = datagram.packet.len();
    assert_eq!(datagram.packet[0] & 0x80, 0, "established short packet");
    capture.clear();

    // A recognizable short header without a protection sample cannot be decoded.
    let truncated = BytesMut::from(&datagram.packet[..9]);
    deliver(&mut pair, client, truncated);
    let malformed = capture.events("quic:packet_dropped");
    assert_eq!(malformed.len(), 1);
    assert_eq!(malformed[0]["data"]["trigger"], "invalid");
    assert_eq!(malformed[0]["data"]["raw"]["length"], 9);
    assert!(
        malformed[0]["data"]["header"]
            .get("packet_number")
            .is_none()
    );
    assert!(capture.events("quic:packet_received").is_empty());
    capture.clear();

    // Changing the authentication tag keeps the header sample and packet number intact.
    let mut corrupted = datagram.packet.clone();
    corrupted[wire_len - 1] ^= 1;
    deliver(&mut pair, client, corrupted);
    let drops = capture.events("quic:packet_dropped");
    assert_eq!(drops.len(), 1);
    assert_eq!(drops[0]["data"]["trigger"], "decryption_failure");
    assert_eq!(drops[0]["data"]["raw"]["length"], wire_len);
    assert_eq!(drops[0]["data"]["header"]["packet_type"], "1RTT");
    assert!(drops[0]["data"]["header"].get("packet_number").is_none());
    assert!(capture.events("quic:packet_received").is_empty());
    assert!(!pair.client_conn_mut(client).is_closed());

    // The unauthenticated attempt must not poison duplicate detection for the original.
    deliver(&mut pair, client, datagram.packet.clone());
    let received = capture.events("quic:packet_received");
    assert_eq!(received.len(), 1);
    deliver(&mut pair, client, datagram.packet);
    let drops = capture.events("quic:packet_dropped");
    assert_eq!(drops.len(), 2);
    assert_eq!(drops[1]["data"]["trigger"], "duplicate");
    assert_eq!(drops[1]["data"]["raw"]["length"], wire_len);
    assert_eq!(
        drops[1]["data"]["header"]["packet_number"],
        received[0]["data"]["header"]["packet_number"]
    );
    assert_eq!(capture.events("quic:packet_received").len(), 1);
    assert!(!pair.client_conn_mut(client).is_closed());
}

#[test]
fn replay_after_handshake_key_discard_omits_unknown_packet_number() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let capture = Capture::default();
    let config = traced_client(&pair, &capture);
    let client = pair.begin_connect(config);
    pair.drive_client();
    pair.drive_server();
    let first_flight = pair
        .client
        .inbound
        .front()
        .expect("server handshake flight")
        .packet
        .clone();
    let (first, _) = PartialDecode::new(
        first_flight,
        &FixedLengthConnectionIdParser::new(8),
        DEFAULT_SUPPORTED_VERSIONS,
        true,
    )
    .unwrap();
    assert!(first.is_initial());
    let packet = BytesMut::from(first.data());
    let wire_len = packet.len();
    pair.drive();
    pair.server.assert_accept();
    assert!(!pair.client_conn_mut(client).is_handshaking());
    capture.clear();

    // This is the real server Initial, after the client has discarded its Initial keys.
    deliver(&mut pair, client, packet);
    let drops = capture.events("quic:packet_dropped");
    assert_eq!(drops.len(), 1);
    assert_eq!(drops[0]["data"]["trigger"], "key_unavailable");
    assert_eq!(drops[0]["data"]["header"]["packet_type"], "initial");
    assert_eq!(drops[0]["data"]["raw"]["length"], wire_len);
    assert!(drops[0]["data"]["header"].get("packet_number").is_none());
    assert!(capture.events("quic:packet_received").is_empty());
    assert!(!pair.client_conn_mut(client).is_closed());
}

#[test]
fn packet_from_unrecognized_peer_is_rejected_before_authentication() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let capture = Capture::default();
    let config = traced_client(&pair, &capture);
    let (client, server) = pair.connect_with(config);
    pair.server_conn_mut(server).ping();
    pair.drive_server();
    let datagram = pair.client.inbound.pop_front().expect("server sent a ping");
    assert!(pair.client.inbound.is_empty());
    let wire_len = datagram.packet.len();
    let legitimate_remote = pair.server.addr;
    let mut unexpected_remote = legitimate_remote;
    unexpected_remote.set_port(legitimate_remote.port() + 1);
    let before = pair.client_conn_mut(client).stats().udp_rx;
    capture.clear();

    // Even a correctly encrypted packet is rejected when it arrives from an unprobed peer.
    deliver_from(
        &mut pair,
        client,
        datagram.packet.clone(),
        unexpected_remote,
    );
    let drops = capture.events("quic:packet_dropped");
    assert_eq!(drops.len(), 1);
    assert_eq!(drops[0]["data"]["trigger"], "rejected");
    assert_eq!(drops[0]["data"]["header"]["packet_type"], "1RTT");
    assert_eq!(drops[0]["data"]["raw"]["length"], wire_len);
    assert!(drops[0]["data"]["header"].get("packet_number").is_none());
    assert!(capture.events("quic:packet_received").is_empty());
    assert_eq!(
        pair.client_conn_mut(client).stats().udp_rx.bytes,
        before.bytes
    );
    assert_eq!(
        pair.client_conn_mut(client).remote_address(),
        legitimate_remote
    );
    assert!(!pair.client_conn_mut(client).is_closed());

    // Rejection must leave authentication and duplicate tracking untouched.
    deliver(&mut pair, client, datagram.packet);
    assert_eq!(capture.events("quic:packet_received").len(), 1);
    assert_eq!(capture.events("quic:packet_dropped").len(), 1);
}

#[test]
fn invalid_first_accepted_initial_logs_drop_without_plaintext_length() {
    let _guard = subscribe();
    let capture = Capture::default();
    let mut server = server_config();
    let mut transport = TransportConfig::default();
    transport.set_qlog_recorder(capture.config(Instant::now()));
    server.transport = Arc::new(transport);
    let version = DEFAULT_SUPPORTED_VERSIONS[0];
    let destination = ConnectionId::new(&[1; 8]);
    let keys = server
        .crypto
        .initial()
        .initial_keys(version, &destination)
        .unwrap();
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );

    // Protect a client Initial with the correct keys but an APPLICATION_CLOSE frame,
    // which is forbidden in Initial packets. This reaches first-packet processing.
    let header = Header::Initial(InitialHeader {
        dst_cid: destination,
        src_cid: ConnectionId::new(&[2; 8]),
        token: Bytes::new(),
        number: PacketNumber::U8(0),
        version: version.to_wire().unwrap(),
    });
    let mut packet = Vec::new();
    let partial = header.encode(&mut packet);
    packet.extend_from_slice(&[0x1d, 0x2a, 0x00]);
    packet.resize(MIN_INITIAL_SIZE as usize, 0);
    partial
        .finish(
            &mut packet,
            keys.remote.as_ref().unwrap().header.as_ref(),
            Some((0, keys.remote.as_ref().unwrap().packet.as_ref())),
        )
        .unwrap();
    pair.server.inbound.push_back(Inbound::plain(
        pair.time,
        None,
        BytesMut::from(packet.as_slice()),
    ));
    pair.drive_server();
    assert_matches!(
        pair.server.assert_accept_error(),
        ConnectionError::TransportError(TransportError {
            code: TransportErrorCode::PROTOCOL_VIOLATION,
            ..
        }),
    );
    let drops = capture.events("quic:packet_dropped");
    assert_eq!(drops.len(), 1);
    assert_eq!(drops[0]["data"]["trigger"], "invalid");
    assert_eq!(drops[0]["data"]["header"]["packet_type"], "initial");
    assert_eq!(drops[0]["data"]["header"]["packet_number"], 0);
    assert!(
        drops[0]["data"].get("raw").is_none(),
        "ciphertext length is unavailable to this processing entry point"
    );
    // Acceptance failed before a connection reached the normal packet observer. The
    // first-packet error path must still record the close once before discarding it.
    let closed = capture.events("quic:connection_closed");
    assert_eq!(closed.len(), 1);
    assert_eq!(closed[0]["data"]["initiator"], "local");
    assert_eq!(closed[0]["data"]["trigger"], "error");
    assert_eq!(closed[0]["data"]["connection_error"], "protocol_violation");
    assert_eq!(
        closed[0]["data"]["reason"],
        "illegal frame type in handshake"
    );
    assert!(closed[0]["data"].get("error_code").is_none());
    let states = capture.events("quic:connection_state_updated");
    assert_eq!(states.last().unwrap()["data"]["new"], "closed");
}

#[test]
fn replay_after_zero_rtt_key_discard_keeps_early_packet_type() {
    let _guard = subscribe();
    let capture = Capture::default();
    let mut server = server_config();
    let mut transport = TransportConfig::default();
    transport.set_qlog_recorder(capture.config(Instant::now()));
    server.transport = Arc::new(transport);
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    pair.server.handle_incoming = Box::new(validate_incoming);
    let config = client_config_with_deterministic_pns();

    // Obtain a resumable TLS session, then send real early stream data on a new connection.
    let (first_client, _) = pair.connect_with(config.clone());
    let now = pair.time;
    pair.client_conn_mut(first_client)
        .close(now, VarInt::from_u32(0), Bytes::new());
    pair.drive();
    pair.client
        .addr
        .set_port(CLIENT_PORTS.lock().next().unwrap());
    let client = pair.begin_connect(config);
    assert!(pair.client_conn_mut(client).has_0rtt());
    let stream = pair.client_streams(client).open(Dir::Uni).unwrap();
    pair.client_send(client, stream)
        .write(b"record and replay this early packet")
        .unwrap();
    pair.drive_client();

    let mut early_packet = None;
    for datagram in &pair.server.inbound {
        let mut remaining = Some(datagram.packet.clone());
        while let Some(bytes) = remaining {
            let (packet, rest) = PartialDecode::new(
                bytes,
                &FixedLengthConnectionIdParser::new(8),
                DEFAULT_SUPPORTED_VERSIONS,
                true,
            )
            .unwrap();
            if packet.is_0rtt() {
                early_packet = Some(BytesMut::from(packet.data()));
            }
            remaining = rest;
        }
    }
    let early_packet = early_packet.expect("resumed client sent a 0-RTT packet");
    let wire_len = early_packet.len();
    pair.drive();
    let server = pair.server.assert_accept();
    assert!(pair.client_conn_mut(client).accepted_0rtt());

    // KeyDiscard is intentionally ignored by Pair's idle check. Fire it explicitly after
    // the server has received 1-RTT, while staying well inside the idle timeout.
    pair.time += Duration::from_secs(3);
    let now = pair.time;
    pair.server_conn_mut(server).handle_timeout(now);
    assert!(
        capture
            .events("quic:key_discarded")
            .iter()
            .any(|event| event["data"]["key_type"] == "client_0rtt_secret")
    );
    capture.clear();

    let (first_decode, remaining) = PartialDecode::new(
        early_packet,
        &FixedLengthConnectionIdParser::new(8),
        DEFAULT_SUPPORTED_VERSIONS,
        true,
    )
    .unwrap();
    let remote = pair.client.addr;
    let local = Some(pair.server.addr);
    pair.server_conn_mut(server)
        .handle_event(ConnectionEvent(ConnectionEventInner::Datagram(
            DatagramConnectionEvent {
                now,
                remote,
                local,
                ecn: None,
                first_decode,
                remaining,
            },
        )));
    let drops = capture.events("quic:packet_dropped");
    assert_eq!(drops.len(), 1);
    assert_eq!(drops[0]["data"]["trigger"], "key_unavailable");
    assert_eq!(drops[0]["data"]["header"]["packet_type"], "0RTT");
    assert_eq!(drops[0]["data"]["raw"]["length"], wire_len);
    assert!(drops[0]["data"]["header"].get("packet_number").is_none());
    assert!(capture.events("quic:packet_received").is_empty());
    assert!(!pair.server_conn_mut(server).is_closed());
}
