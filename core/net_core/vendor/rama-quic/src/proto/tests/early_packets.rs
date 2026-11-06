//! Packets that overtake the packet carrying their keys are held and processed once the keys
//! are available, within the configured bounds (RFC 9001 §4.1.4).

use std::collections::VecDeque;

use rama_quic_proto::{
    Dir,
    packet::{FixedLengthConnectionIdParser, PartialDecode, SpaceId},
};
use rama_utils::octets;

use super::{qlog::Capture, *};

/// The packets of a datagram with their packet number space, each to be sent on its own.
fn packets(datagram: &BytesMut) -> Vec<(BytesMut, Option<SpaceId>)> {
    let mut packets = Vec::new();
    let mut rest = Some(datagram.clone());
    while let Some(bytes) = rest {
        let (packet, next) = PartialDecode::new(
            bytes,
            &FixedLengthConnectionIdParser::new(8),
            DEFAULT_SUPPORTED_VERSIONS,
            true,
        )
        .unwrap();
        packets.push((BytesMut::from(packet.data()), packet.space()));
        rest = next;
    }
    packets
}

/// Splits the queued datagrams into their packets, each in a datagram of its own: those `keep`
/// accepts stay in order, followed by those `late` selects; any other packet is lost.
fn reorder(
    inbound: &mut VecDeque<Inbound>,
    keep: impl Fn(Option<SpaceId>) -> bool,
    late: impl Fn(Option<SpaceId>) -> bool,
) -> usize {
    let mut first = Vec::new();
    let mut last = Vec::new();
    for datagram in inbound.drain(..) {
        for (packet, space) in packets(&datagram.packet) {
            let queue = if late(space) {
                &mut last
            } else if keep(space) {
                &mut first
            } else {
                continue;
            };
            queue.push(Inbound {
                at: datagram.at,
                ecn: datagram.ecn,
                packet,
                from: datagram.from,
                to: datagram.to,
            });
        }
    }
    let overtaking = first.len();
    inbound.extend(first);
    inbound.extend(last);
    overtaking
}

/// Delivers every queued datagram `times` over, as a network that duplicates them would.
fn duplicate(inbound: &mut VecDeque<Inbound>, times: usize) -> usize {
    let queued: Vec<Inbound> = inbound.drain(..).collect();
    for _ in 0..times {
        inbound.extend(queued.iter().cloned());
    }
    inbound.len()
}

/// Exchanges at the current instant: no timer fires, so nothing is retransmitted.
fn exchange(pair: &mut Pair, rounds: usize) {
    for _ in 0..rounds {
        pair.drive_client();
        pair.drive_server();
    }
}

fn transport(packets: usize, bytes: usize) -> TransportConfig {
    let mut transport = TransportConfig::default();
    transport
        .set_early_packet_buffer_packets(packets)
        .set_early_packet_buffer_size(bytes);
    transport
}

fn client(transport: TransportConfig) -> ClientConfig {
    let mut config = client_config();
    config.transport = Arc::new(transport);
    config
}

fn pair_with_server(transport: TransportConfig) -> Pair {
    let mut config = server_config();
    config.transport = Arc::new(transport);
    Pair::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        config,
    )
}

fn is_initial(space: Option<SpaceId>) -> bool {
    space == Some(SpaceId::Initial)
}

#[test]
fn defaults_hold_a_burst_of_packets() {
    let transport = TransportConfig::default();
    assert_eq!(transport.early_packet_buffer_packets, 32);
    assert_eq!(transport.early_packet_buffer_size, octets::kib(64));
    let debug = format!("{transport:?}");
    assert!(debug.contains("early_packet_buffer_packets: 32"));
    assert!(debug.contains("early_packet_buffer_size: 65536"));
}

/// The server's Handshake and 1-RTT packets arrive before its Initial: a client that holds them
/// completes the handshake as soon as the Initial is in, one that drops them has to wait for the
/// server to resend.
#[test]
fn client_holds_a_server_flight_that_overtakes_its_initial() {
    let _guard = subscribe();
    for hold in [true, false] {
        let mut pair = Pair::default();
        let capture = Capture::default();
        let mut transport = transport(if hold { 32 } else { 0 }, octets::kib(64));
        transport.set_qlog_recorder(capture.config(pair.time));
        let client = pair.begin_connect(client(transport));
        pair.drive_client();
        pair.drive_server();
        let overtaking = reorder(&mut pair.client.inbound, |_| true, is_initial);
        assert!(
            overtaking > 0,
            "the server flight carries more than its Initial"
        );

        pair.drive_client();
        assert_eq!(pair.client_conn_mut(client).held_early_packets(), 0);
        let buffered = capture.events("quic:packet_buffered");
        if hold {
            assert_eq!(buffered.len(), overtaking);
            for event in &buffered {
                assert_eq!(event["data"]["trigger"], "keys_unavailable");
                assert!(event["data"]["raw"]["length"].as_u64().unwrap() > 0);
                assert!(event["data"]["header"].get("packet_number").is_none());
            }
            assert!(
                buffered
                    .iter()
                    .any(|event| { event["data"]["header"]["packet_type"] == "handshake" })
            );
        } else {
            assert!(buffered.is_empty());
            assert!(
                capture
                    .events("quic:packet_dropped")
                    .iter()
                    .any(|event| event["data"]["trigger"] == "key_unavailable")
            );
        }

        exchange(&mut pair, 3);
        assert_eq!(
            !pair.client_conn_mut(client).is_handshaking(),
            hold,
            "holding (here: {hold}) completes the handshake without a retransmission"
        );

        // Either way the handshake completes, at the latest once the server resends.
        pair.drive();
        assert!(!pair.client_conn_mut(client).is_handshaking());
        pair.server.assert_accept();
    }
}

/// The client's first 1-RTT data arrives before its Finished: a server that holds it delivers
/// the stream as soon as the handshake completes.
#[test]
fn server_holds_client_data_that_overtakes_its_finished() {
    let _guard = subscribe();
    for hold in [true, false] {
        let mut pair = pair_with_server(transport(if hold { 32 } else { 0 }, octets::kib(64)));
        let client = pair.begin_connect(client_config());
        pair.drive_client();
        pair.drive_server();
        pair.drive_client();
        assert!(!pair.client_conn_mut(client).is_handshaking());

        let stream = pair.client_streams(client).open(Dir::Uni).unwrap();
        pair.client_send(client, stream)
            .write(b"overtakes")
            .unwrap();
        pair.client_send(client, stream).finish().unwrap();
        pair.drive_client();
        let data = |space| space == Some(SpaceId::Data);
        assert!(reorder(&mut pair.server.inbound, data, |space| !data(space)) > 0);

        pair.drive_server();
        let server = pair.server.assert_accept();
        assert_eq!(pair.server_conn_mut(server).held_early_packets(), 0);
        let delivered = pair.server_streams(server).accept(Dir::Uni);
        if !hold {
            assert_eq!(delivered, None, "dropped data waits for a retransmission");
            pair.drive();
            assert_eq!(pair.server_streams(server).accept(Dir::Uni), Some(stream));
        } else {
            assert_eq!(delivered, Some(stream));
        }
        let mut received = pair.server_recv(server, stream);
        let mut chunks = received.read(true).unwrap();
        let chunk = chunks.next(usize::MAX).unwrap().unwrap();
        assert_eq!(&chunk.bytes[..], b"overtakes");
        let _transmit = chunks.finalize();
    }
}

/// What is held stays within both the packet and the byte bound; zero for either holds nothing.
#[test]
fn held_packets_respect_both_bounds() {
    let _guard = subscribe();
    for (packets, bytes, expected) in [
        (1, octets::kib(64), Some(1)),
        (32, 100, Some(0)),
        (0, octets::kib(64), Some(0)),
        (32, 0, Some(0)),
        (32, octets::kib(64), None),
    ] {
        let mut pair = Pair::default();
        let client = pair.begin_connect(client(transport(packets, bytes)));
        pair.drive_client();
        pair.drive_server();
        // The server's Initial is lost, so nothing opens the rest of its flight, which the
        // network delivers several times over.
        reorder(
            &mut pair.client.inbound,
            |space| !is_initial(space),
            |_| false,
        );
        let overtaking = duplicate(&mut pair.client.inbound, 4);
        assert!(overtaking > 1, "several packets to hold");
        pair.drive_client();
        assert_eq!(
            pair.client_conn_mut(client).held_early_packets(),
            expected.unwrap_or(overtaking),
            "{packets} packets, {bytes} bytes"
        );

        // Holding never stands in the way: the resent flight completes the handshake.
        pair.drive();
        assert!(!pair.client_conn_mut(client).is_handshaking());
        assert_eq!(pair.client_conn_mut(client).held_early_packets(), 0);
    }
}

/// A resumed client's 0-RTT data arrives between the Initials of a ClientHello that spans
/// several: a server that holds it accepts the data with the ClientHello, one that drops it
/// waits for the client to resend.
#[test]
fn server_holds_0rtt_that_overtakes_the_rest_of_the_client_hello() {
    let _guard = subscribe();
    const MSG: &[u8] = b"Hello, held 0-RTT!";
    for hold in [true, false] {
        let mut server =
            ServerConfig::with_crypto(Arc::new(server_crypto_with_alpn(vec![vec![0, 0, 0, 42]])));
        server.transport = Arc::new(transport(if hold { 32 } else { 0 }, octets::kib(64)));
        let mut pair = Pair::new(
            Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
            server,
        );
        // Enough protocols that the ClientHello spans several Initials.
        let config = ClientConfig::new(Arc::new(client_crypto_with_alpn(
            (0..300u32).map(|x| x.to_be_bytes().to_vec()).collect(),
        )));

        let first = pair.begin_connect(config.clone());
        pair.drive();
        pair.server.assert_accept();
        let now = pair.time;
        pair.client_conn_mut(first)
            .close(now, VarInt::from_u32(0), Bytes::new());
        pair.drive();
        pair.client.addr = SocketAddr::new(
            Ipv6Addr::LOCALHOST.into(),
            CLIENT_PORTS.lock().next().unwrap(),
        );

        let client = pair.begin_connect(config);
        assert!(pair.client_conn_mut(client).has_0rtt());
        let stream = pair.client_streams(client).open(Dir::Uni).unwrap();
        pair.client_send(client, stream).write(MSG).unwrap();
        pair.drive_client();

        // The first Initial, then the 0-RTT data, then the rest of the ClientHello. A datagram
        // keeps its size, so the Initials left in it still meet the minimum; the filler reads
        // as an unsupported version and is dropped.
        let mut initials = Vec::new();
        let mut early = Vec::new();
        for datagram in pair.server.inbound.drain(..) {
            let mut kept = BytesMut::new();
            for (packet, space) in packets(&datagram.packet) {
                if is_initial(space) {
                    kept.extend_from_slice(&packet);
                } else {
                    early.push(Inbound {
                        packet,
                        ..datagram.clone()
                    });
                }
            }
            if !kept.is_empty() {
                kept.resize(datagram.packet.len(), 0xff);
                initials.push(Inbound {
                    packet: kept,
                    ..datagram
                });
            }
        }
        assert!(initials.len() > 1, "the ClientHello spans several Initials");
        assert!(!early.is_empty(), "the client sent 0-RTT");
        let rest = initials.split_off(1);
        pair.server.inbound.extend(initials);
        pair.server.inbound.extend(early);
        pair.server.inbound.extend(rest);

        pair.drive_server();
        let server = pair.server.assert_accept();
        assert_eq!(pair.server_conn_mut(server).held_early_packets(), 0);
        let delivered = pair.server_streams(server).accept(Dir::Uni);
        pair.drive();
        assert!(pair.client_conn_mut(client).accepted_0rtt());
        let lost = pair.client_conn_mut(client).stats().path.lost_packets;
        if hold {
            assert_eq!(
                delivered,
                Some(stream),
                "held 0-RTT opens with the ClientHello"
            );
            assert_eq!(lost, 0);
        } else {
            assert_eq!(delivered, None, "dropped 0-RTT waits for a retransmission");
            assert!(lost > 0);
            assert_eq!(pair.server_streams(server).accept(Dir::Uni), Some(stream));
        }
        let mut received = pair.server_recv(server, stream);
        let mut chunks = received.read(true).unwrap();
        let chunk = chunks.next(usize::MAX).unwrap().unwrap();
        assert_eq!(&chunk.bytes[..], MSG);
        let _transmit = chunks.finalize();
    }
}

/// A held packet that fails authentication once its keys are in is dropped like any other.
#[test]
fn corrupted_held_packet_fails_authentication_when_processed() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let capture = Capture::default();
    let mut transport = TransportConfig::default();
    transport.set_qlog_recorder(capture.config(pair.time));
    let client = pair.begin_connect(client(transport));
    pair.drive_client();
    pair.drive_server();
    reorder(&mut pair.client.inbound, |_| true, is_initial);
    let handshake = pair
        .client
        .inbound
        .iter_mut()
        .find(|datagram| packets(&datagram.packet)[0].1 == Some(SpaceId::Handshake))
        .expect("a Handshake packet overtakes the Initial");
    let last = handshake.packet.len() - 1;
    handshake.packet[last] ^= 0xff;

    pair.drive_client();
    assert!(!capture.events("quic:packet_buffered").is_empty());
    assert!(
        capture
            .events("quic:packet_dropped")
            .iter()
            .any(|event| event["data"]["trigger"] == "decryption_failure"),
        "the corrupted packet is dropped once it can be opened"
    );
    assert!(!pair.client_conn_mut(client).is_closed());

    pair.drive();
    assert!(!pair.client_conn_mut(client).is_handshaking());
}

/// A connection that closes during the handshake lets go of what it held.
#[test]
fn closing_releases_held_packets() {
    let _guard = subscribe();
    let mut pair = Pair::default();
    let client = pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    reorder(
        &mut pair.client.inbound,
        |space| !is_initial(space),
        |_| false,
    );
    pair.drive_client();
    assert!(pair.client_conn_mut(client).held_early_packets() > 0);

    let now = pair.time;
    pair.client_conn_mut(client)
        .close(now, VarInt::from_u32(0), Bytes::new());
    assert_eq!(pair.client_conn_mut(client).held_early_packets(), 0);
}
