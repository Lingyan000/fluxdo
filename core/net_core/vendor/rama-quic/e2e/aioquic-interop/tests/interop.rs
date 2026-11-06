//! Rama's QUIC transport against aioquic, both directions, through the public API only. The
//! peer is a separate interpreter with its own pinned environment, so the only thing the two
//! stacks share is the wire.

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
    quic::{ConnectionError, Endpoint, proto::VarInt},
    utils::octets,
};
use std::process::Stdio;

use tokio::process::Command;

// The baseline stream scenario in both roles moved to `baseline.rs`, where it runs from the
// shared `interop-common` definition; what remains here is aioquic-specific.

/// aioquic's client stops on the certificate check when Rama's server presents an identity it
/// has no anchor for, and the same client with the right anchor completes an exchange.
#[tokio::test]
async fn an_aioquic_client_refuses_a_rama_server_it_does_not_trust() {
    prepare().await;
    let deadline = Deadline::of(LIMIT);
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

    let sent = payload(0x51, octets::kib(4));
    let sent_hash = digest(&sent);

    let served = Task::spawn({
        let server = server.clone();
        async move {
            // The refused attempt must fail on this side too, rather than being an attempt the
            // server never saw.
            let told = refuse_one("the refused attempt", &server, deadline).await;
            assert!(
                told.contains("Close") || told.to_lowercase().contains("closed"),
                "the peer stated a reason for stopping: {told}"
            );

            let connection = accept_one("the trusted attempt", &server, deadline).await;
            let mut uni = deadline
                .wait("the uni stream arrives", connection.accept_uni())
                .await
                .expect("it opens");
            let received = deadline
                .wait("reading the uni stream", uni.read_to_end(STREAM_LIMIT))
                .await
                .expect("it completes");
            assert_eq!(
                digest(&received),
                sent_hash,
                "the uni payload arrived whole"
            );

            let (mut send, mut recv) = deadline
                .wait("the bi stream arrives", connection.accept_bi())
                .await
                .expect("it opens");
            let asked = deadline
                .wait("reading the question", recv.read_to_end(STREAM_LIMIT))
                .await
                .expect("it completes");
            assert_eq!(digest(&asked), sent_hash, "the question arrived whole");
            deadline
                .wait("answering", send.write_all(&asked))
                .await
                .expect("the answer is written");
            send.finish().expect("the answer ends");
            deadline
                .wait("the connection ends", connection.closed())
                .await;
        }
    });

    let arguments = |anchor: &Identity, port: String, length: String| {
        vec![
            "--port".to_owned(),
            port,
            "--ca".to_owned(),
            anchor.certificate().to_owned(),
            "--seed".to_owned(),
            "81".to_owned(),
            "--length".to_owned(),
            length,
        ]
    };
    let port = server_addr.port().to_string();
    let length = sent.len().to_string();

    let held = arguments(&stranger, port.clone(), length.clone());
    let mut refused = AioQuic::spawn(
        "client",
        &held.iter().map(String::as_str).collect::<Vec<_>>(),
    )
    .await;
    // aioquic's own exception says only that the connection failed, so what the refusal was is
    // read from the close it sent. This is the peer's choice of alert, not Rama's, so the test
    // accepts any a certificate check ends on rather than pinning one.
    let ended = refused.expect("ended", deadline).await;
    let code = ended.code();
    assert!(
        CERTIFICATE_ALERTS.contains(&code),
        "the close carries a certificate alert: {code:#x} ({})",
        ended.reason()
    );
    refused.expect("failed", deadline).await;
    refused.failed(deadline).await;

    let held = arguments(&identity, port, length);
    let mut accepted = AioQuic::spawn(
        "client",
        &held.iter().map(String::as_str).collect::<Vec<_>>(),
    )
    .await;
    accepted.expect("handshake", deadline).await;
    accepted.expect("connected", deadline).await;
    let echoed = accepted.expect("stream", deadline).await;
    assert_eq!(echoed.len(), sent.len(), "the peer read the whole answer");
    assert_eq!(
        echoed.sha256(),
        hex(&sent_hash),
        "and the bytes are the ones it sent"
    );
    accepted.expect("ended", deadline).await;
    accepted.expect("done", deadline).await;
    accepted.finished(deadline).await;
    served.join("the rama peer", deadline).await;
}

/// The reciprocal: Rama's client refuses an aioquic server whose identity it does not trust,
/// and the same client with the right anchor connects and carries a payload.
#[tokio::test]
async fn a_rama_client_refuses_an_aioquic_server_it_does_not_trust() {
    prepare().await;
    let deadline = Deadline::of(LIMIT);
    let identity = Identity::generate("localhost");
    let stranger = Identity::generate_from_a_stranger("localhost", "Someone Else Entirely");
    let mut peer = AioQuic::spawn(
        "server",
        &[
            "--cert",
            identity.certificate(),
            "--key",
            identity.key(),
            // The refused attempt and the trusted one that follows it.
            "--connections",
            "2",
        ],
    )
    .await;
    let server_addr = peer.listening(deadline).await;

    let echo = payload(0x61, octets::kib(2));
    let echo_hash = digest(&echo);

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

    // What reached the peer is the close itself: one of the alerts a certificate check ends on,
    // so a timeout, an idle expiry or an unrelated negotiation failure does not pass.
    let ended = peer.expect("ended", deadline).await;
    let code = ended.code();
    assert!(
        CERTIFICATE_ALERTS.contains(&code),
        "the close carries a certificate alert: {code:#x} ({})",
        ended.reason()
    );

    // The same client, the same server, the right anchor: an exchange, read back before the
    // close, which discards whatever is still unacknowledged.
    let connection = deadline
        .wait(
            "the trusted attempt",
            client
                .connect_with(rama_client_config(&identity), server_addr, "localhost")
                .expect("the attempt starts"),
        )
        .await
        .expect("the identity it trusts is accepted");
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
        .wait("the echo", recv.read_to_end(STREAM_LIMIT))
        .await
        .expect("it completes");
    assert_eq!(digest(&heard), echo_hash, "the payload came back whole");

    peer.expect("handshake", deadline).await;
    let stream = peer.expect("stream", deadline).await;
    assert_eq!(
        stream.sha256(),
        hex(&echo_hash),
        "the peer read what was sent"
    );

    connection.close(0u32, b"done");
    deadline.wait("rama's shutdown", client.wait_idle()).await;
    peer.expect("ended", deadline).await;
    peer.finished(deadline).await;
}

/// A peer that binds a socket, says so, and then answers nothing. The attempt against it must
/// end inside the scenario's own bound, and the peer's socket must be gone once the guard that
/// owns the process has dropped.
#[tokio::test]
async fn a_peer_that_never_finishes_is_stopped() {
    prepare().await;
    let deadline = Deadline::of(Duration::from_secs(5));
    let mut peer = AioQuic::spawn("silent", &[]).await;
    // The port is the peer's acknowledgment that it started and owns the socket.
    let addr = peer.listening(deadline).await;
    assert!(
        !port_is_free(addr.port()),
        "the peer holds the port it named"
    );

    let client = deadline
        .wait(
            "rama binds",
            Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
        )
        .await
        .expect("the client binds");
    let attempt = client
        .connect_with(
            rama_client_config(&Identity::generate("localhost")),
            addr,
            "localhost",
        )
        .expect("the attempt starts");
    assert!(
        deadline.try_wait(attempt).await.is_none(),
        "an attempt against a peer that answers nothing must not resolve"
    );

    drop(peer);
    assert!(
        within(Duration::from_secs(5), || port_is_free(addr.port())).await,
        "the peer's socket is gone once its guard has dropped"
    );
    client.close(0u32, b"done");
}

/// A wait on a task that is itself cancelled leaves the task owned by its guard, and dropping
/// the guard unwinds the task rather than detaching it.
#[tokio::test]
async fn a_cancelled_wait_leaves_the_task_owned() {
    let unwound = Arc::new(AtomicBool::new(false));
    let mut task = Task::spawn({
        let marks = Marks(Arc::clone(&unwound));
        async move {
            let _held = marks;
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

/// A controlled child that writes its own process identifier and then sleeps. It runs on the
/// pinned interpreter and takes the path as an argument, so no shell quoting is involved.
#[cfg(unix)]
fn a_child_that_sleeps(pid_file: &std::path::Path) -> Command {
    let mut command = Command::new(python());
    command
        .arg("-c")
        .arg(
            "import os, sys, time\n\
             open(sys.argv[1], 'w').write(str(os.getpid()))\n\
             time.sleep(600)\n",
        )
        .arg(pid_file)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    command
}

/// Drive a run in progress until its child says it started by writing its process identifier,
/// within a bound of its own. A run that ends first is a child that never started.
#[cfg(unix)]
async fn acknowledged(
    running: &mut (impl Future<Output = Result<Finished, String>> + Unpin),
    pid_file: &std::path::Path,
) -> String {
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            tokio::select! {
                outcome = &mut *running => panic!("the child ended before it started: {outcome:?}"),
                () = tokio::time::sleep(Duration::from_millis(10)) => {
                    if pid_file.is_file() {
                        return read_pid(pid_file);
                    }
                }
            }
        }
    })
    .await
    .expect("the child acknowledges that it started")
}

/// The bounded runner that builds the peer's environment stops a child that overruns, and a
/// cancelled run leaves nothing behind either. Both are checked against a controlled child
/// whose process identifier the test looks for afterwards, and in each case the child is given
/// its own bounded chance to acknowledge that it started before anything is asked of it.
///
/// The check uses `kill -0`, so this test is for Unix hosts.
#[cfg(unix)]
#[tokio::test]
async fn a_setup_command_that_hangs_is_stopped_and_reaped() {
    use rama::utils::fs::tempdir;
    use tokio::time::Instant;

    prepare().await;
    let scratch = tempdir().expect("a directory of our own");

    let overran = scratch.path().join("overran.pid");
    let mut running = Box::pin(bounded_command(
        a_child_that_sleeps(&overran),
        Duration::from_secs(2),
    ));
    // The child's own acknowledgment first, with a bound of its own, so what the bound below
    // stops is a child known to be running rather than one assumed to have started.
    let overrunning = acknowledged(&mut running, &overran).await;
    let started = Instant::now();
    let outcome = running.await;
    assert!(
        outcome.is_err_and(|reason| reason.contains("did not finish")),
        "the run ends at its bound"
    );
    assert!(
        started.elapsed() < Duration::from_secs(20),
        "and at the bound, not whenever the child felt like it"
    );
    assert!(
        within(Duration::from_secs(5), || process_is_gone(&overrunning)).await,
        "the child it stopped is reaped"
    );

    let cancelled = scratch.path().join("cancelled.pid");
    // Boxed rather than pinned in place: dropping a `std::pin::pin!` binding drops the pointer,
    // not the future, so the child would outlive the cancellation this test is about.
    let mut running = Box::pin(bounded_command(
        a_child_that_sleeps(&cancelled),
        Duration::from_secs(600),
    ));
    let acknowledged = acknowledged(&mut running, &cancelled).await;

    drop(running);
    assert!(
        within(Duration::from_secs(5), || process_is_gone(&acknowledged)).await,
        "the child of a cancelled run is reaped too"
    );
}

/// A child that fills its pipe and then exits still finishes inside the bound, and what is kept
/// of its output is capped. Waiting for the exit before reading the pipe would deadlock here.
#[tokio::test]
async fn a_setup_command_that_writes_a_lot_still_finishes() {
    prepare().await;
    let written = octets::mib(1);
    let mut command = Command::new(python());
    command
        .arg("-c")
        .arg(format!("import sys; sys.stdout.write('x' * {written})"))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let finished = bounded_command(command, Duration::from_secs(20))
        .await
        .expect("a child that writes a lot and exits finishes");
    assert!(finished.status.success(), "it exited cleanly");
    assert_eq!(
        finished.stdout.len(),
        OUTPUT_LIMIT,
        "and what was kept of its output is capped"
    );
}

/// One line, and no more than its cap: the boundary in both directions, a cap crossed with the
/// newline in the same buffer, the same input arriving in pieces, and the end of a stream.
#[tokio::test]
async fn a_line_is_read_only_up_to_its_cap() {
    // Exactly the cap is a line.
    assert_eq!(
        read_one_line(b"1234\n", 4, 64).await.expect("it reads"),
        Some("1234".to_owned())
    );
    // One byte more is not, with the newline in the same buffer as the excess.
    assert!(
        read_one_line(b"12345\n", 4, 64).await.is_err(),
        "a line past its cap is refused even when its end is already in hand"
    );
    // The same input in one-byte pieces is refused at the same point.
    assert!(
        read_one_line(b"12345\n", 4, 1).await.is_err(),
        "and refused the same way when it arrives in pieces"
    );
    // A stream that ends without a newline still yields what it had.
    assert_eq!(
        read_one_line(b"1234", 4, 64).await.expect("it reads"),
        Some("1234".to_owned())
    );
    // An empty stream yields nothing at all.
    assert_eq!(read_one_line(b"", 4, 64).await.expect("it reads"), None);
    // Invalid UTF-8 is rendered lossily rather than failing.
    assert_eq!(
        read_one_line(b"a\xffb\n", 8, 64).await.expect("it reads"),
        Some("a\u{fffd}b".to_owned())
    );
}

/// A client that closes the instant its handshake future resolves. The close is then coalesced
/// into the Handshake and 1-RTT spaces, as RFC 9000 §10.2.3 asks of an endpoint closing before
/// the handshake is confirmed, and this peer acts on it: the code and the reason arrive
/// unchanged. Not every stack does; that is the peer's affair, and this is the control that
/// says Rama's datagram is one a peer can read.
#[tokio::test]
async fn a_close_right_after_the_handshake_reaches_the_peer() {
    prepare().await;
    let deadline = Deadline::of(LIMIT);
    let identity = Identity::generate("localhost");
    let mut peer = AioQuic::spawn(
        "server",
        &["--cert", identity.certificate(), "--key", identity.key()],
    )
    .await;
    let server_addr = peer.listening(deadline).await;

    let client = deadline
        .wait(
            "rama binds",
            Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
        )
        .await
        .expect("the client binds");
    let connection = deadline
        .wait(
            "the rama client connects",
            client
                .connect_with(rama_client_config(&identity), server_addr, "localhost")
                .expect("the attempt starts"),
        )
        .await
        .expect("the handshake completes");
    connection.close(VarInt::from(0x2au32), b"immediate");

    peer.expect("handshake", deadline).await;
    let ended = peer.expect("ended", deadline).await;
    assert_eq!(ended.code(), 0x2a, "the code the client gave");
    assert_eq!(ended.reason(), "immediate", "and its reason");

    deadline.wait("rama's shutdown", client.wait_idle()).await;
    peer.finished(deadline).await;
}
