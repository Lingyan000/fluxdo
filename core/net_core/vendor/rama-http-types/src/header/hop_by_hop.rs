//! Hop-by-hop HTTP header sanitation utilities.
//!
//! HTTP intermediaries consume connection-specific fields and must not copy
//! them blindly to the next hop. The context-aware sanitizers are the
//! recommended API for relays: they remove all source-hop metadata, then
//! re-originate only valid upgrade and request-trailer capabilities. The
//! `remove_*` functions remove those capabilities as well, for callers that
//! intentionally do not support them on the next hop.
//!
//! Proxy authentication fields are not removed unless they are explicitly
//! nominated by `Connection`. Whether a proxy consumes or relays credentials
//! depends on its role and is therefore a separate forwarding policy.
//!
//! A request and its response must use the same context:
//!
//! ```
//! use rama_http_types::{Request, Response, StatusCode, Version};
//! use rama_http_types::header::hop_by_hop::{
//!     HopByHopResponseDisposition, sanitize_hop_by_hop_request_headers,
//!     sanitize_hop_by_hop_response_headers,
//! };
//!
//! let mut request = Request::builder()
//!     .version(Version::HTTP_11)
//!     .header("connection", "close")
//!     .body(())?;
//! let context = sanitize_hop_by_hop_request_headers(&mut request);
//!
//! let mut response = Response::builder()
//!     .status(StatusCode::OK)
//!     .body(())?;
//! assert_eq!(
//!     sanitize_hop_by_hop_response_headers(&mut response, &context),
//!     HopByHopResponseDisposition::Forward,
//! );
//! # Ok::<(), rama_http_types::Error>(())
//! ```

use rama_core::telemetry::tracing;
use rama_utils::collections::smallvec::{IntoIter as SmallVecIntoIter, SmallVec};

use crate::{
    HeaderMap, HeaderName, HeaderValue, Request, Response, StatusCode, Version,
    header::{self, is_token as is_http_token},
};

/// Connection-specific fields prohibited in both HTTP/2 and HTTP/3.
///
/// See RFC 9113 Section 8.2.2 and RFC 9114 Section 4.2. `TE` is checked
/// separately because requests may contain `TE: trailers`. `Trailer` is not
/// prohibited; it can announce trailing fields in these protocols.
pub const CONNECTION_SPECIFIC_HEADERS: [&HeaderName; 5] = [
    &header::CONNECTION,
    &header::PROXY_CONNECTION,
    &header::KEEP_ALIVE,
    &header::TRANSFER_ENCODING,
    &header::UPGRADE,
];

/// Whether a `TE` field line holds the one value HTTP/2 and HTTP/3 allow, the
/// case-insensitive token `trailers` (RFC 9113 §8.2.2, RFC 9114 §4.2).
#[must_use]
pub fn is_te_trailers(value: &[u8]) -> bool {
    value.eq_ignore_ascii_case(b"trailers")
}

/// Whether any token of the `TE` `lines` is `trailers` (RFC 9110 §10.1.4).
#[must_use]
pub fn te_names_trailers<'a>(lines: impl IntoIterator<Item = &'a HeaderValue>) -> bool {
    lines.into_iter().any(|line| {
        comma_separated_tokens(line).any(|token| token.eq_ignore_ascii_case(b"trailers"))
    })
}

/// Leave a request's `TE` as the exact `trailers` HTTP/2 and HTTP/3 allow when it names it,
/// as peers compare that value exactly, else remove it. Whether `TE` was removed.
pub fn retain_te_trailers(headers: &mut HeaderMap) -> bool {
    let mut lines = headers.get_all(header::TE).iter();
    let exact = matches!((lines.next(), lines.next()), (Some(line), None) if line == "trailers");
    if exact || !headers.contains_key(header::TE) {
        return false;
    }
    if te_names_trailers(headers.get_all(header::TE)) {
        headers.insert(header::TE, HeaderValue::from_static("trailers"));
        false
    } else {
        headers.remove(header::TE);
        true
    }
}

fn has_single_token(headers: &HeaderMap, name: HeaderName, token: &[u8], allow_ows: bool) -> bool {
    let mut values = headers.get_all(name).iter();
    let (Some(value), None) = (values.next(), values.next()) else {
        return false;
    };
    let bytes = value.as_bytes();
    // HeaderValue excludes other ASCII whitespace, leaving HTTP's SP and HTAB.
    let bytes = if allow_ows { bytes.trim_ascii() } else { bytes };
    bytes.eq_ignore_ascii_case(token)
}

fn known_hop_by_hop_headers() -> impl Iterator<Item = &'static HeaderName> {
    CONNECTION_SPECIFIC_HEADERS
        .into_iter()
        .chain([&header::TE, &header::TRAILER])
}

fn next_comma_separated_token(mut value: &[u8]) -> Option<(&[u8], &[u8])> {
    loop {
        let mut parts = value.splitn(2, |byte| *byte == b',');
        let token = parts.next()?.trim_ascii();
        let remaining = parts.next();
        if !token.is_empty() {
            return Some((token, remaining.unwrap_or_default()));
        }
        value = remaining?;
    }
}

fn comma_separated_tokens(value: &HeaderValue) -> impl Iterator<Item = &[u8]> {
    let mut remaining = value.as_bytes();
    std::iter::from_fn(move || {
        let (token, rest) = next_comma_separated_token(remaining)?;
        remaining = rest;
        Some(token)
    })
}

struct ConnectionHeaderNames {
    values: SmallVecIntoIter<[HeaderValue; 2]>,
    current: Option<HeaderValue>,
    offset: usize,
}

impl Iterator for ConnectionHeaderNames {
    type Item = HeaderName;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            let Some(value) = self.current.as_ref() else {
                self.current = self.values.next();
                self.offset = 0;
                self.current.as_ref()?;
                continue;
            };
            let bytes = value.as_bytes();
            let Some((token, remaining)) =
                next_comma_separated_token(bytes.get(self.offset..).unwrap_or_default())
            else {
                self.current = None;
                continue;
            };
            self.offset = bytes.len().saturating_sub(remaining.len());
            if let Ok(name) = HeaderName::from_bytes(token) {
                return Some(name);
            }
        }
    }
}

/// Return every syntactically valid field name nominated by `Connection`.
///
/// Invalid list members are ignored individually, so they cannot prevent a
/// valid sibling nomination from being removed. The returned iterator owns a
/// cheap snapshot of the `Connection` field values, so callers may mutate the
/// source map while consuming it.
pub fn connection_header_names(headers: &HeaderMap) -> impl Iterator<Item = HeaderName> + use<> {
    let values = headers
        .get_all(header::CONNECTION)
        .iter()
        .cloned()
        .collect::<SmallVec<[HeaderValue; 2]>>()
        .into_iter();
    ConnectionHeaderNames {
        values,
        current: None,
        offset: 0,
    }
}

/// Return known hop-by-hop field names and valid `Connection` nominations.
///
/// Known names are included even when absent from the map. The iterator owns
/// its nominations so callers may mutate the map while consuming it.
pub fn hop_by_hop_header_names(headers: &HeaderMap) -> impl Iterator<Item = HeaderName> + use<> {
    known_hop_by_hop_headers()
        .cloned()
        .chain(connection_header_names(headers))
}

fn remove_field(headers: &mut HeaderMap, name: &HeaderName) {
    if headers.remove(name).is_some() {
        tracing::trace!("removed hop-by-hop header for name: {name}");
    }
}

fn remove_hop_by_hop_headers_with_nominations(
    headers: &mut HeaderMap,
    nominated: impl IntoIterator<Item = HeaderName>,
    known: impl IntoIterator<Item = &'static HeaderName>,
) {
    for name in nominated {
        remove_field(headers, &name);
    }
    for name in known {
        remove_field(headers, name);
    }
}

/// Remove all hop-by-hop headers from an HTTP message.
///
/// In addition to the known connection-specific fields, this removes every
/// field nominated by `Connection`. Use [`HopByHopHeaderContext::take`] when
/// upgrade, trailer, or `TE: trailers` metadata has to be restored for a newly
/// originated hop.
pub fn remove_hop_by_hop_headers(headers: &mut HeaderMap) {
    for name in hop_by_hop_header_names(headers) {
        remove_field(headers, &name);
    }
}

/// Remove request-side hop-by-hop fields without forwarding capabilities.
///
/// Use this when the next hop intentionally does not support upgrades or
/// request trailers.
pub fn remove_hop_by_hop_request_headers(headers: &mut HeaderMap) {
    remove_hop_by_hop_headers(headers);
}

/// Remove response-side hop-by-hop fields without forwarding capabilities.
///
/// Use this when the next hop intentionally does not support upgrades or
/// trailers.
pub fn remove_hop_by_hop_response_headers(headers: &mut HeaderMap) {
    remove_hop_by_hop_headers(headers);
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum UpgradeProtocol {
    WebSocket(UpgradeProtocolVersion),
    H2c(UpgradeProtocolVersion),
    Http(UpgradeProtocolVersion),
    Tls(UpgradeProtocolVersion),
    Other { wire: Box<[u8]>, name_length: usize },
}

fn supports_trailer_fields(version: Version) -> bool {
    matches!(
        version,
        Version::HTTP_11 | Version::HTTP_2 | Version::HTTP_3
    )
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum UpgradeProtocolVersion {
    Unversioned,
    V1_0,
    V1_1,
    V1_2,
    V1_3,
    V2_0,
    V3_0,
    Other(Box<[u8]>),
}

impl UpgradeProtocolVersion {
    fn parse(value: Option<&[u8]>) -> Option<Self> {
        match value {
            None => Some(Self::Unversioned),
            Some(b"1.0") => Some(Self::V1_0),
            Some(b"1.1") => Some(Self::V1_1),
            Some(b"1.2") => Some(Self::V1_2),
            Some(b"1.3") => Some(Self::V1_3),
            Some(b"2.0") => Some(Self::V2_0),
            Some(b"3.0") => Some(Self::V3_0),
            Some(value) if is_http_token(value) => Some(Self::Other(value.into())),
            _ => None,
        }
    }
}

impl UpgradeProtocol {
    fn parse(value: &[u8]) -> Option<Self> {
        let name_length = value
            .iter()
            .position(|byte| *byte == b'/')
            .unwrap_or(value.len());
        let name = &value[..name_length];
        let version = match value.get(name_length..) {
            Some([]) => None,
            Some([b'/', version @ ..]) => Some(version),
            _ => return None,
        };
        if name.eq_ignore_ascii_case(b"websocket") {
            Some(Self::WebSocket(UpgradeProtocolVersion::parse(version)?))
        } else if name.eq_ignore_ascii_case(b"h2c") {
            Some(Self::H2c(UpgradeProtocolVersion::parse(version)?))
        } else if name.eq_ignore_ascii_case(b"http") {
            Some(Self::Http(UpgradeProtocolVersion::parse(version)?))
        } else if name.eq_ignore_ascii_case(b"tls") {
            Some(Self::Tls(UpgradeProtocolVersion::parse(version)?))
        } else if is_http_token(name) && version.is_none_or(is_http_token) {
            Some(Self::Other {
                wire: value.into(),
                name_length,
            })
        } else {
            None
        }
    }

    fn matches(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::WebSocket(left), Self::WebSocket(right))
            | (Self::H2c(left), Self::H2c(right))
            | (Self::Http(left), Self::Http(right))
            | (Self::Tls(left), Self::Tls(right)) => left == right,
            (
                Self::Other {
                    wire: left,
                    name_length: left_name_length,
                },
                Self::Other {
                    wire: right,
                    name_length: right_name_length,
                },
            ) => {
                left[..*left_name_length].eq_ignore_ascii_case(&right[..*right_name_length])
                    && left.get(left_name_length + 1..) == right.get(right_name_length + 1..)
            }
            _ => false,
        }
    }
}

#[derive(Clone, Debug)]
struct Http1UpgradeIntent {
    fields: SmallVec<[(HeaderName, HeaderValue); 2]>,
    protocols: SmallVec<[UpgradeProtocol; 2]>,
}

/// Connection-specific metadata captured while sanitizing an HTTP message.
///
/// This type supports intermediaries that consume hop-by-hop fields and then
/// originate equivalent fields for the next hop. It deliberately retains only
/// valid HTTP/1.1 upgrade intent, `TE: trailers` capability, and non-nominated
/// trailer declarations.
#[derive(Clone, Debug, Default)]
pub struct HopByHopHeaderContext {
    nominated_headers: Box<[HeaderName]>,
    trailer_fields: Box<[(HeaderName, HeaderValue)]>,
    upgrade_intent: Option<Box<Http1UpgradeIntent>>,
    te_trailers: bool,
}

impl HopByHopHeaderContext {
    /// Capture connection-specific metadata without modifying the headers.
    #[must_use]
    pub fn capture(headers: &HeaderMap, version: Version) -> Self {
        let preserve_upgrade = version == Version::HTTP_11;
        let mut nominated_headers = Vec::new();
        let mut trailer_fields = Vec::new();
        let mut upgrade_fields = SmallVec::new();
        let mut upgrade_protocols = SmallVec::new();
        let mut te_trailers = false;
        let mut saw_connection_upgrade = false;
        let mut saw_connection_close = false;
        let mut saw_upgrade = false;
        let mut valid_connection = true;
        let mut valid_upgrade = true;

        for (name, value) in headers.ordered_iter() {
            if name == header::CONNECTION {
                for token in comma_separated_tokens(value) {
                    let Ok(nominated) = HeaderName::from_bytes(token) else {
                        valid_connection = false;
                        continue;
                    };
                    if nominated.as_str().eq_ignore_ascii_case("close") {
                        saw_connection_close = true;
                    }
                    if preserve_upgrade
                        && nominated == header::UPGRADE
                        && let Ok(value) = HeaderValue::from_bytes(token)
                    {
                        saw_connection_upgrade = true;
                        upgrade_fields.push((name.clone(), value));
                    }
                    nominated_headers.push(nominated);
                }
            } else if name == header::TRAILER && supports_trailer_fields(version) {
                trailer_fields.push((name.clone(), value.clone()));
            } else if name == header::TE && supports_trailer_fields(version) {
                te_trailers |= te_names_trailers([value]);
            } else if preserve_upgrade && name == header::UPGRADE {
                saw_upgrade = true;
                upgrade_fields.push((name.clone(), value.clone()));
                for protocol in comma_separated_tokens(value) {
                    match UpgradeProtocol::parse(protocol) {
                        Some(protocol) => upgrade_protocols.push(protocol),
                        None => valid_upgrade = false,
                    }
                }
            }
        }

        let upgrade_intent = if saw_connection_upgrade
            && !saw_connection_close
            && saw_upgrade
            && valid_connection
            && valid_upgrade
            && !upgrade_protocols.is_empty()
        {
            Some(Box::new(Http1UpgradeIntent {
                fields: upgrade_fields,
                protocols: upgrade_protocols,
            }))
        } else {
            None
        };
        if nominated_headers.contains(&header::TRAILER) {
            trailer_fields.clear();
        }
        Self {
            nominated_headers: nominated_headers.into_boxed_slice(),
            trailer_fields: trailer_fields.into_boxed_slice(),
            upgrade_intent,
            te_trailers,
        }
    }

    /// Capture connection-specific metadata and remove all hop-by-hop fields.
    #[must_use]
    pub fn take(headers: &mut HeaderMap, version: Version) -> Self {
        Self::take_with_retention(headers, version, false, false)
    }

    // Relay sanitation retains valid fields in place. Explicit take() still
    // removes every capability for adaptation to a different hop.
    fn take_with_retention(
        headers: &mut HeaderMap,
        version: Version,
        retain_trailers: bool,
        retain_request_te: bool,
    ) -> Self {
        let context = Self::capture(headers, version);
        let keep_trailer = retain_trailers && !context.trailer_fields.is_empty();
        let keep_te = retain_request_te
            && context.te_trailers
            && has_single_token(
                headers,
                header::TE,
                b"trailers",
                version == Version::HTTP_11,
            );
        let keep_connection = keep_te
            && version == Version::HTTP_11
            && has_single_token(headers, header::CONNECTION, b"te", true);
        remove_hop_by_hop_headers_with_nominations(
            headers,
            context
                .nominated_headers
                .iter()
                .filter(|name| !keep_te || *name != &header::TE)
                .cloned(),
            known_hop_by_hop_headers().filter(|name| {
                !(keep_trailer && *name == &header::TRAILER
                    || keep_te && *name == &header::TE
                    || keep_connection && *name == &header::CONNECTION)
            }),
        );
        context
    }

    /// Return the fields nominated by the original `Connection` header.
    #[must_use]
    pub fn nominated_headers(&self) -> &[HeaderName] {
        &self.nominated_headers
    }

    /// Restore captured `Trailer` fields for a target that supports trailers.
    ///
    /// An existing target field takes precedence over the captured fields.
    pub fn restore_trailer_headers(&self, headers: &mut HeaderMap, version: Version) {
        if !supports_trailer_fields(version) {
            return;
        }
        if headers.contains_key(header::TRAILER) {
            return;
        }
        for (name, value) in &self.trailer_fields {
            headers.append(name.clone(), value.clone());
        }
    }

    fn restore_request_te_header(&self, headers: &mut HeaderMap, version: Version) {
        if !self.te_trailers || !supports_trailer_fields(version) {
            remove_field(headers, &header::TE);
            return;
        }
        // A legal field already in place keeps its spelling and position.
        // Lists, repeated fields and transfer codings are re-originated as the
        // one capability HTTP/2 and HTTP/3 permit.
        if !has_single_token(
            headers,
            header::TE,
            b"trailers",
            version == Version::HTTP_11,
        ) {
            headers.insert(header::TE, HeaderValue::from_static("trailers"));
        }
        if version == Version::HTTP_11
            && !connection_header_names(headers).any(|name| name == header::TE)
        {
            headers.append(header::CONNECTION, HeaderValue::from_static("TE"));
        }
    }

    fn restore_upgrade(&self, headers: &mut HeaderMap, version: Version, retain_request_te: bool) {
        let keep_connection = retain_request_te
            && self.te_trailers
            && self.upgrade_intent.is_none()
            && version == Version::HTTP_11
            && has_single_token(headers, header::CONNECTION, b"te", true);
        if !keep_connection {
            remove_field(headers, &header::CONNECTION);
        }
        remove_field(headers, &header::UPGRADE);
        if version != Version::HTTP_11 {
            return;
        }
        if let Some(intent) = &self.upgrade_intent {
            for (name, value) in &intent.fields {
                headers.append(name.clone(), value.clone());
            }
        }
    }

    fn restore_message_headers(
        &self,
        headers: &mut HeaderMap,
        version: Version,
        target_nominations: &[HeaderName],
        retain_request_te: bool,
    ) {
        if !target_nominations.contains(&header::TRAILER) {
            self.restore_trailer_headers(headers, version);
        }
        self.restore_upgrade(headers, version, retain_request_te);
    }

    /// Restore response metadata needed to originate the next hop.
    ///
    /// This is intended for a transformation of the same response, such as
    /// adaptation. It does not correlate a response with its request; relays
    /// should use [`sanitize_hop_by_hop_response_headers`] for that validation.
    ///
    /// The target headers are expected to have been sanitized first. Trailer
    /// declarations remain removed when either the source or target nominated
    /// `Trailer` as connection-specific.
    pub fn restore_response(
        &self,
        headers: &mut HeaderMap,
        version: Version,
        target_nominations: &[HeaderName],
    ) {
        self.restore_message_headers(headers, version, target_nominations, false);
    }

    /// Restore metadata for an adapted or otherwise re-originated request.
    ///
    /// In addition to common message metadata, this restores the normalized
    /// `TE: trailers` capability required by the target HTTP version.
    pub fn restore_request(
        &self,
        headers: &mut HeaderMap,
        version: Version,
        target_nominations: &[HeaderName],
    ) {
        self.restore_message_headers(headers, version, target_nominations, true);
        self.restore_request_te_header(headers, version);
    }

    fn allows_upgrade_response(&self, response: &Self) -> bool {
        let (Some(request), Some(response)) = (&self.upgrade_intent, &response.upgrade_intent)
        else {
            return false;
        };
        response.protocols.iter().all(|selected| {
            request
                .protocols
                .iter()
                .any(|offered| offered.matches(selected))
        })
    }
}

/// Action a caller must take after sanitizing a response.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[must_use]
pub enum HopByHopResponseDisposition {
    /// The response can be forwarded after sanitation.
    Forward,
    /// The invalid `101 Switching Protocols` response must be rejected.
    RejectUpgrade,
}

/// Sanitize an outbound request while preserving valid next-hop metadata.
///
/// The returned context must be supplied to
/// [`sanitize_hop_by_hop_response_headers`] so that an upgrade response is
/// retained only for a matching request.
#[must_use]
pub fn sanitize_hop_by_hop_request_headers<B>(request: &mut Request<B>) -> HopByHopHeaderContext {
    let version = request.version();
    let context =
        HopByHopHeaderContext::take_with_retention(request.headers_mut(), version, true, true);
    context.restore_request(request.headers_mut(), version, &[]);
    context
}

/// Sanitize an outbound response using its corresponding request context.
///
/// Callers must reject the exchange when this returns
/// [`HopByHopResponseDisposition::RejectUpgrade`]; forwarding a stripped `101`
/// would violate HTTP/1.1 framing and desynchronize the connection state.
#[must_use = "a rejected upgrade must not be forwarded"]
pub fn sanitize_hop_by_hop_response_headers<B>(
    response: &mut Response<B>,
    request_context: &HopByHopHeaderContext,
) -> HopByHopResponseDisposition {
    let version = response.version();
    let status = response.status();
    let response_context =
        HopByHopHeaderContext::take_with_retention(response.headers_mut(), version, true, false);
    response_context.restore_trailer_headers(response.headers_mut(), version);
    if status != StatusCode::SWITCHING_PROTOCOLS {
        return HopByHopResponseDisposition::Forward;
    }
    if request_context.allows_upgrade_response(&response_context) {
        response_context.restore_upgrade(response.headers_mut(), version, false);
        HopByHopResponseDisposition::Forward
    } else {
        tracing::debug!(
            http.response.status = %status,
            http.version = %version,
            request.upgrade_intent = request_context.upgrade_intent.is_some(),
            request.upgrade_protocol_count = request_context
                .upgrade_intent
                .as_deref()
                .map_or(0, |intent| intent.protocols.len()),
            response.upgrade_intent = response_context.upgrade_intent.is_some(),
            response.upgrade_protocol_count = response_context
                .upgrade_intent
                .as_deref()
                .map_or(0, |intent| intent.protocols.len()),
            "rejecting invalid or uncorrelated HTTP protocol upgrade"
        );
        HopByHopResponseDisposition::RejectUpgrade
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::assert_matches;

    #[test]
    fn te_is_retained_as_the_exact_trailers_or_removed() {
        for (lines, expected) in [
            (&["trailers"][..], Some("trailers")),
            (&["Trailers"], Some("trailers")),
            (&["trailers, gzip"], Some("trailers")),
            (&["gzip", "trailers"], Some("trailers")),
            (&["gzip"], None),
            (&["trailers;q=0"], None),
            (&[], None),
        ] {
            let mut headers = HeaderMap::new();
            headers.insert(header::ACCEPT, HeaderValue::from_static("*/*"));
            for line in lines {
                headers.append(header::TE, HeaderValue::from_static(line));
            }
            headers.append(header::ACCEPT_ENCODING, HeaderValue::from_static("gzip"));
            let removed = retain_te_trailers(&mut headers);
            assert_eq!(
                removed,
                !lines.is_empty() && expected.is_none(),
                "{lines:?}"
            );
            assert_eq!(
                values(&headers, &header::TE),
                expected.map(str::as_bytes).into_iter().collect::<Vec<_>>(),
                "{lines:?}"
            );
            // The field keeps its position.
            if expected.is_some() {
                assert_eq!(headers.keys().nth(1), Some(&header::TE), "{lines:?}");
            }
        }
    }

    fn values<'a>(headers: &'a HeaderMap, name: &HeaderName) -> Vec<&'a [u8]> {
        headers
            .get_all(name)
            .iter()
            .map(HeaderValue::as_bytes)
            .collect()
    }

    #[test]
    fn connection_parser_keeps_valid_members_beside_invalid_members() {
        let mut headers = HeaderMap::new();
        headers.insert(
            header::CONNECTION,
            HeaderValue::from_bytes(b"close, \xff").unwrap(),
        );
        headers.append(
            header::CONNECTION,
            HeaderValue::from_static(" , x-hop, keep-alive, "),
        );
        headers.append(header::CONNECTION, HeaderValue::from_static("TE"));

        assert_eq!(
            connection_header_names(&headers).collect::<Vec<_>>(),
            [
                HeaderName::from_static("close"),
                HeaderName::from_static("x-hop"),
                HeaderName::from_static("keep-alive"),
                HeaderName::from_static("te"),
            ]
        );
    }

    #[test]
    fn upgrade_protocol_token_validation_matches_http_grammar() {
        assert!(!is_http_token(b""));
        for byte in u8::MIN..=u8::MAX {
            let expected = byte.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&byte);
            assert_eq!(is_http_token(&[byte]), expected, "token byte {byte:#04x}");
        }
    }

    #[test]
    fn common_upgrade_protocols_use_inline_variants() {
        for (wire, expected) in [
            (
                b"WebSocket".as_slice(),
                UpgradeProtocol::WebSocket(UpgradeProtocolVersion::Unversioned),
            ),
            (
                b"H2C".as_slice(),
                UpgradeProtocol::H2c(UpgradeProtocolVersion::Unversioned),
            ),
            (
                b"HTTP/1.0".as_slice(),
                UpgradeProtocol::Http(UpgradeProtocolVersion::V1_0),
            ),
            (
                b"HTTP/1.1".as_slice(),
                UpgradeProtocol::Http(UpgradeProtocolVersion::V1_1),
            ),
            (
                b"TLS/1.2".as_slice(),
                UpgradeProtocol::Tls(UpgradeProtocolVersion::V1_2),
            ),
            (
                b"TLS/1.3".as_slice(),
                UpgradeProtocol::Tls(UpgradeProtocolVersion::V1_3),
            ),
            (
                b"HTTP/2.0".as_slice(),
                UpgradeProtocol::Http(UpgradeProtocolVersion::V2_0),
            ),
            (
                b"HTTP/3.0".as_slice(),
                UpgradeProtocol::Http(UpgradeProtocolVersion::V3_0),
            ),
        ] {
            assert_eq!(UpgradeProtocol::parse(wire), Some(expected));
        }
    }

    #[test]
    fn uncommon_upgrade_protocol_keeps_exact_version() {
        let protocol = UpgradeProtocol::parse(b"IRC/6.9").unwrap();
        assert_matches!(
            protocol,
            UpgradeProtocol::Other { wire, name_length: 3 } if &*wire == b"IRC/6.9",
        );
        assert_matches!(
            UpgradeProtocol::parse(b"TLS/6.9"),
            Some(UpgradeProtocol::Tls(UpgradeProtocolVersion::Other(version)))
                if &*version == b"6.9",
        );
    }

    #[test]
    fn uncommon_upgrade_protocol_requires_valid_name_and_version() {
        assert_eq!(UpgradeProtocol::parse(b"IRC/6 9"), None);
        assert_eq!(UpgradeProtocol::parse(b"IR C/6.9"), None);
    }

    #[test]
    fn directional_removal_preserves_proxy_auth() {
        let mut request = HeaderMap::new();
        request.insert(
            header::PROXY_AUTHENTICATE,
            HeaderValue::from_static("Basic"),
        );
        request.insert(
            header::PROXY_AUTHORIZATION,
            HeaderValue::from_static("Basic dGVzdA=="),
        );
        request.insert(
            header::CONNECTION,
            HeaderValue::from_static("x-request-hop"),
        );
        request.insert(
            header::PROXY_CONNECTION,
            HeaderValue::from_static("keep-alive"),
        );
        request.insert(
            HeaderName::from_static("x-request-hop"),
            HeaderValue::from_static("secret"),
        );
        remove_hop_by_hop_request_headers(&mut request);
        assert!(request.contains_key(header::PROXY_AUTHENTICATE));
        assert!(request.contains_key(header::PROXY_AUTHORIZATION));
        assert!(!request.contains_key(header::CONNECTION));
        assert!(!request.contains_key(header::PROXY_CONNECTION));
        assert!(!request.contains_key("x-request-hop"));

        let mut response = HeaderMap::new();
        response.insert(
            header::PROXY_AUTHENTICATE,
            HeaderValue::from_static("Basic"),
        );
        response.insert(
            header::PROXY_CONNECTION,
            HeaderValue::from_static("keep-alive"),
        );
        response.insert(header::TE, HeaderValue::from_static("trailers"));
        response.insert(header::CONNECTION, HeaderValue::from_static("close"));
        remove_hop_by_hop_response_headers(&mut response);
        assert!(response.contains_key(header::PROXY_AUTHENTICATE));
        assert!(!response.contains_key(header::PROXY_CONNECTION));
        assert!(!response.contains_key(header::TE));
        assert!(!response.contains_key(header::CONNECTION));
    }

    #[test]
    fn connection_nomination_removes_proxy_auth() {
        for (name, nomination) in [
            (
                header::PROXY_AUTHENTICATE,
                HeaderValue::from_static("proxy-authenticate"),
            ),
            (
                header::PROXY_AUTHORIZATION,
                HeaderValue::from_static("proxy-authorization"),
            ),
        ] {
            let mut headers = HeaderMap::new();
            headers.insert(header::CONNECTION, nomination);
            headers.insert(name.clone(), HeaderValue::from_static("Basic dGVzdA=="));

            remove_hop_by_hop_headers(&mut headers);

            assert!(headers.is_empty());
        }
    }

    fn ordered_fields(headers: &HeaderMap) -> Vec<(String, Vec<u8>, bool)> {
        headers
            .ordered_iter()
            .map(|(name, value)| {
                (
                    name.as_original_str().into_owned(),
                    value.as_bytes().to_vec(),
                    value.is_sensitive(),
                )
            })
            .collect()
    }

    #[test]
    fn relay_sanitation_keeps_legal_te_at_its_original_position() {
        for version in [Version::HTTP_11, Version::HTTP_2, Version::HTTP_3] {
            let mut request = Request::builder()
                .version(version)
                .header("x-before", "first")
                .header("tE", "TrAiLeRs")
                .header("x-after", "last")
                .body(())
                .unwrap();
            request
                .headers_mut()
                .get_mut(header::TE)
                .unwrap()
                .set_sensitive(true);
            if version == Version::HTTP_11 {
                request.headers_mut().append(
                    HeaderName::from_bytes(b"cOnNeCtIoN").unwrap(),
                    HeaderValue::from_static("tE"),
                );
            }
            let original = ordered_fields(request.headers());

            // Both proxy boundaries sanitize the same message. Neither pass
            // should move the legal field or discard its native wire metadata.
            for _ in 0..2 {
                let _context = sanitize_hop_by_hop_request_headers(&mut request);
                assert_eq!(ordered_fields(request.headers()), original, "{version:?}");
            }
        }
    }

    #[test]
    fn legal_http1_te_whitespace_is_preserved_but_not_forwarded_to_http2_or_http3() {
        for version in [Version::HTTP_11, Version::HTTP_2, Version::HTTP_3] {
            let mut request = Request::builder()
                .version(version)
                .header("x-before", "first")
                .header("tE", " \tTrAiLeRs\t")
                .header("cOnNeCtIoN", " \tTE \t")
                .header("x-after", "last")
                .body(())
                .unwrap();
            let original = ordered_fields(request.headers());

            let _context = sanitize_hop_by_hop_request_headers(&mut request);

            if version == Version::HTTP_11 {
                assert_eq!(ordered_fields(request.headers()), original);
            } else {
                assert_eq!(
                    values(request.headers(), &header::TE),
                    [b"trailers".as_slice()]
                );
                assert!(!request.headers().contains_key(header::CONNECTION));
            }
        }
    }

    #[test]
    fn retaining_te_does_not_retain_other_connection_nominations() {
        for version in [Version::HTTP_11, Version::HTTP_2, Version::HTTP_3] {
            let mut request = Request::builder()
                .version(version)
                .header("x-before", "first")
                .header("tE", "trailers")
                .header("x-hop", "secret")
                .header("connection", "x-hop, TE, close")
                .header("x-after", "last")
                .body(())
                .unwrap();

            let _context = sanitize_hop_by_hop_request_headers(&mut request);
            let names: Vec<_> = request
                .headers()
                .ordered_iter()
                .map(|(name, _)| name.as_original_str().into_owned())
                .collect();
            let expected = if version == Version::HTTP_11 {
                vec!["x-before", "tE", "x-after", "connection"]
            } else {
                vec!["x-before", "tE", "x-after"]
            };
            assert_eq!(names, expected, "{version:?}");
            assert!(!request.headers().contains_key("x-hop"));
            assert_eq!(
                values(request.headers(), &header::CONNECTION),
                if version == Version::HTTP_11 {
                    vec![b"TE".as_slice()]
                } else {
                    vec![]
                }
            );
        }
    }

    #[test]
    fn request_restoration_adapts_te_without_copying_source_hop_fields() {
        let mut source = HeaderMap::new();
        source.insert(header::CONNECTION, HeaderValue::from_static("TE"));
        source.insert(header::TE, HeaderValue::from_static("trailers"));
        let context = HopByHopHeaderContext::take(&mut source, Version::HTTP_11);
        assert!(source.is_empty());

        for version in [
            Version::HTTP_10,
            Version::HTTP_11,
            Version::HTTP_2,
            Version::HTTP_3,
        ] {
            let mut target = HeaderMap::new();
            target.insert(header::ACCEPT, HeaderValue::from_static("*/*"));
            // An adapter cannot introduce a transfer coding through restoration.
            target.insert(header::TE, HeaderValue::from_static("gzip"));
            context.restore_request(&mut target, version, &[]);
            assert_eq!(
                values(&target, &header::TE),
                if version == Version::HTTP_10 {
                    vec![]
                } else {
                    vec![b"trailers".as_slice()]
                }
            );
            assert_eq!(
                target.contains_key(header::CONNECTION),
                version == Version::HTTP_11
            );
        }
    }

    #[test]
    fn response_sanitation_never_retains_request_te_metadata() {
        for version in [Version::HTTP_11, Version::HTTP_2, Version::HTTP_3] {
            let mut response = Response::builder()
                .version(version)
                .header("x-before", "first")
                .header("te", "trailers")
                .header("connection", "TE")
                .header("x-after", "last")
                .body(())
                .unwrap();
            assert_eq!(
                sanitize_hop_by_hop_response_headers(
                    &mut response,
                    &HopByHopHeaderContext::default()
                ),
                HopByHopResponseDisposition::Forward
            );
            assert_eq!(
                response
                    .headers()
                    .ordered_iter()
                    .map(|(name, _)| name.as_str())
                    .collect::<Vec<_>>(),
                ["x-before", "x-after"]
            );
        }
    }

    #[test]
    fn request_sanitizer_reoriginates_te_trailers_by_version() {
        for (version, connection) in [
            (Version::HTTP_10, None),
            (Version::HTTP_11, Some(b"TE".as_slice())),
            (Version::HTTP_2, None),
            (Version::HTTP_3, None),
        ] {
            let mut request = Request::builder()
                .version(version)
                .header("connection", "close, TE")
                .header("te", "gzip, trailers")
                .body(())
                .unwrap();

            let _context = sanitize_hop_by_hop_request_headers(&mut request);

            assert_eq!(
                request
                    .headers()
                    .get(header::CONNECTION)
                    .map(HeaderValue::as_bytes),
                connection,
                "version: {version:?}"
            );
            assert_eq!(
                request.headers().get(header::TE).map(HeaderValue::as_bytes),
                (version != Version::HTTP_10).then_some(b"trailers".as_slice()),
                "version: {version:?}"
            );
        }
    }

    #[test]
    fn request_sanitizer_does_not_preserve_weighted_trailers_token() {
        let mut request = Request::builder()
            .version(Version::HTTP_11)
            .header("connection", "TE")
            .header("te", "trailers;q=1")
            .body(())
            .unwrap();

        let _context = sanitize_hop_by_hop_request_headers(&mut request);

        assert!(request.headers().is_empty());
    }

    #[test]
    fn request_sanitizer_rejects_invalid_upgrade_version_token() {
        let mut request = Request::builder()
            .version(Version::HTTP_11)
            .header("connection", "upgrade")
            .header("upgrade", "websocket/invalid version")
            .body(())
            .unwrap();

        let _context = sanitize_hop_by_hop_request_headers(&mut request);

        assert!(request.headers().is_empty());
    }

    #[test]
    fn connection_close_invalidates_upgrade_intent() {
        let mut request = Request::builder()
            .version(Version::HTTP_11)
            .header("connection", "Close, upgrade")
            .header("upgrade", "websocket")
            .body(())
            .unwrap();

        let context = sanitize_hop_by_hop_request_headers(&mut request);
        assert!(request.headers().is_empty());

        let mut response = Response::builder()
            .version(Version::HTTP_11)
            .status(StatusCode::SWITCHING_PROTOCOLS)
            .header("connection", "upgrade")
            .header("upgrade", "websocket")
            .body(())
            .unwrap();
        assert_eq!(
            sanitize_hop_by_hop_response_headers(&mut response, &context),
            HopByHopResponseDisposition::RejectUpgrade
        );
        assert!(response.headers().is_empty());
    }

    #[test]
    fn response_sanitizer_only_restores_correlated_upgrade() {
        let mut request = Request::builder()
            .version(Version::HTTP_11)
            .header("connection", "upgrade")
            .header("upgrade", "websocket, example/1")
            .body(())
            .unwrap();
        let context = sanitize_hop_by_hop_request_headers(&mut request);

        for (protocol, disposition) in [
            ("WebSocket", HopByHopResponseDisposition::Forward),
            ("EXAMPLE/1", HopByHopResponseDisposition::Forward),
            ("example/2", HopByHopResponseDisposition::RejectUpgrade),
        ] {
            let mut response = Response::builder()
                .version(Version::HTTP_11)
                .status(StatusCode::SWITCHING_PROTOCOLS)
                .header("connection", "keep-alive, upgrade")
                .header("upgrade", protocol)
                .header("keep-alive", "timeout=5")
                .body(())
                .unwrap();

            assert_eq!(
                sanitize_hop_by_hop_response_headers(&mut response, &context),
                disposition
            );
            assert_eq!(
                response.headers().contains_key(header::UPGRADE),
                disposition == HopByHopResponseDisposition::Forward
            );
            assert!(!response.headers().contains_key(header::KEEP_ALIVE));
        }
    }

    #[test]
    fn trailer_declaration_is_not_restored_when_nominated() {
        let mut headers = HeaderMap::new();
        headers.insert(header::CONNECTION, HeaderValue::from_static("trailer"));
        headers.insert(header::TRAILER, HeaderValue::from_static("x-checksum"));

        let context = HopByHopHeaderContext::take(&mut headers, Version::HTTP_11);
        context.restore_response(&mut headers, Version::HTTP_11, &[]);

        assert!(headers.is_empty());
    }

    #[test]
    fn context_reports_nominations_and_restores_trailer_declaration() {
        let mut headers = HeaderMap::new();
        headers.insert(header::CONNECTION, HeaderValue::from_static("x-hop"));
        headers.insert("x-hop", HeaderValue::from_static("secret"));
        headers.insert(header::TRAILER, HeaderValue::from_static("x-checksum"));

        let context = HopByHopHeaderContext::take(&mut headers, Version::HTTP_11);
        assert_eq!(
            context.nominated_headers(),
            [HeaderName::from_static("x-hop")]
        );
        for (version, restored) in [
            (Version::HTTP_09, false),
            (Version::HTTP_10, false),
            (Version::HTTP_11, true),
            (Version::HTTP_2, true),
            (Version::HTTP_3, true),
        ] {
            let mut target = HeaderMap::new();
            context.restore_response(&mut target, version, &[]);
            assert_eq!(target.contains_key(header::TRAILER), restored);
            assert_eq!(target.len(), usize::from(restored));
        }
    }

    #[test]
    fn relay_sanitation_preserves_trailer_field_positions() {
        fn ordered(headers: &HeaderMap) -> Vec<(String, Vec<u8>, bool)> {
            headers
                .ordered_iter()
                .map(|(name, value)| {
                    (
                        name.as_original_str().into_owned(),
                        value.as_bytes().to_vec(),
                        value.is_sensitive(),
                    )
                })
                .collect()
        }

        for version in [
            Version::HTTP_09,
            Version::HTTP_10,
            Version::HTTP_11,
            Version::HTTP_2,
            Version::HTTP_3,
        ] {
            for nominated in [false, true] {
                let mut headers = HeaderMap::new();
                headers.append("x-first", HeaderValue::from_static("first"));
                let mut declaration = HeaderValue::from_static("X-Checksum");
                declaration.set_sensitive(true);
                headers.append(HeaderName::from_bytes(b"TrAiLeR").unwrap(), declaration);
                headers.append("x-middle", HeaderValue::from_static("middle"));
                headers.append(header::TRAILER, HeaderValue::from_static("X-Final"));
                headers.append("x-last", HeaderValue::from_static("last"));
                let keep = supports_trailer_fields(version) && !nominated;
                let mut expected = headers.clone();
                if !keep {
                    expected.remove(header::TRAILER);
                }
                headers.append(
                    header::CONNECTION,
                    HeaderValue::from_static(if nominated { "trailer, x-hop" } else { "x-hop" }),
                );
                headers.append("x-hop", HeaderValue::from_static("hop-only"));

                let mut request = Request::new(());
                *request.version_mut() = version;
                *request.headers_mut() = headers.clone();
                let context = sanitize_hop_by_hop_request_headers(&mut request);
                assert_eq!(
                    ordered(request.headers()),
                    ordered(&expected),
                    "request: {version:?}, nominated={nominated}",
                );

                let mut response = Response::new(());
                *response.version_mut() = version;
                *response.headers_mut() = headers;
                assert_eq!(
                    sanitize_hop_by_hop_response_headers(&mut response, &context),
                    HopByHopResponseDisposition::Forward,
                );
                assert_eq!(
                    ordered(response.headers()),
                    ordered(&expected),
                    "response: {version:?}, nominated={nominated}",
                );
            }
        }
    }

    #[test]
    fn unsupported_source_version_does_not_capture_trailer_capabilities() {
        for version in [Version::HTTP_09, Version::HTTP_10] {
            let mut headers = HeaderMap::new();
            headers.insert(header::TRAILER, HeaderValue::from_static("x-checksum"));
            headers.insert(header::TE, HeaderValue::from_static("trailers"));

            let context = HopByHopHeaderContext::take(&mut headers, version);
            context.restore_request(&mut headers, Version::HTTP_11, &[]);

            assert!(headers.is_empty());
        }
    }

    #[test]
    fn strict_removal_uses_the_same_nomination_parser() {
        let mut headers = HeaderMap::new();
        headers.insert(header::CONNECTION, HeaderValue::from_static("x-hop"));
        headers.insert("x-hop", HeaderValue::from_static("secret"));
        headers.insert(header::UPGRADE, HeaderValue::from_static("websocket"));
        headers.insert(header::ACCEPT, HeaderValue::from_static("application/json"));

        remove_hop_by_hop_headers(&mut headers);

        assert_eq!(values(&headers, &header::ACCEPT), [b"application/json"]);
        assert_eq!(headers.len(), 1);
    }
}
