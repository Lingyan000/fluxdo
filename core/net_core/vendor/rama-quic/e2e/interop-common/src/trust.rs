//! The shared certificate-trust cases: a peer whose identity is not trusted is refused, and the
//! same peer with the right anchor is not.
//!
//! Both halves belong to one case. A refusal on its own says nothing: it could come from any
//! handshake failure, so the control that follows uses the same identity and the right anchor
//! and has to succeed.

use std::net::SocketAddr;

use rama::{
    crypto::pki_types::CertificateDer,
    quic::{ConnectionError, Endpoint},
};

#[cfg(not(feature = "boring"))]
use rama::tls::rustls::dep::rustls::{self, CertificateError};

use crate::{
    identity::{anchor_of, identity_from_a_stranger, rama_client_config},
    registry::{Case, CaseRun},
    scenario::{Chunk, Received, SERVER_NAME},
    support::localhost,
};

/// The exchange the positive control carries, so the control proves a working connection and
/// not merely a handshake.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TrustScenario {
    pub probe: Chunk,
}

/// An anchor for an issuer nothing in a case was signed by. Both phases of a case serve the
/// same identity; this is what the first phase trusts instead of it, so the only thing that
/// changes between the two is the anchor.
#[must_use]
pub fn wrong_anchor() -> CertificateDer<'static> {
    anchor_of(&identity_from_a_stranger("Another Authority"))
}

/// Every trust case each eligible peer runs.
#[must_use]
pub fn trust_cases() -> Vec<Case<TrustScenario>> {
    vec![Case {
        name: "trust-refusal",
        scenario: TrustScenario {
            probe: Chunk {
                seed: 0x91,
                len: 512,
            },
        },
    }]
}

/// What a peer says about the refusal it saw. The detail is that implementation's own, kept so
/// an adapter can assert on it without the shared code pretending to understand it.
#[derive(Debug, Clone, Default)]
pub struct TrustObservation {
    /// Whether the peer's own implementation reports the handshake as refused.
    pub refused: bool,
    /// What it said about why, in its own words.
    pub detail: Option<String>,
}

impl TrustObservation {
    pub fn check(&self, what: &str) {
        assert!(
            self.refused,
            "{what}: the peer saw the handshake refused, and said: {:?}",
            self.detail
        );
    }
}

/// Rama's client against a server it has no anchor for: the attempt must fail on the
/// certificate, named as such, and no frame is at fault.
pub async fn rama_client_refuses(
    run: &CaseRun<TrustScenario>,
    peer_addr: SocketAddr,
) -> ConnectionError {
    let CaseRun { what, deadline, .. } = run;
    let client = deadline
        .wait(
            what,
            Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
        )
        .await
        .expect("the rama client binds");
    let refused = deadline
        .wait(
            what,
            client
                .connect_with(rama_client_config(wrong_anchor()), peer_addr, SERVER_NAME)
                .expect("the attempt starts"),
        )
        .await
        .expect_err("a server it does not trust must not get a connection");
    let ConnectionError::TransportError(error) = &refused else {
        panic!("{what}: the attempt ended on a transport error: {refused:?}");
    };
    // The refusal is the certificate check and not some other handshake failure: the alert
    // says the issuer is unknown, the cause is that same check, and no frame is at fault.
    assert_eq!(
        error.code().tls_alert(),
        Some(crate::backend::UNKNOWN_CA),
        "{what}: the alert says the issuer is not one it trusts: {}",
        error.reason()
    );
    #[cfg(feature = "boring")]
    crate::backend::assert_certificate_failure(error);
    #[cfg(not(feature = "boring"))]
    assert!(
        error
            .cause()
            .and_then(|cause| cause.downcast_ref::<rustls::Error>())
            .is_some_and(|error| matches!(
                error,
                rustls::Error::InvalidCertificate(CertificateError::UnknownIssuer)
            )),
        "{what}: and the cause is the issuer, not something else: {:?}",
        error.cause()
    );
    assert_eq!(
        error.frame_type(),
        None,
        "{what}: a certificate refusal names no frame"
    );
    deadline.wait(what, client.wait_idle()).await;
    refused
}

/// The control: the same server, the anchor that does match, and a payload over the connection
/// it gets. A refusal only means something next to this.
pub async fn rama_client_accepts(run: &CaseRun<TrustScenario>, peer_addr: SocketAddr) {
    let CaseRun {
        what,
        deadline,
        scenario,
        ..
    } = run;
    let client = deadline
        .wait(
            what,
            Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
        )
        .await
        .expect("the rama client binds");
    let conn = deadline
        .wait(
            what,
            client
                .connect_with(
                    rama_client_config(anchor_of(&run.identity)),
                    peer_addr,
                    SERVER_NAME,
                )
                .expect("the attempt starts"),
        )
        .await
        .expect("the anchor that matches gets a connection");
    // The probe goes and comes back, so the control ends on the peer having answered rather
    // than on this side having written.
    let (mut send, mut recv) = deadline
        .wait(what, conn.open_bi())
        .await
        .expect("a bi stream");
    deadline
        .wait(what, send.write_all(&scenario.probe.bytes()))
        .await
        .expect("the probe is written");
    send.finish().expect("the probe ends");
    let back = deadline
        .wait(what, recv.read_to_end(scenario.probe.len + 1))
        .await
        .expect("the probe comes back");
    Received::Bytes(back).check(what, "probe", scenario.probe);
    conn.close(0u32, b"done");
    deadline.wait(what, client.wait_idle()).await;
}
