#![cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "an integration test's fixtures fail the test by panicking"
)]
//! Serving an endpoint's connections with a service, and draining them on shutdown.

mod runtime;

use std::{
    convert::Infallible,
    net::{Ipv4Addr, SocketAddr},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use rama_core::{
    extensions::ExtensionsRef as _, graceful::Shutdown, rt::Executor, service::service_fn,
};
use rama_net::{address::SocketAddress, stream::SocketInfo};
use rama_quic::{Connection, ConnectionError, Endpoint};
use rama_quic_proto::{TransportErrorCode, VarInt};
use runtime::{Identities, connect, exchange};
use tokio::{
    sync::{Notify, mpsc, oneshot},
    time::timeout,
};

const DEADLINE: Duration = Duration::from_secs(10);

fn localhost() -> SocketAddr {
    SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0)
}

async fn server(identities: &Identities) -> Endpoint {
    Endpoint::build(Executor::new())
        .with_server_config(identities.server_config())
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

/// Echo one bidirectional stream, once `release` allows it, then wait for the peer to close.
async fn echo(connection: Connection, release: Arc<Notify>) -> Result<(), Infallible> {
    let Ok((mut send, mut recv)) = connection.accept_bi().await else {
        return Ok(());
    };
    let got = recv.read_to_end(1024).await.expect("the request completes");
    release.notified().await;
    send.write_all(&got).await.expect("the answer is written");
    send.finish().expect("the answer ends");
    _ = connection.closed().await;
    Ok(())
}

#[tokio::test]
async fn served_connections_carry_their_socket_info() {
    let identities = Identities::new();
    let server = server(&identities).await;
    let addr = server.local_addr().unwrap();
    let (tx, mut rx) = mpsc::unbounded_channel();
    let release = Arc::new(Notify::new());
    let service = service_fn({
        let release = release.clone();
        move |connection: Connection| {
            let info = connection
                .extensions()
                .get_ref::<SocketInfo>()
                .map(|info| info.address_pair());
            tx.send(info).unwrap();
            echo(connection, release.clone())
        }
    });
    let served = tokio::spawn(server.clone().serve(Executor::new(), service));

    let client = client().await;
    for payload in [b"first".as_slice(), b"second"] {
        let connection = connect(&client, &identities, addr).await;
        release.notify_one();
        timeout(DEADLINE, exchange(&connection, payload))
            .await
            .expect("the exchange completes");
        let addresses = rx
            .recv()
            .await
            .unwrap()
            .expect("the connection carries its socket info");
        assert_eq!(addresses.peer_address, client.local_addr().unwrap());
        assert_eq!(addresses.local_address, Some(SocketAddress::from(addr)));
        connection.close(VarInt::from(0u32), b"done");
    }

    server.close(VarInt::from(0u32), b"done");
    timeout(DEADLINE, served)
        .await
        .expect("serving ends once the endpoint closes")
        .unwrap();
    assert!(server.is_closed());
}

#[tokio::test]
async fn connections_after_a_rebind_carry_the_new_socket_address() {
    let identities = Identities::new();
    let server = server(&identities).await;
    let first = server.local_addr().unwrap();
    let (tx, mut rx) = mpsc::unbounded_channel();
    let release = Arc::new(Notify::new());
    let service = service_fn({
        let release = release.clone();
        move |connection: Connection| {
            let info = connection
                .extensions()
                .get_ref::<SocketInfo>()
                .map(|info| info.local_addr());
            tx.send(info).unwrap();
            echo(connection, release.clone())
        }
    });
    let served = tokio::spawn(server.clone().serve(Executor::new(), service));
    let client = client().await;

    // Serving is under way on the first socket before the endpoint moves.
    let mut rebound = None;
    for payload in [b"first".as_slice(), b"rebound"] {
        let addr = rebound.unwrap_or(first);
        let connection = connect(&client, &identities, addr).await;
        release.notify_one();
        timeout(DEADLINE, exchange(&connection, payload))
            .await
            .expect("the exchange completes");
        let local_addr = rx
            .recv()
            .await
            .unwrap()
            .expect("the connection carries its socket info");
        assert_eq!(local_addr, Some(SocketAddress::from(addr)));
        connection.close(VarInt::from(0u32), b"done");

        if rebound.is_none() {
            server
                .rebind_std_socket(std::net::UdpSocket::bind(localhost()).unwrap())
                .unwrap();
            let moved = server.local_addr().unwrap();
            assert_ne!(moved.port(), first.port());
            rebound = Some(moved);
        }
    }

    server.close(VarInt::from(0u32), b"done");
    timeout(DEADLINE, served).await.unwrap().unwrap();
}

#[tokio::test]
async fn a_failed_handshake_does_not_stop_serving() {
    let identities = Identities::new();
    let server = server(&identities).await;
    let addr = server.local_addr().unwrap();
    let release = Arc::new(Notify::new());
    let service = service_fn({
        let release = release.clone();
        move |connection: Connection| echo(connection, release.clone())
    });
    let served = tokio::spawn(server.clone().serve(Executor::new(), service));

    let client = client().await;
    let strangers = Identities::new();
    let refused = client
        .connect_with(strangers.client_config(), addr, runtime::SERVER_NAME)
        .unwrap()
        .await;
    assert!(refused.is_err(), "the untrusted handshake fails");

    let connection = connect(&client, &identities, addr).await;
    release.notify_one();
    timeout(DEADLINE, exchange(&connection, b"still served"))
        .await
        .expect("the exchange completes");
    connection.close(VarInt::from(0u32), b"done");

    server.close(VarInt::from(0u32), b"done");
    timeout(DEADLINE, served).await.unwrap().unwrap();
}

#[tokio::test]
async fn cancellation_refuses_new_attempts_and_drains_served_connections() {
    let identities = Identities::new();
    let server = server(&identities).await;
    let addr = server.local_addr().unwrap();
    let (signal, signalled) = oneshot::channel::<()>();
    let shutdown = Shutdown::new(async move {
        _ = signalled.await;
    });
    let exec = Executor::graceful(shutdown.guard());
    let release = Arc::new(Notify::new());
    let (accepted, mut accepted_rx) = mpsc::unbounded_channel();
    let service = service_fn({
        let release = release.clone();
        move |connection: Connection| {
            accepted.send(()).unwrap();
            echo(connection, release.clone())
        }
    });
    let served = tokio::spawn(server.clone().serve(exec, service));

    let client = client().await;
    let held = connect(&client, &identities, addr).await;
    let (mut send, mut recv) = held.open_bi().await.unwrap();
    send.write_all(b"in flight").await.unwrap();
    send.finish().unwrap();
    accepted_rx.recv().await.unwrap();

    signal.send(()).unwrap();
    let shutdown = tokio::spawn(shutdown.shutdown());

    // An attempt that raced the signal is served too; once it is seen, every one is refused.
    timeout(DEADLINE, async {
        loop {
            match client
                .connect_with(identities.client_config(), addr, runtime::SERVER_NAME)
                .unwrap()
                .await
            {
                Err(ConnectionError::ConnectionClosed(close))
                    if close.error_code == TransportErrorCode::CONNECTION_REFUSED =>
                {
                    break;
                }
                Ok(raced) => {
                    raced.close(VarInt::from(0u32), b"raced");
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
                Err(error) => panic!("unexpected attempt outcome: {error:?}"),
            }
        }
    })
    .await
    .expect("new attempts are refused");
    assert!(!served.is_finished(), "the held connection is still served");
    assert!(!server.is_closed());

    release.notify_waiters();
    release.notify_one();
    let answer = timeout(DEADLINE, recv.read_to_end(1024))
        .await
        .expect("the drained connection answers")
        .unwrap();
    assert_eq!(answer, b"in flight");
    held.close(VarInt::from(0u32), b"done");

    timeout(DEADLINE, served)
        .await
        .expect("serving ends once served connections ended")
        .unwrap();
    assert!(server.is_closed());
    timeout(DEADLINE, shutdown)
        .await
        .expect("the graceful shutdown completes")
        .unwrap();
}

/// A handshake the client stops answering has nothing to drain: a graceful shutdown refuses it,
/// as it refuses a new attempt, instead of waiting for the attempt to time out.
#[tokio::test]
async fn a_pending_handshake_is_refused_by_a_graceful_shutdown() {
    let identities = Identities::new();
    let server = server(&identities).await;
    let addr = server.local_addr().unwrap();
    let (signal, signalled) = oneshot::channel::<()>();
    let shutdown = Shutdown::new(async move {
        _ = signalled.await;
    });
    let exec = Executor::graceful(shutdown.guard());
    let release = Arc::new(Notify::new());
    let service = service_fn(move |connection: Connection| echo(connection, release.clone()));
    let served = tokio::spawn(server.clone().serve(exec, service));

    // Between client and server: the client's datagrams reach the server, but its answers are
    // withheld until `forward` is set, so the server's handshake stays in progress.
    let front = tokio::net::UdpSocket::bind(localhost()).await.unwrap();
    let back = tokio::net::UdpSocket::bind(localhost()).await.unwrap();
    let front_addr = front.local_addr().unwrap();
    let forward = Arc::new(AtomicBool::new(false));
    let (answered, mut answered_rx) = mpsc::unbounded_channel();
    let shim = tokio::spawn({
        let forward = forward.clone();
        async move {
            let mut from_client = vec![0; 65536];
            let mut from_server = vec![0; 65536];
            let mut client = None;
            loop {
                tokio::select! {
                    Ok((len, from)) = front.recv_from(&mut from_client) => {
                        client = Some(from);
                        _ = back.send_to(&from_client[..len], addr).await;
                    }
                    Ok((len, _)) = back.recv_from(&mut from_server) => {
                        _ = answered.send(());
                        if let Some(client) = client.filter(|_| forward.load(Ordering::SeqCst)) {
                            _ = front.send_to(&from_server[..len], client).await;
                        }
                    }
                }
            }
        }
    });
    let client = client().await;
    let attempt = tokio::spawn(
        client
            .connect_with(identities.client_config(), front_addr, runtime::SERVER_NAME)
            .unwrap(),
    );
    timeout(DEADLINE, answered_rx.recv())
        .await
        .expect("the server answers the attempt")
        .unwrap();

    forward.store(true, Ordering::SeqCst);
    signal.send(()).unwrap();
    timeout(Duration::from_secs(2), shutdown.shutdown())
        .await
        .expect("the shutdown does not wait for the handshake");
    let refused = timeout(DEADLINE, attempt)
        .await
        .expect("the client learns of the refusal")
        .unwrap();
    assert!(
        matches!(
            &refused,
            Err(ConnectionError::ConnectionClosed(close))
                if close.error_code == TransportErrorCode::CONNECTION_REFUSED
        ),
        "{refused:?}"
    );
    timeout(DEADLINE, served)
        .await
        .expect("serving ends")
        .unwrap();
    assert!(server.is_closed());
    shim.abort();
}
