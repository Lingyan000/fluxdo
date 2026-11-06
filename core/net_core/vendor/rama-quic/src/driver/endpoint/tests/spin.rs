//! Actual loopback UDP, bounded wire captures and sustained transfers through CID/path changes.

use super::lifecycle::{SegmentLog, endpoint_with, exchange, handshake, recording_socket};
use crate::driver::udp::Socket;
use crate::{Connection, Endpoint, EndpointConfig, proxy::QuicRelay};
use parking_lot::Mutex;
use rama_core::{Service as _, io::BridgeIo, rt::Executor};
use rama_quic_proto::{
    Version,
    packet::{FixedLengthConnectionIdParser, PartialDecode, SPIN_BIT},
    version::ClientVersionPolicy,
};
use std::{
    net::{SocketAddr, SocketAddrV4},
    sync::Arc,
    time::Duration,
};

const LIMIT: Duration = Duration::from_secs(20);
const CAPTURE_LIMIT: usize = 2048;
type Log = Arc<Mutex<SegmentLog>>;

fn capture() -> (Socket, Log) {
    let (socket, log) = recording_socket();
    log.lock().capture_limit = Some(CAPTURE_LIMIT);
    (socket, log)
}

struct Hop {
    client_endpoint: Endpoint,
    server_endpoint: Endpoint,
    client: Connection,
    server: Connection,
    client_log: Log,
    server_log: Log,
    preferred: Option<(SocketAddr, Log)>,
}

impl Drop for Hop {
    fn drop(&mut self) {
        self.client_endpoint.close(0u32, b"spin test done");
        self.server_endpoint.close(0u32, b"spin test done");
    }
}

/// The fixture searches a bounded, fixed population for the requested suppression outcome.
/// It observes the real constructor's draw, and never overrides its decision.
async fn hop(version: Version, allow: [bool; 2], enabled: [bool; 2], preferred: bool) -> Hop {
    let (mut client_config, mut server_config) = super::lifecycle::configs_with_options(
        crate::tls::TlsOptions::default().with_early_data(false),
    );
    Arc::make_mut(&mut client_config.transport).set_allow_spin(allow[0]);
    Arc::make_mut(&mut server_config.transport).set_allow_spin(allow[1]);
    client_config
        .set_versions(ClientVersionPolicy::new(version).unwrap())
        .unwrap();
    for seed in 0u8..=255 {
        let config = EndpointConfig::try_with_rand_key()
            .unwrap()
            .with_rng_seed([seed; 32]);
        let (client_socket, client_log) = capture();
        let (server_socket, server_log) = capture();
        let mut server_config = server_config.clone();
        let (advertised, preferred) = if preferred {
            let (socket, log) = capture();
            let addr = socket.local_addr();
            let SocketAddr::V4(v4) = addr else {
                panic!("IPv4 fixture")
            };
            server_config.set_preferred_address_v4(SocketAddrV4::new(*v4.ip(), v4.port()));
            (vec![socket], Some((addr, log)))
        } else {
            (Vec::new(), None)
        };
        let client_endpoint = endpoint_with(config.clone(), None, client_socket);
        let server_endpoint = Endpoint::new_with_advertised(
            config.with_rng_seed([seed.wrapping_add(64); 32]),
            Some(server_config),
            server_socket,
            advertised,
            Executor::new(),
            Duration::from_secs(1),
        )
        .unwrap();
        let connecting = client_endpoint
            .connect_with(
                client_config.clone(),
                server_endpoint.local_addr().unwrap(),
                "localhost",
            )
            .unwrap();
        let incoming = server_endpoint.accept().await.unwrap();
        let (client, server) = handshake(connecting, incoming).await;
        let hop = Hop {
            client_endpoint,
            server_endpoint,
            client,
            server,
            client_log,
            server_log,
            preferred,
        };
        if [
            hop.client.spin_enabled_for_test(),
            hop.server.spin_enabled_for_test(),
        ] == enabled
        {
            assert_eq!(hop.client.version(), version);
            assert_eq!(hop.server.version(), version);
            return hop;
        }
    }
    panic!("fixed seed population has no {enabled:?} fixture");
}

/// Parse the correct header form, skipping every coalesced long-header packet. v1 and v2
/// share the short-header spin bit. Packet captures contain only public test payloads.
fn spins(log: &Log, conn: &Connection) -> Vec<bool> {
    assert!(matches!(conn.version(), Version::V1 | Version::V2));
    let mut spins = Vec::new();
    for datagram in &log.lock().sent {
        let mut rest: Option<rama_core::bytes::BytesMut> = Some(datagram.bytes.as_slice().into());
        while let Some(bytes) = rest {
            let first = bytes[0];
            let (header, remaining) = PartialDecode::new(
                bytes,
                &FixedLengthConnectionIdParser::new(conn.active_dcid().len()),
                &[Version::V1, Version::V2],
                true,
            )
            .unwrap();
            if !header.has_long_header() {
                spins.push(first & SPIN_BIT != 0);
            }
            rest = remaining;
        }
    }
    spins
}

async fn traffic(client: &Connection, server: &Connection, rounds: usize) {
    for sequence in 0..rounds {
        let payload = vec![sequence as u8; 1024];
        tokio::join!(
            exchange(client, server, &payload),
            exchange(server, client, &payload)
        );
    }
    assert!(client.close_reason().is_none());
    assert!(server.close_reason().is_none());
}

#[tokio::test]
async fn spin_real_udp_enabled_opt_out_and_random_suppression_v1_v2() {
    tokio::time::timeout(LIMIT, async {
        for version in [Version::V1, Version::V2] {
            for (allow, enabled) in [
                ([true; 2], [true; 2]),
                ([false, true], [false, true]),
                ([true, false], [true, false]),
                ([true; 2], [false; 2]),
                ([true; 2], [false, true]),
                ([true; 2], [true, false]),
            ] {
                let hop = hop(version, allow, enabled, false).await;
                traffic(&hop.client, &hop.server, 24).await;
                for (log, conn) in [
                    (&hop.client_log, &hop.client),
                    (&hop.server_log, &hop.server),
                ] {
                    let bits = spins(log, conn);
                    assert!(bits.len() >= 24, "sustained 1-RTT traffic");
                    if enabled == [true; 2] {
                        assert!(
                            bits.contains(&false) && bits.contains(&true),
                            "continuous enabled signaling: {bits:?}"
                        );
                    }
                    // Disabled output is random: neither toggling nor a different sequence
                    // from the peer is required. Exact seeded RNG behavior is tested in proto.
                }
            }
        }
    })
    .await
    .expect("bounded spin UDP matrix");
}

#[tokio::test]
async fn spin_real_udp_stream_survives_rebind_cid_retirement_and_preferred_address() {
    tokio::time::timeout(LIMIT, async {
        for version in [Version::V1, Version::V2] {
            for (enabled, binding) in [
                (true, 0),
                (false, 0),
                (true, 1),
                (false, 1),
                (true, 2),
                (false, 2),
            ] {
                let hop = hop(version, [enabled; 2], [enabled; 2], true).await;
                let (preferred, preferred_log) = hop.preferred.as_ref().unwrap();
                traffic(&hop.client, &hop.server, 8).await;
                assert_eq!(hop.client.remote_address(), *preferred);
                let old_cid = hop.client.active_dcid();
                let (mut send, mut recv) = hop.client.open_bi().await.unwrap();
                send.write_all(b"start").await.unwrap();
                let (mut reply, mut incoming) = hop.server.accept_bi().await.unwrap();
                let mut start = [0; 5];
                incoming.read_exact(&mut start).await.unwrap();
                assert_eq!(&start, b"start");
                let (moved, moved_log) = if binding == 2 {
                    let mut options = rama_net::socket::SocketOptions::default_udp();
                    options.only_v6 = Some(false);
                    let socket = rama_udp::UdpSocketFactory::new(
                        rama_udp::UdpSocketConfig::new().with_socket_options(options),
                    )
                    .bind("[::]:0")
                    .await
                    .unwrap();
                    let (socket, log) = super::lifecycle::recording_packet_socket(socket);
                    log.lock().capture_limit = Some(CAPTURE_LIMIT);
                    (socket, log)
                } else if binding == 1 {
                    let socket = std::net::UdpSocket::bind("0.0.0.0:0").unwrap();
                    let (socket, log) = super::lifecycle::recording_socket_from(socket);
                    log.lock().capture_limit = Some(CAPTURE_LIMIT);
                    (socket, log)
                } else {
                    capture()
                };
                let mut moved_addr = moved.local_addr();
                moved_addr.set_ip(std::net::Ipv4Addr::LOCALHOST.into());
                hop.client_endpoint.rebind_abstract(moved).unwrap();
                let mut before_retirement = None;
                for sequence in 0..32u8 {
                    if sequence == 16 {
                        before_retirement = Some(hop.client.active_dcid());
                        hop.server
                            .rotate_local_cid(hop.client.active_dcid_seq() + 1);
                    }
                    let payload = [sequence; 1024];
                    send.write_all(&payload).await.unwrap();
                    let mut actual = [0; 1024];
                    incoming.read_exact(&mut actual).await.unwrap();
                    assert_eq!(actual, payload);
                    reply.write_all(&actual).await.unwrap();
                    recv.read_exact(&mut actual).await.unwrap();
                    assert_eq!(actual, payload);
                }
                send.finish().unwrap();
                reply.finish().unwrap();
                assert!(incoming.read_to_end(1).await.unwrap().is_empty());
                assert!(recv.read_to_end(1).await.unwrap().is_empty());
                assert_eq!(hop.server.remote_address(), moved_addr);
                assert_ne!(hop.client.active_dcid(), old_cid);
                assert_ne!(
                    Some(hop.client.active_dcid()),
                    before_retirement,
                    "retirement switches again after rebinding"
                );
                assert!(hop.client.path_validated_for_test());
                assert!(hop.server.path_validated_for_test());
                let moved_bits = spins(&moved_log, &hop.client);
                let preferred_bits = spins(preferred_log, &hop.server);
                assert!(!moved_bits.is_empty() && !preferred_bits.is_empty());
                if enabled {
                    assert_eq!(
                        moved_bits.first(),
                        Some(&false),
                        "new local path starts at zero"
                    );
                    assert_eq!(
                        preferred_bits.first(),
                        Some(&false),
                        "preferred local path starts at zero"
                    );
                    assert!(moved_bits.contains(&true) && preferred_bits.contains(&true));
                    let cid = hop.client.active_dcid();
                    let log = moved_log.lock();
                    let rotated: Vec<_> = log
                        .sent
                        .iter()
                        .filter(|d| {
                            d.bytes[0] & 0x80 == 0
                                && d.bytes.get(1..1 + cid.len()) == Some(cid.as_slice())
                        })
                        .collect();
                    assert!(rotated.len() >= 8, "sustained traffic after retirement");
                    assert!(rotated.iter().any(|d| d.bytes[0] & SPIN_BIT != 0));
                    assert!(rotated.iter().any(|d| d.bytes[0] & SPIN_BIT == 0));
                    // The first post-retirement packet may already reflect a newer reception;
                    // the exact reset-before-receive ordering is covered by the proto test.
                }
                assert!(hop.client.close_reason().is_none() && hop.server.close_reason().is_none());
            }
        }
    })
    .await
    .expect("bounded migration/CID transfer");
}

#[tokio::test]
async fn spin_real_udp_terminating_relay_keeps_hop_configuration_independent() {
    tokio::time::timeout(LIMIT, async {
        for disabled_ingress in [true, false] {
            let downstream = hop(
                Version::V1,
                [true, !disabled_ingress],
                [true, !disabled_ingress],
                false,
            )
            .await;
            let upstream = hop(
                Version::V1,
                [disabled_ingress, true],
                [disabled_ingress, true],
                false,
            )
            .await;
            let ingress = downstream.server.clone();
            let egress = upstream.client.clone();
            let relay = tokio::spawn(async move {
                let result = QuicRelay::new(500u32.into())
                    .with_datagrams(true)
                    .serve(BridgeIo(ingress, egress))
                    .await;
                assert!(result.is_ok(), "relay failed: {result:?}");
                result
            });
            traffic(&downstream.client, &upstream.server, 24).await;
            assert_eq!(downstream.server.spin_enabled_for_test(), !disabled_ingress);
            assert_eq!(upstream.client.spin_enabled_for_test(), disabled_ingress);
            for (log, conn) in [
                (&downstream.server_log, &downstream.server),
                (&upstream.client_log, &upstream.client),
            ] {
                let bits = spins(log, conn);
                assert!(bits.len() >= 24);
                if conn.spin_enabled_for_test() {
                    assert!(
                        bits.contains(&false) && bits.contains(&true),
                        "enabled relay hop"
                    );
                }
            }
            downstream.client.close(0u32, b"done");
            relay.await.unwrap().unwrap();
        }
    })
    .await
    .expect("bounded terminating relay");
}

#[tokio::test]
async fn spin_real_udp_forwarding_preserves_captured_quic_datagrams() {
    use rama_net::{address::SocketAddress, stream::Socket as _};
    use rama_udp::{
        DatagramSenderExt as _, DatagramSocket as _, DatagramSocketExt as _, SendDatagram,
        UdpPacketSocket,
        proxy::{DatagramForwardService, EcnPolicy, Peer},
    };
    use std::num::NonZeroUsize;

    tokio::time::timeout(LIMIT, async {
        for version in [Version::V1, Version::V2] {
            let hop = hop(version, [true; 2], [true; 2], false).await;
            traffic(&hop.client, &hop.server, 8).await;
            let captured = [
                hop.client_log.lock().sent.clone(),
                hop.server_log.lock().sent.clone(),
            ];
            let mut client = UdpPacketSocket::bind(SocketAddress::local_ipv4(0))
                .await
                .unwrap();
            let down = UdpPacketSocket::bind(SocketAddress::local_ipv4(0))
                .await
                .unwrap();
            let up = UdpPacketSocket::bind(SocketAddress::local_ipv4(0))
                .await
                .unwrap();
            let mut origin = UdpPacketSocket::bind(SocketAddress::local_ipv4(0))
                .await
                .unwrap();
            let down_addr = down.local_addr().unwrap();
            let up_addr = up.local_addr().unwrap();
            let ingress = Peer {
                socket: down,
                address: client.local_addr().unwrap(),
                source_ip: None,
            };
            let egress = Peer {
                socket: up,
                address: origin.local_addr().unwrap(),
                source_ip: None,
            };
            let relay = tokio::spawn(async move {
                DatagramForwardService::new(NonZeroUsize::new(65536).unwrap(), EcnPolicy::Discard)
                    .serve(BridgeIo(ingress, egress))
                    .await
            });
            let mut bytes = vec![0; 65536];
            for (direction, datagrams) in captured.into_iter().enumerate() {
                let (from, to, destination) = if direction == 0 {
                    (&mut client, &mut origin, down_addr)
                } else {
                    (&mut origin, &mut client, up_addr)
                };
                let mut sender = from.create_sender();
                for datagram in datagrams {
                    sender
                        .send(SendDatagram::new(destination, &datagram.bytes))
                        .await
                        .unwrap();
                    let received = to.recv(&mut bytes).await.unwrap();
                    assert_eq!(
                        &bytes[..received.len],
                        &datagram.bytes,
                        "full QUIC payload, including spin and AEAD tag"
                    );
                }
            }
            relay.abort();
            assert!(relay.await.unwrap_err().is_cancelled());
        }
    })
    .await
    .expect("bounded untouched forwarding");
}
