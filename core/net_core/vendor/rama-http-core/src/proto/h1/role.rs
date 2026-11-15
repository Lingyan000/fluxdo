use std::mem::MaybeUninit;

use rama_core::{
    bytes::{Bytes, BytesMut},
    extensions::Extensions,
    telemetry::tracing::{debug, error, trace, trace_span, warn},
};
use rama_http::{
    HeaderName,
    proto::{
        HeaderByteLength, RequestHeaders,
        h1::ext::{
            CloseDelimitedResponse, OriginalResponseBodyFraming, ReasonPhrase, RequestTargetForm,
        },
    },
};
use rama_http_types::{
    Method, StatusCode, Version,
    header::{self, Entry, HeaderMap, HeaderValue, trailer::ForbiddenTrailers},
};
use rama_utils::collections::smallvec::{SmallVec, smallvec, smallvec_inline};

use super::EncodeHead;
use crate::{
    body::DecodedLength,
    common::date,
    error::{Header as HeaderError, Parse},
    headers,
    proto::{
        BodyLength, MessageHead, RequestLine,
        h1::{Encode, Encoder, Http1Transaction, ParseContext, ParseResult, ParsedMessage},
        target::{normalize_received, repair_outgoing_h1_host, several_hosts},
    },
};

pub(crate) const DEFAULT_MAX_HEADERS: usize = 100;
const AVERAGE_HEADER_SIZE: usize = 30; // totally scientific
const MAX_URI_LEN: usize = (u16::MAX - 1) as usize;

/// Construct a `HeaderValue` from the bytes of a header value that `httparse`
/// accepted (after obs-fold unfolding).
macro_rules! header_value {
    ($bytes:expr) => {{
        let bytes = $bytes;
        // SAFETY: `HeaderValue::from_maybe_shared_unchecked` has a semantic
        // precondition only: every byte is HTAB or in `0x20..=0xFF` except DEL.
        // `httparse` 1.10 accepts exactly those bytes in a header value (its
        // `HEADER_VALUE_MAP`). Obs-fold is only accepted in responses, where
        // `obs_fold_line` replaces its CR/LF with SP before this runs. Debug
        // builds re-check the bytes.
        unsafe { HeaderValue::from_maybe_shared_unchecked(bytes) }
    }};
}

pub(super) fn parse_headers<T>(
    bytes: &mut BytesMut,
    prev_len: Option<usize>,
    ctx: ParseContext<'_>,
) -> ParseResult<T::Incoming>
where
    T: Http1Transaction,
{
    // If the buffer is empty, don't bother entering the span, it's just noise.
    if bytes.is_empty() {
        return Ok(None);
    }

    let _entered = trace_span!("parse_headers");

    if let Some(prev_len) = prev_len
        && !is_complete_fast(bytes, prev_len)
    {
        return Ok(None);
    }

    T::parse(bytes, ctx)
}

/// A fast scan for the end of a message.
/// Used when there was a partial read, to skip full parsing on a
/// a slow connection.
fn is_complete_fast(bytes: &[u8], prev_len: usize) -> bool {
    let start = prev_len.saturating_sub(3);
    let bytes = &bytes[start..];

    for (i, b) in bytes.iter().copied().enumerate() {
        if b == b'\r' {
            if bytes[i + 1..].chunks(3).next() == Some(&b"\n\r\n"[..]) {
                return true;
            }
        } else if b == b'\n'
            && (bytes.get(i + 1) == Some(&b'\n')
                || bytes[i + 1..].chunks(2).next() == Some(&b"\r\n"[..]))
        {
            return true;
        }
    }

    false
}

pub(super) fn encode_headers<T>(
    enc: Encode<'_, T::Outgoing>,
    dst: &mut Vec<u8>,
) -> crate::Result<Encoder>
where
    T: Http1Transaction,
{
    let _entered = trace_span!("encode_headers");
    T::encode(enc, dst)
}

// There are 2 main roles, Client and Server.

pub(crate) enum Client {}

pub(crate) enum Server {}

impl Http1Transaction for Server {
    type Incoming = RequestLine;
    type Outgoing = StatusCode;
    const LOG: &'static str = "{role=server}";

    fn parse(buf: &mut BytesMut, ctx: ParseContext<'_>) -> ParseResult<RequestLine> {
        debug_assert!(!buf.is_empty(), "parse called with empty buf");

        let mut keep_alive;
        let is_http_11;
        let mut subject;
        let version;
        let len;
        let headers_len;
        let method;
        let path_range;

        // Both headers_indices and headers are using uninitialized memory,
        // but we *never* read any of it until after httparse has assigned
        // values into it. By not zeroing out the stack memory, this saves
        // a good ~5% on pipeline benchmarks.
        let mut headers_indices: SmallVec<[MaybeUninit<HeaderIndices>; DEFAULT_MAX_HEADERS]> =
            match ctx.h1_max_headers {
                Some(cap) => smallvec![MaybeUninit::uninit(); cap],
                None => smallvec_inline![MaybeUninit::uninit(); DEFAULT_MAX_HEADERS],
            };
        {
            let mut headers: SmallVec<[MaybeUninit<httparse::Header<'_>>; DEFAULT_MAX_HEADERS]> =
                match ctx.h1_max_headers {
                    Some(cap) => smallvec![MaybeUninit::uninit(); cap],
                    None => smallvec_inline![MaybeUninit::uninit(); DEFAULT_MAX_HEADERS],
                };
            trace!("Request.parse: bytes = {}", buf.len());
            let mut req = httparse::Request::new(&mut []);
            let bytes = buf.as_ref();
            match ctx.h1_parser_config.parse_request_with_uninit_headers(
                &mut req,
                bytes,
                &mut headers,
            ) {
                Ok(httparse::Status::Complete(parsed_len)) => {
                    trace!("Request.parse Complete({parsed_len})");
                    if ctx.h1_max_header_size.is_some_and(|max| parsed_len > max) {
                        return Err(Parse::TooLarge);
                    }
                    len = parsed_len;
                    let Some(uri) = req.path else {
                        return Err(Parse::Uri);
                    };
                    if uri.len() > MAX_URI_LEN {
                        return Err(Parse::UriTooLong);
                    }
                    method =
                        Method::from_bytes(req.method.map(|m| m.as_bytes()).unwrap_or_default())?;
                    path_range = Self::record_path_range(bytes, uri);
                    version = if req.version == Some(1) {
                        keep_alive = true;
                        is_http_11 = true;
                        Version::HTTP_11
                    } else {
                        keep_alive = false;
                        is_http_11 = false;
                        Version::HTTP_10
                    };

                    headers_len = record_header_indices(bytes, req.headers, &mut headers_indices)?;
                }
                Ok(httparse::Status::Partial) => return Ok(None),
                // if invalid Token, try to determine if for method or path
                Err(httparse::Error::Token) => {
                    return Err({
                        if req.method.is_none() {
                            Parse::Method
                        } else {
                            debug_assert!(req.path.is_none());
                            Parse::Uri
                        }
                    });
                }
                Err(err) => return Err(err.into()),
            }
        };

        let slice = buf.split_to(len).freeze();
        let (uri, request_target_form) = {
            let uri_bytes = slice.slice_ref(&slice[path_range]);
            // Zero-copy parse of the request-target. `CONNECT` carries an
            // authority-form target (`host:port`); every other method carries
            // origin-/absolute-/asterisk-form, all handled by `parse`.
            let uri = if method == Method::CONNECT {
                let uri = rama_net::uri::Uri::parse_authority_form(uri_bytes.clone())?;
                // RFC 9112 §3.2.3: CONNECT has no default port, so there is no target to guess.
                if uri.port_u16().is_none() {
                    return Err(Parse::Uri);
                }
                uri
            } else {
                let uri = rama_net::uri::Uri::parse(uri_bytes.clone())?;
                // A scheme without an authority (opaque `scheme:path`, e.g.
                // `htt:p//`) is not a valid HTTP request-target — only origin-,
                // absolute-, and asterisk-form are.
                if uri.scheme().is_some() && uri.authority().is_none() {
                    return Err(Parse::Uri);
                }
                uri
            };
            let form = if uri_bytes.as_ref() == b"*" {
                // RFC 9112 §3.2.4: asterisk-form is only for a server-wide OPTIONS.
                if method != Method::OPTIONS {
                    return Err(Parse::Uri);
                }
                RequestTargetForm::Asterisk
            } else if method == Method::CONNECT {
                RequestTargetForm::Authority
            } else if uri.scheme().is_some() {
                RequestTargetForm::Absolute
            } else {
                RequestTargetForm::Origin
            };
            (uri, form)
        };
        subject = RequestLine(method, uri);

        // According to https://tools.ietf.org/html/rfc7230#section-3.3.3
        // 1. (irrelevant to Request)
        // 2. (irrelevant to Request)
        // 3. Transfer-Encoding: chunked has a chunked body.
        // 4. If multiple differing Content-Length headers or invalid, close connection.
        // 5. Content-Length header has a sized body.
        // 6. Length 0.
        // 7. (irrelevant to Request)

        let mut decoder = DecodedLength::ZERO;
        let mut expect_continue = false;
        let mut saw_connection_close = false;
        let mut con_len = None;
        let mut is_cl = false;
        let mut is_te = false;
        let mut is_te_chunked = false;
        let mut saw_chunked = false;
        let mut wants_upgrade = subject.0 == Method::CONNECT;

        let mut headers = HeaderMap::with_capacity(headers_len);

        for header in &headers_indices[..headers_len] {
            // SAFETY: `assume_init_ref` requires an initialized element.
            // `headers_len` is the count `record_header_indices` returned, so
            // `headers_indices[..headers_len]` is initialized (its
            // safety-usable invariant), and nothing wrote to it since.
            let header = unsafe { header.assume_init_ref() };
            let name = HeaderName::from_bytes(&slice[header.name.0..header.name.1])
                .inspect_err(|err| {
                    debug!("invalid http1 header: {err:?}");
                })
                .map_err(|_e| crate::error::Parse::Internal)?;
            let mut value = header_value!(slice.slice(header.value.0..header.value.1));
            if name.is_sensitive() {
                value.set_sensitive(true);
            }

            if name == header::TRANSFER_ENCODING {
                // RFC 9112 §6.1 / §6.3:
                // If Transfer-Encoding header is present, and 'chunked' is
                // not the final encoding, and this is a Request, then it is
                // malformed. A server should respond with 400 Bad Request.
                if !is_http_11 {
                    debug!("HTTP/1.0 cannot have Transfer-Encoding header");
                    return Err(Parse::transfer_encoding_unexpected());
                }
                is_te = true;
                // RFC 9112 §6.1: `chunked` MUST NOT be applied more than once.
                if headers::has_duplicate_chunked(&value, &mut saw_chunked) {
                    debug!("rejecting Transfer-Encoding with duplicate `chunked`");
                    return Err(Parse::transfer_encoding_invalid());
                }
                if headers::is_chunked_(&value) {
                    is_te_chunked = true;
                    decoder = DecodedLength::CHUNKED;
                    // RFC 9112 §6.1: when TE and CL are both present, the
                    // recipient MUST process per Transfer-Encoding alone.
                    // For a forwarding proxy this means CL MUST NOT travel
                    // downstream — strip any CL that was already appended
                    // earlier in the header block to close the CL.TE
                    // request smuggling vector.
                    if con_len.take().is_some() {
                        let removed = headers.remove(&header::CONTENT_LENGTH).is_some() as usize;
                        debug!(
                            "stripped {removed} Content-Length header(s) after Transfer-Encoding: chunked (RFC 9112 §6.1)"
                        );
                    }
                } else {
                    is_te_chunked = false;
                }
            } else if name == header::CONTENT_LENGTH {
                is_cl = true;
                // Always validate the CL value syntactically, even if TE
                // was already seen — a malformed CL is a malformed message
                // regardless of TE presence (RFC 9112 §6.1).
                let len = headers::content_length_parse(&value)
                    .ok_or_else(Parse::content_length_invalid)?;
                if is_te {
                    // TE wins per RFC 9112 §6.1; do not retain CL.
                    continue;
                }
                if let Some(prev) = con_len {
                    if prev != len {
                        debug!(
                            "multiple Content-Length headers with different values: [{}, {}]",
                            prev, len,
                        );
                        return Err(Parse::content_length_invalid());
                    }
                    // we don't need to append this secondary length
                    continue;
                }
                decoder = DecodedLength::try_checked_new(len)?;
                con_len = Some(len);
            } else if name == header::CONNECTION {
                read_connection_line(&mut keep_alive, &mut saw_connection_close, &value);
            } else if name == header::EXPECT {
                // According to https://datatracker.ietf.org/doc/html/rfc2616#section-14.20
                // Comparison of expectation values is case-insensitive for unquoted tokens
                // (including the 100-continue token)
                expect_continue = value.as_bytes().eq_ignore_ascii_case(b"100-continue");
            } else if name == header::UPGRADE {
                // Upgrades are only allowed with HTTP/1.1
                wants_upgrade = is_http_11;
            }

            headers.append(name, value);
        }

        if is_te && !is_te_chunked {
            debug!("request with transfer-encoding header, but not chunked, bad request");
            return Err(Parse::transfer_encoding_invalid());
        }

        // RFC 9112 §3.2: a server MUST answer several Host lines with 400.
        if several_hosts(&headers) {
            debug!("request with several Host lines, bad request");
            return Err(Parse::Header(HeaderError::Token));
        }
        normalize_received(&mut subject.1, &mut headers, false);

        // RFC 9112 §6.1: TE + CL together is a request smuggling vector,
        // so do not reuse the connection for further requests.
        if is_te && is_cl {
            keep_alive = false;
        }

        let extensions = ctx.prepared_extensions.take().unwrap_or_else(|| {
            warn!(
                "prepared_extensions should always be set in ParseContext: was None: use default instead..."
            );
            Default::default()
        });

        *ctx.req_method = Some(subject.0.clone());

        extensions.insert(HeaderByteLength(len));
        extensions.insert(request_target_form);

        Ok(Some(ParsedMessage {
            head: MessageHead {
                version,
                subject,
                headers,
                extensions,
            },
            decode: decoder,
            expect_continue,
            keep_alive,
            wants_upgrade,
        }))
    }

    fn encode(mut msg: Encode<'_, Self::Outgoing>, dst: &mut Vec<u8>) -> crate::Result<Encoder> {
        trace!(
            "encode status={:?}, body={:?}, req_method={:?}",
            msg.head.subject, msg.body, msg.req_method
        );

        let close_delimited = Self::use_close_delimited_response(
            msg.head.extensions,
            &msg.head.headers,
            msg.req_method.as_ref(),
            msg.head.subject,
        );
        // RFC 9931 §8: bytes after a refused CONNECT may be tunnel data a client sent early;
        // reading them as requests would let it smuggle one. Close instead.
        let refused_connect =
            msg.req_method == &Some(Method::CONNECT) && !msg.head.subject.is_success();
        if close_delimited || refused_connect {
            headers::connection_set_close(&mut msg.head.headers);
            msg.keep_alive = false;
        }

        // hyper currently doesn't support returning 1xx status codes as a Response
        // This is because Service only allows returning a single Response, and
        // so if you try to reply with a e.g. 100 Continue, you have no way of
        // replying with the latter status code response.
        let (ret, is_last) = if msg.head.subject == StatusCode::SWITCHING_PROTOCOLS {
            (Ok(()), true)
        } else if headers::is_tunnel_response(msg.req_method.as_ref(), msg.head.subject) {
            if matches!(msg.body, Some(BodyLength::Known(len)) if len != 0) {
                warn!("body of a successful response to CONNECT dropped: a tunnel follows");
            }
            (Ok(()), true)
        } else if msg.head.subject.is_informational() {
            warn!("response with 1xx status code not supported");
            msg.head.subject = StatusCode::INTERNAL_SERVER_ERROR;
            msg.body = None;
            (Err(crate::Error::new_user_unsupported_status_code()), true)
        } else {
            (Ok(()), !msg.keep_alive)
        };

        // In some error cases, we don't know about the invalid message until already
        // pushing some bytes onto the `dst`. In those cases, we don't want to send
        // the half-pushed message, so rewind to before.
        let orig_len = dst.len();

        let init_cap = 30 + msg.head.headers.len() * AVERAGE_HEADER_SIZE;
        dst.reserve(init_cap);

        let custom_reason_phrase = msg.head.extensions.get_ref::<ReasonPhrase>();

        if msg.head.version == Version::HTTP_11
            && msg.head.subject == StatusCode::OK
            && custom_reason_phrase.is_none()
        {
            extend(dst, b"HTTP/1.1 200 OK\r\n");
        } else {
            match msg.head.version {
                Version::HTTP_10 => extend(dst, b"HTTP/1.0 "),
                Version::HTTP_11 => extend(dst, b"HTTP/1.1 "),
                Version::HTTP_2 => {
                    debug!("response with HTTP2 version coerced to HTTP/1.1");
                    extend(dst, b"HTTP/1.1 ");
                }
                other => panic!("unexpected response version: {other:?}"),
            }

            extend(dst, msg.head.subject.as_str().as_bytes());
            extend(dst, b" ");

            if let Some(reason) = custom_reason_phrase {
                extend(dst, reason.as_bytes());
            } else {
                // a reason MUST be written, as many parsers will expect it.
                extend(
                    dst,
                    msg.head
                        .subject
                        .canonical_reason()
                        .unwrap_or("<none>")
                        .as_bytes(),
                );
            }

            extend(dst, b"\r\n");
        }

        let allowed_trailers = msg.head.extensions.get_arc::<ForbiddenTrailers>();
        let _extensions = std::mem::take(msg.head.extensions);
        let encoder = Self::encode_h1_headers(msg, close_delimited, dst, is_last, orig_len)?
            .maybe_with_allowed_trailers(allowed_trailers);
        ret.map(|()| encoder)
    }

    fn on_error(err: &crate::Error) -> Option<MessageHead<Self::Outgoing>> {
        use crate::error::Kind;
        let status = match *err.kind() {
            Kind::Parse(Parse::Method | Parse::Header(_) | Parse::Uri | Parse::Version) => {
                StatusCode::BAD_REQUEST
            }
            Kind::Parse(Parse::TooLarge) => StatusCode::REQUEST_HEADER_FIELDS_TOO_LARGE,
            Kind::Parse(Parse::UriTooLong) => StatusCode::URI_TOO_LONG,
            _ => return None,
        };

        debug!("sending automatic response ({}) for parse error", status);
        let msg = MessageHead {
            subject: status,
            ..Default::default()
        };
        Some(msg)
    }

    fn is_server() -> bool {
        true
    }

    fn accepts_upgrade(status: &StatusCode, method: Option<&Method>) -> bool {
        *status == StatusCode::SWITCHING_PROTOCOLS
            || (method == Some(&Method::CONNECT) && status.is_success())
    }

    fn update_date() {
        date::update();
    }
}

impl Server {
    // Explicit headers override a framing preference carried in extensions.
    // Keep normal header validation and bodyless-response handling authoritative.
    fn use_close_delimited_response(
        extensions: &Extensions,
        headers: &HeaderMap,
        method: Option<&Method>,
        status: StatusCode,
    ) -> bool {
        extensions.contains::<CloseDelimitedResponse>()
            && Self::can_have_body(method, status)
            && ![
                header::CONTENT_LENGTH,
                header::TRANSFER_ENCODING,
                header::TRAILER,
            ]
            .iter()
            .any(|name| headers.contains_key(name))
    }

    fn can_have_body(method: Option<&Method>, status: StatusCode) -> bool {
        Self::can_chunked(method, status)
    }

    fn can_chunked(method: Option<&Method>, status: StatusCode) -> bool {
        if method == Some(&Method::HEAD)
            || method == Some(&Method::CONNECT) && status.is_success()
            || status.is_informational()
        {
            false
        } else {
            !matches!(status, StatusCode::NO_CONTENT | StatusCode::NOT_MODIFIED)
        }
    }

    fn encode_h1_headers(
        msg: Encode<'_, StatusCode>,
        close_delimited: bool,
        dst: &mut Vec<u8>,
        is_last: bool,
        orig_len: usize,
    ) -> crate::Result<Encoder> {
        struct OrigCaseWriter {
            title_case_headers: bool,
        }

        impl HeaderNameWriter for OrigCaseWriter {
            #[inline]
            fn write_full_header_line(
                &mut self,
                dst: &mut Vec<u8>,
                (name, rest): (HeaderName, &str),
            ) {
                self.write_header_name(dst, &name);
                extend(dst, rest.as_bytes());
            }

            #[inline]
            fn write_header_name_with_colon(&mut self, dst: &mut Vec<u8>, name: &HeaderName) {
                self.write_header_name(dst, name);
                extend(dst, b": ");
            }

            #[inline]
            fn write_header_name(&mut self, dst: &mut Vec<u8>, name: &HeaderName) {
                let Self { title_case_headers } = *self;

                if title_case_headers {
                    let start = dst.len();
                    name.write_original(dst);
                    title_case_in_place(&mut dst[start..]);
                } else {
                    name.write_original(dst);
                }
            }
        }

        let header_name_writer = OrigCaseWriter {
            title_case_headers: msg.title_case_headers,
        };

        Self::encode_headers(
            msg,
            close_delimited,
            dst,
            is_last,
            orig_len,
            header_name_writer,
        )
    }

    #[inline]
    fn encode_headers<W>(
        mut msg: Encode<'_, StatusCode>,
        close_delimited: bool,
        dst: &mut Vec<u8>,
        mut is_last: bool,
        orig_len: usize,
        mut header_name_writer: W,
    ) -> crate::Result<Encoder>
    where
        W: HeaderNameWriter,
    {
        // In some error cases, we don't know about the invalid message until already
        // pushing some bytes onto the `dst`. In those cases, we don't want to send
        // the half-pushed message, so rewind to before.
        let rewind = |dst: &mut Vec<u8>| {
            dst.truncate(orig_len);
        };

        let response_length =
            headers::ResponseLength::of(msg.req_method.as_ref(), msg.head.subject);
        let tunnel = headers::is_tunnel_response(msg.req_method.as_ref(), msg.head.subject);
        // A HEAD or 304 may name the coding a GET would use (RFC 9112 §6.1).
        let describes_get = msg.head.version != Version::HTTP_10
            && (msg.req_method == &Some(Method::HEAD)
                || msg.head.subject == StatusCode::NOT_MODIFIED);

        let descriptive_transfer_encoding = describes_get
            && response_length != headers::ResponseLength::Forbidden
            && msg.head.headers.contains_key(header::TRANSFER_ENCODING);
        // A described coding wins over a length, as a recipient would let it (RFC 9112 §6.3).
        if descriptive_transfer_encoding
            && msg.head.headers.remove(header::CONTENT_LENGTH).is_some()
        {
            debug!("content-length dropped: the response describes a transfer coding");
        }

        // Codings over several field lines combine into one, as RFC 9110 §5.3 allows.
        if msg
            .head
            .headers
            .get_all(header::TRANSFER_ENCODING)
            .iter()
            .nth(1)
            .is_some()
            && let Some(joined) = HeaderValue::join(
                msg.head.headers.get_all(header::TRANSFER_ENCODING),
                &HeaderValue::from_static(", "),
            )
        {
            msg.head.headers.insert(header::TRANSFER_ENCODING, joined);
        }

        // Normalize repeated or comma-separated lengths before writing any headers.
        // Every value must parse and agree; never select just the first value.
        let normalize_content_length = response_length != headers::ResponseLength::Forbidden && {
            let mut values = msg.head.headers.get_all(header::CONTENT_LENGTH).into_iter();
            values
                .next()
                .is_some_and(|first| first.as_bytes().contains(&b',') || values.next().is_some())
        };
        if normalize_content_length {
            let Some(len) = headers::content_length_parse_all(&msg.head.headers) else {
                warn!("invalid or conflicting Content-Length values");
                rewind(dst);
                return Err(crate::Error::new_user_header());
            };
            msg.head
                .headers
                .insert(header::CONTENT_LENGTH, HeaderValue::from(len));
        }
        let mut wrote_len = false;
        let mut encoder = Encoder::length(0);
        let mut wrote_date = false;
        let mut is_name_written = false;
        let mut must_write_chunked = false;
        let connection_header_names = headers::connection_header_names(&msg.head.headers);

        macro_rules! handle_is_name_written {
            () => {{
                if is_name_written {
                    // we need to clean up and write the newline
                    debug_assert_ne!(
                        &dst[dst.len() - 2..],
                        b"\r\n",
                        "previous header wrote newline but set is_name_written"
                    );

                    if must_write_chunked {
                        extend(dst, b", chunked\r\n");
                    } else {
                        extend(dst, b"\r\n");
                    }
                }
            }};
        }

        'headers: for (name, value) in msg.head.headers.into_ordered_iter() {
            handle_is_name_written!();
            is_name_written = false;

            match name.standard() {
                Some(header::StandardHeader::ContentLength) => {
                    if response_length == headers::ResponseLength::Forbidden {
                        if tunnel && msg.strict_connect_framing {
                            warn!("content-length on a successful response to CONNECT, canceling");
                            rewind(dst);
                            return Err(crate::Error::new_user_header());
                        }
                        debug!("content-length dropped: forbidden for this response");
                        continue 'headers;
                    }
                    if wrote_len && !is_name_written {
                        warn!("unexpected content-length found, canceling");
                        rewind(dst);
                        return Err(crate::Error::new_user_header());
                    }
                    match msg.body {
                        Some(BodyLength::Known(known_len)) => {
                            // A HEAD or 304 describes another representation; otherwise the
                            // field must frame the body that is sent.
                            let frames_body = match response_length {
                                headers::ResponseLength::Known => true,
                                headers::ResponseLength::NonZero => known_len != 0,
                                headers::ResponseLength::ExplicitOnly
                                | headers::ResponseLength::Forbidden => false,
                            };
                            if !is_name_written {
                                encoder = Encoder::length(known_len);
                                header_name_writer.write_header_name_with_colon(dst, &name);
                                if frames_body
                                    && headers::content_length_parse(&value) != Some(known_len)
                                {
                                    // A length the body does not have would desync the framing.
                                    warn!(
                                        ?value,
                                        known_len,
                                        "content-length disagrees with the body, sending the body's length"
                                    );
                                    extend(dst, ::itoa::Buffer::new().format(known_len).as_bytes());
                                } else {
                                    extend(dst, value.as_bytes());
                                }
                                wrote_len = true;
                                is_name_written = true;
                            }
                            continue 'headers;
                        }
                        Some(BodyLength::Unknown) => {
                            // The Body impl didn't know how long the
                            // body is, but a length header was included.
                            // We have to parse the value to return our
                            // Encoder...

                            if let Some(len) = headers::content_length_parse(&value) {
                                encoder = Encoder::length(len);
                                header_name_writer.write_header_name_with_colon(dst, &name);
                                extend(dst, value.as_bytes());
                                wrote_len = true;
                                is_name_written = true;
                                continue 'headers;
                            } else {
                                warn!("illegal Content-Length value: {:?}", value);
                                rewind(dst);
                                return Err(crate::Error::new_user_header());
                            }
                        }
                        None => {
                            // We have no body to actually send,
                            // but the headers claim a content-length.
                            // There's only 2 ways this makes sense:
                            //
                            // - The header says the length is `0`.
                            // - This is a response to a `HEAD` request.
                            if matches!(
                                response_length,
                                headers::ResponseLength::NonZero
                                    | headers::ResponseLength::ExplicitOnly
                            ) {
                                debug_assert_eq!(encoder, Encoder::length(0));
                            } else if headers::content_length_parse(&value) != Some(0) {
                                warn!(
                                    "content-length value found, but empty body provided: {:?}",
                                    value
                                );
                                continue 'headers;
                            }
                        }
                    }
                    wrote_len = true;
                }
                Some(header::StandardHeader::TransferEncoding) => {
                    if response_length == headers::ResponseLength::Forbidden {
                        if tunnel && msg.strict_connect_framing {
                            warn!(
                                "transfer-encoding on a successful response to CONNECT, canceling"
                            );
                            rewind(dst);
                            return Err(crate::Error::new_user_header());
                        }
                        debug!("transfer-encoding dropped: forbidden for this response");
                        continue 'headers;
                    }
                    if wrote_len && !is_name_written {
                        warn!("unexpected transfer-encoding found, canceling");
                        rewind(dst);
                        return Err(crate::Error::new_user_header());
                    }
                    // check that we actually can send a chunked body...
                    if msg.head.version == Version::HTTP_10
                        || !Self::can_chunked(msg.req_method.as_ref(), msg.head.subject)
                    {
                        if describes_get {
                            // Kept as the GET would carry it, which ends in `chunked`; it frames
                            // nothing here.
                            header_name_writer.write_header_name_with_colon(dst, &name);
                            extend(dst, value.as_bytes());
                            if !headers::is_chunked_(&value) {
                                extend(dst, b", chunked");
                            }
                            extend(dst, b"\r\n");
                        }
                        continue;
                    }
                    wrote_len = true;
                    // Must check each value, because `chunked` needs to be the
                    // last encoding, or else we add it.
                    must_write_chunked = !headers::is_chunked_(&value);

                    if !is_name_written {
                        encoder = Encoder::chunked();
                        is_name_written = true;
                        header_name_writer.write_header_name_with_colon(dst, &name);
                        extend(dst, value.as_bytes());
                    } else {
                        extend(dst, b", ");
                        extend(dst, value.as_bytes());
                    }
                    continue 'headers;
                }
                Some(header::StandardHeader::Connection) => {
                    if !is_last && headers::connection_close(&value) {
                        is_last = true;
                    }
                    if !is_name_written {
                        is_name_written = true;
                        header_name_writer.write_header_name_with_colon(dst, &name);
                        extend(dst, value.as_bytes());
                    } else {
                        extend(dst, b", ");
                        extend(dst, value.as_bytes());
                    }
                    continue 'headers;
                }
                Some(header::StandardHeader::Date) => {
                    wrote_date = true;
                }
                Some(header::StandardHeader::Trailer) => {
                    // check that we actually can send a chunked body...
                    if msg.head.version == Version::HTTP_10
                        || !Self::can_chunked(msg.req_method.as_ref(), msg.head.subject)
                    {
                        continue;
                    }

                    if !is_name_written {
                        is_name_written = true;
                        header_name_writer.write_header_name_with_colon(dst, &name);
                        extend(dst, value.as_bytes());
                    } else {
                        extend(dst, b", ");
                        extend(dst, value.as_bytes());
                    }

                    continue 'headers;
                }
                _ => (),
            }
            //TODO: this should perhaps instead combine them into
            //single lines, as RFC7230 suggests is preferable.

            // non-special write Name and Value
            debug_assert!(
                !is_name_written,
                "{name:?} set is_name_written and didn't continue loop",
            );
            header_name_writer.write_header_name_with_colon(dst, &name);
            extend(dst, value.as_bytes());
            extend(dst, b"\r\n");
        }

        handle_is_name_written!();

        if !wrote_len && !descriptive_transfer_encoding && close_delimited {
            encoder = Encoder::close_delimited();
        } else if !wrote_len && !descriptive_transfer_encoding {
            encoder = match msg.body {
                Some(BodyLength::Unknown) => {
                    if msg.head.version == Version::HTTP_10
                        || !Self::can_chunked(msg.req_method.as_ref(), msg.head.subject)
                    {
                        Encoder::close_delimited()
                    } else {
                        header_name_writer.write_full_header_line(
                            dst,
                            (header::TRANSFER_ENCODING, ": chunked\r\n"),
                        );
                        Encoder::chunked()
                    }
                }
                None | Some(BodyLength::Known(0)) => {
                    if response_length.implied(Some(0)).is_some() {
                        header_name_writer
                            .write_full_header_line(dst, (header::CONTENT_LENGTH, ": 0\r\n"))
                    }
                    Encoder::length(0)
                }
                Some(BodyLength::Known(len)) => match response_length.implied(Some(len)) {
                    Some(len) => {
                        header_name_writer
                            .write_header_name_with_colon(dst, &header::CONTENT_LENGTH);
                        extend(dst, ::itoa::Buffer::new().format(len).as_bytes());
                        extend(dst, b"\r\n");
                        Encoder::length(len)
                    }
                    None => Encoder::length(0),
                },
            };
        }

        if !Self::can_have_body(msg.req_method.as_ref(), msg.head.subject) {
            trace!(
                "server body forced to 0; method={:?}, status={:?}",
                msg.req_method, msg.head.subject
            );
            encoder = Encoder::length(0);
        }

        // cached date is much faster than formatting every request
        // don't force the write if disabled
        if !wrote_date && msg.date_header {
            dst.reserve(date::DATE_VALUE_LENGTH + 8);
            header_name_writer.write_header_name_with_colon(dst, &header::DATE);
            date::extend(dst);
            extend(dst, b"\r\n\r\n");
        } else {
            extend(dst, b"\r\n");
        }

        Ok(encoder
            .with_nominated_fields(connection_header_names)
            .set_last(is_last))
    }

    /// Helper for zero-copy parsing of request path URI.
    #[inline]
    fn record_path_range(bytes: &[u8], req_path: &str) -> std::ops::Range<usize> {
        let bytes_ptr = bytes.as_ptr() as usize;
        let start = req_path.as_ptr() as usize - bytes_ptr;
        let end = start + req_path.len();
        std::ops::Range { start, end }
    }
}

trait HeaderNameWriter {
    fn write_full_header_line(&mut self, dst: &mut Vec<u8>, name_value_pair: (HeaderName, &str));
    fn write_header_name_with_colon(&mut self, dst: &mut Vec<u8>, name: &HeaderName);
    fn write_header_name(&mut self, dst: &mut Vec<u8>, name: &HeaderName);
}

impl Http1Transaction for Client {
    type Incoming = StatusCode;
    type Outgoing = RequestLine;
    const LOG: &'static str = "{role=client}";

    fn parse(buf: &mut BytesMut, ctx: ParseContext<'_>) -> ParseResult<StatusCode> {
        debug_assert!(!buf.is_empty(), "parse called with empty buf");

        // Loop to skip information status code headers (100 Continue, etc).
        loop {
            let mut headers_indices: SmallVec<[MaybeUninit<HeaderIndices>; DEFAULT_MAX_HEADERS]> =
                match ctx.h1_max_headers {
                    Some(cap) => smallvec![MaybeUninit::uninit(); cap],
                    None => smallvec_inline![MaybeUninit::uninit(); DEFAULT_MAX_HEADERS],
                };
            let (len, status, reason, version, headers_len) = {
                let mut headers: SmallVec<
                    [MaybeUninit<httparse::Header<'_>>; DEFAULT_MAX_HEADERS],
                > = match ctx.h1_max_headers {
                    Some(cap) => smallvec![MaybeUninit::uninit(); cap],
                    None => smallvec_inline![MaybeUninit::uninit(); DEFAULT_MAX_HEADERS],
                };
                trace!("Response.parse: bytes len = {}", buf.len());
                let mut res = httparse::Response::new(&mut []);
                let bytes = buf.as_ref();
                match ctx.h1_parser_config.parse_response_with_uninit_headers(
                    &mut res,
                    bytes,
                    &mut headers,
                ) {
                    Ok(httparse::Status::Complete(len)) => {
                        trace!("Response.parse Complete({})", len);
                        if ctx.h1_max_header_size.is_some_and(|max| len > max) {
                            return Err(Parse::TooLarge);
                        }
                        let status = StatusCode::from_u16(res.code.unwrap_or(u16::MAX))?;

                        let reason = {
                            // Only save the reason phrase if it isn't the canonical reason
                            if let Some(reason) = res.reason
                                && Some(reason) != status.canonical_reason()
                            {
                                Some(Bytes::copy_from_slice(reason.as_bytes()))
                            } else {
                                None
                            }
                        };

                        let version = if res.version == Some(1) {
                            Version::HTTP_11
                        } else {
                            Version::HTTP_10
                        };
                        let headers_len =
                            record_header_indices(bytes, res.headers, &mut headers_indices)?;
                        (len, status, reason, version, headers_len)
                    }
                    Ok(httparse::Status::Partial) => return Ok(None),
                    Err(httparse::Error::Version) if ctx.h09_responses => {
                        trace!("Response.parse accepted HTTP/0.9 response");

                        (0, StatusCode::OK, None, Version::HTTP_09, 0)
                    }
                    Err(e) => return Err(e.into()),
                }
            };

            let mut slice = buf.split_to(len);

            if ctx
                .h1_parser_config
                .obsolete_multiline_headers_in_responses_are_allowed()
            {
                for header in &mut headers_indices[..headers_len] {
                    // SAFETY: `assume_init_mut` requires an initialized
                    // element. `headers_len` is 0 (HTTP/0.9) or the count
                    // `record_header_indices` returned, so
                    // `headers_indices[..headers_len]` is initialized (its
                    // safety-usable invariant).
                    let header = unsafe { header.assume_init_mut() };
                    Self::obs_fold_line(&mut slice, header);
                }
            }

            let slice = slice.freeze();

            let mut keep_alive = version == Version::HTTP_11;
            let mut saw_connection_close = false;

            let mut headers = HeaderMap::with_capacity(headers_len);
            let mut resp_is_te_chunked = false;
            let mut resp_has_cl = false;
            let mut saw_chunked = false;

            for header in &headers_indices[..headers_len] {
                // SAFETY: `assume_init_ref` requires an initialized element.
                // As above, `headers_indices[..headers_len]` is initialized,
                // and `obs_fold_line` only rewrote entries in place.
                let header = unsafe { header.assume_init_ref() };
                let name = HeaderName::from_bytes(&slice[header.name.0..header.name.1])
                    .inspect_err(|err| {
                        debug!("invalid http1 header: {err:?}");
                    })
                    .map_err(|_e| crate::error::Parse::Internal)?;
                let mut value = header_value!(slice.slice(header.value.0..header.value.1));
                if name.is_sensitive() {
                    value.set_sensitive(true);
                }

                if name == header::CONNECTION {
                    read_connection_line(&mut keep_alive, &mut saw_connection_close, &value);
                } else if name == header::TRANSFER_ENCODING {
                    // RFC 9112 §6.1: `chunked` MUST NOT be applied more than once.
                    if headers::has_duplicate_chunked(&value, &mut saw_chunked) {
                        debug!("response: rejecting Transfer-Encoding with duplicate `chunked`");
                        return Err(Parse::transfer_encoding_invalid());
                    }
                    if headers::is_chunked_(&value) {
                        resp_is_te_chunked = true;
                    }
                } else if name == header::CONTENT_LENGTH {
                    resp_has_cl = true;
                }

                headers.append(name, value);
            }

            // RFC 9112 §6.1: if a response carries both Content-Length and
            // `Transfer-Encoding: chunked`, the recipient MUST process per
            // Transfer-Encoding and the CL MUST NOT be forwarded. Strip it
            // here so a downstream proxy hop cannot be desynced.
            if resp_is_te_chunked && resp_has_cl {
                let removed = headers.remove(&header::CONTENT_LENGTH).is_some() as usize;
                debug!(
                    "response: stripped {removed} Content-Length header(s) alongside Transfer-Encoding: chunked (RFC 9112 §6.1)"
                );
            }

            // Extensions are ready for use and don't need to do any special wrapping here
            let extensions = ctx.prepared_extensions.take().unwrap_or_else(|| {
                warn!(
                    "prepared_extensions should always be set in ParseContext but it was missing; falling back to default; report bug in rama"
                );
                Default::default()
            });

            if let Some(reason) = reason {
                // SAFETY: `ReasonPhrase::from_bytes_unchecked` has a semantic
                // precondition only: HTAB, SP, VCHAR or obs-text bytes.
                // `httparse::Response::reason` holds only HTAB, SP and VCHAR
                // (it is empty when the phrase had obs-text or invalid bytes).
                let reason = unsafe { ReasonPhrase::from_bytes_unchecked(reason) };
                extensions.insert(reason);
            }

            extensions.insert(HeaderByteLength(len));

            let head = MessageHead {
                version,
                subject: status,
                headers,
                extensions,
            };
            if let Some((decode, is_upgrade)) = Self::decoder(&head, ctx.req_method)? {
                let framing = if !Server::can_have_body(ctx.req_method.as_ref(), status) {
                    OriginalResponseBodyFraming::Empty
                } else if head.headers.contains_key(header::TRANSFER_ENCODING) {
                    OriginalResponseBodyFraming::TransferEncoded
                } else if decode == DecodedLength::CLOSE_DELIMITED {
                    OriginalResponseBodyFraming::CloseDelimited
                } else {
                    OriginalResponseBodyFraming::ContentLength
                };
                head.extensions.insert(framing);
                return Ok(Some(ParsedMessage {
                    head,
                    decode,
                    expect_continue: false,
                    // a client upgrade means the connection can't be used
                    // again, as it is definitely upgrading; nor can it after
                    // a body delimited by the connection closing (no length
                    // and no chunked final transfer coding).
                    keep_alive: keep_alive
                        && !is_upgrade
                        && decode != DecodedLength::CLOSE_DELIMITED,
                    wants_upgrade: is_upgrade,
                }));
            }

            if head.subject.is_informational()
                && let Some(callback) = ctx.on_informational
            {
                callback.call(head.into_response(()));
            }

            // Parsing a 1xx response could have consumed the buffer, check if
            // it is empty now...
            if buf.is_empty() {
                return Ok(None);
            }
        }
    }

    fn encode(mut msg: Encode<'_, Self::Outgoing>, dst: &mut Vec<u8>) -> crate::Result<Encoder> {
        trace!(
            "encode method={:?}, body={:?}",
            msg.head.subject.0, msg.body
        );

        *msg.req_method = Some(msg.head.subject.0.clone());

        if msg.head.subject.0 == Method::CONNECT
            && !rama_http_types::proto::h1::head::is_http1_connect_target(
                &msg.head.subject.1,
                msg.head.extensions,
            )
        {
            return Err(crate::Error::new_user_target());
        }
        if !repair_outgoing_h1_host(&msg.head.subject.1, &mut msg.head.headers) {
            return Err(crate::Error::new_user_header());
        }

        let body = Self::set_length(&mut msg.head, msg.body);

        let init_cap = 30 + msg.head.headers.len() * AVERAGE_HEADER_SIZE;
        dst.reserve(init_cap);

        extend(dst, msg.head.subject.0.as_str().as_bytes());
        extend(dst, b" ");
        // build the request-target form here (inside the encoder) from the request
        // itself, the h1 analog of `Pseudo::request`. See `encode_request_target`.
        encode_request_target(
            &msg.head.subject.0,
            &msg.head.subject.1,
            msg.head.extensions,
            dst,
        );
        extend(dst, b" ");

        match msg.head.version {
            Version::HTTP_10 => extend(dst, b"HTTP/1.0"),
            Version::HTTP_11 => extend(dst, b"HTTP/1.1"),
            Version::HTTP_2 => {
                debug!("request with HTTP2 version coerced to HTTP/1.1");
                extend(dst, b"HTTP/1.1");
            }
            other => panic!("unexpected request version: {other:?}"),
        }
        extend(dst, b"\r\n");

        write_h1_headers(&msg.head.headers, msg.title_case_headers, dst);

        msg.head
            .extensions
            .insert(RequestHeaders::from(msg.head.headers));

        extend(dst, b"\r\n");

        Ok(body)
    }

    fn on_error(_err: &crate::Error) -> Option<MessageHead<Self::Outgoing>> {
        // we can't tell the server about any errors it creates
        None
    }

    fn is_client() -> bool {
        true
    }
}

impl Client {
    /// Returns `Some(length, wants_upgrade)` if successful.
    ///
    /// Returns `None` if this message head should be skipped (like a 100 status).
    #[expect(clippy::needless_pass_by_ref_mut)]
    fn decoder(
        inc: &MessageHead<StatusCode>,
        method: &mut Option<Method>,
    ) -> Result<Option<(DecodedLength, bool)>, Parse> {
        // According to https://tools.ietf.org/html/rfc7230#section-3.3.3
        // 1. HEAD responses, and Status 1xx, 204, and 304 cannot have a body.
        // 2. Status 2xx to a CONNECT cannot have a body.
        // 3. Transfer-Encoding: chunked has a chunked body.
        // 4. If multiple differing Content-Length headers or invalid, close connection.
        // 5. Content-Length header has a sized body.
        // 6. (irrelevant to Response)
        // 7. Read till EOF.

        // Every successful CONNECT switches to tunnel framing, including 204.
        // Check it before ordinary bodyless responses so an upgrade is published.
        if *method == Some(Method::CONNECT) && inc.subject.is_success() {
            return Ok(Some((DecodedLength::ZERO, true)));
        }

        match inc.subject.as_u16() {
            101 => {
                return Ok(Some((DecodedLength::ZERO, true)));
            }
            100 | 102..=199 => {
                trace!("ignoring informational response: {}", inc.subject.as_u16());
                return Ok(None);
            }
            204 | 304 => return Ok(Some((DecodedLength::ZERO, false))),
            _ => (),
        }
        match *method {
            Some(Method::HEAD) => {
                return Ok(Some((DecodedLength::ZERO, false)));
            }
            Some(_) => {}
            None => {
                trace!("decoder is missing the Method");
            }
        }

        if inc.headers.contains_key(header::TRANSFER_ENCODING) {
            // https://tools.ietf.org/html/rfc7230#section-3.3.3
            // If Transfer-Encoding header is present, and 'chunked' is
            // not the final encoding, and this is a Request, then it is
            // malformed. A server should respond with 400 Bad Request.
            if inc.version == Version::HTTP_10 {
                debug!("HTTP/1.0 cannot have Transfer-Encoding header");
                Err(Parse::transfer_encoding_unexpected())
            } else if headers::transfer_encoding_is_chunked(&inc.headers) {
                Ok(Some((DecodedLength::CHUNKED, false)))
            } else {
                trace!("not chunked, read till eof");
                Ok(Some((DecodedLength::CLOSE_DELIMITED, false)))
            }
        } else if let Some(len) = headers::content_length_parse_all(&inc.headers) {
            Ok(Some((DecodedLength::try_checked_new(len)?, false)))
        } else if inc.headers.contains_key(header::CONTENT_LENGTH) {
            debug!("illegal Content-Length header");
            Err(Parse::content_length_invalid())
        } else {
            trace!("neither Transfer-Encoding nor Content-Length");
            Ok(Some((DecodedLength::CLOSE_DELIMITED, false)))
        }
    }

    fn set_length(head: &mut EncodeHead<'_, RequestLine>, body: Option<BodyLength>) -> Encoder {
        let Some(body) = body else {
            head.headers.remove(header::TRANSFER_ENCODING);
            headers::drop_undeliverable_content_length(&mut head.headers);
            return Encoder::length(0);
        };

        // A capture/inspection body may still need polling to finish bookkeeping
        // although its exact payload length is zero. As in HTTP/2, do not invent
        // Content-Length for GET/HEAD/DELETE/CONNECT. In particular, Capsule
        // Protocol upgrade requests forbid even Content-Length: 0.
        if matches!(body, BodyLength::Known(0))
            && !headers::method_has_defined_payload_semantics(&head.subject.0)
            && !head.headers.contains_key(header::CONTENT_LENGTH)
            && !head.headers.contains_key(header::TRANSFER_ENCODING)
        {
            return Encoder::length(0);
        }

        // HTTP/1.0 doesn't know about chunked
        let can_chunked = head.version == Version::HTTP_11;
        let headers = &mut head.headers;
        let connection_header_names = headers::connection_header_names(headers);

        // If the user already set specific headers, we should respect them, regardless
        // of what the Body knows about itself. They set them for a reason.

        // Because of the borrow checker, we can't check the for an existing
        // Content-Length header while holding an `Entry` for the Transfer-Encoding
        // header, so unfortunately, we must do the check here, first.

        let existing_con_len = headers::content_length_parse_all(headers);
        // A valid list of equal lengths goes out as the one value it stands for.
        if let Some(len) = existing_con_len {
            let mut values = headers.get_all(header::CONTENT_LENGTH).iter();
            if values
                .next()
                .is_some_and(|first| first.as_bytes().contains(&b',') || values.next().is_some())
            {
                headers.insert(header::CONTENT_LENGTH, HeaderValue::from(len));
            }
        }
        let mut should_remove_con_len = false;

        if !can_chunked {
            // Chunked isn't legal, so if it is set, we need to remove it.
            if headers.remove(header::TRANSFER_ENCODING).is_some() {
                trace!("removing illegal transfer-encoding header");
            }

            return if let Some(len) = existing_con_len {
                Encoder::length(len)
            } else if let BodyLength::Known(len) = body {
                set_content_length(headers, len)
            } else {
                // HTTP/1.0 client requests without a content-length
                // cannot have any body at all.
                headers.remove(header::CONTENT_LENGTH);
                Encoder::length(0)
            };
        }

        // If the user set a transfer-encoding, respect that. Let's just
        // make sure `chunked` is the final encoding.
        let encoder = match headers.entry(header::TRANSFER_ENCODING) {
            Entry::Occupied(te) => {
                should_remove_con_len = true;
                if headers::is_chunked(te.iter()) {
                    Some(Encoder::chunked())
                } else {
                    warn!("user provided transfer-encoding does not end in 'chunked'");

                    // There's a Transfer-Encoding, but it doesn't end in 'chunked'!
                    // An example that could trigger this:
                    //
                    //     Transfer-Encoding: gzip
                    //
                    // This can be bad, depending on if this is a request or a
                    // response.
                    //
                    // - A request is illegal if there is a `Transfer-Encoding`
                    //   but it doesn't end in `chunked`.
                    // - A response that has `Transfer-Encoding` but doesn't
                    //   end in `chunked` isn't illegal, it just forces this
                    //   to be close-delimited.
                    //
                    // We can try to repair this, by adding `chunked` ourselves.

                    headers::add_chunked(te);
                    Some(Encoder::chunked())
                }
            }
            Entry::Vacant(te) => {
                if let Some(len) = existing_con_len {
                    Some(Encoder::length(len))
                } else if matches!(body, BodyLength::Unknown) {
                    // A valid Content-Length would have been used above: drop invalid ones.
                    should_remove_con_len = true;
                    // GET, HEAD, and CONNECT almost never have bodies.
                    //
                    // So instead of sending a "chunked" body with a 0-chunk,
                    // assume no body here. If you *must* send a body,
                    // set the headers explicitly.
                    match head.subject.0 {
                        Method::GET | Method::HEAD | Method::CONNECT => Some(Encoder::length(0)),
                        _ => {
                            te.insert(HeaderValue::from_static("chunked"));
                            Some(Encoder::chunked())
                        }
                    }
                } else {
                    None
                }
            }
        };

        let allowed_trailers = head.extensions.get_arc::<ForbiddenTrailers>();
        let encoder = encoder.map(|enc| {
            enc.with_nominated_fields(connection_header_names)
                .maybe_with_allowed_trailers(allowed_trailers)
        });

        // This is because we need a second mutable borrow to remove
        // content-length header.
        if let Some(encoder) = encoder {
            if should_remove_con_len {
                headers.remove(header::CONTENT_LENGTH);
            }
            return encoder;
        }

        // User didn't set transfer-encoding, AND we know body length,
        // so we can just set the Content-Length automatically.

        let BodyLength::Known(len) = body else {
            unreachable!("BodyLength::Unknown would set chunked");
        };

        set_content_length(headers, len)
    }

    fn obs_fold_line(all: &mut [u8], idx: &mut HeaderIndices) {
        // If the value has obs-folded text, then in-place shift the bytes out
        // of here.
        //
        // https://httpwg.org/specs/rfc9112.html#line.folding
        //
        // > A user agent that receives an obs-fold MUST replace each received
        // > obs-fold with one or more SP octets prior to interpreting the
        // > field value.
        //
        // This means strings like "\r\n\t foo" must replace the "\r\n\t " with
        // a single space.

        let buf = &mut all[idx.value.0..idx.value.1];

        // look for a newline, otherwise bail out
        let Some(first_nl) = buf.iter().position(|b| *b == b'\n') else {
            return;
        };

        // not on standard slices because whatever, sigh
        fn trim_start(mut s: &[u8]) -> &[u8] {
            while let [first, rest @ ..] = s {
                if first.is_ascii_whitespace() {
                    s = rest;
                } else {
                    break;
                }
            }
            s
        }

        fn trim_end(mut s: &[u8]) -> &[u8] {
            while let [rest @ .., last] = s {
                if last.is_ascii_whitespace() {
                    s = rest;
                } else {
                    break;
                }
            }
            s
        }

        fn trim(s: &[u8]) -> &[u8] {
            trim_start(trim_end(s))
        }

        // TODO(perf): we could do the moves in-place, but this is so uncommon
        // that it shouldn't matter.
        let mut unfolded = trim_end(&buf[..first_nl]).to_vec();
        for line in buf[first_nl + 1..].split(|b| *b == b'\n') {
            unfolded.push(b' ');
            unfolded.extend_from_slice(trim(line));
        }
        buf[..unfolded.len()].copy_from_slice(&unfolded);
        idx.value.1 = idx.value.0 + unfolded.len();
    }
}

/// Folds a received `Connection` line into `keep_alive`, which starts at the
/// version's default: once any line carries `close`, a later `keep-alive` cannot undo it.
fn read_connection_line(keep_alive: &mut bool, saw_close: &mut bool, value: &HeaderValue) {
    if *saw_close || headers::connection_close(value) {
        *saw_close = true;
        *keep_alive = false;
    } else if !*keep_alive {
        // HTTP/1.0, which defaults to close
        *keep_alive = headers::connection_keep_alive(value);
    }
}

fn set_content_length(headers: &mut HeaderMap, len: u64) -> Encoder {
    // At this point, there should not be a valid Content-Length
    // header. However, since we'll be indexing in anyways, we can
    // warn the user if there was an existing illegal header.
    //
    // Or at least, we can in theory. It's actually a little bit slower,
    // so perhaps only do that while the user is developing/testing.

    if cfg!(debug_assertions) {
        match headers.entry(header::CONTENT_LENGTH) {
            Entry::Occupied(mut cl) => {
                // Internal sanity check, we should have already determined
                // that the header was illegal before calling this function.
                debug_assert!(headers::content_length_parse_all_values(cl.iter()).is_none());
                // Uh oh, the user set `Content-Length` headers, but set bad ones.
                // This would be an illegal message anyways, so let's try to repair
                // with our known good length.
                error!("user provided content-length header was invalid");

                cl.insert(HeaderValue::from(len));
                Encoder::length(len)
            }
            Entry::Vacant(cl) => {
                cl.insert(HeaderValue::from(len));
                Encoder::length(len)
            }
        }
    } else {
        headers.insert(header::CONTENT_LENGTH, HeaderValue::from(len));
        Encoder::length(len)
    }
}

#[derive(Clone, Copy)]
struct HeaderIndices {
    name: (usize, usize),
    value: (usize, usize),
}

/// Record the byte ranges of `headers` within `bytes` into `indices`.
///
/// # Safety-usable invariant
///
/// On `Ok(n)`, `n <= indices.len()` and `indices[..n]` is initialized.
fn record_header_indices(
    bytes: &[u8],
    headers: &[httparse::Header<'_>],
    indices: &mut [MaybeUninit<HeaderIndices>],
) -> Result<usize, crate::error::Parse> {
    let bytes_ptr = bytes.as_ptr() as usize;
    let mut recorded = 0;

    for (header, indices) in headers.iter().zip(indices.iter_mut()) {
        if header.name.len() >= (1 << 16) {
            debug!("header name larger than 64kb: {:?}", header.name);
            return Err(crate::error::Parse::TooLarge);
        }
        let name_start = header.name.as_ptr() as usize - bytes_ptr;
        let name_end = name_start + header.name.len();
        let value_start = header.value.as_ptr() as usize - bytes_ptr;
        let value_end = value_start + header.value.len();

        indices.write(HeaderIndices {
            name: (name_start, name_end),
            value: (value_start, value_end),
        });
        // `zip` visits `indices` in order, so this wrote `indices[recorded]`.
        recorded += 1;
    }

    Ok(recorded)
}

fn title_case_in_place(name: &mut [u8]) {
    let mut prev = b'-';
    for c in name {
        if prev == b'-' {
            c.make_ascii_uppercase();
        }
        prev = *c;
    }
}

/// Write one header field in its original spelling, or title-cased.
pub(crate) fn write_header_field(
    name: &HeaderName,
    value: &HeaderValue,
    title_case: bool,
    dst: &mut Vec<u8>,
) {
    let start = dst.len();
    name.write_original(dst);
    if title_case {
        title_case_in_place(&mut dst[start..]);
    }
    extend(dst, b": ");
    extend(dst, value.as_bytes());
    extend(dst, b"\r\n");
}

fn write_h1_headers(headers: &HeaderMap, title_case_headers: bool, dst: &mut Vec<u8>) {
    for (name, value) in headers.ordered_iter() {
        if title_case_headers {
            let start = dst.len();
            name.write_original(dst);
            title_case_in_place(&mut dst[start..]);
        } else {
            name.write_original(dst);
        }

        // Wanted for curl test cases that send `X-Custom-Header:\r\n`
        if value.is_empty() {
            extend(dst, b":\r\n");
        } else {
            extend(dst, b": ");
            extend(dst, value.as_bytes());
            extend(dst, b"\r\n");
        }
    }
}

#[inline]
fn extend(dst: &mut Vec<u8>, data: &[u8]) {
    dst.extend_from_slice(data);
}

/// Write the HTTP/1 request-target, choosing the form from the request itself —
/// mirroring how `Pseudo::request` builds the h2 pseudo-headers.
///
/// - `CONNECT` -> authority-form (`host:port`)
/// - OPTIONS `*` -> `*`
/// - forward HTTP proxy + insecure scheme -> absolute-form (`http://host/path`)
/// - otherwise -> origin-form (`/path?query`)
///
/// The `EstablishedProxyRoute` extension is the one extra connection signal
/// H1 needs that h2's `Pseudo::request` does not (h2 has no absolute-form). The
/// form writers normalise an empty path to `/` and strip the userinfo/fragment
/// that must not reach the wire.
fn encode_request_target(
    method: &Method,
    uri: &rama_net::uri::Uri,
    extensions: &Extensions,
    dst: &mut Vec<u8>,
) {
    let written =
        rama_http_types::proto::h1::head::encode_request_target(method, uri, extensions, dst);
    // defensive: a form mismatch (e.g. `*` for another method than OPTIONS) still
    // sends a valid target, never the raw URI.
    if written.is_err() && uri.write_http_origin_form(dst).is_err() {
        extend(dst, b"/");
    }
}

#[cfg(test)]
mod tests {
    use std::assert_matches;

    use httparse::ParserConfig;
    use rama_core::{bytes::BytesMut, extensions::Extension};
    use rama_http_types::header::HeaderValue;

    use super::*;

    #[derive(Debug, Clone, Copy, PartialEq, Eq, Extension)]
    struct UpstreamRequestId(u64);

    #[test]
    fn encode_request_target_forms() {
        use rama_net::{
            Protocol,
            address::{HostWithPort, ProxyAddress},
            client::{EstablishedProxyRoute, ProxyRoute},
            uri::Uri,
        };

        fn target(method: &Method, uri: &str, ext: &Extensions) -> String {
            target_of(method, &Uri::parse(uri).unwrap(), ext)
        }

        fn target_of(method: &Method, uri: &Uri, ext: &Extensions) -> String {
            let mut dst = b"GET ".to_vec();
            encode_request_target(method, uri, ext, &mut dst);
            String::from_utf8(dst.split_off(4)).unwrap()
        }

        fn http_proxy_ext() -> Extensions {
            let ext = Extensions::new();
            ext.insert(EstablishedProxyRoute::Forward(ProxyAddress {
                address: HostWithPort::example_domain_http(),
                credential: None,
                protocol: Some(Protocol::HTTP),
                template: None,
            }));
            ext
        }

        fn http_proxy_route_ext() -> Extensions {
            let ext = Extensions::new();
            ext.insert(ProxyRoute::Proxy(ProxyAddress {
                address: HostWithPort::example_domain_http(),
                credential: None,
                protocol: Some(Protocol::HTTP),
                template: None,
            }));
            ext
        }

        let none = Extensions::new();

        // direct -> origin-form (empty path normalised to "/")
        assert_eq!(
            target(&Method::GET, "http://example.com/p?q=1", &none),
            "/p?q=1"
        );
        assert_eq!(target(&Method::GET, "http://example.com", &none), "/");

        // OPTIONS * -> "*"
        assert_eq!(target(&Method::OPTIONS, "*", &none), "*");
        // The infallible connection encoder coerces an invalid GET * to
        // origin-form instead of putting an invalid target on the wire.
        assert_eq!(target(&Method::GET, "*", &none), "/");

        // CONNECT -> authority-form
        assert_eq!(
            target(&Method::CONNECT, "https://example.com:443", &none),
            "example.com:443",
        );

        // forward HTTP proxy + insecure -> absolute-form, stripping userinfo + fragment
        assert_eq!(
            target(
                &Method::GET,
                "http://user:pass@example.com/p#frag",
                &http_proxy_ext()
            ),
            "http://example.com/p",
        );
        // ...and a server-wide OPTIONS stays path-less up to the last hop
        assert_eq!(
            target(&Method::OPTIONS, "http://example.com", &http_proxy_ext()),
            "http://example.com",
        );

        // A reference without a scheme: through a forward proxy a network-path
        // reference takes the resolved protocol, one without authority stays in
        // origin-form; either way the target is valid.
        for (reference, direct, proxied) in [
            ("//example.com/p?q#frag", "/p?q", "http://example.com/p?q"),
            ("/p#frag", "/p", "/p"),
            ("?q=only", "/?q=only", "/?q=only"),
            ("", "/", "/"),
            ("rel/path", "/rel/path", "/rel/path"),
        ] {
            let uri = Uri::parse_reference(reference).unwrap();
            assert_eq!(
                target_of(&Method::GET, &uri, &none),
                direct,
                "{reference:?}"
            );
            assert_eq!(
                target_of(&Method::GET, &uri, &http_proxy_ext()),
                proxied,
                "{reference:?}"
            );
            // The connection encoder's fallback is not what makes these valid.
            let mut checked = Vec::new();
            rama_http_types::proto::h1::head::encode_request_target(
                &Method::GET,
                &uri,
                &http_proxy_ext(),
                &mut checked,
            )
            .unwrap();
            assert_eq!(checked, proxied.as_bytes(), "{reference:?}");
        }

        // A rootless path after an authority stays on that authority's host.
        for uri in [
            Uri::parse("http://example.com").unwrap().with_path("p"),
            Uri::parse_reference("//example.com")
                .unwrap()
                .with_path("p"),
        ] {
            assert_eq!(target_of(&Method::GET, &uri, &none), "/p", "{uri}");
            assert_eq!(
                target_of(&Method::GET, &uri, &http_proxy_ext()),
                "http://example.com/p",
                "{uri}"
            );
        }

        // Without an authority a server-wide OPTIONS is sent as it would be directly.
        assert_eq!(
            target_of(
                &Method::OPTIONS,
                &Uri::parse_reference("").unwrap(),
                &http_proxy_ext()
            ),
            "*"
        );

        // Route intent alone cannot prove which connection was established.
        assert_eq!(
            target(
                &Method::GET,
                "http://user:pass@example.com/p#frag",
                &http_proxy_route_ext()
            ),
            "/p",
        );

        // secure request over an HTTP proxy is tunnelled -> origin-form, not absolute
        assert_eq!(
            target(&Method::GET, "https://example.com/p", &http_proxy_ext()),
            "/p"
        );
    }

    #[test]
    fn encode_request_target_uses_full_protocol_resolution() {
        use rama_net::{
            Protocol,
            address::{HostWithPort, ProxyAddress},
            client::EstablishedProxyRoute,
            uri::Uri,
        };

        // A scheme-less request whose protocol is HTTPS *only* via an inserted `Protocol`
        // extension (not the URI scheme) must resolve as secure -> origin-form over an
        // http proxy, not absolute-form. `uri.scheme()` alone would miss this; the full
        // resolver that `encode_request_target` uses catches it. (The real `SecureTransport`
        // arm — and the feature wiring it needs — is guarded by the `tls` test below.)
        let ext = Extensions::new();
        ext.insert(EstablishedProxyRoute::Forward(ProxyAddress {
            address: HostWithPort::example_domain_http(),
            credential: None,
            protocol: Some(Protocol::HTTP),
            template: None,
        }));
        ext.insert(Protocol::HTTPS);

        // Check the fallible encoder too: the wrapper's defensive fallback
        // would otherwise hide a NoScheme error behind the same relative URI.
        let uri = Uri::parse("/p?q=1").unwrap();
        let mut checked = Vec::new();
        rama_http_types::proto::h1::head::encode_request_target(
            &Method::GET,
            &uri,
            &ext,
            &mut checked,
        )
        .expect("secure protocol metadata must produce a valid origin-form target");
        assert_eq!(&checked[..], b"/p?q=1");

        let mut dst = Vec::new();
        encode_request_target(&Method::GET, &uri, &ext, &mut dst);
        assert_eq!(String::from_utf8(dst).unwrap(), "/p?q=1");
    }

    // Mirrors the rama-http-backend regression guard: with `tls` on (→ `rama-http-types/tls`),
    // the encoder's protocol resolution must see the REAL `SecureTransport` extension (not the
    // feature-off dummy). A scheme-less request marked secure only via TLS termination, sent
    // over an http proxy, must resolve as secure -> origin-form, not absolute. This is the
    // test that fails if `rama-http-core/tls` forgets to forward `rama-http-types/tls`.
    #[cfg(feature = "tls")]
    #[test]
    fn encode_request_target_honors_real_secure_transport() {
        use rama_net::{
            Protocol,
            address::{HostWithPort, ProxyAddress},
            client::EstablishedProxyRoute,
            uri::Uri,
        };
        use rama_tls::SecureTransport;

        let ext = Extensions::new();
        ext.insert(EstablishedProxyRoute::Forward(ProxyAddress {
            address: HostWithPort::example_domain_http(),
            credential: None,
            protocol: Some(Protocol::HTTP),
            template: None,
        }));
        ext.insert(SecureTransport::default());

        let uri = Uri::parse("/p?q=1").unwrap();
        let mut checked = Vec::new();
        rama_http_types::proto::h1::head::encode_request_target(
            &Method::GET,
            &uri,
            &ext,
            &mut checked,
        )
        .expect("TLS metadata must produce a valid origin-form target");
        assert_eq!(&checked[..], b"/p?q=1");

        let mut dst = Vec::new();
        encode_request_target(&Method::GET, &uri, &ext, &mut dst);
        assert_eq!(String::from_utf8(dst).unwrap(), "/p?q=1");
    }

    #[test]
    fn test_parse_request() {
        let mut raw = BytesMut::from(
            "GET /echo HTTP/1.1\r\nHost: ramaproxy.org\r\nAuthorization: secret\r\n\r\n",
        );
        let mut method = None;
        let msg = Server::parse(
            &mut raw,
            ParseContext {
                req_method: &mut method,
                h1_parser_config: Default::default(),
                h1_max_headers: None,
                h1_max_header_size: None,
                h09_responses: false,
                on_informational: &mut None,
                prepared_extensions: &mut Some(Extensions::default()),
            },
        )
        .unwrap()
        .unwrap();
        assert_eq!(raw.len(), 0);
        assert_eq!(msg.head.subject.0, Method::GET);
        assert_eq!(msg.head.subject.1.as_str(), "/echo");
        assert_eq!(msg.head.version, Version::HTTP_11);
        assert_eq!(msg.head.headers.len(), 2);
        assert_eq!(msg.head.headers["Host"], "ramaproxy.org");
        assert!(msg.head.headers["Authorization"].is_sensitive());
        assert_eq!(method, Some(Method::GET));
        assert_eq!(
            msg.head.extensions.get_ref::<RequestTargetForm>(),
            Some(&RequestTargetForm::Origin),
        );
    }

    #[test]
    fn received_targets_name_the_routed_authority() {
        for (raw, uri, host) in [
            // RFC 9112 §3.2.2: an absolute-form target replaces a differing Host.
            (
                "GET http://user:pw@ramaproxy.org/echo HTTP/1.1\r\nHost: other.example\r\n\r\n",
                "http://ramaproxy.org/echo",
                Some("ramaproxy.org"),
            ),
            (
                "GET http://ramaproxy.org/echo HTTP/1.1\r\nHost: RAMAPROXY.org\r\n\r\n",
                "http://ramaproxy.org/echo",
                Some("RAMAPROXY.org"),
            ),
            (
                "CONNECT ramaproxy.org:443 HTTP/1.1\r\nHost: other.example\r\n\r\n",
                "ramaproxy.org:443",
                Some("ramaproxy.org:443"),
            ),
            // Origin-form keeps its Host, less userinfo.
            (
                "GET /echo HTTP/1.1\r\nHost: user@ramaproxy.org\r\n\r\n",
                "/echo",
                Some("ramaproxy.org"),
            ),
            ("GET /echo HTTP/1.1\r\n\r\n", "/echo", None),
        ] {
            let (received, headers) = crate::proto::h1::test_util::receive(raw);
            assert_eq!(received.to_string(), uri, "{raw}");
            assert_eq!(
                headers
                    .get(header::HOST)
                    .map(|value| value.to_str().unwrap()),
                host,
                "{raw}"
            );
        }
    }

    /// A replaced or collapsed Host keeps the first line's spelling and position.
    #[test]
    fn normalized_hosts_keep_their_name_and_position() {
        for (target, host, extra, expected) in [
            (
                "http://ramaproxy.org/x",
                "ramaproxy.org",
                "",
                "ramaproxy.org",
            ),
            (
                "http://ramaproxy.org/x",
                "other.example",
                "",
                "ramaproxy.org",
            ),
            ("/x", "user@ramaproxy.org", "", "ramaproxy.org"),
        ] {
            let raw = format!(
                "GET {target} HTTP/1.1\r\nX-First: a\r\nhOsT: {host}\r\nX-Middle: b\r\n\
                 X-Middle: c\r\n{extra}X-Last: d\r\n\r\n"
            );
            let (_, headers) = crate::proto::h1::test_util::receive(&raw);
            let fields: Vec<_> = headers
                .ordered_iter()
                .map(|(name, value)| {
                    format!("{}: {}", name.as_original_str(), value.to_str().unwrap())
                })
                .collect();
            assert_eq!(
                fields,
                [
                    "X-First: a".to_owned(),
                    format!("hOsT: {expected}"),
                    "X-Middle: b".to_owned(),
                    "X-Middle: c".to_owned(),
                    "X-Last: d".to_owned(),
                ],
                "{target} {host} {extra:?}"
            );
        }
    }

    #[test]
    fn test_parse_request_records_absolute_target_form() {
        let mut raw =
            BytesMut::from("GET http://ramaproxy.org/echo HTTP/1.1\r\nHost: ramaproxy.org\r\n\r\n");
        let msg = Server::parse(
            &mut raw,
            ParseContext {
                req_method: &mut None,
                h1_parser_config: Default::default(),
                h1_max_headers: None,
                h1_max_header_size: None,
                h09_responses: false,
                on_informational: &mut None,
                prepared_extensions: &mut Some(Extensions::default()),
            },
        )
        .unwrap()
        .unwrap();

        assert_eq!(msg.head.subject.1.as_str(), "http://ramaproxy.org/echo");
        assert_eq!(
            msg.head.extensions.get_ref::<RequestTargetForm>(),
            Some(&RequestTargetForm::Absolute),
        );
    }

    #[test]
    fn test_parse_response() {
        let mut raw =
            BytesMut::from("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nSet-Cookie: secret\r\n\r\n");
        let ctx = ParseContext {
            req_method: &mut Some(Method::GET),
            h1_parser_config: Default::default(),
            h1_max_headers: None,
            h1_max_header_size: None,
            h09_responses: false,
            on_informational: &mut None,
            prepared_extensions: &mut Some(Extensions::default()),
        };
        let msg = Client::parse(&mut raw, ctx).unwrap().unwrap();
        assert_eq!(raw.len(), 0);
        assert_eq!(msg.head.subject, StatusCode::OK);
        assert_eq!(msg.head.version, Version::HTTP_11);
        assert_eq!(msg.head.headers.len(), 2);
        assert_eq!(msg.head.headers["Content-Length"], "0");
        assert!(msg.head.headers["Set-Cookie"].is_sensitive());
    }

    #[test]
    fn test_parse_request_errors() {
        let mut raw = BytesMut::from("GET htt:p// HTTP/1.1\r\nHost: ramaproxy.org\r\n\r\n");
        let ctx = ParseContext {
            req_method: &mut None,
            h1_parser_config: Default::default(),
            h1_max_headers: None,
            h1_max_header_size: None,
            h09_responses: false,
            on_informational: &mut None,
            prepared_extensions: &mut Some(Extensions::default()),
        };
        Server::parse(&mut raw, ctx).unwrap_err();
    }

    const H09_RESPONSE: &str = "Baguettes are super delicious, don't you agree?";

    #[test]
    fn test_parse_response_h09_allowed() {
        let mut raw = BytesMut::from(H09_RESPONSE);
        let ctx = ParseContext {
            req_method: &mut Some(Method::GET),
            h1_parser_config: Default::default(),
            h1_max_headers: None,
            h1_max_header_size: None,
            h09_responses: true,
            on_informational: &mut None,
            prepared_extensions: &mut Some(Extensions::default()),
        };
        let msg = Client::parse(&mut raw, ctx).unwrap().unwrap();
        assert_eq!(raw, H09_RESPONSE);
        assert_eq!(msg.head.subject, StatusCode::OK);
        assert_eq!(msg.head.version, Version::HTTP_09);
        assert_eq!(msg.head.headers.len(), 0);
    }

    #[test]
    fn test_parse_response_h09_rejected() {
        let mut raw = BytesMut::from(H09_RESPONSE);
        let ctx = ParseContext {
            req_method: &mut Some(Method::GET),
            h1_parser_config: Default::default(),
            h1_max_headers: None,
            h1_max_header_size: None,
            h09_responses: false,
            on_informational: &mut None,
            prepared_extensions: &mut Some(Extensions::default()),
        };
        Client::parse(&mut raw, ctx).unwrap_err();
        assert_eq!(raw, H09_RESPONSE);
    }

    const RESPONSE_WITH_WHITESPACE_BETWEEN_HEADER_NAME_AND_COLON: &str =
        "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Credentials : true\r\n\r\n";

    #[test]
    fn test_parse_allow_response_with_spaces_before_colons() {
        use httparse::ParserConfig;

        let mut raw = BytesMut::from(RESPONSE_WITH_WHITESPACE_BETWEEN_HEADER_NAME_AND_COLON);
        let mut h1_parser_config = ParserConfig::default();
        h1_parser_config.allow_spaces_after_header_name_in_responses(true);
        let ctx = ParseContext {
            req_method: &mut Some(Method::GET),
            h1_parser_config,
            h1_max_headers: None,
            h1_max_header_size: None,
            h09_responses: false,
            on_informational: &mut None,
            prepared_extensions: &mut Some(Extensions::default()),
        };
        let msg = Client::parse(&mut raw, ctx).unwrap().unwrap();
        assert_eq!(raw.len(), 0);
        assert_eq!(msg.head.subject, StatusCode::OK);
        assert_eq!(msg.head.version, Version::HTTP_11);
        assert_eq!(msg.head.headers.len(), 1);
        assert_eq!(msg.head.headers["Access-Control-Allow-Credentials"], "true");
    }

    #[test]
    fn test_parse_reject_response_with_spaces_before_colons() {
        let mut raw = BytesMut::from(RESPONSE_WITH_WHITESPACE_BETWEEN_HEADER_NAME_AND_COLON);
        let ctx = ParseContext {
            req_method: &mut Some(Method::GET),
            h1_parser_config: Default::default(),
            h1_max_headers: None,
            h1_max_header_size: None,
            h09_responses: false,
            on_informational: &mut None,
            prepared_extensions: &mut Some(Extensions::default()),
        };
        Client::parse(&mut raw, ctx).unwrap_err();
    }

    const REQUEST_WITH_MULTIPLE_SPACES_IN_REQUEST_LINE: &str =
        "GET  /echo  HTTP/1.1\r\nHost: hyper.rs\r\n\r\n";

    #[test]
    fn test_parse_allow_request_with_multiple_spaces_in_request_line() {
        let mut raw = BytesMut::from(REQUEST_WITH_MULTIPLE_SPACES_IN_REQUEST_LINE);
        let mut h1_parser_config = ParserConfig::default();
        h1_parser_config.allow_multiple_spaces_in_request_line_delimiters(true);
        let mut method = None;
        let ctx = ParseContext {
            req_method: &mut method,
            h1_parser_config,
            h1_max_headers: None,
            h1_max_header_size: None,
            h09_responses: false,
            on_informational: &mut None,
            prepared_extensions: &mut Some(Extensions::default()),
        };
        let msg = Server::parse(&mut raw, ctx).unwrap().unwrap();
        assert_eq!(raw.len(), 0);
        assert_eq!(msg.head.subject.0, Method::GET);
        assert_eq!(msg.head.subject.1.as_str(), "/echo");
        assert_eq!(msg.head.version, Version::HTTP_11);
        assert_eq!(msg.head.headers.len(), 1);
        assert_eq!(msg.head.headers["Host"], "hyper.rs");
        assert_eq!(method, Some(Method::GET));
    }

    #[test]
    fn test_parse_reject_request_with_multiple_spaces_in_request_line() {
        let mut raw = BytesMut::from(REQUEST_WITH_MULTIPLE_SPACES_IN_REQUEST_LINE);
        let ctx = ParseContext {
            req_method: &mut None,
            h1_parser_config: Default::default(),
            h1_max_headers: None,
            h1_max_header_size: None,
            h09_responses: false,
            on_informational: &mut None,
            prepared_extensions: &mut Some(Extensions::default()),
        };
        Server::parse(&mut raw, ctx).unwrap_err();
    }

    #[test]
    fn test_parse_preserve_header_case_in_request() {
        let mut raw =
            BytesMut::from("GET / HTTP/1.1\r\nHost: ramaproxy.org\r\nX-PASTA: noodles\r\n\r\n");
        let ctx = ParseContext {
            req_method: &mut None,
            h1_parser_config: Default::default(),
            h1_max_headers: None,
            h1_max_header_size: None,
            h09_responses: false,
            on_informational: &mut None,
            prepared_extensions: &mut Some(Extensions::default()),
        };
        let parsed_message = Server::parse(&mut raw, ctx).unwrap().unwrap();
        let mut orig_headers = parsed_message.head.headers.ordered_iter();
        assert_eq!("Host", orig_headers.next().unwrap().0.to_string());
        assert_eq!("X-PASTA", orig_headers.next().unwrap().0.to_string());
    }

    #[test]
    fn test_decoder_request() {
        fn parse(s: &str) -> ParsedMessage<RequestLine> {
            let mut bytes = BytesMut::from(s);
            Server::parse(
                &mut bytes,
                ParseContext {
                    req_method: &mut None,
                    h1_parser_config: Default::default(),
                    h1_max_headers: None,
                    h1_max_header_size: None,
                    h09_responses: false,
                    on_informational: &mut None,
                    prepared_extensions: &mut Some(Extensions::default()),
                },
            )
            .expect("parse ok")
            .expect("parse complete")
        }

        fn parse_err(s: &str, comment: &str) -> crate::error::Parse {
            let mut bytes = BytesMut::from(s);
            Server::parse(
                &mut bytes,
                ParseContext {
                    req_method: &mut None,
                    h1_parser_config: Default::default(),
                    h1_max_headers: None,
                    h1_max_header_size: None,
                    h09_responses: false,
                    on_informational: &mut None,
                    prepared_extensions: &mut Some(Extensions::default()),
                },
            )
            .expect_err(comment)
        }

        // no length or transfer-encoding means 0-length body
        assert_eq!(
            parse(
                "\
                 GET / HTTP/1.1\r\n\
                 \r\n\
                 "
            )
            .decode,
            DecodedLength::ZERO
        );

        assert_eq!(
            parse(
                "\
                 POST / HTTP/1.1\r\n\
                 \r\n\
                 "
            )
            .decode,
            DecodedLength::ZERO
        );

        // transfer-encoding: chunked
        assert_eq!(
            parse(
                "\
                 POST / HTTP/1.1\r\n\
                 transfer-encoding: chunked\r\n\
                 \r\n\
                 "
            )
            .decode,
            DecodedLength::CHUNKED
        );

        assert_eq!(
            parse(
                "\
                 POST / HTTP/1.1\r\n\
                 transfer-encoding: gzip, chunked\r\n\
                 \r\n\
                 "
            )
            .decode,
            DecodedLength::CHUNKED
        );

        assert_eq!(
            parse(
                "\
                 POST / HTTP/1.1\r\n\
                 transfer-encoding: gzip\r\n\
                 transfer-encoding: chunked\r\n\
                 \r\n\
                 "
            )
            .decode,
            DecodedLength::CHUNKED
        );

        // content-length
        assert_eq!(
            parse(
                "\
                 POST / HTTP/1.1\r\n\
                 content-length: 10\r\n\
                 \r\n\
                 "
            )
            .decode,
            DecodedLength::new(10)
        );

        // transfer-encoding and content-length = chunked
        let msg = parse(
            "\
             POST / HTTP/1.1\r\n\
             content-length: 10\r\n\
             transfer-encoding: chunked\r\n\
             \r\n\
             ",
        );
        assert_eq!(msg.decode, DecodedLength::CHUNKED);
        assert!(!msg.head.headers.contains_key(header::CONTENT_LENGTH));
        assert!(!msg.keep_alive);

        let msg = parse(
            "\
             POST / HTTP/1.1\r\n\
             transfer-encoding: chunked\r\n\
             content-length: 10\r\n\
             \r\n\
             ",
        );
        assert_eq!(msg.decode, DecodedLength::CHUNKED);
        assert!(!msg.head.headers.contains_key(header::CONTENT_LENGTH));
        assert!(!msg.keep_alive);

        let msg = parse(
            "\
             POST / HTTP/1.1\r\n\
             transfer-encoding: gzip\r\n\
             content-length: 10\r\n\
             transfer-encoding: chunked\r\n\
             \r\n\
             ",
        );
        assert_eq!(msg.decode, DecodedLength::CHUNKED);
        assert!(!msg.head.headers.contains_key(header::CONTENT_LENGTH));
        assert!(!msg.keep_alive);

        let msg = parse(
            "\
             POST / HTTP/1.1\r\n\
             connection: keep-alive\r\n\
             content-length: 10\r\n\
             transfer-encoding: chunked\r\n\
             \r\n\
             ",
        );
        assert_eq!(msg.decode, DecodedLength::CHUNKED);
        assert!(!msg.head.headers.contains_key(header::CONTENT_LENGTH));
        assert!(!msg.keep_alive);

        // multiple content-lengths of same value are fine
        assert_eq!(
            parse(
                "\
                 POST / HTTP/1.1\r\n\
                 content-length: 10\r\n\
                 content-length: 10\r\n\
                 \r\n\
                 "
            )
            .decode,
            DecodedLength::new(10)
        );

        // multiple content-lengths with different values is an error
        parse_err(
            "\
             POST / HTTP/1.1\r\n\
             content-length: 10\r\n\
             content-length: 11\r\n\
             \r\n\
             ",
            "multiple content-lengths",
        );

        // content-length with prefix is not allowed
        parse_err(
            "\
             POST / HTTP/1.1\r\n\
             content-length: +10\r\n\
             \r\n\
             ",
            "prefixed content-length",
        );

        // transfer-encoding that isn't chunked is an error
        parse_err(
            "\
             POST / HTTP/1.1\r\n\
             transfer-encoding: gzip\r\n\
             \r\n\
             ",
            "transfer-encoding but not chunked",
        );

        parse_err(
            "\
             POST / HTTP/1.1\r\n\
             transfer-encoding: chunked, gzip\r\n\
             \r\n\
             ",
            "transfer-encoding doesn't end in chunked",
        );

        parse_err(
            "\
             POST / HTTP/1.1\r\n\
             transfer-encoding: chunked\r\n\
             transfer-encoding: afterlol\r\n\
             \r\n\
             ",
            "transfer-encoding multiple lines doesn't end in chunked",
        );

        // http/1.0

        assert_eq!(
            parse(
                "\
                 POST / HTTP/1.0\r\n\
                 content-length: 10\r\n\
                 \r\n\
                 "
            )
            .decode,
            DecodedLength::new(10)
        );

        // 1.0 doesn't understand chunked, so its an error
        parse_err(
            "\
             POST / HTTP/1.0\r\n\
             transfer-encoding: chunked\r\n\
             \r\n\
             ",
            "1.0 chunked",
        );
    }

    /// RFC 9112 §6.1: when a request carries both Content-Length and
    /// `Transfer-Encoding: chunked`, the CL MUST NOT survive the parse —
    /// forwarding it downstream is a classic CL.TE request-smuggling vector.
    #[test]
    fn test_strip_content_length_when_te_chunked_cl_first() {
        fn parse(s: &str) -> ParsedMessage<RequestLine> {
            let mut bytes = BytesMut::from(s);
            Server::parse(
                &mut bytes,
                ParseContext {
                    req_method: &mut None,
                    h1_parser_config: Default::default(),
                    h1_max_headers: None,
                    h1_max_header_size: None,
                    h09_responses: false,
                    on_informational: &mut None,
                    prepared_extensions: &mut Some(Extensions::default()),
                },
            )
            .expect("parse ok")
            .expect("parse complete")
        }

        // CL before TE chunked — CL must be stripped from the HeaderMap
        let msg = parse(
            "\
             POST / HTTP/1.1\r\n\
             host: x\r\n\
             content-length: 10\r\n\
             transfer-encoding: chunked\r\n\
             \r\n\
             ",
        );
        assert_eq!(msg.decode, DecodedLength::CHUNKED);
        assert!(
            !msg.head.headers.contains_key("content-length"),
            "Content-Length must be stripped when TE chunked is also present"
        );
        // And it must not survive in the ordered header map either.
        assert!(
            msg.head
                .headers
                .ordered_iter()
                .all(|(h, _)| h != header::CONTENT_LENGTH),
            "Content-Length must not be present in HeaderMap"
        );

        // TE chunked before CL — same expectation
        let msg = parse(
            "\
             POST / HTTP/1.1\r\n\
             host: x\r\n\
             transfer-encoding: chunked\r\n\
             content-length: 10\r\n\
             \r\n\
             ",
        );
        assert_eq!(msg.decode, DecodedLength::CHUNKED);
        assert!(
            !msg.head.headers.contains_key("content-length"),
            "Content-Length must not be appended after TE chunked"
        );
    }

    /// RFC 9112 §6.1: `chunked` MUST NOT be applied more than once.
    #[test]
    fn test_reject_duplicate_chunked_transfer_encoding() {
        fn parse_err(s: &str, comment: &str) -> crate::error::Parse {
            let mut bytes = BytesMut::from(s);
            Server::parse(
                &mut bytes,
                ParseContext {
                    req_method: &mut None,
                    h1_parser_config: Default::default(),
                    h1_max_headers: None,
                    h1_max_header_size: None,
                    h09_responses: false,
                    on_informational: &mut None,
                    prepared_extensions: &mut Some(Extensions::default()),
                },
            )
            .expect_err(comment)
        }

        parse_err(
            "\
             POST / HTTP/1.1\r\n\
             transfer-encoding: chunked, chunked\r\n\
             \r\n\
             ",
            "duplicate chunked in single TE value",
        );
    }

    /// Even when TE is seen before CL we still validate CL syntactically;
    /// a malformed CL is a malformed message regardless of TE.
    #[test]
    fn test_malformed_cl_still_rejected_after_te() {
        fn parse_err(s: &str, comment: &str) -> crate::error::Parse {
            let mut bytes = BytesMut::from(s);
            Server::parse(
                &mut bytes,
                ParseContext {
                    req_method: &mut None,
                    h1_parser_config: Default::default(),
                    h1_max_headers: None,
                    h1_max_header_size: None,
                    h09_responses: false,
                    on_informational: &mut None,
                    prepared_extensions: &mut Some(Extensions::default()),
                },
            )
            .expect_err(comment)
        }

        parse_err(
            "\
             POST / HTTP/1.1\r\n\
             transfer-encoding: chunked\r\n\
             content-length: +10\r\n\
             \r\n\
             ",
            "malformed CL after TE must still be rejected",
        );
    }

    #[test]
    fn test_decoder_response_request_extensions() {
        let request_exts = Extensions::new();
        request_exts.insert(UpstreamRequestId(42));

        let prepared = request_exts.fork();

        let mut bytes = BytesMut::from(
            "\
         HTTP/1.1 200 OK\r\n\
         \r\n\
         ",
        );
        let msg = Client::parse(
            &mut bytes,
            ParseContext {
                req_method: &mut Some(Method::GET),
                h1_parser_config: Default::default(),
                h1_max_headers: None,
                h1_max_header_size: None,
                h09_responses: false,
                on_informational: &mut None,
                prepared_extensions: &mut Some(prepared),
            },
        )
        .expect("parse ok")
        .expect("parse complete");

        assert_eq!(
            42u64,
            msg.head
                .extensions
                .get_ref::<UpstreamRequestId>()
                .map(|request_id| request_id.0)
                .unwrap()
        );
    }

    #[test]
    fn test_decoder_response() {
        fn parse(s: &str) -> ParsedMessage<StatusCode> {
            let msg = parse_with_method(s, Method::GET);
            let size = msg.head.extensions.get_ref::<HeaderByteLength>().unwrap().0;
            assert_eq!(size, s.len(), "parsed header: {s}");
            msg
        }

        fn parse_ignores(s: &str) {
            let mut bytes = BytesMut::from(s);
            assert!(
                Client::parse(
                    &mut bytes,
                    ParseContext {
                        req_method: &mut Some(Method::GET),
                        h1_parser_config: Default::default(),
                        h1_max_headers: None,
                        h1_max_header_size: None,
                        h09_responses: false,
                        on_informational: &mut None,
                        prepared_extensions: &mut Some(Extensions::default()),
                    }
                )
                .expect("parse ok")
                .is_none()
            )
        }

        fn parse_with_method(s: &str, m: Method) -> ParsedMessage<StatusCode> {
            let mut bytes = BytesMut::from(s);
            Client::parse(
                &mut bytes,
                ParseContext {
                    req_method: &mut Some(m),
                    h1_parser_config: Default::default(),
                    h1_max_headers: None,
                    h1_max_header_size: None,
                    h09_responses: false,
                    on_informational: &mut None,
                    prepared_extensions: &mut Some(Extensions::default()),
                },
            )
            .expect("parse ok")
            .expect("parse complete")
        }

        fn parse_err(s: &str) -> crate::error::Parse {
            let mut bytes = BytesMut::from(s);
            Client::parse(
                &mut bytes,
                ParseContext {
                    req_method: &mut Some(Method::GET),
                    h1_parser_config: Default::default(),
                    h1_max_headers: None,
                    h1_max_header_size: None,
                    h09_responses: false,
                    on_informational: &mut None,
                    prepared_extensions: &mut Some(Extensions::default()),
                },
            )
            .expect_err("parse should err")
        }

        // no content-length or transfer-encoding means close-delimited
        assert_eq!(
            parse(
                "\
                 HTTP/1.1 200 OK\r\n\
                 \r\n\
                 "
            )
            .decode,
            DecodedLength::CLOSE_DELIMITED
        );

        // 204 and 304 never have a body
        assert_eq!(
            parse(
                "\
                 HTTP/1.1 204 No Content\r\n\
                 \r\n\
                 "
            )
            .decode,
            DecodedLength::ZERO
        );

        assert_eq!(
            parse(
                "\
                 HTTP/1.1 304 Not Modified\r\n\
                 \r\n\
                 "
            )
            .decode,
            DecodedLength::ZERO
        );

        // content-length
        assert_eq!(
            parse(
                "\
                 HTTP/1.1 200 OK\r\n\
                 content-length: 8\r\n\
                 \r\n\
                 "
            )
            .decode,
            DecodedLength::new(8)
        );

        assert_eq!(
            parse(
                "\
                 HTTP/1.1 200 OK\r\n\
                 content-length: 8\r\n\
                 content-length: 8\r\n\
                 \r\n\
                 "
            )
            .decode,
            DecodedLength::new(8)
        );

        parse_err(
            "\
             HTTP/1.1 200 OK\r\n\
             content-length: 8\r\n\
             content-length: 9\r\n\
             \r\n\
             ",
        );

        parse_err(
            "\
             HTTP/1.1 200 OK\r\n\
             content-length: +8\r\n\
             \r\n\
             ",
        );

        // transfer-encoding: chunked
        assert_eq!(
            parse(
                "\
                 HTTP/1.1 200 OK\r\n\
                 transfer-encoding: chunked\r\n\
                 \r\n\
                 "
            )
            .decode,
            DecodedLength::CHUNKED
        );

        // transfer-encoding not-chunked is close-delimited
        assert_eq!(
            parse(
                "\
                 HTTP/1.1 200 OK\r\n\
                 transfer-encoding: yolo\r\n\
                 \r\n\
                 "
            )
            .decode,
            DecodedLength::CLOSE_DELIMITED
        );

        // transfer-encoding and content-length = chunked
        assert_eq!(
            parse(
                "\
                 HTTP/1.1 200 OK\r\n\
                 content-length: 10\r\n\
                 transfer-encoding: chunked\r\n\
                 \r\n\
                 "
            )
            .decode,
            DecodedLength::CHUNKED
        );

        // HEAD can have content-length, but not body
        assert_eq!(
            parse_with_method(
                "\
                 HTTP/1.1 200 OK\r\n\
                 content-length: 8\r\n\
                 \r\n\
                 ",
                Method::HEAD
            )
            .decode,
            DecodedLength::ZERO
        );

        // Every successful CONNECT upgrades, including ordinary bodyless 204.
        for status in 200..=299 {
            let msg = parse_with_method(
                &format!("HTTP/1.1 {status} Success\r\n\r\n"),
                Method::CONNECT,
            );
            assert_eq!(msg.decode, DecodedLength::ZERO);
            assert!(!msg.keep_alive, "should be upgrade");
            assert!(msg.wants_upgrade, "should be upgrade");
        }
        for status in [204, 304] {
            let msg = parse(&format!("HTTP/1.1 {status} Bodyless\r\n\r\n"));
            assert!(
                !msg.wants_upgrade,
                "ordinary bodyless responses do not upgrade"
            );
        }

        // Rejected CONNECT responses can have a body.
        assert_eq!(
            parse_with_method(
                "\
                 HTTP/1.1 400 Bad Request\r\n\
                 \r\n\
                 ",
                Method::CONNECT
            )
            .decode,
            DecodedLength::CLOSE_DELIMITED
        );

        // 1xx status codes
        parse_ignores(
            "\
             HTTP/1.1 100 Continue\r\n\
             \r\n\
             ",
        );

        parse_ignores(
            "\
             HTTP/1.1 103 Early Hints\r\n\
             \r\n\
             ",
        );

        // 101 upgrade not supported yet
        {
            let msg = parse(
                "\
                 HTTP/1.1 101 Switching Protocols\r\n\
                 \r\n\
                 ",
            );
            assert_eq!(msg.decode, DecodedLength::ZERO);
            assert!(!msg.keep_alive, "should be last");
            assert!(msg.wants_upgrade, "should be upgrade");
        }

        // a close-delimited body is the last of its connection, also when its
        // final transfer coding is not chunked
        for head in [
            "HTTP/1.1 200 OK\r\n\r\n",
            "HTTP/1.1 200 OK\r\ntransfer-encoding: gzip\r\n\r\n",
        ] {
            let msg = parse(head);
            assert_eq!(msg.decode, DecodedLength::CLOSE_DELIMITED, "{head:?}");
            assert!(!msg.keep_alive, "{head:?}");
        }
        assert!(parse("HTTP/1.1 200 OK\r\ntransfer-encoding: gzip, chunked\r\n\r\n").keep_alive);

        // http/1.0
        assert_eq!(
            parse(
                "\
                 HTTP/1.0 200 OK\r\n\
                 \r\n\
                 "
            )
            .decode,
            DecodedLength::CLOSE_DELIMITED
        );

        // 1.0 doesn't understand chunked
        parse_err(
            "\
             HTTP/1.0 200 OK\r\n\
             transfer-encoding: chunked\r\n\
             \r\n\
             ",
        );

        // keep-alive
        assert!(
            parse(
                "\
                 HTTP/1.1 200 OK\r\n\
                 content-length: 0\r\n\
                 \r\n\
                 "
            )
            .keep_alive,
            "HTTP/1.1 keep-alive is default"
        );

        assert!(
            !parse(
                "\
                 HTTP/1.1 200 OK\r\n\
                 content-length: 0\r\n\
                 connection: foo, close, bar\r\n\
                 \r\n\
                 "
            )
            .keep_alive,
            "connection close is always close"
        );

        assert!(
            !parse(
                "\
                 HTTP/1.0 200 OK\r\n\
                 content-length: 0\r\n\
                 \r\n\
                 "
            )
            .keep_alive,
            "HTTP/1.0 close is default"
        );

        assert!(
            parse(
                "\
                 HTTP/1.0 200 OK\r\n\
                 content-length: 0\r\n\
                 connection: foo, keep-alive, bar\r\n\
                 \r\n\
                 "
            )
            .keep_alive,
            "connection keep-alive is always keep-alive"
        );
    }

    #[test]
    fn test_client_obs_fold_line() {
        fn unfold(src: &str) -> String {
            let mut buf = src.as_bytes().to_vec();
            let mut idx = HeaderIndices {
                name: (0, 0),
                value: (0, buf.len()),
            };
            Client::obs_fold_line(&mut buf, &mut idx);
            String::from_utf8(buf[idx.value.0..idx.value.1].to_vec()).unwrap()
        }

        assert_eq!(unfold("a normal line"), "a normal line",);

        assert_eq!(unfold("obs\r\n fold\r\n\t line"), "obs fold line",);
    }

    /// An empty request body never carries a positive Content-Length.
    #[test]
    fn empty_request_bodies_drop_a_positive_content_length() {
        for (length, expected) in [
            ("5", "GET / HTTP/1.1\r\n\r\n"),
            ("0", "GET / HTTP/1.1\r\ncontent-length: 0\r\n\r\n"),
        ] {
            let mut head = MessageHead::default();
            head.headers
                .insert("content-length", HeaderValue::from_static(length));
            let mut vec = Vec::new();
            let encoder = Client::encode(
                Encode {
                    head: EncodeHead {
                        version: head.version,
                        subject: head.subject,
                        headers: head.headers,
                        extensions: &mut head.extensions,
                    },
                    body: None,
                    keep_alive: true,
                    req_method: &mut None,
                    title_case_headers: false,
                    date_header: true,
                    strict_connect_framing: false,
                },
                &mut vec,
            )
            .unwrap();
            assert!(encoder.is_eof(), "{length}");
            assert_eq!(String::from_utf8(vec).unwrap(), expected, "{length}");
        }
    }

    fn encode_request(mut head: MessageHead<RequestLine>, body: BodyLength) -> (Encoder, String) {
        let mut vec = Vec::new();
        let encoder = Client::encode(
            Encode {
                head: EncodeHead {
                    version: head.version,
                    subject: head.subject,
                    headers: head.headers,
                    extensions: &mut head.extensions,
                },
                body: Some(body),
                keep_alive: true,
                req_method: &mut None,
                title_case_headers: false,
                date_header: true,
                strict_connect_framing: false,
            },
            &mut vec,
        )
        .unwrap();
        (encoder, String::from_utf8(vec).unwrap())
    }

    #[test]
    fn empty_request_body_bookkeeping_does_not_invent_framing() {
        for method in [
            Method::GET,
            Method::HEAD,
            Method::DELETE,
            Method::CONNECT,
            Method::POST,
        ] {
            for explicit in [false, true] {
                let mut head: MessageHead<RequestLine> = MessageHead::default();
                head.subject.0 = method.clone();
                if method == Method::CONNECT {
                    head.subject.1 = "https://example.com:443".parse().unwrap();
                } else {
                    head.subject.1 = "/".parse().unwrap();
                }
                if explicit {
                    head.headers
                        .insert(header::CONTENT_LENGTH, HeaderValue::from_static("0"));
                }
                let (encoder, wire) = encode_request(head, BodyLength::Known(0));
                assert!(encoder.is_eof());
                assert_eq!(
                    wire.contains("content-length: 0"),
                    explicit || method == Method::POST,
                    "{wire}"
                );
            }
        }
    }

    const CONTENT_LENGTHS: [&[&str]; 9] = [
        &[],
        &["10"],
        &[""],
        &["abc"],
        &["+10"],
        &["18446744073709551616"],
        &["10", "11"],
        &["10, 11"],
        &["10", "abc"],
    ];

    /// A sent Transfer-Encoding frames the body, so no Content-Length goes along.
    #[test]
    fn client_request_with_transfer_encoding_drops_content_length() {
        for values in CONTENT_LENGTHS {
            for (transfer_encoding, sent) in [("chunked", "chunked"), ("gzip", "gzip, chunked")] {
                for body in [BodyLength::Known(10), BodyLength::Unknown] {
                    let case = format!("{values:?} {transfer_encoding} {body:?}");
                    let mut head = MessageHead::default();
                    for &value in values {
                        head.headers
                            .append("content-length", HeaderValue::from_static(value));
                    }
                    head.headers.insert(
                        "transfer-encoding",
                        HeaderValue::from_static(transfer_encoding),
                    );
                    let (encoder, wire) = encode_request(head, body);
                    assert!(encoder.is_chunked(), "{case}");
                    assert_eq!(
                        wire,
                        format!("GET / HTTP/1.1\r\ntransfer-encoding: {sent}\r\n\r\n"),
                        "{case}"
                    );
                }
            }
        }
    }

    /// A valid list of equal lengths is sent as the one value it stands for.
    #[test]
    fn client_request_sends_a_listed_content_length_as_one_value() {
        for values in [&["10, 10"][..], &["10", "10"], &["10"]] {
            for body in [BodyLength::Known(10), BodyLength::Unknown] {
                let case = format!("{values:?} {body:?}");
                let mut head: MessageHead<RequestLine> = MessageHead::default();
                head.subject.0 = Method::POST;
                for &value in values {
                    head.headers
                        .append("content-length", HeaderValue::from_static(value));
                }
                let (encoder, wire) = encode_request(head, body);
                assert!(!encoder.is_chunked(), "{case}");
                assert_eq!(
                    wire, "POST / HTTP/1.1\r\ncontent-length: 10\r\n\r\n",
                    "{case}"
                );
            }
        }
    }

    /// Whatever frames an unknown body, a Content-Length that cannot is not sent along.
    #[test]
    fn client_request_framing_an_unknown_body_drops_invalid_content_length() {
        let framings = [
            (Method::POST, Version::HTTP_11, "POST / HTTP/1.1\r\n", true),
            (Method::GET, Version::HTTP_11, "GET / HTTP/1.1\r\n", false),
            (Method::POST, Version::HTTP_10, "POST / HTTP/1.0\r\n", false),
        ];
        for values in CONTENT_LENGTHS {
            for (method, version, request_line, chunked) in framings.clone() {
                let case = format!("{values:?} {request_line:?}");
                let mut head = MessageHead {
                    version,
                    subject: RequestLine(method, "/".parse().unwrap()),
                    ..Default::default()
                };
                for &value in values {
                    head.headers
                        .append("content-length", HeaderValue::from_static(value));
                }
                let (encoder, wire) = encode_request(head, BodyLength::Unknown);
                if values == ["10"] {
                    assert!(!encoder.is_chunked() && !encoder.is_eof(), "{case}");
                    assert_eq!(
                        wire,
                        format!("{request_line}content-length: 10\r\n\r\n"),
                        "{case}"
                    );
                } else if chunked {
                    assert!(encoder.is_chunked(), "{case}");
                    assert_eq!(
                        wire,
                        format!("{request_line}transfer-encoding: chunked\r\n\r\n"),
                        "{case}"
                    );
                } else {
                    assert!(encoder.is_eof(), "{case}");
                    assert_eq!(wire, format!("{request_line}\r\n"), "{case}");
                }
            }
        }
    }

    /// A message may carry several `Connection` lines; a `close` on any of them wins.
    #[test]
    fn parse_connection_close_wins_over_any_keep_alive() {
        let cases: &[(&str, &[&str], bool)] = &[
            ("HTTP/1.1", &["close", "keep-alive"], false),
            ("HTTP/1.1", &["keep-alive", "close"], false),
            ("HTTP/1.1", &["foo", "bar"], true),
            ("HTTP/1.0", &["keep-alive", "foo"], true),
            ("HTTP/1.0", &["keep-alive", "close"], false),
            ("HTTP/1.0", &["close", "keep-alive"], false),
            ("HTTP/1.0", &["close, keep-alive"], false),
        ];
        for &(version, lines, keep_alive) in cases {
            let connection: String = lines
                .iter()
                .map(|line| format!("connection: {line}\r\n"))
                .collect();

            let mut request =
                BytesMut::from(format!("GET / {version}\r\n{connection}\r\n").as_str());
            let request = Server::parse(
                &mut request,
                ParseContext {
                    req_method: &mut None,
                    h1_parser_config: Default::default(),
                    h1_max_headers: None,
                    h1_max_header_size: None,
                    h09_responses: false,
                    on_informational: &mut None,
                    prepared_extensions: &mut Some(Extensions::default()),
                },
            )
            .unwrap()
            .unwrap();
            assert_eq!(
                request.keep_alive, keep_alive,
                "request {version} {lines:?}"
            );

            let mut response = BytesMut::from(
                format!("{version} 200 OK\r\ncontent-length: 0\r\n{connection}\r\n").as_str(),
            );
            let response = Client::parse(
                &mut response,
                ParseContext {
                    req_method: &mut Some(Method::GET),
                    h1_parser_config: Default::default(),
                    h1_max_headers: None,
                    h1_max_header_size: None,
                    h09_responses: false,
                    on_informational: &mut None,
                    prepared_extensions: &mut Some(Extensions::default()),
                },
            )
            .unwrap()
            .unwrap();
            assert_eq!(
                response.keep_alive, keep_alive,
                "response {version} {lines:?}"
            );
        }
    }

    #[test]
    fn parse_respects_max_header_size() {
        fn accepted<T>(parsed: &ParseResult<T>, case: &str) -> bool {
            match parsed {
                Ok(Some(_)) => true,
                Err(Parse::TooLarge) => false,
                Ok(None) => panic!("{case}: incomplete"),
                Err(err) => panic!("{case}: {err:?}"),
            }
        }

        let request = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n";
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
        for (head, is_request) in [(request, true), (response, false)] {
            let len = head.len();
            for (max_header_size, expected) in [
                (None, true),
                (Some(len), true),
                (Some(len + 13), true),
                (Some(len - 1), false),
                (Some(10), false),
            ] {
                let case = format!("{head:?} max_header_size = {max_header_size:?}");
                let ctx = ParseContext {
                    req_method: &mut Some(Method::GET),
                    h1_parser_config: Default::default(),
                    h1_max_headers: None,
                    h1_max_header_size: max_header_size,
                    h09_responses: false,
                    on_informational: &mut None,
                    prepared_extensions: &mut Some(Extensions::default()),
                };
                let mut bytes = BytesMut::from(head);
                let parsed = if is_request {
                    accepted(&Server::parse(&mut bytes, ctx), &case)
                } else {
                    accepted(&Client::parse(&mut bytes, ctx), &case)
                };
                assert_eq!(parsed, expected, "{case}");
            }
        }
    }

    /// An HTTP/1 CONNECT names `host:port` and is never an Extended CONNECT, whose HTTP/1.1
    /// form is an `Upgrade` request: neither falls back to some other target on the wire.
    #[test]
    fn client_connect_refuses_targets_http1_cannot_name() {
        for (uri, protocol, accepted) in [
            ("https://example.test:443", false, true),
            ("https://example.test", false, false),
            ("https://example.test:443/chat", true, false),
        ] {
            let mut head = MessageHead {
                subject: RequestLine(Method::CONNECT, uri.parse().unwrap()),
                ..Default::default()
            };
            if protocol {
                head.extensions
                    .insert(rama_http_types::proto::ext::Protocol::WEBSOCKET);
            }
            let mut vec = Vec::new();
            let encoded = Client::encode(
                Encode {
                    head: EncodeHead {
                        version: head.version,
                        subject: head.subject,
                        headers: head.headers,
                        extensions: &mut head.extensions,
                    },
                    body: None,
                    keep_alive: true,
                    req_method: &mut None,
                    title_case_headers: false,
                    date_header: true,
                    strict_connect_framing: false,
                },
                &mut vec,
            );
            assert_eq!(encoded.is_ok(), accepted, "{uri} {protocol}");
        }
    }

    #[test]
    fn test_client_request_encode_title_case() {
        use rama_http_types::header::HeaderValue;

        use crate::proto::BodyLength;

        let mut head = MessageHead::default();
        head.headers
            .insert("content-length", HeaderValue::from_static("10"));
        head.headers
            .insert("content-type", HeaderValue::from_static("application/json"));
        head.headers.insert("*-*", HeaderValue::from_static("o_o"));

        let mut vec = Vec::new();
        Client::encode(
            Encode {
                head: EncodeHead {
                    version: head.version,
                    subject: head.subject,
                    headers: head.headers,
                    extensions: &mut head.extensions,
                },
                body: Some(BodyLength::Known(10)),
                keep_alive: true,
                req_method: &mut None,
                title_case_headers: true,
                date_header: true,
                strict_connect_framing: false,
            },
            &mut vec,
        )
        .unwrap();

        assert_eq!(vec, b"GET / HTTP/1.1\r\nContent-Length: 10\r\nContent-Type: application/json\r\n*-*: o_o\r\n\r\n".to_vec());
    }

    /// `RequestHeaders` holds the head as written: here with the repaired `Host`
    /// and the `content-length` the encoder added.
    #[test]
    fn request_headers_record_the_head_as_sent() {
        use crate::proto::BodyLength;

        let mut head: MessageHead<RequestLine> = MessageHead::default();
        head.subject.1 = "http://example.com/p".parse().unwrap();
        head.headers
            .insert("host", HeaderValue::from_static("not a host"));
        head.headers.insert("x-a", HeaderValue::from_static("1"));
        let mut wire = Vec::new();
        Client::encode(
            Encode {
                head: EncodeHead {
                    version: head.version,
                    subject: head.subject,
                    headers: head.headers,
                    extensions: &mut head.extensions,
                },
                body: Some(BodyLength::Known(5)),
                keep_alive: true,
                req_method: &mut None,
                title_case_headers: false,
                date_header: false,
                strict_connect_framing: false,
            },
            &mut wire,
        )
        .unwrap();

        let recorded = head.extensions.get_ref::<RequestHeaders>().unwrap();
        let mut fields = Vec::new();
        for (name, value) in recorded.ordered_iter() {
            fields.extend_from_slice(name.as_str().as_bytes());
            fields.extend_from_slice(b": ");
            fields.extend_from_slice(value.as_bytes());
            fields.extend_from_slice(b"\r\n");
        }
        let head_end = wire.windows(4).position(|w| w == b"\r\n\r\n").unwrap() + 2;
        let line_end = wire.windows(2).position(|w| w == b"\r\n").unwrap() + 2;
        assert_eq!(fields, &wire[line_end..head_end]);
        assert_eq!(recorded.get("host").unwrap(), "example.com");
        assert_eq!(recorded.get("content-length").unwrap(), "5");
    }

    #[test]
    fn test_client_request_encode_orig_case() {
        use rama_http_types::header::HeaderValue;

        use crate::proto::BodyLength;

        let mut head = MessageHead::default();
        head.headers
            .insert("CONTENT-LENGTH", HeaderValue::from_static("10"));
        head.headers
            .insert("content-type", HeaderValue::from_static("application/json"));
        let mut vec = Vec::new();
        Client::encode(
            Encode {
                head: EncodeHead {
                    version: head.version,
                    subject: head.subject,
                    headers: head.headers,
                    extensions: &mut head.extensions,
                },
                body: Some(BodyLength::Known(10)),
                keep_alive: true,
                req_method: &mut None,
                title_case_headers: false,
                date_header: true,
                strict_connect_framing: false,
            },
            &mut vec,
        )
        .unwrap();

        assert_eq!(
            &*vec,
            b"GET / HTTP/1.1\r\nCONTENT-LENGTH: 10\r\ncontent-type: application/json\r\n\r\n"
                .as_ref(),
        );
    }
    #[test]
    fn test_client_request_encode_orig_and_title_case() {
        use rama_http_types::header::HeaderValue;

        use crate::proto::BodyLength;

        let mut head = MessageHead::default();
        head.headers
            .insert("CONTENT-LENGTH", HeaderValue::from_static("10"));
        head.headers
            .insert("content-type", HeaderValue::from_static("application/json"));
        let mut vec = Vec::new();
        Client::encode(
            Encode {
                head: EncodeHead {
                    version: head.version,
                    subject: head.subject,
                    headers: head.headers,
                    extensions: &mut head.extensions,
                },
                body: Some(BodyLength::Known(10)),
                keep_alive: true,
                req_method: &mut None,
                title_case_headers: true,
                date_header: true,
                strict_connect_framing: false,
            },
            &mut vec,
        )
        .unwrap();

        assert_eq!(
            &*vec,
            b"GET / HTTP/1.1\r\nCONTENT-LENGTH: 10\r\nContent-Type: application/json\r\n\r\n"
                .as_ref(),
        );
    }

    #[test]
    fn connection_nominated_trailers_are_not_encoded() {
        use rama_http_types::header::{CONNECTION, HeaderValue, TRAILER};

        use crate::proto::BodyLength;

        fn headers() -> HeaderMap {
            HeaderMap::from_iter([
                (CONNECTION, HeaderValue::from_static(" keep-alive,\tX-Hop ")),
                (TRAILER, HeaderValue::from_static("x-hop")),
            ])
        }

        fn trailers() -> HeaderMap {
            HeaderMap::from_iter([(
                HeaderName::from_static("x-hop"),
                HeaderValue::from_static("late"),
            )])
        }

        let mut client_head = MessageHead {
            headers: headers(),
            ..Default::default()
        };
        let mut encoded = Vec::new();
        let client_encoder = Client::encode(
            Encode {
                head: EncodeHead {
                    version: client_head.version,
                    subject: client_head.subject,
                    headers: client_head.headers,
                    extensions: &mut client_head.extensions,
                },
                body: Some(BodyLength::Unknown),
                keep_alive: true,
                req_method: &mut None,
                title_case_headers: false,
                date_header: false,
                strict_connect_framing: false,
            },
            &mut encoded,
        )
        .unwrap();
        assert!(
            client_encoder
                .encode_trailers::<&[u8]>(&trailers(), false)
                .is_none()
        );

        let mut server_head = MessageHead {
            headers: headers(),
            ..Default::default()
        };
        encoded.clear();
        let server_encoder = Server::encode(
            Encode {
                head: EncodeHead {
                    version: server_head.version,
                    subject: server_head.subject,
                    headers: server_head.headers,
                    extensions: &mut server_head.extensions,
                },
                body: Some(BodyLength::Unknown),
                keep_alive: true,
                req_method: &mut None,
                title_case_headers: false,
                date_header: false,
                strict_connect_framing: false,
            },
            &mut encoded,
        )
        .unwrap();
        assert!(
            server_encoder
                .encode_trailers::<&[u8]>(&trailers(), false)
                .is_none()
        );
    }

    // Unknown response lengths must retain the framing appropriate to the
    // response version. Connection: close controls reuse, not chunking.
    #[test]
    fn server_response_framing_for_version_and_length() {
        use crate::proto::BodyLength;

        for version in [Version::HTTP_10, Version::HTTP_11] {
            for known_length in [false, true] {
                for close in [false, true] {
                    let mut head = MessageHead {
                        version,
                        ..MessageHead::default()
                    };
                    if close {
                        head.headers
                            .insert(header::CONNECTION, HeaderValue::from_static("close"));
                    }
                    let mut bytes = Vec::new();
                    let encoder = Server::encode(
                        Encode {
                            head: EncodeHead {
                                version: head.version,
                                subject: head.subject,
                                headers: head.headers,
                                extensions: &mut head.extensions,
                            },
                            body: Some(if known_length {
                                BodyLength::Known(4)
                            } else {
                                BodyLength::Unknown
                            }),
                            keep_alive: !close,
                            req_method: &mut Some(Method::POST),
                            title_case_headers: false,
                            date_header: false,
                            strict_connect_framing: false,
                        },
                        &mut bytes,
                    )
                    .unwrap();
                    let wire = String::from_utf8(bytes).unwrap().to_ascii_lowercase();
                    let expected = if known_length {
                        Encoder::length(4)
                    } else if version == Version::HTTP_10 {
                        Encoder::close_delimited()
                    } else {
                        Encoder::chunked()
                    }
                    .with_nominated_fields(if close {
                        [HeaderName::from_static("close")].into_iter().collect()
                    } else {
                        Default::default()
                    })
                    .set_last(close);
                    assert_eq!(
                        encoder, expected,
                        "{version:?}, known={known_length}, close={close}"
                    );
                    assert!(
                        wire.starts_with(&format!("{version:?} 200 OK\r\n").to_ascii_lowercase())
                    );
                    assert_eq!(
                        wire.contains("transfer-encoding: chunked\r\n"),
                        encoder.is_chunked()
                    );
                    assert_eq!(wire.contains("content-length: 4\r\n"), known_length);
                    assert_eq!(wire.contains("connection: close\r\n"), close);
                }
            }
        }
    }

    fn encode_close_delimited_test_response(
        mut head: MessageHead<StatusCode>,
        body: Option<BodyLength>,
        method: Method,
    ) -> crate::Result<(Encoder, Vec<u8>)> {
        let mut wire = Vec::new();
        let encoder = Server::encode(
            Encode {
                head: EncodeHead {
                    version: head.version,
                    subject: head.subject,
                    headers: head.headers,
                    extensions: &mut head.extensions,
                },
                body,
                keep_alive: true,
                req_method: &mut Some(method),
                title_case_headers: false,
                date_header: false,
                strict_connect_framing: false,
            },
            &mut wire,
        )?;
        Ok((encoder, wire))
    }

    #[test]
    fn empty_responses_preserve_explicit_zero_length_spelling_and_position() {
        for version in [Version::HTTP_10, Version::HTTP_11] {
            for name in ["Content-Length", "cOnTeNt-LeNgTh"] {
                for value in ["0", "00"] {
                    for body in [None, Some(BodyLength::Known(0)), Some(BodyLength::Unknown)] {
                        let mut head = MessageHead {
                            version,
                            ..MessageHead::default()
                        };
                        head.headers
                            .append("X-Before", HeaderValue::from_static("first"));
                        head.headers.append(name, HeaderValue::from_static(value));
                        head.headers
                            .append("X-After", HeaderValue::from_static("last"));
                        let (encoder, wire) =
                            encode_close_delimited_test_response(head, body, Method::GET).unwrap();
                        let wire = String::from_utf8(wire).unwrap();
                        let fields =
                            format!("X-Before: first\r\n{name}: {value}\r\nX-After: last\r\n");
                        assert!(wire.contains(&fields), "{version:?}: {wire}");
                        assert_eq!(
                            wire.to_ascii_lowercase().matches("content-length:").count(),
                            1
                        );
                        assert!(encoder.is_eof());
                    }
                }
            }
        }
    }

    #[test]
    fn server_normalizes_identical_content_lengths() {
        for version in [Version::HTTP_10, Version::HTTP_11] {
            for preference in [false, true] {
                for values in [
                    &["4", "4"][..],
                    &["04", "4", "004"][..],
                    &["4, 4"][..],
                    &["4, 04", "004"][..],
                ] {
                    for (method, body, expected_length) in [
                        (Method::GET, Some(BodyLength::Unknown), 4),
                        (Method::GET, Some(BodyLength::Known(4)), 4),
                        (Method::HEAD, None, 0),
                        (Method::HEAD, Some(BodyLength::Known(0)), 0),
                    ] {
                        let mut head = MessageHead {
                            version,
                            ..MessageHead::default()
                        };
                        if preference {
                            head.extensions.insert(CloseDelimitedResponse);
                        }
                        for value in values {
                            head.headers
                                .append("Content-Length", HeaderValue::from_static(value));
                            head.headers
                                .insert("x-between", HeaderValue::from_static("kept"));
                        }
                        let (encoder, wire) =
                            encode_close_delimited_test_response(head, body, method).unwrap();
                        assert_eq!(encoder, Encoder::length(expected_length));
                        let wire = String::from_utf8(wire).unwrap().to_ascii_lowercase();
                        assert_eq!(wire.matches("content-length:").count(), 1, "{wire}");
                        assert!(wire.contains("content-length: 4\r\n"), "{wire}");
                        assert!(wire.contains("x-between: kept\r\n"), "{wire}");
                        assert!(!wire.contains("transfer-encoding:"));
                        assert!(!wire.contains("connection: close"));
                    }
                }
            }
        }
    }

    #[test]
    fn server_rejects_invalid_or_conflicting_content_lengths_without_output() {
        for values in [
            &["4", "5"][..],
            &["4", ""][..],
            &["4", "+4"][..],
            &["4", "four"][..],
            &["4", "18446744073709551616"][..],
            &["4, 5"][..],
            &["4, "][..],
            &[",4"][..],
            &["4, 4", "5"][..],
        ] {
            for reverse in [false, true] {
                for preference in [false, true] {
                    for body in [Some(BodyLength::Unknown), Some(BodyLength::Known(4))] {
                        let mut head = MessageHead::default();
                        if preference {
                            head.extensions.insert(CloseDelimitedResponse);
                        }
                        let mut values = values.to_vec();
                        if reverse {
                            values.reverse();
                        }
                        for value in values {
                            head.headers
                                .append(header::CONTENT_LENGTH, HeaderValue::from_static(value));
                        }
                        let mut wire = b"previous response".to_vec();
                        let error = Server::encode(
                            Encode {
                                head: EncodeHead {
                                    version: head.version,
                                    subject: head.subject,
                                    headers: head.headers,
                                    extensions: &mut head.extensions,
                                },
                                body,
                                keep_alive: true,
                                req_method: &mut Some(Method::GET),
                                title_case_headers: false,
                                date_header: false,
                                strict_connect_framing: false,
                            },
                            &mut wire,
                        )
                        .unwrap_err();
                        assert_matches!(
                            error.kind(),
                            crate::error::Kind::User(crate::error::User::UnexpectedHeader),
                        );
                        assert_eq!(wire, b"previous response");
                    }
                }
            }
        }
    }

    #[test]
    fn normalized_content_length_still_conflicts_with_transfer_encoding() {
        for transfer_encoding_first in [false, true] {
            for body in [Some(BodyLength::Unknown), Some(BodyLength::Known(4))] {
                let mut head = MessageHead::default();
                head.extensions.insert(CloseDelimitedResponse);
                if transfer_encoding_first {
                    head.headers.insert(
                        header::TRANSFER_ENCODING,
                        HeaderValue::from_static("chunked"),
                    );
                }
                for _ in 0..2 {
                    head.headers
                        .append(header::CONTENT_LENGTH, HeaderValue::from_static("4"));
                }
                if !transfer_encoding_first {
                    head.headers.insert(
                        header::TRANSFER_ENCODING,
                        HeaderValue::from_static("chunked"),
                    );
                }
                let error =
                    encode_close_delimited_test_response(head, body, Method::GET).unwrap_err();
                assert_matches!(
                    error.kind(),
                    crate::error::Kind::User(crate::error::User::UnexpectedHeader),
                );
            }
        }
    }

    #[test]
    fn explicit_close_delimited_response_overrides_size_hint_and_keep_alive() {
        for version in [Version::HTTP_10, Version::HTTP_11] {
            for body in [
                None,
                Some(BodyLength::Known(0)),
                Some(BodyLength::Known(4)),
                Some(BodyLength::Unknown),
            ] {
                let mut head = MessageHead {
                    version,
                    ..MessageHead::default()
                };
                head.extensions.insert(CloseDelimitedResponse);
                head.headers
                    .insert(header::CONNECTION, HeaderValue::from_static("keep-alive"));
                let (encoder, wire) =
                    encode_close_delimited_test_response(head, body, Method::GET).unwrap();
                assert_eq!(encoder, Encoder::close_delimited().set_last(true));
                assert_eq!(
                    wire,
                    format!("{version:?} 200 OK\r\nconnection: close\r\n\r\n").as_bytes()
                );
            }
        }
    }

    #[test]
    fn explicit_headers_override_close_delimited_preference() {
        for (name, value, expected) in [
            (header::CONTENT_LENGTH, "4", Encoder::length(4)),
            (header::TRANSFER_ENCODING, "chunked", Encoder::chunked()),
            (header::TRANSFER_ENCODING, "gzip", Encoder::chunked()),
        ] {
            let mut head = MessageHead::default();
            head.extensions.insert(CloseDelimitedResponse);
            head.headers
                .insert(name.clone(), HeaderValue::from_static(value));
            let (encoder, wire) =
                encode_close_delimited_test_response(head, Some(BodyLength::Unknown), Method::GET)
                    .unwrap();
            assert_eq!(encoder, expected);
            let wire = String::from_utf8(wire).unwrap();
            assert!(wire.contains(&format!("{name}: {value}")));
            assert!(!wire.contains("connection: close"));
        }
        let mut head = MessageHead::default();
        head.extensions.insert(CloseDelimitedResponse);
        head.headers
            .insert(header::TRAILER, HeaderValue::from_static("checksum"));
        let (encoder, wire) =
            encode_close_delimited_test_response(head, Some(BodyLength::Unknown), Method::GET)
                .unwrap();
        assert!(encoder.is_chunked());
        assert!(!encoder.is_last());
        assert!(
            String::from_utf8(wire)
                .unwrap()
                .contains("trailer: checksum\r\n")
        );
    }

    #[test]
    fn close_delimited_preference_does_not_hide_invalid_content_length() {
        let mut head = MessageHead::default();
        head.extensions.insert(CloseDelimitedResponse);
        head.headers
            .insert(header::CONTENT_LENGTH, HeaderValue::from_static("invalid"));
        encode_close_delimited_test_response(head, Some(BodyLength::Unknown), Method::GET)
            .unwrap_err();
    }

    #[test]
    fn close_delimited_directive_does_not_change_bodyless_responses() {
        for (method, status) in [
            (Method::HEAD, StatusCode::OK),
            (Method::GET, StatusCode::NO_CONTENT),
            (Method::GET, StatusCode::NOT_MODIFIED),
            (Method::CONNECT, StatusCode::OK),
            (Method::GET, StatusCode::SWITCHING_PROTOCOLS),
        ] {
            let baseline = MessageHead {
                subject: status,
                ..MessageHead::default()
            };
            let marked = MessageHead {
                subject: status,
                ..MessageHead::default()
            };
            marked.extensions.insert(CloseDelimitedResponse);
            assert_eq!(
                encode_close_delimited_test_response(baseline, None, method.clone()).unwrap(),
                encode_close_delimited_test_response(marked, None, method).unwrap(),
            );
        }
    }

    #[test]
    fn close_delimited_preference_is_inherited_but_explicit_headers_win() {
        let context = Extensions::new();
        context.insert(CloseDelimitedResponse);
        for extensions in [context.fork(), context.fork().fork()] {
            for explicit_length in [false, true] {
                let mut head = MessageHead {
                    extensions: extensions.clone(),
                    ..MessageHead::default()
                };
                if explicit_length {
                    head.headers
                        .insert(header::CONTENT_LENGTH, HeaderValue::from_static("4"));
                }
                let (encoder, wire) = encode_close_delimited_test_response(
                    head,
                    Some(BodyLength::Unknown),
                    Method::GET,
                )
                .unwrap();
                assert_eq!(
                    encoder,
                    if explicit_length {
                        Encoder::length(4)
                    } else {
                        Encoder::close_delimited().set_last(true)
                    }
                );
                assert_eq!(
                    String::from_utf8(wire)
                        .unwrap()
                        .contains("connection: close\r\n"),
                    !explicit_length
                );
            }
        }
    }

    #[test]
    fn original_response_framing_is_recorded_and_overrides_inherited_metadata() {
        use rama_http_types::proto::h1::ext::OriginalResponseBodyFraming as Framing;
        for (version, method, status, headers, expected) in [
            ("1.0", Method::GET, "200 OK", "", Framing::CloseDelimited),
            ("1.1", Method::GET, "200 OK", "", Framing::CloseDelimited),
            (
                "1.1",
                Method::GET,
                "200 OK",
                "Connection: close\r\n",
                Framing::CloseDelimited,
            ),
            (
                "1.1",
                Method::GET,
                "200 OK",
                "Content-Length: 0\r\n",
                Framing::ContentLength,
            ),
            (
                "1.1",
                Method::GET,
                "200 OK",
                "Content-Length: 4\r\n",
                Framing::ContentLength,
            ),
            (
                "1.1",
                Method::GET,
                "200 OK",
                "Transfer-Encoding: chunked\r\n",
                Framing::TransferEncoded,
            ),
            (
                "1.1",
                Method::GET,
                "200 OK",
                "Transfer-Encoding: gzip\r\n",
                Framing::TransferEncoded,
            ),
            (
                "1.1",
                Method::HEAD,
                "200 OK",
                "Content-Length: 4\r\n",
                Framing::Empty,
            ),
            ("1.1", Method::GET, "204 No Content", "", Framing::Empty),
            ("1.1", Method::GET, "304 Not Modified", "", Framing::Empty),
            ("1.1", Method::CONNECT, "200 OK", "", Framing::Empty),
            (
                "1.1",
                Method::GET,
                "101 Switching Protocols",
                "",
                Framing::Empty,
            ),
        ] {
            let inherited = Extensions::new();
            inherited.insert(if expected == Framing::CloseDelimited {
                Framing::Empty
            } else {
                Framing::CloseDelimited
            });
            let mut raw =
                BytesMut::from(format!("HTTP/{version} {status}\r\n{headers}\r\n").as_bytes());
            let msg = Client::parse(
                &mut raw,
                ParseContext {
                    req_method: &mut Some(method),
                    h1_parser_config: Default::default(),
                    h1_max_headers: None,
                    h1_max_header_size: None,
                    h09_responses: false,
                    on_informational: &mut None,
                    prepared_extensions: &mut Some(inherited.fork()),
                },
            )
            .unwrap()
            .unwrap();
            assert_eq!(
                msg.head.extensions.self_get_ref::<Framing>(),
                Some(&expected)
            );
            assert_eq!(msg.head.extensions.get_ref::<Framing>(), Some(&expected));
        }
    }

    fn parse_framed_response(
        wire: &str,
        method: Method,
    ) -> Result<ParsedMessage<StatusCode>, Parse> {
        Client::parse(
            &mut BytesMut::from(wire.as_bytes()),
            ParseContext {
                req_method: &mut Some(method),
                h1_parser_config: Default::default(),
                h1_max_headers: None,
                h1_max_header_size: None,
                h09_responses: false,
                on_informational: &mut None,
                prepared_extensions: &mut None,
            },
        )
        .map(|parsed| parsed.expect("complete response head"))
    }

    #[test]
    fn chunked_cannot_repeat_across_request_or_response_field_lines() {
        for fields in [
            "Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n",
            "Transfer-Encoding: gzip, ChUnKeD\r\nTransfer-Encoding: \tchunked \t\r\n",
            "Transfer-Encoding: chunked, gzip\r\nTransfer-Encoding: br, chunked\r\n",
            "Transfer-Encoding: gzip\r\nTransfer-Encoding: chunked, chunked\r\n",
        ] {
            let request = format!("POST / HTTP/1.1\r\nHost: example.test\r\n{fields}\r\n");
            let parsed = Server::parse(
                &mut BytesMut::from(request.as_bytes()),
                ParseContext {
                    req_method: &mut None,
                    h1_parser_config: Default::default(),
                    h1_max_headers: None,
                    h1_max_header_size: None,
                    h09_responses: false,
                    on_informational: &mut None,
                    prepared_extensions: &mut None,
                },
            );
            assert!(
                parsed.is_err(),
                "request accepted repeated coding: {fields:?}"
            );
            assert!(
                parse_framed_response(&format!("HTTP/1.1 200 OK\r\n{fields}\r\n"), Method::GET,)
                    .is_err(),
                "response accepted repeated coding: {fields:?}"
            );
        }

        // Repeated field lines are legal when only the final coding is chunked.
        let parsed = parse_framed_response(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n",
            Method::GET,
        )
        .unwrap();
        assert_eq!(parsed.decode, DecodedLength::CHUNKED);
    }

    #[expect(
        clippy::option_option,
        reason = "test matrix distinguishes absent and unknown-length bodies"
    )]
    fn encode_framing(
        method: Method,
        status: u16,
        version: Version,
        fields: &[(&'static str, &'static str)],
        body: Option<Option<u64>>,
        strict_connect_framing: bool,
    ) -> crate::Result<(Vec<String>, Encoder)> {
        // `None` is no body, `Some(None)` one of unknown length.
        let body = body.map(|len| len.map_or(BodyLength::Unknown, BodyLength::Known));
        let mut head = MessageHead {
            version,
            subject: StatusCode::from_u16(status).unwrap(),
            ..MessageHead::default()
        };
        for (name, value) in fields {
            head.headers.append(*name, HeaderValue::from_static(value));
        }
        let mut bytes = Vec::new();
        let encoder = Server::encode(
            Encode {
                head: EncodeHead {
                    version: head.version,
                    subject: head.subject,
                    headers: head.headers,
                    extensions: &mut head.extensions,
                },
                body,
                keep_alive: true,
                req_method: &mut Some(method),
                title_case_headers: false,
                date_header: false,
                strict_connect_framing,
            },
            &mut bytes,
        )?;
        let lines = String::from_utf8(bytes)
            .unwrap()
            .lines()
            .skip(1)
            .filter(|line| !line.is_empty())
            .map(str::to_ascii_lowercase)
            .collect();
        Ok((lines, encoder))
    }

    const FRAMING_FIELDS: [&[(&str, &str)]; 5] = [
        &[],
        &[("content-length", "0")],
        &[("content-length", "5")],
        &[("transfer-encoding", "chunked")],
        &[
            ("content-length", "5"),
            ("transfer-encoding", "gzip, chunked"),
        ],
    ];

    #[expect(
        clippy::option_option,
        reason = "test matrix distinguishes absent and unknown-length bodies"
    )]
    const BODIES: [Option<Option<u64>>; 4] = [None, Some(Some(0)), Some(Some(5)), Some(None)];

    fn has_framing(lines: &[String]) -> bool {
        lines.iter().any(|line| {
            line.starts_with("content-length:") || line.starts_with("transfer-encoding:")
        })
    }

    fn lines_named<'a>(lines: &'a [String], name: &str) -> Vec<&'a str> {
        lines
            .iter()
            .filter(|line| line.starts_with(name))
            .map(String::as_str)
            .collect()
    }

    #[test]
    fn descriptive_transfer_encoding_wins_over_content_length() {
        for (method, status) in [(Method::HEAD, 200), (Method::GET, 304)] {
            for body in BODIES {
                let case = format!("{method} {status} {body:?}");
                let (lines, encoder) = encode_framing(
                    method.clone(),
                    status,
                    Version::HTTP_11,
                    &[
                        ("transfer-encoding", "gzip"),
                        ("transfer-encoding", "chunked"),
                    ],
                    body,
                    false,
                )
                .unwrap();
                assert!(encoder.is_eof(), "{case}");
                assert!(lines_named(&lines, "content-length:").is_empty(), "{case}");
                assert_eq!(
                    lines_named(&lines, "transfer-encoding:"),
                    ["transfer-encoding: gzip, chunked"],
                    "{case}"
                );
                for fields in [
                    [("transfer-encoding", "chunked"), ("content-length", "5")],
                    [("content-length", "5"), ("transfer-encoding", "chunked")],
                ] {
                    let (lines, encoder) = encode_framing(
                        method.clone(),
                        status,
                        Version::HTTP_11,
                        &fields,
                        body,
                        false,
                    )
                    .unwrap();
                    assert!(encoder.is_eof(), "{case}");
                    assert!(lines_named(&lines, "content-length:").is_empty(), "{case}");
                    assert_eq!(
                        lines_named(&lines, "transfer-encoding:"),
                        ["transfer-encoding: chunked"],
                        "{case}"
                    );
                }
            }
        }
    }

    #[test]
    fn a_described_coding_ends_in_chunked_as_the_get_would() {
        let (lines, _) = encode_framing(
            Method::HEAD,
            200,
            Version::HTTP_11,
            &[("transfer-encoding", "gzip")],
            None,
            false,
        )
        .unwrap();
        assert_eq!(
            lines_named(&lines, "transfer-encoding:"),
            ["transfer-encoding: gzip, chunked"]
        );
    }

    #[test]
    fn codings_over_several_lines_frame_a_body() {
        for body in [Some(None), Some(Some(5))] {
            let (lines, encoder) = encode_framing(
                Method::GET,
                200,
                Version::HTTP_11,
                &[
                    ("transfer-encoding", "gzip"),
                    ("x-between", "1"),
                    ("transfer-encoding", "chunked"),
                ],
                body,
                false,
            )
            .unwrap();
            assert_eq!(
                lines_named(&lines, "transfer-encoding:"),
                ["transfer-encoding: gzip, chunked"],
                "{body:?}"
            );
            assert!(!encoder.is_eof(), "{body:?}: a chunked body follows");
        }
    }

    #[test]
    fn a_content_length_the_body_does_not_have_is_corrected() {
        for (declared, known) in [("3", 5), ("9", 5), ("not-a-number", 5)] {
            let fields: &'static [(&'static str, &'static str)] = match declared {
                "3" => &[("content-length", "3")],
                "9" => &[("content-length", "9")],
                _ => &[("content-length", "not-a-number")],
            };
            let (lines, encoder) = encode_framing(
                Method::GET,
                200,
                Version::HTTP_11,
                fields,
                Some(Some(known)),
                false,
            )
            .unwrap();
            assert_eq!(
                lines_named(&lines, "content-length:"),
                ["content-length: 5"],
                "declared {declared}"
            );
            assert!(!encoder.is_eof());
        }
    }

    #[test]
    fn connect_2xx_drops_framing_fields_and_opens_the_tunnel() {
        for status in [200, 204, 299] {
            for fields in FRAMING_FIELDS {
                for body in BODIES {
                    let case = format!("{status} {fields:?} {body:?}");
                    let (lines, encoder) = encode_framing(
                        Method::CONNECT,
                        status,
                        Version::HTTP_11,
                        fields,
                        body,
                        false,
                    )
                    .unwrap_or_else(|err| panic!("{case}: {err}"));
                    assert!(!has_framing(&lines), "{case}: {lines:?}");
                    assert!(encoder.is_last(), "{case}");
                    assert!(encoder.is_eof(), "{case}: a tunnel follows, no body");
                }
            }
        }
    }

    #[test]
    fn connect_2xx_framing_fields_fail_when_strict() {
        for fields in &FRAMING_FIELDS[1..] {
            let result = encode_framing(Method::CONNECT, 200, Version::HTTP_11, fields, None, true);
            assert!(result.is_err(), "{fields:?}");
        }
        let (lines, _) =
            encode_framing(Method::CONNECT, 200, Version::HTTP_11, &[], None, true).unwrap();
        assert!(!has_framing(&lines));
    }

    #[test]
    fn rejected_connect_keeps_its_framing() {
        let (lines, encoder) = encode_framing(
            Method::CONNECT,
            407,
            Version::HTTP_11,
            &[("content-length", "5")],
            Some(Some(5)),
            true,
        )
        .unwrap();
        assert!(lines.contains(&"content-length: 5".to_owned()), "{lines:?}");
        assert!(!encoder.is_eof());
    }

    #[test]
    fn no_content_drops_content_length() {
        for body in BODIES {
            let (lines, encoder) = encode_framing(
                Method::GET,
                204,
                Version::HTTP_11,
                &[("content-length", "10"), ("transfer-encoding", "chunked")],
                body,
                false,
            )
            .unwrap();
            assert!(!has_framing(&lines), "{body:?}: {lines:?}");
            assert!(encoder.is_eof(), "{body:?}");
        }
    }

    #[test]
    fn not_modified_keeps_its_declared_content_length() {
        for body in [None, Some(Some(0))] {
            let (lines, encoder) = encode_framing(
                Method::GET,
                304,
                Version::HTTP_11,
                &[("content-length", "1234")],
                body,
                false,
            )
            .unwrap();
            assert!(
                lines.contains(&"content-length: 1234".to_owned()),
                "{body:?}: {lines:?}"
            );
            assert!(encoder.is_eof(), "{body:?}");
        }
        let (lines, _) =
            encode_framing(Method::GET, 304, Version::HTTP_11, &[], None, false).unwrap();
        assert!(!has_framing(&lines), "never invented: {lines:?}");
    }

    #[test]
    fn head_content_length_is_never_invented() {
        for (fields, body, expected) in [
            (&[][..], None, None),
            (&[][..], Some(Some(0)), None),
            (&[][..], Some(Some(42)), Some("content-length: 42")),
            (&[][..], Some(None), None),
            (
                &[("content-length", "99")][..],
                None,
                Some("content-length: 99"),
            ),
            (
                &[("content-length", "99")][..],
                Some(Some(0)),
                Some("content-length: 99"),
            ),
        ] {
            let (lines, encoder) =
                encode_framing(Method::HEAD, 200, Version::HTTP_11, fields, body, false).unwrap();
            let length: Vec<_> = lines
                .iter()
                .filter(|line| line.starts_with("content-length:"))
                .collect();
            match expected {
                Some(expected) => assert_eq!(length, [expected], "{fields:?} {body:?}"),
                None => assert!(length.is_empty(), "{fields:?} {body:?}: {lines:?}"),
            }
            assert!(encoder.is_eof(), "{fields:?} {body:?}");
        }
    }

    #[test]
    fn head_and_not_modified_keep_the_transfer_coding_a_get_would_use() {
        for (method, status) in [(Method::HEAD, 200), (Method::GET, 304)] {
            let (lines, encoder) = encode_framing(
                method.clone(),
                status,
                Version::HTTP_11,
                &[("transfer-encoding", "gzip, chunked")],
                None,
                false,
            )
            .unwrap();
            assert!(
                lines.contains(&"transfer-encoding: gzip, chunked".to_owned()),
                "{method} {status}: {lines:?}"
            );
            assert!(encoder.is_eof(), "{method} {status}");

            let (lines, _) = encode_framing(
                method,
                status,
                Version::HTTP_10,
                &[("transfer-encoding", "chunked")],
                None,
                false,
            )
            .unwrap();
            assert!(
                !has_framing(&lines),
                "an HTTP/1.0 peer knows no coding: {lines:?}"
            );
        }
    }

    #[test]
    fn test_server_encode_connect_method() {
        let mut head = MessageHead::default();

        let mut vec = Vec::new();
        let encoder = Server::encode(
            Encode {
                head: EncodeHead {
                    version: head.version,
                    subject: head.subject,
                    headers: head.headers,
                    extensions: &mut head.extensions,
                },
                body: None,
                keep_alive: true,
                req_method: &mut Some(Method::CONNECT),
                title_case_headers: false,
                date_header: true,
                strict_connect_framing: false,
            },
            &mut vec,
        )
        .unwrap();

        assert!(encoder.is_last());
    }

    #[test]
    fn test_server_response_encode_title_case() {
        use rama_http_types::header::HeaderValue;

        use crate::proto::BodyLength;

        let mut head = MessageHead::default();
        head.headers
            .insert("content-length", HeaderValue::from_static("10"));
        head.headers
            .insert("content-type", HeaderValue::from_static("application/json"));
        head.headers
            .insert("weird--header", HeaderValue::from_static(""));

        let mut vec = Vec::new();
        Server::encode(
            Encode {
                head: EncodeHead {
                    version: head.version,
                    subject: head.subject,
                    headers: head.headers,
                    extensions: &mut head.extensions,
                },
                body: Some(BodyLength::Known(10)),
                keep_alive: true,
                req_method: &mut None,
                title_case_headers: true,
                date_header: true,
                strict_connect_framing: false,
            },
            &mut vec,
        )
        .unwrap();

        let expected_response =
            b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\nContent-Type: application/json\r\nWeird--Header: \r\n";

        assert_eq!(&vec[..expected_response.len()], &expected_response[..]);
    }

    #[test]
    fn test_server_response_encode_orig_case() {
        use rama_http_types::header::HeaderValue;

        use crate::proto::BodyLength;

        let mut head = MessageHead::default();
        head.headers
            .insert("CONTENT-LENGTH", HeaderValue::from_static("10"));
        head.headers
            .insert("content-type", HeaderValue::from_static("application/json"));
        let mut vec = Vec::new();
        Server::encode(
            Encode {
                head: EncodeHead {
                    version: head.version,
                    subject: head.subject,
                    headers: head.headers,
                    extensions: &mut head.extensions,
                },
                body: Some(BodyLength::Known(10)),
                keep_alive: true,
                req_method: &mut None,
                title_case_headers: false,
                date_header: true,
                strict_connect_framing: false,
            },
            &mut vec,
        )
        .unwrap();

        let expected_response =
            b"HTTP/1.1 200 OK\r\nCONTENT-LENGTH: 10\r\ncontent-type: application/json\r\ndate: ";

        assert_eq!(&vec[..expected_response.len()], &expected_response[..]);
    }

    #[test]
    fn test_server_response_encode_orig_and_title_case() {
        use rama_http_types::header::HeaderValue;

        use crate::proto::BodyLength;

        let mut head = MessageHead::default();
        head.headers
            .insert("CONTENT-LENGTH", HeaderValue::from_static("10"));
        head.headers
            .insert("content-type", HeaderValue::from_static("application/json"));
        let mut vec = Vec::new();
        Server::encode(
            Encode {
                head: EncodeHead {
                    version: head.version,
                    subject: head.subject,
                    headers: head.headers,
                    extensions: &mut head.extensions,
                },
                body: Some(BodyLength::Known(10)),
                keep_alive: true,
                req_method: &mut None,
                title_case_headers: true,
                date_header: true,
                strict_connect_framing: false,
            },
            &mut vec,
        )
        .unwrap();

        // this will also test that the date does exist
        let expected_response =
            b"HTTP/1.1 200 OK\r\nCONTENT-LENGTH: 10\r\nContent-Type: application/json\r\nDate: ";

        assert_eq!(&vec[..expected_response.len()], &expected_response[..]);
    }

    #[test]
    fn test_disabled_date_header() {
        use rama_http_types::header::HeaderValue;

        use crate::proto::BodyLength;

        let mut head = MessageHead::default();
        head.headers
            .insert("CONTENT-LENGTH", HeaderValue::from_static("10"));
        head.headers
            .insert("content-type", HeaderValue::from_static("application/json"));
        let mut vec = Vec::new();
        Server::encode(
            Encode {
                head: EncodeHead {
                    version: head.version,
                    subject: head.subject,
                    headers: head.headers,
                    extensions: &mut head.extensions,
                },
                body: Some(BodyLength::Known(10)),
                keep_alive: true,
                req_method: &mut None,
                title_case_headers: true,
                date_header: false,
                strict_connect_framing: false,
            },
            &mut vec,
        )
        .unwrap();

        let expected_response =
            b"HTTP/1.1 200 OK\r\nCONTENT-LENGTH: 10\r\nContent-Type: application/json\r\n\r\n";

        assert_eq!(&vec, &expected_response);
    }

    #[test]
    fn parse_header_htabs() {
        let mut bytes = BytesMut::from("HTTP/1.1 200 OK\r\nserver: hello\tworld\r\n\r\n");
        let parsed = Client::parse(
            &mut bytes,
            ParseContext {
                req_method: &mut Some(Method::GET),
                h1_parser_config: Default::default(),
                h1_max_headers: None,
                h1_max_header_size: None,
                h09_responses: false,
                on_informational: &mut None,
                prepared_extensions: &mut Some(Extensions::default()),
            },
        )
        .expect("parse ok")
        .expect("parse complete");

        assert_eq!(parsed.head.headers["server"], "hello\tworld");
    }

    #[test]
    fn parse_too_large_headers() {
        fn gen_req_with_headers(num: usize) -> String {
            let mut req = String::from("GET / HTTP/1.1\r\n");
            for i in 0..num {
                req.push_str(&format!("key{i}: val{i}\r\n"));
            }
            req.push_str("\r\n");
            req
        }
        fn gen_resp_with_headers(num: usize) -> String {
            let mut req = String::from("HTTP/1.1 200 OK\r\n");
            for i in 0..num {
                req.push_str(&format!("key{i}: val{i}\r\n"));
            }
            req.push_str("\r\n");
            req
        }
        fn parse(max_headers: Option<usize>, gen_size: usize, should_success: bool) {
            {
                // server side
                let mut bytes = BytesMut::from(gen_req_with_headers(gen_size).as_str());
                let result = Server::parse(
                    &mut bytes,
                    ParseContext {
                        req_method: &mut None,
                        h1_parser_config: Default::default(),
                        h1_max_headers: max_headers,
                        h1_max_header_size: None,
                        h09_responses: false,
                        on_informational: &mut None,
                        prepared_extensions: &mut Some(Extensions::default()),
                    },
                );
                if should_success {
                    result.expect("parse ok").expect("parse complete");
                } else {
                    result.expect_err("parse should err");
                }
            }
            {
                // client side
                let mut bytes = BytesMut::from(gen_resp_with_headers(gen_size).as_str());
                let result = Client::parse(
                    &mut bytes,
                    ParseContext {
                        req_method: &mut None,
                        h1_parser_config: Default::default(),
                        h1_max_headers: max_headers,
                        h1_max_header_size: None,
                        h09_responses: false,
                        on_informational: &mut None,
                        prepared_extensions: &mut Some(Extensions::default()),
                    },
                );
                if should_success {
                    result.expect("parse ok").expect("parse complete");
                } else {
                    result.expect_err("parse should err");
                }
            }
        }

        // check generator
        assert_eq!(
            gen_req_with_headers(0),
            String::from("GET / HTTP/1.1\r\n\r\n")
        );
        assert_eq!(
            gen_req_with_headers(1),
            String::from("GET / HTTP/1.1\r\nkey0: val0\r\n\r\n")
        );
        assert_eq!(
            gen_req_with_headers(2),
            String::from("GET / HTTP/1.1\r\nkey0: val0\r\nkey1: val1\r\n\r\n")
        );
        assert_eq!(
            gen_req_with_headers(3),
            String::from("GET / HTTP/1.1\r\nkey0: val0\r\nkey1: val1\r\nkey2: val2\r\n\r\n")
        );

        // default max_headers is 100, so
        //
        // - less than or equal to 100, accepted
        //
        parse(None, 0, true);
        parse(None, 1, true);
        parse(None, 50, true);
        parse(None, 99, true);
        parse(None, 100, true);
        //
        // - more than 100, rejected
        //
        parse(None, 101, false);
        parse(None, 102, false);
        parse(None, 200, false);

        // max_headers is 0, parser will reject any headers
        //
        // - without header, accepted
        //
        parse(Some(0), 0, true);
        //
        // - with header(s), rejected
        //
        parse(Some(0), 1, false);
        parse(Some(0), 100, false);

        // max_headers is 200
        //
        // - less than or equal to 200, accepted
        //
        parse(Some(200), 0, true);
        parse(Some(200), 1, true);
        parse(Some(200), 100, true);
        parse(Some(200), 200, true);
        //
        // - more than 200, rejected
        //
        parse(Some(200), 201, false);
        parse(Some(200), 210, false);
    }

    #[test]
    fn test_is_complete_fast() {
        let s = b"GET / HTTP/1.1\r\na: b\r\n\r\n";
        for n in 0..s.len() {
            assert!(is_complete_fast(s, n), "{s:?}; {n}");
        }
        let s = b"GET / HTTP/1.1\na: b\n\n";
        for n in 0..s.len() {
            assert!(is_complete_fast(s, n));
        }
        let s = b"GET / HTTP/1.1\r\na: b\n\r\n";
        for n in 0..s.len() {
            assert!(is_complete_fast(s, n), "{s:?}; {n}");
        }

        // Not
        let s = b"GET / HTTP/1.1\r\na: b\r\n\r";
        for n in 0..s.len() {
            assert!(!is_complete_fast(s, n));
        }
        let s = b"GET / HTTP/1.1\na: b\n";
        for n in 0..s.len() {
            assert!(!is_complete_fast(s, n));
        }
        let s = b"GET / HTTP/1.1\r\na: b\n\r";
        for n in 0..s.len() {
            assert!(!is_complete_fast(s, n));
        }
    }

    #[test]
    fn test_parse_accepts_lf_crlf_terminator() {
        // The full parser (httparse) accepts a bare-LF line ending followed
        // by a CRLF blank line as the end of the head, so the partial-read
        // fast path must recognize it too.
        let mut bytes = BytesMut::from("GET / HTTP/1.1\r\na: b\n\r\n");
        let mut prepared_extensions = Some(Extensions::new());
        Server::parse(
            &mut bytes,
            ParseContext {
                req_method: &mut None,
                h1_parser_config: Default::default(),
                h1_max_headers: None,
                h1_max_header_size: None,
                h09_responses: false,
                on_informational: &mut None,
                prepared_extensions: &mut prepared_extensions,
            },
        )
        .expect("parse ok")
        .expect("parse complete");
    }

    #[test]
    fn test_write_headers_orig_case_empty_value() {
        let mut headers = HeaderMap::new();
        let name = rama_http_types::header::HeaderName::from_static("X-EmptY");
        headers.insert(&name, "".parse().expect("parse empty"));

        let mut dst = Vec::new();
        super::write_h1_headers(&headers, false, &mut dst);

        assert_eq!(
            dst, b"X-EmptY:\r\n",
            "there should be no space between the colon and CRLF"
        );
    }

    #[test]
    fn test_write_headers_orig_case_multiple_entries() {
        let mut headers = HeaderMap::new();
        headers.insert("X-Empty", "a".parse().unwrap());
        headers.append("X-EMPTY", "b".parse().unwrap());

        let mut dst = Vec::new();
        super::write_h1_headers(&headers, false, &mut dst);

        assert_eq!(dst, b"X-Empty: a\r\nX-EMPTY: b\r\n");
    }

    /// RFC 9112 §6.1: a *response* carrying both `Content-Length` and
    /// `Transfer-Encoding: chunked` must process per Transfer-Encoding and
    /// MUST NOT forward the CL — same smuggling-prevention rule as the
    /// request side, but on the proxy's downstream return path.
    #[test]
    fn test_response_strip_content_length_when_te_chunked() {
        fn parse(s: &str) -> ParsedMessage<StatusCode> {
            let mut bytes = BytesMut::from(s);
            Client::parse(
                &mut bytes,
                ParseContext {
                    req_method: &mut Some(Method::GET),
                    h1_parser_config: Default::default(),
                    h1_max_headers: None,
                    h1_max_header_size: None,
                    h09_responses: false,
                    on_informational: &mut None,
                    prepared_extensions: &mut Some(Extensions::default()),
                },
            )
            .expect("parse ok")
            .expect("parse complete")
        }

        // TE chunked before CL
        let msg = parse(
            "\
             HTTP/1.1 200 OK\r\n\
             transfer-encoding: chunked\r\n\
             content-length: 9999\r\n\
             \r\n\
             ",
        );
        assert_eq!(msg.decode, DecodedLength::CHUNKED);
        assert!(
            !msg.head.headers.contains_key("content-length"),
            "Content-Length must be stripped from response when TE chunked is present"
        );

        // CL before TE chunked
        let msg = parse(
            "\
             HTTP/1.1 200 OK\r\n\
             content-length: 9999\r\n\
             transfer-encoding: chunked\r\n\
             \r\n\
             ",
        );
        assert_eq!(msg.decode, DecodedLength::CHUNKED);
        assert!(
            !msg.head.headers.contains_key("content-length"),
            "Content-Length must be stripped from response when TE chunked appears after CL"
        );
    }

    /// RFC 9112 §6.1: `chunked` MUST NOT be applied more than once — same
    /// rule on response parsing.
    #[test]
    fn test_response_reject_duplicate_chunked() {
        let mut bytes = BytesMut::from(
            "\
             HTTP/1.1 200 OK\r\n\
             transfer-encoding: chunked, chunked\r\n\
             \r\n\
             ",
        );
        Client::parse(
            &mut bytes,
            ParseContext {
                req_method: &mut Some(Method::GET),
                h1_parser_config: Default::default(),
                h1_max_headers: None,
                h1_max_header_size: None,
                h09_responses: false,
                on_informational: &mut None,
                prepared_extensions: &mut Some(Extensions::default()),
            },
        )
        .expect_err("response with duplicate chunked must be rejected");
    }
}
