//! rama http types and minimal utilities
//!
//! # Rama
//!
//! Crate used by the end-user `rama` crate and `rama` crate authors alike.
//!
//! Learn more about `rama`:
//!
//! - Github: <https://github.com/plabayo/rama>
//! - Book: <https://ramaproxy.org/book/>

#![doc(
    html_favicon_url = "https://raw.githubusercontent.com/plabayo/rama/main/docs/img/rama_logo.svg"
)]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/plabayo/rama/main/docs/img/rama_logo.svg"
)]
#![cfg_attr(docsrs, feature(doc_cfg))]
#![cfg_attr(test, allow(clippy::float_cmp))]

use rama_core::extensions::Extension;
use rama_net::uri::Uri;

pub mod body;
pub use body::{
    Body, BodyCaptureEvent, BodyCaptureSink, BodyDataStream, BodyExtractExt, BodyLimit,
    BufferedBodyCapture, CaptureBody, CaptureCanceled, CaptureHandle, CaptureLimit, CaptureOutcome,
    CapturedBody, InfiniteReader, StreamingBody, sse,
};

pub mod request;
pub mod response;

#[macro_use]
mod convert;
pub mod method;
pub mod status;
pub mod structured_fields;

mod error;
#[doc(inline)]
pub use crate::header::{HeaderMap, HeaderName, HeaderValue, IntoOrderedIter, OrderedIter};
#[doc(inline)]
pub use crate::method::Method;
#[doc(inline)]
pub use crate::request::{HttpRequestParts, HttpRequestPartsMut, Request};
#[doc(inline)]
pub use crate::response::Response;
#[doc(inline)]
pub use crate::status::StatusCode;
#[doc(inline)]
pub use error::{Error, Result};
#[doc(inline)]
pub use rama_net::http::Version;

pub mod version {
    //! HTTP version type, owned by `rama-net`.

    #[doc(inline)]
    pub use rama_net::http::{InvalidVersion, Version};
}

/// Hosts the per-concern `*InputExt` accessor impls for http `Request`/`Parts`.
mod input_ext;
pub(crate) use input_ext::target_protocol_from_uri_or_extensions;

pub mod fingerprint;

mod body_limit_layer;
#[doc(inline)]
pub use body_limit_layer::{BodyLimitLayer, BodyLimitService};

pub mod stream {
    //! Stream-oriented utilities layered on top of the HTTP request type.

    pub mod matcher;
}

#[derive(Debug, Clone, Extension)]
#[extension(tags(http))]
/// Extension type that can be inserted in case a Uri is modified as part of nested routers
pub struct OriginalRouterUri(pub Uri);

pub mod proto;

pub mod opentelemetry;

pub mod conn;

pub mod proxy;

pub mod header;

pub mod mime {
    //! Re-export of the [`mime`] crate.
    //!
    //! Support MIME (Media Types) as strong types in Rust.
    //!
    //! [`mime`]: https://docs.rs/mime

    #[doc(inline)]
    pub use mime::*;

    #[doc(inline)]
    pub use mime_guess as guess;
}
