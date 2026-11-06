//! Reproducible release microbenchmarks for private recorder admission and worker output.
//!
//! Run from the workspace root:
//! `cargo test -p rama-quic --lib --release --no-default-features --features rustls,ring \
//! qlog::recorder::benches::qlog_performance -- --ignored --exact --nocapture --test-threads=1`
//!
//! These are measurements, not timing assertions. Each case has one warmup and five measured
//! samples. Startup and shutdown are excluded; output cases include admission and final flush.
//! The writer consumes JSON bytes without filesystem I/O. File/device throughput depends on
//! the destination and must be measured separately. The direct baseline uses the same owned
//! event schema and encoder, not the historical inline implementation. Run on an otherwise idle machine.
//!
//! Register these measurements only when debug assertions are disabled. Debug CI runs
//! ignored tests too; the public allocation benchmarks live in `benches/quic_qlog.rs`.

#![cfg(not(debug_assertions))]

use std::{
    borrow::Cow,
    hint::black_box,
    io::{self, Write},
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    task::{Context, Poll},
    time::{Duration, Instant},
};

use rama_utils::octets;
use tokio::{io::AsyncWrite, sync::Notify};

use super::{History, QlogRecorder, RecorderStats};
use rama_quic_proto::ConnectionId;

use crate::proto::ConnectionQlog;
use crate::qlog::{
    EncodedWriter, EventSchema, HistoryConfig, JsonSeqEncoder, NamedQlogEventView, QlogConfig,
    QlogEvent, QlogEventView, QlogOutput, QlogSink, QueueLimits, ReferenceJsonEncoder, TraceInfo,
    event::{
        EventFields, EventFieldsView, EventView, NegotiationEvent, NegotiationEventView,
        PacketEvent,
        negotiation::{AlpnIdentifier, AlpnIdentifierView, HexView},
        packet::{Packet, PacketHeader, PacketType, RawInfo},
    },
};

const SAMPLES: usize = 5;
const ADMISSION_EVENTS: usize = 8_192;
const OUTPUT_EVENTS: usize = 20_000;

#[derive(Clone, Copy)]
enum Fixture {
    Packet,
    Negotiation,
}

impl Fixture {
    fn event(self, number: u64) -> EventFields {
        match self {
            Self::Packet => PacketEvent::PacketSent(Packet {
                header: PacketHeader {
                    packet_type: PacketType::OneRtt,
                    packet_number: black_box(number),
                },
                raw: Some(RawInfo { length: 1200 }),
                is_mtu_probe_packet: Some(false),
            })
            .into(),
            Self::Negotiation => NegotiationEvent::AlpnInformation {
                chosen_alpn: AlpnIdentifier {
                    byte_value: HexView(Cow::Owned(black_box(b"rama-quic-benchmark/1").to_vec())),
                },
            }
            .into(),
        }
    }
}

impl Fixture {
    fn view(self, number: u64, alpn: &[u8]) -> EventFieldsView<'_> {
        match self {
            Self::Packet => self.event(number),
            Self::Negotiation => NegotiationEventView::AlpnInformation {
                chosen_alpn: AlpnIdentifierView {
                    byte_value: HexView(Cow::Borrowed(alpn)),
                },
            }
            .into(),
        }
    }
}

struct Measurement {
    elapsed: Duration,
    attempts: usize,
    submitted: u64,
    dropped: u64,
    bytes: u64,
}

fn report(name: &str, mut run: impl FnMut() -> Measurement) {
    black_box(run());
    let mut samples = Vec::with_capacity(SAMPLES);
    for _ in 0..SAMPLES {
        samples.push(run());
    }
    samples.sort_by_key(|sample| sample.elapsed);
    let middle = &samples[SAMPLES / 2];
    let ns = |sample: &Measurement| sample.elapsed.as_nanos() as f64 / sample.attempts as f64;
    eprintln!(
        "{name}: median={:.1} ns/attempt min={:.1} max={:.1}; {:.0} attempts/s; submitted={} dropped={} bytes={} (per sample)",
        ns(middle),
        ns(&samples[0]),
        ns(&samples[SAMPLES - 1]),
        middle.attempts as f64 / middle.elapsed.as_secs_f64(),
        middle.submitted,
        middle.dropped,
        middle.bytes,
    );
}

fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .build()
        .unwrap()
}

fn limits(events: usize) -> QueueLimits {
    QueueLimits {
        max_queued_events: events,
        max_queued_bytes: octets::mib(64),
        max_event_bytes: octets::kib(1),
    }
}

fn group() -> ConnectionId {
    ConnectionId::new(black_box(b"qlogperf"))
}

/// Initialization waits at a barrier so admission measurements cannot accidentally become
/// concurrent draining or dropped-event measurements.
struct ParkedOutput {
    ready: Arc<Notify>,
    release: Arc<Notify>,
    events: Arc<AtomicU64>,
}

impl QlogOutput for ParkedOutput {
    async fn named_event(&mut self, _event: &NamedQlogEventView<'_>) -> io::Result<()> {
        Ok(())
    }

    async fn begin(&mut self, _info: &TraceInfo) -> io::Result<()> {
        self.ready.notify_one();
        self.release.notified().await;
        Ok(())
    }

    async fn event(&mut self, event: &QlogEventView<'_>) -> io::Result<()> {
        black_box(event);
        self.events.fetch_add(1, Ordering::Relaxed);
        Ok(())
    }

    async fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn parked(
    runtime: &tokio::runtime::Runtime,
    events: usize,
) -> (QlogRecorder, Arc<Notify>, Arc<AtomicU64>) {
    let ready = Arc::new(Notify::new());
    let release = Arc::new(Notify::new());
    let count = Arc::new(AtomicU64::new(0));
    let recorder = runtime.block_on(async {
        QlogConfig::default()
            .with_queue_limits(limits(events))
            .with_output(ParkedOutput {
                ready: ready.clone(),
                release: release.clone(),
                events: count.clone(),
            })
            .start()
            .unwrap()
    });
    runtime.block_on(ready.notified());
    (recorder, release, count)
}

fn assert_drained(stats: RecorderStats, expected: usize) {
    assert_eq!(stats.submitted_events, expected as u64);
    assert_eq!(stats.dropped_events, 0);
    assert_eq!(stats.oversized_events, 0);
    assert_eq!(stats.queued_events, 0);
    assert_eq!(stats.queued_bytes, 0);
}

#[derive(Clone, Copy)]
enum GateCase {
    ConnectionDisabled,
    RecorderDisabled,
    Saturated,
}

fn gate_case(case: GateCase) -> Measurement {
    let saturated = matches!(case, GateCase::Saturated);
    let runtime = runtime();
    let (recorder, release, count) = parked(&runtime, 1);
    let group = group();
    let now = Instant::now();
    let control = recorder.connection(group);
    if saturated {
        recorder.emit(group, now, || Some(Fixture::Packet.event(0)));
        assert_eq!(recorder.stats().queued_events, 1);
    } else if matches!(case, GateCase::RecorderDisabled) {
        recorder.set_enabled(false);
    } else {
        control.set_enabled(false);
    }
    let attempts = 500_000;
    let mut built = 0usize;
    let start = Instant::now();
    for number in 0..attempts {
        black_box(&control).emit(group, now, || {
            built += 1;
            Some(Fixture::Negotiation.event(number as u64))
        });
    }
    let elapsed = start.elapsed();
    assert_eq!(
        built, 0,
        "disabled/full admission must skip event construction"
    );
    let stats = recorder.stats();
    assert_eq!(
        stats.dropped_events,
        if saturated { attempts as u64 } else { 0 }
    );
    release.notify_one();
    runtime.block_on(recorder.shutdown()).unwrap();
    assert_eq!(count.load(Ordering::Relaxed), u64::from(saturated));
    Measurement {
        elapsed,
        attempts,
        submitted: 0,
        dropped: stats.dropped_events,
        bytes: 0,
    }
}

fn admission_case(fixture: Fixture) -> Measurement {
    let runtime = runtime();
    let (recorder, release, count) = parked(&runtime, ADMISSION_EVENTS);
    let group = group();
    let control = recorder.connection(group);
    let now = Instant::now();
    let mut built = 0usize;
    let start = Instant::now();
    for number in 0..ADMISSION_EVENTS {
        black_box(&control).emit(group, now, || {
            built += 1;
            Some(fixture.event(number as u64))
        });
    }
    let elapsed = start.elapsed();
    let stats = recorder.stats();
    assert_eq!(built, ADMISSION_EVENTS);
    assert_eq!(stats.submitted_events, ADMISSION_EVENTS as u64);
    assert_eq!(stats.dropped_events, 0);
    release.notify_one();
    runtime.block_on(recorder.shutdown()).unwrap();
    assert_drained(recorder.stats(), ADMISSION_EVENTS);
    assert_eq!(count.load(Ordering::Relaxed), ADMISSION_EVENTS as u64);
    Measurement {
        elapsed,
        attempts: ADMISSION_EVENTS,
        submitted: stats.submitted_events,
        dropped: stats.dropped_events,
        bytes: 0,
    }
}

/// Consume the exact encoder output without allocating an ever-growing output buffer or
/// adding a shared atomic operation to every tiny serde write. Flush publishes byte totals.
struct CountingWriter {
    bytes: u64,
    published: Arc<AtomicU64>,
}

impl Write for CountingWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.bytes += black_box(bytes).len() as u64;
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        self.published.store(self.bytes, Ordering::Relaxed);
        Ok(())
    }
}

impl AsyncWrite for CountingWriter {
    fn poll_write(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        Poll::Ready(Write::write(self.get_mut(), bytes))
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Write::flush(self.get_mut()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.poll_flush(cx)
    }
}

fn output_case(fixture: Fixture, worker: bool) -> Measurement {
    let runtime = runtime();
    runtime.block_on(async {
        let group = group();
        let now = Instant::now();
        let info = TraceInfo {
            event_schemas: &[],
            title: None,
            description: None,
            start_time: now,
        };
        let bytes = Arc::new(AtomicU64::new(0));
        let writer = CountingWriter {
            bytes: 0,
            published: bytes.clone(),
        };
        let mut output = EncodedWriter::new(writer, JsonSeqEncoder);
        let (elapsed, stats, header_bytes) = if worker {
            let recorder = QlogConfig::default()
                .with_start_time(now)
                .with_output(output)
                .with_queue_limits(limits(OUTPUT_EVENTS))
                .start()
                .unwrap();
            recorder.flush().await.unwrap();
            let header_bytes = bytes.load(Ordering::Relaxed);
            let control = recorder.connection(group);
            let start = Instant::now();
            for number in 0..OUTPUT_EVENTS {
                black_box(&control).emit(group, now, || Some(fixture.event(number as u64)));
            }
            recorder.flush().await.unwrap();
            let elapsed = start.elapsed();
            let stats = recorder.stats();
            assert_drained(stats, OUTPUT_EVENTS);
            recorder.shutdown().await.unwrap();
            (elapsed, Some(stats), header_bytes)
        } else {
            output.begin(&info).await.unwrap();
            output.flush().await.unwrap();
            let header_bytes = bytes.load(Ordering::Relaxed);
            let start = Instant::now();
            for number in 0..OUTPUT_EVENTS {
                let event = QlogEvent {
                    group_id: group,
                    time: now,
                    fields: fixture.event(number as u64),
                };
                output.event(black_box(&event)).await.unwrap();
            }
            output.flush().await.unwrap();
            let elapsed = start.elapsed();
            output.finish().await.unwrap();
            (elapsed, None, header_bytes)
        };
        let output_bytes = bytes.load(Ordering::Relaxed) - header_bytes;
        assert!(output_bytes > OUTPUT_EVENTS as u64);
        Measurement {
            elapsed,
            attempts: OUTPUT_EVENTS,
            submitted: stats.map_or(OUTPUT_EVENTS as u64, |stats| stats.submitted_events),
            dropped: stats.map_or(0, |stats| stats.dropped_events),
            bytes: output_bytes,
        }
    })
}

fn history_case() -> Measurement {
    let runtime = runtime();
    let _entered = runtime.enter();
    let group = group();
    let now = Instant::now();
    let bytes = Arc::new(AtomicU64::new(0));
    let recorder = QlogConfig::default()
        .with_start_time(now)
        .with_writer(CountingWriter {
            bytes: 0,
            published: bytes.clone(),
        })
        .with_queue_limits(limits(OUTPUT_EVENTS))
        .with_history(HistoryConfig {
            window: Duration::from_secs(60),
            max_bytes: octets::mib(16),
        })
        .start()
        .unwrap();
    runtime.block_on(recorder.flush()).unwrap();
    let header_bytes = bytes.load(Ordering::Relaxed);
    let control = recorder.connection(group);
    let start = Instant::now();
    for number in 0..OUTPUT_EVENTS {
        black_box(&control).emit(group, now, || Some(Fixture::Packet.event(number as u64)));
    }
    runtime.block_on(recorder.flush()).unwrap();
    let elapsed = start.elapsed();
    let stats = recorder.stats();
    assert_drained(stats, OUTPUT_EVENTS);
    assert_eq!(stats.history_events, OUTPUT_EVENTS);
    assert_eq!(bytes.load(Ordering::Relaxed), header_bytes);
    // Dump is outside the retention timer and verifies the retained observations are usable.
    runtime.block_on(control.dump_recent()).unwrap();
    assert!(bytes.load(Ordering::Relaxed) > header_bytes + OUTPUT_EVENTS as u64);
    runtime.block_on(recorder.shutdown()).unwrap();
    Measurement {
        elapsed,
        attempts: OUTPUT_EVENTS,
        submitted: stats.submitted_events,
        dropped: stats.dropped_events,
        bytes: 0,
    }
}

struct InlineCounter {
    count: AtomicU64,
    expected_alpn: usize,
}

impl QlogSink for InlineCounter {
    fn emit_named(&self, _event: &NamedQlogEventView<'_>) {}

    fn accepts_named(&self, _schema: &EventSchema) -> bool {
        false
    }

    fn emit(&self, event: &QlogEventView<'_>) -> bool {
        if let EventView::Negotiation(NegotiationEventView::AlpnInformation { chosen_alpn }) =
            &event.fields.event
        {
            assert_eq!(
                chosen_alpn.byte_value.0.as_ptr() as usize,
                self.expected_alpn
            );
        }
        black_box(event);
        self.count.fetch_add(1, Ordering::Relaxed);
        true
    }
}

struct InlineBytes {
    count: u64,
}

impl Write for InlineBytes {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.count += black_box(bytes).len() as u64;
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

struct InlineJson {
    info: TraceInfo,
    count: AtomicU64,
    bytes: AtomicU64,
}

impl QlogSink for InlineJson {
    fn emit_named(&self, _event: &NamedQlogEventView<'_>) {}

    fn accepts_named(&self, _schema: &EventSchema) -> bool {
        false
    }

    fn emit(&self, event: &QlogEventView<'_>) -> bool {
        let mut output = InlineBytes { count: 0 };
        ReferenceJsonEncoder::event(&self.info, event, &mut output).unwrap();
        self.bytes.fetch_add(output.count, Ordering::Relaxed);
        self.count.fetch_add(1, Ordering::Relaxed);
        true
    }
}

fn inline_case(fixture: Fixture, json: bool) -> Measurement {
    let group = group();
    let now = Instant::now();
    let source = b"rama-quic-benchmark/1".to_vec();
    let counter = Arc::new(InlineCounter {
        count: AtomicU64::new(0),
        expected_alpn: source.as_ptr() as usize,
    });
    let encoder = Arc::new(InlineJson {
        info: TraceInfo {
            event_schemas: &[],
            title: None,
            description: None,
            start_time: now,
        },
        count: AtomicU64::new(0),
        bytes: AtomicU64::new(0),
    });
    let observer: Arc<dyn QlogSink> = if json {
        encoder.clone()
    } else {
        counter.clone()
    };
    let sink = ConnectionQlog::from_sink(Some(observer)).for_connection(group);
    let attempts = if json { OUTPUT_EVENTS } else { 500_000 };
    let start = Instant::now();
    for number in 0..attempts {
        assert!(black_box(&sink).emit(group, now, || fixture.view(number as u64, &source)));
    }
    let elapsed = start.elapsed();
    let count = if json {
        encoder.count.load(Ordering::Relaxed)
    } else {
        counter.count.load(Ordering::Relaxed)
    };
    assert_eq!(count, attempts as u64);
    Measurement {
        elapsed,
        attempts,
        submitted: count,
        dropped: 0,
        bytes: encoder.bytes.load(Ordering::Relaxed),
    }
}

fn borrowed_admission_case(fixture: Fixture) -> Measurement {
    let runtime = runtime();
    let (recorder, release, count) = parked(&runtime, ADMISSION_EVENTS);
    let group = group();
    let now = Instant::now();
    let source = b"rama-quic-benchmark/1".to_vec();
    let sink = ConnectionQlog::from_sink(Some(Arc::new(recorder.clone()))).for_connection(group);
    let start = Instant::now();
    for number in 0..ADMISSION_EVENTS {
        assert!(black_box(&sink).emit(group, now, || fixture.view(number as u64, &source)));
    }
    let elapsed = start.elapsed();
    let stats = recorder.stats();
    assert_eq!(stats.submitted_events, ADMISSION_EVENTS as u64);
    assert_eq!(stats.dropped_events, 0);
    release.notify_one();
    runtime.block_on(recorder.shutdown()).unwrap();
    assert_drained(recorder.stats(), ADMISSION_EVENTS);
    assert_eq!(count.load(Ordering::Relaxed), ADMISSION_EVENTS as u64);
    Measurement {
        elapsed,
        attempts: ADMISSION_EVENTS,
        submitted: stats.submitted_events,
        dropped: stats.dropped_events,
        bytes: 0,
    }
}

/// Isolate steady-state storage cost using ordered synthetic receipt timestamps. Every new
/// observation expires exactly one oldest entry, while 2,048 entries remain retained.
/// This deliberately excludes queue submission, worker scheduling, and JSON export.
fn history_expiry_case() -> Measurement {
    const RETAINED_EVENTS: usize = 2_048;
    let window = Duration::from_millis(RETAINED_EVENTS as u64);
    let mut history = History::new(HistoryConfig {
        window,
        max_bytes: octets::mib(16),
    });
    let group = group();
    let epoch = Instant::now();
    let event = |number: usize| QlogEvent {
        group_id: group,
        time: epoch,
        fields: Fixture::Packet.event(number as u64),
    };
    for number in 0..RETAINED_EVENTS {
        history.push(event(number), epoch + Duration::from_millis(number as u64));
    }
    let retained_bytes = history.bytes;
    let start = Instant::now();
    for number in RETAINED_EVENTS..RETAINED_EVENTS + OUTPUT_EVENTS {
        let observed = epoch + Duration::from_millis(black_box(number as u64));
        history.expire(observed);
        history.push(event(number), observed);
        black_box(&history);
    }
    let elapsed = start.elapsed();
    assert_eq!(history.events.len(), RETAINED_EVENTS);
    assert_eq!(history.bytes, retained_bytes);
    let oldest = history.events.front().unwrap();
    assert_eq!(
        oldest.observed,
        epoch + Duration::from_millis(OUTPUT_EVENTS as u64)
    );
    history
        .expire(epoch + Duration::from_millis((RETAINED_EVENTS + OUTPUT_EVENTS) as u64) + window);
    assert!(history.events.is_empty());
    assert_eq!(history.bytes, 0);
    Measurement {
        elapsed,
        attempts: OUTPUT_EVENTS,
        submitted: OUTPUT_EVENTS as u64,
        dropped: 0,
        bytes: 0,
    }
}

#[test]
#[ignore = "release microbenchmarks; run explicitly on an otherwise idle machine"]
fn qlog_performance() {
    eprintln!(
        "qlog release microbenchmarks: one warmup + {SAMPLES} samples; bytes consumed in memory, no disk I/O"
    );
    report("disabled connection gate", || {
        gate_case(GateCase::ConnectionDisabled)
    });
    report("disabled recorder gate", || {
        gate_case(GateCase::RecorderDisabled)
    });
    report("saturated admission (builder skipped)", || {
        gate_case(GateCase::Saturated)
    });
    report("packet admission (worker parked, zero drops)", || {
        admission_case(Fixture::Packet)
    });
    report(
        "allocated ALPN admission (worker parked, zero drops)",
        || admission_case(Fixture::Negotiation),
    );
    report(
        "packet rolling history (zero drops, no export in timer)",
        history_case,
    );
    report(
        "history expire+replace only (2,048 retained entries)",
        history_expiry_case,
    );
    for (fixture, label) in [
        (Fixture::Packet, "packet"),
        (Fixture::Negotiation, "allocated ALPN"),
    ] {
        report(&format!("{label} borrowed inline counter"), || {
            inline_case(fixture, false)
        });
        report(&format!("{label} borrowed inline Serde reference"), || {
            inline_case(fixture, true)
        });
        report(
            &format!("{label} borrowed sink -> owned admission (worker parked)"),
            || borrowed_admission_case(fixture),
        );
        let baseline = output_case(fixture, false);
        let inline = inline_case(fixture, true);
        assert_eq!(
            baseline.bytes, inline.bytes,
            "borrowed inline and owned direct JSON must match"
        );
        let queued = output_case(fixture, true);
        assert_eq!(
            baseline.bytes, queued.bytes,
            "direct and worker output must contain equivalent records"
        );
        report(&format!("{label} direct async JSON baseline"), || {
            output_case(fixture, false)
        });
        report(
            &format!("{label} worker JSON end-to-end (zero drops)"),
            || output_case(fixture, true),
        );
    }
}
