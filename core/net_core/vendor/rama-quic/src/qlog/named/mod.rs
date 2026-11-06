//! Schema-neutral events for protocols layered above QUIC, such as HTTP/3.

use super::schema::EVENT_SCHEMA_QUIC;
use rama_quic_proto::ConnectionId;
use rama_utils::octets::kib;
use serde::Serialize;
use std::{io, time::Instant};

/// An event schema declared in the trace header, identified by a fixed revision.
#[derive(Clone, Copy, Debug)]
pub struct EventSchema {
    id: &'static str,
    namespace: &'static str,
}

impl EventSchema {
    /// Declare a schema by its identifier and the namespace prefixing its event names.
    pub const fn new(id: &'static str, namespace: &'static str) -> Self {
        Self { id, namespace }
    }

    /// Fixed schema identifier, written into the trace header.
    pub const fn id(&self) -> &'static str {
        self.id
    }

    /// Namespace before the colon in this schema's event names.
    pub const fn namespace(&self) -> &'static str {
        self.namespace
    }

    fn names(&self, name: &str) -> bool {
        name.strip_prefix(self.namespace)
            .is_some_and(|suffix| suffix.starts_with(':'))
    }
}

/// Upper bound of one encoded named event, independent of recorder limits.
pub(super) const MAX_DATA_BYTES: usize = kib(64);

pub(super) fn validate_schemas(schemas: &[EventSchema]) -> io::Result<()> {
    let invalid = schemas.iter().enumerate().any(|(index, schema)| {
        schema.id.is_empty()
            || schema.namespace.is_empty()
            // The namespace ends at the first colon of an event name.
            || schema.namespace.contains(':')
            || schema.id == EVENT_SCHEMA_QUIC
            || schema.namespace == "quic"
            || schemas[..index]
                .iter()
                .any(|other| other.id == schema.id || other.namespace == schema.namespace)
    });
    if invalid {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "qlog event schemas must be unique, distinct from QUIC and have colon-free namespaces",
        ));
    }
    Ok(())
}

/// A named event whose data was encoded once as a JSON object.
#[derive(Debug)]
pub struct NamedQlogEventView<'a> {
    pub(super) group_id: ConnectionId,
    pub(super) time: Instant,
    pub(super) schema: &'static EventSchema,
    pub(super) name: &'static str,
    pub(super) data: &'a [u8],
}

impl NamedQlogEventView<'_> {
    /// Connection group of the emitting connection.
    pub fn group_id(&self) -> ConnectionId {
        self.group_id
    }

    /// Monotonic observation time.
    pub fn time(&self) -> Instant {
        self.time
    }

    /// Schema of this event.
    pub fn schema(&self) -> &'static EventSchema {
        self.schema
    }

    /// Qualified event name, such as `http3:frame_parsed`.
    pub fn name(&self) -> &'static str {
        self.name
    }

    /// Encoded JSON object, borrowed for this callback only.
    pub fn data(&self) -> &[u8] {
        self.data
    }
}

pub(super) struct NamedEvent {
    pub(super) group_id: ConnectionId,
    pub(super) time: Instant,
    pub(super) schema: &'static EventSchema,
    pub(super) name: &'static str,
    pub(super) data: Box<[u8]>,
}

impl NamedEvent {
    pub(super) fn view(&self) -> NamedQlogEventView<'_> {
        NamedQlogEventView {
            group_id: self.group_id,
            time: self.time,
            schema: self.schema,
            name: self.name,
            data: &self.data,
        }
    }
}

pub(super) enum EncodeError {
    Oversized,
    Invalid,
}

struct CappedWriter {
    bytes: Vec<u8>,
    limit: usize,
}

impl io::Write for CappedWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if self.bytes.len().saturating_add(bytes.len()) > self.limit {
            return Err(io::Error::new(
                io::ErrorKind::FileTooLarge,
                "qlog event data exceeds its limit",
            ));
        }
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// Encode `data` as one JSON object of at most `limit` bytes; partial output is discarded.
pub(super) fn encode(
    schema: &EventSchema,
    name: &str,
    data: &impl Serialize,
    limit: usize,
) -> Result<Box<[u8]>, EncodeError> {
    if !schema.names(name) {
        return Err(EncodeError::Invalid);
    }
    let limit = limit.min(MAX_DATA_BYTES);
    let mut writer = CappedWriter {
        bytes: Vec::with_capacity(limit.min(256)),
        limit,
    };
    if let Err(error) = serde_json::to_writer(&mut writer, data) {
        return Err(if error.is_io() {
            EncodeError::Oversized
        } else {
            EncodeError::Invalid
        });
    }
    // Event data must be an object; serde emits no surrounding whitespace.
    if writer.bytes.first() != Some(&b'{') {
        return Err(EncodeError::Invalid);
    }
    Ok(writer.bytes.into_boxed_slice())
}

#[cfg(test)]
mod tests;
