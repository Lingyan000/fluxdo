#![cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "an integration test's fixtures fail the test by panicking"
)]
//! Server TLS configurations resolved per ClientHello, such as certificates issued on demand.

use std::{
    convert::Infallible,
    net::{Ipv4Addr, SocketAddr},
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

use ahash::HashSet;
use parking_lot::Mutex;
use rama_core::{
    error::{BoxError, BoxErrorExt as _},
    rt::Executor,
    service::service_fn,
};
use rama_crypto::cert::CertificateAuthorityData;
use rama_net::{address::Domain, tls::ApplicationProtocol};
use rama_quic::{
    ClientConfig, Connection, ConnectionError, Endpoint, ServerConfig, TransportConfig,
    tls::{QuicClientConfigProvider, QuicServerConfigProvider, TlsOptions},
};
use rama_quic_proto::{TransportErrorCode, VarInt};
use rama_tls::{
    client::TlsClientConfig,
    server::{
        CertificateIdentity, LeafCertRequest, SelfSignedCaConfig, ServerAuthData, TlsServerConfig,
    },
};
use rama_utils::collections::smallvec::SmallVec;
use tokio::{net::UdpSocket, time::timeout};

const DEADLINE: Duration = Duration::from_secs(10);
const ALPN: &[u8] = b"rama-quic-dynamic";

fn localhost() -> SocketAddr {
    SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0)
}

fn alpn() -> SmallVec<[ApplicationProtocol; 2]> {
    [ApplicationProtocol::from(ALPN)].into_iter().collect()
}

/// Enough offered protocols to push the ClientHello past one Initial packet.
fn padded_alpn() -> SmallVec<[ApplicationProtocol; 2]> {
    alpn_padded_with(24)
}

/// A ClientHello of several KiB: more than one read of a TLS record layer takes.
fn large_alpn() -> SmallVec<[ApplicationProtocol; 2]> {
    alpn_padded_with(64)
}

fn alpn_padded_with(protocols: u8) -> SmallVec<[ApplicationProtocol; 2]> {
    (0..protocols)
        .map(|n| ApplicationProtocol::from(vec![b'a' + n % 26; 96]))
        .chain([ApplicationProtocol::from(ALPN)])
        .collect()
}

fn issue(ca: &CertificateAuthorityData, name: &str) -> ServerAuthData {
    ServerAuthData::new_issued_by(
        ca,
        LeafCertRequest {
            identities: vec![CertificateIdentity::Dns(Domain::try_from(name).unwrap())],
            ..Default::default()
        },
    )
    .unwrap()
}

fn client_config(
    ca: &CertificateAuthorityData,
    alpn: SmallVec<[ApplicationProtocol; 2]>,
    provider: &dyn QuicClientConfigProvider,
) -> ClientConfig {
    let tls = TlsClientConfig::new()
        .with_alpn(alpn)
        .try_with_server_trust_anchors([ca.certificate_chain()[0].clone()])
        .unwrap();
    ClientConfig::try_from_rama_tls_with_provider(&tls, TlsOptions::default(), provider).unwrap()
}

async fn server(tls: &TlsServerConfig, provider: &dyn QuicServerConfigProvider) -> Endpoint {
    let config =
        ServerConfig::try_from_rama_tls_with_provider(tls, TlsOptions::default(), provider)
            .unwrap();
    Endpoint::build(Executor::new())
        .with_server_config(config)
        .bind_address(localhost())
        .await
        .expect("the server binds")
}

async fn client() -> Endpoint {
    Endpoint::build(Executor::new())
        .bind_address(localhost())
        .await
        .expect("the client binds")
}

/// Serve every attempt by awaiting it, which resolves its configuration first.
fn serve(server: &Endpoint) -> tokio::task::JoinHandle<()> {
    tokio::spawn(server.clone().serve(
        Executor::new(),
        service_fn(async |connection: Connection| {
            _ = connection.closed().await;
            Ok::<_, Infallible>(())
        }),
    ))
}

async fn connect(
    client: &Endpoint,
    config: ClientConfig,
    addr: SocketAddr,
    name: &str,
) -> Result<Connection, ConnectionError> {
    timeout(DEADLINE, client.connect_with(config, addr, name).unwrap())
        .await
        .expect("the attempt settles")
}

fn refused(error: &ConnectionError) -> bool {
    matches!(
        error,
        ConnectionError::ConnectionClosed(close)
            if close.error_code == TransportErrorCode::CONNECTION_REFUSED
    )
}

/// Relay UDP between a client and `server`, holding the client's second datagram back for
/// `delay`, so a ClientHello spanning two Initial packets arrives in two steps.
async fn delaying_relay(server: SocketAddr, delay: Duration) -> SocketAddr {
    relay(server, Relaying::DelaySecond(delay)).await.addr
}

/// Relay UDP between a client and `server` passing only the client's first datagram, so a
/// ClientHello spanning several Initial packets never completes.
#[cfg(feature = "boring")]
async fn truncating_relay(server: SocketAddr) -> SocketAddr {
    relay(server, Relaying::FirstOnly).await.addr
}

/// What a relay does with a client's datagrams after its first, or with the server's Retry.
#[derive(Clone, Copy)]
enum Relaying {
    All,
    DelaySecond(Duration),
    HoldFirstRetry(Duration),
    #[cfg(feature = "boring")]
    FirstOnly,
    #[cfg(feature = "boring")]
    NoRetries,
}

/// A UDP relay between clients and a server, recording the Retry packets the server sends.
struct Relay {
    addr: SocketAddr,
    /// The connection IDs of the client attempts sent a Retry: a client that retransmits its
    /// Initial before the Retry arrives is sent another for the same attempt.
    retried: Arc<Mutex<HashSet<Box<[u8]>>>>,
    retry_packets: Arc<AtomicUsize>,
}

impl Relay {
    /// The client attempts the server sent a Retry.
    fn retries(&self) -> usize {
        self.retried.lock().len()
    }

    fn retry_packets(&self) -> usize {
        self.retry_packets.load(Ordering::Relaxed)
    }
}

/// Whether `packet` is a QUIC v1 or v2 Retry (RFC 9000 §17.2.5, RFC 9369 §3.2).
fn is_retry(packet: &[u8]) -> bool {
    let (Some(&first), Some(version)) = (packet.first(), packet.get(1..5)) else {
        return false;
    };
    let kind = (first & 0x30) >> 4;
    first & 0x80 != 0
        && match u32::from_be_bytes(version.try_into().unwrap()) {
            0x0000_0001 => kind == 0b11,
            0x6b33_43cf => kind == 0b00,
            _ => false,
        }
}

/// The Destination Connection ID of a long header packet (RFC 9000 §17.2).
fn destination_cid(packet: &[u8]) -> &[u8] {
    let len = usize::from(packet[5]);
    &packet[6..6 + len]
}

async fn relay(server: SocketAddr, relaying: Relaying) -> Relay {
    let front = Arc::new(UdpSocket::bind(localhost()).await.unwrap());
    let back = Arc::new(UdpSocket::bind(localhost()).await.unwrap());
    back.connect(server).await.unwrap();
    let addr = front.local_addr().unwrap();
    let retried = Arc::new(Mutex::new(HashSet::default()));
    let retry_packets = Arc::new(AtomicUsize::new(0));
    let (peer_tx, mut peer_rx) = tokio::sync::watch::channel(None::<SocketAddr>);
    tokio::spawn({
        let (front, back) = (front.clone(), back.clone());
        async move {
            let mut buf = vec![0; 65_536];
            let mut seen = 0usize;
            loop {
                let (len, from) = front.recv_from(&mut buf).await.unwrap();
                peer_tx.send_replace(Some(from));
                seen += 1;
                let datagram = buf[..len].to_vec();
                let back = back.clone();
                match relaying {
                    Relaying::DelaySecond(delay) if seen == 2 => {
                        tokio::spawn(async move {
                            tokio::time::sleep(delay).await;
                            _ = back.send(&datagram).await;
                        });
                    }
                    #[cfg(feature = "boring")]
                    Relaying::FirstOnly if seen > 1 => {}
                    _ => _ = back.send(&datagram).await,
                }
            }
        }
    });
    tokio::spawn({
        let (retried, retry_packets) = (retried.clone(), retry_packets.clone());
        async move {
            let mut buf = vec![0; 65_536];
            loop {
                let len = back.recv(&mut buf).await.unwrap();
                let Some(peer) = *peer_rx.borrow_and_update() else {
                    continue;
                };
                let datagram = &buf[..len];
                if is_retry(datagram) {
                    retried.lock().insert(destination_cid(datagram).into());
                    let first = retry_packets.fetch_add(1, Ordering::Relaxed) == 0;
                    match relaying {
                        #[cfg(feature = "boring")]
                        Relaying::NoRetries => continue,
                        Relaying::HoldFirstRetry(delay) if first => {
                            let (front, datagram) = (front.clone(), datagram.to_vec());
                            tokio::spawn(async move {
                                tokio::time::sleep(delay).await;
                                _ = front.send_to(&datagram, peer).await;
                            });
                            continue;
                        }
                        _ => {}
                    }
                }
                _ = front.send_to(datagram, peer).await;
            }
        }
    });
    Relay {
        addr,
        retried,
        retry_packets,
    }
}

/// Serve every connection by echoing its first bidirectional stream.
fn serve_echo(server: &Endpoint) -> tokio::task::JoinHandle<()> {
    tokio::spawn(server.clone().serve(
        Executor::new(),
        service_fn(async |connection: Connection| {
            if let Ok((mut send, mut recv)) = connection.accept_bi().await
                && let Ok(got) = recv.read_to_end(64).await
            {
                _ = send.write_all(&got).await;
                _ = send.finish();
            }
            _ = connection.closed().await;
            Ok::<_, Infallible>(())
        }),
    ))
}

/// Wait until `done` holds.
#[cfg(feature = "boring")]
async fn until(done: impl Fn() -> bool) {
    timeout(DEADLINE, async {
        while !done() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the condition holds in time");
}

/// Exchange a message through a relay holding the server's first Retry back until the client
/// retransmitted its Initial, which the server sends a Retry of its own.
async fn exchange_retransmitting_before_the_retry(
    server: &Endpoint,
    config: ClientConfig,
) -> Relay {
    let relay = relay(
        server.local_addr().unwrap(),
        Relaying::HoldFirstRetry(Duration::from_millis(500)),
    )
    .await;
    // A short initial RTT has the client probe long before the held Retry arrives.
    let transport = TransportConfig::default().with_initial_rtt(Duration::from_millis(10));
    let config = config.with_transport_config(Arc::new(transport));
    exchange(&client().await, config, relay.addr, "a.test")
        .await
        .close(VarInt::from(0u32), b"done");
    assert!(
        relay.retry_packets() > 1,
        "the Initial was retransmitted first"
    );
    relay
}

/// Connect and exchange a message, which also delivers what the server sends after the
/// handshake, such as session tickets and address validation tokens.
async fn exchange(
    client: &Endpoint,
    config: ClientConfig,
    addr: SocketAddr,
    name: &str,
) -> Connection {
    let connection = connect(client, config, addr, name)
        .await
        .expect("the client connects");
    let (mut send, mut recv) = connection.open_bi().await.unwrap();
    send.write_all(b"ping").await.unwrap();
    send.finish().unwrap();
    assert_eq!(recv.read_to_end(64).await.unwrap(), b"ping");
    connection
}

#[cfg(feature = "boring")]
mod boring {
    use std::future::IntoFuture as _;

    use rama_core::extensions::ExtensionsRef as _;
    use rama_crypto::cert::LeafCertConfig;
    use rama_quic::{EndpointConfig, NegotiatedTlsParameters, tls::BoringTlsProvider};
    use rama_tls::server::{CertificateIssuanceContext, DynamicCertIssuer};
    use rama_tls_boring::server::{
        BoringServerConfigExt as _, CacheKind, ServerCertIssuerData, ServerCertIssuerKind,
    };
    use tokio::sync::Notify;

    use super::*;

    /// Issues a leaf for whatever name is asked, and records each request.
    #[derive(Clone)]
    struct RecordingIssuer {
        ca: Arc<CertificateAuthorityData>,
        seen: Arc<Mutex<Vec<Option<CertificateIdentity>>>>,
        fail: bool,
    }

    impl RecordingIssuer {
        fn new(ca: &Arc<CertificateAuthorityData>) -> Self {
            Self {
                ca: ca.clone(),
                seen: Arc::default(),
                fail: false,
            }
        }

        fn seen(&self) -> Vec<Option<CertificateIdentity>> {
            self.seen.lock().clone()
        }
    }

    impl DynamicCertIssuer for RecordingIssuer {
        async fn issue_cert(
            &self,
            context: CertificateIssuanceContext,
        ) -> Result<ServerAuthData, BoxError> {
            self.seen.lock().push(context.server_identity.clone());
            if self.fail {
                return Err(BoxError::from_static_str("issuer unavailable"));
            }
            let Some(CertificateIdentity::Dns(name)) = context.server_identity else {
                return Err(BoxError::from_static_str("no server name"));
            };
            Ok(issue(&self.ca, name.as_str()))
        }
    }

    fn tls(issuer: &RecordingIssuer) -> TlsServerConfig {
        TlsServerConfig::new()
            .with_alpn(alpn())
            .with_cert_issuer(ServerCertIssuerData::new(issuer.clone()))
    }

    fn dns(name: &str) -> Option<CertificateIdentity> {
        Some(CertificateIdentity::Dns(Domain::try_from(name).unwrap()))
    }

    #[tokio::test]
    async fn issued_certificates_follow_the_requested_server_name() {
        let ca =
            Arc::new(CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap());
        let issuer = RecordingIssuer::new(&ca);
        let server = server(&tls(&issuer), &BoringTlsProvider).await;
        let addr = server.local_addr().unwrap();
        let served = serve(&server);

        let client = client().await;
        for name in ["a.test", "b.test", "a.test"] {
            let connection = connect(
                &client,
                client_config(&ca, alpn(), &BoringTlsProvider),
                addr,
                name,
            )
            .await
            .unwrap_or_else(|error| panic!("{name} connects: {error}"));
            connection.close(VarInt::from(0u32), b"done");
        }
        // The second `a.test` connection reuses the cached certificate.
        assert_eq!(issuer.seen(), [dns("a.test"), dns("b.test")]);

        server.close(VarInt::from(0u32), b"done");
        timeout(DEADLINE, served).await.unwrap().unwrap();
    }

    /// Connections issued the same certificate share its TLS contexts, so a session one of
    /// them issued resumes on the next.
    #[tokio::test]
    async fn connections_issued_one_certificate_resume_each_other() {
        let ca =
            Arc::new(CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap());
        let issuer = RecordingIssuer::new(&ca);
        let server = server(&tls(&issuer), &BoringTlsProvider).await;
        let addr = server.local_addr().unwrap();
        let served = serve_echo(&server);

        let client = client().await;
        let config = client_config(&ca, alpn(), &BoringTlsProvider);
        let mut resumed = Vec::new();
        for _ in 0..2 {
            let connection = exchange(&client, config.clone(), addr, "a.test").await;
            resumed.push(
                connection
                    .extensions()
                    .get_ref::<NegotiatedTlsParameters>()
                    .unwrap()
                    .resumed,
            );
            connection.close(VarInt::from(0u32), b"done");
        }
        assert_eq!(resumed, [Some(false), Some(true)]);

        server.close(VarInt::from(0u32), b"done");
        timeout(DEADLINE, served).await.unwrap().unwrap();
    }

    /// A certificate still to issue waits until the client proved its address with a Retry;
    /// one the issuer cached does not.
    #[tokio::test]
    async fn serving_validates_an_address_before_issuing_for_it() {
        let ca =
            Arc::new(CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap());
        let issuer = RecordingIssuer::new(&ca);
        let server = server(&tls(&issuer), &BoringTlsProvider).await;
        let relay = relay(server.local_addr().unwrap(), Relaying::All).await;
        let served = serve_echo(&server);

        let config = client_config(&ca, alpn(), &BoringTlsProvider);
        exchange(&client().await, config.clone(), relay.addr, "a.test")
            .await
            .close(VarInt::from(0u32), b"done");
        assert_eq!(relay.retries(), 1, "a certificate still to issue");
        // Another client, without a token from the first: the certificate is cached by now.
        let config = client_config(&ca, alpn(), &BoringTlsProvider);
        exchange(&client().await, config, relay.addr, "a.test")
            .await
            .close(VarInt::from(0u32), b"done");
        assert_eq!(relay.retries(), 1, "a cached certificate");
        assert_eq!(issuer.seen(), [dns("a.test")]);

        server.close(VarInt::from(0u32), b"done");
        timeout(DEADLINE, served).await.unwrap().unwrap();
    }

    /// An Initial retransmitted before its Retry arrives is the same attempt: one Retry is
    /// followed, and the certificate is issued once.
    #[tokio::test]
    async fn a_retransmitted_initial_is_validated_and_issued_for_once() {
        let ca =
            Arc::new(CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap());
        let issuer = RecordingIssuer::new(&ca);
        let server = server(&tls(&issuer), &BoringTlsProvider).await;
        let served = serve_echo(&server);

        let config = client_config(&ca, alpn(), &BoringTlsProvider);
        let relay = exchange_retransmitting_before_the_retry(&server, config).await;
        assert_eq!(relay.retries(), 1);
        assert_eq!(issuer.seen(), [dns("a.test")]);

        server.close(VarInt::from(0u32), b"done");
        timeout(DEADLINE, served).await.unwrap().unwrap();
    }

    /// An address validation token from an earlier connection spares the Retry.
    #[tokio::test]
    async fn a_token_validated_address_is_issued_for_without_a_retry() {
        let ca =
            Arc::new(CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap());
        let issuer = RecordingIssuer::new(&ca);
        let tls = tls(&issuer).with_cert_issuer(
            ServerCertIssuerData::new(issuer.clone()).with_cache_kind(CacheKind::Disabled),
        );
        let server = server(&tls, &BoringTlsProvider).await;
        let relay = relay(server.local_addr().unwrap(), Relaying::All).await;
        let served = serve_echo(&server);

        let client = client().await;
        let config = client_config(&ca, alpn(), &BoringTlsProvider);
        for _ in 0..2 {
            exchange(&client, config.clone(), relay.addr, "a.test")
                .await
                .close(VarInt::from(0u32), b"done");
        }
        assert_eq!(relay.retries(), 1);
        assert_eq!(issuer.seen(), [dns("a.test"), dns("a.test")]);

        server.close(VarInt::from(0u32), b"done");
        timeout(DEADLINE, served).await.unwrap().unwrap();
    }

    /// A client that never follows its Retry, as a spoofed source cannot, costs no issuance.
    #[tokio::test]
    async fn an_unproven_address_costs_no_issuance() {
        let ca =
            Arc::new(CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap());
        let issuer = RecordingIssuer::new(&ca);
        let server = server(&tls(&issuer), &BoringTlsProvider).await;
        let relay = relay(server.local_addr().unwrap(), Relaying::NoRetries).await;
        let served = serve(&server);

        let client = client().await;
        let config = client_config(&ca, alpn(), &BoringTlsProvider);
        let connecting = tokio::spawn({
            let (client, addr) = (client.clone(), relay.addr);
            async move { client.connect_with(config, addr, "a.test").unwrap().await }
        });
        until(|| relay.retries() > 0).await;
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(issuer.seen().is_empty(), "{:?}", issuer.seen());

        connecting.abort();
        server.close(VarInt::from(0u32), b"done");
        timeout(DEADLINE, served).await.unwrap().unwrap();
    }

    /// An attempt that needs a Retry no one can send gets neither issuance nor a response.
    #[tokio::test]
    async fn an_attempt_without_a_possible_retry_is_dropped_unissued() {
        let ca =
            Arc::new(CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap());
        let issuer = RecordingIssuer::new(&ca);
        let config = ServerConfig::try_from_rama_tls_with_provider(
            &tls(&issuer),
            TlsOptions::default(),
            &BoringTlsProvider,
        )
        .unwrap()
        // A token lifetime past any representable instant cannot be sealed into a Retry.
        .with_retry_token_lifetime(Duration::MAX);
        let server = Endpoint::build(Executor::new())
            .with_server_config(config)
            .bind_address(localhost())
            .await
            .unwrap();
        let addr = server.local_addr().unwrap();
        let served = serve(&server);

        let client = client().await;
        let config = client_config(&ca, alpn(), &BoringTlsProvider);
        let connecting = tokio::spawn({
            let client = client.clone();
            async move { client.connect_with(config, addr, "a.test").unwrap().await }
        });
        until(|| server.stats().ignored_handshakes > 0).await;
        assert!(issuer.seen().is_empty(), "{:?}", issuer.seen());
        assert_eq!(server.stats().refused_handshakes, 0);

        connecting.abort();
        server.close(VarInt::from(0u32), b"done");
        timeout(DEADLINE, served).await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn a_client_hello_split_over_delayed_initials_is_waited_for() {
        let ca =
            Arc::new(CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap());
        let issuer = RecordingIssuer::new(&ca);
        let tls = tls(&issuer).with_cert_issuer(
            ServerCertIssuerData::new(issuer.clone()).with_cache_kind(CacheKind::Disabled),
        );
        let server = server(&tls, &BoringTlsProvider).await;
        let relay = delaying_relay(server.local_addr().unwrap(), Duration::from_millis(250)).await;
        let served = serve(&server);

        let client = client().await;
        let started = tokio::time::Instant::now();
        let connection = connect(
            &client,
            client_config(&ca, padded_alpn(), &BoringTlsProvider),
            relay,
            "split.test",
        )
        .await
        .expect("the split ClientHello resolves once complete");
        assert!(started.elapsed() >= Duration::from_millis(250));
        assert_eq!(issuer.seen(), [dns("split.test")]);
        connection.close(VarInt::from(0u32), b"done");

        server.close(VarInt::from(0u32), b"done");
        timeout(DEADLINE, served).await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn a_large_client_hello_resolves() {
        let ca =
            Arc::new(CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap());
        let issuer = RecordingIssuer::new(&ca);
        let server = server(&tls(&issuer), &BoringTlsProvider).await;
        let addr = server.local_addr().unwrap();
        let served = serve(&server);

        let client = client().await;
        let connection = connect(
            &client,
            client_config(&ca, large_alpn(), &BoringTlsProvider),
            addr,
            "large.test",
        )
        .await
        .expect("a ClientHello of several KiB resolves");
        connection.close(VarInt::from(0u32), b"done");
        assert_eq!(issuer.seen(), [dns("large.test")]);

        server.close(VarInt::from(0u32), b"done");
        timeout(DEADLINE, served).await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn an_in_memory_ca_issues_per_server_name() {
        let ca = CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap();
        let tls =
            TlsServerConfig::new()
                .with_alpn(alpn())
                .with_cert_issuer(ServerCertIssuerData::new(
                    ServerCertIssuerKind::ProvidedCa {
                        ca: CertificateAuthorityData::try_new(
                            ca.certificate_chain().to_vec(),
                            ca.private_key().clone_key(),
                        )
                        .unwrap(),
                        leaf: LeafCertConfig::default(),
                    },
                ));
        let server = server(&tls, &BoringTlsProvider).await;
        let addr = server.local_addr().unwrap();
        let served = serve(&server);

        let client = client().await;
        for name in ["a.test", "b.test"] {
            let connection = connect(
                &client,
                client_config(&ca, alpn(), &BoringTlsProvider),
                addr,
                name,
            )
            .await
            .unwrap_or_else(|error| panic!("{name} connects: {error}"));
            connection.close(VarInt::from(0u32), b"done");
        }

        server.close(VarInt::from(0u32), b"done");
        timeout(DEADLINE, served).await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn an_incomplete_client_hello_times_out() {
        let ca =
            Arc::new(CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap());
        let issuer = RecordingIssuer::new(&ca);
        let mut endpoint_config =
            EndpointConfig::new(rama_crypto::hmac::HmacSha2::try_rand_256().unwrap());
        endpoint_config
            .handshake_timeout(Duration::from_millis(300))
            .unwrap();
        let server = Endpoint::build(Executor::new())
            .with_config(endpoint_config)
            .with_server_config(
                ServerConfig::try_from_rama_tls_with_provider(
                    &tls(&issuer),
                    TlsOptions::default(),
                    &BoringTlsProvider,
                )
                .unwrap(),
            )
            .bind_address(localhost())
            .await
            .unwrap();
        let relay = truncating_relay(server.local_addr().unwrap()).await;

        let client = client().await;
        let config = client_config(&ca, padded_alpn(), &BoringTlsProvider);
        tokio::spawn({
            let client = client.clone();
            async move {
                client
                    .connect_with(config, relay, "late.test")
                    .unwrap()
                    .await
            }
        });
        let mut incoming = server.accept().await.unwrap();
        let started = tokio::time::Instant::now();
        let error = timeout(DEADLINE, incoming.client_hello())
            .await
            .unwrap()
            .unwrap_err();
        assert!(matches!(error, ConnectionError::TimedOut), "{error:?}");
        assert!(started.elapsed() < Duration::from_secs(5));
        assert!(issuer.seen().is_empty());
    }

    #[tokio::test]
    async fn closing_the_endpoint_ends_the_wait_for_a_client_hello() {
        let ca =
            Arc::new(CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap());
        let issuer = RecordingIssuer::new(&ca);
        let server = server(&tls(&issuer), &BoringTlsProvider).await;
        let relay = truncating_relay(server.local_addr().unwrap()).await;

        let client = client().await;
        let config = client_config(&ca, padded_alpn(), &BoringTlsProvider);
        tokio::spawn({
            let client = client.clone();
            async move {
                client
                    .connect_with(config, relay, "late.test")
                    .unwrap()
                    .await
            }
        });
        let mut incoming = server.accept().await.unwrap();
        let waiting = tokio::spawn(async move { incoming.client_hello().await });
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(!waiting.is_finished());
        server.close(VarInt::from(0u32), b"done");
        let error = timeout(Duration::from_secs(2), waiting)
            .await
            .expect("the wait ends with the endpoint")
            .unwrap()
            .unwrap_err();
        assert!(matches!(error, ConnectionError::LocallyClosed), "{error:?}");
    }

    #[tokio::test]
    async fn a_failed_issuance_refuses_the_attempt() {
        let ca =
            Arc::new(CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap());
        let mut issuer = RecordingIssuer::new(&ca);
        issuer.fail = true;
        let server = server(&tls(&issuer), &BoringTlsProvider).await;
        let addr = server.local_addr().unwrap();
        let served = serve(&server);

        let client = client().await;
        let error = connect(
            &client,
            client_config(&ca, alpn(), &BoringTlsProvider),
            addr,
            "a.test",
        )
        .await
        .unwrap_err();
        assert!(refused(&error), "{error:?}");
        assert_eq!(issuer.seen(), [dns("a.test")]);

        server.close(VarInt::from(0u32), b"done");
        timeout(DEADLINE, served).await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn the_client_hello_is_read_before_accepting() {
        let ca =
            Arc::new(CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap());
        let issuer = RecordingIssuer::new(&ca);
        let server = server(&tls(&issuer), &BoringTlsProvider).await;
        let addr = server.local_addr().unwrap();

        let client = client().await;
        let config = client_config(&ca, alpn(), &BoringTlsProvider);
        let connecting = tokio::spawn({
            let client = client.clone();
            async move { connect(&client, config, addr, "early.test").await }
        });
        let mut incoming = server.accept().await.unwrap();
        let hello = timeout(DEADLINE, incoming.client_hello())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            hello.ext_server_name().map(Domain::as_str),
            Some("early.test")
        );
        assert!(
            issuer.seen().is_empty(),
            "nothing is issued before accepting"
        );

        let accepted = timeout(DEADLINE, incoming.into_future())
            .await
            .unwrap()
            .unwrap();
        connecting.await.unwrap().expect("the client connects");
        accepted.close(VarInt::from(0u32), b"done");
    }

    #[tokio::test]
    async fn accepting_without_the_client_hello_fails_the_attempt() {
        let ca =
            Arc::new(CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap());
        let issuer = RecordingIssuer::new(&ca);
        let server = server(&tls(&issuer), &BoringTlsProvider).await;
        let addr = server.local_addr().unwrap();

        let client = client().await;
        let config = client_config(&ca, alpn(), &BoringTlsProvider);
        let connecting = tokio::spawn({
            let client = client.clone();
            async move { connect(&client, config, addr, "a.test").await }
        });
        let incoming = server.accept().await.unwrap();
        assert!(
            incoming.accept().is_err(),
            "a resolving configuration cannot start here"
        );
        let error = connecting.await.unwrap().unwrap_err();
        assert!(
            matches!(
                &error,
                ConnectionError::ConnectionClosed(close)
                    if close.error_code == TransportErrorCode::INTERNAL_ERROR
            ),
            "{error:?}"
        );
        assert!(issuer.seen().is_empty());
    }

    /// Never issues, after telling it was asked.
    #[derive(Clone, Default)]
    struct Stalled(Arc<Notify>);

    impl DynamicCertIssuer for Stalled {
        async fn issue_cert(
            &self,
            _: CertificateIssuanceContext,
        ) -> Result<ServerAuthData, BoxError> {
            self.0.notify_one();
            std::future::pending().await
        }
    }

    fn stalled_tls(issuer: &Stalled) -> TlsServerConfig {
        TlsServerConfig::new()
            .with_alpn(alpn())
            .with_cert_issuer(ServerCertIssuerData::new(issuer.clone()))
    }

    #[tokio::test]
    async fn a_stalled_issuance_ends_with_its_attempt() {
        let ca =
            Arc::new(CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap());
        let issuer = Stalled::default();
        let mut endpoint_config =
            EndpointConfig::new(rama_crypto::hmac::HmacSha2::try_rand_256().unwrap());
        endpoint_config
            .handshake_timeout(Duration::from_millis(300))
            .unwrap();
        let server = Endpoint::build(Executor::new())
            .with_config(endpoint_config)
            .with_server_config(
                ServerConfig::try_from_rama_tls_with_provider(
                    &stalled_tls(&issuer),
                    TlsOptions::default(),
                    &BoringTlsProvider,
                )
                .unwrap(),
            )
            .bind_address(localhost())
            .await
            .unwrap();
        let addr = server.local_addr().unwrap();

        let client = client().await;
        let config = client_config(&ca, alpn(), &BoringTlsProvider);
        tokio::spawn({
            let client = client.clone();
            async move { client.connect_with(config, addr, "a.test").unwrap().await }
        });
        let incoming = server.accept().await.unwrap();
        let started = tokio::time::Instant::now();
        let error = timeout(DEADLINE, incoming.into_future())
            .await
            .expect("the attempt's deadline ends the issuance")
            .unwrap_err();
        assert!(matches!(error, ConnectionError::TimedOut), "{error:?}");
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[tokio::test]
    async fn closing_the_endpoint_ends_a_stalled_issuance() {
        let ca =
            Arc::new(CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap());
        let issuer = Stalled::default();
        let server = server(&stalled_tls(&issuer), &BoringTlsProvider).await;
        let addr = server.local_addr().unwrap();
        let served = serve(&server);

        let client = client().await;
        let config = client_config(&ca, alpn(), &BoringTlsProvider);
        tokio::spawn({
            let client = client.clone();
            async move { client.connect_with(config, addr, "a.test").unwrap().await }
        });
        timeout(DEADLINE, issuer.0.notified())
            .await
            .expect("the attempt asks for a certificate");
        server.close(VarInt::from(0u32), b"done");
        timeout(Duration::from_secs(2), served)
            .await
            .expect("serving drains without waiting on the issuer")
            .unwrap();
    }
}

#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
mod rustls {
    use rama_quic::tls::RustlsTlsProvider;
    use rama_tls_rustls::{
        dep::rustls,
        server::{DynamicConfigProvider, RustlsServerConfigExt as _},
    };

    use super::*;

    fn crypto() -> Arc<rustls::crypto::CryptoProvider> {
        #[cfg(feature = "aws-lc")]
        {
            Arc::new(rustls::crypto::aws_lc_rs::default_provider())
        }
        #[cfg(not(feature = "aws-lc"))]
        {
            Arc::new(rustls::crypto::ring::default_provider())
        }
    }

    /// Builds a rustls configuration with a leaf for whatever name is asked.
    struct PerName {
        ca: Arc<CertificateAuthorityData>,
        seen: Arc<Mutex<Vec<Option<String>>>>,
        fail: bool,
    }

    impl DynamicConfigProvider for PerName {
        async fn get_config(
            &self,
            client_hello: rustls::server::ClientHello<'_>,
        ) -> Result<Arc<rustls::ServerConfig>, BoxError> {
            let name = client_hello.server_name().map(str::to_owned);
            self.seen.lock().push(name.clone());
            if self.fail {
                return Err(BoxError::from_static_str("configuration unavailable"));
            }
            let name = name.ok_or_else(|| BoxError::from_static_str("no server name"))?;
            let auth = issue(&self.ca, &name);
            let mut config = rustls::ServerConfig::builder_with_provider(crypto())
                .with_protocol_versions(&[&rustls::version::TLS13])?
                .with_no_client_auth()
                .with_single_cert(auth.cert_chain, auth.private_key)?;
            config.alpn_protocols = vec![ALPN.to_vec()];
            Ok(Arc::new(config))
        }
    }

    #[tokio::test]
    async fn dynamic_configurations_follow_the_requested_server_name() {
        let ca =
            Arc::new(CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let provider = RustlsTlsProvider::new(crypto());
        let tls = TlsServerConfig::new().with_dynamic_config(Arc::new(PerName {
            ca: ca.clone(),
            seen: seen.clone(),
            fail: false,
        }));
        let server = server(&tls, &provider).await;
        let relay = delaying_relay(server.local_addr().unwrap(), Duration::from_millis(100)).await;
        let served = serve(&server);

        let client = client().await;
        for (name, alpn, addr) in [
            ("a.test", alpn(), server.local_addr().unwrap()),
            ("b.test", padded_alpn(), relay),
        ] {
            let connection = connect(&client, client_config(&ca, alpn, &provider), addr, name)
                .await
                .unwrap_or_else(|error| panic!("{name} connects: {error}"));
            connection.close(VarInt::from(0u32), b"done");
        }
        assert_eq!(
            *seen.lock(),
            [Some("a.test".to_owned()), Some("b.test".to_owned())]
        );

        server.close(VarInt::from(0u32), b"done");
        timeout(DEADLINE, served).await.unwrap().unwrap();
    }

    /// The provider is opaque, so every attempt without a validated address gets a Retry.
    #[tokio::test]
    async fn serving_validates_every_address_before_resolving() {
        let ca =
            Arc::new(CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let provider = RustlsTlsProvider::new(crypto());
        let tls = TlsServerConfig::new().with_dynamic_config(Arc::new(PerName {
            ca: ca.clone(),
            seen: seen.clone(),
            fail: false,
        }));
        let server = server(&tls, &provider).await;
        let relay = relay(server.local_addr().unwrap(), Relaying::All).await;
        let served = serve_echo(&server);

        // Two clients without tokens, so neither address is validated: each gets a Retry.
        for client in [client().await, client().await] {
            exchange(
                &client,
                client_config(&ca, alpn(), &provider),
                relay.addr,
                "a.test",
            )
            .await
            .close(VarInt::from(0u32), b"done");
        }
        assert_eq!(relay.retries(), 2);

        server.close(VarInt::from(0u32), b"done");
        timeout(DEADLINE, served).await.unwrap().unwrap();
    }

    /// An Initial retransmitted before its Retry arrives is the same attempt: one Retry is
    /// followed, and the configuration is resolved once.
    #[tokio::test]
    async fn a_retransmitted_initial_is_validated_and_resolved_once() {
        let ca =
            Arc::new(CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let provider = RustlsTlsProvider::new(crypto());
        let tls = TlsServerConfig::new().with_dynamic_config(Arc::new(PerName {
            ca: ca.clone(),
            seen: seen.clone(),
            fail: false,
        }));
        let server = server(&tls, &provider).await;
        let served = serve_echo(&server);

        let config = client_config(&ca, alpn(), &provider);
        let relay = exchange_retransmitting_before_the_retry(&server, config).await;
        assert_eq!(relay.retries(), 1);
        assert_eq!(*seen.lock(), [Some("a.test".to_owned())]);

        server.close(VarInt::from(0u32), b"done");
        timeout(DEADLINE, served).await.unwrap().unwrap();
    }

    /// rustls reads the record layer a few KiB at a time: a larger ClientHello must still be
    /// handed over whole.
    #[tokio::test]
    async fn a_large_client_hello_resolves() {
        let ca =
            Arc::new(CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let provider = RustlsTlsProvider::new(crypto());
        let tls = TlsServerConfig::new().with_dynamic_config(Arc::new(PerName {
            ca: ca.clone(),
            seen: seen.clone(),
            fail: false,
        }));
        let server = server(&tls, &provider).await;
        let addr = server.local_addr().unwrap();
        let served = serve(&server);

        let client = client().await;
        let connection = connect(
            &client,
            client_config(&ca, large_alpn(), &provider),
            addr,
            "large.test",
        )
        .await
        .expect("a ClientHello of several KiB resolves");
        connection.close(VarInt::from(0u32), b"done");
        assert_eq!(*seen.lock(), [Some("large.test".to_owned())]);

        server.close(VarInt::from(0u32), b"done");
        timeout(DEADLINE, served).await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn a_failed_configuration_refuses_the_attempt() {
        let ca =
            Arc::new(CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let provider = RustlsTlsProvider::new(crypto());
        let tls = TlsServerConfig::new().with_dynamic_config(Arc::new(PerName {
            ca: ca.clone(),
            seen: seen.clone(),
            fail: true,
        }));
        let server = server(&tls, &provider).await;
        let addr = server.local_addr().unwrap();
        let served = serve(&server);

        let client = client().await;
        let error = connect(
            &client,
            client_config(&ca, alpn(), &provider),
            addr,
            "a.test",
        )
        .await
        .unwrap_err();
        assert!(refused(&error), "{error:?}");
        assert_eq!(*seen.lock(), [Some("a.test".to_owned())]);

        server.close(VarInt::from(0u32), b"done");
        timeout(DEADLINE, served).await.unwrap().unwrap();
    }
}
