#![cfg(all(
    feature = "opentelemetry",
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )
))]
#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    reason = "an integration test's fixtures fail the test by panicking"
)]
//! What endpoint and connection metrics record, and when.

mod runtime;

use std::{
    net::{Ipv4Addr, SocketAddr},
    sync::Arc,
    time::Duration,
};

use parking_lot::Mutex;
use rama_core::{
    rt::{Executor, spawn},
    telemetry::opentelemetry::{
        KeyValue, MeterOptions,
        metrics::MeterProvider as _,
        sdk::{
            error::OTelSdkResult,
            metrics::{
                PeriodicReader, SdkMeterProvider, Temporality,
                data::{AggregatedMetrics, MetricData, ResourceMetrics},
                exporter::PushMetricExporter,
            },
        },
    },
};
use rama_quic::{Endpoint, telemetry::QuicMetrics};
use runtime::{Identities, connect, exchange, serve_one};

fn localhost() -> SocketAddr {
    SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0)
}

/// A point's value: a sum's, or a histogram's count.
#[derive(Debug, Clone)]
struct Point {
    name: String,
    attributes: Vec<KeyValue>,
    value: u64,
}

/// Keeps the points of the latest export; cumulative, so they are the whole state.
#[derive(Debug, Clone, Default)]
struct Capture(Arc<Mutex<Vec<Point>>>);

impl PushMetricExporter for Capture {
    async fn export(&self, metrics: &ResourceMetrics) -> OTelSdkResult {
        let mut points = Vec::new();
        for metric in metrics.scope_metrics().flat_map(|scope| scope.metrics()) {
            let name = metric.name();
            match metric.data() {
                AggregatedMetrics::U64(MetricData::Sum(sum)) => {
                    points.extend(sum.data_points().map(|point| Point {
                        name: name.to_owned(),
                        attributes: point.attributes().cloned().collect(),
                        value: point.value(),
                    }));
                }
                AggregatedMetrics::F64(MetricData::Histogram(histogram)) => {
                    points.extend(histogram.data_points().map(|point| Point {
                        name: name.to_owned(),
                        attributes: point.attributes().cloned().collect(),
                        value: point.count(),
                    }));
                }
                other => panic!("{name}: unexpected data {other:?}"),
            }
        }
        *self.0.lock() = points;
        Ok(())
    }

    fn force_flush(&self) -> OTelSdkResult {
        Ok(())
    }

    fn shutdown_with_timeout(&self, _timeout: Duration) -> OTelSdkResult {
        Ok(())
    }

    fn temporality(&self) -> Temporality {
        Temporality::Cumulative
    }
}

struct Collector {
    provider: SdkMeterProvider,
    capture: Capture,
    metrics: QuicMetrics,
}

impl Collector {
    fn new() -> Self {
        let capture = Capture::default();
        let provider = SdkMeterProvider::builder()
            .with_reader(PeriodicReader::builder(capture.clone()).build())
            .build();
        let metrics =
            QuicMetrics::new_with_meter(&provider.meter("rama-quic-test"), MeterOptions::default());
        Self {
            provider,
            capture,
            metrics,
        }
    }

    fn points(&self, name: &str) -> Vec<Point> {
        self.provider.force_flush().unwrap();
        self.capture
            .0
            .lock()
            .iter()
            .filter(|point| point.name == name)
            .cloned()
            .collect()
    }

    /// The sum of the points carrying every `(key, value)` given.
    fn value(&self, name: &str, filter: &[(&str, &str)]) -> u64 {
        self.points(name)
            .iter()
            .filter(|point| {
                filter.iter().all(|(key, value)| {
                    point
                        .attributes
                        .iter()
                        .any(|kv| kv.key.as_str() == *key && kv.value.as_str() == *value)
                })
            })
            .map(|point| point.value)
            .sum()
    }
}

async fn endpoint(identities: Option<&Identities>, metrics: &QuicMetrics) -> Endpoint {
    Endpoint::build(Executor::new())
        .maybe_with_server_config(identities.map(Identities::server_config))
        .with_metrics(metrics.clone())
        .bind_address(localhost())
        .await
        .expect("the endpoint binds")
}

/// Closed while its stream handles live on: the connection is recorded at the close, once, and
/// not again when the handles go.
#[tokio::test]
async fn a_connection_is_recorded_once_at_its_end() {
    let collector = Collector::new();
    let identities = Identities::new();
    let server = endpoint(Some(&identities), &collector.metrics).await;
    let client = endpoint(None, &collector.metrics).await;
    let addr = server.local_addr().unwrap();
    let (arrived, stream_arrived) = tokio::sync::oneshot::channel();
    let served = spawn({
        let server = server.clone();
        async move {
            let connection = server.accept().await.unwrap().await.unwrap();
            let (send, mut recv) = connection.accept_bi().await.unwrap();
            let mut first = [0; 4];
            recv.read_exact(&mut first).await.unwrap();
            arrived.send(()).unwrap();
            let reason = connection.closed().await;
            ((send, recv), reason)
        }
    });
    let connection = connect(&client, &identities, addr).await;
    let (mut send, recv) = connection.open_bi().await.unwrap();
    send.write_all(b"held open").await.unwrap();
    stream_arrived.await.unwrap();

    let closed = "quic.connection.closed";
    let handshake = "quic.connection.handshake.duration";
    assert_eq!(collector.value(handshake, &[("quic.side", "client")]), 1);
    assert_eq!(collector.value(closed, &[]), 0, "nothing ended yet");

    let before = connection.stats();
    connection.close(7u32, b"done");
    let (server_streams, _reason) = served.await.unwrap();
    assert_eq!(collector.value(handshake, &[("quic.side", "server")]), 1);
    let client_closed = [
        ("quic.side", "client"),
        ("quic.close.reason", "local_close"),
        ("quic.handshake.completed", "true"),
        ("quic.version", "1"),
    ];
    let server_closed = [
        ("quic.side", "server"),
        ("quic.close.reason", "application_close"),
    ];
    assert_eq!(collector.value(closed, &client_closed), 1);
    assert_eq!(collector.value(closed, &server_closed), 1);
    assert_eq!(collector.value(closed, &[]), 2);
    let duration = "quic.connection.duration";
    assert_eq!(collector.value(duration, &client_closed), 1);
    assert_eq!(collector.value(duration, &server_closed), 1);

    // The totals at the close: at least what was sent before it, not what its closing period
    // sent after.
    let bytes = "quic.connection.bytes";
    let sent = collector.value(bytes, &[("quic.side", "client"), ("direction", "sent")]);
    assert!(
        sent >= before.udp_tx.bytes,
        "{sent} < {}",
        before.udp_tx.bytes
    );
    assert!(sent > 0);
    client.wait_idle().await;
    assert!(sent <= connection.stats().udp_tx.bytes);
    assert!(collector.value(bytes, &[("quic.side", "server"), ("direction", "received")]) > 0);

    drop((send, recv, server_streams, connection));
    server.shutdown().await;
    client.shutdown().await;
    drop((server, client));
    assert_eq!(
        collector.value(closed, &[]),
        2,
        "no record when the handles go"
    );
    assert_eq!(collector.value(duration, &[]), 2);
    assert_eq!(collector.value(bytes, &[("direction", "sent")]), {
        collector.value(bytes, &[("quic.side", "client"), ("direction", "sent")])
            + collector.value(bytes, &[("quic.side", "server"), ("direction", "sent")])
    });
}

/// Endpoints sharing metrics report their sum, and an endpoint that goes leaves its counts.
#[tokio::test]
async fn endpoint_counters_add_up_and_stay_when_an_endpoint_goes() {
    let collector = Collector::new();
    let identities = Identities::new();
    let first = endpoint(Some(&identities), &collector.metrics).await;
    let second = endpoint(Some(&identities), &collector.metrics).await;
    let client = endpoint(None, &collector.metrics).await;

    for server in [&first, &second] {
        let served = spawn({
            let server = server.clone();
            async move { serve_one(&server).await }
        });
        let connection = connect(&client, &identities, server.local_addr().unwrap()).await;
        exchange(&connection, b"count me").await;
        connection.close(0u32, b"");
        served.await.unwrap();
    }

    let handshakes = "quic.endpoint.handshakes";
    let received = "quic.endpoint.datagrams.received";
    assert_eq!(collector.value(handshakes, &[("outcome", "accepted")]), 2);
    assert_eq!(collector.value(handshakes, &[("outcome", "outgoing")]), 2);
    assert_eq!(collector.value(handshakes, &[("outcome", "refused")]), 0);
    let all_received = collector.value(received, &[]);
    let expected = first.stats().received_datagrams
        + second.stats().received_datagrams
        + client.stats().received_datagrams;
    assert!(all_received <= expected && all_received > 0);

    first.shutdown().await;
    let last_seen = collector.value(received, &[]);
    drop(first);
    // However far its teardown got, the total does not fall.
    for _ in 0..20 {
        assert_eq!(collector.value(handshakes, &[("outcome", "accepted")]), 2);
        assert!(collector.value(received, &[]) >= last_seen);
        tokio::task::yield_now().await;
    }
    assert_eq!(
        collector.points("quic.endpoint.admission.refused").len(),
        3,
        "one series per reason"
    );
    assert_eq!(collector.points("quic.endpoint.responses.dropped").len(), 2);
}
