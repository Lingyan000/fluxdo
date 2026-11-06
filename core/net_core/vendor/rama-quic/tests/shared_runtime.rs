#![cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "an integration test's fixtures fail the test by panicking; the workspace allows this inside test functions and this file is one, but its helpers are not #[test] themselves"
)]
//! An endpoint on an application's own runtime, through the public API alone.
//!
//! What these hold to is the ownership: the application's shutdown joins even while it still
//! holds an endpoint, because the endpoint keeps no strong guard, and a construction that
//! fails keeps nothing either.

mod runtime;

use std::assert_matches;
use std::{
    future::Future,
    net::{Ipv4Addr, SocketAddr},
    pin::pin,
    task::Poll,
    time::Duration,
};

use rama_core::{
    graceful::Shutdown,
    rt::{Executor, spawn},
};
use rama_quic::{Endpoint, EndpointBuilder, EndpointConfig, ShutdownOutcome};
use rama_udp::UdpSocketConfig;
use rama_utils::octets;

use runtime::{Identities, connect, exchange, serve_one};

/// Every wait here is bounded: a shutdown that does not join has to fail the test rather than
/// hang it.
const LIMIT: Duration = Duration::from_secs(20);
/// A hop limit the platform will keep, so the prepared socket can be asked for it back.
const TTL: u32 = 37;

fn localhost() -> SocketAddr {
    SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0)
}

/// A shutdown that fires when the returned sender is used, and nothing else fires it.
fn application() -> (Shutdown, tokio::sync::oneshot::Sender<()>) {
    let (tell, told) = tokio::sync::oneshot::channel::<()>();
    let shutdown = Shutdown::new(async move {
        drop(told.await);
    });
    (shutdown, tell)
}

/// Traffic on a shared runtime, and a shutdown that joins while the application still holds an
/// endpoint. The handle is deliberately alive across the join: if it kept a strong guard, this
/// would time out.
#[tokio::test]
async fn an_application_shutdown_joins_while_it_still_holds_an_endpoint() {
    let identities = Identities::new();
    let (shutdown, tell) = application();
    let server = Endpoint::build(Executor::graceful(shutdown.guard()))
        .with_server_config(identities.server_config())
        .bind_address(localhost())
        .await
        .expect("the server binds on the application's runtime");
    let addr = server.local_addr().unwrap();
    let client = Endpoint::build(Executor::graceful(shutdown.guard()))
        .bind_address(localhost())
        .await
        .expect("the client binds on the same runtime");

    let serving = spawn({
        let server = server.clone();
        async move { serve_one(&server).await }
    });
    let connection = connect(&client, &identities, addr).await;
    exchange(&connection, b"through a shared runtime").await;
    drop(connection);
    tokio::time::timeout(LIMIT, serving)
        .await
        .expect("the server finished its connection")
        .expect("the serving task did not panic");

    tell.send(()).unwrap();
    tokio::time::timeout(LIMIT, shutdown.shutdown())
        .await
        .expect("the application's shutdown joined while an endpoint was still held");
    // Held across the join on purpose, and still here afterwards.
    drop((server, client));
}

/// An accept waiting on nothing ends when the application shuts down, rather than holding the
/// join open.
#[tokio::test]
async fn a_pending_accept_ends_with_the_application() {
    let identities = Identities::new();
    let (shutdown, tell) = application();
    let server = Endpoint::build(Executor::graceful(shutdown.guard()))
        .with_server_config(identities.server_config())
        .bind_address(localhost())
        .await
        .expect("the server binds");

    // Polled here until it registers, so the shutdown below is what ends it rather than the
    // accept being first polled after cancellation.
    let mut accepting = pin!(server.accept());
    let first = std::future::poll_fn(|cx| Poll::Ready(accepting.as_mut().poll(cx))).await;
    assert!(
        first.is_pending(),
        "the accept is waiting on an attempt that has not come"
    );

    tell.send(()).unwrap();
    tokio::time::timeout(LIMIT, shutdown.shutdown())
        .await
        .expect("the shutdown joined");
    assert!(
        tokio::time::timeout(LIMIT, accepting)
            .await
            .expect("the accept ended")
            .is_none(),
        "a closed endpoint answers the accept it had already parked"
    );
}

/// A shutdown budget of zero on an endpoint with a live connection joins at once either way:
/// forced when a driver was still running as the budget ran out, or drained when the close the
/// shutdown gave the connection went out on that driver's next turn and let it leave first.
#[tokio::test]
async fn a_zero_budget_joins_a_live_endpoint_at_once() {
    let identities = Identities::new();
    let server = Endpoint::build(Executor::new())
        .with_server_config(identities.server_config())
        .with_shutdown_budget(Duration::ZERO)
        .bind_address(localhost())
        .await
        .expect("the server binds");
    let addr = server.local_addr().unwrap();
    let client = Endpoint::build(Executor::new())
        .bind_address(localhost())
        .await
        .expect("the client binds");

    let serving = spawn({
        let server = server.clone();
        async move { serve_one(&server).await }
    });
    let connection = connect(&client, &identities, addr).await;
    exchange(&connection, b"before the budget runs out").await;

    // The connection is up and its driver is running, so the join cannot already be ready
    // when a zero budget is checked.
    let outcome = tokio::time::timeout(LIMIT, server.shutdown())
        .await
        .expect("the shutdown joined");
    assert_matches!(
        outcome,
        ShutdownOutcome::Forced | ShutdownOutcome::Drained,
        "a zero budget waits for nothing: {outcome:?}",
    );
    drop(connection);
    // The server was forced mid-connection, so its task ends without finishing its work. What
    // is required of it is that it ends at all, and without panicking.
    tokio::time::timeout(LIMIT, serving)
        .await
        .expect("the serving task ended with the forced shutdown")
        .expect("it did not panic");
    tokio::time::timeout(LIMIT, client.shutdown())
        .await
        .expect("the client's own shutdown joined");
}

/// The same budget on an endpoint with nothing left to do may simply drain: zero is a shutdown
/// that does not wait, which is not the same as one that always forces.
#[tokio::test]
async fn a_zero_budget_on_an_idle_endpoint_may_drain() {
    let identities = Identities::new();
    let server = Endpoint::build(Executor::new())
        .with_server_config(identities.server_config())
        .with_shutdown_budget(Duration::ZERO)
        .bind_address(localhost())
        .await
        .expect("the server binds");
    let outcome = tokio::time::timeout(LIMIT, server.shutdown())
        .await
        .expect("the shutdown joined");
    assert_matches!(
        outcome,
        ShutdownOutcome::Drained | ShutdownOutcome::Forced,
        "either is correct for an endpoint with nothing to finish: {outcome:?}",
    );
}

/// A connection still carrying a stream when the application shuts down. The endpoints and the
/// connection are all held across the join, and the operations on it end rather than hanging.
#[tokio::test]
async fn an_active_connection_ends_with_the_application_that_holds_it() {
    let identities = Identities::new();
    let (shutdown, tell) = application();
    let server = Endpoint::build(Executor::graceful(shutdown.guard()))
        .with_server_config(identities.server_config())
        .bind_address(localhost())
        .await
        .expect("the server binds");
    let addr = server.local_addr().unwrap();
    let client = Endpoint::build(Executor::graceful(shutdown.guard()))
        .bind_address(localhost())
        .await
        .expect("the client binds");

    // The server says when it has the stream and its own read is outstanding, so the
    // shutdown below happens with a connection that is demonstrably active.
    let (reached, is_reached) = tokio::sync::oneshot::channel::<()>();
    let serving = spawn({
        let server = server.clone();
        async move {
            let connection = server
                .accept()
                .await
                .expect("an attempt arrives")
                .await
                .expect("the handshake completes");
            let (_send, mut recv) = connection.accept_bi().await.expect("the stream arrives");
            let mut reading = pin!(recv.read_to_end(octets::kib(1)));
            let first = std::future::poll_fn(|cx| Poll::Ready(reading.as_mut().poll(cx))).await;
            assert!(first.is_pending(), "the server's own read is outstanding");
            reached.send(()).expect("the case is listening");
            drop(reading.await);
            connection.closed().await;
        }
    });

    let connection = connect(&client, &identities, addr).await;
    let (mut send, mut recv) = connection.open_bi().await.expect("a bi stream");
    send.write_all(b"still open").await.expect("it is written");
    tokio::time::timeout(LIMIT, is_reached)
        .await
        .expect("the server reached its read")
        .expect("it said so");
    // Nothing will answer this: it is the pending operation held across the shutdown.
    let mut reading = pin!(recv.read_to_end(octets::kib(1)));
    let first = std::future::poll_fn(|cx| Poll::Ready(reading.as_mut().poll(cx))).await;
    assert!(first.is_pending(), "the read is waiting on an answer");

    tell.send(()).unwrap();
    tokio::time::timeout(LIMIT, shutdown.shutdown())
        .await
        .expect("the application's shutdown joined with a live connection held");
    assert!(
        tokio::time::timeout(LIMIT, reading)
            .await
            .expect("the pending read ended")
            .is_err(),
        "the read ends with the connection rather than hanging"
    );
    tokio::time::timeout(LIMIT, serving)
        .await
        .expect("the serving task ended with the application")
        .expect("it did not panic");
    // Held across the join on purpose.
    drop((connection, server, client));
}

/// A budget no clock can reach is refused at construction rather than panicking later, and the
/// guard it was given goes with the refusal.
#[tokio::test]
async fn an_unreachable_budget_is_refused_and_releases_the_guard() {
    let (shutdown, tell) = application();
    let refused = EndpointBuilder::new(Executor::graceful(shutdown.guard()))
        .with_config(EndpointConfig::new(
            rama_crypto::hmac::HmacSha2::try_rand_256().expect("random reset key"),
        ))
        .with_shutdown_budget(Duration::MAX)
        .bind_address(localhost())
        .await
        .expect_err("a budget beyond the clock is refused");
    assert!(
        refused.to_string().contains("shutdown budget"),
        "and it says which limit: {refused}"
    );

    tell.send(()).unwrap();
    tokio::time::timeout(LIMIT, shutdown.shutdown())
        .await
        .expect("the refused construction released the guard it was given");
}

/// The same for a socket that cannot be bound: nothing was built, so nothing is held.
#[tokio::test]
async fn a_failed_bind_releases_the_guard() {
    let (shutdown, tell) = application();
    // A port this process already owns, asked for exclusively.
    let taken = std::net::UdpSocket::bind(localhost()).unwrap();
    let occupied = taken.local_addr().unwrap();
    let mut options = rama_net::socket::SocketOptions::default_udp();
    #[cfg(all(
        target_family = "unix",
        not(any(target_os = "solaris", target_os = "illumos"))
    ))]
    {
        options.reuse_port = Some(false);
    }
    options.reuse_address = Some(false);
    let refused = Endpoint::build(Executor::graceful(shutdown.guard()))
        .bind_address_with_socket_config(
            occupied,
            UdpSocketConfig::default().with_socket_options(options),
        )
        .await;
    assert!(refused.is_err(), "the address is already in use");

    tell.send(()).unwrap();
    tokio::time::timeout(LIMIT, shutdown.shutdown())
        .await
        .expect("the failed bind released the guard it was given");
}

/// Without a graceful runtime there is no application shutdown to join, and the endpoint's own
/// shutdown is what stops it.
#[tokio::test]
async fn an_endpoint_without_a_graceful_runtime_shuts_itself_down() {
    let identities = Identities::new();
    let server = Endpoint::build(Executor::new())
        .with_server_config(identities.server_config())
        .bind_address(localhost())
        .await
        .expect("the server binds");
    let addr = server.local_addr().unwrap();
    let client = Endpoint::build(Executor::new())
        .bind_address(localhost())
        .await
        .expect("the client binds");

    let serving = spawn({
        let server = server.clone();
        async move { serve_one(&server).await }
    });
    let connection = connect(&client, &identities, addr).await;
    exchange(&connection, b"no graceful runtime here").await;
    drop(connection);
    tokio::time::timeout(LIMIT, serving)
        .await
        .expect("the server finished")
        .unwrap();

    tokio::time::timeout(LIMIT, server.shutdown())
        .await
        .expect("the endpoint's own shutdown joined");
    tokio::time::timeout(LIMIT, client.shutdown())
        .await
        .expect("and so did the client's");
}

/// A socket the caller prepared keeps the address and the options the caller put on it, and
/// the endpoint built on it carries data.
///
/// The option is set on the socket itself, which is where it belongs for an already-bound one:
/// a `UdpSocketConfig`'s options are applied when the factory binds, and wrapping only sets up
/// the packet metadata. What this checks is that taking the socket over leaves the caller's own
/// setting alone.
#[tokio::test]
async fn a_prepared_socket_keeps_what_the_caller_gave_it() {
    let identities = Identities::new();
    let bound = std::net::UdpSocket::bind(localhost()).unwrap();
    bound
        .set_ttl(TTL)
        .expect("the caller sets its own hop limit");
    let chosen = bound.local_addr().unwrap();
    // A second handle on the same socket, so the setting is read back from the socket the
    // endpoint took rather than from the value that was passed in.
    let same_socket = bound.try_clone().expect("a second handle on the socket");
    let prepared = UdpSocketConfig::default()
        .wrap_std(bound)
        .expect("the socket is wrapped");

    let server = Endpoint::build(Executor::new())
        .with_server_config(identities.server_config())
        .with_packet_socket(prepared)
        .expect("the server takes the prepared socket");
    assert_eq!(
        server.local_addr().unwrap(),
        chosen,
        "the endpoint is on the socket the caller bound"
    );
    assert_eq!(
        server.advertised_addrs(),
        Vec::<SocketAddr>::new(),
        "and advertises nothing it was not given"
    );
    assert_eq!(
        same_socket.ttl().expect("the socket reports its hop limit"),
        TTL,
        "taking the socket over left the caller's own setting alone"
    );

    let client = Endpoint::build(Executor::new())
        .bind_address(localhost())
        .await
        .expect("the client binds");
    let serving = spawn({
        let server = server.clone();
        async move { serve_one(&server).await }
    });
    let connection = connect(&client, &identities, chosen).await;
    exchange(&connection, b"on a prepared socket").await;
    drop(connection);
    tokio::time::timeout(LIMIT, serving)
        .await
        .expect("the server finished")
        .unwrap();
    tokio::join!(server.shutdown(), client.shutdown());
}
