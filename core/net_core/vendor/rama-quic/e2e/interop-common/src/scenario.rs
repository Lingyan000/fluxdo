//! The baseline stream scenario: what is sent, what each end must see, and the whole Rama side
//! of it in either role.
//!
//! A peer project supplies only its own implementation's half. What that implementation read
//! comes back as a [`PeerObservation`], which this module checks against the case's parameters
//! by length and by digest.

use std::net::SocketAddr;

use rama::{extensions::ExtensionsRef as _, quic::NegotiatedTlsParameters};
use rama::{
    net::address::Domain,
    quic::{Connection, Endpoint},
    utils::octets,
};

use crate::{
    identity::{ALPN, alpn, anchor_of, rama_client_config, rama_server_config},
    registry::{CaseRun, Role},
    support::{Deadline, Peer, digest, localhost, payload},
};

/// The name a client asks for and a server reports, so both ends can assert the same thing.
pub const SERVER_NAME: &str = "localhost";

/// A second name, and a second loopback address, for the cases where a certificate carries
/// one identity of a kind and the client asks for another of the same kind.
pub const ANOTHER_NAME: &str = "elsewhere.test";
pub const ANOTHER_ADDRESS: &str = "127.0.0.2";

/// The most a scenario ever reads in one call, so a peer sending more fails rather than filling
/// memory.
const READ_CAP: usize = octets::mib(1);

/// One payload, named by the two numbers it follows from. A peer that cannot be handed bytes —
/// a child process, say — is given these instead and derives the same payload itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Chunk {
    pub seed: u8,
    pub len: usize,
}

impl Chunk {
    #[must_use]
    pub fn bytes(self) -> Vec<u8> {
        payload(self.seed, self.len)
    }

    #[must_use]
    pub fn digest(self) -> [u8; 32] {
        digest(&self.bytes())
    }
}

/// Unidirectional payloads in both directions, followed by a bidirectional exchange.
/// Every peer derives its payloads from these parameters.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamScenario {
    pub up: Chunk,
    pub down: Chunk,
    pub question: Chunk,
    pub answer: Chunk,
}

/// What one stream looked like to the peer.
///
/// A peer in this process hands over the bytes it read and they are digested here; a peer in
/// another process reports its own digest and the length it read.
#[derive(Debug, Clone)]
pub enum Received {
    /// The bytes the peer read.
    Bytes(Vec<u8>),
    /// A digest the peer computed itself, and the length it read.
    Reported { digest: [u8; 32], len: usize },
}

impl Received {
    #[must_use]
    pub fn digest(&self) -> [u8; 32] {
        match self {
            Self::Bytes(bytes) => digest(bytes),
            Self::Reported { digest, .. } => *digest,
        }
    }

    #[must_use]
    pub fn len(&self) -> usize {
        match self {
            Self::Bytes(bytes) => bytes.len(),
            Self::Reported { len, .. } => *len,
        }
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Check one stream against the chunk it was built from, by length and by digest.
    pub fn check(&self, what: &str, which: &str, chunk: Chunk) {
        assert_eq!(self.len(), chunk.len, "{what}: the whole {which}");
        assert_eq!(
            self.digest(),
            chunk.digest(),
            "{what}: the {which} is intact"
        );
    }
}

/// What a peer implementation reports. Each field is what its adapter passed on from that
/// implementation: the bytes it read, or a digest it computed.
#[derive(Debug, Clone, Default)]
pub struct PeerObservation {
    /// The protocol the peer's own handshake settled on.
    pub protocol: Option<Vec<u8>>,
    /// The unidirectional payload the peer read, and whether it read it to the end of the
    /// stream.
    pub up: Option<(Received, bool)>,
    /// Server-initiated unidirectional stream, read through FIN by the client.
    pub down: Option<(Received, bool)>,
    /// The question the peer read, and whether that stream ended.
    pub question: Option<(Received, bool)>,
    /// The answer the peer read, and whether that stream ended. Only the end that receives the
    /// answer fills this in.
    pub answer: Option<(Received, bool)>,
    /// Whether the peer saw the connection close, as its own implementation reports it.
    pub closed: bool,
}

impl PeerObservation {
    /// Check what the peer saw against what the scenario sent. `role` is the scenario's own
    /// role — which end Rama was — and so says which half the peer played.
    ///
    /// `what` names the peer, the case and the role, so a failure says where it happened.
    pub fn check(&self, what: &str, scenario: &StreamScenario, role: Role) {
        assert_eq!(
            self.protocol.as_deref(),
            Some(ALPN),
            "{what}: the peer negotiated the scenario's protocol"
        );
        match role {
            // The peer received the upload and the question, and sent the answer.
            Role::RamaClient => {
                let (up, up_ended) = self.up.as_ref().expect("the peer read the upload");
                up.check(what, "upload", scenario.up);
                assert!(up_ended, "{what}: the upload's stream ended");
                let (question, question_ended) =
                    self.question.as_ref().expect("the peer read the question");
                question.check(what, "question", scenario.question);
                assert!(question_ended, "{what}: the question's stream ended");
                assert!(
                    self.answer.is_none(),
                    "{what}: the peer answered rather than receiving an answer"
                );
            }
            // The peer sent the upload and the question, and received the answer.
            Role::RamaServer => {
                let (down, down_ended) = self
                    .down
                    .as_ref()
                    .expect("the peer read the server uni stream");
                down.check(what, "server uni stream", scenario.down);
                assert!(down_ended, "{what}: the server uni stream ended with FIN");
                let (answer, answer_ended) =
                    self.answer.as_ref().expect("the peer read the answer");
                answer.check(what, "answer", scenario.answer);
                assert!(answer_ended, "{what}: the answer's stream ended");
            }
        }
        assert!(self.closed, "{what}: the peer saw the connection end");
    }
}

/// Rama as the client, up to the point where its traffic is done: open the connection, upload,
/// ask and read the answer. Closing is [`RamaClient::close`], so an adapter that has to collect
/// what its peer reported can do so while the connection is still up.
///
/// Its own assertions are made here; what the peer saw is checked separately, so neither side
/// stands in for the other.
pub async fn rama_client_side(run: &CaseRun<StreamScenario>, peer_addr: SocketAddr) -> RamaClient {
    let CaseRun {
        what,
        identity,
        deadline,
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

    // What the handshake settled, in Rama's own types.
    let settled = connection
        .extensions()
        .get_ref::<NegotiatedTlsParameters>()
        .cloned()
        .expect("the handshake settled something");
    assert_eq!(
        settled.application_layer_protocol,
        Some(alpn()),
        "{what}: the protocol both sides agreed on"
    );
    let chain = connection
        .extensions()
        .get_ref::<NegotiatedTlsParameters>()
        .and_then(|tls| tls.peer_certificate_chain.clone())
        .expect("the server presented a certificate");
    assert_eq!(
        chain.first(),
        identity.cert_chain.first(),
        "{what}: which is the identity the server was given"
    );

    upload_and_ask(run, &connection).await;
    RamaClient {
        endpoint,
        connection,
    }
}

/// A Rama client that has finished the scenario's traffic and not yet closed.
#[derive(Debug)]
pub struct RamaClient {
    pub endpoint: Endpoint,
    pub connection: Connection,
}

impl RamaClient {
    /// Close the connection and wait for the endpoint to go idle, both inside the deadline.
    pub async fn close(self, what: &str, deadline: Deadline) {
        self.connection.close(0u32, b"done");
        deadline.wait(what, self.endpoint.wait_idle()).await;
    }
}

/// Rama as the server: bind, accept, take the upload, answer the question, and stay until the
/// peer is done with the connection.
pub async fn rama_server_side(run: &CaseRun<StreamScenario>) -> (Endpoint, SocketAddr, Peer<()>) {
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

            // What the handshake settled on this side: the protocol, and the name the client
            // asked for, both in Rama's own types.
            let settled = conn
                .extensions()
                .get_ref::<NegotiatedTlsParameters>()
                .cloned()
                .expect("the handshake settled something");
            assert_eq!(
                settled.application_layer_protocol,
                Some(alpn()),
                "{}: the protocol both sides agreed on",
                run.what
            );
            assert_eq!(
                settled.server_name,
                Some(Domain::from_static(SERVER_NAME)),
                "{}: and the name the client asked for, as a domain",
                run.what
            );

            take_and_answer(&run, &conn).await;
            run.deadline.wait(&run.what, conn.closed()).await;
        }
    });
    (server, addr, serving)
}

/// The uploading half: a unidirectional stream ended with FIN, then a bidirectional question
/// whose answer is read back.
pub async fn upload_and_ask(run: &CaseRun<StreamScenario>, conn: &Connection) {
    let CaseRun {
        what,
        scenario,
        deadline,
        ..
    } = run;
    let mut uni = deadline
        .wait(what, conn.open_uni())
        .await
        .expect("a uni stream");
    deadline
        .wait(what, uni.write_all(&scenario.up.bytes()))
        .await
        .expect("the payload is written");
    uni.finish().expect("the uni stream ends");

    let mut down = deadline
        .wait(what, conn.accept_uni())
        .await
        .expect("the server initiated a uni stream");
    let bytes = deadline
        .wait(what, down.read_to_end(READ_CAP))
        .await
        .expect("the server uni stream ended");
    Received::Bytes(bytes).check(what, "server uni stream", scenario.down);
    // The client opens its question only after consuming the server's stream and FIN.
    let (mut send, mut recv) = deadline
        .wait(what, conn.open_bi())
        .await
        .expect("a bi stream");
    deadline
        .wait(what, send.write_all(&scenario.question.bytes()))
        .await
        .expect("the question is written");
    send.finish().expect("the question ends");
    let heard = deadline
        .wait(what, recv.read_to_end(READ_CAP))
        .await
        .expect("the answer completes");
    Received::Bytes(heard).check(what, "answer", scenario.answer);
}

/// The answering half: take the upload, read the question, write a different answer, end it.
pub async fn take_and_answer(run: &CaseRun<StreamScenario>, conn: &Connection) {
    let CaseRun {
        what,
        scenario,
        deadline,
        ..
    } = run;
    let mut uni = deadline
        .wait(what, conn.accept_uni())
        .await
        .expect("the uni stream arrives");
    let received = deadline
        .wait(what, uni.read_to_end(READ_CAP))
        .await
        .expect("the uni stream completes");
    Received::Bytes(received).check(what, "upload", scenario.up);

    let mut down = deadline
        .wait(what, conn.open_uni())
        .await
        .expect("the server opens a uni stream");
    deadline
        .wait(what, down.write_all(&scenario.down.bytes()))
        .await
        .expect("the server uni payload is written");
    down.finish().expect("the server uni stream ends");
    let (mut send, mut recv) = deadline
        .wait(what, conn.accept_bi())
        .await
        .expect("the bi stream arrives");
    let asked = deadline
        .wait(what, recv.read_to_end(READ_CAP))
        .await
        .expect("the question completes");
    Received::Bytes(asked).check(what, "question", scenario.question);
    deadline
        .wait(what, send.write_all(&scenario.answer.bytes()))
        .await
        .expect("the answer is written");
    send.finish().expect("the answer ends");
}

/// One exchange from the opening side, checked by length and digest on the way back. Every
/// family that carries traffic to prove a connection still works uses this pair.
pub async fn exchange(what: &str, deadline: Deadline, connection: &Connection, payload: Chunk) {
    let (mut send, mut recv) = deadline
        .wait(what, connection.open_bi())
        .await
        .expect("a bi stream");
    deadline
        .wait(what, send.write_all(&payload.bytes()))
        .await
        .expect("the payload is written");
    send.finish().expect("the stream ends");
    let back = deadline
        .wait(what, recv.read_to_end(READ_CAP))
        .await
        .expect("the answer completes");
    Received::Bytes(back).check(what, "exchange", payload);
}

/// The same exchange from the answering side.
pub async fn answer(what: &str, deadline: Deadline, connection: &Connection, payload: Chunk) {
    let (mut send, mut recv) = deadline
        .wait(what, connection.accept_bi())
        .await
        .expect("the stream arrives");
    let got = deadline
        .wait(what, recv.read_to_end(READ_CAP))
        .await
        .expect("it completes");
    Received::Bytes(got.clone()).check(what, "exchange", payload);
    deadline
        .wait(what, send.write_all(&got))
        .await
        .expect("the answer is written");
    send.finish().expect("the answer ends");
}

/// Read one exchange and answer it with the same bytes, whatever it carried, and say what that
/// was. For a case whose number of exchanges is not fixed in advance.
pub async fn echo_one(what: &str, deadline: Deadline, connection: &Connection) -> Vec<u8> {
    let (mut send, mut recv) = deadline
        .wait(what, connection.accept_bi())
        .await
        .expect("the stream arrives");
    let got = deadline
        .wait(what, recv.read_to_end(READ_CAP))
        .await
        .expect("it completes");
    deadline
        .wait(what, send.write_all(&got))
        .await
        .expect("the answer is written");
    send.finish().expect("the answer ends");
    got
}
