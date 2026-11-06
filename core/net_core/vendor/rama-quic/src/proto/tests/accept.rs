//! An accept split around its handshake work: what `start_accept` reserves stays exact until
//! `finish_accept` or `abandon_accept` settles it, whatever happens to the attempt in between.

use std::assert_matches;

use quickcheck::{Arbitrary, Gen, QuickCheck, TestResult};
use rama_quic_proto::packet::SpaceId;

use super::*;
use crate::proto::endpoint::{Accepted, Accepting, incoming_datagram_charge};

const LIMIT: Duration = Duration::from_millis(100);

fn pair_with(endpoint: EndpointConfig, server: ServerConfig) -> Pair {
    let mut endpoint = endpoint;
    endpoint.handshake_timeout(LIMIT).unwrap();
    let mut pair = Pair::new(Arc::new(endpoint), server);
    pair.server.handle_incoming = Box::new(|_| IncomingConnectionBehavior::Wait);
    pair
}

fn pair() -> Pair {
    pair_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        server_config(),
    )
}

fn zero_cid_endpoint() -> EndpointConfig {
    let mut endpoint = EndpointConfig::try_with_rand_key().unwrap();
    endpoint.set_cid_generator(Arc::new(|| {
        Box::new(RandomConnectionIdGenerator::new(0).unwrap())
    }));
    endpoint
}

fn arrive(pair: &mut Pair, config: ClientConfig) -> (ConnectionHandle, Incoming) {
    let client = pair.begin_connect(config);
    pair.drive_client();
    pair.drive_server();
    (client, pair.server.waiting_incoming.pop().unwrap())
}

fn start(pair: &mut Pair, incoming: Incoming, config: Option<ServerConfig>) -> Accepting {
    pair.server
        .start_accept(incoming, pair.time, &mut Vec::new(), config.map(Arc::new))
        .unwrap()
}

/// A server configuration whose TLS refuses every client's ALPN.
fn refusing_server() -> ServerConfig {
    ServerConfig::with_crypto(Arc::new(server_crypto_with_alpn(vec![b"nobody".to_vec()])))
}

fn assert_released(pair: &Pair) {
    assert_eq!(pair.server.known_cids(), 0, "minted identifiers retired");
    assert_eq!(pair.server.pending_incoming(), 0, "incoming buffer removed");
    assert_eq!(
        pair.server.incoming_buffer_bytes(),
        0,
        "buffered bytes released"
    );
    assert_eq!(
        pair.server.admission_load(pair.time).0,
        0,
        "admission released"
    );
    assert!(
        pair.server.poll_incoming_timeout().is_none(),
        "deadline gone"
    );
}

fn assert_connected(pair: &mut Pair, client: ConnectionHandle) {
    pair.drive();
    assert_matches!(
        pair.client_conn_mut(client).poll(),
        Some(Event::HandshakeDataReady)
    );
    assert_matches!(pair.client_conn_mut(client).poll(), Some(Event::Connected));
}

#[test]
fn an_accept_between_phases_stays_pending_and_holds_its_reservation() {
    let mut pair = pair_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        server_config().with_max_incoming(1),
    );
    let (client, incoming) = arrive(&mut pair, client_config());
    let accepting = start(&mut pair, incoming, None);
    assert_eq!(pair.server.pending_incoming(), 1);
    assert_eq!(pair.server.admission_load(pair.time).0, 1);
    assert_eq!(
        pair.server.known_cids(),
        1,
        "the connection's identifier is reserved"
    );
    assert_eq!(pair.server.open_connections(), 0);

    // The accept still counts toward the incoming limit: another attempt finds it saturated.
    let other = pair.begin_connect(client_config());
    pair.drive_client();
    pair.drive_server();
    assert!(pair.server.waiting_incoming.is_empty());
    pair.client.connections.remove(&other);

    let server = pair.server.finish(accepting.accept()).unwrap();
    assert_eq!(pair.server.pending_incoming(), 0);
    assert_eq!(pair.server.open_connections(), 1);
    assert_eq!(pair.server.cids_routing_to(server).len(), 1);
    assert_connected(&mut pair, client);
}

#[test]
fn datagrams_arriving_between_phases_reach_the_connection() {
    let mut pair = pair();
    let client = pair.begin_connect(client_config());
    pair.drive_client();
    let retransmitted = pair.server.inbound.front().unwrap().clone();
    pair.drive_server();
    let incoming = pair.server.waiting_incoming.pop().unwrap();
    let accepting = start(&mut pair, incoming, None);

    pair.server.inbound.push_back(retransmitted.clone());
    pair.drive_server();
    assert!(
        pair.server.waiting_incoming.is_empty(),
        "held for the attempt, not a new one"
    );
    assert_eq!(
        pair.server.incoming_buffer_bytes(),
        incoming_datagram_charge(retransmitted.packet.len())
    );

    let server = pair.server.finish(accepting.accept()).unwrap();
    assert_eq!(pair.server.incoming_buffer_bytes(), 0);
    assert_eq!(pair.server_conn_mut(server).stats().udp_rx.datagrams, 1);
    assert_connected(&mut pair, client);
}

/// The datagrams buffered before acceptance began are processed with the first packet, so a
/// ClientHello spanning several Initials completes, and the server's first flight is built,
/// before the connection is registered rather than while registering it.
#[test]
fn a_client_hello_spanning_initials_completes_before_registration() {
    let mut pair = pair_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        ServerConfig::with_crypto(Arc::new(server_crypto_with_alpn(vec![vec![0, 0, 0, 42]]))),
    );
    let client_crypto =
        client_crypto_with_alpn((0..300u32).map(|x| x.to_be_bytes().to_vec()).collect());
    let client = pair.begin_connect(ClientConfig::new(Arc::new(client_crypto)));
    pair.drive_client();
    assert!(
        pair.server.inbound.len() >= 2,
        "the ClientHello spans several Initials"
    );
    pair.drive_server();
    let incoming = pair.server.waiting_incoming.pop().unwrap();
    assert!(pair.server.incoming_buffer_bytes() > 0);

    let accepted = start(&mut pair, incoming, None).accept();
    assert_ne!(
        accepted.connection().unwrap().highest_space(),
        SpaceId::Initial,
        "the whole ClientHello was processed before registration"
    );
    pair.server.finish(accepted).unwrap();
    assert_eq!(pair.server.incoming_buffer_bytes(), 0);
    assert_connected(&mut pair, client);
}

/// The rest of a ClientHello that arrives while the handshake runs is handed back with the
/// registered connection rather than processed while registering it, so completing the
/// ClientHello (and signing the first flight) stays outside the endpoint.
#[test]
fn the_rest_of_a_client_hello_arriving_between_phases_is_handed_back() {
    let mut pair = pair_with(
        EndpointConfig::try_with_rand_key().unwrap(),
        ServerConfig::with_crypto(Arc::new(server_crypto_with_alpn(vec![vec![0, 0, 0, 42]]))),
    );
    let client_crypto =
        client_crypto_with_alpn((0..300u32).map(|x| x.to_be_bytes().to_vec()).collect());
    let client = pair.begin_connect(ClientConfig::new(Arc::new(client_crypto)));
    pair.drive_client();
    let rest: Vec<_> = pair.server.inbound.drain(1..).collect();
    assert!(!rest.is_empty(), "the ClientHello spans several Initials");
    pair.drive_server();
    let incoming = pair.server.waiting_incoming.pop().unwrap();
    let accepting = start(&mut pair, incoming, None);
    pair.server.inbound.extend(rest.iter().cloned());
    pair.drive_server();

    let accepted = accepting.accept();
    assert_eq!(
        accepted.connection().unwrap().highest_space(),
        SpaceId::Initial,
        "the ClientHello is still incomplete"
    );
    let registered = pair
        .server
        .endpoint
        .finish_accept(accepted, &mut Vec::new())
        .unwrap();
    assert_eq!(registered.late.len(), rest.len());
    assert_eq!(
        registered.connection.highest_space(),
        SpaceId::Initial,
        "not processed while registering"
    );
    assert_eq!(pair.server.incoming_buffer_bytes(), 0);
    let (handle, conn, _admission) = registered.replayed();
    assert_ne!(conn.highest_space(), SpaceId::Initial);
    pair.server.connections.insert(handle, conn);
    assert_connected(&mut pair, client);
}

#[test]
fn a_failed_handshake_between_phases_releases_what_was_reserved() {
    let mut pair = pair();
    let (client, incoming) = arrive(&mut pair, client_config());
    let accepting = start(&mut pair, incoming, Some(refusing_server()));
    assert_eq!(pair.server.known_cids(), 1);
    assert_matches!(
        pair.server.finish(accepting.accept()),
        Err(ConnectionError::TransportError(_))
    );
    assert_released(&pair);
    assert_eq!(pair.server.open_connections(), 0);
    pair.drive();
    assert_matches!(
        pair.client_conn_mut(client).poll(),
        Some(Event::ConnectionLost {
            reason: ConnectionError::ConnectionClosed(_)
        })
    );
}

#[derive(Debug, Clone, Copy)]
enum Release {
    /// Nothing happens to the attempt between the phases.
    Kept,
    Expired,
    Discarded,
    DiscardedAll,
}

#[derive(Debug, Clone, Copy)]
enum Settle {
    Finish,
    Abandon,
}

/// Whatever retires the attempt between the phases releases its reservation exactly once:
/// settling the accept afterwards neither answers the client nor touches the attempt that
/// took over its incoming slot.
#[test]
fn an_attempt_retired_between_phases_is_released_once() {
    for release in [
        Release::Kept,
        Release::Expired,
        Release::Discarded,
        Release::DiscardedAll,
    ] {
        for settle in [Settle::Finish, Settle::Abandon] {
            if matches!((release, settle), (Release::Kept, Settle::Finish)) {
                continue;
            }
            let mut pair = pair();
            let (stale_client, incoming) = arrive(&mut pair, client_config());
            let accepting = start(&mut pair, incoming, None);
            match release {
                Release::Kept => {}
                Release::Expired => {
                    pair.time += LIMIT;
                    assert_eq!(pair.server.expire_incoming(pair.time, 8), 1);
                }
                Release::Discarded => pair.server.discard_incoming(8),
                Release::DiscardedAll => pair.server.discard_all_incoming(),
            }
            if !matches!(release, Release::Kept) {
                assert_released(&pair);
            }
            // Only the server side of the retired attempt matters from here.
            pair.client.connections.remove(&stale_client);
            let (client, current) = arrive(&mut pair, client_config());
            let accepted = accepting.accept();
            match settle {
                Settle::Finish => {
                    let mut buf = Vec::new();
                    let error = pair
                        .server
                        .endpoint
                        .finish_accept(accepted, &mut buf)
                        .unwrap_err();
                    assert_matches!(error.cause, ConnectionError::TimedOut, "{release:?}");
                    assert!(error.response.is_none(), "{release:?}: nothing to answer");
                }
                Settle::Abandon => pair.server.endpoint.abandon_accept(accepted),
            }
            assert!(pair.server.outbound.is_empty(), "{release:?} {settle:?}");
            assert_eq!(pair.server.pending_incoming(), 1, "{release:?} {settle:?}");
            assert_eq!(pair.server.known_cids(), 0, "{release:?} {settle:?}");
            assert_eq!(pair.server.admission_load(pair.time).0, 1);
            assert!(!current.is_expired(), "{release:?} {settle:?}");
            pair.server.try_accept(current, pair.time).unwrap();
            assert_connected(&mut pair, client);
        }
    }
}

/// A zero-CID server refuses a fresh attempt from an established connection's addresses: a
/// sender that never proved it receives there cannot take that connection's route over.
#[test]
fn a_fresh_attempt_never_takes_over_an_established_zero_cid_route() {
    let mut pair = pair_with(zero_cid_endpoint(), server_config());
    pair.server.handle_incoming = Box::new(|_| IncomingConnectionBehavior::Accept);
    let (client, server) = pair.connect();
    pair.server.handle_incoming = Box::new(|_| IncomingConnectionBehavior::Wait);
    pair.fresh_attempt_from_client_address(client_config());
    pair.drive_server();
    let incoming = pair.server.waiting_incoming.pop().unwrap();
    assert_matches!(
        pair.server.try_accept(incoming, pair.time),
        Err(ConnectionError::EndpointInUse)
    );
    assert_eq!(pair.server.open_connections(), 1);
    for _ in 0..40 {
        pair.time += LIMIT;
        pair.drive_client();
        pair.drive_server();
    }
    let after = Bytes::from_static(b"established route survived the attempt");
    pair.client_datagrams(client)
        .send(after.clone(), true)
        .unwrap();
    pair.drive_client();
    pair.drive_server();
    assert_eq!(pair.server_datagrams(server).recv(), Some(after));
}

/// The identifier for a preferred address is minted with the connection's own and follows it:
/// routed to the connection once registered, retired with the attempt otherwise.
#[test]
fn a_preferred_address_identifier_follows_the_accept() {
    for fail in [false, true] {
        let mut config = if fail {
            refusing_server()
        } else {
            server_config()
        };
        config.preferred_address_v4 = Some("127.0.0.1:444".parse().unwrap());
        let mut pair = pair_with(EndpointConfig::try_with_rand_key().unwrap(), config);
        let (_client, incoming) = arrive(&mut pair, client_config());
        let accepting = start(&mut pair, incoming, None);
        assert_eq!(pair.server.known_cids(), 2);
        let outcome = pair.server.finish(accepting.accept());
        assert_eq!(outcome.is_err(), fail);
        if let Ok(server) = outcome {
            assert_eq!(pair.server.cids_routing_to(server).len(), 2);
        } else {
            assert_released(&pair);
        }
    }
}

/// One step of a scenario over many attempts, each in some phase of acceptance.
#[derive(Debug, Clone, Copy)]
enum Step {
    Arrive,
    Start(usize),
    Run(usize),
    Finish(usize),
    Abandon(usize),
    Ignore(usize),
    /// A copy of an attempt's first datagram arrives again.
    Retransmit(usize),
    /// Time passes, by quarters of the handshake deadline, and expired attempts are retired.
    Advance(u8),
    DiscardAll,
}

impl Arbitrary for Step {
    fn arbitrary(g: &mut Gen) -> Self {
        let pick = usize::arbitrary(g);
        match u8::arbitrary(g) % 12 {
            0 | 1 => Self::Arrive,
            2 | 3 => Self::Start(pick),
            4 => Self::Run(pick),
            5 | 6 => Self::Finish(pick),
            7 => Self::Abandon(pick),
            8 => Self::Ignore(pick),
            9 => Self::Retransmit(pick),
            10 => Self::Advance(1 + u8::arbitrary(g) % 4),
            _ => Self::DiscardAll,
        }
    }
}

/// Where an attempt is, as the application holds it.
enum Held {
    Waiting(Box<Incoming>),
    Accepting(Box<Accepting>),
    Accepted(Box<Accepted>),
    Registered,
    Gone,
}

/// One attempt, and what the endpoint should be holding for it.
struct Attempt {
    flight: usize,
    held: Held,
    deadline: Instant,
    /// Its incoming buffer is still in the endpoint.
    live: bool,
    /// Its acceptance began, so it holds an identifier.
    started: bool,
    buffered: u64,
}

fn nth(
    attempts: &mut [Attempt],
    pick: usize,
    mut fits: impl FnMut(&Held) -> bool,
) -> Option<&mut Attempt> {
    let matching = attempts.iter().filter(|a| fits(&a.held)).count();
    if matching == 0 {
        return None;
    }
    attempts
        .iter_mut()
        .filter(|a| fits(&a.held))
        .nth(pick % matching)
}

fn check(pair: &Pair, attempts: &[Attempt], step: Step) -> Result<(), String> {
    let live = attempts.iter().filter(|a| a.live).count();
    let registered = attempts
        .iter()
        .filter(|a| matches!(a.held, Held::Registered))
        .count();
    let reserved = attempts.iter().filter(|a| a.live && a.started).count();
    let buffered: u64 = attempts.iter().filter(|a| a.live).map(|a| a.buffered).sum();
    let observed = (
        pair.server.pending_incoming(),
        pair.server.admission_load(pair.time).0,
        pair.server.incoming_buffer_bytes(),
        pair.server.known_cids(),
        pair.server.open_connections(),
        pair.server.poll_incoming_timeout().is_some(),
    );
    let expected = (
        live,
        live,
        buffered,
        reserved + registered,
        registered,
        live > 0,
    );
    if observed == expected {
        Ok(())
    } else {
        Err(format!(
            "after {step:?}: (pending, in progress, buffered, cids, open, deadline) is {observed:?}, \
             the model says {expected:?}"
        ))
    }
}

fn split_accepts_agree_with_the_model(steps: Vec<Step>) -> TestResult {
    let mut pair = pair();
    let mut flights: Vec<Inbound> = Vec::new();
    let mut attempts: Vec<Attempt> = Vec::new();
    let mut buf = Vec::new();
    for step in steps {
        match step {
            Step::Arrive => {
                let client = pair.begin_connect(client_config());
                pair.drive_client();
                let first = pair.server.inbound.front().unwrap().clone();
                // Only the attempt's first flight matters; the client stays quiet from here.
                pair.client.connections.remove(&client);
                pair.server.drive_incoming(first.at, pair.client.addr);
                let incoming = pair.server.waiting_incoming.pop().unwrap();
                attempts.push(Attempt {
                    flight: flights.len(),
                    held: Held::Waiting(Box::new(incoming)),
                    deadline: first.at + LIMIT,
                    live: true,
                    started: false,
                    buffered: 0,
                });
                flights.push(first);
            }
            Step::Start(pick) => {
                let now = pair.time;
                let Some(attempt) = nth(&mut attempts, pick, |h| matches!(h, Held::Waiting(_)))
                else {
                    continue;
                };
                let Held::Waiting(incoming) = mem::replace(&mut attempt.held, Held::Gone) else {
                    panic!("picked by its phase")
                };
                match pair
                    .server
                    .endpoint
                    .start_accept(*incoming, now, &mut buf, None)
                {
                    Ok(accepting) => {
                        if !attempt.live || now >= attempt.deadline {
                            return TestResult::error(format!("{step:?}: a retired attempt began"));
                        }
                        attempt.held = Held::Accepting(Box::new(accepting));
                        attempt.started = true;
                    }
                    Err(error) => {
                        if attempt.live && now < attempt.deadline {
                            return TestResult::error(format!("{step:?}: refused {error:?}"));
                        }
                        attempt.live = false;
                    }
                }
            }
            Step::Run(pick) => {
                let Some(attempt) = nth(&mut attempts, pick, |h| matches!(h, Held::Accepting(_)))
                else {
                    continue;
                };
                let Held::Accepting(accepting) = mem::replace(&mut attempt.held, Held::Gone) else {
                    panic!("picked by its phase")
                };
                attempt.held = Held::Accepted(Box::new(accepting.accept()));
            }
            Step::Finish(pick) | Step::Abandon(pick) => {
                let Some(attempt) = nth(&mut attempts, pick, |h| matches!(h, Held::Accepted(_)))
                else {
                    continue;
                };
                let Held::Accepted(accepted) = mem::replace(&mut attempt.held, Held::Gone) else {
                    panic!("picked by its phase")
                };
                if matches!(step, Step::Abandon(_)) {
                    pair.server.endpoint.abandon_accept(*accepted);
                } else {
                    match pair.server.endpoint.finish_accept(*accepted, &mut buf) {
                        Ok(_registered) => {
                            if !attempt.live {
                                return TestResult::error(format!(
                                    "{step:?}: a retired attempt was registered"
                                ));
                            }
                            attempt.held = Held::Registered;
                        }
                        Err(error) => {
                            if attempt.live || error.response.is_some() {
                                return TestResult::error(format!(
                                    "{step:?}: {:?} with a response {}",
                                    error.cause,
                                    error.response.is_some()
                                ));
                            }
                        }
                    }
                }
                attempt.live = false;
            }
            Step::Ignore(pick) => {
                let Some(attempt) = nth(&mut attempts, pick, |h| matches!(h, Held::Waiting(_)))
                else {
                    continue;
                };
                let Held::Waiting(incoming) = mem::replace(&mut attempt.held, Held::Gone) else {
                    panic!("picked by its phase")
                };
                pair.server.endpoint.ignore(*incoming);
                attempt.live = false;
            }
            Step::Retransmit(pick) => {
                if flights.is_empty() {
                    continue;
                }
                let flight = pick % flights.len();
                let mut copy = flights[flight].clone();
                copy.at = pair.time;
                let len = incoming_datagram_charge(copy.packet.len());
                pair.server.inbound.push_back(copy);
                pair.server.drive_incoming(pair.time, pair.client.addr);
                // The flight's newest attempt receives it while held or registered.
                let newest = attempts
                    .iter_mut()
                    .rev()
                    .find(|a| a.flight == flight)
                    .unwrap();
                if newest.live {
                    newest.buffered += len;
                } else if !matches!(newest.held, Held::Registered) {
                    let Some(incoming) = pair.server.waiting_incoming.pop() else {
                        return TestResult::error(format!("{step:?}: no new attempt"));
                    };
                    attempts.push(Attempt {
                        flight,
                        held: Held::Waiting(Box::new(incoming)),
                        deadline: pair.time + LIMIT,
                        live: true,
                        started: false,
                        buffered: 0,
                    });
                }
                if !pair.server.waiting_incoming.is_empty() {
                    return TestResult::error(format!("{step:?}: an unexpected attempt"));
                }
            }
            Step::Advance(quarters) => {
                pair.time += LIMIT * u32::from(quarters) / 4;
                pair.server.expire_incoming(pair.time, usize::MAX);
                for attempt in &mut attempts {
                    if attempt.deadline <= pair.time {
                        attempt.live = false;
                    }
                }
            }
            Step::DiscardAll => {
                pair.server.discard_all_incoming();
                for attempt in &mut attempts {
                    attempt.live = false;
                }
            }
        }
        pair.server.outbound.clear();
        if let Err(failure) = check(&pair, &attempts, step) {
            return TestResult::error(failure);
        }
    }
    // Settling every attempt the application still holds leaves only the connections.
    for attempt in &mut attempts {
        match mem::replace(&mut attempt.held, Held::Gone) {
            Held::Waiting(incoming) => pair.server.endpoint.ignore(*incoming),
            Held::Accepting(accepting) => {
                pair.server.endpoint.abandon_accept(accepting.accept());
            }
            Held::Accepted(accepted) => pair.server.endpoint.abandon_accept(*accepted),
            held => attempt.held = held,
        }
        attempt.live = false;
    }
    match check(&pair, &attempts, Step::DiscardAll) {
        Ok(()) => TestResult::passed(),
        Err(failure) => TestResult::error(format!("settling everything: {failure}")),
    }
}

#[test]
fn split_accepts_agree_with_the_reference_model() {
    QuickCheck::new()
        .tests(300)
        .rng(Gen::new(60))
        .quickcheck(split_accepts_agree_with_the_model as fn(Vec<Step>) -> TestResult);
}
