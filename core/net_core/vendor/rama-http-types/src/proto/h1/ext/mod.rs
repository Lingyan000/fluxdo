//! Public http1 Extensions
//!
//! This module provides types and utilities that extend the capabilities of HTTP1 requests and responses
//! in Rama. Extensions are additional pieces of information or features that can be attached to HTTP1
//! messages via the [`rama_core::extensions::Extensions`] map, which is
//! accessible through the methods provided by the
//! [`rama_core::extensions::ExtensionsRef`]
//! traits implemented for [`crate::Request`] and [`crate::Response`].
//!
//! # What are extensions?
//!
//! Extensions allow Rama to associate extra metadata or behaviors with HTTP messages, beyond the standard
//! headers and body. These can be used by advanced users and library authors to access protocol-specific
//! features, track original header casing, handle informational responses, and more.
//!
//! See for more information the rama book:
//! <https://ramaproxy.org/book/intro/state.html#extensions>
//!
//! # How to access extensions
//!
//! Extensions are stored in the `Extensions` map of a request or response. You can access them using:
//!
//! ```rust
//! # use rama_core::extensions::ExtensionsRef;
//! # let response = rama_http_types::Response::new(());
//! if let Some(ext) = response.extensions().get_ref::<rama_http_types::proto::h1::ext::ReasonPhrase>() {
//!     // use the extension
//! }
//! ```

mod reason_phrase;
pub use reason_phrase::{InvalidReasonPhrase, ReasonPhrase};

mod response_framing;
pub use response_framing::{CloseDelimitedResponse, OriginalResponseBodyFraming};

mod connection_close;
pub use connection_close::ConnectionClose;

mod request_target_form;
pub use request_target_form::RequestTargetForm;

pub mod informational;
