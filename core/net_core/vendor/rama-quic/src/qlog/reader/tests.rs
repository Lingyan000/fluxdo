use super::*;

/// Shaped exactly like what `rama-quic`'s JSON text-sequence encoder writes.
const SEQUENTIAL: &str = concat!(
    "\u{1e}{\"file_schema\":\"urn:ietf:params:qlog:file:sequential\",",
    "\"serialization_format\":\"application/qlog+json-seq\",\"title\":\"rama\",",
    "\"trace\":{\"title\":\"rama\",\"vantage_point\":{\"type\":\"client\"},",
    "\"event_schemas\":[\"urn:ietf:params:qlog:events:quic-13\"],",
    "\"common_fields\":{\"time_format\":\"relative_to_epoch\",",
    "\"reference_time\":{\"clock_type\":\"monotonic\",\"epoch\":\"unknown\"}}}}\n",
    "\u{1e}{\"time\":0.5,\"group_id\":\"c0ffee\",\"name\":\"quic:packet_sent\",",
    "\"data\":{\"header\":{\"packet_type\":\"initial\",\"packet_number\":0}}}\n",
    "\u{1e}{\"time\":12.25,\"group_id\":\"c0ffee\",\"tuple\":\"1\",",
    "\"name\":\"quic:packet_received\",\"data\":{\"raw\":{\"length\":1200}},",
    "\"trigger\":\"keys_available\"}\n",
    "\u{1e}{\"time\":30.0,\"group_id\":\"deadbeef\",\"name\":\"vendor:custom_event\",",
    "\"data\":{\"whatever\":true},\"unknown_member\":42}\n",
);

#[test]
fn reads_a_rama_written_json_text_sequence() {
    let file = read(SEQUENTIAL.as_bytes()).unwrap();
    assert_eq!(file.schema, FileSchema::Sequential);
    assert_eq!(file.title.as_deref(), Some("rama"));
    assert_eq!(file.traces.len(), 1);

    let trace = &file.traces[0];
    assert_eq!(trace.vantage_point.kind.as_deref(), Some("client"));
    assert_eq!(
        trace
            .event_schemas
            .iter()
            .map(ArcStr::as_str)
            .collect::<Vec<_>>(),
        ["urn:ietf:params:qlog:events:quic-13"],
    );
    assert_eq!(trace.clock_type.as_deref(), Some("monotonic"));
    // a monotonic reference with an unknown epoch stays unknown
    assert!(trace.epoch.is_none());

    assert_eq!(trace.events.len(), 3);
    assert!((trace.events[0].time_ms - 0.5).abs() < f64::EPSILON);
    assert_eq!(trace.events[0].name, "quic:packet_sent");
    assert_eq!(trace.events[0].group_id.as_deref(), Some("c0ffee"));
    assert_eq!(trace.events[1].path.as_deref(), Some("1"));
    assert_eq!(
        trace.events[1].data["raw"]["length"].as_u64(),
        Some(1200),
        "event data is preserved verbatim",
    );
    assert_eq!(file.event_count(), 3);
}

#[test]
fn unknown_events_and_members_are_preserved() {
    let file = read(SEQUENTIAL.as_bytes()).unwrap();
    let event = &file.traces[0].events[2];
    assert_eq!(event.name, "vendor:custom_event");
    assert_eq!(event.group_id.as_deref(), Some("deadbeef"));
    assert_eq!(event.data["whatever"], Value::Bool(true));
    assert_eq!(
        event.extra.get("unknown_member").and_then(Value::as_u64),
        Some(42)
    );
    // a known-but-unhandled member is kept too
    assert_eq!(
        file.traces[0].events[1]
            .extra
            .get("trigger")
            .and_then(Value::as_str),
        Some("keys_available"),
    );
}

#[test]
fn reads_a_contained_file_with_several_connection_groups() {
    let input = br#"{
        "file_schema": "urn:ietf:params:qlog:file:contained",
        "serialization_format": "application/qlog+json",
        "description": "two connections",
        "traces": [
            {
                "title": "client",
                "common_fields": {
                    "group_id": "aaaa",
                    "reference_time": {"clock_type": "system", "epoch": "2026-09-14T10:00:00Z"}
                },
                "events": [
                    {"time": 1.0, "name": "quic:connection_started", "data": {}},
                    {"time": 2.0, "name": "quic:packet_sent", "data": {}}
                ]
            },
            {
                "title": "server",
                "events": [{"time": 3.0, "group_id": "bbbb", "name": "quic:packet_received", "data": {}}]
            }
        ]
    }"#;

    let file = read(input).unwrap();
    assert_eq!(file.schema, FileSchema::Contained);
    assert_eq!(file.description.as_deref(), Some("two connections"));
    assert_eq!(file.traces.len(), 2);
    assert_eq!(file.event_count(), 3);

    let client = &file.traces[0];
    assert_eq!(client.title.as_deref(), Some("client"));
    assert_eq!(
        client.epoch.map(|epoch| epoch.to_string()),
        Some("2026-09-14T10:00:00Z".to_owned()),
    );
    // group_id from common_fields applies to every event of the trace
    assert!(
        client
            .events
            .iter()
            .all(|event| event.group_id.as_deref() == Some("aaaa"))
    );
    assert_eq!(
        file.traces[1].events[0].group_id.as_deref(),
        Some("bbbb"),
        "an event-level group_id is used as-is",
    );
}

#[test]
fn relative_event_times_accumulate() {
    let input = br#"{
        "file_schema": "urn:ietf:params:qlog:file:contained",
        "traces": [{
            "common_fields": {"time_format": "relative_to_previous_event"},
            "events": [
                {"time": 10.0, "name": "a:b", "data": {}},
                {"time": 5.0, "name": "a:b", "data": {}},
                {"time": 2.5, "name": "a:b", "data": {}}
            ]
        }]
    }"#;

    let file = read(input).unwrap();
    let times: Vec<f64> = file.traces[0]
        .events
        .iter()
        .map(|event| event.time_ms)
        .collect();
    assert_eq!(times, [10.0, 15.0, 17.5]);
}

#[test]
fn legacy_qlog_versions_are_rejected_by_name() {
    let input = br#"{"qlog_format": "JSON", "qlog_version": "0.3", "traces": []}"#;
    let error = read(input).unwrap_err().to_string();
    assert!(error.contains("legacy qlog version"), "error: {error}");
    assert!(error.contains("0.3"), "error: {error}");
}

#[test]
fn an_unknown_file_schema_is_reported_with_its_value() {
    let input = br#"{"file_schema": "urn:ietf:params:qlog:file:from-the-future", "traces": []}"#;
    let error = read(input).unwrap_err().to_string();
    assert!(
        error.contains("unsupported qlog file schema"),
        "error: {error}"
    );
    assert!(error.contains("from-the-future"), "error: {error}");
}

#[test]
fn json_without_a_file_schema_is_not_a_qlog_file() {
    let error = read(br#"{"log": {"entries": []}}"#)
        .unwrap_err()
        .to_string();
    assert!(error.contains("not a qlog file"), "error: {error}");
}

#[test]
fn truncated_and_malformed_input_is_reported_per_record() {
    let truncated = &SEQUENTIAL.as_bytes()[..SEQUENTIAL.len() - 40];
    let error = read(truncated).unwrap_err().to_string();
    assert!(error.contains("parse qlog event record"), "error: {error}");
    assert!(error.contains("event=\"2\""), "error: {error}");

    let error = read(
        b"\x1e{\"file_schema\":\"urn:ietf:params:qlog:file:sequential\"}\n\x1e{\"name\":\"a:b\"}\n",
    )
    .unwrap_err()
    .to_string();
    assert!(error.contains("misses its time"), "error: {error}");

    let error = read(b"not json at all").unwrap_err().to_string();
    assert!(error.contains("parse qlog JSON file"), "error: {error}");
}

#[test]
fn the_event_limit_is_enforced_for_both_serializations() {
    let limits = ReadLimits {
        max_events: 2,
        ..Default::default()
    };
    let error = read_with_limits(SEQUENTIAL.as_bytes(), limits)
        .unwrap_err()
        .to_string();
    assert!(error.contains("event limit exceeded"), "error: {error}");
    assert!(error.contains("limit=\"2\""), "error: {error}");

    let contained = br#"{
        "file_schema": "urn:ietf:params:qlog:file:contained",
        "traces": [{"events": [
            {"time": 1.0, "name": "a:b"}, {"time": 2.0, "name": "a:b"}, {"time": 3.0, "name": "a:b"}
        ]}]
    }"#;
    let error = read_with_limits(contained, limits).unwrap_err().to_string();
    assert!(error.contains("event limit exceeded"), "error: {error}");

    let trace_limits = ReadLimits {
        max_traces: 0,
        ..Default::default()
    };
    let error = read_with_limits(contained, trace_limits)
        .unwrap_err()
        .to_string();
    assert!(error.contains("trace limit exceeded"), "error: {error}");
}

#[test]
fn detection_recognises_both_serializations_without_parsing() {
    assert!(looks_like_qlog(SEQUENTIAL.as_bytes()));
    assert!(looks_like_qlog(
        br#"{"file_schema": "urn:ietf:params:qlog:file:contained"}"#
    ));
    assert!(
        looks_like_qlog(br#"{"qlog_format": "JSON"}"#),
        "legacy files are recognised so they can be rejected with a clear error",
    );
    assert!(!looks_like_qlog(br#"{"log": {"entries": []}}"#));
    assert!(!looks_like_qlog(&[0xff, 0xd8, 0xff]));
}

/// What the recorder writes, this reader reads: the same encoder the crate ships
/// produces the bytes, so a schema change on either side breaks this test.
#[tokio::test]
async fn round_trips_the_json_text_sequence_encoder() {
    use crate::qlog::{
        QlogEventView, TraceInfo,
        event::{LifecycleEventView, TupleId, lifecycle::ConnectionState},
        output::QlogEncoder as _,
    };
    use rama_quic_proto::ConnectionId;
    use rama_utils::str::arcstr::arcstr;
    use std::time::{Duration, Instant};

    let start_time = Instant::now();
    let info = TraceInfo {
        event_schemas: &[],
        title: Some(arcstr!("round trip")),
        description: None,
        start_time,
    };
    let mut encoder = crate::qlog::JsonSeqEncoder;
    let mut written = Vec::new();
    encoder.begin(&info, &mut written).await.unwrap();
    for (offset, state) in [
        (Duration::ZERO, ConnectionState::Attempted),
        (Duration::from_millis(7), ConnectionState::HandshakeStarted),
        (
            Duration::from_micros(9_500),
            ConnectionState::HandshakeComplete,
        ),
    ] {
        let mut fields: crate::qlog::event::EventFieldsView<'_> =
            LifecycleEventView::StateUpdated {
                old: None,
                new: state,
            }
            .into();
        fields.tuple = Some(TupleId::Generation(1));
        encoder
            .event(
                &info,
                &QlogEventView {
                    group_id: ConnectionId::new(&[0xc0, 0xff, 0xee]),
                    time: start_time + offset,
                    fields,
                },
                &mut written,
            )
            .await
            .unwrap();
    }

    let file = read(&written).unwrap();
    assert_eq!(file.schema, FileSchema::Sequential);
    assert_eq!(file.title.as_deref(), Some("round trip"));

    let trace = &file.traces[0];
    assert_eq!(
        trace
            .event_schemas
            .iter()
            .map(ArcStr::as_str)
            .collect::<Vec<_>>(),
        [crate::qlog::schema::EVENT_SCHEMA_QUIC],
    );
    assert_eq!(trace.events.len(), 3);
    let times: Vec<f64> = trace.events.iter().map(|event| event.time_ms).collect();
    assert_eq!(times, [0.0, 7.0, 9.5]);
    for event in &trace.events {
        assert_eq!(event.name, "quic:connection_state_updated");
        assert_eq!(event.group_id.as_deref(), Some("c0ffee"));
        assert_eq!(event.path.as_deref(), Some("1"));
    }
    assert_eq!(
        trace.events[2].data["new"].as_str(),
        Some("handshake_complete")
    );
}

#[test]
fn byte_limits_bound_what_a_single_record_or_document_can_allocate() {
    let limits = ReadLimits {
        max_record_bytes: 64,
        ..Default::default()
    };
    let error = read_from(SEQUENTIAL.as_bytes(), limits)
        .unwrap_err()
        .to_string();
    assert!(
        error.contains("record exceeds the size limit"),
        "error: {error}"
    );

    let contained = br#"{"file_schema": "urn:ietf:params:qlog:file:contained", "traces": []}"#;
    let limits = ReadLimits {
        max_contained_bytes: 16,
        ..Default::default()
    };
    let error = read_from(&contained[..], limits).unwrap_err().to_string();
    assert!(error.contains("exceeds the size limit"), "error: {error}");
}

#[test]
fn a_sequence_is_read_from_a_stream_one_record_at_a_time() {
    /// Yields a couple of bytes per read, the way a slow pipe would.
    struct Stuttering<'a>(&'a [u8]);

    impl std::io::Read for Stuttering<'_> {
        fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
            let count = self.0.len().min(out.len()).min(3);
            out[..count].copy_from_slice(&self.0[..count]);
            self.0 = &self.0[count..];
            Ok(count)
        }
    }

    let mut input = b"\xef\xbb\xbf".to_vec();
    input.extend_from_slice(SEQUENTIAL.as_bytes());
    let file = read_from(Stuttering(&input), ReadLimits::default()).unwrap();
    assert_eq!(file.schema, FileSchema::Sequential);
    assert_eq!(file.event_count(), 3);
}
