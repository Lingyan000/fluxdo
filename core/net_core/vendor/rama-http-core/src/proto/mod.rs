//! Pieces pertaining to the HTTP message protocol.

use rama_core::extensions::Extensions;
use rama_http::io::upgrade;
use rama_http_types::{HeaderMap, Method, Response, StatusCode, Version};
use rama_net::uri::Uri;

pub(crate) mod h1;

pub(crate) use self::h1::Conn;
pub(crate) use self::h1::ServerTransaction;
pub(crate) use self::h1::dispatch;

pub(crate) mod h2;

pub(crate) mod target;

/// An Incoming Message head. Includes request/status line, and headers.
#[derive(Debug, Default)]
pub(crate) struct MessageHead<S> {
    /// HTTP version of the message.
    pub(crate) version: Version,
    /// Subject (request line or status line) of Incoming message.
    pub(crate) subject: S,
    /// Headers of the Incoming message.
    pub(crate) headers: HeaderMap,
    /// Extensions.
    extensions: Extensions,
}

/// An incoming request message.
pub(crate) type RequestHead = MessageHead<RequestLine>;

#[derive(Debug, Default, PartialEq)]
pub(crate) struct RequestLine(pub(crate) Method, pub(crate) Uri);

/// An incoming response message.
pub(crate) type ResponseHead = MessageHead<StatusCode>;

#[derive(Debug)]
pub(crate) enum BodyLength {
    /// `Content-Length`.
    Known(u64),
    /// `Transfer-Encoding: chunked` (if h1).
    Unknown,
}

/// Status of when a Dispatcher future completes.
pub(crate) enum Dispatched {
    /// Dispatcher completely shutdown connection.
    Shutdown,
    /// Dispatcher has pending upgrade, and so did not shutdown.
    Upgrade(upgrade::Pending),
}

impl MessageHead<StatusCode> {
    fn into_response<B>(self, body: B) -> Response<B> {
        let mut res = Response::new(body);
        *res.status_mut() = self.subject;
        *res.headers_mut() = self.headers;
        *res.version_mut() = self.version;
        res.set_extensions(self.extensions);
        res
    }
}
