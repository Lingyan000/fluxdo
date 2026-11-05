//! Reader for recorded qlog files, [main schema draft 14].
//!
//! The counterpart of [the recorder](super): both serializations of the main
//! schema are accepted, a contained JSON file (`application/qlog+json`) and the
//! JSON text sequence (`application/qlog+json-seq`, [RFC 7464]) this crate writes.
//!
//! Reading is schema-generic where the recorder is typed: event bodies stay
//! [`serde_json::Value`]. The reader validates the file and trace envelope and
//! resolves timestamps against the trace's time reference, but preserves every
//! event — including ones no [`EventView`](super::event::EventView) covers, and
//! traces written by another implementation. Older qlog formats (draft-02 /
//! qlog 0.3 and earlier) are rejected with an explicit error rather than guessed at.
//!
//! [main schema draft 14]: https://www.ietf.org/archive/id/draft-ietf-quic-qlog-main-schema-14.html
//! [RFC 7464]: https://www.rfc-editor.org/rfc/rfc7464

use std::io::{BufRead, BufReader, Read};

use super::schema;
use jiff::Timestamp;
use rama_core::error::{BoxError, BoxErrorExt as _, ErrorContext as _, ErrorExt as _};
use rama_utils::{
    octets::{kib, mib_u64},
    str::arcstr::ArcStr,
};
use serde_json::{Map, Value};

#[cfg(test)]
mod tests;

/// Serialization of a qlog file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileSchema {
    /// One JSON document holding every trace and event.
    Contained,
    /// A JSON text sequence: a header record followed by one record per event.
    Sequential,
}

impl FileSchema {
    /// The `file_schema` URN identifying this serialization.
    #[must_use]
    pub fn urn(self) -> &'static str {
        match self {
            Self::Contained => schema::FILE_SCHEMA_CONTAINED,
            Self::Sequential => schema::FILE_SCHEMA_SEQUENTIAL,
        }
    }
}

/// Where a trace was recorded.
#[derive(Debug, Clone, Default)]
pub struct VantagePoint {
    /// Free-form name of the recording endpoint.
    pub name: Option<ArcStr>,
    /// Endpoint role, e.g. `client`, `server` or `unknown`.
    pub kind: Option<ArcStr>,
}

/// How an event's `time` is expressed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum TimeFormat {
    /// Milliseconds since the trace's reference time.
    #[default]
    RelativeToEpoch,
    /// Milliseconds since the previous event of the same trace.
    RelativeToPreviousEvent,
}

/// One recorded event.
#[derive(Debug, Clone)]
pub struct Event {
    /// Index of the trace this event belongs to, in [`QlogFile::traces`].
    pub trace: usize,
    /// Milliseconds since the trace's reference time, with deltas already resolved.
    pub time_ms: f64,
    /// Qualified event name, e.g. `quic:packet_sent`.
    pub name: ArcStr,
    /// Connection group this event belongs to.
    pub group_id: Option<ArcStr>,
    /// Network path (`path`, or the `tuple` spelling used by the QUIC events schema).
    pub path: Option<ArcStr>,
    /// Schema-defined event body, kept verbatim.
    pub data: Value,
    /// Any further event member, kept verbatim.
    pub extra: Map<String, Value>,
}

/// One trace: the events of a single recording, with their shared metadata.
#[derive(Debug, Clone, Default)]
pub struct Trace {
    /// Short label.
    pub title: Option<ArcStr>,
    /// Longer context.
    pub description: Option<ArcStr>,
    /// Recording endpoint.
    pub vantage_point: VantagePoint,
    /// Event schema URNs this trace declares.
    pub event_schemas: Vec<ArcStr>,
    /// Wall-clock time of `time_ms == 0`, when the reference clock is absolute.
    pub epoch: Option<Timestamp>,
    /// Reference clock kind, e.g. `monotonic` or `system`.
    pub clock_type: Option<ArcStr>,
    /// Fields shared by the trace's events, kept verbatim.
    pub common_fields: Map<String, Value>,
    /// Recorded events, in file order.
    pub events: Vec<Event>,
}

/// A decoded qlog file.
#[derive(Debug, Clone)]
pub struct QlogFile {
    /// Serialization the file used.
    pub schema: FileSchema,
    /// Short label.
    pub title: Option<ArcStr>,
    /// Longer context.
    pub description: Option<ArcStr>,
    /// Traces, in file order.
    pub traces: Vec<Trace>,
}

impl QlogFile {
    /// Total number of events across all traces.
    #[must_use]
    pub fn event_count(&self) -> usize {
        self.traces.iter().map(|trace| trace.events.len()).sum()
    }
}

/// Bounds applied while reading, so a hostile or accidental input cannot exhaust memory.
///
/// A decoded trace is held in memory, so the event limit is what bounds a reader's
/// footprint; the byte limits bound what a single malformed record can allocate
/// before that.
#[derive(Debug, Clone, Copy)]
pub struct ReadLimits {
    /// Maximum number of events across all traces.
    pub max_events: usize,
    /// Maximum number of traces.
    pub max_traces: usize,
    /// Maximum size of one JSON text-sequence record.
    pub max_record_bytes: u64,
    /// Maximum size of a contained JSON file, which is parsed as one document.
    pub max_contained_bytes: u64,
}

impl Default for ReadLimits {
    fn default() -> Self {
        Self {
            max_events: 250_000,
            max_traces: 1024,
            max_record_bytes: mib_u64(16),
            max_contained_bytes: mib_u64(256),
        }
    }
}

/// Whether `input` plausibly starts a qlog file, for content-based detection.
///
/// This only inspects the head of the input; [`read`] does the real validation.
#[must_use]
pub fn looks_like_qlog(input: &[u8]) -> bool {
    if input.first() == Some(&schema::RECORD_SEPARATOR) {
        return true;
    }
    let head = &input[..input.len().min(kib(4))];
    head.windows(13)
        .any(|window| window == br#""file_schema""# || window == br#""qlog_format""#)
}

/// Read a qlog file from memory, using the default [`ReadLimits`].
pub fn read(input: &[u8]) -> Result<QlogFile, BoxError> {
    read_with_limits(input, ReadLimits::default())
}

/// Read a qlog file from memory, rejecting input that exceeds `limits`.
pub fn read_with_limits(input: &[u8], limits: ReadLimits) -> Result<QlogFile, BoxError> {
    read_from(std::io::Cursor::new(input), limits)
}

/// Read a qlog file from a stream, collecting its events.
///
/// A whole capture is held in memory. Use [`read_streaming`] to consume events
/// as they are decoded, which is what a viewer of a large file wants.
pub fn read_from(reader: impl Read, limits: ReadLimits) -> Result<QlogFile, BoxError> {
    let mut events = Vec::new();
    let mut file = read_streaming(reader, limits, |event| {
        events.push(event);
        Ok(())
    })?;
    for event in events {
        if let Some(trace) = file.traces.get_mut(event.trace) {
            trace.events.push(event);
        }
    }
    Ok(file)
}

/// Read a qlog file from a stream, handing each event to `on_event` as it is decoded.
///
/// The returned [`QlogFile`] carries the file and trace metadata with empty
/// [`Trace::events`]: what to keep of an event is the caller's choice, so a
/// viewer can render one and drop its JSON instead of holding the whole capture.
///
/// A JSON text sequence is decoded one record at a time, so the source bytes are
/// never held whole either. A contained JSON file is a single document and is
/// parsed as one, bounded by [`ReadLimits::max_contained_bytes`].
pub fn read_streaming(
    reader: impl Read,
    limits: ReadLimits,
    on_event: impl FnMut(Event) -> Result<(), BoxError>,
) -> Result<QlogFile, BoxError> {
    let mut reader = BufReader::new(reader);
    const BOM: &[u8] = b"\xef\xbb\xbf";
    let head = reader.fill_buf().context("read qlog file")?;
    let bom = head.starts_with(BOM);
    if bom {
        reader.consume(BOM.len());
    }
    let head = reader.fill_buf().context("read qlog file")?;
    if head.first() == Some(&schema::RECORD_SEPARATOR) {
        read_sequential(reader, limits, on_event)
    } else {
        read_contained(reader, limits, on_event)
    }
}

fn read_contained(
    reader: impl BufRead,
    limits: ReadLimits,
    mut on_event: impl FnMut(Event) -> Result<(), BoxError>,
) -> Result<QlogFile, BoxError> {
    let mut reader = reader.take(limits.max_contained_bytes.saturating_add(1));
    let mut input = Vec::new();
    reader.read_to_end(&mut input).context("read qlog file")?;
    if input.len() as u64 > limits.max_contained_bytes {
        return Err(
            BoxError::from_static_str("contained qlog file exceeds the size limit")
                .context_field("limit", limits.max_contained_bytes),
        );
    }
    let value: Value = serde_json::from_slice(&input).context("parse qlog JSON file")?;
    let object = value
        .as_object()
        .context("qlog file must be a JSON object")?;
    let schema = file_schema(object)?;
    let traces = object
        .get("traces")
        .and_then(Value::as_array)
        .context("contained qlog file misses its traces array")?;
    if traces.len() > limits.max_traces {
        return Err(BoxError::from_static_str("qlog trace limit exceeded")
            .context_field("limit", limits.max_traces)
            .context_field("traces", traces.len()));
    }

    let mut budget = limits.max_events;
    let mut decoded = Vec::with_capacity(traces.len());
    for (index, trace) in traces.iter().enumerate() {
        let trace = trace
            .as_object()
            .context("qlog trace must be a JSON object")
            .context_field("trace", index)?;
        let decoded_trace = trace_metadata(trace);
        if let Some(events) = trace.get("events").and_then(Value::as_array) {
            let mut resolver = TimeResolver::new(&decoded_trace.common_fields);
            for (position, event) in events.iter().enumerate() {
                if budget == 0 {
                    return Err(BoxError::from_static_str("qlog event limit exceeded")
                        .context_field("limit", limits.max_events));
                }
                budget -= 1;
                let event = read_event(index, event, &mut resolver, &decoded_trace.common_fields)
                    .context_field("trace", index)
                    .context_field("event", position)?;
                on_event(event)?;
            }
        }
        decoded.push(decoded_trace);
    }

    Ok(QlogFile {
        schema,
        title: text(object.get("title")),
        description: text(object.get("description")),
        traces: decoded,
    })
}

fn read_sequential(
    reader: impl BufRead,
    limits: ReadLimits,
    mut on_event: impl FnMut(Event) -> Result<(), BoxError>,
) -> Result<QlogFile, BoxError> {
    let mut records = Records {
        reader,
        limit: limits.max_record_bytes,
        buffer: Vec::new(),
    };

    let header = records
        .next()?
        .context("sequential qlog file misses its header record")?;
    let header: Value = serde_json::from_slice(header).context("parse qlog header record")?;
    let header = header
        .as_object()
        .context("qlog header record must be a JSON object")?;
    let schema = file_schema(header)?;

    let trace = header
        .get("trace")
        .and_then(Value::as_object)
        .map_or_else(Trace::default, trace_metadata);
    let title = text(header.get("title"));
    let description = text(header.get("description"));
    let mut resolver = TimeResolver::new(&trace.common_fields);
    let mut position = 0;
    while let Some(record) = records.next()? {
        if position == limits.max_events {
            return Err(BoxError::from_static_str("qlog event limit exceeded")
                .context_field("limit", limits.max_events));
        }
        let record: Value = serde_json::from_slice(record)
            .context("parse qlog event record")
            .context_field("event", position)?;
        let event = read_event(0, &record, &mut resolver, &trace.common_fields)
            .context_field("event", position)?;
        on_event(event)?;
        position += 1;
    }

    Ok(QlogFile {
        schema,
        title,
        description,
        traces: vec![trace],
    })
}

/// Splits a JSON text sequence into records, holding one record at a time.
struct Records<R> {
    reader: R,
    limit: u64,
    buffer: Vec<u8>,
}

impl<R: BufRead> Records<R> {
    /// The next non-empty record, without its separators.
    fn next(&mut self) -> Result<Option<&[u8]>, BoxError> {
        loop {
            self.buffer.clear();
            let read = (&mut self.reader)
                .take(self.limit.saturating_add(1))
                .read_until(schema::RECORD_SEPARATOR, &mut self.buffer)
                .context("read qlog record")?;
            if read == 0 {
                return Ok(None);
            }
            if read as u64 > self.limit {
                return Err(
                    BoxError::from_static_str("qlog record exceeds the size limit")
                        .context_field("limit", self.limit),
                );
            }
            let record = match self.buffer.last() {
                Some(&schema::RECORD_SEPARATOR) => &self.buffer[..self.buffer.len() - 1],
                _ => &self.buffer[..],
            };
            if !record.iter().all(u8::is_ascii_whitespace) {
                // borrow again: the compiler cannot see that `record` outlives the loop
                let len = record.len();
                return Ok(Some(&self.buffer[..len]));
            }
        }
    }
}

fn file_schema(object: &Map<String, Value>) -> Result<FileSchema, BoxError> {
    let Some(urn) = object.get("file_schema").and_then(Value::as_str) else {
        // qlog 0.3 (draft-02 and earlier) is a different schema with the same file extension.
        if let Some(version) = object.get("qlog_version").and_then(Value::as_str) {
            return Err(BoxError::from_static_str(
                "unsupported legacy qlog version, only main schema draft 14 is supported",
            )
            .context_str_field("qlog_version", version));
        }
        return Err(BoxError::from_static_str(
            "not a qlog file: no file_schema member",
        ));
    };
    match urn.strip_prefix(schema::FILE_SCHEMA_PREFIX) {
        Some("contained") => Ok(FileSchema::Contained),
        Some("sequential") => Ok(FileSchema::Sequential),
        _ => Err(BoxError::from_static_str("unsupported qlog file schema")
            .context_str_field("file_schema", urn)),
    }
}

fn trace_metadata(trace: &Map<String, Value>) -> Trace {
    let vantage_point = trace
        .get("vantage_point")
        .and_then(Value::as_object)
        .map(|point| VantagePoint {
            name: text(point.get("name")),
            kind: text(point.get("type")),
        })
        .unwrap_or_default();
    let common_fields = trace
        .get("common_fields")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let reference = common_fields
        .get("reference_time")
        .and_then(Value::as_object);
    Trace {
        title: text(trace.get("title")),
        description: text(trace.get("description")),
        vantage_point,
        event_schemas: trace
            .get("event_schemas")
            .and_then(Value::as_array)
            .map(|schemas| schemas.iter().map(Some).filter_map(text).collect())
            .unwrap_or_default(),
        epoch: reference
            .and_then(|reference| reference.get("epoch"))
            .and_then(Value::as_str)
            .and_then(|epoch| epoch.parse::<Timestamp>().ok()),
        clock_type: reference.and_then(|reference| text(reference.get("clock_type"))),
        common_fields,
        events: Vec::new(),
    }
}

/// Resolves each event's `time` against the trace's declared time format.
struct TimeResolver {
    format: TimeFormat,
    previous_ms: f64,
}

impl TimeResolver {
    fn new(common_fields: &Map<String, Value>) -> Self {
        Self {
            format: time_format(common_fields.get("time_format")),
            previous_ms: 0.0,
        }
    }

    fn resolve(&mut self, event: &Map<String, Value>) -> Result<f64, BoxError> {
        let format = event
            .get("time_format")
            .map_or(self.format, |value| time_format(Some(value)));
        // `relative_time` is the delta spelling of draft-14's optional event times.
        let (raw, delta) = match (event.get("time"), event.get("relative_time")) {
            (Some(time), _) => (time, format == TimeFormat::RelativeToPreviousEvent),
            (None, Some(relative)) => (relative, true),
            (None, None) => return Err(BoxError::from_static_str("qlog event misses its time")),
        };
        let raw = raw
            .as_f64()
            .context("qlog event time must be a number of milliseconds")?;
        if !raw.is_finite() {
            return Err(BoxError::from_static_str("qlog event time is not finite"));
        }
        let resolved = if delta { self.previous_ms + raw } else { raw };
        self.previous_ms = resolved;
        Ok(resolved)
    }
}

fn time_format(value: Option<&Value>) -> TimeFormat {
    match value.and_then(Value::as_str) {
        Some("relative_to_previous_event") => TimeFormat::RelativeToPreviousEvent,
        _ => TimeFormat::default(),
    }
}

fn read_event(
    trace: usize,
    event: &Value,
    resolver: &mut TimeResolver,
    common_fields: &Map<String, Value>,
) -> Result<Event, BoxError> {
    let event = event
        .as_object()
        .context("qlog event must be a JSON object")?;
    let time_ms = resolver.resolve(event)?;
    let name = text(event.get("name"))
        .or_else(|| {
            // draft-14 names an event `namespace:type`; some writers still split the two.
            let namespace = event.get("category").and_then(Value::as_str)?;
            let kind = event.get("event").and_then(Value::as_str)?;
            Some(ArcStr::from(format!("{namespace}:{kind}")))
        })
        .context("qlog event misses its name")?;
    let shared = |key: &str| text(event.get(key)).or_else(|| text(common_fields.get(key)));
    let extra = event
        .iter()
        .filter(|(key, _)| {
            !matches!(
                key.as_str(),
                "time"
                    | "relative_time"
                    | "time_format"
                    | "name"
                    | "data"
                    | "group_id"
                    | "path"
                    | "tuple"
            )
        })
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();

    Ok(Event {
        trace,
        time_ms,
        name,
        group_id: shared("group_id"),
        path: shared("path").or_else(|| shared("tuple")),
        data: event.get("data").cloned().unwrap_or(Value::Null),
        extra,
    })
}

fn text(value: Option<&Value>) -> Option<ArcStr> {
    match value? {
        Value::String(value) => Some(ArcStr::from(value.as_str())),
        _ => None,
    }
}
