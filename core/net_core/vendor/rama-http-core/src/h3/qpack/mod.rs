//! Connection-scoped QPACK (RFC 9204): the dynamic table plus the stateful encoder and decoder.
//!
//! The pure wire vocabulary — the static table, prefixed codings, field-line and instruction
//! representations — lives in [`rama_http_types::proto::h3::qpack`]; this module adds the
//! connection state that turns those representations into a working compressor.

pub mod dynamic_table;

mod error;
pub use error::{ErrorScope, QpackError};

mod decoder;
pub use decoder::{Decoder, DecoderConfig, FieldPair};

mod encoder;
pub use encoder::{EncodeField, Encoder, EncoderConfig};

#[cfg(test)]
mod tests;

#[cfg(test)]
mod pylsqpack_tests;
