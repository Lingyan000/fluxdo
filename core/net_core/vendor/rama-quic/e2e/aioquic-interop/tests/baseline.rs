//! The shared stream scenarios, run against aioquic in both roles.
//!
//! Every case in `interop_common::cases` runs here: the entry points enumerate the registry
//! rather than pick entries out of it. The child takes each payload as the two numbers it
//! follows from and derives the bytes itself, so its parameters come from the same case the
//! Rama side is given.

mod common;

use common::*;
use interop_common::{
    CaseRun, PeerObservation, Role, SERVER_NAME, StreamScenario, for_each_case_within,
    scenario::{rama_client_side, rama_server_side},
    stream_cases,
};

const PEER: &str = "aioquic";
/// A client's first unidirectional stream, and its first bidirectional one.
const UNI: u64 = 2;
const BI: u64 = 0;

/// This case's payloads as the child takes them: a seed and a length each, from the same
/// scenario the Rama side is running.
fn scenario_arguments(run: &CaseRun<StreamScenario>) -> Vec<String> {
    let scenario = &run.scenario;
    [
        ("--up-seed", usize::from(scenario.up.seed)),
        ("--up-length", scenario.up.len),
        ("--down-seed", usize::from(scenario.down.seed)),
        ("--down-length", scenario.down.len),
        ("--question-seed", usize::from(scenario.question.seed)),
        ("--question-length", scenario.question.len),
        ("--answer-seed", usize::from(scenario.answer.seed)),
        ("--answer-length", scenario.answer.len),
    ]
    .into_iter()
    .flat_map(|(name, value)| [name.to_owned(), value.to_string()])
    .collect()
}

/// Rama opens the connection and aioquic answers it, for every registered case.
#[tokio::test]
async fn stream_cases_rama_client() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaClient,
        stream_cases(),
        LIMIT,
        |run| async move {
            let identity = Identity::generate(SERVER_NAME);
            let run = run.with_identity(identity.auth.clone());
            let mut arguments = vec![
                "--cert".to_owned(),
                identity.certificate().to_owned(),
                "--key".to_owned(),
                identity.key().to_owned(),
            ];
            arguments.extend(scenario_arguments(&run));
            let borrowed: Vec<&str> = arguments.iter().map(String::as_str).collect();
            let mut peer = AioQuic::spawn("server", &borrowed).await;
            let addr = peer.listening(run.deadline).await;

            let rama = rama_client_side(&run, addr).await;

            // The child's own account, read while the connection is still up: it reports each
            // stream as it finishes it.
            let handshake = peer.expect("handshake", run.deadline).await;
            let reported = peer.streams(2, run.deadline).await;
            let seen = |id: u64| {
                reported
                    .iter()
                    .find(|stream| stream.id() == id)
                    .unwrap_or_else(|| panic!("{}: the peer reported stream {id}", run.what))
            };
            let (up, question) = (seen(UNI), seen(BI));

            rama.close(&run.what, run.deadline).await;
            let ended = peer.expect("ended", run.deadline).await;
            let observed = PeerObservation {
                protocol: Some(handshake.alpn().as_bytes().to_vec()),
                up: Some((up.reported(), true)),
                down: None,
                question: Some((question.reported(), true)),
                answer: None,
                closed: ended.name() == "ended",
            };
            peer.finished(run.deadline).await;
            observed.check(&run.what, &run.scenario, run.role);
        },
    )
    .await;
}

/// aioquic opens the connection and Rama answers it, for every registered case.
#[tokio::test]
async fn stream_cases_rama_server() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaServer,
        stream_cases(),
        LIMIT,
        |run| async move {
            let identity = Identity::generate(SERVER_NAME);
            let run = run.with_identity(identity.auth.clone());
            let (endpoint, addr, serving) = rama_server_side(&run).await;

            let mut arguments = vec![
                "--ca".to_owned(),
                identity.certificate().to_owned(),
                "--port".to_owned(),
                addr.port().to_string(),
            ];
            arguments.extend(scenario_arguments(&run));
            let borrowed: Vec<&str> = arguments.iter().map(String::as_str).collect();
            let mut peer = AioQuic::spawn("client", &borrowed).await;

            let handshake = peer.expect("handshake", run.deadline).await;
            peer.expect("connected", run.deadline).await;
            let down = peer.expect("stream", run.deadline).await;
            assert_eq!(down.id(), 3, "the server initiated the uni stream");
            let answer = peer.expect("stream", run.deadline).await;
            let ended = peer.expect("ended", run.deadline).await;
            let observed = PeerObservation {
                protocol: Some(handshake.alpn().as_bytes().to_vec()),
                up: None,
                down: Some((down.reported(), true)),
                question: None,
                answer: Some((answer.reported(), true)),
                closed: ended.name() == "ended",
            };
            peer.finished(run.deadline).await;

            observed.check(&run.what, &run.scenario, run.role);
            serving.join(&run.what, run.deadline).await;
            run.deadline.wait(&run.what, endpoint.wait_idle()).await;
        },
    )
    .await;
}
