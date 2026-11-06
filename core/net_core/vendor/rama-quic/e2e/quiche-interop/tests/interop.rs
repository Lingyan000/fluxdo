//! Rama's QUIC transport against the upstream quiche stack, both directions, through the public
//! API only. quiche owns neither sockets nor timers, so its side of each test is driven by hand
//! against one deadline for the whole scenario.

mod common;

use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use common::*;
#[cfg(not(feature = "boring"))]
use rama::tls::rustls::dep::rustls::{self, CertificateError};
use rama::{
    quic::{ConnectionError, Endpoint},
    utils::octets,
};
use tokio::net::UdpSocket;

// The baseline stream scenario in both roles moved to `baseline.rs`, where it runs from the
// shared `interop-common` definition; what remains here is quiche-specific.

/// A quiche client that does not trust the Rama server's identity is refused by the certificate
/// check, which its own error names as a TLS alert. The same client with the right anchor gets a
/// connection and carries a payload over it.
#[tokio::test]
async fn a_quiche_client_refuses_a_rama_server_it_does_not_trust() {
    let deadline = Deadline::new();
    let identity = Identity::generate("localhost");
    let stranger = Identity::generate("localhost");
    let server = deadline
        .wait(
            "the rama server binds",
            Endpoint::bind_server(
                rama::rt::Executor::new(),
                rama_server_config(&identity),
                localhost(),
            ),
        )
        .await
        .expect("it binds");
    let server_addr = server.local_addr().expect("its address");

    let echo = payload(0x51, octets::kib(2));
    let echo_hash = digest(&echo);
    let accepting = Peer::spawn({
        let server = server.clone();
        async move {
            // Both attempts are taken to their end, so a refusal is the certificate check rather
            // than an attempt nobody answered. The first must fail its handshake; the second
            // must complete one and carry the payload back.
            let told = refuse_one("the refused attempt", &server, deadline).await;
            assert!(
                told.to_lowercase().contains("clos"),
                "the peer stated a reason for stopping: {told}"
            );

            let connection = accept_one("the trusted attempt", &server, deadline).await;
            let (mut send, mut recv) = deadline
                .wait("the bi stream arrives", connection.accept_bi())
                .await
                .expect("it opens");
            let received = deadline
                .wait("reading the payload", recv.read_to_end(octets::mib(1)))
                .await
                .expect("it completes");
            assert_eq!(digest(&received), echo_hash, "the payload arrived whole");
            deadline
                .wait("echoing it", send.write_all(&received))
                .await
                .expect("the echo is written");
            send.finish().expect("the echo ends");
            deadline
                .wait("the connection ends", connection.closed())
                .await;
        }
    });

    let mut refused = Quiche::connect(
        server_addr,
        "localhost",
        quiche_client_config(&stranger),
        deadline,
    )
    .await;
    // The refusal reaches the client as a failed handshake, so what stops the loop is asked for
    // rather than assumed: either the connection closes or the datagram carrying the rest of the
    // handshake is refused with the TLS failure.
    let stopped = refused
        .drive_or_stop("the untrusted attempt ends", deadline, |c| {
            c.is_closed() || c.is_established()
        })
        .await;
    match stopped {
        None | Some(Stopped::Closed) | Some(Stopped::Rejected(quiche::Error::TlsFail)) => {}
        Some(other) => panic!("the attempt ended for an unrelated reason: {other:?}"),
    }
    assert!(
        !refused.connection().is_established(),
        "a server it does not trust must not get a connection"
    );
    let alert = refused
        .ended_on_a_tls_alert()
        .expect("the refusal is a TLS alert, not a timeout or an unrelated close");
    assert_eq!(
        alert, 0x130,
        "the alert is unknown_ca (48), which is what a chain with no trusted anchor gives"
    );

    let mut accepted = Quiche::connect(
        server_addr,
        "localhost",
        quiche_client_config(&identity),
        deadline,
    )
    .await;
    accepted
        .drive_until("the trusted attempt", deadline, |c| c.is_established())
        .await;
    // An exchange rather than a one-way write: reading the payload back proves it arrived
    // before the close, which discards whatever is still unacknowledged.
    accepted.write_stream(0, &echo, deadline).await;
    let heard = accepted.read_stream(0, octets::mib(1), deadline).await;
    assert_eq!(digest(&heard), echo_hash, "the payload came back whole");
    accepted.close(deadline).await;

    accepting.join("the rama peer", deadline).await;
    deadline.wait("rama's shutdown", server.shutdown()).await;
}

/// A peer that never finishes is stopped by its guard rather than left running. It owns a
/// socket and says which one, so what is checked afterwards is the socket being gone and not
/// merely a handle being dropped.
#[tokio::test]
async fn a_peer_that_never_finishes_is_stopped() {
    let stopped = Arc::new(AtomicBool::new(false));
    struct Guard(Arc<AtomicBool>);
    impl Drop for Guard {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }

    let (says, port) = tokio::sync::oneshot::channel();
    let mut peer = Peer::spawn({
        let stopped = stopped.clone();
        async move {
            let _guard = Guard(stopped);
            let held = UdpSocket::bind(localhost())
                .await
                .expect("a socket of its own");
            says.send(held.local_addr().expect("its address").port())
                .expect("the test is listening");
            std::future::pending::<()>().await;
        }
    });
    let port = tokio::time::timeout(Duration::from_secs(5), port)
        .await
        .expect("the peer acknowledges its start")
        .expect("with the port it bound");
    assert!(!port_is_free(port), "the peer holds the port it named");

    let outcome = peer.try_join(Deadline::of(Duration::from_secs(2))).await;
    assert!(
        outcome.is_err_and(|reason| reason.contains("ran out")),
        "the wait ends by running out of time"
    );
    assert!(
        stopped.load(Ordering::SeqCst),
        "and the task it was waiting for is stopped, not detached"
    );
    assert!(
        within(Duration::from_secs(5), || port_is_free(port)).await,
        "so its socket is gone as well"
    );
}

/// A wait on a task that is itself cancelled leaves the task owned by its guard, and dropping
/// the guard unwinds the task rather than detaching it.
#[tokio::test]
async fn a_cancelled_wait_leaves_the_task_owned() {
    let unwound = Arc::new(AtomicBool::new(false));
    struct Guard(Arc<AtomicBool>);
    impl Drop for Guard {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }

    let mut task = Peer::spawn({
        let unwound = unwound.clone();
        async move {
            let _guard = Guard(unwound);
            std::future::pending::<()>().await;
        }
    });

    // A deadline far away, so what ends this wait is the cancellation and nothing else.
    let waiting = task.try_join(Deadline::of(Duration::from_secs(60)));
    assert!(
        tokio::time::timeout(Duration::from_millis(100), waiting)
            .await
            .is_err(),
        "the wait was cancelled rather than finishing"
    );
    assert!(
        task.owns_it(),
        "a cancelled wait leaves the task with its guard"
    );
    assert!(
        !unwound.load(Ordering::SeqCst),
        "and does not stop the task"
    );

    drop(task);
    assert!(
        within(Duration::from_secs(5), || unwound.load(Ordering::SeqCst)).await,
        "dropping the guard unwinds the task"
    );
}

/// The reciprocal: Rama's client refuses a quiche server whose identity it does not trust, and
/// the same client with the right anchor connects and carries a payload.
#[tokio::test]
async fn a_rama_client_refuses_a_quiche_server_it_does_not_trust() {
    let deadline = Deadline::new();
    let identity = Identity::generate("localhost");
    let stranger = Identity::generate_from_a_stranger("localhost", "Someone Else Entirely");
    let (server_addr, accepting) =
        Quiche::bind_server(quiche_server_config(&identity), deadline).await;
    // The same identity again, for the attempt that follows the refused one on the same socket.
    let second = quiche_server_config(&identity);

    let echo = payload(0x61, octets::kib(2));
    let echo_hash = digest(&echo);
    let peer = Peer::spawn(async move {
        // The refused attempt is answered to its end, so what stops it is the client's check of
        // the certificate rather than a server that never replied.
        let mut refused = accepting.await;
        let stopped = refused
            .drive_or_stop("the refused attempt ends", deadline, |c| {
                c.peer_error().is_some() || c.is_closed()
            })
            .await;
        match stopped {
            None | Some(Stopped::Closed) => {}
            Some(other) => panic!("the attempt ended for an unrelated reason: {other:?}"),
        }
        assert!(
            !refused.connection().is_established(),
            "the attempt the client refused must not have completed on this side either"
        );
        let alert = refused
            .ended_on_a_tls_alert()
            .expect("the client's close carries a TLS alert, not a timeout or another reason");
        // The stranger has an issuer of its own, so no anchor matches and the alert is
        // unknown_ca (48).
        assert_eq!(alert, 0x130, "the refusal is the issuer check");

        let mut server = Quiche::accept_on(refused.into_socket(), second, deadline).await;
        server
            .drive_until("the quiche server completes the handshake", deadline, |c| {
                c.is_established()
            })
            .await;
        let received = server.read_stream(0, octets::mib(1), deadline).await;
        assert_eq!(digest(&received), echo_hash, "the payload arrived whole");
        server.write_stream(0, &received, deadline).await;
        server
            .drive_until("the quiche server sees the connection end", deadline, |c| {
                c.is_closed()
            })
            .await;
    });

    let client = deadline
        .wait(
            "rama binds",
            Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
        )
        .await
        .expect("the client binds");
    let refused = deadline
        .wait(
            "the untrusted attempt",
            client
                .connect_with(rama_client_config(&stranger), server_addr, "localhost")
                .expect("the attempt starts"),
        )
        .await
        .expect_err("a server it does not trust must not get a connection");
    let ConnectionError::TransportError(ref error) = refused else {
        panic!("the attempt ended on a transport error: {refused:?}");
    };
    assert_eq!(
        error.code().tls_alert(),
        Some(interop_common::backend::UNKNOWN_CA),
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

    // The same client, the same server, the right anchor: a connection that carries a payload.
    let connection = deadline
        .wait(
            "the trusted attempt",
            client
                .connect_with(rama_client_config(&identity), server_addr, "localhost")
                .expect("the attempt starts"),
        )
        .await
        .expect("the identity it trusts is accepted");
    // An exchange rather than a one-way write: reading the payload back proves it arrived before
    // the close, which discards whatever is still unacknowledged.
    let (mut send, mut recv) = deadline
        .wait("a bi stream", connection.open_bi())
        .await
        .expect("it opens");
    deadline
        .wait("writing the payload", send.write_all(&echo))
        .await
        .expect("it is written");
    send.finish().expect("the stream ends");
    let heard = deadline
        .wait("the echo", recv.read_to_end(octets::mib(1)))
        .await
        .expect("it completes");
    assert_eq!(digest(&heard), echo_hash, "the payload came back whole");
    connection.close(0u32, b"done");

    deadline.wait("rama's shutdown", client.wait_idle()).await;
    peer.join("the quiche peer", deadline).await;
}
