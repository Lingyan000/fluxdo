//! HTTP/3 qlog events, recorded through the QUIC connection's qlog sink.
//!
//! A recorder writes these events only when started with
//! `QlogConfig::with_event_schemas(EVENT_SCHEMAS)`; a custom sink receives the schemas it
//! accepts through `QlogSink::accepts_named`.
//! Events carry protocol metadata only, never field names, values, paths or payloads; the one
//! value logged is a PRIORITY_UPDATE frame's priority field.
//! Events a peer can trigger at will, ignored frames and QPACK instructions, have a per-connection
//! budget; exhausting it is recorded once as `rama_h3:events_suppressed`.
//!
//! Covered: SETTINGS, stream types, control frames, HTTP Datagrams, Capsules and
//! QPACK instructions and field sections. HEADERS frames are omitted since their standard
//! event requires field names.
//! Peer stream types read before SETTINGS are applied are reported once SETTINGS are applied.
//!
//! Schemas: [HTTP/3 events draft 13] and Rama's own QPACK schema.
//!
//! [HTTP/3 events draft 13]: https://datatracker.ietf.org/doc/html/draft-ietf-quic-qlog-h3-events-13

mod capsule;
pub(in crate::h3) mod qpack;
pub use capsule::EVENT_SCHEMA_HTTP;
pub(in crate::h3) use capsule::observation as capsule_observation;
pub use qpack::EVENT_SCHEMA_QPACK;
pub(in crate::h3) use qpack::QPACK_INSTRUCTION_EVENTS;

use super::{control::Role, frame::FrameEvent};
use rama_core::bytes::Bytes;
use rama_http_types::proto::h3::{QuarterStreamId, SettingId, Settings, StreamType};
use rama_quic::qlog::{ConnectionQlogControl, EventSchema};
use rama_quic_proto::{StreamId, VarInt};
use serde::{Serialize, Serializer, ser::SerializeSeq as _};
use std::{
    borrow::Cow,
    sync::atomic::{AtomicU32, Ordering},
};

/// HTTP/3 events draft 13.
pub const EVENT_SCHEMA_HTTP3: EventSchema =
    EventSchema::new("urn:ietf:params:qlog:events:http3-13", "http3");

/// Rama's own HTTP/3 events, such as suppressed peer-triggered events.
pub const EVENT_SCHEMA_RAMA_H3: EventSchema =
    EventSchema::new("https://ramaproxy.org/qlog/rama-h3-1", "rama_h3");

/// Every schema emitted by HTTP/3, for `QlogConfig::with_event_schemas`.
pub const EVENT_SCHEMAS: &[EventSchema] = &[
    EVENT_SCHEMA_HTTP3,
    EVENT_SCHEMA_HTTP,
    EVENT_SCHEMA_QPACK,
    EVENT_SCHEMA_RAMA_H3,
];

/// Peer-ignorable frames recorded per connection before the rest are suppressed.
pub(in crate::h3) const IGNORED_FRAME_EVENTS: u32 = 256;

#[derive(Serialize)]
struct Suppressed {
    events: &'static str,
    limit: u32,
}

/// A per-connection cap on one class of peer-triggered events.
#[derive(Debug)]
pub(in crate::h3) struct PeerEventBudget {
    events: &'static str,
    limit: u32,
    used: AtomicU32,
}

impl PeerEventBudget {
    pub(in crate::h3) const fn new(events: &'static str, limit: u32) -> Self {
        Self {
            events,
            limit,
            used: AtomicU32::new(0),
        }
    }

    /// Whether one more event may be recorded; the first refusal records the suppression.
    pub(in crate::h3) fn admit(&self, control: &ConnectionQlogControl) -> bool {
        if !control.is_enabled() {
            return false;
        }
        let used = self.used.load(Ordering::Relaxed);
        if used > self.limit {
            return false;
        }
        self.used.store(used + 1, Ordering::Relaxed);
        if used < self.limit {
            return true;
        }
        control.emit_named(&EVENT_SCHEMA_RAMA_H3, "rama_h3:events_suppressed", || {
            Suppressed {
                events: self.events,
                limit: self.limit,
            }
        });
        false
    }
}

#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum Initiator {
    Local,
    Remote,
}

#[derive(Serialize)]
struct Parameters {
    initiator: Initiator,
    max_table_capacity: u64,
    blocked_streams_count: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    max_field_section_size: Option<u64>,
    extended_connect: u16,
    h3_datagram: u16,
}

pub(super) fn parameters(
    control: Option<&ConnectionQlogControl>,
    initiator: Initiator,
    settings: &Settings,
) {
    if let Some(control) = control {
        control.emit_named(&EVENT_SCHEMA_HTTP3, "http3:parameters_set", || Parameters {
            initiator,
            max_table_capacity: settings.qpack_max_table_capacity(),
            blocked_streams_count: settings.qpack_blocked_streams(),
            max_field_section_size: settings.max_field_section_size(),
            extended_connect: u16::from(settings.enable_connect_protocol()),
            h3_datagram: u16::from(settings.h3_datagram()),
        });
    }
}

#[derive(Serialize)]
struct StreamTypeSet {
    initiator: Initiator,
    stream_id: u64,
    stream_type: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    stream_type_bytes: Option<u64>,
}

pub(super) fn stream_type(
    control: Option<&ConnectionQlogControl>,
    initiator: Initiator,
    id: u64,
    kind: StreamType,
) {
    if let Some(control) = control {
        control.emit_named(&EVENT_SCHEMA_HTTP3, "http3:stream_type_set", || {
            let stream_type = match kind {
                StreamType::CONTROL => "control",
                StreamType::PUSH => "push",
                StreamType::QPACK_ENCODER => "qpack_encode",
                StreamType::QPACK_DECODER => "qpack_decode",
                kind if kind.is_reserved() => "reserved",
                _ => "unknown",
            };
            StreamTypeSet {
                initiator,
                stream_id: id,
                stream_type,
                stream_type_bytes: (stream_type == "unknown").then_some(kind.value()),
            }
        });
    }
}

pub(super) fn request_stream(control: Option<&ConnectionQlogControl>, role: Role, id: u64) {
    // Request streams are client-initiated bidirectional streams. Push readers are not requests.
    if let Some(control) = control
        && id.is_multiple_of(4)
    {
        control.emit_named(&EVENT_SCHEMA_HTTP3, "http3:stream_type_set", || {
            StreamTypeSet {
                initiator: if role == Role::Client {
                    Initiator::Local
                } else {
                    Initiator::Remote
                },
                stream_id: id,
                stream_type: "request",
                stream_type_bytes: None,
            }
        });
    }
}

struct SettingsEntries<'a>(&'a Settings);

#[derive(Serialize)]
struct Setting {
    name: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    name_bytes: Option<u64>,
    value: u64,
}

impl Serialize for SettingsEntries<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut entries = serializer.serialize_seq(Some(self.0.len()))?;
        for entry in self.0.entries() {
            let name = match entry.id {
                SettingId::QPACK_MAX_TABLE_CAPACITY => "settings_qpack_max_table_capacity",
                SettingId::MAX_FIELD_SECTION_SIZE => "settings_max_field_section_size",
                SettingId::QPACK_BLOCKED_STREAMS => "settings_qpack_blocked_streams",
                SettingId::ENABLE_CONNECT_PROTOCOL => "settings_enable_connect_protocol",
                SettingId::H3_DATAGRAM => "settings_h3_datagram",
                id if id.is_reserved() => "reserved",
                _ => "unknown",
            };
            entries.serialize_element(&Setting {
                name,
                name_bytes: (name == "unknown").then_some(entry.id.value()),
                value: entry.value,
            })?;
        }
        entries.end()
    }
}

#[derive(Serialize)]
#[serde(tag = "frame_type", rename_all = "snake_case")]
enum Frame<'a> {
    Settings {
        settings: SettingsEntries<'a>,
    },
    CancelPush {
        push_id: u64,
    },
    Goaway {
        id: u64,
    },
    MaxPushId {
        push_id: u64,
    },
    PriorityUpdate {
        #[serde(skip_serializing_if = "Option::is_none")]
        stream_id: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        push_id: Option<u64>,
        priority_field_value: Cow<'a, str>,
    },
    Reserved {
        frame_type_bytes: u64,
    },
    Unknown {
        frame_type_bytes: u64,
    },
}

impl<'a> Frame<'a> {
    fn priority_update(push: bool, element_id: u64, field_value: &'a [u8]) -> Self {
        Self::PriorityUpdate {
            stream_id: (!push).then_some(element_id),
            push_id: push.then_some(element_id),
            priority_field_value: String::from_utf8_lossy(field_value),
        }
    }
}

/// A locally queued control frame, reported once written to the control stream.
pub(super) enum ControlFrame {
    CancelPush(u64),
    Goaway(u64),
    MaxPushId(u64),
    PriorityUpdate {
        push: bool,
        element_id: u64,
        field_value: Bytes,
    },
}

pub(super) fn created_control(
    control: Option<&ConnectionQlogControl>,
    id: u64,
    frame: &ControlFrame,
) {
    record_frame(control, "http3:frame_created", id, || match frame {
        ControlFrame::CancelPush(push_id) => Frame::CancelPush { push_id: *push_id },
        ControlFrame::Goaway(goaway) => Frame::Goaway { id: *goaway },
        ControlFrame::MaxPushId(push_id) => Frame::MaxPushId { push_id: *push_id },
        ControlFrame::PriorityUpdate {
            push,
            element_id,
            field_value,
        } => Frame::priority_update(*push, *element_id, field_value),
    });
}

#[derive(Serialize)]
struct FrameRecord<'a> {
    stream_id: u64,
    frame: Frame<'a>,
    #[serde(skip_serializing_if = "Option::is_none")]
    raw: Option<RawPayload>,
}

#[derive(Serialize)]
struct RawPayload {
    payload_length: u64,
}

fn record_frame<'a>(
    control: Option<&ConnectionQlogControl>,
    name: &'static str,
    id: u64,
    build: impl FnOnce() -> Frame<'a>,
) {
    if let Some(control) = control {
        control.emit_named(&EVENT_SCHEMA_HTTP3, name, || FrameRecord {
            stream_id: id,
            frame: build(),
            raw: None,
        });
    }
}

pub(super) fn created_settings(
    control: Option<&ConnectionQlogControl>,
    id: u64,
    settings: &Settings,
) {
    record_frame(control, "http3:frame_created", id, || Frame::Settings {
        settings: SettingsEntries(settings),
    });
}

pub(super) fn parsed_settings(
    control: Option<&ConnectionQlogControl>,
    id: u64,
    settings: &Settings,
) {
    record_frame(control, "http3:frame_parsed", id, || Frame::Settings {
        settings: SettingsEntries(settings),
    });
}

/// Record a parsed control-stream frame; `ignored` bounds the peer's reserved and unknown frames.
pub(super) fn parsed(
    control: Option<&ConnectionQlogControl>,
    id: u64,
    event: &FrameEvent,
    ignored: &PeerEventBudget,
) {
    // Header-only events, HTTP/QPACK fields and payload chunks are never logged.
    let Some(recorder) = control else {
        return;
    };
    match event {
        FrameEvent::Settings(settings) => parsed_settings(control, id, settings),
        FrameEvent::CancelPush(push_id) => record_frame(control, "http3:frame_parsed", id, || {
            Frame::CancelPush { push_id: *push_id }
        }),
        FrameEvent::GoAway(id_value) => record_frame(control, "http3:frame_parsed", id, || {
            Frame::Goaway { id: *id_value }
        }),
        FrameEvent::MaxPushId(push_id) => record_frame(control, "http3:frame_parsed", id, || {
            Frame::MaxPushId { push_id: *push_id }
        }),
        FrameEvent::PriorityUpdate {
            push,
            element_id,
            field_value,
        } => record_frame(control, "http3:frame_parsed", id, || {
            Frame::priority_update(*push, *element_id, field_value)
        }),
        // An unbuffered ignored frame is reported before its payload is skipped, so `raw`
        // carries the declared payload length.
        FrameEvent::Ignored { ty, len, .. } => {
            if !ignored.admit(recorder) {
                return;
            }
            recorder.emit_named(&EVENT_SCHEMA_HTTP3, "http3:frame_parsed", || FrameRecord {
                stream_id: id,
                frame: if ty.is_reserved() {
                    Frame::Reserved {
                        frame_type_bytes: ty.value(),
                    }
                } else {
                    Frame::Unknown {
                        frame_type_bytes: ty.value(),
                    }
                },
                raw: Some(RawPayload {
                    payload_length: *len,
                }),
            });
        }
        _ => (),
    }
}

#[derive(Serialize)]
struct DatagramRecord {
    quarter_stream_id: u64,
    raw: DatagramRaw,
}

#[derive(Serialize)]
struct DatagramRaw {
    length: u64,
}

pub(super) fn datagram(
    control: Option<&ConnectionQlogControl>,
    name: &'static str,
    request: u64,
    observed_length: usize,
) {
    let Some(control) = control.filter(|control| control.is_enabled()) else {
        return;
    };
    let Ok(id) = VarInt::from_u64(request) else {
        return;
    };
    let Ok(id) = QuarterStreamId::from_request_stream(StreamId::from(id)) else {
        return;
    };
    control.emit_named(&EVENT_SCHEMA_HTTP3, name, || DatagramRecord {
        quarter_stream_id: id.value(),
        raw: DatagramRaw {
            length: observed_length as u64,
        },
    });
}
