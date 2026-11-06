#![cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "an integration test's fixtures fail the test by panicking"
)]
//! Throttling a connection paces the data of all its streams against one budget per direction.

mod runtime;

use std::{
    convert::Infallible,
    net::{Ipv4Addr, SocketAddr},
    time::{Duration, Instant},
};

use rama_core::{
    Layer, Service,
    bytes::Bytes,
    rt::Executor,
    service::{BoxService, service_fn},
};
use rama_net::stream::layer::{ThrottleConfig, ThrottleLayer, ThrottleMode, Throttleable as _};
use rama_quic::{Connection, Endpoint, ReadError, RecvStream, WriteError};
use rama_quic_proto::VarInt;
use rama_utils::rate::{Rate, RateLimiter};
use runtime::{Identities, connect};
use tokio::{io::AsyncReadExt, sync::mpsc, task::JoinHandle, time::timeout};

const DEADLINE: Duration = Duration::from_secs(10);
/// Bytes per second.
const RATE: u64 = 64 * 1024;
const BURST: u64 = 16 * 1024;
/// Two streams carry 64 KiB: past the burst, 48 KiB at 64 KiB/s take 750 ms.
const PER_STREAM: usize = 32 * 1024;
/// Short of the 750 ms one budget allows, yet over the 250 ms a budget per stream would take.
const PACED: Duration = Duration::from_millis(650);

fn per_conn() -> ThrottleMode {
    ThrottleMode::per_conn_with_burst(Rate::per_sec(RATE), BURST)
}

/// Past its 1 KiB burst, a stream waits about ten seconds for its next KiB.
fn starved() -> ThrottleLayer {
    ThrottleLayer::symmetric(ThrottleMode::per_conn_with_burst(Rate::per_sec(100), 1024))
        .with_quantum(1024)
}

fn localhost() -> SocketAddr {
    SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0)
}

async fn server(identities: &Identities) -> Endpoint {
    Endpoint::build(Executor::new())
        .with_server_config(identities.server_config())
        .bind_address(localhost())
        .await
        .expect("the server binds")
}

async fn client() -> Endpoint {
    Endpoint::build(Executor::new())
        .bind_address(localhost())
        .await
        .expect("the client binds")
}

fn serve<S>(server: &Endpoint, service: S) -> JoinHandle<()>
where
    S: Service<Connection> + Clone,
{
    tokio::spawn(server.clone().serve(Executor::new(), service))
}

/// How a stream is written: each way meets the throttle on its own path.
#[derive(Clone, Copy)]
enum Write {
    Slice,
    Chunks,
}

/// How a stream is read: each way meets the throttle on its own path.
#[derive(Clone, Copy)]
enum Read {
    Unordered,
    Io,
    Chunks,
}

async fn send(connection: &Connection, how: Write) {
    let mut stream = connection.open_uni().await.expect("a uni stream");
    match how {
        Write::Slice => stream.write_all(&[7; PER_STREAM]).await,
        Write::Chunks => {
            let half = Bytes::from_static(&[7; PER_STREAM / 2]);
            stream.write_all_chunks(&mut [half.clone(), half]).await
        }
    }
    .expect("it is written");
    stream.finish().expect("the stream ends");
}

async fn receive(connection: &Connection, how: Read) {
    let stream = connection.accept_uni().await.expect("the stream arrives");
    assert_eq!(read_all(stream, how).await, PER_STREAM);
}

async fn read_all(mut stream: RecvStream, how: Read) -> usize {
    match how {
        Read::Unordered => stream
            .read_to_end(PER_STREAM)
            .await
            .expect("it completes")
            .len(),
        Read::Io => {
            let mut got = Vec::new();
            AsyncReadExt::read_to_end(&mut stream, &mut got)
                .await
                .expect("it completes");
            got.len()
        }
        Read::Chunks => {
            let mut bufs = vec![Bytes::new(); 4];
            let mut total = 0;
            while let Some(count) = stream.read_chunks(&mut bufs).await.expect("it reads") {
                total += bufs[..count].iter().map(Bytes::len).sum::<usize>();
            }
            total
        }
    }
}

/// Send two streams at once, each written its own way, and wait for the peer to close.
async fn send_two(connection: Connection) -> Result<(), Infallible> {
    tokio::join!(
        send(&connection, Write::Slice),
        send(&connection, Write::Chunks)
    );
    _ = connection.closed().await;
    Ok(())
}

/// How long a client takes to receive the two streams a server sends with `service`.
async fn download<S>(service: S) -> Duration
where
    S: Service<Connection> + Clone,
{
    let identities = Identities::new();
    let server = server(&identities).await;
    let addr = server.local_addr().unwrap();
    let served = serve(&server, service);

    let client = client().await;
    let connection = connect(&client, &identities, addr).await;
    let start = Instant::now();
    timeout(DEADLINE, async {
        tokio::join!(
            receive(&connection, Read::Unordered),
            receive(&connection, Read::Unordered)
        )
    })
    .await
    .expect("both streams arrive");
    let elapsed = start.elapsed();

    connection.close(VarInt::from(0u32), b"done");
    server.close(VarInt::from(0u32), b"done");
    timeout(DEADLINE, served).await.unwrap().unwrap();
    elapsed
}

/// How long a server takes to read the two streams a client sends, throttled by `layer`.
async fn upload<L>(layer: L, reads: [Read; 2]) -> Duration
where
    L: Layer<BoxService<Connection, (), Infallible>, Service: Service<Connection> + Clone>,
{
    let identities = Identities::new();
    let server = server(&identities).await;
    let addr = server.local_addr().unwrap();
    let (tx, mut rx) = mpsc::unbounded_channel();
    let service = service_fn(move |connection: Connection| {
        let tx = tx.clone();
        async move {
            let start = Instant::now();
            tokio::join!(
                receive(&connection, reads[0]),
                receive(&connection, reads[1])
            );
            tx.send(start.elapsed()).unwrap();
            _ = connection.closed().await;
            Ok::<_, Infallible>(())
        }
    })
    .boxed();
    let served = serve(&server, layer.into_layer(service));

    let client = client().await;
    let connection = connect(&client, &identities, addr).await;
    tokio::join!(
        send(&connection, Write::Slice),
        send(&connection, Write::Slice)
    );
    let elapsed = timeout(DEADLINE, rx.recv()).await.unwrap().unwrap();

    connection.close(VarInt::from(0u32), b"done");
    server.close(VarInt::from(0u32), b"done");
    timeout(DEADLINE, served).await.unwrap().unwrap();
    elapsed
}

#[tokio::test]
async fn a_throttled_connection_writes_all_its_streams_from_one_budget() {
    let service = ThrottleLayer::write_only(per_conn()).into_layer(service_fn(send_two));
    let elapsed = download(service).await;
    assert!(elapsed >= PACED, "two streams arrived in {elapsed:?}");
}

#[tokio::test]
async fn an_unthrottled_connection_is_not_paced() {
    let elapsed = download(service_fn(send_two)).await;
    assert!(elapsed < PACED, "two streams arrived in {elapsed:?}");
}

#[tokio::test]
async fn a_throttled_connection_reads_all_its_streams_from_one_budget() {
    let layer = ThrottleLayer::read_only(per_conn());
    let elapsed = upload(layer, [Read::Io, Read::Chunks]).await;
    assert!(elapsed >= PACED, "two streams were read in {elapsed:?}");
}

/// Like nested throttles of a byte stream, every throttle added to a connection applies.
#[tokio::test]
async fn stacked_throttles_all_apply() {
    let fast = ThrottleMode::per_conn_with_burst(Rate::per_sec(4 * RATE), BURST);
    let layers = (
        ThrottleLayer::read_only(per_conn()),
        ThrottleLayer::read_only(fast),
    );
    let elapsed = upload(layers, [Read::Unordered, Read::Unordered]).await;
    assert!(elapsed >= PACED, "two streams were read in {elapsed:?}");
}

#[tokio::test]
async fn a_shared_throttle_spans_connections() {
    let identities = Identities::new();
    let server = server(&identities).await;
    let addr = server.local_addr().unwrap();
    let limiter = RateLimiter::new(Rate::per_sec(RATE), BURST);
    let service = ThrottleLayer::write_only(ThrottleMode::shared(limiter)).into_layer(service_fn(
        async |connection: Connection| {
            send(&connection, Write::Slice).await;
            _ = connection.closed().await;
            Ok::<_, Infallible>(())
        },
    ));
    let served = serve(&server, service);

    let client = client().await;
    // Started before connecting: the first connection may send while the second connects.
    let start = Instant::now();
    let (first, second) = tokio::join!(
        connect(&client, &identities, addr),
        connect(&client, &identities, addr)
    );
    timeout(DEADLINE, async {
        tokio::join!(
            receive(&first, Read::Unordered),
            receive(&second, Read::Unordered)
        )
    })
    .await
    .expect("both streams arrive");
    let elapsed = start.elapsed();
    assert!(elapsed >= PACED, "two connections received in {elapsed:?}");

    for connection in [first, second] {
        connection.close(VarInt::from(0u32), b"done");
    }
    server.close(VarInt::from(0u32), b"done");
    timeout(DEADLINE, served).await.unwrap().unwrap();
}

/// Within this, a stream's end reached a task that waits for budget (about ten seconds).
const PROMPTLY: Duration = Duration::from_secs(3);

#[tokio::test]
async fn a_reset_reaches_a_reader_waiting_for_budget() {
    let identities = Identities::new();
    let server = server(&identities).await;
    let addr = server.local_addr().unwrap();
    let (tx, mut rx) = mpsc::unbounded_channel();
    let service = starved().into_layer(service_fn(move |connection: Connection| {
        let tx = tx.clone();
        async move {
            let mut stream = connection.accept_uni().await.expect("the stream arrives");
            let mut buf = [0; 4096];
            let error = loop {
                match stream.read(&mut buf).await {
                    Ok(Some(_)) => {}
                    Ok(None) => panic!("the stream is reset, not finished"),
                    Err(error) => break error,
                }
            };
            tx.send(error).unwrap();
            _ = connection.closed().await;
            Ok::<_, Infallible>(())
        }
    }));
    let served = serve(&server, service);

    let client = client().await;
    let connection = connect(&client, &identities, addr).await;
    let mut stream = connection.open_uni().await.expect("a uni stream");
    stream.write_all(&[7; 8192]).await.expect("it is written");
    // Past its burst, the reader now waits for budget.
    tokio::time::sleep(Duration::from_millis(300)).await;
    stream.reset(VarInt::from(7u32)).expect("the stream resets");
    let error = timeout(PROMPTLY, rx.recv())
        .await
        .expect("the reset arrives without waiting for budget")
        .unwrap();
    assert!(
        matches!(error, ReadError::Reset(code) if code == VarInt::from(7u32)),
        "{error:?}"
    );

    connection.close(VarInt::from(0u32), b"done");
    server.close(VarInt::from(0u32), b"done");
    timeout(DEADLINE, served).await.unwrap().unwrap();
}

#[tokio::test]
async fn a_stop_reaches_a_writer_waiting_for_budget() {
    let identities = Identities::new();
    let server = server(&identities).await;
    let addr = server.local_addr().unwrap();
    let (tx, mut rx) = mpsc::unbounded_channel();
    let service = starved().into_layer(service_fn(move |connection: Connection| {
        let tx = tx.clone();
        async move {
            let mut stream = connection.open_uni().await.expect("a uni stream");
            let error = stream
                .write_all(&[7; 8192])
                .await
                .expect_err("the peer stops the stream");
            tx.send(error).unwrap();
            _ = connection.closed().await;
            Ok::<_, Infallible>(())
        }
    }));
    let served = serve(&server, service);

    let client = client().await;
    let connection = connect(&client, &identities, addr).await;
    let mut stream = connection.accept_uni().await.expect("the stream arrives");
    // Past its burst, the writer now waits for budget.
    tokio::time::sleep(Duration::from_millis(300)).await;
    stream.stop(VarInt::from(9u32)).expect("the stream stops");
    let error = timeout(PROMPTLY, rx.recv())
        .await
        .expect("the stop arrives without waiting for budget")
        .unwrap();
    assert!(
        matches!(error, WriteError::Stopped(code) if code == VarInt::from(9u32)),
        "{error:?}"
    );

    connection.close(VarInt::from(0u32), b"done");
    server.close(VarInt::from(0u32), b"done");
    timeout(DEADLINE, served).await.unwrap().unwrap();
}

/// A client connection and the server's side of it, the server's side throttled by `config`.
async fn throttled_pair(
    identities: &Identities,
    config: &ThrottleConfig,
) -> (Endpoint, Connection, Endpoint, Connection) {
    let server = server(identities).await;
    let client = client().await;
    let addr = server.local_addr().unwrap();
    let (client_connection, server_connection) =
        tokio::join!(connect(&client, identities, addr), async {
            server.accept().await.unwrap().await.unwrap()
        });
    let server_connection = server_connection.throttle(config);
    (client, client_connection, server, server_connection)
}

/// A KiB burst that barely refills: a byte per second.
fn kib_burst() -> ThrottleMode {
    ThrottleMode::per_conn_with_burst(Rate::per_sec(1), 1024)
}

fn close_pair(endpoints: [&Endpoint; 2], connections: [&Connection; 2]) {
    for connection in connections {
        connection.close(VarInt::from(0u32), b"done");
    }
    for endpoint in endpoints {
        endpoint.close(VarInt::from(0u32), b"done");
    }
}

#[tokio::test]
async fn datagrams_spend_the_budget_their_connections_streams_wait_for() {
    let identities = Identities::new();
    let config = ThrottleConfig::new(None, Some(kib_burst())).with_quantum(1024);
    let (client, client_connection, server, server_connection) =
        throttled_pair(&identities, &config).await;

    for _ in 0..10 {
        server_connection
            .send_datagram(Bytes::from_static(&[1; 100]))
            .unwrap();
    }
    assert_eq!(server_connection.stats().gated_datagrams.sent, 0);
    for _ in 0..10 {
        timeout(DEADLINE, client_connection.read_datagram())
            .await
            .unwrap()
            .unwrap();
    }
    // The datagrams left 24 bytes: a stream waits seconds for its KiB.
    let mut stream = server_connection.open_uni().await.unwrap();
    let write = timeout(Duration::from_millis(300), stream.write_all(&[2; 1024])).await;
    assert!(write.is_err(), "the stream did not wait for budget");

    close_pair([&client, &server], [&client_connection, &server_connection]);
}

#[tokio::test]
async fn streams_spend_the_budget_their_connections_datagrams_need() {
    let identities = Identities::new();
    let config = ThrottleConfig::new(None, Some(kib_burst())).with_quantum(1024);
    let (client, client_connection, server, server_connection) =
        throttled_pair(&identities, &config).await;

    let mut stream = server_connection.open_uni().await.unwrap();
    timeout(DEADLINE, stream.write_all(&[2; 1024]))
        .await
        .unwrap()
        .unwrap();
    server_connection
        .send_datagram(Bytes::from_static(&[1; 100]))
        .unwrap();
    assert_eq!(server_connection.stats().gated_datagrams.sent, 1);

    close_pair([&client, &server], [&client_connection, &server_connection]);
}

#[tokio::test]
async fn a_throttled_connection_drops_received_datagrams_beyond_its_budget() {
    let identities = Identities::new();
    let config = ThrottleConfig::new(Some(kib_burst()), None);
    let (client, client_connection, server, server_connection) =
        throttled_pair(&identities, &config).await;

    for _ in 0..20 {
        client_connection
            .send_datagram(Bytes::from_static(&[1; 100]))
            .unwrap();
    }
    let mut delivered = 0;
    while let Ok(Ok(_)) = timeout(
        Duration::from_millis(300),
        server_connection.read_datagram(),
    )
    .await
    {
        delivered += 1;
    }
    let refused = server_connection.stats().gated_datagrams.received;
    assert_eq!(delivered, 10);
    assert_eq!(delivered + refused, 20, "{refused} refused");

    close_pair([&client, &server], [&client_connection, &server_connection]);
}

#[tokio::test]
async fn stacked_throttles_all_admit_each_datagram() {
    let identities = Identities::new();
    let (client, client_connection, server, server_connection) =
        throttled_pair(&identities, &ThrottleConfig::new(None, Some(kib_burst()))).await;
    let tight = ThrottleMode::per_conn_with_burst(Rate::per_sec(100), 200);
    let server_connection = server_connection.throttle(&ThrottleConfig::new(None, Some(tight)));

    for _ in 0..3 {
        server_connection
            .send_datagram(Bytes::from_static(&[1; 100]))
            .unwrap();
    }
    assert_eq!(server_connection.stats().gated_datagrams.sent, 1);

    close_pair([&client, &server], [&client_connection, &server_connection]);
}

#[tokio::test]
async fn a_shared_throttle_spans_the_datagrams_of_connections() {
    let identities = Identities::new();
    let shared = ThrottleMode::shared(RateLimiter::new(Rate::per_sec(100), 1024));
    let config = ThrottleConfig::new(None, Some(shared));
    let (client_a, client_connection_a, server_a, first) =
        throttled_pair(&identities, &config).await;
    let (client_b, client_connection_b, server_b, second) =
        throttled_pair(&identities, &config).await;

    for _ in 0..10 {
        first.send_datagram(Bytes::from_static(&[1; 100])).unwrap();
    }
    second.send_datagram(Bytes::from_static(&[1; 100])).unwrap();
    assert_eq!(first.stats().gated_datagrams.sent, 0);
    assert_eq!(second.stats().gated_datagrams.sent, 1);

    close_pair([&client_a, &server_a], [&client_connection_a, &first]);
    close_pair([&client_b, &server_b], [&client_connection_b, &second]);
}
