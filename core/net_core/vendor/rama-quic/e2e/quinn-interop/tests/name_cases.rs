//! The shared server-name cases, run against Quinn in both roles.
//!
//! Rama's own view of the name is asserted in the shared code. Quinn's server exposes what it
//! received through `HandshakeData::server_name`, so this adapter reports that as well.

mod common;

use std::{net::SocketAddr, sync::Arc};

use common::{quinn_client_config, quinn_server_config};
use interop_common::{
    CaseRun, NameObservation, NameScenario, Peer, Received, ReceivedName, Role, for_each_case,
    identity::anchor_of,
    names::{identity_for, name_cases, rama_client_side, rama_server_side},
    support::{localhost, localhost_v6},
};
use rama::{crypto::pki_types::CertificateDer, net::socket::core as socket, utils::octets};

const PEER: &str = "quinn";
const READ_CAP: usize = octets::kib(64);

/// Rama asks Quinn for the case's name, or for none, and Quinn reports what it received.
#[tokio::test]
async fn name_cases_rama_client() {
    for_each_case(PEER, Role::RamaClient, name_cases(), |run| async move {
        let run = run.clone().with_identity(identity_for(&run.scenario));
        let server = quinn::Endpoint::server(quinn_server_config(&run.identity), run.scenario.bind)
            .expect("the quinn server binds");
        let addr = server.local_addr().expect("its address");
        let peer = Peer::spawn({
            let run = run.clone();
            async move { quinn_answers(&run, server).await }
        });

        rama_client_side(&run, addr).await;
        let observed = peer.join(&run.what, run.deadline).await;
        assert!(
            observed.check(&run.what, &run.scenario),
            "{}: this peer reports the name it received",
            run.what
        );
    })
    .await;
}

/// Quinn asks Rama for the case's name, or for none, and Rama reports what it received.
#[tokio::test]
async fn name_cases_rama_server() {
    for_each_case(PEER, Role::RamaServer, name_cases(), |run| async move {
        let run = run.clone().with_identity(identity_for(&run.scenario));
        let (endpoint, addr, serving) = rama_server_side(&run).await;
        quinn_asks(&run, anchor_of(&run.identity), addr).await;
        serving.join(&run.what, run.deadline).await;
        run.deadline.wait(&run.what, endpoint.wait_idle()).await;
    })
    .await;
}

/// Quinn's server: what it says the client asked for, and the probe answered.
async fn quinn_answers(run: &CaseRun<NameScenario>, server: quinn::Endpoint) -> NameObservation {
    let (what, deadline) = (&run.what, run.deadline);
    let attempt = deadline
        .wait(what, server.accept())
        .await
        .expect("an attempt arrives");
    let conn = deadline
        .wait(what, attempt)
        .await
        .expect("the handshake completes");
    let observed = NameObservation {
        server_name: ReceivedName::Seen(received_name(what, &conn)),
    };
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
    deadline.wait(what, conn.closed()).await;
    deadline.wait(what, server.wait_idle()).await;
    observed
}

/// Quinn's client, asking for the case's name or naming the address instead.
async fn quinn_asks(
    run: &CaseRun<NameScenario>,
    anchor: CertificateDer<'static>,
    addr: SocketAddr,
) {
    let (what, deadline) = (&run.what, run.deadline);
    // These cases use one address family. Bind IPv6-only on loopback instead of using
    // the dual-stack socket created by Quinn's convenience client.
    let bind = bound_like(addr);
    let socket = socket::Socket::new(
        socket::Domain::for_address(bind),
        socket::Type::DGRAM,
        Some(socket::Protocol::UDP),
    )
    .expect("the quinn client socket is created");
    if bind.is_ipv6() {
        socket
            .set_only_v6(true)
            .expect("the quinn client uses only IPv6");
    }
    socket.bind(&bind.into()).expect("the quinn client binds");
    let mut client = quinn::Endpoint::new(
        quinn::EndpointConfig::default(),
        None,
        socket.into(),
        Arc::new(quinn::TokioRuntime),
    )
    .expect("the quinn client endpoint is created");
    client.set_default_client_config(quinn_client_config(anchor));
    let asked = run
        .scenario
        .asked
        .map_or_else(|| addr.ip().to_string(), str::to_owned);
    let conn = deadline
        .wait(
            what,
            client.connect(addr, &asked).expect("the attempt starts"),
        )
        .await
        .expect("the handshake completes");
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
    conn.close(0u32.into(), b"done");
    deadline.wait(what, client.wait_idle()).await;
}

/// The name Quinn's server says the client asked for. The handshake data must be there and be
/// the expected type: a missing or unexpected one is a failure, not an absent name.
fn received_name(what: &str, conn: &quinn::Connection) -> Option<String> {
    let data = conn
        .handshake_data()
        .unwrap_or_else(|| panic!("{what}: the handshake settled something"));
    let data = data
        .downcast::<quinn::crypto::rustls::HandshakeData>()
        .unwrap_or_else(|_| panic!("{what}: the handshake data is Quinn's rustls type"));
    data.server_name
}

/// A local address on the same socket family as `peer`.
fn bound_like(peer: SocketAddr) -> SocketAddr {
    if peer.is_ipv6() {
        localhost_v6()
    } else {
        localhost()
    }
}
