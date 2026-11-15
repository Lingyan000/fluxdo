//! HTTP/3 wire vocabulary: frames, settings, stream types, error codes and the QPACK
//! instruction/field representations.
//!
//! These are pure wire/value types with self-contained encoding and decoding. They carry no
//! connection state: the stateful QPACK tables, encoder/decoder state machines and the bounded,
//! incremental frame codec live in `rama-http-core`'s `h3` module. The QUIC variable-length
//! integer and stream-identifier vocabulary is reused from [`rama_quic_proto`] rather than
//! re-modelled here.
//!
//! References: [RFC 9114](https://www.rfc-editor.org/rfc/rfc9114) (HTTP/3),
//! [RFC 9204](https://www.rfc-editor.org/rfc/rfc9204) (QPACK) and
//! [RFC 9297](https://www.rfc-editor.org/rfc/rfc9297) (HTTP/3 datagrams).

pub use rama_quic_proto::{VarInt, VarIntDecoder};

// H2 and H3 share pseudo-header vocabulary, ordering and sensitivity metadata.
pub use super::h2::{
    PseudoHeader, PseudoHeaderOrder, PseudoHeaderOrderIter, PseudoHeaderSensitivity,
};

pub mod control;
pub mod critical_streams;

mod error;
pub use error::Code;

mod stream;
pub use stream::StreamType;

mod frame;
pub use frame::{FrameHeader, FrameType};

mod datagram;
pub use datagram::{InvalidQuarterStreamId, QuarterStreamId};

mod settings;
pub use settings::{
    ClientSettingsProfile, DEFAULT_MAX_SETTINGS_ENTRIES, Setting, SettingId, Settings,
    SettingsError,
};

pub mod qpack;

pub mod observation;
