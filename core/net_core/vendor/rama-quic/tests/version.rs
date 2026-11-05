#![cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "an integration test's fixtures fail the test by panicking"
)]
//! QUIC versions over real sockets, through the public API.

mod runtime;

use std::{
    future::{Future as _, poll_fn},
    net::{Ipv4Addr, SocketAddr},
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    task::{Context, Wake, Waker},
    time::Duration,
};

use rama_core::rt::Executor;
use rama_quic::Endpoint;
use rama_quic_proto::{
    Version,
    profile::{ConnectionIdProfile, QuicProfile},
    version::ClientVersionPolicy,
};
use runtime::Identities;

async fn loopback_endpoint(server: Option<rama_quic::ServerConfig>) -> Endpoint {
    let builder = Endpoint::build(Executor::new());
    let builder = match server {
        Some(config) => builder.with_server_config(config),
        None => builder,
    };
    builder
        .bind_address(SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0))
        .await
        .expect("an endpoint binds")
}

/// A client that starts in version 2 completes the handshake with a default server and
/// exchanges data.
#[tokio::test]
async fn a_v2_first_flight_completes_against_a_default_server() {
    let identities = Identities::new();
    let server = loopback_endpoint(Some(identities.server_config())).await;
    let client = loopback_endpoint(None).await;
    let address = server.local_addr().unwrap();

    let serving = tokio::spawn({
        let server = server.clone();
        async move { runtime::serve_one(&server).await }
    });

    let mut config = identities.client_config();
    config.set_version(Version::V2).unwrap();
    let connection = client
        .connect_with(config, address, runtime::SERVER_NAME)
        .expect("the attempt starts")
        .await
        .expect("the v2 handshake completes");
    runtime::exchange(&connection, b"hello over QUICv2").await;
    connection.close(0u32, b"done");
    serving.await.unwrap();
    tokio::join!(client.shutdown(), server.shutdown());
}

fn endpoint_config(versions: Vec<Version>) -> rama_quic::EndpointConfig {
    let mut config =
        rama_quic::EndpointConfig::new(rama_crypto::hmac::HmacSha2::try_rand_256().unwrap());
    config.set_supported_versions(versions);
    config
}

async fn server_speaking(versions: Vec<Version>, config: rama_quic::ServerConfig) -> Endpoint {
    Endpoint::build(Executor::new())
        .with_config(endpoint_config(versions))
        .with_server_config(config)
        .bind_address(SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0))
        .await
        .expect("an endpoint binds")
}

/// RFC 9368 §2.1: a server that only speaks v2 answers a v1 first flight with Version
/// Negotiation, and the client starts over in v2 without the application noticing.
#[tokio::test]
async fn a_client_restarts_in_v2_when_the_server_only_speaks_v2() {
    let identities = Identities::new();
    let server = server_speaking(vec![Version::V2], identities.server_config()).await;
    let client = loopback_endpoint(None).await;
    let address = server.local_addr().unwrap();

    let serving = tokio::spawn({
        let server = server.clone();
        async move { runtime::serve_one(&server).await }
    });

    let connection = client
        .connect_with(identities.client_config(), address, runtime::SERVER_NAME)
        .expect("the attempt starts")
        .await
        .expect("the restarted handshake completes");
    assert_eq!(connection.version(), Version::V2);
    assert_eq!(connection.original_version(), Version::V2);
    assert_eq!(
        client.stats().outgoing_handshakes,
        2,
        "the first flight and the restart"
    );
    runtime::exchange(&connection, b"after version negotiation").await;
    connection.close(0u32, b"done");
    serving.await.unwrap();
    tokio::join!(client.shutdown(), server.shutdown());
}

/// RFC 9368 §4: after a Version Negotiation restart, a server whose version_information reports an
/// empty Available Versions list cannot justify the version the client was moved to, so the client
/// refuses the connection rather than trusting a possibly forged negotiation.
#[tokio::test]
async fn a_restart_with_an_empty_server_version_list_is_refused() {
    use rama_quic_proto::version::ServerVersionPolicy;

    let identities = Identities::new();
    let mut config = identities.server_config();
    config.set_versions(
        ServerVersionPolicy::new()
            .try_with_fully_deployed(vec![])
            .unwrap()
            .with_reserved_version_grease(false),
    );
    // Only v2, so a v1 first flight is answered with Version Negotiation and the client restarts.
    let server = server_speaking(vec![Version::V2], config).await;
    let client = loopback_endpoint(None).await;
    let address = server.local_addr().unwrap();

    let accepting = tokio::spawn({
        let server = server.clone();
        async move {
            let incoming = server.accept().await.expect("an attempt arrives");
            let _result = incoming.await;
        }
    });

    let error = client
        .connect_with(identities.client_config(), address, runtime::SERVER_NAME)
        .expect("the attempt starts")
        .await
        .expect_err("the empty list is refused");
    match error {
        rama_quic::ConnectionError::TransportError(error) => assert_eq!(
            error.code(),
            rama_quic_proto::TransportErrorCode::VERSION_NEGOTIATION_ERROR
        ),
        other => panic!("expected a version negotiation error, got {other:?}"),
    }
    accepting.await.unwrap();
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A server offering nothing the client speaks ends the attempt with what it offered.
#[tokio::test]
async fn an_offer_without_a_common_version_ends_the_attempt() {
    let identities = Identities::new();
    let draft = Version::from_u32(0xff00_0020);
    let server = server_speaking(vec![draft], identities.server_config()).await;
    let client = loopback_endpoint(None).await;
    let address = server.local_addr().unwrap();

    let error = client
        .connect_with(identities.client_config(), address, runtime::SERVER_NAME)
        .expect("the attempt starts")
        .await
        .expect_err("no mutually supported version");
    match error {
        rama_quic::ConnectionError::VersionMismatch { offered } => {
            assert!(offered.contains(&draft));
            assert!(offered.iter().any(|version| version.is_reserved()));
        }
        other => panic!("expected a version mismatch, got {other:?}"),
    }
    assert_eq!(client.stats().outgoing_handshakes, 1);
    tokio::join!(client.shutdown(), server.shutdown());
}

/// RFC 9368 §4: after a restart the client checks the server's fully deployed list. A server
/// that claims to have v1 deployed everywhere while its Version Negotiation packet omitted it
/// looks like a downgrade, and the client refuses the connection.
#[tokio::test]
async fn a_restart_that_the_servers_deployed_list_contradicts_is_refused() {
    use rama_quic_proto::version::ServerVersionPolicy;

    let identities = Identities::new();
    let mut config = identities.server_config();
    config.set_versions(
        ServerVersionPolicy::new()
            .try_with_fully_deployed(vec![Version::V1, Version::V2])
            .unwrap(),
    );
    let server = server_speaking(vec![Version::V2], config).await;
    let client = loopback_endpoint(None).await;
    let address = server.local_addr().unwrap();

    let accepting = tokio::spawn({
        let server = server.clone();
        async move {
            let incoming = server.accept().await.expect("an attempt arrives");
            // The client ends the handshake; the server sees it fail.
            let _result = incoming.await;
        }
    });

    let error = client
        .connect_with(identities.client_config(), address, runtime::SERVER_NAME)
        .expect("the attempt starts")
        .await
        .expect_err("the downgrade is detected");
    match error {
        rama_quic::ConnectionError::TransportError(error) => assert_eq!(
            error.code(),
            rama_quic_proto::TransportErrorCode::VERSION_NEGOTIATION_ERROR
        ),
        other => panic!("expected a version negotiation error, got {other:?}"),
    }
    accepting.await.unwrap();
    tokio::join!(client.shutdown(), server.shutdown());
}

/// A Version Negotiation restart replaces its abandoned zero-CID route before
/// reserving the same dedicated endpoint for the next first flight.
#[tokio::test]
async fn zero_cid_profile_restarts_after_version_negotiation() {
    tokio::time::timeout(Duration::from_secs(10), async {
        let identities = Identities::new();
        let server = server_speaking(vec![Version::V2], identities.server_config()).await;
        let profile = QuicProfile::standard()
            .with_versions(
                ClientVersionPolicy::new(Version::V1)
                    .unwrap()
                    .try_with_supported(vec![Version::V1, Version::V2])
                    .unwrap(),
            )
            .with_connection_ids(
                ConnectionIdProfile::standard()
                    .try_with_local_len(0)
                    .unwrap(),
            );
        let mut endpoint = endpoint_config(vec![Version::V1, Version::V2]);
        endpoint.apply_quic_profile(&profile).unwrap();
        let client = Endpoint::build(Executor::new())
            .with_config(endpoint)
            .bind_address(SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0))
            .await
            .unwrap();
        let serving = tokio::spawn({
            let server = server.clone();
            async move { runtime::serve_one(&server).await }
        });
        let mut config = identities.client_config();
        config.apply_quic_profile(&profile).unwrap();
        let mut connecting = client
            .connect_with(config, server.local_addr().unwrap(), runtime::SERVER_NAME)
            .unwrap();
        let first_wake_connections = Arc::new(AtomicUsize::new(usize::MAX));
        // Observe the endpoint synchronously at notification, before the waiting
        // task resumes. The current-thread runtime makes this ordering assertion
        // deterministic; no scheduling race or sleep is part of the regression.
        let connection = poll_fn(|cx| {
            let waker = Waker::from(Arc::new(RestartWake {
                endpoint: client.clone(),
                first_wake_connections: first_wake_connections.clone(),
                inner: cx.waker().clone(),
            }));
            Pin::new(&mut connecting).poll(&mut Context::from_waker(&waker))
        })
        .await
        .expect("zero-CID endpoint is released before the version restart");
        assert_eq!(
            first_wake_connections.load(Ordering::SeqCst),
            0,
            "the abandoned route must be removed before notifying the retry task"
        );
        assert_eq!(connection.version(), Version::V2);
        assert_eq!(client.stats().outgoing_handshakes, 2);
        runtime::exchange(&connection, b"zero CID after negotiation").await;
        connection.close(0u32, b"done");
        serving.await.unwrap();
        tokio::join!(client.shutdown(), server.shutdown());
    })
    .await
    .unwrap();
}

struct RestartWake {
    endpoint: Endpoint,
    first_wake_connections: Arc<AtomicUsize>,
    inner: Waker,
}

impl Wake for RestartWake {
    fn wake(self: Arc<Self>) {
        self.wake_by_ref();
    }

    fn wake_by_ref(self: &Arc<Self>) {
        let _previous = self.first_wake_connections.compare_exchange(
            usize::MAX,
            self.endpoint.open_connections(),
            Ordering::SeqCst,
            Ordering::SeqCst,
        );
        self.inner.wake_by_ref();
    }
}
