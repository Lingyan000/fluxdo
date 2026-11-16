//! Validate decoded HTTP fields before normalization can hide malformed input.

use std::{cell::Cell, collections::hash_map::Entry};

use ahash::HashMap;

use rama_core::{
    bytes::Bytes,
    extensions::{Extensions, ExtensionsRef},
    telemetry::tracing::debug,
};
use rama_http_types::{
    HeaderMap, HeaderName, HeaderValue, Method, Request, Response, StatusCode, Version,
    header::{
        self, ValueIter,
        trailer::{ForbiddenTrailers, is_never_a_trailer, is_sent_in_trailers},
    },
    proto::{
        ext,
        h3::{
            Code, PseudoHeader, PseudoHeaderOrder, PseudoHeaderSensitivity,
            qpack::{
                FieldSectionBase,
                encoding::{FieldPreferences, HeaderPreferences},
            },
        },
    },
};
use rama_net::{Protocol, address::AuthorityRef, uri::Uri};

use super::{
    Error,
    connection::Shared,
    qpack::{EncodeField, FieldPair},
};
use crate::proto::target::{
    AsteriskHostError, OutgoingHost, asterisk_host, host_is_wire_authority, normalize_received,
    outgoing_host, received_authority, several_hosts,
};

#[derive(Default)]
struct Fields {
    headers: HeaderMap,
    order: PseudoHeaderOrder,
    sensitivity: PseudoHeaderSensitivity,
    method: Option<Bytes>,
    scheme: Option<Bytes>,
    authority: Option<Bytes>,
    path: Option<Bytes>,
    protocol: Option<Bytes>,
    status: Option<Bytes>,
}

fn malformed(reason: &'static str) -> Error {
    Error::stream(Code::H3_MESSAGE_ERROR, reason)
}

fn parse(fields: Vec<FieldPair>, trailers: bool) -> Result<Fields, Error> {
    let mut result = Fields::default();
    let mut regular = false;
    for field in fields {
        if field.name.first() == Some(&b':') {
            if !header::is_valid_h2_h3_field_value(&field.value) {
                return Err(malformed("invalid pseudo-header value"));
            }
            if regular || trailers {
                return Err(malformed("misplaced pseudo-header"));
            }
            let pseudo = PseudoHeader::from_bytes(&field.name)
                .map_err(|_error| malformed("unknown pseudo-header"))?;
            let slot = match pseudo {
                PseudoHeader::Method => &mut result.method,
                PseudoHeader::Scheme => &mut result.scheme,
                PseudoHeader::Authority => &mut result.authority,
                PseudoHeader::Path => &mut result.path,
                PseudoHeader::Status => &mut result.status,
                PseudoHeader::Protocol => &mut result.protocol,
            };
            if slot.replace(field.value).is_some() {
                return Err(malformed("duplicate pseudo-header"));
            }
            result.order.push(pseudo);
            result.sensitivity.set_sensitive(pseudo, field.never_index);
            continue;
        }
        regular = true;
        let name = HeaderName::from_lowercase_bytes(field.name)
            .map_err(|_error| malformed("invalid field name"))?;
        validate_name(&name, &field.value, trailers)?;
        let mut value = HeaderValue::from_maybe_shared(field.value)
            .map_err(|_error| malformed("invalid field value"))?;
        validate_value(&value)?;
        value.set_sensitive(field.never_index);
        result
            .headers
            .try_append(name, value)
            .map_err(|_error| Error::stream(Code::H3_EXCESSIVE_LOAD, "too many header fields"))?;
    }
    Ok(result)
}

fn validate_value(value: &HeaderValue) -> Result<(), Error> {
    if value.has_outer_whitespace() {
        return Err(malformed("invalid field value"));
    }
    Ok(())
}

fn validate_name(name: &HeaderName, value: &[u8], trailers: bool) -> Result<(), Error> {
    if header::hop_by_hop::CONNECTION_SPECIFIC_HEADERS.contains(&name)
        || (*name == header::TE && (trailers || !header::hop_by_hop::is_te_trailers(value)))
    {
        return Err(malformed("connection-specific field"));
    }
    if trailers && is_never_a_trailer(name) {
        return Err(malformed("message framing field in trailers"));
    }
    Ok(())
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Outgoing {
    Request,
    Response,
}

/// `TE` as HTTP/2 and HTTP/3 peers compare it, exactly.
static TE_TRAILERS: HeaderValue = HeaderValue::from_static("trailers");

/// [`TE_TRAILERS`], never indexed.
static TE_TRAILERS_SENSITIVE: HeaderValue = {
    let mut value = HeaderValue::from_static("trailers");
    value.set_sensitive(true);
    value
};

/// The fields of an outgoing message that go on the wire.
///
/// HTTP/3, like HTTP/2, carries no connection-specific fields: they are dropped with the
/// fields a `Connection` field nominates. A request whose `TE` names `trailers` sends exactly
/// that, once, where its first `TE` line stood; any other `TE` is dropped (RFC 9114 §4.2).
/// Received messages carrying them stay malformed.
fn outgoing_fields(
    headers: &HeaderMap,
    kind: Outgoing,
) -> impl Iterator<Item = (&HeaderName, &HeaderValue)> {
    let nominated: Vec<HeaderName> = header::hop_by_hop::connection_header_names(headers).collect();
    let mut te_trailers = kind == Outgoing::Request
        && header::hop_by_hop::te_names_trailers(headers.get_all(header::TE));
    // Never indexed when any of the caller's `TE` lines is sensitive.
    let te_value = if headers
        .get_all(header::TE)
        .iter()
        .any(HeaderValue::is_sensitive)
    {
        &TE_TRAILERS_SENSITIVE
    } else {
        &TE_TRAILERS
    };
    headers.ordered_iter().filter_map(move |(name, value)| {
        if *name == header::TE {
            if core::mem::take(&mut te_trailers) {
                return Some((name, te_value));
            }
        } else if !header::hop_by_hop::CONNECTION_SPECIFIC_HEADERS.contains(&name)
            && !nominated.contains(name)
        {
            return Some((name, value));
        }
        debug!(header.name = %name, "dropped connection-specific field from HTTP/3 message");
        None
    })
}

/// The fields of an outgoing trailer section that go on the wire, as over HTTP/1.1 and
/// HTTP/2: the others are dropped instead of failing the stream.
pub(crate) fn outgoing_trailer_fields<'a>(
    headers: &'a HeaderMap,
    allowed: Option<&ForbiddenTrailers>,
) -> impl Iterator<Item = (&'a HeaderName, &'a HeaderValue)> {
    headers.ordered_iter().filter(move |(name, _)| {
        let sent = is_sent_in_trailers(name, allowed);
        if !sent {
            debug!(header.name = %name, "dropped field not allowed in HTTP/3 trailers");
        }
        sent
    })
}

/// Applications can construct HeaderValue through its unchecked API: recheck what is sent.
fn validate_values<'a>(
    fields: impl Iterator<Item = (&'a HeaderName, &'a HeaderValue)>,
) -> Result<(), Error> {
    for (_, value) in fields {
        if !header::is_valid_h2_h3_field_value(value.as_bytes()) {
            return Err(malformed("invalid field value"));
        }
    }
    Ok(())
}

fn validate_outgoing(headers: &HeaderMap, kind: Outgoing) -> Result<(), Error> {
    validate_values(outgoing_fields(headers, kind))?;
    content_length(headers)?;
    Ok(())
}

pub(crate) fn validate_outgoing_trailers(
    headers: &HeaderMap,
    allowed: Option<&ForbiddenTrailers>,
) -> Result<(), Error> {
    validate_values(outgoing_trailer_fields(headers, allowed))
}

pub(crate) fn content_length(headers: &HeaderMap) -> Result<Option<u64>, Error> {
    if !headers.contains_key(header::CONTENT_LENGTH) {
        return Ok(None);
    }
    crate::headers::content_length_parse_all(headers)
        .map(Some)
        .ok_or(malformed("invalid content-length"))
}

fn text(bytes: &Bytes) -> Result<&str, Error> {
    std::str::from_utf8(bytes).map_err(|_error| malformed("invalid pseudo-header value"))
}

/// Decode a request head. `extended_connect` is whether this endpoint advertised
/// `SETTINGS_ENABLE_CONNECT_PROTOCOL`; `:protocol` is malformed otherwise (RFC 8441 §3).
#[cfg(test)]
pub(crate) fn request(fields: Vec<FieldPair>) -> Result<Request<()>, Error> {
    request_head(fields, false)
}

pub(crate) fn request_head(
    fields: Vec<FieldPair>,
    extended_connect: bool,
) -> Result<Request<()>, Error> {
    let mut fields = parse(fields, false)?;
    content_length(&fields.headers)?;
    if fields.status.is_some() {
        return Err(malformed("status in request"));
    }
    let method = Method::from_bytes(
        fields
            .method
            .as_deref()
            .ok_or(malformed("missing method"))?,
    )
    .map_err(|_error| malformed("invalid method"))?;
    let protocol = fields
        .protocol
        .take()
        .map(|value| {
            if !extended_connect {
                return Err(malformed("extended CONNECT is not enabled"));
            }
            // RFC 8441 §4: Extended CONNECT carries :scheme, :path and an ordinary :authority.
            if method != Method::CONNECT || fields.scheme.is_none() || fields.path.is_none() {
                return Err(malformed("invalid extended CONNECT pseudo-headers"));
            }
            ext::Protocol::try_from_bytes(value).map_err(|_error| malformed("invalid :protocol"))
        })
        .transpose()?;
    // Several Host lines leave the routed authority ambiguous.
    if several_hosts(&fields.headers) {
        return Err(malformed("several Host lines"));
    }
    // Only a parseable first Host stands in for a missing :authority; any other Host is
    // reconciled with the request authority once the request is built.
    let host = fields
        .headers
        .get(header::HOST)
        .filter(|host| fields.authority.is_none() && AuthorityRef::parse(host.as_bytes()).is_ok());
    // Normalizing Host into the URI must retain its compression restriction
    // when a subsequent HTTP/2 or HTTP/3 encoder emits it as :authority.
    if fields.authority.is_none() && host.is_some_and(HeaderValue::is_sensitive) {
        fields
            .sensitivity
            .set_sensitive(PseudoHeader::Authority, true);
    }
    let authority = fields
        .authority
        .as_deref()
        .or_else(|| host.map(HeaderValue::as_bytes));
    if authority.is_some_and(|value| value.is_empty()) {
        return Err(malformed("empty authority"));
    }
    let authority = authority
        .map(std::str::from_utf8)
        .transpose()
        .map_err(|_error| malformed("invalid authority"))?;
    // The URI grammar's reg-name, raw UTF-8 included, as on HTTP/1 and HTTP/2.
    if let Some(authority) = authority {
        received_authority(authority).ok_or(malformed("invalid authority"))?;
    }
    let mut asterisk_scheme = None;
    let uri = if method == Method::CONNECT && protocol.is_none() {
        if fields.scheme.is_some() || fields.path.is_some() || fields.authority.is_none() {
            return Err(malformed("invalid CONNECT pseudo-headers"));
        }
        let uri =
            Uri::parse_authority_form(authority.ok_or(malformed("missing CONNECT authority"))?)
                .map_err(|_error| malformed("invalid CONNECT authority"))?;
        // RFC 9114 §4.4: CONNECT names a host and port; there is no default to guess.
        if uri.port_u16().is_none() {
            return Err(malformed("CONNECT without a port"));
        }
        uri
    } else {
        let mut scheme = text(fields.scheme.as_ref().ok_or(malformed("missing scheme"))?)?
            .parse::<Protocol>()
            .map_err(|_error| malformed("invalid scheme"))?;
        // RFC 8441 §5: a ws/wss target is carried as http/https, whatever the peer sent.
        if protocol.is_some() {
            scheme = ext::extended_connect_pseudo_scheme(&scheme).clone();
        }
        let path = text(fields.path.as_ref().ok_or(malformed("missing path"))?)?;
        let http_scheme = scheme.is_http();
        if !(path.starts_with('/')
            || (method == Method::OPTIONS && path == "*")
            || (!http_scheme && path.is_empty()))
            || path.contains('#')
        {
            return Err(malformed("invalid request path"));
        }
        // A path-less OPTIONS is the server-wide request every version sends as `*`.
        let path = if method == Method::OPTIONS && path.is_empty() {
            "*"
        } else {
            path
        };
        if path == "*" {
            asterisk_scheme = Some(scheme.clone());
        }
        let mut uri = if path == "*" {
            Uri::parse("*").map_err(|_error| malformed("invalid asterisk target"))?
        } else if path.is_empty() {
            Uri::default().without_path()
        } else {
            Uri::parse_http_request_target(path, false)
                .map_err(|_error| malformed("invalid request path"))?
        };
        if path != "*" {
            if let Some(authority) = authority {
                uri.set_authority(
                    received_authority(authority).ok_or(malformed("invalid authority"))?,
                );
            }
            uri.set_scheme(scheme);
        }
        uri
    };
    let mut request = Request::new(());
    *request.method_mut() = method;
    *request.uri_mut() = uri;
    *request.version_mut() = Version::HTTP_3;
    *request.headers_mut() = fields.headers;
    request.extensions().insert(fields.order);
    if fields.sensitivity != PseudoHeaderSensitivity::default() {
        request.extensions().insert(fields.sensitivity);
    }
    if let Some(protocol) = protocol {
        request.extensions().insert(protocol);
    }
    let authority_sensitive = fields.sensitivity.is_sensitive(PseudoHeader::Authority);
    if let Some(scheme) = asterisk_scheme {
        request.extensions().insert(scheme);
        if let Some(authority) = fields.authority.as_deref() {
            asterisk_host(authority, request.headers_mut(), authority_sensitive).map_err(
                |error| match error {
                    AsteriskHostError::InvalidAuthority => malformed("invalid authority"),
                    AsteriskHostError::TooManyFields => {
                        Error::stream(Code::H3_EXCESSIVE_LOAD, "too many header fields")
                    }
                },
            )?;
        }
    }
    let mut uri = std::mem::take(request.uri_mut());
    normalize_received(&mut uri, request.headers_mut(), authority_sensitive);
    *request.uri_mut() = uri;
    // Preserve split Cookie lines in this H3 context, as the H2 decoder does.
    // RFC 9114 §4.2.1 requires coalescing at the boundary to a non-H2/H3 context;
    // the HTTP/1 version adapter already handles that conversion.
    Ok(request)
}

#[cfg(test)]
pub(crate) fn response(fields: Vec<FieldPair>) -> Result<Response<()>, Error> {
    response_for_method(fields, false, Extensions::new())
}

/// A response decoded from `fields`, on top of `extensions`: a client passes a fork of the
/// request's, as responses fork their request on every HTTP version.
pub(crate) fn response_for_method(
    fields: Vec<FieldPair>,
    connect: bool,
    extensions: Extensions,
) -> Result<Response<()>, Error> {
    let fields = parse(fields, false)?;
    if fields.headers.contains_key(header::TE) {
        return Err(malformed("TE forbidden in response"));
    }
    if fields.method.is_some()
        || fields.scheme.is_some()
        || fields.authority.is_some()
        || fields.path.is_some()
        || fields.protocol.is_some()
    {
        return Err(malformed("request pseudo-header in response"));
    }
    let status = StatusCode::from_bytes(
        fields
            .status
            .as_deref()
            .ok_or(malformed("missing status"))?,
    )
    .map_err(|_error| malformed("invalid status"))?;
    if status == StatusCode::SWITCHING_PROTOCOLS {
        return Err(malformed("101 is forbidden in HTTP/3"));
    }
    // RFC 9110 §9.3.6: a successful CONNECT (any 2xx) ignores Content-Length for framing.
    // The field stays visible so protocols forbidding it can reject the message (RFC 9297 §3.2).
    let tunnel = connect && status.is_success();
    if !tunnel {
        content_length(&fields.headers)?;
    }
    if !tunnel
        && (status.is_informational() || status == StatusCode::NO_CONTENT)
        && fields.headers.contains_key(header::CONTENT_LENGTH)
    {
        return Err(malformed("content-length forbidden on this response"));
    }
    let (mut parts, ()) = Response::new(()).into_parts();
    parts.status = status;
    parts.version = Version::HTTP_3;
    parts.headers = fields.headers;
    parts.extensions = extensions;
    let response = Response::from_parts(parts, ());
    response.extensions().insert(fields.order);
    if fields.sensitivity != PseudoHeaderSensitivity::default() {
        response.extensions().insert(fields.sensitivity);
    }
    Ok(response)
}

pub(crate) fn trailers(fields: Vec<FieldPair>) -> Result<HeaderMap, Error> {
    Ok(parse(fields, true)?.headers)
}

// Cursors make duplicate-field lookup linear. Ordinary traffic creates none.
struct PreferenceCursor<'a> {
    preferences: &'a HeaderPreferences,
    headers: HashMap<&'a HeaderName, ValueIter<'a, FieldPreferences>>,
}

impl<'a> PreferenceCursor<'a> {
    fn new(preferences: &'a HeaderPreferences) -> Self {
        Self {
            preferences,
            headers: HashMap::default(),
        }
    }

    fn header(&mut self, name: &'a HeaderName) -> Option<&'a FieldPreferences> {
        if !self.preferences.headers.contains_key(name) {
            return None;
        }
        match self.headers.entry(name) {
            Entry::Occupied(entry) => entry.into_mut().next(),
            Entry::Vacant(entry) => {
                let mut values = self.preferences.headers.get_all(name).iter();
                let first = values.next();
                if first.is_some() {
                    entry.insert(values);
                }
                first
            }
        }
    }
}

/// Positioned dynamic references and explicit insertions wait for peer SETTINGS
/// and local encoder-stream registration. Ordered startup additionally waits
/// for its local prefix writes before admitting any HEADERS; literal sections
/// still need no peer SETTINGS. Defaults keep the pre-SETTINGS fallback, and
/// what exhausted registered-stream credit cannot carry is encoded natively.
pub(super) async fn wait_for_header_admission(
    shared: &Shared,
    extensions: &Extensions,
) -> Result<(), Error> {
    let requires_encoder = extensions
        .get_ref::<HeaderPreferences>()
        .is_some_and(|preferences| preferences.requires_encoder_stream());
    if requires_encoder {
        shared.peer_settings().await?;
    }
    if requires_encoder || shared.config.critical_streams.ordered_startup {
        // Ordered initialization always registers this stream after queuing its
        // configured prefixes, including when the encoder itself is OnDemand.
        shared.encoder_ready().await?;
    }
    Ok(())
}

pub(crate) fn encode_request<B>(
    shared: &Shared,
    id: u64,
    request: &Request<B>,
) -> Result<Bytes, Error> {
    encode_request_fields(shared, id, request).map(|(block, _)| block)
}

/// Which of a request's fields an encoded request block sent.
pub(crate) struct SentFields {
    drop_host: bool,
    unchanged: bool,
}

impl SentFields {
    /// The fields sent of the request's `headers`: those themselves, unless some
    /// were left out or rewritten.
    pub(crate) fn of(self, headers: HeaderMap) -> HeaderMap {
        if self.unchanged {
            return headers;
        }
        let mut sent = HeaderMap::new();
        for (name, value) in sent_request_fields(&headers, self.drop_host) {
            sent.append(name.clone(), value.clone());
        }
        sent
    }
}

/// The request fields that go on the wire: not the connection-specific ones, nor
/// an unusable `Host` next to an authority.
fn sent_request_fields(
    headers: &HeaderMap,
    drop_host: bool,
) -> impl Iterator<Item = (&HeaderName, &HeaderValue)> {
    outgoing_fields(headers, Outgoing::Request)
        .filter(move |(name, _)| !drop_host || *name != header::HOST)
}

/// [`encode_request`], also telling which of the request's fields it sent.
pub(crate) fn encode_request_fields<B>(
    shared: &Shared,
    id: u64,
    request: &Request<B>,
) -> Result<(Bytes, SentFields), Error> {
    validate_outgoing(request.headers(), Outgoing::Request)?;
    let protocol = request.extensions().get_ref::<ext::Protocol>();
    if protocol.is_some() && request.method() != Method::CONNECT {
        return Err(malformed(":protocol requires CONNECT"));
    }
    // Ordinary CONNECT uses authority-form; Extended CONNECT is an ordinary target.
    let connect = request.method() == Method::CONNECT && protocol.is_none();
    if request.uri().fragment().is_some() || (connect && request.uri().port_u16().is_none()) {
        return Err(malformed("invalid request target"));
    }
    // Serialize only components that need wire normalization into one buffer.
    // The scheme and header values can remain borrowed from the request.
    let mut target = Vec::with_capacity(128);
    if request.uri().authority().is_some() {
        request
            .uri()
            .write_h2_authority(&mut target)
            .map_err(|_error| malformed("invalid request authority"))?;
    }
    let mut authority_from_host = false;
    let mut drop_host = false;
    match outgoing_host(request.headers()) {
        OutgoingHost::Usable(host, parsed_host) => {
            // Compared with the wire projection, as parsed host and port: `Host: h:02` is port 2.
            authority_from_host = AuthorityRef::parse(&target[..])
                .is_ok_and(|projected| host_is_wire_authority(projected, parsed_host));
            if authority_from_host {
                target.clear();
                target.extend_from_slice(host.as_bytes());
            }
        }
        // Next to a URI authority it is dropped, so one authority reaches the wire.
        OutgoingHost::Unusable if !target.is_empty() => drop_host = true,
        OutgoingHost::Unusable => return Err(malformed("invalid Host")),
        OutgoingHost::Absent
            if target.is_empty()
                && (connect || request.uri().scheme().is_some_and(Protocol::is_http)) =>
        {
            return Err(malformed("missing request authority"));
        }
        OutgoingHost::Absent => {}
    }
    // RFC 9114 §4.4: an ordinary CONNECT names a host and port, whichever field supplied them.
    if connect
        && !AuthorityRef::parse(&target[..]).is_ok_and(|authority| authority.port_u16().is_some())
    {
        return Err(malformed("invalid request target"));
    }
    let scheme = if connect {
        None
    } else if protocol.is_some() {
        Some(ext::extended_connect_pseudo_scheme(
            request
                .uri()
                .scheme()
                .ok_or(malformed("missing request scheme"))?,
        ))
    } else if request.uri().is_asterisk() {
        if request.method() != Method::OPTIONS {
            return Err(malformed("asterisk requires OPTIONS"));
        }
        let protocol = request
            .extensions()
            .get_ref::<Protocol>()
            .ok_or(malformed("missing request scheme"))?;
        if let Some(host) = request.headers().get(header::HOST) {
            target.extend_from_slice(host.as_bytes());
        }
        Some(protocol)
    } else {
        Some(
            request
                .uri()
                .scheme()
                .ok_or(malformed("missing request scheme"))?,
        )
    };
    let http_scheme = scheme.is_some_and(Protocol::is_http);

    let authority_len = target.len();
    if !connect
        && request.method() == Method::OPTIONS
        && request.uri().is_path_empty()
        && request.uri().query().is_none()
    {
        // RFC 9112 §3.2.4: an OPTIONS request without a path is for the whole server.
        target.extend_from_slice(b"*");
    } else if !connect && !scheme.is_some_and(|scheme| ext::sends_empty_path(request.uri(), scheme))
    {
        request.uri().write_h2_path(&mut target);
    }
    let (authority, path) = target.split_at(authority_len);
    // RFC 9114 §4.3.1: http(s) needs :authority or Host, for Extended CONNECT too.
    if http_scheme && authority.is_empty() && !request.headers().contains_key(header::HOST) {
        return Err(malformed("HTTP URI requires authority"));
    }
    if protocol.is_some() && http_scheme && path.is_empty() {
        return Err(malformed("extended CONNECT requires a path"));
    }
    let mut pseudo = [
        Some((PseudoHeader::Method, request.method().as_str().as_bytes())),
        (!authority.is_empty()).then_some((PseudoHeader::Authority, authority)),
        scheme.map(|scheme| (PseudoHeader::Scheme, scheme.as_str().as_bytes())),
        (!connect).then_some((PseudoHeader::Path, path)),
        protocol.map(|protocol| (PseudoHeader::Protocol, protocol.as_ref())),
    ];
    let mut order = request
        .extensions()
        .get_ref::<PseudoHeaderOrder>()
        .cloned()
        .unwrap_or_default();
    // Keep the requested order and append newly applicable pseudo-headers.
    // Taking each slot also ignores inapplicable entries after a method change.
    order.extend(pseudo.iter().flatten().map(|(name, _)| *name));
    let mut sensitivity = request
        .extensions()
        .get_ref::<PseudoHeaderSensitivity>()
        .copied()
        .unwrap_or_default();
    if (authority_from_host || request.uri().is_asterisk())
        && request
            .headers()
            .get(header::HOST)
            .is_some_and(HeaderValue::is_sensitive)
    {
        // The :authority value above came from Host.
        sensitivity.set_sensitive(PseudoHeader::Authority, true);
    }
    let preferences = request.extensions().get_ref::<HeaderPreferences>();
    let mut encoding = preferences.map(PreferenceCursor::new);
    let pseudo = order.into_iter().filter_map(|name| {
        pseudo
            .iter_mut()
            .find(|field| field.as_ref().is_some_and(|(key, _)| *key == name))
            .and_then(Option::take)
            .map(|(name, value)| EncodeField {
                name: std::borrow::Cow::Borrowed(name.as_bytes()),
                value,
                preferences: preferences.and_then(|choices| choices.pseudo_headers.get(&name)),
                // Userinfo, kept only outside the HTTP family, is never indexed.
                never_index: sensitivity.is_sensitive(name)
                    || (name == PseudoHeader::Authority && value.contains(&b'@')),
            })
    });
    let sent = Cell::new(0);
    let block = shared.encode(
        id,
        pseudo.chain(
            sent_request_fields(request.headers(), drop_host)
                .inspect(|_| sent.set(sent.get() + 1))
                .map(|(name, value)| {
                    let mut field = EncodeField::from_header(name, value);
                    field.preferences = encoding.as_mut().and_then(|cursor| cursor.header(name));
                    field
                }),
        ),
        request.extensions().get_ref::<FieldSectionBase>().copied(),
    )?;
    // Every field went out, and `TE` only as the `trailers` it is rewritten to.
    let unchanged = sent.get() == request.headers().len()
        && request
            .headers()
            .get_all(header::TE)
            .iter()
            .all(|value| *value == TE_TRAILERS);
    Ok((
        block,
        SentFields {
            drop_host,
            unchanged,
        },
    ))
}

pub(crate) fn encode_response<B>(
    shared: &Shared,
    id: u64,
    response: &Response<B>,
) -> Result<Bytes, Error> {
    validate_outgoing(response.headers(), Outgoing::Response)?;
    if response.status() == StatusCode::SWITCHING_PROTOCOLS
        || ((response.status().is_informational() || response.status() == StatusCode::NO_CONTENT)
            && response.headers().contains_key(header::CONTENT_LENGTH))
    {
        return Err(malformed("invalid response status or content-length"));
    }
    let preferences = response.extensions().get_ref::<HeaderPreferences>();
    let mut encoding = preferences.map(PreferenceCursor::new);
    shared.encode(
        id,
        std::iter::once(EncodeField {
            name: std::borrow::Cow::Borrowed(PseudoHeader::Status.as_bytes()),
            value: response.status().as_str().as_bytes(),
            preferences: preferences
                .and_then(|choices| choices.pseudo_headers.get(&PseudoHeader::Status)),
            never_index: response
                .extensions()
                .get_ref::<PseudoHeaderSensitivity>()
                .is_some_and(|sensitivity| sensitivity.is_sensitive(PseudoHeader::Status)),
        })
        .chain(outgoing_fields(response.headers(), Outgoing::Response).map(
            |(name, value)| {
                let mut field = EncodeField::from_header(name, value);
                field.preferences = encoding.as_mut().and_then(|cursor| cursor.header(name));
                field
            },
        )),
        response.extensions().get_ref::<FieldSectionBase>().copied(),
    )
}

#[cfg(test)]
mod tests {
    use rama_core::{
        Service as _,
        bytes::{BufMut, BytesMut},
        service::service_fn,
    };
    use rama_http::layer::required_header::AddRequiredRequestHeaders;
    use rama_http_types::proto::h2::{
        frame::{self, StreamId},
        hpack,
    };
    use rama_http_types::proto::h3::qpack::{FieldLine, HeaderPrefix, encoding::Representation};
    use rama_net::AuthorityInputExt as _;

    use super::*;
    use crate::{h3::qpack::ErrorScope, proto::h1::test_util as h1};

    fn fields(values: &[(&'static str, &'static str)]) -> Vec<FieldPair> {
        values
            .iter()
            .map(|(name, value)| FieldPair {
                name: Bytes::from_static(name.as_bytes()),
                value: Bytes::from_static(value.as_bytes()),
                never_index: false,
            })
            .collect()
    }

    #[test]
    fn excessive_distinct_header_names_return_an_error_without_panicking() {
        let fields = (0..32_768)
            .map(|index| FieldPair {
                name: Bytes::from(format!("x-field-{index}")),
                value: Bytes::new(),
                never_index: false,
            })
            .collect();
        let error = parse(fields, false).err().unwrap();
        assert_eq!(error.code(), Code::H3_EXCESSIVE_LOAD);
        assert_eq!(error.scope(), ErrorScope::Stream);
    }

    #[test]
    fn incoming_and_outgoing_field_boundaries_are_rejected() {
        for value in [" leading", "trailing ", "\tleading", "trailing\t"] {
            assert!(parse(fields(&[("x-test", value)]), false).is_err());
            let mut headers = HeaderMap::new();
            headers.insert("x-test", HeaderValue::from_static(value));
            assert!(validate_outgoing(&headers, Outgoing::Response).is_err());
            assert!(validate_outgoing_trailers(&headers, None).is_err());
        }
        for value in ["", "internal \t whitespace", "\"quoted\""] {
            let parsed = parse(fields(&[("x-test", value)]), false).unwrap();
            validate_outgoing(&parsed.headers, Outgoing::Response).unwrap();
            validate_outgoing_trailers(&parsed.headers, None).unwrap();
        }
        for value in ["nul\0byte", "new\nline", "carriage\rreturn"] {
            assert!(parse(fields(&[("x-test", value)]), false).is_err());
            assert!(parse(fields(&[(":path", value)]), false).is_err());
        }
    }

    #[test]
    fn connection_fields_are_rejected_but_trailer_declarations_are_allowed() {
        for name in header::hop_by_hop::CONNECTION_SPECIFIC_HEADERS {
            assert!(validate_name(name, b"value", false).is_err());
            assert!(validate_name(name, b"value", true).is_err());
        }
        validate_name(&header::TRAILER, b"x-checksum", false).unwrap();
        validate_name(&header::TE, b"trailers", false).unwrap();
    }

    #[test]
    fn te_trailers_is_case_insensitive() {
        // RFC 9110 §10.1.4 defines the keyword using case-insensitive ABNF.
        for value in ["trailers", "Trailers", "TRAILERS"] {
            let mut request = request(fields(&[
                (":method", "GET"),
                (":scheme", "https"),
                (":authority", "example.com"),
                (":path", "/"),
                ("te", value),
            ]))
            .unwrap();
            let te = request.headers().get(header::TE).unwrap().as_bytes();
            validate_name(&header::TE, te, false).unwrap();
            validate_name(&header::TE, te, true).unwrap_err();
            request
                .headers_mut()
                .insert(header::TE, HeaderValue::from_static("gzip"));
            let te = request.headers().get(header::TE).unwrap().as_bytes();
            validate_name(&header::TE, te, false).unwrap_err();
        }
    }

    #[test]
    fn typed_schemes_preserve_http_validation_and_custom_scheme_paths() {
        for scheme in ["http", "HTTPS", "HtTp", "hTtPs"] {
            // Accepted as received; without an authority it cannot be sent on.
            let head = fields(&[(":method", "GET"), (":scheme", scheme), (":path", "/")]);
            let unroutable = request(head.clone()).unwrap();
            assert!(unroutable.uri().authority().is_none());
            encode_request(&shared(), 0, &unroutable).unwrap_err();
            // HTTP-family userinfo is dropped on receipt.
            let mut with_userinfo = head;
            with_userinfo.extend(fields(&[(":authority", "user@example.com")]));
            let normalized = request(with_userinfo).unwrap();
            assert!(normalized.uri().userinfo().is_none());
            assert_eq!(normalized.uri().host_str().as_deref(), Some("example.com"));
            let request = request(fields(&[
                (":method", "GET"),
                (":scheme", scheme),
                (":authority", "example.com"),
                (":path", "/"),
            ]))
            .unwrap();
            assert!(request.uri().scheme().unwrap().is_http());
            let encoded = decode(encode_request(&shared(), 0, &request).unwrap());
            let decoded = super::request(encoded).unwrap();
            assert_eq!(decoded.uri(), request.uri());
        }

        // H3 also carries non-HTTP URI schemes; their empty paths stay empty.
        let request = request(fields(&[
            (":method", "GET"),
            (":scheme", "custom"),
            (":path", ""),
        ]))
        .unwrap();
        let encoded = decode(encode_request(&shared(), 0, &request).unwrap());
        assert!(
            encoded
                .iter()
                .any(|field| field.name == ":path" && field.value.is_empty())
        );
        assert_eq!(super::request(encoded).unwrap().uri(), request.uri());
    }

    #[test]
    fn outgoing_host_fallback_is_validated_before_encoding() {
        let shared = crate::h3::connection::Shared::new(
            crate::h3::connection::Config::default(),
            crate::h3::control::Role::Client,
            Default::default(),
        )
        .unwrap();
        for host in ["bad host", "user@example.com", "[invalid]"] {
            let mut request = Request::new(());
            *request.uri_mut() = Uri::parse("custom:/path").unwrap();
            request
                .headers_mut()
                .insert(header::HOST, HeaderValue::from_static(host));
            encode_request(&shared, 0, &request).unwrap_err();
        }
    }

    #[test]
    fn empty_cookie_segments_and_individual_sensitivity_are_preserved() {
        let mut input = fields(&[
            (":method", "GET"),
            (":scheme", "https"),
            (":authority", "example.com"),
            (":path", "/"),
            ("cookie", ""),
            ("cookie", "session=secret"),
            ("cookie", ""),
        ]);
        input[5].never_index = true;
        let request = request(input).unwrap();
        let cookies: Vec<_> = request.headers().get_all(header::COOKIE).iter().collect();
        assert_eq!(
            cookies
                .iter()
                .map(|value| value.as_bytes())
                .collect::<Vec<_>>(),
            [b"".as_slice(), b"session=secret", b""]
        );
        assert!(!cookies[0].is_sensitive());
        assert!(cookies[1].is_sensitive());
        assert!(!cookies[2].is_sensitive());
    }

    fn shared() -> std::sync::Arc<crate::h3::connection::Shared> {
        crate::h3::connection::Shared::new(
            crate::h3::connection::Config::default(),
            crate::h3::control::Role::Client,
            Default::default(),
        )
        .unwrap()
    }

    fn decode(encoded: Bytes) -> Vec<FieldPair> {
        crate::h3::qpack::Decoder::new(crate::h3::qpack::DecoderConfig::default())
            .decode_field_section(0, encoded)
            .unwrap()
            .unwrap()
    }

    #[test]
    fn request_relay_preserves_each_pseudo_order_and_interleaved_field_lines() {
        let pseudo = [
            (":path", "/a%2Fb?x=1&x=2"),
            (":authority", "example.com:8443"),
            (":scheme", "https"),
            (":method", "GET"),
        ];
        // Every permutation is valid as long as pseudo-fields precede regular fields.
        for a in 0..4 {
            for b in 0..4 {
                for c in 0..4 {
                    for d in 0..4 {
                        let indices = [a, b, c, d];
                        if (0..4).any(|i| indices[i + 1..].contains(&indices[i])) {
                            continue;
                        }
                        let mut input = fields(&indices.map(|i| pseudo[i]));
                        input.extend(fields(&[
                            ("x-first", "one"),
                            ("cookie", ""),
                            ("x-middle", "Keep CASE"),
                            ("x-first", "two"),
                            ("cookie", "session=secret"),
                            ("x-last", ""),
                        ]));
                        input[0].never_index = true;
                        input[8].never_index = true;
                        let request = request(input.clone()).unwrap();
                        let received_order: Vec<_> = request
                            .extensions()
                            .get_ref::<PseudoHeaderOrder>()
                            .unwrap()
                            .iter()
                            .map(|name| name.as_str())
                            .collect();
                        assert_eq!(received_order, indices.map(|i| pseudo[i].0));
                        assert_eq!(
                            decode(encode_request(&shared(), 0, &request).unwrap()),
                            input
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn response_and_trailers_relay_preserve_interleaved_fields_and_sensitivity() {
        let mut regular = fields(&[
            ("set-cookie", "first=1"),
            ("x-middle", "Keep CASE"),
            ("set-cookie", "second=2"),
            ("x-middle", ""),
        ]);
        regular[2].never_index = true;
        let mut input = fields(&[(":status", "200")]);
        input[0].never_index = true;
        input.extend(regular.clone());
        let response = response(input.clone()).unwrap();
        assert_eq!(
            decode(encode_response(&shared(), 0, &response).unwrap()),
            input
        );

        // A relay forwards `set-cookie` trailers as received.
        let trailers = trailers(regular.clone()).unwrap();
        assert_eq!(
            decode(
                crate::h3::stream::encode_trailers(
                    &shared(),
                    0,
                    &trailers,
                    Some(&ForbiddenTrailers::AllowAll)
                )
                .unwrap()
            ),
            regular
        );
    }

    fn names(fields: &[FieldPair]) -> Vec<String> {
        fields
            .iter()
            .map(|field| String::from_utf8_lossy(&field.name).into_owned())
            .collect()
    }

    /// Like HTTP/2, an outgoing message drops connection-specific fields, those `Connection`
    /// nominates and TE other than a request's `trailers`, instead of failing the stream: an
    /// HTTP/1-shaped message, such as a server-sent events response, can be served over HTTP/3.
    #[test]
    fn outgoing_messages_drop_connection_specific_fields() {
        let mut response = Response::new(());
        let headers = response.headers_mut();
        for (name, value) in [
            ("content-type", "text/event-stream"),
            ("connection", "keep-alive, X-Hop"),
            ("keep-alive", "timeout=5"),
            ("proxy-connection", "keep-alive"),
            ("transfer-encoding", "chunked"),
            ("upgrade", "websocket"),
            ("x-hop", "nominated"),
            ("te", "trailers"),
            ("cache-control", "no-cache"),
        ] {
            headers.append(
                HeaderName::from_static(name),
                HeaderValue::from_static(value),
            );
        }
        let sent = decode(encode_response(&shared(), 0, &response).unwrap());
        assert_eq!(names(&sent), [":status", "content-type", "cache-control"]);
        assert!(
            response.headers().contains_key(header::CONNECTION),
            "input untouched"
        );

        for (te, kept) in [("trailers", true), ("Trailers", true), ("gzip", false)] {
            let request = Request::builder()
                .uri("https://example.com/")
                .header(header::TE, te)
                .header(header::CONNECTION, "close")
                .body(())
                .unwrap();
            let sent = names(&decode(encode_request(&shared(), 0, &request).unwrap()));
            assert_eq!(sent.iter().any(|name| name == "te"), kept, "{te}");
            assert!(!sent.iter().any(|name| name == "connection"));
        }
    }

    /// The `trailers` a request's `TE` is sent as is never indexed when any of its lines is
    /// sensitive.
    #[test]
    fn outgoing_te_keeps_the_callers_sensitivity() {
        for (lines, sensitive) in [
            (&[("trailers", true)][..], true),
            (&[("Trailers", true)], true),
            (&[("trailers, gzip", true)], true),
            (&[("trailers", false), ("gzip", true)], true),
            (&[("gzip", true), ("trailers", false)], true),
            (&[("trailers", false)], false),
            (&[("trailers, gzip", false)], false),
        ] {
            let mut request = Request::builder()
                .uri("https://example.com/")
                .body(())
                .unwrap();
            for &(line, line_sensitive) in lines {
                let mut value = HeaderValue::from_static(line);
                value.set_sensitive(line_sensitive);
                request.headers_mut().append(header::TE, value);
            }
            let sent = decode(encode_request(&shared(), 0, &request).unwrap());
            let te: Vec<_> = sent.iter().filter(|field| field.name == "te").collect();
            assert_eq!(te.len(), 1, "{lines:?}");
            assert_eq!(te[0].value, "trailers", "{lines:?}");
            assert_eq!(te[0].never_index, sensitive, "{lines:?}");
        }
    }

    /// As over HTTP/2, a request sends `TE` as the exact `trailers` when any of its lines
    /// names it, where its first line stood; a `TE` that `Connection` nominates keeps it.
    #[test]
    fn outgoing_te_keeps_only_an_exact_trailers() {
        for (lines, kept) in [
            (&["trailers"][..], true),
            (&["Trailers"], true),
            (&["trailers, gzip"], true),
            (&["gzip, Trailers"], true),
            (&["trailers", "gzip"], true),
            (&["gzip", "trailers"], true),
            (&["gzip"], false),
            (&["trailers;q=0"], false),
        ] {
            let mut request = Request::builder().uri("https://example.com/");
            for line in lines {
                request = request.header(header::TE, *line);
            }
            let request = request
                .header("x-after", "1")
                .header(header::CONNECTION, "TE, x-hop")
                .header("x-hop", "1")
                .body(())
                .unwrap();
            let sent: Vec<_> = decode(encode_request(&shared(), 0, &request).unwrap())
                .into_iter()
                .filter(|field| !field.name.starts_with(b":"))
                .map(|field| (field.name.to_vec(), field.value.to_vec()))
                .collect();
            let expected: Vec<(Vec<u8>, Vec<u8>)> = if kept {
                vec![
                    (b"te".to_vec(), b"trailers".to_vec()),
                    (b"x-after".to_vec(), b"1".to_vec()),
                ]
            } else {
                vec![(b"x-after".to_vec(), b"1".to_vec())]
            };
            assert_eq!(sent, expected, "{lines:?}");

            let mut response = Response::new(());
            for line in lines {
                response
                    .headers_mut()
                    .append(header::TE, HeaderValue::from_static(line));
            }
            let sent = names(&decode(encode_response(&shared(), 0, &response).unwrap()));
            assert_eq!(sent, [":status"], "{lines:?}");
        }
    }

    /// Outgoing trailers send what the trailer policy allows, as over HTTP/1.1 and HTTP/2, and
    /// drop the rest instead of failing the stream.
    #[test]
    fn outgoing_trailers_follow_the_trailer_policy() {
        let mut trailers = HeaderMap::new();
        for (name, value) in [
            ("grpc-status", "0"),
            ("set-cookie", "a=b"),
            ("content-type", "text/plain"),
            ("connection", "close"),
            ("keep-alive", "timeout=5"),
            ("te", "trailers"),
            ("transfer-encoding", "chunked"),
            ("content-length", "3"),
            ("host", "example.com"),
            ("x-checksum", "abc"),
        ] {
            trailers.append(
                HeaderName::from_static(name),
                HeaderValue::from_static(value),
            );
        }
        let sent = |allowed: Option<&ForbiddenTrailers>| {
            names(&decode(
                crate::h3::stream::encode_trailers(&shared(), 0, &trailers, allowed).unwrap(),
            ))
        };
        assert_eq!(sent(None), ["grpc-status", "x-checksum"]);
        assert_eq!(
            sent(Some(&ForbiddenTrailers::AllowAll)),
            ["grpc-status", "set-cookie", "content-type", "x-checksum"]
        );
        assert_eq!(
            sent(Some(&ForbiddenTrailers::AllowSome(
                [header::SET_COOKIE].into()
            ))),
            ["grpc-status", "set-cookie", "x-checksum"]
        );
        assert_eq!(trailers.len(), 10, "input untouched");
    }

    /// What arrives with connection-specific fields stays malformed (RFC 9114 §4.2).
    #[test]
    fn received_connection_specific_fields_stay_malformed() {
        let error =
            response(fields(&[(":status", "200"), ("connection", "keep-alive")])).unwrap_err();
        assert_eq!(error.code(), Code::H3_MESSAGE_ERROR);
    }

    #[test]
    fn outgoing_custom_names_are_lowercase_without_mutating_the_header_map() {
        let mut request = Request::builder()
            .uri("https://example.com/")
            .body(())
            .unwrap();
        let name = HeaderName::from_bytes(b"X-Custom-CASE").unwrap();
        request
            .headers_mut()
            .append(name, HeaderValue::from_static("Keep CASE"));
        let output = decode(encode_request(&shared(), 0, &request).unwrap());
        assert_eq!(output.last().unwrap().name, "x-custom-case");
        assert_eq!(output.last().unwrap().value, "Keep CASE");
        assert_eq!(
            request
                .headers()
                .ordered_iter()
                .next()
                .unwrap()
                .0
                .as_original_str(),
            "X-Custom-CASE"
        );
    }

    #[test]
    fn qpack_never_index_requirements_survive_hpack_forwarding() {
        let mut input = fields(&[
            (":method", "GET"),
            (":scheme", "https"),
            (":authority", "example.com"),
            (":path", "/"),
            ("x-private", "secret"),
        ]);
        // Include exact static-table matches: indexing them would silently drop N.
        for field in &mut input {
            field.never_index = true;
        }
        let request = request(input.clone()).unwrap();
        let request =
            self::request(decode(encode_request(&shared(), 0, &request).unwrap())).unwrap();
        let (frame, _) = crate::h2::client::Peer::convert_send_message(
            frame::StreamId::from(1),
            request,
            None,
            true,
            None,
            None,
        )
        .unwrap();
        let mut wire = BytesMut::new();
        assert!(
            frame
                .encode(&mut hpack::Encoder::default(), &mut (&mut wire).limit(4096))
                .is_none()
        );
        let head = frame::Head::parse(&wire[..9]).unwrap();
        let (mut frame, mut payload) = frame::Headers::load(head, wire.split_off(9)).unwrap();
        frame
            .load_hpack(&mut payload, 4096, &mut hpack::Decoder::new(4096))
            .unwrap();
        let (pseudo, headers) = frame.into_parts();
        let mut forwarded = self::request(fields(&[
            (":method", "GET"),
            (":scheme", "https"),
            (":authority", "example.com"),
            (":path", "/"),
        ]))
        .unwrap();
        forwarded.extensions().insert(pseudo.sensitivity);
        *forwarded.headers_mut() = headers;
        assert_eq!(
            decode(encode_request(&shared(), 0, &forwarded).unwrap()),
            input
        );
    }

    #[test]
    fn request_edits_use_current_values_and_append_new_pseudo_fields() {
        let mut request = request(fields(&[
            (":authority", "example.com:443"),
            (":method", "CONNECT"),
            ("x-untouched", "one"),
            ("x-change", "before"),
            ("x-untouched", "two"),
        ]))
        .unwrap();
        *request.method_mut() = Method::POST;
        *request.uri_mut() = Uri::parse("https://example.com:443/new").unwrap();
        request
            .headers_mut()
            .insert("x-change", HeaderValue::from_static("after"));
        let output = decode(encode_request(&shared(), 0, &request).unwrap());
        assert_eq!(
            &output[..4],
            &fields(&[
                (":authority", "example.com:443"),
                (":method", "POST"),
                (":scheme", "https"),
                (":path", "/new"),
            ])
        );
        assert_eq!(
            output
                .iter()
                .filter(|field| field.name == "x-untouched")
                .map(|field| field.value.as_ref())
                .collect::<Vec<_>>(),
            [b"one", b"two"]
        );
        assert!(
            output
                .iter()
                .any(|field| field.name == "x-change" && field.value == "after")
        );

        *request.method_mut() = Method::CONNECT;
        *request.uri_mut() = Uri::parse_http_request_target("other.example:8443", true).unwrap();
        let output = decode(encode_request(&shared(), 0, &request).unwrap());
        assert_eq!(
            &output[..2],
            &fields(&[(":authority", "other.example:8443"), (":method", "CONNECT")])
        );
        assert!(
            output
                .iter()
                .all(|field| field.name != ":path" && field.name != ":scheme")
        );
    }

    #[test]
    fn raw_names_and_values_are_rejected_before_normalization() {
        for name in ["", "Upper", "bad name", ":Status", ":status ", ":protocol"] {
            response(fields(&[(":status", "200"), (name, "x")])).unwrap_err();
        }
        for value in [" leading", "trailing\t", "a\0b", "a\rb", "a\nb"] {
            response(fields(&[(":status", "200"), ("x", value)])).unwrap_err();
        }
    }

    #[test]
    fn request_response_and_trailer_field_rules() {
        for name in [
            "connection",
            "proxy-connection",
            "keep-alive",
            "transfer-encoding",
            "upgrade",
        ] {
            response(fields(&[(":status", "200"), (name, "x")])).unwrap_err();
            trailers(fields(&[(name, "x")])).unwrap_err();
        }
        for name in ["content-length", "host", "te"] {
            trailers(fields(&[(name, "0")])).unwrap_err();
        }
        response(fields(&[(":status", "200"), ("te", "trailers")])).unwrap_err();
        response(fields(&[(":status", "103"), ("content-length", "0")])).unwrap_err();
        let response = response_for_method(
            fields(&[(":status", "200"), ("content-length", "invalid")]),
            true,
            Extensions::new(),
        )
        .unwrap();
        assert_eq!(response.headers()[header::CONTENT_LENGTH], "invalid");
        trailers(fields(&[("x-checksum", "abc")])).unwrap();
    }

    #[test]
    fn successful_connect_keeps_content_length_for_every_2xx() {
        for status in ["200", "201", "204", "205", "206", "299"] {
            for length in ["0", "5", "invalid"] {
                let response = response_for_method(
                    fields(&[(":status", status), ("content-length", length)]),
                    true,
                    Extensions::new(),
                )
                .unwrap_or_else(|error| panic!("CONNECT {status} CL={length}: {error:?}"));
                assert_eq!(response.headers()[header::CONTENT_LENGTH], length);
            }
        }
        // Without a tunnel the ordinary framing rules stay.
        for (status, connect) in [("204", false), ("103", true), ("403", true)] {
            let length = if status == "403" { "invalid" } else { "0" };
            response_for_method(
                fields(&[(":status", status), ("content-length", length)]),
                connect,
                Extensions::new(),
            )
            .unwrap_err();
        }
        let refused = response_for_method(
            fields(&[(":status", "403"), ("content-length", "5")]),
            true,
            Extensions::new(),
        )
        .unwrap();
        assert_eq!(refused.headers()[header::CONTENT_LENGTH], "5");
    }

    #[test]
    fn extended_connect_requests_keep_content_length() {
        let head = |length| {
            fields(&[
                (":method", "CONNECT"),
                (":scheme", "https"),
                (":authority", "example.com"),
                (":path", "/capsules"),
                (":protocol", "x-capsule"),
                ("content-length", length),
            ])
        };
        for length in ["0", "5"] {
            let request = request_head(head(length), true).unwrap();
            assert_eq!(request.headers()[header::CONTENT_LENGTH], length);
        }
        request_head(head("invalid"), true).unwrap_err();
    }

    #[test]
    fn response_rejects_each_request_pseudo_header_independently() {
        for pseudo in [
            (":method", "GET"),
            (":scheme", "https"),
            (":authority", "example.com"),
            (":path", "/"),
        ] {
            let error = response(fields(&[(":status", "200"), pseudo])).unwrap_err();
            assert_eq!(error.code(), Code::H3_MESSAGE_ERROR);
            assert_eq!(error.scope(), crate::h3::qpack::ErrorScope::Stream);
        }
    }

    #[test]
    fn request_paths_and_connect() {
        for path in ["/", "//double/slash", "/?query=1"] {
            let req = request(fields(&[
                (":method", "GET"),
                (":scheme", "https"),
                (":authority", "example.com"),
                (":path", path),
            ]))
            .unwrap();
            assert_eq!(req.uri().request_target(), path);
        }
        let req = request(fields(&[
            (":method", "CONNECT"),
            (":authority", "example.com:443"),
        ]))
        .unwrap();
        assert_eq!(
            req.uri().authority().unwrap().to_string(),
            "example.com:443"
        );
        request(fields(&[
            (":method", "CONNECT"),
            (":authority", "example.com"),
        ]))
        .unwrap_err();
    }

    #[test]
    fn authority_userinfo_is_kept_outside_the_http_family_and_never_indexed() {
        for (uri, authority, never_index) in [
            ("https://user@example.com/", "example.com", false),
            ("ftp://user:pw@example.com/f", "user:pw@example.com", true),
        ] {
            let request = Request::builder().uri(uri).body(()).unwrap();
            let fields = decode(encode_request(&shared(), 0, &request).unwrap());
            let field = fields
                .iter()
                .find(|field| field.name == ":authority")
                .unwrap();
            assert_eq!(
                (&field.value[..], field.never_index),
                (authority.as_bytes(), never_index)
            );
        }
    }

    /// The `:authority` actually sent, or `None` when encoding refuses the request.
    fn wire_authority(uri: &str, host: Option<&str>) -> Option<Bytes> {
        let encoded = encode_request(&shared(), 0, &authority_request(uri, host)).ok()?;
        let fields = decode(encoded);
        fields
            .into_iter()
            .find(|field| field.name == ":authority")
            .map(|field| field.value)
    }

    fn h2_wire_authority(uri: &str, host: Option<&str>) -> Option<Bytes> {
        let (frame, _) = crate::h2::client::Peer::convert_send_message(
            StreamId::from(1),
            authority_request(uri, host),
            None,
            true,
            None,
            None,
        )
        .ok()?;
        frame
            .pseudo()
            .authority
            .as_deref()
            .map(|authority| Bytes::copy_from_slice(authority.as_bytes()))
    }

    /// A GET for `uri`, with `host` taken as raw bytes so raw UTF-8 can be sent.
    fn authority_request(uri: &str, host: Option<&str>) -> Request<()> {
        let mut request = Request::builder().uri(uri).body(()).unwrap();
        if let Some(host) = host {
            request.headers_mut().insert(
                header::HOST,
                HeaderValue::from_bytes(host.as_bytes()).unwrap(),
            );
        }
        request
    }

    /// Host is compared with the projected wire authority, not the raw URI.
    #[test]
    fn host_is_compared_with_the_projected_authority() {
        for (uri, host, expected) in [
            // HTTP-family userinfo is stripped whether or not a Host is present.
            ("https://user:pw@example.com/", None, Some("example.com")),
            (
                "https://user:pw@example.com/",
                Some("example.com"),
                Some("example.com"),
            ),
            (
                "http://user@example.com/",
                Some("EXAMPLE.com"),
                Some("EXAMPLE.com"),
            ),
            // A matching Host is sent byte for byte, including a leading-zero port.
            (
                "https://example.com:02/",
                Some("example.com:02"),
                Some("example.com:02"),
            ),
            // Other schemes keep userinfo, which a matching Host can never express.
            ("ftp://user@example.com/f", None, Some("user@example.com")),
            (
                "ftp://user@example.com/f",
                Some("example.com"),
                Some("user@example.com"),
            ),
            // A Host naming another authority is the wire authority, as with curl.
            (
                "https://example.com/",
                Some("other.example"),
                Some("other.example"),
            ),
            (
                "ftp://user@example.com/f",
                Some("other.example:21"),
                Some("other.example:21"),
            ),
            // A Host carrying userinfo is dropped next to the URI authority.
            (
                "https://example.com/",
                Some("user@example.com"),
                Some("example.com"),
            ),
            // Both sides are read with the received grammar: a raw UTF-8 authority without an
            // IDNA form compares like any other.
            (
                "https://\u{fffd}.example/",
                Some("other.example"),
                Some("other.example"),
            ),
            (
                "https://\u{fffd}.example/",
                Some("\u{fffd}.example"),
                Some("\u{fffd}.example"),
            ),
        ] {
            let expected = expected.map(|value: &str| Bytes::copy_from_slice(value.as_bytes()));
            assert_eq!(
                wire_authority(uri, host),
                expected,
                "h3 {uri} with Host {host:?}"
            );
            assert_eq!(
                h2_wire_authority(uri, host),
                expected,
                "h2 {uri} with Host {host:?}"
            );
        }
    }

    /// Several Host lines are refused on every version (RFC 9112 §3.2), equal or not, with or
    /// without `:authority`: which one routes would be a guess another hop may make differently.
    #[test]
    fn several_hosts_are_refused_on_every_version() {
        let text = |value: &'static str| {
            hpack::BytesStr::try_from(Bytes::from_static(value.as_bytes())).unwrap()
        };
        for hosts in [["a.example", "b.example"], ["a.example", "a.example"]] {
            let raw = format!(
                "GET / HTTP/1.1\r\nHost: {}\r\nHost: {}\r\n\r\n",
                hosts[0], hosts[1]
            );
            assert!(h1::refuses(&raw), "h1 {hosts:?}");
            for authority in [Some("example.com"), None] {
                let mut head = vec![(":method", "GET"), (":scheme", "https"), (":path", "/")];
                head.extend(authority.map(|authority| (":authority", authority)));
                head.extend(hosts.map(|host| ("host", host)));
                request(fields(&head)).unwrap_err();
                let mut headers = HeaderMap::new();
                for host in hosts {
                    headers.append(header::HOST, HeaderValue::from_static(host));
                }
                let pseudo = frame::Pseudo {
                    method: Some(Method::GET),
                    scheme: Some(text("https")),
                    authority: authority.map(text),
                    path: Some(text("/")),
                    ..Default::default()
                };
                crate::h2::server::test_util::receive(pseudo, headers).unwrap_err();
            }
        }
    }

    /// An unusable Host never reaches the wire next to a URI authority, on any version; without
    /// one, every version refuses it.
    #[test]
    fn unusable_hosts_are_dropped_next_to_the_uri_authority() {
        let request = |uri: &str, hosts: &[&'static str]| {
            let mut request = Request::new(());
            *request.uri_mut() = Uri::parse(uri).unwrap();
            for host in hosts {
                request
                    .headers_mut()
                    .append(header::HOST, HeaderValue::from_static(host));
            }
            request
        };
        for hosts in [
            &["bad host"][..],
            &["a@b@evil.example"][..],
            &["user@other.example"][..],
            &["a.example", "b.example"][..],
        ] {
            let sent = decode(
                encode_request(&shared(), 0, &request("https://good.example/", hosts)).unwrap(),
            );
            let authorities: Vec<_> = sent
                .iter()
                .filter(|field| field.name == ":authority" || field.name == "host")
                .map(|field| (field.name.clone(), field.value.clone()))
                .collect();
            assert_eq!(
                authorities,
                [(
                    Bytes::from_static(b":authority"),
                    Bytes::from_static(b"good.example")
                )],
                "h3 {hosts:?}"
            );
            let (frame, _) = crate::h2::client::Peer::convert_send_message(
                StreamId::from(1),
                request("https://good.example/", hosts),
                None,
                true,
                None,
                None,
            )
            .unwrap();
            assert_eq!(
                frame.pseudo().authority.as_deref(),
                Some("good.example"),
                "h2 {hosts:?}"
            );
            assert!(frame.fields().get(header::HOST).is_none(), "h2 {hosts:?}");
            let sent = request("https://good.example/", hosts);
            let h1 =
                h1::send_with(Method::GET, sent.uri().clone(), sent.headers().clone()).unwrap();
            assert!(
                h1.starts_with("GET / HTTP/1.1\r\nhost: good.example\r\n"),
                "h1 {hosts:?}: {h1}"
            );
            // Without a URI authority the Host is all there is, and no version can send it.
            for uri in ["custom:/p", "/p"] {
                encode_request(&shared(), 0, &request(uri, hosts)).unwrap_err();
                let sent = request(uri, hosts);
                assert!(
                    h1::send_with(Method::GET, sent.uri().clone(), sent.headers().clone())
                        .is_none(),
                    "h1 {uri} {hosts:?}"
                );
                crate::h2::client::Peer::convert_send_message(
                    StreamId::from(1),
                    request(uri, hosts),
                    None,
                    true,
                    None,
                    None,
                )
                .unwrap_err();
            }
        }
    }

    /// With an :authority, H3 accepts and replaces any Host, whatever its order.
    #[test]
    fn unparseable_hosts_are_replaced_by_the_authority() {
        for hosts in [
            &["bad host"][..],
            &[""][..],
            &["a@b@evil.example"][..],
            &["example.com:99999"][..],
        ] {
            let mut head = vec![
                (":method", "GET"),
                (":scheme", "https"),
                (":authority", "example.com"),
                (":path", "/"),
            ];
            head.extend(hosts.iter().map(|host| ("host", *host)));
            let received = request_head(fields(&head), true).unwrap();
            let received_hosts: Vec<_> = received.headers().get_all(header::HOST).iter().collect();
            assert_eq!(received_hosts, ["example.com"], "{hosts:?}");
        }
        // Without one, an unparseable first Host is kept, like H1/H2, and cannot be sent on.
        let received = request_head(
            fields(&[
                (":method", "GET"),
                (":scheme", "https"),
                (":path", "/"),
                ("host", "bad host"),
            ]),
            true,
        )
        .unwrap();
        assert!(received.uri().authority().is_none());
        assert_eq!(received.headers()[header::HOST], "bad host");
        encode_request(&shared(), 0, &received).unwrap_err();
    }

    /// An OPTIONS request without a path is `*` on H1, H2 and H3 (RFC 9112 §3.2.4), for every
    /// scheme, so a received `*` is relayed as `*`.
    #[test]
    fn options_without_a_path_is_sent_as_asterisk() {
        // A URI without a path, as a service or an adapter builds it, is the server-wide request
        // on every version (RFC 9112 §3.2.4, RFC 9113 §8.3.1).
        for uri in ["https://real.example", "foo://real.example"] {
            let uri = Uri::parse(uri).unwrap();
            let mut request = Request::new(());
            *request.method_mut() = Method::OPTIONS;
            *request.uri_mut() = uri.clone();
            let sent = decode(encode_request(&shared(), 0, &request).unwrap());
            let path = sent.iter().find(|field| field.name == ":path").unwrap();
            assert_eq!(path.value, &b"*"[..], "h3 {uri}");
            let h2 = frame::Pseudo::request(Method::OPTIONS, &uri, None);
            assert_eq!(h2.path.as_deref(), Some("*"), "h2 {uri}");
            let mut h1 = Vec::new();
            rama_http_types::proto::h1::head::encode_request_target(
                &Method::OPTIONS,
                &uri,
                &Default::default(),
                &mut h1,
            )
            .unwrap();
            assert_eq!(&h1[..], b"*", "h1 {uri}");
        }
        // A path or query is kept as is.
        for (uri, h1_target) in [
            ("https://real.example/", "/"),
            ("https://real.example?q", "/?q"),
        ] {
            let mut h1 = Vec::new();
            rama_http_types::proto::h1::head::encode_request_target(
                &Method::OPTIONS,
                &Uri::parse(uri).unwrap(),
                &Default::default(),
                &mut h1,
            )
            .unwrap();
            assert_eq!(&h1[..], h1_target.as_bytes(), "{uri}");
        }
    }

    /// Outside http(s) a request may have an empty `:path` (RFC 9113 §8.3.1, RFC 9114 §4.3.1)
    /// on H2 as on H3; on OPTIONS it is the server-wide `*`, which both relay as `*`.
    #[test]
    fn empty_paths_of_other_schemes_are_received_alike_on_h2_and_h3() {
        let text = |value: &'static str| {
            hpack::BytesStr::try_from(Bytes::from_static(value.as_bytes())).unwrap()
        };
        for authority in [Some("example.com"), None] {
            for (method, protocol, path, sent_path) in [
                ("OPTIONS", None, "", "*"),
                ("OPTIONS", None, "*", "*"),
                ("GET", None, "", ""),
                ("GET", None, "/x", "/x"),
                ("CONNECT", Some("x-custom"), "", ""),
            ] {
                let case = format!("{method} {path:?} {protocol:?} {authority:?}");
                let h3 = || {
                    let mut h3_fields = vec![(":method", method), (":scheme", "custom")];
                    h3_fields.extend(authority.map(|authority| (":authority", authority)));
                    h3_fields.push((":path", path));
                    h3_fields.extend(protocol.map(|protocol| (":protocol", protocol)));
                    request_head(fields(&h3_fields), true).unwrap()
                };
                let h2 = || {
                    let pseudo = frame::Pseudo {
                        method: Some(Method::from_bytes(method.as_bytes()).unwrap()),
                        scheme: Some(text("custom")),
                        authority: authority.map(text),
                        path: Some(text(path)),
                        protocol: protocol.map(rama_http_types::proto::ext::Protocol::from_static),
                        ..Default::default()
                    };
                    crate::h2::server::test_util::receive(pseudo, HeaderMap::new())
                        .unwrap_or_else(|error| panic!("h2 {case}: {error:?}"))
                };
                assert_eq!(h2().uri(), h3().uri(), "{case}");
                assert_eq!(h2().headers(), h3().headers(), "{case}");
                for (version, received) in [("h2", h2()), ("h3", h3())] {
                    let sent = decode(encode_request(&shared(), 0, &received).unwrap());
                    let field = |name: &str| {
                        sent.iter()
                            .find(|field| field.name == name)
                            .map(|field| field.value.clone())
                    };
                    assert_eq!(
                        field(":path").as_deref(),
                        Some(sent_path.as_bytes()),
                        "{version} {case} h3"
                    );
                    assert_eq!(
                        field(":scheme").as_deref(),
                        Some(&b"custom"[..]),
                        "{version} {case} h3"
                    );
                    assert_eq!(
                        field(":authority").as_deref(),
                        authority.map(str::as_bytes),
                        "{version} {case} h3"
                    );
                    let again = request_head(sent, true).unwrap();
                    assert_eq!(again.uri(), received.uri(), "{version} {case} h3");

                    let uri = received.uri().clone();
                    let protocol = received
                        .extensions()
                        .get_ref::<rama_http_types::proto::ext::Protocol>()
                        .cloned();
                    let (frame, _) = crate::h2::client::Peer::convert_send_message(
                        StreamId::from(1),
                        received,
                        protocol,
                        true,
                        None,
                        None,
                    )
                    .unwrap_or_else(|error| panic!("{version} {case} h2: {error:?}"));
                    assert_eq!(
                        frame.pseudo().path.as_deref(),
                        Some(sent_path),
                        "{version} {case} h2"
                    );
                    assert_eq!(
                        frame.pseudo().scheme.as_deref(),
                        Some("custom"),
                        "{version} {case} h2"
                    );
                    let (pseudo, headers) = frame.into_parts();
                    assert_eq!(
                        pseudo.authority.as_deref(),
                        authority,
                        "{version} {case} h2"
                    );
                    let again = crate::h2::server::test_util::receive(pseudo, headers).unwrap();
                    assert_eq!(again.uri(), &uri, "{version} {case} h2");
                }
            }
        }
        // http(s) still needs a path.
        let pseudo = frame::Pseudo {
            method: Some(Method::GET),
            scheme: Some(text("https")),
            authority: Some(text("example.com")),
            path: Some(text("")),
            ..Default::default()
        };
        crate::h2::server::test_util::receive(pseudo, HeaderMap::new()).unwrap_err();
    }

    /// HTTP/2 and HTTP/3 send an empty `:path` only for a non-http(s) wire scheme without path
    /// and query; a query is always sent, after a `/`, and a ws/wss root is `/` as its
    /// http/https `:scheme` requires. Each reads back to the same target on both versions.
    #[test]
    fn queries_and_websocket_roots_survive_encoding() {
        for (method, protocol, uri, wire_scheme, wire_path) in [
            ("GET", None, "custom://example.com", "custom", ""),
            (
                "GET",
                None,
                "custom://example.com?name=value",
                "custom",
                "/?name=value",
            ),
            ("OPTIONS", None, "custom://example.com", "custom", "*"),
            (
                "OPTIONS",
                None,
                "custom://example.com?name=value",
                "custom",
                "/?name=value",
            ),
            (
                "CONNECT",
                Some("x-custom"),
                "custom://example.com",
                "custom",
                "",
            ),
            (
                "CONNECT",
                Some("x-custom"),
                "custom://example.com?name=value",
                "custom",
                "/?name=value",
            ),
            (
                "CONNECT",
                Some("websocket"),
                "ws://example.com",
                "http",
                "/",
            ),
            (
                "CONNECT",
                Some("websocket"),
                "wss://example.com",
                "https",
                "/",
            ),
            (
                "CONNECT",
                Some("websocket"),
                "wss://example.com?room=1",
                "https",
                "/?room=1",
            ),
            (
                "CONNECT",
                Some("websocket"),
                "wss://example.com/chat",
                "https",
                "/chat",
            ),
        ] {
            let case = format!("{method} {uri}");
            let request = || {
                let request = Request::builder().method(method).uri(uri).body(()).unwrap();
                if let Some(protocol) = protocol {
                    request
                        .extensions()
                        .insert(rama_http_types::proto::ext::Protocol::from_static(protocol));
                }
                request
            };

            let sent = decode(encode_request(&shared(), 0, &request()).unwrap());
            let field = |name: &str| {
                sent.iter()
                    .find(|field| field.name == name)
                    .map(|field| field.value.clone())
            };
            assert_eq!(
                field(":path").as_deref(),
                Some(wire_path.as_bytes()),
                "h3 {case}"
            );
            assert_eq!(
                field(":scheme").as_deref(),
                Some(wire_scheme.as_bytes()),
                "h3 {case}"
            );
            let h3 = request_head(sent, true).unwrap();

            let (frame, _) = crate::h2::client::Peer::convert_send_message(
                StreamId::from(1),
                request(),
                protocol.map(rama_http_types::proto::ext::Protocol::from_static),
                true,
                None,
                None,
            )
            .unwrap();
            assert_eq!(frame.pseudo().path.as_deref(), Some(wire_path), "h2 {case}");
            assert_eq!(
                frame.pseudo().scheme.as_deref(),
                Some(wire_scheme),
                "h2 {case}"
            );
            let (pseudo, headers) = frame.into_parts();
            let h2 = crate::h2::server::test_util::receive(pseudo, headers)
                .unwrap_or_else(|error| panic!("h2 {case}: {error:?}"));

            assert_eq!(h2.uri(), h3.uri(), "{case}");
            assert_eq!(
                h3.uri().query(),
                request().uri().query(),
                "the query reads back: {case}"
            );
        }
    }

    /// `OPTIONS *` reads alike on HTTP/1, HTTP/2 and HTTP/3: an asterisk URI, its scheme beside
    /// it, and its authority as `Host`, winning over a disagreeing one and keeping its
    /// never-index flag. Sent on over HTTP/2 or HTTP/3, that `Host` is the `:authority` again.
    #[test]
    fn options_asterisk_reads_alike_on_every_version() {
        let text = |value: &'static str| {
            hpack::BytesStr::try_from(Bytes::from_static(value.as_bytes())).unwrap()
        };
        for (path, sensitive) in [("*", false), ("*", true), ("", false)] {
            for host in [None, Some("example.com"), Some("other.example")] {
                let case = format!("{path:?} sensitive={sensitive} host={host:?}");
                let scheme = if path.is_empty() { "custom" } else { "https" };
                let mut h3_fields = vec![
                    FieldPair {
                        name: Bytes::from_static(b":method"),
                        value: Bytes::from_static(b"OPTIONS"),
                        never_index: false,
                    },
                    FieldPair {
                        name: Bytes::from_static(b":scheme"),
                        value: Bytes::from_static(scheme.as_bytes()),
                        never_index: false,
                    },
                    FieldPair {
                        name: Bytes::from_static(b":authority"),
                        value: Bytes::from_static(b"example.com"),
                        never_index: sensitive,
                    },
                    FieldPair {
                        name: Bytes::from_static(b":path"),
                        value: Bytes::from_static(path.as_bytes()),
                        never_index: false,
                    },
                ];
                h3_fields.extend(host.map(|host| FieldPair {
                    name: Bytes::from_static(b"host"),
                    value: Bytes::from_static(host.as_bytes()),
                    never_index: false,
                }));
                let h3 = request(h3_fields).unwrap();
                let mut pseudo = frame::Pseudo {
                    method: Some(Method::OPTIONS),
                    scheme: Some(text(scheme)),
                    authority: Some(text("example.com")),
                    path: Some(text(path)),
                    ..Default::default()
                };
                pseudo
                    .sensitivity
                    .set_sensitive(PseudoHeader::Authority, sensitive);
                let mut headers = HeaderMap::new();
                if let Some(host) = host {
                    headers.insert(header::HOST, HeaderValue::from_static(host));
                }
                let h2 = crate::h2::server::test_util::receive(pseudo, headers).unwrap();

                for (version, received) in [("h2", &h2), ("h3", &h3)] {
                    assert!(received.uri().is_asterisk(), "{version} {case}");
                    let host = received.headers().get(header::HOST).unwrap();
                    assert_eq!(host, "example.com", "{version} {case}");
                    assert_eq!(host.is_sensitive(), sensitive, "{version} {case}");
                    assert_eq!(
                        received
                            .extensions()
                            .get_ref::<Protocol>()
                            .map(Protocol::as_str),
                        Some(scheme),
                        "{version} {case}"
                    );
                }
                assert_eq!(h2.headers(), h3.headers(), "{case}");

                for (version, received) in [("h2", h2), ("h3", h3)] {
                    let sent = decode(encode_request(&shared(), 0, &received).unwrap());
                    let field = |name: &str| sent.iter().find(|field| field.name == name).cloned();
                    let authority = field(":authority").unwrap();
                    assert_eq!(&authority.value[..], b"example.com", "{version} {case} h3");
                    assert_eq!(authority.never_index, sensitive, "{version} {case} h3");
                    assert_eq!(
                        &field(":path").unwrap().value[..],
                        b"*",
                        "{version} {case} h3"
                    );

                    let (frame, _) = crate::h2::client::Peer::convert_send_message(
                        StreamId::from(1),
                        received,
                        None,
                        true,
                        None,
                        None,
                    )
                    .unwrap();
                    let (pseudo, _) = frame.into_parts();
                    assert_eq!(
                        pseudo.authority.as_deref(),
                        Some("example.com"),
                        "{version} {case} h2"
                    );
                    assert_eq!(
                        pseudo.sensitivity.is_sensitive(PseudoHeader::Authority),
                        sensitive,
                        "{version} {case} h2"
                    );
                    assert_eq!(pseudo.path.as_deref(), Some("*"), "{version} {case} h2");
                    assert_eq!(
                        pseudo.scheme.as_deref(),
                        Some(scheme),
                        "{version} {case} h2"
                    );
                }
            }
        }

        // HTTP/1 reads it the same way, and has only `Host` to carry the authority. That is the
        // target's authority (RFC 9112 §3.3), so HTTP/2 and HTTP/3 send it as `:authority`.
        let (uri, headers) = h1::receive("OPTIONS * HTTP/1.1\r\nHost: example.com\r\n\r\n");
        assert!(uri.is_asterisk());
        assert_eq!(headers[header::HOST], "example.com");
        let from_h1 = || {
            let mut request = Request::new(());
            *request.method_mut() = Method::OPTIONS;
            *request.uri_mut() = uri.clone();
            *request.headers_mut() = headers.clone();
            request.extensions().insert(Protocol::HTTPS);
            request
        };
        let sent = decode(encode_request(&shared(), 0, &from_h1()).unwrap());
        let authority = sent
            .iter()
            .find(|field| field.name == ":authority")
            .unwrap();
        assert_eq!(&authority.value[..], b"example.com");
        let (frame, _) = crate::h2::client::Peer::convert_send_message(
            StreamId::from(1),
            from_h1(),
            None,
            true,
            None,
            None,
        )
        .unwrap();
        assert_eq!(frame.pseudo().authority.as_deref(), Some("example.com"));
        assert_eq!(frame.pseudo().path.as_deref(), Some("*"));
    }

    /// An asterisk target is a server-wide OPTIONS on every version; another method with it
    /// is refused, not read as `/`.
    #[test]
    fn an_asterisk_target_needs_options_on_every_version() {
        let text = |value: &'static str| {
            hpack::BytesStr::try_from(Bytes::from_static(value.as_bytes())).unwrap()
        };
        for (method, allowed) in [("OPTIONS", true), ("GET", false), ("POST", false)] {
            let raw = format!("{method} * HTTP/1.1\r\nHost: example.com\r\n\r\n");
            assert_eq!(!h1::refuses(&raw), allowed, "h1 {method}");
            let pseudo = frame::Pseudo {
                method: Some(Method::from_bytes(method.as_bytes()).unwrap()),
                scheme: Some(text("https")),
                authority: Some(text("example.com")),
                path: Some(text("*")),
                ..Default::default()
            };
            assert_eq!(
                crate::h2::server::test_util::receive(pseudo, HeaderMap::new()).is_ok(),
                allowed,
                "h2 {method}"
            );
            let head = fields(&[
                (":method", method),
                (":scheme", "https"),
                (":authority", "example.com"),
                (":path", "*"),
            ]);
            assert_eq!(request(head).is_ok(), allowed, "h3 {method}");
        }
    }

    /// A request naming its target only by `Host` resolves to that `Host` on H2 and H3 alike,
    /// also when the connection's TLS SNI names another origin it coalesces.
    #[test]
    fn a_host_only_target_resolves_alike_on_h2_and_h3_whatever_the_sni() {
        use rama_net::AuthorityInputExt as _;
        use rama_tls::{
            ProtocolVersion, SecureTransport,
            client::{ClientHello, ClientHelloExtension},
        };
        let mut host = HeaderMap::new();
        host.insert(
            rama_http_types::header::HOST,
            HeaderValue::from_static("b.example"),
        );
        let h3 = request(fields(&[
            (":method", "GET"),
            (":scheme", "https"),
            (":path", "/"),
            ("host", "b.example"),
        ]))
        .unwrap();
        let pseudo = frame::Pseudo {
            method: Some(Method::GET),
            scheme: Some(hpack::BytesStr::try_from(Bytes::from_static(b"https")).unwrap()),
            path: Some(hpack::BytesStr::try_from(Bytes::from_static(b"/")).unwrap()),
            ..Default::default()
        };
        let h2 = crate::h2::server::test_util::receive(pseudo, host).unwrap();
        for request in [&h3, &h2] {
            request
                .extensions()
                .insert(SecureTransport::with_client_hello(ClientHello::new(
                    ProtocolVersion::TLSv1_3,
                    Vec::new(),
                    Vec::new(),
                    vec![ClientHelloExtension::ServerName(Some(
                        rama_net::address::Domain::from_static("a.example"),
                    ))],
                )));
            let expected = Some(rama_net::address::HostWithOptPort::try_from("b.example").unwrap());
            assert_eq!(request.target_authority(), expected);
            assert_eq!(request.authority(), expected);
        }
    }

    /// A raw UTF-8 host is a reg-name the URI grammar accepts, on H2 as on H3, and is sent on.
    #[test]
    fn raw_utf8_authorities_are_received_alike_on_h2_and_h3() {
        let h3 = request(fields(&[
            (":method", "GET"),
            (":scheme", "https"),
            (":authority", "bücher.example"),
            (":path", "/"),
        ]))
        .unwrap();
        let pseudo = frame::Pseudo {
            method: Some(Method::GET),
            scheme: Some(hpack::BytesStr::try_from(Bytes::from_static(b"https")).unwrap()),
            authority: Some(hpack::BytesStr::try_from(Bytes::from("bücher.example")).unwrap()),
            path: Some(hpack::BytesStr::try_from(Bytes::from_static(b"/")).unwrap()),
            ..Default::default()
        };
        let h2 = crate::h2::server::test_util::receive(pseudo, HeaderMap::new()).unwrap();
        assert_eq!(h3.uri(), h2.uri());
        let sent = decode(encode_request(&shared(), 0, &h3).unwrap());
        let authority = sent
            .iter()
            .find(|field| field.name == ":authority")
            .unwrap();
        // Sent as its IDNA form when rama-net has `idna`, else as received; both read back as
        // the same target.
        assert!(
            [&b"xn--bcher-kva.example"[..], "bücher.example".as_bytes()]
                .contains(&&authority.value[..]),
            "{:?}",
            authority.value
        );
        assert_eq!(request(sent).unwrap().uri(), h3.uri());

        // A Host beside it becomes the authority's own Host form: raw, or its IDNA form with
        // rama-net's `idna`.
        for (authority, idna_form) in [
            ("bücher.example", Some("xn--bcher-kva.example")),
            ("\u{fffd}.example", None),
        ] {
            for host in [authority, "[ve.ü]:", "other.example"] {
                let h3 = request(fields(&[
                    (":method", "GET"),
                    (":scheme", "https"),
                    (":authority", authority),
                    (":path", "/"),
                    ("host", host),
                ]))
                .unwrap();
                let mut headers = HeaderMap::new();
                headers.insert(
                    header::HOST,
                    HeaderValue::from_bytes(host.as_bytes()).unwrap(),
                );
                let pseudo = frame::Pseudo {
                    method: Some(Method::GET),
                    scheme: Some(hpack::BytesStr::try_from(Bytes::from_static(b"https")).unwrap()),
                    authority: Some(hpack::BytesStr::try_from(Bytes::from(authority)).unwrap()),
                    path: Some(hpack::BytesStr::try_from(Bytes::from_static(b"/")).unwrap()),
                    ..Default::default()
                };
                let h2 = crate::h2::server::test_util::receive(pseudo, headers).unwrap();
                let received = h3.headers().get(header::HOST);
                assert!(
                    received
                        .is_some_and(|value| value == authority
                            || idna_form.is_some_and(|form| value == form)),
                    "{authority} {host}: {received:?}"
                );
                assert_eq!(
                    h2.headers().get(header::HOST),
                    received,
                    "{authority} {host}"
                );
                assert_eq!(h2.uri(), h3.uri(), "{authority} {host}");
                let again = request(decode(encode_request(&shared(), 0, &h3).unwrap())).unwrap();
                assert_eq!(again.headers(), h3.headers(), "{authority} {host}");
            }
        }

        // An authority without a host names nothing a Host could carry, on either version.
        for authority in ["@", "user@", ""] {
            for scheme in ["https", "custom"] {
                request(fields(&[
                    (":method", "GET"),
                    (":scheme", scheme),
                    (":authority", authority),
                    (":path", "/"),
                ]))
                .unwrap_err();
                let pseudo = frame::Pseudo {
                    method: Some(Method::GET),
                    scheme: Some(hpack::BytesStr::try_from(Bytes::from(scheme)).unwrap()),
                    authority: Some(hpack::BytesStr::try_from(Bytes::from(authority)).unwrap()),
                    path: Some(hpack::BytesStr::try_from(Bytes::from_static(b"/")).unwrap()),
                    ..Default::default()
                };
                crate::h2::server::test_util::receive(pseudo, HeaderMap::new())
                    .expect_err(authority);
            }
        }
    }

    /// A plain CONNECT names a host and port on every version, received or sent: there is no
    /// default port to guess. Userinfo is accepted on receipt and never sent.
    #[test]
    fn ordinary_connect_names_a_port_on_every_version() {
        for (authority, routed) in [
            ("example.com", None),
            ("example.com:", None),
            ("[::1]", None),
            ("[::1]:", None),
            ("example.com:443", Some("example.com:443")),
            ("[::1]:8443", Some("[::1]:8443")),
            ("user@example.com:443", Some("example.com:443")),
        ] {
            let raw = format!("CONNECT {authority} HTTP/1.1\r\n\r\n");
            let h1 = (!h1::refuses(&raw)).then(|| h1::receive(&raw).0.to_string());
            let h2 = crate::h2::server::test_util::receive(
                frame::Pseudo {
                    method: Some(Method::CONNECT),
                    authority: Some(
                        hpack::BytesStr::try_from(Bytes::copy_from_slice(authority.as_bytes()))
                            .unwrap(),
                    ),
                    ..Default::default()
                },
                HeaderMap::new(),
            )
            .ok()
            .map(|request| request.uri().to_string());
            let h3 = request_head(
                vec![
                    FieldPair {
                        name: Bytes::from_static(b":method"),
                        value: Bytes::from_static(b"CONNECT"),
                        never_index: false,
                    },
                    FieldPair {
                        name: Bytes::from_static(b":authority"),
                        value: Bytes::copy_from_slice(authority.as_bytes()),
                        never_index: false,
                    },
                ],
                true,
            )
            .ok()
            .map(|request| request.uri().to_string());
            for (version, received) in [("h1", h1), ("h2", h2), ("h3", h3)] {
                assert_eq!(
                    received.as_deref(),
                    routed,
                    "{version} received {authority}"
                );
            }

            let uri = Uri::parse_authority_form(authority).unwrap();
            let connect = || {
                let mut request = Request::new(());
                *request.method_mut() = Method::CONNECT;
                *request.uri_mut() = uri.clone();
                request
            };
            let h1 = h1::send(Method::CONNECT, uri.clone()).map(|head| {
                let line = head.lines().next().unwrap().to_owned();
                line.strip_prefix("CONNECT ")
                    .unwrap()
                    .strip_suffix(" HTTP/1.1")
                    .unwrap()
                    .to_owned()
            });
            let h2 = crate::h2::client::Peer::convert_send_message(
                StreamId::from(1),
                connect(),
                None,
                true,
                None,
                None,
            )
            .ok()
            .map(|(frame, _)| frame.pseudo().authority.as_deref().unwrap().to_owned());
            let h3 = encode_request(&shared(), 0, &connect())
                .ok()
                .map(|encoded| {
                    let fields = decode(encoded);
                    let authority = fields
                        .iter()
                        .find(|field| field.name == ":authority")
                        .unwrap();
                    String::from_utf8(authority.value.to_vec()).unwrap()
                });
            for (version, sent) in [("h1", h1), ("h2", h2), ("h3", h3)] {
                assert_eq!(sent.as_deref(), routed, "{version} sent {authority}");
            }
        }
    }

    /// An ordinary CONNECT still names a port after a Host override, on H2 and H3.
    #[test]
    fn ordinary_connect_keeps_a_port_after_a_host_override() {
        for (host, sent) in [
            (None, Some("real.example:443")),
            (Some("other.example:8443"), Some("other.example:8443")),
            (Some("[::1]:8443"), Some("[::1]:8443")),
            (Some("other.example"), None),
            (Some("other.example:"), None),
            (Some("[::1]"), None),
            (Some("[::1]:"), None),
        ] {
            let connect = || {
                let mut request = Request::new(());
                *request.method_mut() = Method::CONNECT;
                *request.uri_mut() =
                    Uri::parse_http_request_target("real.example:443", true).unwrap();
                if let Some(host) = host {
                    request
                        .headers_mut()
                        .insert(header::HOST, HeaderValue::from_static(host));
                }
                request
            };
            let h3 = encode_request(&shared(), 0, &connect())
                .ok()
                .map(|encoded| {
                    let fields = decode(encoded);
                    assert!(
                        !fields
                            .iter()
                            .any(|field| field.name == ":scheme" || field.name == ":path")
                    );
                    let authority = fields.into_iter().find(|field| field.name == ":authority");
                    authority.unwrap().value
                });
            assert_eq!(h3.as_deref(), sent.map(str::as_bytes), "h3 {host:?}");
            let h2 = crate::h2::client::Peer::convert_send_message(
                StreamId::from(1),
                connect(),
                None,
                true,
                None,
                None,
            )
            .ok()
            .map(|(frame, _)| frame.pseudo().authority.as_deref().unwrap().to_owned());
            assert_eq!(h2.as_deref(), sent, "h2 {host:?}");
        }
        // Extended CONNECT is an ordinary target: a port-less Host is its wire authority.
        for host in ["other.example", "other.example:", "[::1]", "[::1]:"] {
            let extended = || {
                let mut request = Request::new(());
                *request.method_mut() = Method::CONNECT;
                *request.uri_mut() = Uri::parse("https://real.example/chat").unwrap();
                request.extensions().insert(ext::Protocol::WEBSOCKET);
                request
                    .headers_mut()
                    .insert(header::HOST, HeaderValue::from_static(host));
                request
            };
            let h3 = decode(encode_request(&shared(), 0, &extended()).unwrap());
            let field = |name: &str| {
                h3.iter()
                    .find(|field| field.name == name)
                    .unwrap()
                    .value
                    .clone()
            };
            assert_eq!(field(":authority"), host.as_bytes(), "{host}");
            assert_eq!(field(":path"), &b"/chat"[..], "{host}");
            let (h2, _) = crate::h2::client::Peer::convert_send_message(
                StreamId::from(1),
                extended(),
                Some(ext::Protocol::WEBSOCKET),
                true,
                None,
                None,
            )
            .unwrap();
            assert_eq!(h2.pseudo().authority.as_deref(), Some(host));
            assert_eq!(h2.pseudo().path.as_deref(), Some("/chat"));
        }
    }

    /// An asterisk target's explicit `:authority` wins over Host, as on H2.
    #[test]
    fn asterisk_authority_wins_over_host() {
        for scheme in ["https", "custom"] {
            for (authority, hosts) in [
                ("real.example", &[][..]),
                ("real.example", &["real.example"][..]),
                ("real.example", &["other.example"][..]),
                ("user@real.example", &["other.example"][..]),
            ] {
                let mut head = vec![
                    (":method", "OPTIONS"),
                    (":scheme", scheme),
                    (":authority", authority),
                    (":path", "*"),
                ];
                head.extend(hosts.iter().map(|host| ("host", *host)));
                let received = request_head(fields(&head), true).unwrap();
                let received_hosts: Vec<_> =
                    received.headers().get_all(header::HOST).iter().collect();
                assert_eq!(
                    received_hosts,
                    ["real.example"],
                    "{scheme} {authority} {hosts:?}"
                );
                let sent = decode(encode_request(&shared(), 0, &received).unwrap());
                let sent_authority = sent
                    .iter()
                    .find(|field| field.name == ":authority")
                    .unwrap();
                assert_eq!(
                    sent_authority.value,
                    &b"real.example"[..],
                    "{scheme} {hosts:?}"
                );
            }
        }
        // A sensitive :authority keeps its restriction in the Host that replaces a differing one.
        let mut head = fields(&[
            (":method", "OPTIONS"),
            (":scheme", "https"),
            (":authority", "real.example"),
            (":path", "*"),
            ("host", "other.example"),
        ]);
        head[2].never_index = true;
        let received = request_head(head, true).unwrap();
        assert!(received.headers()[header::HOST].is_sensitive());
    }

    /// A Host derived from a sensitive :authority is never indexed on either version.
    #[test]
    fn hosts_derived_from_a_sensitive_authority_stay_sensitive() {
        let h3 = {
            let mut head = fields(&[
                (":method", "GET"),
                (":scheme", "https"),
                (":authority", "private.example"),
                (":path", "/"),
                ("host", "public.example"),
            ]);
            head[2].never_index = true;
            request_head(head, true).unwrap()
        };
        let h2 = {
            let mut pseudo = frame::Pseudo::request(
                Method::GET,
                &Uri::parse("https://private.example/").unwrap(),
                None,
            );
            pseudo
                .sensitivity
                .set_sensitive(PseudoHeader::Authority, true);
            let mut headers = HeaderMap::new();
            headers.insert(header::HOST, HeaderValue::from_static("public.example"));
            crate::h2::server::test_util::receive(pseudo, headers).unwrap()
        };
        for (version, received) in [("h3", h3), ("h2", h2)] {
            assert_eq!(
                received.headers()[header::HOST],
                "private.example",
                "{version}"
            );
            assert!(received.headers()[header::HOST].is_sensitive(), "{version}");
            let sent = decode(encode_request(&shared(), 0, &received).unwrap());
            for name in ["host", ":authority"] {
                let field = sent.iter().find(|field| field.name == name).unwrap();
                assert!(field.never_index, "{version} sent on h3: {name}");
            }
            let (frame, _) = crate::h2::client::Peer::convert_send_message(
                StreamId::from(1),
                received,
                None,
                true,
                None,
                None,
            )
            .unwrap();
            assert!(
                frame.fields()[header::HOST].is_sensitive(),
                "{version} sent on h2"
            );
            assert!(
                frame
                    .pseudo()
                    .sensitivity
                    .is_sensitive(PseudoHeader::Authority),
                "{version} sent on h2"
            );
        }
    }

    /// An `:authority` taken from a sensitive `Host` is never indexed either.
    #[test]
    fn authorities_taken_from_host_keep_its_sensitivity() {
        for (uri, host) in [
            ("https://example.com/", "EXAMPLE.com"),
            ("https://example.com/", "other.example"),
        ] {
            let mut value = HeaderValue::from_static(host);
            value.set_sensitive(true);
            let request = Request::builder()
                .uri(uri)
                .header(header::HOST, value)
                .body(())
                .unwrap();
            let sent = decode(encode_request(&shared(), 0, &request).unwrap());
            let authority = sent
                .iter()
                .find(|field| field.name == ":authority")
                .unwrap();
            assert_eq!(authority.value, host.as_bytes(), "{host}");
            assert!(authority.never_index, "{host}");
        }
    }

    /// The required-header layer adds `Host: example.com` to a credential URI; it must still encode.
    #[tokio::test]
    async fn required_host_headers_keep_the_http_userinfo_projection() {
        let service =
            AddRequiredRequestHeaders::new(service_fn(|request: Request<()>| async move {
                assert_eq!(request.headers()[header::HOST], "example.com");
                let fields = decode(encode_request(&shared(), 0, &request)?);
                let authority = fields
                    .iter()
                    .find(|field| field.name == ":authority")
                    .unwrap();
                assert_eq!(&authority.value[..], b"example.com");
                Ok::<_, Error>(Response::new(()))
            }));
        let request = Request::builder()
            .uri("https://user:pw@example.com/")
            .body(())
            .unwrap();
        service.serve(request).await.unwrap();
    }

    /// A generated Host keeps a plain CONNECT's port, default or not, so H2 and H3 send it.
    #[tokio::test]
    async fn required_host_headers_keep_a_plain_connect_port() {
        for (uri, authority) in [
            ("http://example.com:80", "example.com:80"),
            ("https://example.com:443", "example.com:443"),
            ("http://example.com:8080", "example.com:8080"),
        ] {
            let service = AddRequiredRequestHeaders::new(service_fn(
                move |request: Request<()>| async move {
                    assert_eq!(request.headers()[header::HOST], authority);
                    let fields = decode(encode_request(&shared(), 0, &request)?);
                    let h3 = fields
                        .iter()
                        .find(|field| field.name == ":authority")
                        .unwrap();
                    assert_eq!(&h3.value[..], authority.as_bytes());
                    let (frame, _) = crate::h2::client::Peer::convert_send_message(
                        StreamId::from(1),
                        request,
                        None,
                        true,
                        None,
                        None,
                    )
                    .unwrap();
                    assert_eq!(frame.pseudo().authority.as_deref(), Some(authority));
                    Ok::<_, Error>(Response::new(()))
                },
            ));
            let request = Request::builder()
                .method(Method::CONNECT)
                .uri(uri)
                .body(())
                .unwrap();
            service.serve(request).await.unwrap();
        }
    }

    /// A decoded Host, userinfo removed, re-encodes to the same request.
    #[test]
    fn decoded_hosts_reencode_and_never_carry_userinfo() {
        for scheme in ["custom", "https"] {
            let head = |host: &'static str| {
                let mut head = fields(&[(":method", "GET"), (":scheme", scheme), (":path", "/")]);
                head.extend(fields(&[("host", host)]));
                head
            };
            for host in ["user@example.com", "example.com", "Example.COM:02"] {
                let accepted = request(head(host)).unwrap();
                assert!(
                    !accepted.headers()[header::HOST].as_bytes().contains(&b'@'),
                    "{host}"
                );
                let forwarded =
                    request(decode(encode_request(&shared(), 0, &accepted).unwrap())).unwrap();
                assert_eq!(forwarded.uri(), accepted.uri(), "{host}");
                assert_eq!(forwarded.headers(), accepted.headers(), "{host}");
            }
        }
    }

    #[test]
    fn extended_connect_pseudo_header_rules() {
        let extended = [
            (":method", "CONNECT"),
            (":protocol", "connect-udp"),
            (":scheme", "https"),
            (":authority", "proxy.example:4443"),
            (":path", "/.well-known/masque/udp/192.0.2.6/443/"),
        ];
        let req = request_head(fields(&extended), true).unwrap();
        assert_eq!(
            req.extensions().get_ref::<ext::Protocol>(),
            Some(&ext::Protocol::from_static("connect-udp"))
        );
        assert_eq!(
            req.uri().to_string(),
            "https://proxy.example:4443/.well-known/masque/udp/192.0.2.6/443/"
        );
        // Not advertised: malformed (RFC 8441 §3), never an ordinary tunnel.
        assert_eq!(
            request_head(fields(&extended), false).unwrap_err().code(),
            Code::H3_MESSAGE_ERROR
        );
        for missing in [":scheme", ":path"] {
            let input: Vec<_> = extended
                .iter()
                .copied()
                .filter(|(name, _)| *name != missing)
                .collect();
            request_head(fields(&input), true).unwrap_err();
        }
        for (name, value) in [
            (":method", "GET"),
            (":protocol", "bad token"),
            (":protocol", ""),
        ] {
            let input: Vec<_> = extended
                .iter()
                .map(|field| {
                    if field.0 == name {
                        (name, value)
                    } else {
                        *field
                    }
                })
                .collect();
            request_head(fields(&input), true).unwrap_err();
        }
        let mut duplicate = extended.to_vec();
        duplicate.insert(2, (":protocol", "websocket"));
        request_head(fields(&duplicate), true).unwrap_err();
    }

    #[test]
    fn extended_connect_encoding_keeps_target_and_orders_protocol() {
        let mut request = Request::builder()
            .method(Method::CONNECT)
            .uri("https://example.com/chat?x=1")
            .body(())
            .unwrap();
        request.extensions().insert(ext::Protocol::WEBSOCKET);
        let output = decode(encode_request(&shared(), 0, &request).unwrap());
        assert_eq!(
            output,
            fields(&[
                (":method", "CONNECT"),
                (":authority", "example.com"),
                (":scheme", "https"),
                (":path", "/chat?x=1"),
                (":protocol", "websocket"),
            ])
        );
        let decoded = request_head(output, true).unwrap();
        assert_eq!(decoded.uri(), request.uri());
        // A forwarded request keeps the received pseudo-header order.
        let reordered = request_head(
            fields(&[
                (":protocol", "websocket"),
                (":method", "CONNECT"),
                (":scheme", "https"),
                (":path", "/chat"),
                (":authority", "example.com"),
            ]),
            true,
        )
        .unwrap();
        let output = decode(encode_request(&shared(), 0, &reordered).unwrap());
        let names: Vec<_> = output.iter().map(|field| field.name.clone()).collect();
        assert_eq!(
            names,
            [":protocol", ":method", ":scheme", ":path", ":authority"]
        );
        *request.method_mut() = Method::GET;
        encode_request(&shared(), 0, &request).unwrap_err();
    }

    #[test]
    fn websocket_uris_use_their_http_scheme() {
        for (uri, scheme) in [
            ("wss://example.com/chat", "https"),
            ("ws://example.com/chat", "http"),
        ] {
            let request = Request::builder()
                .method(Method::CONNECT)
                .uri(uri)
                .body(())
                .unwrap();
            request.extensions().insert(ext::Protocol::WEBSOCKET);
            let output = decode(encode_request(&shared(), 0, &request).unwrap());
            let value = output
                .iter()
                .find(|field| field.name == ":scheme")
                .map(|field| field.value.clone());
            assert_eq!(value.as_deref(), Some(scheme.as_bytes()), "{uri}");
        }
    }

    // Every Extended CONNECT scheme is accepted; ws/wss is carried as http/https (RFC 8441 §5).
    #[test]
    fn extended_connect_schemes_are_accepted_and_ws_is_carried_as_http() {
        for (protocol, scheme, carried) in [
            ("websocket", "https", "https"),
            ("websocket", "http", "http"),
            ("WebSocket", "https", "https"),
            ("websocket", "custom", "custom"),
            ("WebSocket", "ftp", "ftp"),
            ("websocket", "wss", "https"),
            ("x", "custom", "custom"),
            ("x", "ws", "http"),
            ("x", "wss", "https"),
        ] {
            let head = [
                (":method", "CONNECT"),
                (":protocol", protocol),
                (":scheme", scheme),
                (":authority", "example.com"),
                (":path", "/chat"),
            ];
            let received = request_head(fields(&head), true).unwrap();
            assert_eq!(
                received.uri().scheme_str(),
                Some(carried),
                "{protocol} {scheme}"
            );
            let sent = decode(encode_request(&shared(), 0, &received).unwrap());
            assert_eq!(
                request_head(sent, true).unwrap().uri(),
                received.uri(),
                "{protocol} {scheme}"
            );
        }
    }

    // RFC 9114 §4.3.1: Host stands in for a missing :authority, for Extended CONNECT too.
    #[test]
    fn host_stands_in_for_the_authority_of_every_request_kind() {
        for (method, protocol, uri) in [
            (Method::GET, None, "https:/chat"),
            (
                Method::CONNECT,
                Some(ext::Protocol::WEBSOCKET),
                "https:/chat",
            ),
            (Method::CONNECT, Some(ext::Protocol::WEBSOCKET), "wss:/chat"),
        ] {
            let mut request = Request::new(());
            *request.method_mut() = method;
            *request.uri_mut() = Uri::parse(uri).unwrap();
            if let Some(protocol) = protocol {
                request.extensions().insert(protocol);
            }
            encode_request(&shared(), 0, &request).unwrap_err();
            request
                .headers_mut()
                .insert(header::HOST, HeaderValue::from_static("example.com"));
            let output = decode(encode_request(&shared(), 0, &request).unwrap());
            assert!(
                !output.iter().any(|field| field.name == ":authority"),
                "{uri}"
            );
            let decoded = request_head(output, true).unwrap();
            assert_eq!(
                decoded.uri().to_string(),
                "https://example.com/chat",
                "{uri}"
            );
        }
    }

    /// One received target as each version carries it: HTTP/1 request text (`None` when it has no
    /// HTTP/1 form), then the HTTP/2 and HTTP/3 fields, and what every version must route on.
    struct Target {
        h1: Option<&'static str>,
        method: &'static str,
        protocol: Option<&'static str>,
        scheme: &'static str,
        authority: Option<&'static str>,
        path: &'static str,
        host: Option<&'static str>,
        routed: Option<&'static str>,
        carried_scheme: &'static str,
    }

    const TARGETS: [Target; 8] = [
        // HTTP-family userinfo is dropped.
        Target {
            h1: Some("GET https://user:pw@example.com/p HTTP/1.1\r\nHost: example.com\r\n\r\n"),
            method: "GET",
            protocol: None,
            scheme: "https",
            authority: Some("user:pw@example.com"),
            path: "/p",
            host: None,
            routed: Some("example.com"),
            carried_scheme: "https",
        },
        Target {
            h1: Some("GET wss://user@example.com/p HTTP/1.1\r\nHost: example.com\r\n\r\n"),
            method: "GET",
            protocol: None,
            scheme: "wss",
            authority: Some("user@example.com"),
            path: "/p",
            host: None,
            routed: Some("example.com"),
            carried_scheme: "wss",
        },
        Target {
            h1: Some("OPTIONS * HTTP/1.1\r\nHost: user@example.com\r\n\r\n"),
            method: "OPTIONS",
            protocol: None,
            scheme: "https",
            authority: Some("user@example.com"),
            path: "*",
            host: None,
            routed: Some("example.com"),
            carried_scheme: "https",
        },
        // Host loses userinfo, and always names the routed authority.
        Target {
            h1: Some("GET /p HTTP/1.1\r\nHost: user@example.com:8080\r\n\r\n"),
            method: "GET",
            protocol: None,
            scheme: "https",
            authority: None,
            path: "/p",
            host: Some("user@example.com:8080"),
            routed: Some("example.com:8080"),
            carried_scheme: "https",
        },
        Target {
            h1: Some("GET http://example.com/p HTTP/1.1\r\nHost: other.example\r\n\r\n"),
            method: "GET",
            protocol: None,
            scheme: "http",
            authority: Some("example.com"),
            path: "/p",
            host: Some("other.example"),
            routed: Some("example.com"),
            carried_scheme: "http",
        },
        // Extended CONNECT: ws/wss is carried as http/https; other schemes as received.
        Target {
            h1: None,
            method: "CONNECT",
            protocol: Some("x"),
            scheme: "ws",
            authority: Some("example.com"),
            path: "/chat",
            host: None,
            routed: Some("example.com"),
            carried_scheme: "http",
        },
        Target {
            h1: None,
            method: "CONNECT",
            protocol: Some("websocket"),
            scheme: "custom",
            authority: Some("example.com"),
            path: "/chat",
            host: None,
            routed: Some("example.com"),
            carried_scheme: "custom",
        },
        // Received without any authority; nothing to route on.
        Target {
            h1: Some("GET /p HTTP/1.1\r\n\r\n"),
            method: "GET",
            protocol: None,
            scheme: "https",
            authority: None,
            path: "/p",
            host: None,
            routed: None,
            carried_scheme: "https",
        },
    ];

    fn address(authority: AuthorityRef<'_>) -> String {
        let mut address = String::new();
        authority.write_address(&mut address).unwrap();
        address
    }

    /// Every authority a message names (URI or `:authority`, and `Host`) is `routed`, without userinfo.
    fn assert_routed(label: &str, authorities: &[Option<&[u8]>], routed: Option<&str>) {
        let named: Vec<_> = authorities.iter().flatten().collect();
        assert_eq!(named.is_empty(), routed.is_none(), "{label}: {named:?}");
        for value in named {
            let parsed = AuthorityRef::try_from(*value).unwrap();
            assert!(parsed.userinfo().is_none(), "{label}: {value:?}");
            assert_eq!(Some(address(parsed).as_str()), routed, "{label}");
        }
    }

    fn received(target: &Target) -> Vec<(&'static str, Request<()>)> {
        let mut received = Vec::new();
        if let Some(raw) = target.h1 {
            let (uri, headers) = h1::receive(raw);
            let mut request = Request::new(());
            *request.method_mut() = Method::from_bytes(target.method.as_bytes()).unwrap();
            *request.uri_mut() = uri;
            *request.headers_mut() = headers;
            *request.version_mut() = Version::HTTP_11;
            received.push(("h1", request));
        }
        let bytes_str = |value: &'static str| {
            hpack::BytesStr::try_from(Bytes::from_static(value.as_bytes())).unwrap()
        };
        let mut headers = HeaderMap::new();
        if let Some(host) = target.host {
            headers.insert(header::HOST, HeaderValue::from_static(host));
        }
        let pseudo = frame::Pseudo {
            method: Some(Method::from_bytes(target.method.as_bytes()).unwrap()),
            scheme: Some(bytes_str(target.scheme)),
            authority: target.authority.map(bytes_str),
            path: Some(bytes_str(target.path)),
            protocol: target.protocol.map(ext::Protocol::from_static),
            ..Default::default()
        };
        received.push((
            "h2",
            crate::h2::server::test_util::receive(pseudo, headers).unwrap(),
        ));
        let mut h3 = vec![
            (":method", target.method),
            (":scheme", target.scheme),
            (":path", target.path),
        ];
        h3.extend(target.protocol.map(|protocol| (":protocol", protocol)));
        h3.extend(target.authority.map(|authority| (":authority", authority)));
        h3.extend(target.host.map(|host| ("host", host)));
        received.push(("h3", request_head(fields(&h3), true).unwrap()));
        received
    }

    fn copy(request: &Request<()>) -> Request<()> {
        let mut copy = Request::new(());
        *copy.method_mut() = request.method().clone();
        *copy.uri_mut() = request.uri().clone();
        *copy.version_mut() = request.version();
        *copy.headers_mut() = request.headers().clone();
        if let Some(protocol) = request.extensions().get_ref::<ext::Protocol>() {
            copy.extensions().insert(protocol.clone());
        }
        copy
    }

    /// Each target received on every version routes on one authority, and every version it is
    /// sent on names only that authority.
    #[test]
    fn received_targets_route_and_forward_on_one_authority() {
        for target in &TARGETS {
            for (version, request) in received(target) {
                let label = format!(
                    "{:?} received on {version}",
                    target.h1.unwrap_or(target.scheme)
                );
                let uri_authority = request
                    .uri()
                    .authority()
                    .map(|authority| address(authority));
                assert_routed(
                    &label,
                    &[
                        uri_authority.as_deref().map(str::as_bytes),
                        request
                            .headers()
                            .get(header::HOST)
                            .map(HeaderValue::as_bytes),
                    ],
                    target.routed,
                );
                assert!(request.uri().userinfo().is_none(), "{label}");
                if version != "h1" && request.uri().authority().is_some() {
                    assert_eq!(
                        request.uri().scheme_str(),
                        Some(target.carried_scheme),
                        "{label}"
                    );
                }

                let protocol = request.extensions().get_ref::<ext::Protocol>().cloned();
                let sent_h2 = crate::h2::client::Peer::convert_send_message(
                    StreamId::from(1),
                    copy(&request),
                    protocol,
                    true,
                    None,
                    None,
                );
                if let Ok((frame, _)) = &sent_h2 {
                    assert_routed(
                        &format!("{label}, sent on h2"),
                        &[
                            frame.pseudo().authority.as_deref().map(str::as_bytes),
                            frame.fields().get(header::HOST).map(HeaderValue::as_bytes),
                        ],
                        target.routed,
                    );
                }
                let sent_h3 = encode_request(&shared(), 0, &request).map(decode);
                if let Ok(sent) = &sent_h3 {
                    let field = |name: &str| {
                        sent.iter()
                            .find(|field| field.name == name.as_bytes())
                            .map(|field| &field.value[..])
                    };
                    assert_routed(
                        &format!("{label}, sent on h3"),
                        &[field(":authority"), field("host")],
                        target.routed,
                    );
                }
                // Anything with an absolute URI can be sent on either version.
                if request.uri().authority().is_some() {
                    assert!(sent_h2.is_ok() && sent_h3.is_ok(), "{label}");
                }
            }
        }
    }

    #[test]
    fn protocol_is_never_a_response_field() {
        response(fields(&[(":status", "200"), (":protocol", "websocket")])).unwrap_err();
    }

    #[test]
    fn sensitive_host_fallback_preserves_synthesized_authority_sensitivity() {
        for path in ["/", "*"] {
            let mut input = fields(&[
                (":method", "OPTIONS"),
                (":scheme", "https"),
                (":path", path),
                ("host", "example.com"),
            ]);
            input[3].never_index = true;
            let request = request(input).unwrap();
            assert!(
                request
                    .extensions()
                    .get_ref::<PseudoHeaderSensitivity>()
                    .unwrap()
                    .is_sensitive(PseudoHeader::Authority)
            );
            let output = decode(encode_request(&shared(), 0, &request).unwrap());
            assert!(
                output
                    .iter()
                    .find(|field| field.name == ":authority")
                    .unwrap()
                    .never_index
            );
            assert!(
                output
                    .iter()
                    .find(|field| field.name == "host")
                    .unwrap()
                    .never_index
            );

            if path == "/" {
                let (frame, _) = crate::h2::client::Peer::convert_send_message(
                    StreamId::from(1),
                    request,
                    None,
                    true,
                    None,
                    None,
                )
                .unwrap();
                assert!(
                    frame
                        .pseudo()
                        .sensitivity
                        .is_sensitive(PseudoHeader::Authority)
                );
            }
        }
    }

    #[test]
    fn options_asterisk_host_synthesis_respects_header_capacity() {
        let mut headers = HeaderMap::new();
        for index in 0.. {
            let name = HeaderName::try_from(format!("x-field-{index}")).unwrap();
            if headers
                .try_insert(name, HeaderValue::from_static("value"))
                .is_err()
            {
                break;
            }
        }
        let mut input = fields(&[
            (":method", "OPTIONS"),
            (":scheme", "https"),
            (":authority", "example.com"),
            (":path", "*"),
        ]);
        input.extend(headers.iter().map(|(name, value)| FieldPair {
            name: Bytes::copy_from_slice(name.as_str().as_bytes()),
            value: Bytes::copy_from_slice(value.as_bytes()),
            never_index: false,
        }));
        // The received fields fit; only the additional synthesized Host exceeds
        // capacity. It must reject this request without panicking the driver.
        parse(input.clone(), false).unwrap();
        let error = request(input).unwrap_err();
        assert_eq!(error.code(), Code::H3_EXCESSIVE_LOAD);
        assert_eq!(error.scope(), ErrorScope::Stream);
    }

    #[test]
    fn options_asterisk_survives_forwarding() {
        let req = request(fields(&[
            (":method", "OPTIONS"),
            (":scheme", "https"),
            (":authority", "example.com"),
            (":path", "*"),
        ]))
        .unwrap();
        assert!(req.uri().is_asterisk());
        assert_eq!(req.uri().request_target(), "*");
        assert_eq!(req.headers()[header::HOST], "example.com");
        let shared = crate::h3::connection::Shared::new(
            crate::h3::connection::Config::default(),
            crate::h3::control::Role::Client,
            Default::default(),
        )
        .unwrap();
        let encoded = encode_request(&shared, 0, &req).unwrap();
        let mut decoder =
            crate::h3::qpack::Decoder::new(crate::h3::qpack::DecoderConfig::default());
        let decoded = request(decoder.decode_field_section(0, encoded).unwrap().unwrap()).unwrap();
        assert!(decoded.uri().is_asterisk());
        assert_eq!(decoded.headers()[header::HOST], "example.com");
    }

    /// A raw UTF-8 `:authority` routes ahead of `Host` for `*` as for `/`, whether `Host` is
    /// absent, matching or conflicting, and still does after H2 and H3 re-encoding.
    #[test]
    fn utf8_authorities_route_ahead_of_host_for_every_target() {
        let expected = received_authority("bücher.example").unwrap().address;
        for path in ["/", "*"] {
            for host in [None, Some("bücher.example"), Some("other.example")] {
                let case = format!("{path} {host:?}");
                let received = || {
                    let mut input = vec![
                        (":method", "OPTIONS"),
                        (":scheme", "https"),
                        (":authority", "bücher.example"),
                        (":path", path),
                    ];
                    input.extend(host.map(|host| ("host", host)));
                    request(fields(&input)).unwrap()
                };
                assert_eq!(
                    received().target_authority(),
                    Some(expected.clone()),
                    "{case}"
                );

                let h3 =
                    request(decode(encode_request(&shared(), 0, &received()).unwrap())).unwrap();
                assert_eq!(h3.target_authority(), Some(expected.clone()), "h3 {case}");
                assert_eq!(h3.headers(), received().headers(), "h3 {case}");

                let (frame, _) = crate::h2::client::Peer::convert_send_message(
                    StreamId::from(1),
                    received(),
                    None,
                    true,
                    None,
                    None,
                )
                .unwrap();
                let (pseudo, headers) = frame.into_parts();
                let h2 = crate::h2::server::test_util::receive(pseudo, headers).unwrap();
                assert_eq!(h2.target_authority(), Some(expected.clone()), "h2 {case}");
                assert_eq!(h2.headers(), received().headers(), "h2 {case}");
            }
        }
    }

    #[test]
    fn options_asterisk_preserves_authority_and_host_sensitivity() {
        for existing_host in [false, true] {
            let mut input = fields(&[
                (":method", "OPTIONS"),
                (":scheme", "https"),
                (":authority", "example.com"),
                (":path", "*"),
            ]);
            input[2].never_index = !existing_host;
            if existing_host {
                input.push(FieldPair {
                    name: Bytes::from_static(b"host"),
                    value: Bytes::from_static(b"EXAMPLE.COM"),
                    never_index: true,
                });
            }
            let request = request(input).unwrap();
            assert!(request.headers()[header::HOST].is_sensitive());
            if existing_host {
                assert_eq!(request.headers()[header::HOST], "EXAMPLE.COM");
            }
            let output = decode(encode_request(&shared(), 0, &request).unwrap());
            assert!(
                output
                    .iter()
                    .find(|field| field.name == "host")
                    .unwrap()
                    .never_index
            );
            assert!(
                output
                    .iter()
                    .find(|field| field.name == ":authority")
                    .unwrap()
                    .never_index
            );
        }
    }

    #[test]
    fn rejects_before_header_normalization() {
        for bad in [
            vec![(":status", "200"), ("Upper", "value")],
            vec![("x", "v"), (":status", "200")],
            vec![(":status", "200"), (":status", "200")],
            vec![(":status", "101")],
            vec![(":status", "204"), ("content-length", "0")],
            vec![(":status", "200"), ("connection", "close")],
            vec![(":status", "200"), ("x", " value")],
            vec![
                (":status", "200"),
                ("content-length", "1"),
                ("content-length", "2"),
            ],
        ] {
            assert_eq!(
                response(fields(&bad)).unwrap_err().code(),
                Code::H3_MESSAGE_ERROR
            );
        }
        trailers(fields(&[(":status", "200")])).unwrap_err();
    }

    #[test]
    fn response_values_share_bytes_and_preserve_sensitivity() {
        let value = Bytes::from_static(b"secret");
        let mut input = fields(&[(":status", "200")]);
        input.push(FieldPair {
            name: Bytes::from_static(b"x-secret"),
            value: value.clone(),
            never_index: true,
        });
        let resp = response(input).unwrap();
        assert_eq!(
            resp.headers()["x-secret"].as_bytes().as_ptr(),
            value.as_ptr()
        );
        assert!(resp.headers()["x-secret"].is_sensitive());
    }

    #[test]
    fn field_preferences_follow_duplicate_occurrences_pseudo_fields_and_responses() {
        let mut preferences = HeaderPreferences::default();
        let plain = FieldPreferences {
            representation: Representation::LiteralName,
            insertion: None,
            name_huffman: Some(false),
            value_huffman: Some(false),
            never_index: false,
        };
        preferences.pseudo_headers.insert(
            PseudoHeader::Method,
            FieldPreferences {
                never_index: true,
                ..plain
            },
        );
        preferences.headers.append("x-policy", plain);
        preferences.headers.append(
            "x-policy",
            FieldPreferences {
                value_huffman: Some(true),
                never_index: true,
                ..plain
            },
        );
        let request = Request::builder()
            .uri("https://example.test/")
            .header("x-policy", "a")
            .header("x-policy", "a")
            .body(())
            .unwrap();
        request.extensions().insert(preferences);
        let encoded = encode_request(&shared(), 0, &request).unwrap();
        let mut cursor = &encoded[..];
        HeaderPrefix::decode(&mut cursor, 128, 0).unwrap();
        let mut custom = Vec::new();
        let mut method = false;
        while !cursor.is_empty() {
            if let FieldLine::LiteralWithLiteralName {
                name,
                name_huffman,
                value_huffman,
                never_index,
                ..
            } = FieldLine::decode(&mut cursor, 4096).unwrap()
            {
                if name.as_ref() == b":method" {
                    assert!(!name_huffman && !value_huffman && never_index);
                    method = true;
                } else if name.as_ref() == b"x-policy" {
                    custom.push((name_huffman, value_huffman, never_index));
                }
            }
        }
        assert!(method);
        assert_eq!(custom, [(false, false, false), (false, true, true)]);
        let decoded = decode(encoded);
        assert!(
            decoded
                .iter()
                .find(|f| f.name.as_ref() == b":method")
                .unwrap()
                .never_index
        );

        let mut preferences = HeaderPreferences::default();
        preferences.pseudo_headers.insert(
            PseudoHeader::Status,
            FieldPreferences {
                never_index: true,
                ..plain
            },
        );
        let response = Response::new(());
        response.extensions().insert(preferences);
        let encoded = encode_response(&shared(), 0, &response).unwrap();
        assert!(decode(encoded)[0].never_index);
    }

    #[test]
    fn unhonourable_field_preferences_still_encode_the_request() {
        let inserted = FieldPreferences {
            insertion: Some(Default::default()),
            ..FieldPreferences::default()
        };
        let mut preferences = HeaderPreferences::default();
        preferences.pseudo_headers.insert(
            PseudoHeader::Path,
            FieldPreferences {
                representation: Representation::LiteralStaticName(2),
                ..FieldPreferences::default()
            },
        );
        for representation in [
            Representation::DynamicIndexAfterBase,
            Representation::LiteralDynamicNameBeforeBase,
        ] {
            preferences.headers.append(
                "x-policy",
                FieldPreferences {
                    representation,
                    ..inserted
                },
            );
        }
        // More preferences than occurrences leave the extras unused.
        preferences.headers.append("x-policy", inserted);
        for base in [None, Some(FieldSectionBase::FromFieldPreferences)] {
            let request = Request::builder()
                .uri("https://example.test/path")
                .header("x-policy", "a")
                .header("x-policy", "b")
                .body(())
                .unwrap();
            request.extensions().insert(preferences.clone());
            if let Some(base) = base {
                request.extensions().insert(base);
            }
            // No peer SETTINGS and no encoder stream: every preference falls back.
            let decoded = decode(encode_request(&shared(), 0, &request).unwrap());
            let values: Vec<_> = decoded
                .iter()
                .map(|field| (field.name.as_ref(), field.value.as_ref()))
                .collect();
            assert!(values.contains(&(b":path".as_slice(), b"/path".as_slice())));
            assert_eq!(
                values
                    .iter()
                    .filter(|(name, _)| *name == b"x-policy")
                    .map(|(_, value)| *value)
                    .collect::<Vec<_>>(),
                [b"a".as_slice(), b"b"]
            );
        }
    }
}
