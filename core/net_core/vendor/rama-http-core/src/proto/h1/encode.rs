use std::{fmt, io::IoSlice, sync::Arc};

use rama_core::{
    bytes::{
        Buf, Bytes,
        buf::{Chain, Take},
    },
    telemetry::tracing::{debug, trace},
};
use rama_http_types::{
    HeaderMap, HeaderName,
    header::trailer::{ForbiddenTrailers, is_sent_in_trailers},
};

use super::{io::WriteBuf, role::write_header_field};
use crate::headers::ConnectionHeaderNames;

type StaticBuf = &'static [u8];

/// Encoders to handle different Transfer-Encodings.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Encoder {
    kind: Kind,
    is_last: bool,
}

#[derive(Debug)]
pub(crate) struct EncodedBuf<B> {
    kind: BufKind<B>,
}

#[derive(Debug)]
pub(crate) struct NotEof(u64);

#[derive(Debug, PartialEq, Clone)]
enum Kind {
    /// An Encoder for when Transfer-Encoding includes `chunked`.
    Chunked(ChunkedTrailers),
    /// An Encoder for when Content-Length is set.
    ///
    /// Enforces that the body is not longer than the Content-Length header.
    Length(u64),
    /// An Encoder for when neither Content-Length nor Chunked encoding is set.
    ///
    /// This is mostly only used with HTTP/1.0 with a length. This kind requires
    /// the connection to be closed when the body is finished.
    CloseDelimited,
}

/// What the trailer section of a chunked message sends.
#[derive(Debug, Clone, Default)]
struct ChunkedTrailers {
    /// Fields the message's `Connection` nominates, which stay with this hop.
    nominated: ConnectionHeaderNames,
    allowed: Option<Arc<ForbiddenTrailers>>,
}

impl ChunkedTrailers {
    fn sends(&self, name: &HeaderName) -> bool {
        !self.nominated.contains(name) && is_sent_in_trailers(name, self.allowed.as_deref())
    }
}

impl PartialEq for ChunkedTrailers {
    fn eq(&self, other: &Self) -> bool {
        self.nominated == other.nominated
            && match (&self.allowed, &other.allowed) {
                (Some(this), Some(other)) => Arc::ptr_eq(this, other),
                (this, other) => this.is_none() && other.is_none(),
            }
    }
}

#[derive(Debug)]
enum BufKind<B> {
    Exact(B),
    Limited(Take<B>),
    Chunked(Chain<Chain<ChunkSize, B>, StaticBuf>),
    ChunkedEnd(StaticBuf),
    Trailers(Chain<Chain<StaticBuf, Bytes>, StaticBuf>),
}

impl Encoder {
    fn new(kind: Kind) -> Self {
        Self {
            kind,
            is_last: false,
        }
    }
    pub(crate) fn chunked() -> Self {
        Self::new(Kind::Chunked(ChunkedTrailers::default()))
    }

    pub(crate) fn length(len: u64) -> Self {
        Self::new(Kind::Length(len))
    }

    pub(crate) fn close_delimited() -> Self {
        Self::new(Kind::CloseDelimited)
    }

    rama_utils::macros::generate_set_and_with! {
        /// Keep the fields `Connection` nominates out of a chunked message's trailers.
        pub(crate) fn nominated_fields(mut self, nominated: ConnectionHeaderNames) -> Self {
            if let Kind::Chunked(trailers) = &mut self.kind {
                trailers.nominated = nominated;
            }
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Send the trailer fields `allowed` opts in, as well as those allowed in trailers.
        pub(crate) fn allowed_trailers(mut self, allowed: Option<Arc<ForbiddenTrailers>>) -> Self {
            if let Kind::Chunked(trailers) = &mut self.kind {
                trailers.allowed = allowed;
            }
            self
        }
    }

    pub(crate) fn is_eof(&self) -> bool {
        matches!(self.kind, Kind::Length(0))
    }

    pub(crate) fn set_last(mut self, is_last: bool) -> Self {
        self.is_last = is_last;
        self
    }

    pub(crate) fn is_last(&self) -> bool {
        self.is_last
    }

    pub(crate) fn is_close_delimited(&self) -> bool {
        matches!(self.kind, Kind::CloseDelimited)
    }

    #[cfg(test)]
    pub(crate) fn is_chunked(&self) -> bool {
        matches!(self.kind, Kind::Chunked(_))
    }

    pub(crate) fn end<B>(&self) -> Result<Option<EncodedBuf<B>>, NotEof> {
        match self.kind {
            Kind::CloseDelimited | Kind::Length(0) => Ok(None),
            Kind::Chunked(_) => Ok(Some(EncodedBuf {
                kind: BufKind::ChunkedEnd(b"0\r\n\r\n"),
            })),
            Kind::Length(n) => Err(NotEof(n)),
        }
    }

    pub(crate) fn encode<B>(&mut self, msg: B) -> EncodedBuf<B>
    where
        B: Buf,
    {
        let len = msg.remaining();
        debug_assert!(len > 0, "encode() called with empty buf");

        let kind = match &mut self.kind {
            Kind::Chunked(_) => {
                trace!("encoding chunked {}B", len);
                let buf = ChunkSize::new(len)
                    .chain(msg)
                    .chain(b"\r\n" as &'static [u8]);
                BufKind::Chunked(buf)
            }
            Kind::Length(remaining) => {
                trace!("sized write, len = {}", len);
                if len as u64 > *remaining {
                    let limit = *remaining as usize;
                    *remaining = 0;
                    BufKind::Limited(msg.take(limit))
                } else {
                    *remaining -= len as u64;
                    BufKind::Exact(msg)
                }
            }
            Kind::CloseDelimited => {
                trace!("close delimited write {}B", len);
                BufKind::Exact(msg)
            }
        };
        EncodedBuf { kind }
    }

    pub(crate) fn encode_trailers<B>(
        &self,
        trailers: &HeaderMap,
        title_case_headers: bool,
    ) -> Option<EncodedBuf<B>> {
        trace!("encoding trailers");
        match &self.kind {
            Kind::Chunked(policy) => {
                // Sized exactly, so the buffer converts to `Bytes` without another allocation.
                let len: usize = trailers
                    .iter()
                    .filter(|(name, _)| policy.sends(name))
                    .map(|(name, value)| name.as_str().len() + value.len() + 4)
                    .sum();
                if len == 0 {
                    debug!("no trailer field sent");
                    return None;
                }

                let mut buf = Vec::with_capacity(len);
                for (name, value) in trailers {
                    if policy.sends(name) {
                        write_header_field(name, value, title_case_headers, &mut buf);
                    } else {
                        debug!("trailer field not sent: {}", name);
                    }
                }

                debug_assert_eq!(buf.len(), buf.capacity(), "sized exactly");
                Some(EncodedBuf {
                    kind: BufKind::Trailers(b"0\r\n".chain(Bytes::from(buf)).chain(b"\r\n")),
                })
            }
            Kind::CloseDelimited | Kind::Length(_) => {
                debug!("attempted to encode trailers for non-chunked response");
                None
            }
        }
    }

    pub(super) fn encode_and_end<B>(&self, msg: B, dst: &mut WriteBuf<EncodedBuf<B>>) -> bool
    where
        B: Buf,
    {
        let len = msg.remaining();
        debug_assert!(len > 0, "encode() called with empty buf");

        match self.kind {
            Kind::Chunked(_) => {
                trace!("encoding chunked {}B", len);
                let buf = ChunkSize::new(len)
                    .chain(msg)
                    .chain(b"\r\n0\r\n\r\n" as &'static [u8]);
                dst.buffer(buf);
                !self.is_last
            }
            Kind::Length(remaining) => {
                use std::cmp::Ordering;

                trace!("sized write, len = {}", len);
                match (len as u64).cmp(&remaining) {
                    Ordering::Equal => {
                        dst.buffer(msg);
                        !self.is_last
                    }
                    Ordering::Greater => {
                        dst.buffer(msg.take(remaining as usize));
                        !self.is_last
                    }
                    Ordering::Less => {
                        dst.buffer(msg);
                        false
                    }
                }
            }
            Kind::CloseDelimited => {
                trace!("close delimited write {}B", len);
                dst.buffer(msg);
                false
            }
        }
    }
}

impl<B> Buf for EncodedBuf<B>
where
    B: Buf,
{
    #[inline]
    fn remaining(&self) -> usize {
        match &self.kind {
            BufKind::Exact(b) => b.remaining(),
            BufKind::Limited(b) => b.remaining(),
            BufKind::Chunked(b) => b.remaining(),
            BufKind::ChunkedEnd(b) => b.remaining(),
            BufKind::Trailers(b) => b.remaining(),
        }
    }

    #[inline]
    fn chunk(&self) -> &[u8] {
        match &self.kind {
            BufKind::Exact(b) => b.chunk(),
            BufKind::Limited(b) => b.chunk(),
            BufKind::Chunked(b) => b.chunk(),
            BufKind::ChunkedEnd(b) => b.chunk(),
            BufKind::Trailers(b) => b.chunk(),
        }
    }

    #[inline]
    fn advance(&mut self, cnt: usize) {
        match &mut self.kind {
            BufKind::Exact(b) => b.advance(cnt),
            BufKind::Limited(b) => b.advance(cnt),
            BufKind::Chunked(b) => b.advance(cnt),
            BufKind::ChunkedEnd(b) => b.advance(cnt),
            BufKind::Trailers(b) => b.advance(cnt),
        }
    }

    #[inline]
    fn chunks_vectored<'t>(&'t self, dst: &mut [IoSlice<'t>]) -> usize {
        match &self.kind {
            BufKind::Exact(b) => b.chunks_vectored(dst),
            BufKind::Limited(b) => b.chunks_vectored(dst),
            BufKind::Chunked(b) => b.chunks_vectored(dst),
            BufKind::ChunkedEnd(b) => b.chunks_vectored(dst),
            BufKind::Trailers(b) => b.chunks_vectored(dst),
        }
    }
}

#[cfg(target_pointer_width = "32")]
const USIZE_BYTES: usize = 4;

#[cfg(target_pointer_width = "64")]
const USIZE_BYTES: usize = 8;

// each byte will become 2 hex
const CHUNK_SIZE_MAX_BYTES: usize = USIZE_BYTES * 2;

#[derive(Clone, Copy)]
struct ChunkSize {
    bytes: [u8; CHUNK_SIZE_MAX_BYTES + 2],
    pos: u8,
    len: u8,
}

impl ChunkSize {
    fn new(len: usize) -> Self {
        use std::fmt::Write;
        let mut size = Self {
            bytes: [0; CHUNK_SIZE_MAX_BYTES + 2],
            pos: 0,
            len: 0,
        };
        let _write_result = write!(&mut size, "{len:X}\r\n");
        debug_assert!(
            _write_result.is_ok(),
            "CHUNK_SIZE_MAX_BYTES should fit any usize: {_write_result:?}",
        );
        size
    }
}

impl Buf for ChunkSize {
    #[inline]
    fn remaining(&self) -> usize {
        (self.len - self.pos).into()
    }

    #[inline]
    fn chunk(&self) -> &[u8] {
        &self.bytes[self.pos.into()..self.len.into()]
    }

    #[inline]
    fn advance(&mut self, cnt: usize) {
        assert!(cnt <= self.remaining());
        self.pos += cnt as u8; // just asserted cnt fits in u8
    }
}

impl fmt::Debug for ChunkSize {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ChunkSize")
            .field("bytes", &&self.bytes[..self.len.into()])
            .field("pos", &self.pos)
            .finish()
    }
}

impl fmt::Write for ChunkSize {
    fn write_str(&mut self, num: &str) -> fmt::Result {
        use std::io::Write;
        _ = (&mut self.bytes[self.len.into()..]).write_all(num.as_bytes());
        self.len += num.len() as u8; // safe because bytes is never bigger than 256
        Ok(())
    }
}

impl<B: Buf> From<B> for EncodedBuf<B> {
    fn from(buf: B) -> Self {
        Self {
            kind: BufKind::Exact(buf),
        }
    }
}

impl<B: Buf> From<Take<B>> for EncodedBuf<B> {
    fn from(buf: Take<B>) -> Self {
        Self {
            kind: BufKind::Limited(buf),
        }
    }
}

impl<B: Buf> From<Chain<Chain<ChunkSize, B>, StaticBuf>> for EncodedBuf<B> {
    fn from(buf: Chain<Chain<ChunkSize, B>, StaticBuf>) -> Self {
        Self {
            kind: BufKind::Chunked(buf),
        }
    }
}

impl fmt::Display for NotEof {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "early end, expected {} more bytes", self.0)
    }
}

impl std::error::Error for NotEof {}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use rama_core::bytes::BufMut;
    use rama_http_types::{
        HeaderMap, HeaderName, HeaderValue,
        header::{
            AUTHORIZATION, CACHE_CONTROL, CONTENT_ENCODING, CONTENT_LENGTH, CONTENT_RANGE,
            CONTENT_TYPE, HOST, MAX_FORWARDS, SET_COOKIE, TE, TRAILER, TRANSFER_ENCODING,
            trailer::ForbiddenTrailers,
        },
    };

    use super::Encoder;
    use crate::proto::h1::io::Cursor;

    #[test]
    fn chunked() {
        let mut encoder = Encoder::chunked();
        let mut dst = Vec::new();

        let msg1 = b"foo bar".as_ref();
        let buf1 = encoder.encode(msg1);
        dst.put(buf1);
        assert_eq!(dst, b"7\r\nfoo bar\r\n");

        let msg2 = b"baz quux herp".as_ref();
        let buf2 = encoder.encode(msg2);
        dst.put(buf2);

        assert_eq!(dst, b"7\r\nfoo bar\r\nD\r\nbaz quux herp\r\n");

        let end = encoder.end::<Cursor<Vec<u8>>>().unwrap().unwrap();
        dst.put(end);

        assert_eq!(
            dst,
            b"7\r\nfoo bar\r\nD\r\nbaz quux herp\r\n0\r\n\r\n".as_ref()
        );
    }

    #[test]
    fn length() {
        let max_len = 8;
        let mut encoder = Encoder::length(max_len as u64);
        let mut dst = Vec::new();

        let msg1 = b"foo bar".as_ref();
        let buf1 = encoder.encode(msg1);
        dst.put(buf1);

        assert_eq!(dst, b"foo bar");
        assert!(!encoder.is_eof());
        encoder.end::<()>().unwrap_err();

        let msg2 = b"baz".as_ref();
        let buf2 = encoder.encode(msg2);
        dst.put(buf2);

        assert_eq!(dst.len(), max_len);
        assert_eq!(dst, b"foo barb");
        assert!(encoder.is_eof());
        assert!(encoder.end::<()>().unwrap().is_none());
    }

    #[test]
    fn eof() {
        let mut encoder = Encoder::close_delimited();
        let mut dst = Vec::new();

        let msg1 = b"foo bar".as_ref();
        let buf1 = encoder.encode(msg1);
        dst.put(buf1);

        assert_eq!(dst, b"foo bar");
        assert!(!encoder.is_eof());
        encoder.end::<()>().unwrap();

        let msg2 = b"baz".as_ref();
        let buf2 = encoder.encode(msg2);
        dst.put(buf2);

        assert_eq!(dst, b"foo barbaz");
        assert!(!encoder.is_eof());
        encoder.end::<()>().unwrap();
    }

    fn encode<'a>(
        encoder: &Encoder,
        trailers: impl IntoIterator<Item = (&'a str, &'a str)>,
    ) -> Option<Vec<u8>> {
        let mut headers = HeaderMap::new();
        for (name, value) in trailers {
            headers.append(
                HeaderName::from_bytes(name.as_bytes()).unwrap(),
                HeaderValue::from_str(value).unwrap(),
            );
        }
        let mut dst = Vec::new();
        dst.put(encoder.encode_trailers::<&[u8]>(&headers, false)?);
        Some(dst)
    }

    /// Declaring trailers in `Trailer` is only a SHOULD (RFC 9110 §6.6.2): undeclared ones
    /// are sent as well, as over HTTP/2 and HTTP/3.
    #[test]
    fn chunked_trailers_need_no_declaration() {
        let encoded = encode(
            &Encoder::chunked(),
            [
                ("chunky-trailer", "header data"),
                ("chunky-trailer-2", "more"),
                ("chunky-trailer", "second"),
            ],
        );
        assert_eq!(
            encoded.as_deref(),
            Some(&b"0\r\nchunky-trailer: header data\r\nchunky-trailer: second\r\nchunky-trailer-2: more\r\n\r\n"[..])
        );
    }

    #[test]
    fn chunked_with_standard_trailers() {
        let encoded = encode(
            &Encoder::chunked(),
            [
                ("accept-ranges", "bytes"),
                ("etag", "\"generated-after-body\""),
            ],
        );
        assert_eq!(
            encoded.as_deref(),
            Some(&b"0\r\naccept-ranges: bytes\r\netag: \"generated-after-body\"\r\n\r\n"[..])
        );
    }

    /// Fields not allowed in trailers are dropped, unless the message opts them in; those that
    /// frame or route a message never go out.
    #[test]
    fn chunked_trailers_follow_the_trailer_policy() {
        let fields = [
            AUTHORIZATION,
            CACHE_CONTROL,
            CONTENT_ENCODING,
            CONTENT_LENGTH,
            CONTENT_RANGE,
            CONTENT_TYPE,
            HOST,
            MAX_FORWARDS,
            SET_COOKIE,
            TRAILER,
            TRANSFER_ENCODING,
            TE,
        ];
        let trailers = fields.iter().map(|name| (name.as_str(), "header data"));
        assert_eq!(encode(&Encoder::chunked(), trailers.clone()), None);

        let all = Encoder::chunked().with_allowed_trailers(Arc::new(ForbiddenTrailers::AllowAll));
        let sent = String::from_utf8(encode(&all, trailers.clone()).unwrap()).unwrap();
        for name in &fields {
            let framing = [CONTENT_LENGTH, HOST, TRANSFER_ENCODING, TE].contains(name);
            assert_eq!(!sent.contains(&format!("{name}:")), framing, "{name}");
        }

        let only = Encoder::chunked().with_allowed_trailers(Arc::new(
            ForbiddenTrailers::AllowSome([SET_COOKIE, HOST].into()),
        ));
        assert_eq!(
            encode(&only, trailers).as_deref(),
            Some(&b"0\r\nset-cookie: header data\r\n\r\n"[..])
        );
    }

    #[test]
    fn chunked_trailers_leave_connection_nominated_fields_out() {
        let encoder = Encoder::chunked()
            .with_nominated_fields([HeaderName::from_static("x-hop")].into_iter().collect());
        assert_eq!(
            encode(&encoder, [("x-hop", "1"), ("x-kept", "2")]).as_deref(),
            Some(&b"0\r\nx-kept: 2\r\n\r\n"[..])
        );
    }

    #[test]
    fn chunked_with_title_case_headers() {
        let headers = HeaderMap::from_iter([(
            HeaderName::from_static("chunky-trailer"),
            HeaderValue::from_static("header data"),
        )]);
        let buf1 = Encoder::chunked()
            .encode_trailers::<&[u8]>(&headers, true)
            .unwrap();

        let mut dst = Vec::new();
        dst.put(buf1);
        assert_eq!(dst, b"0\r\nChunky-Trailer: header data\r\n\r\n");
    }

    #[test]
    fn non_chunked_messages_send_no_trailers() {
        assert_eq!(encode(&Encoder::length(3), [("x-checksum", "abc")]), None);
        assert_eq!(
            encode(&Encoder::close_delimited(), [("x-checksum", "abc")]),
            None
        );
    }
}
