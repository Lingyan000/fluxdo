//! The shared QUIC version cases (RFC 9368, RFC 9369), run against aioquic in both roles.
//!
//! aioquic speaks v1 and v2, starts a client in the first of its configured versions, lists
//! them all as compatible, and moves a connection as a server to the first version the client
//! listed that it supports. It reports the version it settled on in its handshake event.

mod common;

use common::*;
use interop_common::{
    PeerObservation, Role, VersionScenario, for_each_case_within,
    registry::CaseRun,
    scenario::SERVER_NAME,
    version::{check_peer_version, rama_client_side, rama_server_side, version_cases},
};
use rama::quic::proto::Version;

const PEER: &str = "aioquic";
/// A client's first unidirectional stream, and its first bidirectional one.
const UNI: u64 = 2;
const BI: u64 = 0;

/// Keep the independent peer pinned to correct RFC 9369 Appendix A.5 key updates.
/// This tests the pinned peer directly, without changing its cryptography.
#[tokio::test]
async fn pinned_peer_passes_the_v2_key_update_vector() {
    prepare().await;
    let mut command = tokio::process::Command::new(python());
    command
        .args([
            "-c",
            r#"
from aioquic.quic.crypto import CryptoContext, next_key_phase
from aioquic.quic.packet import QuicProtocolVersion
from aioquic.tls import CipherSuite, cipher_suite_hash, hkdf_expand_label
secret = bytes.fromhex("9ac312a7f877468ebe69422748ad00a15443f18203a07d6060f688f30f21632b")
expected = bytes.fromhex("c69374c49e3d2a9466fa689e49d476db5d0dfbc87d32ceeaa6343fd0ae4c7d88")
suite = CipherSuite.CHACHA20_POLY1305_SHA256
algorithm = cipher_suite_hash(suite)
assert hkdf_expand_label(algorithm, secret, b"quicv2 ku", b"", 32) == expected
context = CryptoContext()
context.setup(cipher_suite=suite, secret=secret, version=QuicProtocolVersion.VERSION_2)
actual = next_key_phase(context).secret
assert actual == expected, "peer must implement the v2 key-update label"
"#,
        ])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let result = bounded_command(command, LIMIT)
        .await
        .expect("peer probe finishes");
    assert!(result.status.success(), "{}", result.stderr);
}

fn versions_argument(versions: &[Version]) -> String {
    versions
        .iter()
        .map(|version| format!("{:#x}", version.as_u32()))
        .collect::<Vec<_>>()
        .join(",")
}

fn traffic_arguments(run: &CaseRun<VersionScenario>) -> Vec<String> {
    let scenario = &run.scenario.traffic;
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

/// Rama opens the connection with the case's version policy and aioquic, speaking the case's
/// versions, answers it.
#[tokio::test]
async fn version_cases_rama_client() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaClient,
        version_cases(),
        LIMIT,
        |run| async move {
            let identity = Identity::generate(SERVER_NAME);
            let run = run.with_identity(identity.auth.clone());
            let mut arguments = vec![
                "--cert".to_owned(),
                identity.certificate().to_owned(),
                "--key".to_owned(),
                identity.key().to_owned(),
                "--versions".to_owned(),
                versions_argument(run.scenario.peer_versions),
            ];
            arguments.extend(traffic_arguments(&run));
            let borrowed: Vec<&str> = arguments.iter().map(String::as_str).collect();
            let mut peer = AioQuic::spawn("server", &borrowed).await;
            let addr = peer.listening(run.deadline).await;

            let rama = match rama_client_side(&run, addr).await {
                Ok(rama) => rama,
                Err(reason) => {
                    // Visible with `cargo test -- --nocapture`; the case is named in full.
                    println!("{PEER} does not run {}: {reason}", run.what);
                    drop(peer);
                    return;
                }
            };
            let expected = rama.connection.version();

            let handshake = peer.expect("handshake", run.deadline).await;
            check_peer_version(&run.what, handshake.version(), expected);
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
            observed.check(&run.what, &run.scenario.traffic, run.role);
        },
    )
    .await;
}

/// aioquic opens the connection in the case's versions and Rama, accepting and preferring
/// what the case says, answers it.
#[tokio::test]
async fn version_cases_rama_server() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaServer,
        version_cases(),
        LIMIT,
        |run| async move {
            let identity = Identity::generate(SERVER_NAME);
            let run = run.with_identity(identity.auth.clone());
            let (endpoint, addr, serving) = rama_server_side(&run).await;
            let expected = run.scenario.as_server.expected(true);

            // The peer speaks both versions here, most preferred first, unless the case says
            // it only speaks one; its first flight is v1 unless it only speaks v2.
            let peer_versions = if run.scenario.restarts {
                vec![Version::V1, Version::V2]
            } else {
                run.scenario.peer_versions.to_vec()
            };
            let mut arguments = vec![
                "--ca".to_owned(),
                identity.certificate().to_owned(),
                "--port".to_owned(),
                addr.port().to_string(),
                "--versions".to_owned(),
                versions_argument(&peer_versions),
            ];
            arguments.extend(traffic_arguments(&run));
            let borrowed: Vec<&str> = arguments.iter().map(String::as_str).collect();
            let mut peer = AioQuic::spawn("client", &borrowed).await;

            let handshake = peer.expect("handshake", run.deadline).await;
            check_peer_version(&run.what, handshake.version(), expected);
            peer.expect("connected", run.deadline).await;
            let reported = peer.streams(2, run.deadline).await;
            let seen = |id: u64| {
                reported
                    .iter()
                    .find(|stream| stream.id() == id)
                    .unwrap_or_else(|| panic!("{}: the peer reported stream {id}", run.what))
            };
            let (down, question) = (seen(3), seen(BI));
            let ended = peer.expect("ended", run.deadline).await;
            peer.finished(run.deadline).await;
            serving.join(&run.what, run.deadline).await;
            run.deadline.wait(&run.what, endpoint.wait_idle()).await;
            let observed = PeerObservation {
                protocol: Some(handshake.alpn().as_bytes().to_vec()),
                up: None,
                down: Some((down.reported(), true)),
                question: None,
                answer: Some((question.reported(), true)),
                closed: ended.name() == "ended",
            };
            observed.check(&run.what, &run.scenario.traffic, run.role);
        },
    )
    .await;
}
