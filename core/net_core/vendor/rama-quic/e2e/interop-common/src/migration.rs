//! The shared migration cases: a connection whose client moves to another socket, and the two
//! shapes where it may not.
//!
//! What says a connection moved is where the peer saw the datagrams come from, not that a
//! rebind was called: the call only changes the socket the endpoint owns. Traffic crosses
//! before and after the move either way, so a case that does not move still has to work.

use std::net::SocketAddr;

use rama::{
    quic::{Connection, Endpoint},
    udp::UdpSocketConfig,
    utils::octets,
};

use crate::{
    close::{CloseObservation, told},
    identity::{anchor_of, rama_client_config, rama_server_config},
    registry::{Case, CaseRun},
    scenario::{Chunk, SERVER_NAME, answer, exchange},
    support::{Peer, localhost},
};

/// One migration case: what the peer offers the connection, and whether it may then move.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MigrationScenario {
    /// Whether the peer gives the connection a spare identifier to move with.
    pub spare_identifier: bool,
    /// Whether the peer allows a connection to move at all.
    pub migration_allowed: bool,
    /// Whether the connection is then expected to be seen coming from the new socket.
    pub moves: bool,
    /// The exchange before the move.
    pub before: Chunk,
    /// The exchange after it, which crosses whether or not the connection moved.
    pub after: Chunk,
}

/// Every migration case each eligible peer runs. A peer that cannot withhold an identifier or
/// forbid a move records those cases rather than running something else.
#[must_use]
pub fn migration_cases() -> Vec<Case<MigrationScenario>> {
    [
        ("migration-moves", true, true, true, 0xe1),
        ("migration-without-an-identifier", false, true, false, 0xe4),
        ("migration-forbidden", true, false, false, 0xe7),
    ]
    .into_iter()
    .map(
        |(name, spare_identifier, migration_allowed, moves, seed)| Case {
            name,
            scenario: MigrationScenario {
                spare_identifier,
                migration_allowed,
                moves,
                before: Chunk {
                    seed,
                    len: octets::kib(1),
                },
                after: Chunk {
                    seed: seed + 1,
                    len: octets::kib(1) + 17,
                },
            },
        },
    )
    .collect()
}

/// Where the peer saw a case's datagrams come from, either side of the move.
///
/// This is the address the peer is talking to, and nothing more: Rama answers it from
/// `self.path.remote`, which `migrate` swaps while the challenge on the new path is still
/// outstanding, and quiche answers it from the source tuple of the last datagram it read. So a
/// case here establishes that the traffic moved and kept working, not that the new path was
/// validated. Validation itself is not covered yet.
#[derive(Debug, Clone, Copy)]
pub struct MigrationObservation {
    pub from_before: SocketAddr,
    pub from_after: SocketAddr,
}

impl MigrationObservation {
    /// Check against where Rama's endpoint was bound at each point: a case that moves is seen
    /// coming from the new socket, and one that does not is still seen coming from the old.
    pub fn check(&self, what: &str, scenario: &MigrationScenario, bound: (SocketAddr, SocketAddr)) {
        let (first, second) = bound;
        assert_eq!(
            self.from_before, first,
            "{what}: the peer saw the socket the connection was made on"
        );
        if scenario.moves {
            assert_eq!(
                self.from_after, second,
                "{what}: and afterwards the one it rebound to"
            );
        } else {
            assert_eq!(
                self.from_after, first,
                "{what}: and afterwards the same one, since it could not move"
            );
        }
    }
}

/// What a client saw at the address it moved to, over the case's bounded observation.
///
/// The peer's policy is a transport parameter it advertises; a client that does not read it
/// moves anyway.
#[derive(Debug, Clone, Copy)]
pub struct RefusedMove {
    /// Packets the client put out from the address it moved to. Each adapter counts these
    /// where its own peer offers them, so this is submissions to a socket or transport
    /// rather than delivery confirmed on the wire.
    pub sent: usize,
    /// Packets the socket at that address delivered.
    pub received: usize,
}

impl RefusedMove {
    /// A move the peer did not answer: the client sent from the new address and nothing
    /// arrived there within the case's observation.
    ///
    /// # Panics
    /// If the case allows migration, or the client did not try, or anything came back.
    pub fn check(&self, what: &str, scenario: &MigrationScenario) {
        assert!(
            !scenario.migration_allowed,
            "{what}: case allows migration, so no refusal to observe"
        );
        assert!(
            self.sent > 0,
            "{what}: no packets sent from the address the client moved to"
        );
        assert_eq!(
            self.received, 0,
            "{what}: received packets on the forbidden path"
        );
    }
}

/// Rama's client for a migration case: an exchange, a rebind onto a socket of its own, and
/// another exchange. Answers where its endpoint was bound before and after the rebind.
pub async fn rama_client_side(
    run: &CaseRun<MigrationScenario>,
    addr: SocketAddr,
) -> (SocketAddr, SocketAddr) {
    let CaseRun {
        what,
        deadline,
        scenario,
        identity,
        ..
    } = run;
    let client = deadline
        .wait(
            what,
            Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
        )
        .await
        .expect("the rama client binds");
    let first = client.local_addr().expect("its address");
    let connection = deadline
        .wait(
            what,
            client
                .connect_with(rama_client_config(anchor_of(identity)), addr, SERVER_NAME)
                .expect("the attempt starts"),
        )
        .await
        .expect("the handshake completes");
    exchange(what, *deadline, &connection, scenario.before).await;

    deadline
        .wait(what, client.rebind(localhost(), UdpSocketConfig::new()))
        .await
        .expect("the endpoint rebinds");
    let second = client.local_addr().expect("its address");
    assert_ne!(first, second, "{what}: the endpoint is on another socket");

    // The application carries on across the rebind whether or not the connection moved.
    exchange(what, *deadline, &connection, scenario.after).await;
    let (code, reason) = CLOSED_WITH;
    connection.close(code, reason);
    deadline.wait(what, client.wait_idle()).await;
    (first, second)
}

/// The code and reason every migration case closes with, so a case can check the close it
/// was told about without carrying a close scenario of its own.
pub const CLOSED_WITH: (u32, &[u8]) = (0, b"done");

/// Rama's server for the other direction: it answers both exchanges and says where each came
/// from, so a peer that moves is seen to have moved, and what it was told when the peer
/// closed.
pub async fn rama_server_side(
    run: &CaseRun<MigrationScenario>,
) -> (
    Endpoint,
    SocketAddr,
    Peer<(MigrationObservation, CloseObservation)>,
) {
    let CaseRun { what, deadline, .. } = run;
    let (what, deadline, scenario) = (what.clone(), *deadline, run.scenario);
    // Rama's own server decides whether a peer may move: `ServerConfig::with_migration`.
    let config = rama_server_config(&run.identity).with_migration(scenario.migration_allowed);
    let server = deadline
        .wait(
            &what,
            Endpoint::bind_server(rama::rt::Executor::new(), config, localhost()),
        )
        .await
        .expect("the rama server binds");
    let addr = server.local_addr().expect("its address");
    let serving = Peer::spawn({
        let server = server.clone();
        async move {
            let connection = deadline
                .wait(&what, server.accept())
                .await
                .expect("an attempt arrives")
                .await
                .expect("the handshake completes");
            answer(&what, deadline, &connection, scenario.before).await;
            let from_before = connection.remote_address();
            answer(&what, deadline, &connection, scenario.after).await;
            let from_after = seen_from(&what, deadline, &connection, from_before, &scenario).await;
            let ended = deadline.wait(&what, connection.closed()).await;
            (
                MigrationObservation {
                    from_before,
                    from_after,
                },
                told(&what, ended),
            )
        }
    });
    (server, addr, serving)
}

/// Where the connection is coming from now. A case that expects a move waits for the address
/// to change rather than reading it the moment the second exchange is answered, since the
/// answer may go out before the peer's new address is the one in use.
async fn seen_from(
    what: &str,
    deadline: crate::support::Deadline,
    connection: &Connection,
    before: SocketAddr,
    scenario: &MigrationScenario,
) -> SocketAddr {
    if scenario.moves {
        deadline
            .wait(what, async {
                while connection.remote_address() == before {
                    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
                }
            })
            .await;
    }
    connection.remote_address()
}
