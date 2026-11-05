//! A peer that never offered the DATAGRAM extension: what Rama reports, what it refuses, and
//! the ordinary exchange the same connection still carries.

use std::net::SocketAddr;

use rama::{
    quic::{Connection, Endpoint, SendDatagramError},
    utils::octets,
};

use crate::{
    identity::{anchor_of, rama_client_config, rama_server_config},
    registry::{Case, CaseRun},
    scenario::{Chunk, RamaClient, Received, SERVER_NAME, answer, exchange},
    support::{Peer, localhost},
};

/// A peer that never offered the extension, and the exchange the connection carries anyway.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UnsupportedScenario {
    /// The datagram whose send must be refused. Nothing carries it, so only its size matters.
    pub refused: Chunk,
    /// What goes over an ordinary stream instead, and comes back.
    pub carried: Chunk,
}

/// The unsupported case each peer that can withhold the extension runs, in both roles.
#[must_use]
pub fn unsupported_cases() -> Vec<Case<UnsupportedScenario>> {
    vec![Case {
        name: "datagram-unsupported",
        scenario: UnsupportedScenario {
            refused: Chunk {
                seed: 0x79,
                len: 64,
            },
            carried: Chunk {
                seed: 0x7a,
                len: octets::kib(4),
            },
        },
    }]
}

/// What the peer saw on a connection where it offered no datagram size.
#[derive(Debug, Clone, Default)]
pub struct UnsupportedObservation {
    /// A datagram the peer's own implementation says arrived, which must be none. Every
    /// adapter establishes this: nothing was ever sent, so anything here is a defect.
    pub datagram: Option<Received>,
    /// The exchange it carried instead.
    pub carried: Option<Received>,
}

impl UnsupportedObservation {
    /// Check the peer's account of a connection without the extension.
    pub fn check(&self, what: &str, scenario: &UnsupportedScenario) {
        assert!(
            self.datagram.is_none(),
            "{what}: a peer that offered no datagram size was sent one of {} bytes",
            self.datagram.as_ref().map_or(0, Received::len)
        );
        self.carried
            .as_ref()
            .expect("the peer carried the exchange")
            .check(what, "exchange", scenario.carried);
    }
}

/// What a connection to a peer that never offered the extension reports: no size to send, and
/// a refusal that names the reason.
///
/// # Panics
/// If a size is reported, or a datagram is accepted, or refused for another reason.
fn refused(what: &str, conn: &Connection, chunk: Chunk) {
    assert!(
        conn.max_datagram_size().is_none(),
        "{what}: there is no size to send to: the peer offered none"
    );
    let refusal = conn
        .send_datagram(chunk.bytes().into())
        .expect_err("a peer that did not offer the extension must not be sent one");
    assert_eq!(
        refusal,
        SendDatagramError::UnsupportedByPeer,
        "{what}: and the refusal says why"
    );
}

/// Rama as the client against a peer without the extension: the refusal, then an ordinary
/// exchange over the same connection.
pub async fn rama_client_without_datagrams(
    run: &CaseRun<UnsupportedScenario>,
    peer_addr: SocketAddr,
) -> RamaClient {
    let CaseRun {
        what,
        identity,
        deadline,
        scenario,
        ..
    } = run;
    let endpoint = deadline
        .wait(
            what,
            Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
        )
        .await
        .expect("the rama client binds");
    let connection = deadline
        .wait(
            what,
            endpoint
                .connect_with(
                    rama_client_config(anchor_of(identity)),
                    peer_addr,
                    SERVER_NAME,
                )
                .expect("the attempt starts"),
        )
        .await
        .expect("the handshake completes");
    refused(what, &connection, scenario.refused);
    exchange(what, *deadline, &connection, scenario.carried).await;
    RamaClient {
        endpoint,
        connection,
    }
}

/// The same with Rama serving: the refusal, then the exchange the peer opens.
pub async fn rama_server_without_datagrams(
    run: &CaseRun<UnsupportedScenario>,
) -> (Endpoint, SocketAddr, Peer<()>) {
    let CaseRun {
        what,
        deadline,
        identity,
        ..
    } = run;
    let server = deadline
        .wait(
            what,
            Endpoint::bind_server(
                rama::rt::Executor::new(),
                rama_server_config(identity),
                localhost(),
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
            refused(&run.what, &conn, run.scenario.refused);
            answer(&run.what, run.deadline, &conn, run.scenario.carried).await;
            run.deadline.wait(&run.what, conn.closed()).await;
        }
    });
    (server, addr, serving)
}

#[cfg(test)]
mod tests;
