use std::{sync::Arc, time::Duration};

use rama_core::telemetry::opentelemetry::{
    metrics::MeterProvider as _,
    sdk::{
        error::OTelSdkResult,
        metrics::{
            PeriodicReader, SdkMeterProvider, Temporality,
            data::{AggregatedMetrics, MetricData, ResourceMetrics},
            exporter::PushMetricExporter,
        },
    },
};

use super::*;

#[derive(Default)]
struct Fake(Mutex<EndpointCounters>);

impl CountedEndpoint for Fake {
    fn counters(&self) -> EndpointCounters {
        *self.0.lock()
    }
}

fn fake(accepted: u64) -> Arc<Fake> {
    Arc::new(Fake(Mutex::new(EndpointCounters {
        accepted,
        ..EndpointCounters::default()
    })))
}

fn weak(endpoint: &Arc<Fake>) -> Weak<dyn CountedEndpoint> {
    let weak: Weak<Fake> = Arc::downgrade(endpoint);
    weak
}

#[test]
fn endpoints_add_up_and_a_gone_one_keeps_what_it_counted() {
    let registry = Arc::new(Registry::default());
    let a = fake(3);
    let b = fake(4);
    let slot_a = registry.register(weak(&a));
    let _slot_b = registry.register(weak(&b));
    assert_eq!(registry.collect().accepted, 7);

    // Unreachable, with its last counters not handed in yet: what was seen still counts.
    a.0.lock().accepted = 5;
    drop(a);
    assert_eq!(registry.collect().accepted, 7);

    // Its last counters, then retired: they stay in the total.
    slot_a.hand_in(EndpointCounters {
        accepted: 5,
        ..EndpointCounters::default()
    });
    drop(slot_a);
    assert_eq!(registry.collect().accepted, 9);
    assert_eq!(
        registry.state.lock().live.len(),
        1,
        "the retired entry is folded"
    );
    assert_eq!(registry.collect().accepted, 9);
}

/// Endpoints that come and go while nothing collects leave no entry behind, only their counts.
#[test]
fn retired_endpoints_are_folded_without_a_collection() {
    let registry = Arc::new(Registry::default());
    for _ in 0..1_000 {
        let endpoint = fake(1);
        let slot = registry.register(weak(&endpoint));
        slot.hand_in(endpoint.counters());
        drop(endpoint);
        drop(slot);
    }
    assert!(registry.state.lock().live.is_empty());
    assert_eq!(registry.collect().accepted, 1_000);
    assert_eq!(registry.collect().accepted, 1_000);
}

#[test]
fn a_late_hand_in_never_lowers_what_was_seen() {
    let registry = Arc::new(Registry::default());
    let a = fake(6);
    let slot = registry.register(weak(&a));
    assert_eq!(registry.collect().accepted, 6);
    slot.hand_in(EndpointCounters::default());
    drop(slot);
    assert_eq!(registry.collect().accepted, 6);
}

#[test]
fn every_counter_is_summed_and_kept() {
    let registry = Arc::new(Registry::default());
    let all = |value| EndpointCounters {
        accepted: value,
        outgoing: value,
        refused: value,
        ignored: value,
        expired: value,
        refused_at_limit: value,
        refused_per_source: value,
        refused_unvalidated: value,
        retried: value,
        received: value,
        dropped: value,
        truncated_entries: value,
        errors_ignored: value,
        responses_queue_full: value,
        responses_send_failed: value,
    };
    let a = Arc::new(Fake(Mutex::new(all(1))));
    let b = Arc::new(Fake(Mutex::new(all(2))));
    let slot_a = registry.register(weak(&a));
    let _slot_b = registry.register(weak(&b));
    assert_eq!(registry.collect(), all(3));
    drop(a);
    drop(slot_a);
    assert_eq!(registry.collect(), all(3));
}

/// One exported point: its metric, attributes, and value: a `u64` sum's, or a histogram's sum
/// of samples (`counted` is `None` then).
#[derive(Debug, Clone)]
struct Point {
    name: String,
    attributes: Vec<KeyValue>,
    counted: Option<u64>,
    value: f64,
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
                        counted: Some(point.value()),
                        value: point.value() as f64,
                    }));
                }
                AggregatedMetrics::F64(MetricData::Histogram(histogram)) => {
                    points.extend(histogram.data_points().map(|point| Point {
                        name: name.to_owned(),
                        attributes: point.attributes().cloned().collect(),
                        counted: None,
                        value: point.sum(),
                    }));
                }
                // Anything else exports no points, which the exact expectations reject.
                _ => {}
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

impl Capture {
    fn points(&self, provider: &SdkMeterProvider, name: &str) -> Vec<Point> {
        provider.force_flush().unwrap();
        self.0
            .lock()
            .iter()
            .filter(|point| point.name == name)
            .cloned()
            .collect()
    }
}

fn collector(options: MeterOptions) -> (SdkMeterProvider, Capture, QuicMetrics) {
    let exporter = Capture::default();
    let provider = SdkMeterProvider::builder()
        .with_reader(PeriodicReader::builder(exporter.clone()).build())
        .build();
    let metrics = QuicMetrics::new_with_meter(&provider.meter("rama-quic-test"), options);
    (provider, exporter, metrics)
}

/// Every exported `u64` sum point of `name`.
fn exported(
    provider: &SdkMeterProvider,
    exporter: &Capture,
    name: &str,
) -> Vec<(Vec<KeyValue>, u64)> {
    exporter
        .points(provider, name)
        .into_iter()
        .filter_map(|point| Some((point.attributes, point.counted?)))
        .collect()
}

/// Endpoints with the same attributes would overwrite each other's observation; one callback
/// reports their sum instead.
#[test]
fn endpoints_with_the_same_attributes_report_their_sum() {
    let (provider, exporter, metrics) = collector(MeterOptions {
        attributes: Some(vec![KeyValue::new("service", "edge")]),
        metric_prefix: None,
    });
    let a = fake(2);
    let b = fake(5);
    let _slot_a = metrics.register(weak(&a));
    let _slot_b = metrics.register(weak(&b));
    let points = exported(&provider, &exporter, "quic.endpoint.handshakes");
    let accepted: Vec<_> = points
        .iter()
        .filter(|(attributes, _)| {
            attributes.contains(&KeyValue::new("outcome", "accepted"))
                && attributes.contains(&KeyValue::new("service", "edge"))
        })
        .collect();
    assert_eq!(accepted.len(), 1, "one series: {points:?}");
    assert_eq!(accepted[0].1, 7);
    assert_eq!(points.len(), 4, "one series per outcome: {points:?}");
}

#[test]
fn a_prefix_names_every_instrument() {
    let (provider, exporter, metrics) = collector(MeterOptions {
        attributes: None,
        metric_prefix: Some("edge".to_owned()),
    });
    let a = fake(1);
    let _slot = metrics.register(weak(&a));
    assert_eq!(
        exported(&provider, &exporter, "edge.quic.endpoint.handshakes").len(),
        4
    );
    assert!(exported(&provider, &exporter, "quic.endpoint.handshakes").is_empty());
}

#[test]
fn versions_and_reasons_are_bounded_names() {
    assert_eq!(version_name(Version::V1), "1");
    assert_eq!(version_name(Version::V2), "2");
    assert_eq!(version_name(Version::from_u32(0x1a2a_3a4a)), "other");
    assert_eq!(reason_name(None), "dropped");
    assert_eq!(reason_name(Some(&ConnectionError::TimedOut)), "timeout");
    assert_eq!(
        reason_name(Some(&ConnectionError::LocallyClosed)),
        "local_close"
    );
}

/// Every exported point of `name` as a value: a sum's, or a histogram's sum of samples.
fn values(
    provider: &SdkMeterProvider,
    exporter: &Capture,
    name: &str,
) -> Vec<(Vec<KeyValue>, f64)> {
    exporter
        .points(provider, name)
        .into_iter()
        .map(|point| (point.attributes, point.value))
        .collect()
}

/// The points carrying every attribute in `filter` add up to `expected`.
#[track_caller]
fn assert_value(points: &[(Vec<KeyValue>, f64)], filter: &[KeyValue], expected: f64) {
    let value: f64 = points
        .iter()
        .filter(|(attributes, _)| filter.iter().all(|kv| attributes.contains(kv)))
        .map(|(_, value)| value)
        .sum();
    assert!(
        (value - expected).abs() < f64::EPSILON,
        "{value} != {expected} for {filter:?}"
    );
}

#[tokio::test(start_paused = true)]
async fn a_connection_records_its_times_and_totals() {
    let (provider, exporter, metrics) = collector(MeterOptions::default());
    let record = metrics.connection();
    tokio::time::advance(Duration::from_millis(250)).await;
    record.connected(true, Version::V1);
    tokio::time::advance(Duration::from_millis(750)).await;
    let mut stats = ConnectionStats::default();
    stats.udp_tx.bytes = 1_200;
    stats.udp_rx.bytes = 3_400;
    stats.path.lost_packets = 2;
    stats.gated_datagrams.sent = 5;
    stats.gated_datagrams.received = 7;
    record.finish(
        true,
        Version::V1,
        Some(&ConnectionError::TimedOut),
        true,
        &stats,
    );

    let side = KeyValue::new("quic.side", "server");
    let version = KeyValue::new("quic.version", "1");
    let ended = [
        side.clone(),
        version.clone(),
        KeyValue::new("quic.close.reason", "timeout"),
        KeyValue::new("quic.handshake.completed", true),
    ];
    let handshake = values(&provider, &exporter, "quic.connection.handshake.duration");
    assert_value(&handshake, &[side.clone(), version], 0.25);
    let duration = values(&provider, &exporter, "quic.connection.duration");
    assert_value(&duration, &ended, 1.0);
    let closed = values(&provider, &exporter, "quic.connection.closed");
    assert_value(&closed, &ended, 1.0);

    let sent = KeyValue::new("direction", "sent");
    let received = KeyValue::new("direction", "received");
    let bytes = values(&provider, &exporter, "quic.connection.bytes");
    assert_value(&bytes, &[side.clone(), sent.clone()], 1_200.0);
    assert_value(&bytes, &[side.clone(), received.clone()], 3_400.0);
    let lost = values(&provider, &exporter, "quic.connection.lost_packets");
    assert_value(&lost, std::slice::from_ref(&side), 2.0);
    let gated = values(&provider, &exporter, "quic.connection.datagrams.gated");
    assert_value(&gated, &[side.clone(), sent], 5.0);
    assert_value(&gated, &[side, received], 7.0);
}

#[cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
mod endpoints {
    use std::net::{Ipv4Addr, SocketAddr};

    use rama_core::rt::{Executor, spawn};

    use super::*;
    use crate::{Endpoint, test_helpers};

    async fn bind(metrics: &QuicMetrics, server: Option<crate::ServerConfig>) -> Endpoint {
        Endpoint::build(Executor::new())
            .maybe_with_server_config(server)
            .with_metrics(metrics.clone())
            .bind_address(SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0))
            .await
            .unwrap()
    }

    /// Endpoints that end before anything collects still count what they did, from the
    /// counters their state hands in as it goes.
    #[tokio::test]
    async fn a_dropped_endpoint_hands_in_its_final_counters() {
        let (provider, exporter, metrics) = collector(MeterOptions::default());
        let identity = test_helpers::identity();
        let server = bind(&metrics, Some(test_helpers::server(&identity))).await;
        let client = bind(&metrics, None).await;
        let addr = server.local_addr().unwrap();
        let served = spawn({
            let server = server.clone();
            async move {
                let connection = server.accept().await.unwrap().await.unwrap();
                connection.closed().await
            }
        });
        let connection = client
            .connect_with(test_helpers::client(&identity), addr, "localhost")
            .unwrap()
            .await
            .unwrap();
        connection.close(0u32, b"");
        let _reason = served.await.unwrap();
        client.shutdown().await;
        server.shutdown().await;
        let received = server.stats().received_datagrams + client.stats().received_datagrams;
        assert!(received > 0);
        drop((connection, server, client));
        // Bounded, so a slot that never leaves the registry fails here instead of hanging.
        tokio::time::timeout(Duration::from_secs(10), async {
            while !metrics.inner.endpoints.state.lock().live.is_empty() {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        })
        .await
        .expect("dropped endpoints leave the registry");

        let handshakes = exported(&provider, &exporter, "quic.endpoint.handshakes");
        let outcome = |name| {
            handshakes
                .iter()
                .find(|(attributes, _)| attributes.contains(&KeyValue::new("outcome", name)))
                .map(|(_, value)| *value)
        };
        assert_eq!(outcome("accepted"), Some(1));
        assert_eq!(outcome("outgoing"), Some(1));
        let total = exported(&provider, &exporter, "quic.endpoint.datagrams.received");
        assert_eq!(total.len(), 1);
        assert!(total[0].1 >= received, "{} < {received}", total[0].1);
    }
}
