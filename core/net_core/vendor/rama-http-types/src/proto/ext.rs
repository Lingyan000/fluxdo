//! Message extensions shared by the HTTP protocol versions.

use crate::{header::is_token, proto::h2::hpack::BytesStr};

use rama_core::bytes::Bytes;
use rama_core::extensions::Extension;
use std::fmt;

/// An HTTP upgrade token: the `:protocol` pseudo-header of
/// [Extended CONNECT](https://datatracker.ietf.org/doc/html/rfc8441#section-4) on HTTP/2
/// (RFC 8441) and HTTP/3 (RFC 9220), or the HTTP/1.1 `Upgrade` token it replaces.
///
/// Any registered or private token is representable (`websocket`, `connect-udp`, ...). Whether
/// an application serves a token is its own policy; RFC 9220 §3 recommends `501` otherwise.
///
/// The value is a validated, non-empty HTTP token (RFC 9110 §5.6.2). Every construction path
/// enforces that invariant, so a `Protocol` can never hold an empty or non-token value that
/// would be illegal on the wire.
///
/// # Example
///
/// ```rust
/// use rama_core::extensions::ExtensionsRef;
/// use rama_http_types::proto::ext::Protocol;
/// use rama_http_types::{Request, Method, Version};
///
/// let mut req = Request::new(());
/// *req.method_mut() = Method::CONNECT;
/// *req.version_mut() = Version::HTTP_2;
/// req.extensions().insert(Protocol::WEBSOCKET);
/// // Now the request will include the `:protocol` pseudo-header with value "websocket"
/// ```
#[derive(Clone, Eq, PartialEq, Extension)]
#[extension(tags(http))]
pub struct Protocol {
    value: BytesStr,
}

impl Protocol {
    /// `websocket`, the token registered by RFC 8441 for the WebSocket Protocol.
    ///
    /// It is used for Extended CONNECT over both HTTP/2 (RFC 8441) and HTTP/3 (RFC 9220).
    pub const WEBSOCKET: Self = Self::from_static("websocket");

    /// `connect-udp`, the token registered by RFC 9298 for proxying UDP in HTTP (MASQUE).
    ///
    /// It upgrades an HTTP/1.1 `GET` and names Extended CONNECT on HTTP/2 and HTTP/3.
    pub const CONNECT_UDP: Self = Self::from_static("connect-udp");

    /// `connect-ip`, the token registered by RFC 9484 for proxying IP in HTTP.
    pub const CONNECT_IP: Self = Self::from_static("connect-ip");

    /// Converts a static string to a protocol name.
    ///
    /// # Panics
    ///
    /// Panics if `value` is not a non-empty HTTP token. Because a `:protocol` value that is not
    /// a token cannot be sent on the wire, an invalid literal is a programming error rather than
    /// a runtime condition.
    #[must_use]
    pub const fn from_static(value: &'static str) -> Self {
        assert!(
            is_token(value.as_bytes()),
            "`:protocol` value must be a non-empty HTTP token"
        );
        Self {
            value: BytesStr::from_static(value),
        }
    }

    /// Returns a str representation of the header.
    pub fn as_str(&self) -> &str {
        self.value.as_str()
    }

    /// Returns true for the [`WEBSOCKET`](Self::WEBSOCKET) token, compared case-insensitively.
    #[must_use]
    pub fn is_websocket(&self) -> bool {
        self.as_str().eq_ignore_ascii_case(Self::WEBSOCKET.as_str())
    }

    /// Parses a `:protocol` value from raw wire bytes, validating that it is a non-empty token.
    /// The same protocol in bytes of its own.
    pub(crate) fn detached(&self) -> Self {
        Self {
            value: self.value.detached(),
        }
    }

    pub fn try_from_bytes(bytes: Bytes) -> Result<Self, InvalidProtocol> {
        if !is_token(bytes.as_ref()) {
            return Err(InvalidProtocol::new());
        }
        // a token is ASCII, so the bytes are valid UTF-8; validate defensively rather than
        // reaching for an unchecked conversion.
        let value = BytesStr::try_from(bytes)?;
        Ok(Self { value })
    }
}

impl TryFrom<Bytes> for Protocol {
    type Error = InvalidProtocol;

    fn try_from(bytes: Bytes) -> Result<Self, Self::Error> {
        Self::try_from_bytes(bytes)
    }
}

impl<'a> TryFrom<&'a str> for Protocol {
    type Error = InvalidProtocol;

    fn try_from(value: &'a str) -> Result<Self, Self::Error> {
        Self::try_from_bytes(Bytes::copy_from_slice(value.as_bytes()))
    }
}

impl AsRef<[u8]> for Protocol {
    fn as_ref(&self) -> &[u8] {
        self.value.as_ref()
    }
}

impl fmt::Debug for Protocol {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        self.value.fmt(f)
    }
}

/// The `:scheme` pseudo-header value of a request carrying `:protocol` (Extended CONNECT).
///
/// RFC 8441 §5 (reused by RFC 9220 §3 for HTTP/3) requires `https` for a `wss` target and
/// `http` for a `ws` target; other schemes are sent as they are. Only the pseudo-header is
/// mapped: the request URI keeps its `ws`/`wss` scheme.
#[must_use]
pub fn extended_connect_pseudo_scheme(scheme: &rama_net::Protocol) -> &rama_net::Protocol {
    if *scheme == rama_net::Protocol::WSS {
        &rama_net::Protocol::HTTPS
    } else if *scheme == rama_net::Protocol::WS {
        &rama_net::Protocol::HTTP
    } else {
        scheme
    }
}

/// Whether an HTTP/2 or HTTP/3 request for `uri` sends an empty `:path`: only a target without
/// path and query whose `:scheme` on the wire, `wire_scheme` (after
/// [`extended_connect_pseudo_scheme`]), is not http(s), which turn a missing path into `/`
/// (RFC 9113 §8.3.1, RFC 9114 §4.3.1). A query is always sent, after a `/`.
#[must_use]
pub fn sends_empty_path(uri: &rama_net::uri::Uri, wire_scheme: &rama_net::Protocol) -> bool {
    !uri.is_asterisk() && uri.is_path_empty() && uri.query().is_none() && !wire_scheme.is_http()
}

rama_utils::macros::error::static_str_error! {
    #[doc = "`:protocol` pseudo-header value is not a non-empty HTTP token"]
    #[derive(Copy)]
    pub struct InvalidProtocol;
}

impl From<std::str::Utf8Error> for InvalidProtocol {
    fn from(_: std::str::Utf8Error) -> Self {
        // a validated token is ASCII, so this is unreachable in practice; map it defensively.
        Self::new()
    }
}

/// Declares that a message's upgrade token defines HTTP Datagram semantics (RFC 9297 §2).
///
/// A syntactically valid `:protocol` never implies datagrams. An HTTP/3 client sets this on
/// the request extensions of an Extended CONNECT; a server sets it on the extensions of the
/// `2xx` response it sends to one. Without it, received datagrams for the request are handled
/// as violations. A relay may declare it on each leg based on `Capsule-Protocol: ?1` alone,
/// without understanding the token (RFC 9297 §3.4).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Extension)]
#[extension(tags(http))]
pub struct HttpDatagrams;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn websocket_constant() {
        assert_eq!(Protocol::WEBSOCKET.as_str(), "websocket");
    }

    #[test]
    fn from_static_valid() {
        assert_eq!(Protocol::from_static("connect-udp").as_str(), "connect-udp");
    }

    #[test]
    #[should_panic(expected = "non-empty HTTP token")]
    fn from_static_empty_panics() {
        let _p = Protocol::from_static("");
    }

    #[test]
    #[should_panic(expected = "non-empty HTTP token")]
    fn from_static_non_token_panics() {
        let _p = Protocol::from_static("bad protocol");
    }

    #[test]
    fn try_from_bytes_valid() {
        let p = Protocol::try_from_bytes(Bytes::from_static(b"websocket")).unwrap();
        assert_eq!(p.as_str(), "websocket");
    }

    #[test]
    fn try_from_bytes_rejects_empty() {
        Protocol::try_from_bytes(Bytes::new()).unwrap_err();
    }

    #[test]
    fn try_from_bytes_rejects_non_token() {
        // space is not a tchar
        Protocol::try_from_bytes(Bytes::from_static(b"web socket")).unwrap_err();
        // control byte
        Protocol::try_from_bytes(Bytes::from_static(b"web\x01")).unwrap_err();
        // delimiter
        Protocol::try_from_bytes(Bytes::from_static(b"a/b")).unwrap_err();
    }

    #[test]
    fn try_from_str() {
        assert_eq!(Protocol::try_from("h2c").unwrap().as_str(), "h2c");
        Protocol::try_from("").unwrap_err();
        Protocol::try_from("a b").unwrap_err();
    }
}
