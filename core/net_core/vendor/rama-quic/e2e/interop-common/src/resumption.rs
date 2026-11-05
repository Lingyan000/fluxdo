//! The shared resumption and 0-RTT cases: a session taken up again, and early data offered on
//! it, accepted or refused.
//!
//! Three facts are kept apart here, because a peer can give one without the others: whether the
//! client had a ticket to offer at all, whether the session was resumed, and whether early data
//! was accepted. Rama's own side reports the first and the third — `into_0rtt` succeeding is the
//! ticket, and the verdict it hands back is the acceptance — while the resumption itself is only
//! visible to the server, so it comes back through the peer's own report.
//!
//! Every payload is an echo of bytes the case names, so a payload sent twice after a refusal
//! carries no side effect the second time.

use crate::backend::VerifyBackend as _;
use std::assert_matches;
use std::{net::SocketAddr, sync::Arc};

#[cfg(not(feature = "boring"))]
use rama::tls::rustls::server::RustlsServerConfigExt;
use rama::{
    crypto::pki_types::CertificateDer,
    extensions::ExtensionsRef as _,
    quic::{
        ClientConfig, Connection, Endpoint, NegotiatedTlsParameters, ServerConfig, StoppedError,
    },
    tls::{client::TlsClientConfig, server::TlsServerConfig},
    utils::{collections::smallvec::smallvec, octets},
};
#[cfg(any(not(feature = "boring"), feature = "peer-rustls"))]
use {
    rustls::server::{ServerSessionMemoryCache, StoresServerSessions},
    std::sync::atomic::{AtomicUsize, Ordering},
};

use crate::{
    close::CloseObservation,
    identity::{ALPN, Identity, alpn},
    registry::{Case, CaseRun},
    scenario::{Chunk, Received, SERVER_NAME},
    support::{Deadline, Peer, localhost},
};

const READ_CAP: usize = octets::mib(1);

/// The close every second connection ends on, so an idle timeout cannot stand in for the
/// client having closed.
pub const CLOSE_CODE: u32 = 0;
pub const CLOSE_REASON: &[u8] = b"done";

/// What the peer's server does with the second attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    /// The session resumes and the early data is taken on the early keys.
    EarlyDataAccepted,
    /// The session resumes and the early data is refused, so the payload goes again once the
    /// handshake has finished.
    EarlyDataRefused,
    /// The session is not resumed, so there is no early data to accept either.
    NotResumed,
    /// The session resumes; this client never asked for early keys, so it offers none.
    ResumedWithoutEarlyData,
}

/// One resumption case: what the client offers, what the peer must do with it, and the
/// payloads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResumptionScenario {
    /// Whether the client asks for early keys and offers early data on the second attempt.
    pub offers_early_data: bool,
    pub verdict: Verdict,
    /// The exchange on the first connection, which is what earns the ticket.
    pub warm: Chunk,
    /// The early payload, sent again after a refusal.
    pub early: Chunk,
    /// The exchange that ends the second connection, so what the peer read is counted while
    /// the connection is still running.
    pub barrier: Chunk,
}

/// How one payload reaches the peer's server, so an adapter knows what to accept next.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Arrival {
    /// On a unidirectional stream, which the peer only reads.
    Uni,
    /// On a bidirectional stream, which the peer reads and answers with the same bytes.
    Bi,
}

/// One payload the peer's server must read on the second connection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Expected {
    pub chunk: Chunk,
    pub arrival: Arrival,
}

impl ResumptionScenario {
    /// The payloads the peer's server must read on the second connection, in order.
    ///
    /// A payload the peer refused arrives once, not twice: it was never delivered on the early
    /// keys, and the send that follows the refusal is the only one that reaches the
    /// application. Both refusals recover the same way — a refused session is not a reason to
    /// lose the payload — so what tells those two cases apart is the peer's report, not what
    /// arrived.
    #[must_use]
    pub fn expected(&self) -> Vec<Expected> {
        let barrier = Expected {
            chunk: self.barrier,
            arrival: Arrival::Bi,
        };
        if self.offers_early_data {
            vec![
                Expected {
                    chunk: self.early,
                    arrival: Arrival::Uni,
                },
                barrier,
            ]
        } else {
            vec![barrier]
        }
    }
}

/// Every resumption case each eligible peer runs. A peer whose server cannot produce one of
/// these outcomes reports it as unsupported rather than running a case that proves something
/// else.
#[must_use]
pub fn resumption_cases() -> Vec<Case<ResumptionScenario>> {
    let payloads = |seed: u8| {
        (
            Chunk {
                seed,
                len: octets::kib(1),
            },
            Chunk {
                seed: seed + 1,
                len: octets::kib(2),
            },
            Chunk {
                seed: seed + 2,
                len: 640,
            },
        )
    };
    [
        (
            "resumption-early-accepted",
            true,
            Verdict::EarlyDataAccepted,
            0xc1,
        ),
        (
            "resumption-early-refused",
            true,
            Verdict::EarlyDataRefused,
            0xc4,
        ),
        ("resumption-not-resumed", true, Verdict::NotResumed, 0xc7),
        (
            "resumption-without-early-data",
            false,
            Verdict::ResumedWithoutEarlyData,
            0xca,
        ),
    ]
    .into_iter()
    .map(|(name, offers_early_data, verdict, seed)| {
        let (warm, early, barrier) = payloads(seed);
        Case {
            name,
            scenario: ResumptionScenario {
                offers_early_data,
                verdict,
                warm,
                early,
                barrier,
            },
        }
    })
    .collect()
}

/// One fact a peer's server may or may not be able to report.
///
/// A peer that cannot report something is not the same as a peer reporting that it did not
/// happen, so the two are kept apart and a case whose peer cannot report one of them still
/// runs: what the client was told carries that half.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reported {
    Seen(bool),
    /// That implementation exposes no such observation, for the reason given.
    Unavailable(&'static str),
}

/// What was seen of the second attempt, from both sides.
#[derive(Debug, Clone)]
pub struct ResumptionObservation {
    /// Rama's own answer: whether its handshake took up a session. Read from the
    /// [`NegotiatedTlsParameters`] the connection publishes, so it is the TLS outcome and not a
    /// lookup.
    pub rama: Option<bool>,
    /// Whether the peer's implementation says the session was resumed, where it says so.
    pub resumed: Reported,
    /// Whether it says it accepted early data. The client is told this by the server itself
    /// through the handshake, and the shared client side asserts it; this is the peer's own
    /// corroboration where its API has one.
    pub early_data: Reported,
    /// What it read on the second connection, in the order it read it.
    pub received: Vec<Received>,
    /// How the peer saw Rama's client close the second connection, where it reports that.
    /// Only the role where Rama opens the connection has one; it is checked by
    /// [`Self::closed_as_the_client_did`] rather than by [`Self::check`], since what the
    /// other role sees is the peer's own close and the peer chooses that.
    pub closed: Option<CloseObservation>,
    /// Anything that implementation says for itself, kept for a failure message.
    pub detail: Option<String>,
}

impl ResumptionObservation {
    /// Check both sides against the case: Rama's own verdict, whichever verdicts the peer can
    /// report, and every payload the second connection carried in the order it was read.
    /// Returns the reasons for whatever the peer could not report, for an adapter to record.
    pub fn check(&self, what: &str, scenario: &ResumptionScenario) -> Vec<&'static str> {
        let (resumed, early_data) = match scenario.verdict {
            Verdict::EarlyDataAccepted => (true, true),
            Verdict::EarlyDataRefused | Verdict::ResumedWithoutEarlyData => (true, false),
            Verdict::NotResumed => (false, false),
        };
        assert_eq!(
            self.rama,
            Some(resumed),
            "{what}: whether rama's own handshake resumed ({:?})",
            self.detail
        );
        let mut withheld = Vec::new();
        for (field, seen, expected) in [
            ("resumed the session", self.resumed, resumed),
            ("accepted early data", self.early_data, early_data),
        ] {
            match seen {
                Reported::Seen(seen) => assert_eq!(
                    seen, expected,
                    "{what}: whether the peer {field} ({:?})",
                    self.detail
                ),
                Reported::Unavailable(reason) => withheld.push(reason),
            }
        }
        let expected = scenario.expected();
        assert_eq!(
            self.received.len(),
            expected.len(),
            "{what}: the second connection carried {} payloads, not {}",
            self.received.len(),
            expected.len()
        );
        for (i, (got, expected)) in self.received.iter().zip(expected).enumerate() {
            got.check(what, &format!("payload {i}"), expected.chunk);
        }
        withheld
    }

    /// How the peer saw Rama's client close: an application close with the code and reason it
    /// gave, so an idle timeout cannot stand in for the client having closed. Only the role
    /// where Rama opens the connection has one to report.
    ///
    /// # Panics
    /// If the peer reported no close, or not that one.
    pub fn closed_as_the_client_did(&self, what: &str) {
        self.closed
            .as_ref()
            .unwrap_or_else(|| panic!("{what}: the peer says how the connection ended"))
            .says(what, u64::from(CLOSE_CODE), CLOSE_REASON);
    }
}

/// A client configuration for a case: it asks for early keys only where the case offers early
/// data, and it is the one configuration both attempts use, so the ticket the first earns is
/// the one the second offers.
#[must_use]
pub fn rama_client_config_for(
    anchor: CertificateDer<'static>,
    scenario: &ResumptionScenario,
) -> ClientConfig {
    let tls = TlsClientConfig::new()
        .with_alpn(smallvec![alpn()])
        .try_with_server_trust_anchors([anchor])
        .expect("the trust anchor is accepted")
        .verify_backend();
    let options = crate::backend::options();
    let options = if scenario.offers_early_data {
        options.with_early_data(true)
    } else {
        options
    };
    crate::backend::tls_provider()
        .client_config(&tls, options)
        .expect("the client config is built")
}

/// The first connection: an exchange after the handshake, which is when the session ticket
/// follows. That it arrived is not asserted here; the second attempt resuming is what says so.
pub async fn rama_client_warms_up(
    run: &CaseRun<ResumptionScenario>,
    client: &Endpoint,
    config: ClientConfig,
    addr: SocketAddr,
) {
    let CaseRun { what, deadline, .. } = run;
    let connection = deadline
        .wait(
            what,
            client
                .connect_with(config, addr, SERVER_NAME)
                .expect("the attempt starts"),
        )
        .await
        .expect("the first handshake completes");
    exchange(what, *deadline, &connection, run.scenario.warm).await;
    connection.close(CLOSE_CODE, CLOSE_REASON);
    deadline.wait(what, connection.closed()).await;
}

/// The second attempt, and everything this side can see of it: whether there was a ticket to
/// offer, what the peer said about the early data, and — after a refusal — that the payload
/// goes again on the 1-RTT keys and is taken exactly once.
pub async fn rama_client_resumes(
    run: &CaseRun<ResumptionScenario>,
    client: &Endpoint,
    config: ClientConfig,
    addr: SocketAddr,
) -> Option<bool> {
    let CaseRun {
        what,
        deadline,
        scenario,
        ..
    } = run;
    let attempt = client
        .connect_with(config, addr, SERVER_NAME)
        .expect("the attempt starts");
    let connection = if scenario.offers_early_data {
        // The ticket witness: early keys to offer means the first connection left a session
        // behind. A case that expects no resumption may still have one to offer; what happens
        // to it is the peer's answer, below.
        let (connection, accepted) = attempt
            .into_0rtt()
            .unwrap_or_else(|_| panic!("{what}: the client had a ticket and early keys to offer"));
        let mut early = deadline
            .wait(what, connection.open_uni())
            .await
            .expect("an early stream opens");
        deadline
            .wait(what, early.write_all(&scenario.early.bytes()))
            .await
            .expect("the early payload is written");
        early.finish().expect("the early stream ends");
        let taken = deadline
            .wait(what, accepted)
            .await
            .expect("the handshake completes");
        assert_eq!(
            taken,
            scenario.verdict == Verdict::EarlyDataAccepted,
            "{what}: what the client was told about its early data"
        );
        if taken {
            // `Ok(None)` is the acknowledged end of the stream; `Ok(Some(_))` would be a
            // STOP_SENDING. The peer's own digest is the receipt, and it is checked there.
            assert_eq!(
                deadline
                    .wait(what, early.stopped())
                    .await
                    .expect("the early stream ended cleanly"),
                None,
                "{what}: the peer acknowledged the end of the early stream"
            );
        } else {
            // The stream opened before the handshake did not survive, and it says why: the
            // caller has to send again, and nothing does it for them.
            let refused = deadline
                .wait(what, early.stopped())
                .await
                .expect_err("a rejected early stream does not end cleanly");
            assert_matches!(
                refused,
                StoppedError::ZeroRttRejected,
                "{what}: the rejection is what ended it, not something else: {refused:?}",
            );
            // Whichever refusal it was, the payload the application handed over is still
            // owed to the peer and goes again on the keys that survived.
            send_again(what, *deadline, &connection, scenario.early).await;
        }
        connection
    } else {
        let attempt = attempt
            .into_0rtt()
            .err()
            .expect("default TLS options refuse early data even with a resumable ticket");
        deadline
            .wait(what, attempt)
            .await
            .expect("the second handshake completes")
    };
    // The barrier: an exchange the peer answers, so the peer counts what arrived while the
    // connection is still running rather than after it has gone.
    exchange(what, *deadline, &connection, scenario.barrier).await;
    let resumed = connection
        .extensions()
        .get_ref::<NegotiatedTlsParameters>()
        .cloned()
        .expect("the handshake settled something")
        .resumed;
    connection.close(CLOSE_CODE, CLOSE_REASON);
    deadline.wait(what, connection.closed()).await;
    resumed
}

/// The refused payload, sent again on the keys that survived.
///
/// What `stopped()` answers is a transport acknowledgment of the stream's end, not the peer's
/// application having read it. The receipt is the peer's own report of what it read, which the
/// case checks, and the barrier that follows.
async fn send_again(what: &str, deadline: Deadline, connection: &Connection, payload: Chunk) {
    let mut again = deadline
        .wait(what, connection.open_uni())
        .await
        .expect("a stream after the rejection opens");
    deadline
        .wait(what, again.write_all(&payload.bytes()))
        .await
        .expect("the payload is written again");
    again.finish().expect("the second attempt at it ends");
    assert_eq!(
        deadline
            .wait(what, again.stopped())
            .await
            .expect("the stream ended cleanly"),
        None,
        "{what}: the peer acknowledged the end of the payload rather than stopping it"
    );
}

/// One bidirectional exchange, checked by length and digest on the way back.
async fn exchange(what: &str, deadline: Deadline, connection: &Connection, payload: Chunk) {
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

/// A client endpoint for a resumption case.
pub async fn rama_client(run: &CaseRun<ResumptionScenario>) -> Endpoint {
    run.deadline
        .wait(
            &run.what,
            Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
        )
        .await
        .expect("the rama client binds")
}

/// The protocol both attempts negotiate, for a peer that names it itself.
pub const PROTOCOL: &[u8] = ALPN;

/// A rustls server's session store, wrapped so a case can say what rustls asked of it.
///
/// It is rustls's own store underneath; what is added is a count of the sessions kept and of
/// the lookups answered. These are diagnostics, not verdicts: rustls takes the bytes before it
/// parses the session, checks the binder and decides what the handshake is
/// (`rustls/src/server/tls13.rs`), so a lookup that found something is not a resumption. The
/// resumption is [`ResumptionObservation::rama`], read from the handshake itself.
#[derive(Debug)]
#[cfg(any(not(feature = "boring"), feature = "peer-rustls"))]
pub struct RecordingSessions {
    inner: Arc<dyn StoresServerSessions>,
    stored: AtomicUsize,
    taken: AtomicUsize,
    missed: AtomicUsize,
}

#[cfg(any(not(feature = "boring"), feature = "peer-rustls"))]
impl RecordingSessions {
    #[must_use]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: ServerSessionMemoryCache::new(8),
            stored: AtomicUsize::new(0),
            taken: AtomicUsize::new(0),
            missed: AtomicUsize::new(0),
        })
    }

    /// Whether anything was kept, which is what a second attempt has to offer.
    #[must_use]
    pub fn kept_a_session(&self) -> bool {
        self.stored.load(Ordering::SeqCst) > 0
    }

    #[must_use]
    pub fn detail(&self) -> String {
        format!(
            "sessions stored {}, taken {}, offers not found {}",
            self.stored.load(Ordering::SeqCst),
            self.taken.load(Ordering::SeqCst),
            self.missed.load(Ordering::SeqCst)
        )
    }

    /// Forget the offers counted so far, so a second attempt is judged on its own.
    pub fn forget_offers(&self) {
        self.taken.store(0, Ordering::SeqCst);
        self.missed.store(0, Ordering::SeqCst);
    }
}

#[cfg(any(not(feature = "boring"), feature = "peer-rustls"))]
impl StoresServerSessions for RecordingSessions {
    fn put(&self, key: Vec<u8>, value: Vec<u8>) -> bool {
        let stored = self.inner.put(key, value);
        if stored {
            self.stored.fetch_add(1, Ordering::SeqCst);
        }
        stored
    }

    fn get(&self, key: &[u8]) -> Option<Vec<u8>> {
        self.inner.get(key)
    }

    fn take(&self, key: &[u8]) -> Option<Vec<u8>> {
        let session = self.inner.take(key);
        if session.is_some() {
            self.taken.fetch_add(1, Ordering::SeqCst);
        } else {
            self.missed.fetch_add(1, Ordering::SeqCst);
        }
        session
    }

    fn can_cache(&self) -> bool {
        self.inner.can_cache()
    }
}

/// A Rama server that remembers sessions in a store the case can look at, and accepts early
/// data only where the case wants it accepted.
///
/// The store is installed through `with_modify_rustls_config`, the hook Rama already offers for
/// reaching the native configuration, so nothing here goes around the public surface.
#[must_use]
#[cfg(not(feature = "boring"))]
pub fn rama_resuming_server_config(
    identity: &Identity,
    sessions: Arc<RecordingSessions>,
    early_data: bool,
) -> ServerConfig {
    let tls = TlsServerConfig::new()
        .with_alpn(smallvec![alpn()])
        .with_server_auth(identity.clone())
        .with_modify_rustls_config(move |mut native| {
            native.session_storage = sessions.clone();
            crate::backend::verify_server(native)
        });
    crate::backend::server_tls_provider()
        .server_config(&tls, crate::backend::options().with_early_data(early_data))
        .expect("the server config is built")
}

/// Server configurations for the shared verdicts, retaining the backend's native ticket state.
pub struct RamaResumptionConfigs {
    warming: ServerConfig,
    identity: Identity,
    #[cfg(not(feature = "boring"))]
    sessions: Arc<RecordingSessions>,
}

impl RamaResumptionConfigs {
    pub fn new(identity: &Identity) -> Self {
        Self::new_with_early_data(identity, true)
    }

    pub fn new_with_early_data(identity: &Identity, early_data: bool) -> Self {
        #[cfg(not(feature = "boring"))]
        let sessions = RecordingSessions::new();
        #[cfg(not(feature = "boring"))]
        let warming = rama_resuming_server_config(identity, sessions.clone(), early_data);
        #[cfg(feature = "boring")]
        let warming = {
            let tls = TlsServerConfig::new()
                .with_alpn(smallvec![alpn()])
                .with_server_auth(identity.clone());
            let mut config = crate::backend::server_tls_provider()
                .server_config(&tls, crate::backend::options().with_early_data(early_data))
                .unwrap();
            config.set_transport_config(Arc::new(
                rama::quic::TransportConfig::default()
                    .with_receive_window(rama::quic::proto::VarInt::from(65536u32)),
            ));
            config
        };
        Self {
            warming,
            identity: identity.clone(),
            #[cfg(not(feature = "boring"))]
            sessions,
        }
    }

    pub fn warming(&self) -> ServerConfig {
        self.warming.clone()
    }

    pub fn after_warmup(&self, what: &str) {
        self.check_warmup(what);
        #[cfg(not(feature = "boring"))]
        self.sessions.forget_offers();
    }

    /// Validate warm-up without resetting counters when the peer already started resuming.
    pub fn check_warmup(&self, what: &str) {
        #[cfg(not(feature = "boring"))]
        {
            assert!(
                self.sessions.kept_a_session(),
                "{what}: no session stored: {}",
                self.sessions.detail()
            );
        }
        #[cfg(feature = "boring")]
        let _ = what; // Stateless ticket issuance is proved by the second handshake resuming.
    }

    pub fn resuming(&self, verdict: Verdict) -> (ServerConfig, impl Fn() -> String) {
        #[cfg(not(feature = "boring"))]
        {
            let sessions = if verdict == Verdict::NotResumed {
                RecordingSessions::new()
            } else {
                self.sessions.clone()
            };
            let config = rama_resuming_server_config(
                &self.identity,
                sessions.clone(),
                verdict != Verdict::EarlyDataRefused,
            );
            (config, move || sessions.detail())
        }
        #[cfg(feature = "boring")]
        {
            let mut config = if verdict == Verdict::NotResumed {
                Self::new(&self.identity).warming
            } else {
                self.warming.clone()
            };
            if verdict == Verdict::EarlyDataRefused {
                // Preserve ticket keys but change their bound transport context to reject 0-RTT.
                config.set_transport_config(Arc::new(
                    rama::quic::TransportConfig::default()
                        .with_receive_window(rama::quic::proto::VarInt::from(131072u32)),
                ));
            }
            (config, || {
                "native stateless tickets; verdict checked from the handshake".into()
            })
        }
    }
}

/// What Rama's server made of one connection: the payloads it read, and whether its own
/// handshake took up a session.
#[derive(Debug, Clone)]
pub struct ServerReport {
    pub received: Vec<Received>,
    pub resumed: Option<bool>,
}

/// A Rama server for one connection of a case: it reads the payloads that connection carries,
/// answers the bidirectional ones with the same bytes, and reports what it read.
///
/// After those payloads it keeps reading until the peer closes, and adds whatever else turns
/// up to the same list. What that catches is a payload the peer delivered twice: the peer
/// closes only once the barrier has come back to it, so a duplicate it had already sent is
/// read here. It is not a claim that every stream in flight arrives — a peer may drop what it
/// had buffered when the close goes out — so the count speaks for what was delivered, not for
/// what was sent.
pub async fn rama_server_reading(
    run: &CaseRun<ResumptionScenario>,
    config: ServerConfig,
    arrivals: Vec<Expected>,
) -> (Endpoint, SocketAddr, Peer<ServerReport>) {
    let CaseRun { what, deadline, .. } = run;
    let (what, deadline) = (what.clone(), *deadline);
    let server = deadline
        .wait(
            &what,
            Endpoint::bind_server(rama::rt::Executor::new(), config, localhost()),
        )
        .await
        .expect("the rama server binds");
    let addr = server.local_addr().expect("its address");
    let serving = Peer::spawn({
        let server = server.clone();
        async move {
            let attempt = deadline
                .wait(&what, server.accept())
                .await
                .expect("an attempt arrives");
            let connection = deadline
                .wait(&what, attempt)
                .await
                .expect("the handshake completes");
            let mut received = Vec::new();
            for expected in arrivals {
                received.push(read_one(&what, deadline, &connection, expected.arrival).await);
            }
            // Owned guards, so a scenario that ends early takes these with it rather than
            // leaving them running, and a read that fails inside one is raised by the join.
            let draining = [Arrival::Uni, Arrival::Bi].map(|arrival| {
                let (what, connection) = (what.clone(), connection.clone());
                Peer::spawn(async move {
                    let mut extra = Vec::new();
                    while let Some(more) = read_more(&what, deadline, &connection, arrival).await {
                        extra.push(more);
                    }
                    extra
                })
            });
            let resumed = connection
                .extensions()
                .get_ref::<NegotiatedTlsParameters>()
                .cloned()
                .expect("the handshake settled something")
                .resumed;
            deadline.wait(&what, connection.closed()).await;
            for draining in draining {
                received.extend(draining.join(&what, deadline).await);
            }
            ServerReport { received, resumed }
        }
    });
    (server, addr, serving)
}

/// Read one payload the way the case says it arrives, answering a bidirectional one with the
/// same bytes so the peer sees it taken.
async fn read_one(
    what: &str,
    deadline: Deadline,
    connection: &Connection,
    arrival: Arrival,
) -> Received {
    match arrival {
        Arrival::Uni => {
            let mut recv = deadline
                .wait(what, connection.accept_uni())
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
            Received::Bytes(got)
        }
    }
}

/// One more stream of that kind if the connection is still carrying any, and nothing once the
/// close has ended it.
async fn read_more(
    what: &str,
    deadline: Deadline,
    connection: &Connection,
    arrival: Arrival,
) -> Option<Received> {
    let mut recv = match arrival {
        Arrival::Uni => deadline.wait(what, connection.accept_uni()).await.ok()?,
        Arrival::Bi => deadline.wait(what, connection.accept_bi()).await.ok()?.1,
    };
    Some(Received::Bytes(
        deadline
            .wait(what, recv.read_to_end(READ_CAP))
            .await
            .expect("a stream that opened completes"),
    ))
}
