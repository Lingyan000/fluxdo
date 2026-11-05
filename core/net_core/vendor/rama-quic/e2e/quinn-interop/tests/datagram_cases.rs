//! The shared DATAGRAM cases, run against Quinn in both roles.

mod common;

use std::{net::SocketAddr, sync::Arc};

use common::{Deaf, answer, bound_socket, exchange, quinn_client_config, quinn_server_config};
use interop_common::{
    BackpressureScenario, CaseRun, DatagramObservation, DatagramScenario, Ears, Peer, Received,
    Role, UnsupportedObservation, UnsupportedScenario,
    backpressure::{
        bind_backpressure_server, rama_client_fills_and_cancels, rama_server_fills_and_cancels,
    },
    backpressure_cases,
    datagram::{rama_client_side, rama_server_side},
    datagram_cases, for_each_case,
    identity::anchor_of,
    scenario::SERVER_NAME,
    support::localhost,
    unsupported::{rama_client_without_datagrams, rama_server_without_datagrams},
    unsupported_cases,
};
use rama::{crypto::pki_types::CertificateDer, utils::octets};

const PEER: &str = "quinn";
/// The frame this side tells Quinn to advertise. `TransportConfig::datagram_receive_buffer_size`
/// is what Quinn derives `max_datagram_frame_size` from, as `min(value, u16::MAX)`
/// (quinn-proto 0.11.17 `transport_parameters.rs:170`), so a configured 256 is an advertised
/// 256. Small enough that it, and not the path MTU, is what bounds Rama.
const FRAME: usize = 256;
/// What a boundary row configures instead. Quinn derives the frame it advertises from this
/// same number, which RFC 9221 §3 makes a bound on the frame, but its receive check compares
/// `data.len() + size_of::<Datagram>()` against it (quinn-proto 0.11.17
/// `connection/datagrams/mod.rs:126`). That second term is the size of its own Rust struct rather
/// than the wire header, so a budget that only just covers what it advertised refuses what it
/// invited. A budget well above the row's pinned path leaves the MTU as what bounds Rama, and
/// that quirk out of the way.
const BOUNDARY_FRAME: usize = octets::kib(4);

/// Quinn with that bound configured, for this family alone.
fn advertising(frame: usize) -> Arc<quinn::TransportConfig> {
    let mut transport = quinn::TransportConfig::default();
    transport.datagram_receive_buffer_size(Some(frame));
    Arc::new(transport)
}

/// The frame this row asks Quinn to advertise.
fn frame_for(run: &CaseRun<DatagramScenario>) -> usize {
    match run.scenario.at_the_boundary {
        true => BOUNDARY_FRAME,
        false => FRAME,
    }
}

/// Rama opens the connection and Quinn answers it, for every registered datagram case.
#[tokio::test]
async fn datagram_cases_rama_client() {
    for_each_case(PEER, Role::RamaClient, datagram_cases(), |run| async move {
        let mut config = quinn_server_config(&run.identity);
        config.transport_config(advertising(frame_for(&run)));
        let server = quinn::Endpoint::server(config, localhost()).expect("the quinn server binds");
        let addr = server.local_addr().expect("its address");
        let peer = Peer::spawn({
            let run = run.clone();
            async move { quinn_answers(&run, server).await }
        });

        let rama = rama_client_side(&run, addr).await;
        let (limit, sent) = (rama.limit, rama.sent);
        rama.close(&run.what, run.deadline).await;
        let observed = peer.join(&run.what, run.deadline).await;
        observed.check(&run.what, &run.scenario, run.role, sent);
        observed.bounds(&run.what, limit);
    })
    .await;
}

/// Quinn opens the connection and Rama answers it, for every registered datagram case.
#[tokio::test]
async fn datagram_cases_rama_server() {
    for_each_case(PEER, Role::RamaServer, datagram_cases(), |run| async move {
        let (endpoint, addr, serving) = rama_server_side(&run).await;
        let observed = quinn_asks(&run, anchor_of(&run.identity), addr).await;
        let (limit, sent) = serving.join(&run.what, run.deadline).await;
        observed.check(&run.what, &run.scenario, run.role, sent);
        observed.bounds(&run.what, limit);
        run.deadline.wait(&run.what, endpoint.wait_idle()).await;
    })
    .await;
}

/// Quinn receives the datagram Rama sent and answers with the case's other one.
async fn quinn_answers(
    run: &CaseRun<DatagramScenario>,
    server: quinn::Endpoint,
) -> DatagramObservation {
    let (what, deadline) = (&run.what, run.deadline);
    let attempt = deadline
        .wait(what, server.accept())
        .await
        .expect("an attempt arrives");
    let conn = deadline
        .wait(what, attempt)
        .await
        .expect("the handshake completes");
    let arrived = deadline
        .wait(what, conn.read_datagram())
        .await
        .expect("a datagram arrives");
    // Quinn reports the largest datagram this connection may send.
    let observed = DatagramObservation {
        sendable: conn.max_datagram_size(),
        advertised: Some(frame_for(run)),
        received: Some(Received::Bytes(arrived.to_vec())),
    };
    conn.send_datagram(run.scenario.back.bytes().into())
        .expect("the answering datagram is accepted");
    deadline.wait(what, conn.closed()).await;
    deadline.wait(what, server.wait_idle()).await;
    observed
}

/// Quinn sends the case's first datagram and receives the answering one.
async fn quinn_asks(
    run: &CaseRun<DatagramScenario>,
    anchor: CertificateDer<'static>,
    addr: SocketAddr,
) -> DatagramObservation {
    let (what, deadline) = (&run.what, run.deadline);
    let mut client = quinn::Endpoint::client(localhost()).expect("the quinn client binds");
    let mut config = quinn_client_config(anchor);
    config.transport_config(advertising(frame_for(run)));
    client.set_default_client_config(config);
    let conn = deadline
        .wait(
            what,
            client
                .connect(addr, SERVER_NAME)
                .expect("the attempt starts"),
        )
        .await
        .expect("the handshake completes");
    let sendable = conn.max_datagram_size();
    conn.send_datagram(run.scenario.out.bytes().into())
        .expect("the datagram is accepted");
    let arrived = deadline
        .wait(what, conn.read_datagram())
        .await
        .expect("a datagram comes back");
    conn.close(0u32.into(), b"done");
    deadline.wait(what, client.wait_idle()).await;
    DatagramObservation {
        sendable,
        advertised: Some(frame_for(run)),
        received: Some(Received::Bytes(arrived.to_vec())),
    }
}

/// Quinn offering no datagram size at all, so the extension is never negotiated.
fn offering_nothing() -> Arc<quinn::TransportConfig> {
    let mut transport = quinn::TransportConfig::default();
    transport.datagram_receive_buffer_size(None);
    Arc::new(transport)
}

/// Watch for a datagram for as long as the connection lasts, rather than for a window of this
/// side's choosing: the read ends when the connection does, so what it answers covers the
/// whole case.
fn watch_for_a_datagram(conn: &quinn::Connection) -> Peer<Option<Received>> {
    Peer::spawn({
        let conn = conn.clone();
        async move {
            conn.read_datagram()
                .await
                .ok()
                .map(|read| Received::Bytes(read.to_vec()))
        }
    })
}

/// Rama opens the connection and a Quinn that offered no datagram size answers it.
#[tokio::test]
async fn unsupported_cases_rama_client() {
    for_each_case(
        PEER,
        Role::RamaClient,
        unsupported_cases(),
        |run| async move {
            let mut config = quinn_server_config(&run.identity);
            config.transport_config(offering_nothing());
            let server =
                quinn::Endpoint::server(config, localhost()).expect("the quinn server binds");
            let addr = server.local_addr().expect("its address");
            let peer = Peer::spawn({
                let run = run.clone();
                async move { quinn_carries(&run, server).await }
            });

            let rama = rama_client_without_datagrams(&run, addr).await;
            rama.close(&run.what, run.deadline).await;
            peer.join(&run.what, run.deadline)
                .await
                .check(&run.what, &run.scenario);
        },
    )
    .await;
}

/// A Quinn that offered no datagram size opens the connection and Rama answers it.
#[tokio::test]
async fn unsupported_cases_rama_server() {
    for_each_case(
        PEER,
        Role::RamaServer,
        unsupported_cases(),
        |run| async move {
            let (endpoint, addr, serving) = rama_server_without_datagrams(&run).await;
            let observed =
                quinn_opens_without_datagrams(&run, anchor_of(&run.identity), addr).await;
            serving.join(&run.what, run.deadline).await;
            observed.check(&run.what, &run.scenario);
            run.deadline.wait(&run.what, endpoint.wait_idle()).await;
        },
    )
    .await;
}

/// Quinn answers the exchange Rama opens, and says no datagram reached it.
async fn quinn_carries(
    run: &CaseRun<UnsupportedScenario>,
    server: quinn::Endpoint,
) -> UnsupportedObservation {
    let (what, deadline) = (&run.what, run.deadline);
    let attempt = deadline
        .wait(what, server.accept())
        .await
        .expect("an attempt arrives");
    let conn = deadline
        .wait(what, attempt)
        .await
        .expect("the handshake completes");
    let watching = watch_for_a_datagram(&conn);
    let carried = answer(what, deadline, &conn, run.scenario.carried).await;
    deadline.wait(what, conn.closed()).await;
    deadline.wait(what, server.wait_idle()).await;
    UnsupportedObservation {
        datagram: watching.join(what, deadline).await,
        carried: Some(carried),
    }
}

/// Quinn opens the exchange instead, and says the same.
async fn quinn_opens_without_datagrams(
    run: &CaseRun<UnsupportedScenario>,
    anchor: CertificateDer<'static>,
    addr: SocketAddr,
) -> UnsupportedObservation {
    let (what, deadline) = (&run.what, run.deadline);
    let mut client = quinn::Endpoint::client(localhost()).expect("the quinn client binds");
    let mut config = quinn_client_config(anchor);
    config.transport_config(offering_nothing());
    client.set_default_client_config(config);
    let conn = deadline
        .wait(
            what,
            client
                .connect(addr, SERVER_NAME)
                .expect("the attempt starts"),
        )
        .await
        .expect("the handshake completes");
    let watching = watch_for_a_datagram(&conn);
    let carried = exchange(what, deadline, &conn, run.scenario.carried).await;
    conn.close(0u32.into(), b"done");
    deadline.wait(what, client.wait_idle()).await;
    UnsupportedObservation {
        datagram: watching.join(what, deadline).await,
        carried: Some(carried),
    }
}

/// The Quinn side's pause, as the shared backpressure case asks for it.
struct Muted(Arc<Deaf>);

impl Ears for Muted {
    async fn deaf(&mut self) {
        self.0.stop_reading();
    }

    async fn hear(&mut self) {
        self.0.read_again();
    }
}

/// Rama fills its outgoing buffer against a Quinn that has stopped reading its socket,
/// cancels the send that has no room, and carries on once it is reading again.
#[tokio::test]
async fn backpressure_cases_rama_client() {
    backpressure(Role::RamaClient).await;
}

#[tokio::test]
async fn backpressure_cases_rama_server() {
    backpressure(Role::RamaServer).await;
}

async fn backpressure(role: Role) {
    for_each_case(PEER, role, backpressure_cases(), |run| async move {
        let runtime = quinn::default_runtime().expect("an async runtime");
        let socket = Deaf::around(
            runtime
                .wrap_udp_socket(bound_socket())
                .expect("the socket is wrapped"),
        );
        let mut config = quinn_server_config(&run.identity);
        config.transport_config(advertising(BOUNDARY_FRAME));
        let server = quinn::Endpoint::new_with_abstract_socket(
            quinn::EndpointConfig::default(),
            Some(config),
            socket.clone(),
            runtime,
        )
        .expect("the quinn server binds");
        let (reports, mut arriving) = tokio::sync::mpsc::unbounded_channel();
        let mut ears = Muted(socket);
        let (peer, filled) = match role {
            Role::RamaClient => {
                let addr = server.local_addr().expect("its address");
                let peer = Peer::spawn({
                    let run = run.clone();
                    async move { quinn_stalls(&run, server, reports, None).await }
                });
                let filled = rama_client_fills_and_cancels(&run, addr, &mut ears).await;
                (peer, filled)
            }
            Role::RamaServer => {
                let endpoint = bind_backpressure_server(&run).await;
                let address = endpoint.local_addr().unwrap();
                let peer = Peer::spawn({
                    let run = run.clone();
                    async move { quinn_stalls(&run, server, reports, Some(address)).await }
                });
                let filled = rama_server_fills_and_cancels(&run, endpoint, &mut ears).await;
                (peer, filled)
            }
        };

        // Read until the peer has the one sent once there was room, so the connection is
        // not closed while it is still catching up, then close and read what is left.
        // Datagrams are unordered, so the marker bounds the wait rather than ending it.
        let mut reports = Vec::new();
        loop {
            let report = run
                .deadline
                .wait(&run.what, arriving.recv())
                .await
                .expect("the peer is still reporting");
            let resumed = filled.sent.resumed(&report);
            reports.push(report);
            if resumed {
                break;
            }
        }
        let sent = filled.sent.clone();
        filled.close(&run.what, run.deadline).await;
        run.deadline
            .wait(&run.what, async {
                while let Some(report) = arriving.recv().await {
                    reports.push(report);
                }
            })
            .await;
        peer.join(&run.what, run.deadline).await;
        sent.account_for(&run.what, &reports);
    })
    .await;
}

/// Quinn reports every datagram it is given as it arrives, and answers the exchange that
/// follows the stall.
async fn quinn_stalls(
    run: &CaseRun<BackpressureScenario>,
    server: quinn::Endpoint,
    reports: tokio::sync::mpsc::UnboundedSender<Received>,
    connect_to: Option<SocketAddr>,
) {
    let (what, deadline) = (&run.what, run.deadline);
    let conn = if let Some(address) = connect_to {
        let mut config = quinn_client_config(anchor_of(&run.identity));
        config.transport_config(advertising(BOUNDARY_FRAME));
        deadline
            .wait(
                what,
                server.connect_with(config, address, SERVER_NAME).unwrap(),
            )
            .await
            .unwrap()
    } else {
        let attempt = deadline
            .wait(what, server.accept())
            .await
            .expect("an attempt arrives");
        deadline
            .wait(what, attempt)
            .await
            .expect("the handshake completes")
    };
    let reading = {
        let conn = conn.clone();
        async move {
            while let Ok(bytes) = conn.read_datagram().await {
                if reports.send(Received::Bytes(bytes.to_vec())).is_err() {
                    break;
                }
            }
        }
    };
    let serving = async {
        answer(what, deadline, &conn, run.scenario.carried).await;
        deadline.wait(what, conn.closed()).await;
    };
    tokio::join!(reading, serving);
    deadline.wait(what, server.wait_idle()).await;
}
