//! The shared DATAGRAM cases: what is sent each way, what each end must see, and the Rama side
//! of both roles.
//!
//! A datagram is one frame: what is sent arrives whole or not at all. Each case sends one out
//! and expects one back, so nothing here depends on the order of two deliveries.

use std::{net::SocketAddr, sync::Arc};

use rama::{
    quic::{ClientConfig, Connection, Endpoint, SendDatagramError, ServerConfig, TransportConfig},
    utils::octets,
};

use crate::{
    identity::{Identity, anchor_of, rama_client_config, rama_server_config},
    registry::{Case, CaseRun, Role},
    scenario::{Chunk, Received, SERVER_NAME},
    support::{Deadline, Peer, localhost, payload},
};

/// One datagram out and one back, each named by the two numbers it follows from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DatagramScenario {
    pub out: Chunk,
    pub back: Chunk,
    /// Whether this row probes the size boundary rather than carrying the fixed payload.
    ///
    /// A boundary row pins the path so the limit cannot move under it: MTU discovery off and
    /// a fixed MTU. Whatever Rama sends is then the limit itself, read immediately before the
    /// send, in whichever role it plays.
    pub at_the_boundary: bool,
}

/// Every datagram case each eligible peer runs, in both roles.
#[must_use]
pub fn datagram_cases() -> Vec<Case<DatagramScenario>> {
    vec![
        Case {
            name: "datagram-exchange",
            scenario: DatagramScenario {
                out: Chunk {
                    seed: 0x71,
                    len: 128,
                },
                back: Chunk {
                    seed: 0x72,
                    len: 96,
                },
                at_the_boundary: false,
            },
        },
        Case {
            name: "datagram-exchange-small",
            scenario: DatagramScenario {
                out: Chunk {
                    seed: 0x73,
                    len: 17,
                },
                back: Chunk {
                    seed: 0x74,
                    len: 41,
                },
                at_the_boundary: false,
            },
        },
        // Zero-length application data is valid, and is not a request for the boundary.
        Case {
            name: "datagram-empty-payload",
            scenario: DatagramScenario {
                out: Chunk { seed: 0x77, len: 0 },
                back: Chunk {
                    seed: 0x78,
                    len: 24,
                },
                at_the_boundary: false,
            },
        },
        // The API's own boundary: the largest datagram the connection reports is delivered,
        // and one byte more is refused. Whichever of these two Rama sends has its length
        // replaced by that maximum; the peer sends the other one as written.
        Case {
            name: "datagram-at-the-boundary",
            scenario: DatagramScenario {
                out: Chunk {
                    seed: 0x75,
                    len: 48,
                },
                back: Chunk {
                    seed: 0x76,
                    len: 64,
                },
                at_the_boundary: true,
            },
        },
    ]
}

/// What a peer says about the datagram it received and the size it may send.
#[derive(Debug, Clone, Default)]
pub struct DatagramObservation {
    /// The largest datagram payload the peer's own connection says **it** may send, where its
    /// implementation exposes that. `None` where it does not: the adapter says so rather than
    /// reporting a configured input as though it were an observation.
    pub sendable: Option<usize>,
    /// The `max_datagram_frame_size` the peer advertises, which bounds what **Rama** may
    /// send. This is the peer's configuration as the adapter set or read it from the pinned
    /// API, not something the peer measured; `None` where the adapter cannot establish it.
    ///
    /// Kept apart from `sendable`, which is the other direction.
    pub advertised: Option<usize>,
    /// The datagram the peer received.
    pub received: Option<Received>,
}

impl DatagramObservation {
    /// Check the peer's account against what Rama actually sent, in the role Rama played.
    ///
    /// The two directions are separate: what the peer received is what Rama sent, and the
    /// limit it reports governs what it sends back. Comparing one against the other would pass
    /// for the wrong reason.
    pub fn check(&self, what: &str, scenario: &DatagramScenario, role: Role, rama_sent: Chunk) {
        // What Rama sent is passed in, since a boundary row sizes it from the connection
        // rather than from the case. What the peer sends is the case's other chunk.
        let peer_sends = match role {
            Role::RamaClient => scenario.back,
            Role::RamaServer => scenario.out,
        };
        if let Some(limit) = self.sendable {
            assert!(
                limit >= peer_sends.len,
                "{what}: the peer may send the datagram this case asks of it: {limit} against {}",
                peer_sends.len
            );
        }
        let received = self.received.as_ref().expect("the peer received one");
        received.check(what, "datagram", rama_sent);
    }

    /// What Rama may send towards this peer, against the frame the peer advertised. The
    /// limit is Rama's own; the bound is the peer's. Skipped where the adapter could not
    /// establish the advertisement.
    ///
    /// # Panics
    /// If Rama would send more than the peer said it would take.
    pub fn bounds(&self, what: &str, rama_limit: usize) {
        let Some(advertised) = self.advertised else {
            return;
        };
        assert!(
            rama_limit <= advertised,
            "{what}: rama's datagram limit {rama_limit} exceeds the {advertised} the peer advertised"
        );
    }
}

/// The MTU a boundary row pins its path to, comfortably above the smallest a QUIC path may
/// carry and below what loopback would discover.
const PINNED_MTU: u16 = 1300;

/// A transport whose path cannot move under a boundary row. `max_datagram_size` and
/// `send_datagram` take the connection lock separately, so discovery running between them
/// could change the limit a case just read; an ordinary row keeps discovery on.
fn pinned_path() -> Arc<TransportConfig> {
    let mut transport = TransportConfig::default();
    transport.unset_mtu_discovery_config();
    transport.set_initial_mtu(PINNED_MTU);
    transport.set_min_mtu(PINNED_MTU);
    Arc::new(transport)
}

/// The client configuration a row runs with: the path is pinned for a boundary row and left
/// to discovery otherwise.
fn client_config_for(identity: &Identity, boundary: bool) -> ClientConfig {
    let config = rama_client_config(anchor_of(identity));
    match boundary {
        true => config.with_transport_config(pinned_path()),
        false => config,
    }
}

/// The same for the serving side.
fn server_config_for(identity: &Identity, boundary: bool) -> ServerConfig {
    let config = rama_server_config(identity);
    match boundary {
        true => config.with_transport_config(pinned_path()),
        false => config,
    }
}

/// Rama as the client: connect, send one datagram, read the one that comes back.
pub async fn rama_client_side(
    run: &CaseRun<DatagramScenario>,
    peer_addr: SocketAddr,
) -> RamaDatagramClient {
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
                    client_config_for(identity, scenario.at_the_boundary),
                    peer_addr,
                    SERVER_NAME,
                )
                .expect("the attempt starts"),
        )
        .await
        .expect("the handshake completes");
    let (limit, sent) = exchange(
        what,
        &connection,
        *deadline,
        scenario.out,
        scenario.back,
        scenario.at_the_boundary,
    )
    .await;
    RamaDatagramClient {
        endpoint,
        connection,
        limit,
        sent,
    }
}

/// A Rama client that has exchanged its datagrams and not yet closed.
#[derive(Debug)]
pub struct RamaDatagramClient {
    pub endpoint: Endpoint,
    pub connection: Connection,
    /// The largest datagram Rama said it could send on this connection.
    pub limit: usize,
    /// The payload it actually sent, which is the case's own for an ordinary row and the
    /// limit itself for a boundary row.
    pub sent: Chunk,
}

impl RamaDatagramClient {
    pub async fn close(self, what: &str, deadline: Deadline) {
        self.connection.close(0u32, b"done");
        deadline.wait(what, self.endpoint.wait_idle()).await;
    }
}

/// Rama as the server: accept, read the datagram that arrives, send the answering one.
///
/// The peer joins on the limit Rama reported and the payload it sent, which a boundary row
/// sizes from the connection rather than from the case.
pub async fn rama_server_side(
    run: &CaseRun<DatagramScenario>,
) -> (Endpoint, SocketAddr, Peer<(usize, Chunk)>) {
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
                server_config_for(identity, run.scenario.at_the_boundary),
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
            // The peer sends first in this role, so the answering datagram is the one Rama
            // receives and `back` the one it sends.
            let arrived = run
                .deadline
                .wait(&run.what, conn.read_datagram())
                .await
                .expect("a datagram arrives");
            Received::Bytes(arrived.to_vec()).check(&run.what, "datagram", run.scenario.out);
            let sent = send_sized(
                &run.what,
                run.deadline,
                &conn,
                run.scenario.back,
                run.scenario.at_the_boundary,
                true,
            )
            .await;
            run.deadline.wait(&run.what, conn.closed()).await;
            sent
        }
    });
    (server, addr, serving)
}

/// Send one datagram and read the one that answers it.
async fn exchange(
    what: &str,
    conn: &Connection,
    deadline: Deadline,
    out: Chunk,
    back: Chunk,
    boundary: bool,
) -> (usize, Chunk) {
    let (limit, out) = send_sized(what, deadline, conn, out, boundary, false).await;
    let arrived = deadline
        .wait(what, conn.read_datagram())
        .await
        .expect("a datagram comes back");
    Received::Bytes(arrived.to_vec()).check(what, "datagram", back);
    (limit, out)
}

/// The payload a row sends: the one it names, or the connection's own limit read immediately
/// before the send where the row probes the boundary. A boundary row then requires one byte
/// more to be refused, reading the limit again at that moment: a stale value cannot stand in
/// for a live one, and a path that moved between the two is what the pinning exists to stop.
///
/// The reported maximum reserves more than the header a frame of that size needs, so what
/// this establishes is that it is deliverable and that one byte more is refused, not that it
/// is exact to the byte.
///
/// # Panics
/// If an oversized datagram is accepted, or refused for another reason.
async fn send_sized(
    what: &str,
    deadline: Deadline,
    conn: &Connection,
    out: Chunk,
    boundary: bool,
    waiting: bool,
) -> (usize, Chunk) {
    let Chunk { seed, .. } = out;
    let out = match boundary {
        true => Chunk {
            seed,
            len: conn
                .max_datagram_size()
                .expect("the peer offered the extension"),
        },
        false => out,
    };
    let limit = send_one(what, deadline, conn, out, waiting).await;
    if boundary {
        let live = conn
            .max_datagram_size()
            .expect("the peer offered the extension");
        assert_eq!(
            live, limit,
            "{what}: the pinned path moved under this row: {limit} then {live}"
        );
        let refused = conn
            .send_datagram(payload(seed, live + 1).into())
            .expect_err("a datagram over the limit is refused");
        assert_eq!(
            refused,
            SendDatagramError::TooLarge,
            "{what}: unexpected refusal for {} bytes against a live limit of {live}",
            live + 1
        );
        // And a size beyond any path, so one refusal does not stand on where the limit sits.
        let beyond = conn
            .send_datagram(payload(seed, octets::kib(64)).into())
            .expect_err("a datagram larger than any path could carry is refused");
        assert_eq!(
            beyond,
            SendDatagramError::TooLarge,
            "{what}: unexpected refusal for a datagram beyond any path"
        );
    }
    (limit, out)
}

/// Send one datagram, having checked the connection admits one of that size. Answers the
/// limit this side reported, which a case compares against what the peer advertised.
///
/// The answering side waits for room rather than refusing; the opening side, which has a
/// whole buffer to itself, does not.
async fn send_one(
    what: &str,
    deadline: Deadline,
    conn: &Connection,
    chunk: Chunk,
    waiting: bool,
) -> usize {
    let limit = conn
        .max_datagram_size()
        .expect("the peer offered the extension");
    assert!(
        limit >= chunk.len,
        "{what}: the negotiated size admits this datagram: {limit} against {}",
        chunk.len
    );
    let bytes = chunk.bytes().into();
    match waiting {
        true => deadline
            .wait(what, conn.send_datagram_wait(bytes))
            .await
            .expect("the datagram is accepted once there is room"),
        false => conn.send_datagram(bytes).expect("the datagram is accepted"),
    }
    limit
}

#[cfg(test)]
mod tests;
