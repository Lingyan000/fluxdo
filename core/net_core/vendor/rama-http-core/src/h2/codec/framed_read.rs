use crate::h2::proto::Error;

use rama_core::extensions::ExtensionsRef;
use rama_http_types::proto::h2::frame::{self, Frame, Kind, Reason};
use rama_http_types::proto::h2::frame::{
    DEFAULT_MAX_FRAME_SIZE, DEFAULT_SETTINGS_HEADER_TABLE_SIZE, MAX_MAX_FRAME_SIZE,
};
use rama_http_types::proto::h2::hpack;

use rama_core::futures::Stream;

use rama_core::bytes::{Buf, BytesMut};
use rama_core::stream::codec::FramedRead as InnerFramedRead;
use rama_core::stream::codec::{LengthDelimitedCodec, LengthDelimitedCodecError};
use rama_core::telemetry::tracing;

use std::io;

use std::pin::Pin;
use std::task::{Context, Poll};
use tokio::{io::AsyncRead, task::coop};

// 16 MB "sane default" taken from golang http2
const DEFAULT_SETTINGS_MAX_HEADER_LIST_SIZE: usize = 16 << 20;

#[derive(Debug)]
pub(super) struct FramedRead<T> {
    inner: InnerFramedRead<T, LengthDelimitedCodec>,

    decoder: FrameDecoder,

    /// Bytes of the complete frames of the header block being received.
    header_bytes: u64,

    /// Header blocks that ended, completed or not: it tells consecutive heads apart.
    header_blocks: u64,
}

/// A request head the peer started but did not complete.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct HeadProgress {
    /// Bytes of it received so far.
    pub(crate) bytes: u64,
    /// The header block it belongs to.
    pub(crate) block: u64,
    /// Whether the bytes surely belong to a header block, rather than to a
    /// frame whose type has not arrived yet.
    pub(crate) certain: bool,
}

#[derive(Debug)]
struct FrameDecoder {
    // hpack decoder state
    hpack: hpack::Decoder,

    max_header_list_size: usize,

    max_continuation_frames: usize,

    partial: Option<Partial>,

    recv_alt_svc: bool,
    observe_early_frames: bool,
}

/// Partially loaded headers frame
#[derive(Debug)]
struct Partial {
    /// Empty frame
    frame: Continuable,

    /// Partial header payload
    buf: BytesMut,

    continuation_frames_count: usize,
}

#[derive(Debug)]
enum Continuable {
    Headers(frame::Headers),
    PushPromise(frame::PushPromise),
}

impl<T> FramedRead<T> {
    pub(super) fn new(inner: InnerFramedRead<T, LengthDelimitedCodec>) -> Self {
        let decoder = FrameDecoder::new(inner.decoder().max_frame_length());
        Self {
            inner,
            decoder,
            header_bytes: 0,
            header_blocks: 0,
        }
    }

    /// The header block in progress, including buffered fragments so a peer
    /// cannot evade the deadline with partial frames.
    pub(super) fn head_progress(&self) -> Option<HeadProgress> {
        let buffered = self.inner.read_buffer();
        // Only the first buffered frame can be incomplete or undecoded head bytes.
        let frame = match buffered.get(..3) {
            Some(&[a, b, c]) => {
                let len = u64::from(u32::from_be_bytes([0, a, b, c]));
                (buffered.len() as u64).min(len.saturating_add(frame::HEADER_LEN as u64))
            }
            _ => buffered.len() as u64,
        };
        let block = self.header_blocks;
        if self.decoder.partial.is_some() {
            return Some(HeadProgress {
                bytes: self.header_bytes.saturating_add(frame),
                block,
                certain: true,
            });
        }
        match buffered.get(3).copied() {
            Some(kind) if kind == Kind::Headers as u8 => Some(HeadProgress {
                bytes: frame,
                block,
                certain: true,
            }),
            None if !buffered.is_empty() => Some(HeadProgress {
                bytes: frame,
                block,
                certain: false,
            }),
            _ => None,
        }
    }

    pub(super) fn set_observe_early_frames(&mut self, enabled: bool) {
        self.decoder.observe_early_frames = enabled;
    }

    pub(super) fn set_recv_alt_svc(&mut self, enabled: bool) {
        self.decoder.recv_alt_svc = enabled;
    }

    pub(super) fn into_read_buffer(self) -> BytesMut {
        self.inner.into_parts().read_buf
    }

    pub(super) fn get_ref(&self) -> &T {
        self.inner.get_ref()
    }

    pub(super) fn get_mut(&mut self) -> &mut T {
        self.inner.get_mut()
    }

    /// Returns the current max frame size setting
    #[inline]
    pub(super) fn max_frame_size(&self) -> usize {
        self.inner.decoder().max_frame_length()
    }

    /// Updates the max frame size setting.
    ///
    /// Must be within 16,384 and 16,777,215.
    #[inline]
    pub(super) fn set_max_frame_size(&mut self, val: usize) {
        assert!(DEFAULT_MAX_FRAME_SIZE as usize <= val && val <= MAX_MAX_FRAME_SIZE as usize);
        self.inner.decoder_mut().set_max_frame_length(val);
        // Update max CONTINUATION frames too, since its based on this
        self.decoder.set_max_frame_size(val);
    }

    /// Update the max header list size setting.
    #[inline]
    pub(super) fn set_max_header_list_size(&mut self, val: usize) {
        self.decoder
            .set_max_header_list_size(val, self.max_frame_size());
    }

    /// Update the header table size setting.
    #[inline]
    pub(super) fn set_header_table_size(&mut self, val: usize) {
        self.decoder.set_header_table_size(val);
    }
}

impl<T: ExtensionsRef> ExtensionsRef for FramedRead<T> {
    fn extensions(&self) -> &rama_core::extensions::Extensions {
        self.inner.get_ref().extensions()
    }
}

fn calc_max_continuation_frames(header_max: usize, frame_max: usize) -> usize {
    // At least this many frames needed to use max header list size
    let min_frames_for_list = (header_max / frame_max).max(1);
    // Some padding for imperfectly packed frames
    // 25% without floats
    let padding = min_frames_for_list >> 2;
    min_frames_for_list.saturating_add(padding).max(5)
}

impl FrameDecoder {
    fn new(max_frame_size: usize) -> Self {
        let max_header_list_size = DEFAULT_SETTINGS_MAX_HEADER_LIST_SIZE;
        Self {
            hpack: hpack::Decoder::new(DEFAULT_SETTINGS_HEADER_TABLE_SIZE),
            max_header_list_size,
            max_continuation_frames: calc_max_continuation_frames(
                max_header_list_size,
                max_frame_size,
            ),
            partial: None,
            recv_alt_svc: true,
            observe_early_frames: false,
        }
    }

    fn set_max_frame_size(&mut self, val: usize) {
        self.max_continuation_frames = calc_max_continuation_frames(self.max_header_list_size, val);
    }

    fn set_max_header_list_size(&mut self, val: usize, max_frame_size: usize) {
        self.max_header_list_size = val;
        // Update max CONTINUATION frames too, since its based on this
        self.max_continuation_frames = calc_max_continuation_frames(val, max_frame_size);
    }

    fn set_header_table_size(&mut self, val: usize) {
        self.hpack.queue_size_update(val);
    }

    fn decode(&mut self, bytes: BytesMut) -> Result<Option<Frame>, Error> {
        decode_frame(self, bytes)
    }
}

/// Decodes a frame.
///
/// This function is intentionally de-generified and outlined because it is very large.
fn decode_frame(decoder: &mut FrameDecoder, mut bytes: BytesMut) -> Result<Option<Frame>, Error> {
    let span = tracing::trace_span!("FramedRead::decode_frame", offset = bytes.len());
    let _e = span.enter();

    tracing::trace!("decoding frame from {}B", bytes.len());

    // Parse the head
    let head = frame::Head::parse(&bytes).map_err(|e| {
        proto_err!(conn: "failed to parse frame head; err={:?}", e);
        Error::library_go_away(Reason::PROTOCOL_ERROR)
    })?;

    if decoder.partial.is_some() && head.kind() != Kind::Continuation {
        proto_err!(conn: "expected CONTINUATION, got {:?}", head.kind());
        return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
    }

    let kind = head.kind();

    tracing::trace!("frame kind = {kind:?}");

    macro_rules! header_block {
        ($frame:ident, $head:ident, $bytes:ident) => ({
            // Drop the frame header
            $bytes.advance(frame::HEADER_LEN);

            // Parse the header frame w/o parsing the payload
            let (mut frame, mut payload) = match frame::$frame::load($head, $bytes) {
                Ok(res) => res,
                Err(frame::Error::InvalidDependencyId) => {
                    proto_err!(stream: "invalid HEADERS dependency ID");
                    // A stream cannot depend on itself. An endpoint MUST
                    // treat this as a stream error (Section 5.4.2) of type
                    // `PROTOCOL_ERROR`.
                    return Err(Error::library_reset($head.stream_id(), Reason::PROTOCOL_ERROR));
                },
                Err(e) => {
                    proto_err!(conn: "failed to load frame; err={:?}", e);
                    return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
                }
            };

            let is_end_headers = frame.is_end_headers();

            // Load the HPACK encoded headers
            match frame.load_hpack(&mut payload, decoder.max_header_list_size, &mut decoder.hpack) {
                Ok(_) => {},
                Err(frame::Error::Hpack(hpack::DecoderError::NeedMore(_))) if !is_end_headers => {},
                Err(frame::Error::MalformedMessage) => {
                    let id = $head.stream_id();
                    proto_err!(stream: "malformed header block; stream={:?}", id);
                    return Err(Error::library_reset(id, Reason::PROTOCOL_ERROR));
                },
                Err(frame::Error::HeaderListWayTooLarge) => {
                    proto_err!(conn: "decoded header list size over abuse limit");
                    return Err(Error::library_go_away_data(
                        Reason::ENHANCE_YOUR_CALM,
                        "header_list_way_too_large",
                    ));
                },
                Err(e) => {
                    proto_err!(conn: "failed HPACK decoding; err={:?}", e);
                    return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
                }
            }

            if is_end_headers {
                frame.into()
            } else {
                tracing::trace!("loaded partial header block");
                // Defer returning the frame
                decoder.partial = Some(Partial {
                    frame: Continuable::$frame(frame),
                    buf: payload,
                    continuation_frames_count: 0,
                });

                return Ok(None);
            }
        });
    }

    let frame = match kind {
        Kind::Settings => {
            let res = frame::Settings::load_observed(
                head,
                &bytes[frame::HEADER_LEN..],
                decoder.observe_early_frames,
            );

            res.map_err(|e| {
                proto_err!(conn: "failed to load SETTINGS frame; err={:?}", e);
                // RFC 9113 §6.5.2: SETTINGS_INITIAL_WINDOW_SIZE > 2^31-1
                // MUST be treated as a FLOW_CONTROL_ERROR.
                let reason = match e {
                    frame::Error::InvalidInitialWindowSize => Reason::FLOW_CONTROL_ERROR,
                    _ => Reason::PROTOCOL_ERROR,
                };
                Error::library_go_away(reason)
            })?
            .into()
        }
        Kind::Ping => {
            let res = frame::Ping::load(head, &bytes[frame::HEADER_LEN..]);

            res.map_err(|e| {
                proto_err!(conn: "failed to load PING frame; err={:?}", e);
                Error::library_go_away(Reason::PROTOCOL_ERROR)
            })?
            .into()
        }
        Kind::WindowUpdate => {
            let res = frame::WindowUpdate::load(head, &bytes[frame::HEADER_LEN..]);

            res.map_err(|e| {
                proto_err!(conn: "failed to load WINDOW_UPDATE frame; err={:?}", e);
                Error::library_go_away(Reason::PROTOCOL_ERROR)
            })?
            .into()
        }
        Kind::AltSvc => {
            if !decoder.recv_alt_svc {
                return Ok(None);
            }
            bytes.advance(frame::HEADER_LEN);
            match frame::AltSvc::load(head, bytes.freeze()) {
                Ok(frame) => frame.into(),
                Err(frame::Error::InvalidStreamId) => {
                    // Invalid origin/stream associations MUST be ignored
                    // (RFC 7838 §4), without affecting stream state.
                    return Ok(None);
                }
                Err(error) => {
                    // Known frames must contain their mandatory payload
                    // fields (RFC 9113 §4.2).
                    proto_err!(conn: "truncated ALTSVC frame; err={:?}", error);
                    return Err(Error::library_go_away(Reason::FRAME_SIZE_ERROR));
                }
            }
        }
        Kind::Data => {
            bytes.advance(frame::HEADER_LEN);
            let res = frame::Data::load(head, bytes.freeze());

            // TODO: Should this always be connection level? Probably not...
            res.map_err(|e| {
                proto_err!(conn: "failed to load DATA frame; err={:?}", e);
                Error::library_go_away(Reason::PROTOCOL_ERROR)
            })?
            .into()
        }
        Kind::Headers => header_block!(Headers, head, bytes),
        Kind::Reset => {
            let res = frame::Reset::load(head, &bytes[frame::HEADER_LEN..]);
            res.map_err(|e| {
                proto_err!(conn: "failed to load RESET frame; err={:?}", e);
                Error::library_go_away(Reason::PROTOCOL_ERROR)
            })?
            .into()
        }
        Kind::GoAway => {
            let res = frame::GoAway::load(head, &bytes[frame::HEADER_LEN..]);
            res.map_err(|e| {
                proto_err!(conn: "failed to load GO_AWAY frame; err={:?}", e);
                Error::library_go_away(Reason::PROTOCOL_ERROR)
            })?
            .into()
        }
        Kind::PushPromise => header_block!(PushPromise, head, bytes),
        Kind::Priority => {
            if head.stream_id() == 0 {
                // Invalid stream identifier
                proto_err!(conn: "invalid stream ID 0");
                return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
            }

            match frame::Priority::load(head, &bytes[frame::HEADER_LEN..]) {
                Ok(frame) => frame.into(),
                Err(frame::Error::InvalidDependencyId) => {
                    // A stream cannot depend on itself. An endpoint MUST
                    // treat this as a stream error (Section 5.4.2) of type
                    // `PROTOCOL_ERROR`.
                    let id = head.stream_id();
                    proto_err!(stream: "PRIORITY invalid dependency ID; stream={:?}", id);
                    return Err(Error::library_reset(id, Reason::PROTOCOL_ERROR));
                }
                Err(e) => {
                    proto_err!(conn: "failed to load PRIORITY frame; err={:?};", e);
                    return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
                }
            }
        }
        Kind::Continuation => {
            let is_end_headers = (head.flag() & 0x4) == 0x4;

            let Some(mut partial) = decoder.partial.take() else {
                proto_err!(conn: "received unexpected CONTINUATION frame");
                return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
            };

            // The stream identifiers must match
            if partial.frame.stream_id() != head.stream_id() {
                proto_err!(conn: "CONTINUATION frame stream ID does not match previous frame stream ID");
                return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
            }

            // Check for CONTINUATION flood
            if is_end_headers {
                partial.continuation_frames_count = 0;
            } else {
                let cnt = partial.continuation_frames_count + 1;
                if cnt > decoder.max_continuation_frames {
                    tracing::debug!(
                        "too_many_continuations, max = {}",
                        decoder.max_continuation_frames
                    );
                    return Err(Error::library_go_away_data(
                        Reason::ENHANCE_YOUR_CALM,
                        "too_many_continuations",
                    ));
                } else {
                    partial.continuation_frames_count = cnt;
                }
            }

            // Extend the buf
            if partial.buf.is_empty() {
                partial.buf = bytes.split_off(frame::HEADER_LEN);
            } else {
                if partial.frame.is_over_size() {
                    // If there was left over bytes previously, they may be
                    // needed to continue decoding, even though we will
                    // be ignoring this frame. This is done to keep the HPACK
                    // decoder state up-to-date.
                    //
                    // Still, we need to be careful, because if a malicious
                    // attacker were to try to send a gigantic string, such
                    // that it fits over multiple header blocks, we could
                    // grow memory uncontrollably again, and that'd be a shame.
                    //
                    // Instead, we use a simple heuristic to determine if
                    // we should continue to ignore decoding, or to tell
                    // the attacker to go away.
                    if partial.buf.len() + bytes.len() > decoder.max_header_list_size {
                        proto_err!(conn: "CONTINUATION frame header block size over ignorable limit");
                        return Err(Error::library_go_away(Reason::COMPRESSION_ERROR));
                    }
                }
                partial.buf.extend_from_slice(&bytes[frame::HEADER_LEN..]);
            }

            match partial.frame.load_hpack(
                &mut partial.buf,
                decoder.max_header_list_size,
                &mut decoder.hpack,
            ) {
                Ok(_) => {}
                Err(frame::Error::Hpack(hpack::DecoderError::NeedMore(_))) if !is_end_headers => {}
                Err(frame::Error::MalformedMessage) => {
                    let id = head.stream_id();
                    proto_err!(stream: "malformed CONTINUATION frame; stream={:?}", id);
                    return Err(Error::library_reset(id, Reason::PROTOCOL_ERROR));
                }
                Err(frame::Error::HeaderListWayTooLarge) => {
                    proto_err!(conn: "decoded CONTINUATION header list size over abuse limit");
                    return Err(Error::library_go_away_data(
                        Reason::ENHANCE_YOUR_CALM,
                        "header_list_way_too_large",
                    ));
                }
                Err(e) => {
                    proto_err!(conn: "failed HPACK decoding; err={:?}", e);
                    return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
                }
            }

            if is_end_headers {
                partial.frame.into()
            } else {
                decoder.partial = Some(partial);
                return Ok(None);
            }
        }
        Kind::Unknown => {
            // Unknown frames are ignored
            return Ok(None);
        }
    };

    Ok(Some(frame))
}

impl<T> Stream for FramedRead<T>
where
    T: AsyncRead + Unpin,
{
    type Item = Result<Frame, Error>;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let span = tracing::trace_span!("FramedRead::poll_next");
        let _e = span.enter();
        loop {
            tracing::trace!("poll");
            // Buffered extension frames can remain ready without polling the
            // socket. Charge every consumed frame, including ignored ones,
            // so parsing and synchronous observers share the task's budget.
            let budget = ready!(coop::poll_proceed(cx));
            let bytes = match ready!(Pin::new(&mut self.inner).poll_next(cx)) {
                Some(Ok(bytes)) => bytes,
                Some(Err(e)) => return Poll::Ready(Some(Err(map_err(e)))),
                None => return Poll::Ready(None),
            };

            budget.made_progress();
            tracing::trace!("bytes read = {}", bytes.len());
            let in_block = bytes.get(3).is_some_and(|&kind| {
                kind == Kind::Headers as u8
                    || kind == Kind::Continuation as u8
                    || kind == Kind::PushPromise as u8
            });
            let header_bytes = self.header_bytes.saturating_add(bytes.len() as u64);
            let decoded = self.decoder.decode(bytes);
            if self.decoder.partial.is_some() {
                self.header_bytes = header_bytes;
            } else {
                // A block ends when its last frame decodes or is refused.
                if in_block {
                    self.header_blocks = self.header_blocks.wrapping_add(1);
                }
                self.header_bytes = 0;
            }
            if let Some(frame) = decoded? {
                tracing::trace!("frame received: {frame:?}");
                return Poll::Ready(Some(Ok(frame)));
            }
        }
    }
}

fn map_err(err: io::Error) -> Error {
    if err.kind() == io::ErrorKind::InvalidData
        && let Some(custom) = err.get_ref()
        && custom.is::<LengthDelimitedCodecError>()
    {
        return Error::library_go_away(Reason::FRAME_SIZE_ERROR);
    }
    err.into()
}

// ===== impl Continuable =====

impl Continuable {
    fn stream_id(&self) -> frame::StreamId {
        match *self {
            Self::Headers(ref h) => h.stream_id(),
            Self::PushPromise(ref p) => p.stream_id(),
        }
    }

    fn is_over_size(&self) -> bool {
        match *self {
            Self::Headers(ref h) => h.is_over_size(),
            Self::PushPromise(ref p) => p.is_over_size(),
        }
    }

    fn load_hpack(
        &mut self,
        src: &mut BytesMut,
        max_header_list_size: usize,
        decoder: &mut hpack::Decoder,
    ) -> Result<(), frame::Error> {
        match *self {
            Self::Headers(ref mut h) => h.load_hpack(src, max_header_list_size, decoder),
            Self::PushPromise(ref mut p) => p.load_hpack(src, max_header_list_size, decoder),
        }
    }
}

impl<T> From<Continuable> for Frame<T> {
    fn from(cont: Continuable) -> Self {
        match cont {
            Continuable::Headers(mut headers) => {
                headers.set_end_headers();
                headers.into()
            }
            Continuable::PushPromise(mut push) => {
                push.set_end_headers();
                push.into()
            }
        }
    }
}
