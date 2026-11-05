//! The shared stream scenarios, run against quiche in both roles.
//!
//! Every case in `interop_common::cases` runs here: the entry points enumerate the registry
//! rather than pick entries out of it. quiche owns neither sockets nor timers, so its side is
//! driven by hand against the same scenario deadline, and what it hands back is what its own
//! connection read.

mod common;

use common::{Identity, Quiche, quiche_client_config, quiche_server_config};
use interop_common::{
    CaseRun, Peer, PeerObservation, Received, Role, SERVER_NAME, StreamScenario, for_each_case,
    scenario::{rama_client_side, rama_server_side},
    stream_cases,
};
use rama::utils::octets;

const PEER: &str = "quiche";
/// A client's first unidirectional stream, and its first bidirectional one.
const UNI: u64 = 2;
const BI: u64 = 0;
const READ_CAP: usize = octets::mib(1);

/// Rama opens the connection and quiche answers it, for every registered case.
#[tokio::test]
async fn stream_cases_rama_client() {
    for_each_case(PEER, Role::RamaClient, stream_cases(), |run| async move {
        // quiche reads its identity from files, so it makes its own and the run takes it.
        let identity = Identity::generate(SERVER_NAME);
        let run = run.with_identity(identity.auth.clone());
        let (addr, accepting) =
            Quiche::bind_server(quiche_server_config(&identity), run.deadline).await;
        let peer = Peer::spawn({
            let run = run.clone();
            async move {
                let mut server = accepting.await;
                quiche_answers(&run, &mut server).await
            }
        });

        let rama = rama_client_side(&run, addr).await;
        rama.close(&run.what, run.deadline).await;
        let observed = peer.join(&run.what, run.deadline).await;
        observed.check(&run.what, &run.scenario, run.role);
    })
    .await;
}

/// quiche opens the connection and Rama answers it, for every registered case.
#[tokio::test]
async fn stream_cases_rama_server() {
    for_each_case(PEER, Role::RamaServer, stream_cases(), |run| async move {
        let identity = Identity::generate(SERVER_NAME);
        let run = run.with_identity(identity.auth.clone());
        let (endpoint, addr, serving) = rama_server_side(&run).await;
        let mut client = Quiche::connect(
            addr,
            SERVER_NAME,
            quiche_client_config(&identity),
            run.deadline,
        )
        .await;
        let observed = quiche_asks(&run, &mut client).await;
        observed.check(&run.what, &run.scenario, run.role);
        serving.join(&run.what, run.deadline).await;
        run.deadline.wait(&run.what, endpoint.wait_idle()).await;
    })
    .await;
}

/// quiche as the answering end.
async fn quiche_answers(run: &CaseRun<StreamScenario>, server: &mut Quiche) -> PeerObservation {
    let (what, deadline) = (&run.what, run.deadline);
    server
        .drive_until(what, deadline, |connection| connection.is_established())
        .await;
    let protocol = server.connection().application_proto().to_vec();

    let received = server.read_stream(UNI, READ_CAP, deadline).await;
    server
        .write_stream(3, &run.scenario.down.bytes(), deadline)
        .await;
    let asked = server.read_stream(BI, READ_CAP, deadline).await;
    server
        .write_stream(BI, &run.scenario.answer.bytes(), deadline)
        .await;
    server
        .drive_until(what, deadline, |connection| connection.is_closed())
        .await;
    PeerObservation {
        protocol: Some(protocol),
        up: Some((Received::Bytes(received), true)),
        down: None,
        question: Some((Received::Bytes(asked), true)),
        answer: None,
        closed: server.connection().is_closed(),
    }
}

/// quiche as the asking end.
async fn quiche_asks(run: &CaseRun<StreamScenario>, client: &mut Quiche) -> PeerObservation {
    let (what, deadline) = (&run.what, run.deadline);
    client
        .drive_until(what, deadline, |connection| connection.is_established())
        .await;
    let protocol = client.connection().application_proto().to_vec();
    client
        .write_stream(UNI, &run.scenario.up.bytes(), deadline)
        .await;
    let down = client.read_stream(3, READ_CAP, deadline).await;
    client
        .write_stream(BI, &run.scenario.question.bytes(), deadline)
        .await;
    let heard = client.read_stream(BI, READ_CAP, deadline).await;
    client.close(deadline).await;
    PeerObservation {
        protocol: Some(protocol),
        up: None,
        down: Some((Received::Bytes(down), true)),
        question: None,
        answer: Some((Received::Bytes(heard), true)),
        closed: client.connection().is_closed(),
    }
}

/// The receive budget must accommodate the peer's datagrams independently of our send budget.
#[tokio::test]
async fn rama_datagrams_larger_than_quiche_send_budget_arrive_intact() {
    use common::{Deadline, Packet, Read, localhost, rama_client_config};
    use rama::quic::{Endpoint, TransportConfig};
    use std::sync::Arc;

    const MTU: u16 = 1452;
    let deadline = Deadline::new();
    let identity = Identity::generate(SERVER_NAME);
    let (addr, accepting) = Quiche::bind_server(quiche_server_config(&identity), deadline).await;
    let bytes = common::payload(0x5a, 4096);
    let peer = Peer::spawn({
        let expected = bytes.clone();
        async move {
            let mut server = accepting.await;
            server.read_headers();
            server
                .drive_until("the connection establishes", deadline, |connection| {
                    connection.is_established()
                })
                .await;
            assert_eq!(server.read_stream(UNI, READ_CAP, deadline).await, expected);
            // A short-header packet runs to the end of its UDP datagram. Verify its actual
            // received length, so retransmission after truncation cannot hide a short buffer.
            assert!(server.headers().iter().any(|read| matches!(
                read,
                Read::Datagram(packets) if packets.iter().any(|packet| matches!(
                    packet,
                    Packet::Known { kind: quiche::Type::Short, bytes } if *bytes == usize::from(MTU)
                ))
            )));
            server.close(deadline).await;
        }
    });
    let client = deadline
        .wait(
            "the Rama client binds",
            Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
        )
        .await
        .expect("the client binds");
    // Pin the path size so this tests oversized datagrams without waiting for MTU discovery.
    let transport = TransportConfig::default()
        .with_initial_mtu(MTU)
        .with_min_mtu(MTU)
        .with_pad_to_mtu(true)
        .without_mtu_discovery_config();
    let config = rama_client_config(&identity).with_transport_config(Arc::new(transport));
    let connection = deadline
        .wait(
            "the Rama client connects",
            client
                .connect_with(config, addr, SERVER_NAME)
                .expect("the attempt starts"),
        )
        .await
        .expect("the handshake completes");
    let mut stream = deadline
        .wait("Rama opens the stream", connection.open_uni())
        .await
        .expect("the stream opens");
    deadline
        .wait("Rama writes the payload", stream.write_all(&bytes))
        .await
        .expect("the payload is written");
    stream.finish().expect("the stream finishes");
    peer.join("the oversized datagrams arrive", deadline).await;
    deadline
        .wait("the endpoint shuts down", client.wait_idle())
        .await;
}
