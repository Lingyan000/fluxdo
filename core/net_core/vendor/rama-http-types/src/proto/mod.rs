//! High level pertaining to the HTTP message protocol.
//!
//! For low-level proto details you can refer to the `proto` module
//! in the `rama-http-core` crate.

use std::{ops::Deref, sync::Arc};

use rama_core::extensions::Extension;

use crate::HeaderMap;

pub mod capsule;
pub mod ext;
pub mod h1;
pub mod h2;
pub mod h3;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Extension)]
#[extension(tags(http))]
/// Byte length of the raw bytes of the request/response headers (excl. trailers).
pub struct HeaderByteLength(pub usize);

#[derive(Debug, Clone, Extension)]
#[extension(tags(http))]
/// The headers of a request as the client sent them, in their original order.
///
/// The HTTP/1.1, HTTP/2 and HTTP/3 clients record it on the request after writing
/// its head, so its response, whose extensions fork the request's, carries it too.
/// "As sent" means the field lines the client put on the wire, after its own
/// adjustments: a repaired or omitted `Host`, framing headers it added or removed,
/// and the fields a version leaves out or rewrites (connection-specific fields,
/// `TE`). Names keep the casing they were given, while HTTP/2 and HTTP/3 send them
/// lowercase and HTTP/1.1 may title-case them.
pub struct RequestHeaders(Arc<HeaderMap>);

impl From<HeaderMap> for RequestHeaders {
    fn from(value: HeaderMap) -> Self {
        Self(Arc::new(value))
    }
}

impl From<Arc<HeaderMap>> for RequestHeaders {
    fn from(value: Arc<HeaderMap>) -> Self {
        Self(value)
    }
}

impl Deref for RequestHeaders {
    type Target = HeaderMap;

    fn deref(&self) -> &Self::Target {
        self.0.as_ref()
    }
}
