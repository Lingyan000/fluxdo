//! HTTP/3 client/server engine and connection-scoped codecs (RFC 9114, RFC 9204).
//!
//! This module holds the stateful pieces that sit above the pure wire vocabulary in
//! [`rama_http_types::proto::h3`]: the bounded incremental frame reader and the stateful QPACK
//! encoder/decoder with their dynamic tables and blocked-section accounting.
//!
//! [`client`] and [`server`] expose Rama requests, responses and the common
//! [`crate::body::Incoming`] body. Run their accompanying [`connection::Driver`]
//! concurrently to drive control and QPACK streams independently of application bodies.
//! The underlying frame and compression codecs also remain usable synchronously.
//!
//! Received field lines retain their order, duplicates, values and sensitivity in
//! the common header map; encoders use its ordered iterator. Names must be lowercase
//! on the H3 wire. The shared [`rama_http_types::proto::h3::PseudoHeaderOrder`] and
//! [`rama_http_types::proto::h3::PseudoHeaderSensitivity`] extensions retain pseudo-field
//! ordering and never-index requirements across forwarding and message edits.
//! Split Cookie lines stay separate in this H3 API, as in H2. Before passing them to
//! a non-H2/H3 context (including a generic server application), coalesce them using
//! `rama_http::layer::remove_header::coalesce_cookie_headers`; the HTTP/1 version
//! adapter does this automatically.
//!
//! Ordinary CONNECT and Extended CONNECT (RFC 9220, when [`connection::Config::extended_connect`]
//! is set on a server) expose their tunnels through Rama's upgrade API after a 2xx response.
//! Extended CONNECT tunnels declared with
//! [`HttpDatagrams`](rama_http_types::proto::ext::HttpDatagrams) (client request, server `2xx`
//! response) publish a [`rama_http::datagram::NativeDatagrams`] carrier (RFC 9297 §2.1). The
//! driver alone reads QUIC DATAGRAM frames and files them per request within
//! [`DatagramConfig`]; datagrams for other requests follow its violation policy. Use
//! [`rama_http::datagram::HttpDatagramSession`] on the tunnel.
//!
//! h3 runs over any [`transport::Connection`]. [`transport::Reversed`] swaps the roles, so a
//! QUIC client can serve HTTP/3 to the QUIC server it dialed.
//!
//! This is HTTP message forwarding, not a wire capture/replay API: URI serialization
//! can normalize pseudo-field values, and connection settings, unknown frames, frame
//! boundaries and QPACK representations are not reproduced on another connection.
//!
//! The frame decoder accepts owned [`rama_core::bytes::Bytes`] through
//! [`frame::FrameDecoder::feed_bytes`]. Drain `poll` until it needs more input before feeding the
//! next chunk; rejected input stays with the caller. Contiguous payloads share their input storage,
//! and only fragmented known payloads are coalesced. Input chunk and frame limits are independent.
//!
//! QPACK encoders accept ordinary name/value tuples or [`qpack::EncodeField`] inputs preserving
//! sensitivity. [`qpack::EncodeField::from_header`] carries Rama header sensitivity across the
//! boundary, and decoded [`qpack::FieldPair`] values can be forwarded directly. Optional dynamic
//! compression falls back to literals when reference or encoder-output budgets are exhausted.
//!
//! Drain both QPACK instruction outputs regularly. [`qpack::QpackError::OutputBlocked`] is local
//! backpressure with no wire error code; retry after draining (or split an oversized input batch).
//! Other errors expose their wire code and stream/connection scope. A driver abandoning a field
//! section must also arrange stream cancellation so the remote encoder can release references.
//! Plain decoded literals share section storage. Blocked sections and dynamic-table literals use
//! compact owned storage instead, so small retained slices cannot pin unrelated large buffers.

pub mod frame;
pub mod qpack;

mod control;
mod cooperative;
mod error;
pub use error::Error;

mod quic;
pub mod transport;

mod headers;

pub mod connection;
pub mod observation;
pub mod qlog;

pub(crate) mod body;
mod stream;

pub mod client;

pub mod server;

#[cfg(test)]
mod tests;

mod priority;
pub use priority::{PriorityHandle, PriorityObserver};

mod upgrade;

mod datagram;
pub use datagram::{DatagramConfig, DatagramDrops, DatagramLimits, MIN_DATAGRAM_CHARGE};

#[cfg(feature = "opentelemetry")]
mod telemetry;
#[cfg(feature = "opentelemetry")]
pub use telemetry::H3Metrics;

pub mod push;

#[cfg(feature = "fuzz-utils")]
#[doc(hidden)]
pub mod fuzz;
