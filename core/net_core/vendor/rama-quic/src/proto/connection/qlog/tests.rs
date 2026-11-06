use super::*;
use crate::qlog::{EncodedWriter, JsonSeqEncoder, QlogOutput, QueueLimits, TraceInfo};
use parking_lot::Mutex;
use rama_utils::octets;
use serde_json::{Value, json};
use std::{
    io,
    net::{Ipv4Addr, SocketAddr},
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
};
use tokio::io::AsyncWrite;

#[derive(Default)]
struct Output {
    bytes: Vec<u8>,
    remaining: Option<usize>,
    max_chunk: Option<usize>,
    interrupt_once: bool,
    calls: usize,
    flushes: usize,
    shutdowns: usize,
}

#[derive(Clone, Default)]
struct Trace(Arc<Mutex<Output>>);

impl Trace {
    fn records(&self) -> Vec<Value> {
        let output = self.0.lock();
        assert_eq!(output.bytes.first(), Some(&0x1e));
        output.bytes[1..]
            .split(|byte| *byte == 0x1e)
            .map(|record| {
                assert_eq!(record.last(), Some(&b'\n'));
                serde_json::from_slice(record).unwrap()
            })
            .collect()
    }
}

impl io::Write for Trace {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let mut output = self.0.lock();
        output.calls += 1;
        if std::mem::take(&mut output.interrupt_once) {
            return Err(io::Error::from(io::ErrorKind::Interrupted));
        }
        let len = output
            .remaining
            .unwrap_or(bytes.len())
            .min(output.max_chunk.unwrap_or(bytes.len()))
            .min(bytes.len());
        if len == 0 && !bytes.is_empty() {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "closed trace"));
        }
        output.bytes.extend_from_slice(&bytes[..len]);
        if let Some(remaining) = &mut output.remaining {
            *remaining -= len;
        }
        Ok(len)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.0.lock().flushes += 1;
        Ok(())
    }
}

impl AsyncWrite for Trace {
    fn poll_write(
        mut self: Pin<&mut Self>,
        _: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        Poll::Ready(io::Write::write(&mut *self, bytes))
    }

    fn poll_flush(mut self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(io::Write::flush(&mut *self))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.0.lock().shutdowns += 1;
        Poll::Ready(Ok(()))
    }
}

#[tokio::test]
async fn qlog_header_escapes_metadata_and_declares_schema_and_clock() {
    let trace = Trace::default();
    let title = "a \"trace\"\nwith a record separator: \u{1e}";
    let mut writer = EncodedWriter::new(trace.clone(), JsonSeqEncoder);
    writer
        .begin(&TraceInfo {
            event_schemas: &[],
            start_time: Instant::now(),
            title: Some(title.into()),
            description: Some(rama_utils::str::arcstr::arcstr!("λ")),
        })
        .await
        .unwrap();
    let records = trace.records();
    assert_eq!(
        records,
        vec![json!({
            "file_schema": "urn:ietf:params:qlog:file:sequential",
            "serialization_format": "application/qlog+json-seq",
            "title": title,
            "description": "λ",
            "trace": {
                "title": title,
                "description": "λ",
                "vantage_point": {"type": "unknown"},
                "event_schemas": ["urn:ietf:params:qlog:events:quic-13"],
                "common_fields": {
                    "time_format": "relative_to_epoch",
                    "reference_time": {"clock_type": "monotonic", "epoch": "unknown"}
                }
            }
        })]
    );
    assert_eq!(trace.0.lock().flushes, 0);
    writer.finish().await.unwrap();
    assert_eq!(trace.0.lock().flushes, 1);
    assert_eq!(trace.0.lock().shutdowns, 1);
}

#[tokio::test]
async fn qlog_events_preserve_packet_types_time_group_and_loss_reason() {
    let trace = Trace::default();
    let start = Instant::now();
    let stream = crate::qlog::QlogConfig::default()
        .with_writer(Box::new(trace.clone()))
        .with_start_time(start)
        .start()
        .unwrap();
    let sink = ConnectionQlog::from(Some(stream.clone()));
    assert!(sink.is_enabled());
    assert!(!ConnectionQlog::default().is_enabled());
    let group = ConnectionId::new(&[0, 0xab]);
    for (space, early) in [
        (SpaceId::Initial, false),
        (SpaceId::Handshake, false),
        (SpaceId::Data, true),
        (SpaceId::Data, false),
    ] {
        sink.emit_packet_sent(
            7,
            1200,
            space,
            early,
            false,
            start + Duration::from_micros(1250),
            group,
        );
    }
    sink.emit_packet_received(
        8,
        Some(1200),
        SpaceId::Data,
        false,
        start.checked_sub(Duration::from_millis(1)).unwrap(),
        group,
    );
    let packet = SentPacket {
        path_generation: 0,
        time_sent: start,
        size: 1200,
        ack_eliciting: true,
        is_0rtt: false,
        is_mtu_probe_packet: false,
        largest_acked: None,
        retransmits: Default::default(),
        stream_frames: Default::default(),
    };
    let delay = Duration::from_micros(2500);
    for elapsed in [Duration::from_micros(1250), delay] {
        sink.emit_packet_lost(7, &packet, delay, SpaceId::Data, start + elapsed, group);
    }
    stream.emit_event(
        group,
        Event::RecoveryMetricsUpdated(event::RecoveryMetricsUpdated {
            latest_rtt: Some(1.25),
            bytes_in_flight: Some(u64::MAX),
            ..Default::default()
        }),
        start,
    );

    stream.flush().await.unwrap();
    let records = trace.records();
    assert_eq!(records.len(), 9);
    assert!(records[0].get("title").is_none());
    for (record, kind) in records[1..5]
        .iter()
        .zip(["initial", "handshake", "0RTT", "1RTT"])
    {
        assert_eq!(
            *record,
            json!({
                "time": 1.25, "group_id": "00ab", "name": "quic:packet_sent",
                "data": {"header": {"packet_type": kind, "packet_number": 7}, "raw": {"length": 1200}, "is_mtu_probe_packet": false}
            })
        );
    }
    assert_eq!(
        records[5],
        json!({
            "time": 0.0, "group_id": "00ab", "name": "quic:packet_received",
            "data": {"header": {"packet_type": "1RTT", "packet_number": 8}, "raw": {"length": 1200}}
        })
    );
    for (record, (time, trigger)) in records[6..8]
        .iter()
        .zip([(1.25, "reordering_threshold"), (2.5, "time_threshold")])
    {
        assert_eq!(
            *record,
            json!({
                "time": time, "group_id": "00ab", "name": "quic:packet_lost",
                "data": {"header": {"packet_type": "1RTT", "packet_number": 7},
                    "trigger": trigger, "is_mtu_probe_packet": false}
            })
        );
    }
    assert_eq!(
        records[8],
        json!({
            "time": 0.0, "group_id": "00ab", "name": "quic:recovery_metrics_updated",
            "data": {"latest_rtt": 1.25, "bytes_in_flight": u64::MAX}
        })
    );
    let early_packet = SentPacket {
        is_0rtt: true,
        ..packet
    };
    sink.emit_packet_lost(9, &early_packet, delay, SpaceId::Data, start + delay, group);
    stream.flush().await.unwrap();
    assert_eq!(trace.records()[9]["data"]["header"]["packet_type"], "0RTT");
    let flushes = trace.0.lock().flushes;
    drop(sink);
    assert_eq!(
        trace.0.lock().flushes,
        flushes,
        "dropping a producer does not flush on the caller"
    );
    stream.shutdown().await.unwrap();
    assert_eq!(trace.0.lock().flushes, flushes + 1);
}

#[tokio::test]
async fn qlog_writer_failure_disables_further_writes_and_preserves_first_error() {
    let trace = Trace::default();
    let start = Instant::now();
    let stream = crate::qlog::QlogConfig::default()
        .with_writer(Box::new(trace.clone()))
        .with_start_time(start)
        .start()
        .unwrap();
    stream.flush().await.unwrap();
    trace.0.lock().remaining = Some(5);
    let sink = ConnectionQlog::from(Some(stream.clone()));
    sink.emit_packet_received(
        0,
        Some(1200),
        SpaceId::Initial,
        false,
        start,
        ConnectionId::new(&[]),
    );
    let error = stream.flush().await.unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::BrokenPipe);
    assert!(!sink.is_enabled());
    let calls = trace.0.lock().calls;
    sink.emit(ConnectionId::new(&[]), start, || -> Event {
        panic!("failed recording must not construct more event data")
    });
    let repeated = stream.flush().await.unwrap_err();
    assert_eq!(repeated.kind(), error.kind());
    assert_eq!(repeated.to_string(), error.to_string());
    assert_eq!(
        trace.0.lock().calls,
        calls,
        "a partial record ends the trace"
    );
    let shutdown = stream.shutdown().await.unwrap_err();
    assert_eq!(shutdown.kind(), error.kind());

    let trace = Trace::default();
    trace.0.lock().remaining = Some(0);
    let stream = crate::qlog::QlogConfig::default()
        .with_writer(Box::new(trace))
        .start()
        .unwrap();
    assert_eq!(
        stream.flush().await.unwrap_err().kind(),
        io::ErrorKind::BrokenPipe
    );
    assert!(!ConnectionQlog::from(Some(stream.clone())).is_enabled());
    stream.shutdown().await.unwrap_err();
    crate::qlog::QlogConfig::default()
        .start()
        .expect_err("starting a recorder requires an output destination");
}

#[tokio::test]
async fn qlog_short_writes_and_interruptions_preserve_complete_records() {
    let trace = Trace::default();
    {
        let mut output = trace.0.lock();
        output.max_chunk = Some(1);
        output.interrupt_once = true;
    }
    let start = Instant::now();
    let stream = crate::qlog::QlogConfig::default()
        .with_writer(Box::new(trace.clone()))
        .with_start_time(start)
        .start()
        .unwrap();
    stream.flush().await.unwrap();
    trace.0.lock().interrupt_once = true;
    ConnectionQlog::from(Some(stream.clone())).emit_packet_received(
        42,
        Some(1200),
        SpaceId::Handshake,
        false,
        start,
        ConnectionId::new(&[]),
    );
    stream.flush().await.unwrap();
    let records = trace.records();
    assert_eq!(records.len(), 2);
    assert_eq!(
        records[1],
        json!({"time": 0.0, "group_id": "", "name": "quic:packet_received", "data": {"header": {"packet_type": "handshake", "packet_number": 42}, "raw": {"length": 1200}}})
    );
    stream.shutdown().await.unwrap();
    assert_eq!(trace.0.lock().flushes, 3);
}

#[tokio::test]
async fn qlog_cloned_streams_serialize_concurrent_records() {
    let trace = Trace::default();
    let start = Instant::now();
    let stream = crate::qlog::QlogConfig::default()
        .with_writer(Box::new(trace.clone()))
        .with_queue_limits(QueueLimits {
            max_queued_bytes: octets::mib(64),
            ..QueueLimits::default()
        })
        .start()
        .unwrap();
    std::thread::scope(|scope| {
        for producer in 0..4 {
            let sink = ConnectionQlog::from(Some(stream.clone()));
            scope.spawn(move || {
                for pn in 0..100 {
                    sink.emit_packet_sent(
                        pn,
                        1200,
                        SpaceId::Data,
                        false,
                        false,
                        start,
                        ConnectionId::new(&[producer]),
                    );
                }
            });
        }
    });
    stream.flush().await.unwrap();
    let records = trace.records();
    assert_eq!(records.len(), 401);
    let mut packets = std::collections::BTreeSet::new();
    for record in &records[1..] {
        assert_eq!(record["name"], "quic:packet_sent");
        assert!(packets.insert((
            record["group_id"].as_str().unwrap(),
            record["data"]["header"]["packet_number"].as_u64().unwrap()
        )));
    }
    for group in ["00", "01", "02", "03"] {
        for pn in 0..100 {
            assert!(packets.contains(&(group, pn)));
        }
    }
    stream.shutdown().await.unwrap();
    assert_eq!(trace.0.lock().flushes, 2);
}

#[tokio::test]
async fn qlog_recovery_metrics_emit_initial_snapshot_then_changes() {
    let trace = Trace::default();
    let start = Instant::now();
    let stream = crate::qlog::QlogConfig::default()
        .with_writer(Box::new(trace.clone()))
        .with_start_time(start)
        .start()
        .unwrap();
    let sink = ConnectionQlog::from(Some(stream.clone()));
    let mut path = PathData::new(
        SocketAddr::from((Ipv4Addr::LOCALHOST, 443)),
        None,
        false,
        None,
        0,
        start,
        &crate::proto::TransportConfig::default(),
    );
    let group = ConnectionId::new(&[0xff]);
    ConnectionQlog::default().emit_recovery_metrics(0, &mut path, start, group);
    sink.emit_recovery_metrics(0, &mut path, start, group);
    stream.flush().await.unwrap();
    let records = trace.records();
    assert_eq!(records.len(), 2);
    assert_eq!(records[1]["name"], "quic:recovery_metrics_updated");
    let data = &records[1]["data"];
    for field in [
        "min_rtt",
        "smoothed_rtt",
        "latest_rtt",
        "rtt_variance",
        "pto_count",
        "bytes_in_flight",
        "congestion_window",
    ] {
        assert!(data.get(field).is_some(), "missing {field}");
    }
    assert!(data.get("packets_in_flight").is_none());
    sink.emit_recovery_metrics(0, &mut path, start, group);
    stream.flush().await.unwrap();
    assert_eq!(trace.records().len(), 2);
    sink.emit_recovery_metrics(1, &mut path, start + Duration::from_millis(5), group);
    stream.flush().await.unwrap();
    assert_eq!(
        trace.records()[2],
        json!({"time": 5.0, "group_id": "ff", "name": "quic:recovery_metrics_updated", "data": {"pto_count": 1}})
    );
    stream.shutdown().await.unwrap();
}

#[test]
fn qlog_disabled_sink_does_not_construct_event_data() {
    ConnectionQlog::default().emit(ConnectionId::new(&[]), Instant::now(), || -> Event {
        panic!("disabled recording must not construct diagnostic data")
    });
}

struct BlockedHeader {
    trace: Trace,
    entered: Option<tokio::sync::oneshot::Sender<()>>,
    release: Option<tokio::sync::oneshot::Receiver<()>>,
}

impl AsyncWrite for BlockedHeader {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        if let Some(entered) = self.entered.take() {
            entered.send(()).unwrap_or_default();
        }
        if let Some(release) = self.release.as_mut() {
            if std::future::Future::poll(Pin::new(release), cx).is_pending() {
                return Poll::Pending;
            }
            self.release = None;
        }
        Pin::new(&mut self.trace).poll_write(cx, bytes)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.trace).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.trace).poll_shutdown(cx)
    }
}

fn blocked_recorder() -> (
    crate::qlog::QlogRecorder,
    Trace,
    tokio::sync::oneshot::Receiver<()>,
    tokio::sync::oneshot::Sender<()>,
) {
    let trace = Trace::default();
    let (entered, waiting) = tokio::sync::oneshot::channel();
    let (release, receiver) = tokio::sync::oneshot::channel();
    let recorder = crate::qlog::QlogConfig::default()
        .with_output(EncodedWriter::new(
            BlockedHeader {
                trace: trace.clone(),
                entered: Some(entered),
                release: Some(receiver),
            },
            JsonSeqEncoder,
        ))
        .with_queue_limits(QueueLimits {
            max_queued_events: 1,
            ..QueueLimits::default()
        })
        .start()
        .unwrap();
    (recorder, trace, waiting, release)
}

#[tokio::test]
async fn rejected_recovery_snapshot_is_retried_and_unchanged_metrics_remain_suppressed() {
    let (recorder, trace, entered, release) = blocked_recorder();
    entered.await.unwrap();
    let sink = ConnectionQlog::from(Some(recorder.clone()));
    let start = Instant::now();
    let group = ConnectionId::new(&[1]);
    let mut path = PathData::new(
        SocketAddr::from((Ipv4Addr::LOCALHOST, 443)),
        None,
        false,
        None,
        0,
        start,
        &crate::proto::TransportConfig::default(),
    );
    // A control command fills the channel without consuming event reservations. Admission
    // must reject before committing the path's recovery snapshot.
    let mut flush = std::pin::pin!(recorder.flush());
    tokio::select! {
        biased;
        result = &mut flush => panic!("header output is blocked: {result:?}"),
        () = std::future::ready(()) => {}
    }
    sink.emit_recovery_metrics(0, &mut path, start, group);
    assert_eq!(recorder.stats().submitted_events, 0);
    assert_eq!(recorder.stats().dropped_events, 1);
    release.send(()).unwrap();
    flush.await.unwrap();
    sink.emit_recovery_metrics(0, &mut path, start, group);
    recorder.flush().await.unwrap();
    let records = trace.records();
    assert_eq!(records.len(), 2);
    assert!(records[1]["data"].get("smoothed_rtt").is_some());
    assert!(records[1]["data"].get("congestion_window").is_some());
    for _ in 0..2 {
        sink.emit_recovery_metrics(0, &mut path, start, group);
        recorder.flush().await.unwrap();
    }
    assert_eq!(
        trace.records().len(),
        2,
        "a skipped unchanged observation must not reset the cache"
    );
    recorder.shutdown().await.unwrap();
}

#[cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
#[tokio::test]
async fn rejected_lifecycle_events_do_not_commit_connection_logging_state() {
    let mut pair = crate::proto::tests::util::Pair::default();
    let (client, _) = pair.connect();
    let now = pair.time;
    let (recorder, trace, entered, release) = blocked_recorder();
    entered.await.unwrap();
    let connection = pair.client_conn_mut(client);
    connection.qlog_sink = ConnectionQlog::from(Some(recorder.clone()));
    let mut flush = std::pin::pin!(recorder.flush());
    tokio::select! {
        biased;
        result = &mut flush => panic!("header output is blocked: {result:?}"),
        () = std::future::ready(()) => {}
    }
    connection.qlog_handshake_started(now);
    connection.qlog_connection_error(now, &crate::ConnectionError::TimedOut);
    assert!(connection.qlog_state.is_none());
    assert!(!connection.qlog_closed);
    release.send(()).unwrap();
    flush.await.unwrap();
    connection.qlog_handshake_started(now);
    recorder.flush().await.unwrap();
    assert!(connection.qlog_state.is_some());
    connection.qlog_connection_error(now, &crate::ConnectionError::TimedOut);
    recorder.flush().await.unwrap();
    assert!(connection.qlog_closed);
    connection.qlog_handshake_started(now);
    connection.qlog_connection_error(now, &crate::ConnectionError::TimedOut);
    recorder.shutdown().await.unwrap();
    let records = trace.records();
    assert_eq!(records.len(), 3);
    assert_eq!(records[1]["data"]["new"], "handshake_started");
    assert_eq!(records[2]["name"], "quic:connection_closed");
}

#[tokio::test]
async fn transport_qlog_recorder_records_to_its_writer() {
    let trace = Trace::default();
    let start = Instant::now();
    let recorder = crate::qlog::QlogConfig::default()
        .with_writer(Box::new(trace.clone()))
        .with_start_time(start)
        .start()
        .unwrap();
    let transport = crate::TransportConfig::default().with_qlog_recorder(recorder);
    let control = transport
        .qlog_sink
        .control()
        .expect("configured recorder control");
    transport.qlog_sink.emit_packet_sent(
        42,
        1200,
        SpaceId::Data,
        false,
        false,
        start,
        ConnectionId::new(&[1]),
    );
    control.recorder().unwrap().shutdown().await.unwrap();
    let records = trace.records();
    assert_eq!(records.len(), 2);
    assert_eq!(records[1]["name"], "quic:packet_sent");
    assert_eq!(records[1]["data"]["header"]["packet_number"], 42);
}

#[tokio::test]
async fn recording_toggles_refresh_recovery_snapshot_without_redundant_state_updates() {
    let trace = Trace::default();
    let recorder = crate::qlog::QlogConfig::default()
        .with_writer(Box::new(trace.clone()))
        .start()
        .unwrap();
    let sink = ConnectionQlog::from(Some(recorder.clone()));
    let control = sink.control().unwrap();
    let now = Instant::now();
    let group = ConnectionId::new(&[1]);
    let mut path = PathData::new(
        SocketAddr::from((Ipv4Addr::LOCALHOST, 443)),
        None,
        false,
        None,
        0,
        now,
        &crate::TransportConfig::default(),
    );
    sink.emit_recovery_metrics(0, &mut path, now, group);
    recorder.flush().await.unwrap();
    assert_eq!(trace.records().len(), 2);
    recorder.set_enabled(false);
    recorder.set_enabled(true);
    sink.emit_recovery_metrics(0, &mut path, now, group);
    recorder.flush().await.unwrap();
    assert_eq!(
        trace.records().len(),
        3,
        "global re-enabling starts with a fresh snapshot"
    );
    control.set_enabled(false);
    control.set_enabled(true);
    sink.emit_recovery_metrics(0, &mut path, now, group);
    recorder.flush().await.unwrap();
    assert_eq!(
        trace.records().len(),
        4,
        "connection re-enabling starts with a fresh snapshot"
    );
    recorder.set_enabled(true);
    control.set_enabled(true);
    sink.emit_recovery_metrics(0, &mut path, now, group);
    recorder.flush().await.unwrap();
    assert_eq!(
        trace.records().len(),
        4,
        "setting an unchanged gate does not invalidate metrics"
    );
    recorder.shutdown().await.unwrap();
}

#[tokio::test]
async fn dynamic_filter_generation_refreshes_previously_suppressed_recovery_snapshot() {
    use crate::qlog::{QlogEventView, QlogFilter, QlogSink};
    use std::sync::atomic::{AtomicU64, Ordering};

    struct DynamicFilter(Arc<AtomicU64>);

    impl QlogFilter for DynamicFilter {
        fn matches(&self, _: &QlogEventView<'_>) -> bool {
            self.0.load(Ordering::Acquire) % 2 == 1
        }

        fn generation(&self) -> u64 {
            self.0.load(Ordering::Acquire)
        }
    }

    let trace = Trace::default();
    let recorder = crate::qlog::QlogConfig::default()
        .with_writer(Box::new(trace.clone()))
        .start()
        .unwrap();
    let generation = Arc::new(AtomicU64::new(0));
    let sink = ConnectionQlog::from_sink(Some(Arc::new(
        recorder
            .clone()
            .filtered_by(DynamicFilter(generation.clone())),
    )));
    let now = Instant::now();
    let group = ConnectionId::new(&[1]);
    let mut path = PathData::new(
        SocketAddr::from((Ipv4Addr::LOCALHOST, 443)),
        None,
        false,
        None,
        0,
        now,
        &crate::TransportConfig::default(),
    );
    sink.emit_recovery_metrics(0, &mut path, now, group);
    recorder.flush().await.unwrap();
    assert_eq!(
        trace.records().len(),
        1,
        "the initial snapshot was filtered out"
    );
    assert_eq!(recorder.stats().submitted_events, 0);
    generation.store(1, Ordering::Release);
    sink.emit_recovery_metrics(0, &mut path, now, group);
    recorder.flush().await.unwrap();
    let records = trace.records();
    assert_eq!(records.len(), 2);
    assert!(records[1]["data"].get("smoothed_rtt").is_some());
    assert!(records[1]["data"].get("congestion_window").is_some());
    sink.emit_recovery_metrics(0, &mut path, now, group);
    recorder.flush().await.unwrap();
    assert_eq!(
        trace.records().len(),
        2,
        "unchanged metrics are suppressed after the fresh snapshot"
    );
    recorder.set_enabled(false);
    recorder.set_enabled(true);
    sink.emit_recovery_metrics(0, &mut path, now, group);
    recorder.shutdown().await.unwrap();
    assert_eq!(
        trace.records().len(),
        3,
        "the filter also propagates its recorder's generation"
    );
}

#[test]
fn post_build_recovery_snapshot_rejection_retries_complete_snapshot() {
    use crate::qlog::{EventSchema, NamedQlogEventView, QlogEventView, QlogSink};

    #[derive(Default)]
    struct RejectFirst(Mutex<Vec<Value>>);

    impl QlogSink for RejectFirst {
        fn emit_named(&self, _event: &NamedQlogEventView<'_>) {}

        fn accepts_named(&self, _schema: &EventSchema) -> bool {
            false
        }

        fn emit(&self, event: &QlogEventView<'_>) -> bool {
            let mut attempts = self.0.lock();
            attempts.push(serde_json::to_value(&event.fields).unwrap());
            attempts.len() != 1
        }
    }

    let output = Arc::new(RejectFirst::default());
    let sink = ConnectionQlog::from_sink(Some(output.clone()));
    let now = Instant::now();
    let group = ConnectionId::new(&[1]);
    let mut path = PathData::new(
        SocketAddr::from((Ipv4Addr::LOCALHOST, 443)),
        None,
        false,
        None,
        0,
        now,
        &crate::TransportConfig::default(),
    );
    sink.emit_recovery_metrics(0, &mut path, now, group);
    assert_eq!(
        output.0.lock().len(),
        1,
        "rejection happened after building the event"
    );
    sink.emit_recovery_metrics(0, &mut path, now, group);
    {
        let attempts = output.0.lock();
        assert_eq!(
            attempts.len(),
            2,
            "unchanged metrics must retry after rejection"
        );
        assert_eq!(
            attempts[0], attempts[1],
            "retry retains the complete snapshot"
        );
        for field in [
            "min_rtt",
            "smoothed_rtt",
            "latest_rtt",
            "rtt_variance",
            "pto_count",
            "bytes_in_flight",
            "congestion_window",
        ] {
            assert!(attempts[1]["data"].get(field).is_some(), "missing {field}");
        }
    }
    sink.emit_recovery_metrics(0, &mut path, now, group);
    assert_eq!(
        output.0.lock().len(),
        2,
        "accepted unchanged metrics remain suppressed"
    );
}

#[cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
#[tokio::test]
async fn migration_with_unusable_fallback_does_not_log_abandonment() {
    use crate::proto::connection::migration::{PrevCid, PreviousPath};

    let mut pair = crate::proto::tests::util::Pair::default();
    let (client, _) = pair.connect();
    let now = pair.time;
    let trace = Trace::default();
    let recorder = crate::qlog::QlogConfig::default()
        .with_writer(Box::new(trace.clone()))
        .start()
        .unwrap();
    let connection = pair.client_conn_mut(client);
    connection.qlog_sink = ConnectionQlog::from(Some(recorder.clone()));
    let moved_to = SocketAddr::from(([127, 0, 0, 7], 443));
    connection.migrate(now, moved_to, None, PreviousPath::Keep(PrevCid::Gone));
    assert!(connection.prev_path.is_some());
    while connection.rem_cids.next().is_some() {}

    assert!(!connection.abandon_current_path(now));
    assert_eq!(connection.remote_address(), moved_to);
    assert!(!connection.is_closed());
    recorder.shutdown().await.unwrap();
    let migrations: Vec<_> = trace
        .records()
        .into_iter()
        .filter(|event| event["name"] == "quic:migration_state_updated")
        .collect();
    assert_eq!(
        migrations.len(),
        1,
        "an unusable fallback cannot replace the path"
    );
    assert_eq!(migrations[0]["data"]["new"], "migration_started");
}
