//! The shared key-update cases: an update asked for by one side or the other, and one asked
//! for by neither.
//!
//! Traffic crosses before and after the update, so a case says the connection still works
//! under the new keys rather than only that a counter moved.
//!
//! A connection can also update its keys without being asked: `key_phase_size` starts as a
//! random `10..1000` packets (`proto/connection/mod.rs`) and the packet builder updates the
//! keys once that many have gone out under them (`packet_builder.rs`); quinn's peer does the
//! same. After any update that size becomes the keys' confidentiality limit less a margin,
//! which no case here approaches. So a case that counts updates settles the phase first with
//! one deliberate update, and what it counts afterwards is only what it asked for.
//!
//! Where the peer asks, the request is made, an exchange is driven behind it so a request that
//! was taken can travel, and the count says whether it was; the asking stops at the first
//! update seen. A peer that cannot start an update while the settling one is in flight
//! (RFC 9001 §6.1) is simply asked again. Two facts are kept apart: Rama
//! counts the updates it makes and follows (`ConnectionStats::key_updates`), and the peer says
//! what key phase it is using, where its own API has one. A peer with no phase to report is
//! recorded as such.

use std::{net::SocketAddr, time::Duration};

use tokio::sync::oneshot;

use rama::{
    quic::{Connection, Endpoint},
    utils::octets,
};

use crate::{
    identity::{anchor_of, rama_client_config, rama_server_config},
    registry::{Case, CaseRun},
    resumption::Reported,
    scenario::{Chunk, Received, SERVER_NAME, answer, echo_one, exchange},
    support::{Deadline, Peer, localhost},
};

const READ_CAP: usize = octets::mib(1);

/// Which side asks for the update, if either does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Initiator {
    /// Rama asks, through `Connection::force_key_update`.
    Rama,
    /// The peer asks, through whatever its own API offers.
    Peer,
    /// Neither asks. The case is then the control: the same traffic, and nothing moves.
    Nobody,
}

/// One key-update case: who asks, and the traffic either side of the asking.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyScenario {
    pub initiator: Initiator,
    /// The exchange that carries the settling update's new phase to the peer, so that what
    /// each side reads afterwards is either side of the case's own update.
    pub settling: Chunk,
    /// The exchange before the update is asked for.
    pub before: Chunk,
    /// The exchange after it, which is what says the connection works under the new keys.
    pub after: Chunk,
}

impl KeyScenario {
    /// How many updates Rama should count. It counts the ones it makes and the ones it
    /// follows, so either side asking gives one.
    #[must_use]
    pub fn updates(&self) -> u64 {
        u64::from(self.initiator != Initiator::Nobody)
    }
}

/// Every key-update case each eligible peer runs.
#[must_use]
pub fn key_cases() -> Vec<Case<KeyScenario>> {
    [
        ("key-update-rama-asks", Initiator::Rama, 0xd1),
        ("key-update-peer-asks", Initiator::Peer, 0xd4),
        ("key-update-nobody-asks", Initiator::Nobody, 0xd7),
    ]
    .into_iter()
    .map(|(name, initiator, seed)| Case {
        name,
        scenario: KeyScenario {
            initiator,
            settling: Chunk {
                seed: seed + 2,
                len: 512,
            },
            before: Chunk {
                seed,
                len: octets::kib(4),
            },
            after: Chunk {
                seed: seed + 1,
                len: octets::kib(4) + 33,
            },
        },
    })
    .collect()
}

/// What the peer says about its own keys.
#[derive(Debug, Clone)]
pub struct KeyObservation {
    /// Whether the peer's key phase is the other one now, where its API reports a phase.
    pub phase_changed: Reported,
    /// What the peer said for itself, kept for a failure message.
    pub detail: Option<String>,
}

impl KeyObservation {
    /// Check the peer's report where there is one. Answers the reason it could not report,
    /// for an adapter to record.
    pub fn check(&self, what: &str, scenario: &KeyScenario) -> Option<&'static str> {
        match self.phase_changed {
            Reported::Seen(changed) => {
                assert_eq!(
                    changed,
                    scenario.initiator != Initiator::Nobody,
                    "{what}: whether the peer's key phase moved ({:?})",
                    self.detail
                );
                None
            }
            Reported::Unavailable(reason) => Some(reason),
        }
    }
}

/// Rama's client for a key case: it binds, connects, runs both exchanges around the update,
/// and closes.
///
/// `between` is called between the two exchanges, after Rama has asked for the update where
/// the case has Rama asking. It is where an adapter says whatever its own implementation needs
/// saying at that moment — asking for the update, where the case has the peer asking. That
/// must be the only moment the peer asks: an update it starts on its own clock can land before
/// the count below is read, and then the case is measuring from a baseline that already moved.
pub async fn rama_client_side<Between, Between_>(
    run: &CaseRun<KeyScenario>,
    addr: SocketAddr,
    between: Between,
) where
    Between: FnMut() -> Between_,
    Between_: Future<Output = ()>,
{
    let (client, connection) = rama_client_connects(run, addr).await;
    settle_before_measuring(run, &connection).await;
    rama_client_updates(run, &connection, between).await;
    connection.close(0u32, b"done");
    run.deadline.wait(&run.what, client.wait_idle()).await;
}

/// The connection a key case runs over, for an adapter that has something to do with its peer
/// before the exchanges start.
pub async fn rama_client_connects(
    run: &CaseRun<KeyScenario>,
    addr: SocketAddr,
) -> (Endpoint, Connection) {
    let CaseRun {
        what,
        deadline,
        identity,
        ..
    } = run;
    let client = deadline
        .wait(
            what,
            Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
        )
        .await
        .expect("the rama client binds");
    let connection = deadline
        .wait(
            what,
            client
                .connect_with(rama_client_config(anchor_of(identity)), addr, SERVER_NAME)
                .expect("the attempt starts"),
        )
        .await
        .expect("the handshake completes");
    (client, connection)
}

/// Both exchanges, the update between them, and Rama's own count either side of it.
pub async fn rama_client_updates<Between, Between_>(
    run: &CaseRun<KeyScenario>,
    connection: &Connection,
    mut between: Between,
) where
    Between: FnMut() -> Between_,
    Between_: Future<Output = ()>,
{
    let CaseRun {
        what,
        deadline,
        scenario,
        ..
    } = run;
    exchange(what, *deadline, connection, scenario.before).await;

    let before = connection.stats().key_updates;
    match scenario.initiator {
        Initiator::Rama => {
            ask_when_ready(what, *deadline, connection).await;
            between().await;
        }
        // The peer cannot say whether its own implementation took the request — quinn's
        // `force_key_update` answers nothing and ignores it while an update is in flight — so
        // the ask is made, traffic is driven so an update that was taken can travel, and the
        // count says whether it did. The asking stops at the first update seen, so a second
        // one is never invited.
        Initiator::Peer => {
            while connection.stats().key_updates == before {
                between().await;
                exchange(what, *deadline, connection, scenario.settling).await;
                if deadline.passed() {
                    break;
                }
            }
        }
        Initiator::Nobody => between().await,
    }
    exchange(what, *deadline, connection, scenario.after).await;
    settled(what, *deadline, connection, before, scenario).await;
}

/// Rama's server for a key case: it answers both exchanges, asks for the update between them
/// where the case has Rama asking, and reports its own count either side of it.
pub async fn rama_server_side(
    run: &CaseRun<KeyScenario>,
) -> (
    Endpoint,
    SocketAddr,
    Peer<()>,
    oneshot::Receiver<Connection>,
) {
    let CaseRun { what, deadline, .. } = run;
    let (what, deadline, scenario) = (what.clone(), *deadline, run.scenario);
    let server = deadline
        .wait(
            &what,
            Endpoint::bind_server(
                rama::rt::Executor::new(),
                rama_server_config(&run.identity),
                localhost(),
            ),
        )
        .await
        .expect("the rama server binds");
    let addr = server.local_addr().expect("its address");
    // The connection is handed to the caller as well: a peer that has to ask for an update
    // more than once needs to see whether the last try took, and its own implementation may
    // not say.
    let (accepted, is_accepted) = oneshot::channel();
    let serving = Peer::spawn({
        let server = server.clone();
        async move {
            let connection = deadline
                .wait(&what, server.accept())
                .await
                .expect("an attempt arrives")
                .await
                .expect("the handshake completes");
            accepted
                .send(connection.clone())
                .expect("the case is listening");
            // A phase that will not change on its own, before anything is counted.
            settle_the_keys_answering(&what, deadline, &connection, scenario.settling).await;
            // The baseline is taken before the answer goes out, so a peer that asks the
            // moment it hears back cannot have its update counted into it.
            let (mut send, mut recv) = deadline
                .wait(&what, connection.accept_bi())
                .await
                .expect("the stream arrives");
            let got = deadline
                .wait(&what, recv.read_to_end(READ_CAP))
                .await
                .expect("it completes");
            Received::Bytes(got.clone()).check(&what, "exchange", scenario.before);
            let before = connection.stats().key_updates;
            deadline
                .wait(&what, send.write_all(&got))
                .await
                .expect("the answer is written");
            send.finish().expect("the answer ends");
            if scenario.initiator == Initiator::Rama {
                ask_when_ready(&what, deadline, &connection).await;
            }
            // The peer may need more than one go at asking, and each try brings an exchange
            // of its own, so what arrives from here on is answered as it comes.
            answer_until_the_last(&what, deadline, &connection, &scenario).await;
            settled(&what, deadline, &connection, before, &scenario).await;
            deadline.wait(&what, connection.closed()).await;
        }
    });
    (server, addr, serving, is_accepted)
}

/// Settle the phase before a case measures anything.
///
/// An adapter that reads its peer's key phase calls this itself, so that what it reads
/// afterwards brackets the case's own update and not this one.
pub async fn settle_before_measuring(run: &CaseRun<KeyScenario>, connection: &Connection) {
    settle_the_keys(&run.what, run.deadline, connection, run.scenario.settling).await;
}

/// Put the connection in a key phase that will not change on its own.
///
/// A connection starts with a small random number of packets before this implementation
/// updates its keys by itself: `key_phase_size` is a random `10..1000`
/// (`proto/connection/mod.rs`) and the packet builder updates the keys once that many have
/// gone out under them (`packet_builder.rs`). quinn does the same, and its peer follows suit.
/// After any update the size becomes the keys' confidentiality limit less a margin, which no
/// case here comes near, so one update at the start is what makes "no update happened" a fact
/// instead of a hope. quiche and aioquic never start one themselves: quiche updates only on
/// verifying a peer's phase change (`lib.rs`) and aioquic only on `request_key_update`.
pub async fn settle_the_keys(
    what: &str,
    deadline: Deadline,
    connection: &Connection,
    carrying: Chunk,
) {
    ensure_updated_keys(what, deadline, connection).await;
    // Carried to the peer, so its own keys are in the new phase before the case reads
    // anything: an update it has not seen yet is not a settled phase.
    exchange(what, deadline, connection, carrying).await;
}

/// The same, from the side that answers rather than opens the carrying exchange.
pub async fn settle_the_keys_answering(
    what: &str,
    deadline: Deadline,
    connection: &Connection,
    carrying: Chunk,
) {
    ensure_updated_keys(what, deadline, connection).await;
    answer(what, deadline, connection, carrying).await;
}

// An earlier automatic or peer update already retired the initial short phase.
// Waiting for another update can deadlock until the carrying exchange sends
// an ACK-eliciting packet under the current keys.
async fn ensure_updated_keys(what: &str, deadline: Deadline, connection: &Connection) {
    deadline
        .wait(what, async {
            while connection.stats().key_updates == 0 && !connection.force_key_update() {
                tokio::time::sleep(READY_STEP).await;
            }
        })
        .await;
}

/// Wait until this side can start another update, which it cannot while the last one is still
/// in flight (RFC 9001 §6.1, and `force_key_update` answers `false` until then). The wait is a
/// readiness check on that answer, not a pause of a chosen length: it ends the moment the
/// update starts.
pub async fn ask_when_ready(what: &str, deadline: Deadline, connection: &Connection) {
    let asked = deadline
        .try_wait(async {
            while !connection.force_key_update() {
                tokio::time::sleep(READY_STEP).await;
            }
        })
        .await;
    assert!(
        asked.is_some(),
        "{what}: the connection was able to start an update"
    );
}

/// How often a readiness check looks again. It bounds nothing on its own; the case's deadline
/// does that.
const READY_STEP: Duration = Duration::from_millis(5);

/// What Rama's counter did, once it has had the chance to move: an update the peer asked for
/// is counted when its packets arrive, not when the asking did.
async fn settled(
    what: &str,
    deadline: Deadline,
    connection: &Connection,
    before: u64,
    scenario: &KeyScenario,
) {
    let expected = before + scenario.updates();
    if scenario.updates() > 0 {
        // Waited for without failing on the wait itself: an update that never arrives is
        // reported as the count it left behind, not as a case that ran out of time.
        deadline
            .try_wait(async {
                while connection.stats().key_updates < expected {
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
            })
            .await;
    }
    assert_eq!(
        connection.stats().key_updates,
        expected,
        "{what}: the updates rama counted, having asked for {}",
        scenario.updates()
    );
}

/// Answer whatever the peer sends, in the order it comes, until the case's last payload has
/// been answered. A peer that has to ask for an update more than once carries a probe
/// exchange for each try, and their number is not known in advance; every one of them must
/// still be a payload this case named.
async fn answer_until_the_last(
    what: &str,
    deadline: Deadline,
    connection: &Connection,
    scenario: &KeyScenario,
) {
    let after = scenario.after.bytes();
    loop {
        let got = echo_one(what, deadline, connection).await;
        if got == after {
            return;
        }
        assert!(
            got == scenario.settling.bytes() || got == scenario.before.bytes(),
            "{what}: every exchange carries one of this case's payloads"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::server_identity;
    use rama::{bytes::Bytes, rt::Executor};

    async fn warmup_after_peer_update(answering: bool) {
        let what = "warmup after peer key update";
        let deadline = Deadline::new();
        let identity = server_identity();
        let server =
            Endpoint::bind_server(Executor::new(), rama_server_config(&identity), localhost())
                .await
                .unwrap();
        let client = Endpoint::bind_client(Executor::new(), localhost())
            .await
            .unwrap();
        let connecting = client
            .connect_with(
                rama_client_config(anchor_of(&identity)),
                server.local_addr().unwrap(),
                SERVER_NAME,
            )
            .unwrap();
        let (connection, peer) = deadline
            .wait(what, async {
                tokio::join!(connecting, async { server.accept().await.unwrap().await })
            })
            .await;
        let (connection, peer) = (connection.unwrap(), peer.unwrap());
        deadline
            .wait(what, peer.handshake_confirmed())
            .await
            .unwrap();
        assert!(peer.stats().key_updates > 0 || peer.force_key_update());
        let probe = Bytes::from_static(b"early key update");
        peer.send_datagram(probe.clone()).unwrap();
        assert_eq!(
            deadline
                .wait(what, connection.read_datagram())
                .await
                .unwrap(),
            probe,
        );
        let before = connection.stats().key_updates;
        assert!(before > 0, "the peer's update arrived before warmup");
        let carrying = Chunk {
            seed: 0xe1,
            len: 512,
        };
        if answering {
            tokio::join!(
                settle_the_keys_answering(what, deadline, &connection, carrying),
                exchange(what, deadline, &peer, carrying),
            );
        } else {
            tokio::join!(
                settle_the_keys(what, deadline, &connection, carrying),
                answer(what, deadline, &peer, carrying),
            );
        }
        assert_eq!(
            connection.stats().key_updates,
            before,
            "warmup must use the existing update, not require a second one",
        );
        connection.close(0u32, b"done");
        deadline
            .wait(what, async {
                tokio::join!(client.wait_idle(), server.wait_idle())
            })
            .await;
    }

    #[tokio::test]
    async fn opening_warmup_accepts_an_early_peer_update() {
        warmup_after_peer_update(false).await;
    }

    #[tokio::test]
    async fn answering_warmup_accepts_an_early_peer_update() {
        warmup_after_peer_update(true).await;
    }
}
