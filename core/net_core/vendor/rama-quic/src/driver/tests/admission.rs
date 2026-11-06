//! Admission holds a lease from the Initial through every handshake outcome.

use std::{net::UdpSocket, num::NonZeroUsize};

use tokio::{task::yield_now, time::advance};

use crate::{AdmissionConfig, ConnectionError};
use rama_quic_proto::TransportErrorCode;

use super::*;

const DEADLINE: Duration = Duration::from_secs(10);

fn configured(config: AdmissionConfig) -> (Endpoint, Endpoint) {
    let factory = EndpointFactory::new();
    let client = factory.endpoint();
    let server = factory.endpoint();
    server.set_server_config(Some(
        test_helpers::server(&factory.identity).with_admission(config),
    ));
    (client, server)
}

async fn arriving(client: &Endpoint, server: &Endpoint) -> (crate::Connecting, crate::Incoming) {
    let connecting = client
        .connect(server.local_addr().unwrap(), "localhost")
        .unwrap();
    let incoming = timeout(DEADLINE, server.accept()).await.unwrap().unwrap();
    (connecting, incoming)
}

async fn empty(server: &Endpoint) {
    timeout(DEADLINE, async {
        while server.stats().handshakes_in_progress != 0 {
            yield_now().await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn admission_below_threshold_has_no_retry_and_completion_releases_the_lease() {
    let (client, server) = configured(AdmissionConfig::default());
    let (connecting, incoming) = arriving(&client, &server).await;
    assert!(!incoming.remote_address_validated());
    assert_eq!(server.stats().retried_under_load, 0);
    assert_eq!(server.stats().handshakes_in_progress, 1);
    let accepting = incoming.accept().unwrap();
    assert_eq!(server.stats().handshakes_in_progress, 1);
    let (outgoing, accepted) = timeout(DEADLINE, async { join!(connecting, accepting) })
        .await
        .unwrap();
    let (_outgoing, _accepted) = (outgoing.unwrap(), accepted.unwrap());
    assert_eq!(server.stats().handshakes_in_progress, 0);
}

#[tokio::test]
async fn admission_retries_under_load_then_accepts_the_validated_client_transparently() {
    let (client, server) = configured(AdmissionConfig::default().with_retry_threshold_min(1));
    let (_first_client, first_incoming) = arriving(&client, &server).await;
    let (second_client, second_incoming) = arriving(&client, &server).await;
    assert!(second_incoming.remote_address_validated());
    assert!(
        server.stats().retried_under_load >= 1,
        "a client PTO may draw a second Retry"
    );
    assert_eq!(server.stats().handshakes_in_progress, 2);
    let second_server = second_incoming.accept().unwrap();
    let (outgoing, accepted) = timeout(DEADLINE, async { join!(second_client, second_server) })
        .await
        .unwrap();
    let (_outgoing, _accepted) = (outgoing.unwrap(), accepted.unwrap());
    assert_eq!(server.stats().handshakes_in_progress, 1);
    drop(first_incoming);
    empty(&server).await;
}

#[tokio::test]
async fn admission_hard_cap_refuses_unvalidated_and_validated_attempts() {
    for threshold in [0, 1] {
        let (client, server) = configured(
            AdmissionConfig::default()
                .with_retry_threshold_min(threshold)
                .with_retry_threshold_max(threshold)
                .with_max_in_progress(1),
        );
        let (_first, incoming) = arriving(&client, &server).await;
        let second = client
            .connect(server.local_addr().unwrap(), "localhost")
            .unwrap();
        let error = timeout(DEADLINE, second).await.unwrap().unwrap_err();
        assert_matches!(error, ConnectionError::ConnectionClosed(ref close) if close.error_code == TransportErrorCode::CONNECTION_REFUSED);
        assert!(server.stats().refused_at_limit >= 1);
        assert_eq!(server.stats().handshakes_in_progress, 1);
        drop(incoming);
        empty(&server).await;
    }
}

#[tokio::test]
async fn admission_per_source_cap_counts_validated_clients_and_recovers_after_drop() {
    let (client, server) = configured(
        AdmissionConfig::default()
            .with_retry_threshold_min(0)
            .with_retry_threshold_max(0)
            .with_max_in_progress_per_source(NonZeroUsize::MIN),
    );
    let (_first, incoming) = arriving(&client, &server).await;
    assert!(incoming.remote_address_validated());
    let second = client
        .connect(server.local_addr().unwrap(), "localhost")
        .unwrap();
    let error = timeout(DEADLINE, second).await.unwrap().unwrap_err();
    assert_matches!(error, ConnectionError::ConnectionClosed(ref close) if close.error_code == TransportErrorCode::CONNECTION_REFUSED);
    assert!(server.stats().refused_per_source >= 1);
    drop(incoming);
    empty(&server).await;
    let (_third, incoming) = arriving(&client, &server).await;
    assert!(incoming.remote_address_validated());
    assert_eq!(server.stats().handshakes_in_progress, 1);
    drop(incoming);
    empty(&server).await;
}

#[tokio::test]
async fn admission_is_released_when_incoming_or_connecting_is_abandoned() {
    for outcome in 0..6 {
        let (client, server) = configured(AdmissionConfig::default());
        let (_client, incoming) = arriving(&client, &server).await;
        match outcome {
            0 => drop(incoming),
            1 => incoming.refuse(),
            2 => incoming.ignore(),
            3 => {
                let connecting = incoming.accept().unwrap();
                assert_eq!(server.stats().handshakes_in_progress, 1);
                drop(connecting);
            }
            4 => {
                server.set_server_config(None);
                assert_matches!(incoming.accept(), Err(ConnectionError::LocallyClosed));
            }
            _ => {
                let connecting = incoming.accept().unwrap();
                client.close(0u32, b"cancel");
                timeout(DEADLINE, connecting).await.unwrap().unwrap_err();
            }
        }
        empty(&server).await;
    }
}

#[tokio::test]
async fn admission_is_released_when_pending_or_accepted_handshakes_expire() {
    for accept in [false, true] {
        let factory = EndpointFactory::new();
        let client = factory.endpoint();
        let mut server_factory = EndpointFactory::new();
        server_factory.identity = factory.identity.clone();
        server_factory
            .endpoint_config
            .handshake_timeout(Duration::from_secs(1))
            .unwrap();
        let server = server_factory.endpoint();
        let (_client, incoming) = arriving(&client, &server).await;
        // No client response can progress the handshake while the single-thread runtime is paused.
        tokio::time::pause();
        let mut incoming = Some(incoming);
        let connecting = if accept {
            Some(incoming.take().unwrap().accept().unwrap())
        } else {
            None
        };
        assert_eq!(server.stats().handshakes_in_progress, 1);
        advance(Duration::from_secs(2)).await;
        if let Some(connecting) = connecting {
            assert_matches!(connecting.await, Err(ConnectionError::TimedOut));
        }
        empty(&server).await;
        tokio::time::resume();
    }
}

#[tokio::test]
async fn established_streams_progress_while_new_handshakes_hold_the_retry_threshold() {
    let (client, server) = configured(
        AdmissionConfig::default()
            .with_retry_threshold_min(4)
            .with_retry_threshold_max(4),
    );
    let (connecting, incoming) = arriving(&client, &server).await;
    let accepting = incoming.accept().unwrap();
    let (outgoing, accepted) = timeout(DEADLINE, async { join!(connecting, accepting) })
        .await
        .unwrap();
    let (outgoing, accepted) = (outgoing.unwrap(), accepted.unwrap());
    let mut pending = Vec::new();
    for _ in 0..16 {
        pending.push(arriving(&client, &server).await);
    }
    assert_eq!(server.stats().handshakes_in_progress, 16);
    assert!(server.stats().retried_under_load >= 12);
    timeout(DEADLINE, async {
        join!(
            async {
                let (mut send, mut recv) = outgoing.open_bi().await.unwrap();
                send.write_all(b"ping").await.unwrap();
                send.finish().unwrap();
                assert_eq!(recv.read_to_end(4).await.unwrap(), b"pong");
            },
            async {
                let (mut send, mut recv) = accepted.accept_bi().await.unwrap();
                assert_eq!(recv.read_to_end(4).await.unwrap(), b"ping");
                send.write_all(b"pong").await.unwrap();
                send.finish().unwrap();
            },
        );
    })
    .await
    .unwrap();
    drop(pending);
    empty(&server).await;
}

/// A Retry sent under load keeps the replaced socket's route for the token's lifetime, so a
/// client returning with its token after a rebind still reaches the endpoint.
#[tokio::test]
async fn a_retry_under_load_holds_the_route_of_a_replaced_socket() {
    let always_retry = AdmissionConfig::default()
        .with_retry_threshold_min(0)
        .with_retry_threshold_max(0);
    for (config, retried) in [(AdmissionConfig::default(), false), (always_retry, true)] {
        let (_client_endpoint, server) = {
            let (client, server) = configured(config);
            let (connecting, incoming) = arriving(&client, &server).await;
            assert_eq!(incoming.remote_address_validated(), retried);
            incoming.ignore();
            drop(connecting);
            (client, server)
        };
        empty(&server).await;
        server
            .rebind_std_socket(UdpSocket::bind("127.0.0.1:0").unwrap())
            .unwrap();
        assert_eq!(
            server.stats().retained_sockets,
            if retried { 2 } else { 1 },
            "retried {retried}: the replaced socket is held only for a Retry's returning client"
        );
    }
}
