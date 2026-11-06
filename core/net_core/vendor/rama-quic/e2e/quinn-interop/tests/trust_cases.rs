//! The shared certificate-trust cases, run against Quinn in both roles.
//!
//! The refusal and its control are one case: the same identity is refused with the wrong anchor
//! and accepted with the right one. Rama's own error is checked in the shared code; the rustls
//! alert and cause Quinn or Rama reports natively are checked here.

mod common;

use common::{quinn_client_config, quinn_server_config};
use interop_common::{
    Deadline, Peer, Role, TrustObservation, for_each_case,
    identity::anchor_of,
    scenario::SERVER_NAME,
    serving::{ServerOutcome, expect_outcome, rama_probe_server},
    support::localhost,
    trust::{rama_client_accepts, rama_client_refuses, trust_cases, wrong_anchor},
};
use rama::crypto::pki_types::CertificateDer;
use rustls::AlertDescription;
use std::net::SocketAddr;

const PEER: &str = "quinn";

/// Rama's client refuses a Quinn server it has no anchor for, and accepts the one it does.
#[tokio::test]
async fn trust_cases_rama_client() {
    for_each_case(PEER, Role::RamaClient, trust_cases(), |run| async move {
        // One server identity throughout: only the anchor the client trusts changes.
        let server = quinn::Endpoint::server(quinn_server_config(&run.identity), localhost())
            .expect("the quinn server binds");
        let addr = server.local_addr().expect("its address");
        let refusing = Peer::spawn({
            let deadline = run.deadline;
            let what = run.what.clone();
            let server = server.clone();
            async move {
                let Some(attempt) = deadline.wait(&what, server.accept()).await else {
                    return;
                };
                let ended = deadline.wait(&what, attempt).await;
                assert!(ended.is_err(), "{what}: the peer saw the attempt fail");
            }
        });
        // The certificate assertions are shared; nothing Quinn-specific is observable on this
        // side of the refusal.
        rama_client_refuses(&run, addr).await;
        refusing.join(&run.what, run.deadline).await;

        // The control: the same server identity, now with the anchor that matches it.
        let serving = Peer::spawn({
            let deadline = run.deadline;
            let what = run.what.clone();
            let probe = run.scenario.probe;
            let server = server.clone();
            async move {
                let attempt = deadline
                    .wait(&what, server.accept())
                    .await
                    .expect("an attempt arrives");
                let conn = deadline
                    .wait(&what, attempt)
                    .await
                    .expect("the trusted handshake completes");
                let (mut send, mut recv) = deadline
                    .wait(&what, conn.accept_bi())
                    .await
                    .expect("the probe's stream arrives");
                let received = deadline
                    .wait(&what, recv.read_to_end(probe.len + 1))
                    .await
                    .expect("the probe completes");
                assert_eq!(received, probe.bytes(), "{what}: the probe arrived whole");
                deadline
                    .wait(&what, send.write_all(&probe.bytes()))
                    .await
                    .expect("the probe goes back");
                send.finish().expect("the answer ends");
                deadline.wait(&what, conn.closed()).await;
            }
        });
        rama_client_accepts(&run, addr).await;
        serving.join(&run.what, run.deadline).await;
        server.close(0u32.into(), b"done");
    })
    .await;
}

/// A Quinn client refuses a Rama server it has no anchor for, and accepts the one it does.
#[tokio::test]
async fn trust_cases_rama_server() {
    for_each_case(PEER, Role::RamaServer, trust_cases(), |run| async move {
        // One Rama server identity throughout: only the anchor this client trusts changes.
        let (endpoint, addr, serving) = rama_probe_server(&run, run.scenario.probe, false).await;
        let observed = quinn_refuses(&run.what, run.deadline, wrong_anchor(), addr).await;
        observed.check(&run.what);
        expect_outcome(serving, &run.what, run.deadline, ServerOutcome::Refused).await;
        run.deadline.wait(&run.what, endpoint.wait_idle()).await;

        // The control: the same identity, now with the anchor that matches it.
        let (endpoint, addr, serving) = rama_probe_server(&run, run.scenario.probe, true).await;
        let mut client = quinn::Endpoint::client(localhost()).expect("the quinn client binds");
        client.set_default_client_config(quinn_client_config(anchor_of(&run.identity)));
        let conn = run
            .deadline
            .wait(
                &run.what,
                client
                    .connect(addr, SERVER_NAME)
                    .expect("the attempt starts"),
            )
            .await
            .expect("the anchor that matches gets a connection");
        let (mut send, mut recv) = run
            .deadline
            .wait(&run.what, conn.open_bi())
            .await
            .expect("a bi stream");
        run.deadline
            .wait(&run.what, send.write_all(&run.scenario.probe.bytes()))
            .await
            .expect("the probe is written");
        send.finish().expect("the probe ends");
        let back = run
            .deadline
            .wait(&run.what, recv.read_to_end(run.scenario.probe.len + 1))
            .await
            .expect("the probe comes back");
        assert_eq!(
            back,
            run.scenario.probe.bytes(),
            "{}: the probe came back whole",
            run.what
        );
        conn.close(0u32.into(), b"done");
        run.deadline.wait(&run.what, client.wait_idle()).await;
        expect_outcome(serving, &run.what, run.deadline, ServerOutcome::Probed).await;
        run.deadline.wait(&run.what, endpoint.wait_idle()).await;
    })
    .await;
}

/// A Quinn client that has no anchor for what the server presents, and what it says about it.
/// A refusal only counts here if Quinn's own error names the certificate.
async fn quinn_refuses(
    what: &str,
    deadline: Deadline,
    anchor: CertificateDer<'static>,
    addr: SocketAddr,
) -> TrustObservation {
    let mut client = quinn::Endpoint::client(localhost()).expect("the quinn client binds");
    client.set_default_client_config(quinn_client_config(anchor));
    let refused = deadline
        .wait(
            what,
            client
                .connect(addr, SERVER_NAME)
                .expect("the attempt starts"),
        )
        .await
        .expect_err("a server it does not trust must not get a connection");
    let detail = format!("{refused:?}");
    // Quinn reports the alert it raised. Anything other than the issuer check is a different
    // failure and does not satisfy this case.
    let quinn::ConnectionError::TransportError(error) = &refused else {
        panic!("{what}: a transport error was due: {detail}");
    };
    // A TLS alert reaches QUIC as CRYPTO_ERROR plus the alert's own number (RFC 9001 §4.8), so
    // unknown_ca (48) is 0x130.
    assert_eq!(
        u64::from(error.code),
        0x100 + u64::from(u8::from(AlertDescription::UnknownCA)),
        "{what}: the alert is unknown_ca: {detail}"
    );
    assert!(
        error.reason.contains("UnknownIssuer"),
        "{what}: and Quinn names the issuer as the reason: {detail}"
    );
    deadline.wait(what, client.wait_idle()).await;
    TrustObservation {
        refused: true,
        detail: Some(detail),
    }
}
