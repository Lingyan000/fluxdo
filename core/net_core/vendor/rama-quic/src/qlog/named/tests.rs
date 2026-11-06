use super::*;
use crate::qlog::{
    ConnectionQlogControl, HistoryConfig, QlogConfig, QlogEventView, QlogSink, QueueLimits, reader,
    schema, sink::Filtered,
};
use parking_lot::Mutex;
use serde_json::{Value, json};
use std::{
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
    time::Duration,
};
use tokio::io::AsyncWrite;

static APP: EventSchema = EventSchema::new("urn:example:qlog:app-1", "app");
static OTHER: EventSchema = EventSchema::new("urn:example:qlog:other-1", "other");
static SCHEMAS: &[EventSchema] = &[APP];

#[derive(Clone, Default)]
struct Buffer(Arc<Mutex<Vec<u8>>>);

impl Buffer {
    fn records(&self) -> Vec<Value> {
        String::from_utf8(self.0.lock().clone())
            .unwrap()
            .split('\x1e')
            .filter(|record| !record.is_empty())
            .map(|record| serde_json::from_str(record).unwrap())
            .collect()
    }
}

impl AsyncWrite for Buffer {
    fn poll_write(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        self.0.lock().extend_from_slice(bytes);
        Poll::Ready(Ok(bytes.len()))
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

#[derive(Serialize)]
struct Data {
    stream_id: u64,
}

fn must_not_build() -> Data {
    panic!("named event data built while it cannot be recorded")
}

#[tokio::test]
async fn named_events_are_written_under_declared_schemas() {
    let buffer = Buffer::default();
    let recorder = QlogConfig::default()
        .with_writer(buffer.clone())
        .with_event_schemas(SCHEMAS)
        .start()
        .unwrap();
    let control = recorder.connection(ConnectionId::new(&[7]));
    control.emit_named(&APP, "app:frame_parsed", || Data { stream_id: 4 });
    recorder.shutdown().await.unwrap();

    let records = buffer.records();
    assert_eq!(
        records[0]["trace"]["event_schemas"],
        json!([schema::EVENT_SCHEMA_QUIC, APP.id()])
    );
    assert_eq!(records.len(), 2);
    assert_eq!(records[1]["name"], "app:frame_parsed");
    assert_eq!(records[1]["group_id"], "07");
    assert_eq!(records[1]["data"], json!({ "stream_id": 4 }));
    let file = reader::read(&buffer.0.lock()).unwrap();
    assert_eq!(file.event_count(), 1);
}

#[tokio::test]
async fn unrecordable_named_events_are_never_built() {
    let recorder = QlogConfig::default()
        .with_writer(Buffer::default())
        .with_event_schemas(SCHEMAS)
        .start()
        .unwrap();
    let control = recorder.connection(ConnectionId::new(&[1]));
    control.emit_named(&OTHER, "other:event", must_not_build);
    let composed =
        ConnectionQlogControl::from_sink(Arc::new(recorder.clone()), ConnectionId::new(&[2]));
    composed.emit_named(&OTHER, "other:event", must_not_build);
    control.set_enabled(false);
    control.emit_named(&APP, "app:event", must_not_build);
    control.set_enabled(true);
    recorder.set_enabled(false);
    control.emit_named(&APP, "app:event", must_not_build);
    recorder.shutdown().await.unwrap();
    assert_eq!(recorder.stats().submitted_events, 0);
}

#[tokio::test]
async fn invalid_named_data_is_dropped_without_failing_the_recorder() {
    let buffer = Buffer::default();
    let recorder = QlogConfig::default()
        .with_writer(buffer.clone())
        .with_event_schemas(SCHEMAS)
        .with_queue_limits(QueueLimits {
            max_event_bytes: kib(1),
            ..QueueLimits::default()
        })
        .start()
        .unwrap();
    let control = recorder.connection(ConnectionId::new(&[1]));
    control.emit_named(
        &APP,
        "app:oversized",
        || json!({ "padding": "x".repeat(kib(2)) }),
    );
    control.emit_named(&APP, "app:scalar", || 1);
    control.emit_named(&APP, "other:misnamed", || Data { stream_id: 0 });
    control.emit_named(&APP, "app:kept", || Data { stream_id: 8 });
    recorder.shutdown().await.unwrap();

    let stats = recorder.stats();
    assert_eq!(stats.submitted_events, 1);
    assert_eq!(stats.dropped_events, 3);
    assert_eq!(stats.oversized_events, 1);
    assert_eq!(stats.queued_bytes, 0);
    let records = buffer.records();
    assert_eq!(records.len(), 2);
    assert_eq!(records[1]["name"], "app:kept");
}

#[tokio::test]
async fn named_history_dumps_per_connection() {
    let buffer = Buffer::default();
    let recorder = QlogConfig::default()
        .with_writer(buffer.clone())
        .with_event_schemas(SCHEMAS)
        .with_history(HistoryConfig {
            window: Duration::from_mins(1),
            max_bytes: kib(8),
        })
        .start()
        .unwrap();
    let first = recorder.connection(ConnectionId::new(&[1]));
    let second = recorder.connection(ConnectionId::new(&[2]));
    first.emit_named(&APP, "app:event", || Data { stream_id: 0 });
    second.emit_named(&APP, "app:event", || Data { stream_id: 4 });
    first.dump_recent().await.unwrap();
    assert_eq!(recorder.stats().history_events, 1);
    recorder.shutdown().await.unwrap();

    let records = buffer.records();
    assert_eq!(records.len(), 2);
    assert_eq!(records[1]["group_id"], "01");
    assert_eq!(records[1]["data"], json!({ "stream_id": 0 }));
}

#[test]
fn invalid_schema_declarations_fail_start() {
    static DUPLICATE: &[EventSchema] = &[APP, EventSchema::new("urn:example:qlog:app-2", "app")];
    static QUIC: &[EventSchema] = &[EventSchema::new("urn:example:quic", "quic")];
    static EMPTY: &[EventSchema] = &[EventSchema::new("", "app")];
    let runtime = tokio::runtime::Builder::new_current_thread()
        .build()
        .unwrap();
    let _guard = runtime.enter();
    for schemas in [DUPLICATE, QUIC, EMPTY] {
        let error = QlogConfig::default()
            .with_writer(Buffer::default())
            .with_event_schemas(schemas)
            .start()
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
    }
}

#[derive(Clone, Default)]
struct Collect(Arc<Mutex<Vec<(&'static str, Box<[u8]>)>>>);

impl QlogSink for Collect {
    fn emit(&self, _event: &QlogEventView<'_>) -> bool {
        true
    }

    fn accepts_named(&self, _schema: &EventSchema) -> bool {
        true
    }

    fn emit_named(&self, event: &NamedQlogEventView<'_>) {
        self.0.lock().push((event.name(), event.data().into()));
    }
}

#[test]
fn sinks_receive_encoded_named_events_but_typed_filters_drop_them() {
    let direct = Collect::default();
    let filtered = Collect::default();
    let sink: (Collect, Filtered<Collect, _>) = (
        direct.clone(),
        filtered.clone().filtered(|_: &QlogEventView<'_>| true),
    );
    let control = ConnectionQlogControl::from_sink(Arc::new(sink), ConnectionId::new(&[1]));
    control.emit_named(&APP, "app:event", || Data { stream_id: 12 });
    assert_eq!(
        direct.0.lock().as_slice(),
        [("app:event", Box::from(&b"{\"stream_id\":12}"[..]))]
    );
    assert!(filtered.0.lock().is_empty());
    control.emit_named(
        &APP,
        "app:oversized",
        || json!({ "padding": "x".repeat(MAX_DATA_BYTES) }),
    );
    assert_eq!(direct.0.lock().len(), 1);
}

#[test]
fn sinks_rejecting_named_events_never_build_them() {
    let filtered = Collect::default().filtered(|_: &QlogEventView<'_>| true);
    let control = ConnectionQlogControl::from_sink(Arc::new(filtered), ConnectionId::new(&[1]));
    control.emit_named(&APP, "app:event", must_not_build);
}

#[test]
fn schemas_with_a_colon_in_their_namespace_are_refused() {
    static COLON: EventSchema = EventSchema::new("urn:example:qlog:colon-1", "app:sub");
    validate_schemas(&[APP, OTHER]).unwrap();
    assert_eq!(
        validate_schemas(&[COLON]).unwrap_err().kind(),
        io::ErrorKind::InvalidInput
    );
}
