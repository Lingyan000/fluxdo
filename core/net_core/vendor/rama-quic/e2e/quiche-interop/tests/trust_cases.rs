//! The shared certificate-trust cases, run against quiche in both roles.
//!
//! Rama's own error is checked in the shared code; the TLS alert quiche reports for itself is
//! checked here, so a refusal for some other reason is not mistaken for this one.

mod common;

use common::{Identity, Quiche, Stopped, quiche_client_config, quiche_server_config};
use interop_common::{
    Peer, Role, TrustObservation, for_each_case,
    scenario::SERVER_NAME,
    serving::{ServerOutcome, expect_outcome, rama_probe_server},
    trust::{rama_client_accepts, rama_client_refuses, trust_cases},
};
use rama::utils::octets;
use std::assert_matches;

const PEER: &str = "quiche";
const UNI_READ: usize = octets::kib(64);

/// Rama's client refuses a quiche server it has no anchor for, and accepts the one it does.
#[tokio::test]
async fn trust_cases_rama_client() {
    for_each_case(PEER, Role::RamaClient, trust_cases(), |run| async move {
        // One server identity throughout: only the anchor the client trusts changes.
        let served = Identity::generate(SERVER_NAME);
        let run = run.with_identity(served.auth.clone());
        let (addr, accepting) =
            Quiche::bind_server(quiche_server_config(&served), run.deadline).await;
        let refusing = Peer::spawn({
            let what = run.what.clone();
            let deadline = run.deadline;
            async move {
                let mut server = accepting.await;
                server
                    .drive_or_stop(&what, deadline, |connection| connection.is_established())
                    .await;
            }
        });
        rama_client_refuses(&run, addr).await;
        refusing.join(&run.what, run.deadline).await;

        // The control: the same identity, now with the anchor that matches it. quiche's
        // driver serves one connection, so a second server with the same certificate and key
        // stands in for the same endpoint.
        let (trusted_addr, accepting) =
            Quiche::bind_server(quiche_server_config(&served), run.deadline).await;
        let serving = Peer::spawn({
            let what = run.what.clone();
            let deadline = run.deadline;
            let probe = run.scenario.probe;
            async move {
                let mut server = accepting.await;
                server
                    .drive_until(&what, deadline, |connection| connection.is_established())
                    .await;
                let received = server.read_stream(0, UNI_READ, deadline).await;
                assert_eq!(received, probe.bytes(), "{what}: the probe arrived whole");
                server.write_stream(0, &probe.bytes(), deadline).await;
                server
                    .drive_until(&what, deadline, |connection| connection.is_closed())
                    .await;
            }
        });
        rama_client_accepts(&run, trusted_addr).await;
        serving.join(&run.what, run.deadline).await;
    })
    .await;
}

/// A quiche client refuses a Rama server it has no anchor for, and accepts the one it does.
#[tokio::test]
async fn trust_cases_rama_server() {
    for_each_case(PEER, Role::RamaServer, trust_cases(), |run| async move {
        // One Rama server identity throughout: only the anchor this client trusts changes.
        let served = Identity::generate(SERVER_NAME);
        let stranger = Identity::generate_from_a_stranger(SERVER_NAME, "Another Authority");
        let run = run.with_identity(served.auth.clone());
        let (endpoint, addr, serving) = rama_probe_server(&run, run.scenario.probe, false).await;
        let mut client = Quiche::connect(
            addr,
            SERVER_NAME,
            quiche_client_config(&stranger),
            run.deadline,
        )
        .await;
        let stopped = client
            .drive_or_stop(&run.what, run.deadline, |connection| {
                connection.is_established()
            })
            .await;
        assert_matches!(
            stopped,
            None | Some(Stopped::Closed) | Some(Stopped::Rejected(quiche::Error::TlsFail)),
            "{}: the untrusted attempt ends without a connection: {stopped:?}",
            run.what,
        );
        let observed = TrustObservation {
            refused: !client.connection().is_established(),
            detail: client.ended_on_a_tls_alert().map(|alert| alert.to_string()),
        };
        observed.check(&run.what);
        // quiche's own account of why. A TLS alert reaches QUIC as CRYPTO_ERROR plus the
        // alert's own number (RFC 9001 §4.8), so unknown_ca (48) is 0x130.
        assert_eq!(
            client.ended_on_a_tls_alert(),
            Some(0x100 + u64::from(interop_common::backend::UNKNOWN_CA)),
            "{}: quiche reports the issuer alert",
            run.what
        );
        expect_outcome(serving, &run.what, run.deadline, ServerOutcome::Refused).await;
        run.deadline.wait(&run.what, endpoint.wait_idle()).await;

        // The control: the same Rama identity, now with the anchor that matches it.
        let (endpoint, addr, serving) = rama_probe_server(&run, run.scenario.probe, true).await;
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
        client
            .write_stream(0, &run.scenario.probe.bytes(), run.deadline)
            .await;
        let back = client.read_stream(0, UNI_READ, run.deadline).await;
        assert_eq!(
            back,
            run.scenario.probe.bytes(),
            "{}: the probe came back whole",
            run.what
        );
        client.close(run.deadline).await;
        expect_outcome(serving, &run.what, run.deadline, ServerOutcome::Probed).await;
        run.deadline.wait(&run.what, endpoint.wait_idle()).await;
    })
    .await;
}
