//! Filling the outgoing datagram buffer against a peer that has stopped reading.
//!
//! Backpressure is local. A peer that stops reading its socket stops acknowledging, so the
//! transport cannot make progress and this side's outgoing buffer fills; that is what a
//! waiting send waits for. The buffer is small here so filling it is deliberate rather than a
//! matter of volume, and the wait is judged by the buffer having no room, not by how long a
//! future took to resolve.

use std::{future::Future, net::SocketAddr, sync::Arc, time::Duration};

use rama::{
    quic::{Connection, Endpoint, TransportConfig},
    utils::octets,
};

use crate::{
    identity::{anchor_of, rama_client_config, rama_server_config},
    registry::{Case, CaseRun},
    scenario::{Chunk, Received, SERVER_NAME, exchange},
    support::{Deadline, digest, localhost, payload},
};

/// A peer that can be made to stop reading its socket, and to start again.
///
/// Every pinned peer can be withheld and let go; what an adapter may not have is a way to do
/// it while Rama keeps sending. Pauses must be acknowledged after QUIC input stops,
/// for both peer roles.
pub trait Ears {
    /// Stop reading. Nothing is acknowledged from here on.
    fn deaf(&mut self) -> impl Future<Output = ()> + Send;
    /// Read again, so the transport drains.
    fn hear(&mut self) -> impl Future<Output = ()> + Send;
}

/// How long one send is given to prove it is waiting rather than slow. It is not a deadline
/// for the case: what makes the wait a wait is the buffer having no room for it, asserted
/// while the send is still pending.
const PENDING: Duration = Duration::from_millis(200);

/// A bound on the fill, so a buffer that never fills fails the case rather than running on.
const ATTEMPTS: usize = 4096;

/// What a backpressure case fills with, and what it carries afterwards.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BackpressureScenario {
    /// How much of Rama's outgoing datagram buffer this case allows.
    pub buffer: usize,
    /// The seed every filling datagram follows from. Each carries its own number as well, so
    /// the one that had to wait is identifiable among the ones that were taken.
    pub seed: u8,
    /// The exchange that must still complete once the peer is reading again.
    pub carried: Chunk,
}

/// Every backpressure case each peer with a pause of its own runs.
#[must_use]
pub fn backpressure_cases() -> Vec<Case<BackpressureScenario>> {
    vec![Case {
        name: "datagram-no-room",
        scenario: BackpressureScenario {
            buffer: octets::kib(8),
            seed: 0x76,
            carried: Chunk {
                seed: 0x79,
                len: octets::kib(4),
            },
        },
    }]
}

/// What Rama sent while the peer was deaf, and what the peer's reports are checked against.
#[derive(Debug, Clone)]
pub struct Sent {
    /// How many datagrams the buffer took before one had to wait.
    pub queued: usize,
    /// The payload whose send was cancelled. It must never reach the peer.
    pub cancelled: Vec<u8>,
    /// The payload sent once the peer was reading again. Its arrival is what says the peer
    /// is making progress; datagrams are unordered, so it says nothing about the rest.
    pub after: Vec<u8>,
}

impl Sent {
    /// Whether this report is the datagram sent once there was room again. Its arrival says
    /// the peer is making progress; it says nothing about the rest, which are unordered and
    /// may be lost. A case reads on until the peer stops reporting.
    #[must_use]
    pub fn resumed(&self, report: &Received) -> bool {
        report.digest() == digest(&self.after)
    }

    /// Every report the peer made, once it has stopped reporting.
    ///
    /// # Panics
    /// If the cancelled payload is among them, if the one sent once there was room is not, or
    /// if there are more of them than were ever sent.
    pub fn account_for(&self, what: &str, reports: &[Received]) {
        let cancelled = digest(&self.cancelled);
        assert!(
            !reports.iter().any(|report| report.digest() == cancelled),
            "{what}: the cancelled datagram was never enqueued"
        );
        assert!(
            reports.iter().any(|report| self.resumed(report)),
            "{what}: the datagram sent once there was room arrived"
        );
        assert!(
            reports.len() <= self.queued + 1,
            "{what}: the peer reported {} datagrams where {} were sent",
            reports.len(),
            self.queued + 1
        );
    }
}

/// A Rama endpoint that has filled, cancelled and carried on, and not yet closed.
#[derive(Debug)]
pub struct Filled {
    pub endpoint: Endpoint,
    pub connection: Connection,
    pub sent: Sent,
}

impl Filled {
    pub async fn close(self, what: &str, deadline: Deadline) {
        self.connection.close(0u32, b"done");
        deadline.wait(what, self.endpoint.wait_idle()).await;
    }
}

/// Rama as the client: fill the buffer against a peer that has stopped reading, cancel the
/// send that has no room, and show the connection is usable in both shapes afterwards.
pub async fn rama_client_fills_and_cancels<E: Ears>(
    run: &CaseRun<BackpressureScenario>,
    peer_addr: SocketAddr,
    ears: &mut E,
) -> Filled {
    let CaseRun {
        what,
        identity,
        deadline,
        scenario,
        ..
    } = run;
    let endpoint = deadline
        .wait(
            what,
            Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
        )
        .await
        .expect("the rama client binds");
    let transport = TransportConfig::default().with_datagram_send_buffer_size(scenario.buffer);
    let config = rama_client_config(anchor_of(identity)).with_transport_config(Arc::new(transport));
    let connection = deadline
        .wait(
            what,
            endpoint
                .connect_with(config, peer_addr, SERVER_NAME)
                .expect("the attempt starts"),
        )
        .await
        .expect("the handshake completes");
    fills_and_cancels(run, endpoint, connection, ears).await
}

/// Bind before starting the independent client, with the same send budget as the client case.
pub async fn bind_backpressure_server(run: &CaseRun<BackpressureScenario>) -> Endpoint {
    let transport = TransportConfig::default().with_datagram_send_buffer_size(run.scenario.buffer);
    let config = rama_server_config(&run.identity).with_transport_config(Arc::new(transport));
    run.deadline
        .wait(
            &run.what,
            Endpoint::bind_server(rama::rt::Executor::new(), config, localhost()),
        )
        .await
        .expect("the Rama server binds")
}

/// Fill and cancel on an accepted connection, then initiate the recovery stream from the server.
pub async fn rama_server_fills_and_cancels<E: Ears>(
    run: &CaseRun<BackpressureScenario>,
    endpoint: Endpoint,
    ears: &mut E,
) -> Filled {
    let incoming = run
        .deadline
        .wait(&run.what, endpoint.accept())
        .await
        .expect("the independent client arrives");
    let connection = run
        .deadline
        .wait(&run.what, incoming)
        .await
        .expect("the handshake completes");
    fills_and_cancels(run, endpoint, connection, ears).await
}

async fn fills_and_cancels<E: Ears>(
    run: &CaseRun<BackpressureScenario>,
    endpoint: Endpoint,
    connection: Connection,
    ears: &mut E,
) -> Filled {
    let CaseRun {
        what,
        deadline,
        scenario,
        ..
    } = run;
    let limit = connection
        .max_datagram_size()
        .expect("the peer offered the extension");

    ears.deaf().await;
    let (queued, cancelled) = fill(run, &connection, limit).await;
    assert!(
        connection.datagram_send_buffer_space() < cancelled.len(),
        "{what}: and there is still no room now the wait has been cancelled"
    );

    ears.hear().await;
    let after = numbered(what, scenario.seed, limit, queued + 1);
    deadline
        .wait(what, connection.send_datagram_wait(after.clone().into()))
        .await
        .expect("it is accepted once there is room");
    exchange(what, *deadline, &connection, scenario.carried).await;
    Filled {
        endpoint,
        connection,
        sent: Sent {
            queued,
            cancelled,
            after,
        },
    }
}

/// Send until one send has no room, and answer how many were taken and which payload waited.
/// Returning drops the pending send, which is the cancellation.
async fn fill(
    run: &CaseRun<BackpressureScenario>,
    connection: &Connection,
    limit: usize,
) -> (usize, Vec<u8>) {
    let CaseRun {
        what,
        deadline,
        scenario,
        ..
    } = run;
    let mut queued = 0usize;
    let cancelled = deadline
        .wait(what, async {
            loop {
                let bytes = numbered(what, scenario.seed, limit, queued);
                let mut sending = Box::pin(connection.send_datagram_wait(bytes.clone().into()));
                match tokio::time::timeout(PENDING, &mut sending).await {
                    Ok(Ok(())) => queued += 1,
                    Ok(Err(error)) => {
                        panic!("{what}: the connection failed while filling: {error}")
                    }
                    Err(_) => {
                        // Still pending, and the send is still alive here: the buffer having
                        // no room for this datagram is why.
                        assert!(
                            connection.datagram_send_buffer_space() < bytes.len(),
                            "{what}: the send is waiting for room, not for a wakeup"
                        );
                        return bytes;
                    }
                }
            }
        })
        .await;
    assert!(
        queued > 0,
        "{what}: the buffer took datagrams before it filled"
    );
    (queued, cancelled)
}

/// One filling payload, carrying its own number so the peer's reports can be told apart.
///
/// # Panics
/// If the buffer took more than the case allows for, which means it is not filling.
fn numbered(what: &str, seed: u8, len: usize, number: usize) -> Vec<u8> {
    assert!(
        number < ATTEMPTS,
        "{what}: the buffer took {number} datagrams without filling"
    );
    let mut bytes = payload(seed, len);
    bytes[0..2].copy_from_slice(&u16::try_from(number).expect("it fits").to_be_bytes());
    bytes
}

#[cfg(test)]
mod tests;
