use super::*;
use crate::{
    proto::ConnectionQlog,
    qlog::{
        QlogConfig, ReferenceJsonEncoder, TraceInfo,
        event::{
            EventView,
            negotiation::{AlpnIdentifierView, HexView, NegotiationEventView},
        },
    },
};
use rama_quic_proto::ConnectionId;
use std::assert_matches;
use std::{
    borrow::Cow,
    io::{self, Write},
    sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    time::Instant,
};

struct Inspect {
    address: usize,
    caller: std::thread::ThreadId,
    calls: AtomicUsize,
    enabled: AtomicBool,
    accepted: bool,
    generation: AtomicU64,
}

impl Inspect {
    fn new(bytes: &[u8], accepted: bool) -> Self {
        Self {
            address: bytes.as_ptr() as usize,
            caller: std::thread::current().id(),
            calls: AtomicUsize::new(0),
            enabled: AtomicBool::new(true),
            accepted,
            generation: AtomicU64::new(0),
        }
    }
}

impl QlogSink for Inspect {
    fn emit_named(&self, _event: &NamedQlogEventView<'_>) {}

    fn accepts_named(&self, _schema: &EventSchema) -> bool {
        false
    }

    fn is_enabled(&self) -> bool {
        self.enabled.load(Ordering::Relaxed)
    }

    fn generation(&self) -> u64 {
        self.generation.load(Ordering::Relaxed)
    }

    fn emit(&self, event: &QlogEventView<'_>) -> bool {
        assert_eq!(std::thread::current().id(), self.caller);
        let EventView::Negotiation(NegotiationEventView::AlpnInformation { chosen_alpn }) =
            &event.fields.event
        else {
            panic!("unexpected observation")
        };
        assert_matches!(chosen_alpn.byte_value.0, Cow::Borrowed(_));
        assert_eq!(chosen_alpn.byte_value.0.as_ptr() as usize, self.address);
        assert_eq!(event.fields.heap_size(), 0);
        self.calls.fetch_add(1, Ordering::Relaxed);
        self.accepted
    }
}

fn alpn(bytes: &[u8]) -> NegotiationEventView<'_> {
    NegotiationEventView::AlpnInformation {
        chosen_alpn: AlpnIdentifierView {
            byte_value: HexView(Cow::Borrowed(bytes)),
        },
    }
}

#[test]
fn connection_sink_receives_original_borrow_on_calling_thread() {
    let bytes = [0, 0xff, b'q'];
    let observer = Arc::new(Inspect::new(&bytes, true));
    let group = ConnectionId::new(&[4]);
    let sink = ConnectionQlog::from_sink(Some(observer.clone())).for_connection(group);
    assert!(sink.emit(group, Instant::now(), || alpn(&bytes)));
    assert_eq!(observer.calls.load(Ordering::Relaxed), 1);
    let control = sink.control().unwrap();
    assert_eq!(control.group_id(), group);
    assert!(control.recorder().is_none());
    control.set_enabled(false);
    assert!(
        !sink.emit(group, Instant::now(), || -> NegotiationEventView<'_> {
            panic!("disabled view must not be built")
        })
    );
    control.set_enabled(true);
    observer.enabled.store(false, Ordering::Relaxed);
    assert!(
        !sink.emit(group, Instant::now(), || -> NegotiationEventView<'_> {
            panic!("disabled observer must not build a view")
        })
    );
}

#[test]
fn sink_with_default_gate_receives_events_and_honors_connection_control() {
    struct Counter(AtomicUsize);

    impl QlogSink for Counter {
        fn emit_named(&self, _event: &NamedQlogEventView<'_>) {}

        fn accepts_named(&self, _schema: &EventSchema) -> bool {
            false
        }

        fn emit(&self, _event: &QlogEventView<'_>) -> bool {
            self.0.fetch_add(1, Ordering::Relaxed);
            true
        }
    }

    let observer = Arc::new(Counter(AtomicUsize::new(0)));
    let group = ConnectionId::new(&[7]);
    let sink = ConnectionQlog::from_sink(Some(observer.clone())).for_connection(group);
    assert!(sink.emit(group, Instant::now(), || alpn(b"first")));
    assert_eq!(observer.0.load(Ordering::Relaxed), 1);

    let control = sink.control().unwrap();
    control.set_enabled(false);
    assert!(
        !sink.emit(group, Instant::now(), || -> NegotiationEventView<'_> {
            panic!("disabled connection must not construct an observation")
        })
    );
    assert_eq!(observer.0.load(Ordering::Relaxed), 1);

    control.set_enabled(true);
    assert!(sink.emit(group, Instant::now(), || alpn(b"resumed")));
    assert_eq!(observer.0.load(Ordering::Relaxed), 2);
}

#[test]
fn closure_filter_delivers_selected_borrows_and_propagates_rejection() {
    let bytes = b"selected";
    let observer = Arc::new(Inspect::new(bytes, false));
    let selected = ConnectionId::new(&[7]);
    let filtered = observer
        .clone()
        .filtered(move |event| event.group_id == selected);
    let sink = ConnectionQlog::from_sink(Some(Arc::new(filtered)));

    assert!(sink.emit(ConnectionId::new(&[8]), Instant::now(), || alpn(bytes)));
    assert_eq!(observer.calls.load(Ordering::Relaxed), 0);
    assert!(!sink.emit(selected, Instant::now(), || alpn(bytes)));
    assert_eq!(observer.calls.load(Ordering::Relaxed), 1);
}

#[test]
fn borrowed_filter_and_fanout_deliver_without_short_circuiting_rejections() {
    let bytes = b"rama";
    let rejecting = Arc::new(Inspect::new(bytes, false));
    let accepting = Arc::new(Inspect::new(bytes, true));
    let pair = (rejecting.clone(), accepting.clone());
    let event = QlogEventView {
        group_id: ConnectionId::new(&[]),
        time: Instant::now(),
        fields: alpn(bytes).into(),
    };
    assert!(!pair.emit(&event));
    assert_eq!(rejecting.calls.load(Ordering::Relaxed), 1);
    assert_eq!(accepting.calls.load(Ordering::Relaxed), 1);
    rejecting.enabled.store(false, Ordering::Relaxed);
    assert!(pair.emit(&event));
    assert_eq!(rejecting.calls.load(Ordering::Relaxed), 1);
    assert_eq!(accepting.calls.load(Ordering::Relaxed), 2);
    rejecting.generation.store(2, Ordering::Relaxed);
    accepting.generation.store(3, Ordering::Relaxed);
    assert_eq!(pair.generation(), 5);
    let filtered = pair.filtered(|event| !event.group_id.is_empty());
    assert!(filtered.emit(&event));
    assert_eq!(accepting.calls.load(Ordering::Relaxed), 2);
    assert_eq!(filtered.generation(), 5);
    assert!(filtered.is_enabled());
    accepting.enabled.store(false, Ordering::Relaxed);
    assert!(!filtered.is_enabled());
}

struct FixedOutput {
    bytes: [u8; 512],
    len: usize,
}

impl Write for FixedOutput {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let len = bytes.len().min(self.bytes.len() - self.len);
        self.bytes[self.len..self.len + len].copy_from_slice(&bytes[..len]);
        self.len += len;
        Ok(len)
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[test]
fn borrowed_event_can_be_encoded_directly_into_fixed_storage() {
    let bytes = [0, 0xff];
    let now = Instant::now();
    let event = QlogEventView {
        group_id: ConnectionId::new(&[0xab]),
        time: now,
        fields: alpn(&bytes).into(),
    };
    let mut output = FixedOutput {
        bytes: [0; 512],
        len: 0,
    };
    ReferenceJsonEncoder::event(
        &TraceInfo {
            event_schemas: &[],
            title: None,
            description: None,
            start_time: now,
        },
        &event,
        &mut output,
    )
    .unwrap();
    assert_eq!(output.bytes[0], 0x1e);
    let record: serde_json::Value = serde_json::from_slice(&output.bytes[1..output.len]).unwrap();
    assert_eq!(record["group_id"], "ab");
    assert_eq!(record["data"]["chosen_alpn"]["byte_value"], "00ff");
    assert_eq!(event.fields.heap_size(), 0);
}

#[derive(Clone, Default)]
struct Output(Arc<parking_lot::Mutex<Vec<u8>>>);

impl tokio::io::AsyncWrite for Output {
    fn poll_write(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
        bytes: &[u8],
    ) -> std::task::Poll<io::Result<usize>> {
        self.0.lock().extend_from_slice(bytes);
        std::task::Poll::Ready(Ok(bytes.len()))
    }

    fn poll_flush(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<io::Result<()>> {
        std::task::Poll::Ready(Ok(()))
    }

    fn poll_shutdown(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<io::Result<()>> {
        std::task::Poll::Ready(Ok(()))
    }
}

#[tokio::test]
async fn composed_recorder_owns_borrowed_data_only_for_background_output() {
    let output = Output::default();
    let recorder = QlogConfig::default()
        .with_writer(output.clone())
        .start()
        .unwrap();
    let mut bytes = [0, 0xff];
    let observer = Arc::new(Inspect::new(&bytes, true));
    let sink = ConnectionQlog::from_sink(Some(Arc::new((observer.clone(), recorder.clone()))));
    assert!(sink.emit(ConnectionId::new(&[1]), Instant::now(), || alpn(&bytes)));
    bytes.fill(42);
    recorder.flush().await.unwrap();
    let buffer = output.0.lock().clone();
    let records: Vec<serde_json::Value> = buffer
        .split(|b| *b == 0x1e)
        .filter(|record| !record.is_empty())
        .map(|record| serde_json::from_slice(record).unwrap())
        .collect();
    assert_eq!(records[1]["data"]["chosen_alpn"]["byte_value"], "00ff");
    assert_eq!(observer.calls.load(Ordering::Relaxed), 1);
    let control = sink.control().unwrap();
    let old = control.generation();
    recorder.set_enabled(false);
    recorder.set_enabled(true);
    assert_ne!(control.generation(), old);
    recorder.shutdown().await.unwrap();
}

#[test]
fn inline_sink_encodes_borrowed_events_in_local_stack_storage() {
    struct InlineJson(AtomicUsize);

    impl QlogSink for InlineJson {
        fn emit_named(&self, _event: &NamedQlogEventView<'_>) {}

        fn accepts_named(&self, _schema: &EventSchema) -> bool {
            false
        }

        fn emit(&self, event: &QlogEventView<'_>) -> bool {
            let mut output = FixedOutput {
                bytes: [0; 512],
                len: 0,
            };
            ReferenceJsonEncoder::event(
                &TraceInfo {
                    event_schemas: &[],
                    title: None,
                    description: None,
                    start_time: event.time,
                },
                event,
                &mut output,
            )
            .unwrap();
            let record: serde_json::Value =
                serde_json::from_slice(&output.bytes[1..output.len]).unwrap();
            assert_eq!(record["data"]["chosen_alpn"]["byte_value"], "74657374");
            assert_eq!(event.fields.heap_size(), 0);
            self.0.fetch_add(1, Ordering::Relaxed);
            true
        }
    }
    let bytes = *b"test";
    let sink = InlineJson(AtomicUsize::new(0));
    let view = QlogEventView {
        group_id: ConnectionId::new(&[]),
        time: Instant::now(),
        fields: alpn(&bytes).into(),
    };
    assert!(sink.emit(&view));
    assert_eq!(sink.0.load(Ordering::Relaxed), 1);
}
