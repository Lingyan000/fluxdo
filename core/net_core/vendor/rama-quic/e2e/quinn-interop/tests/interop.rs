//! Rama's QUIC transport against the upstream Quinn stack, both directions, through the public
//! API only: no engine internals, and no Rustls type on the Rama side of any call.

mod common;

use std::{sync::Arc, time::Duration};

use common::*;
use rama::quic::{ConnectionError, Endpoint, proto::frame::FrameType};
use rustls::AlertDescription;
#[cfg(not(feature = "boring"))]
use rustls::CertificateError;

// The baseline stream scenario in both roles moved to `baseline.rs`, where it runs from the
// shared `interop-common` definition; what remains here is Quinn-specific.

/// Rama's client refuses a server whose identity it does not trust, and the same client accepts
/// the same server when it does. The refusal is the certificate check, named in the error.
#[tokio::test]
async fn a_rama_client_refuses_a_server_it_does_not_trust() {
    let auth = identity();
    let anchor = auth.cert_chain.last().expect("a chain").clone();
    let stranger = identity_from_a_stranger("Someone Else Entirely");
    let wrong_anchor = stranger.cert_chain.last().expect("a chain").clone();

    let server = quinn::Endpoint::server(quinn_server_config(&auth), localhost())
        .expect("the quinn server binds");
    let server_addr = server.local_addr().expect("its address");
    let accepting = Peer::spawn({
        let server = server.clone();
        async move {
            // The server takes both attempts to their end: the refusal must come from the
            // client's certificate check, not from an attempt nobody answered. These awaits are
            // not bounded one by one; the guard that joins this task bounds it as a whole and
            // stops it if it ever fails to finish.
            for _ in 0..2 {
                let Some(incoming) = server.accept().await else {
                    return;
                };
                let _ = incoming.await;
            }
        }
    });

    let client = step(
        "rama binds",
        Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
    )
    .await
    .expect("the client binds");
    let refused = step(
        "the refused attempt",
        client
            .connect_with(rama_client_config(wrong_anchor), server_addr, "localhost")
            .expect("the attempt starts"),
    )
    .await
    .expect_err("a server it does not trust must not get a connection");
    let ConnectionError::TransportError(ref error) = refused else {
        panic!("the attempt ended on a transport error: {refused:?}");
    };
    assert_eq!(
        error.code().tls_alert(),
        Some(u8::from(AlertDescription::UnknownCA)),
        "the alert says the issuer is not one it trusts: {}",
        error.reason()
    );
    #[cfg(feature = "boring")]
    interop_common::backend::assert_certificate_failure(error);
    #[cfg(not(feature = "boring"))]
    assert!(
        error
            .cause()
            .and_then(|cause| cause.downcast_ref::<rustls::Error>())
            .is_some_and(|error| matches!(
                error,
                rustls::Error::InvalidCertificate(CertificateError::UnknownIssuer)
            )),
        "and the cause is the issuer, not something else: {:?}",
        error.cause()
    );
    let frame: Option<FrameType> = error.frame_type();
    assert_eq!(frame, None, "a certificate refusal names no frame");

    // The control: the same client, the same server, the right anchor.
    let accepted = step(
        "the trusted attempt",
        client
            .connect_with(rama_client_config(anchor), server_addr, "localhost")
            .expect("the attempt starts"),
    )
    .await
    .expect("the identity it trusts is accepted");
    accepted.close(0u32, b"done");

    step("rama's shutdown", client.wait_idle()).await;
    server.close(0u32.into(), b"done");
    step("the quinn server goes idle", server.wait_idle()).await;
    accepting.join("the quinn peer").await;
}

/// The same in the other direction: Quinn's client refuses the Rama server it does not trust, and
/// accepts it with the right anchor.
#[tokio::test]
async fn a_quinn_client_refuses_a_rama_server_it_does_not_trust() {
    let auth = identity();
    let anchor = auth.cert_chain.last().expect("a chain").clone();
    let stranger = identity_from_a_stranger("Someone Else Entirely");
    let wrong_anchor = stranger.cert_chain.last().expect("a chain").clone();

    let server = step(
        "the rama server binds",
        Endpoint::bind_server(
            rama::rt::Executor::new(),
            rama_server_config(&auth),
            localhost(),
        ),
    )
    .await
    .expect("it binds");
    let server_addr = server.local_addr().expect("its address");
    let accepting = Peer::spawn({
        let server = server.clone();
        async move {
            // As above: the guard bounds this task as a whole.
            for _ in 0..2 {
                let Some(incoming) = server.accept().await else {
                    return;
                };
                match incoming.accept() {
                    Ok(connecting) => {
                        let _ = connecting.await;
                    }
                    Err(_) => return,
                }
            }
        }
    });

    let mut client = quinn::Endpoint::client(localhost()).expect("quinn binds");
    client.set_default_client_config(quinn_client_config(wrong_anchor));
    let refused = step(
        "the refused attempt",
        client
            .connect(server_addr, "localhost")
            .expect("the attempt starts"),
    )
    .await
    .expect_err("a server it does not trust must not get a connection");
    // The peer's own error type, so this reads quinn's code rather than Rama's.
    let quinn::ConnectionError::TransportError(ref error) = refused else {
        panic!("the attempt ended on a transport error: {refused:?}");
    };
    assert_eq!(
        u64::from(error.code),
        0x100 | u64::from(u8::from(AlertDescription::UnknownCA)),
        "and on the alert for an issuer it does not trust: {}",
        error.reason
    );

    client.set_default_client_config(quinn_client_config(anchor));
    let accepted = step(
        "the trusted attempt",
        client
            .connect(server_addr, "localhost")
            .expect("the attempt starts"),
    )
    .await
    .expect("the identity it trusts is accepted");
    accepted.close(0u32.into(), b"done");

    step("quinn's shutdown", client.wait_idle()).await;
    accepting.join("the rama peer").await;
    step("rama's shutdown", server.shutdown()).await;
}

/// The guard stops a peer that never finishes. Its wait keeps the handle, so the timeout can
/// abort the task; the task's own drop is observed here.
#[tokio::test]
async fn a_peer_that_never_finishes_is_stopped() {
    let stopped = Arc::new(std::sync::atomic::AtomicBool::new(false));
    struct Guard(Arc<std::sync::atomic::AtomicBool>);
    impl Drop for Guard {
        fn drop(&mut self) {
            self.0.store(true, std::sync::atomic::Ordering::SeqCst);
        }
    }

    let peer = Peer::spawn({
        let stopped = stopped.clone();
        async move {
            let _guard = Guard(stopped);
            std::future::pending::<()>().await;
        }
    });
    let mut peer = peer;
    let outcome = peer.try_join_within(Duration::from_millis(200)).await;
    assert!(
        outcome.is_err_and(|reason| reason.contains("not within")),
        "the wait ends by timing out"
    );
    assert!(
        stopped.load(std::sync::atomic::Ordering::SeqCst),
        "and the task it was waiting for is stopped, not detached"
    );
}
