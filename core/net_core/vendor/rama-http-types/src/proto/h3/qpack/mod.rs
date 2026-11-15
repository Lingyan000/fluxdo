//! QPACK wire vocabulary (RFC 9204): the static table, prefixed integer/string codings, the
//! field-line representations that make up an encoded field section, and the encoder- and
//! decoder-stream instruction representations.
//!
//! These are pure value types with self-contained encoding and decoding over a slice cursor. The
//! connection-scoped dynamic table, the stateful encoder/decoder and blocked-section accounting
//! live in `rama-http-core`'s `h3::qpack` module.

pub mod encoding;

pub mod prefix;
pub use prefix::{DecodedString, PrefixError};

pub mod static_table;

pub mod field;
pub use field::{FieldLine, HeaderPrefix, InvalidPrefix};

pub mod instruction;
pub use instruction::{DecoderInstruction, EncoderInstruction};

mod preferences;
pub use preferences::{EncoderPreferences, FieldSectionBase};
