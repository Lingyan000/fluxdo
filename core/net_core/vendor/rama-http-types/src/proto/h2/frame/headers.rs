use super::{StreamDependency, StreamId, util};
use crate::proto::ext::Protocol;
use crate::proto::h2::frame::{Error, Frame, Head, Kind};
use crate::proto::h2::hpack::{self, BytesStr};

use crate::proto::h2::{
    PseudoHeader, PseudoHeaderOrder, PseudoHeaderOrderIter, PseudoHeaderSensitivity,
};
use crate::{
    HeaderMap, HeaderName, HeaderValue, IntoOrderedIter, Method, Request, StatusCode, Uri, header,
};

use rama_core::bytes::{Buf, BufMut, Bytes, BytesMut};
use rama_core::telemetry::tracing;

use std::fmt;
use std::io::Cursor;
use std::mem;
use std::ops::{ControlFlow, Range};
use std::sync::Arc;

type EncodeBuf<'a> = rama_core::bytes::buf::Limit<&'a mut BytesMut>;

const MAX_HEADER_LIST_ABUSE_MULTIPLIER: usize = 4;

/// Header frame
///
/// This could be either a request or a response.
#[derive(Eq, PartialEq)]
pub struct Headers {
    /// The ID of the stream with which this frame is associated.
    stream_id: StreamId,

    /// The stream dependency information, if any.
    stream_dep: Option<StreamDependency>,

    /// The header block fragment
    header_block: HeaderBlock,

    /// The associated flags
    flags: HeadersFlag,
}

#[derive(Copy, Clone, Eq, PartialEq)]
pub struct HeadersFlag(u8);

#[derive(Eq, PartialEq)]
pub struct PushPromise {
    /// The ID of the stream with which this frame is associated.
    stream_id: StreamId,

    /// The ID of the stream being reserved by this PushPromise.
    promised_id: StreamId,

    /// The header block fragment
    header_block: HeaderBlock,

    /// The associated flags
    flags: PushPromiseFlag,
}

#[derive(Copy, Clone, Eq, PartialEq)]
pub struct PushPromiseFlag(u8);

#[derive(Debug)]
pub struct Continuation {
    /// Stream ID of continuation frame
    stream_id: StreamId,

    header_block: EncodingHeaderBlock,
}

// TODO: These fields shouldn't be `pub`
#[derive(Debug, Default)]
pub struct Pseudo {
    // Request
    pub method: Option<Method>,
    pub scheme: Option<BytesStr>,
    pub authority: Option<BytesStr>,
    pub path: Option<BytesStr>,
    pub protocol: Option<Protocol>,

    // Response
    pub status: Option<StatusCode>,

    // Order
    pub order: PseudoHeaderOrder,

    /// Never-index requirements retained across HTTP/2 and HTTP/3 forwarding.
    pub sensitivity: PseudoHeaderSensitivity,
}

impl PartialEq for Pseudo {
    fn eq(&self, other: &Self) -> bool {
        let Self {
            method,
            scheme,
            authority,
            path,
            protocol,
            status,
            order: _,
            sensitivity,
        } = self;
        let Self {
            method: other_method,
            scheme: other_scheme,
            authority: other_authority,
            path: other_path,
            protocol: other_protocol,
            status: other_status,
            order: _,
            sensitivity: other_sensitivity,
        } = other;
        (
            method,
            scheme,
            authority,
            path,
            protocol,
            status,
            sensitivity,
        ) == (
            other_method,
            other_scheme,
            other_authority,
            other_path,
            other_protocol,
            other_status,
            other_sensitivity,
        )
    }
}

impl Eq for Pseudo {}

#[derive(Debug)]
struct Iter {
    /// Pseudo headers
    pseudo: Option<Pseudo>,

    /// Desired Pseudo header order
    pseudo_order: PseudoHeaderOrderIter,

    /// Header fields
    fields: IntoOrderedIter<HeaderValue>,
}

/// A header block's fields: its own, or shared with the [`RequestHeaders`] of the
/// request they are sent for.
///
/// [`RequestHeaders`]: crate::proto::RequestHeaders
#[derive(Debug)]
enum Fields {
    Owned(HeaderMap),
    Shared(Arc<HeaderMap>),
}

impl Fields {
    fn get(&self) -> &HeaderMap {
        match self {
            Self::Owned(fields) => fields,
            Self::Shared(fields) => fields,
        }
    }

    fn get_mut(&mut self) -> &mut HeaderMap {
        match self {
            Self::Owned(fields) => fields,
            Self::Shared(fields) => Arc::make_mut(fields),
        }
    }

    fn into_owned(self) -> HeaderMap {
        match self {
            Self::Owned(fields) => fields,
            Self::Shared(fields) => Arc::unwrap_or_clone(fields),
        }
    }
}

#[derive(Debug)]
struct HeaderBlock {
    /// The decoded header fields
    fields: Fields,

    /// Precomputed size of all of our header fields, for perf reasons
    field_size: usize,

    /// Set to true if decoding went over the max header list size.
    is_over_size: bool,

    /// Pseudo headers, these are broken out as they must be sent as part of the
    /// headers frame.
    pseudo: Pseudo,
}

impl PartialEq for HeaderBlock {
    fn eq(&self, other: &Self) -> bool {
        let Self {
            fields,
            field_size,
            is_over_size,
            pseudo,
        } = self;
        let Self {
            fields: other_fields,
            field_size: other_field_size,
            is_over_size: other_is_over_size,
            pseudo: other_pseudo,
        } = other;
        (fields.get(), field_size, is_over_size, pseudo)
            == (
                other_fields.get(),
                other_field_size,
                other_is_over_size,
                other_pseudo,
            )
    }
}

impl Eq for HeaderBlock {}

#[derive(Debug)]
struct EncodingHeaderBlock {
    hpack: BytesMut,
}

const END_STREAM: u8 = 0x1;
const END_HEADERS: u8 = 0x4;
const PADDED: u8 = 0x8;
const PRIORITY: u8 = 0x20;
const ALL: u8 = END_STREAM | END_HEADERS | PADDED | PRIORITY;

// ===== impl Headers =====

impl Headers {
    /// Create a new HEADERS frame
    pub fn new(
        stream_id: StreamId,
        pseudo: Pseudo,
        fields: HeaderMap,
        stream_dep: Option<StreamDependency>,
    ) -> Self {
        let mut flags = HeadersFlag::default();
        if stream_dep.is_some() {
            flags.0 |= PRIORITY;
        }
        Self {
            stream_id,
            stream_dep,
            header_block: HeaderBlock {
                field_size: calculate_headermap_size(&fields),
                fields: Fields::Owned(fields),
                is_over_size: false,
                pseudo,
            },
            flags,
        }
    }

    #[must_use]
    pub fn trailers(stream_id: StreamId, fields: HeaderMap) -> Self {
        let mut flags = HeadersFlag::default();
        flags.set_end_stream();

        Self {
            stream_id,
            stream_dep: None,
            header_block: HeaderBlock {
                field_size: calculate_headermap_size(&fields),
                fields: Fields::Owned(fields),
                is_over_size: false,
                pseudo: Pseudo::default(),
            },
            flags,
        }
    }

    /// Loads the header frame but doesn't actually do HPACK decoding.
    ///
    /// HPACK decoding is done in the `load_hpack` step.
    pub fn load(head: Head, mut src: BytesMut) -> Result<(Self, BytesMut), Error> {
        let flags = HeadersFlag(head.flag());
        let mut pad = 0;

        tracing::trace!("loading headers; flags={:?}", flags);

        if head.stream_id().is_zero() {
            return Err(Error::InvalidStreamId);
        }

        // Read the padding length
        if flags.is_padded() {
            if src.is_empty() {
                return Err(Error::MalformedMessage);
            }
            pad = src[0] as usize;

            // Drop the padding
            src.advance(1);
        }

        // Read the stream dependency
        let stream_dep = if flags.is_priority() {
            if src.len() < 5 {
                return Err(Error::MalformedMessage);
            }
            let stream_dep = StreamDependency::load(&src[..5])?;

            if stream_dep.dependency_id == head.stream_id() {
                return Err(Error::InvalidDependencyId);
            }

            // Drop the next 5 bytes
            src.advance(5);

            Some(stream_dep)
        } else {
            None
        };

        if pad > 0 {
            if pad > src.len() {
                return Err(Error::TooMuchPadding);
            }

            let len = src.len() - pad;
            src.truncate(len);
        }

        let headers = Self {
            stream_id: head.stream_id(),
            stream_dep,
            header_block: HeaderBlock {
                fields: Fields::Owned(HeaderMap::new()),
                field_size: 0,
                is_over_size: false,
                pseudo: Pseudo::default(),
            },
            flags,
        };

        Ok((headers, src))
    }

    pub fn load_hpack(
        &mut self,
        src: &mut BytesMut,
        max_header_list_size: usize,
        decoder: &mut hpack::Decoder,
    ) -> Result<(), Error> {
        self.header_block.load(src, max_header_list_size, decoder)
    }

    pub fn stream_id(&self) -> StreamId {
        self.stream_id
    }

    /// HEADERS 内嵌优先级，不能与独立 PRIORITY 帧混为一谈。
    pub fn stream_dependency(&self) -> Option<&StreamDependency> {
        self.stream_dep.as_ref()
    }

    pub fn is_end_headers(&self) -> bool {
        self.flags.is_end_headers()
    }

    pub fn set_end_headers(&mut self) {
        self.flags.set_end_headers();
    }

    pub fn is_end_stream(&self) -> bool {
        self.flags.is_end_stream()
    }

    pub fn set_end_stream(&mut self) {
        self.flags.set_end_stream()
    }

    pub fn is_over_size(&self) -> bool {
        self.header_block.is_over_size
    }

    pub fn calculate_header_list_size(&self) -> usize {
        self.header_block.calculate_header_list_size()
    }

    pub fn into_parts(self) -> (Pseudo, HeaderMap) {
        (
            self.header_block.pseudo,
            self.header_block.fields.into_owned(),
        )
    }

    /// Shares the fields of this frame, as they will be sent, with the caller.
    pub fn share_fields(&mut self) -> Arc<HeaderMap> {
        let fields = match mem::replace(
            &mut self.header_block.fields,
            Fields::Owned(HeaderMap::new()),
        ) {
            Fields::Owned(fields) => Arc::new(fields),
            Fields::Shared(fields) => fields,
        };
        self.header_block.fields = Fields::Shared(fields.clone());
        fields
    }

    pub fn pseudo_mut(&mut self) -> &mut Pseudo {
        &mut self.header_block.pseudo
    }

    pub fn pseudo(&self) -> &Pseudo {
        &self.header_block.pseudo
    }

    /// Whether it has status 1xx
    pub fn is_informational(&self) -> bool {
        self.header_block.pseudo.is_informational()
    }

    pub fn fields(&self) -> &HeaderMap {
        self.header_block.fields.get()
    }

    pub fn into_fields(self) -> HeaderMap {
        self.header_block.fields.into_owned()
    }

    pub fn encode(
        self,
        encoder: &mut hpack::Encoder,
        dst: &mut EncodeBuf<'_>,
    ) -> Option<Continuation> {
        // At this point, the `is_end_headers` flag should always be set
        debug_assert!(self.flags.is_end_headers());

        // Get the HEADERS frame head
        let head = self.head();

        self.header_block
            .into_encoding(encoder)
            .encode(head, dst, Some(encoder), |dst| {
                if let Some(dependency) = self.stream_dep {
                    dependency.encode(dst);
                }
            })
    }

    fn head(&self) -> Head {
        Head::new(Kind::Headers, self.flags.into(), self.stream_id)
    }
}

impl<T> From<Headers> for Frame<T> {
    fn from(src: Headers) -> Self {
        Self::Headers(src)
    }
}

impl fmt::Debug for Headers {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        let mut builder = f.debug_struct("Headers");
        builder
            .field("stream_id", &self.stream_id)
            .field("flags", &self.flags);

        if let Some(ref protocol) = self.header_block.pseudo.protocol {
            builder.field("protocol", protocol);
        }

        if let Some(ref dep) = self.stream_dep {
            builder.field("stream_dep", dep);
        }

        // `fields` and `pseudo` purposefully not included
        builder.finish()
    }
}

// ===== util =====

#[derive(Debug, PartialEq, Eq)]
pub struct ParseU64Error;

pub fn parse_u64(src: &[u8]) -> Result<u64, ParseU64Error> {
    if src.len() > 19 {
        // At danger for overflow...
        return Err(ParseU64Error);
    }

    let mut ret = 0;

    for &d in src {
        if !d.is_ascii_digit() {
            return Err(ParseU64Error);
        }

        ret *= 10;
        ret += (d - b'0') as u64;
    }

    Ok(ret)
}

// ===== impl PushPromise =====

#[derive(Debug)]
pub enum PushPromiseHeaderError {
    InvalidContentLength(Result<u64, ParseU64Error>),
    NotSafeAndCacheable,
}

impl PushPromise {
    pub fn new(
        stream_id: StreamId,
        promised_id: StreamId,
        pseudo: Pseudo,
        fields: HeaderMap,
    ) -> Self {
        Self {
            flags: PushPromiseFlag::default(),
            header_block: HeaderBlock {
                field_size: calculate_headermap_size(&fields),
                fields: Fields::Owned(fields),
                is_over_size: false,
                pseudo,
            },
            promised_id,
            stream_id,
        }
    }

    pub fn validate_request(req: &Request<()>) -> Result<(), PushPromiseHeaderError> {
        // The spec has some requirements for promised request headers
        // [https://httpwg.org/specs/rfc7540.html#PushRequests]

        // A promised request "that indicates the presence of a request body
        // MUST reset the promised stream with a stream error"
        // Every line counts.
        for content_length in req.headers().get_all(header::CONTENT_LENGTH) {
            let parsed_length = parse_u64(content_length.as_bytes());
            if parsed_length != Ok(0) {
                return Err(PushPromiseHeaderError::InvalidContentLength(parsed_length));
            }
        }
        // "The server MUST include a method in the :method pseudo-header field
        // that is safe and cacheable"
        if !Self::safe_and_cacheable(req.method()) {
            return Err(PushPromiseHeaderError::NotSafeAndCacheable);
        }

        Ok(())
    }

    fn safe_and_cacheable(method: &Method) -> bool {
        // Cacheable: https://httpwg.org/specs/rfc7231.html#cacheable.methods
        // Safe: https://httpwg.org/specs/rfc7231.html#safe.methods
        //
        // QUERY (RFC 10008) is safe and cacheable too, but it is deliberately
        // excluded here: a promised request must not carry a body, and a QUERY
        // without its body (which *is* the query) is meaningless to push.
        method == Method::GET || method == Method::HEAD
    }

    pub fn fields(&self) -> &HeaderMap {
        self.header_block.fields.get()
    }

    pub fn into_fields(self) -> HeaderMap {
        self.header_block.fields.into_owned()
    }

    /// Loads the push promise frame but doesn't actually do HPACK decoding.
    ///
    /// HPACK decoding is done in the `load_hpack` step.
    pub fn load(head: Head, mut src: BytesMut) -> Result<(Self, BytesMut), Error> {
        let flags = PushPromiseFlag(head.flag());
        let mut pad = 0;

        if head.stream_id().is_zero() {
            return Err(Error::InvalidStreamId);
        }

        // Read the padding length
        if flags.is_padded() {
            if src.is_empty() {
                return Err(Error::MalformedMessage);
            }

            // TODO: Ensure payload is sized correctly
            pad = src[0] as usize;

            // Drop the padding
            src.advance(1);
        }

        if src.len() < 5 {
            return Err(Error::MalformedMessage);
        }

        let (promised_id, _) = StreamId::parse(&src[..4])?;
        // Drop promised_id bytes
        src.advance(4);

        if pad > 0 {
            if pad > src.len() {
                return Err(Error::TooMuchPadding);
            }

            let len = src.len() - pad;
            src.truncate(len);
        }

        let frame = Self {
            flags,
            header_block: HeaderBlock {
                fields: Fields::Owned(HeaderMap::new()),
                field_size: 0,
                is_over_size: false,
                pseudo: Pseudo::default(),
            },
            promised_id,
            stream_id: head.stream_id(),
        };
        Ok((frame, src))
    }

    pub fn load_hpack(
        &mut self,
        src: &mut BytesMut,
        max_header_list_size: usize,
        decoder: &mut hpack::Decoder,
    ) -> Result<(), Error> {
        self.header_block.load(src, max_header_list_size, decoder)
    }

    pub fn calculate_header_list_size(&self) -> usize {
        self.header_block.calculate_header_list_size()
    }

    pub fn stream_id(&self) -> StreamId {
        self.stream_id
    }

    pub fn promised_id(&self) -> StreamId {
        self.promised_id
    }

    pub fn is_end_headers(&self) -> bool {
        self.flags.is_end_headers()
    }

    pub fn set_end_headers(&mut self) {
        self.flags.set_end_headers();
    }

    pub fn is_over_size(&self) -> bool {
        self.header_block.is_over_size
    }

    pub fn encode(
        self,
        encoder: &mut hpack::Encoder,
        dst: &mut EncodeBuf<'_>,
    ) -> Option<Continuation> {
        // At this point, the `is_end_headers` flag should always be set
        debug_assert!(self.flags.is_end_headers());

        let head = self.head();
        let promised_id = self.promised_id;

        self.header_block
            .into_encoding(encoder)
            .encode(head, dst, Some(encoder), |dst| {
                dst.put_u32(promised_id.into());
            })
    }

    fn head(&self) -> Head {
        Head::new(Kind::PushPromise, self.flags.into(), self.stream_id)
    }

    /// Consume `self`, returning the parts of the frame
    pub fn into_parts(self) -> (Pseudo, HeaderMap) {
        (
            self.header_block.pseudo,
            self.header_block.fields.into_owned(),
        )
    }
}

impl<T> From<PushPromise> for Frame<T> {
    fn from(src: PushPromise) -> Self {
        Self::PushPromise(src)
    }
}

impl fmt::Debug for PushPromise {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.debug_struct("PushPromise")
            .field("stream_id", &self.stream_id)
            .field("promised_id", &self.promised_id)
            .field("flags", &self.flags)
            // `fields` and `pseudo` purposefully not included
            .finish()
    }
}

// ===== impl Continuation =====

impl Continuation {
    fn head(&self) -> Head {
        Head::new(Kind::Continuation, END_HEADERS, self.stream_id)
    }

    pub fn encode(self, dst: &mut EncodeBuf<'_>) -> Option<Self> {
        // Get the CONTINUATION frame head
        let head = self.head();
        self.header_block.encode(head, dst, None, |_| {})
    }
}

// ===== impl Pseudo =====

impl Pseudo {
    fn take_header(&mut self, name: PseudoHeader) -> Option<hpack::Header<Option<HeaderName>>> {
        let header = match name {
            PseudoHeader::Method => self.method.take().map(hpack::Header::Method),
            PseudoHeader::Scheme => self.scheme.take().map(hpack::Header::Scheme),
            PseudoHeader::Authority => self.authority.take().map(hpack::Header::Authority),
            PseudoHeader::Path => self.path.take().map(hpack::Header::Path),
            PseudoHeader::Protocol => self.protocol.take().map(hpack::Header::Protocol),
            PseudoHeader::Status => self.status.take().map(hpack::Header::Status),
        }?;
        // Userinfo, kept only outside the HTTP family, is never indexed.
        let credentials = matches!(&header, hpack::Header::Authority(value) if value.contains('@'));
        Some(header.with_sensitive(self.sensitivity.is_sensitive(name) || credentials))
    }

    pub fn request(method: Method, uri: &Uri, protocol: Option<Protocol>) -> Self {
        // `:authority` and `:path` are rendered into one buffer, shared once frozen.
        let mut target = Vec::with_capacity(128);
        let authority_len = uri
            .write_h2_authority(&mut target)
            .is_ok()
            .then_some(target.len());

        let (scheme, path) = if method == Method::CONNECT && protocol.is_none() {
            // CONNECT (non-extended): no `:scheme`/`:path`.
            (None, None)
        } else {
            let wire_scheme = uri.scheme().map(|scheme| {
                if protocol.is_some() {
                    crate::proto::ext::extended_connect_pseudo_scheme(scheme)
                } else {
                    scheme
                }
            });
            // RFC 9113 §8.3.1: an OPTIONS request without a path is the "OPTIONS *"
            // form and carries `:path = *`, required for http(s) and how a received
            // `*` reads back for every scheme. The origin-form writer normalises an
            // absent path to `/`, so the absent path is detected via the typed accessor.
            let path = if method == Method::OPTIONS
                && !uri.is_asterisk()
                && uri.is_path_empty()
                && uri.query().is_none()
            {
                PathSource::Static("*")
            } else if wire_scheme
                .is_some_and(|scheme| crate::proto::ext::sends_empty_path(uri, scheme))
            {
                PathSource::Static("")
            } else {
                // `:path` mirrors origin-form, except that asterisk-form carries `*`.
                uri.write_h2_path(&mut target);
                PathSource::Rendered
            };
            (wire_scheme.map(pseudo_scheme), Some(path))
        };

        let target = Bytes::from(target);
        let rendered = |range: Range<usize>| {
            BytesStr::try_from(target.slice(range)).unwrap_or_else(|_| BytesStr::from_static(""))
        };
        let path = path.map(|path| match path {
            PathSource::Static(value) => BytesStr::from_static(value),
            PathSource::Rendered => rendered(authority_len.unwrap_or(0)..target.len()),
        });

        let mut pseudo = Self {
            method: Some(method),
            scheme,
            authority: None,
            path,
            protocol,
            status: None,
            order: PseudoHeaderOrder::default(),
            sensitivity: PseudoHeaderSensitivity::default(),
        };
        if let Some(authority_len) = authority_len {
            pseudo.set_authority(rendered(0..authority_len));
        }
        pseudo
    }

    /// Returns true if no pseudo-header fields are present.
    ///
    /// Used to validate trailers, which MUST NOT contain pseudo-headers
    /// (RFC 9113 §8.1).
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.method.is_none()
            && self.scheme.is_none()
            && self.authority.is_none()
            && self.path.is_none()
            && self.protocol.is_none()
            && self.status.is_none()
    }

    /// The value of the pseudo-header `name`, if present.
    #[must_use]
    pub fn value(&self, name: PseudoHeader) -> Option<&str> {
        match name {
            PseudoHeader::Method => self.method.as_ref().map(Method::as_str),
            PseudoHeader::Scheme => self.scheme.as_deref(),
            PseudoHeader::Authority => self.authority.as_deref(),
            PseudoHeader::Path => self.path.as_deref(),
            PseudoHeader::Protocol => self.protocol.as_ref().map(Protocol::as_str),
            PseudoHeader::Status => self.status.as_ref().map(StatusCode::as_str),
        }
    }

    #[must_use]
    pub fn response(status: StatusCode) -> Self {
        Self {
            method: None,
            scheme: None,
            authority: None,
            path: None,
            protocol: None,
            status: Some(status),
            order: PseudoHeaderOrder::default(),
            sensitivity: PseudoHeaderSensitivity::default(),
        }
    }

    pub fn set_status(&mut self, value: StatusCode) {
        self.status = Some(value);
    }

    pub fn set_scheme(&mut self, scheme: &rama_net::Protocol) {
        self.scheme = Some(pseudo_scheme(scheme));
    }

    pub fn set_protocol(&mut self, protocol: Protocol) {
        self.protocol = Some(protocol);
    }

    pub fn set_authority(&mut self, authority: BytesStr) {
        self.authority = Some(authority);
    }

    /// Whether it has status 1xx
    pub fn is_informational(&self) -> bool {
        self.status.is_some_and(|status| status.is_informational())
    }
}

// ===== impl EncodingHeaderBlock =====

impl EncodingHeaderBlock {
    fn encode<F>(
        mut self,
        head: Head,
        dst: &mut EncodeBuf<'_>,
        encoder: Option<&mut hpack::Encoder>,
        f: F,
    ) -> Option<Continuation>
    where
        F: FnOnce(&mut EncodeBuf<'_>),
    {
        let head_pos = dst.get_ref().len();

        // At this point, we don't know how big the h2 frame will be.
        // So, we write the head with length 0, then write the body, and
        // finally write the length once we know the size.
        head.encode(0, dst);

        let payload_pos = dst.get_ref().len();

        f(dst);

        // Now, encode the header payload
        let continuation = if self.hpack.len() > dst.remaining_mut() {
            let head_part = self.hpack.split_to(dst.remaining_mut());
            dst.put_slice(&head_part);

            Some(Continuation {
                stream_id: head.stream_id(),
                header_block: self,
            })
        } else {
            dst.put_slice(&self.hpack);
            // The block is fully written, so the buffer can be reused by the
            // next frame on this connection.
            if let Some(encoder) = encoder {
                encoder.return_scratch(self.hpack);
            }

            None
        };

        // Compute the header block length
        let payload_len = (dst.get_ref().len() - payload_pos) as u64;

        // Write the frame length
        let payload_len_be = payload_len.to_be_bytes();
        assert!(payload_len_be[0..5].iter().all(|b| *b == 0));
        (dst.get_mut()[head_pos..head_pos + 3]).copy_from_slice(&payload_len_be[5..]);

        if continuation.is_some() {
            // There will be continuation frames, so the `is_end_headers` flag
            // must be unset
            debug_assert!(dst.get_ref()[head_pos + 4] & END_HEADERS == END_HEADERS);

            dst.get_mut()[head_pos + 4] -= END_HEADERS;
        }

        continuation
    }
}

// ===== impl Iter =====

impl Iterator for Iter {
    type Item = hpack::Header<Option<HeaderName>>;

    fn next(&mut self) -> Option<Self::Item> {
        if let Some(ref mut pseudo) = self.pseudo {
            for name in self.pseudo_order.by_ref() {
                if let Some(header) = pseudo.take_header(name) {
                    return Some(header);
                }
            }

            // Fields added by middleware may not occur in the recorded order.
            for name in [
                PseudoHeader::Method,
                PseudoHeader::Scheme,
                PseudoHeader::Authority,
                PseudoHeader::Path,
                PseudoHeader::Protocol,
                PseudoHeader::Status,
            ] {
                if let Some(header) = pseudo.take_header(name) {
                    return Some(header);
                }
            }
        }

        self.pseudo = None;

        self.fields
            .next()
            .map(|(name, value)| hpack::Header::Field {
                name: Some(name),
                value,
            })
    }
}

// ===== impl HeadersFlag =====

impl HeadersFlag {
    pub fn empty() -> Self {
        Self(0)
    }

    pub fn load(bits: u8) -> Self {
        Self(bits & ALL)
    }

    pub fn is_end_stream(self) -> bool {
        self.0 & END_STREAM == END_STREAM
    }

    pub fn set_end_stream(&mut self) {
        self.0 |= END_STREAM;
    }

    pub fn is_end_headers(self) -> bool {
        self.0 & END_HEADERS == END_HEADERS
    }

    pub fn set_end_headers(&mut self) {
        self.0 |= END_HEADERS;
    }

    pub fn is_padded(self) -> bool {
        self.0 & PADDED == PADDED
    }

    pub fn is_priority(self) -> bool {
        self.0 & PRIORITY == PRIORITY
    }
}

impl Default for HeadersFlag {
    /// Returns a `HeadersFlag` value with `END_HEADERS` set.
    fn default() -> Self {
        Self(END_HEADERS)
    }
}

impl From<HeadersFlag> for u8 {
    fn from(src: HeadersFlag) -> Self {
        src.0
    }
}

impl fmt::Debug for HeadersFlag {
    fn fmt(&self, fmt: &mut fmt::Formatter) -> fmt::Result {
        util::debug_flags(fmt, self.0)
            .flag_if(self.is_end_headers(), "END_HEADERS")
            .flag_if(self.is_end_stream(), "END_STREAM")
            .flag_if(self.is_padded(), "PADDED")
            .flag_if(self.is_priority(), "PRIORITY")
            .finish()
    }
}

// ===== impl PushPromiseFlag =====

impl PushPromiseFlag {
    pub fn empty() -> Self {
        Self(0)
    }

    pub fn load(bits: u8) -> Self {
        Self(bits & ALL)
    }

    pub fn is_end_headers(self) -> bool {
        self.0 & END_HEADERS == END_HEADERS
    }

    pub fn set_end_headers(&mut self) {
        self.0 |= END_HEADERS;
    }

    pub fn is_padded(self) -> bool {
        self.0 & PADDED == PADDED
    }
}

impl Default for PushPromiseFlag {
    /// Returns a `PushPromiseFlag` value with `END_HEADERS` set.
    fn default() -> Self {
        Self(END_HEADERS)
    }
}

impl From<PushPromiseFlag> for u8 {
    fn from(src: PushPromiseFlag) -> Self {
        src.0
    }
}

impl fmt::Debug for PushPromiseFlag {
    fn fmt(&self, fmt: &mut fmt::Formatter) -> fmt::Result {
        util::debug_flags(fmt, self.0)
            .flag_if(self.is_end_headers(), "END_HEADERS")
            .flag_if(self.is_padded(), "PADDED")
            .finish()
    }
}

// ===== HeaderBlock =====

impl HeaderBlock {
    fn load(
        &mut self,
        src: &mut BytesMut,
        max_header_list_size: usize,
        decoder: &mut hpack::Decoder,
    ) -> Result<(), Error> {
        let mut reg = !self.fields.get().is_empty();
        let mut malformed = false;
        let mut header_list_way_too_large = false;
        let mut headers_size = self.calculate_header_list_size();
        let max_header_list_abuse_size =
            max_header_list_size.saturating_mul(MAX_HEADER_LIST_ABUSE_MULTIPLIER);

        macro_rules! check_size {
            () => {{
                if headers_size > max_header_list_abuse_size {
                    tracing::trace!("load_hpack; header list size over abuse max");
                    header_list_way_too_large = true;
                    ControlFlow::Break(())
                } else {
                    if headers_size >= max_header_list_size && !self.is_over_size {
                        tracing::trace!("load_hpack; header list size over max");
                        self.is_over_size = true;
                    }
                    ControlFlow::Continue(())
                }
            }};
        }

        macro_rules! set_pseudo {
            ($field:ident, $val:expr) => {{
                if reg {
                    tracing::trace!("load_hpack; header malformed -- pseudo not at head of block");
                    malformed = true;
                } else if self.pseudo.$field.is_some() {
                    tracing::trace!("load_hpack; header malformed -- repeated pseudo");
                    malformed = true;
                } else {
                    let __val = $val;
                    headers_size +=
                        decoded_header_size(stringify!($field).len() + 1, __val.as_str().len());
                    if check_size!().is_break() {
                        return ControlFlow::Break(());
                    }
                    if !self.is_over_size {
                        self.pseudo.$field = Some(__val);
                    }
                }
            }};
        }

        let mut cursor = Cursor::new(src);

        // If the header frame is malformed, we still have to continue decoding
        // the headers. A malformed header frame is a stream level error, but
        // the hpack state is connection level. In order to maintain correct
        // state for other streams, the hpack decoding process must complete.
        let res = decoder.decode(&mut cursor, |header| {
            if let hpack::Header::NeverIndexed(ref value) = header {
                self.pseudo.sensitivity.set_sensitive(value.name(), true);
            }
            match header {
                hpack::Header::Field { name, value } => {
                    // Connection level header fields are not supported and must
                    // result in a protocol error.

                    if header::hop_by_hop::CONNECTION_SPECIFIC_HEADERS.contains(&&name) {
                        tracing::trace!("load_hpack; connection level header");
                        malformed = true;
                    } else if name == header::TE
                        && !header::hop_by_hop::is_te_trailers(value.as_bytes())
                    {
                        tracing::trace!(
                            "load_hpack; TE header not set to trailers; val={:?}",
                            value
                        );
                        malformed = true;
                    } else {
                        reg = true;

                        let header_size = decoded_header_size(name.as_str().len(), value.len());
                        headers_size += header_size;
                        if check_size!().is_break() {
                            return ControlFlow::Break(());
                        }
                        if !self.is_over_size {
                            self.field_size += header_size;
                            if self.fields.get_mut().try_append(name, value).is_err() {
                                // HeaderMap capacity exceeded — treat as over-size
                                // so the stream is rejected downstream (RST_STREAM / 431)
                                // instead of panicking on the 24,577th unique header.
                                self.is_over_size = true;
                            }
                        }
                    }
                }
                hpack::Header::Authority(v)
                | hpack::Header::NeverIndexed(hpack::NeverIndexedPseudo::Authority(v)) => {
                    self.pseudo.order.push(PseudoHeader::Authority);
                    set_pseudo!(authority, v)
                }
                hpack::Header::Method(v)
                | hpack::Header::NeverIndexed(hpack::NeverIndexedPseudo::Method(v)) => {
                    self.pseudo.order.push(PseudoHeader::Method);
                    set_pseudo!(method, v)
                }
                hpack::Header::Scheme(v)
                | hpack::Header::NeverIndexed(hpack::NeverIndexedPseudo::Scheme(v)) => {
                    self.pseudo.order.push(PseudoHeader::Scheme);
                    set_pseudo!(scheme, v)
                }
                hpack::Header::Path(v)
                | hpack::Header::NeverIndexed(hpack::NeverIndexedPseudo::Path(v)) => {
                    self.pseudo.order.push(PseudoHeader::Path);
                    set_pseudo!(path, v)
                }
                hpack::Header::Protocol(v)
                | hpack::Header::NeverIndexed(hpack::NeverIndexedPseudo::Protocol(v)) => {
                    self.pseudo.order.push(PseudoHeader::Protocol);
                    set_pseudo!(protocol, v)
                }
                hpack::Header::Status(v)
                | hpack::Header::NeverIndexed(hpack::NeverIndexedPseudo::Status(v)) => {
                    self.pseudo.order.push(PseudoHeader::Status);
                    set_pseudo!(status, v)
                }
            }
            ControlFlow::Continue(())
        });

        match res {
            Ok(()) => {}
            Err(e) => {
                tracing::trace!("hpack decoding error; err={:?}", e);
                return Err(e.into());
            }
        }

        if header_list_way_too_large {
            tracing::trace!("header list way too large; aborting connection");
            return Err(Error::HeaderListWayTooLarge);
        }

        if malformed {
            tracing::trace!("malformed message");
            return Err(Error::MalformedMessage);
        }

        Ok(())
    }

    fn into_encoding(self, encoder: &mut hpack::Encoder) -> EncodingHeaderBlock {
        let mut hpack = encoder.take_scratch();
        hpack.clear();
        let pseudo_order = self.pseudo.order.iter();
        match self.fields {
            Fields::Owned(fields) => encoder.encode(
                Iter {
                    pseudo_order,
                    pseudo: Some(self.pseudo),
                    fields: fields.into_ordered_iter(),
                },
                &mut hpack,
            ),
            // Values are reference counted, so encoding from the shared map copies none.
            Fields::Shared(fields) => encoder.encode(
                Iter {
                    pseudo_order,
                    pseudo: Some(self.pseudo),
                    fields: HeaderMap::new().into_ordered_iter(),
                }
                .chain(fields.ordered_iter().map(|(name, value)| {
                    hpack::Header::Field {
                        name: Some(name.clone()),
                        value: value.clone(),
                    }
                })),
                &mut hpack,
            ),
        }

        EncodingHeaderBlock { hpack }
    }

    /// Calculates the size of the currently decoded header list.
    ///
    /// According to http://httpwg.org/specs/rfc7540.html#SETTINGS_MAX_HEADER_LIST_SIZE
    ///
    /// > The value is based on the uncompressed size of header fields,
    /// > including the length of the name and value in octets plus an
    /// > overhead of 32 octets for each header field.
    fn calculate_header_list_size(&self) -> usize {
        macro_rules! pseudo_size {
            ($name:ident) => {{
                self.pseudo
                    .$name
                    .as_ref()
                    .map(|m| decoded_header_size(stringify!($name).len() + 1, m.as_str().len()))
                    .unwrap_or(0)
            }};
        }

        pseudo_size!(method)
            + pseudo_size!(scheme)
            + pseudo_size!(status)
            + pseudo_size!(authority)
            + pseudo_size!(path)
            + self.field_size
    }
}

fn calculate_headermap_size(map: &HeaderMap) -> usize {
    map.iter()
        .map(|(name, value)| decoded_header_size(name.as_str().len(), value.len()))
        .sum::<usize>()
}

fn decoded_header_size(name: usize, value: usize) -> usize {
    name + value + 32
}

/// Where a request's `:path` comes from.
enum PathSource {
    Static(&'static str),
    Rendered,
}

/// `:scheme` for `scheme`, without a copy for http(s).
fn pseudo_scheme(scheme: &rama_net::Protocol) -> BytesStr {
    match scheme.as_str() {
        "https" => BytesStr::from_static("https"),
        "http" => BytesStr::from_static("http"),
        other => BytesStr::from(other),
    }
}

#[cfg(test)]
mod test {
    use super::*;

    /// A shared block encodes byte for byte as an owned one: order, duplicates,
    /// casing, never-index, empty values, removed fields and CONTINUATION, also
    /// against a dynamic table an earlier block filled.
    #[test]
    fn shared_fields_encode_like_owned_fields() {
        fn fields() -> HeaderMap {
            let mut fields = HeaderMap::new();
            fields.append(
                HeaderName::from_static("x-a"),
                HeaderValue::from_static("1"),
            );
            fields.append(header::COOKIE, HeaderValue::from_static("a=1"));
            let mut secret = HeaderValue::from_static("token");
            secret.set_sensitive(true);
            fields.append(header::AUTHORIZATION, secret);
            fields.append(
                HeaderName::from_bytes(b"X-Mixed-Case").unwrap(),
                HeaderValue::from_static("v"),
            );
            fields.append(
                HeaderName::from_static("x-a"),
                HeaderValue::from_static("2"),
            );
            fields.append(
                HeaderName::from_static("x-gone"),
                HeaderValue::from_static("g"),
            );
            fields.append(
                HeaderName::from_static("x-empty"),
                HeaderValue::from_static(""),
            );
            fields.append(
                HeaderName::from_static("x-big"),
                HeaderValue::from_str(&"b".repeat(40_000)).unwrap(),
            );
            fields.remove("x-gone");
            fields
        }

        fn encode(share: bool) -> Vec<u8> {
            let mut encoder = hpack::Encoder::default();
            let mut wire = Vec::new();
            for id in [1u32, 3] {
                let pseudo =
                    Pseudo::request(Method::GET, &"https://example.com/p".parse().unwrap(), None);
                let mut frame = Headers::new(StreamId::from(id), pseudo, fields(), None);
                if share {
                    let shared = frame.share_fields();
                    assert_eq!(Arc::strong_count(&shared), 2);
                }
                let mut buf = BytesMut::new();
                let mut next = frame.encode(&mut encoder, &mut (&mut buf).limit(16_384 + 9));
                while let Some(continuation) = next {
                    next = continuation.encode(&mut (&mut buf).limit(16_384 + 9));
                }
                wire.extend_from_slice(&buf);
            }
            wire
        }

        let owned = encode(false);
        assert!(owned.len() > 40_000);
        assert_eq!(encode(true), owned);
    }

    #[test]
    fn every_promised_content_length_line_counts() {
        for (lengths, valid) in [
            (&[][..], true),
            (&["0"][..], true),
            (&["0", "0"][..], true),
            (&["5"][..], false),
            (&["0", "5"][..], false),
            (&["5", "0"][..], false),
        ] {
            let mut req = Request::new(());
            for length in lengths {
                req.headers_mut()
                    .append(header::CONTENT_LENGTH, HeaderValue::from_static(length));
            }
            assert_eq!(
                PushPromise::validate_request(&req).is_ok(),
                valid,
                "{lengths:?}"
            );
        }
    }

    #[test]
    fn authority_userinfo_is_kept_outside_the_http_family_and_never_indexed() {
        for (uri, authority, sensitive) in [
            ("https://user@example.com/", "example.com", false),
            ("ftp://user:pw@example.com/f", "user:pw@example.com", true),
        ] {
            let mut pseudo = Pseudo::request(Method::GET, &uri.parse().unwrap(), None);
            let (value, never_indexed) = match pseudo.take_header(PseudoHeader::Authority) {
                Some(hpack::Header::Authority(value)) => (value, false),
                Some(hpack::Header::NeverIndexed(value)) => {
                    match value.into_header::<Option<HeaderName>>() {
                        hpack::Header::Authority(value) => (value, true),
                        other => panic!("{other:?}"),
                    }
                }
                other => panic!("{other:?}"),
            };
            assert_eq!(
                (value.as_str(), never_indexed),
                (authority, sensitive),
                "{uri}"
            );
        }
    }

    #[test]
    fn removed_pseudo_fields_do_not_discard_remaining_order_or_sensitivity() {
        let mut pseudo =
            Pseudo::request(Method::GET, &"https://example.com/".parse().unwrap(), None);
        pseudo.order.extend([
            PseudoHeader::Protocol,
            PseudoHeader::Path,
            PseudoHeader::Method,
        ]);
        pseudo.sensitivity.set_sensitive(PseudoHeader::Path, true);
        let iter = Iter {
            pseudo_order: pseudo.order.iter(),
            pseudo: Some(pseudo),
            fields: HeaderMap::new().into_ordered_iter(),
        };
        let headers: Vec<_> = iter.map(|header| header.reify().unwrap()).collect();
        assert_eq!(
            headers
                .iter()
                .map(|header| header.name().as_slice().to_vec())
                .collect::<Vec<_>>(),
            [b":path".as_slice(), b":method", b":scheme", b":authority"]
        );
        assert!(headers[0].is_sensitive());
        assert!(headers[1..].iter().all(|header| !header.is_sensitive()));
    }

    #[test]
    fn test_connect_request_pseudo_headers_omits_path_and_scheme() {
        // CONNECT requests MUST NOT include :scheme & :path pseudo-header fields
        // See: https://datatracker.ietf.org/doc/html/rfc9113#section-8.5

        assert_eq!(
            Pseudo::request(
                Method::CONNECT,
                &Uri::from_static("https://example.com:8443"),
                None
            ),
            Pseudo {
                method: Method::CONNECT.into(),
                authority: BytesStr::from_static("example.com:8443").into(),
                ..Default::default()
            }
        );

        assert_eq!(
            Pseudo::request(
                Method::CONNECT,
                &Uri::from_static("https://example.com/test"),
                None
            ),
            Pseudo {
                method: Method::CONNECT.into(),
                authority: BytesStr::from_static("example.com").into(),
                ..Default::default()
            }
        );

        assert_eq!(
            Pseudo::request(
                Method::CONNECT,
                &Uri::parse_authority_form("example.com:8443").unwrap(),
                None
            ),
            Pseudo {
                method: Method::CONNECT.into(),
                authority: BytesStr::from_static("example.com:8443").into(),
                ..Default::default()
            }
        );
    }

    #[test]
    fn extended_connect_websocket_uses_the_http_scheme() {
        // RFC 8441 §5: `https` for `wss`-schemed WebSockets, `http` for `ws`.
        for (uri, scheme) in [
            ("wss://example.com/chat", "https"),
            ("ws://example.com/chat", "http"),
        ] {
            let pseudo = Pseudo::request(
                Method::CONNECT,
                &Uri::from_static(uri),
                Protocol::WEBSOCKET.into(),
            );
            assert_eq!(pseudo.scheme.as_deref(), Some(scheme), "{uri}");
            assert_eq!(pseudo.path.as_deref(), Some("/chat"));
        }
    }

    #[test]
    fn test_extended_connect_request_pseudo_headers_includes_path_and_scheme() {
        // On requests that contain the :protocol pseudo-header field, the
        // :scheme and :path pseudo-header fields of the target URI (see
        // Section 5) MUST also be included.
        // See: https://datatracker.ietf.org/doc/html/rfc8441#section-4

        assert_eq!(
            Pseudo::request(
                Method::CONNECT,
                &Uri::from_static("https://example.com:8443"),
                Protocol::from_static("the-bread-protocol").into()
            ),
            Pseudo {
                method: Method::CONNECT.into(),
                authority: BytesStr::from_static("example.com:8443").into(),
                scheme: BytesStr::from_static("https").into(),
                path: BytesStr::from_static("/").into(),
                protocol: Protocol::from_static("the-bread-protocol").into(),
                ..Default::default()
            }
        );

        assert_eq!(
            Pseudo::request(
                Method::CONNECT,
                &Uri::from_static("https://example.com:8443/test"),
                Protocol::from_static("the-bread-protocol").into()
            ),
            Pseudo {
                method: Method::CONNECT.into(),
                authority: BytesStr::from_static("example.com:8443").into(),
                scheme: BytesStr::from_static("https").into(),
                path: BytesStr::from_static("/test").into(),
                protocol: Protocol::from_static("the-bread-protocol").into(),
                ..Default::default()
            }
        );

        assert_eq!(
            Pseudo::request(
                Method::CONNECT,
                &Uri::from_static("http://example.com/a/b/c"),
                Protocol::from_static("the-bread-protocol").into()
            ),
            Pseudo {
                method: Method::CONNECT.into(),
                authority: BytesStr::from_static("example.com").into(),
                scheme: BytesStr::from_static("http").into(),
                path: BytesStr::from_static("/a/b/c").into(),
                protocol: Protocol::from_static("the-bread-protocol").into(),
                ..Default::default()
            }
        );
    }

    #[test]
    fn test_options_request_with_empty_path_has_asterisk_as_pseudo_path() {
        // an OPTIONS request for an "http" or "https" URI that does not include a path component;
        // these MUST include a ":path" pseudo-header field with a value of '*' (see Section 7.1 of [HTTP]).
        // See: https://datatracker.ietf.org/doc/html/rfc9113#section-8.3.1
        assert_eq!(
            Pseudo::request(
                Method::OPTIONS,
                &Uri::parse_authority_form("example.com:8080").unwrap(),
                None,
            ),
            Pseudo {
                method: Method::OPTIONS.into(),
                authority: BytesStr::from_static("example.com:8080").into(),
                path: BytesStr::from_static("*").into(),
                ..Default::default()
            }
        );
    }

    #[test]
    fn options_without_a_path_is_asterisk_for_every_scheme() {
        for (uri, path) in [
            ("https://example.com", "*"),
            ("http://example.com:8080", "*"),
            ("foo://example.com", "*"),
            ("foo://example.com/", "/"),
        ] {
            let pseudo = Pseudo::request(Method::OPTIONS, &Uri::parse(uri).unwrap(), None);
            assert_eq!(pseudo.path.as_deref(), Some(path), "{uri}");
        }
    }

    #[test]
    fn request_pseudo_fields_share_one_rendered_target() {
        for (uri, scheme, authority, path) in [
            (
                "https://example.com/a?b",
                Some("https"),
                Some("example.com"),
                "/a?b",
            ),
            ("http://[::1]:8080", Some("http"), Some("[::1]:8080"), "/"),
            ("file:///etc/hosts", Some("file"), Some(""), "/etc/hosts"),
            ("urn:isbn:123", Some("urn"), None, "/isbn:123"),
        ] {
            let pseudo = Pseudo::request(Method::GET, &Uri::parse(uri).unwrap(), None);
            assert_eq!(pseudo.scheme.as_deref(), scheme, "{uri}");
            assert_eq!(pseudo.authority.as_deref(), authority, "{uri}");
            assert_eq!(pseudo.path.as_deref(), Some(path), "{uri}");
        }
    }

    #[test]
    #[expect(clippy::vec_init_then_push)]
    fn test_try_append_prevents_panic_on_max_size_reached() {
        // Verify that decoding >24,577 unique headers sets `is_over_size`
        // instead of panicking via HeaderMap::append().
        //
        // HeaderMap::MAX_SIZE = 32,768. With 75% load factor, max entries = 24,576.
        // try_append returns Err(MaxSizeReached) at entry 24,577.
        // Before the fix (using append), this panicked.
        //
        // We manually construct HPACK bytes for 25,000 unique headers because
        // creating a HeaderMap with that many entries also panics on construction.

        // Build HPACK-encoded block:
        // Pseudo-headers (indexed refs to static table):
        //   :method GET         → 0x82 (static index 2)
        //   :scheme http        → 0x86 (static index 6)
        //   :path /             → 0x84 (static index 4)
        //   :authority "localhost" → literal with indexing (name index 0)
        //
        // Then 25,000 unique headers: "literal without indexing, new name"
        //   0x00 → literal without indexing, name index 0
        //   <name_len> <name_bytes>
        //   <value_len> <value_bytes>

        let num_headers = 25_000;

        // Build the HPACK block
        let mut hpack = Vec::new();

        // Pseudo-headers
        hpack.push(0x82u8); // :method GET (static index 2)
        hpack.push(0x86); // :scheme http (static index 6)
        hpack.push(0x84); // :path / (static index 4)

        // :authority "localhost" — literal with incremental indexing
        hpack.push(0x41); // literal with indexing, name index 1 (= ":authority")
        hpack.push(0x09); // value length 9
        hpack.extend_from_slice(b"localhost");

        // 25,000 unique headers: "literal without indexing, new name"
        // Format: 0x00 + name_len + name + value_len + value
        for i in 0..num_headers {
            let name = format!("x-h-{i}");
            hpack.push(0x00u8); // literal without indexing, name index 0
            hpack.push(name.len() as u8);
            hpack.extend_from_slice(name.as_bytes());
            hpack.push(1u8); // value length 1
            hpack.push(b'v');
        }

        // Build the HTTP/2 HEADERS frame: 9-byte header + HPACK payload
        let payload_len = hpack.len();
        let mut frame = BytesMut::with_capacity(9 + payload_len);

        // Frame header: 3 bytes length, 1 byte type (0x01=HEADERS), 1 byte flags, 4 bytes stream_id
        frame.put_u8(((payload_len >> 16) & 0xFF) as u8);
        frame.put_u8(((payload_len >> 8) & 0xFF) as u8);
        frame.put_u8((payload_len & 0xFF) as u8);
        frame.put_u8(0x01); // type: HEADERS
        frame.put_u8(0x04); // flags: END_HEADERS
        frame.put_u32(1); // stream_id: 1

        frame.extend_from_slice(&hpack);

        // Parse the HEADERS frame
        let head = Head::parse(&frame[..9]).unwrap();
        let payload = BytesMut::from(&frame[9..]);
        let (mut headers, mut hpack_data) = Headers::load(head, payload).unwrap();
        // hpack_data contains the HPACK payload (no padding/priority in our frame)

        // Decode the HPACK block — this should NOT panic
        let mut decoder = hpack::Decoder::new(4096);
        const DEFAULT_MAX_HEADER_LIST_SIZE: usize = 16 << 20; // 16 MB
        headers
            .load_hpack(&mut hpack_data, DEFAULT_MAX_HEADER_LIST_SIZE, &mut decoder)
            .expect("load_hpack should return Ok");

        // Verify that is_over_size was set (try_append returned Err)
        assert!(
            headers.is_over_size(),
            "is_over_size should be true when HeaderMap capacity is exceeded"
        );
    }

    #[test]
    fn test_non_option_and_non_connect_requests_include_path_and_scheme() {
        let methods = [
            Method::GET,
            Method::POST,
            Method::PUT,
            Method::DELETE,
            Method::HEAD,
            Method::PATCH,
            Method::TRACE,
        ];

        for method in methods {
            assert_eq!(
                Pseudo::request(
                    method.clone(),
                    &Uri::from_static("http://example.com:8080"),
                    None,
                ),
                Pseudo {
                    method: method.clone().into(),
                    authority: BytesStr::from_static("example.com:8080").into(),
                    scheme: BytesStr::from_static("http").into(),
                    path: BytesStr::from_static("/").into(),
                    ..Default::default()
                }
            );
            assert_eq!(
                Pseudo::request(
                    method.clone(),
                    &Uri::from_static("https://example.com/a/b/c"),
                    None,
                ),
                Pseudo {
                    method: method.into(),
                    authority: BytesStr::from_static("example.com").into(),
                    scheme: BytesStr::from_static("https").into(),
                    path: BytesStr::from_static("/a/b/c").into(),
                    ..Default::default()
                }
            );
        }
    }

    /// RFC 9113 §8.1: trailers MUST NOT contain pseudo-header fields.
    /// Used by `Recv::recv_trailers` to short-circuit malformed trailers.
    #[test]
    fn pseudo_is_empty_detects_emptiness() {
        let empty = Pseudo::default();
        assert!(empty.is_empty());

        let with_method = Pseudo {
            method: Some(Method::GET),
            ..Default::default()
        };
        assert!(!with_method.is_empty());

        let with_status = Pseudo::response(StatusCode::OK);
        assert!(!with_status.is_empty());

        let with_path = Pseudo {
            path: Some(BytesStr::from_static("/")),
            ..Default::default()
        };
        assert!(!with_path.is_empty());
    }

    /// A trailers frame built by us is always pseudo-empty. After HPACK
    /// decode of a malicious peer's HEADERS frame carrying trailers, the
    /// pseudo block can be non-empty — mirror that with `pseudo_mut` and
    /// verify the guard precondition used by `Recv::recv_trailers` fires.
    #[test]
    fn trailers_with_injected_pseudo_is_detected() {
        let mut frame = Headers::trailers(StreamId::from(1), HeaderMap::new());
        assert!(
            frame.pseudo().is_empty(),
            "freshly-built trailers must have an empty pseudo block"
        );

        // Simulate what HPACK decode would do for malformed trailers
        // carrying a pseudo-header (here `:status`).
        frame.pseudo_mut().status = Some(StatusCode::OK);
        assert!(
            !frame.pseudo().is_empty(),
            "trailers with an injected pseudo must NOT report is_empty"
        );
    }
}
