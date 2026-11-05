//! Packet I/O ownership and transmit adaptation.

use rama_utils::octets;
use std::{
    collections::VecDeque,
    fmt::Debug,
    io::{self, IoSliceMut},
    net::{IpAddr, SocketAddr},
    num::NonZeroUsize,
    task::{Context, Poll, ready},
};

use rama_core::telemetry::tracing::{debug, warn};
use rama_net::address::{SocketAddress, ip::IntoCanonicalIpAddr as _};
use rama_udp::{
    DatagramCapabilities, DatagramError, DatagramFeature, DatagramMetadata, DatagramSender,
    DatagramSocket, SendDatagram, SendFailure,
};

use crate::driver::{
    Duration, Instant,
    sockets::{Lease, SocketId},
};
use crate::proto;

// Stateless responses are expendable under load, but a queued response must get a real
// readiness registration even when no further peer packet or connection timer arrives.
const MAX_RESPONSES: usize = 64;
const MAX_RESPONSE_BYTES: usize = octets::kib(64);
pub(crate) const SEND_WORK_LIMIT: usize = 32;
const FAILURE_WARNING_INTERVAL: Duration = Duration::from_secs(60);

/// A transmit the socket refused, classified for the caller's failure policy.
///
/// `Datagram` and `TooLarge` failures lose only the affected datagram; `Descriptor` failures
/// mean the request itself is invalid; `Socket` failures mean the send handle is unusable.
#[derive(Debug)]
pub(crate) struct SendError {
    pub(crate) class: SendFailure,
    pub(crate) error: io::Error,
}

impl SendError {
    fn descriptor(message: &'static str) -> Self {
        Self {
            class: SendFailure::Descriptor,
            error: io::Error::new(io::ErrorKind::InvalidInput, message),
        }
    }
}

impl From<DatagramError> for SendError {
    fn from(error: DatagramError) -> Self {
        Self {
            class: error.send_failure(),
            error: io_error(error),
        }
    }
}

/// Keeps per-datagram send failures observable without flooding the log.
#[derive(Debug, Default)]
pub(crate) struct FailureLog {
    last_warning: Option<Instant>,
}

impl FailureLog {
    /// One warning per interval; everything else at debug level.
    pub(crate) fn record(&mut self, now: Instant, what: &'static str, error: &SendError) {
        let warn_now = self
            .last_warning
            .is_none_or(|last| now.saturating_duration_since(last) >= FAILURE_WARNING_INTERVAL);
        if warn_now {
            self.last_warning = Some(now);
            warn!(class = ?error.class, error = %error.error, "{what} failed: datagram dropped");
        } else {
            debug!(class = ?error.class, error = %error.error, "{what} failed: datagram dropped");
        }
    }
}

trait ReceiveSocket: Send + Debug {
    fn create_sender(&self) -> Box<dyn DatagramSender>;
    fn poll_recv(
        &mut self,
        cx: &mut Context<'_>,
        buffers: &mut [IoSliceMut<'_>],
        metadata: &mut [DatagramMetadata],
    ) -> Poll<Result<usize, DatagramError>>;
    fn capabilities(&self) -> DatagramCapabilities;
}

impl<T: DatagramSocket> ReceiveSocket for T {
    fn create_sender(&self) -> Box<dyn DatagramSender> {
        Box::new(DatagramSocket::create_sender(self))
    }

    fn poll_recv(
        &mut self,
        cx: &mut Context<'_>,
        buffers: &mut [IoSliceMut<'_>],
        metadata: &mut [DatagramMetadata],
    ) -> Poll<Result<usize, DatagramError>> {
        DatagramSocket::poll_recv(self, cx, buffers, metadata)
    }

    fn capabilities(&self) -> DatagramCapabilities {
        DatagramSocket::capabilities(self)
    }
}

/// One mutable receive owner and a dedicated sender for stateless responses.
#[derive(Debug)]
pub(crate) struct Socket {
    inner: Box<dyn ReceiveSocket>,
    local_addr: SocketAddr,
    /// The only remote a connected socket or a tunnel reaches.
    fixed_peer: Option<SocketAddr>,
    /// Evidence that this socket receives IPv4, including IPv4 on an IPv6 wildcard bind.
    received_ipv4: bool,
    response_sender: Sender,
    responses: VecDeque<(proto::Transmit, Box<[u8]>)>,
    response_bytes: usize,
    /// Names the response currently being sent, so a partly accepted one cannot lend its offset
    /// to the next.
    response_transmits: u64,
    dropped_responses: u64,
    failed_responses: u64,
    failure_log: FailureLog,
}

impl Socket {
    pub(crate) fn new<T: DatagramSocket>(socket: T) -> io::Result<Self> {
        let local_addr = socket.local_addr()?.into();
        let fixed_peer = socket.peer_addr().ok().map(SocketAddr::from);
        let response_sender = Sender::new(
            Box::new(DatagramSocket::create_sender(&socket)),
            local_addr,
            None,
        );
        Ok(Self {
            inner: Box::new(socket),
            local_addr,
            fixed_peer,
            received_ipv4: false,
            response_sender,
            responses: VecDeque::new(),
            response_bytes: 0,
            response_transmits: 0,
            dropped_responses: 0,
            failed_responses: 0,
            failure_log: FailureLog::default(),
        })
    }

    /// Wrap a bound standard socket for the current Tokio runtime.
    ///
    /// Fails with a useful error outside a runtime instead of panicking.
    pub(crate) fn from_std(socket: std::net::UdpSocket) -> io::Result<Self> {
        if tokio::runtime::Handle::try_current().is_err() {
            return Err(io::Error::other("no async runtime found"));
        }
        socket.set_nonblocking(true)?;
        let socket =
            rama_udp::UdpPacketSocket::from_socket(tokio::net::UdpSocket::from_std(socket)?)
                .map_err(io_error)?;
        Self::new(socket)
    }

    /// The only remote this socket reaches, when it is connected or a tunnel.
    pub(crate) fn fixed_peer(&self) -> Option<SocketAddr> {
        self.fixed_peer
    }

    /// A send handle that owns `lease` on its registry socket.
    pub(crate) fn sender_for(&self, lease: Lease) -> Sender {
        Sender::new(self.inner.create_sender(), self.local_addr, Some(lease))
    }

    /// A send handle outside any registry (tests).
    #[cfg(test)]
    pub(crate) fn create_sender(&self) -> Sender {
        Sender::new(self.inner.create_sender(), self.local_addr, None)
    }

    /// Whether stateless responses are still queued on this socket.
    pub(crate) fn has_responses(&self) -> bool {
        !self.responses.is_empty()
    }

    /// Drop every queued response (the socket became unusable); returns how many were dropped.
    pub(crate) fn discard_responses(&mut self) -> u64 {
        let dropped = self.responses.len() as u64;
        self.responses.clear();
        self.response_bytes = 0;
        dropped
    }

    pub(crate) fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    pub(crate) fn capabilities(&self) -> DatagramCapabilities {
        self.inner.capabilities()
    }

    pub(crate) fn poll_recv(
        &mut self,
        cx: &mut Context<'_>,
        buffers: &mut [IoSliceMut<'_>],
        metadata: &mut [DatagramMetadata],
    ) -> Poll<io::Result<usize>> {
        let outcome = self
            .inner
            .poll_recv(cx, buffers, metadata)
            .map_err(io_error);
        if !self.received_ipv4
            && let Poll::Ready(Ok(received)) = &outcome
            && *received <= buffers.len().min(metadata.len())
        {
            self.received_ipv4 = metadata
                .iter()
                .take(*received)
                .any(|meta| meta.peer.into_canonical_ip_addr().ip_addr.is_ipv4());
        }
        outcome
    }

    /// Whether an IPv4 datagram actually arrived on this socket. The shared UDP abstraction
    /// does not expose IPV6_V6ONLY, so an IPv6 wildcard is offered for an IPv4 local path only
    /// after receiving IPv4 proves that this particular socket supports it.
    pub(crate) fn received_ipv4(&self) -> bool {
        self.received_ipv4
    }

    /// Queue a response without polling from a second task. The caller wakes the endpoint.
    pub(crate) fn queue_response(&mut self, transmit: proto::Transmit, buffer: &[u8]) -> bool {
        let Some(payload) = buffer.get(..transmit.size) else {
            self.dropped_responses += 1;
            return false;
        };
        if self.responses.len() >= MAX_RESPONSES
            || payload.len() > MAX_RESPONSE_BYTES.saturating_sub(self.response_bytes)
        {
            self.dropped_responses += 1;
            return false;
        }
        self.response_bytes += payload.len();
        self.responses.push_back((transmit, payload.into()));
        true
    }

    pub(crate) fn dropped_responses(&self) -> u64 {
        self.dropped_responses
    }

    /// Responses the socket refused for their destination; they are dropped and counted.
    pub(crate) fn failed_responses(&self) -> u64 {
        self.failed_responses
    }

    #[cfg(test)]
    /// Return true when fairness, rather than socket readiness, interrupted sending.
    ///
    /// Only an unusable socket is an error. A response refused for its destination is
    /// expendable: the peer retries or gives up, and other peers keep being served.
    pub(crate) fn drive_responses(
        &mut self,
        cx: &mut Context<'_>,
        now: Instant,
    ) -> io::Result<bool> {
        let mut budget = SEND_WORK_LIMIT;
        Ok(matches!(
            self.drive_responses_within(cx, now, &mut budget)?,
            ResponseProgress::Exhausted
        ))
    }

    /// Like `drive_responses` but drawing on a budget shared with
    /// other sockets polled in the same pass, and distinguishing a sender that is not ready
    /// (the task's waker is registered; nothing to re-poll for) from a budget that ran out with
    /// runnable responses left.
    pub(crate) fn drive_responses_within(
        &mut self,
        cx: &mut Context<'_>,
        now: Instant,
        budget: &mut usize,
    ) -> io::Result<ResponseProgress> {
        while *budget > 0 {
            let Some((transmit, payload)) = self.responses.front() else {
                return Ok(ResponseProgress::Drained);
            };
            *budget -= 1;
            match self.response_sender.poll_transmit(
                cx,
                TransmitId(self.response_transmits),
                transmit,
                payload,
            ) {
                Poll::Pending => return Ok(ResponseProgress::Pending),
                Poll::Ready(Ok(())) => {}
                Poll::Ready(Err(error)) if error.class == SendFailure::Socket => {
                    return Err(error.error);
                }
                Poll::Ready(Err(error)) => {
                    self.failed_responses += 1;
                    self.failure_log.record(now, "stateless response", &error);
                }
            }
            self.response_bytes -= payload.len();
            self.responses.pop_front();
            // The next response is a descriptor of its own, so it starts its own attempt.
            self.response_transmits = self.response_transmits.wrapping_add(1);
        }
        Ok(if self.responses.is_empty() {
            ResponseProgress::Drained
        } else {
            ResponseProgress::Exhausted
        })
    }
}

/// How a response-driving pass ended for one socket.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ResponseProgress {
    /// No response is queued any more.
    Drained,
    /// The sender was not ready; it registered the task's waker for the next attempt.
    Pending,
    /// The budget ran out while runnable responses remain: poll again.
    Exhausted,
}

/// Which descriptor an attempt at the wire belongs to. The caller mints one per descriptor, so
/// bytes a backend accepted for one can never be spliced into another.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TransmitId(pub(crate) u64);

/// What a backend has taken of the descriptor in the sender's hands.
#[derive(Debug, Clone, Copy)]
struct InFlight {
    id: TransmitId,
    /// Bytes already accepted, which must never be offered again. Cleared when there is nothing
    /// left to send, when the descriptor is rejected, and when it is abandoned.
    offset: usize,
    /// Whether the backend took anything at all for this descriptor. It outlives the offset,
    /// because a prefix that left counts even when the rest never does.
    accepted: bool,
}

/// The port of the `bound` socket, with the IP packets were sent to (`observed`) when the socket
/// is bound to a wildcard. `None` when neither tells a specific IP.
pub(crate) fn known_local_address(
    bound: SocketAddr,
    observed: Option<IpAddr>,
) -> Option<SocketAddr> {
    let ip = observed
        .filter(|ip| !ip.is_unspecified())
        .or_else(|| (!bound.ip().is_unspecified()).then_some(bound.ip()))?;
    Some(SocketAddr::new(ip, bound.port()))
}

/// A single independently wakeable sender. No Sync bound is required.
#[derive(Debug)]
pub(crate) struct Sender {
    inner: Box<dyn DatagramSender>,
    local_addr: SocketAddr,
    /// The hold on the registry socket this handle was created from; `None` for a socket's own
    /// response sender and for handles created outside a registry.
    lease: Option<Lease>,
    in_flight: Option<InFlight>,
}

impl Sender {
    fn new(inner: Box<dyn DatagramSender>, local_addr: SocketAddr, lease: Option<Lease>) -> Self {
        Self {
            inner,
            local_addr,
            lease,
            in_flight: None,
        }
    }

    /// Tests: the bytes of the descriptor in hand that the backend has taken and that must not be
    /// offered again.
    #[cfg(test)]
    fn accepted_prefix(&self) -> usize {
        self.in_flight.map_or(0, |held| held.offset)
    }

    /// Whether the backend has taken any part of the descriptor `id`.
    pub(crate) fn accepted_any(&self, id: TransmitId) -> bool {
        self.in_flight
            .is_some_and(|held| held.id == id && held.accepted)
    }

    /// Give up the unsent remainder of the descriptor `id`. What was accepted stays accepted and
    /// is never offered again; what was not is dropped with the descriptor.
    pub(crate) fn abandon(&mut self, id: TransmitId) {
        if let Some(held) = self.in_flight.as_mut().filter(|held| held.id == id) {
            held.offset = 0;
        }
    }

    /// The bytes of `id` still to send, starting a fresh attempt when the descriptor is new.
    fn resume(&mut self, id: TransmitId) -> usize {
        match self.in_flight {
            Some(held) if held.id == id => held.offset,
            _ => {
                self.in_flight = Some(InFlight {
                    id,
                    offset: 0,
                    accepted: false,
                });
                0
            }
        }
    }

    /// The registry socket this handle sends from.
    pub(crate) fn socket_id(&self) -> SocketId {
        self.lease.as_ref().map_or(SocketId::RESPONSE, Lease::id)
    }

    /// Take the handle's lease for release, leaving the handle itself intact so the caller can
    /// drop it (and its socket-specific resources) outside any lock. The socket is never retired
    /// while the lease is held, so a handle dropped with its lease keeps it retained.
    pub(crate) fn take_lease(&mut self) -> Option<Lease> {
        self.lease.take()
    }

    /// The local address this handle sends from.
    pub(crate) fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    /// Whether this handle can put a source address other than its own bind on the wire, which
    /// is what a wildcard-bound socket needs to serve a concrete path.
    pub(crate) fn can_select_source(&self) -> bool {
        self.inner.capabilities().send_source_ip
    }

    pub(crate) fn capabilities(&self) -> DatagramCapabilities {
        self.inner.capabilities()
    }

    pub(crate) fn max_transmit_segments(&self) -> usize {
        self.inner.capabilities().max_send_segments.max(1)
    }

    /// Keep the same descriptor and bytes until Ready. Accepted fallback segments are never
    /// replayed after Pending. The caller owns the bytes for the whole operation.
    ///
    /// Any `Err` ends the descriptor: segments already accepted stay sent, the unsent suffix
    /// is lost like any other dropped datagram, and the next call starts a new descriptor.
    pub(crate) fn poll_transmit(
        &mut self,
        cx: &mut Context<'_>,
        id: TransmitId,
        transmit: &proto::Transmit,
        buffer: &[u8],
    ) -> Poll<Result<(), SendError>> {
        let mut offset = self.resume(id);
        let Some(payload) = buffer.get(..transmit.size) else {
            return self.fail(SendError::descriptor("QUIC transmit exceeds its buffer"));
        };
        let segment_size = match transmit.segment_size {
            Some(size) if size.get() < payload.len() => Some(size.get()),
            _ => None,
        };
        for _ in 0..SEND_WORK_LIMIT {
            let caps = self.inner.capabilities();
            let Some(remaining) = payload.get(offset..) else {
                // The offset belongs to this descriptor, so it cannot exceed it; refuse rather
                // than splice if that ever stops being true.
                debug_assert!(false, "accepted prefix outside its own descriptor");
                return self.fail(SendError::descriptor("QUIC transmit offset out of range"));
            };
            let split = segment_size
                .is_some_and(|size| remaining.len().div_ceil(size) > caps.max_send_segments.max(1));
            let len = if split {
                segment_size.unwrap_or(remaining.len()).min(remaining.len())
            } else {
                remaining.len()
            };
            let mut datagram = SendDatagram::new(transmit.destination, &remaining[..len]);
            if !split
                && let Some(size) = segment_size
                    .filter(|&size| size < len)
                    .and_then(NonZeroUsize::new)
            {
                datagram.set_segment_size(size);
            }
            // ECN is optional in QUIC. A backend without transmit ECN sends unmarked packets.
            // Source selection, in contrast, is required unless the bind already enforces it.
            if caps.send_ecn
                && let Some(ecn) = transmit.ecn
            {
                datagram.set_ecn(udp_ecn(ecn));
            }
            if let Some(source) = transmit
                .local
                .map(|local| local.ip())
                .filter(|ip| !ip.is_unspecified())
            {
                let source = SocketAddress::from((source, 0))
                    .into_canonical_ip_addr()
                    .ip_addr;
                let bound = SocketAddress::from(self.local_addr)
                    .into_canonical_ip_addr()
                    .ip_addr;
                if caps.send_source_ip {
                    datagram.set_source_ip(source);
                } else if source != bound || bound.is_unspecified() {
                    return self
                        .fail(DatagramError::Unsupported(DatagramFeature::SendSourceIp).into());
                }
            }
            let result = ready!(self.inner.poll_send(cx, &datagram));
            match result {
                Ok(()) => {
                    offset += len;
                    self.in_flight = Some(InFlight {
                        id,
                        offset,
                        accepted: true,
                    });
                    if offset == payload.len() {
                        // Nothing is left to send, so nothing may be offered again; that the
                        // backend took this descriptor stays on record.
                        self.in_flight = Some(InFlight {
                            id,
                            offset: 0,
                            accepted: true,
                        });
                        return Poll::Ready(Ok(()));
                    }
                }
                Err(error) => {
                    // P1 segmented sends are atomic: a capability downgrade did not accept a
                    // prefix. Retry only if this was a segmented descriptor and its capability
                    // actually fell. Unrelated metadata/validation/I/O errors remain errors.
                    let downgraded =
                        self.inner.capabilities().max_send_segments < datagram.segment_count();
                    let segmentation_error = matches!(
                        error,
                        DatagramError::Unsupported(DatagramFeature::Segmentation)
                            | DatagramError::TooManySegments { .. }
                            | DatagramError::SegmentationRejected(_)
                    );
                    if datagram.segment_size().is_some() && downgraded && segmentation_error {
                        continue;
                    }
                    return self.fail(error.into());
                }
            }
        }
        cx.waker().wake_by_ref();
        Poll::Pending
    }

    fn fail(&mut self, error: SendError) -> Poll<Result<(), SendError>> {
        // A stale offset would splice the next descriptor's bytes; every rejection ends this one.
        // What the backend already took is still on record: a prefix that left, left.
        if let Some(held) = self.in_flight.as_mut() {
            held.offset = 0;
        }
        Poll::Ready(Err(error))
    }
}

pub(crate) fn io_error(error: DatagramError) -> io::Error {
    match error {
        DatagramError::Io(error) | DatagramError::SegmentationRejected(error) => error,
        DatagramError::Unsupported(_) => io::Error::new(io::ErrorKind::Unsupported, error),
        _ => io::Error::other(error),
    }
}

fn udp_ecn(ecn: rama_quic_proto::EcnCodepoint) -> rama_udp::EcnCodepoint {
    match ecn {
        rama_quic_proto::EcnCodepoint::Ect0 => rama_udp::EcnCodepoint::Ect0,
        rama_quic_proto::EcnCodepoint::Ect1 => rama_udp::EcnCodepoint::Ect1,
        rama_quic_proto::EcnCodepoint::Ce => rama_udp::EcnCodepoint::Ce,
    }
}

pub(crate) fn proto_ecn(ecn: rama_udp::EcnCodepoint) -> Option<rama_quic_proto::EcnCodepoint> {
    match ecn {
        rama_udp::EcnCodepoint::Ect0 => Some(rama_quic_proto::EcnCodepoint::Ect0),
        rama_udp::EcnCodepoint::Ect1 => Some(rama_quic_proto::EcnCodepoint::Ect1),
        rama_udp::EcnCodepoint::Ce => Some(rama_quic_proto::EcnCodepoint::Ce),
        rama_udp::EcnCodepoint::NotEct => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use parking_lot::Mutex;
    use std::assert_matches;
    use std::{
        cell::Cell,
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        },
        task::{Wake, Waker},
    };

    #[test]
    fn local_address_is_never_a_wildcard() {
        let concrete = SocketAddr::from(([127, 0, 0, 1], 443));
        let wildcard = SocketAddr::from(([0, 0, 0, 0], 443));
        assert_eq!(known_local_address(wildcard, None), None);
        assert_eq!(known_local_address(concrete, None), Some(concrete));
        assert_eq!(
            known_local_address(wildcard, Some(concrete.ip())),
            Some(concrete)
        );
        assert_eq!(
            known_local_address(concrete, Some(wildcard.ip())),
            Some(concrete)
        );
    }

    #[derive(Debug)]
    enum Action {
        Pending,
        Downgrade,
        Fail(io::ErrorKind),
        FailAfterCapabilityDrop(io::ErrorKind),
        Descriptor,
        SocketGone,
        Sent,
    }

    #[derive(Debug, Default)]
    struct Probe {
        actions: VecDeque<Action>,
        accepted: Vec<(
            Vec<u8>,
            Option<std::net::IpAddr>,
            Option<rama_udp::EcnCodepoint>,
            Option<usize>,
        )>,
        waker: Option<Waker>,
    }

    #[derive(Debug)]
    struct StubSender {
        probe: Arc<Mutex<Probe>>,
        caps: DatagramCapabilities,
        // Deliberately !Sync, exercising the P1 send-handle contract.
        calls: Cell<usize>,
    }

    impl DatagramSender for StubSender {
        fn poll_send(
            &mut self,
            cx: &mut Context<'_>,
            datagram: &SendDatagram<'_>,
        ) -> Poll<Result<(), DatagramError>> {
            self.calls.set(self.calls.get() + 1);
            let mut probe = self.probe.lock();
            match probe.actions.pop_front().unwrap_or(Action::Sent) {
                Action::Pending => {
                    probe.waker = Some(cx.waker().clone());
                    Poll::Pending
                }
                Action::Downgrade => {
                    assert!(datagram.segment_size().is_some());
                    self.caps.max_send_segments = 1;
                    Poll::Ready(Err(DatagramError::SegmentationRejected(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "offload rejected",
                    ))))
                }
                Action::FailAfterCapabilityDrop(kind) => {
                    self.caps.max_send_segments = 1;
                    Poll::Ready(Err(io::Error::new(kind, "unrelated failure").into()))
                }
                Action::Fail(kind) => {
                    Poll::Ready(Err(io::Error::new(kind, "injected failure").into()))
                }
                Action::Descriptor => {
                    Poll::Ready(Err(DatagramError::TooManySegments { count: 2, max: 1 }))
                }
                Action::SocketGone => Poll::Ready(Err(DatagramError::Closed)),
                Action::Sent => {
                    probe.accepted.push((
                        datagram.payload().to_vec(),
                        datagram.source_ip(),
                        datagram.ecn(),
                        datagram.segment_size().map(NonZeroUsize::get),
                    ));
                    Poll::Ready(Ok(()))
                }
            }
        }
        fn capabilities(&self) -> DatagramCapabilities {
            self.caps
        }
    }

    #[derive(Default)]
    struct WakeCount(AtomicUsize);
    impl Wake for WakeCount {
        fn wake(self: Arc<Self>) {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
        fn wake_by_ref(self: &Arc<Self>) {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }

    fn fixture(
        actions: impl IntoIterator<Item = Action>,
        caps: DatagramCapabilities,
    ) -> (Sender, Arc<Mutex<Probe>>) {
        let probe = Arc::new(Mutex::new(Probe {
            actions: actions.into_iter().collect(),
            ..Probe::default()
        }));
        let sender = Sender::new(
            Box::new(StubSender {
                probe: probe.clone(),
                caps,
                calls: Cell::new(0),
            }),
            ([127, 0, 0, 1], 1234).into(),
            None,
        );
        (sender, probe)
    }

    fn transmit(size: usize, segment_size: Option<usize>) -> proto::Transmit {
        proto::Transmit {
            destination: ([127, 0, 0, 2], 443).into(),
            ecn: Some(rama_quic_proto::EcnCodepoint::Ect0),
            size,
            segment_size: segment_size.map(|size| NonZeroUsize::new(size).unwrap()),
            local: Some(([127, 0, 0, 1], 0).into()),
            cid_used: None,
        }
    }

    #[test]
    fn downgrade_then_pending_preserves_segments_metadata_and_wakeup() {
        let mut caps = DatagramCapabilities::portable();
        caps.max_send_segments = 4;
        caps.send_source_ip = true;
        caps.send_ecn = true;
        let (mut sender, probe) = fixture([Action::Downgrade, Action::Sent, Action::Pending], caps);
        let wake = Arc::new(WakeCount::default());
        let waker = Waker::from(wake.clone());
        let mut cx = Context::from_waker(&waker);
        let t = transmit(5, Some(2));
        assert!(
            sender
                .poll_transmit(&mut cx, TransmitId(1), &t, b"abcde")
                .is_pending()
        );
        assert_eq!(probe.lock().accepted.len(), 1);
        probe.lock().waker.take().unwrap().wake();
        assert_eq!(wake.0.load(Ordering::Relaxed), 1);
        assert_matches!(
            sender.poll_transmit(&mut cx, TransmitId(1), &t, b"abcde"),
            Poll::Ready(Ok(())),
        );
        let probe = probe.lock();
        assert_eq!(
            probe
                .accepted
                .iter()
                .map(|x| x.0.as_slice())
                .collect::<Vec<_>>(),
            [b"ab".as_slice(), b"cd", b"e"]
        );
        assert!(probe.accepted.iter().all(|x| x.1 == t.local.map(|l| l.ip())
            && x.2 == Some(rama_udp::EcnCodepoint::Ect0)
            && x.3.is_none()));
    }

    #[test]
    fn invalid_input_is_not_mistaken_for_segmentation_rejection() {
        let mut caps = DatagramCapabilities::portable();
        caps.max_send_segments = 4;
        caps.send_source_ip = true;
        let (mut sender, probe) = fixture([Action::Fail(io::ErrorKind::InvalidInput)], caps);
        let mut cx = Context::from_waker(Waker::noop());
        assert_matches!(
            sender.poll_transmit(&mut cx, TransmitId(1), &transmit(5, Some(2)), b"abcde"),
            Poll::Ready(Err(e)) if e.error.kind() == io::ErrorKind::InvalidInput && e.class == SendFailure::Descriptor,
        );
        assert!(probe.lock().accepted.is_empty());
    }

    #[test]
    fn concurrent_capability_drop_does_not_hide_an_unrelated_io_error() {
        for kind in [io::ErrorKind::InvalidInput, io::ErrorKind::PermissionDenied] {
            let mut caps = DatagramCapabilities::portable();
            caps.max_send_segments = 4;
            let (mut sender, probe) = fixture([Action::FailAfterCapabilityDrop(kind)], caps);
            let mut cx = Context::from_waker(Waker::noop());
            assert_matches!(
                sender.poll_transmit(&mut cx, TransmitId(1), &transmit(5, Some(2)), b"abcde"),
                Poll::Ready(Err(error)) if error.error.kind() == kind,
            );
            assert!(probe.lock().accepted.is_empty());
        }
    }

    #[test]
    fn bound_source_is_sufficient_but_different_or_wildcard_source_is_not() {
        let (mut sender, probe) = fixture([], DatagramCapabilities::portable());
        let mut cx = Context::from_waker(Waker::noop());
        let mut t = transmit(1, None);
        assert_matches!(
            sender.poll_transmit(&mut cx, TransmitId(1), &t, b"a"),
            Poll::Ready(Ok(())),
        );
        assert_eq!(probe.lock().accepted[0].1, None);
        t.local = Some(([127, 0, 0, 3], 0).into());
        assert_matches!(
            sender.poll_transmit(&mut cx, TransmitId(1), &t, b"a"),
            Poll::Ready(Err(e)) if e.error.kind() == io::ErrorKind::Unsupported && e.class == SendFailure::Descriptor,
        );
        sender.local_addr = ([0, 0, 0, 0], 1234).into();
        t.local = Some(([127, 0, 0, 1], 0).into());
        assert_matches!(
            sender.poll_transmit(&mut cx, TransmitId(1), &t, b"a"),
            Poll::Ready(Err(e)) if e.error.kind() == io::ErrorKind::Unsupported,
        );
        assert_eq!(probe.lock().accepted.len(), 1);
    }

    #[test]
    fn single_segment_is_normalized_and_work_per_poll_is_bounded() {
        let (mut sender, probe) = fixture([], DatagramCapabilities::portable());
        let wake = Arc::new(WakeCount::default());
        let waker = Waker::from(wake.clone());
        let mut cx = Context::from_waker(&waker);
        assert_matches!(
            sender.poll_transmit(&mut cx, TransmitId(1), &transmit(1, Some(1)), b"a"),
            Poll::Ready(Ok(())),
        );
        assert_eq!(probe.lock().accepted[0].3, None);
        let data = [42; SEND_WORK_LIMIT + 1];
        let t = transmit(data.len(), Some(1));
        assert!(
            sender
                .poll_transmit(&mut cx, TransmitId(1), &t, &data)
                .is_pending()
        );
        assert_eq!(wake.0.load(Ordering::Relaxed), 1);
        assert_eq!(probe.lock().accepted.len(), SEND_WORK_LIMIT + 1);
        assert_matches!(
            sender.poll_transmit(&mut cx, TransmitId(1), &t, &data),
            Poll::Ready(Ok(())),
        );
        assert_eq!(probe.lock().accepted.len(), SEND_WORK_LIMIT + 2);
    }

    #[derive(Debug, Default)]
    struct StubSocket(Arc<Mutex<Vec<Arc<Mutex<Probe>>>>>);
    impl rama_net::stream::Socket for StubSocket {
        fn local_addr(&self) -> io::Result<SocketAddress> {
            Ok(([127, 0, 0, 1], 1234).into())
        }
        fn peer_addr(&self) -> io::Result<SocketAddress> {
            Err(io::ErrorKind::NotConnected.into())
        }
    }
    impl DatagramSocket for StubSocket {
        type Sender = StubSender;
        fn create_sender(&self) -> StubSender {
            let probe = Arc::new(Mutex::new(Probe {
                actions: [Action::Pending].into(),
                ..Probe::default()
            }));
            self.0.lock().push(probe.clone());
            StubSender {
                probe,
                caps: DatagramCapabilities::portable(),
                calls: Cell::new(0),
            }
        }
        fn poll_recv(
            &mut self,
            _: &mut Context<'_>,
            _: &mut [IoSliceMut<'_>],
            _: &mut [DatagramMetadata],
        ) -> Poll<Result<usize, DatagramError>> {
            Poll::Pending
        }
        fn capabilities(&self) -> DatagramCapabilities {
            DatagramCapabilities::portable()
        }
    }

    #[test]
    fn response_and_connection_senders_register_independent_real_wakers() {
        let stub = StubSocket::default();
        let probes = stub.0.clone();
        let mut socket = Socket::new(stub).unwrap();
        let mut a = socket.create_sender();
        let mut b = socket.create_sender();
        let counts = [
            Arc::new(WakeCount::default()),
            Arc::new(WakeCount::default()),
            Arc::new(WakeCount::default()),
        ];
        let wakers = counts.clone().map(Waker::from);
        assert!(socket.queue_response(transmit(1, None), b"r"));
        assert!(
            !socket
                .drive_responses(&mut Context::from_waker(&wakers[0]), Instant::now())
                .unwrap()
        );
        assert!(
            a.poll_transmit(
                &mut Context::from_waker(&wakers[1]),
                TransmitId(1),
                &transmit(1, None),
                b"a"
            )
            .is_pending()
        );
        assert!(
            b.poll_transmit(
                &mut Context::from_waker(&wakers[2]),
                TransmitId(1),
                &transmit(1, None),
                b"b"
            )
            .is_pending()
        );
        for p in probes.lock().iter() {
            p.lock().waker.take().unwrap().wake();
        }
        assert!(counts.iter().all(|c| c.0.load(Ordering::Relaxed) == 1));
        assert!(
            !socket
                .drive_responses(&mut Context::from_waker(&wakers[0]), Instant::now())
                .unwrap()
        );
        assert!(socket.responses.is_empty());
        assert_eq!(socket.response_bytes, 0);
        for _ in 0..MAX_RESPONSES {
            assert!(socket.queue_response(transmit(0, None), b""));
        }
        assert!(!socket.queue_response(transmit(0, None), b""));
    }

    /// A prefix the backend accepted has left the machine, so the identifier that descriptor
    /// carried counts as used even though the rest of it failed. What must not survive is the
    /// offset: the next descriptor is a descriptor of its own and starts at nothing.
    #[test]
    fn a_prefix_accepted_before_an_error_counts_and_leaves_no_offset() {
        let mut caps = DatagramCapabilities::portable();
        caps.max_send_segments = 1;
        // One sender throughout: a freshly built one could not have kept a stale offset, so
        // recovery has to be observed on the very instance whose descriptor failed.
        let (mut sender, probe) = fixture(
            [
                Action::Sent,
                Action::Fail(io::ErrorKind::HostUnreachable),
                Action::Sent,
            ],
            caps,
        );
        let mut cx = Context::from_waker(Waker::noop());
        let first = TransmitId(1);
        let descriptor = transmit(6, Some(2));
        let error = match sender.poll_transmit(&mut cx, first, &descriptor, b"aabbcc") {
            Poll::Ready(Err(error)) => error,
            other => panic!("expected the second segment to fail, got {other:?}"),
        };
        assert_eq!(error.class, SendFailure::Datagram);
        assert!(
            sender.accepted_any(first),
            "the first segment left, so its identifier has been used"
        );
        assert_eq!(
            sender.accepted_prefix(),
            0,
            "and nothing of it may be spliced into what comes next"
        );
        assert_eq!(
            probe.lock().accepted.len(),
            1,
            "only the first segment was taken"
        );
        assert_eq!(probe.lock().accepted[0].0, b"aa");

        // The same sender, a new descriptor shorter than the prefix it had accepted: it goes out
        // whole, which is what a retained offset used to make impossible.
        let second = TransmitId(2);
        assert_matches!(
            sender.poll_transmit(&mut cx, second, &transmit(1, None), b"z"),
            Poll::Ready(Ok(())),
        );
        let probe = probe.lock();
        assert_eq!(
            probe.accepted.len(),
            2,
            "one datagram each, nothing replayed"
        );
        assert_eq!(probe.accepted[1].0, b"z", "the whole of the new descriptor");
        assert!(
            sender.accepted_any(second),
            "the new descriptor's acceptance is recorded against its own id"
        );
    }

    /// The send work limit yields rather than finishing a long descriptor in one go. The
    /// descriptor keeps its place: the same one continues where it stopped, nothing is offered
    /// twice, and what has left already counts.
    #[test]
    fn a_work_budget_yield_keeps_the_descriptor_and_its_progress() {
        let mut caps = DatagramCapabilities::portable();
        caps.max_send_segments = 1;
        // One more segment than a single pass may send.
        let segments = SEND_WORK_LIMIT + 1;
        let payload: Vec<u8> = (0..segments).map(|i| i as u8).collect();
        let (mut sender, probe) = fixture((0..segments).map(|_| Action::Sent), caps);
        // A counting waker, so the yield can be shown to schedule another poll.
        let waker = Arc::new(WakeCount::default());
        let counted = std::task::Waker::from(waker.clone());
        let mut cx = Context::from_waker(&counted);
        let id = TransmitId(7);
        let descriptor = transmit(payload.len(), Some(1));

        assert!(
            sender
                .poll_transmit(&mut cx, id, &descriptor, &payload)
                .is_pending(),
            "the budget ran out before the descriptor did"
        );
        assert_eq!(probe.lock().accepted.len(), SEND_WORK_LIMIT);
        assert_eq!(
            sender.accepted_prefix(),
            SEND_WORK_LIMIT,
            "its place is kept, not lost"
        );
        assert!(sender.accepted_any(id), "and what left already counts");
        assert!(
            waker.0.load(Ordering::Relaxed) >= 1,
            "the budget yield scheduled another poll instead of waiting to be asked"
        );

        // The same descriptor continues from there and completes.
        assert_matches!(
            sender.poll_transmit(&mut cx, id, &descriptor, &payload),
            Poll::Ready(Ok(())),
        );
        let probe = probe.lock();
        assert_eq!(probe.accepted.len(), segments, "every segment, once");
        let sent: Vec<u8> = probe.accepted.iter().flat_map(|d| d.0.clone()).collect();
        assert_eq!(sent, payload, "in order, with nothing sent twice");
    }

    #[test]
    fn rejected_partial_batch_resets_the_offset_for_the_next_descriptor() {
        let mut caps = DatagramCapabilities::portable();
        caps.max_send_segments = 4;
        let (mut sender, probe) = fixture(
            [
                Action::Downgrade,
                Action::Sent,
                Action::Fail(io::ErrorKind::HostUnreachable),
            ],
            caps,
        );
        let mut cx = Context::from_waker(Waker::noop());
        let first = transmit(5, Some(2));
        let error = match sender.poll_transmit(&mut cx, TransmitId(1), &first, b"abcde") {
            Poll::Ready(Err(error)) => error,
            other => panic!("expected the second segment to fail, got {other:?}"),
        };
        assert_eq!(error.class, SendFailure::Datagram);
        assert_eq!(error.error.kind(), io::ErrorKind::HostUnreachable);
        assert_eq!(
            sender.accepted_prefix(),
            0,
            "a rejected descriptor must not leave a partial offset"
        );
        let second = transmit(3, None);
        assert_matches!(
            sender.poll_transmit(&mut cx, TransmitId(2), &second, b"xyz"),
            Poll::Ready(Ok(())),
        );
        let probe = probe.lock();
        assert_eq!(
            probe
                .accepted
                .iter()
                .map(|x| x.0.as_slice())
                .collect::<Vec<_>>(),
            [b"ab".as_slice(), b"xyz"],
            "the accepted prefix stays sent, the suffix is lost, the next descriptor is intact"
        );
    }

    #[test]
    fn failures_are_classified_for_the_caller() {
        let mut cx = Context::from_waker(Waker::noop());
        let cases: [(Action, SendFailure); 3] = [
            (
                Action::Fail(io::ErrorKind::PermissionDenied),
                SendFailure::Datagram,
            ),
            (Action::Descriptor, SendFailure::Descriptor),
            (Action::SocketGone, SendFailure::Socket),
        ];
        for (action, class) in cases {
            let (mut sender, _) = fixture([action], DatagramCapabilities::portable());
            match sender.poll_transmit(&mut cx, TransmitId(1), &transmit(1, None), b"a") {
                Poll::Ready(Err(error)) => assert_eq!(error.class, class),
                other => panic!("expected a failure, got {other:?}"),
            }
            assert_eq!(sender.accepted_prefix(), 0);
        }
    }

    #[test]
    fn refused_responses_are_dropped_and_counted_but_an_unusable_socket_is_fatal() {
        #[derive(Debug)]
        struct ScriptedSocket(Arc<Mutex<Probe>>);
        impl rama_net::stream::Socket for ScriptedSocket {
            fn local_addr(&self) -> io::Result<SocketAddress> {
                Ok(([127, 0, 0, 1], 1234).into())
            }
            fn peer_addr(&self) -> io::Result<SocketAddress> {
                Err(io::ErrorKind::NotConnected.into())
            }
        }
        impl DatagramSocket for ScriptedSocket {
            type Sender = StubSender;
            fn create_sender(&self) -> StubSender {
                StubSender {
                    probe: self.0.clone(),
                    caps: DatagramCapabilities::portable(),
                    calls: Cell::new(0),
                }
            }
            fn poll_recv(
                &mut self,
                _: &mut Context<'_>,
                _: &mut [IoSliceMut<'_>],
                _: &mut [DatagramMetadata],
            ) -> Poll<Result<usize, DatagramError>> {
                Poll::Pending
            }
            fn capabilities(&self) -> DatagramCapabilities {
                DatagramCapabilities::portable()
            }
        }
        let probe = Arc::new(Mutex::new(Probe {
            actions: [
                Action::Fail(io::ErrorKind::NetworkUnreachable),
                Action::Sent,
                Action::Fail(io::ErrorKind::PermissionDenied),
                Action::SocketGone,
            ]
            .into(),
            ..Probe::default()
        }));
        let mut socket = Socket::new(ScriptedSocket(probe.clone())).unwrap();
        let mut cx = Context::from_waker(Waker::noop());
        for payload in [b"1".as_slice(), b"2", b"3"] {
            assert!(socket.queue_response(transmit(1, None), payload));
        }
        assert!(!socket.drive_responses(&mut cx, Instant::now()).unwrap());
        assert_eq!(socket.failed_responses(), 2);
        assert!(socket.responses.is_empty());
        assert_eq!(socket.response_bytes, 0);
        assert_eq!(
            probe
                .lock()
                .accepted
                .iter()
                .map(|x| x.0.as_slice())
                .collect::<Vec<_>>(),
            [b"2".as_slice()],
            "only the refused responses are dropped"
        );
        assert!(socket.queue_response(transmit(1, None), b"4"));
        let error = socket.drive_responses(&mut cx, Instant::now()).unwrap_err();
        assert_eq!(error.to_string(), DatagramError::Closed.to_string());
    }

    #[test]
    fn response_queue_enforces_bytes_then_entries_and_counts_drops() {
        let stub = StubSocket::default();
        let mut socket = Socket::new(stub).unwrap();
        let payload = [0u8; 1200];
        let fitting = MAX_RESPONSE_BYTES / payload.len();
        for _ in 0..fitting {
            assert!(socket.queue_response(transmit(payload.len(), None), &payload));
        }
        assert_eq!(socket.response_bytes, fitting * payload.len());
        assert!(!socket.queue_response(transmit(payload.len(), None), &payload));
        assert_eq!(socket.dropped_responses(), 1);
        // Zero-length responses cost no bytes but still count against the entry limit.
        for _ in fitting..MAX_RESPONSES {
            assert!(socket.queue_response(transmit(0, None), b""));
        }
        assert!(!socket.queue_response(transmit(0, None), b""));
        assert_eq!(socket.dropped_responses(), 2);
        // A descriptor longer than its buffer is dropped and counted too.
        assert!(!socket.queue_response(transmit(2, None), b"x"));
        assert_eq!(socket.dropped_responses(), 3);
        assert_eq!(socket.responses.len(), MAX_RESPONSES);
    }

    #[test]
    fn failure_log_warns_once_per_interval() {
        let mut log = FailureLog::default();
        let error = SendError::descriptor("x");
        let start = Instant::now();
        log.record(start, "test", &error);
        assert_eq!(log.last_warning, Some(start));
        log.record(start + Duration::from_secs(1), "test", &error);
        assert_eq!(
            log.last_warning,
            Some(start),
            "within the interval only debug output"
        );
        let later = start + FAILURE_WARNING_INTERVAL;
        log.record(later, "test", &error);
        assert_eq!(log.last_warning, Some(later));
    }

    #[test]
    fn segment_size_boundaries_normalize_split_or_reject() {
        let mut caps = DatagramCapabilities::portable();
        caps.max_send_segments = 4;
        let mut cx = Context::from_waker(Waker::noop());
        // A segment size equal to or above the payload is a single plain datagram.
        for size in [4usize, 5] {
            let (mut sender, probe) = fixture([], caps);
            assert_matches!(
                sender.poll_transmit(&mut cx, TransmitId(1), &transmit(4, Some(size)), b"abcd"),
                Poll::Ready(Ok(())),
            );
            let probe = probe.lock();
            assert_eq!(probe.accepted.len(), 1);
            assert_eq!(probe.accepted[0].3, None, "segment size {size}");
        }
        // Exactly the capability's segment count goes out as one segmented descriptor.
        let (mut sender, probe) = fixture([], caps);
        assert_matches!(
            sender.poll_transmit(&mut cx, TransmitId(1), &transmit(8, Some(2)), b"abcdefgh"),
            Poll::Ready(Ok(())),
        );
        assert_eq!(probe.lock().accepted.len(), 1);
        assert_eq!(probe.lock().accepted[0].3, Some(2));
        // One more segment than the capability allows: one segment is peeled off as a plain
        // datagram, then the remaining four fit one segmented descriptor.
        let (mut sender, probe) = fixture([], caps);
        assert_matches!(
            sender.poll_transmit(
                &mut cx,
                TransmitId(1),
                &transmit(10, Some(2)),
                b"abcdefghij"
            ),
            Poll::Ready(Ok(())),
        );
        let probe = probe.lock();
        assert_eq!(
            probe
                .accepted
                .iter()
                .map(|x| (x.0.as_slice(), x.3))
                .collect::<Vec<_>>(),
            [(b"ab".as_slice(), None), (b"cdefghij".as_slice(), Some(2))]
        );
    }

    #[test]
    fn every_successful_transmit_reaches_the_sender_exactly_once() {
        let (mut sender, probe) = fixture([], DatagramCapabilities::portable());
        let mut cx = Context::from_waker(Waker::noop());
        for payload in [b"a".as_slice(), b"bb", b"ccc"] {
            assert_matches!(
                sender.poll_transmit(
                    &mut cx,
                    TransmitId(1),
                    &transmit(payload.len(), None),
                    payload
                ),
                Poll::Ready(Ok(())),
            );
        }
        assert_eq!(probe.lock().accepted.len(), 3);
        assert_eq!(sender.max_transmit_segments(), 1);
        let mut caps = DatagramCapabilities::portable();
        caps.max_send_segments = 7;
        assert_eq!(fixture([], caps).0.max_transmit_segments(), 7);
    }

    #[test]
    fn ecn_codepoints_map_both_ways() {
        for (proto, udp) in [
            (
                rama_quic_proto::EcnCodepoint::Ect0,
                rama_udp::EcnCodepoint::Ect0,
            ),
            (
                rama_quic_proto::EcnCodepoint::Ect1,
                rama_udp::EcnCodepoint::Ect1,
            ),
            (
                rama_quic_proto::EcnCodepoint::Ce,
                rama_udp::EcnCodepoint::Ce,
            ),
        ] {
            assert_eq!(udp_ecn(proto), udp);
            assert_eq!(proto_ecn(udp), Some(proto));
        }
        assert_eq!(proto_ecn(rama_udp::EcnCodepoint::NotEct), None);
    }

    #[test]
    fn response_queue_limits_have_their_configured_values() {
        assert_eq!(MAX_RESPONSE_BYTES, 65_536);
        assert_eq!(MAX_RESPONSES, 64);
        let mut socket = Socket::new(StubSocket::default()).unwrap();
        // Exactly filling the byte budget is allowed; one more byte is not.
        let half = [0u8; MAX_RESPONSE_BYTES / 2];
        assert!(socket.queue_response(transmit(half.len(), None), &half));
        assert!(socket.queue_response(transmit(half.len(), None), &half));
        assert_eq!(socket.response_bytes, MAX_RESPONSE_BYTES);
        assert!(!socket.queue_response(transmit(1, None), b"x"));
        assert_eq!(socket.dropped_responses(), 1);
    }

    #[test]
    fn drive_responses_reports_remaining_work_only_when_responses_remain() {
        let mut socket = Socket::new(StubSocket::default()).unwrap();
        // StubSocket senders return Pending once; drain that first.
        assert!(socket.queue_response(transmit(1, None), b"p"));
        let mut cx = Context::from_waker(Waker::noop());
        assert!(!socket.drive_responses(&mut cx, Instant::now()).unwrap());
        assert_eq!(socket.responses.len(), 1, "still queued after Pending");
        assert!(!socket.drive_responses(&mut cx, Instant::now()).unwrap());
        assert!(socket.responses.is_empty());
        for _ in 0..SEND_WORK_LIMIT {
            assert!(socket.queue_response(transmit(1, None), b"r"));
        }
        assert!(
            !socket.drive_responses(&mut cx, Instant::now()).unwrap(),
            "a full batch that empties the queue leaves nothing to do"
        );
        for _ in 0..=SEND_WORK_LIMIT {
            assert!(socket.queue_response(transmit(1, None), b"r"));
        }
        assert!(
            socket.drive_responses(&mut cx, Instant::now()).unwrap(),
            "one response beyond the batch limit remains queued"
        );
        assert_eq!(socket.responses.len(), 1);
    }

    #[test]
    fn segmentation_error_without_a_capability_drop_is_not_retried() {
        let mut caps = DatagramCapabilities::portable();
        caps.max_send_segments = 3;
        let (mut sender, probe) = fixture([Action::Descriptor], caps);
        let mut cx = Context::from_waker(Waker::noop());
        // Three segments exactly match the capability, and it does not fall: no retry.
        match sender.poll_transmit(&mut cx, TransmitId(1), &transmit(6, Some(2)), b"abcdef") {
            Poll::Ready(Err(error)) => assert_eq!(error.class, SendFailure::Descriptor),
            other => panic!("expected an immediate descriptor failure, got {other:?}"),
        }
        assert!(probe.lock().accepted.is_empty());
        assert_eq!(probe.lock().actions.len(), 0, "exactly one send attempt");
    }
}
