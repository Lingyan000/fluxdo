//! The shared DATAGRAM cases, run against quiche in both roles.
//!
//! quiche advertises 65536 when datagrams are enabled, from draft-ietf-quic-datagram-01 rather
//! than RFC 9221's 65535, and either value is far above the path budget: against this peer the
//! binding limit is the path. That is the other half of what the aioquic project shows, where
//! the peer's advertised size is small enough to bind.

mod common;

use common::{Identity, Quiche, quiche_client_config, quiche_server_config, with_datagrams};
use interop_common::{
    BackpressureScenario, CaseRun, DatagramObservation, DatagramScenario, Deadline, Ears, Peer,
    Received, Role, UnsupportedObservation, UnsupportedScenario,
    backpressure::{
        bind_backpressure_server, rama_client_fills_and_cancels, rama_server_fills_and_cancels,
    },
    backpressure_cases,
    datagram::{rama_client_side, rama_server_side},
    datagram_cases, for_each_case,
    scenario::SERVER_NAME,
    unsupported::{rama_client_without_datagrams, rama_server_without_datagrams},
    unsupported_cases,
};
use rama::utils::octets;

const PEER: &str = "quiche";
/// What quiche advertises as `max_datagram_frame_size`. `Config::enable_dgram` sets it to
/// this fixed value in the pinned 0.24 and offers no way to choose another, so the bound is
/// read from that API rather than configured by a case.
const QUICHE_FRAME: usize = octets::kib(64);
const READ_CAP: usize = octets::kib(64);

/// Rama opens the connection and quiche answers it, for every registered datagram case.
#[tokio::test]
async fn datagram_cases_rama_client() {
    for_each_case(PEER, Role::RamaClient, datagram_cases(), |run| async move {
        let identity = Identity::generate(SERVER_NAME);
        let run = run.with_identity(identity.auth.clone());
        let (addr, accepting) = Quiche::bind_server(
            with_datagrams(quiche_server_config(&identity)),
            run.deadline,
        )
        .await;
        let peer = Peer::spawn({
            let run = run.clone();
            async move {
                let mut server = accepting.await;
                quiche_answers(&run, &mut server).await
            }
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

/// quiche opens the connection and Rama answers it, for every registered datagram case.
#[tokio::test]
async fn datagram_cases_rama_server() {
    for_each_case(PEER, Role::RamaServer, datagram_cases(), |run| async move {
        let identity = Identity::generate(SERVER_NAME);
        let run = run.with_identity(identity.auth.clone());
        let (endpoint, addr, serving) = rama_server_side(&run).await;
        let mut client = Quiche::connect(
            addr,
            SERVER_NAME,
            with_datagrams(quiche_client_config(&identity)),
            run.deadline,
        )
        .await;
        let observed = quiche_asks(&run, &mut client).await;
        let (limit, sent) = serving.join(&run.what, run.deadline).await;
        observed.check(&run.what, &run.scenario, run.role, sent);
        observed.bounds(&run.what, limit);
        run.deadline.wait(&run.what, endpoint.wait_idle()).await;
    })
    .await;
}

/// quiche receives the datagram Rama sent and answers with the case's other one.
async fn quiche_answers(
    run: &CaseRun<DatagramScenario>,
    server: &mut Quiche,
) -> DatagramObservation {
    let (what, deadline) = (&run.what, run.deadline);
    server
        .drive_until(what, deadline, |connection| connection.is_established())
        .await;
    let arrived = server.read_datagram(READ_CAP, deadline).await;
    // What quiche says this connection may write as one datagram.
    let sendable = server.connection().dgram_max_writable_len();
    server
        .send_datagram(&run.scenario.back.bytes(), deadline)
        .await;
    server
        .drive_until(what, deadline, |connection| connection.is_closed())
        .await;
    DatagramObservation {
        sendable,
        advertised: Some(QUICHE_FRAME),
        received: Some(Received::Bytes(arrived)),
    }
}

/// quiche sends the case's first datagram and receives the answering one.
async fn quiche_asks(run: &CaseRun<DatagramScenario>, client: &mut Quiche) -> DatagramObservation {
    let (what, deadline) = (&run.what, run.deadline);
    client
        .drive_until(what, deadline, |connection| connection.is_established())
        .await;
    let sendable = client.connection().dgram_max_writable_len();
    client
        .send_datagram(&run.scenario.out.bytes(), deadline)
        .await;
    let arrived = client.read_datagram(READ_CAP, deadline).await;
    client.close(deadline).await;
    DatagramObservation {
        sendable,
        advertised: Some(QUICHE_FRAME),
        received: Some(Received::Bytes(arrived)),
    }
}

/// The client-initiated bidirectional stream a case's exchange runs on.
const CLIENT_BI: u64 = 0;

/// Rama opens the connection and a quiche that never enabled datagrams answers it.
#[tokio::test]
async fn unsupported_cases_rama_client() {
    for_each_case(
        PEER,
        Role::RamaClient,
        unsupported_cases(),
        |run| async move {
            let identity = Identity::generate(SERVER_NAME);
            let run = run.with_identity(identity.auth.clone());
            let (addr, accepting) =
                Quiche::bind_server(quiche_server_config(&identity), run.deadline).await;
            let peer = Peer::spawn({
                let run = run.clone();
                async move {
                    let mut server = accepting.await;
                    quiche_carries(&run, &mut server).await
                }
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

/// A quiche that never enabled datagrams opens the connection and Rama answers it.
#[tokio::test]
async fn unsupported_cases_rama_server() {
    for_each_case(
        PEER,
        Role::RamaServer,
        unsupported_cases(),
        |run| async move {
            let identity = Identity::generate(SERVER_NAME);
            let run = run.with_identity(identity.auth.clone());
            let (endpoint, addr, serving) = rama_server_without_datagrams(&run).await;
            let mut client = Quiche::connect(
                addr,
                SERVER_NAME,
                quiche_client_config(&identity),
                run.deadline,
            )
            .await;
            let observed = quiche_opens_without_datagrams(&run, &mut client).await;
            client.close(run.deadline).await;
            serving.join(&run.what, run.deadline).await;
            observed.check(&run.what, &run.scenario);
            run.deadline.wait(&run.what, endpoint.wait_idle()).await;
        },
    )
    .await;
}

/// quiche answers the exchange Rama opens, and says whether a datagram reached it.
async fn quiche_carries(
    run: &CaseRun<UnsupportedScenario>,
    server: &mut Quiche,
) -> UnsupportedObservation {
    let (what, deadline) = (&run.what, run.deadline);
    server
        .drive_until(what, deadline, |connection| connection.is_established())
        .await;
    let got = server.read_stream(CLIENT_BI, READ_CAP, deadline).await;
    server.write_stream(CLIENT_BI, &got, deadline).await;
    server
        .drive_until(what, deadline, |connection| connection.is_closed())
        .await;
    UnsupportedObservation {
        datagram: nothing_arrived(server, deadline).await,
        carried: Some(Received::Bytes(got)),
    }
}

/// quiche opens the exchange instead, and says the same.
async fn quiche_opens_without_datagrams(
    run: &CaseRun<UnsupportedScenario>,
    client: &mut Quiche,
) -> UnsupportedObservation {
    let (what, deadline) = (&run.what, run.deadline);
    client
        .drive_until(what, deadline, |connection| connection.is_established())
        .await;
    client
        .write_stream(CLIENT_BI, &run.scenario.carried.bytes(), deadline)
        .await;
    let back = client.read_stream(CLIENT_BI, READ_CAP, deadline).await;
    client.close(deadline).await;
    UnsupportedObservation {
        datagram: nothing_arrived(client, deadline).await,
        carried: Some(Received::Bytes(back)),
    }
}

/// Whatever quiche has queued once the connection has ended. The queue keeps every datagram
/// that arrived, so asking it here answers for the whole case rather than for a window.
async fn nothing_arrived(peer: &mut Quiche, deadline: Deadline) -> Option<Received> {
    match peer.connection().dgram_recv_queue_len() {
        0 => None,
        _ => Some(Received::Bytes(
            peer.read_datagram(READ_CAP, deadline).await,
        )),
    }
}

#[tokio::test]
async fn backpressure_cases_rama_client() {
    backpressure(Role::RamaClient).await;
}

#[tokio::test]
async fn backpressure_cases_rama_server() {
    backpressure(Role::RamaServer).await;
}

struct ReadControl {
    paused: bool,
    acknowledged: tokio::sync::oneshot::Sender<()>,
}

struct Controls {
    sender: tokio::sync::mpsc::Sender<ReadControl>,
    deadline: Deadline,
}

impl Controls {
    async fn set_paused(&mut self, paused: bool) {
        let (acknowledged, received) = tokio::sync::oneshot::channel();
        self.deadline
            .wait(
                "set quiche read state",
                self.sender.send(ReadControl {
                    paused,
                    acknowledged,
                }),
            )
            .await
            .expect("the quiche driver is running");
        self.deadline
            .wait("quiche acknowledged read state", received)
            .await
            .unwrap();
    }
}

impl Ears for Controls {
    async fn deaf(&mut self) {
        self.set_paused(true).await;
    }

    async fn hear(&mut self) {
        self.set_paused(false).await;
    }
}

struct ControlledPeer {
    ears: Controls,
    reports: tokio::sync::mpsc::UnboundedReceiver<Received>,
    task: Peer<()>,
}

fn controlled_peer(
    run: CaseRun<BackpressureScenario>,
    starting: impl std::future::Future<Output = Quiche> + Send + 'static,
) -> ControlledPeer {
    let (sender, mut controls) = tokio::sync::mpsc::channel::<ReadControl>(1);
    let (reports, arriving) = tokio::sync::mpsc::unbounded_channel();
    let deadline = run.deadline;
    let task = Peer::spawn(async move {
        let mut peer = starting.await;
        peer.drive_until(&run.what, deadline, |connection| {
            connection.is_established()
        })
        .await;
        let stream = match run.role {
            Role::RamaClient => 0,
            Role::RamaServer => 1,
        };
        let mut carried = Vec::new();
        let mut echoed = false;
        let mut paused = false;
        loop {
            // Complete sends before accepting a pause: extracting a quiche packet
            // then cancelling send_to would silently discard that packet.
            if !paused {
                peer.flush(deadline).await;
            }
            while peer.connection().dgram_recv_queue_len() != 0 {
                let bytes = peer.read_datagram(READ_CAP, deadline).await;
                reports
                    .send(Received::Bytes(bytes))
                    .expect("the test reads reports");
            }
            while peer.connection().stream_readable(stream) {
                let mut chunk = [0; 4096];
                match peer.connection().stream_recv(stream, &mut chunk) {
                    Ok((size, fin)) => {
                        assert!(!echoed, "the recovery stream ended already");
                        carried.extend_from_slice(&chunk[..size]);
                        assert!(carried.len() <= run.scenario.carried.len);
                        if fin {
                            assert_eq!(carried, run.scenario.carried.bytes());
                            peer.write_stream(stream, &carried, deadline).await;
                            echoed = true;
                        }
                    }
                    Err(quiche::Error::Done) => break,
                    Err(error) => panic!("recovery stream: {error}"),
                }
            }
            if peer.connection().is_closed() {
                assert!(
                    echoed,
                    "the recovery stream completed with exact bytes and FIN"
                );
                break;
            }
            tokio::select! {
                biased;
                command = controls.recv() => {
                    let command = command.expect("the test retains read controls until close");
                    paused = command.paused;
                    command.acknowledged.send(()).expect("the test awaits the read state");
                }
                () = peer.receive(deadline), if !paused => {}
                () = tokio::time::sleep_until(deadline.at()) => panic!("quiche pause exceeded the scenario deadline"),
            }
        }
    });
    ControlledPeer {
        ears: Controls { sender, deadline },
        reports: arriving,
        task,
    }
}

async fn backpressure(role: Role) {
    for_each_case(PEER, role, backpressure_cases(), |run| async move {
        let identity = Identity::generate(SERVER_NAME);
        let run = run.with_identity(identity.auth.clone());
        let (mut peer, filled) = match role {
            Role::RamaClient => {
                let (address, accepting) = Quiche::bind_server(
                    with_datagrams(quiche_server_config(&identity)),
                    run.deadline,
                )
                .await;
                let mut peer = controlled_peer(run.clone(), accepting);
                let filled = rama_client_fills_and_cancels(&run, address, &mut peer.ears).await;
                (peer, filled)
            }
            Role::RamaServer => {
                let endpoint = bind_backpressure_server(&run).await;
                let address = endpoint.local_addr().unwrap();
                let config = with_datagrams(quiche_client_config(&identity));
                let deadline = run.deadline;
                let mut peer = controlled_peer(run.clone(), async move {
                    Quiche::connect(address, SERVER_NAME, config, deadline).await
                });
                let filled = rama_server_fills_and_cancels(&run, endpoint, &mut peer.ears).await;
                (peer, filled)
            }
        };
        let mut reports = Vec::new();
        loop {
            let report = run
                .deadline
                .wait(&run.what, peer.reports.recv())
                .await
                .unwrap();
            let resumed = filled.sent.resumed(&report);
            reports.push(report);
            if resumed {
                break;
            }
        }
        let sent = filled.sent.clone();
        filled.close(&run.what, run.deadline).await;
        while let Some(report) = run.deadline.wait(&run.what, peer.reports.recv()).await {
            reports.push(report);
        }
        peer.task.join(&run.what, run.deadline).await;
        sent.account_for(&run.what, &reports);
    })
    .await;
}
