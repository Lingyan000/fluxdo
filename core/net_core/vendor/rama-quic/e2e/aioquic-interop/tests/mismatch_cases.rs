//! The shared mismatched-identity cases, run against aioquic.
//!
//! The anchor is trusted throughout and only the identity the certificate carries is wrong.
//!
//! With Rama's client the certificate stays the same and the request changes; with aioquic's
//! client the request stays the same and the served identity changes, both identities coming
//! from one authority so nothing the client trusts changes between them.

mod common;

use common::*;
use interop_common::{
    ANOTHER_ADDRESS, ANOTHER_NAME, IssuedIdentities, MISMATCH_PROBE, Mismatch, Role, SERVER_NAME,
    for_each_case_within, mismatch_cases,
    names::{identity_alert, rama_client_accepts_the_identity, rama_client_refuses_the_identity},
    path_of,
    serving::{ServerOutcome, expect_outcome, rama_probe_server},
};

const PEER: &str = "aioquic";

/// Rama's client refuses an identity the certificate does not carry, and accepts the one it
/// does.
#[tokio::test]
async fn mismatch_cases_rama_client() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaClient,
        mismatch_cases(),
        LIMIT,
        |run| async move {
            let served = match run.scenario {
                Mismatch::CertificateForAddress => Identity::generate_for(None),
                Mismatch::CertificateForName => Identity::generate_for(Some(SERVER_NAME)),
                Mismatch::CertificateForAnotherName => Identity::generate(ANOTHER_NAME),
                Mismatch::CertificateForAnotherAddress => Identity::generate(ANOTHER_ADDRESS),
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
                    "2",
                ],
            )
            .await;
            let addr = peer.listening(run.deadline).await;

            rama_client_refuses_the_identity(&run, addr).await;
            // The child's own account: it saw the handshake end, and nothing was exchanged.
            let ended = peer.expect("ended", run.deadline).await;
            assert!(
                CERTIFICATE_ALERTS.contains(&ended.code()),
                "{}: the close carries a certificate alert: {:#x} ({})",
                run.what,
                ended.code(),
                ended.reason()
            );

            // The control: the same certificate and key, asked for what it is valid for.
            rama_client_accepts_the_identity(&run, addr).await;
            peer.expect("handshake", run.deadline).await;
            let reported = peer.expect("stream", run.deadline).await;
            reported
                .reported()
                .check(&run.what, "probe", MISMATCH_PROBE);
            peer.expect("ended", run.deadline).await;
            peer.finished(run.deadline).await;
        },
    )
    .await;
}

/// An aioquic client refuses a Rama server whose certificate carries another identity, and
/// accepts the one that carries what it asked for.
///
/// Both cases run: aioquic checks an address identity as an address (`verify_certificate_ip_address`)
/// and sends no SNI for it, which is what RFC 6066 §3 asks of a client naming an address.
#[tokio::test]
async fn mismatch_cases_rama_server() {
    prepare().await;
    for_each_case_within(
        PEER,
        Role::RamaServer,
        mismatch_cases(),
        LIMIT,
        |run| async move {
            // Both certificates come from one authority, so this client's trust file is the same
            // in both halves and only the identity the certificate carries changes.
            let pair = IssuedIdentities::generate();
            let anchor = path_of(&pair.authority).to_owned();

            let refusing = run
                .clone()
                .with_identity(run.scenario.served_by(&pair).auth.clone());
            let (endpoint, addr, serving) =
                rama_probe_server(&refusing, MISMATCH_PROBE, false).await;
            let asked = run.scenario.requested(addr);
            let mut refused = AioQuic::spawn(
                "client",
                &[
                    "--ca",
                    &anchor,
                    "--port",
                    &addr.port().to_string(),
                    "--server-name",
                    &asked,
                    "--streams",
                    "0",
                ],
            )
            .await;
            let ended = refused.expect("ended", run.deadline).await;
            assert_eq!(
                ended.code(),
                identity_alert(),
                "{}: the close carries the identity alert: {:#x} ({})",
                run.what,
                ended.code(),
                ended.reason()
            );
            // aioquic says which identity it was looking for, so the refusal is this check and not
            // another certificate one.
            assert!(
                ended.reason().contains(&asked),
                "{}: and aioquic names what it asked for: {}",
                run.what,
                ended.reason()
            );
            refused.expect("failed", run.deadline).await;
            refused.failed(run.deadline).await;
            expect_outcome(serving, &run.what, run.deadline, ServerOutcome::Refused).await;
            run.deadline.wait(&run.what, endpoint.wait_idle()).await;

            // The control: the same request and the same trust file, against the identity that
            // does carry what is asked for.
            let matching = run
                .clone()
                .with_identity(run.scenario.matched_by(&pair).auth.clone());
            let (endpoint, addr, serving) =
                rama_probe_server(&matching, MISMATCH_PROBE, true).await;
            let mut accepted = AioQuic::spawn(
                "client",
                &[
                    "--ca",
                    &anchor,
                    "--port",
                    &addr.port().to_string(),
                    "--server-name",
                    &run.scenario.requested(addr),
                    "--probe-seed",
                    &MISMATCH_PROBE.seed.to_string(),
                    "--probe-length",
                    &MISMATCH_PROBE.len.to_string(),
                ],
            )
            .await;
            accepted.expect("handshake", run.deadline).await;
            accepted.expect("connected", run.deadline).await;
            let back = accepted.expect("stream", run.deadline).await;
            back.reported().check(&run.what, "probe", MISMATCH_PROBE);
            accepted.expect("ended", run.deadline).await;
            accepted.finished(run.deadline).await;
            expect_outcome(serving, &run.what, run.deadline, ServerOutcome::Probed).await;
            run.deadline.wait(&run.what, endpoint.wait_idle()).await;
        },
    )
    .await;
}
