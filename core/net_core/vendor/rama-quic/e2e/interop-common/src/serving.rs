//! The Rama server a peer's client connects to, in whichever family the case belongs to.
//!
//! Every peer-client case wants the same thing of this side: serve the identity the case gives
//! it, answer one probe where a connection is expected, and report what it made of the attempt
//! instead of swallowing it.

use std::net::SocketAddr;

use rama::quic::Endpoint;

use crate::{
    identity::rama_server_config,
    registry::CaseRun,
    scenario::{Chunk, Received},
    support::{Deadline, Peer, localhost},
};

/// What Rama's server made of the attempt against it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServerOutcome {
    /// The peer completed the handshake and its probe came back.
    Probed,
    /// No connection was established. A refused identity gives this, and so would an
    /// endpoint closed before any attempt arrived, so it is not on its own proof that an
    /// attempt was made.
    Refused,
    /// Nothing happened before the case ran out of time. Never what a case expects.
    TimedOut,
}

/// Rama's server for a peer-client case, serving whichever identity the case gives it. The
/// peer's client decides whether it accepts that identity.
///
/// The task returns what it saw rather than swallowing it, so a caller that joins it learns
/// both the outcome and any assertion that failed inside it.
pub async fn rama_probe_server<S>(
    run: &CaseRun<S>,
    probe: Chunk,
    expect_probe: bool,
) -> (Endpoint, SocketAddr, Peer<ServerOutcome>) {
    let CaseRun { what, deadline, .. } = run;
    let (what, deadline) = (what.clone(), *deadline);
    let server = deadline
        .wait(
            &what,
            Endpoint::bind_server(
                rama::rt::Executor::new(),
                rama_server_config(&run.identity),
                localhost(),
            ),
        )
        .await
        .expect("the rama server binds");
    let addr = server.local_addr().expect("its address");
    let serving = Peer::spawn({
        let server = server.clone();
        async move {
            // A refused identity may leave nothing to accept at all, so this waits for an
            // attempt without insisting on one. Running out of time is not a refusal and is
            // reported as itself.
            let attempt = match deadline.try_wait(server.accept()).await {
                Some(Some(attempt)) => attempt,
                Some(None) => return ServerOutcome::Refused,
                None => return ServerOutcome::TimedOut,
            };
            let conn = match deadline.try_wait(attempt).await {
                Some(Ok(conn)) => conn,
                Some(Err(_)) => return ServerOutcome::Refused,
                None => return ServerOutcome::TimedOut,
            };
            if !expect_probe {
                return ServerOutcome::Probed;
            }
            let (mut send, mut recv) = deadline
                .wait(&what, conn.accept_bi())
                .await
                .expect("the probe's stream arrives");
            let received = deadline
                .wait(&what, recv.read_to_end(probe.len + 1))
                .await
                .expect("the probe completes");
            Received::Bytes(received).check(&what, "probe", probe);
            deadline
                .wait(&what, send.write_all(&probe.bytes()))
                .await
                .expect("the probe goes back");
            send.finish().expect("the answer ends");
            deadline.wait(&what, conn.closed()).await;
            ServerOutcome::Probed
        }
    });
    (server, addr, serving)
}

/// Join a server task and require the outcome the case expects. A panic inside the task is
/// propagated rather than passed over.
pub async fn expect_outcome(
    serving: Peer<ServerOutcome>,
    what: &str,
    deadline: Deadline,
    expected: ServerOutcome,
) {
    let seen = serving.join(what, deadline).await;
    assert_eq!(seen, expected, "{what}: what the rama server made of it");
}
