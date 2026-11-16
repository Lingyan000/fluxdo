//! Standalone HTTP/1 message-head parsing and encoding.
//!
//! This module handles only a request or response line plus header fields.
//! It deliberately does not infer or encode an HTTP body framing mode, which
//! makes it suitable for protocols such as ICAP that carry HTTP heads while
//! framing the associated entity body themselves.

use core::fmt;

use rama_core::{
    bytes::{BufMut, Bytes},
    extensions::{Extensions, ExtensionsRef as _},
};
use rama_net::{client::EstablishedProxyRoute, uri::Uri};

use crate::{
    HeaderMap, HeaderName, HeaderValue, Method, Request, Response, StatusCode, Version,
    proto::{
        HeaderByteLength,
        ext::Protocol,
        h1::ext::{ReasonPhrase, RequestTargetForm},
    },
};

/// Default maximum number of HTTP header fields in one standalone head.
pub const DEFAULT_MAX_HEADERS: usize = 100;

/// Standalone HTTP/1 message-head parser configuration.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct HeadParser {
    max_headers: usize,
}

impl HeadParser {
    /// Construct a strict parser with bounded header storage.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            max_headers: DEFAULT_MAX_HEADERS,
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set the maximum number of header fields in one head.
        pub const fn max_headers(mut self, max_headers: usize) -> Self {
            self.max_headers = max_headers;
            self
        }
    }

    /// Parse one complete HTTP/1 request head.
    pub fn parse_request(&self, input: &Bytes) -> Result<Request<()>, HeadError> {
        validate_crlf(input)?;
        let mut slots = vec![httparse::EMPTY_HEADER; self.max_headers];
        let mut parsed = httparse::Request::new(&mut slots);
        let consumed = complete(parsed.parse(input).map_err(HeadError::from_httparse)?)?;
        if consumed != input.len() {
            return Err(HeadError::new(HeadErrorKind::TrailingBytes));
        }

        let method = Method::from_bytes(
            parsed
                .method
                .ok_or_else(|| HeadError::new(HeadErrorKind::InvalidMethod))?
                .as_bytes(),
        )
        .map_err(|_error| HeadError::new(HeadErrorKind::InvalidMethod))?;
        let target = input.slice_ref(
            parsed
                .path
                .ok_or_else(|| HeadError::new(HeadErrorKind::InvalidTarget))?
                .as_bytes(),
        );
        if target.as_ref() == b"*" && method != Method::OPTIONS {
            return Err(HeadError::new(HeadErrorKind::InvalidTarget));
        }
        let uri = Uri::parse_http_request_target(target.clone(), method == Method::CONNECT)
            .map_err(|_error| HeadError::new(HeadErrorKind::InvalidTarget))?;
        let target_form = if target.as_ref() == b"*" {
            RequestTargetForm::Asterisk
        } else if method == Method::CONNECT {
            RequestTargetForm::Authority
        } else if uri.scheme().is_some() {
            RequestTargetForm::Absolute
        } else {
            RequestTargetForm::Origin
        };
        let version = parse_version(parsed.version)?;
        let headers = parse_headers(input, parsed.headers)?;
        let extensions = Extensions::new();
        extensions.insert(HeaderByteLength(input.len()));
        extensions.insert(target_form);

        Ok(Request::from_parts(
            crate::request::Parts {
                method,
                uri,
                version,
                headers,
                extensions,
            },
            (),
        ))
    }

    /// Parse one complete HTTP/1 response head.
    pub fn parse_response(&self, input: &Bytes) -> Result<Response<()>, HeadError> {
        validate_crlf(input)?;
        let mut slots = vec![httparse::EMPTY_HEADER; self.max_headers];
        let mut parsed = httparse::Response::new(&mut slots);
        let consumed = complete(parsed.parse(input).map_err(HeadError::from_httparse)?)?;
        if consumed != input.len() {
            return Err(HeadError::new(HeadErrorKind::TrailingBytes));
        }

        let version = parse_version(parsed.version)?;
        let status = StatusCode::from_u16(
            parsed
                .code
                .ok_or_else(|| HeadError::new(HeadErrorKind::InvalidStatus))?,
        )
        .map_err(|_error| HeadError::new(HeadErrorKind::InvalidStatus))?;
        let headers = parse_headers(input, parsed.headers)?;
        let extensions = Extensions::new();
        extensions.insert(HeaderByteLength(input.len()));
        let reason = raw_response_reason(input)?;
        if status
            .canonical_reason()
            .is_none_or(|canonical| reason != canonical.as_bytes())
        {
            let reason = ReasonPhrase::try_from(reason)
                .map_err(|_error| HeadError::new(HeadErrorKind::InvalidStatus))?;
            extensions.insert(reason);
        }

        Ok(Response::from_parts(
            crate::response::Parts {
                status,
                version,
                headers,
                extensions,
            },
            (),
        ))
    }

    /// Parse one complete HTTP/1 header or trailer field block.
    ///
    /// `input` includes the final empty line. Header values retain shared
    /// slices of the supplied [`Bytes`] allocation.
    pub fn parse_fields(&self, input: &Bytes) -> Result<HeaderMap, HeadError> {
        validate_crlf(input)?;
        let mut slots = vec![httparse::EMPTY_HEADER; self.max_headers];
        let (consumed, fields) = complete(
            httparse::parse_headers(input, &mut slots).map_err(HeadError::from_httparse)?,
        )?;
        if consumed != input.len() {
            return Err(HeadError::new(HeadErrorKind::TrailingBytes));
        }
        parse_headers(input, fields)
    }
}

fn raw_response_reason(input: &Bytes) -> Result<Bytes, HeadError> {
    let line_end = input
        .windows(2)
        .position(|window| window == b"\r\n")
        .ok_or_else(|| HeadError::new(HeadErrorKind::Incomplete))?;
    let line = &input[..line_end];
    let suffix = line
        .get(12..)
        .ok_or_else(|| HeadError::new(HeadErrorKind::InvalidStatus))?;
    let reason_start = match suffix.first() {
        Some(b' ') => 13,
        None => 12,
        Some(_) => return Err(HeadError::new(HeadErrorKind::InvalidStatus)),
    };
    Ok(input.slice(reason_start..line_end))
}

impl Default for HeadParser {
    fn default() -> Self {
        Self::new()
    }
}

fn complete<T>(status: httparse::Status<T>) -> Result<T, HeadError> {
    match status {
        httparse::Status::Complete(consumed) => Ok(consumed),
        httparse::Status::Partial => Err(HeadError::new(HeadErrorKind::Incomplete)),
    }
}

fn validate_crlf(input: &[u8]) -> Result<(), HeadError> {
    for (index, byte) in input.iter().copied().enumerate() {
        let valid = match byte {
            b'\r' => input.get(index + 1) == Some(&b'\n'),
            b'\n' => index > 0 && input[index - 1] == b'\r',
            _ => true,
        };
        if !valid {
            return Err(HeadError::new(HeadErrorKind::InvalidSyntax));
        }
    }
    Ok(())
}

fn parse_version(version: Option<u8>) -> Result<Version, HeadError> {
    match version {
        Some(0) => Ok(Version::HTTP_10),
        Some(1) => Ok(Version::HTTP_11),
        _ => Err(HeadError::new(HeadErrorKind::InvalidVersion)),
    }
}

fn parse_headers(input: &Bytes, fields: &[httparse::Header<'_>]) -> Result<HeaderMap, HeadError> {
    let mut headers = HeaderMap::with_capacity(fields.len());
    for field in fields {
        let name = HeaderName::from_bytes(field.name.as_bytes())
            .map_err(|_error| HeadError::new(HeadErrorKind::InvalidHeader))?;
        let mut value = HeaderValue::from_maybe_shared(input.slice_ref(field.value))
            .map_err(|_error| HeadError::new(HeadErrorKind::InvalidHeader))?;
        if name.is_sensitive() {
            value.set_sensitive(true);
        }
        headers.append(name, value);
    }
    Ok(headers)
}

/// Encode one standalone HTTP/1 request head.
pub fn encode_request<T>(request: &Request<T>) -> Result<Bytes, HeadError> {
    // The request line rarely needs more than 128 bytes beside its method.
    let mut output = Vec::with_capacity(
        request.method().as_str().len() + 128 + header_fields_len(request.headers()),
    );
    output.extend_from_slice(request.method().as_str().as_bytes());
    output.extend_from_slice(b" ");
    encode_request_target_preserving_form(
        request.method(),
        request.uri(),
        request.extensions(),
        &mut output,
    )?;
    output.extend_from_slice(b" ");
    encode_version(request.version(), &mut output)?;
    output.extend_from_slice(b"\r\n");
    encode_header_fields(request.headers(), &mut output);
    output.extend_from_slice(b"\r\n");
    Ok(Bytes::from(output))
}

/// Encode one standalone HTTP/1 response head.
pub fn encode_response<T>(response: &Response<T>) -> Result<Bytes, HeadError> {
    // The status line rarely needs more than 64 bytes.
    let mut output = Vec::with_capacity(64 + header_fields_len(response.headers()));
    encode_version(response.version(), &mut output)?;
    output.extend_from_slice(b" ");
    output.extend_from_slice(response.status().as_str().as_bytes());
    output.extend_from_slice(b" ");
    if let Some(reason) = response.extensions().get_ref::<ReasonPhrase>() {
        output.extend_from_slice(reason.as_bytes());
    } else {
        output.extend_from_slice(
            response
                .status()
                .canonical_reason()
                .unwrap_or("<none>")
                .as_bytes(),
        );
    }
    output.extend_from_slice(b"\r\n");
    encode_header_fields(response.headers(), &mut output);
    output.extend_from_slice(b"\r\n");
    Ok(Bytes::from(output))
}

/// The encoded size of `headers`, each field with its `: ` and CRLF.
fn header_fields_len(headers: &HeaderMap) -> usize {
    headers
        .ordered_iter()
        .map(|(name, value)| name.as_str().len() + value.len() + 4)
        .sum()
}

fn encode_version(version: Version, output: &mut Vec<u8>) -> Result<(), HeadError> {
    match version {
        Version::HTTP_10 => output.extend_from_slice(b"HTTP/1.0"),
        Version::HTTP_11 | Version::HTTP_2 | Version::HTTP_3 => {
            output.extend_from_slice(b"HTTP/1.1");
        }
        _ => return Err(HeadError::new(HeadErrorKind::UnsupportedVersion)),
    }
    Ok(())
}

fn encode_request_target_preserving_form(
    method: &Method,
    uri: &Uri,
    extensions: &Extensions,
    output: &mut Vec<u8>,
) -> Result<(), HeadError> {
    if let Some(form) = extensions.get_ref::<RequestTargetForm>() {
        let result = match form {
            RequestTargetForm::Origin if *method != Method::CONNECT && !uri.is_asterisk() => {
                uri.write_http_origin_form(output)
            }
            RequestTargetForm::Absolute if *method != Method::CONNECT && !uri.is_asterisk() => {
                write_absolute_form(method, uri, None, output)
            }
            RequestTargetForm::Authority
                if *method == Method::CONNECT && is_http1_connect_target(uri, extensions) =>
            {
                uri.write_http_authority_form(output)
            }
            RequestTargetForm::Asterisk if *method == Method::OPTIONS && uri.is_asterisk() => {
                output.push(b'*');
                Ok(())
            }
            _ => Err(rama_net::uri::WireError::AsteriskMismatch),
        };
        return result.map_err(|_error| HeadError::new(HeadErrorKind::InvalidTarget));
    }
    encode_request_target(method, uri, extensions, output)
}

/// Whether an HTTP/1 `CONNECT` can name `uri`: as `host:port` (RFC 9112 §3.2.3), and never as
/// an Extended CONNECT, whose HTTP/1.1 form is an `Upgrade` request instead (RFC 8441 §5).
#[must_use]
pub fn is_http1_connect_target(uri: &Uri, extensions: &Extensions) -> bool {
    uri.port_u16().is_some() && !extensions.contains::<Protocol>()
}

/// Encode the HTTP/1 request-target selected by Rama connection metadata.
///
/// Direct requests use origin-form, `CONNECT` uses authority-form, `OPTIONS
/// *` uses asterisk-form, and insecure requests on an established HTTP forward
/// proxy connection use absolute-form, with the resolved protocol as scheme for a
/// URI without one; a URI with neither a scheme nor an authority cannot name its
/// origin there and is sent as it would be directly (origin-form, or `*` for a
/// server-wide OPTIONS),
/// leaving the origin to the `Host` header. Fragments are never
/// emitted, nor is userinfo for HTTP-family schemes (see
/// [`Uri::write_http_absolute_form`]), and a rootless path is sent rooted. Route
/// intent is deliberately ignored: the established connection route is the only
/// authoritative signal after fallback and pool selection. When an
/// [`Egress`](rama_core::extensions::Egress) connection snapshot is present, its
/// route (including absence) takes precedence over request-local metadata.
/// Low-level callers without a connection snapshot must insert
/// [`EstablishedProxyRoute::Forward`] themselves.
///
/// On error nothing is written to `output`.
pub fn encode_request_target(
    method: &Method,
    uri: &Uri,
    extensions: &Extensions,
    output: &mut Vec<u8>,
) -> Result<(), HeadError> {
    let result = if *method == Method::CONNECT {
        if !is_http1_connect_target(uri, extensions) {
            return Err(HeadError::new(HeadErrorKind::InvalidTarget));
        }
        uri.write_http_authority_form(output)
    } else if uri.is_asterisk() && *method == Method::OPTIONS {
        output.push(b'*');
        Ok(())
    } else if uri.is_asterisk() {
        Err(rama_net::uri::WireError::AsteriskMismatch)
    } else {
        let protocol = crate::target_protocol_from_uri_or_extensions(extensions, uri);
        // Secure targets are tunnelled, so only insecure ones look up the route.
        let via_http_proxy = !protocol.is_secure() && {
            let established_extensions = extensions.egress().map_or(extensions, |egress| &egress.0);
            established_extensions
                .get_ref::<EstablishedProxyRoute>()
                .is_some_and(EstablishedProxyRoute::is_http_forward)
        };
        if via_http_proxy && (uri.scheme().is_some() || uri.authority().is_some()) {
            write_absolute_form(method, uri, Some(protocol), output)
        } else if is_server_wide(method, uri) {
            output.push(b'*');
            Ok(())
        } else {
            uri.write_http_origin_form(output)
        }
    };
    result.map_err(|_error| HeadError::new(HeadErrorKind::InvalidTarget))
}

/// RFC 9112 §3.2.4: an OPTIONS request without a path is for the server as a whole.
fn is_server_wide(method: &Method, uri: &Uri) -> bool {
    *method == Method::OPTIONS && uri.is_path_empty() && uri.query().is_none()
}

/// A server-wide OPTIONS stays path-less up to the last hop, which sends it as `*`.
fn write_absolute_form(
    method: &Method,
    uri: &Uri,
    default_scheme: Option<&rama_net::Protocol>,
    output: &mut Vec<u8>,
) -> Result<(), rama_net::uri::WireError> {
    let start = output.len();
    match default_scheme {
        Some(scheme) => uri.write_http_absolute_form_with_default_scheme(scheme, output)?,
        None => uri.write_http_absolute_form(output)?,
    }
    if is_server_wide(method, uri) && output[start..].ends_with(b"/") {
        output.pop();
    }
    Ok(())
}

/// Encode HTTP header fields and the empty line ending them, as a trailer
/// section carries them, into an exactly sized buffer.
#[must_use]
pub fn encode_header_block(headers: &HeaderMap) -> Bytes {
    let mut output = Vec::with_capacity(header_fields_len(headers) + 2);
    encode_header_fields(headers, &mut output);
    output.extend_from_slice(b"\r\n");
    debug_assert_eq!(output.len(), output.capacity(), "sized exactly");
    Bytes::from(output)
}

/// Append HTTP header fields in their insertion order and original casing.
///
/// This emits the terminating CRLF of each field, but not the final empty
/// line that terminates a complete HTTP head.
pub fn encode_header_fields<B>(headers: &HeaderMap, output: &mut B)
where
    B: BufMut,
{
    for (name, value) in headers.ordered_iter() {
        name.write_original(output);
        output.put_slice(b": ");
        output.put_slice(value.as_bytes());
        output.put_slice(b"\r\n");
    }
}

/// Classification for standalone HTTP/1 message-head failures.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum HeadErrorKind {
    /// The input ended before a complete head was available.
    Incomplete,
    /// Bytes followed the terminating empty line.
    TrailingBytes,
    /// The configured header count bound was exceeded.
    TooManyHeaders,
    /// The request or response head syntax was invalid.
    InvalidSyntax,
    /// The request method was absent or invalid.
    InvalidMethod,
    /// The HTTP request-target was absent or invalid.
    InvalidTarget,
    /// The HTTP version was absent or invalid.
    InvalidVersion,
    /// The response status was absent or invalid.
    InvalidStatus,
    /// A header name or value was invalid.
    InvalidHeader,
    /// The typed version cannot be represented by this HTTP/1 codec.
    UnsupportedVersion,
}

/// Error returned by standalone HTTP/1 message-head operations.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct HeadError {
    kind: HeadErrorKind,
}

impl HeadError {
    const fn new(kind: HeadErrorKind) -> Self {
        Self { kind }
    }

    fn from_httparse(error: httparse::Error) -> Self {
        Self::new(if error == httparse::Error::TooManyHeaders {
            HeadErrorKind::TooManyHeaders
        } else {
            HeadErrorKind::InvalidSyntax
        })
    }

    /// Return the failure classification.
    #[must_use]
    pub const fn kind(&self) -> HeadErrorKind {
        self.kind
    }
}

impl fmt::Display for HeadError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self.kind {
            HeadErrorKind::Incomplete => "incomplete HTTP/1 message head",
            HeadErrorKind::TrailingBytes => "bytes follow the HTTP/1 message head",
            HeadErrorKind::TooManyHeaders => "too many HTTP/1 header fields",
            HeadErrorKind::InvalidSyntax => "invalid HTTP/1 message-head syntax",
            HeadErrorKind::InvalidMethod => "invalid HTTP/1 request method",
            HeadErrorKind::InvalidTarget => "invalid HTTP/1 request-target",
            HeadErrorKind::InvalidVersion => "invalid HTTP/1 version",
            HeadErrorKind::InvalidStatus => "invalid HTTP/1 response status",
            HeadErrorKind::InvalidHeader => "invalid HTTP/1 header field",
            HeadErrorKind::UnsupportedVersion => "unsupported version for HTTP/1 encoding",
        })
    }
}

impl std::error::Error for HeadError {}

#[cfg(test)]
mod tests {
    use super::*;
    use rama_net::address::ProxyAddress;

    #[test]
    fn http1_connect_names_host_and_port_and_never_carries_a_protocol() {
        for (uri, protocol, form, expected) in [
            (
                "https://example.test:443",
                false,
                None,
                Some("CONNECT example.test:443 "),
            ),
            ("https://example.test", false, None, None),
            ("https://example.test:443/chat", true, None, None),
            (
                "https://example.test:443",
                false,
                Some(RequestTargetForm::Authority),
                Some("CONNECT example.test:443 "),
            ),
            (
                "https://example.test:443",
                true,
                Some(RequestTargetForm::Authority),
                None,
            ),
        ] {
            let request = Request::builder()
                .method(Method::CONNECT)
                .uri(uri)
                .body(())
                .unwrap();
            if protocol {
                request.extensions().insert(Protocol::WEBSOCKET);
            }
            if let Some(form) = form {
                request.extensions().insert(form);
            }
            let encoded = encode_request(&request);
            match expected {
                Some(line) => assert!(
                    encoded.as_ref().unwrap().starts_with(line.as_bytes()),
                    "{uri} {protocol} {form:?}: {encoded:?}"
                ),
                None => assert_eq!(
                    encoded.unwrap_err().kind(),
                    HeadErrorKind::InvalidTarget,
                    "{uri} {protocol} {form:?}"
                ),
            }
        }
    }

    #[test]
    fn parses_request_without_copying_header_values() {
        let wire = Bytes::from_static(
            b"POST /scan?q=1 HTTP/1.1\r\nHost: example.test\r\nX-Test: value\r\n\r\n",
        );
        let request = HeadParser::new().parse_request(&wire).unwrap();

        assert_eq!(request.method(), Method::POST);
        assert_eq!(request.uri().as_str(), "/scan?q=1");
        assert_eq!(request.version(), Version::HTTP_11);
        let value = request.headers().get("x-test").unwrap().as_bytes();
        let value_start = value.as_ptr() as usize;
        let wire_start = wire.as_ptr() as usize;
        assert!(value_start >= wire_start);
        assert!(value_start < wire_start + wire.len());
        assert_eq!(
            request.extensions().get_ref::<HeaderByteLength>(),
            Some(&HeaderByteLength(wire.len())),
        );
    }

    #[test]
    fn response_round_trip_preserves_reason_and_field_order() {
        let wire =
            Bytes::from_static(b"HTTP/1.0 299 Adapted\r\nX-First: one\r\nX-Second: two\r\n\r\n");
        let response = HeadParser::new().parse_response(&wire).unwrap();

        assert_eq!(response.status().as_u16(), 299);
        assert_eq!(response.version(), Version::HTTP_10);
        assert_eq!(
            encode_response(&response).unwrap().as_ref(),
            b"HTTP/1.0 299 Adapted\r\nX-First: one\r\nX-Second: two\r\n\r\n"
        );
    }

    #[test]
    fn request_round_trip_preserves_target_form() {
        for wire in [
            b"GET /path?q=1 HTTP/1.1\r\nHost: example.test\r\n\r\n".as_slice(),
            b"GET http://example.test/path?q=1 HTTP/1.1\r\nHost: example.test\r\n\r\n",
            b"CONNECT example.test:443 HTTP/1.1\r\nHost: example.test:443\r\n\r\n",
            b"OPTIONS * HTTP/1.1\r\nHost: example.test\r\n\r\n",
            b"OPTIONS http://example.test:8001 HTTP/1.1\r\nHost: example.test:8001\r\n\r\n",
        ] {
            let request = HeadParser::new()
                .parse_request(&Bytes::copy_from_slice(wire))
                .unwrap();
            assert_eq!(encode_request(&request).unwrap().as_ref(), wire);
        }
        // A kept authority-form still needs a port once the target is rewritten.
        let mut request = HeadParser::new()
            .parse_request(&Bytes::from_static(
                b"CONNECT example.test:443 HTTP/1.1\r\nHost: example.test:443\r\n\r\n",
            ))
            .unwrap();
        *request.uri_mut() = Uri::parse_authority_form("example.test").unwrap();
        assert_eq!(
            encode_request(&request).unwrap_err().kind(),
            HeadErrorKind::InvalidTarget,
        );
    }

    #[test]
    fn response_round_trip_preserves_obs_text_reason() {
        let wire = Bytes::from_static(b"HTTP/1.1 200 Caf\xe9\r\nHost: example.test\r\n\r\n");
        let response = HeadParser::new().parse_response(&wire).unwrap();

        assert_eq!(
            response
                .extensions()
                .get_ref::<ReasonPhrase>()
                .unwrap()
                .as_bytes(),
            b"Caf\xe9",
        );
        assert_eq!(encode_response(&response).unwrap(), wire);
    }

    #[test]
    fn stores_only_noncanonical_reason_phrases() {
        let canonical = HeadParser::new()
            .parse_response(&Bytes::from_static(b"HTTP/1.1 200 OK\r\n\r\n"))
            .unwrap();
        assert!(canonical.extensions().get_ref::<ReasonPhrase>().is_none());

        let wire = Bytes::from_static(b"HTTP/1.1 200 Adapted\r\n\r\n");
        let custom = HeadParser::new().parse_response(&wire).unwrap();
        let reason = custom.extensions().get_ref::<ReasonPhrase>().unwrap();
        assert_eq!(reason.as_bytes(), b"Adapted");
        let reason_start = reason.as_bytes().as_ptr() as usize;
        let wire_start = wire.as_ptr() as usize;
        assert!(reason_start >= wire_start);
        assert!(reason_start < wire_start + wire.len());
    }

    #[test]
    fn enforces_http_request_target_forms() {
        for wire in [
            b"GET /scan#fragment HTTP/1.1\r\n\r\n".as_slice(),
            b"CONNECT user@example.test:443 HTTP/1.1\r\n\r\n",
            b"CONNECT example.test HTTP/1.1\r\n\r\n",
            b"GET * HTTP/1.1\r\n\r\n",
        ] {
            assert_eq!(
                HeadParser::new()
                    .parse_request(&Bytes::copy_from_slice(wire))
                    .unwrap_err()
                    .kind(),
                HeadErrorKind::InvalidTarget,
            );
        }

        for wire in [
            b"CONNECT example.test:443 HTTP/1.1\r\n\r\n".as_slice(),
            b"OPTIONS * HTTP/1.1\r\n\r\n",
            b"GET /scan?q=1 HTTP/1.1\r\n\r\n",
            b"GET http://example.test/scan HTTP/1.1\r\n\r\n",
        ] {
            HeadParser::new()
                .parse_request(&Bytes::copy_from_slice(wire))
                .unwrap();
        }
    }

    #[test]
    fn enforces_shared_request_target_length_bound() {
        let mut target = vec![b'a'; u16::MAX as usize - 1];
        target[0] = b'/';
        let mut wire = b"GET ".to_vec();
        wire.extend_from_slice(&target);
        wire.extend_from_slice(b" HTTP/1.1\r\n\r\n");
        HeadParser::new().parse_request(&Bytes::from(wire)).unwrap();

        target.push(b'a');
        let mut wire = b"GET ".to_vec();
        wire.extend_from_slice(&target);
        wire.extend_from_slice(b" HTTP/1.1\r\n\r\n");
        assert_eq!(
            HeadParser::new()
                .parse_request(&Bytes::from(wire))
                .unwrap_err()
                .kind(),
            HeadErrorKind::InvalidTarget,
        );
    }

    #[test]
    fn encodes_request_target_forms_and_coerces_higher_versions() {
        let request = Request::builder()
            .method(Method::GET)
            .uri("https://user@example.test/path?q=1#fragment")
            .version(Version::HTTP_2)
            .header("Host", "example.test")
            .body(())
            .unwrap();
        assert_eq!(
            encode_request(&request).unwrap().as_ref(),
            b"GET /path?q=1 HTTP/1.1\r\nHost: example.test\r\n\r\n",
        );

        let mut connect = Request::new(());
        *connect.method_mut() = Method::CONNECT;
        *connect.uri_mut() = Uri::parse_authority_form("example.test:443").unwrap();
        assert!(
            encode_request(&connect)
                .unwrap()
                .starts_with(b"CONNECT example.test:443 HTTP/1.1\r\n")
        );
        // RFC 9112 §3.2.3: there is no default port to send.
        *connect.uri_mut() = Uri::parse_authority_form("example.test").unwrap();
        assert_eq!(
            encode_request(&connect).unwrap_err().kind(),
            HeadErrorKind::InvalidTarget,
        );

        let mut wrong_asterisk = Request::new(());
        *wrong_asterisk.uri_mut() = Uri::parse("*").unwrap();
        assert_eq!(
            encode_request(&wrong_asterisk).unwrap_err().kind(),
            HeadErrorKind::InvalidTarget,
        );
    }

    #[test]
    fn forward_proxy_targets_keep_userinfo_outside_the_http_family() {
        let proxy: ProxyAddress = "http://proxy.example:8080".parse().unwrap();
        for (uri, target) in [
            (
                "http://user@origin.example/p",
                "GET http://origin.example/p HTTP/1.1\r\n",
            ),
            (
                "ftp://user:pw@origin.example/f",
                "GET ftp://user:pw@origin.example/f HTTP/1.1\r\n",
            ),
        ] {
            let request = Request::builder().uri(uri).body(()).unwrap();
            request
                .extensions()
                .insert(EstablishedProxyRoute::Forward(proxy.clone()));
            let encoded = encode_request(&request).unwrap();
            assert!(encoded.starts_with(target.as_bytes()), "{uri}: {encoded:?}");
        }
    }

    #[test]
    fn forward_proxy_targets_keep_a_server_wide_options_path_less() {
        let proxy: ProxyAddress = "http://proxy.example:8080".parse().unwrap();
        for (method, uri, target) in [
            (
                Method::OPTIONS,
                "http://origin.example:8001",
                "OPTIONS http://origin.example:8001 HTTP/1.1\r\n",
            ),
            (
                Method::OPTIONS,
                "http://origin.example/",
                "OPTIONS http://origin.example/ HTTP/1.1\r\n",
            ),
            (
                Method::OPTIONS,
                "http://origin.example?q",
                "OPTIONS http://origin.example/?q HTTP/1.1\r\n",
            ),
            (
                Method::GET,
                "http://origin.example",
                "GET http://origin.example/ HTTP/1.1\r\n",
            ),
        ] {
            let request = Request::builder().method(method).uri(uri).body(()).unwrap();
            request
                .extensions()
                .insert(EstablishedProxyRoute::Forward(proxy.clone()));
            let encoded = encode_request(&request).unwrap();
            assert!(encoded.starts_with(target.as_bytes()), "{uri}: {encoded:?}");
        }
    }

    #[test]
    fn established_proxy_route_overrides_route_intent() {
        use rama_net::client::ProxyRoute;

        let proxy: ProxyAddress = "http://proxy.example:8080".parse().unwrap();
        for (route, target) in [
            (
                Some(EstablishedProxyRoute::Forward(proxy.clone())),
                "GET http://origin.example/path?q=1 HTTP/1.1\r\n",
            ),
            (
                Some(EstablishedProxyRoute::Tunnel(proxy)),
                "GET /path?q=1 HTTP/1.1\r\n",
            ),
            (
                Some(EstablishedProxyRoute::Tunnel(
                    "socks5://proxy.example:1080".parse().unwrap(),
                )),
                "GET /path?q=1 HTTP/1.1\r\n",
            ),
            (
                Some(EstablishedProxyRoute::Direct),
                "GET /path?q=1 HTTP/1.1\r\n",
            ),
            (None, "GET /path?q=1 HTTP/1.1\r\n"),
        ] {
            let request = Request::builder()
                .uri("http://origin.example/path?q=1")
                .body(())
                .unwrap();
            request.extensions().insert(ProxyRoute::Proxy(
                "http://proxy.example:8080".parse::<ProxyAddress>().unwrap(),
            ));
            if let Some(route) = route.clone() {
                request.extensions().insert(route);
            }

            let encoded = encode_request(&request).unwrap();
            assert!(
                encoded.starts_with(target.as_bytes()),
                "unexpected request target for {route:?}: {encoded:?}"
            );
        }

        let request = Request::builder()
            .uri("http://origin.example/path?q=1")
            .body(())
            .unwrap();
        request.extensions().insert(ProxyRoute::Proxy(
            "http://proxy.example:8080".parse::<ProxyAddress>().unwrap(),
        ));
        let encoded = encode_request(&request).unwrap();
        assert!(
            encoded.starts_with(b"GET /path?q=1 HTTP/1.1\r\n"),
            "route intent without an established route must not select absolute-form: {encoded:?}"
        );
    }

    #[test]
    fn connection_snapshot_overrides_stale_local_route_including_absence() {
        use rama_core::extensions::Egress;
        use rama_net::address::ProxyAddress;

        let proxy: ProxyAddress = "http://proxy.example:8080".parse().unwrap();
        for route in [
            None,
            Some(EstablishedProxyRoute::Direct),
            Some(EstablishedProxyRoute::Tunnel(proxy.clone())),
            Some(EstablishedProxyRoute::Tunnel(
                "socks5://proxy.example:1080".parse().unwrap(),
            )),
            Some(EstablishedProxyRoute::Forward(proxy.clone())),
        ] {
            let is_forward = route
                .as_ref()
                .is_some_and(EstablishedProxyRoute::is_http_forward);
            let request = Request::builder()
                .uri("http://origin.example/path?q=1")
                .body(())
                .unwrap();
            request.extensions().insert(if is_forward {
                EstablishedProxyRoute::Direct
            } else {
                EstablishedProxyRoute::Forward(proxy.clone())
            });
            let connection = Extensions::new();
            if let Some(route) = route {
                connection.insert(route);
            }
            request.extensions().insert(Egress(connection));
            let encoded = encode_request(&request).unwrap();
            let target = if is_forward {
                b"GET http://origin.example/path?q=1 HTTP/1.1\r\n".as_slice()
            } else {
                b"GET /path?q=1 HTTP/1.1\r\n".as_slice()
            };
            assert!(
                encoded.starts_with(target),
                "unexpected request target: {encoded:?}"
            );
        }
    }

    #[test]
    fn enforces_complete_input_and_header_bounds() {
        let parser = HeadParser::new().with_max_headers(1);
        assert_eq!(
            parser
                .parse_request(&Bytes::from_static(b"GET / HTTP/1.1\r\n"))
                .unwrap_err()
                .kind(),
            HeadErrorKind::Incomplete,
        );
        assert_eq!(
            parser
                .parse_request(&Bytes::from_static(
                    b"GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\n\r\n",
                ))
                .unwrap_err()
                .kind(),
            HeadErrorKind::TooManyHeaders,
        );
        assert_eq!(
            parser
                .parse_response(&Bytes::from_static(b"HTTP/1.1 200 OK\r\n\r\nbody",))
                .unwrap_err()
                .kind(),
            HeadErrorKind::TrailingBytes,
        );
        for wire in [
            b"GET / HTTP/1.1\n\n".as_slice(),
            b"GET / HTTP/1.1\r\nX-Test: one\rvalue\r\n\r\n",
        ] {
            assert_eq!(
                HeadParser::new()
                    .parse_request(&Bytes::copy_from_slice(wire))
                    .unwrap_err()
                    .kind(),
                HeadErrorKind::InvalidSyntax,
            );
        }
    }

    #[test]
    fn parses_trailer_fields_without_copying_values() {
        let wire = Bytes::from_static(b"Digest: sha-256=abc\r\nX-End: yes\r\n\r\n");
        let fields = HeadParser::new().parse_fields(&wire).unwrap();

        assert_eq!(fields["digest"], "sha-256=abc");
        let value = fields["x-end"].as_bytes();
        let value_start = value.as_ptr() as usize;
        let wire_start = wire.as_ptr() as usize;
        assert!(value_start >= wire_start);
        assert!(value_start < wire_start + wire.len());
    }

    #[test]
    fn marks_parsed_credentials_and_cookies_sensitive() {
        use crate::header::{AUTHORIZATION, COOKIE, PROXY_AUTHORIZATION, SET_COOKIE};

        let request = HeadParser::new()
            .parse_request(&Bytes::from_static(
                b"GET / HTTP/1.1\r\n\
                  Authorization: bearer-secret\r\n\
                  Proxy-Authorization: proxy-secret\r\n\
                  Cookie: cookie-secret\r\n\
                  Set-Cookie: set-cookie-secret\r\n\r\n",
            ))
            .unwrap();

        for name in [AUTHORIZATION, PROXY_AUTHORIZATION, COOKIE, SET_COOKIE] {
            assert!(request.headers()[name].is_sensitive());
        }
        let debug = format!("{:?}", request.headers());
        assert!(!debug.contains("secret"));
    }
}
