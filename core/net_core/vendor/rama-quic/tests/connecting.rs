#![cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "an integration test's fixtures fail the test by panicking"
)]
//! What a pending connection promises about its handshake metadata through the public API.

mod runtime;

use std::{
    future::Future,
    net::{Ipv4Addr, SocketAddr},
    pin::pin,
    task::{Context, Waker},
};

use rama_core::rt::Executor;
use rama_quic::Endpoint;
use runtime::Identities;

/// Waiting for handshake metadata is cancel-safe: a call given up while the handshake is still
/// in progress leaves the next call waiting for the same event, rather than answering at once
/// with metadata the session does not have yet.
#[tokio::test]
async fn waiting_for_handshake_data_survives_cancellation() {
    let identities = Identities::new();
    // A peer that never answers keeps the handshake in progress for as long as the test needs.
    let black_hole = tokio::net::UdpSocket::bind(SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0))
        .await
        .unwrap();
    let client = Endpoint::build(Executor::new())
        .bind_address(SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0))
        .await
        .expect("the client binds");
    let mut connecting = client
        .connect_with(
            identities.client_config(),
            black_hole.local_addr().unwrap(),
            "localhost",
        )
        .expect("the attempt starts");

    let mut cx = Context::from_waker(Waker::noop());
    {
        let mut first = pin!(connecting.handshake_data());
        assert!(
            first.as_mut().poll(&mut cx).is_pending(),
            "nothing has answered yet"
        );
    }
    {
        let mut second = pin!(connecting.handshake_data());
        assert!(
            second.as_mut().poll(&mut cx).is_pending(),
            "the second call waits like the first did, instead of failing on missing metadata"
        );
    }
    drop(connecting);
    client.shutdown().await;
}
