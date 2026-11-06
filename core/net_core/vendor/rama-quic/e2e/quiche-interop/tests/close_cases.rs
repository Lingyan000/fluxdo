//! The shared close cases, run against quiche in both roles.
//!
//! quiche reports the other side's close through `peer_error`, which says whether it was an
//! application close and carries the code and the reason.
//!
//! The case that closes as its first act used to fail here: rama coalesced its Handshake and
//! 1-RTT closes into one datagram, and this peer, having discarded its Handshake keys, made
//! nothing of either packet. The closes go in separate datagrams now, and the case at the end
//! of this file records what arrives.

mod common;

use common::{
    Identity, Quiche, Read, quiche_client_config, quiche_server_config, rama_client_config,
};
use interop_common::{
    CloseObservation, Deadline, Received, Role,
    close::{close_cases, rama_client_closes, rama_server_side},
    for_each_case,
    scenario::SERVER_NAME,
    support::{Peer, localhost},
};
use parking_lot::Mutex;
use rama::{
    quic::{Endpoint, proto::VarInt},
    utils::octets,
};
use std::{
    io::{Result as IoResult, Write},
    sync::Arc,
    time::Duration,
};

const PEER: &str = "quiche";
const READ_CAP: usize = octets::mib(1);
const CLIENT_BI: u64 = 0;

/// Rama's client closes, and quiche says what it was told.
#[tokio::test]
async fn close_cases_rama_client() {
    for_each_case(PEER, Role::RamaClient, close_cases(), |run| async move {
        let served = Identity::generate(SERVER_NAME);
        let run = run.with_identity(served.auth.clone());
        let (addr, accepting) =
            Quiche::bind_server(quiche_server_config(&served), run.deadline).await;
        let (settled, is_settled) = tokio::sync::oneshot::channel();
        let observing = Peer::spawn({
            let run = run.clone();
            async move {
                let mut server = accepting.await;
                server
                    .drive_until(&run.what, run.deadline, |connection| {
                        connection.is_established()
                    })
                    .await;
                settled.send(()).expect("the case is listening");
                if let Some(first) = run.scenario.first {
                    let got = server.read_stream(CLIENT_BI, READ_CAP, run.deadline).await;
                    Received::Bytes(got.clone()).check(&run.what, "exchange", first);
                    server.write_stream(CLIENT_BI, &got, run.deadline).await;
                }
                server
                    .drive_until(&run.what, run.deadline, |connection| {
                        connection.peer_error().is_some() || connection.is_closed()
                    })
                    .await;
                let ended = server
                    .connection()
                    .peer_error()
                    .expect("the peer stated why it stopped")
                    .clone();
                CloseObservation {
                    code: ended.error_code,
                    reason: ended.reason.clone(),
                    application: ended.is_app,
                    // `peer_error` is the peer's, which `local_error` is not.
                    received: Some(true),
                }
            }
        });

        rama_client_closes(&run, addr, || async {
            run.deadline
                .wait(&run.what, is_settled)
                .await
                .expect("the peer settled its handshake");
        })
        .await;
        let observed = observing.join(&run.what, run.deadline).await;
        observed.check(&run.what, &run.scenario);
    })
    .await;
}

/// A quiche client closes, and Rama's server says what it was told.
#[tokio::test]
async fn close_cases_rama_server() {
    for_each_case(PEER, Role::RamaServer, close_cases(), |run| async move {
        let served = Identity::generate(SERVER_NAME);
        let run = run.with_identity(served.auth.clone());
        let (endpoint, addr, serving) = rama_server_side(&run).await;
        let mut client = Quiche::connect(
            addr,
            SERVER_NAME,
            quiche_client_config(&served),
            run.deadline,
        )
        .await;
        client
            .drive_until(&run.what, run.deadline, |connection| {
                connection.is_established()
            })
            .await;
        if let Some(first) = run.scenario.first {
            client
                .write_stream(CLIENT_BI, &first.bytes(), run.deadline)
                .await;
            let back = client.read_stream(CLIENT_BI, READ_CAP, run.deadline).await;
            Received::Bytes(back).check(&run.what, "exchange", first);
        }
        client
            .close_with(
                u64::from(run.scenario.code),
                run.scenario.reason,
                run.deadline,
            )
            .await;
        let observed = serving.join(&run.what, run.deadline).await;
        observed.check(&run.what, &run.scenario);
        run.deadline.wait(&run.what, endpoint.wait_idle()).await;
    })
    .await;
}

/// Rama's client closes as its first application act, this peer reads it, and nothing it
/// received after the close began carried a packet behind another one.
///
/// Both handshakes are settled first, so the close is not racing one. The closes of the
/// spaces arrive in separate datagrams, which is what this peer needs: coalesced behind a
/// Handshake packet whose keys it had discarded, it read neither.
#[tokio::test]
async fn an_immediate_close_reaches_this_peer_in_its_own_datagram() {
    let deadline = Deadline::new();
    // The peer's own watch is shorter than the case's, so it comes back with what it saw
    // instead of the case running out of time.
    let watching = Deadline::of(Duration::from_secs(3));
    let served = Identity::generate(SERVER_NAME);
    let (addr, accepting) = Quiche::bind_server(quiche_server_config(&served), deadline).await;
    let (settled, is_settled) = tokio::sync::oneshot::channel();
    // Said just before the close goes out, so the record shows which datagrams came after it.
    let (closing, is_closing) = tokio::sync::oneshot::channel::<()>();
    // The peer's own qlog, which says what it made of each packet. Kept in memory and read
    // by the case; quiche writes JSON-SEQ.
    let qlog = Shared::default();
    let observing = Peer::spawn({
        let qlog = qlog.clone();
        async move {
            let mut server = accepting.await;
            server.write_qlog(Box::new(qlog), "the immediate close");
            server
                .drive_until("the handshake", deadline, |connection| {
                    connection.is_established()
                })
                .await;
            let before = server.connection().stats().recv;
            // From here on, what each datagram carried is recorded as it arrives; the bytes go to
            // `recv` untouched.
            server.read_headers();
            settled.send(()).expect("the case is listening");
            // Driven under the case's own deadline, and given up on when the shorter watch has
            // passed, so what comes back is what this peer saw rather than a failure to wait.
            // The case says when it is about to close before this side reads anything more, so
            // every datagram recorded after the note arrived after the close was asked for. The
            // socket buffers them while this waits.
            if deadline.try_wait(is_closing).await.is_some() {
                server.note("rama closed here");
            }
            let stopped = server
                .drive_or_stop("the close", deadline, |connection| {
                    connection.peer_error().is_some() || connection.is_closed() || watching.passed()
                })
                .await;
            let stats = server.connection().stats();
            Seen {
                packets: stats.recv - before,
                told: server.connection().peer_error().map(|error| {
                    (
                        error.is_app,
                        error.error_code,
                        String::from_utf8_lossy(&error.reason).into_owned(),
                    )
                }),
                established: server.connection().is_established(),
                closed: server.connection().is_closed(),
                datagrams: server.headers().to_vec(),
                stopped: format!("{stopped:?}"),
            }
        }
    });

    let client = deadline
        .wait(
            "the rama client binds",
            Endpoint::bind_client(rama::rt::Executor::new(), localhost()),
        )
        .await
        .expect("it binds");
    let connection = deadline
        .wait(
            "the rama client connects",
            client
                .connect_with(rama_client_config(&served), addr, SERVER_NAME)
                .expect("the attempt starts"),
        )
        .await
        .expect("the handshake completes");
    deadline
        .wait("the peer settles its handshake", is_settled)
        .await
        .expect("it said so");
    let before = connection.stats().udp_tx.datagrams;
    closing.send(()).expect("the peer is listening");
    connection.close(VarInt::from(0x2au32), b"immediate");
    deadline.wait("rama's shutdown", client.wait_idle()).await;
    let sent = connection.stats().udp_tx.datagrams - before;
    let frames = connection.stats().frame_tx.connection_close;

    let seen = observing.join("the quiche peer", deadline).await;
    println!(
        "rama wrote {frames} close frame(s) in {sent} datagram(s); the peer took {} packet(s), \
         read {:?}, was told {:?}, established {}, closed {}, stopped {}",
        seen.packets, seen.datagrams, seen.told, seen.established, seen.closed, seen.stopped
    );
    // What the peer says it did with the packets it read, in its own words.
    for line in qlog.lines() {
        if line.contains("packet_dropped") || line.contains("packet_received") {
            println!("qlog: {line}");
        }
    }
    assert_eq!(
        seen.told,
        Some((true, 0x2a, "immediate".to_owned())),
        "the peer reads the close rama sent as its first application act"
    );
    // The shape that makes that possible: nothing this peer received after the close began
    // carries a packet behind another one. Which packet is the close is not read here — a
    // short header carries whatever frames it carries — so that is all this asserts.
    let mut after_the_note = false;
    for read in &seen.datagrams {
        match read {
            Read::Note(_) => after_the_note = true,
            Read::Datagram(packets) if after_the_note => assert_eq!(
                packets.len(),
                1,
                "each datagram carries one packet: {packets:?}"
            ),
            Read::Datagram(_) => {}
        }
    }
    assert!(after_the_note, "the record says where the close began");
}

/// A sink the peer writes its qlog into and the case reads afterwards.
#[derive(Clone, Default)]
struct Shared(Arc<Mutex<Vec<u8>>>);

impl Shared {
    fn lines(&self) -> Vec<String> {
        String::from_utf8_lossy(&self.0.lock())
            .lines()
            .map(str::to_owned)
            .collect()
    }
}

impl Write for Shared {
    fn write(&mut self, buf: &[u8]) -> IoResult<usize> {
        self.0.lock().extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> IoResult<()> {
        Ok(())
    }
}

/// What the peer's own state said after the close, rather than a line to read words out of.
#[derive(Debug)]
struct Seen {
    /// QUIC packets this peer took after the handshake, which is what its own counter counts.
    packets: usize,
    /// The application close it was told about: whether it was one, its code and its reason.
    told: Option<(bool, u64, String)>,
    established: bool,
    closed: bool,
    /// What was read after the close was asked for: the datagrams and their packets, and
    /// the note that says where the close began.
    datagrams: Vec<Read>,
    /// Why the driver stopped, in its own words.
    stopped: String,
}
