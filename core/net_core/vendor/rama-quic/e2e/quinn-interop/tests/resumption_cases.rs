//! The shared resumption and 0-RTT cases, run against Quinn as the server.
//!
//! Quinn's server side reports neither verdict itself: `HandshakeData` carries the protocol
//! and the name and nothing about resumption, and `into_0rtt` on an incoming connection always
//! succeeds with a verdict of true (quinn 0.11.11, `src/connection.rs`), so it says nothing
//! about the client's early data.
//!
//! What this adapter observes instead is the one event that makes a session resume here:
//! Rama's own handshake, through `NegotiatedTlsParameters::resumed`. The server's session store is
//! wrapped as well, but only to say what rustls looked for: a lookup that found something is
//! not a resumption, and the counts are diagnostics.
//!
//! Resumption is stateful here and not by ticket, because rustls implements RFC 8446 §8.1 by
//! allowing early data only with stateful resumption: `server/tls13.rs` reads
//! `max_early_data_size > 0 && !config.ticketer.enabled()`, so a server with a ticketer resumes
//! and can never accept early data.
//!
//! Early-data acceptance is the server's own answer, and it reaches the client through the
//! handshake, where the shared code asserts it. Nothing here guesses at it: this side reports
//! it unavailable.

mod common;

use std::assert_matches;
use std::{net::SocketAddr, sync::Arc};

use common::ALPN;
use interop_common::{
    Arrival, Chunk, CloseObservation, Expected, Identity, Received, RecordingSessions, Reported,
    ResumptionObservation, ResumptionScenario, Role, Verdict, for_each_case,
    identity::anchor_of,
    registry::CaseRun,
    resumption::{
        RamaResumptionConfigs, rama_client, rama_client_config_for, rama_client_resumes,
        rama_client_warms_up, rama_server_reading, resumption_cases,
    },
    scenario::SERVER_NAME,
    support::{Deadline, Peer, localhost},
};
use rama::{crypto::pki_types::CertificateDer, utils::octets};

const PEER: &str = "quinn";
const READ_CAP: usize = octets::mib(1);

/// A Quinn server that remembers sessions, and accepts early data only where the case wants it
/// accepted. Everything else about the two servers a case uses is the same.
fn quinn_resuming_server_config(
    auth: &Identity,
    sessions: Arc<RecordingSessions>,
    early_data: bool,
) -> quinn::ServerConfig {
    let mut tls = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_protocol_versions(&[&rustls::version::TLS13])
    .expect("TLS 1.3 is supported")
    .with_no_client_auth()
    .with_single_cert(auth.cert_chain.clone(), auth.private_key.clone_key())
    .expect("the identity is accepted");
    tls.alpn_protocols = vec![ALPN.to_vec()];
    tls.session_storage = sessions;
    tls.send_tls13_tickets = 1;
    // QUIC allows only these two values (RFC 9001 §4.6.1), and zero is a server that resumes
    // and refuses early data.
    tls.max_early_data_size = if early_data { u32::MAX } else { 0 };
    quinn::ServerConfig::with_crypto(Arc::new(
        quinn::crypto::rustls::QuicServerConfig::try_from(tls).expect("a QUIC server config"),
    ))
}

/// Rama's client resumes a session with a Quinn server, and offers early data on it where the
/// case does.
#[tokio::test]
async fn resumption_cases_rama_client() {
    for_each_case(
        PEER,
        Role::RamaClient,
        resumption_cases(),
        |run| async move {
            let sessions = RecordingSessions::new();
            // The first server always allows early data, so the session it leaves behind carries
            // early keys for the client to offer. What the second server does with the offer is
            // what the case is about.
            let first = quinn::Endpoint::server(
                quinn_resuming_server_config(&run.identity, sessions.clone(), true),
                localhost(),
            )
            .expect("the quinn server binds");
            let warming = serve_one(&run, first.clone(), None);

            // One configuration for both attempts: the ticket the first earns lives in its
            // resumption cache and is what the second offers.
            let config = rama_client_config_for(anchor_of(&run.identity), &run.scenario);
            let client = rama_client(&run).await;
            rama_client_warms_up(
                &run,
                &client,
                config.clone(),
                first.local_addr().expect("its address"),
            )
            .await;
            warming.join(&run.what, run.deadline).await;
            assert!(
                sessions.kept_a_session(),
                "{}: the first connection left a session behind ({})",
                run.what,
                sessions.detail()
            );
            // Only offers made from here on count towards the second attempt's verdict.
            sessions.forget_offers();

            // What the second server changes about the first is one thing, named by the case: the
            // store it looks in, or whether it takes early data at all.
            let resuming = match run.scenario.verdict {
                // A store of its own, which does not hold the session the other one kept.
                Verdict::NotResumed => {
                    second_server(&run, RecordingSessions::new(), true, &first).await
                }
                // The same sessions, and no early data taken from them.
                Verdict::EarlyDataRefused => {
                    second_server(&run, sessions.clone(), false, &first).await
                }
                Verdict::EarlyDataAccepted | Verdict::ResumedWithoutEarlyData => first.clone(),
            };
            let observing = serve_one(&run, resuming.clone(), Some(sessions.clone()));
            let rama = rama_client_resumes(
                &run,
                &client,
                config,
                resuming.local_addr().expect("its address"),
            )
            .await;
            let observed = ResumptionObservation {
                rama,
                ..observing.join(&run.what, run.deadline).await
            };
            let withheld = observed.check(&run.what, &run.scenario);
            for reason in withheld {
                // Visible with `cargo test -- --nocapture`.
                println!("{}: {reason}", run.what);
            }
            observed.closed_as_the_client_did(&run.what);
            run.deadline.wait(&run.what, client.wait_idle()).await;
            resuming.close(0u32.into(), b"done");
            run.deadline.wait(&run.what, resuming.wait_idle()).await;
        },
    )
    .await;
}

/// The second server of a case, and the first one closed: quinn hands an attempt to whichever
/// endpoint the datagram reached, so the one that is finished with goes away first.
async fn second_server(
    run: &CaseRun<ResumptionScenario>,
    sessions: Arc<RecordingSessions>,
    early_data: bool,
    first: &quinn::Endpoint,
) -> quinn::Endpoint {
    first.close(0u32.into(), b"done");
    run.deadline.wait(&run.what, first.wait_idle()).await;
    quinn::Endpoint::server(
        quinn_resuming_server_config(&run.identity, sessions, early_data),
        localhost(),
    )
    .expect("the second quinn server binds")
}

/// One connection served: it reads exactly the payloads the case says arrive, answers the
/// bidirectional ones with the same bytes, and reports what it read. Without a session store
/// to ask, it is the warm-up and reports nothing.
fn serve_one(
    run: &CaseRun<ResumptionScenario>,
    server: quinn::Endpoint,
    sessions: Option<Arc<RecordingSessions>>,
) -> Peer<ResumptionObservation> {
    let run = run.clone();
    Peer::spawn(async move {
        let (what, deadline) = (run.what.clone(), run.deadline);
        let attempt = deadline
            .wait(&what, server.accept())
            .await
            .expect("an attempt arrives");
        let conn = deadline
            .wait(&what, attempt)
            .await
            .expect("the handshake completes");
        let arrivals = match &sessions {
            Some(_) => run.scenario.expected(),
            None => vec![Expected {
                chunk: run.scenario.warm,
                arrival: Arrival::Bi,
            }],
        };
        let mut received = Vec::new();
        for expected in arrivals {
            received.push(read_one(&what, deadline, &conn, expected.arrival).await);
        }
        // The boundary this connection is counted against: the client closes only once the
        // barrier has come back to it, so anything else it sent was already on its way. Both
        // kinds of stream are drained until the close ends them, and whatever turns up is
        // added to what was read, so a payload delivered twice fails the count rather than
        // going unnoticed.
        // Owned guards, so a scenario that ends early takes these with it rather than leaving
        // them running, and a read that fails inside one is raised by the join.
        let draining = [Arrival::Uni, Arrival::Bi].map(|arrival| {
            let (what, conn) = (what.clone(), conn.clone());
            Peer::spawn(async move {
                let mut extra = Vec::new();
                while let Some(more) = read_more(&what, deadline, &conn, arrival).await {
                    extra.push(more);
                }
                extra
            })
        });
        let ended = deadline.wait(&what, conn.closed()).await;
        for draining in draining {
            received.extend(draining.join(&what, deadline).await);
        }
        ResumptionObservation {
            // Filled in by the caller from Rama's own side.
            rama: None,
            // The store counts say what rustls looked for, not what the handshake settled;
            // the verdict is Rama's own, and this side has none of its own to give.
            resumed: Reported::Unavailable(
                "quinn's server reports no resumption of its own: its handshake data carries \
                 the protocol and the name and nothing else",
            ),
            early_data: Reported::Unavailable(
                "quinn's server reports no early-data verdict of its own; what the server \
                 decided reaches the client through the handshake, and the shared client side \
                 asserts it there",
            ),
            received,
            closed: Some(the_clients_close(&what, ended)),
            detail: sessions.as_ref().map(|sessions| sessions.detail()),
        }
    })
}

/// How Quinn saw the client end the connection.
fn the_clients_close(what: &str, ended: quinn::ConnectionError) -> CloseObservation {
    let quinn::ConnectionError::ApplicationClosed(ref close) = ended else {
        panic!("{what}: the client closed the connection rather than it failing: {ended:?}");
    };
    CloseObservation {
        code: close.error_code.into_inner(),
        reason: close.reason.to_vec(),
        application: true,
        // Quinn reports `LocallyClosed` for a close of its own, so this variant is both the
        // category and the origin.
        received: Some(true),
    }
}

/// One more stream of that kind if the connection is still carrying any, and nothing once the
/// close has ended it.
async fn read_more(
    what: &str,
    deadline: Deadline,
    conn: &quinn::Connection,
    arrival: Arrival,
) -> Option<Received> {
    match arrival {
        Arrival::Uni => {
            let mut recv = deadline.wait(what, conn.accept_uni()).await.ok()?;
            Some(Received::Bytes(
                deadline
                    .wait(what, recv.read_to_end(READ_CAP))
                    .await
                    .expect("a stream that opened completes"),
            ))
        }
        Arrival::Bi => {
            let (_send, mut recv) = deadline.wait(what, conn.accept_bi()).await.ok()?;
            Some(Received::Bytes(
                deadline
                    .wait(what, recv.read_to_end(READ_CAP))
                    .await
                    .expect("a stream that opened completes"),
            ))
        }
    }
}

/// Read one payload the way the case says it arrives, answering a bidirectional one with the
/// same bytes so the client sees it taken.
async fn read_one(
    what: &str,
    deadline: Deadline,
    conn: &quinn::Connection,
    arrival: Arrival,
) -> Received {
    match arrival {
        Arrival::Uni => {
            let mut recv = deadline
                .wait(what, conn.accept_uni())
                .await
                .expect("the stream arrives");
            Received::Bytes(
                deadline
                    .wait(what, recv.read_to_end(READ_CAP))
                    .await
                    .expect("it completes"),
            )
        }
        Arrival::Bi => {
            let (mut send, mut recv) = deadline
                .wait(what, conn.accept_bi())
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
            Received::Bytes(got)
        }
    }
}

/// A Quinn client resumes a session with a Rama server, and offers early data on it where the
/// case does.
///
/// Quinn's client reports what it was told about its early data, through the verdict
/// `into_0rtt` hands back; whether the session itself resumed is Rama's own handshake, read
/// from `NegotiatedTlsParameters::resumed` on the server side.
#[tokio::test]
async fn resumption_cases_rama_server() {
    for_each_case(
        PEER,
        Role::RamaServer,
        resumption_cases(),
        |run| async move {
            let configs = RamaResumptionConfigs::new(&run.identity);
            // The first server always allows early data, so the session it keeps carries early
            // keys for the client to offer.
            let warming = configs.warming();
            let (endpoint, addr, serving) = rama_server_reading(
                &run,
                warming,
                vec![Expected {
                    chunk: run.scenario.warm,
                    arrival: Arrival::Bi,
                }],
            )
            .await;

            // One configuration for both attempts: the session the first earns lives in its
            // resumption cache and is what the second offers.
            let config = quinn_client_config_for(anchor_of(&run.identity), &run.scenario);
            let mut client = quinn::Endpoint::client(localhost()).expect("the quinn client binds");
            client.set_default_client_config(config);
            quinn_warms_up(&run, &client, addr).await;
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
            let early_accepted = quinn_resumes(&run, &client, addr).await;
            let report = serving.join(&run.what, run.deadline).await;
            let observed = ResumptionObservation {
                rama: report.resumed,
                // Quinn's client says nothing about the resumption itself; what it is told is the
                // early-data verdict below.
                resumed: Reported::Unavailable("quinn's client reports no resumption of its own"),
                // A case that offers no early data is told nothing about any, and a verdict
                // nobody gave is not one to report.
                early_data: early_accepted.map_or(
                    Reported::Unavailable(
                        "this attempt offered no early data, so the client was told no verdict",
                    ),
                    Reported::Seen,
                ),
                received: report.received,
                // Rama serves here, so the close this role sees is the peer's own, which the
                // peer chooses rather than the case.
                closed: None,
                detail: Some(active()),
            };
            let withheld = observed.check(&run.what, &run.scenario);
            assert_eq!(
                withheld.len(),
                if run.scenario.offers_early_data { 1 } else { 2 },
                "{}: quinn's client tells the resumption to nobody, and an attempt that offers no \
             early data is told no verdict either: {withheld:?}",
                run.what
            );
            for reason in withheld {
                // Visible with `cargo test -- --nocapture`.
                println!("{}: {reason}", run.what);
            }
            client.close(0u32.into(), b"done");
            run.deadline.wait(&run.what, client.wait_idle()).await;
            run.deadline.wait(&run.what, endpoint.wait_idle()).await;
        },
    )
    .await;
}

/// A Quinn client configuration that asks for early keys only where the case offers early
/// data. Its resumption cache is rustls's own, and it is the one configuration both attempts
/// use, so the session the first earns is the one the second offers.
fn quinn_client_config_for(
    anchor: CertificateDer<'static>,
    scenario: &ResumptionScenario,
) -> quinn::ClientConfig {
    let mut roots = rustls::RootCertStore::empty();
    roots.add(anchor).expect("the anchor is accepted");
    let mut tls = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_protocol_versions(&[&rustls::version::TLS13])
    .expect("TLS 1.3 is supported")
    .with_root_certificates(roots)
    .with_no_client_auth();
    tls.alpn_protocols = vec![ALPN.to_vec()];
    tls.enable_early_data = scenario.offers_early_data;
    quinn::ClientConfig::new(Arc::new(
        quinn::crypto::rustls::QuicClientConfig::try_from(tls).expect("a QUIC client config"),
    ))
}

/// The first connection: the exchange that earns the session, then a close.
async fn quinn_warms_up(
    run: &CaseRun<ResumptionScenario>,
    client: &quinn::Endpoint,
    addr: SocketAddr,
) {
    let (what, deadline) = (&run.what, run.deadline);
    let connection = deadline
        .wait(
            what,
            client
                .connect(addr, SERVER_NAME)
                .expect("the attempt starts"),
        )
        .await
        .expect("the first handshake completes");
    quinn_exchange(what, deadline, &connection, run.scenario.warm).await;
    connection.close(0u32.into(), b"done");
    deadline.wait(what, connection.closed()).await;
}

/// The second attempt. Answers what the client was told about its early data, or nothing
/// where it offered none.
async fn quinn_resumes(
    run: &CaseRun<ResumptionScenario>,
    client: &quinn::Endpoint,
    addr: SocketAddr,
) -> Option<bool> {
    let (what, deadline) = (&run.what, run.deadline);
    let attempt = client
        .connect(addr, SERVER_NAME)
        .expect("the attempt starts");
    let (connection, taken) = if run.scenario.offers_early_data {
        // The ticket witness: early keys to offer means the first connection left a session
        // behind that this one can use.
        let (connection, accepted) = attempt
            .into_0rtt()
            .unwrap_or_else(|_| panic!("{what}: the client had a session and early keys to offer"));
        let mut early = deadline
            .wait(what, connection.open_uni())
            .await
            .expect("an early stream opens");
        deadline
            .wait(what, early.write_all(&run.scenario.early.bytes()))
            .await
            .expect("the early payload is written");
        early.finish().expect("the early stream ends");
        // Quinn's verdict is the bool itself; the handshake failing would have shown up as
        // the connection ending instead.
        let taken = deadline.wait(what, accepted).await;
        assert_eq!(
            taken,
            run.scenario.verdict == Verdict::EarlyDataAccepted,
            "{what}: what the client was told about its early data"
        );
        if !taken {
            // The stream opened before the handshake did not survive the refusal, and the
            // payload the application handed over is still owed to the peer.
            let refused = deadline
                .wait(what, early.stopped())
                .await
                .expect_err("a refused early stream does not end cleanly");
            assert_matches!(
                refused,
                quinn::StoppedError::ZeroRttRejected,
                "{what}: the refusal is what ended it, not something else: {refused:?}",
            );
            let mut again = deadline
                .wait(what, connection.open_uni())
                .await
                .expect("a stream after the refusal opens");
            deadline
                .wait(what, again.write_all(&run.scenario.early.bytes()))
                .await
                .expect("the payload is written again");
            again.finish().expect("the second attempt at it ends");
        }
        (connection, Some(taken))
    } else {
        (
            deadline
                .wait(what, attempt)
                .await
                .expect("the second handshake completes"),
            None,
        )
    };
    quinn_exchange(what, deadline, &connection, run.scenario.barrier).await;
    connection.close(0u32.into(), b"done");
    deadline.wait(what, connection.closed()).await;
    taken
}

/// One bidirectional exchange, checked by length and digest on the way back.
async fn quinn_exchange(
    what: &str,
    deadline: Deadline,
    connection: &quinn::Connection,
    payload: Chunk,
) {
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
