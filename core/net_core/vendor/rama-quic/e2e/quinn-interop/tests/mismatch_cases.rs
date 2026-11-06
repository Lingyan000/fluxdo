//! The shared mismatched-identity cases, run against Quinn.
//!
//! The anchor is trusted throughout and only the identity the certificate carries is wrong,
//! which is what separates these from the trust cases.
//!
//! The two directions hold different halves fixed. With Rama's client the certificate stays the
//! same and the request changes; with Quinn's client the request stays the same and the served
//! identity changes, both identities coming from one authority so the client's configuration is
//! untouched between them.

mod common;

use common::{quinn_client_config, quinn_server_config};
use interop_common::{
    Deadline, IssuedIdentities, MISMATCH_PROBE, Peer, Received, Role, for_each_case,
    mismatch_cases,
    names::{identity_alert, rama_client_accepts_the_identity, rama_client_refuses_the_identity},
    serving::{ServerOutcome, expect_outcome, rama_probe_server},
    support::localhost,
};
use rama::utils::octets;
use std::net::SocketAddr;

const PEER: &str = "quinn";
const READ_CAP: usize = octets::kib(64);

/// Rama's client refuses an identity the certificate does not carry, and accepts the one it
/// does.
#[tokio::test]
async fn mismatch_cases_rama_client() {
    for_each_case(PEER, Role::RamaClient, mismatch_cases(), |run| async move {
        let served = run.scenario.identity();
        let run = run.clone().with_identity(served.clone());
        let server = quinn::Endpoint::server(quinn_server_config(&served), localhost())
            .expect("the quinn server binds");
        let addr = server.local_addr().expect("its address");

        let refusing = Peer::spawn({
            let deadline = run.deadline;
            let what = run.what.clone();
            let server = server.clone();
            async move {
                let attempt = deadline
                    .wait(&what, server.accept())
                    .await
                    .expect("an attempt arrives");
                let ended = deadline.wait(&what, attempt).await;
                assert!(
                    ended.is_err(),
                    "{what}: the peer saw no connection established, so nothing passed"
                );
            }
        });
        rama_client_refuses_the_identity(&run, addr).await;
        refusing.join(&run.what, run.deadline).await;

        // The control: the same certificate, asked for what it is valid for.
        let serving = Peer::spawn({
            let deadline = run.deadline;
            let what = run.what.clone();
            let server = server.clone();
            async move {
                let attempt = deadline
                    .wait(&what, server.accept())
                    .await
                    .expect("an attempt arrives");
                let conn = deadline
                    .wait(&what, attempt)
                    .await
                    .expect("the matching identity is accepted");
                let (mut send, mut recv) = deadline
                    .wait(&what, conn.accept_bi())
                    .await
                    .expect("the probe's stream arrives");
                let got = deadline
                    .wait(&what, recv.read_to_end(READ_CAP))
                    .await
                    .expect("the probe completes");
                Received::Bytes(got).check(&what, "probe", MISMATCH_PROBE);
                deadline
                    .wait(&what, send.write_all(&MISMATCH_PROBE.bytes()))
                    .await
                    .expect("the probe goes back");
                send.finish().expect("the answer ends");
                deadline.wait(&what, conn.closed()).await;
            }
        });
        rama_client_accepts_the_identity(&run, addr).await;
        serving.join(&run.what, run.deadline).await;
        server.close(0u32.into(), b"done");
        run.deadline.wait(&run.what, server.wait_idle()).await;
    })
    .await;
}

/// A Quinn client refuses a Rama server whose certificate carries another identity, and accepts
/// the one that carries what it asked for.
#[tokio::test]
async fn mismatch_cases_rama_server() {
    for_each_case(PEER, Role::RamaServer, mismatch_cases(), |run| async move {
        // Both certificates come from one authority, so the client's configuration is the same
        // in both halves and only the identity the certificate carries changes.
        let pair = IssuedIdentities::generate();
        let config = quinn_client_config(pair.anchor.clone());

        let refusing = run
            .clone()
            .with_identity(run.scenario.served_by(&pair).auth.clone());
        let (endpoint, addr, serving) = rama_probe_server(&refusing, MISMATCH_PROBE, false).await;
        let asked = run.scenario.requested(addr);
        quinn_refuses_the_identity(&run.what, run.deadline, config.clone(), addr, &asked).await;
        expect_outcome(serving, &run.what, run.deadline, ServerOutcome::Refused).await;
        run.deadline.wait(&run.what, endpoint.wait_idle()).await;

        // The control: the same request and the same anchor, against the identity that does
        // carry what is asked for.
        let matching = run
            .clone()
            .with_identity(run.scenario.matched_by(&pair).auth.clone());
        let (endpoint, addr, serving) = rama_probe_server(&matching, MISMATCH_PROBE, true).await;
        let mut client = quinn::Endpoint::client(localhost()).expect("the quinn client binds");
        client.set_default_client_config(config);
        let conn = run
            .deadline
            .wait(
                &run.what,
                client
                    .connect(addr, &run.scenario.requested(addr))
                    .expect("the attempt starts"),
            )
            .await
            .expect("the identity it asks for is the one presented");
        let (mut send, mut recv) = run
            .deadline
            .wait(&run.what, conn.open_bi())
            .await
            .expect("a bi stream");
        run.deadline
            .wait(&run.what, send.write_all(&MISMATCH_PROBE.bytes()))
            .await
            .expect("the probe is written");
        send.finish().expect("the probe ends");
        let back = run
            .deadline
            .wait(&run.what, recv.read_to_end(READ_CAP))
            .await
            .expect("the probe comes back");
        Received::Bytes(back).check(&run.what, "probe", MISMATCH_PROBE);
        conn.close(0u32.into(), b"done");
        run.deadline.wait(&run.what, client.wait_idle()).await;
        expect_outcome(serving, &run.what, run.deadline, ServerOutcome::Probed).await;
        run.deadline.wait(&run.what, endpoint.wait_idle()).await;
    })
    .await;
}

/// A Quinn client asking for an identity the server's certificate does not carry. The refusal
/// counts only if Quinn's own error is the identity check: the shared bad_certificate alert,
/// and a reason naming what was asked for.
async fn quinn_refuses_the_identity(
    what: &str,
    deadline: Deadline,
    config: quinn::ClientConfig,
    addr: SocketAddr,
    asked: &str,
) {
    let mut client = quinn::Endpoint::client(localhost()).expect("the quinn client binds");
    client.set_default_client_config(config);
    let refused = deadline
        .wait(
            what,
            client.connect(addr, asked).expect("the attempt starts"),
        )
        .await
        .expect_err("a certificate for another identity must not be accepted");
    let detail = format!("{refused:?}");
    let quinn::ConnectionError::TransportError(error) = &refused else {
        panic!("{what}: a transport error was due: {detail}");
    };
    assert_eq!(
        u64::from(error.code),
        identity_alert(),
        "{what}: the alert is bad_certificate: {detail}"
    );
    // rustls names the identity that was asked for in the error it raises, quoted as it was
    // written, which is what reaches Quinn as the reason.
    assert!(
        error.reason.contains(&format!("{asked:?}")),
        "{what}: and Quinn names the identity that was asked for: {detail}"
    );
    deadline.wait(what, client.wait_idle()).await;
}
