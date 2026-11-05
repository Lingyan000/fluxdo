//! The shared server-name cases, run against aioquic.
//!
//! aioquic's server parses the name a client sends and uses it, but discards it afterwards:
//! `pull_client_hello` fills `ClientHello.server_name` and nothing on the server keeps it, so
//! the child has nothing to report. That is a missing observation in the bridge, not missing
//! protocol support, and it is recorded rather than worked around. The role where Rama is the
//! server needs no such observation and runs both cases.

mod common;

use common::*;
use interop_common::{
    NameObservation, ReceivedName, Role, for_each_case_within,
    names::{name_cases, rama_client_side, rama_server_side},
};

/// The child parses and uses the name it receives but does not retain it, so the bridge has
/// no field to read. The protocol side works; only the observation is missing.
const UNAVAILABLE: &str = "aioquic's server does not retain the name from the client hello";

const PEER: &str = "aioquic";

/// Rama asks aioquic for the case's name, or sends none. The connection, its certificate
/// verification and the probe all run; only the child's report of the name it received is
/// unavailable, and that one assertion is withheld rather than the case being skipped.
#[tokio::test]
async fn name_cases_rama_client() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaClient,
        name_cases(),
        LIMIT,
        |run| async move {
            let host = run.scenario.bind.ip();
            let served = match run.scenario.asked {
                Some(name) => Identity::generate(name),
                None => Identity::generate_for_loopback(host),
            };
            let run = run.clone().with_identity(served.auth.clone());
            let mut peer = AioQuic::spawn(
                "server",
                &[
                    "--cert",
                    served.certificate(),
                    "--key",
                    served.key(),
                    "--connections",
                    "1",
                    "--host",
                    &host.to_string(),
                ],
            )
            .await;
            let addr = peer.listening_on(host, run.deadline).await;

            rama_client_side(&run, addr).await;

            // The child read the probe and echoed it; that is checked here the same way the other
            // peers' probes are.
            peer.expect("handshake", run.deadline).await;
            let reported = peer.expect("stream", run.deadline).await;
            reported
                .reported()
                .check(&run.what, "probe", run.scenario.probe);
            peer.expect("ended", run.deadline).await;
            peer.finished(run.deadline).await;

            let observed = NameObservation {
                server_name: ReceivedName::Unavailable(UNAVAILABLE),
            };
            assert!(
                !observed.check(&run.what, &run.scenario),
                "{}: this peer has no name to report, so no name was asserted",
                run.what
            );
            // Visible with `cargo test -- --nocapture`, which is how the runner surfaces the
            // capabilities a run did not assert.
            println!("{}: received-SNI unavailable: {UNAVAILABLE}", run.what);
        },
    )
    .await;
}

/// aioquic asks Rama for the case's name, or names the address, and Rama reports what it
/// received.
#[tokio::test]
async fn name_cases_rama_server() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaServer,
        name_cases(),
        LIMIT,
        |run| async move {
            let served = match run.scenario.asked {
                Some(name) => Identity::generate(name),
                None => Identity::generate_for_loopback(run.scenario.bind.ip()),
            };
            let run = run.clone().with_identity(served.auth.clone());
            let (endpoint, addr, serving) = rama_server_side(&run).await;
            let asked = run
                .scenario
                .asked
                .map_or_else(|| addr.ip().to_string(), str::to_owned);
            let mut peer = AioQuic::spawn(
                "client",
                &[
                    "--ca",
                    served.certificate(),
                    "--host",
                    &addr.ip().to_string(),
                    "--port",
                    &addr.port().to_string(),
                    "--server-name",
                    &asked,
                    "--probe-seed",
                    &run.scenario.probe.seed.to_string(),
                    "--probe-length",
                    &run.scenario.probe.len.to_string(),
                ],
            )
            .await;
            peer.expect("handshake", run.deadline).await;
            let connected = peer.expect("connected", run.deadline).await;
            // A dual-stack ephemeral bind can overlap another test's IPv4 port on macOS.
            assert_eq!(connected.socket_is_ipv6(), addr.is_ipv6());
            let back = peer.expect("stream", run.deadline).await;
            back.reported()
                .check(&run.what, "probe", run.scenario.probe);
            peer.expect("ended", run.deadline).await;
            peer.finished(run.deadline).await;
            serving.join(&run.what, run.deadline).await;
            run.deadline.wait(&run.what, endpoint.wait_idle()).await;
        },
    )
    .await;
}
