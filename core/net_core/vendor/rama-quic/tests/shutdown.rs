#![cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    reason = "an integration test's fixtures fail the test by panicking"
)]
//! What shutting an endpoint down promises about connections that are closing.

mod runtime;

use std::{
    net::{Ipv4Addr, SocketAddr},
    time::{Duration, Instant},
};

use rama_core::rt::{Executor, spawn};
use rama_quic::{ConnectionError, Endpoint, ShutdownOutcome};
use rama_quic_proto::VarInt;
use runtime::{Identities, connect, exchange};

fn localhost() -> SocketAddr {
    SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0)
}

/// The closing period after a close is three PTOs, which on loopback is at least the 75 ms
/// three advertised maximum ACK delays add up to (RFC 9000 §10.2). `wait_idle` gives a close
/// that whole period; `shutdown` leaves as soon as the close went out, and the peer still
/// receives it.
#[tokio::test]
async fn shutdown_leaves_once_the_close_went_out() {
    let identities = Identities::new();
    let server = Endpoint::build(Executor::new())
        .with_server_config(identities.server_config())
        .bind_address(localhost())
        .await
        .expect("the server binds");
    let addr = server.local_addr().unwrap();
    let serve = |server: Endpoint| async move {
        let connection = server
            .accept()
            .await
            .expect("an attempt arrives")
            .await
            .expect("the handshake completes");
        let (mut send, mut recv) = connection.accept_bi().await.expect("the stream arrives");
        let got = recv.read_to_end(1024).await.expect("it completes");
        send.write_all(&got).await.expect("the answer is written");
        send.finish().expect("the answer ends");
        connection.closed().await
    };

    // The control: a close given its whole closing period.
    let served = spawn(serve(server.clone()));
    let patient = Endpoint::build(Executor::new())
        .bind_address(localhost())
        .await
        .expect("the client binds");
    let connection = connect(&patient, &identities, addr).await;
    exchange(&connection, b"one round").await;
    connection.close(VarInt::from(8u32), b"patient");
    let started = Instant::now();
    tokio::time::timeout(Duration::from_secs(10), patient.wait_idle())
        .await
        .expect("the closing period ends");
    let whole_period = started.elapsed();
    assert!(
        whole_period >= Duration::from_millis(70),
        "the control waited out the closing period: {whole_period:?}"
    );
    patient.shutdown().await;
    expect_close(served, 8, b"patient").await;

    // The subject: a close, then a shutdown.
    let served = spawn(serve(server.clone()));
    let client = Endpoint::build(Executor::new())
        .bind_address(localhost())
        .await
        .expect("the client binds");
    let connection = connect(&client, &identities, addr).await;
    exchange(&connection, b"one round").await;
    connection.close(VarInt::from(9u32), b"leaving");
    let started = Instant::now();
    let outcome = tokio::time::timeout(Duration::from_secs(10), client.shutdown())
        .await
        .expect("the shutdown completes");
    let elapsed = started.elapsed();
    assert_eq!(
        outcome,
        ShutdownOutcome::Drained,
        "nothing had to be forced"
    );
    assert!(
        elapsed < Duration::from_millis(60),
        "the closing period was not waited out: {elapsed:?} against {whole_period:?}"
    );
    expect_close(served, 9, b"leaving").await;
    server.shutdown().await;
}

async fn expect_close(
    served: impl std::future::Future<Output = Result<ConnectionError, impl std::fmt::Debug>>,
    code: u32,
    reason: &[u8],
) {
    let got = tokio::time::timeout(Duration::from_secs(5), served)
        .await
        .expect("the server saw the connection end")
        .expect("the server task completes");
    match got {
        ConnectionError::ApplicationClosed(close) => {
            assert_eq!(close.error_code(), VarInt::from(code));
            assert_eq!(close.reason(), reason);
        }
        other => panic!("the peer received the close, not {other:?}"),
    }
}
