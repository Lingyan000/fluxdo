use super::*;
use crate::qlog::QlogConfig;
use parking_lot::Mutex;
use rama_quic_proto::{Dir, VarInt, packet};
use std::{
    io,
    pin::Pin,
    task::{Context, Poll},
};
use tokio::io::AsyncWrite;

#[derive(Clone, Default)]
struct CaptureWriter(Arc<Mutex<Vec<u8>>>);

impl AsyncWrite for CaptureWriter {
    fn poll_write(
        self: Pin<&mut Self>,
        _: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        self.0.lock().extend_from_slice(bytes);
        Poll::Ready(Ok(bytes.len()))
    }

    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.poll_flush(cx)
    }
}

pub(super) struct Capture {
    writer: CaptureWriter,
    recorder: Mutex<Option<crate::qlog::QlogRecorder>>,
    runtime: tokio::runtime::Runtime,
}

impl Default for Capture {
    fn default() -> Self {
        Self {
            writer: CaptureWriter::default(),
            recorder: Mutex::new(None),
            runtime: tokio::runtime::Builder::new_current_thread()
                .build()
                .unwrap(),
        }
    }
}

impl Capture {
    pub(super) fn config(&self, start: Instant) -> crate::qlog::QlogRecorder {
        let _entered = self.runtime.enter();
        let recorder = QlogConfig::default()
            .with_writer(Box::new(self.writer.clone()))
            .with_start_time(start)
            .start()
            .unwrap();
        assert!(self.recorder.lock().replace(recorder.clone()).is_none());
        recorder
    }

    pub(super) fn transport(&self, start: Instant) -> Arc<TransportConfig> {
        Arc::new(TransportConfig::default().with_qlog_recorder(self.config(start)))
    }

    fn flush(&self) {
        let recorder = self.recorder.lock().clone().expect("configured capture");
        // Drive the same runtime that owns this synchronous simulator's recording task.
        self.runtime.block_on(recorder.flush()).unwrap();
    }

    pub(super) fn clear(&self) {
        self.flush();
        self.writer.0.lock().clear();
    }

    pub(super) fn records(&self) -> Vec<serde_json::Value> {
        self.flush();
        self.writer
            .0
            .lock()
            .split(|byte| *byte == 0x1e)
            .filter(|record| !record.is_empty())
            .map(|record| serde_json::from_slice(record).unwrap())
            .collect()
    }

    pub(super) fn events(&self, name: &str) -> Vec<serde_json::Value> {
        self.records()
            .into_iter()
            .filter(|record| record["name"] == name)
            .collect()
    }

    fn take_sent(&self) -> Vec<serde_json::Value> {
        let records = self.records();
        self.writer.0.lock().clear();
        records
            .into_iter()
            .filter(|record| record["name"] == "quic:packet_sent")
            .collect()
    }
}

/// Send a flight without delivering it, checking the logged packet lengths against the wire.
fn capture_flight(pair: &mut Pair, capture: &Capture) -> Vec<serde_json::Value> {
    assert!(pair.client.outbound.is_empty());
    capture.clear();
    for _ in 0..10 {
        pair.client.drive(pair.time, pair.server.addr);
        if !pair.client.outbound.is_empty() {
            break;
        }
        pair.time = pair
            .client
            .next_wakeup()
            .expect("a pending flight has a wakeup");
    }
    let sent = capture.take_sent();
    assert!(!sent.is_empty(), "the flight must actually send packets");
    let logged_bytes: u64 = sent
        .iter()
        .map(|record| record["data"]["raw"]["length"].as_u64().unwrap())
        .sum();
    let wire_bytes: usize = pair
        .client
        .outbound
        .iter()
        .map(|(_, bytes)| bytes.len())
        .sum();
    assert_eq!(logged_bytes, wire_bytes as u64);
    sent
}

#[test]
fn lost_packets_keep_their_original_encryption_level() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    pair.server.handle_incoming = Box::new(validate_incoming);
    let mut config = client_config_with_deterministic_pns();

    // Populate the TLS session cache before enabling this connection's trace.
    let (client_ch, _) = pair.connect_with(config.clone());
    let now = pair.time;
    pair.client_conn_mut(client_ch)
        .close(now, VarInt::from_u32(0), Bytes::new());
    pair.drive();
    pair.client
        .addr
        .set_port(CLIENT_PORTS.lock().next().unwrap());

    let capture = Capture::default();
    let mut transport = TransportConfig::default();
    transport.deterministic_packet_numbers(true);
    transport.set_qlog_recorder(capture.config(pair.time));
    config.transport = Arc::new(transport);
    let client_ch = pair.begin_connect(config);
    assert!(pair.client_conn_mut(client_ch).has_0rtt());

    // Deliver Initial separately, so dropping the next flight loses only early data.
    let initial = capture_flight(&mut pair, &capture);
    assert!(
        initial
            .iter()
            .all(|event| event["data"]["header"]["packet_type"] == "initial")
    );
    pair.drive_client();
    let stream = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    pair.client_send(client_ch, stream)
        .write(b"early data")
        .unwrap();
    let early = capture_flight(&mut pair, &capture);
    assert_eq!(early.len(), 1);
    assert_eq!(early[0]["data"]["header"]["packet_type"], "0RTT");
    let early_number = early[0]["data"]["header"]["packet_number"].clone();
    pair.client.outbound.clear();

    // Process the server's handshake before any data-space acknowledgement can declare loss.
    pair.drive_server();
    pair.drive_client();
    assert!(!pair.client_conn_mut(client_ch).is_handshaking());
    assert!(pair.client_conn_mut(client_ch).accepted_0rtt());
    assert!(
        capture
            .records()
            .iter()
            .all(|event| event["name"] != "quic:packet_lost")
    );
    pair.drive();
    pair.server.assert_accept();
    let losses: Vec<_> = capture
        .records()
        .into_iter()
        .filter(|event| event["name"] == "quic:packet_lost")
        .collect();
    assert!(
        losses.iter().any(|event| {
            event["data"]["header"]["packet_number"] == early_number
                && event["data"]["header"]["packet_type"] == "0RTT"
        }),
        "the lost early packet must retain its 0-RTT type after 1-RTT keys arrive: {losses:?}"
    );

    // A packet built with 1-RTT keys must not inherit the early packet's classification.
    pair.client_send(client_ch, stream)
        .write(b"established data")
        .unwrap();
    let established = capture_flight(&mut pair, &capture);
    assert_eq!(established.len(), 1);
    assert_eq!(established[0]["data"]["header"]["packet_type"], "1RTT");
    let established_number = established[0]["data"]["header"]["packet_number"].clone();
    pair.client.outbound.clear();
    pair.drive();
    let losses: Vec<_> = capture
        .records()
        .into_iter()
        .filter(|event| event["name"] == "quic:packet_lost")
        .collect();
    assert!(
        losses.iter().any(|event| {
            event["data"]["header"]["packet_number"] == established_number
                && event["data"]["header"]["packet_type"] == "1RTT"
        }),
        "the lost established packet must be classified as 1-RTT: {losses:?}"
    );
}

#[test]
fn qlog_mtu_probe_packets_are_identified_when_sent_and_lost() {
    let _guard = subscribe();
    let capture = Capture::default();
    let mut pair = Pair::default();
    pair.mtu = 1200;
    let mut config = client_config();
    config.transport = capture.transport(pair.time);
    let (client_ch, _) = pair.connect_with(config);
    pair.drive();

    let stats = pair.client_conn_mut(client_ch).stats();
    let sent = capture.events("quic:packet_sent");
    let probes: Vec<_> = sent
        .iter()
        .filter(|event| event["data"]["is_mtu_probe_packet"] == true)
        .collect();
    assert!(stats.path.sent_plpmtud_probes > 0);
    assert_eq!(probes.len() as u64, stats.path.sent_plpmtud_probes);
    assert!(
        sent.iter()
            .any(|event| event["data"]["is_mtu_probe_packet"] == false)
    );
    let losses = capture.events("quic:packet_lost");
    let lost_probes: Vec<_> = losses
        .iter()
        .filter(|event| event["data"]["is_mtu_probe_packet"] == true)
        .collect();
    assert_eq!(lost_probes.len() as u64, stats.path.lost_plpmtud_probes);
    assert_eq!(probes.len(), lost_probes.len());
    for probe in probes {
        assert_eq!(probe["data"]["header"]["packet_type"], "1RTT");
        assert!(probe["data"]["raw"]["length"].as_u64().unwrap() > pair.mtu as u64);
        assert!(
            lost_probes
                .iter()
                .any(|loss| loss["data"]["header"] == probe["data"]["header"])
        );
    }
    // Recording probe losses must not turn them into congestion losses.
    assert_eq!(stats.path.congestion_events, 0);
}

#[test]
fn qlog_received_lengths_match_individual_coalesced_packets() {
    let _guard = subscribe();
    let client_capture = Capture::default();
    let server_capture = Capture::default();
    let mut server = server_config();
    server.transport = server_capture.transport(Instant::now());
    let mut pair = Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        server,
    );
    let mut config = client_config();
    config.transport = client_capture.transport(pair.time);
    pair.begin_connect(config);
    pair.drive_client();

    // Deliver the client's Initial, then inspect the server's first flight before delivery.
    pair.server.drive(pair.time, pair.client.addr);
    let mut wire_lengths = Vec::new();
    let mut coalesced = false;
    for (_, bytes) in &pair.server.outbound {
        let mut remaining = Some(BytesMut::from(&bytes[..]));
        let mut packets = 0;
        while let Some(bytes) = remaining {
            let (packet, rest) = packet::PartialDecode::new(
                bytes,
                &packet::FixedLengthConnectionIdParser::new(8),
                &[Version::V1],
                true,
            )
            .unwrap();
            wire_lengths.push(packet.len());
            packets += 1;
            remaining = rest;
        }
        coalesced |= packets > 1;
    }
    assert!(
        coalesced,
        "fixture must contain multiple QUIC packets in one datagram"
    );
    let sent = server_capture.events("quic:packet_sent");
    assert_eq!(sent.len(), wire_lengths.len());
    for (event, len) in sent.iter().zip(&wire_lengths) {
        assert_eq!(event["data"]["raw"]["length"], *len);
    }
    pair.drive_server();
    pair.drive_client();
    let received = client_capture.events("quic:packet_received");
    assert_eq!(received.len(), sent.len());
    for (received, sent) in received.iter().zip(&sent) {
        assert_eq!(received["data"]["header"], sent["data"]["header"]);
        assert_eq!(received["data"]["raw"], sent["data"]["raw"]);
        assert!(received["data"].get("is_mtu_probe_packet").is_none());
    }

    // The accepting server's first Initial is decrypted in the endpoint, before the
    // connection receives it. Its length must still include the authentication tag.
    let first_sent = &client_capture.events("quic:packet_sent")[0];
    let first_received = &server_capture.events("quic:packet_received")[0];
    assert_eq!(
        first_received["data"]["header"],
        first_sent["data"]["header"]
    );
    assert_eq!(first_received["data"]["raw"], first_sent["data"]["raw"]);
}

#[test]
fn qlog_lost_probe_retains_identity_after_path_reset() {
    let _guard = subscribe();
    let capture = Capture::default();
    let mut pair = Pair::default();
    let mut config = client_config();
    config.transport = capture.transport(pair.time);
    let (client_ch, _) = pair.connect_with(config);
    pair.drive();

    // Restart discovery and put a real probe on the wire, without delivering it.
    capture.clear();
    let now = pair.time;
    pair.client_conn_mut(client_ch).path_changed(now);
    pair.client.drive_outgoing(now);
    let sent = capture.events("quic:packet_sent");
    let probe = sent
        .iter()
        .find(|event| event["data"]["is_mtu_probe_packet"] == true)
        .expect("reset MTU discovery must send a probe");
    assert!(!pair.client.outbound.is_empty());
    pair.client.outbound.clear();

    // Reset while that packet remains outstanding. MTUD no longer remembers its
    // probe number; a later ACK declares it lost through the ordinary loss path.
    let connection = pair.client_conn_mut(client_ch);
    connection.path_changed(now);
    connection.ping();
    pair.drive();
    let losses = capture.events("quic:packet_lost");
    let loss = losses
        .iter()
        .find(|event| event["data"]["header"] == probe["data"]["header"])
        .expect("the dropped outstanding probe must be declared lost");
    assert_eq!(loss["data"]["is_mtu_probe_packet"], true);
}

#[test]
fn packet_sizes_follow_the_mtu_at_emission_during_discovery_and_pto() {
    let _guard = subscribe();
    let capture = Capture::default();
    let mut pair = Pair::default();
    let mut config = client_config();
    config.transport = capture.transport(pair.time);
    let (client_ch, server_ch) = pair.connect_with(config);
    pair.drive();
    assert_eq!(
        pair.client_conn_mut(client_ch).stats().path.current_mtu,
        1452
    );

    // A changed path restarts discovery at 1200 while stream data remains queued.
    let now = pair.time;
    pair.client_conn_mut(client_ch).path_changed(now);
    let stream = pair.client_streams(client_ch).open(Dir::Uni).unwrap();
    let payload = vec![0x53; octets::kib(8)];
    pair.client_send(client_ch, stream).write(&payload).unwrap();
    pair.client_send(client_ch, stream).finish().unwrap();
    let mut ordinary = 0;
    let mut discovery = 0;
    let mut recovery = 0;
    for _ in 0..128 {
        capture.clear();
        let now = pair.time;
        let conn = pair.client_conn_mut(client_ch);
        let before = conn.emission_state();
        let mut buffer = Vec::new();
        if let Some(transmit) = conn.poll_transmit(now, 1, &mut buffer) {
            let after = pair.client_conn_mut(client_ch).emission_state();
            let events = capture.events("quic:packet_sent");
            assert_eq!(events.len(), 1, "one confirmed 1-RTT packet per datagram");
            let packet = &events[0]["data"];
            assert_eq!(packet["raw"]["length"], transmit.size);
            assert_eq!(buffer.len(), transmit.size);
            if packet["is_mtu_probe_packet"] == true {
                discovery += 1;
                assert!(transmit.size > usize::from(before.mtu));
                assert!(transmit.size <= 1452);
                assert_eq!(before.loss_probes, after.loss_probes);
            } else {
                assert!(
                    transmit.size <= usize::from(before.mtu),
                    "ordinary/PTO packet exceeds its emission-time MTU: {before:?}, {} bytes",
                    transmit.size
                );
                if after.loss_probes < before.loss_probes {
                    recovery += 1;
                } else {
                    ordinary += 1;
                }
            }
            // This simulated path drops the packet after emission; no ACK is delivered.
        } else {
            let deadline = pair
                .client_conn_mut(client_ch)
                .poll_timeout()
                .expect("loss recovery has a deadline");
            pair.time = pair.time.max(deadline);
            let now = pair.time;
            pair.client_conn_mut(client_ch).handle_timeout(now);
        }
        if ordinary > 0 && discovery > 0 && recovery > 0 {
            break;
        }
    }
    assert!(
        ordinary > 0 && discovery > 0 && recovery > 0,
        "observed ordinary={ordinary}, MTUD={discovery}, PTO={recovery}"
    );
    pair.drive();
    assert_eq!(
        pair.server_streams(server_ch).accept(Dir::Uni),
        Some(stream)
    );
    let mut recv = pair.server_recv(server_ch, stream);
    let mut chunks = recv.read(true).unwrap();
    let mut received = Vec::new();
    while let Some(chunk) = chunks.next(payload.len()).unwrap() {
        received.extend_from_slice(&chunk.bytes);
    }
    let _transmit = chunks.finalize();
    assert_eq!(
        received, payload,
        "traffic recovers after the dropped packets"
    );
}
