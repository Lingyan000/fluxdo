#![cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "an integration test's fixtures fail the test by panicking"
)]
//! The gates added to a connection see its streams and admit every byte they move.

mod runtime;

use std::{
    net::{Ipv4Addr, SocketAddr},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    task::{Context, Poll, Wake, Waker},
    time::Duration,
};

use parking_lot::Mutex;
use rama_core::{bytes::Bytes, futures::poll, rt::Executor};
use rama_net::gate::{
    DatagramGates, GateDirection, GatedStream, Initiator, StreamGate, StreamGates,
};
use rama_quic::{
    Connection, Endpoint, RecvStream, SendDatagramError, SendStream, StreamHandle, TransportConfig,
    WriteError,
};
use rama_quic_proto::VarInt;
use runtime::{Identities, connect};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    time::timeout,
};

const DEADLINE: Duration = Duration::from_secs(10);

fn localhost() -> SocketAddr {
    SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0)
}

/// A client connected to a server, and the server's side of that connection.
async fn pair(identities: &Identities) -> (Endpoint, Connection, Endpoint, Connection) {
    let server = Endpoint::build(Executor::new())
        .with_server_config(identities.server_config())
        .bind_address(localhost())
        .await
        .unwrap();
    let client = Endpoint::build(Executor::new())
        .bind_address(localhost())
        .await
        .unwrap();
    let addr = server.local_addr().unwrap();
    let (client_connection, server_connection) =
        tokio::join!(connect(&client, identities, addr), async {
            server.accept().await.unwrap().await.unwrap()
        });
    (client, client_connection, server, server_connection)
}

/// Remembers the streams it is asked about, gating none.
#[derive(Clone, Default)]
struct Recording(Arc<Mutex<Vec<GatedStream>>>);

impl StreamGates for Recording {
    type Gate = Counting;

    fn open(&self, stream: GatedStream) -> Option<Counting> {
        self.0.lock().push(stream);
        None
    }
}

/// Admits at most a KiB at a time and counts what moved, checking the gate contract.
struct Counting {
    admitted: u64,
    moved: Arc<AtomicU64>,
}

impl StreamGate for Counting {
    fn poll_admit(&mut self, _: &mut Context<'_>, want: u64) -> Poll<u64> {
        assert!(want > 0, "a gate is asked for at least one byte");
        assert_eq!(self.admitted, 0, "every admission is settled first");
        self.admitted = want.min(1024);
        Poll::Ready(self.admitted)
    }

    fn settle(&mut self, used: u64) {
        assert!(
            used <= self.admitted,
            "{used} moved of {} admitted",
            self.admitted
        );
        self.admitted = 0;
        self.moved.fetch_add(used, Ordering::Relaxed);
    }
}

/// Counts every byte read and written on the streams it gates.
#[derive(Clone, Default)]
struct Counters {
    read: Arc<AtomicU64>,
    written: Arc<AtomicU64>,
}

impl StreamGates for Counters {
    type Gate = Counting;

    fn open(&self, stream: GatedStream) -> Option<Counting> {
        let moved = match stream.direction {
            GateDirection::Read => self.read.clone(),
            GateDirection::Write => self.written.clone(),
        };
        Some(Counting { admitted: 0, moved })
    }
}

/// Holds the bidirectional streams it gates back until opened.
#[derive(Clone, Default)]
struct Valve(Arc<Mutex<(bool, Vec<Waker>)>>);

impl Valve {
    fn open(&self) {
        let mut state = self.0.lock();
        state.0 = true;
        for waker in state.1.drain(..) {
            waker.wake();
        }
    }
}

impl StreamGate for Valve {
    fn poll_admit(&mut self, cx: &mut Context<'_>, want: u64) -> Poll<u64> {
        let mut state = self.0.lock();
        if state.0 {
            return Poll::Ready(want);
        }
        state.1.push(cx.waker().clone());
        Poll::Pending
    }

    fn settle(&mut self, _: u64) {}
}

impl StreamGates for Valve {
    type Gate = Self;

    fn open(&self, stream: GatedStream) -> Option<Self> {
        stream.bidirectional.then(|| self.clone())
    }
}

fn close(endpoints: [&Endpoint; 2], connections: [&Connection; 2]) {
    for connection in connections {
        connection.close(VarInt::from(0u32), b"done");
    }
    for endpoint in endpoints {
        endpoint.close(VarInt::from(0u32), b"done");
    }
}

#[tokio::test]
async fn gates_are_told_which_stream_direction_they_pace() {
    let identities = Identities::new();
    let (client, client_connection, server, server_connection) = pair(&identities).await;
    let recording = Recording::default();
    server_connection.add_stream_gates(recording.clone());

    let (mut bi, _) = client_connection.open_bi().await.unwrap();
    bi.write_all(b"request").await.unwrap();
    let mut uni = client_connection.open_uni().await.unwrap();
    uni.write_all(b"control").await.unwrap();
    let (bi_id, uni_id) = (u64::from(bi.id()), u64::from(uni.id()));
    timeout(DEADLINE, server_connection.accept_bi())
        .await
        .unwrap()
        .unwrap();
    timeout(DEADLINE, server_connection.accept_uni())
        .await
        .unwrap()
        .unwrap();
    let pushed = server_connection.open_uni().await.unwrap();

    let seen: Vec<_> = recording
        .0
        .lock()
        .iter()
        .map(|stream| {
            (
                stream.id,
                stream.direction,
                stream.bidirectional,
                stream.initiator,
            )
        })
        .collect();
    assert_eq!(
        seen,
        [
            (bi_id, GateDirection::Write, true, Initiator::Peer),
            (bi_id, GateDirection::Read, true, Initiator::Peer),
            (uni_id, GateDirection::Read, false, Initiator::Peer),
            (
                u64::from(pushed.id()),
                GateDirection::Write,
                false,
                Initiator::Local
            ),
        ]
    );

    close([&client, &server], [&client_connection, &server_connection]);
}

/// Each way a stream is read, meeting its gates on its own path.
#[derive(Clone, Copy)]
enum Read {
    Unordered,
    Io,
    Chunks,
    Buf,
}

/// Each way a stream is written, meeting its gates on its own path.
#[derive(Clone, Copy)]
enum Write {
    Slice,
    Chunks,
    Io,
}

async fn read(mut stream: RecvStream, how: Read, limit: usize) -> Vec<u8> {
    match how {
        Read::Unordered => stream.read_to_end(limit).await.unwrap(),
        Read::Io => {
            let mut got = Vec::new();
            AsyncReadExt::read_to_end(&mut stream, &mut got)
                .await
                .unwrap();
            got
        }
        Read::Chunks => {
            let mut got = Vec::new();
            let mut bufs = vec![Bytes::new(); 4];
            while let Some(count) = stream.read_chunks(&mut bufs).await.unwrap() {
                for chunk in &bufs[..count] {
                    got.extend_from_slice(chunk);
                }
            }
            got
        }
        Read::Buf => {
            let mut got = Vec::new();
            let mut buf = [0; 1500];
            while let Some(count) = stream.read(&mut buf).await.unwrap() {
                got.extend_from_slice(&buf[..count]);
            }
            got
        }
    }
}

async fn write(mut stream: SendStream, how: Write, data: &[u8]) {
    match how {
        Write::Slice => stream.write_all(data).await.unwrap(),
        Write::Chunks => {
            let (first, second) = data.split_at(data.len() / 3);
            let mut chunks = [
                Bytes::copy_from_slice(first),
                Bytes::copy_from_slice(second),
            ];
            stream.write_all_chunks(&mut chunks).await.unwrap();
        }
        Write::Io => AsyncWriteExt::write_all(&mut stream, data).await.unwrap(),
    }
    stream.finish().unwrap();
}

#[tokio::test]
async fn gates_admit_every_byte_their_streams_move() {
    let identities = Identities::new();
    let (client, client_connection, server, server_connection) = pair(&identities).await;
    let counters = Counters::default();
    server_connection.add_stream_gates(counters.clone());
    let payload: Vec<u8> = (0..30_000u32).map(|n| n as u8).collect();
    let styles = [
        (Read::Unordered, Write::Slice),
        (Read::Io, Write::Chunks),
        (Read::Chunks, Write::Io),
        (Read::Buf, Write::Slice),
    ];

    for (read_how, write_how) in styles {
        let echo = async {
            let (send, recv) = server_connection.accept_bi().await.unwrap();
            let got = read(recv, read_how, payload.len()).await;
            write(send, write_how, &got).await;
        };
        let exchange = async {
            let (send, recv) = client_connection.open_bi().await.unwrap();
            write(send, Write::Slice, &payload).await;
            read(recv, Read::Unordered, payload.len()).await
        };
        let ((), back) = timeout(DEADLINE, async { tokio::join!(echo, exchange) })
            .await
            .unwrap();
        assert_eq!(back, payload);
    }
    let moved = (styles.len() * payload.len()) as u64;
    assert_eq!(counters.read.load(Ordering::Relaxed), moved);
    assert_eq!(counters.written.load(Ordering::Relaxed), moved);

    close([&client, &server], [&client_connection, &server_connection]);
}

#[tokio::test]
async fn a_closed_gate_holds_only_the_streams_it_gates() {
    let identities = Identities::new();
    let (client, client_connection, server, server_connection) = pair(&identities).await;
    let valve = Valve::default();
    server_connection.add_stream_gates(valve.clone());

    let (mut bi, _) = client_connection.open_bi().await.unwrap();
    bi.write_all(b"request").await.unwrap();
    bi.finish().unwrap();
    let mut uni = client_connection.open_uni().await.unwrap();
    uni.write_all(b"control").await.unwrap();
    uni.finish().unwrap();

    let (_, mut request) = server_connection.accept_bi().await.unwrap();
    let mut control = server_connection.accept_uni().await.unwrap();
    let control = timeout(DEADLINE, control.read_to_end(64)).await.unwrap();
    assert_eq!(control.unwrap(), b"control", "ungated streams flow");

    let reading = tokio::spawn(async move { request.read_to_end(64).await });
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(
        !reading.is_finished(),
        "a closed gate holds its stream back"
    );
    valve.open();
    let request = timeout(DEADLINE, reading).await.unwrap().unwrap();
    assert_eq!(request.unwrap(), b"request");

    close([&client, &server], [&client_connection, &server_connection]);
}

#[tokio::test]
async fn gates_apply_to_streams_opened_after_they_are_added() {
    let identities = Identities::new();
    let (client, client_connection, server, server_connection) = pair(&identities).await;

    let (mut early, _) = client_connection.open_bi().await.unwrap();
    early.write_all(b"early").await.unwrap();
    early.finish().unwrap();
    let (_, mut early) = server_connection.accept_bi().await.unwrap();
    server_connection.add_stream_gates(Valve::default());

    let early = timeout(DEADLINE, early.read_to_end(64)).await.unwrap();
    assert_eq!(
        early.unwrap(),
        b"early",
        "a stream accepted before stays ungated"
    );

    close([&client, &server], [&client_connection, &server_connection]);
}

/// What a server reads of a request whose client closed the connection after sending it.
///
/// Ungated, the server reads only once the connection is lost; `gated`, it reads from the
/// start but a closed gate holds the request back until after the loss.
async fn read_after_close(gated: bool) -> Result<Vec<u8>, String> {
    let identities = Identities::new();
    let (client, client_connection, server, server_connection) = pair(&identities).await;
    let valve = Valve::default();
    if gated {
        server_connection.add_stream_gates(valve.clone());
    }

    let (mut bi, _) = client_connection.open_bi().await.unwrap();
    bi.write_all(b"request").await.unwrap();
    bi.finish().unwrap();
    let (_, request) = server_connection.accept_bi().await.unwrap();
    let mut request = Some(request);
    let reading = gated.then(|| {
        let mut request = request.take().unwrap();
        tokio::spawn(async move { request.read_to_end(64).await })
    });
    // The whole request arrived before the connection is lost.
    timeout(DEADLINE, bi.stopped()).await.unwrap().unwrap();
    client_connection.close(VarInt::from(7u32), b"gone");
    timeout(DEADLINE, server_connection.closed()).await.unwrap();
    // The gated reader sees the loss while its gate is still closed.
    tokio::time::sleep(Duration::from_millis(50)).await;
    valve.open();
    let read = if let Some(reading) = reading {
        timeout(DEADLINE, reading).await.unwrap().unwrap()
    } else {
        let mut request = request.take().unwrap();
        timeout(DEADLINE, request.read_to_end(64)).await.unwrap()
    };

    close([&client, &server], [&client_connection, &server_connection]);
    read.map_err(|error| error.to_string())
}

#[tokio::test]
async fn a_lost_connection_ends_a_gated_stream_as_an_ungated_one() {
    let ungated = read_after_close(false).await;
    assert_eq!(ungated.as_deref(), Ok(b"request".as_slice()));
    assert_eq!(read_after_close(true).await, ungated);
}

/// Gates that call into their own connection from every gate call: any of them made under
/// the connection's lock would deadlock.
struct Probing(Connection);

struct Probe(Connection);

impl StreamGates for Probing {
    type Gate = Probe;

    fn open(&self, _: GatedStream) -> Option<Probe> {
        _ = self.0.rtt();
        Some(Probe(self.0.clone()))
    }
}

impl StreamGate for Probe {
    fn poll_admit(&mut self, _: &mut Context<'_>, want: u64) -> Poll<u64> {
        _ = self.0.rtt();
        Poll::Ready(want)
    }

    fn settle(&mut self, _: u64) {
        _ = self.0.rtt();
    }
}

impl Drop for Probe {
    fn drop(&mut self) {
        _ = self.0.rtt();
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn gates_are_never_called_under_the_connection_lock() {
    let identities = Identities::new();
    let (client, client_connection, server, server_connection) = pair(&identities).await;
    server_connection.add_stream_gates(Probing(server_connection.clone()));

    let server_side = server_connection.clone();
    let echo = tokio::spawn(async move {
        let (mut send, mut recv) = server_side.accept_bi().await.unwrap();
        let got = recv.read_to_end(1024).await.unwrap();
        send.write_all(&got).await.unwrap();
        send.finish().unwrap();
    });
    let client_side = client_connection.clone();
    let exchange = tokio::spawn(async move {
        let (mut send, mut recv) = client_side.open_bi().await.unwrap();
        send.write_all(b"probe").await.unwrap();
        send.finish().unwrap();
        recv.read_to_end(1024).await.unwrap()
    });
    timeout(DEADLINE, echo).await.unwrap().unwrap();
    let back = timeout(DEADLINE, exchange).await.unwrap().unwrap();
    assert_eq!(back, b"probe");

    close([&client, &server], [&client_connection, &server_connection]);
}

/// Counts the gates dropped.
#[derive(Clone, Default)]
struct Drops(Arc<AtomicU64>);

struct Dropped(Arc<AtomicU64>);

impl StreamGates for Drops {
    type Gate = Dropped;

    fn open(&self, _: GatedStream) -> Option<Dropped> {
        Some(Dropped(self.0.clone()))
    }
}

impl StreamGate for Dropped {
    fn poll_admit(&mut self, _: &mut Context<'_>, want: u64) -> Poll<u64> {
        Poll::Ready(want)
    }

    fn settle(&mut self, _: u64) {}
}

impl Drop for Dropped {
    fn drop(&mut self) {
        self.0.fetch_add(1, Ordering::Relaxed);
    }
}

#[tokio::test]
async fn gates_drop_with_their_stream_handles() {
    let identities = Identities::new();
    let (client, client_connection, server, server_connection) = pair(&identities).await;
    let drops = Drops::default();
    server_connection.add_stream_gates(drops.clone());

    let (mut bi, _) = client_connection.open_bi().await.unwrap();
    bi.write_all(b"request").await.unwrap();
    let (send, recv) = server_connection.accept_bi().await.unwrap();
    assert_eq!(drops.0.load(Ordering::Relaxed), 0);
    drop(recv);
    assert_eq!(drops.0.load(Ordering::Relaxed), 1);
    drop(send);
    assert_eq!(drops.0.load(Ordering::Relaxed), 2);

    close([&client, &server], [&client_connection, &server_connection]);
}

#[tokio::test]
async fn a_lost_connection_reaches_a_writer_waiting_on_a_gate() {
    let identities = Identities::new();
    let (client, client_connection, server, server_connection) = pair(&identities).await;
    server_connection.add_stream_gates(Valve::default());

    // Both ends keep their halves: a dropped receive half would stop the stream instead.
    let (mut bi, _response) = client_connection.open_bi().await.unwrap();
    bi.write_all(b"request").await.unwrap();
    let (mut send, _request) = server_connection.accept_bi().await.unwrap();
    let writing = tokio::spawn(async move { send.write_all(b"response").await });
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(!writing.is_finished(), "a closed gate holds the write back");
    client_connection.close(VarInt::from(7u32), b"gone");
    let written = timeout(DEADLINE, writing).await.unwrap().unwrap();
    assert!(
        matches!(written, Err(WriteError::ConnectionLost(_))),
        "{written:?}"
    );

    close([&client, &server], [&client_connection, &server_connection]);
}

/// Records every datagram it is asked about; refuses those `refuses` matches.
#[derive(Clone)]
struct Ledger {
    asked: Arc<Mutex<Vec<(GateDirection, usize)>>>,
    refuses: fn(usize) -> bool,
}

impl Ledger {
    /// Refuses one-byte datagrams only.
    fn refusing_one_byte() -> Self {
        Self::new(|len| len == 1)
    }

    /// Refuses every datagram.
    fn refusing_all() -> Self {
        Self::new(|_| true)
    }

    /// Admits every datagram.
    fn admitting() -> Self {
        Self::new(|_| false)
    }

    fn new(refuses: fn(usize) -> bool) -> Self {
        Self {
            asked: Arc::default(),
            refuses,
        }
    }

    fn asked(&self) -> Vec<(GateDirection, usize)> {
        self.asked.lock().clone()
    }
}

impl DatagramGates for Ledger {
    fn admit(&self, direction: GateDirection, len: usize) -> bool {
        self.asked.lock().push((direction, len));
        !(self.refuses)(len)
    }
}

/// Refuses every datagram.
struct RefuseAll;

impl DatagramGates for RefuseAll {
    fn admit(&self, _: GateDirection, _: usize) -> bool {
        false
    }
}

#[tokio::test]
async fn datagram_gates_drop_what_they_refuse_in_both_directions() {
    let identities = Identities::new();
    let (client, client_connection, server, server_connection) = pair(&identities).await;
    let ledger = Ledger::refusing_one_byte();
    server_connection.add_datagram_gates(ledger.clone());

    // Received: the one-byte datagram is dropped before the application sees it.
    client_connection
        .send_datagram(Bytes::from_static(b"x"))
        .unwrap();
    client_connection
        .send_datagram(Bytes::from_static(b"ok"))
        .unwrap();
    let got = timeout(DEADLINE, server_connection.read_datagram())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(got, b"ok"[..]);
    assert_eq!(server_connection.stats().gated_datagrams.received, 1);

    // Sent: every entry point drops a refused datagram and still reports it sent.
    let (send, _recv) = server_connection.open_bi().await.unwrap();
    let handle = send.handle();
    server_connection
        .send_datagram(Bytes::from_static(b"a"))
        .unwrap();
    server_connection
        .try_send_datagram(Bytes::from_static(b"b"))
        .unwrap();
    server_connection
        .send_datagram_wait(Bytes::from_static(b"c"))
        .await
        .unwrap();
    handle.send_datagram(Bytes::from_static(b"d")).unwrap();
    handle.try_send_datagram(Bytes::from_static(b"e")).unwrap();
    server_connection
        .send_datagram(Bytes::from_static(b"done"))
        .unwrap();
    let got = timeout(DEADLINE, client_connection.read_datagram())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(got, b"done"[..], "refused datagrams never left");
    assert_eq!(server_connection.stats().gated_datagrams.sent, 5);

    let asked = ledger.asked();
    let reads = asked
        .iter()
        .filter(|(direction, _)| *direction == GateDirection::Read)
        .count();
    let writes = asked.len() - reads;
    assert_eq!((reads, writes), (2, 6), "{asked:?}");

    close([&client, &server], [&client_connection, &server_connection]);
}

/// Every datagram send path: the connection's three and the two bound to `handle`'s stream.
async fn send_every_way(
    connection: &Connection,
    handle: &StreamHandle,
    data: &Bytes,
) -> [Result<(), SendDatagramError>; 5] {
    [
        connection.send_datagram(data.clone()),
        connection.try_send_datagram(data.clone()),
        connection.send_datagram_wait(data.clone()).await,
        handle.send_datagram(data.clone()),
        handle.try_send_datagram(data.clone()),
    ]
}

/// Every result is the `expected` error, and the refusing gate was never asked.
fn assert_errors_before_gates(
    results: &[Result<(), SendDatagramError>],
    expected: fn(&SendDatagramError) -> bool,
    ledger: &Ledger,
    connection: &Connection,
) {
    for (path, result) in results.iter().enumerate() {
        assert!(
            result.as_ref().err().is_some_and(expected),
            "send path {path}: {result:?}"
        );
    }
    assert!(ledger.asked().is_empty(), "{:?}", ledger.asked());
    assert_eq!(connection.stats().gated_datagrams.sent, 0);
}

#[tokio::test]
async fn refusing_gates_never_hide_a_send_error() {
    let identities = Identities::new();

    // Datagrams disabled here, so unsupported by this peer for the other end.
    let (client, client_connection, server, server_connection) = pair_with_server_transport(
        &identities,
        TransportConfig::default().maybe_with_datagram_receive_buffer_size(None),
    )
    .await;
    let data = Bytes::from_static(b"x");
    let server_ledger = Ledger::refusing_all();
    server_connection.add_datagram_gates(server_ledger.clone());
    let (send, _recv) = server_connection.open_bi().await.unwrap();
    let results = send_every_way(&server_connection, &send.handle(), &data).await;
    assert_errors_before_gates(
        &results,
        |error| matches!(error, SendDatagramError::Disabled),
        &server_ledger,
        &server_connection,
    );
    let client_ledger = Ledger::refusing_all();
    client_connection.add_datagram_gates(client_ledger.clone());
    let (send, _recv) = client_connection.open_bi().await.unwrap();
    let results = send_every_way(&client_connection, &send.handle(), &data).await;
    assert_errors_before_gates(
        &results,
        |error| matches!(error, SendDatagramError::UnsupportedByPeer),
        &client_ledger,
        &client_connection,
    );
    close([&client, &server], [&client_connection, &server_connection]);

    let (client, client_connection, server, server_connection) = pair(&identities).await;
    let ledger = Ledger::refusing_all();
    server_connection.add_datagram_gates(ledger.clone());
    let (mut send, _recv) = server_connection.open_bi().await.unwrap();
    let handle = send.handle();

    // Too large for the peer.
    let large = Bytes::from(vec![0; 100_000]);
    let results = send_every_way(&server_connection, &handle, &large).await;
    assert_errors_before_gates(
        &results,
        |error| matches!(error, SendDatagramError::TooLarge),
        &ledger,
        &server_connection,
    );

    // A finished stream refuses datagrams bound to it.
    send.finish().unwrap();
    for result in [
        handle.send_datagram(data.clone()),
        handle.try_send_datagram(data.clone()),
    ] {
        assert!(
            matches!(result, Err(SendDatagramError::StreamClosed)),
            "{result:?}"
        );
    }

    // A closed connection reports itself lost on every path.
    let (other, _recv) = server_connection.open_bi().await.unwrap();
    server_connection.close(VarInt::from(0u32), b"done");
    let results = send_every_way(&server_connection, &other.handle(), &data).await;
    assert_errors_before_gates(
        &results,
        |error| matches!(error, SendDatagramError::ConnectionLost(_)),
        &ledger,
        &server_connection,
    );

    close([&client, &server], [&client_connection, &server_connection]);
}

/// Touches its connection's lock from every datagram it is asked about.
struct DatagramProbing(Connection);

impl DatagramGates for DatagramProbing {
    fn admit(&self, _: GateDirection, _: usize) -> bool {
        _ = self.0.rtt();
        true
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn datagram_gates_are_never_called_under_the_connection_lock() {
    let identities = Identities::new();
    let (client, client_connection, server, server_connection) = pair(&identities).await;
    server_connection.add_datagram_gates(DatagramProbing(server_connection.clone()));

    timeout(DEADLINE, async {
        client_connection
            .send_datagram(Bytes::from_static(b"in"))
            .unwrap();
        assert_eq!(server_connection.read_datagram().await.unwrap(), b"in"[..]);
        let (send, _recv) = server_connection.open_bi().await.unwrap();
        server_connection
            .send_datagram(Bytes::from_static(b"1"))
            .unwrap();
        server_connection
            .try_send_datagram(Bytes::from_static(b"2"))
            .unwrap();
        server_connection
            .send_datagram_wait(Bytes::from_static(b"3"))
            .await
            .unwrap();
        send.handle()
            .send_datagram(Bytes::from_static(b"4"))
            .unwrap();
        send.handle()
            .try_send_datagram(Bytes::from_static(b"5"))
            .unwrap();
        for _ in 0..5 {
            client_connection.read_datagram().await.unwrap();
        }
    })
    .await
    .expect("no gate call deadlocked on the connection lock");

    close([&client, &server], [&client_connection, &server_connection]);
}

/// Counts its wakes.
#[derive(Default)]
struct WakeCount(AtomicU64);

impl Wake for WakeCount {
    fn wake(self: Arc<Self>) {
        self.0.fetch_add(1, Ordering::Relaxed);
    }

    fn wake_by_ref(self: &Arc<Self>) {
        self.0.fetch_add(1, Ordering::Relaxed);
    }
}

#[tokio::test]
async fn refused_datagrams_are_discarded_a_bounded_batch_per_poll() {
    let identities = Identities::new();
    let (client, client_connection, server, server_connection) = pair(&identities).await;
    server_connection.add_datagram_gates(RefuseAll);
    for _ in 0..100 {
        client_connection
            .send_datagram(Bytes::from_static(b"x"))
            .unwrap();
    }
    timeout(DEADLINE, async {
        while server_connection.stats().frame_rx.datagram < 100 {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();

    // One batch per poll, and the task is woken to continue: the queue is not left
    // waiting on a datagram that will never come.
    for batch in 1..=2 {
        let wakes = Arc::new(WakeCount::default());
        let waker = Waker::from(wakes.clone());
        let mut cx = Context::from_waker(&waker);
        let mut read = Box::pin(server_connection.read_datagram());
        assert!(read.as_mut().poll(&mut cx).is_pending());
        assert_eq!(
            server_connection.stats().gated_datagrams.received,
            32 * batch
        );
        assert_eq!(wakes.0.load(Ordering::Relaxed), 1, "batch {batch}");
        // Cancelled between batches: the next read resumes where this one stopped.
        drop(read);
    }

    close([&client, &server], [&client_connection, &server_connection]);
}

/// As [`pair`], the server's connection on `transport`.
async fn pair_with_server_transport(
    identities: &Identities,
    transport: TransportConfig,
) -> (Endpoint, Connection, Endpoint, Connection) {
    let mut config = identities.server_config();
    config.set_transport_config(Arc::new(transport));
    let server = Endpoint::build(Executor::new())
        .with_server_config(config)
        .bind_address(localhost())
        .await
        .unwrap();
    let client = Endpoint::build(Executor::new())
        .bind_address(localhost())
        .await
        .unwrap();
    let addr = server.local_addr().unwrap();
    let (client_connection, server_connection) =
        tokio::join!(connect(&client, identities, addr), async {
            server.accept().await.unwrap().await.unwrap()
        });
    (client, client_connection, server, server_connection)
}

#[tokio::test]
async fn a_waiting_datagram_send_asks_its_gates_once() {
    let identities = Identities::new();
    let (client, client_connection, server, server_connection) = pair_with_server_transport(
        &identities,
        TransportConfig::default().with_datagram_send_buffer_size(1024),
    )
    .await;
    let ledger = Ledger::admitting();
    server_connection.add_datagram_gates(ledger.clone());

    // Fill the send buffer without yielding, so nothing is transmitted in between.
    while server_connection
        .try_send_datagram(Bytes::from_static(&[1; 100]))
        .is_ok()
    {}
    let mut wait =
        std::pin::pin!(server_connection.send_datagram_wait(Bytes::from_static(&[2; 77])));
    assert!(poll!(wait.as_mut()).is_pending(), "the send waits for room");
    assert!(poll!(wait.as_mut()).is_pending());
    timeout(DEADLINE, wait).await.unwrap().unwrap();
    let asked = ledger
        .asked()
        .into_iter()
        .filter(|(_, len)| *len == 77)
        .count();
    assert_eq!(asked, 1, "the waiting send was charged once");

    close([&client, &server], [&client_connection, &server_connection]);
}
