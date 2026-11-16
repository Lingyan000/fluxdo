//! Rama http protocol implementation and low level utilities.
//!
//! # Cancel safety
//!
//! Futures returned by this crate's senders are cancel safe: dropping a future before it
//! completes is the supported way to cancel the operation. The protocol in
//! use changes what that cancellation actually does on the wire:
//!
//! - **HTTP/1** has no in-protocol way to abort a single request without
//!   affecting the shared connection, so dropping an in-flight request future
//!   closes the underlying TCP connection. Any subsequent call on the same
//!   `SendRequest` returns a `canceled` error; the connection cannot be
//!   reused.
//! - **HTTP/2** resets the single stream with `RST_STREAM` (`CANCEL` error
//!   code) and notifies the peer immediately rather than continuing to
//!   deliver a response body that would be discarded. The shared connection
//!   stays usable for other in-flight and future requests.
//!
//! See the documentation on individual futures — for example
//! `SendRequest::send_request` in `client::conn::http1` and the equivalent
//! in `client::conn::http2` — for the protocol-specific behavior on
//! cancellation.
//!
//! # Rama
//!
//! Crate used by the end-user `rama` crate and `rama` crate authors alike.
//!
//! Learn more about `rama`:
//!
//! - Github: <https://github.com/plabayo/rama>
//! - Book: <https://ramaproxy.org/book/>
//!
//! ## rama-http-core
//!
//! ### Features
//!
//! - HTTP/1, HTTP/2 and HTTP/3
//! - Asynchronous design
//! - Leading in performance
//! - Tested and **correct**
//! - Extensive production use
//! - [Client](client/index.html) and [Server](server/index.html) APIs

#![doc(
    html_favicon_url = "https://raw.githubusercontent.com/plabayo/rama/main/docs/img/rama_logo.svg"
)]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/plabayo/rama/main/docs/img/rama_logo.svg"
)]
#![cfg_attr(docsrs, feature(doc_cfg))]
#![cfg_attr(test, allow(clippy::float_cmp))]
#![cfg_attr(feature = "unstable", expect(clippy::allow_attributes))]
#![allow(unreachable_pub)]
#![expect(
    clippy::panic,
    clippy::unreachable,
    reason = "vendored from upstream `hyper`/`h2`: matches upstream invariant-violation panicking style and macro-internal `#[allow]` attrs"
)]

pub mod body;

mod common;

mod error;
pub use self::error::{Error, Result};

pub mod h2;
#[cfg(feature = "quic")]
#[cfg_attr(docsrs, doc(cfg(feature = "quic")))]
pub mod h3;

pub mod service;

mod headers;

pub(crate) mod proto;

pub mod client;
pub mod server;
