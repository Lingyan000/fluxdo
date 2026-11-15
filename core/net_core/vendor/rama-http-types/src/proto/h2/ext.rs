//! Extensions specific to the HTTP/2 protocol.

use crate::proto::h2::frame::Reason;

use rama_core::extensions::Extension;

/// Reset the HTTP/2 stream with this [`Reason`] instead of sending the
/// response carrying it.
///
/// Only the HTTP/2 server acts on it; other versions send the response
/// as is, so attach it to a response that is a sane fallback.
///
/// [`Reason::REFUSED_STREAM`] tells the client the request was not
/// processed, which makes it safe to retry (RFC 9113 section 8.7).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Extension)]
#[extension(tags(http))]
pub struct ResetStream(pub Reason);
