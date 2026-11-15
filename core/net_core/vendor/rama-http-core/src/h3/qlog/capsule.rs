//! Capsule events of the HTTP/3 request stream carrying a tunnel.

use rama_http::datagram::{CapsuleObservation, CapsuleObserver};
use rama_http_types::proto::capsule::{CapsuleHeader, CapsuleType};
use rama_quic::qlog::{ConnectionQlogControl, EventSchema};
use serde::Serialize;

/// Capsule events from HTTP qlog draft 13, a separate namespace from HTTP/3 events.
pub const EVENT_SCHEMA_HTTP: EventSchema =
    EventSchema::new("urn:ietf:params:qlog:events:http-13", "http");

struct Observer {
    control: ConnectionQlogControl,
    stream: u64,
}

pub(in crate::h3) fn observation(
    control: &ConnectionQlogControl,
    stream: u64,
) -> CapsuleObservation {
    CapsuleObservation::new(Observer {
        control: control.clone(),
        stream,
    })
}

#[derive(Serialize)]
struct CapsuleRecord {
    stream_id: u64,
    capsule: Capsule,
}

#[derive(Serialize)]
#[serde(tag = "capsule_type", rename_all = "snake_case")]
enum Capsule {
    Datagram,
    Unknown { capsule_type_value: u64 },
}

impl Observer {
    fn emit(&self, name: &'static str, header: CapsuleHeader) {
        self.control
            .emit_named(&EVENT_SCHEMA_HTTP, name, || CapsuleRecord {
                stream_id: self.stream,
                capsule: if header.ty == CapsuleType::DATAGRAM {
                    Capsule::Datagram
                } else {
                    Capsule::Unknown {
                        capsule_type_value: header.ty.value(),
                    }
                },
            });
    }
}

impl CapsuleObserver for Observer {
    fn is_enabled(&self) -> bool {
        self.control.is_enabled()
    }
    fn created(&self, header: CapsuleHeader) {
        self.emit("http:capsule_created", header);
    }
    fn parsed(&self, header: CapsuleHeader) {
        self.emit("http:capsule_parsed", header);
    }
}
