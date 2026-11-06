//! Independent peer coverage. Quinn's allow_spin is set explicitly in every case;
//! permission does not guarantee its random suppression draw enables signaling.

mod common;

use common::{
    identity, localhost, quinn_client_config, quinn_server_config, rama_client_config,
    rama_server_config, step,
};
use parking_lot::Mutex;
use rama::{
    quic::{Endpoint, TransportConfig},
    rt::Executor,
};
use std::sync::Arc;

/// A bounded, header-only trace between two known QUIC v1 endpoints. No application
/// payload or TLS key material is retained. A short-header datagram cannot coalesce a
/// subsequent packet; coalesced long-header datagrams are deliberately excluded.
async fn proxy(
    server: std::net::SocketAddr,
) -> (
    std::net::SocketAddr,
    Arc<Mutex<Vec<(bool, bool)>>>,
    tokio::task::JoinHandle<()>,
) {
    let socket = tokio::net::UdpSocket::bind(localhost()).await.unwrap();
    let address = socket.local_addr().unwrap();
    let trace = Arc::new(Mutex::new(Vec::new()));
    let copy = trace.clone();
    let task = tokio::spawn(async move {
        let mut client = None;
        let mut bytes = [0; 65536];
        loop {
            let (len, from) = socket.recv_from(&mut bytes).await.unwrap();
            let from_server = from == server;
            let to = if from_server {
                client.expect("client sent first")
            } else {
                if let Some(client) = client {
                    assert_eq!(client, from);
                }
                client = Some(from);
                server
            };
            if len > 0 && bytes[0] & 0x80 == 0 {
                let mut trace = copy.lock();
                assert!(trace.len() < 4096, "bounded header capture");
                trace.push((from_server, bytes[0] & 0x20 != 0));
            }
            socket.send_to(&bytes[..len], to).await.unwrap();
        }
    });
    (address, trace, task)
}

#[tokio::test]
async fn spin_permission_and_opt_out_interoperate_with_quinn_in_both_roles() {
    step("spin interop matrix", async {
        let identity = identity();
        let anchor = identity.cert_chain.last().unwrap().clone();
        for rama_is_client in [true, false] {
            for rama_allow in [true, false] {
                for quinn_allow in [true, false] {
                    let rama_transport =
                        Arc::new(TransportConfig::default().with_allow_spin(rama_allow));
                    let mut quinn_transport = quinn::TransportConfig::default();
                    quinn_transport.allow_spin(quinn_allow);
                    let quinn_transport = Arc::new(quinn_transport);
                    let (rama_endpoint, quinn_endpoint, rama_conn, quinn_conn, trace, proxy_task) =
                        if rama_is_client {
                            let mut server_config = quinn_server_config(&identity);
                            server_config.transport_config(quinn_transport);
                            let server =
                                quinn::Endpoint::server(server_config, localhost()).unwrap();
                            let (address, trace, proxy_task) =
                                proxy(server.local_addr().unwrap()).await;
                            let client = Endpoint::bind_client(Executor::new(), localhost())
                                .await
                                .unwrap();
                            let config = rama_client_config(anchor.clone())
                                .with_transport_config(rama_transport);
                            let (rama, peer) = tokio::join!(
                                client.connect_with(config, address, "localhost").unwrap(),
                                async { server.accept().await.unwrap().await }
                            );
                            (
                                client,
                                server,
                                rama.unwrap(),
                                peer.unwrap(),
                                trace,
                                proxy_task,
                            )
                        } else {
                            let config =
                                rama_server_config(&identity).with_transport_config(rama_transport);
                            let server =
                                Endpoint::bind_server(Executor::new(), config, localhost())
                                    .await
                                    .unwrap();
                            let (address, trace, proxy_task) =
                                proxy(server.local_addr().unwrap()).await;
                            let mut client = quinn::Endpoint::client(localhost()).unwrap();
                            let mut config = quinn_client_config(anchor.clone());
                            config.transport_config(quinn_transport);
                            client.set_default_client_config(config);
                            let (rama, peer) = tokio::join!(
                                async { server.accept().await.unwrap().await },
                                client.connect(address, "localhost").unwrap()
                            );
                            (
                                server,
                                client,
                                rama.unwrap(),
                                peer.unwrap(),
                                trace,
                                proxy_task,
                            )
                        };
                    assert_eq!(rama_conn.version(), rama::quic::proto::Version::V1);
                    for number in 0..24u8 {
                        let payload = [number; 1024];
                        let (mut send, mut recv) = rama_conn.open_bi().await.unwrap();
                        send.write_all(&payload).await.unwrap();
                        send.finish().unwrap();
                        let (mut reply, mut request) = quinn_conn.accept_bi().await.unwrap();
                        assert_eq!(request.read_to_end(1024).await.unwrap(), payload);
                        reply.write_all(&payload).await.unwrap();
                        reply.finish().unwrap();
                        assert_eq!(recv.read_to_end(1024).await.unwrap(), payload);
                    }
                    {
                        let captured = trace.lock();
                        assert!(captured.iter().filter(|(server, _)| *server).count() >= 24);
                        assert!(captured.iter().filter(|(server, _)| !*server).count() >= 24);
                    }
                    // Neither a constant nor randomized peer bit is a failure. Exact reflection
                    // assertions belong to fixtures whose activation and packet order we control.
                    assert!(rama_conn.close_reason().is_none());
                    assert!(quinn_conn.close_reason().is_none());
                    rama_endpoint.close(0u32, b"spin test done");
                    quinn_endpoint.close(0u32.into(), b"spin test done");
                    proxy_task.abort();
                    assert!(proxy_task.await.unwrap_err().is_cancelled());
                }
            }
        }
    })
    .await;
}
