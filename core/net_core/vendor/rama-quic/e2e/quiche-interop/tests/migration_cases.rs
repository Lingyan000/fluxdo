//! The shared migration cases, run against quiche in both roles.
//!
//! quiche issues connection identifiers only when the application asks it to, which is what
//! lets the case that withholds one be run here at all, and it can be configured to forbid
//! active migration. Where the datagrams came from is its own observation.

mod common;

use common::{
    Identity, Quiche, quiche_client_config_that_moves, quiche_server_config,
    quiche_server_config_without_migration,
};
use std::{net::SocketAddr, time::Duration};

use interop_common::{
    CloseObservation, MigrationObservation, MigrationScenario, Received, RefusedMove, Role,
    Unsupported, for_each_case,
    migration::{CLOSED_WITH, migration_cases, rama_client_side, rama_server_side},
    registry::CaseRun,
    scenario::SERVER_NAME,
    support::Peer,
};
use rama::utils::octets;

const PEER: &str = "quiche";
const READ_CAP: usize = octets::mib(1);
const CLIENT_BI: u64 = 0;
/// The next bidirectional stream a client opens.
const NEXT_BI: u64 = 4;
/// Observe traffic on the moved socket for this long before returning to the original one.
const SILENCE: Duration = Duration::from_millis(500);
/// Why the case that withholds an identifier does not run in the rama-server role.
const RAMA_ISSUES_ITS_OWN: &str = "rama issues its own connection identifiers, so this side cannot withhold the one the peer \
     would move with";

/// Rama's client moves, or is kept where it is, and quiche says where it saw the datagrams.
#[tokio::test]
async fn migration_cases_rama_client() {
    for_each_case(
        PEER,
        Role::RamaClient,
        migration_cases(),
        |run| async move {
            let served = Identity::generate(SERVER_NAME);
            let run = run.with_identity(served.auth.clone());
            let config = if run.scenario.migration_allowed {
                quiche_server_config(&served)
            } else {
                quiche_server_config_without_migration(&served)
            };
            let (addr, accepting) = Quiche::bind_server(config, run.deadline).await;
            let observing = Peer::spawn({
                let run = run.clone();
                async move {
                    let mut server = accepting.await;
                    server
                        .drive_until(&run.what, run.deadline, |connection| {
                            connection.is_established()
                        })
                        .await;
                    if run.scenario.spare_identifier {
                        server.offer_another_identifier(0x77, run.deadline).await;
                    }
                    let mut seen = Vec::new();
                    for (stream, payload) in [
                        (CLIENT_BI, run.scenario.before),
                        (NEXT_BI, run.scenario.after),
                    ] {
                        let got = server.read_stream(stream, READ_CAP, run.deadline).await;
                        Received::Bytes(got.clone()).check(&run.what, "exchange", payload);
                        server.write_stream(stream, &got, run.deadline).await;
                        seen.push(server.last_seen_from().expect("a datagram arrived"));
                    }
                    server
                        .drive_until(&run.what, run.deadline, |connection| connection.is_closed())
                        .await;
                    let ended = server
                        .connection()
                        .peer_error()
                        .expect("the peer stated why it stopped")
                        .clone();
                    (
                        MigrationObservation {
                            from_before: seen[0],
                            from_after: seen[1],
                        },
                        CloseObservation {
                            code: ended.error_code,
                            reason: ended.reason.clone(),
                            application: ended.is_app,
                            // `peer_error` is the peer's, which `local_error` is not.
                            received: Some(true),
                        },
                    )
                }
            });

            let bound = rama_client_side(&run, addr).await;
            let (observed, closed) = observing.join(&run.what, run.deadline).await;
            observed.check(&run.what, &run.scenario, bound);
            let (code, reason) = CLOSED_WITH;
            closed.says(&run.what, u64::from(code), reason);
        },
    )
    .await;
}

/// A quiche client moves under Rama's server, which either follows it or does not.
///
/// Two of the three cases run here. Withholding an identifier is not this side's to do: Rama
/// issues its own, so that one is recorded rather than skipped. Forbidding a move is Rama's
/// (`ServerConfig::with_migration`), and quiche never reads that policy, so the forbidden
/// case is a client that moves against it.
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
            let served = Identity::generate(SERVER_NAME);
            let run = run.with_identity(served.auth.clone());
            let (endpoint, addr, serving) = rama_server_side(&run).await;
            let mut client = Quiche::connect(
                addr,
                SERVER_NAME,
                quiche_client_config_that_moves(&served),
                run.deadline,
            )
            .await;
            client
                .drive_until(&run.what, run.deadline, |connection| {
                    connection.is_established()
                })
                .await;
            // A move needs spare identifiers on both sides. Rama issues its own; quiche leaves
            // this side's to the application, and wants two: one to keep the current path and one
            // for the path being validated.
            for tag in [0x88, 0x89] {
                client.offer_another_identifier(tag, run.deadline).await;
            }
            let first = client.local_address();
            client
                .write_stream(CLIENT_BI, &run.scenario.before.bytes(), run.deadline)
                .await;
            let back = client.read_stream(CLIENT_BI, READ_CAP, run.deadline).await;
            Received::Bytes(back).check(&run.what, "exchange", run.scenario.before);

            let second = client.move_to_a_new_socket(run.deadline).await;
            assert_ne!(
                first, second,
                "{}: the client is on another socket",
                run.what
            );
            client
                .write_stream(NEXT_BI, &run.scenario.after.bytes(), run.deadline)
                .await;
            if !run.scenario.migration_allowed {
                refused_at_the_new_address(&run, &mut client, first, second).await;
            }
            let back = client.read_stream(NEXT_BI, READ_CAP, run.deadline).await;
            Received::Bytes(back).check(&run.what, "exchange", run.scenario.after);
            client.close(run.deadline).await;

            let (observed, closed) = serving.join(&run.what, run.deadline).await;
            observed.check(&run.what, &run.scenario, (first, second));
            let (code, reason) = CLOSED_WITH;
            closed.says(&run.what, u64::from(code), reason);
            run.deadline.wait(&run.what, endpoint.wait_idle()).await;
        },
    )
    .await;
}

/// Observe the moved socket over [`SILENCE`], then return the connection to the socket the
/// server knows. The exchange the client was holding is answered after the return.
async fn refused_at_the_new_address(
    run: &CaseRun<MigrationScenario>,
    client: &mut Quiche,
    first: SocketAddr,
    second: SocketAddr,
) {
    let stopped = client.quiet_for(SILENCE, run.deadline).await;
    assert!(
        stopped.is_none(),
        "{}: the connection stopped while its move went unanswered ({stopped:?})",
        run.what
    );
    let moved = client.path_from(second);
    RefusedMove {
        sent: moved.sent,
        received: moved.recv,
    }
    .check(&run.what, &run.scenario);
    assert_eq!(
        client.move_back(run.deadline).await,
        first,
        "{}: the client returns to the path the server knows",
        run.what
    );
}
