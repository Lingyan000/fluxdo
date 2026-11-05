//! The shared mismatched-identity cases, run against quiche.
//!
//! The anchor is trusted throughout and only the identity the certificate carries is wrong.
//!
//! With Rama's client the certificate stays the same and the request changes; quiche serves one
//! connection at a time, so the control binds a second server with that same identity. With
//! quiche's client the request stays the same and the served identity changes, both identities
//! coming from one authority so nothing the client trusts changes between them.

mod common;

use common::{Identity, Quiche, quiche_client_config_trusting, quiche_server_config};
use interop_common::{
    ANOTHER_ADDRESS, ANOTHER_NAME, IssuedIdentities, MISMATCH_PROBE, Mismatch, Peer, Received,
    Role, SERVER_NAME, Unsupported, for_each_case, mismatch_cases,
    names::{identity_alert, rama_client_accepts_the_identity, rama_client_refuses_the_identity},
    serving::{ServerOutcome, expect_outcome, rama_probe_server},
};
use rama::utils::octets;

const PEER: &str = "quiche";
/// Why the two address-requesting cases do not run against this client: `set_host_name` is
/// the only place quiche installs an identity to verify against, and it installs a host name.
const NO_IP_VERIFICATION: &str =
    "this adapter's quiche client verifies a host name and has no address identity to verify";
const BI: u64 = 0;
const READ_CAP: usize = octets::kib(64);

/// Rama's client refuses an identity the certificate does not carry, and accepts the one it
/// does.
#[tokio::test]
async fn mismatch_cases_rama_client() {
    for_each_case(PEER, Role::RamaClient, mismatch_cases(), |run| async move {
        // The same two shapes the shared case names, as files quiche can read.
        let served = match run.scenario {
            Mismatch::CertificateForAddress => Identity::generate_for(None),
            Mismatch::CertificateForName => Identity::generate_for(Some(SERVER_NAME)),
            Mismatch::CertificateForAnotherName => Identity::generate(ANOTHER_NAME),
            Mismatch::CertificateForAnotherAddress => Identity::generate(ANOTHER_ADDRESS),
        };
        let run = run.clone().with_identity(served.auth.clone());

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
                assert!(
                    !server.connection().is_established(),
                    "{what}: the peer saw no connection established, so nothing passed"
                );
            }
        });
        rama_client_refuses_the_identity(&run, addr).await;
        refusing.join(&run.what, run.deadline).await;

        // The control: the same certificate and key, asked for what it is valid for.
        let (control_addr, accepting) =
            Quiche::bind_server(quiche_server_config(&served), run.deadline).await;
        let serving = Peer::spawn({
            let what = run.what.clone();
            let deadline = run.deadline;
            async move {
                let mut server = accepting.await;
                server
                    .drive_until(&what, deadline, |connection| connection.is_established())
                    .await;
                let got = server.read_stream(BI, READ_CAP, deadline).await;
                Received::Bytes(got).check(&what, "probe", MISMATCH_PROBE);
                server
                    .write_stream(BI, &MISMATCH_PROBE.bytes(), deadline)
                    .await;
                server
                    .drive_until(&what, deadline, |connection| connection.is_closed())
                    .await;
            }
        });
        rama_client_accepts_the_identity(&run, control_addr).await;
        serving.join(&run.what, run.deadline).await;
    })
    .await;
}

/// A quiche client refuses a Rama server whose certificate carries another identity, and
/// accepts the one that carries the name it asked for.
///
/// The two cases that ask for a DNS name run here. quiche installs an identity parameter in
/// one place, `set_host_name`, which sets `X509_VERIFY_PARAM_set1_host` alongside SNI; this
/// adapter's configuration has no address parameter to set, so an address literal is not
/// checked as an identity and the two cases that ask for one are reported unsupported.
#[tokio::test]
async fn mismatch_cases_rama_server() {
    for_each_case(PEER, Role::RamaServer, mismatch_cases(), |run| async move {
        // The two cases whose request is an address: this client has no way to verify one.
        if let Mismatch::CertificateForName | Mismatch::CertificateForAnotherAddress = run.scenario
        {
            // Visible with `cargo test -- --nocapture`.
            println!(
                "{}",
                Unsupported {
                    case: match run.scenario {
                        Mismatch::CertificateForAnotherAddress =>
                            "identity-mismatch-another-address",
                        _ => "identity-mismatch-address-asked",
                    },
                    peer: PEER,
                    reason: NO_IP_VERIFICATION,
                }
            );
            return;
        }
        // Both certificates come from one authority, so this client's configuration is the
        // same in both halves and only the identity the certificate carries changes.
        let pair = IssuedIdentities::generate();

        let refusing = run
            .clone()
            .with_identity(run.scenario.served_by(&pair).auth.clone());
        let (endpoint, addr, serving) = rama_probe_server(&refusing, MISMATCH_PROBE, false).await;
        let asked = run.scenario.requested(addr);
        let mut client = Quiche::connect(
            addr,
            &asked,
            quiche_client_config_trusting(&pair.authority),
            run.deadline,
        )
        .await;
        client
            .drive_or_stop(&run.what, run.deadline, |connection| {
                connection.is_established()
            })
            .await;
        assert!(
            !client.connection().is_established(),
            "{}: a certificate for another identity must not be accepted",
            run.what
        );
        assert_eq!(
            client.ended_on_a_tls_alert(),
            Some(identity_alert()),
            "{}: quiche reports the identity alert",
            run.what
        );
        expect_outcome(serving, &run.what, run.deadline, ServerOutcome::Refused).await;
        run.deadline.wait(&run.what, endpoint.wait_idle()).await;

        // The control: the same request and the same anchor, against the identity that does
        // carry the name asked for.
        let matching = run
            .clone()
            .with_identity(run.scenario.matched_by(&pair).auth.clone());
        let (endpoint, addr, serving) = rama_probe_server(&matching, MISMATCH_PROBE, true).await;
        let mut client = Quiche::connect(
            addr,
            &run.scenario.requested(addr),
            quiche_client_config_trusting(&pair.authority),
            run.deadline,
        )
        .await;
        client
            .drive_until(&run.what, run.deadline, |connection| {
                connection.is_established()
            })
            .await;
        client
            .write_stream(BI, &MISMATCH_PROBE.bytes(), run.deadline)
            .await;
        let back = client.read_stream(BI, READ_CAP, run.deadline).await;
        Received::Bytes(back).check(&run.what, "probe", MISMATCH_PROBE);
        client.close(run.deadline).await;
        expect_outcome(serving, &run.what, run.deadline, ServerOutcome::Probed).await;
        run.deadline.wait(&run.what, endpoint.wait_idle()).await;
    })
    .await;
}
