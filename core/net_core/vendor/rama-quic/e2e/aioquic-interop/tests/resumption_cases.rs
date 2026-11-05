//! The shared resumption and 0-RTT cases, run against aioquic as the server.
//!
//! aioquic reports both verdicts in its handshake event, `session_resumed` and
//! `early_data_accepted`, so neither is inferred from the other. What it cannot be made to do
//! is resume a session and refuse the early data offered on it: a server there is built with
//! `max_early_data=MAX_EARLY_DATA` whatever the configuration says (`quic/connection.py`), and
//! it accepts early data whenever the offered ticket validates (`tls.py`). That case is
//! recorded as unsupported rather than run against something else.

mod common;

use common::*;
use interop_common::{
    Arrival, CloseObservation, Expected, Reported, ResumptionObservation, ResumptionScenario, Role,
    Unsupported, Verdict, for_each_case_within,
    identity::anchor_of,
    registry::CaseRun,
    resumption::{
        RamaResumptionConfigs, rama_client, rama_client_config_for, rama_client_resumes,
        rama_client_warms_up, rama_server_reading, resumption_cases,
    },
    scenario::SERVER_NAME,
};

const PEER: &str = "aioquic";
/// Why the refusal case does not run against this server.
const NO_EARLY_DATA_REFUSAL: &str = "an aioquic server takes the early data of any session it resumes: its TLS is built with \
     the maximum early-data size whatever the configuration says";

/// Rama's client resumes a session with an aioquic server, and offers early data on it where
/// the case does.
#[tokio::test]
async fn resumption_cases_rama_client() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaClient,
        resumption_cases(),
        LIMIT,
        |run| async move {
            if run.scenario.verdict == Verdict::EarlyDataRefused {
                // Visible with `cargo test -- --nocapture`.
                println!(
                    "{}",
                    Unsupported {
                        case: "resumption-early-refused",
                        peer: PEER,
                        reason: NO_EARLY_DATA_REFUSAL,
                    }
                );
                return;
            }
            let served = Identity::generate(SERVER_NAME);
            let run = run.with_identity(served.auth.clone());
            // A case that must not resume gets a second process for the second attempt, with a
            // ticket store it never wrote to. The others serve both connections from one.
            let one_each = run.scenario.verdict == Verdict::NotResumed;
            let mut peer = ticketing_server(&served, if one_each { 1 } else { 2 }).await;
            let addr = peer.listening(run.deadline).await;

            // One configuration for both attempts: the ticket the first earns lives in its
            // resumption cache and is what the second offers.
            let config = rama_client_config_for(anchor_of(&run.identity), &run.scenario);
            let client = rama_client(&run).await;
            rama_client_warms_up(&run, &client, config.clone(), addr).await;
            let first = peer.expect("handshake", run.deadline).await;
            assert!(
                !first.resumed(),
                "{}: the first connection is not a resumption",
                run.what
            );
            assert!(!first.early(), "{}: and carries no early data", run.what);
            // What the child says it read on that exchange, not merely that it read something.
            peer.expect("stream", run.deadline).await.reported().check(
                &run.what,
                "first exchange",
                run.scenario.warm,
            );
            peer.expect("ended", run.deadline).await;

            let (mut peer, addr) = if one_each {
                peer.finished(run.deadline).await;
                // No ticket store at all, so the offer cannot be taken up. The identity and
                // everything else stay as they were.
                let mut second = AioQuic::spawn(
                    "server",
                    &[
                        "--cert",
                        served.certificate(),
                        "--key",
                        served.key(),
                        "--connections",
                        "1",
                    ],
                )
                .await;
                let addr = second.listening(run.deadline).await;
                (second, addr)
            } else {
                (peer, addr)
            };

            let rama = rama_client_resumes(&run, &client, config, addr).await;
            let observed = ResumptionObservation {
                rama,
                ..observe(&run, &mut peer).await
            };
            let withheld = observed.check(&run.what, &run.scenario);
            assert!(
                withheld.is_empty(),
                "{}: this peer reports both verdicts itself: {withheld:?}",
                run.what
            );
            observed.closed_as_the_client_did(&run.what);
            peer.finished(run.deadline).await;
            run.deadline.wait(&run.what, client.wait_idle()).await;
        },
    )
    .await;
}

/// A server that keeps session tickets, ready for `connections` of them.
async fn ticketing_server(identity: &Identity, connections: u8) -> AioQuic {
    AioQuic::spawn(
        "server",
        &[
            "--cert",
            identity.certificate(),
            "--key",
            identity.key(),
            "--tickets",
            "--connections",
            &connections.to_string(),
        ],
    )
    .await
}

/// Everything the child says about the second connection, up to the moment it ends.
///
/// The boundary is the child's own account of the connection ending, and every stream it read
/// is collected on the way there, so a payload delivered twice arrives as one more stream
/// event and fails the count rather than going unnoticed.
async fn observe(run: &CaseRun<ResumptionScenario>, peer: &mut AioQuic) -> ResumptionObservation {
    let (what, deadline) = (&run.what, run.deadline);
    let mut handshake = None;
    let mut received = Vec::new();
    let ended = loop {
        let event = peer.event(what, deadline).await;
        match event.name() {
            "handshake" => assert!(
                handshake.replace(event).is_none(),
                "{what}: duplicate handshake event"
            ),
            "stream" => received.push(event.reported()),
            "ended" => break event,
            other => panic!("{what}: the peer reported {other} on the second connection"),
        }
    };
    let handshake = handshake.expect("the connection completed its handshake before closing");
    ResumptionObservation {
        // Filled in by the caller from Rama's own side.
        rama: None,
        resumed: Reported::Seen(handshake.resumed()),
        early_data: Reported::Seen(handshake.early()),
        received,
        closed: Some(CloseObservation {
            code: ended.code(),
            reason: ended.reason().as_bytes().to_vec(),
            application: ended.application(),
            received: Some(ended.close_arrived()),
        }),
        detail: None,
    }
}

/// An aioquic client resumes a session with a Rama server, and offers early data on it where
/// the case does.
///
/// The child runs both connections, so the ticket the first is given is the one the second
/// offers. It says what it was told about each handshake, and Rama's own handshake says
/// whether it resumed, through `NegotiatedTlsParameters::resumed`; the two are checked against each
/// other.
#[tokio::test]
async fn resumption_cases_rama_server() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaServer,
        resumption_cases(),
        LIMIT,
        |run| async move {
            // Every case runs in this direction: what refuses the early data here is Rama's own
            // server, so aioquic's server never having a way to is beside the point.
            let served = Identity::generate(SERVER_NAME);
            let run = run.with_identity(served.auth.clone());
            let configs = RamaResumptionConfigs::new_with_early_data(
                &run.identity,
                run.scenario.offers_early_data,
            );
            // This client offers early data whenever its ticket allows any — `tls.py` puts the
            // extension in the hello from the ticket alone, with no say for the application — so
            // the case that offers none is a session issued without early data rather than a
            // client that holds back. Everywhere else the first server allows it, and the session
            // it keeps carries early keys for the child to offer.
            let (warming, warm_addr, warmed) = rama_server_reading(
                &run,
                configs.warming(),
                vec![Expected {
                    chunk: run.scenario.warm,
                    arrival: Arrival::Bi,
                }],
            )
            .await;
            // Bind both endpoints before the child starts its two connections.
            let (config, active) = configs.resuming(run.scenario.verdict);
            let (resuming, resume_addr, serving) =
                rama_server_reading(&run, config, run.scenario.expected()).await;

            let mut arguments = vec![
                "--ca".to_owned(),
                served.certificate().to_owned(),
                "--port".to_owned(),
                warm_addr.port().to_string(),
                "--second-port".to_owned(),
                resume_addr.port().to_string(),
                "--warm-seed".to_owned(),
                run.scenario.warm.seed.to_string(),
                "--warm-length".to_owned(),
                run.scenario.warm.len.to_string(),
                "--barrier-seed".to_owned(),
                run.scenario.barrier.seed.to_string(),
                "--barrier-length".to_owned(),
                run.scenario.barrier.len.to_string(),
            ];
            if run.scenario.offers_early_data {
                arguments.extend([
                    "--early-seed".to_owned(),
                    run.scenario.early.seed.to_string(),
                    "--early-length".to_owned(),
                    run.scenario.early.len.to_string(),
                ]);
            }
            let borrowed: Vec<&str> = arguments.iter().map(String::as_str).collect();
            let mut peer = AioQuic::spawn("resuming-client", &borrowed).await;

            // The first connection, and what the child says of it.
            let first = peer.expect("handshake", run.deadline).await;
            assert!(
                !first.resumed(),
                "{}: the first connection is not a resumption",
                run.what
            );
            // The echo the child read back, checked rather than counted.
            peer.expect("stream", run.deadline).await.reported().check(
                &run.what,
                "first exchange the child read back",
                run.scenario.warm,
            );
            peer.expect("ended", run.deadline).await;
            let warm = warmed.join(&run.what, run.deadline).await;
            assert_eq!(
                warm.received.len(),
                1,
                "{}: the first connection carried the one exchange",
                run.what
            );
            warm.received[0].check(&run.what, "first exchange", run.scenario.warm);
            assert_eq!(
                warm.resumed,
                Some(false),
                "{}: a first handshake resumes nothing",
                run.what
            );
            run.deadline.wait(&run.what, warming.wait_idle()).await;
            configs.check_warmup(&run.what);

            // The ticket witness, which the child states for itself before it offers anything.
            let ticket = peer.expect("ticket", run.deadline).await;
            assert!(
                ticket.present(),
                "{}: the child was given a ticket to offer",
                run.what
            );

            // The second connection.
            let second = peer.expect("handshake", run.deadline).await;
            peer.expect("stream", run.deadline).await.reported().check(
                &run.what,
                "barrier the child read back",
                run.scenario.barrier,
            );
            peer.expect("ended", run.deadline).await;
            peer.expect("done", run.deadline).await;
            peer.finished(run.deadline).await;
            let report = serving.join(&run.what, run.deadline).await;
            // Two sides that decided for themselves, and they have to agree.
            assert_eq!(
                Some(second.resumed()),
                report.resumed,
                "{}: the child and rama's own handshake agree on the resumption ({})",
                run.what,
                active()
            );
            let observed = ResumptionObservation {
                rama: report.resumed,
                resumed: Reported::Seen(second.resumed()),
                early_data: Reported::Seen(second.early()),
                received: report.received,
                // Rama serves here, so the close this role sees is the peer's own, which the
                // peer chooses rather than the case.
                closed: None,
                detail: Some(active()),
            };
            let withheld = observed.check(&run.what, &run.scenario);
            assert!(
                withheld.is_empty(),
                "{}: this peer reports both verdicts itself: {withheld:?}",
                run.what
            );
            run.deadline.wait(&run.what, resuming.wait_idle()).await;
        },
    )
    .await;
}
