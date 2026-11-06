#![cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "an integration test's fixtures fail the test by panicking"
)]
//! Platform verification and certificate chain policies over QUIC.

use std::{
    convert::Infallible,
    net::{Ipv4Addr, SocketAddr},
    time::Duration,
};

use rama_core::{rt::Executor, service::service_fn};
use rama_crypto::cert::CertificateAuthorityData;
use rama_net::{address::Domain, tls::ApplicationProtocol};
use rama_quic::{
    ClientConfig, Connection, Endpoint, ServerConfig,
    tls::{QuicClientConfigProvider, QuicServerConfigProvider, TlsOptions},
};
use rama_tls::{
    client::{
        DistrustedServerKeys, DynTlsServerCertChainPolicy, ServerVerifyMode, TlsClientConfig,
        TlsServerTrust,
    },
    server::{
        CertificateIdentity, LeafCertRequest, SelfSignedCaConfig, ServerAuthData, TlsServerConfig,
    },
};
use tokio::time::timeout;

const DEADLINE: Duration = Duration::from_secs(10);
const ALPN: &[u8] = b"rama-quic-trust";
const NAME: &str = "trust.localhost";

fn localhost() -> SocketAddr {
    SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0)
}

struct Origin {
    ca: CertificateAuthorityData,
    leaf: ServerAuthData,
}

fn origin() -> Origin {
    let ca = CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap();
    let leaf = ServerAuthData::new_issued_by(
        &ca,
        LeafCertRequest {
            identities: vec![CertificateIdentity::Dns(Domain::from_static(NAME))],
            ..Default::default()
        },
    )
    .unwrap();
    Origin { ca, leaf }
}

/// Whether a client configured by `tls` completes a handshake with `origin`.
async fn connects(
    origin: &Origin,
    tls: TlsClientConfig,
    client_provider: &dyn QuicClientConfigProvider,
    server_provider: &dyn QuicServerConfigProvider,
) -> bool {
    let server_tls = TlsServerConfig::new()
        .with_alpn([ApplicationProtocol::from(ALPN)].into_iter().collect())
        .with_server_auth(origin.leaf.clone());
    let server = Endpoint::build(Executor::new())
        .with_server_config(
            ServerConfig::try_from_rama_tls_with_provider(
                &server_tls,
                TlsOptions::default(),
                server_provider,
            )
            .unwrap(),
        )
        .bind_address(localhost())
        .await
        .expect("the server binds");
    let served = tokio::spawn(server.clone().serve(
        Executor::new(),
        service_fn(async |connection: Connection| {
            _ = connection.closed().await;
            Ok::<_, Infallible>(())
        }),
    ));

    let client = Endpoint::build(Executor::new())
        .bind_address(localhost())
        .await
        .expect("the client binds");
    let tls = tls.with_alpn([ApplicationProtocol::from(ALPN)].into_iter().collect());
    let config =
        ClientConfig::try_from_rama_tls_with_provider(&tls, TlsOptions::default(), client_provider)
            .unwrap();
    let attempt = client
        .connect_with(config, server.local_addr().unwrap(), NAME)
        .unwrap();
    let connected = timeout(DEADLINE, attempt)
        .await
        .expect("the attempt settles")
        .is_ok();
    served.abort();
    connected
}

async fn assert_trust_matrix(
    client_provider: &dyn QuicClientConfigProvider,
    server_provider: &dyn QuicServerConfigProvider,
) {
    let origin = origin();
    let ca = origin.ca.certificate_chain()[0].clone();
    let platform = || {
        TlsClientConfig::new().with_server_trust(
            TlsServerTrust::platform_verifier()
                .try_with_additional_anchors([ca.clone()])
                .unwrap(),
        )
    };
    let distrust_ca = || {
        DynTlsServerCertChainPolicy::new(DistrustedServerKeys::new().try_with_key_of(&ca).unwrap())
    };

    assert!(
        !connects(
            &origin,
            TlsClientConfig::new().with_platform_verifier(),
            client_provider,
            server_provider
        )
        .await,
        "the platform does not trust a private CA"
    );
    assert!(
        connects(&origin, platform(), client_provider, server_provider).await,
        "the platform trusts an additional anchor"
    );
    assert!(
        !connects(
            &origin,
            platform().with_server_cert_chain_policy(distrust_ca()),
            client_provider,
            server_provider
        )
        .await,
        "a distrusted CA key is rejected under platform verification"
    );
    assert!(
        !connects(
            &origin,
            TlsClientConfig::new()
                .try_with_server_trust_anchors([ca.clone()])
                .unwrap()
                .with_server_cert_chain_policy(distrust_ca()),
            client_provider,
            server_provider
        )
        .await,
        "a distrusted CA key is rejected under custom roots"
    );
    let distrust_leaf = DynTlsServerCertChainPolicy::new(
        DistrustedServerKeys::new()
            .try_with_key_of(&origin.leaf.cert_chain[0])
            .unwrap(),
    );
    assert!(
        !connects(
            &origin,
            TlsClientConfig::new()
                .with_server_verify(ServerVerifyMode::Disable)
                .with_server_cert_chain_policy(distrust_leaf),
            client_provider,
            server_provider
        )
        .await,
        "a distrusted key is rejected without verification"
    );
}

#[cfg(feature = "boring")]
#[tokio::test]
async fn boring_enforces_platform_trust_and_chain_policies() {
    use rama_quic::tls::BoringTlsProvider;
    assert_trust_matrix(&BoringTlsProvider, &BoringTlsProvider).await;
}

#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
#[tokio::test]
async fn rustls_enforces_platform_trust_and_chain_policies() {
    use rama_quic::tls::RustlsTlsProvider;
    use rama_tls_rustls::dep::rustls;

    #[cfg(feature = "aws-lc")]
    let crypto = std::sync::Arc::new(rustls::crypto::aws_lc_rs::default_provider());
    #[cfg(not(feature = "aws-lc"))]
    let crypto = std::sync::Arc::new(rustls::crypto::ring::default_provider());
    let provider = RustlsTlsProvider::new(crypto);
    assert_trust_matrix(&provider, &provider).await;
}
