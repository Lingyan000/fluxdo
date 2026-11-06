use std::{net::SocketAddr, num::NonZeroUsize, sync::Arc, time::Duration};

use rama_core::{Service, bytes::Bytes, error::BoxError, io::BridgeIo, rt::Executor};
use rama_quic_proto::{Dir, VarInt};
use rama_tls::{client::TlsClientConfig, server::TlsServerConfig};
use rama_udp::test_utils::MemoryDatagramSocket;
use rama_utils::octets;
use tokio::{task::JoinHandle, time::timeout};

use super::{QuicRelay, relay_bidi};
use crate::{
    ClientConfig, Connection, ConnectionError, Endpoint, ReadError, ServerConfig, TransportConfig,
    test_helpers, tls::TlsOptions,
};

struct Fixture {
    endpoints: Vec<Endpoint>,
    client: Connection,
    origin: Connection,
    relay: JoinHandle<Result<(), BoxError>>,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.relay.abort();
        for endpoint in &self.endpoints {
            endpoint.close(0u32, b"test completed");
        }
    }
}

async fn hop(
    port: u16,
    small_receive_window: bool,
    protocol: &'static [u8],
    bidi_streams: u32,
) -> (Endpoint, Endpoint, Connection, Connection) {
    hop_with_early_data(port, small_receive_window, protocol, bidi_streams, false).await
}

#[expect(clippy::unwrap_used, reason = "test fixture construction")]
async fn hop_with_early_data(
    port: u16,
    small_receive_window: bool,
    protocol: &'static [u8],
    bidi_streams: u32,
    early_data: bool,
) -> (Endpoint, Endpoint, Connection, Connection) {
    let identity = test_helpers::identity();
    let alpn = [protocol.into()].into_iter().collect();
    let server_tls = TlsServerConfig::new()
        .with_alpn(alpn)
        .with_server_auth(identity.clone());
    let client_tls = TlsClientConfig::new()
        .with_alpn([protocol.into()].into_iter().collect())
        .try_with_server_trust_anchors([identity.cert_chain.last().unwrap().clone()])
        .unwrap();
    let mut server_config = ServerConfig::try_from_rama_tls(
        &server_tls,
        TlsOptions::default().with_early_data(early_data),
    )
    .unwrap();
    let mut transport =
        TransportConfig::default().with_max_concurrent_bidi_streams(VarInt::from_u32(bidi_streams));
    if small_receive_window {
        transport = transport
            .with_receive_window(VarInt::from_u32(1))
            .with_stream_receive_window(VarInt::from_u32(1));
    }
    server_config.set_transport_config(Arc::new(transport));
    let client_config = ClientConfig::try_from_rama_tls(
        &client_tls,
        TlsOptions::default().with_early_data(early_data),
    )
    .unwrap();
    let client_address = SocketAddr::from(([127, 0, 0, 1], port));
    let server_address = SocketAddr::from(([127, 0, 0, 1], port + 1));
    let (client_socket, server_socket) = MemoryDatagramSocket::pair(
        client_address,
        server_address,
        NonZeroUsize::new(64).unwrap(),
    );
    let mut client = Endpoint::build(Executor::new())
        .with_datagram_socket(client_socket)
        .unwrap();
    let server = Endpoint::build(Executor::new())
        .with_server_config(server_config)
        .with_datagram_socket(server_socket)
        .unwrap();
    client.set_default_client_config(client_config.clone());
    let (client_conn, server_conn) = tokio::join!(
        client
            .connect_with(client_config, server_address, "localhost")
            .unwrap(),
        async { server.accept().await.unwrap().await },
    );
    (client, server, client_conn.unwrap(), server_conn.unwrap())
}

#[expect(clippy::unwrap_used, reason = "test fixture construction")]
fn config() -> QuicRelay {
    QuicRelay::new(VarInt::from_u32(500))
        .with_streams_per_class(NonZeroUsize::new(1).unwrap())
        .with_chunk_bytes(NonZeroUsize::new(octets::kib(8)).unwrap())
        .with_datagrams(true)
}

async fn fixture(small_window: bool) -> Fixture {
    let (a, b, client, ingress) = hop(24100, false, b"rama-quic-relay-test", 128).await;
    let (c, d, egress, origin) = hop(24200, small_window, b"rama-quic-relay-test", 128).await;
    let config = config();
    let relay = tokio::spawn(async move { config.serve(BridgeIo(ingress, egress)).await });
    Fixture {
        endpoints: vec![a, b, c, d],
        client,
        origin,
        relay,
    }
}

#[tokio::test(start_paused = true)]
async fn relay_streams_and_datagrams_from_both_initiators() {
    timeout(Duration::from_secs(10), async {
        let fixture = fixture(false).await;
        for (from, to) in [
            (&fixture.client, &fixture.origin),
            (&fixture.origin, &fixture.client),
        ] {
            let mut send = from.open_uni().await.unwrap();
            send.write_all(b"unidirectional payload").await.unwrap();
            send.finish().unwrap();
            let mut recv = to.accept_uni().await.unwrap();
            assert_eq!(
                recv.read_to_end(128).await.unwrap(),
                b"unidirectional payload"
            );

            let (mut send, mut recv) = from.open_bi().await.unwrap();
            send.write_all(b"request").await.unwrap();
            send.finish().unwrap();
            let (mut response, mut request) = to.accept_bi().await.unwrap();
            assert_eq!(request.read_to_end(128).await.unwrap(), b"request");
            response
                .write_all(b"response after request FIN")
                .await
                .unwrap();
            response.finish().unwrap();
            assert_eq!(
                recv.read_to_end(128).await.unwrap(),
                b"response after request FIN"
            );

            for bytes in [b"one".as_slice(), b"second datagram".as_slice()] {
                from.send_datagram_wait(Bytes::copy_from_slice(bytes))
                    .await
                    .unwrap();
                assert_eq!(to.read_datagram().await.unwrap().as_ref(), bytes);
            }
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn relay_preserves_reset_and_stop_codes() {
    timeout(Duration::from_secs(10), async {
        let fixture = fixture(false).await;
        for (from, to) in [
            (&fixture.client, &fixture.origin),
            (&fixture.origin, &fixture.client),
        ] {
            let mut send = from.open_uni().await.unwrap();
            send.write_all(b"prefix").await.unwrap();
            let mut recv = to.accept_uni().await.unwrap();
            let mut prefix = [0; 6];
            recv.read_exact(&mut prefix).await.unwrap();
            assert_eq!(&prefix, b"prefix");
            send.reset(91u32).unwrap();
            assert_eq!(
                recv.read_to_end(128).await.unwrap_err(),
                crate::ReadToEndError::Read(ReadError::Reset(91u32.into()))
            );

            let mut send = from.open_uni().await.unwrap();
            send.write_all(b"waiting for more input").await.unwrap();
            let mut recv = to.accept_uni().await.unwrap();
            recv.stop(92u32).unwrap();
            assert_eq!(send.stopped().await.unwrap(), Some(92u32.into()));
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn relay_reset_interrupts_a_flow_control_blocked_write() {
    timeout(Duration::from_secs(10), async {
        let fixture = fixture(true).await;
        let mut send = fixture.client.open_uni().await.unwrap();
        send.write_all(&vec![7; octets::kib(16)]).await.unwrap();
        let mut recv = fixture.origin.accept_uni().await.unwrap();
        // Only one byte can reach this hop until its application reads. The
        // relay's pending write must notice a reset on its input independently.
        send.reset(93u32).unwrap();
        assert_eq!(recv.received_reset().await.unwrap(), Some(93u32.into()));
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn relay_forwards_application_close_and_cancellation() {
    timeout(Duration::from_secs(10), async {
        for egress in [false, true] {
            let mut fixture = fixture(false).await;
            let (from, to) = if egress { (&fixture.origin, &fixture.client) } else { (&fixture.client, &fixture.origin) };
            // A completed exchange establishes that the relay passed its gates.
            from.send_datagram_wait(Bytes::from_static(b"ready")).await.unwrap();
            assert_eq!(to.read_datagram().await.unwrap(), b"ready".as_slice());
            from.close(94u32, b"application reason");
            assert!(matches!(to.closed().await, ConnectionError::ApplicationClosed(close)
                if close.error_code == VarInt::from_u32(94) && close.reason == b"application reason".as_slice()));
            // Relaying an application's own close ends the relay successfully.
            (&mut fixture.relay).await.unwrap().unwrap();
        }
        let fixture = fixture(false).await;
        fixture.client.send_datagram_wait(Bytes::from_static(b"ready")).await.unwrap();
        fixture.origin.read_datagram().await.unwrap();
        fixture.relay.abort();
        for conn in [&fixture.client, &fixture.origin] {
            assert!(matches!(conn.closed().await, ConnectionError::ApplicationClosed(close) if close.error_code == VarInt::from_u32(500)));
        }
    }).await.unwrap();
}

#[tokio::test(start_paused = true)]
async fn relay_rejects_protocol_and_advertisement_mismatch() {
    timeout(Duration::from_secs(10), async {
        for mismatched_protocol in [false, true] {
            let (a, b, client, ingress) = hop(24300, false, b"first", 128).await;
            let (c, d, egress, origin) = hop(
                24400,
                false,
                if mismatched_protocol {
                    b"other"
                } else {
                    b"first"
                },
                128,
            )
            .await;
            let mut config = config();
            config.datagrams = mismatched_protocol;
            let error = config.serve(BridgeIo(ingress, egress)).await.unwrap_err();
            let expected = if mismatched_protocol {
                "application protocols differ"
            } else {
                "disabled datagrams were advertised"
            };
            assert!(error.to_string().contains(expected), "{error}");
            assert!(matches!(
                client.closed().await,
                ConnectionError::ApplicationClosed(_)
            ));
            assert!(matches!(
                origin.closed().await,
                ConnectionError::ApplicationClosed(_)
            ));
            for endpoint in [a, b, c, d] {
                endpoint.close(0u32, b"done");
            }
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn relay_stream_budget_waits_without_blocking_the_other_class() {
    timeout(Duration::from_secs(10), async {
        let fixture = fixture(false).await;
        let mut first = fixture.client.open_uni().await.unwrap();
        first.write_all(b"first").await.unwrap();
        let mut first_peer = fixture.origin.accept_uni().await.unwrap();
        let mut bytes = [0; 5];
        first_peer.read_exact(&mut bytes).await.unwrap();
        assert_eq!(&bytes, b"first");
        let mut second = fixture.client.open_uni().await.unwrap();
        second.write_all(b"second").await.unwrap();
        second.finish().unwrap();
        timeout(Duration::from_millis(1), fixture.origin.accept_uni())
            .await
            .unwrap_err();

        // This class is saturated, but the other initiator still makes progress.
        let mut reverse = fixture.origin.open_uni().await.unwrap();
        reverse.write_all(b"reverse").await.unwrap();
        reverse.finish().unwrap();
        assert_eq!(
            fixture
                .client
                .accept_uni()
                .await
                .unwrap()
                .read_to_end(128)
                .await
                .unwrap(),
            b"reverse"
        );
        first.finish().unwrap();
        assert!(first_peer.read_to_end(128).await.unwrap().is_empty());
        assert_eq!(
            fixture
                .origin
                .accept_uni()
                .await
                .unwrap()
                .read_to_end(128)
                .await
                .unwrap(),
            b"second"
        );
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn relay_both_cancelled_halves_release_pending_credit_wait() {
    timeout(Duration::from_secs(10), async {
        let (a, b, client, ingress) = hop(24500, false, b"relay", 128).await;
        let (c, d, egress, origin) = hop(24600, false, b"relay", 0).await;
        let (mut send, mut recv) = client.open_bi().await.unwrap();
        send.write_all(b"request").await.unwrap();
        let (relay_send, relay_recv) = ingress.accept_bi().await.unwrap();
        let task = tokio::spawn(async move {
            relay_bidi(
                relay_recv,
                relay_send,
                &egress,
                NonZeroUsize::new(128).unwrap(),
            )
            .await
        });
        send.reset(95u32).unwrap();
        recv.stop(96u32).unwrap();
        task.await.unwrap().unwrap();
        assert_eq!(origin.remote_open_streams(Dir::Bi), 0);
        for endpoint in [a, b, c, d] {
            endpoint.close(0u32, b"done");
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn relay_bidi_cancellation_keeps_the_other_direction_alive() {
    timeout(Duration::from_secs(10), async {
        let fixture = fixture(false).await;
        for (from, to) in [
            (&fixture.client, &fixture.origin),
            (&fixture.origin, &fixture.client),
        ] {
            let (mut send, mut recv) = from.open_bi().await.unwrap();
            send.write_all(b"prefix").await.unwrap();
            let (mut other_send, mut other_recv) = to.accept_bi().await.unwrap();
            send.reset(97u32).unwrap();
            assert_eq!(
                other_recv.received_reset().await.unwrap(),
                Some(97u32.into())
            );
            other_send
                .write_all(b"response remains valid")
                .await
                .unwrap();
            other_send.finish().unwrap();
            assert_eq!(
                recv.read_to_end(128).await.unwrap(),
                b"response remains valid"
            );

            let (mut send, mut recv) = from.open_bi().await.unwrap();
            send.write_all(b"prefix").await.unwrap();
            let (other_send, mut other_recv) = to.accept_bi().await.unwrap();
            recv.stop(98u32).unwrap();
            assert_eq!(other_send.stopped().await.unwrap(), Some(98u32.into()));
            send.write_all(b" and the remaining request").await.unwrap();
            send.finish().unwrap();
            assert_eq!(
                other_recv.read_to_end(128).await.unwrap(),
                b"prefix and the remaining request"
            );
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn relay_cancellation_before_first_poll_closes_both_hops() {
    timeout(Duration::from_secs(10), async {
        let (a, b, client, ingress) = hop(24700, false, b"relay", 128).await;
        let (c, d, egress, origin) = hop(24800, false, b"relay", 128).await;
        drop(config().serve(BridgeIo(ingress, egress)));
        for peer in [client, origin] {
            assert!(matches!(peer.closed().await, ConnectionError::ApplicationClosed(close) if close.error_code == VarInt::from_u32(500)));
        }
        for endpoint in [a, b, c, d] { endpoint.close(0u32, b"done"); }
    }).await.unwrap();
}

#[tokio::test(start_paused = true)]
async fn relay_rejects_reversed_connection_roles() {
    timeout(Duration::from_secs(10), async {
        let (a, b, client, ingress) = hop(24900, false, b"relay", 128).await;
        let (c, d, egress, origin) = hop(25000, false, b"relay", 128).await;
        let error = config().serve(BridgeIo(egress, ingress)).await.unwrap_err();
        assert!(error.to_string().contains("server and a client"), "{error}");
        for peer in [client, origin] {
            assert!(
                matches!(peer.closed().await, ConnectionError::ApplicationClosed(close)
                if close.error_code == VarInt::from_u32(500))
            );
        }
        for endpoint in [a, b, c, d] {
            endpoint.close(0u32, b"done");
        }
    })
    .await
    .unwrap();
}

/// Resume a real ticket-bearing session so the relay sees installed early-data
/// keys, rather than merely a TLS configuration that permits future resumption.
#[expect(
    clippy::unwrap_used,
    clippy::panic,
    reason = "test fixture requires actual resumption keys"
)]
async fn resumed_hop(port: u16) -> (Endpoint, Endpoint, Connection, Connection) {
    let (client_endpoint, server_endpoint, client, server) =
        hop_with_early_data(port, false, b"relay", 128, true).await;
    let mut send = server.open_uni().await.unwrap();
    send.write_all(b"ticket delivery barrier").await.unwrap();
    send.finish().unwrap();
    client
        .accept_uni()
        .await
        .unwrap()
        .read_to_end(128)
        .await
        .unwrap();
    client.close(0u32, b"resume next session");
    server.closed().await;

    let connecting = client_endpoint
        .connect(server_endpoint.local_addr().unwrap(), "localhost")
        .unwrap();
    let (client, accepted) = connecting
        .into_0rtt()
        .unwrap_or_else(|_| panic!("the first session must provide resumption keys"));
    let server = server_endpoint.accept().await.unwrap().await.unwrap();
    assert!(accepted.await.unwrap());
    tokio::try_join!(client.handshake_confirmed(), server.handshake_confirmed()).unwrap();
    assert!(client.early_data_keys_enabled());
    assert!(server.early_data_keys_enabled());
    (client_endpoint, server_endpoint, client, server)
}

#[tokio::test(start_paused = true)]
async fn relay_rejects_resumed_early_data_on_either_hop() {
    timeout(Duration::from_secs(10), async {
        for early_ingress in [false, true] {
            let (a, b, client, ingress) = if early_ingress {
                resumed_hop(25100).await
            } else {
                hop(25100, false, b"relay", 128).await
            };
            let (c, d, egress, origin) = if early_ingress {
                hop(25200, false, b"relay", 128).await
            } else {
                resumed_hop(25200).await
            };
            let error = config().serve(BridgeIo(ingress, egress)).await.unwrap_err();
            assert!(error.to_string().contains("early data disabled"), "{error}");
            for peer in [client, origin] {
                assert!(
                    matches!(peer.closed().await, ConnectionError::ApplicationClosed(close)
                    if close.error_code == VarInt::from_u32(500))
                );
            }
            for endpoint in [a, b, c, d] {
                endpoint.close(0u32, b"done");
            }
        }
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn relay_stream_class_limits_hold_until_the_active_pair_finishes() {
    timeout(Duration::from_secs(10), async {
        let fixture = fixture(false).await;
        for (from, to) in [
            (&fixture.client, &fixture.origin),
            (&fixture.origin, &fixture.client),
        ] {
            // A stream with no FIN retains its slot even after its current bytes
            // are delivered. Admission must resume when that exact pair ends.
            let mut first = from.open_uni().await.unwrap();
            first.write_all(b"a").await.unwrap();
            let mut first_peer = to.accept_uni().await.unwrap();
            let mut byte = [0];
            first_peer.read_exact(&mut byte).await.unwrap();
            assert_eq!(byte, [b'a']);
            let mut second = from.open_uni().await.unwrap();
            second.write_all(b"b").await.unwrap();
            second.finish().unwrap();
            timeout(Duration::from_millis(1), to.accept_uni())
                .await
                .unwrap_err();
            first.finish().unwrap();
            assert!(first_peer.read_to_end(1).await.unwrap().is_empty());
            assert_eq!(
                to.accept_uni().await.unwrap().read_to_end(1).await.unwrap(),
                b"b"
            );

            let (mut first_send, mut first_receive) = from.open_bi().await.unwrap();
            first_send.write_all(b"c").await.unwrap();
            let (mut first_peer_send, mut first_peer_receive) = to.accept_bi().await.unwrap();
            first_peer_receive.read_exact(&mut byte).await.unwrap();
            assert_eq!(byte, [b'c']);
            let (mut second_send, mut second_receive) = from.open_bi().await.unwrap();
            second_send.write_all(b"d").await.unwrap();
            second_send.finish().unwrap();
            timeout(Duration::from_millis(1), to.accept_bi())
                .await
                .unwrap_err();

            // Ending only the request direction must still retain the pair's slot.
            first_send.finish().unwrap();
            assert!(first_peer_receive.read_to_end(1).await.unwrap().is_empty());
            timeout(Duration::from_millis(1), to.accept_bi())
                .await
                .unwrap_err();
            first_peer_send.finish().unwrap();
            assert!(first_receive.read_to_end(1).await.unwrap().is_empty());
            let (mut second_peer_send, mut second_peer_receive) = to.accept_bi().await.unwrap();
            assert_eq!(second_peer_receive.read_to_end(1).await.unwrap(), b"d");
            second_peer_send.finish().unwrap();
            assert!(second_receive.read_to_end(1).await.unwrap().is_empty());
        }
    })
    .await
    .unwrap();
}
