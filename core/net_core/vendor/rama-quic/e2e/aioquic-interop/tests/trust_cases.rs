//! The shared certificate-trust cases, run against aioquic.
//!
//! One server identity is used throughout a case; only the anchor the client trusts changes.
//! Rama's own error is checked in the shared code; the close aioquic sends is read here,
//! because its own exception says only that the connection failed.

mod common;

use common::*;
use interop_common::{
    CaseRun, Role, TrustObservation, TrustScenario, for_each_case_within,
    scenario::SERVER_NAME,
    serving::{ServerOutcome, expect_outcome, rama_probe_server},
    trust::{rama_client_accepts, rama_client_refuses, trust_cases},
};

const PEER: &str = "aioquic";

/// Rama's client refuses an aioquic server whose anchor it does not have, and accepts the same
/// server once it has the matching one.
#[tokio::test]
async fn trust_cases_rama_client() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaClient,
        trust_cases(),
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
                    "--connections",
                    "2",
                ],
            )
            .await;
            let addr = peer.listening(run.deadline).await;

            rama_client_refuses(&run, addr).await;
            // The child's own account of the refusal, read rather than assumed.
            let ended = peer.expect("ended", run.deadline).await;
            let code = ended.code();
            assert!(
                CERTIFICATE_ALERTS.contains(&code),
                "{}: the child saw a certificate alert: {code:#x} ({})",
                run.what,
                ended.reason()
            );
            let observed = TrustObservation {
                refused: true,
                detail: Some(format!("{code:#x} {}", ended.reason())),
            };
            observed.check(&run.what);

            // The control: the same identity, now with the anchor that matches it. The child
            // echoes the probe on its bidirectional stream and reports what it read.
            rama_client_accepts(&run, addr).await;
            peer.expect("handshake", run.deadline).await;
            let reported = peer.expect("stream", run.deadline).await;
            probe_seen(&run, &reported);
            peer.expect("ended", run.deadline).await;
            peer.finished(run.deadline).await;
        },
    )
    .await;
}

/// An aioquic client refuses a Rama server whose anchor it does not have, and accepts the same
/// server once it has the matching one.
#[tokio::test]
async fn trust_cases_rama_server() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaServer,
        trust_cases(),
        LIMIT,
        |run| async move {
            let served = Identity::generate(SERVER_NAME);
            let stranger = Identity::generate_from_a_stranger(SERVER_NAME, "Another Authority");
            let run = run.with_identity(served.auth.clone());

            let (endpoint, addr, serving) =
                rama_probe_server(&run, run.scenario.probe, false).await;
            let mut refused = AioQuic::spawn(
                "client",
                &[
                    "--ca",
                    stranger.certificate(),
                    "--port",
                    &addr.port().to_string(),
                    "--streams",
                    "0",
                ],
            )
            .await;
            let ended = refused.expect("ended", run.deadline).await;
            let code = ended.code();
            // The peer's own choice of alert, so any a certificate check ends on is accepted.
            assert!(
                CERTIFICATE_ALERTS.contains(&code),
                "{}: the close carries a certificate alert: {code:#x} ({})",
                run.what,
                ended.reason()
            );
            let observed = TrustObservation {
                refused: true,
                detail: Some(format!("{code:#x} {}", ended.reason())),
            };
            observed.check(&run.what);
            refused.expect("failed", run.deadline).await;
            refused.failed(run.deadline).await;
            expect_outcome(serving, &run.what, run.deadline, ServerOutcome::Refused).await;
            run.deadline.wait(&run.what, endpoint.wait_idle()).await;

            // The control: the same Rama identity, the anchor that matches it, and exactly one
            // bidirectional probe.
            let (endpoint, addr, serving) = rama_probe_server(&run, run.scenario.probe, true).await;
            let mut accepted = AioQuic::spawn(
                "client",
                &[
                    "--ca",
                    served.certificate(),
                    "--port",
                    &addr.port().to_string(),
                    "--probe-seed",
                    &run.scenario.probe.seed.to_string(),
                    "--probe-length",
                    &run.scenario.probe.len.to_string(),
                ],
            )
            .await;
            accepted.expect("handshake", run.deadline).await;
            accepted.expect("connected", run.deadline).await;
            let back = accepted.expect("stream", run.deadline).await;
            probe_seen(&run, &back);
            accepted.expect("ended", run.deadline).await;
            accepted.finished(run.deadline).await;
            expect_outcome(serving, &run.what, run.deadline, ServerOutcome::Probed).await;
            run.deadline.wait(&run.what, endpoint.wait_idle()).await;
        },
    )
    .await;
}

/// What the child said it read on the probe's stream, checked by length and digest the same way
/// the in-process peers are.
fn probe_seen(run: &CaseRun<TrustScenario>, reported: &Event) {
    reported
        .reported()
        .check(&run.what, "probe", run.scenario.probe);
}
