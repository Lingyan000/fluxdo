//! The shared server-name cases: the name a client asks for, and the absence of one when it
//! connects to an address.
//!
//! Two observations are involved and they are not equally available. What **Rama's** server saw
//! is `handshake_data().server_name` and every peer can drive it. What the **peer's** server saw
//! depends on that implementation exposing it, which is a bridge question rather than a
//! protocol one; [`ReceivedName::Unavailable`] carries that, and the case still runs.

use std::net::SocketAddr;

use rama::{extensions::ExtensionsRef as _, quic::NegotiatedTlsParameters};
use rama::{
    net::address::Domain,
    quic::{Connection, ConnectionError, Endpoint},
    utils::octets,
};

#[cfg(not(feature = "boring"))]
use rama::{
    crypto::pki_types::ServerName,
    tls::rustls::dep::rustls::{self, CertificateError},
};

use crate::{
    identity::{
        Identity, IssuedIdentities, IssuedIdentity, address_identity, address_identity_v6, alpn,
        anchor_of, another_address_identity, another_named_identity, rama_client_config,
        rama_server_config, server_identity,
    },
    registry::{Case, CaseRun},
    scenario::{ANOTHER_ADDRESS, ANOTHER_NAME, Chunk, Received, SERVER_NAME},
    support::{Peer, localhost, localhost_v6},
};

const READ_CAP: usize = octets::kib(64);

/// What a name case asks for, and the probe that proves the connection works afterwards.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NameScenario {
    /// The name the client asks for, or none when it connects to an address literal.
    pub asked: Option<&'static str>,
    /// Where the serving side binds, which is what makes a case run over one socket family
    /// or the other. The identity a case asks for is separate from this.
    pub bind: SocketAddr,
    pub probe: Chunk,
}

/// A case where the server's certificate does not match what the client asks for, while still
/// chaining to an anchor the client trusts. That is what separates this from the trust family:
/// the issuer is fine and only the identity is wrong.
///
/// Both shapes the native tests cover are here, built from the two identities the shared
/// module already makes: a certificate for the address while a name is asked for, and a
/// certificate for the name while the address is asked for.
///
/// The two directions hold different halves fixed. With Rama's client the certificate stays
/// the same and the request varies. With a peer's client the request stays the same and the
/// served identity varies, because for some peers the request decides the verification mode
/// itself: quiche installs an identity parameter only alongside SNI, so a request that changed
/// from a name to an address would change what is checked and would be no control at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mismatch {
    /// The certificate carries the loopback address; the client asks for the name.
    CertificateForAddress,
    /// The certificate carries the name; the client asks for the address.
    CertificateForName,
    /// The certificate carries one name; the client asks for another name.
    CertificateForAnotherName,
    /// The certificate carries one address; the client asks for another address.
    CertificateForAnotherAddress,
}

impl Mismatch {
    /// The identity the server presents.
    #[must_use]
    pub fn identity(self) -> Identity {
        match self {
            Self::CertificateForAddress => address_identity(),
            Self::CertificateForName => server_identity(),
            Self::CertificateForAnotherName => another_named_identity(),
            Self::CertificateForAnotherAddress => another_address_identity(),
        }
    }

    /// What the client asks for. The case's own certificate is not valid for it: with Rama's
    /// client the control asks for something else, and with a peer's client the control serves
    /// something else.
    #[must_use]
    pub fn requested(self, peer: SocketAddr) -> String {
        match self {
            Self::CertificateForAddress | Self::CertificateForAnotherName => SERVER_NAME.to_owned(),
            Self::CertificateForName | Self::CertificateForAnotherAddress => peer.ip().to_string(),
        }
    }

    /// What the client asks for in the control, which the same certificate is valid for.
    #[must_use]
    pub fn matching_request(self, peer: SocketAddr) -> String {
        match self {
            Self::CertificateForAddress => peer.ip().to_string(),
            Self::CertificateForName => SERVER_NAME.to_owned(),
            Self::CertificateForAnotherName => ANOTHER_NAME.to_owned(),
            Self::CertificateForAnotherAddress => ANOTHER_ADDRESS.to_owned(),
        }
    }

    /// Of an issued pair, the identity a peer-client case serves when the request must not
    /// match it.
    #[must_use]
    pub fn served_by(self, pair: &IssuedIdentities) -> &IssuedIdentity {
        match self {
            Self::CertificateForAddress => &pair.for_address,
            Self::CertificateForName => &pair.for_name,
            Self::CertificateForAnotherName => &pair.for_another_name,
            Self::CertificateForAnotherAddress => &pair.for_another_address,
        }
    }

    /// And the one its control serves, which the same request does match. Both come from the
    /// same authority, so nothing the client trusts changes between them.
    #[must_use]
    pub fn matched_by(self, pair: &IssuedIdentities) -> &IssuedIdentity {
        match self {
            Self::CertificateForAddress => &pair.for_name,
            Self::CertificateForAnotherName => &pair.for_name,
            Self::CertificateForName => &pair.for_address,
            Self::CertificateForAnotherAddress => &pair.for_address,
        }
    }
}

/// The QUIC error a peer's client raises when the certificate carries the wrong identity.
///
/// A TLS alert reaches QUIC as CRYPTO_ERROR plus the alert's own number (RFC 9001 §4.8), and
/// every peer here answers this with bad_certificate: rustls maps `NotValidForName` to it
/// (`rustls/src/error.rs`), the BoringSSL quiche vendors maps `X509_V_ERR_HOSTNAME_MISMATCH` to
/// it (`ssl/ssl_x509.cc`), and aioquic raises `AlertBadCertificate` (`aioquic/tls.py`).
#[must_use]
pub fn identity_alert() -> u64 {
    0x100 + u64::from(crate::backend::BAD_CERTIFICATE)
}

/// The probe the control carries, so acceptance means a working connection and not merely a
/// handshake.
pub const MISMATCH_PROBE: Chunk = Chunk {
    seed: 0xb1,
    len: 320,
};

/// Every mismatched-identity case each eligible peer runs.
#[must_use]
pub fn mismatch_cases() -> Vec<Case<Mismatch>> {
    vec![
        Case {
            name: "identity-mismatch-name-asked",
            scenario: Mismatch::CertificateForAddress,
        },
        Case {
            name: "identity-mismatch-address-asked",
            scenario: Mismatch::CertificateForName,
        },
        Case {
            name: "identity-mismatch-another-name",
            scenario: Mismatch::CertificateForAnotherName,
        },
        Case {
            name: "identity-mismatch-another-address",
            scenario: Mismatch::CertificateForAnotherAddress,
        },
    ]
}

/// Rama's client against a server whose certificate is for something else: the attempt must
/// fail on the identity, naming what was asked for, and nothing may pass first.
pub async fn rama_client_refuses_the_identity(run: &CaseRun<Mismatch>, peer_addr: SocketAddr) {
    let CaseRun {
        what,
        deadline,
        identity,
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
    let asked = scenario.requested(peer_addr);
    let refused = deadline
        .wait(
            what,
            client
                .connect_with(rama_client_config(anchor_of(identity)), peer_addr, &asked)
                .expect("the attempt starts"),
        )
        .await
        .expect_err("a certificate for another identity must not be accepted");
    let ConnectionError::TransportError(error) = &refused else {
        panic!("{what}: the attempt ended on a transport error: {refused:?}");
    };
    // The wire carries the alert; the cause below is what went wrong locally.
    assert_eq!(
        error.code().tls_alert(),
        Some(crate::backend::BAD_CERTIFICATE),
        "{what}: unexpected TLS alert ({})",
        error.reason()
    );
    // The anchor is trusted, so this must be the identity check and not the issuer.
    #[cfg(feature = "boring")]
    crate::backend::assert_certificate_failure(error);
    #[cfg(not(feature = "boring"))]
    {
        let cause = error
            .cause()
            .and_then(|cause| cause.downcast_ref::<rustls::Error>())
            .unwrap_or_else(|| panic!("{what}: a rustls cause was due: {:?}", error.cause()));
        let rustls::Error::InvalidCertificate(CertificateError::NotValidForNameContext {
            expected,
            presented,
        }) = cause
        else {
            panic!("{what}: the identity check was due, not {cause:?}");
        };
        // Compared as an identity rather than as text: an address is not spelled the same way in
        // the debug output as it is in the request.
        let wanted = ServerName::try_from(asked.as_str())
            .unwrap_or_else(|_| panic!("{what}: the request is a usable identity"))
            .to_owned();
        assert_eq!(
            *expected, wanted,
            "{what}: the context names the identity that was asked for"
        );
        // What the certificate is valid for is what the control asks for.
        let carried = scenario.matching_request(peer_addr);
        assert!(
            presented.iter().any(|name| name.contains(&carried)),
            "{what}: the certificate did not carry {carried}: {presented:?}"
        );
    }
    deadline.wait(what, client.wait_idle()).await;
}

/// The control: the same server certificate, and a client asking for what it is valid for.
/// The probe crosses both ways, so acceptance is a working connection.
pub async fn rama_client_accepts_the_identity(run: &CaseRun<Mismatch>, peer_addr: SocketAddr) {
    let CaseRun {
        what,
        deadline,
        identity,
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
    let asked = scenario.matching_request(peer_addr);
    let conn = deadline
        .wait(
            what,
            client
                .connect_with(rama_client_config(anchor_of(identity)), peer_addr, &asked)
                .expect("the attempt starts"),
        )
        .await
        .expect("the identity it asks for is the one presented");
    let (mut send, mut recv) = deadline
        .wait(what, conn.open_bi())
        .await
        .expect("a bi stream");
    deadline
        .wait(what, send.write_all(&MISMATCH_PROBE.bytes()))
        .await
        .expect("the probe is written");
    send.finish().expect("the probe ends");
    let back = deadline
        .wait(what, recv.read_to_end(READ_CAP))
        .await
        .expect("the probe comes back");
    Received::Bytes(back).check(what, "probe", MISMATCH_PROBE);
    conn.close(0u32, b"done");
    deadline.wait(what, client.wait_idle()).await;
}

/// Every name case each eligible peer runs.
#[must_use]
pub fn name_cases() -> Vec<Case<NameScenario>> {
    vec![
        Case {
            name: "name-asked",
            scenario: NameScenario {
                asked: Some(SERVER_NAME),
                bind: localhost(),
                probe: Chunk {
                    seed: 0xa1,
                    len: 256,
                },
            },
        },
        // RFC 6066 §3: a client connecting to an address literal sends no name at all. The
        // socket family is separate from the shape of the name, so it runs over both.
        Case {
            name: "name-absent",
            scenario: NameScenario {
                asked: None,
                bind: localhost(),
                probe: Chunk {
                    seed: 0xa2,
                    len: 192,
                },
            },
        },
        Case {
            name: "name-absent-over-ipv6",
            scenario: NameScenario {
                asked: None,
                bind: localhost_v6(),
                probe: Chunk {
                    seed: 0xa3,
                    len: 208,
                },
            },
        },
    ]
}

/// What a peer's own side says about the name it received.
///
/// `Seen(None)` and `Unavailable` are different facts and are kept apart: the first is the peer
/// reporting that no name was sent, the second is the peer having no way to report at all. A
/// case whose diagnostic is unavailable still runs; only that one assertion is withheld.
#[derive(Debug, Clone)]
pub enum ReceivedName {
    /// The peer reported the name it received, or reported that none was sent.
    Seen(Option<String>),
    /// This peer's bridge exposes no such observation, for the reason given.
    Unavailable(&'static str),
}

/// What the peer's own side reports about the name it received.
#[derive(Debug, Clone)]
pub struct NameObservation {
    pub server_name: ReceivedName,
}

impl NameObservation {
    /// Check the peer's report where there is one. Returns whether the assertion was made, so
    /// a caller can say which combinations carried it.
    pub fn check(&self, what: &str, scenario: &NameScenario) -> bool {
        match &self.server_name {
            ReceivedName::Seen(seen) => {
                assert_eq!(
                    seen.as_deref(),
                    scenario.asked,
                    "{what}: the name the peer says the client asked for"
                );
                true
            }
            ReceivedName::Unavailable(_) => false,
        }
    }
}

/// The identity a case's server presents: one valid for the loopback address when no name is
/// asked for, and one valid for the name otherwise.
#[must_use]
pub fn identity_for(scenario: &NameScenario) -> Identity {
    match (scenario.asked, scenario.bind.is_ipv6()) {
        (Some(_), _) => server_identity(),
        (None, false) => address_identity(),
        (None, true) => address_identity_v6(),
    }
}

/// Rama as the client, asking for the case's name or for none, then proving the connection
/// carries traffic.
pub async fn rama_client_side(run: &CaseRun<NameScenario>, peer_addr: SocketAddr) {
    let CaseRun {
        what,
        deadline,
        identity,
        scenario,
        ..
    } = run;
    // On the family the peer bound, so a case over IPv6 reaches an IPv6 peer.
    let client = deadline
        .wait(
            what,
            Endpoint::bind_client(rama::rt::Executor::new(), bound_like(peer_addr)),
        )
        .await
        .expect("the rama client binds");
    // Asking for nothing means naming the address itself, which is how RFC 6066 §3 says a
    // client with no name to send behaves.
    let asked = scenario
        .asked
        .map_or_else(|| peer_addr.ip().to_string(), str::to_owned);
    let conn = deadline
        .wait(
            what,
            client
                .connect_with(rama_client_config(anchor_of(identity)), peer_addr, &asked)
                .expect("the attempt starts"),
        )
        .await
        .expect("the handshake completes");
    probe(what, &conn, run).await;
    conn.close(0u32, b"done");
    deadline.wait(what, client.wait_idle()).await;
}

/// Rama as the server: it reports the name the peer asked for, which is the observation this
/// family is about, then answers the probe.
pub async fn rama_server_side(run: &CaseRun<NameScenario>) -> (Endpoint, SocketAddr, Peer<()>) {
    let CaseRun { what, deadline, .. } = run;
    let server = deadline
        .wait(
            what,
            Endpoint::bind_server(
                rama::rt::Executor::new(),
                rama_server_config(&run.identity),
                run.scenario.bind,
            ),
        )
        .await
        .expect("the rama server binds");
    let addr = server.local_addr().expect("its address");
    let serving = Peer::spawn({
        let run = run.clone();
        let server = server.clone();
        async move {
            let attempt = run
                .deadline
                .wait(&run.what, server.accept())
                .await
                .expect("an attempt arrives");
            let conn = run
                .deadline
                .wait(&run.what, attempt)
                .await
                .expect("the handshake completes");
            let settled = conn
                .extensions()
                .get_ref::<NegotiatedTlsParameters>()
                .cloned()
                .expect("the handshake settled something");
            assert_eq!(
                settled.server_name,
                run.scenario.asked.map(Domain::from_static),
                "{}: the name rama's server says the client asked for",
                run.what
            );
            assert_eq!(
                settled.application_layer_protocol.as_ref(),
                Some(&alpn()),
                "{}: unexpected negotiated protocol",
                run.what
            );
            answer(&run.what, &conn, &run).await;
            run.deadline.wait(&run.what, conn.closed()).await;
        }
    });
    (server, addr, serving)
}

/// Send the probe and read it back.
async fn probe(what: &str, conn: &Connection, run: &CaseRun<NameScenario>) {
    let deadline = run.deadline;
    let (mut send, mut recv) = deadline
        .wait(what, conn.open_bi())
        .await
        .expect("a bi stream");
    deadline
        .wait(what, send.write_all(&run.scenario.probe.bytes()))
        .await
        .expect("the probe is written");
    send.finish().expect("the probe ends");
    let back = deadline
        .wait(what, recv.read_to_end(READ_CAP))
        .await
        .expect("the probe comes back");
    Received::Bytes(back).check(what, "probe", run.scenario.probe);
}

/// Read the probe and send it back.
async fn answer(what: &str, conn: &Connection, run: &CaseRun<NameScenario>) {
    let deadline = run.deadline;
    let (mut send, mut recv) = deadline
        .wait(what, conn.accept_bi())
        .await
        .expect("the probe's stream arrives");
    let received = deadline
        .wait(what, recv.read_to_end(READ_CAP))
        .await
        .expect("the probe completes");
    Received::Bytes(received).check(what, "probe", run.scenario.probe);
    deadline
        .wait(what, send.write_all(&run.scenario.probe.bytes()))
        .await
        .expect("the probe goes back");
    send.finish().expect("the answer ends");
}

/// A local address on the same socket family as `peer`, so a client reaches it.
fn bound_like(peer: SocketAddr) -> SocketAddr {
    match peer.is_ipv6() {
        true => localhost_v6(),
        false => localhost(),
    }
}
