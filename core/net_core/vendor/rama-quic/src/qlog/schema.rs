//! Identifiers of the qlog schemas this crate writes and reads.
//!
//! Shared by the [encoder](super::JsonSeqEncoder) and the [reader](super::reader)
//! so one side cannot drift from the other.

/// Record separator introducing every record of a JSON text sequence ([RFC 7464]).
///
/// [RFC 7464]: https://www.rfc-editor.org/rfc/rfc7464
pub const RECORD_SEPARATOR: u8 = 0x1e;

/// Common prefix of every main-schema `file_schema` URN.
pub const FILE_SCHEMA_PREFIX: &str = "urn:ietf:params:qlog:file:";

/// `file_schema` of a single JSON document holding every trace and event.
pub const FILE_SCHEMA_CONTAINED: &str = "urn:ietf:params:qlog:file:contained";

/// `file_schema` of a JSON text sequence: a header record, then one record per event.
pub const FILE_SCHEMA_SEQUENTIAL: &str = "urn:ietf:params:qlog:file:sequential";

/// Media type of the JSON text-sequence serialization.
pub const SERIALIZATION_FORMAT_JSON_SEQ: &str = "application/qlog+json-seq";

/// Event schema of [QUIC events draft 13], the event set this crate implements.
///
/// [QUIC events draft 13]: https://www.ietf.org/archive/id/draft-ietf-quic-qlog-quic-events-13.html
pub const EVENT_SCHEMA_QUIC: &str = "urn:ietf:params:qlog:events:quic-13";
