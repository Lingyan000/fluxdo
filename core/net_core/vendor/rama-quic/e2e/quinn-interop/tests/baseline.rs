//! The shared stream scenarios, run against Quinn in both roles.
//!
//! Every case in `interop_common::cases` runs here: the entry points enumerate the registry
//! rather than pick entries out of it, so a case added there runs against Quinn without this
//! file being touched. What is sent and what must be seen live in the shared crate; this file
//! is the Quinn adapter — its configuration, its async API, and the bytes it read.

mod common;

use std::{any::Any, net::SocketAddr};

use common::{quinn_client_config, quinn_server_config};
use interop_common::{
    CaseRun, Peer, PeerObservation, Received, Role, SERVER_NAME, StreamScenario, for_each_case,
    identity::anchor_of,
    scenario::{rama_client_side, rama_server_side},
    stream_cases,
    support::localhost,
};
use rama::{crypto::pki_types::CertificateDer, utils::octets};

const PEER: &str = "quinn";
const READ_CAP: usize = octets::mib(1);

/// Rama opens the connection and Quinn answers it, for every registered case.
#[tokio::test]
async fn stream_cases_rama_client() {
    for_each_case(PEER, Role::RamaClient, stream_cases(), |run| async move {
        let server = quinn::Endpoint::server(quinn_server_config(&run.identity), localhost())
            .expect("the quinn server binds");
        let addr = server.local_addr().expect("its address");
        let peer = Peer::spawn({
            let run = run.clone();
            async move { quinn_answers(&run, server).await }
        });

        let rama = rama_client_side(&run, addr).await;
        rama.close(&run.what, run.deadline).await;
        let observed = peer.join(&run.what, run.deadline).await;
        observed.check(&run.what, &run.scenario, run.role);
    })
    .await;
}

/// Quinn opens the connection and Rama answers it, for every registered case.
#[tokio::test]
async fn stream_cases_rama_server() {
    for_each_case(PEER, Role::RamaServer, stream_cases(), |run| async move {
        let (endpoint, addr, serving) = rama_server_side(&run).await;
        let observed = quinn_asks(&run, anchor_of(&run.identity), addr).await;
        observed.check(&run.what, &run.scenario, run.role);
        serving.join(&run.what, run.deadline).await;
        run.deadline.wait(&run.what, endpoint.wait_idle()).await;
    })
    .await;
}

/// Quinn as the answering end: take the upload, read the question, write the answer, and hand
/// back the bytes it read.
async fn quinn_answers(run: &CaseRun<StreamScenario>, server: quinn::Endpoint) -> PeerObservation {
    let (what, deadline) = (&run.what, run.deadline);
    let attempt = deadline
        .wait(what, server.accept())
        .await
        .expect("an attempt arrives");
    let conn = deadline
        .wait(what, attempt)
        .await
        .expect("the handshake completes");
    let mut observed = PeerObservation {
        protocol: conn.handshake_data().and_then(negotiated_protocol),
        ..PeerObservation::default()
    };

    let mut uni = deadline
        .wait(what, conn.accept_uni())
        .await
        .expect("the uni stream arrives");
    let received = deadline
        .wait(what, uni.read_to_end(READ_CAP))
        .await
        .expect("the uni stream completes");
    observed.up = Some((Received::Bytes(received), true));

    let mut down = deadline.wait(what, conn.open_uni()).await.unwrap();
    deadline
        .wait(what, down.write_all(&run.scenario.down.bytes()))
        .await
        .unwrap();
    down.finish().unwrap();

    let (mut send, mut recv) = deadline
        .wait(what, conn.accept_bi())
        .await
        .expect("the bi stream arrives");
    let asked = deadline
        .wait(what, recv.read_to_end(READ_CAP))
        .await
        .expect("the question completes");
    observed.question = Some((Received::Bytes(asked), true));
    deadline
        .wait(what, send.write_all(&run.scenario.answer.bytes()))
        .await
        .expect("the answer is written");
    send.finish().expect("the answer ends");

    deadline.wait(what, conn.closed()).await;
    observed.closed = true;
    deadline.wait(what, server.wait_idle()).await;
    observed
}

/// Quinn as the asking end: upload, ask, read the answer, and hand back the bytes it read.
async fn quinn_asks(
    run: &CaseRun<StreamScenario>,
    anchor: CertificateDer<'static>,
    addr: SocketAddr,
) -> PeerObservation {
    let (what, deadline) = (&run.what, run.deadline);
    let mut client = quinn::Endpoint::client(localhost()).expect("the quinn client binds");
    client.set_default_client_config(quinn_client_config(anchor));
    let conn = deadline
        .wait(
            what,
            client
                .connect(addr, SERVER_NAME)
                .expect("the attempt starts"),
        )
        .await
        .expect("the handshake completes");
    let mut observed = PeerObservation {
        protocol: conn.handshake_data().and_then(negotiated_protocol),
        ..PeerObservation::default()
    };

    let mut uni = deadline
        .wait(what, conn.open_uni())
        .await
        .expect("a uni stream");
    deadline
        .wait(what, uni.write_all(&run.scenario.up.bytes()))
        .await
        .expect("the payload is written");
    uni.finish().expect("the uni stream ends");

    let mut down = deadline.wait(what, conn.accept_uni()).await.unwrap();
    let bytes = deadline
        .wait(what, down.read_to_end(READ_CAP))
        .await
        .unwrap();
    observed.down = Some((Received::Bytes(bytes), true));

    let (mut send, mut recv) = deadline
        .wait(what, conn.open_bi())
        .await
        .expect("a bi stream");
    deadline
        .wait(what, send.write_all(&run.scenario.question.bytes()))
        .await
        .expect("the question is written");
    send.finish().expect("the question ends");
    let heard = deadline
        .wait(what, recv.read_to_end(READ_CAP))
        .await
        .expect("the answer completes");
    observed.answer = Some((Received::Bytes(heard), true));

    conn.close(0u32.into(), b"done");
    deadline.wait(what, client.wait_idle()).await;
    observed.closed = true;
    observed
}

fn negotiated_protocol(data: Box<dyn Any>) -> Option<Vec<u8>> {
    data.downcast::<quinn::crypto::rustls::HandshakeData>()
        .ok()
        .and_then(|data| data.protocol)
}
