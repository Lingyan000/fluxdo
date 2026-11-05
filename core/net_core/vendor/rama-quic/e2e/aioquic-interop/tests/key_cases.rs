//! The shared key-update cases, run against aioquic in both roles.
//!
//! This peer says the most of the three: it asks through `request_key_update` and reports the
//! phase its 1-RTT keys are in, so a case here has both Rama's count and the peer's own phase.
//! In the rama-client role the child takes an order at the moment the case says; in the
//! rama-server role the flag on its command line is enough, because Rama's server has already
//! answered the first exchange and read its count before that child can ask.

mod common;

use common::*;
use interop_common::{
    Chunk, Initiator, KeyObservation, KeyScenario, Reported, Role, for_each_case_within,
    keys::{
        key_cases, rama_client_connects, rama_client_updates, rama_server_side,
        settle_before_measuring,
    },
    registry::CaseRun,
    scenario::SERVER_NAME,
};
use std::sync::atomic::{AtomicUsize, Ordering};
use tokio::sync::Mutex;

const PEER: &str = "aioquic";

/// Rama's client asks an aioquic server for an update, is asked by it, or neither.
#[tokio::test]
async fn key_cases_rama_client() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaClient,
        key_cases(),
        LIMIT,
        |run| async move {
            let served = Identity::generate(SERVER_NAME);
            let run = run.with_identity(served.auth.clone());
            let mut peer = AioQuic::spawn(
                "server",
                &[
                    "--cert",
                    served.certificate(),
                    "--key",
                    served.key(),
                    "--orders",
                ],
            )
            .await;
            let addr = peer.listening(run.deadline).await;
            let (client, connection) = rama_client_connects(&run, addr).await;
            peer.expect("handshake", run.deadline).await;
            // The settling update and the exchange that carries it over there, so the phases
            // read here and at the end are either side of the case's own update.
            settle_before_measuring(&run, &connection).await;
            slot(&mut peer, &run, run.scenario.settling, "settling exchange").await;
            let before = phase(&mut peer, &run).await;

            let asks = AtomicUsize::new(0);
            let asking = Mutex::new(peer);
            rama_client_updates(&run, &connection, || {
                let (asking, asks) = (&asking, &asks);
                let run = run.clone();
                async move {
                    let mut peer = asking.lock().await;
                    // The exchange before the ask is read before anything is said to the
                    // child, so its answer to an order is the next line and not a stream
                    // report. On a second try, what came first is that try's probe.
                    let which = if asks.load(Ordering::SeqCst) == 0 {
                        ("first exchange", run.scenario.before)
                    } else {
                        ("probe exchange", run.scenario.settling)
                    };
                    slot(&mut peer, &run, which.1, which.0).await;
                    if run.scenario.initiator == Initiator::Peer {
                        peer.tell("update-keys", run.deadline).await;
                        asks.fetch_add(1, Ordering::SeqCst);
                    }
                }
            })
            .await;
            let mut peer = asking.into_inner();
            // Each try after the first read the previous try's probe, so one probe is left
            // to read where the case asked at all; then the case's last payload.
            if asks.load(Ordering::SeqCst) > 0 {
                slot(&mut peer, &run, run.scenario.settling, "probe exchange").await;
            }
            slot(&mut peer, &run, run.scenario.after, "second exchange").await;
            let after = phase(&mut peer, &run).await;
            record(&run, before, after);

            connection.close(0u32, b"done");
            run.deadline.wait(&run.what, client.wait_idle()).await;
            peer.expect("ended", run.deadline).await;
            peer.finished(run.deadline).await;
        },
    )
    .await;
}

/// An aioquic client asks Rama's server for an update, is asked by it, or neither.
#[tokio::test]
async fn key_cases_rama_server() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaServer,
        key_cases(),
        LIMIT,
        |run| async move {
            let served = Identity::generate(SERVER_NAME);
            let run = run.with_identity(served.auth.clone());
            // This peer asks through its own order, and watches its own phase, so it has
            // no use for the connection handed back here.
            let (endpoint, addr, serving, _accepted) = rama_server_side(&run).await;
            let mut arguments = vec![
                "--ca".to_owned(),
                served.certificate().to_owned(),
                "--port".to_owned(),
                addr.port().to_string(),
                "--settling-seed".to_owned(),
                run.scenario.settling.seed.to_string(),
                "--settling-length".to_owned(),
                run.scenario.settling.len.to_string(),
                "--before-seed".to_owned(),
                run.scenario.before.seed.to_string(),
                "--before-length".to_owned(),
                run.scenario.before.len.to_string(),
                "--after-seed".to_owned(),
                run.scenario.after.seed.to_string(),
                "--after-length".to_owned(),
                run.scenario.after.len.to_string(),
            ];
            if run.scenario.initiator == Initiator::Peer {
                arguments.push("--ask-for-a-key-update".to_owned());
            }
            let borrowed: Vec<&str> = arguments.iter().map(String::as_str).collect();
            let mut peer = AioQuic::spawn("key-client", &borrowed).await;
            peer.expect("handshake", run.deadline).await;
            // The echo it read on the first exchange and its phase then, which is after the
            // settling update where the case has one; then the same at the end.
            // Exactly what this child sends, in order: the exchange that carries rama's
            // warm-up update, its phase before anything else, the case's own exchange, one
            // probe behind its request where it makes one, and the last exchange.
            slot(&mut peer, &run, run.scenario.settling, "settling exchange").await;
            let before = peer.expect("phase", run.deadline).await.phase();
            slot(&mut peer, &run, run.scenario.before, "first exchange").await;
            if run.scenario.initiator == Initiator::Peer {
                slot(&mut peer, &run, run.scenario.settling, "probe exchange").await;
            }
            slot(&mut peer, &run, run.scenario.after, "second exchange").await;
            let after = peer.expect("phase", run.deadline).await.phase();
            peer.expect("ended", run.deadline).await;
            peer.expect("done", run.deadline).await;
            peer.finished(run.deadline).await;
            // Rama's own count is checked inside the shared server side, and a failure there is
            // raised by this join.
            serving.join(&run.what, run.deadline).await;
            record(&run, before, after);
            run.deadline.wait(&run.what, endpoint.wait_idle()).await;
        },
    )
    .await;
}

/// One exchange the child reports, checked against the payload that slot must carry.
async fn slot(peer: &mut AioQuic, run: &CaseRun<KeyScenario>, payload: Chunk, which: &str) {
    peer.expect("stream", run.deadline)
        .await
        .reported()
        .check(&run.what, which, payload);
}

/// The phase the child says its keys are in.
async fn phase(peer: &mut AioQuic, run: &CaseRun<KeyScenario>) -> u64 {
    peer.tell("key-phase", run.deadline).await.phase()
}

/// What the child said about its keys, either side of the update.
fn record(run: &CaseRun<KeyScenario>, before: u64, after: u64) {
    let observed = KeyObservation {
        phase_changed: Reported::Seen(before != after),
        detail: Some(format!("key phase {before} then {after}")),
    };
    assert!(
        observed.check(&run.what, &run.scenario).is_none(),
        "{}: this peer reports its phase itself",
        run.what
    );
}
