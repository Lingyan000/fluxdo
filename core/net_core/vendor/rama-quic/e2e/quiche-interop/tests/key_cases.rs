//! The shared key-update cases, run against quiche in both roles.
//!
//! quiche follows an update but cannot be asked to start one: its public surface has no
//! initiator — `key_phase` is private, and the `pub fn`s about keys are the key files,
//! `log_keys`, `set_keylog` and `set_ticket_key` — so the peer-asks case is recorded
//! unsupported rather than run as something else, and the phase it is in is not reported
//! either. Rama's own count is what says an update happened.

mod common;

use common::{Identity, Quiche, quiche_client_config, quiche_server_config};
use interop_common::{
    Initiator, KeyObservation, KeyScenario, Received, Reported, Role, Unsupported, for_each_case,
    keys::{key_cases, rama_client_side, rama_server_side},
    registry::CaseRun,
    scenario::SERVER_NAME,
    support::Peer,
};
use rama::utils::octets;

const PEER: &str = "quiche";
const READ_CAP: usize = octets::mib(1);
const CLIENT_BI: u64 = 0;
/// Why this peer neither asks nor reports.
const NO_INITIATOR: &str = "quiche's public surface has no key-update initiator";
const NO_PHASE: &str = "quiche reports no key phase of its own";

/// Rama's client asks for an update against a quiche server, or nobody does.
#[tokio::test]
async fn key_cases_rama_client() {
    for_each_case(PEER, Role::RamaClient, key_cases(), |run| async move {
        if !runs_here(&run) {
            return;
        }
        let served = Identity::generate(SERVER_NAME);
        let run = run.with_identity(served.auth.clone());
        let (addr, accepting) =
            Quiche::bind_server(quiche_server_config(&served), run.deadline).await;
        let serving = Peer::spawn({
            let run = run.clone();
            async move {
                let mut server = accepting.await;
                server
                    .drive_until(&run.what, run.deadline, |connection| {
                        connection.is_established()
                    })
                    .await;
                // A client opens a new bidirectional stream for each exchange and their
                // identifiers go up in fours. The first carries rama's settling update over
                // here; this peer never asks for one, so there are no probe exchanges.
                for (index, payload) in [
                    run.scenario.settling,
                    run.scenario.before,
                    run.scenario.after,
                ]
                .into_iter()
                .enumerate()
                {
                    let stream = CLIENT_BI + 4 * index as u64;
                    let got = server.read_stream(stream, READ_CAP, run.deadline).await;
                    Received::Bytes(got.clone()).check(&run.what, "exchange", payload);
                    server.write_stream(stream, &got, run.deadline).await;
                }
                server
                    .drive_until(&run.what, run.deadline, |connection| connection.is_closed())
                    .await;
            }
        });
        // This peer is never the one asking, so nothing is said to it.
        rama_client_side(&run, addr, || async {}).await;
        serving.join(&run.what, run.deadline).await;
        record(&run);
    })
    .await;
}

/// Rama's server asks for an update against a quiche client, or nobody does.
#[tokio::test]
async fn key_cases_rama_server() {
    for_each_case(PEER, Role::RamaServer, key_cases(), |run| async move {
        if !runs_here(&run) {
            return;
        }
        let served = Identity::generate(SERVER_NAME);
        let run = run.with_identity(served.auth.clone());
        // This peer never asks, so it has no use for the connection handed back here.
        let (endpoint, addr, serving, _accepted) = rama_server_side(&run).await;
        let mut client = Quiche::connect(
            addr,
            SERVER_NAME,
            quiche_client_config(&served),
            run.deadline,
        )
        .await;
        client
            .drive_until(&run.what, run.deadline, |connection| {
                connection.is_established()
            })
            .await;
        // The first exchange carries rama's settling update over here; this peer never asks
        // for one, so there are no probe exchanges.
        for (index, payload) in [
            run.scenario.settling,
            run.scenario.before,
            run.scenario.after,
        ]
        .into_iter()
        .enumerate()
        {
            let stream = CLIENT_BI + 4 * index as u64;
            client
                .write_stream(stream, &payload.bytes(), run.deadline)
                .await;
            let back = client.read_stream(stream, READ_CAP, run.deadline).await;
            Received::Bytes(back).check(&run.what, "exchange", payload);
        }
        client.close(run.deadline).await;
        serving.join(&run.what, run.deadline).await;
        record(&run);
        run.deadline.wait(&run.what, endpoint.wait_idle()).await;
    })
    .await;
}

/// Whether this case can run against this peer at all, and the record when it cannot.
fn runs_here(run: &CaseRun<KeyScenario>) -> bool {
    if run.scenario.initiator == Initiator::Peer {
        // Visible with `cargo test -- --nocapture`.
        println!(
            "{}",
            Unsupported {
                case: "key-update-peer-asks",
                peer: PEER,
                reason: NO_INITIATOR,
            }
        );
        return false;
    }
    true
}

/// What this peer can say for itself, which is nothing about the phase.
fn record(run: &CaseRun<KeyScenario>) {
    let observed = KeyObservation {
        phase_changed: Reported::Unavailable(NO_PHASE),
        detail: None,
    };
    if let Some(reason) = observed.check(&run.what, &run.scenario) {
        // Visible with `cargo test -- --nocapture`.
        println!("{}: {reason}", run.what);
    }
}
