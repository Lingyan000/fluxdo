use std::{
    future::ready,
    io::{self, Write},
    net::SocketAddr,
    num::NonZeroUsize,
    sync::{
        Arc, RwLock,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

use rama_core::{Service, error::BoxError, io::BridgeIo, rt::Executor, service::service_fn};
use rama_crypto::dep::boring::{pkey::PKey, x509::X509};
use rama_net::{
    http::{TargetHttpVersion, Version},
    tls::ApplicationProtocol,
};
use rama_quic_proto::{
    TransportError, TransportErrorCode,
    frame::{ApplicationClose, ConnectionClose},
    peek::PeekedClientHello,
};
use rama_tls::{
    alpn::AlpnRouter,
    client::{ClientHelloExtension, TlsClientConfig},
    server::ServerAuthData,
};
use rama_tls_boring::proxy::cert_issuer::{BoringMitmCertIssuer, StaticBoringMitmCertIssuer};
use rama_udp::test_utils::MemoryDatagramSocket;
use rama_utils::collections::NonEmptyVec;
use tokio::time::timeout;

use super::*;
use crate::{
    ClientConfig, Endpoint, ServerConfig,
    proxy::{PeekQuicClientHelloService, QuicRelay},
    test_helpers::{identity, untrusted_identity},
    tls::{BoringTlsProvider, TlsOptions},
};

#[derive(Clone, Default)]
struct RefusalLog(Arc<RwLock<Vec<u8>>>);

impl Write for RefusalLog {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0.write().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl RefusalLog {
    fn text(&self) -> String {
        String::from_utf8(self.0.read().unwrap().clone()).unwrap()
    }

    fn assert_class(&self, class: &str) {
        let log = self.text();
        assert!(
            log.contains(&format!("QUIC MITM origin refused: {class}")),
            "{log}"
        );
    }
}

// These tests use Tokio's current-thread runtime, so spawned resolver work uses
// the same thread-local subscriber throughout the awaited test.
fn capture_refusals() -> (RefusalLog, tracing::subscriber::DefaultGuard) {
    let log = RefusalLog::default();
    let writer = log.clone();
    let subscriber = tracing_subscriber::fmt()
        .without_time()
        .with_ansi(false)
        .with_writer(move || writer.clone())
        .finish();
    (log, tracing::subscriber::set_default(subscriber))
}

const ALPN: &[u8] = b"rama-quic-test";
const LIMIT: Duration = Duration::from_secs(20);

fn issuer(identity: &ServerAuthData) -> StaticBoringMitmCertIssuer {
    StaticBoringMitmCertIssuer::new(
        NonEmptyVec::new(X509::from_der(&identity.cert_chain[0]).unwrap()),
        PKey::private_key_from_der(identity.private_key.secret_der()).unwrap(),
    )
}

fn trusting(identity: &ServerAuthData) -> TlsClientConfig {
    trusting_with_alpn(identity, ALPN)
}

fn trusting_with_alpn(identity: &ServerAuthData, alpn: &[u8]) -> TlsClientConfig {
    TlsClientConfig::new()
        .with_alpn([alpn.into()].into_iter().collect())
        .try_with_server_trust_anchors([identity.cert_chain.last().unwrap().clone()])
        .unwrap()
}

/// Client ⇄ ingress socket, egress socket ⇄ origin, as a producer would prepare them.
struct Sockets {
    client: Endpoint,
    ingress: MemoryDatagramSocket,
    ingress_address: SocketAddr,
    egress: MemoryDatagramSocket,
    origin: Endpoint,
}

fn sockets(origin_identity: &ServerAuthData, port: u16) -> Sockets {
    sockets_with_alpn(origin_identity, port, ALPN)
}

fn sockets_with_alpn(origin_identity: &ServerAuthData, port: u16, alpn: &[u8]) -> Sockets {
    let address = |offset| SocketAddr::from(([127, 0, 0, 1], port + offset));
    let capacity = NonZeroUsize::new(64).unwrap();
    let (client_socket, ingress) = MemoryDatagramSocket::pair(address(0), address(1), capacity);
    let (egress, origin_socket) = MemoryDatagramSocket::pair(address(2), address(3), capacity);
    let tls = rama_tls::server::TlsServerConfig::new()
        .with_alpn([alpn.into()].into_iter().collect())
        .with_server_auth(origin_identity.clone());
    let origin = Endpoint::build(Executor::new())
        .with_server_config(ServerConfig::try_from_rama_tls(&tls, TlsOptions::default()).unwrap())
        .with_datagram_socket(origin_socket)
        .unwrap();
    let client = Endpoint::build(Executor::new())
        .with_datagram_socket(client_socket)
        .unwrap();
    Sockets {
        client,
        ingress,
        ingress_address: address(1),
        egress,
        origin,
    }
}

fn relay<I>(issuer: I, origin_identity: &ServerAuthData) -> QuicMitmRelay<I> {
    QuicMitmRelay::new(
        issuer,
        Executor::new(),
        trusting(origin_identity),
        VarInt::from_u32(0x0101),
    )
}

#[tokio::test]
async fn a_terminated_association_relays_streams_to_the_verified_origin() {
    timeout(LIMIT, async {
        let mitm_identity = identity();
        let origin_identity = untrusted_identity();
        let Sockets {
            client,
            ingress,
            ingress_address,
            egress,
            origin,
        } = sockets(&origin_identity, 24500);
        let service = PeekQuicClientHelloService::new(
            BoringTlsProvider,
            relay(issuer(&mitm_identity), &origin_identity)
                .into_layer(QuicRelay::new(VarInt::from_u32(0x0101))),
        );
        let relaying = tokio::spawn(async move { service.serve(BridgeIo(ingress, egress)).await });

        let origin_task = tokio::spawn(async move {
            let connection = origin.accept().await.unwrap().await.unwrap();
            let (mut send, mut recv) = connection.accept_bi().await.unwrap();
            let request = recv.read_to_end(64).await.unwrap();
            send.write_all(&[b"pong:", request.as_slice()].concat())
                .await
                .unwrap();
            send.finish().unwrap();
            connection.closed().await;
            origin
        });

        let config = ClientConfig::try_from_rama_tls(
            &trusting(&mitm_identity).with_store_server_cert_chain(true),
            TlsOptions::default(),
        )
        .unwrap();
        let connection = client
            .connect_with(config, ingress_address, "localhost")
            .unwrap()
            .await
            .unwrap();
        // The client authenticated the relay's certificate, not the origin's.
        let tls = connection
            .extensions()
            .get_ref::<NegotiatedTlsParameters>()
            .unwrap();
        assert_eq!(
            tls.peer_certificate_chain.as_deref().unwrap()[0],
            mitm_identity.cert_chain[0]
        );
        let (mut send, mut recv) = connection.open_bi().await.unwrap();
        send.write_all(b"ping").await.unwrap();
        send.finish().unwrap();
        assert_eq!(recv.read_to_end(64).await.unwrap(), b"pong:ping");
        connection.close(VarInt::from_u32(0), b"done");
        relaying.await.unwrap().unwrap();
        drop(origin_task.await.unwrap());
    })
    .await
    .unwrap();
}

/// One association is one relayed connection: its ingress endpoint mirrors a single origin.
/// Another connection the client opens on the same socket to the same destination must be
/// refused at once, not left to its own handshake timeout, and the first one keeps working.
#[tokio::test]
async fn a_second_connection_on_an_association_is_refused_at_once() {
    timeout(LIMIT, async {
        let mitm_identity = identity();
        let origin_identity = untrusted_identity();
        let Sockets {
            client,
            ingress,
            ingress_address,
            egress,
            origin,
        } = sockets(&origin_identity, 24520);
        let service = PeekQuicClientHelloService::new(
            BoringTlsProvider,
            relay(issuer(&mitm_identity), &origin_identity)
                .into_layer(QuicRelay::new(VarInt::from_u32(0x0101))),
        );
        let relaying = tokio::spawn(async move { service.serve(BridgeIo(ingress, egress)).await });

        let origin_task = tokio::spawn(async move {
            let connection = origin.accept().await.unwrap().await.unwrap();
            while let Ok((mut send, mut recv)) = connection.accept_bi().await {
                let request = recv.read_to_end(64).await.unwrap();
                send.write_all(&[b"pong:", request.as_slice()].concat())
                    .await
                    .unwrap();
                send.finish().unwrap();
            }
            origin
        });

        let config =
            ClientConfig::try_from_rama_tls(&trusting(&mitm_identity), TlsOptions::default())
                .unwrap();
        let ping = async |connection: &Connection, payload: &[u8]| {
            let (mut send, mut recv) = connection.open_bi().await.unwrap();
            send.write_all(payload).await.unwrap();
            send.finish().unwrap();
            recv.read_to_end(64).await.unwrap()
        };
        let first = client
            .connect_with(config.clone(), ingress_address, "localhost")
            .unwrap()
            .await
            .unwrap();
        assert_eq!(ping(&first, b"one").await, b"pong:one");

        let second = client
            .connect_with(config, ingress_address, "localhost")
            .unwrap();
        tokio::time::timeout(Duration::from_secs(2), second)
            .await
            .expect("the second connection must be answered, not left to time out")
            .unwrap_err();

        assert_eq!(ping(&first, b"two").await, b"pong:two");
        first.close(VarInt::from_u32(0), b"done");
        relaying.await.unwrap().unwrap();
        drop(origin_task.await.unwrap());
    })
    .await
    .unwrap();
}

/// Counts issuance, which must not happen for an origin that failed verification.
#[derive(Clone)]
struct CountingIssuer {
    inner: StaticBoringMitmCertIssuer,
    issued: Arc<AtomicUsize>,
}

impl BoringMitmCertIssuer for CountingIssuer {
    type Error = BoxError;

    async fn issue_mitm_x509_cert(
        &self,
        original: X509,
    ) -> Result<rama_tls_boring::proxy::cert_issuer::MitmIssuedCert, BoxError> {
        self.issued.fetch_add(1, Ordering::Relaxed);
        self.inner
            .issue_mitm_x509_cert(original)
            .await
            .map_err(Into::into)
    }
}

#[tokio::test]
async fn an_unverified_origin_is_never_mirrored_to_the_client() {
    unverified_origin_is_refused(None).await;
}

#[tokio::test]
async fn an_unverified_origin_with_client_auth_logs_its_handshake_kind() {
    let policy = TlsMitmClientAuthPolicy::new(service_fn(|_: TlsMitmClientAuthInput| {
        ready(Ok::<_, BoxError>(TlsMitmClientAuthPlan::fixed(None)))
    }));
    unverified_origin_is_refused(Some(policy)).await;
}

async fn unverified_origin_is_refused(client_auth: Option<TlsMitmClientAuthPolicy>) {
    let (log, _subscriber) = capture_refusals();
    timeout(LIMIT, async {
        let mitm_identity = identity();
        let origin_identity = untrusted_identity();
        let Sockets {
            client,
            ingress,
            ingress_address,
            egress,
            origin,
        } = sockets(&origin_identity, 24510);
        let issued = Arc::new(AtomicUsize::new(0));
        let issuer = CountingIssuer {
            inner: issuer(&mitm_identity),
            issued: issued.clone(),
        };
        // Egress trusts some other identity, so the origin fails verification.
        let service = PeekQuicClientHelloService::new(
            BoringTlsProvider,
            relay(issuer, &mitm_identity)
                .maybe_with_client_auth(client_auth)
                .into_layer(service_fn(async |_: BridgeIo<Connection, Connection>| {
                    Ok::<_, BoxError>(())
                })),
        );
        let relaying = tokio::spawn(async move { service.serve(BridgeIo(ingress, egress)).await });
        let origin_task = tokio::spawn(async move {
            // The origin's handshake fails on the relay's side; nothing reaches it after.
            let _refused = origin.accept().await.unwrap().await;
            origin
        });
        let config =
            ClientConfig::try_from_rama_tls(&trusting(&mitm_identity), TlsOptions::default())
                .unwrap()
                .with_transport_config(Arc::new(
                    crate::TransportConfig::default()
                        .with_max_idle_timeout(Duration::from_secs(1).try_into().unwrap()),
                ));
        let connecting = client
            .connect_with(config, ingress_address, "localhost")
            .unwrap();
        relaying.await.unwrap().unwrap_err();
        connecting.await.unwrap_err();
        assert_eq!(issued.load(Ordering::Relaxed), 0);
        drop(origin_task.await.unwrap());
        log.assert_class("origin-handshake:transport-crypto-0x130");
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn the_alpn_router_dispatches_on_the_negotiated_protocol() {
    timeout(LIMIT, async {
        let mitm_identity = identity();
        let origin_identity = untrusted_identity();
        let Sockets {
            client,
            ingress,
            ingress_address,
            egress,
            origin,
        } = sockets(&origin_identity, 24520);
        let routed = Arc::new(AtomicUsize::new(0));
        let counted = routed.clone();
        let service = PeekQuicClientHelloService::new(
            BoringTlsProvider,
            relay(issuer(&mitm_identity), &origin_identity).into_layer(AlpnRouter::new(
                ApplicationProtocol::from(ALPN),
                service_fn(
                    move |BridgeIo(ingress, egress): BridgeIo<Connection, Connection>| {
                        let counted = counted.clone();
                        async move {
                            counted.fetch_add(1, Ordering::Relaxed);
                            ingress.close(VarInt::from_u32(0), b"routed");
                            egress.close(VarInt::from_u32(0), b"routed");
                            Ok::<_, BoxError>(())
                        }
                    },
                ),
            )),
        );
        let relaying = tokio::spawn(async move { service.serve(BridgeIo(ingress, egress)).await });
        let origin_task = tokio::spawn(async move {
            let _connection = origin.accept().await.unwrap().await;
            origin
        });
        let config =
            ClientConfig::try_from_rama_tls(&trusting(&mitm_identity), TlsOptions::default())
                .unwrap();
        let connection = client
            .connect_with(config, ingress_address, "localhost")
            .unwrap()
            .await
            .unwrap();
        relaying.await.unwrap().unwrap();
        connection.closed().await;
        assert_eq!(routed.load(Ordering::Relaxed), 1);
        drop(origin_task.await.unwrap());
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn the_handshake_budget_is_fixed_when_the_association_is_handed_over() {
    timeout(LIMIT, async {
        let mitm_identity = identity();
        let origin_identity = untrusted_identity();
        let Sockets {
            client,
            ingress,
            ingress_address,
            egress,
            origin,
        } = sockets(&origin_identity, 24530);
        let origin_task = tokio::spawn(async move {
            if let Some(incoming) = origin.accept().await {
                let _connection = incoming.await;
            }
            origin
        });
        let config =
            ClientConfig::try_from_rama_tls(&trusting(&mitm_identity), TlsOptions::default())
                .unwrap();
        let connecting = client
            .connect_with(config, ingress_address, "localhost")
            .unwrap();
        // Peek first, keeping its output, so the relay itself is what is handed over late.
        let peeked = PeekQuicClientHelloService::new(
            BoringTlsProvider,
            service_fn(async |input: InputWithQuicClientHello<_>| Ok::<_, BoxError>(input)),
        )
        .with_fallback(service_fn(async |_: BridgeIo<_, _>| {
            Err::<InputWithQuicClientHello<_>, _>(BoxError::from_static_str("no ClientHello"))
        }))
        .serve(BridgeIo(ingress, egress))
        .await
        .unwrap();
        // Plenty for an in-memory handshake, but spent before the relay is first polled.
        let mitm = relay(issuer(&mitm_identity), &origin_identity)
            .with_handshake_timeout(Duration::from_millis(200))
            .into_layer(QuicRelay::new(VarInt::from_u32(0x0101)));
        let serving = mitm.serve(peeked);
        tokio::time::sleep(Duration::from_millis(400)).await;
        let error = serving.await.unwrap_err();
        assert!(error.to_string().contains("deadline"), "{error}");
        drop(connecting);
        origin_task.abort();
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn an_http3_origin_marks_the_egress_http_version() {
    timeout(LIMIT, async {
        let mitm_identity = identity();
        let origin_identity = untrusted_identity();
        let Sockets {
            client,
            ingress,
            ingress_address,
            egress,
            origin,
        } = sockets_with_alpn(&origin_identity, 24540, b"h3");
        let marked = Arc::new(AtomicUsize::new(0));
        let counted = marked.clone();
        let service = PeekQuicClientHelloService::new(
            BoringTlsProvider,
            QuicMitmRelay::new(
                issuer(&mitm_identity),
                Executor::new(),
                trusting_with_alpn(&origin_identity, b"h3"),
                VarInt::from_u32(0x0101),
            )
            .into_layer(service_fn(
                move |BridgeIo(ingress, egress): BridgeIo<Connection, Connection>| {
                    let counted = counted.clone();
                    async move {
                        if egress.extensions().get_ref::<TargetHttpVersion>()
                            == Some(&TargetHttpVersion(Version::HTTP_3))
                        {
                            counted.fetch_add(1, Ordering::Relaxed);
                        }
                        ingress.close(VarInt::from_u32(0), b"checked");
                        egress.close(VarInt::from_u32(0), b"checked");
                        Ok::<_, BoxError>(())
                    }
                },
            )),
        );
        let relaying = tokio::spawn(async move { service.serve(BridgeIo(ingress, egress)).await });
        let origin_task = tokio::spawn(async move {
            let _connection = origin.accept().await.unwrap().await;
            origin
        });
        let config = ClientConfig::try_from_rama_tls(
            &trusting_with_alpn(&mitm_identity, b"h3"),
            TlsOptions::default(),
        )
        .unwrap();
        let connection = client
            .connect_with(config, ingress_address, "localhost")
            .unwrap()
            .await
            .unwrap();
        relaying.await.unwrap().unwrap();
        connection.closed().await;
        assert_eq!(marked.load(Ordering::Relaxed), 1);
        drop(origin_task.await.unwrap());
    })
    .await
    .unwrap();
}

fn trusting_with_alpns(identity: &ServerAuthData, alpns: &[&[u8]]) -> TlsClientConfig {
    TlsClientConfig::new()
        .with_alpn(alpns.iter().map(|alpn| (*alpn).into()).collect())
        .try_with_server_trust_anchors([identity.cert_chain.last().unwrap().clone()])
        .unwrap()
}

/// An origin task counting the attempts that reach it, and recording what they offered.
fn watch_origin(origin: Endpoint) -> (Arc<AtomicUsize>, tokio::task::JoinHandle<Vec<Connection>>) {
    let reached = Arc::new(AtomicUsize::new(0));
    let counted = reached.clone();
    let task = tokio::spawn(async move {
        let mut connections = Vec::new();
        while let Some(incoming) = origin.accept().await {
            counted.fetch_add(1, Ordering::Relaxed);
            if let Ok(connection) = incoming.await {
                connections.push(connection);
            }
        }
        connections
    });
    (reached, task)
}

/// The Initial datagrams of a captured Chrome flight.
fn chrome_flight() -> [Vec<u8>; 2] {
    [
        include_str!("../../../profile/fixtures/chrome-153-initial-1.hex"),
        include_str!("../../../profile/fixtures/chrome-153-initial-2.hex"),
    ]
    .map(|hex| {
        rama_utils::hex::decode::<Vec<u8>>(hex.split_whitespace().collect::<String>()).unwrap()
    })
}

#[tokio::test]
async fn no_origin_work_runs_for_a_client_that_never_proves_its_address() {
    timeout(LIMIT, async {
        for validate in [true, false] {
            let mitm_identity = identity();
            let origin_identity = untrusted_identity();
            let Sockets {
                client,
                ingress,
                ingress_address,
                egress,
                origin,
            } = sockets(&origin_identity, if validate { 24550 } else { 24560 });
            // A first flight nobody answers for, as from a spoofed source.
            for datagram in chrome_flight() {
                let mut metadata = rama_udp::DatagramMetadata::empty();
                metadata.peer = SocketAddr::from(([192, 0, 2, 1], 443)).into();
                metadata.local = ingress_address.into();
                ingress.inject_received(datagram, metadata).unwrap();
            }
            // Kept open, so the ingress lives on, but it never answers the relay.
            let _client = client;
            let issued = Arc::new(AtomicUsize::new(0));
            let issuer = CountingIssuer {
                inner: issuer(&mitm_identity),
                issued: issued.clone(),
            };
            let (reached, origin_task) = watch_origin(origin);
            // Any protocol the client offers may go upstream.
            let egress_tls = TlsClientConfig::new()
                .try_with_server_trust_anchors([origin_identity.cert_chain.last().unwrap().clone()])
                .unwrap();
            let mut mitm = QuicMitmRelay::new(
                issuer,
                Executor::new(),
                egress_tls,
                VarInt::from_u32(0x0101),
            )
            .with_handshake_timeout(Duration::from_millis(500));
            // Validation is the default; only its absence is configured.
            if !validate {
                mitm.set_validate_address(false);
            }
            let service = PeekQuicClientHelloService::new(
                BoringTlsProvider,
                mitm.into_layer(QuicRelay::new(VarInt::from_u32(0x0101))),
            );
            let error = service.serve(BridgeIo(ingress, egress)).await.unwrap_err();
            // Validating, it waits for a token that never comes; otherwise the origin work runs.
            if validate {
                assert!(error.to_string().contains("deadline"), "{error}");
            }
            assert_eq!(
                reached.load(Ordering::Relaxed),
                usize::from(!validate),
                "validate {validate}"
            );
            // The captured flight names a server the test origin cannot prove it is.
            assert_eq!(issued.load(Ordering::Relaxed), 0);
            origin_task.abort();
        }
    })
    .await
    .unwrap();
}

/// What the peek sees of a client offering the same protocols for `server_name`.
async fn peeked_client_hello_for(
    server_name: &str,
    identity: &ServerAuthData,
) -> PeekedClientHello {
    let Sockets {
        client,
        ingress,
        ingress_address,
        egress,
        ..
    } = sockets(identity, 24600);
    let config =
        ClientConfig::try_from_rama_tls(&trusting(identity), TlsOptions::default()).unwrap();
    let _connecting = client
        .connect_with(config, ingress_address, server_name)
        .unwrap();
    PeekQuicClientHelloService::new(
        BoringTlsProvider,
        service_fn(async |input: InputWithQuicClientHello<BridgeIo<_, _>>| {
            Ok::<_, BoxError>(input.peeked)
        }),
    )
    .with_fallback(service_fn(async |_: BridgeIo<_, _>| {
        Err::<PeekedClientHello, _>(BoxError::from_static_str("no ClientHello"))
    }))
    .serve(BridgeIo(ingress, egress))
    .await
    .unwrap()
}

#[tokio::test]
async fn an_attempt_other_than_the_peeked_one_is_refused_without_origin_work() {
    // The routing decision saw another server name, or another protocol list.
    for other_name in [true, false] {
        let (log, _subscriber) = capture_refusals();
        timeout(LIMIT, async {
            let mitm_identity = identity();
            let origin_identity = untrusted_identity();
            let Sockets {
                client,
                ingress,
                ingress_address,
                egress,
                origin,
            } = sockets(&origin_identity, 24570);
            let issued = Arc::new(AtomicUsize::new(0));
            let issuer = CountingIssuer {
                inner: issuer(&mitm_identity),
                issued: issued.clone(),
            };
            let (reached, origin_task) = watch_origin(origin);
            let config =
                ClientConfig::try_from_rama_tls(&trusting(&mitm_identity), TlsOptions::default())
                    .unwrap();
            let connecting = client
                .connect_with(config, ingress_address, "localhost")
                .unwrap();
            let mut peeked = PeekQuicClientHelloService::new(
                BoringTlsProvider,
                service_fn(async |input: InputWithQuicClientHello<_>| Ok::<_, BoxError>(input)),
            )
            .with_fallback(service_fn(async |_: BridgeIo<_, _>| {
                Err::<InputWithQuicClientHello<_>, _>(BoxError::from_static_str("no ClientHello"))
            }))
            .serve(BridgeIo(ingress, egress))
            .await
            .unwrap();
            peeked.peeked = if other_name {
                peeked_client_hello_for("other.localhost", &mitm_identity).await
            } else {
                // Still within what the egress allows, so only the comparison refuses it.
                PeekedClientHello {
                    client_hello: with_extra_alpn(&peeked.peeked.client_hello, b"other"),
                    ..peeked.peeked
                }
            };
            let mitm = relay(issuer, &origin_identity)
                .with_validate_address(false)
                .into_layer(QuicRelay::new(VarInt::from_u32(0x0101)));
            let error = mitm.serve(peeked).await.unwrap_err();
            assert!(error.to_string().contains("refused"), "{error}");
            // The client is refused at once rather than left to its own handshake timeout.
            tokio::time::timeout(Duration::from_secs(2), connecting)
                .await
                .unwrap()
                .unwrap_err();
            assert_eq!(reached.load(Ordering::Relaxed), 0);
            assert_eq!(issued.load(Ordering::Relaxed), 0);
            origin_task.abort();
            log.assert_class("attempt-mismatch");
        })
        .await
        .unwrap();
    }
}

/// `hello` also offering `protocol`, after its own.
fn with_extra_alpn(hello: &ClientHello, protocol: &[u8]) -> ClientHello {
    let extensions = hello
        .extensions()
        .iter()
        .map(|ext| match ext {
            ClientHelloExtension::ApplicationLayerProtocolNegotiation(offered) => {
                let mut offered = offered.clone();
                offered.push(ApplicationProtocol::from(protocol));
                ClientHelloExtension::ApplicationLayerProtocolNegotiation(offered)
            }
            other => other.clone(),
        })
        .collect();
    ClientHello::new(
        hello.protocol_version(),
        hello.cipher_suites().to_vec(),
        hello.compression_algorithms().to_vec(),
        extensions,
    )
}

#[tokio::test]
async fn the_origin_sees_the_clients_protocols_in_order_and_its_version() {
    timeout(LIMIT, async {
        for version in [rama_quic_proto::Version::V1, rama_quic_proto::Version::V2] {
            let mitm_identity = identity();
            let origin_identity = untrusted_identity();
            let address = |offset: u16| SocketAddr::from(([127, 0, 0, 1], 24580 + offset));
            let capacity = NonZeroUsize::new(64).unwrap();
            let (client_socket, ingress) =
                MemoryDatagramSocket::pair(address(0), address(1), capacity);
            let (egress, origin_socket) =
                MemoryDatagramSocket::pair(address(2), address(3), capacity);
            let origin_tls = rama_tls::server::TlsServerConfig::new()
                .with_alpn(
                    [b"b".as_slice().into(), b"a".as_slice().into()]
                        .into_iter()
                        .collect(),
                )
                .with_server_auth(origin_identity.clone());
            let origin = Endpoint::build(Executor::new())
                .with_server_config(
                    ServerConfig::try_from_rama_tls(&origin_tls, TlsOptions::default()).unwrap(),
                )
                .with_datagram_socket(origin_socket)
                .unwrap();
            let client = Endpoint::build(Executor::new())
                .with_datagram_socket(client_socket)
                .unwrap();
            let origin_task = tokio::spawn(async move {
                let mut incoming = origin.accept().await.unwrap();
                let offered: Vec<ApplicationProtocol> = incoming
                    .client_hello()
                    .await
                    .unwrap()
                    .ext_alpn()
                    .unwrap()
                    .to_vec();
                let connection = incoming.await.unwrap();
                (offered, connection.version(), origin)
            });
            // The egress configuration allows another order, more, and not all the client offers.
            let egress_tls = trusting_with_alpns(&origin_identity, &[b"c", b"b", b"a"]);
            let service = PeekQuicClientHelloService::new(
                BoringTlsProvider,
                QuicMitmRelay::new(
                    issuer(&mitm_identity),
                    Executor::new(),
                    egress_tls,
                    VarInt::from_u32(0x0101),
                )
                .into_layer(service_fn(
                    async |BridgeIo(ingress, egress): BridgeIo<Connection, Connection>| {
                        let versions = (ingress.version(), egress.version());
                        ingress.close(VarInt::from_u32(0), b"checked");
                        egress.close(VarInt::from_u32(0), b"checked");
                        Ok::<_, BoxError>(versions)
                    },
                )),
            )
            .with_fallback(service_fn(async |_: BridgeIo<_, _>| {
                Err::<(rama_quic_proto::Version, rama_quic_proto::Version), _>(
                    BoxError::from_static_str("no ClientHello"),
                )
            }));
            let relaying =
                tokio::spawn(async move { service.serve(BridgeIo(ingress, egress)).await });
            let mut config = ClientConfig::try_from_rama_tls(
                &trusting_with_alpns(&mitm_identity, &[b"a", b"d", b"b"]),
                TlsOptions::default(),
            )
            .unwrap();
            config.set_version(version).unwrap();
            let connection = client
                .connect_with(config, address(1), "localhost")
                .unwrap()
                .await
                .unwrap();
            assert_eq!(relaying.await.unwrap().unwrap(), (version, version));
            connection.closed().await;
            let (offered, origin_version, _origin) = origin_task.await.unwrap();
            assert_eq!(
                offered,
                [
                    ApplicationProtocol::from(b"a"),
                    ApplicationProtocol::from(b"b")
                ]
            );
            assert_eq!(origin_version, version);
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn a_client_that_fails_its_handshake_closes_the_origin_with_the_failure_code() {
    timeout(LIMIT, async {
        let mitm_identity = identity();
        let origin_identity = untrusted_identity();
        let Sockets {
            client,
            ingress,
            ingress_address,
            egress,
            origin,
        } = sockets(&origin_identity, 24590);
        let service = PeekQuicClientHelloService::new(
            BoringTlsProvider,
            relay(issuer(&mitm_identity), &origin_identity)
                .into_layer(QuicRelay::new(VarInt::from_u32(0x0101))),
        );
        let relaying = tokio::spawn(async move { service.serve(BridgeIo(ingress, egress)).await });
        let origin_task = tokio::spawn(async move {
            let connection = origin.accept().await.unwrap().await.unwrap();
            (connection.closed().await, origin)
        });
        // The client trusts only the origin's identity, so it rejects the mirrored certificate.
        let config =
            ClientConfig::try_from_rama_tls(&trusting(&origin_identity), TlsOptions::default())
                .unwrap();
        client
            .connect_with(config, ingress_address, "localhost")
            .unwrap()
            .await
            .unwrap_err();
        relaying.await.unwrap().unwrap_err();
        let (closed, _origin) = origin_task.await.unwrap();
        assert!(
            matches!(&closed, crate::ConnectionError::ApplicationClosed(close)
                if close.error_code == VarInt::from_u32(0x0101)),
            "{closed:?}"
        );
    })
    .await
    .unwrap();
}

mod answer;
mod client_auth;
mod mirror;
mod spin;

#[test]
fn origin_refusal_classes_are_public_without_private_error_details() {
    let (output, _subscriber) = capture_refusals();
    for class in [
        "attempt-mismatch",
        "egress-unavailable",
        "client-auth-configuration",
        "egress-tls-configuration",
        "transport-configuration",
        "origin-address",
        "origin-endpoint",
        "origin-connect",
        "origin-handshake",
        "origin-certificate",
        "origin-missing-alpn",
        "client-auth-policy",
        "certificate-issuance",
        "issued-identity",
        "ingress-tls-configuration",
    ] {
        let error = origin_refusal(
            class,
            BoxError::from_static_str("private-origin.example: secret certificate"),
        );
        assert!(error.to_string().contains("private-origin.example"));
        let log = output.text();
        assert!(
            log.contains(&format!("QUIC MITM origin refused: {class}")),
            "{log}"
        );
        assert!(!log.contains("private-origin.example"));
        assert!(!log.contains("secret certificate"));
    }
}

#[tokio::test]
async fn origin_connect_failure_logs_its_public_class() {
    let (log, _subscriber) = capture_refusals();
    timeout(LIMIT, async {
        let identity = identity();
        let peeked = peeked_client_hello_for("localhost", &identity).await;
        let (egress, _peer) = MemoryDatagramSocket::pair(
            SocketAddr::from(([127, 0, 0, 1], 24610)),
            SocketAddr::from(([127, 0, 0, 1], 0)),
            NonZeroUsize::new(64).unwrap(),
        );
        let resolver = OriginResolver {
            relay: relay(issuer(&identity), &identity),
            peeked,
            server_name: "localhost".parse().unwrap(),
            client_auth: None,
            egress: Mutex::new(Some(egress)),
            origin: Arc::new(Mutex::new(None)),
        };
        assert!(resolver.reach_origin().await.is_err());
        log.assert_class("origin-connect");
    })
    .await
    .unwrap();
}

#[test]
fn origin_handshake_kinds_exclude_private_reasons() {
    let (log, _subscriber) = capture_refusals();
    for (error, class) in [
        (
            ConnectionError::ConnectionClosed(ConnectionClose {
                error_code: TransportErrorCode::crypto(40),
                frame_type: None,
                reason: b"secret origin.example peer reason".as_slice().into(),
            }),
            "peer-transport-crypto-0x128",
        ),
        (
            ConnectionError::ApplicationClosed(ApplicationClose {
                error_code: VarInt::from_u32(12345),
                reason: b"secret origin.example application reason"
                    .as_slice()
                    .into(),
            }),
            "application-closed",
        ),
        (ConnectionError::TimedOut, "timed-out"),
        (ConnectionError::LocallyClosed, "locally-closed"),
        (ConnectionError::Reset, "reset"),
        (ConnectionError::CidsExhausted, "cids-exhausted"),
        (ConnectionError::EndpointInUse, "endpoint-in-use"),
        (
            ConnectionError::VersionMismatch { offered: vec![] },
            "version-mismatch",
        ),
        (
            ConnectionError::TransportError(TransportError::new(
                TransportErrorCode::crypto(48),
                "secret origin.example certificate",
            )),
            "transport-crypto-0x130",
        ),
        (
            ConnectionError::TransportError(TransportError::INTERNAL_ERROR(
                "secret origin.example runtime",
            )),
            "transport-0x1",
        ),
    ] {
        let expected = error.to_string();
        let returned = origin_handshake_refusal(error);
        assert_eq!(returned.to_string(), expected);
        log.assert_class(&format!("origin-handshake:{class}"));
        assert!(!log.text().contains("secret"));
        assert!(!log.text().contains("origin.example"));
    }
}
