//! The shared key-update cases, run against Quinn in both roles.
//!
//! Quinn asks for an update the same way Rama does, through `force_key_update`. It reports no
//! key phase of its own — its `ConnectionStats` counts udp, frame and path work and nothing
//! about keys — so the phase is recorded unavailable here and Rama's own count is what says an
//! update happened.

mod common;

use common::{quinn_client_config, quinn_server_config};
use interop_common::{
    Initiator, KeyObservation, KeyScenario, Received, Reported, Role, for_each_case,
    identity::anchor_of,
    keys::{
        key_cases, rama_client_connects, rama_client_updates, rama_server_side,
        settle_before_measuring,
    },
    registry::CaseRun,
    scenario::{Chunk, SERVER_NAME},
    support::{Deadline, Peer, localhost},
};
use rama::utils::octets;

const PEER: &str = "quinn";
const READ_CAP: usize = octets::mib(1);
/// Why the phase is not part of a Quinn observation.
const NO_PHASE: &str = "quinn reports no key phase of its own";

/// Rama's client asks Quinn's server for an update, is asked by it, or neither.
#[tokio::test]
async fn key_cases_rama_client() {
    for_each_case(PEER, Role::RamaClient, key_cases(), |run| async move {
        let server = quinn::Endpoint::server(quinn_server_config(&run.identity), localhost())
            .expect("the quinn server binds");
        let addr = server.local_addr().expect("its address");
        // The case asks this peer directly, which it may have to do more than once while an
        // earlier update is still in flight, so the connection itself is handed over rather
        // than a one-shot signal.
        let (accepted, is_accepted) = tokio::sync::oneshot::channel();
        let serving = Peer::spawn({
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
                accepted
                    .send(connection.clone())
                    .expect("the case is listening");
                // The number of exchanges is not fixed: the case carries one for the
                // settling update and one for each try at asking this side, so they are
                // answered as they come until the case's last payload arrives.
                answer_until_the_last(&run, &connection).await;
                run.deadline.wait(&run.what, connection.closed()).await;
            }
        });
        // Connect first: the peer has nothing to accept until then.
        let (client, connection) = rama_client_connects(&run, addr).await;
        let peer = run
            .deadline
            .wait(&run.what, is_accepted)
            .await
            .expect("the peer accepted the attempt");

        settle_before_measuring(&run, &connection).await;
        rama_client_updates(&run, &connection, || {
            let peer = peer.clone();
            let asks = run.scenario.initiator == Initiator::Peer;
            async move {
                if asks {
                    peer.force_key_update();
                }
            }
        })
        .await;
        connection.close(0u32, b"done");
        run.deadline.wait(&run.what, client.wait_idle()).await;
        serving.join(&run.what, run.deadline).await;
        record(&run);
        server.close(0u32.into(), b"done");
        run.deadline.wait(&run.what, server.wait_idle()).await;
    })
    .await;
}

/// A Quinn client asks Rama's server for an update, is asked by it, or neither.
#[tokio::test]
async fn key_cases_rama_server() {
    for_each_case(PEER, Role::RamaServer, key_cases(), |run| async move {
        let (endpoint, addr, serving, accepted) = rama_server_side(&run).await;
        let mut client = quinn::Endpoint::client(localhost()).expect("the quinn client binds");
        client.set_default_client_config(quinn_client_config(anchor_of(&run.identity)));
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
        // The exchange that carries rama's settling update over here.
        exchange(&run.what, run.deadline, &connection, run.scenario.settling).await;
        exchange(&run.what, run.deadline, &connection, run.scenario.before).await;
        if run.scenario.initiator == Initiator::Peer {
            // Quinn ignores the request while an update of its own is still in flight and
            // says nothing about it — its `ConnectionStats` has no key counter either — so
            // the request is made again until rama's own count moves, with an exchange
            // behind each try so the new phase can travel.
            let rama = run
                .deadline
                .wait(&run.what, accepted)
                .await
                .expect("rama's server accepted the attempt");
            let baseline = rama.stats().key_updates;
            while rama.stats().key_updates == baseline {
                connection.force_key_update();
                exchange(&run.what, run.deadline, &connection, run.scenario.settling).await;
                if run.deadline.passed() {
                    break;
                }
            }
        }
        exchange(&run.what, run.deadline, &connection, run.scenario.after).await;
        connection.close(0u32.into(), b"done");
        run.deadline.wait(&run.what, client.wait_idle()).await;
        // Rama's own count is checked inside the shared server side, and a failure there is
        // raised by this join.
        serving.join(&run.what, run.deadline).await;
        record(&run);
        run.deadline.wait(&run.what, endpoint.wait_idle()).await;
    })
    .await;
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

/// Answer what arrives, as it comes, until the case's last payload has been answered. The
/// number of exchanges is not fixed: the case carries one for the settling update and one for
/// each try at asking this side.
async fn answer_until_the_last(run: &CaseRun<KeyScenario>, connection: &quinn::Connection) {
    let after = run.scenario.after.bytes();
    loop {
        let got = echo_one(&run.what, run.deadline, connection).await;
        if got == after {
            return;
        }
        assert!(
            got == run.scenario.settling.bytes() || got == run.scenario.before.bytes(),
            "{}: every exchange carries one of this case's payloads",
            run.what
        );
    }
}

/// Read one exchange and answer it with the same bytes, whatever it carried.
async fn echo_one(what: &str, deadline: Deadline, connection: &quinn::Connection) -> Vec<u8> {
    let (mut send, mut recv) = deadline
        .wait(what, connection.accept_bi())
        .await
        .expect("the stream arrives");
    let got = deadline
        .wait(what, recv.read_to_end(READ_CAP))
        .await
        .expect("it completes");
    deadline
        .wait(what, send.write_all(&got))
        .await
        .expect("the answer is written");
    send.finish().expect("the answer ends");
    got
}
