//! The shared close cases, run against aioquic in both roles.
//!
//! The child says what its `ConnectionTerminated` event carried, which is the code and the
//! reason the other side gave.

mod common;

use common::*;
use interop_common::{
    Chunk, CloseObservation, Role,
    close::{close_cases, rama_client_closes, rama_server_side},
    for_each_case_within,
    scenario::SERVER_NAME,
};

const PEER: &str = "aioquic";

/// Rama's client closes, and the aioquic server says what it was told.
#[tokio::test]
async fn close_cases_rama_client() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaClient,
        close_cases(),
        LIMIT,
        |run| async move {
            let served = Identity::generate(SERVER_NAME);
            let run = run.with_identity(served.auth.clone());
            let mut peer = AioQuic::spawn(
                "server",
                &["--cert", served.certificate(), "--key", served.key()],
            )
            .await;
            let addr = peer.listening(run.deadline).await;

            let waiting = tokio::sync::Mutex::new(peer);
            rama_client_closes(&run, addr, || async {
                let mut peer = waiting.lock().await;
                peer.expect("handshake", run.deadline).await;
            })
            .await;
            let mut peer = waiting.into_inner();
            if let Some(first) = run.scenario.first {
                peer.expect("stream", run.deadline)
                    .await
                    .reported()
                    .check(&run.what, "exchange", first);
            }
            let ended = peer.expect("ended", run.deadline).await;
            let observed = CloseObservation {
                code: ended.code(),
                reason: ended.reason().as_bytes().to_vec(),
                application: ended.application(),
                received: Some(ended.close_arrived()),
            };
            observed.check(&run.what, &run.scenario);
            peer.finished(run.deadline).await;
        },
    )
    .await;
}

/// An aioquic client closes, and Rama's server says what it was told.
#[tokio::test]
async fn close_cases_rama_server() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaServer,
        close_cases(),
        LIMIT,
        |run| async move {
            let served = Identity::generate(SERVER_NAME);
            let run = run.with_identity(served.auth.clone());
            let (endpoint, addr, serving) = rama_server_side(&run).await;
            let first = run.scenario.first.unwrap_or(Chunk { seed: 0, len: 0 });
            let reason =
                String::from_utf8(run.scenario.reason.to_vec()).expect("a printable reason");
            let arguments = vec![
                "--ca".to_owned(),
                served.certificate().to_owned(),
                "--port".to_owned(),
                addr.port().to_string(),
                "--before-seed".to_owned(),
                first.seed.to_string(),
                "--before-length".to_owned(),
                first.len.to_string(),
                "--close-code".to_owned(),
                run.scenario.code.to_string(),
                "--close-reason".to_owned(),
                reason,
            ];
            let borrowed: Vec<&str> = arguments.iter().map(String::as_str).collect();
            let mut peer = AioQuic::spawn("close-client", &borrowed).await;
            peer.expect("handshake", run.deadline).await;
            if let Some(first) = run.scenario.first {
                peer.expect("stream", run.deadline)
                    .await
                    .reported()
                    .check(&run.what, "exchange", first);
            }
            // This close is the child's own; aioquic's termination event looks the same
            // either way, so only the frame handler tells them apart.
            let ended = peer.expect("ended", run.deadline).await;
            assert!(
                !ended.close_arrived(),
                "{}: a close of the child's own making reported as one that arrived",
                run.what
            );
            peer.expect("done", run.deadline).await;
            peer.finished(run.deadline).await;
            let observed = serving.join(&run.what, run.deadline).await;
            observed.check(&run.what, &run.scenario);
            run.deadline.wait(&run.what, endpoint.wait_idle()).await;
        },
    )
    .await;
}
