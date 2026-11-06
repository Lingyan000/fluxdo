//! The shared close cases, run against Quinn in both roles.
//!
//! Quinn reports an application close as `ConnectionError::ApplicationClosed`, carrying the
//! code and the reason, which is what each case reads back.

mod common;

use common::{answer, exchange, quinn_client_config, quinn_server_config};
use interop_common::{
    CloseObservation, Role,
    close::{close_cases, rama_client_closes, rama_server_side},
    for_each_case,
    identity::anchor_of,
    scenario::SERVER_NAME,
    support::{Peer, localhost},
};

const PEER: &str = "quinn";

/// Rama's client closes, and Quinn's server says what it was told.
#[tokio::test]
async fn close_cases_rama_client() {
    for_each_case(PEER, Role::RamaClient, close_cases(), |run| async move {
        let server = quinn::Endpoint::server(quinn_server_config(&run.identity), localhost())
            .expect("the quinn server binds");
        let addr = server.local_addr().expect("its address");
        let (settled, is_settled) = tokio::sync::oneshot::channel();
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
                settled.send(()).expect("the case is listening");
                if let Some(first) = run.scenario.first {
                    answer(&run.what, run.deadline, &connection, first).await;
                }
                told(
                    &run.what,
                    run.deadline.wait(&run.what, connection.closed()).await,
                )
            }
        });

        rama_client_closes(&run, addr, || async {
            run.deadline
                .wait(&run.what, is_settled)
                .await
                .expect("the peer settled its handshake");
        })
        .await;
        let observed = observing.join(&run.what, run.deadline).await;
        observed.check(&run.what, &run.scenario);
        server.close(0u32.into(), b"done");
        run.deadline.wait(&run.what, server.wait_idle()).await;
    })
    .await;
}

/// A Quinn client closes, and Rama's server says what it was told.
#[tokio::test]
async fn close_cases_rama_server() {
    for_each_case(PEER, Role::RamaServer, close_cases(), |run| async move {
        let (endpoint, addr, serving) = rama_server_side(&run).await;
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
        if let Some(first) = run.scenario.first {
            exchange(&run.what, run.deadline, &connection, first).await;
        }
        connection.close(run.scenario.code.into(), run.scenario.reason);
        run.deadline.wait(&run.what, client.wait_idle()).await;
        let observed = serving.join(&run.what, run.deadline).await;
        observed.check(&run.what, &run.scenario);
        run.deadline.wait(&run.what, endpoint.wait_idle()).await;
    })
    .await;
}

/// What Quinn's side was told when the other closed.
fn told(what: &str, ended: quinn::ConnectionError) -> CloseObservation {
    let quinn::ConnectionError::ApplicationClosed(ref close) = ended else {
        panic!("{what}: the peer closed the connection rather than it failing: {ended:?}");
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
