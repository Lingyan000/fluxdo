//! Push-driven SSE decoding.
//!
//! [`EventDecoder`] is the decoder itself; [`EventStream`] is a thin
//! [`Stream`] adapter on top of it.
//!
//! [`EventStream`]: super::EventStream
//! [`Stream`]: rama_core::futures::stream::Stream

use crate::sse::event_data::EventDataLineReader;

use super::parser::{RawEventLine, parse_line};
use super::{Event, EventBuildError, EventDataRead};

use memchr::{memchr2, memchr2_iter};
use rama_core::error::{BoxError, BoxErrorExt as _, ErrorContext as _, ErrorExt as _};
use rama_core::error_sink::ErrorSink;
use rama_core::telemetry::tracing;
use rama_utils::macros::generate_set_and_with;
use rama_utils::str::smol_str::SmolStr;
use std::collections::VecDeque;
use std::fmt;
use std::iter::FusedIterator;
use std::sync::Arc;

struct EventBuilder<T: EventDataRead> {
    reader: T::Reader,
    event: Event<T>,
    is_complete: bool,
}

impl<T> fmt::Debug for EventBuilder<T>
where
    T: EventDataRead + fmt::Debug,
    T::Reader: fmt::Debug,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("EventBuilder")
            .field("reader", &self.reader)
            .field("event", &self.event)
            .field("is_complete", &self.is_complete)
            .finish()
    }
}

impl<T: EventDataRead> Default for EventBuilder<T> {
    fn default() -> Self {
        Self {
            reader: T::line_reader(),
            event: Default::default(),
            is_complete: false,
        }
    }
}

impl<T: EventDataRead> EventBuilder<T> {
    /// From the HTML spec
    ///
    /// -> If the field name is "event"
    ///    Set the event type buffer to field value.
    ///
    /// -> If the field name is "data"
    ///    Append the field value to the data buffer, then append a single U+000A LINE FEED (LF)
    ///    character to the data buffer.
    ///
    /// -> If the field name is "id"
    ///    If the field value does not contain U+0000 NULL, then set the last event ID buffer
    ///    to the field value. Otherwise, ignore the field.
    ///
    /// -> If the field name is "retry"
    ///    If the field value consists of only ASCII digits, then interpret the field value as
    ///    an integer in base ten, and set the event stream's reconnection time to that integer.
    ///    Otherwise, ignore the field.
    ///
    /// -> Otherwise
    ///    The field is ignored.
    #[inline]
    fn add(&mut self, line: RawEventLine<'_>) -> Result<(), BoxError> {
        match line {
            RawEventLine::Field(field, val) => match field {
                "data" => {
                    self.reader.read_line(val.unwrap_or(""))?;
                }
                "event" => {
                    // WHATWG: bare `event` (no value) sets the event-type buffer
                    // to the empty string, which then dispatches as the default
                    // `message` event. Modelling that as `None` so the dispatch
                    // path treats it identically to "no event field present".
                    if let Some(v) = val {
                        self.event.try_set_event(v).context("set event value")?;
                    } else {
                        self.event.event = None;
                    }
                }
                "id" => {
                    // WHATWG: bare `id` (no value) sets the last-event-ID buffer
                    // to the empty string; NUL in the id makes the field ignored.
                    if let Some(v) = val {
                        if !v.contains('\u{0000}') {
                            self.event.try_set_id(v).context("set event id")?;
                        }
                    } else {
                        self.event.id = Some(SmolStr::default());
                    }
                }
                "retry" => {
                    // WHATWG: retry value MUST consist of only ASCII digits.
                    // `u64::parse` would otherwise accept a leading `+`.
                    if let Some(v) = val
                        && !v.is_empty()
                        && v.bytes().all(|b| b.is_ascii_digit())
                        && let Ok(ms) = v.parse::<u64>()
                    {
                        self.event.set_retry(ms);
                    }
                }
                _ => {
                    tracing::debug!("ignore unknown SSE field {field}: value = {val:?}",)
                }
            },
            RawEventLine::Comment(comment) => {
                self.event
                    .try_set_comment(comment)
                    .context("set event comment")?;
            }
            RawEventLine::Empty => self.is_complete = true,
        }
        Ok(())
    }

    /// From the HTML spec
    ///
    /// 1. Set the last event ID string of the event source to the value of the last event ID
    ///    buffer. The buffer does not get reset, so the last event ID string of the event source
    ///    remains set to this value until the next time it is set by the server.
    /// 2. If the data buffer is an empty string, set the data buffer and the event type buffer
    ///    to the empty string and return.
    /// 3. If the data buffer's last character is a U+000A LINE FEED (LF) character, then remove
    ///    the last character from the data buffer.
    /// 4. Let event be the result of creating an event using MessageEvent, in the relevant Realm
    ///    of the EventSource object.
    /// 5. Initialize event's type attribute to message, its data attribute to data, its origin
    ///    attribute to the serialization of the origin of the event stream's final URL (i.e., the
    ///    URL after redirects), and its lastEventId attribute to the last event ID string of the
    ///    event source.
    /// 6. If the event type buffer has a value other than the empty string, change the type of
    ///    the newly created event to equal the value of the event type buffer.
    /// 7. Set the data buffer and the event type buffer to the empty string.
    /// 8. Queue a task which, if the readyState attribute is set to a value other than CLOSED,
    ///    dispatches the newly created event at the EventSource object.
    fn try_dispatch(&mut self) -> Result<Event<T>, BoxError> {
        self.is_complete = false;
        let mut event = std::mem::take(&mut self.event);
        if let Some(data) = self.reader.data(event.event.as_deref())? {
            event.set_data(data);
        }
        Ok(event)
    }
}

const UTF8_BOM: [u8; 3] = [0xEF, 0xBB, 0xBF];

/// Decoding pauses once this many events are queued but not yet yielded:
/// a single upstream chunk full of tiny events would otherwise be decoded
/// in one go, an input-controlled memory amplification
/// (and executor monopolization) the chunk size does not bound.
pub(super) const READY_EVENTS_SOFT_CAP: usize = 16;

/// At most this many bytes are decoded per `scan` call.
/// Real HTTP/1 bodies arrive in chunks well below this, so the regular
/// path is unaffected.
pub(super) const SCAN_BYTES_SOFT_CAP: usize = rama_utils::octets::mib(1);

/// Start each scan in a fixed-size block, then grow blocks exponentially.
/// If dense events hit the ready cap, at most this fixed prefix was inspected;
/// sparse input reaches large SIMD-friendly blocks after only a few steps.
const SCAN_INITIAL_BLOCK_SIZE: usize = 1024;

/// Incremental SSE decoder state.
///
/// Consumes raw body chunks as bytes: complete lines are parsed directly out
/// of each scan block (one UTF-8 validation pass and one line-terminator scan,
/// zero allocations per line); only a line or UTF-8 sequence that
/// crosses a chunk boundary is buffered in `carry`.
struct DecodeState<T: EventDataRead> {
    /// partial line (possibly ending in a partial UTF-8 sequence) from prior chunks
    carry: Vec<u8>,
    /// valid UTF-8 prefix of `carry`, always ending at a character boundary;
    /// the remaining suffix is an incomplete sequence of at most three bytes
    // Safety invariant: `carry_valid_up_to <= carry.len()` and
    // `carry[..carry_valid_up_to]` is valid UTF-8.
    carry_valid_up_to: usize,
    /// a CR was the last byte seen: an LF at the start of the next chunk
    /// belongs to that terminator and must be skipped
    pending_cr: bool,
    /// leading BOM check has been resolved
    started: bool,
    builder: EventBuilder<T>,
    /// events decoded but not yet yielded (a single chunk can complete several)
    ready: VecDeque<Event<T>>,
    last_event_id: Option<SmolStr>,
    /// bytes of line input accumulated into the event currently being built
    event_len: usize,
    /// longest single line accepted; `None` leaves memory to a body-wide limit
    max_line_len: Option<usize>,
    /// most line input a single event may accumulate; `None` is unbounded
    max_event_len: Option<usize>,
    /// either limit is set: one test per line instead of two
    limited: bool,
    /// recover from a decode error by skipping to the next event boundary
    /// instead of failing the whole stream; see [`EventDecoder::with_lenient`]
    lenient: bool,
    /// normal decoding, or resynchronising after a lenient-mode fault
    mode: ScanMode,
    /// number of resync episodes (one per discarded run), for observability
    resync_count: usize,
    /// notified once per resync with the error that triggered it
    on_resync: Option<Arc<dyn ErrorSink>>,
}

/// Whether the decoder is decoding normally or, after a lenient-mode fault,
/// skipping input up to the next event boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ScanMode {
    /// Decoding lines into events.
    Normal,
    /// Discarding input up to the next blank line. `saw_content` records
    /// whether the line currently being skipped already had content, so its
    /// own terminator is not mistaken for the empty-line boundary.
    Recovering { saw_content: bool },
}

impl<T> fmt::Debug for DecodeState<T>
where
    T: EventDataRead + fmt::Debug,
    T::Reader: fmt::Debug,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DecodeState")
            .field("carry", &self.carry)
            .field("carry_valid_up_to", &self.carry_valid_up_to)
            .field("pending_cr", &self.pending_cr)
            .field("started", &self.started)
            .field("builder", &self.builder)
            .field("ready", &self.ready)
            .field("last_event_id", &self.last_event_id)
            .field("event_len", &self.event_len)
            .field("max_line_len", &self.max_line_len)
            .field("max_event_len", &self.max_event_len)
            .field("lenient", &self.lenient)
            .field("mode", &self.mode)
            .field("resync_count", &self.resync_count)
            .field("on_resync", &self.on_resync.is_some())
            .finish()
    }
}

impl<T: EventDataRead> Default for DecodeState<T> {
    fn default() -> Self {
        Self {
            carry: Vec::new(),
            carry_valid_up_to: 0,
            pending_cr: false,
            started: false,
            builder: EventBuilder::default(),
            ready: VecDeque::new(),
            last_event_id: None,
            event_len: 0,
            max_line_len: None,
            max_event_len: None,
            limited: false,
            lenient: false,
            mode: ScanMode::Normal,
            resync_count: 0,
            on_resync: None,
        }
    }
}

impl<T: EventDataRead> DecodeState<T> {
    /// Feed one body chunk into the decoder; completed events queue up in
    /// `ready`. Returns the number of bytes consumed: decoding pauses once
    /// `ready` holds [`READY_EVENTS_SOFT_CAP`] events, and the caller is
    /// expected to re-offer the unconsumed remainder once drained.
    fn feed(&mut self, mut input: &[u8]) -> Result<usize, BoxError> {
        let full_len = input.len();
        if input.is_empty() {
            return Ok(0);
        }
        if !self.started {
            if self.carry.is_empty() && input.len() >= UTF8_BOM.len() {
                self.started = true;
                if input[..UTF8_BOM.len()] == UTF8_BOM {
                    input = &input[UTF8_BOM.len()..];
                }
            } else {
                // tiny first chunk(s): buffer bytes until the BOM question is decided
                while !self.started {
                    let Some((&byte, rest)) = input.split_first() else {
                        return Ok(full_len);
                    };
                    input = rest;
                    self.carry.push(byte);
                    if self.carry[..] == UTF8_BOM {
                        self.carry.clear();
                        self.carry_valid_up_to = 0;
                        self.started = true;
                    } else if self.carry[..] != UTF8_BOM[..self.carry.len()] {
                        self.started = true;
                        // non-BOM prefix: replay it through the regular scanner,
                        // as it may itself contain line terminators
                        let mut replay = [0u8; UTF8_BOM.len()];
                        let n = self.carry.len();
                        replay[..n].copy_from_slice(&self.carry);
                        self.carry.clear();
                        self.carry_valid_up_to = 0;
                        let consumed = self.scan(&replay[..n])?;
                        debug_assert_eq!(
                            consumed, n,
                            "a replay of at most 3 bytes cannot hit the ready-event cap"
                        );
                    }
                }
            }
        }
        let consumed = self.scan(input)?;
        Ok(full_len - input.len() + consumed)
    }

    /// The input is exhausted: take the unterminated trailing line out, per
    /// the WHATWG event stream model, together with the verdict on whether
    /// it was valid UTF-8.
    fn finish(&mut self) -> (Vec<u8>, Result<(), BoxError>) {
        if self.carry.is_empty() {
            return (Vec::new(), Ok(()));
        }
        // `scan` validates carried bytes incrementally. Only the possible
        // incomplete UTF-8 suffix remains to check at EOF, rather than
        // re-validating an attacker-sized unterminated line in one go.
        let result = std::str::from_utf8(&self.carry[self.carry_valid_up_to..])
            .map(|_| ())
            .map_err(|err| err.context("utf8 error: invalid trailing sse bytes"));
        let line = std::mem::take(&mut self.carry);
        self.carry_valid_up_to = 0;
        (line, result)
    }

    /// Extend `carry` while validating only bytes not already known valid.
    fn extend_carry(&mut self, bytes: &[u8]) -> Result<(), BoxError> {
        if self.limited {
            self.check_limits(self.carry.len() + bytes.len())?;
        }
        let validate_from = self.carry_valid_up_to;
        self.carry.extend_from_slice(bytes);
        // `carry[..validate_from]` is valid UTF-8 (invariant) and the bytes
        // after it are validated here, so the new prefix is valid UTF-8 too.
        match std::str::from_utf8(&self.carry[validate_from..]) {
            Ok(_) => self.carry_valid_up_to = self.carry.len(),
            Err(err) => {
                self.carry_valid_up_to = validate_from + err.valid_up_to();
                if err.error_len().is_some() {
                    return Err(err.context("utf8 error: invalid sse bytes"));
                }
            }
        }
        debug_assert!(self.carry.len() - self.carry_valid_up_to <= 3);
        Ok(())
    }

    /// Scan the input for complete lines; returns the number of bytes
    /// consumed, which is less than `input.len()` when one of the soft
    /// caps ([`READY_EVENTS_SOFT_CAP`], [`SCAN_BYTES_SOFT_CAP`]) pauses
    /// decoding mid-chunk. Every pause point is also a valid chunk
    /// boundary, so resuming later with the remainder is state-safe.
    fn scan(&mut self, input: &[u8]) -> Result<usize, BoxError> {
        let input = &input[..input.len().min(SCAN_BYTES_SOFT_CAP)];
        if input.is_empty() || self.ready.len() >= READY_EVENTS_SOFT_CAP {
            return Ok(0);
        }

        // A ready-cap pause can only overlap this fixed initial block on the
        // next call; fully consumed blocks are never inspected again. This
        // bounds dense-input amplification by a constant and makes total
        // overflow-drain work linear, while sparse input quickly reaches the
        // full scan cap.
        let mut offset = 0;
        let mut block_len = SCAN_INITIAL_BLOCK_SIZE;
        while offset < input.len() {
            let block_start = offset;
            let end = (offset + block_len).min(input.len());
            let consumed = self.scan_block(&input[offset..end])?;
            if consumed == 0 && end > block_start {
                if self.lenient {
                    // recovery always advances on non-empty input, so this is
                    // unreachable in lenient mode; stop rather than spin.
                    break;
                }
                return Err(BoxError::from_static_str(
                    "SSE decoder made no progress on a non-empty scan block",
                ));
            }
            offset += consumed;
            if consumed < end - block_start || self.ready.len() >= READY_EVENTS_SOFT_CAP {
                break;
            }
            block_len = (block_len * 2).min(SCAN_BYTES_SOFT_CAP);
        }
        Ok(offset)
    }

    #[inline]
    fn recovering(&self) -> bool {
        matches!(self.mode, ScanMode::Recovering { .. })
    }

    /// Scan one block, alternating between normal decoding and recovery. In
    /// lenient mode a fault starts a resync that this drives to the next event
    /// boundary before decoding resumes; otherwise the fault propagates.
    fn scan_block(&mut self, input: &[u8]) -> Result<usize, BoxError> {
        if input.is_empty() {
            return Ok(0);
        }
        let mut base = 0;
        loop {
            if self.recovering() {
                base += self.recover(&input[base..]);
                if self.recovering() || base >= input.len() {
                    return Ok(base);
                }
            }
            base += self.scan_block_once(&input[base..])?;
            // a fault flipped us mid-block: recover the remainder, else done
            if !self.recovering() {
                return Ok(base);
            }
        }
    }

    /// Scan one artificial chunk boundary in normal mode. The caller grows
    /// these blocks exponentially until the byte or ready-event cap is reached.
    /// On a lenient-mode fault it starts recovery (see [`Self::begin_recovery`])
    /// and returns the bytes consumed before the fault.
    fn scan_block_once(&mut self, input: &[u8]) -> Result<usize, BoxError> {
        if input.is_empty() {
            return Ok(0);
        }

        let mut offset = 0;

        if self.pending_cr {
            self.pending_cr = false;
            if input[0] == b'\n' {
                offset += 1;
            }
        }

        // complete a line left over from previous chunk(s)
        if !self.carry.is_empty() {
            match memchr2(b'\r', b'\n', &input[offset..]) {
                None => {
                    if let Err(err) = self.extend_carry(&input[offset..]) {
                        self.absorb(err, true)?;
                        return Ok(offset);
                    }
                    return Ok(input.len());
                }
                Some(pos) => {
                    if let Err(err) = self.extend_carry(&input[offset..offset + pos]) {
                        self.absorb(err, true)?;
                        return Ok(offset);
                    }
                    let is_cr = input[offset + pos] == b'\r';
                    offset += pos + 1;
                    if is_cr {
                        if offset == input.len() {
                            self.pending_cr = true;
                        } else if input[offset] == b'\n' {
                            offset += 1;
                        }
                    }
                    // take/restore the carry buffer so its allocation is reused,
                    // while keeping the borrow checker happy about `handle_line`
                    let line = std::mem::take(&mut self.carry);
                    let valid_up_to = std::mem::take(&mut self.carry_valid_up_to);
                    if let Err(err) = std::str::from_utf8(&line[valid_up_to..])
                        .map_err(|err| err.context("utf8 error: invalid sse line"))
                    {
                        self.carry = line;
                        self.carry.clear();
                        // the line's terminator was already consumed above
                        self.absorb(err, false)?;
                        return Ok(offset);
                    }
                    debug_assert_eq!(valid_up_to, line.len());
                    // SAFETY: `str::from_utf8_unchecked` requires valid UTF-8.
                    // `line[..valid_up_to]` is valid UTF-8 (the
                    // `carry_valid_up_to` invariant, read before the take) and
                    // `line[valid_up_to..]` was validated just above; two
                    // valid UTF-8 strings concatenate to valid UTF-8.
                    let s = unsafe { std::str::from_utf8_unchecked(&line) };
                    let result = self.handle_line(s);
                    self.carry = line;
                    self.carry.clear();
                    result?;
                    if self.recovering() {
                        return Ok(offset);
                    }
                    if self.ready.len() >= READY_EVENTS_SOFT_CAP {
                        return Ok(offset);
                    }
                }
            }
        }

        // validate the remaining input once; an incomplete UTF-8 sequence at
        // the very end is carried over, invalid bytes fail after the valid
        // prefix has been processed
        let rest = &input[offset..];
        let (valid, utf8_tail, utf8_err) = match std::str::from_utf8(rest) {
            Ok(s) => (s, &[][..], None),
            Err(err) => {
                let (head, tail) = rest.split_at(err.valid_up_to());
                // SAFETY: `str::from_utf8_unchecked` requires valid UTF-8.
                // `Utf8Error::valid_up_to` documents that `rest[..valid_up_to]`
                // is valid UTF-8, and `head` is exactly that prefix.
                let s = unsafe { std::str::from_utf8_unchecked(head) };
                match err.error_len() {
                    None => (s, tail, None),
                    Some(_) => (
                        s,
                        &[][..],
                        Some(err.context("utf8 error: invalid sse bytes")),
                    ),
                }
            }
        };

        let bytes = valid.as_bytes();
        let mut start = 0;
        for pos in memchr2_iter(b'\r', b'\n', bytes) {
            if pos < start {
                // the LF half of a CRLF pair
                continue;
            }
            let line = &valid[start..pos];
            let mut next = pos + 1;
            if bytes[pos] == b'\r' {
                if next < bytes.len() {
                    if bytes[next] == b'\n' {
                        next += 1;
                    }
                } else if utf8_tail.is_empty() && utf8_err.is_none() {
                    // chunk ends exactly on the CR: an LF may still follow
                    // (a non-empty tail or invalid byte can never be an LF)
                    self.pending_cr = true;
                }
            }
            self.handle_line(line)?;
            start = next;
            if self.recovering() {
                return Ok(offset + start);
            }
            if self.ready.len() >= READY_EVENTS_SOFT_CAP {
                return Ok(offset + start);
            }
        }

        if let Some(err) = utf8_err {
            // the invalid byte is content of the unterminated line at `start`;
            // recover from it, leaving the valid lines already handled above
            self.absorb(err, true)?;
            return Ok(offset + valid.len());
        }

        if self.limited
            && let Err(err) =
                self.check_limits(self.carry.len() + bytes.len() - start + utf8_tail.len())
        {
            self.absorb(err, true)?;
            return Ok(offset + start);
        }
        // `carry` is empty here: every path above that leaves it non-empty
        // returns. So `carry[..bytes.len() - start]` is `valid[start..]`, valid
        // UTF-8 because `start` follows an ASCII terminator (invariant).
        debug_assert!(self.carry.is_empty());
        self.carry.extend_from_slice(&bytes[start..]);
        self.carry.extend_from_slice(utf8_tail);
        self.carry_valid_up_to = bytes.len() - start;
        Ok(input.len())
    }

    #[inline]
    fn handle_line(&mut self, line: &str) -> Result<(), BoxError> {
        if self.limited {
            if let Err(err) = self.check_limits(line.len()) {
                return self.absorb(err, false);
            }
            self.event_len += line.len();
        }
        if let Err(err) = self.builder.add(parse_line(line)) {
            return self.absorb(err, false);
        }
        if self.builder.is_complete {
            match self.builder.try_dispatch() {
                Ok(event) => {
                    if self.limited {
                        self.event_len = 0;
                    }
                    self.ready.push_back(event);
                }
                Err(err) => return self.absorb(err, false),
            }
        }
        Ok(())
    }

    /// In lenient mode turn a decode fault into a resync (see
    /// [`Self::begin_recovery`]) and report success; otherwise surface it as
    /// the fatal error it is. `mid_line` says whether the fault left an
    /// unterminated line still on the wire.
    fn absorb(&mut self, err: BoxError, mid_line: bool) -> Result<(), BoxError> {
        if !self.lenient {
            return Err(err);
        }
        self.begin_recovery(err, mid_line);
        Ok(())
    }

    /// Drop the partial event being built and enter recovery, which skips
    /// input up to the next blank line. `mid_line` records whether the fault
    /// left an unterminated line whose own terminator is therefore not the
    /// boundary. `pending_cr` is deliberately kept: a CR that ended the
    /// faulting line is part of its terminator, and [`Self::recover`] must
    /// pair it with a following LF rather than read that LF as an empty line.
    fn begin_recovery(&mut self, err: BoxError, mid_line: bool) {
        self.mode = ScanMode::Recovering {
            saw_content: mid_line,
        };
        self.builder = EventBuilder::default();
        self.event_len = 0;
        self.carry.clear();
        self.carry_valid_up_to = 0;
        self.resync_count = self.resync_count.saturating_add(1);
        if let Some(sink) = self.on_resync.as_ref() {
            sink.sink_error(err);
        }
    }

    /// Discard input up to and including the next blank line — the SSE event
    /// delimiter — then return to normal decoding. A blank line cannot appear
    /// inside a field or value, and its terminators are ASCII that no UTF-8
    /// sequence (valid or not) can contain, so the boundary is unambiguous
    /// even across corruption. Returns the number of bytes consumed.
    fn recover(&mut self, input: &[u8]) -> usize {
        let ScanMode::Recovering { mut saw_content } = self.mode else {
            return 0;
        };
        let mut offset = 0;
        if self.pending_cr {
            self.pending_cr = false;
            // the LF half of a CRLF that ended the faulting line
            if input.first() == Some(&b'\n') {
                offset += 1;
            }
        }
        while offset < input.len() {
            let Some(pos) = memchr2(b'\r', b'\n', &input[offset..]) else {
                // no terminator: the whole rest is line content, discarded
                self.mode = ScanMode::Recovering { saw_content: true };
                return input.len();
            };
            let is_empty_line = pos == 0 && !saw_content;
            let is_cr = input[offset + pos] == b'\r';
            offset += pos + 1;
            saw_content = false;
            if is_cr {
                if offset == input.len() {
                    self.pending_cr = true;
                } else if input[offset] == b'\n' {
                    offset += 1;
                }
            }
            if is_empty_line {
                self.mode = ScanMode::Normal;
                return offset;
            }
        }
        self.mode = ScanMode::Recovering { saw_content };
        input.len()
    }

    /// Check a complete or partial line against both limits without counting
    /// it toward `event_len` until `handle_line` accepts the complete line.
    fn check_limits(&self, len: usize) -> Result<(), BoxError> {
        self.check_line_len(len)?;
        if let Some(max) = self.max_event_len
            && self.event_len.saturating_add(len) > max
        {
            return Err(
                BoxError::from_static_str("sse event exceeds the max event length")
                    .context_field("max_event_len", max),
            );
        }
        Ok(())
    }

    fn check_line_len(&self, len: usize) -> Result<(), BoxError> {
        match self.max_line_len {
            Some(max) if len > max => Err(BoxError::from_static_str(
                "sse line exceeds the max line length",
            )
            .context_field("max_line_len", max)),
            _ => Ok(()),
        }
    }

    /// Take the next decoded event, moving the last-event-ID checkpoint with it.
    fn take_ready(&mut self) -> Option<Event<T>> {
        let event = self.ready.pop_front()?;
        // WHATWG: the last-event-ID buffer persists across events;
        // only overwrite it when the yielded event actually had an
        // id field (post-parse `Some(_)`, empty string included).
        // The checkpoint moves when the event is handed to the
        // caller, never while it still sits in the ready queue.
        if let Some(id) = event.id() {
            self.last_event_id = Some(SmolStr::new(id));
        }
        Some(event)
    }
}

/// Handler for the bytes of an unterminated trailing line, registered with
/// [`EventDecoder::with_on_incomplete`].
pub type OnIncompleteLine = Box<dyn FnOnce(Vec<u8>) + Send + Sync>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Status {
    Open,
    Finished,
    Failed,
}

/// Push-driven decoder turning raw SSE bytes into [`Event`]s.
///
/// Push borrowed chunks to inspect an SSE body while forwarding it unchanged.
/// Use [`EventStream`] to decode a stream of chunks instead.
///
/// Push a chunk, drain what it completed, repeat, and call
/// [`finish`](Self::finish) once the body ends:
///
/// ```
/// use rama_http_types::sse::EventDecoder;
/// use std::assert_matches;
///
/// # fn main() -> Result<(), rama_core::error::BoxError> {
/// let mut decoder = EventDecoder::<String>::new();
///
/// for chunk in [&b"data: hello\n"[..], b"\ndata: wor", b"ld\n\n"] {
///     decoder.push(chunk)?;
///     for event in decoder.events() {
///         let event = event?;
///         assert_matches!(event.data(), Some(data) if data == "hello" || data == "world");
///     }
/// }
/// decoder.finish()?;
/// # Ok(())
/// # }
/// ```
///
/// Chunks may split lines, UTF-8 sequences and CRLF pairs anywhere.
/// Partial lines and undecoded chunk tails are buffered.
///
/// Events dispatch on blank lines. [`finish`](Self::finish) is optional;
/// it checks trailing UTF-8 without dispatching an event.
/// [`on_incomplete`](Self::with_on_incomplete) receives the buffered partial
/// line on finish or drop.
///
/// Input is unlimited by default. For untrusted input, set
/// [`max_line_len`](Self::with_max_line_len) and
/// [`max_event_len`](Self::with_max_event_len). These limits do not cap the
/// undecoded backlog; drain events between pushes.
///
/// A decode error is fatal by default. [`lenient`](Self::with_lenient) mode
/// instead recovers to the next event boundary, losing only the events around
/// the fault — useful when observing a stream that must not be blinded by one
/// bad event.
///
/// [`EventStream`]: super::EventStream
pub struct EventDecoder<T: EventDataRead = String> {
    state: DecodeState<T>,
    /// input accepted but not yet decoded, set aside when a soft cap
    /// paused a [`EventDecoder::push`] mid-chunk
    backlog: Vec<u8>,
    backlog_offset: usize,
    /// a decode error, surfaced only once the events completed before it
    /// have been yielded
    pending_error: Option<BoxError>,
    status: Status,
    /// handed the unterminated trailing line, at most once
    on_incomplete: Option<OnIncompleteLine>,
}

impl<T> fmt::Debug for EventDecoder<T>
where
    T: EventDataRead + fmt::Debug,
    T::Reader: fmt::Debug,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("EventDecoder")
            .field("state", &self.state)
            .field("backlog", &self.backlog.len())
            .field("backlog_offset", &self.backlog_offset)
            .field("pending_error", &self.pending_error)
            .field("status", &self.status)
            .field("on_incomplete", &self.on_incomplete.is_some())
            .finish()
    }
}

impl<T: EventDataRead> Default for EventDecoder<T> {
    fn default() -> Self {
        Self {
            state: DecodeState::default(),
            backlog: Vec::new(),
            backlog_offset: 0,
            pending_error: None,
            status: Status::Open,
            on_incomplete: None,
        }
    }
}

impl<T: EventDataRead> EventDecoder<T> {
    /// Create a new [`EventDecoder`].
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    generate_set_and_with! {
        /// Fail decoding once a single line grows past `max` bytes,
        /// terminator excluded.
        pub fn max_line_len(mut self, max: Option<usize>) -> Self {
            self.state.max_line_len = max;
            self.state.limited = self.state.max_line_len.is_some() || self.state.max_event_len.is_some();
            self
        }
    }

    generate_set_and_with! {
        /// Fail decoding once an event exceeds `max` raw line bytes.
        /// Includes field names, separators, comments, unknown fields and
        /// partial lines; excludes line terminators. Resets per event.
        pub fn max_event_len(mut self, max: Option<usize>) -> Self {
            self.state.max_event_len = max;
            self.state.limited = self.state.max_line_len.is_some() || self.state.max_event_len.is_some();
            self
        }
    }

    generate_set_and_with! {
        /// Pass a nonempty buffered partial line to `cb` at most once,
        /// on [`finish`](Self::finish) or drop.
        ///
        /// Bytes may contain invalid UTF-8. Completed lines from an unfinished
        /// event and undrained input are excluded.
        pub fn on_incomplete(mut self, cb: Option<OnIncompleteLine>) -> Self {
            self.on_incomplete = cb;
            self
        }
    }

    generate_set_and_with! {
        /// Recover from a decode fault instead of failing the whole stream.
        ///
        /// When on, a fault drops the event being built and skips to the next
        /// blank line, then resumes — losing only the events around it, never
        /// the rest of the stream. Off by default. See
        /// [`resync_count`](Self::resync_count) and
        /// [`with_on_resync`](Self::with_on_resync) to observe recovery.
        pub fn lenient(mut self, lenient: bool) -> Self {
            self.state.lenient = lenient;
            self
        }
    }

    generate_set_and_with! {
        /// Route each resync in [`lenient`](Self::with_lenient) mode to an
        /// [`ErrorSink`], which receives the triggering error. Wrap a
        /// `Fn(BoxError) + Send + Sync` closure in [`Arc`] to use one.
        pub fn on_resync(mut self, sink: Option<Arc<dyn ErrorSink>>) -> Self {
            self.state.on_resync = sink;
            self
        }
    }

    /// How many resyncs have happened in [`lenient`](Self::with_lenient) mode.
    /// Zero when off, and nonzero exactly when recovery occurred — a health
    /// signal for an otherwise silent stream. Best-effort: the tally can shift
    /// slightly with how the input is chunked, though the surviving events do
    /// not.
    #[must_use]
    pub fn resync_count(&self) -> usize {
        self.state.resync_count
    }

    /// Set the last event ID, e.g. to initialize the decoder with the
    /// ID a previous connection ended on.
    pub fn try_set_last_event_id(&mut self, id: impl Into<SmolStr>) -> Result<(), BoxError> {
        let id = id.into();
        if id.contains(['\n', '\r', '\0']) {
            return Err(EventBuildError::invalid_characters(id).into_box_error());
        }
        self.state.last_event_id = Some(id);
        Ok(())
    }

    /// The ID of the last event yielded that carried one.
    #[must_use]
    pub fn last_event_id(&self) -> Option<&str> {
        self.state.last_event_id.as_deref()
    }

    /// Push one chunk of the event stream into the decoder.
    ///
    /// Undecoded bytes are buffered. Drain with [`events`](Self::events)
    /// between pushes to keep the backlog empty.
    ///
    /// Decode errors surface through [`next_event`](Self::next_event) after
    /// preceding events. This method returns an error if already finished or failed.
    pub fn push(&mut self, chunk: &[u8]) -> Result<(), BoxError> {
        match self.status {
            Status::Open => (),
            Status::Finished => {
                return Err(BoxError::from_static_str(
                    "sse decoder cannot accept input after it finished",
                ));
            }
            Status::Failed => {
                return Err(BoxError::from_static_str(
                    "sse decoder already failed on earlier input",
                ));
            }
        }

        if chunk.is_empty() {
            return Ok(());
        }

        // undecoded input first: the decoder may not see bytes out of order
        if self.backlog_offset < self.backlog.len() {
            let remaining = self.backlog.len() - self.backlog_offset;
            if self.backlog_offset >= remaining {
                // Reclaim consumed input even if the backlog never empties.
                // Copy no more than we consumed, keeping compaction amortized linear.
                self.backlog.copy_within(self.backlog_offset.., 0);
                self.backlog.truncate(remaining);
                self.backlog_offset = 0;
            }
            self.backlog.extend_from_slice(chunk);
            return Ok(());
        }

        match self.state.feed(chunk) {
            Ok(consumed) => {
                if consumed < chunk.len() {
                    self.reset_backlog();
                    self.backlog.extend_from_slice(&chunk[consumed..]);
                }
            }
            Err(err) => self.fail(err),
        }
        Ok(())
    }

    /// Yield the next decoded event, or `None` once everything pushed so far
    /// has been decoded.
    ///
    /// An error is fatal: the byte stream can no longer be interpreted
    /// reliably, so the decoder yields nothing further.
    pub fn next_event(&mut self) -> Result<Option<Event<T>>, BoxError> {
        loop {
            if let Some(event) = self.state.take_ready() {
                return Ok(Some(event));
            }
            if let Some(err) = self.pending_error.take() {
                return Err(err);
            }
            if self.status != Status::Open || self.backlog_offset >= self.backlog.len() {
                return Ok(None);
            }

            match self.state.scan(&self.backlog[self.backlog_offset..]) {
                // the ready queue is empty here, so a paused scan can only
                // mean the decoder stopped making progress
                Ok(0) => {
                    self.reset_backlog();
                    self.fail(BoxError::from_static_str(
                        "SSE decoder made no progress on buffered input",
                    ));
                }
                Ok(consumed) => {
                    self.backlog_offset += consumed;
                    if self.backlog_offset >= self.backlog.len() {
                        self.reset_backlog();
                    }
                }
                Err(err) => {
                    self.reset_backlog();
                    self.fail(err);
                }
            }
        }
    }

    /// Iterator over the events decodable from what was pushed so far,
    /// ending on the first error.
    pub fn events(&mut self) -> Events<'_, T> {
        Events {
            decoder: self,
            done: false,
        }
    }

    /// End input and validate trailing UTF-8 without dispatching an event.
    ///
    /// Releases the buffered partial line, passing it to
    /// [`on_incomplete`](Self::with_on_incomplete) if set, even if validation fails.
    /// Drain [`events`](Self::events) first; undecoded input is a fatal error.
    pub fn finish(&mut self) -> Result<(), BoxError> {
        if let Some(err) = self.pending_error.take() {
            return Err(err);
        }
        match self.status {
            Status::Open => (),
            Status::Finished => return Ok(()),
            Status::Failed => {
                return Err(BoxError::from_static_str(
                    "sse decoder already failed on earlier input",
                ));
            }
        }

        if self.backlog_offset < self.backlog.len() {
            self.reset_backlog();
            let err = BoxError::from_static_str("sse decoder finished with input left undecoded");
            self.status = Status::Failed;
            return Err(err);
        }

        self.status = Status::Finished;
        let (line, result) = self.state.finish();
        self.emit_incomplete(line);
        if self.state.lenient {
            // a truncated trailing UTF-8 sequence is incomplete input, not a
            // fatal error, in lenient mode; the bytes still reach on_incomplete
            return Ok(());
        }
        result.inspect_err(|_| {
            self.status = Status::Failed;
        })
    }

    fn emit_incomplete(&mut self, line: Vec<u8>) {
        if line.is_empty() {
            return;
        }
        if let Some(cb) = self.on_incomplete.take() {
            cb(line);
        }
    }

    fn fail(&mut self, err: BoxError) {
        self.status = Status::Failed;
        self.pending_error = Some(err);
    }

    fn reset_backlog(&mut self) {
        self.backlog.clear();
        self.backlog_offset = 0;
    }
}

impl<T: EventDataRead> Drop for EventDecoder<T> {
    fn drop(&mut self) {
        if self.on_incomplete.is_some() && !self.state.carry.is_empty() {
            let line = std::mem::take(&mut self.state.carry);
            self.emit_incomplete(line);
        }
    }
}

/// Iterator over the events an [`EventDecoder`] can decode right now,
/// created with [`EventDecoder::events`].
pub struct Events<'a, T: EventDataRead = String> {
    decoder: &'a mut EventDecoder<T>,
    done: bool,
}

impl<T> fmt::Debug for Events<'_, T>
where
    T: EventDataRead + fmt::Debug,
    T::Reader: fmt::Debug,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Events")
            .field("decoder", &self.decoder)
            .field("done", &self.done)
            .finish()
    }
}

impl<T: EventDataRead> Iterator for Events<'_, T> {
    type Item = Result<Event<T>, BoxError>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.done {
            return None;
        }
        match self.decoder.next_event() {
            Ok(Some(event)) => Some(Ok(event)),
            Ok(None) => {
                self.done = true;
                None
            }
            Err(err) => {
                self.done = true;
                Some(Err(err))
            }
        }
    }
}

impl<T: EventDataRead> FusedIterator for Events<'_, T> {}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::allow_attributes,
        reason = "test macros use `#[allow(unused_mut)]` because the binding is mutated only by some variadic arms — `#[expect]` would warn unfulfilled when no arm fires"
    )]

    use super::*;
    use crate::sse::{JsonEventData, test_event as event};
    use crate::{BodyExtractExt as _, sse::EventDataWrite};
    use serde::{Deserialize, Serialize};
    use serde_json::json;
    use std::sync::{Arc, OnceLock};

    #[test]
    fn ready_cap_stops_within_the_initial_scan_block() {
        let mut state = DecodeState::<String> {
            started: true,
            ..Default::default()
        };

        let dense_lf = vec![b'\n'; SCAN_BYTES_SOFT_CAP];
        assert_eq!(READY_EVENTS_SOFT_CAP, state.scan(&dense_lf).unwrap());

        let mut state = DecodeState::<String> {
            started: true,
            ..Default::default()
        };
        let dense_crlf = b"\r\n".repeat(READY_EVENTS_SOFT_CAP);
        assert_eq!(dense_crlf.len(), state.scan(&dense_crlf).unwrap());

        // A leading LF can belong to a CR terminator from the prior window.
        let mut state = DecodeState::<String> {
            started: true,
            pending_cr: true,
            ..Default::default()
        };
        let after_cr = vec![b'\n'; READY_EVENTS_SOFT_CAP + 1];
        assert_eq!(after_cr.len(), state.scan(&after_cr).unwrap());

        // A carried prefix makes the first terminated line non-empty.
        let mut state = DecodeState::<String> {
            started: true,
            ..Default::default()
        };
        state.carry.push(b'x');
        state.carry_valid_up_to = 1;
        assert_eq!(after_cr.len(), state.scan(&after_cr).unwrap());
    }

    #[test]
    fn carried_utf8_is_validated_incrementally() {
        let mut state = DecodeState::<String>::default();
        assert_eq!(7, state.feed(b"data: \xf0").unwrap());
        assert_eq!(6, state.carry_valid_up_to);
        state.feed(b"(").unwrap_err();
    }

    #[test]
    fn invalid_byte_after_cr_does_not_arm_pending_cr() {
        let mut state = DecodeState::<String>::default();

        state.scan_block(b"\r\xff").unwrap_err();

        assert!(!state.pending_cr);
    }

    /// decode input in `chunk_size` pushes, draining after each one
    fn decode_in_chunks<T: EventDataRead>(
        decoder: &mut EventDecoder<T>,
        input: &[u8],
        chunk_size: usize,
    ) -> Result<Vec<Event<T>>, BoxError> {
        let mut events = Vec::new();
        for chunk in input.chunks(chunk_size.min(input.len()).max(1)) {
            decoder.push(chunk)?;
            for event in decoder.events() {
                events.push(event?);
            }
        }
        decoder.finish()?;
        Ok(events)
    }

    /// decode a full input in one chunk, expecting at most one event
    fn parse_single<T: EventDataRead>(input: &str) -> (Option<Event<T>>, EventDecoder<T>) {
        let mut decoder = EventDecoder::<T>::new();
        let mut events = decode_in_chunks(&mut decoder, input.as_bytes(), usize::MAX).unwrap();
        assert!(
            events.len() <= 1,
            "input yielded more than one event: '{input}'"
        );
        (events.pop(), decoder)
    }

    #[test]
    fn same_events_wherever_the_pushes_split() {
        let input = "\u{feff}: a comment\r\nevent: a\r\ndata: one\r\n\r\ndata: t\u{00e9}o\ndata: lines\n\nid: 3\rdata: three\r\rretry: 20\ndata: four\n\ndata: cut";
        let whole = decode_in_chunks(
            &mut EventDecoder::<String>::new(),
            input.as_bytes(),
            usize::MAX,
        )
        .unwrap();
        let mut fourth = event!("four".to_owned(),);
        fourth.set_retry(20);
        assert_eq!(
            whole,
            vec![
                event!("one".to_owned(), event = "a", comment = "a comment",),
                event!("t\u{00e9}o\nlines".to_owned(),),
                event!("three".to_owned(), id = "3",),
                fourth,
            ],
        );

        for chunk_size in 1..=input.len() {
            let events = decode_in_chunks(
                &mut EventDecoder::<String>::new(),
                input.as_bytes(),
                chunk_size,
            )
            .unwrap();
            assert_eq!(events, whole, "chunk size {chunk_size}");
        }
    }

    #[test]
    fn every_two_way_split_yields_the_same_events() {
        let input = "\u{feff}data: \u{1f680}\r\n\rid\ndata: b\n\n: c\r\n\r\n";
        let whole = decode_in_chunks(
            &mut EventDecoder::<String>::new(),
            input.as_bytes(),
            usize::MAX,
        )
        .unwrap();

        for split in 0..=input.len() {
            let (head, tail) = input.as_bytes().split_at(split);
            let mut decoder = EventDecoder::<String>::new();
            let mut events = Vec::new();
            for chunk in [head, tail] {
                decoder.push(chunk).unwrap();
                for event in decoder.events() {
                    events.push(event.unwrap());
                }
            }
            decoder.finish().unwrap();
            assert_eq!(events, whole, "split at {split}");
        }
    }

    #[test]
    fn a_single_push_delivers_every_event_past_the_ready_cap() {
        let input = "data: x\n\n".repeat(READY_EVENTS_SOFT_CAP * 3 + 1);
        let events = decode_in_chunks(
            &mut EventDecoder::<String>::new(),
            input.as_bytes(),
            usize::MAX,
        )
        .unwrap();
        assert_eq!(events.len(), READY_EVENTS_SOFT_CAP * 3 + 1);
    }

    #[test]
    fn a_push_on_top_of_undecoded_input_keeps_order() {
        let mut decoder = EventDecoder::<String>::new();
        let dense: String = (0..READY_EVENTS_SOFT_CAP * 2)
            .map(|i| format!("data: {i}\n\n"))
            .collect();

        decoder.push(dense.as_bytes()).unwrap();
        // the ready cap paused the first push, so this lands behind the
        // bytes it could not decode yet
        decoder.push(b"data: last\n\n").unwrap();

        let events: Vec<_> = decoder.events().map(Result::unwrap).collect();
        decoder.finish().unwrap();

        assert_eq!(events.len(), READY_EVENTS_SOFT_CAP * 2 + 1);
        for (i, event) in events.iter().take(READY_EVENTS_SOFT_CAP * 2).enumerate() {
            assert_eq!(event.data(), Some(&i.to_string()));
        }
        assert_eq!(
            events.last().and_then(Event::data),
            Some(&"last".to_owned())
        );
    }

    #[test]
    fn partial_drains_keep_backlog_bounded_and_preserve_order() {
        let mut decoder = EventDecoder::<String>::new();
        let initial: String = (0..100).map(|i| format!("data: {i:06}\n\n")).collect();
        decoder.push(initial.as_bytes()).unwrap();
        let mut expected = 0;
        for _ in 0..50 {
            let event = decoder.next_event().unwrap().unwrap();
            assert_eq!(event.data().unwrap(), &format!("{expected:06}"));
            expected += 1;
        }

        // The consumer keeps a constant lag of 50 events, so the backlog
        // never empties, but retained input must not grow with total traffic.
        for batch in 0..200 {
            let start = 100 + batch * 50;
            let input: String = (start..start + 50)
                .map(|i| format!("data: {i:06}\n\n"))
                .collect();
            decoder.push(input.as_bytes()).unwrap();
            for _ in 0..50 {
                let event = decoder.next_event().unwrap().unwrap();
                assert_eq!(event.data().unwrap(), &format!("{expected:06}"));
                expected += 1;
            }
            assert!(decoder.backlog.len() <= initial.len() * 3);
        }

        let mut remaining = 0;
        for event in decoder.events() {
            assert_eq!(event.unwrap().data().unwrap(), &format!("{expected:06}"));
            expected += 1;
            remaining += 1;
        }
        assert_eq!(remaining, 50);
        decoder.finish().unwrap();
    }

    #[test]
    fn finish_discards_an_unterminated_trailing_line() {
        let mut decoder = EventDecoder::<String>::new();
        let events = decode_in_chunks(&mut decoder, b"data: a\n\ndata: cut", usize::MAX).unwrap();
        assert_eq!(events, vec![event!("a".to_owned(),)]);
    }

    fn incomplete_sink() -> (Arc<OnceLock<Vec<u8>>>, OnIncompleteLine) {
        let seen = Arc::new(OnceLock::new());
        let sink = Arc::clone(&seen);
        (seen, Box::new(move |line| drop(sink.set(line))))
    }

    #[test]
    fn an_unterminated_trailing_line_is_handed_over_on_drop() {
        let (seen, cb) = incomplete_sink();
        let mut decoder = EventDecoder::<String>::new().with_on_incomplete(cb);
        decoder.push(b"data: a\n\ndata: cut").unwrap();
        assert_eq!(1, decoder.events().count());

        // no finish: the decoder simply goes away, as it would inside a
        // frame callback owned by a body
        assert!(seen.get().is_none());
        drop(decoder);
        assert_eq!(seen.get().map(Vec::as_slice), Some(&b"data: cut"[..]));
    }

    #[test]
    fn an_unterminated_trailing_line_is_handed_over_on_finish_only_once() {
        let (seen, cb) = incomplete_sink();
        let mut decoder = EventDecoder::<String>::new().with_on_incomplete(cb);
        decoder.push(b"data: cut").unwrap();
        assert_eq!(0, decoder.events().count());

        decoder.finish().unwrap();
        assert_eq!(seen.get().map(Vec::as_slice), Some(&b"data: cut"[..]));

        // dropping afterwards must not hand anything over a second time
        drop(decoder);
        assert_eq!(seen.get().map(Vec::as_slice), Some(&b"data: cut"[..]));
    }

    /// The line is reassembled from every push it spanned, not just the
    /// last one.
    #[test]
    fn a_trailing_line_spanning_pushes_is_handed_over_whole() {
        for chunk_size in [1, 2, 3, 7] {
            let (seen, cb) = incomplete_sink();
            let mut decoder = EventDecoder::<String>::new().with_on_incomplete(cb);
            let input = b"data: a\n\ndata: never terminated";
            for chunk in input.chunks(chunk_size) {
                decoder.push(chunk).unwrap();
                assert!(decoder.events().count() <= 1);
            }
            drop(decoder);
            assert_eq!(
                seen.get().map(Vec::as_slice),
                Some(&b"data: never terminated"[..]),
                "chunk size {chunk_size}",
            );
        }
    }

    /// A decoder that failed still holds bytes it had buffered; they are
    /// handed over rather than swallowed.
    #[test]
    fn a_failed_decoder_hands_over_what_it_had_buffered() {
        let (seen, cb) = incomplete_sink();
        let mut decoder = EventDecoder::<String>::new().with_on_incomplete(cb);
        decoder.push(b"data: partial").unwrap();
        // a second push that fails outright: the carried line survives it
        decoder.push(b" \xff").unwrap();
        decoder.next_event().unwrap_err();

        // including the byte that made it fail: the bytes go over as they
        // arrived, not as the decoder wished they had
        drop(decoder);
        assert_eq!(
            seen.get().map(Vec::as_slice),
            Some(&b"data: partial \xff"[..]),
        );
    }

    /// A failed `finish` hands the bytes over exactly like a successful one,
    /// and the later drop must not repeat it.
    #[test]
    fn a_failed_finish_hands_over_once() {
        let (seen, cb) = incomplete_sink();
        let mut decoder = EventDecoder::<String>::new().with_on_incomplete(cb);
        decoder.push(b"data: \xf0\x9f\x9a").unwrap();
        decoder.finish().unwrap_err();
        assert_eq!(
            seen.get().map(Vec::as_slice),
            Some(&b"data: \xf0\x9f\x9a"[..]),
        );

        // the sink only accepts one value, so a second call would be visible
        // as a panic in the callback rather than a silent overwrite
        drop(decoder);
        assert_eq!(
            seen.get().map(Vec::as_slice),
            Some(&b"data: \xf0\x9f\x9a"[..]),
        );
    }

    /// A stream that stops inside the leading BOM leaves those bytes
    /// buffered; they are handed over as the incomplete input they are.
    #[test]
    fn a_truncated_bom_is_handed_over() {
        let (seen, cb) = incomplete_sink();
        let mut decoder = EventDecoder::<String>::new().with_on_incomplete(cb);
        decoder.push(b"\xef\xbb").unwrap();
        assert_eq!(0, decoder.events().count());

        drop(decoder);
        assert_eq!(seen.get().map(Vec::as_slice), Some(&b"\xef\xbb"[..]));
    }

    /// Only the trailing line is handed over: input the caller pushed but
    /// never drained is not part of the contract.
    #[test]
    fn undecoded_backlog_is_not_handed_over() {
        let (seen, cb) = incomplete_sink();
        let mut decoder = EventDecoder::<String>::new().with_on_incomplete(cb);
        let dense = "data: x\n\n".repeat(READY_EVENTS_SOFT_CAP * 2);
        decoder.push(dense.as_bytes()).unwrap();
        // never drained: the ready cap left most of that push undecoded
        drop(decoder);

        assert!(seen.get().is_none());
    }

    #[test]
    fn a_stream_ending_on_a_terminator_hands_nothing_over() {
        let (seen, cb) = incomplete_sink();
        let mut decoder = EventDecoder::<String>::new().with_on_incomplete(cb);
        decoder.push(b"data: a\n\n").unwrap();
        assert_eq!(1, decoder.events().count());
        decoder.finish().unwrap();
        drop(decoder);

        assert!(seen.get().is_none());
    }

    /// The raw bytes are worth more than the error: a body that stopped
    /// mid-sequence is handed over as it arrived, invalid tail included.
    #[test]
    fn an_invalid_trailing_line_is_handed_over_and_still_errors() {
        let (seen, cb) = incomplete_sink();
        let mut decoder = EventDecoder::<String>::new().with_on_incomplete(cb);
        decoder.push(b"data: \xf0\x9f\x9a").unwrap();
        assert_eq!(0, decoder.events().count());

        decoder.finish().unwrap_err();
        assert_eq!(
            seen.get().map(Vec::as_slice),
            Some(&b"data: \xf0\x9f\x9a"[..])
        );
    }

    #[test]
    fn finish_errors_on_a_truncated_utf8_sequence() {
        let mut decoder = EventDecoder::<String>::new();
        decoder.push(b"data: \xf0\x9f\x9a").unwrap();
        assert!(decoder.next_event().unwrap().is_none());
        decoder.finish().unwrap_err();
    }

    #[test]
    fn finish_errors_when_input_is_left_undecoded() {
        let mut decoder = EventDecoder::<String>::new();
        let dense = "data: x\n\n".repeat(READY_EVENTS_SOFT_CAP * 2);
        decoder.push(dense.as_bytes()).unwrap();

        decoder.finish().unwrap_err();
        // and the decoder is done for
        decoder.push(b"data: a\n\n").unwrap_err();
    }

    #[test]
    fn a_finished_decoder_takes_no_more_input() {
        let mut decoder = EventDecoder::<String>::new();
        decoder.push(b"data: a\n\n").unwrap();
        assert!(decoder.next_event().unwrap().is_some());

        decoder.finish().unwrap();
        // finishing twice is a no-op, pushing after it is not allowed
        decoder.finish().unwrap();
        decoder.push(b"data: b\n\n").unwrap_err();
        assert!(decoder.next_event().unwrap().is_none());
    }

    #[test]
    fn an_error_is_surfaced_after_the_events_that_preceded_it() {
        let mut decoder = EventDecoder::<String>::new();
        decoder.push(b"data: a\n\ndata: \xff\n\n").unwrap();

        assert_eq!(decoder.next_event().unwrap(), Some(event!("a".to_owned(),)));
        decoder.next_event().unwrap_err();
        // the error is fatal, and reported once
        assert!(decoder.next_event().unwrap().is_none());
        decoder.push(b"data: b\n\n").unwrap_err();
        decoder.finish().unwrap_err();
    }

    #[test]
    fn the_events_iterator_ends_at_the_first_error() {
        let mut decoder = EventDecoder::<String>::new();
        decoder
            .push(b"data: a\n\ndata: \xff\n\ndata: b\n\n")
            .unwrap();

        let events: Vec<_> = decoder.events().collect();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].as_ref().unwrap(), &event!("a".to_owned(),));
        events[1].as_ref().unwrap_err();

        assert_eq!(decoder.events().count(), 0);
    }

    #[test]
    fn empty_pushes_are_a_no_op() {
        let mut decoder = EventDecoder::<String>::new();
        for chunk in [&b""[..], b"data: a\n", b"", b"\n", b""] {
            decoder.push(chunk).unwrap();
        }
        let events: Vec<_> = decoder.events().map(Result::unwrap).collect();
        decoder.finish().unwrap();
        assert_eq!(events, vec![event!("a".to_owned(),)]);
    }

    #[test]
    fn the_last_event_id_moves_only_when_an_event_is_yielded() {
        let mut decoder = EventDecoder::<String>::new();
        decoder
            .push(b"id: 1\ndata: a\n\ndata: b\n\nid: 3\ndata: c\n\n")
            .unwrap();

        assert_eq!(decoder.last_event_id(), None);
        decoder.next_event().unwrap();
        assert_eq!(decoder.last_event_id(), Some("1"));
        // an event without an id leaves the checkpoint where it was
        decoder.next_event().unwrap();
        assert_eq!(decoder.last_event_id(), Some("1"));
        decoder.next_event().unwrap();
        assert_eq!(decoder.last_event_id(), Some("3"));
    }

    #[test]
    fn the_last_event_id_can_be_seeded_and_rejects_line_breaks() {
        let mut decoder = EventDecoder::<String>::new();
        decoder.try_set_last_event_id("42").unwrap();
        assert_eq!(decoder.last_event_id(), Some("42"));

        for invalid in ["4\n2", "4\r2", "4\u{0000}2"] {
            decoder.try_set_last_event_id(invalid).unwrap_err();
        }
        assert_eq!(decoder.last_event_id(), Some("42"));
    }

    #[test]
    fn a_line_past_the_limit_fails_however_it_is_chunked() {
        let long_line = format!("data: {}\n\n", "x".repeat(64));
        for chunk_size in [usize::MAX, 7, 4, 1] {
            let mut decoder = EventDecoder::<String>::new().with_max_line_len(32);
            assert!(
                decode_in_chunks(&mut decoder, long_line.as_bytes(), chunk_size).is_err(),
                "chunk size {chunk_size}",
            );
        }

        // the limit counts one line, not the whole stream
        let mut decoder = EventDecoder::<String>::new().with_max_line_len(32);
        let input = "data: fits\n\n".repeat(16);
        let events = decode_in_chunks(&mut decoder, input.as_bytes(), 3).unwrap();
        assert_eq!(events.len(), 16);
    }

    #[test]
    fn an_event_past_the_limit_fails_however_it_accumulates() {
        // data lines, comments and unknown fields all accumulate
        for input in [
            "data: aaaa\ndata: bbbb\ndata: cccc\n\n",
            ": aaaa\n: bbbb\n: cccc\n\n",
            "x: aaaa\nx: bbbb\nx: cccc\n\n",
        ] {
            for chunk_size in [usize::MAX, 5, 1] {
                let mut decoder = EventDecoder::<String>::new().with_max_event_len(16);
                assert!(
                    decode_in_chunks(&mut decoder, input.as_bytes(), chunk_size).is_err(),
                    "input {input:?}, chunk size {chunk_size}",
                );
            }
        }

        // the budget resets per event, so a long stream of small events is fine
        let mut decoder = EventDecoder::<String>::new().with_max_event_len(16);
        let input = "data: fits\n\n".repeat(16);
        let events = decode_in_chunks(&mut decoder, input.as_bytes(), 3).unwrap();
        assert_eq!(events.len(), 16);
    }

    #[test]
    fn the_event_limit_includes_unterminated_lines() {
        for input in ["data: 01234567890123456789", "data: 1234567890\ndata: x"] {
            for chunk_size in 1..=input.len() {
                for max_line_len in [None, Some(1024)] {
                    let mut decoder = EventDecoder::<String>::new()
                        .with_max_event_len(16)
                        .maybe_with_max_line_len(max_line_len);
                    let mut failed = false;
                    for chunk in input.as_bytes().chunks(chunk_size) {
                        decoder.push(chunk).unwrap();
                        if decoder.next_event().is_err() {
                            failed = true;
                            break;
                        }
                    }
                    assert!(failed, "input {input:?}, chunk size {chunk_size}");
                    assert!(decoder.state.carry.len() <= 16);
                }
            }
        }
    }

    #[test]
    fn partial_lines_are_counted_once_and_limits_reset_per_event() {
        let event = "data: é\r\ndata: 🚀\r\n\r\n";
        let input = event.repeat(3);
        let event_len = "data: é".len() + "data: 🚀".len();
        for chunk_size in 1..=input.len() {
            let mut decoder = EventDecoder::<String>::new().with_max_event_len(event_len);
            let events = decode_in_chunks(&mut decoder, input.as_bytes(), chunk_size).unwrap();
            assert_eq!(events.len(), 3);
            assert!(events.iter().all(|event| event.data().unwrap() == "é\n🚀"));
        }
    }

    #[test]
    fn json_data_decodes_across_pushes() {
        let mut decoder = EventDecoder::<JsonEventData<serde_json::Value>>::new();
        let events = decode_in_chunks(&mut decoder, b"data: {\"v\":1}\n\n", 4).unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].data().map(|d| d.0.clone()), Some(json!({"v": 1})));
    }

    #[tokio::test]
    async fn test_string_event_serialize() {
        for (expected, event) in [
            ("", event!(@,)),
            (
                "event: ping\ndata: 42\n\n",
                event!("42".to_owned(), event = "ping",),
            ),
            (
                "data: example message\n\n",
                event!("example message".to_owned(),),
            ),
            (
                "data: a\ndata: b\ndata: c\ndata: d\ndata: e\ndata: f\n\n",
                event!("a\nb\nc\nd\ne\nf".to_owned(),),
            ),
            (
                ": this is a comment\n: another comment\nid: 42\nevent: some-event\ndata: and some data\n\n",
                event!(
                    "and some data".to_owned(),
                    event = "some-event",
                    id = "42",
                    comment = "this is a comment",
                    comment = "another comment",
                ),
            ),
        ] {
            let buffer = event.serialize().unwrap().try_into_string().await.unwrap();
            assert_eq!(expected, buffer);
        }
    }

    #[tokio::test]
    async fn test_string_event_deserialize() {
        for (input, expected) in [
            ("", None),
            (
                "data: 42\nevent: ping\n\n",
                Some(event!("42".to_owned(), event = "ping",)),
            ),
            (
                "event: ping\ndata: 42\n\n",
                Some(event!("42".to_owned(), event = "ping",)),
            ),
            (
                "data: example message\n\n",
                Some(event!("example message".to_owned(),)),
            ),
            (
                "data: a\ndata: b\ndata: c\ndata: d\ndata: e\ndata: f\n\n",
                Some(event!("a\nb\nc\nd\ne\nf".to_owned(),)),
            ),
            (
                ": this is a comment\n: another comment\nid: 42\nevent: some-event\ndata: and some data\n\n",
                Some(event!(
                    "and some data".to_owned(),
                    event = "some-event",
                    id = "42",
                    comment = "this is a comment",
                    comment = "another comment",
                )),
            ),
        ] {
            let (event_out, decoder) = parse_single::<String>(input);
            assert!(
                decoder.state.carry.is_empty(),
                "input: '{input}'; decoder: '{decoder:?}'"
            );
            assert!(
                !decoder.state.builder.is_complete,
                "input: '{input}'; decoder: '{decoder:?}'"
            );
            assert_eq!(
                Event::default(),
                decoder.state.builder.event,
                "input: '{input}'"
            );
            assert_eq!(expected, event_out, "input: '{input}'");
        }
    }

    #[tokio::test]
    async fn test_string_event_serialize_deserialize() {
        for event in [
            event!("foo".to_owned(), event = "ping",),
            event!(
                "and some data".to_owned(),
                event = "some-event",
                id = "42",
                comment = "this is a comment",
                comment = "another comment",
            ),
        ] {
            let buffer = event.serialize().unwrap().try_into_string().await.unwrap();
            let (event_out, decoder) = parse_single::<String>(&buffer);
            assert!(decoder.state.carry.is_empty());
            assert!(!decoder.state.builder.is_complete);
            assert_eq!(Event::default(), decoder.state.builder.event);
            assert_eq!(Some(event), event_out);
        }
    }

    #[tokio::test]
    async fn test_json_event_serialize() {
        for (expected, event) in [
            ("data: {}\n\n", event!(JsonEventData(json!({})),)),
            (
                "data: {\"name\":\"john\"}\n\n",
                event!(JsonEventData(json!({"name": "john"})),),
            ),
        ] {
            let buffer = event.serialize().unwrap().try_into_string().await.unwrap();
            assert_eq!(expected, buffer);
        }
    }

    #[tokio::test]
    async fn test_json_event_deserialize() {
        #[derive(Debug, Deserialize, Default, PartialEq, Eq)]
        struct Data {
            points: Option<Vec<u32>>,
        }
        type PointsEvent = Event<JsonEventData<Data>>;

        for (input, expected) in [
            (
                "data: {}\n\n",
                Some(event!(JsonEventData(Data::default()),)),
            ),
            (
                "data: {\"points\":[]}\nevent: message\n\n",
                Some(event!(
                    JsonEventData(Data {
                        points: Some(vec![])
                    }),
                    event = "message",
                )),
            ),
            (
                "data: {\"points\":[4,2]}\nevent: ping\n\n",
                Some(event!(
                    JsonEventData(Data {
                        points: Some(vec![4, 2])
                    }),
                    event = "ping",
                )),
            ),
        ] {
            let (event_out, decoder) = parse_single::<JsonEventData<Data>>(input);
            assert!(
                decoder.state.carry.is_empty(),
                "input: '{input}'; decoder: '{decoder:?}'"
            );
            assert!(
                !decoder.state.builder.is_complete,
                "input: '{input}'; decoder: '{decoder:?}'"
            );
            assert_eq!(
                PointsEvent::default(),
                decoder.state.builder.event,
                "input: '{input}'"
            );
            assert_eq!(expected, event_out, "input: '{input}'");
        }
    }

    #[tokio::test]
    async fn test_json_event_serialize_deserialize() {
        #[derive(Debug, Serialize, Deserialize, Default, PartialEq, Eq)]
        struct Log {
            text: String,
        }
        type LogEvent = Event<JsonEventData<Log>>;

        for event in [
            event!(
                JsonEventData(Log {
                    text: "a log line".to_owned()
                }),
                event = "message",
            ),
            event!(
                JsonEventData(Log {
                    text: "another log line".to_owned()
                }),
                event = "final",
                id = "L3",
                comment = "this is",
                comment = " a log",
            ),
        ] {
            let buffer = event.serialize().unwrap().try_into_string().await.unwrap();
            let (event_out, decoder) = parse_single::<JsonEventData<Log>>(&buffer);
            assert!(decoder.state.carry.is_empty());
            assert!(!decoder.state.builder.is_complete);
            assert_eq!(LogEvent::default(), decoder.state.builder.event);
            assert_eq!(Some(event), event_out);
        }
    }

    #[tokio::test]
    async fn test_multiline_event_serialize() {
        for (expected, event) in [
            ("data: \n\n", event!(Vec::<String>::default(),)),
            ("data: a\n\n", event!(vec!["a".to_owned()],)),
            (
                "data: a\ndata: b\n\n",
                event!(vec!["a".to_owned(), "b".to_owned()],),
            ),
        ] {
            let buffer = event.serialize().unwrap().try_into_string().await.unwrap();
            assert_eq!(expected, buffer);
        }
    }

    #[tokio::test]
    async fn test_multiline_event_deserialize() {
        for (input, expected) in [
            ("", None),
            ("data: \n\n", Some(event!(vec![String::default()],))),
            ("data: a\n\n", Some(event!(vec!["a".to_owned()],))),
            (
                "data: a\ndata: b\n\n",
                Some(event!(vec!["a".to_owned(), "b".to_owned()],)),
            ),
        ] {
            let (event_out, decoder) = parse_single::<Vec<String>>(input);
            assert!(
                decoder.state.carry.is_empty(),
                "input: '{input}'; decoder: '{decoder:?}'"
            );
            assert!(
                !decoder.state.builder.is_complete,
                "input: '{input}'; decoder: '{decoder:?}'"
            );
            assert_eq!(
                Event::<Vec<String>>::default(),
                decoder.state.builder.event,
                "input: '{input}'"
            );
            assert_eq!(expected, event_out, "input: '{input}'");
        }
    }

    #[tokio::test]
    async fn test_multiline_event_serialize_deserialize() {
        type MultilineEvent = Event<Vec<String>>;

        for event in [
            event!(vec!["foo".to_owned(), "bar".to_owned()], event = "message",),
            event!(
                vec!["foo".to_owned()],
                event = "final",
                id = "L3",
                comment = "this is",
                comment = " a log",
            ),
        ] {
            let buffer = event.serialize().unwrap().try_into_string().await.unwrap();
            let (event_out, decoder) = parse_single::<Vec<String>>(&buffer);
            assert!(decoder.state.carry.is_empty());
            assert!(!decoder.state.builder.is_complete);
            assert_eq!(MultilineEvent::default(), decoder.state.builder.event);
            assert_eq!(Some(event), event_out);
        }
    }

    /// serialization is only used to build the round-trip inputs above
    #[allow(dead_code, reason = "keeps the trait bound visible at a glance")]
    fn _assert_serializable<T: EventDataWrite>() {}
}
