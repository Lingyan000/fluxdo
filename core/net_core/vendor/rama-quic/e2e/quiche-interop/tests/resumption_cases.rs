//! The shared resumption and 0-RTT cases, run against quiche as the server.
//!
//! quiche reports both verdicts itself: `is_resumed` says whether the session was taken up
//! again, and `early_data_reason` says what became of the early data, so nothing here is
//! inferred from the other. Which outcome a case gets is set by the second server's ticket key
//! and whether it takes early data at all; everything else about the two servers is the same.
//!
//! Three outcomes are told apart rather than inferred from one another: early data accepted,
//! early data refused while the session still resumes, and the resumption itself refused.
//! [`expected_reason`] pins what quiche must say for each, since a session that was never
//! resumed and a resumed session whose early data was refused are different facts.

mod common;

use common::{
    Identity, OTHER_TICKET_KEY, Quiche, TICKET_KEY, early_data, quiche_client_config,
    quiche_resuming_server_config,
};
use interop_common::{
    Arrival, CloseObservation, Expected, Received, Reported, ResumptionObservation,
    ResumptionScenario, Role, Verdict, for_each_case,
    identity::anchor_of,
    registry::CaseRun,
    resumption::{
        RamaResumptionConfigs, rama_client, rama_client_config_for, rama_client_resumes,
        rama_client_warms_up, rama_server_reading, resumption_cases,
    },
    scenario::SERVER_NAME,
    support::Peer,
};
use rama::utils::octets;
use std::net::SocketAddr;
use tokio::{net::UdpSocket, sync::oneshot};

const PEER: &str = "quiche";
const READ_CAP: usize = octets::mib(1);
/// The first unidirectional stream a client opens, and the first bidirectional one.
const CLIENT_UNI: u64 = 2;
const CLIENT_BI: u64 = 0;

/// Rama's client resumes a session with a quiche server, and offers early data on it where the
/// case does.
#[tokio::test]
async fn resumption_cases_rama_client() {
    for_each_case(
        PEER,
        Role::RamaClient,
        resumption_cases(),
        |run| async move {
            // quiche reads its identity from files, and one identity serves both connections.
            let served = Identity::generate(SERVER_NAME);
            let run = run.with_identity(served.auth.clone());
            // The first server always issues tickets that allow early data, so the session it
            // leaves behind carries early keys for the client to offer. What the second server
            // does with the offer is what the case is about.
            let (addr, accepting) = Quiche::bind_server(
                quiche_resuming_server_config(&served, &TICKET_KEY, true),
                run.deadline,
            )
            .await;
            let second = match run.scenario.verdict {
                // A ticket key of its own, which cannot read the ticket the first one issued.
                Verdict::NotResumed => {
                    quiche_resuming_server_config(&served, &OTHER_TICKET_KEY, true)
                }
                // The same authority over tickets, and no early data taken under it.
                Verdict::EarlyDataRefused => {
                    quiche_resuming_server_config(&served, &TICKET_KEY, false)
                }
                Verdict::EarlyDataAccepted | Verdict::ResumedWithoutEarlyData => {
                    quiche_resuming_server_config(&served, &TICKET_KEY, true)
                }
            };

            // quiche's driver serves one connection at a time and owns the socket while it does,
            // so the second attempt waits until the first has handed the socket on.
            let (ready, is_ready) = oneshot::channel();
            let peer = Peer::spawn({
                let run = run.clone();
                async move {
                    let socket = warmed(&run, accepting.await).await;
                    ready.send(()).expect("the case is listening");
                    second_connection(&run, socket, second).await
                }
            });

            // One configuration for both attempts: the ticket the first earns lives in its
            // resumption cache and is what the second offers.
            let config = rama_client_config_for(anchor_of(&run.identity), &run.scenario);
            let client = rama_client(&run).await;
            rama_client_warms_up(&run, &client, config.clone(), addr).await;
            run.deadline
                .wait(&run.what, is_ready)
                .await
                .expect("the peer handed its socket on");
            let rama = rama_client_resumes(&run, &client, config, addr).await;

            let observed = ResumptionObservation {
                rama,
                ..peer.join(&run.what, run.deadline).await
            };
            let withheld = observed.check(&run.what, &run.scenario);
            assert!(
                withheld.is_empty(),
                "{}: this peer reports both verdicts itself: {withheld:?}",
                run.what
            );
            observed.closed_as_the_client_did(&run.what);
            run.deadline.wait(&run.what, client.wait_idle()).await;
        },
    )
    .await;
}

/// The first connection: the exchange that earns the ticket, then the socket handed on.
async fn warmed(run: &CaseRun<ResumptionScenario>, mut server: Quiche) -> UdpSocket {
    let (what, deadline) = (&run.what, run.deadline);
    server
        .drive_until(what, deadline, |connection| connection.is_established())
        .await;
    let got = server.read_stream(CLIENT_BI, READ_CAP, deadline).await;
    Received::Bytes(got.clone()).check(what, "first exchange", run.scenario.warm);
    // Echoed, so the client has a round trip after the handshake, which is when the session
    // ticket follows.
    server.write_stream(CLIENT_BI, &got, deadline).await;
    server
        .drive_until(what, deadline, |connection| connection.is_closed())
        .await;
    server.into_socket()
}

/// The second connection: what quiche made of the resumption, and everything it read.
async fn second_connection(
    run: &CaseRun<ResumptionScenario>,
    socket: UdpSocket,
    config: quiche::Config,
) -> ResumptionObservation {
    let (what, deadline) = (&run.what, run.deadline);
    // Where early data is expected, the server is kept silent until it arrives: a server that
    // has sent nothing cannot have finished a handshake, so a stream readable while it stays
    // silent arrived on the early keys.
    let mut server = if run.scenario.verdict == Verdict::EarlyDataAccepted {
        let mut server = Quiche::accept_on_silently(socket, config, deadline).await;
        server
            .receive_until(what, deadline, |connection| {
                connection.stream_readable(CLIENT_UNI)
            })
            .await;
        assert!(
            !server.connection().is_established(),
            "{what}: the early bytes were on the wire before the handshake was let finish"
        );
        server
            .drive_until(what, deadline, |connection| connection.is_established())
            .await;
        server
    } else {
        let mut server = Quiche::accept_on(socket, config, deadline).await;
        // Nothing may be readable before the handshake finishes: whatever the client offered
        // was not taken on the early keys.
        let mut early = Vec::new();
        server
            .drive_until(what, deadline, |connection| {
                if !connection.is_established() {
                    early.extend(connection.readable());
                }
                connection.is_established()
            })
            .await;
        assert!(
            early.is_empty(),
            "{what}: no early bytes were taken, yet {early:?} was readable before the handshake"
        );
        server
    };
    let resumed = server.connection().is_resumed();
    let reason = server.connection().early_data_reason();
    assert_eq!(
        reason,
        expected_reason(run.scenario.verdict),
        "{what}: quiche's own reason for this verdict"
    );

    let mut received = Vec::new();
    for expected in run.scenario.expected() {
        let stream = match expected.arrival {
            Arrival::Uni => CLIENT_UNI,
            Arrival::Bi => CLIENT_BI,
        };
        let got = server.read_stream(stream, READ_CAP, deadline).await;
        if expected.arrival == Arrival::Bi {
            // Answered, so the client sees the barrier taken rather than infers it.
            server.write_stream(stream, &got, deadline).await;
        }
        received.push(Received::Bytes(got));
    }

    // The boundary this connection is counted against: the client closes only once the barrier
    // has come back to it, so anything else it sent was already on its way. Every stream that
    // becomes readable on the way to the close is read as well, so a payload delivered twice
    // fails the count rather than going unnoticed.
    let mut extra = Vec::new();
    server
        .drive_until(what, deadline, |connection| {
            for stream in connection.readable() {
                if !extra.contains(&stream) {
                    extra.push(stream);
                }
            }
            connection.peer_error().is_some() || connection.is_closed()
        })
        .await;
    for stream in extra {
        let got = server.read_stream(stream, READ_CAP, deadline).await;
        received.push(Received::Bytes(got));
    }

    ResumptionObservation {
        // Filled in by the caller from Rama's own side.
        rama: None,
        resumed: Reported::Seen(resumed),
        early_data: Reported::Seen(reason == early_data::ACCEPTED),
        received,
        closed: Some(the_clients_close(&mut server)),
        detail: Some(format!("early data reason {reason}")),
    }
}

/// The reason quiche must give for a case's verdict. `early_data_reason` tells a session that
/// was never resumed apart from one that was and whose early data was refused, and the two
/// refusals apart from one another, which the shared verdict alone does not.
///
/// The values are BoringSSL's `ssl_early_data_reason_t`, as vendored by quiche 0.24.9 at
/// `deps/boringssl/src/include/openssl/ssl.h:3513`.
fn expected_reason(verdict: Verdict) -> u32 {
    match verdict {
        Verdict::EarlyDataAccepted => early_data::ACCEPTED,
        // The second server never enabled early data, so it is disabled rather than declined.
        Verdict::EarlyDataRefused => early_data::DISABLED,
        Verdict::NotResumed => early_data::SESSION_NOT_RESUMED,
        // The client offered none, which is a refusal by the peer that had it to offer.
        Verdict::ResumedWithoutEarlyData => early_data::PEER_DECLINED,
    }
}

/// How quiche saw the client end the connection.
fn the_clients_close(server: &mut Quiche) -> CloseObservation {
    let ended = server
        .connection()
        .peer_error()
        .expect("the client stated why it stopped")
        .clone();
    CloseObservation {
        code: ended.error_code,
        reason: ended.reason,
        application: ended.is_app,
        // quiche's `peer_error` is by definition the close that arrived.
        received: Some(true),
    }
}

/// A quiche client resumes a session with a Rama server, and offers early data on it where the
/// case does.
///
/// Both sides can see this direction: quiche's client says whether it resumed and what became
/// of its early data, and Rama's own session store says whether it was asked for that session
/// and gave it up. The two are checked against each other.
#[tokio::test]
async fn resumption_cases_rama_server() {
    for_each_case(
        PEER,
        Role::RamaServer,
        resumption_cases(),
        |run| async move {
            // quiche reads its trust anchor from a file, so the identity Rama serves is generated
            // as one.
            let served = Identity::generate(SERVER_NAME);
            let run = run.with_identity(served.auth.clone());
            let configs = RamaResumptionConfigs::new(&run.identity);
            // The first server always allows early data, so the session it keeps carries early
            // keys for the client to offer.
            let (endpoint, addr, serving) = rama_server_reading(
                &run,
                configs.warming(),
                vec![Expected {
                    chunk: run.scenario.warm,
                    arrival: Arrival::Bi,
                }],
            )
            .await;
            let session = quiche_warms_up(&run, &served, addr).await;
            let warmed = serving.join(&run.what, run.deadline).await;
            assert_eq!(
                warmed.received.len(),
                1,
                "{}: the first connection carried the one exchange",
                run.what
            );
            warmed.received[0].check(&run.what, "first exchange", run.scenario.warm);
            assert_eq!(
                warmed.resumed,
                Some(false),
                "{}: a first handshake resumes nothing",
                run.what
            );
            run.deadline.wait(&run.what, endpoint.wait_idle()).await;
            configs.after_warmup(&run.what);
            let (resuming, active) = configs.resuming(run.scenario.verdict);
            let (endpoint, addr, serving) =
                rama_server_reading(&run, resuming, run.scenario.expected()).await;
            let (resumed, reason) = quiche_resumes(&run, &served, addr, &session).await;
            let report = serving.join(&run.what, run.deadline).await;
            // Two sides that decided for themselves, and they have to agree.
            assert_eq!(
                Some(resumed),
                report.resumed,
                "{}: the client and rama's own handshake agree on the resumption ({})",
                run.what,
                active()
            );
            let observed = ResumptionObservation {
                rama: report.resumed,
                resumed: Reported::Seen(resumed),
                early_data: Reported::Seen(reason == early_data::ACCEPTED),
                received: report.received,
                // Rama serves here, so the close this role sees is the peer's own, which the
                // peer chooses rather than the case.
                closed: None,
                detail: Some(format!("early data reason {reason}, {}", active())),
            };
            let withheld = observed.check(&run.what, &run.scenario);
            assert!(
                withheld.is_empty(),
                "{}: this peer reports both verdicts itself: {withheld:?}",
                run.what
            );
            run.deadline.wait(&run.what, endpoint.wait_idle()).await;
        },
    )
    .await;
}

/// The first connection: the exchange that earns the session, and the session itself.
async fn quiche_warms_up(
    run: &CaseRun<ResumptionScenario>,
    served: &Identity,
    addr: SocketAddr,
) -> Vec<u8> {
    let (what, deadline) = (&run.what, run.deadline);
    let mut client = Quiche::connect(
        addr,
        SERVER_NAME,
        quiche_client_config_for(served, run.scenario.offers_early_data),
        deadline,
    )
    .await;
    client
        .drive_until(what, deadline, |connection| connection.is_established())
        .await;
    client
        .write_stream(CLIENT_BI, &run.scenario.warm.bytes(), deadline)
        .await;
    let back = client.read_stream(CLIENT_BI, READ_CAP, deadline).await;
    Received::Bytes(back).check(what, "first exchange", run.scenario.warm);
    // The session ticket follows the handshake, so the connection is driven until it is there
    // rather than assumed to have arrived with the answer.
    client
        .drive_until(what, deadline, |connection| connection.session().is_some())
        .await;
    let session = client
        .connection()
        .session()
        .expect("the peer kept a session")
        .to_vec();
    client.close(deadline).await;
    session
}

/// The second attempt: the session offered, and the early data written on the early keys where
/// the case offers any.
///
/// Answers what quiche made of it: whether it resumed, and its own reason for what became of
/// the early data.
async fn quiche_resumes(
    run: &CaseRun<ResumptionScenario>,
    served: &Identity,
    addr: SocketAddr,
    session: &[u8],
) -> (bool, u32) {
    let (what, deadline) = (&run.what, run.deadline);
    let mut client = Quiche::connect_resuming(
        addr,
        SERVER_NAME,
        quiche_client_config_for(served, run.scenario.offers_early_data),
        session,
        deadline,
    )
    .await;
    if run.scenario.offers_early_data {
        // Written while the connection is in early data, so the payload goes on the early
        // keys rather than after the handshake.
        assert!(
            client.connection().is_in_early_data(),
            "{what}: the client had a session and early keys to offer"
        );
        client
            .write_stream(CLIENT_UNI, &run.scenario.early.bytes(), deadline)
            .await;
    }
    client
        .drive_until(what, deadline, |connection| connection.is_established())
        .await;
    let resumed = client.connection().is_resumed();
    let reason = client.connection().early_data_reason();
    assert_eq!(
        reason == early_data::ACCEPTED,
        run.scenario.verdict == Verdict::EarlyDataAccepted,
        "{what}: what the client made of its early data (reason {reason})"
    );
    // Nothing is sent again after a refusal here, and the payload still arrives exactly once:
    // quiche keeps the stream and puts its data on the keys that survived, where Rama's client
    // ends the stream with `ZeroRttRejected` and leaves the sending to the application. The
    // payload count is what holds this to once either way.
    client
        .write_stream(CLIENT_BI, &run.scenario.barrier.bytes(), deadline)
        .await;
    let back = client.read_stream(CLIENT_BI, READ_CAP, deadline).await;
    Received::Bytes(back).check(what, "barrier", run.scenario.barrier);
    client.close(deadline).await;
    (resumed, reason)
}

/// A quiche client that trusts what Rama serves, asking for early keys only where the case
/// offers early data.
fn quiche_client_config_for(served: &Identity, early_data: bool) -> quiche::Config {
    let mut config = quiche_client_config(served);
    if early_data {
        config.enable_early_data();
    }
    config
}
