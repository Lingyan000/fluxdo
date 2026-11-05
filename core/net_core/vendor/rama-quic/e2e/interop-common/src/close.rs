//! The shared close cases: an application close carrying a code and a reason, read back by the
//! other side, sent after an exchange or immediately after the handshake.
//!
//! What a case checks is what the side that did not close was told: the code and the reason.
//! The side that closes is always the one that opened the exchange, so it has read the answer
//! before it closes. A close is not a promise that anything still in flight arrives — RFC 9000
//! §10.2 lets the peer drop what it had buffered — and no case here depends on one.
//!
//! Each role covers one direction of the reporting: with Rama as the client, Rama closes and
//! the peer reports; with Rama as the server, the peer's client closes and Rama reports.

use std::net::SocketAddr;

use rama::{
    quic::{ConnectionError, Endpoint, proto::VarInt},
    utils::octets,
};

use crate::{
    identity::{anchor_of, rama_client_config, rama_server_config},
    registry::{Case, CaseRun},
    scenario::{Chunk, SERVER_NAME, answer, exchange},
    support::{Peer, localhost},
};

/// One close case: what is said, and whether anything crosses first.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CloseScenario {
    /// The application code the closing side gives.
    pub code: u32,
    /// The reason it gives with it.
    pub reason: &'static [u8],
    /// An exchange before the close, where the case has one. A case without it closes as soon
    /// as the handshake is through.
    pub first: Option<Chunk>,
}

/// Every close case each eligible peer runs.
#[must_use]
pub fn close_cases() -> Vec<Case<CloseScenario>> {
    vec![
        Case {
            name: "close-after-an-exchange",
            scenario: CloseScenario {
                code: 0x2a,
                reason: b"that is all",
                first: Some(Chunk {
                    seed: 0xf1,
                    len: octets::kib(2),
                }),
            },
        },
        // The close is the first thing the application does with the connection, so it goes
        // out while the handshake's own packets are still settling.
        Case {
            name: "close-right-after-the-handshake",
            scenario: CloseScenario {
                code: 0,
                reason: b"immediate",
                first: None,
            },
        },
    ]
}

/// What the peer's application was told about the close.
#[derive(Debug, Clone)]
pub struct CloseObservation {
    pub code: u64,
    pub reason: Vec<u8>,
    /// Whether the close was an application close rather than a transport one. This is the
    /// frame's category and says nothing about which side sent it.
    pub application: bool,
    /// Whether this side observed the close arriving, where its own API establishes that.
    /// `None` where the peer exposes no way to tell a received close from a local one.
    pub received: Option<bool>,
}

impl CloseObservation {
    pub fn check(&self, what: &str, scenario: &CloseScenario) {
        self.says(what, u64::from(scenario.code), scenario.reason);
    }

    /// The same against a code and a reason given directly, for a family whose cases carry no
    /// close scenario of their own.
    ///
    /// Origin is checked only where the peer establishes it; a `None` there is an
    /// unavailable observation, not a passing one.
    ///
    /// # Panics
    /// If the close was not an application close, if this side can tell it was not received,
    /// or if its code or reason differ.
    pub fn says(&self, what: &str, code: u64, reason: &[u8]) {
        assert!(
            self.application,
            "{what}: transport close where an application close was due"
        );
        assert_ne!(
            self.received,
            Some(false),
            "{what}: close originated locally rather than arriving from the peer"
        );
        assert_eq!(self.code, code, "{what}: unexpected close code");
        assert_eq!(
            self.reason,
            reason,
            "{what}: unexpected close reason ({})",
            String::from_utf8_lossy(&self.reason)
        );
    }
}

/// Rama's client for a close case: it connects, waits for the peer to have settled its own
/// handshake, exchanges where the case has an exchange, and closes with the case's code and
/// reason.
///
/// `peer_is_ready` is how the adapter waits for its own side: a close sent while the peer is
/// still finishing the handshake may reach a peer that cannot read it yet, and what these
/// cases are about is the close itself, not that race. The case that closes straight after
/// still sends no application data at all.
pub async fn rama_client_closes<Ready, Waiting>(
    run: &CaseRun<CloseScenario>,
    addr: SocketAddr,
    peer_is_ready: Ready,
) where
    Ready: FnOnce() -> Waiting,
    Waiting: Future<Output = ()>,
{
    let CaseRun {
        what,
        deadline,
        scenario,
        identity,
        ..
    } = run;
    let client = deadline
        .wait(
            what,
            Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
        )
        .await
        .expect("the rama client binds");
    let connection = deadline
        .wait(
            what,
            client
                .connect_with(rama_client_config(anchor_of(identity)), addr, SERVER_NAME)
                .expect("the attempt starts"),
        )
        .await
        .expect("the handshake completes");
    peer_is_ready().await;
    if let Some(first) = scenario.first {
        exchange(what, *deadline, &connection, first).await;
    }
    connection.close(VarInt::from(scenario.code), scenario.reason);
    deadline.wait(what, client.wait_idle()).await;
}

/// Rama's server for the other direction: it answers the exchange where there is one, and says
/// what it was told when the peer closed.
pub async fn rama_server_side(
    run: &CaseRun<CloseScenario>,
) -> (Endpoint, SocketAddr, Peer<CloseObservation>) {
    let CaseRun { what, deadline, .. } = run;
    let (what, deadline, scenario) = (what.clone(), *deadline, run.scenario);
    let server = deadline
        .wait(
            &what,
            Endpoint::bind_server(
                rama::rt::Executor::new(),
                rama_server_config(&run.identity),
                localhost(),
            ),
        )
        .await
        .expect("the rama server binds");
    let addr = server.local_addr().expect("its address");
    let serving = Peer::spawn({
        let server = server.clone();
        async move {
            let connection = deadline
                .wait(&what, server.accept())
                .await
                .expect("an attempt arrives")
                .await
                .expect("the handshake completes");
            if let Some(first) = scenario.first {
                answer(&what, deadline, &connection, first).await;
            }
            told(&what, deadline.wait(&what, connection.closed()).await)
        }
    });
    (server, addr, serving)
}

/// What Rama's side was told when the peer closed.
#[must_use]
pub fn told(what: &str, ended: ConnectionError) -> CloseObservation {
    let ConnectionError::ApplicationClosed(ref close) = ended else {
        panic!("{what}: the peer closed the connection rather than it failing: {ended:?}");
    };
    // The variant is the derivation: rama reports `LocallyClosed` for a close of its own and
    // a transport error for a transport close, so reaching here establishes both facts.
    CloseObservation {
        code: u64::from(close.error_code()),
        reason: close.reason().to_vec(),
        application: true,
        received: Some(true),
    }
}
