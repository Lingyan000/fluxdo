//! Bounded synchronous fuzz entry points and timing hooks for transport-independent H3 state.

use super::{
    Error,
    connection::{Config, Shared},
    control::{Control, Role},
    datagram::{
        AbortRequest, DatagramConfig, DatagramDrops, DatagramLimits, Demux, MIN_DATAGRAM_CHARGE,
        ReceiveEnd, Semantics,
    },
    frame::{FrameDecoder, FrameEvent},
    headers::{encode_request, request_head as decode_request_head},
    observation::Recorder,
    qpack::{Decoder, DecoderConfig, Encoder, EncoderConfig, FieldPair},
    quic::RecvStream,
    stream::{Phase, Reader},
};
use crate::proto::target::{OutgoingHost, outgoing_host};
use ahash::{HashMap, HashSet};
use rama_core::{
    bytes::{Buf as _, Bytes, BytesMut},
    extensions::ExtensionsRef as _,
};
use rama_http::datagram::ViolationPolicy;
use rama_http_types::{
    Method,
    proto::{
        ext::Protocol,
        h3::{Code, Settings, StreamType, observation::ObservationLimits},
    },
};
use rama_utils::octets;
use std::{
    cell::RefCell,
    future::Future,
    pin::Pin,
    rc::Rc,
    sync::{Arc, atomic::AtomicBool},
    task::{Context, Poll, Waker},
    time::Duration,
};
use tokio::time::Instant;

struct Fragmented {
    bytes: Bytes,
    fragment: usize,
    pending: bool,
}
impl RecvStream for Fragmented {
    fn poll_chunk(
        &mut self,
        cx: &mut Context<'_>,
        limit: usize,
    ) -> Poll<Result<Option<Bytes>, Error>> {
        self.pending = !self.pending;
        if self.pending {
            cx.waker().wake_by_ref();
            return Poll::Pending;
        }
        Poll::Ready(Ok((!self.bytes.is_empty()).then(|| {
            self.bytes
                .split_to(limit.min(self.fragment).min(self.bytes.len()))
        })))
    }
    fn stop(&mut self, _code: Code) {
        self.bytes = Bytes::new();
    }
}

/// Exercise fragmented frame placement, stream registration, completion and cancellation.
/// The first three bytes select role, message phase and fragmentation. Remaining
/// bytes are wire input, with fixed memory/work caps independent of advertised lengths.
pub fn state(input: &[u8]) {
    compression_schedule(input);
    if input.len() < 3 {
        return;
    }
    let role = if input[0] & 1 == 0 {
        Role::Client
    } else {
        Role::Server
    };
    let fragment = usize::from(input[2] % 32) + 1;
    let bytes = Bytes::copy_from_slice(&input[3..input.len().min(rama_utils::octets::kib(64))]);
    let mut control = Control::new(role);
    let limits = ObservationLimits {
        bytes: octets::kib(1),
        events: usize::from(input[0]),
        fields: 8,
        streams: 4,
        retained_snapshots: 2,
        pending_fields: 2,
    };
    let mut observation = Recorder::new(limits, &Settings::new());
    for &kind in &input[..3] {
        let ty = StreamType::new(u64::from(kind & 7));
        observation.stream(u64::from(kind), ty);
        let _result = control.register(ty);
    }
    let mut frames =
        FrameDecoder::with_input_limit(rama_utils::octets::kib(4), 32).with_header_events();
    for part in bytes.chunks(fragment) {
        if frames.feed(part).is_err() {
            break;
        }
        while let Ok(Some(event)) = frames.poll() {
            if control.receive(&event).is_err() {
                break;
            }
            observation.control(&event);
        }
    }
    let snapshot = observation.snapshot(None, None, None);
    assert!(snapshot.control.len() <= limits.events);
    assert!(snapshot.streams.len() <= limits.streams);
    let Ok(shared) = Shared::new(
        Config {
            observation: Some(Box::new(limits)),
            max_frame_size: rama_utils::octets::kib(4),
            read_chunk_size: 32,
            ..Config::default()
        },
        role,
        Default::default(),
    ) else {
        return;
    };
    let mut reader = Reader::new(
        Fragmented {
            bytes,
            fragment,
            pending: false,
        },
        shared,
        0,
    );
    reader.phase = match input[1] % 4 {
        0 => Phase::Headers,
        1 => Phase::Body,
        2 => Phase::Trailers,
        _ => Phase::Tunnel,
    };
    let mut cx = Context::from_waker(Waker::noop());
    for _ in 0..input
        .len()
        .saturating_mul(4)
        .min(rama_utils::octets::mib(1))
    {
        match reader.poll_event(&mut cx) {
            Poll::Ready(Ok(Some(FrameEvent::Headers(_)))) => {
                reader.phase = if reader.phase == Phase::Headers {
                    Phase::Body
                } else {
                    Phase::Trailers
                };
            }
            Poll::Ready(Err(_) | Ok(None)) => break,
            _ => (),
        }
    }
    // Abandoning a partial stream exercises STOP and queued QPACK cancellation.
}

// Correlated field sections exercise the live Shared decoder waiters, output
// reservations, cancellation retries and partial instruction delivery together.
#[expect(
    clippy::unwrap_used,
    reason = "correlated valid streams must succeed or explicitly exhaust their budget"
)]
fn compression_schedule(input: &[u8]) {
    let shared = Shared::new(
        Config {
            decoder: DecoderConfig {
                max_decoder_stream_bytes: 10,
                ..DecoderConfig::default()
            },
            observation: Some(Box::new(ObservationLimits {
                bytes: octets::kib(1),
                events: 8,
                fields: 4,
                streams: 4,
                retained_snapshots: 2,
                pending_fields: 2,
            })),
            max_requests: 4,
            ..Config::default()
        },
        Role::Server,
        Default::default(),
    )
    .unwrap();
    let mut encoder = Encoder::new(EncoderConfig {
        max_blocked_streams: 4,
        ..EncoderConfig::default()
    });
    let mut forward = BytesMut::new();
    let mut feedback = Bytes::new();
    let mut pending: [Option<Pin<Box<dyn Future<Output = _>>>>; 4] = std::array::from_fn(|_| None);
    let mut ids = [0, 4, 8, 12];
    let mut cx = Context::from_waker(Waker::noop());
    for &operation in input.iter().take(1024) {
        let slot = usize::from(operation >> 6);
        match operation & 3 {
            0 if pending[slot].is_none() && forward.len() < rama_utils::octets::kib(4) => {
                let section = encoder
                    .encode(ids[slot], [("x-scheduled", "repeated dynamic value")])
                    .unwrap();
                forward.extend_from_slice(&encoder.take_encoder_stream());
                pending[slot] = Some(Box::pin(shared.decode(ids[slot], section)));
            }
            1 if !forward.is_empty() => {
                let len = forward.len().min(usize::from((operation >> 2) & 7) + 1);
                if !shared
                    .feed_instructions(StreamType::QPACK_ENCODER, &forward[..len])
                    .unwrap()
                {
                    forward.advance(len);
                }
            }
            2 => {
                if feedback.is_empty() {
                    feedback = shared.take_decoder_output().unwrap();
                }
                let len = feedback.len().min(usize::from((operation >> 2) & 7) + 1);
                encoder
                    .feed_decoder_stream(&feedback.split_to(len))
                    .unwrap();
                shared.decoder_output_written(len).unwrap();
            }
            3 if pending[slot].is_some() => {
                pending[slot] = None;
                shared.cancel(ids[slot]);
                ids[slot] += 16;
            }
            _ => (),
        }
        if let Some(error) = shared.error() {
            assert_eq!(error.code(), Code::H3_EXCESSIVE_LOAD);
            return;
        }
        for slot in 0..4 {
            if let Some(future) = &mut pending[slot]
                && let Poll::Ready(fields) = future.as_mut().poll(&mut cx)
            {
                let fields = fields.unwrap();
                assert_eq!(fields.len(), 1);
                assert_eq!(fields[0].value, "repeated dynamic value");
                let (_, captured) = shared.request_observation(ids[slot], &fields).unwrap();
                assert!(captured.fields.len() <= 4);
                assert!(captured.connection.encoder_instructions.len() <= 8);
                pending[slot] = None;
                ids[slot] += 16;
            }
        }
    }
    for slot in 0..4 {
        pending[slot] = None;
        shared.cancel(ids[slot]);
        if let Some(error) = shared.error() {
            assert_eq!(error.code(), Code::H3_EXCESSIVE_LOAD);
            return;
        }
    }
    // Drain withheld transport bytes before pending cancellation output. Each
    // drain releases the exact reservation held by the live connection code.
    loop {
        if feedback.is_empty() {
            feedback = shared.take_decoder_output().unwrap();
        }
        if feedback.is_empty() {
            break;
        }
        let len = feedback.len();
        encoder.feed_decoder_stream(&feedback).unwrap();
        feedback = Bytes::new();
        shared.decoder_output_written(len).unwrap();
    }
    assert_eq!(encoder.tracked_section_count(), 0);
    assert_eq!(encoder.tracked_reference_count(), 0);
}

/// Aborts nothing: the timing driver never violates datagram semantics.
#[derive(Clone)]
struct NoAbort;

impl AbortRequest for NoAbort {
    fn abort_request(&self) {}
}

/// Synchronous access to the demux critical sections, which run under the connection's
/// datagram lock, so they can be timed without a connection.
pub struct DemuxDriver {
    demux: Demux<NoAbort>,
    config: DatagramConfig,
    now: Instant,
    registered: u64,
    next_stream: u64,
}

impl DemuxDriver {
    /// A demux with `registered` requests that claim datagram semantics.
    #[must_use]
    pub fn new(registered: usize) -> Self {
        let mut driver = Self {
            demux: Demux::default(),
            config: DatagramConfig::default(),
            now: Instant::now(),
            registered: registered as u64,
            next_stream: 0,
        };
        for _ in 0..registered {
            driver.register_next();
        }
        driver
    }

    fn register_next(&mut self) -> u64 {
        let stream = self.next_stream;
        self.next_stream += 4;
        self.demux
            .register(
                &self.config,
                stream,
                Semantics::Claimed,
                NoAbort,
                Arc::new(AtomicBool::new(false)),
                self.now,
            )
            .run();
        stream
    }

    /// Deliver a datagram to request `index` and take it back out.
    pub fn deliver_and_take(&mut self, index: usize, payload: &Bytes) -> Option<Bytes> {
        let stream = (index as u64 % self.registered.max(1)) * 4;
        self.demux
            .deliver(
                &self.config,
                stream,
                payload,
                self.now,
                Duration::from_millis(100),
            )
            .run();
        self.take(stream)
    }

    /// Hold a datagram for the next, not yet registered request, register it and take it out.
    pub fn adopt_and_take(&mut self, payload: &Bytes) -> Option<Bytes> {
        let stream = self.next_stream;
        self.demux
            .deliver(
                &self.config,
                stream,
                payload,
                self.now,
                Duration::from_millis(100),
            )
            .run();
        self.register_next();
        let taken = self.take(stream);
        _ = self.demux.unregister(stream);
        taken
    }

    /// A demux of `registered` requests whose queues fill the byte budget, two datagrams each,
    /// beside `held` datagrams for requests still to come: every further datagram for a
    /// request has to evict one.
    #[must_use]
    pub fn saturated(registered: usize, held: usize) -> Self {
        let charge = super::datagram::MIN_DATAGRAM_CHARGE;
        let mut driver = Self {
            demux: Demux::default(),
            config: DatagramConfig {
                limits: super::datagram::DatagramLimits {
                    queue_len: 32,
                    pending_len: held.max(1),
                    max_buffered_bytes: (2 * registered + held) * charge,
                },
                violations: ViolationPolicy::default(),
            },
            now: Instant::now(),
            registered: registered as u64,
            next_stream: 0,
        };
        for _ in 0..registered {
            driver.register_next();
        }
        let payload = Bytes::from_static(&[7]);
        for index in 0..held {
            let stream = driver.next_stream + 4 * index as u64;
            driver.deliver(stream, &payload);
        }
        for index in 0..2 * registered {
            driver.deliver((index as u64 % driver.registered) * 4, &payload);
        }
        driver
    }

    /// A demux of `registered` requests whose queues fill a byte budget of `budget` bytes in
    /// small datagrams, spread over the first `filled` requests; the others stay registered
    /// with empty queues, as retained but idle handles do.
    #[must_use]
    pub fn filled(registered: usize, filled: usize, budget: usize) -> Self {
        let charge = super::datagram::MIN_DATAGRAM_CHARGE;
        let mut driver = Self {
            demux: Demux::default(),
            config: DatagramConfig {
                limits: super::datagram::DatagramLimits {
                    queue_len: budget / charge + 1,
                    pending_len: 1,
                    max_buffered_bytes: budget,
                },
                violations: ViolationPolicy::default(),
            },
            now: Instant::now(),
            registered: registered as u64,
            next_stream: 0,
        };
        for _ in 0..registered {
            driver.register_next();
        }
        let payload = Bytes::from_static(&[7]);
        let filled = filled.clamp(1, registered.max(1)) as u64;
        for index in 0..budget / charge {
            driver.deliver((index as u64 % filled) * 4, &payload);
        }
        driver
    }

    /// Deliver a datagram to request `index` without taking it out.
    pub fn deliver_to(&mut self, index: usize, payload: &Bytes) {
        let stream = (index as u64 % self.registered.max(1)) * 4;
        self.deliver(stream, payload);
    }

    fn deliver(&mut self, stream: u64, payload: &Bytes) {
        self.demux
            .deliver(
                &self.config,
                stream,
                payload,
                self.now,
                Duration::from_millis(100),
            )
            .run();
    }

    fn take(&mut self, stream: u64) -> Option<Bytes> {
        match self
            .demux
            .poll_recv(stream, &Context::from_waker(Waker::noop()))
        {
            Poll::Ready(Ok(payload)) => payload,
            _ => None,
        }
    }
}

/// Records the requests the demux aborted, for the harness to end their receive side.
#[derive(Clone)]
struct RecordAbort(u64, Rc<RefCell<Vec<u64>>>);

impl AbortRequest for RecordAbort {
    fn abort_request(&self) {
        self.1.borrow_mut().push(self.0);
    }
}

/// What the harness knows of each delivered datagram, keyed by its sequence number.
struct Sent {
    stream: u64,
    // Delivered after the stream's receive side ended: it must never be yielded.
    after_end: bool,
}

/// Drive the datagram demultiplexer with arbitrary driver and consumer events.
///
/// Every delivered datagram must end exactly once: yielded, counted as a drop, released with
/// its stream, or still held. Yields keep per-stream delivery order and never include a
/// datagram delivered after its stream's receive side ended; the byte accounting matches
/// what is held, within the limits.
#[expect(
    clippy::unwrap_used,
    reason = "fuzz oracle: a violated invariant must crash the target"
)]
/// Returns the drops and how many datagrams were yielded, so a caller can tell the run
/// reached the paths it means to cover.
pub fn datagram_demux(input: &[u8]) -> (DatagramDrops, u64) {
    let mut input = input.iter().copied();
    let mut next = move || input.next();
    let (Some(queue_len), Some(pending_len), Some(budget), Some(flags)) =
        (next(), next(), next(), next())
    else {
        return Default::default();
    };
    let config = DatagramConfig {
        limits: DatagramLimits {
            queue_len: usize::from(queue_len % 6),
            pending_len: usize::from(pending_len % 6),
            // Every datagram is charged at least a packet: up to about 16 of them fit.
            max_buffered_bytes: usize::from(budget) * MIN_DATAGRAM_CHARGE / 16,
        },
        violations: if flags & 1 == 0 {
            ViolationPolicy::Ignore
        } else {
            ViolationPolicy::Reject
        },
    };
    let lifetime = Duration::from_millis(100);
    let start = Instant::now();
    let mut elapsed = Duration::ZERO;
    let aborted = Rc::new(RefCell::new(Vec::new()));
    let mut demux: Demux<RecordAbort> = Demux::default();
    let mut sent: HashMap<u32, Sent> = HashMap::default();
    let mut ended: HashSet<u64> = HashSet::default();
    let mut last_yield: HashMap<u64, u32> = HashMap::default();
    let (mut delivered, mut yielded, mut released) = (0u64, 0u64, 0u64);
    let mut registered: HashSet<u64> = HashSet::default();
    let mut next_stream = 0u64;
    let waker = Waker::noop();
    let cx = Context::from_waker(waker);

    while let (Some(op), Some(arg)) = (next(), next()) {
        let stream = u64::from(arg % 8) * 4;
        let now = start + elapsed;
        let action = match op % 8 {
            0 => {
                let seq = u32::try_from(delivered).unwrap();
                let mut payload = seq.to_be_bytes().to_vec();
                payload.resize(4 + usize::from(op >> 3), 0);
                sent.insert(
                    seq,
                    Sent {
                        stream,
                        after_end: ended.contains(&stream),
                    },
                );
                delivered += 1;
                demux.deliver(&config, stream, &Bytes::from(payload), now, lifetime)
            }
            // Streams register once, in order, as the driver sees them.
            1 if stream >= next_stream => {
                next_stream = stream + 4;
                registered.insert(stream);
                let semantics = match op >> 3 & 3 {
                    0 => Semantics::Provisional,
                    1 => Semantics::Claimed,
                    _ => Semantics::None,
                };
                let abort = RecordAbort(stream, aborted.clone());
                demux.register(
                    &config,
                    stream,
                    semantics,
                    abort,
                    Arc::new(AtomicBool::new(false)),
                    now,
                )
            }
            // A refused response ends what a provisional claim had queued.
            2 if op & 16 != 0 => {
                demux.refuse(stream);
                Default::default()
            }
            2 => demux.decide(&config, stream, op & 8 != 0),
            3 => {
                released += demux.queued(stream) as u64;
                registered.remove(&stream);
                _ = demux.unregister(stream);
                Default::default()
            }
            4 if registered.contains(&stream) => {
                let end = match op >> 3 & 3 {
                    0 => ReceiveEnd::Finished,
                    1 => ReceiveEnd::Reset(0),
                    2 => ReceiveEnd::Aborted(0),
                    _ => ReceiveEnd::Released,
                };
                ended.insert(stream);
                _ = demux.receive_ended(stream, end);
                Default::default()
            }
            5 => {
                if let Poll::Ready(Ok(Some(payload))) = demux.poll_recv(stream, &cx) {
                    let seq = u32::from_be_bytes(payload[..4].try_into().unwrap());
                    let origin = &sent[&seq];
                    assert_eq!(origin.stream, stream, "yielded for another stream");
                    assert!(!origin.after_end, "yielded after the receive side ended");
                    let last = last_yield.insert(stream, seq);
                    assert!(last.is_none_or(|last| last < seq), "out of delivery order");
                    yielded += 1;
                }
                Default::default()
            }
            // Rare: a closed connection drops everything after it, ending the run's coverage.
            6 if arg % 32 == 0 => {
                ended.extend(registered.iter().copied());
                _ = demux.close();
                Default::default()
            }
            7 => {
                elapsed += Duration::from_millis(u64::from(arg) * 4);
                Default::default()
            }
            _ => Default::default(),
        };
        action.run();
        // An aborted request's receive side ends, as the stream abort makes it.
        for stream in aborted.borrow_mut().drain(..) {
            ended.insert(stream);
            _ = demux.receive_ended(stream, ReceiveEnd::Aborted(0));
        }

        demux.assert_consistent(&config.limits);
        let drops = demux.drops();
        let dropped = drops.no_semantics
            + drops.invalid_id
            + drops.beyond_limit
            + drops.unknown_stream
            + drops.receive_closed
            + drops.queue_full
            + drops.over_budget
            + drops.expired
            + drops.unadvertised;
        let held: usize = registered.iter().map(|stream| demux.queued(*stream)).sum();
        let held = (held + demux.pending_len()) as u64;
        assert_eq!(
            delivered,
            yielded + dropped + released + held,
            "a datagram was lost or counted twice"
        );
    }
    (demux.drops(), yielded)
}

/// Field names the request-head input selects from; other selectors become raw names.
const REQUEST_FIELD_NAMES: [&[u8]; 12] = [
    b":method",
    b":scheme",
    b":authority",
    b":path",
    b":protocol",
    b":status",
    b"host",
    b"content-length",
    b"capsule-protocol",
    b"connection",
    b"te",
    b"x-field",
];

/// Decode arbitrary request field lines with and without Extended CONNECT (RFC 9220 §3).
/// A head that is accepted must re-encode, and decode back to the same request, so a relay
/// can forward everything it accepts. Each field is a selector byte, a length and a value.
/// Returns how many of the two variants accepted the head.
#[expect(
    clippy::expect_used,
    reason = "an accepted head that cannot be forwarded is the defect this oracle reports"
)]
pub fn request_head(input: &[u8]) -> usize {
    let mut fields = Vec::new();
    let mut rest = input;
    while let [selector, len, tail @ ..] = rest
        && fields.len() < 32
    {
        let (value, next) = tail.split_at(usize::from(len % 64).min(tail.len()));
        let name = REQUEST_FIELD_NAMES
            .get(usize::from(selector & 0x7f))
            .map_or_else(
                || Bytes::copy_from_slice(&[*selector]),
                |name| Bytes::from_static(name),
            );
        fields.push(FieldPair {
            name,
            value: Bytes::copy_from_slice(value),
            never_index: selector & 0x80 != 0,
        });
        rest = next;
    }
    let mut accepted = 0;
    for extended_connect in [false, true] {
        let Ok(request) = decode_request_head(fields.clone(), extended_connect) else {
            continue;
        };
        accepted += 1;
        let protocol = request.extensions().get_ref::<Protocol>().cloned();
        assert!(
            protocol.is_none() || (extended_connect && request.method() == Method::CONNECT),
            ":protocol accepted outside an enabled Extended CONNECT"
        );
        let Ok(shared) = Shared::new(Config::default(), Role::Client, Default::default()) else {
            return accepted;
        };
        // Without a URI authority, an http(s) target without Host, or a Host unusable as the
        // only authority, is received but cannot be sent on. An asterisk URI keeps its scheme
        // in an extension, as the encoder reads it.
        let http_scheme = request
            .uri()
            .scheme()
            .or_else(|| request.extensions().get_ref::<rama_net::Protocol>())
            .is_some_and(rama_net::Protocol::is_http);
        let unroutable = request.uri().authority().is_none()
            && match outgoing_host(request.headers()) {
                OutgoingHost::Absent => http_scheme,
                OutgoingHost::Unusable => true,
                OutgoingHost::Usable(..) => false,
            };
        let encoded = encode_request(&shared, 0, &request);
        assert_eq!(encoded.is_err(), unroutable, "an accepted head re-encodes");
        let Ok(encoded) = encoded else {
            continue;
        };
        let decoded = Decoder::new(DecoderConfig::default())
            .decode_field_section(0, encoded)
            .expect("the encoder output decodes")
            .expect("static-only sections never block");
        let again = decode_request_head(decoded, extended_connect).expect("re-encoded head");
        assert_eq!(again.method(), request.method());
        assert_eq!(again.uri(), request.uri());
        assert_eq!(again.headers(), request.headers());
        assert_eq!(again.extensions().get_ref::<Protocol>().cloned(), protocol);
    }
    accepted
}

#[cfg(test)]
mod tests {
    use super::{REQUEST_FIELD_NAMES, datagram_demux, request_head};

    /// One oracle input: each field is a vocabulary index, a length and a value.
    fn head(fields: &[(&[u8], &str)]) -> Vec<u8> {
        fields
            .iter()
            .flat_map(|(name, value)| {
                let selector = REQUEST_FIELD_NAMES.iter().position(|known| known == name);
                let mut bytes = vec![u8::try_from(selector.unwrap()).unwrap(), value.len() as u8];
                bytes.extend_from_slice(value.as_bytes());
                bytes
            })
            .collect()
    }

    /// The forwarding contract on named targets: how many of the two variants (Extended
    /// CONNECT off/on) accept each head; every accepted one must round-trip unchanged.
    #[test]
    fn named_request_targets_follow_the_forwarding_contract() {
        let (method, scheme, authority, path, protocol, host) = (
            &b":method"[..],
            &b":scheme"[..],
            &b":authority"[..],
            &b":path"[..],
            &b":protocol"[..],
            &b"host"[..],
        );
        for (fields, accepted) in [
            (
                &[
                    (method, "GET"),
                    (scheme, "https"),
                    (authority, "example.com"),
                    (path, "/"),
                ][..],
                2,
            ),
            (&[(method, "GET"), (scheme, "custom"), (path, "/")], 2),
            (
                &[
                    (method, "GET"),
                    (scheme, "ftp"),
                    (authority, "user@example.com"),
                    (path, "/"),
                ],
                2,
            ),
            (
                &[
                    (method, "CONNECT"),
                    (scheme, "https"),
                    (authority, "example.com"),
                    (path, "/"),
                    (protocol, "x"),
                ],
                1,
            ),
            // RFC 9114 §4.3.1 requires authority and path only for http(s).
            (
                &[
                    (method, "CONNECT"),
                    (scheme, "custom"),
                    (path, "/"),
                    (protocol, "x"),
                ],
                1,
            ),
            (
                &[
                    (method, "CONNECT"),
                    (scheme, "custom"),
                    (authority, "example.com"),
                    (path, ""),
                    (protocol, "x"),
                ],
                1,
            ),
            // Accepted, dropping userinfo: the HTTP family, ws/wss included, never carries it.
            (
                &[
                    (method, "GET"),
                    (scheme, "https"),
                    (authority, "user@example.com"),
                    (path, "/"),
                ],
                2,
            ),
            (
                &[
                    (method, "GET"),
                    (scheme, "ws"),
                    (authority, "user@example.com"),
                    (path, "/"),
                ],
                2,
            ),
            (
                &[
                    (method, "GET"),
                    (scheme, "wss"),
                    (authority, "user@example.com"),
                    (path, "/"),
                ],
                2,
            ),
            // An asterisk target's authority becomes Host, without userinfo.
            (
                &[
                    (method, "OPTIONS"),
                    (scheme, "ftp"),
                    (authority, "user@example.com"),
                    (path, "*"),
                ],
                2,
            ),
            // A raw ws/wss Extended CONNECT scheme is carried as http/https (RFC 8441 §5).
            (
                &[
                    (method, "CONNECT"),
                    (scheme, "ws"),
                    (authority, "example.com"),
                    (path, "/"),
                    (protocol, "x"),
                ],
                1,
            ),
            // Any other scheme is forwarded as received, websocket included.
            (
                &[
                    (method, "CONNECT"),
                    (scheme, "custom"),
                    (authority, "example.com"),
                    (path, "/"),
                    (protocol, "websocket"),
                ],
                1,
            ),
            // Host naming another authority is replaced by the one Rama routes on.
            (
                &[
                    (method, "GET"),
                    (scheme, "https"),
                    (authority, "example.com"),
                    (path, "/"),
                    (host, "other.example"),
                ],
                2,
            ),
            // An empty-port Host is not the same authority, so it is replaced.
            (
                &[
                    (path, ""),
                    (method, "v"),
                    (scheme, "-"),
                    (authority, "-"),
                    (host, "-:"),
                ],
                2,
            ),
            // A raw UTF-8 authority has no Host form, so a Host beside it goes, matching or not.
            (
                &[
                    (path, ""),
                    (method, "~"),
                    (scheme, "-"),
                    (authority, "\u{fffd}"),
                    (host, "bad host"),
                ],
                2,
            ),
            (
                &[
                    (method, "GET"),
                    (scheme, "https"),
                    (authority, "bücher.example"),
                    (path, "/"),
                    (host, "bücher.example"),
                ],
                2,
            ),
            // An authority without a host is refused, whatever its scheme.
            (
                &[
                    (path, ""),
                    (method, "v"),
                    (scheme, "-"),
                    (authority, "@"),
                    (host, "ee.e-ehhhhhhhhhh"),
                ],
                0,
            ),
            // A path-less OPTIONS of another scheme is the server-wide `*`, on every version.
            (
                &[
                    (method, "OPTIONS"),
                    (scheme, "custom"),
                    (authority, "example.com"),
                    (path, ""),
                ],
                2,
            ),
            // Accepted like H1/H2, but a Host unusable as the only authority is not sent on.
            (
                &[(path, ""), (method, "~"), (scheme, "-"), (host, "bad host")],
                2,
            ),
            // Bare asterisk targets keep their scheme in an extension.
            (&[(method, "OPTIONS"), (scheme, "http"), (path, "*")], 2),
            (&[(method, "OPTIONS"), (scheme, "HTTP"), (path, "*")], 2),
            (&[(method, "OPTIONS"), (scheme, "custom"), (path, "*")], 2),
            (
                &[
                    (method, "OPTIONS"),
                    (scheme, "https"),
                    (path, "*"),
                    (host, "example.com"),
                ],
                2,
            ),
            // Received without any authority; it cannot be sent on.
            (&[(method, "GET"), (scheme, "https"), (path, "/")], 2),
            // RFC 9114 §4.3.1: Host stands in for :authority.
            (
                &[
                    (method, "CONNECT"),
                    (scheme, "https"),
                    (path, "/"),
                    (protocol, "websocket"),
                    (host, "example.com"),
                ],
                1,
            ),
        ] {
            assert_eq!(request_head(&head(fields)), accepted, "{fields:?}");
        }
    }

    /// Well-formed Extended CONNECT heads, then their byte-level mutations.
    #[test]
    fn request_heads_round_trip_when_accepted() {
        let head = head(&[
            (b":method", "CONNECT"),
            (b":protocol", "websocket"),
            (b":scheme", "https"),
            (b":authority", "example.com"),
            (b":path", "/chat"),
            (b"capsule-protocol", "?1"),
        ]);
        assert_eq!(
            request_head(&head),
            1,
            "accepted only with Extended CONNECT"
        );
        let mut accepted = 0;
        for index in 0..head.len() {
            for flip in [0x01, 0x20, 0x80] {
                let mut mutated = head.clone();
                mutated[index] ^= flip;
                accepted += request_head(&mutated);
            }
        }
        assert!(
            accepted > 0,
            "some mutations stay acceptable and round-trip"
        );
    }

    /// The fuzz oracle over deterministic inputs, so its conservation checks run with every
    /// test pass and not only under a fuzzer.
    #[test]
    fn datagram_demux_sequences_keep_their_invariants() {
        let mut state = 0x9e37_79b9_7f4a_7c15u64;
        let mut next = move || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        let (mut yielded, mut queue_full, mut over_budget, mut expired) = (0, 0, 0, 0);
        for _ in 0..4000 {
            let len = usize::try_from(next() % 512).unwrap();
            let input: Vec<u8> = (0..len.div_ceil(8))
                .flat_map(|_| next().to_le_bytes())
                .take(len)
                .collect();
            let (drops, run_yielded) = datagram_demux(&input);
            yielded += run_yielded;
            queue_full += drops.queue_full;
            over_budget += drops.over_budget;
            expired += drops.expired;
        }
        // The oracle only guards what it reaches: delivery, both evictions and expiry.
        assert!(
            yielded > 0 && queue_full > 0 && over_budget > 0 && expired > 0,
            "yielded={yielded} queue_full={queue_full} over_budget={over_budget} expired={expired}"
        );
    }
}
