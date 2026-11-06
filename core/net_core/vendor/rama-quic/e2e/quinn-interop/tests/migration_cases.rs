//! The shared migration cases, run against Quinn in both roles.
//!
//! Quinn's server can be told to forbid a move (`ServerConfig::migration`) and reports where a
//! connection is coming from, so those cases run. It issues connection identifiers itself,
//! with nothing in its configuration to withhold them, so the case that withholds one is
//! recorded rather than run as something else.
//!
//! Its client does not read the server's `disable_active_migration`, so the forbidden case in
//! the rama-server role is a client that moves against the policy. The socket it was made on
//! is held here as an `Arc<dyn AsyncUdpSocket>` and given back through `rebind_abstract`, so
//! that client can return to the path the server still holds.

mod common;

use std::{
    net::{Ipv4Addr, SocketAddr, UdpSocket},
    sync::Arc,
    time::Duration,
};

use common::{Counted, quinn_client_config, quinn_server_config};
use interop_common::{
    CloseObservation, MigrationObservation, MigrationScenario, Received, RefusedMove, Role,
    Unsupported, for_each_case,
    identity::anchor_of,
    migration::{CLOSED_WITH, migration_cases, rama_client_side, rama_server_side},
    registry::CaseRun,
    scenario::{Chunk, SERVER_NAME},
    support::{Deadline, Peer, localhost},
};
use rama::utils::octets;

const PEER: &str = "quinn";
const READ_CAP: usize = octets::mib(1);
/// Why the case that withholds an identifier does not run in the rama-server role.
const RAMA_ISSUES_ITS_OWN: &str = "rama issues its own connection identifiers, so this side cannot withhold the one the peer \
     would move with";
/// Observe traffic on the moved socket for this long before returning to the original one.
const SILENCE: Duration = Duration::from_millis(500);
/// Why the case that withholds an identifier does not run against this peer.
const ISSUES_ITS_OWN: &str = "quinn issues connection identifiers itself, with nothing in its configuration to withhold \
     them";

/// Rama's client moves, or is kept where it is, and Quinn says where it saw the connection.
#[tokio::test]
async fn migration_cases_rama_client() {
    for_each_case(
        PEER,
        Role::RamaClient,
        migration_cases(),
        |run| async move {
            if !runs_here(&run) {
                return;
            }
            let mut config = quinn_server_config(&run.identity);
            if !run.scenario.migration_allowed {
                config.migration(false);
            }
            let server =
                quinn::Endpoint::server(config, localhost()).expect("the quinn server binds");
            let addr = server.local_addr().expect("its address");
            let observing = Peer::spawn({
                let run = run.clone();
                let server = server.clone();
                async move {
                    let connection = run
                        .deadline
                        .wait(&run.what, server.accept())
                        .await
                        .expect("an attempt arrives")
                        .await
                        .expect("the handshake completes");
                    answer(&run.what, run.deadline, &connection, run.scenario.before).await;
                    let from_before = connection.remote_address();
                    answer(&run.what, run.deadline, &connection, run.scenario.after).await;
                    let from_after = seen_from(&run, &connection, from_before).await;
                    let ended = run.deadline.wait(&run.what, connection.closed()).await;
                    (
                        MigrationObservation {
                            from_before,
                            from_after,
                        },
                        quinn_told(&run.what, ended),
                    )
                }
            });

            let bound = rama_client_side(&run, addr).await;
            let (observed, closed) = observing.join(&run.what, run.deadline).await;
            observed.check(&run.what, &run.scenario, bound);
            let (code, reason) = CLOSED_WITH;
            closed.says(&run.what, u64::from(code), reason);
            server.close(0u32.into(), b"done");
            run.deadline.wait(&run.what, server.wait_idle()).await;
        },
    )
    .await;
}

/// A Quinn client moves under Rama's server, which follows it.
///
/// Two of the three cases run here. Withholding an identifier is not this side's to do: Rama
/// issues its own, so that case is recorded rather than run. Forbidding a move is Rama's
/// (`ServerConfig::with_migration`), and this client does not read that policy, so it moves
/// against it.
#[tokio::test]
async fn migration_cases_rama_server() {
    for_each_case(
        PEER,
        Role::RamaServer,
        migration_cases(),
        |run| async move {
            if !run.scenario.spare_identifier {
                // Visible with `cargo test -- --nocapture`.
                println!(
                    "{}",
                    Unsupported {
                        case: "migration-without-an-identifier",
                        peer: PEER,
                        reason: RAMA_ISSUES_ITS_OWN,
                    }
                );
                return;
            }
            let (endpoint, addr, serving) = rama_server_side(&run).await;
            // The socket the connection is made on is held here rather than left to
            // `Endpoint::client`, so the connection can be put back on it after a move.
            let runtime = quinn::default_runtime().expect("an async runtime");
            let original = runtime
                .wrap_udp_socket(bound_socket())
                .expect("the first socket is wrapped");
            let mut client = quinn::Endpoint::new_with_abstract_socket(
                quinn::EndpointConfig::default(),
                None,
                original.clone(),
                runtime.clone(),
            )
            .expect("the quinn client binds");
            client.set_default_client_config(quinn_client_config(anchor_of(&run.identity)));
            let first = client.local_addr().expect("its address");
            let connection = run
                .deadline
                .wait(
                    &run.what,
                    client
                        .connect(addr, SERVER_NAME)
                        .expect("the attempt starts"),
                )
                .await
                .expect("the handshake completes");
            exchange(&run.what, run.deadline, &connection, run.scenario.before).await;

            let moved = Counted::around(
                runtime
                    .wrap_udp_socket(bound_socket())
                    .expect("the second socket is wrapped"),
            );
            client
                .rebind_abstract(moved.clone())
                .expect("the endpoint rebinds");
            let second = client.local_addr().expect("its address");
            assert_ne!(
                first, second,
                "{}: the client is on another socket",
                run.what
            );
            if run.scenario.migration_allowed {
                exchange(&run.what, run.deadline, &connection, run.scenario.after).await;
            } else {
                refused_at_the_new_address(&run, &connection, &client, &original, &moved).await;
            }
            connection.close(0u32.into(), b"done");
            run.deadline.wait(&run.what, client.wait_idle()).await;

            let (observed, closed) = serving.join(&run.what, run.deadline).await;
            observed.check(&run.what, &run.scenario, (first, second));
            let (code, reason) = CLOSED_WITH;
            closed.says(&run.what, u64::from(code), reason);
            run.deadline.wait(&run.what, endpoint.wait_idle()).await;
        },
    )
    .await;
}

/// Whether this case can run against this peer at all, and the record when it cannot.
fn runs_here(run: &CaseRun<MigrationScenario>) -> bool {
    if !run.scenario.spare_identifier {
        // Visible with `cargo test -- --nocapture`.
        println!(
            "{}",
            Unsupported {
                case: "migration-without-an-identifier",
                peer: PEER,
                reason: ISSUES_ITS_OWN,
            }
        );
        return false;
    }
    true
}

/// Where the connection is coming from now, waited for where the case expects a move: the new
/// path counts once it has been validated, not the moment a datagram arrives on it.
async fn seen_from(
    run: &CaseRun<MigrationScenario>,
    connection: &quinn::Connection,
    before: SocketAddr,
) -> SocketAddr {
    if run.scenario.moves {
        run.deadline
            .wait(&run.what, async {
                while connection.remote_address() == before {
                    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
                }
            })
            .await;
    }
    connection.remote_address()
}

/// One exchange from the opening side.
async fn exchange(what: &str, deadline: Deadline, connection: &quinn::Connection, payload: Chunk) {
    let (mut send, mut recv) = deadline
        .wait(what, connection.open_bi())
        .await
        .expect("a bi stream");
    deadline
        .wait(what, send.write_all(&payload.bytes()))
        .await
        .expect("the payload is written");
    send.finish().expect("the stream ends");
    let back = deadline
        .wait(what, recv.read_to_end(READ_CAP))
        .await
        .expect("the answer completes");
    Received::Bytes(back).check(what, "exchange", payload);
}

/// The same exchange from the answering side.
async fn answer(what: &str, deadline: Deadline, connection: &quinn::Connection, payload: Chunk) {
    let (mut send, mut recv) = deadline
        .wait(what, connection.accept_bi())
        .await
        .expect("the stream arrives");
    let got = deadline
        .wait(what, recv.read_to_end(READ_CAP))
        .await
        .expect("it completes");
    Received::Bytes(got.clone()).check(what, "exchange", payload);
    deadline
        .wait(what, send.write_all(&got))
        .await
        .expect("the answer is written");
    send.finish().expect("the answer ends");
}

/// A loopback socket for this side to hold, ready for quinn's runtime to wrap.
fn bound_socket() -> UdpSocket {
    UdpSocket::bind(SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0)).expect("the socket binds")
}

/// Send the next exchange from the address the client moved to, observe that socket over
/// [`SILENCE`], then return to the socket the server knows and read the answer.
async fn refused_at_the_new_address(
    run: &CaseRun<MigrationScenario>,
    connection: &quinn::Connection,
    client: &quinn::Endpoint,
    original: &Arc<dyn quinn::AsyncUdpSocket>,
    moved: &Arc<Counted>,
) {
    let (mut send, mut recv) = run
        .deadline
        .wait(&run.what, connection.open_bi())
        .await
        .expect("a bi stream");
    run.deadline
        .wait(&run.what, send.write_all(&run.scenario.after.bytes()))
        .await
        .expect("the payload is written");
    send.finish().expect("the stream ends");
    tokio::time::sleep(SILENCE).await;

    RefusedMove {
        sent: moved.sent(),
        received: moved.received(),
    }
    .check(&run.what, &run.scenario);

    client
        .rebind_abstract(original.clone())
        .expect("the endpoint returns to the socket it was made on");
    let back = run
        .deadline
        .wait(&run.what, recv.read_to_end(READ_CAP))
        .await
        .expect("the answer completes once the client is back");
    Received::Bytes(back).check(&run.what, "exchange", run.scenario.after);
}

/// What Quinn's side was told when the other closed. The category comes from the variant
/// Quinn reports, not from this fixture.
fn quinn_told(what: &str, ended: quinn::ConnectionError) -> CloseObservation {
    let quinn::ConnectionError::ApplicationClosed(ref close) = ended else {
        panic!("{what}: close reported as a failure rather than an application close: {ended:?}");
    };
    CloseObservation {
        code: close.error_code.into_inner(),
        reason: close.reason.to_vec(),
        application: true,
        // Quinn reports `LocallyClosed` for a close of its own, so the variant
        // matched above establishes both the category and the origin.
        received: Some(true),
    }
}
