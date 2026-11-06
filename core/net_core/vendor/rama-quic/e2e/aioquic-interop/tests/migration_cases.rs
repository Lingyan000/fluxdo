//! The shared migration cases, run against aioquic in both roles.
//!
//! Its client can move: `QuicConnectionProtocol` sends through the transport it holds, so the
//! child hands it a second datagram endpoint and routes what arrives there back into the same
//! connection. Its own path state describes the address it is sending *to*, so in that role it
//! holds no verdict on the tuple it moved from. As a server the path is the peer's, so there
//! its `is_validated` does refer to the client that moved.
//!
//! Neither role can withhold an identifier: aioquic issues its own and rama issues its own.
//! Its client does not read rama's `disable_active_migration` either, so the forbidden case
//! in the rama-server role is a client that moves against the policy and then returns. Its
//! server configuration cannot refuse a move, so that case is recorded in the rama-client
//! role rather than run.

mod common;

use common::*;
use interop_common::{
    CloseObservation, MigrationScenario, RefusedMove, Role, Unsupported, for_each_case_within,
    migration::{CLOSED_WITH, migration_cases, rama_client_side, rama_server_side},
    registry::CaseRun,
    scenario::SERVER_NAME,
};

const PEER: &str = "aioquic";
/// What nobody reports about the tuple aioquic's client moved to.
const NO_VALIDATION_VERDICT: &str = "no validation verdict for the moved tuple: this peer's path state is about the address \
     it sends to, and rama exposes none for the path it validated";
/// Why the case that withholds an identifier does not run in the rama-server role.
const RAMA_ISSUES_ITS_OWN: &str = "rama issues its own connection identifiers, so this side cannot withhold the one the peer \
     would move with";
/// Why neither of the two withholding cases runs in the rama-client role.
const NOTHING_TO_WITHHOLD: &str = "this peer issues its own connection identifiers and its server configuration cannot \
     refuse a move";

/// Rama's client moves under an aioquic server, which says where it saw the datagrams come
/// from and whether it validated the path they arrived on.
#[tokio::test]
async fn migration_cases_rama_client() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaClient,
        migration_cases(),
        LIMIT,
        |run| async move {
            if !run.scenario.moves {
                // Visible with `cargo test -- --nocapture`.
                println!(
                    "{}",
                    Unsupported {
                        case: withheld_case(&run),
                        peer: PEER,
                        reason: NOTHING_TO_WITHHOLD,
                    }
                );
                return;
            }
            let served = Identity::generate(SERVER_NAME);
            let run = run.with_identity(served.auth.clone());
            // Echoing is what the shared client-side exchange expects back.
            let mut peer = AioQuic::spawn(
                "server",
                &[
                    "--cert",
                    served.certificate(),
                    "--key",
                    served.key(),
                    "--connections",
                    "1",
                    "--report-paths",
                ],
            )
            .await;
            let addr = peer.listening(run.deadline).await;

            // The child reports as it goes and its lines wait to be read, so the exchange runs
            // first and what it saw is taken afterwards. What is checked here is where its
            // datagrams came from, not the payload: the shared scenario covers that.
            let (first, second) = rama_client_side(&run, addr).await;
            peer.expect("handshake", run.deadline).await;
            let mut seen = Vec::new();
            for _ in 0..2 {
                peer.expect("stream", run.deadline).await;
                seen.push(peer.expect("path", run.deadline).await);
            }
            closed_as_expected(&run.what, peer.expect("ended", run.deadline).await);
            peer.finished(run.deadline).await;
            assert_eq!(
                seen[0].endpoint(),
                same_endpoint(first),
                "{}: the peer saw the socket the connection was made on",
                run.what
            );
            assert_eq!(
                seen[1].endpoint(),
                same_endpoint(second),
                "{}: and afterwards the one it rebound to",
                run.what
            );
            assert!(
                seen[1].validated(),
                "{}: and it validated the path the client moved to",
                run.what
            );
        },
    )
    .await;
}

/// An aioquic client moves under Rama's server, which follows it.
#[tokio::test]
async fn migration_cases_rama_server() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaServer,
        migration_cases(),
        LIMIT,
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
            let (port, before_seed, before_len, after_seed, after_len) = (
                addr.port().to_string(),
                run.scenario.before.seed.to_string(),
                run.scenario.before.len.to_string(),
                run.scenario.after.seed.to_string(),
                run.scenario.after.len.to_string(),
            );
            let (close_code, close_reason) = (
                CLOSED_WITH.0.to_string(),
                String::from_utf8(CLOSED_WITH.1.to_vec()).expect("a reason that is text"),
            );
            let mut spawned = vec![
                "--ca",
                served.certificate(),
                "--close-code",
                &close_code,
                "--close-reason",
                &close_reason,
                "--port",
                &port,
                "--before-seed",
                &before_seed,
                "--before-length",
                &before_len,
                "--after-seed",
                &after_seed,
                "--after-length",
                &after_len,
            ];
            if !run.scenario.migration_allowed {
                spawned.push("--the-move-is-refused");
            }
            let mut peer = AioQuic::spawn("moving-client", &spawned).await;
            peer.expect("handshake", run.deadline).await;
            let first = peer.expect("address", run.deadline).await.endpoint();
            peer.expect("stream", run.deadline).await.reported().check(
                &run.what,
                "first exchange",
                run.scenario.before,
            );
            let second = peer.expect("address", run.deadline).await.endpoint();
            assert_ne!(
                first, second,
                "{}: the child moved to another endpoint",
                run.what
            );
            if !run.scenario.migration_allowed {
                let refused = peer.expect("refused", run.deadline).await;
                RefusedMove {
                    sent: refused.sent(),
                    received: refused.received(),
                }
                .check(&run.what, &run.scenario);
                assert_eq!(
                    peer.expect("address", run.deadline).await.endpoint(),
                    first,
                    "{}: the child returns to the path the server knows",
                    run.what
                );
            }
            peer.expect("stream", run.deadline).await.reported().check(
                &run.what,
                "second exchange",
                run.scenario.after,
            );

            // What this peer can say about the path it ends on: its path model is about the
            // address it is talking *to*, so moving its own socket creates no path there and
            // it holds no verdict on the tuple that moved. What it does say is that it is
            // still talking to rama's server, at the address rama bound.
            let path = peer.expect("path", run.deadline).await;
            assert!(
                path.validated(),
                "{}: the path it is talking to is validated",
                run.what
            );
            assert_eq!(
                path.endpoint(),
                same_endpoint(addr),
                "{}: and it is rama's server",
                run.what
            );
            // Visible with `cargo test -- --nocapture`.
            println!("{}: {NO_VALIDATION_VERDICT}", run.what);
            peer.expect("ended", run.deadline).await;
            peer.expect("done", run.deadline).await;
            peer.finished(run.deadline).await;

            // Both sides name the same two endpoints: the child binds each socket to the
            // address it sends from, and `endpoint` reads a v4-mapped spelling as the IPv4
            // address it maps.
            let (observed, closed) = serving.join(&run.what, run.deadline).await;
            observed.check(&run.what, &run.scenario, (first, second));
            let (code, reason) = CLOSED_WITH;
            closed.says(&run.what, u64::from(code), reason);
            run.deadline.wait(&run.what, endpoint.wait_idle()).await;
        },
    )
    .await;
}

/// The same move under a server that never acts on a PATH_RESPONSE. Its path is the client's,
/// it reports the client at the address it moved to, it carries both exchanges, and it
/// reports that path unvalidated. This is the control for the verdict the role above reads.
#[tokio::test]
async fn a_moved_path_is_unvalidated_while_its_responses_go_unheard() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaClient,
        migration_cases(),
        LIMIT,
        |run| async move {
            if !run.scenario.moves {
                return;
            }
            let served = Identity::generate(SERVER_NAME);
            let run = run.with_identity(served.auth.clone());
            let mut peer = AioQuic::spawn(
                "server",
                &[
                    "--cert",
                    served.certificate(),
                    "--key",
                    served.key(),
                    "--connections",
                    "1",
                    "--report-paths",
                    "--never-act-on-path-responses",
                    // Nothing will settle, so the report is taken after a short look rather
                    // than after the wait an ordinary case gives a challenge.
                    "--validation-wait",
                    "0.5",
                ],
            )
            .await;
            let addr = peer.listening(run.deadline).await;

            let (first, second) = rama_client_side(&run, addr).await;
            peer.expect("handshake", run.deadline).await;
            let mut seen = Vec::new();
            for exchange in [run.scenario.before, run.scenario.after] {
                peer.expect("stream", run.deadline)
                    .await
                    .reported()
                    .check(&run.what, "exchange", exchange);
                seen.push(peer.expect("path", run.deadline).await);
            }
            closed_as_expected(&run.what, peer.expect("ended", run.deadline).await);
            peer.finished(run.deadline).await;

            assert_eq!(
                seen[0].endpoint(),
                same_endpoint(first),
                "{}: the peer saw the socket the connection was made on",
                run.what
            );
            assert!(
                seen[0].validated(),
                "{}: original path reported unvalidated after the handshake",
                run.what
            );
            assert_eq!(
                seen[1].endpoint(),
                same_endpoint(second),
                "{}: and afterwards the one it rebound to",
                run.what
            );
            assert!(
                !seen[1].validated(),
                "{}: moved path reported validated while responses go unheard",
                run.what
            );
        },
    )
    .await;
}

/// Which of the two cases that hold something back this is.
fn withheld_case(run: &CaseRun<MigrationScenario>) -> &'static str {
    match run.scenario.spare_identifier {
        true => "migration-forbidden",
        false => "migration-without-an-identifier",
    }
}

/// What the child was told when Rama closed, against what every migration case closes with.
/// The category is the one the child read off the frame.
fn closed_as_expected(what: &str, ended: Event) {
    let (code, reason) = CLOSED_WITH;
    CloseObservation {
        code: ended.code(),
        reason: ended.reason().as_bytes().to_vec(),
        application: ended.application(),
        received: Some(ended.close_arrived()),
    }
    .says(what, u64::from(code), reason);
}
