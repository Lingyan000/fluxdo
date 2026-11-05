//! Tests for the endpoint driver.

use super::*;
use crate::driver::sockets::RESPONSE_WORK_LIMIT;
use crate::driver::udp::SEND_WORK_LIMIT;
use rama_udp::{DatagramCapabilities, DatagramError, DatagramSender, DatagramSocket, SendDatagram};
use std::assert_matches;
use std::collections::VecDeque;
use std::{num::NonZeroUsize, task::Wake};

pub(super) type Captured = Arc<Mutex<Vec<(SocketAddress, Option<std::net::IpAddr>)>>>;

#[derive(Debug)]
pub(super) struct TestSocket {
    pub(super) entries: VecDeque<(Vec<u8>, DatagramMetadata)>,
    pub(super) captured: Captured,
    /// Every sender created from this socket refuses with this error kind.
    pub(super) send_failure: Option<io::ErrorKind>,
    /// Reported bound address.
    pub(super) local: SocketAddress,
    /// Whether senders advertise per-datagram source selection.
    pub(super) send_source_ip: bool,
    /// Report this entry count instead of the real one (invalid-count injection).
    pub(super) report_count: Option<usize>,
    /// Receive errors returned once every entry has been delivered.
    pub(super) recv_errors: VecDeque<io::ErrorKind>,
    /// Consumed oversize receive errors, before any queued entries.
    pub(super) oversized: VecDeque<usize>,
    /// While unset, sends return `Pending` and keep the caller's waker for `SendReady::open`.
    pub(super) send_ready: Option<Arc<SendReady>>,
    /// Deliver at most this many entries per receive call.
    pub(super) batch_limit: Option<usize>,
}

/// Observes when the sockets wrapping it are destroyed: a destructor that finds the
/// endpoint lock held would block a real socket's teardown, so it is counted as a violation
/// without blocking.
#[derive(Debug, Default)]
pub(super) struct DropObserver {
    endpoint: std::sync::OnceLock<std::sync::Weak<EndpointInner>>,
    pub(super) drops: AtomicUsize,
    pub(super) under_lock: AtomicUsize,
}

impl DropObserver {
    pub(super) fn attach(&self, endpoint: &Endpoint) {
        let _installed = self.endpoint.set(Arc::downgrade(&endpoint.inner.0));
    }

    fn record(&self) {
        self.drops.fetch_add(1, Ordering::SeqCst);
        if let Some(endpoint) = self.endpoint.get().and_then(std::sync::Weak::upgrade)
            && endpoint.state.try_lock().is_none()
        {
            self.under_lock.fetch_add(1, Ordering::SeqCst);
        }
    }
}

/// A [`TestSocket`] whose destruction is reported to a [`DropObserver`].
#[derive(Debug)]
pub(super) struct ProbeSocket {
    pub(super) inner: TestSocket,
    pub(super) observer: Arc<DropObserver>,
}

impl rama_net::stream::Socket for ProbeSocket {
    fn local_addr(&self) -> io::Result<SocketAddress> {
        self.inner.local_addr()
    }
    fn peer_addr(&self) -> io::Result<SocketAddress> {
        self.inner.peer_addr()
    }
}

impl DatagramSocket for ProbeSocket {
    type Sender = TestSender;
    fn create_sender(&self) -> TestSender {
        self.inner.create_sender()
    }
    fn poll_recv(
        &mut self,
        cx: &mut Context<'_>,
        buffers: &mut [IoSliceMut<'_>],
        metadata: &mut [DatagramMetadata],
    ) -> Poll<Result<usize, DatagramError>> {
        self.inner.poll_recv(cx, buffers, metadata)
    }
    fn capabilities(&self) -> DatagramCapabilities {
        self.inner.capabilities()
    }
}

impl Drop for ProbeSocket {
    fn drop(&mut self) {
        self.observer.record();
    }
}

/// A deterministic "sender not writable" state for [`TestSocket`].
#[derive(Debug, Default)]
pub(super) struct SendReady {
    ready: std::sync::atomic::AtomicBool,
    waker: Mutex<Option<Waker>>,
}

impl SendReady {
    /// Become writable and wake the task that last found the sender pending.
    pub(super) fn open(&self) {
        self.ready.store(true, Ordering::SeqCst);
        if let Some(waker) = self.waker.lock().take() {
            waker.wake();
        }
    }
}

impl Default for TestSocket {
    fn default() -> Self {
        Self {
            entries: VecDeque::new(),
            captured: Captured::default(),
            send_failure: None,
            local: ([127, 0, 0, 1], 443).into(),
            send_source_ip: true,
            report_count: None,
            recv_errors: VecDeque::new(),
            oversized: VecDeque::new(),
            send_ready: None,
            batch_limit: None,
        }
    }
}

impl rama_net::stream::Socket for TestSocket {
    fn local_addr(&self) -> io::Result<SocketAddress> {
        Ok(self.local)
    }
    fn peer_addr(&self) -> io::Result<SocketAddress> {
        Err(io::ErrorKind::NotConnected.into())
    }
}

impl DatagramSocket for TestSocket {
    type Sender = TestSender;
    fn create_sender(&self) -> TestSender {
        TestSender(
            self.captured.clone(),
            self.send_failure,
            self.send_source_ip,
            self.send_ready.clone(),
        )
    }
    fn poll_recv(
        &mut self,
        _: &mut Context<'_>,
        buffers: &mut [IoSliceMut<'_>],
        metadata: &mut [DatagramMetadata],
    ) -> Poll<Result<usize, DatagramError>> {
        if let Some(len) = self.oversized.pop_front() {
            return Poll::Ready(Err(DatagramError::PayloadTooLarge {
                len,
                max: buffers[0].len(),
            }));
        }
        // Entries are delivered first, so an error can follow a valid batch in one pass.
        if self.entries.is_empty() {
            if let Some(kind) = self.recv_errors.pop_front() {
                return Poll::Ready(Err(io::Error::new(kind, "injected receive error").into()));
            }
            return Poll::Pending;
        }
        let count = self
            .entries
            .len()
            .min(buffers.len())
            .min(self.batch_limit.unwrap_or(usize::MAX));
        for (i, (data, meta)) in self.entries.drain(..count).enumerate() {
            let copied = data.len().min(buffers[i].len());
            buffers[i][..copied].copy_from_slice(&data[..copied]);
            metadata[i] = meta;
            if copied < data.len() {
                // Model the actual socket contract when the receive buffer is
                // too short, without panicking inside the test fixture.
                metadata[i].len = copied;
                metadata[i].original_len = data.len();
                metadata[i].truncated = true;
            }
        }
        Poll::Ready(Ok(self.report_count.take().unwrap_or(count)))
    }
    fn capabilities(&self) -> DatagramCapabilities {
        let mut caps = DatagramCapabilities::portable();
        // The same answer the senders this socket creates give, so a socket without per-datagram
        // source selection reports that at both levels.
        caps.send_source_ip = self.send_source_ip;
        caps.send_ecn = true;
        caps.max_receive_segments = 4;
        caps
    }
}

#[derive(Debug)]
pub(super) struct TestSender(
    Captured,
    Option<io::ErrorKind>,
    bool,
    Option<Arc<SendReady>>,
);
impl DatagramSender for TestSender {
    fn poll_send(
        &mut self,
        cx: &mut Context<'_>,
        datagram: &SendDatagram<'_>,
    ) -> Poll<Result<(), DatagramError>> {
        if let Some(gate) = &self.3
            && !gate.ready.load(Ordering::SeqCst)
        {
            *gate.waker.lock() = Some(cx.waker().clone());
            return Poll::Pending;
        }
        if let Some(kind) = self.1 {
            return Poll::Ready(Err(io::Error::new(kind, "injected send failure").into()));
        }
        self.0
            .lock()
            .push((datagram.destination(), datagram.source_ip()));
        Poll::Ready(Ok(()))
    }
    fn capabilities(&self) -> DatagramCapabilities {
        let mut caps = DatagramCapabilities::portable();
        caps.send_source_ip = self.2;
        caps.send_ecn = true;
        caps
    }
}

fn metadata(len: usize, segment_size: Option<usize>) -> DatagramMetadata {
    let mut meta = DatagramMetadata::empty();
    meta.len = len;
    meta.original_len = len;
    meta.segment_size = segment_size.and_then(NonZeroUsize::new);
    meta.peer = ([127, 0, 0, 2], 5555).into();
    meta.local = ([127, 0, 0, 1], 443).into();
    meta.original_destination = Some(([127, 0, 0, 3], 8443).into());
    meta
}

#[test]
fn retained_datagrams_use_temporary_space_only_within_the_udp_bound() {
    use rama_udp::{PrefixedDatagramSocket, RetainedDatagram};

    for len in [1200, 8192, 65536, 65537] {
        let mut config = EndpointConfig::try_with_rand_key().unwrap();
        config.max_udp_payload_size(1231).unwrap();
        let mut endpoint = proto::Endpoint::new(Arc::new(config), None, false, None);
        let mut socket = Socket::new(PrefixedDatagramSocket::new(
            TestSocket::default(),
            [RetainedDatagram {
                payload: vec![0; len].into(),
                metadata: metadata(len, None),
            }],
        ))
        .unwrap();
        let mut recv = RecvState::new(4, &endpoint);
        let initial_size = recv.recv_buf.len();
        let budget = PacketBudget::new(endpoint.config().endpoint_receive_queue);
        let allocation = recv.recv_buf.as_ptr();
        let mut poll = |recv: &mut RecvState| {
            recv.poll_socket(
                &mut Context::from_waker(Waker::noop()),
                &mut endpoint,
                &mut socket,
                Instant::now(),
                &budget,
                &mut WorkCycle::with_allowance(1),
            )
        };
        let first = poll(&mut recv);
        if len > 65536 {
            assert!(first.error.is_some());
            assert_eq!(recv.recv_buf.len(), initial_size);
        } else {
            assert!(first.error.is_none());
            assert_eq!(recv.recv_buf.len(), initial_size);
            assert_eq!(recv.recv_buf.as_ptr(), allocation);
            assert_eq!(recv.received_datagrams, 1);
            assert_eq!(recv.truncated_receive_entries, 0);
            // Once the prefix is consumed, ordinary polling reuses the batch.
            assert!(poll(&mut recv).error.is_none());
            assert_eq!(recv.recv_buf.len(), initial_size);
            assert_eq!(recv.recv_buf.as_ptr(), allocation);
        }
    }
}

#[test]
fn consumed_oversize_datagrams_are_counted_without_growing_or_stopping_the_endpoint() {
    let mut config = EndpointConfig::try_with_rand_key().unwrap();
    config.max_udp_payload_size(1231).unwrap();
    let mut endpoint = proto::Endpoint::new(Arc::new(config), None, false, None);
    let mut socket = Socket::new(TestSocket {
        oversized: [8192, 65536, 65537].into(),
        entries: [(vec![0; 1200], metadata(1200, None))].into(),
        ..Default::default()
    })
    .unwrap();
    let mut recv = RecvState::new(4, &endpoint);
    let initial_size = recv.recv_buf.len();
    let budget = PacketBudget::new(endpoint.config().endpoint_receive_queue);
    // Even a stream of oversize errors must yield under the work budget.
    let mut cycle = WorkCycle::with_allowance(2);
    let first = recv.poll_socket(
        &mut Context::from_waker(Waker::noop()),
        &mut endpoint,
        &mut socket,
        Instant::now(),
        &budget,
        &mut cycle,
    );
    assert!(first.error.is_none());
    assert!(first.keep_going);
    assert_eq!(recv.dropped_packets, 2);
    assert_eq!(recv.recv_buf.len(), initial_size);
    let mut cycle = WorkCycle::with_allowance(10);
    let second = recv.poll_socket(
        &mut Context::from_waker(Waker::noop()),
        &mut endpoint,
        &mut socket,
        Instant::now(),
        &budget,
        &mut cycle,
    );
    assert!(second.error.is_none());
    assert!(!second.keep_going);
    assert_eq!(recv.dropped_packets, 3);
    assert_eq!(recv.received_datagrams, 1);
    assert_eq!(recv.recv_buf.len(), initial_size);
}

#[test]
fn receive_discards_truncated_groups_and_splits_complete_groups() {
    let mut truncated = metadata(6, Some(3));
    truncated.original_len = 9;
    truncated.truncated = true;
    let entries = [
        (vec![0; 6], truncated),
        (vec![0; 5], metadata(5, Some(3))),
        (vec![], metadata(0, None)),
    ]
    .into();
    let mut socket = Socket::new(TestSocket {
        entries,
        captured: Captured::default(),
        ..TestSocket::default()
    })
    .unwrap();
    let mut endpoint = proto::Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        None,
        false,
        None,
    );
    let mut recv = RecvState::new(4, &endpoint);
    let budget = PacketBudget::new(endpoint.config().endpoint_receive_queue);
    let mut cycle = recv.recv_limiter.start_cycle(Instant::now);
    let _progress = recv
        .poll_socket(
            &mut Context::from_waker(Waker::noop()),
            &mut endpoint,
            &mut socket,
            Instant::now(),
            &budget,
            &mut cycle,
        )
        .into_result()
        .unwrap();
    assert_eq!(recv.truncated_receive_entries, 1);
    assert_eq!(recv.received_datagrams, 2);
}

#[test]
fn invalid_receive_length_returns_error_instead_of_indexing_past_buffer() {
    let entries = [(vec![0], metadata(usize::MAX, None))].into();
    let mut socket = Socket::new(TestSocket {
        entries,
        captured: Captured::default(),
        ..TestSocket::default()
    })
    .unwrap();
    let mut endpoint = proto::Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        None,
        false,
        None,
    );
    let mut recv = RecvState::new(1, &endpoint);
    let budget = PacketBudget::new(endpoint.config().endpoint_receive_queue);
    let mut cycle = recv.recv_limiter.start_cycle(Instant::now);
    let error = recv
        .poll_socket(
            &mut Context::from_waker(Waker::noop()),
            &mut endpoint,
            &mut socket,
            Instant::now(),
            &budget,
            &mut cycle,
        )
        .into_result()
        .err()
        .unwrap();
    assert_eq!(error.kind(), io::ErrorKind::InvalidData);
}

#[cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
#[test]
fn stateless_response_uses_actual_local_address_not_original_destination() {
    let server = crate::test_helpers::server(&crate::test_helpers::identity());
    let mut endpoint = proto::Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        Some(Arc::new(server)),
        false,
        None,
    );
    let mut packet = vec![
        0x80, 0x0a, 0x1a, 0x2a, 0x3a, 4, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0,
    ];
    packet.resize(1200, 0);
    let meta = metadata(packet.len(), None);
    let captured = Captured::default();
    let mut socket = Socket::new(TestSocket {
        entries: [(packet, meta)].into(),
        captured: captured.clone(),
        ..TestSocket::default()
    })
    .unwrap();
    let mut recv = RecvState::new(1, &endpoint);
    let budget = PacketBudget::new(endpoint.config().endpoint_receive_queue);
    let mut cx = Context::from_waker(Waker::noop());
    let mut cycle = recv.recv_limiter.start_cycle(Instant::now);
    recv.poll_socket(
        &mut cx,
        &mut endpoint,
        &mut socket,
        Instant::now(),
        &budget,
        &mut cycle,
    )
    .into_result()
    .unwrap();
    assert!(
        captured.lock().is_empty(),
        "receiving only queues the response"
    );
    socket.drive_responses(&mut cx, Instant::now()).unwrap();
    assert_eq!(
        captured.lock().as_slice(),
        [(meta.peer, Some(meta.local.ip_addr))]
    );
}

#[derive(Default)]
pub(super) struct WakeCount(pub(super) AtomicUsize);
impl Wake for WakeCount {
    fn wake(self: Arc<Self>) {
        self.0.fetch_add(1, Ordering::Relaxed);
    }
    fn wake_by_ref(self: &Arc<Self>) {
        self.0.fetch_add(1, Ordering::Relaxed);
    }
}

/// Coverage is a property of one socket, and the record of it names that socket. A replacement
/// bound elsewhere does not inherit it, so the same tuple is looked up again and this time nothing
/// covers it. Comparing addresses alone would carry the old answer over to the new socket.
#[test]
fn a_coverage_record_belongs_to_the_socket_it_was_established_on() {
    let wildcard = TestSocket {
        local: ([0, 0, 0, 0], 4433).into(),
        ..TestSocket::default()
    };
    let concrete_elsewhere = TestSocket {
        local: ([127, 0, 0, 2], 5555).into(),
        ..TestSocket::default()
    };
    let path = ([127, 0, 0, 1], 4433).into();

    let mut registry = crate::driver::sockets::SocketRegistry::new(Socket::new(wildcard).unwrap());
    let wildcard_id = registry.active_id();
    assert!(
        registry.covers_local(wildcard_id, path),
        "the wildcard socket covers that tuple"
    );
    // Something depends on it, so the rebind below retains it rather than retiring it at once.
    let lease = registry
        .acquire_attempt(wildcard_id)
        .expect("a lease on the wildcard socket");

    // The replacement is bound to another address and port: it neither is nor covers that tuple.
    let (concrete_id, _retired) = registry
        .activate(Socket::new(concrete_elsewhere).unwrap(), now())
        .expect("the rebind is accepted");
    assert!(
        !registry.covers_local(concrete_id, path),
        "and the replacement does not"
    );
    assert_eq!(
        registry.id_for_local(path),
        None,
        "nor is any socket bound to it"
    );
    // The wildcard socket is retained while its lease lives, so it remains the only cover: a
    // delayed datagram for that path leaves from it rather than from the replacement.
    assert_eq!(registry.only_cover_for(path), Some(wildcard_id));

    // Once nothing depends on it, it is retired and nothing covers the tuple: such a datagram has
    // no socket it may leave from.
    let retired = registry.release(lease, now());
    drop(retired);
    assert_eq!(registry.only_cover_for(path), None);
    assert!(!registry.covers_local(concrete_id, path));
}

/// A wildcard socket carries another local tuple only if it can put that address on the wire as
/// the source: without per-datagram source selection its sender refuses such a datagram, so the
/// registry does not offer it as cover.
#[test]
fn a_wildcard_socket_covers_a_tuple_only_with_source_selection() {
    let wildcard = |source: bool| TestSocket {
        local: ([0, 0, 0, 0], 4433).into(),
        send_source_ip: source,
        ..TestSocket::default()
    };
    let concrete = ([127, 0, 0, 1], 4433).into();
    let other_port = ([127, 0, 0, 1], 4434).into();

    let registry =
        crate::driver::sockets::SocketRegistry::new(Socket::new(wildcard(true)).unwrap());
    let id = registry.active_id();
    assert!(
        registry.covers_local(id, concrete),
        "a wildcard of that port and family with source selection covers it"
    );
    assert!(
        !registry.covers_local(id, other_port),
        "another port is a different path"
    );

    let registry =
        crate::driver::sockets::SocketRegistry::new(Socket::new(wildcard(false)).unwrap());
    let id = registry.active_id();
    assert!(
        !registry.covers_local(id, concrete),
        "without source selection the sender would refuse the datagram, so it is no cover"
    );
    assert_eq!(registry.only_cover_for(concrete), None);
}

#[test]
fn response_queued_between_polls_wakes_the_endpoint() {
    let captured = Captured::default();
    let socket = Socket::new(TestSocket {
        entries: VecDeque::new(),
        captured: captured.clone(),
        ..TestSocket::default()
    })
    .unwrap();
    let endpoint = proto::Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        None,
        false,
        None,
    );
    let endpoint = EndpointRef::new(socket, endpoint, false, u16::MAX, false);
    let mut driver = std::pin::pin!(EndpointDriver(endpoint.0.clone()));
    let count = Arc::new(WakeCount::default());
    let waker = Waker::from(count.clone());
    let mut cx = Context::from_waker(&waker);
    assert!(driver.as_mut().poll(&mut cx).is_pending());
    endpoint.state.lock().respond_active(
        proto::Transmit {
            destination: ([127, 0, 0, 2], 5555).into(),
            ecn: None,
            size: 1,
            segment_size: None,
            local: Some(([127, 0, 0, 1], 0).into()),
            cid_used: None,
        },
        b"x",
    );
    assert_eq!(count.0.load(Ordering::Relaxed), 1);
    assert!(driver.as_mut().poll(&mut cx).is_pending());
    assert_eq!(captured.lock().len(), 1);
}

#[cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
pub(super) fn version_negotiation_probe() -> Vec<u8> {
    let mut packet = vec![
        0x80, 0x0a, 0x1a, 0x2a, 0x3a, 4, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0,
    ];
    packet.resize(1200, 0);
    packet
}

#[cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
#[test]
fn saturated_endpoint_budget_drops_packets_before_engine_work() {
    let server = crate::test_helpers::server(&crate::test_helpers::identity());
    let mut endpoint = proto::Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        Some(Arc::new(server)),
        false,
        None,
    );
    let packet = version_negotiation_probe();
    let meta = metadata(packet.len(), None);
    let budget = PacketBudget::new(ReceiveQueueLimits::new(1, 4096).unwrap());
    let mut recv = RecvState::new(1, &endpoint);
    let mut cx = Context::from_waker(Waker::noop());
    let run = |recv: &mut RecvState, endpoint: &mut proto::Endpoint, cx: &mut Context<'_>| {
        let captured = Captured::default();
        let mut socket = Socket::new(TestSocket {
            entries: [(packet.clone(), meta), (packet.clone(), meta)].into(),
            captured: captured.clone(),
            ..TestSocket::default()
        })
        .unwrap();
        let mut cycle = recv.recv_limiter.start_cycle(Instant::now);
        recv.poll_socket(
            cx,
            endpoint,
            &mut socket,
            Instant::now(),
            &budget,
            &mut cycle,
        )
        .into_result()
        .unwrap();
        socket.drive_responses(cx, Instant::now()).unwrap();
        captured.lock().len()
    };

    let held = budget.reserve(0).unwrap();
    assert_eq!(
        run(&mut recv, &mut endpoint, &mut cx),
        0,
        "refused packets never reach the engine, so no response is produced"
    );
    assert_eq!(recv.received_datagrams, 2);
    assert_eq!(recv.dropped_packets, 2);
    assert_eq!(budget.stats().dropped_datagrams, 2);

    drop(held);
    assert_eq!(
        run(&mut recv, &mut endpoint, &mut cx),
        2,
        "with budget available both probes are answered"
    );
    assert_eq!(recv.dropped_packets, 2);
    assert_eq!(
        budget.stats().queued_datagrams,
        0,
        "responses hold no queue charge"
    );
}

#[test]
fn refused_stateless_response_keeps_the_endpoint_driver_running() {
    let captured = Captured::default();
    let socket = Socket::new(TestSocket {
        entries: VecDeque::new(),
        captured: captured.clone(),
        send_failure: Some(io::ErrorKind::PermissionDenied),
        ..TestSocket::default()
    })
    .unwrap();
    let endpoint = proto::Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        None,
        false,
        None,
    );
    let endpoint = EndpointRef::new(socket, endpoint, false, u16::MAX, false);
    let mut driver = std::pin::pin!(EndpointDriver(endpoint.0.clone()));
    let mut cx = Context::from_waker(Waker::noop());
    assert!(driver.as_mut().poll(&mut cx).is_pending());
    for _ in 0..2 {
        endpoint.state.lock().respond_active(
            proto::Transmit {
                destination: ([127, 0, 0, 2], 5555).into(),
                ecn: None,
                size: 1,
                segment_size: None,
                local: None,
                cid_used: None,
            },
            b"x",
        );
    }
    assert!(
        driver.as_mut().poll(&mut cx).is_pending(),
        "a destination refusing a response is not an endpoint failure"
    );
    let state = endpoint.state.lock();
    assert_eq!(state.sockets.failed_responses(), 2);
    assert!(captured.lock().is_empty());
}

/// Received local-address metadata is preserved (C5); when the sender cannot honor the
/// selected source on a wildcard bind, only that response fails and nothing is sent with a
/// silently substituted default source.
#[cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
#[test]
fn unsupported_required_source_fails_the_response_without_substitution_or_endpoint_loss() {
    let server = crate::test_helpers::server(&crate::test_helpers::identity());
    let packet = version_negotiation_probe();
    let meta = metadata(packet.len(), None);
    let captured = Captured::default();
    let socket = Socket::new(TestSocket {
        entries: [(packet, meta)].into(),
        captured: captured.clone(),
        local: ([0, 0, 0, 0], 443).into(),
        send_source_ip: false,
        ..TestSocket::default()
    })
    .unwrap();
    let endpoint = proto::Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        Some(Arc::new(server)),
        false,
        None,
    );
    let endpoint = EndpointRef::new(socket, endpoint, false, u16::MAX, false);
    let mut driver = std::pin::pin!(EndpointDriver(endpoint.0.clone()));
    let mut cx = Context::from_waker(Waker::noop());
    assert!(driver.as_mut().poll(&mut cx).is_pending());
    assert!(driver.as_mut().poll(&mut cx).is_pending());
    let state = endpoint.state.lock();
    assert_eq!(state.recv_state.received_datagrams, 1);
    assert_eq!(state.sockets.failed_responses(), 1);
    assert!(
        captured.lock().is_empty(),
        "the response must not go out with a default source"
    );
}

fn test_endpoint(socket: TestSocket) -> Endpoint {
    test_endpoint_on(Socket::new(socket).unwrap())
}

fn test_endpoint_on(socket: Socket) -> Endpoint {
    let engine = proto::Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        None,
        false,
        None,
    );
    Endpoint {
        inner: EndpointRef::new(socket, engine, false, u16::MAX, false),
        default_client_config: None,
    }
}

fn probe_socket(observer: &Arc<DropObserver>, inner: TestSocket) -> Socket {
    Socket::new(ProbeSocket {
        inner,
        observer: observer.clone(),
    })
    .unwrap()
}

fn one_byte_response() -> proto::Transmit {
    proto::Transmit {
        destination: ([127, 0, 0, 2], 5555).into(),
        ecn: None,
        size: 1,
        segment_size: None,
        local: None,
        cid_used: None,
    }
}

fn active_socket_id(endpoint: &Endpoint) -> SocketId {
    endpoint
        .inner
        .state
        .lock()
        .sockets
        .live()
        .map(SocketRegistry::active_id)
        .expect("live sockets")
}

/// Hold an attempt lease on the active socket so it stays retained across a rebind.
pub(super) fn pin_active_socket(endpoint: &Endpoint) -> Lease {
    let mut state = endpoint.inner.state.lock();
    let registry = state.sockets.live_mut().expect("live sockets");
    let id = registry.active_id();
    registry.acquire_attempt(id).expect("active socket leases")
}

pub(super) fn release_lease(endpoint: &Endpoint, lease: Lease) {
    let retired = endpoint.inner.state.lock().sockets.release(lease, now());
    drop(retired);
}

/// A rebind refused at the retained bound hands the replacement socket back and destroys it
/// only after the endpoint lock is released.
#[tokio::test]
async fn a_rejected_replacement_socket_is_dropped_outside_the_endpoint_lock() {
    let endpoint = test_endpoint(TestSocket::default());
    let observer = Arc::new(DropObserver::default());
    observer.attach(&endpoint);
    let mut leases = Vec::new();
    for _ in 1..crate::driver::sockets::MAX_RETAINED_SOCKETS {
        leases.push(pin_active_socket(&endpoint));
        endpoint
            .rebind_abstract(Socket::new(TestSocket::default()).unwrap())
            .unwrap();
    }
    leases.push(pin_active_socket(&endpoint));
    let addrs = endpoint.local_addrs();
    let error = endpoint
        .rebind_abstract(probe_socket(&observer, TestSocket::default()))
        .unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::QuotaExceeded);
    assert_eq!(observer.drops.load(Ordering::SeqCst), 1);
    assert_eq!(
        observer.under_lock.load(Ordering::SeqCst),
        0,
        "the rejected socket's destructor ran under the endpoint lock"
    );
    assert_eq!(endpoint.local_addrs(), addrs, "nothing changed");
    for lease in leases {
        release_lease(&endpoint, lease);
    }
    assert_eq!(endpoint.stats().retained_sockets, 1);
}

/// A fatal receive error on the active socket ends the driver; a socket retired earlier in
/// that same poll is still destroyed only after the lock is released.
#[tokio::test]
async fn a_socket_retired_in_a_failing_poll_is_dropped_outside_the_endpoint_lock() {
    let observer = Arc::new(DropObserver::default());
    let endpoint = test_endpoint_on(probe_socket(
        &observer,
        TestSocket {
            recv_errors: [io::ErrorKind::PermissionDenied].into(),
            ..TestSocket::default()
        },
    ));
    observer.attach(&endpoint);
    // The queued response is A's only dependent; its failure drops it and retires A.
    endpoint
        .inner
        .state
        .lock()
        .respond_active(one_byte_response(), b"x");
    endpoint
        .rebind_abstract(
            Socket::new(TestSocket {
                recv_errors: [io::ErrorKind::PermissionDenied].into(),
                ..TestSocket::default()
            })
            .unwrap(),
        )
        .unwrap();
    assert_eq!(endpoint.stats().retained_sockets, 2);
    let mut driver = std::pin::pin!(EndpointDriver(endpoint.inner.0.clone()));
    let mut cx = Context::from_waker(Waker::noop());
    // The receive pass visits the retiring socket (it fails and retires), then the active one,
    // whose failure ends the driver. A pass may yield before reaching both, so poll until it
    // finishes rather than assuming one pass covers everything.
    let mut polls = 0;
    let error = loop {
        polls += 1;
        assert!(polls <= 16, "the driver did not finish in {polls} polls");
        if let Poll::Ready(result) = driver.as_mut().poll(&mut cx) {
            break result.expect_err("the active socket's failure ends the driver");
        }
    };
    assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
    assert_eq!(observer.drops.load(Ordering::SeqCst), 1, "A was retired");
    assert_eq!(
        observer.under_lock.load(Ordering::SeqCst),
        0,
        "A's destructor ran under the endpoint lock on the error exit"
    );
    let stats = endpoint.stats();
    assert_eq!(stats.retired_sockets, 1);
    assert_eq!(stats.dropped_responses, 1);
}

/// A socket that fails while its endpoint stops, such as a tunnel whose carrier stops with
/// it, ends the driver cleanly; the same failure outside a shutdown stays fatal.
#[tokio::test]
async fn a_receive_failure_during_shutdown_ends_the_driver_cleanly() {
    for shutdown in [false, true] {
        let endpoint = test_endpoint(TestSocket {
            recv_errors: [io::ErrorKind::BrokenPipe].into(),
            ..TestSocket::default()
        });
        endpoint.inner.state.lock().shutdown = shutdown;
        let mut driver = std::pin::pin!(EndpointDriver(endpoint.inner.0.clone()));
        let mut cx = Context::from_waker(Waker::noop());
        let mut polls = 0;
        let result = loop {
            polls += 1;
            assert!(polls <= 16, "the driver did not finish in {polls} polls");
            if let Poll::Ready(result) = driver.as_mut().poll(&mut cx) {
                break result;
            }
        };
        match result {
            Ok(()) => assert!(shutdown, "a failure outside shutdown was swallowed"),
            Err(error) => {
                assert!(
                    !shutdown,
                    "a stopping endpoint reported its socket's failure"
                );
                assert_eq!(error.kind(), io::ErrorKind::BrokenPipe);
            }
        }
    }
}

/// Rebinding while the endpoint is shutting down (driver still live) or after the driver is
/// gone is refused; the offered socket is destroyed outside the lock either way. The two
/// states differ in what remains: shutdown keeps the active socket bound until the driver
/// finishes, driver loss has released every socket already.
#[tokio::test]
async fn rebind_is_refused_during_shutdown_and_after_driver_loss_without_holding_the_socket() {
    let observer = Arc::new(DropObserver::default());

    let shutting_down = test_endpoint(TestSocket::default());
    observer.attach(&shutting_down);
    let _driver = EndpointDriver(shutting_down.inner.0.clone());
    shutting_down.inner.state.lock().shutdown = true;
    let error = shutting_down
        .rebind_abstract(probe_socket(&observer, TestSocket::default()))
        .unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::NotConnected);
    assert_eq!(observer.drops.load(Ordering::SeqCst), 1);
    assert_eq!(observer.under_lock.load(Ordering::SeqCst), 0);
    assert_eq!(
        shutting_down.local_addrs().len(),
        1,
        "the active socket stays bound while the driver finishes shutting down"
    );
    assert_eq!(shutting_down.stats().retained_sockets, 1);

    let observer = Arc::new(DropObserver::default());
    let lost = test_endpoint(TestSocket::default());
    observer.attach(&lost);
    drop(EndpointDriver(lost.inner.0.clone()));
    assert!(
        lost.local_addrs().is_empty(),
        "driver loss released every socket"
    );
    assert_eq!(lost.stats().retained_sockets, 0);
    let error = lost
        .rebind_abstract(probe_socket(&observer, TestSocket::default()))
        .unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::NotConnected);
    assert_eq!(observer.drops.load(Ordering::SeqCst), 1);
    assert_eq!(observer.under_lock.load(Ordering::SeqCst), 0);
    assert!(lost.local_addrs().is_empty());
}

/// A Socket-class stateless-send failure (the handle itself is unusable) ends the driver
/// when it is the active socket; on a retiring socket it marks the socket failed: the rest
/// of its queue is dropped and counted, later responses addressed to it are dropped and
/// counted too, it accepts no new senders, and it retires with its last dependent.
#[tokio::test]
async fn socket_class_response_failures_are_fatal_on_the_active_socket_and_isolate_a_retiring_one()
{
    let mut cx = Context::from_waker(Waker::noop());
    let active = test_endpoint(TestSocket {
        send_failure: Some(io::ErrorKind::NotConnected),
        ..TestSocket::default()
    });
    active
        .inner
        .state
        .lock()
        .respond_active(one_byte_response(), b"x");
    let mut driver = std::pin::pin!(EndpointDriver(active.inner.0.clone()));
    assert_matches!(
        driver.as_mut().poll(&mut cx),
        Poll::Ready(Err(error)) if error.kind() == io::ErrorKind::NotConnected,
    );

    let endpoint = test_endpoint(TestSocket {
        send_failure: Some(io::ErrorKind::NotConnected),
        ..TestSocket::default()
    });
    let id_a = active_socket_id(&endpoint);
    let pin = pin_active_socket(&endpoint);
    for _ in 0..3 {
        endpoint
            .inner
            .state
            .lock()
            .respond_active(one_byte_response(), b"x");
    }
    let captured_b = Captured::default();
    endpoint
        .rebind_abstract(
            Socket::new(TestSocket {
                captured: captured_b.clone(),
                ..TestSocket::default()
            })
            .unwrap(),
        )
        .unwrap();
    let mut driver = std::pin::pin!(EndpointDriver(endpoint.inner.0.clone()));
    assert!(
        driver.as_mut().poll(&mut cx).is_pending(),
        "a retiring socket's unusable sender is not fatal"
    );
    let stats = endpoint.stats();
    assert_eq!(stats.retained_sockets, 2, "the pinned failed socket stays");
    assert_eq!(
        stats.dropped_responses, 3,
        "an unusable handle sends nothing: its whole queue is dropped and counted: {stats:?}"
    );
    assert_eq!(
        stats.failed_responses, 0,
        "a Socket-class failure is not a per-datagram refusal"
    );
    {
        let mut state = endpoint.inner.state.lock();
        let registry = state.sockets.live_mut().unwrap();
        assert!(!registry.is_usable(id_a));
        assert!(
            registry.sender(id_a).is_none(),
            "no new senders on a failed socket"
        );
        registry.respond(id_a, one_byte_response(), b"late");
    }
    assert!(driver.as_mut().poll(&mut cx).is_pending());
    let stats = endpoint.stats();
    assert_eq!(
        stats.dropped_responses, 4,
        "a late response to the failed socket is dropped and counted, never re-routed"
    );
    assert!(captured_b.lock().is_empty());
    release_lease(&endpoint, pin);
    let stats = endpoint.stats();
    assert_eq!(stats.retained_sockets, 1);
    assert_eq!(stats.retired_sockets, 1);
    // The active socket still serves.
    endpoint
        .inner
        .state
        .lock()
        .respond_active(one_byte_response(), b"x");
    assert!(driver.as_mut().poll(&mut cx).is_pending());
    assert_eq!(captured_b.lock().len(), 1);
}

/// The route timer may become ready after the poll read its clock. That firing is not
/// judged with the stale clock and lost: the pass asks to be polled again, the next pass
/// judges the hold against a fresh clock and re-arms whatever remains.
#[tokio::test(start_paused = true)]
async fn a_route_timer_that_fires_after_the_clock_was_read_asks_for_another_poll() {
    let endpoint = test_endpoint(TestSocket::default());
    let a = active_socket_id(&endpoint);
    let read_at = now();
    let until = read_at + Duration::from_millis(100);
    endpoint
        .inner
        .state
        .lock()
        .sockets
        .live_mut()
        .unwrap()
        .hold_route(a, until);
    endpoint
        .rebind_abstract(Socket::new(TestSocket::default()).unwrap())
        .unwrap();
    assert_eq!(endpoint.stats().retained_sockets, 2, "the hold keeps A");
    let mut cx = Context::from_waker(Waker::noop());
    let mut retired = Vec::new();
    {
        let mut state = endpoint.inner.state.lock();
        assert!(
            !state.drive_route_expiry(&mut cx, read_at, &mut retired),
            "the hold lies ahead: the timer is armed"
        );
        assert_eq!(state.route_timer.armed(), Some(until));
    }
    // The deadline passes after `read_at` was taken; the armed sleep is ready now.
    tokio::time::advance(Duration::from_millis(150)).await;
    {
        let mut state = endpoint.inner.state.lock();
        assert!(
            state.drive_route_expiry(&mut cx, read_at, &mut retired),
            "a timer that fired after the clock was read requests another poll"
        );
        assert!(retired.is_empty(), "nothing is judged with the stale clock");
        assert_eq!(state.sockets.live().unwrap().len(), 2);
    }
    {
        let mut state = endpoint.inner.state.lock();
        assert!(!state.drive_route_expiry(&mut cx, now(), &mut retired));
        assert_eq!(state.route_timer.armed(), None, "nothing left to arm");
    }
    assert_eq!(retired.len(), 1, "the fresh clock retires A");
    drop(retired);
    assert_eq!(endpoint.stats().retained_sockets, 1);
}

/// A pass whose allowance is already spent when it starts (the task was preempted) still
/// receives one batch from the first socket, so continuation always makes progress.
#[tokio::test]
async fn a_spent_allowance_still_moves_one_batch_per_pass() {
    struct SelfWake(AtomicUsize);
    impl Wake for SelfWake {
        fn wake(self: Arc<Self>) {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }
    let endpoint = test_endpoint(TestSocket {
        entries: (0..3).map(|_| (vec![0u8; 6], metadata(6, None))).collect(),
        batch_limit: Some(1),
        ..TestSocket::default()
    });
    endpoint.inner.state.lock().recv_state.forced_recv_allowance = Some(0);
    let wake = Arc::new(SelfWake(AtomicUsize::new(0)));
    let waker = Waker::from(wake.clone());
    let mut cx = Context::from_waker(&waker);
    let mut driver = std::pin::pin!(EndpointDriver(endpoint.inner.0.clone()));
    for pass in 1..=3 {
        let wakes = wake.0.load(Ordering::Relaxed);
        assert!(driver.as_mut().poll(&mut cx).is_pending());
        assert_eq!(
            endpoint.stats().received_datagrams,
            pass,
            "exactly one batch per pass"
        );
        assert!(
            wake.0.load(Ordering::Relaxed) > wakes,
            "pass {pass} continues"
        );
    }
    let wakes = wake.0.load(Ordering::Relaxed);
    assert!(driver.as_mut().poll(&mut cx).is_pending());
    assert_eq!(endpoint.stats().received_datagrams, 3);
    assert_eq!(
        wake.0.load(Ordering::Relaxed),
        wakes,
        "drained: the driver parks"
    );
}

/// A route hold ends at its instant and the timer is scheduled for that same instant: when
/// the paused clock reaches it (exactly, or later) the next poll retires the socket with no
/// packet activity and asks for no continuation; before it, the driver parks.
#[tokio::test(start_paused = true)]
async fn a_route_hold_ends_at_its_instant_without_self_wakes() {
    struct CountWake(AtomicUsize);
    impl Wake for CountWake {
        fn wake(self: Arc<Self>) {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }
    for extra in [Duration::ZERO, Duration::from_millis(1)] {
        let endpoint = test_endpoint(TestSocket::default());
        let a = active_socket_id(&endpoint);
        let until = now() + Duration::from_millis(100);
        endpoint
            .inner
            .state
            .lock()
            .sockets
            .live_mut()
            .unwrap()
            .hold_route(a, until);
        endpoint
            .rebind_abstract(Socket::new(TestSocket::default()).unwrap())
            .unwrap();
        let mut driver = std::pin::pin!(EndpointDriver(endpoint.inner.0.clone()));
        let wake = Arc::new(CountWake(AtomicUsize::new(0)));
        let waker = Waker::from(wake.clone());
        let mut cx = Context::from_waker(&waker);
        assert!(driver.as_mut().poll(&mut cx).is_pending());
        assert_eq!(
            wake.0.load(Ordering::Relaxed),
            0,
            "parked before the deadline"
        );
        assert_eq!(endpoint.stats().retained_sockets, 2);
        tokio::time::advance(Duration::from_millis(99)).await;
        assert!(driver.as_mut().poll(&mut cx).is_pending());
        assert_eq!(endpoint.stats().retained_sockets, 2, "still held at 99 ms");
        assert_eq!(wake.0.load(Ordering::Relaxed), 0);
        // Reaching the deadline fires the timer once (a real wake, which the runtime may hand
        // over before or after `before` is read); a driver waiting for the same instant to
        // change would instead wake itself on every one of these polls.
        tokio::time::advance(Duration::from_millis(1) + extra).await;
        let before = wake.0.load(Ordering::Relaxed);
        for _ in 0..16 {
            assert!(driver.as_mut().poll(&mut cx).is_pending());
        }
        let wakes = wake.0.load(Ordering::Relaxed) - before;
        assert!(
            wakes <= 1,
            "extra {extra:?}: {wakes} wakes across 16 polls at or after the deadline"
        );
        assert_eq!(
            endpoint.stats().retained_sockets,
            1,
            "extra {extra:?}: the hold ended and A retired"
        );
        assert_eq!(endpoint.inner.state.lock().route_timer.armed(), None);
    }
}

/// Ignored connection-reset errors are work: a stream of them yields at the shared
/// allowance with a continuation wake, is counted apart from received datagrams, and a real
/// fatal error behind them is still surfaced when the allowance reaches it.
#[tokio::test]
async fn connection_reset_noise_is_work_under_the_shared_allowance() {
    struct SelfWake(AtomicUsize);
    impl Wake for SelfWake {
        fn wake(self: Arc<Self>) {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }
    let endpoint = test_endpoint(TestSocket {
        recv_errors: std::iter::repeat_n(io::ErrorKind::ConnectionReset, 100)
            .chain(std::iter::once(io::ErrorKind::PermissionDenied))
            .collect(),
        ..TestSocket::default()
    });
    endpoint.inner.state.lock().recv_state.forced_recv_allowance = Some(2);
    let wake = Arc::new(SelfWake(AtomicUsize::new(0)));
    let waker = Waker::from(wake.clone());
    let mut cx = Context::from_waker(&waker);
    let mut driver = std::pin::pin!(EndpointDriver(endpoint.inner.0.clone()));
    for pass in 1..=50 {
        let wakes = wake.0.load(Ordering::Relaxed);
        assert!(driver.as_mut().poll(&mut cx).is_pending(), "pass {pass}");
        let stats = endpoint.stats();
        assert_eq!(
            stats.ignored_receive_errors,
            pass * 2,
            "two resets per pass"
        );
        assert_eq!(stats.received_datagrams, 0, "resets are not datagrams");
        assert!(
            wake.0.load(Ordering::Relaxed) > wakes,
            "pass {pass}: the spent allowance requests a continuation"
        );
    }
    assert_matches!(
        driver.as_mut().poll(&mut cx),
        Poll::Ready(Err(error)) if error.kind() == io::ErrorKind::PermissionDenied,
    );
    assert_eq!(endpoint.stats().ignored_receive_errors, 100);
}

/// Sustained reset noise on one socket does not starve another: the pass rotates on, the
/// other socket's datagrams arrive within a bounded number of passes, and once the noise
/// ends (the socket is pending) the driver parks without a continuation.
#[tokio::test]
async fn reset_noise_on_one_socket_does_not_starve_another() {
    struct SelfWake(AtomicUsize);
    impl Wake for SelfWake {
        fn wake(self: Arc<Self>) {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }
    let endpoint = test_endpoint(TestSocket {
        recv_errors: std::iter::repeat_n(io::ErrorKind::ConnectionReset, 6).collect(),
        ..TestSocket::default()
    });
    let pin = pin_active_socket(&endpoint);
    endpoint
        .rebind_abstract(
            Socket::new(TestSocket {
                entries: (0..3).map(|_| (vec![0u8; 6], metadata(6, None))).collect(),
                batch_limit: Some(1),
                ..TestSocket::default()
            })
            .unwrap(),
        )
        .unwrap();
    endpoint.inner.state.lock().recv_state.forced_recv_allowance = Some(2);
    let wake = Arc::new(SelfWake(AtomicUsize::new(0)));
    let waker = Waker::from(wake.clone());
    let mut cx = Context::from_waker(&waker);
    let mut driver = std::pin::pin!(EndpointDriver(endpoint.inner.0.clone()));
    let mut passes = 0;
    loop {
        let wakes = wake.0.load(Ordering::Relaxed);
        assert!(driver.as_mut().poll(&mut cx).is_pending());
        passes += 1;
        let stats = endpoint.stats();
        assert!(
            stats.received_datagrams + stats.ignored_receive_errors <= passes * 2,
            "no pass exceeds the allowance"
        );
        if wake.0.load(Ordering::Relaxed) == wakes {
            break;
        }
        assert!(passes < 12, "never parked: {stats:?}");
    }
    let stats = endpoint.stats();
    assert_eq!(
        stats.received_datagrams, 3,
        "the quiet socket's datagrams all arrived"
    );
    assert_eq!(
        stats.ignored_receive_errors, 6,
        "the noise was consumed and counted"
    );
    assert!(
        passes >= 5,
        "9 work items under an allowance of 2 take at least 5 passes"
    );
    release_lease(&endpoint, pin);
}

/// One receive allowance per poll covers every retained socket. When it is spent, the pass
/// stops, the driver asks to be polled again, and the next pass starts with the first socket
/// the previous one did not reach, so a hot socket early in the rotation cannot starve the
/// others and the allowance is never multiplied by the number of sockets.
#[tokio::test]
async fn a_shared_receive_allowance_rotates_across_hot_sockets_without_starving_any() {
    struct SelfWake(AtomicUsize);
    impl Wake for SelfWake {
        fn wake(self: Arc<Self>) {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }
    let normal =
        |n: usize| -> VecDeque<_> { (0..n).map(|_| (vec![0u8; 6], metadata(6, None))).collect() };
    let mut truncated = metadata(6, None);
    truncated.truncated = true;
    // A: one ordinary datagram; B: four truncated groups; C (active): two empty entries.
    // Each class moves its own counter, so every pass reveals which sockets it served.
    let endpoint = test_endpoint(TestSocket {
        entries: normal(1),
        batch_limit: Some(1),
        ..TestSocket::default()
    });
    let pin_a = pin_active_socket(&endpoint);
    endpoint
        .rebind_abstract(
            Socket::new(TestSocket {
                entries: (0..4).map(|_| (vec![0u8; 6], truncated)).collect(),
                batch_limit: Some(1),
                ..TestSocket::default()
            })
            .unwrap(),
        )
        .unwrap();
    let pin_b = pin_active_socket(&endpoint);
    endpoint
        .rebind_abstract(
            Socket::new(TestSocket {
                entries: (0..2).map(|_| (Vec::new(), metadata(0, None))).collect(),
                batch_limit: Some(1),
                ..TestSocket::default()
            })
            .unwrap(),
        )
        .unwrap();
    assert_eq!(endpoint.stats().retained_sockets, 3);
    endpoint.inner.state.lock().recv_state.forced_recv_allowance = Some(2);

    let wake = Arc::new(SelfWake(AtomicUsize::new(0)));
    let waker = Waker::from(wake.clone());
    let mut cx = Context::from_waker(&waker);
    let mut driver = std::pin::pin!(EndpointDriver(endpoint.inner.0.clone()));
    let mut observed = Vec::new();
    let mut last = (0, 0);
    for pass in 1..=4 {
        let wakes = wake.0.load(Ordering::Relaxed);
        assert!(driver.as_mut().poll(&mut cx).is_pending());
        let stats = endpoint.stats();
        let now = (stats.received_datagrams, stats.truncated_receive_entries);
        observed.push((now.0 - last.0, now.1 - last.1));
        last = now;
        let woke = wake.0.load(Ordering::Relaxed) > wakes;
        // The fourth pass drains the last datagram with allowance to spare: nothing left.
        assert_eq!(
            woke,
            pass < 4,
            "pass {pass}: a spent allowance with unserved sockets requests a continuation"
        );
    }
    // Pass 1 (A, B, C): A's single datagram, then one of B's, allowance spent before C.
    // Pass 2 starts at the unvisited C: both empties, spent before A. Pass 3 (A, B, C): A is
    // dry, B gives two, spent before C. Pass 4 starts at C: dry, A dry, B's last one drains.
    // A one-step rotation would instead serve B again in pass 2 and starve C. No pass moves
    // more than the allowance, however many sockets are retained.
    assert_eq!(
        observed,
        vec![(1, 1), (0, 0), (0, 2), (0, 1)],
        "(ordinary, truncated) datagrams per pass"
    );
    // Everything drains within a bounded number of passes, then the driver parks.
    let mut passes = 0;
    loop {
        let wakes = wake.0.load(Ordering::Relaxed);
        let before = endpoint.stats().received_datagrams;
        assert!(driver.as_mut().poll(&mut cx).is_pending());
        assert!(
            endpoint.stats().received_datagrams - before <= 2,
            "a pass never exceeds the shared allowance"
        );
        passes += 1;
        if wake.0.load(Ordering::Relaxed) == wakes {
            break;
        }
        assert!(passes < 16, "the sockets never drained");
    }
    let stats = endpoint.stats();
    assert_eq!(stats.received_datagrams, 1);
    assert_eq!(stats.truncated_receive_entries, 4);
    assert_eq!(stats.dropped_packets, 0);
    release_lease(&endpoint, pin_a);
    release_lease(&endpoint, pin_b);
    assert_eq!(endpoint.stats().retained_sockets, 1);
}

#[test]
fn endpoint_stats_report_truncation_and_response_drops() {
    let mut truncated = metadata(6, Some(3));
    truncated.truncated = true;
    let socket = TestSocket {
        entries: [(vec![0; 6], truncated)].into(),
        send_failure: Some(io::ErrorKind::NetworkUnreachable),
        ..TestSocket::default()
    };
    let endpoint = test_endpoint(socket);
    let mut driver = std::pin::pin!(EndpointDriver(endpoint.inner.0.clone()));
    let mut cx = Context::from_waker(Waker::noop());
    assert!(driver.as_mut().poll(&mut cx).is_pending());
    {
        let mut state = endpoint.inner.state.lock();
        for _ in 0..=64 {
            state.respond_active(
                proto::Transmit {
                    destination: ([127, 0, 0, 2], 5555).into(),
                    ecn: None,
                    size: 0,
                    segment_size: None,
                    local: None,
                    cid_used: None,
                },
                b"",
            );
        }
    }
    assert!(driver.as_mut().poll(&mut cx).is_pending());
    let stats = endpoint.stats();
    assert_eq!(stats.received_datagrams, 0);
    assert_eq!(stats.truncated_receive_entries, 1);
    assert_eq!(
        stats.dropped_responses, 1,
        "the 65th response exceeded the queue"
    );
    assert_eq!(
        stats.failed_responses, SEND_WORK_LIMIT as u64,
        "one poll drains one send work budget of refused responses"
    );
    assert!(driver.as_mut().poll(&mut cx).is_pending());
    assert_eq!(
        endpoint.stats().failed_responses,
        64,
        "every queued response was refused"
    );
}

#[tokio::test]
async fn retired_sockets_keep_their_response_counters() {
    let socket = TestSocket {
        send_failure: Some(io::ErrorKind::HostUnreachable),
        ..TestSocket::default()
    };
    let endpoint = test_endpoint(socket);
    let mut driver = std::pin::pin!(EndpointDriver(endpoint.inner.0.clone()));
    let mut cx = Context::from_waker(Waker::noop());
    assert!(driver.as_mut().poll(&mut cx).is_pending());
    endpoint.inner.state.lock().respond_active(
        proto::Transmit {
            destination: ([127, 0, 0, 2], 5555).into(),
            ecn: None,
            size: 1,
            segment_size: None,
            local: None,
            cid_used: None,
        },
        b"x",
    );
    assert!(driver.as_mut().poll(&mut cx).is_pending());
    assert_eq!(endpoint.stats().failed_responses, 1);
    // Rebinding retires the old socket immediately (no connections use it).
    endpoint
        .rebind_abstract(Socket::new(TestSocket::default()).unwrap())
        .unwrap();
    assert!(driver.as_mut().poll(&mut cx).is_pending());
    assert_eq!(endpoint.inner.state.lock().sockets.retained_sockets(), 1);
    assert_eq!(
        endpoint.stats().failed_responses,
        1,
        "counters survive socket retirement"
    );
}

#[test]
fn full_batches_are_accepted_and_a_poll_drains_every_ready_batch() {
    let mut engine = proto::Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        None,
        false,
        None,
    );
    let budget = PacketBudget::new(engine.config().endpoint_receive_queue);
    let mut cx = Context::from_waker(Waker::noop());
    let mut recv = RecvState::new(1, &engine);
    // Two complete batches are ready; each receive reports exactly BATCH_SIZE entries.
    let entries = (0..2 * BATCH_SIZE)
        .map(|_| (vec![0x40, 1, 2, 3], metadata(4, None)))
        .collect();
    let mut socket = Socket::new(TestSocket {
        entries,
        ..TestSocket::default()
    })
    .unwrap();
    // A fixed allowance keeps the outcome independent of the host clock: work stays
    // allowed for both batches, so one poll must drain both.
    let mut cycle = WorkCycle::with_allowance(usize::MAX);
    recv.poll_socket(
        &mut cx,
        &mut engine,
        &mut socket,
        Instant::now(),
        &budget,
        &mut cycle,
    )
    .into_result()
    .unwrap();
    assert_eq!(
        recv.received_datagrams,
        (2 * BATCH_SIZE) as u64,
        "a full batch is valid and the loop continues while work is allowed"
    );
    // With an allowance that the first batch exhausts, the poll stops after that batch and
    // leaves the rest for the next cycle.
    let entries = (0..2 * BATCH_SIZE)
        .map(|_| (vec![0x40, 1, 2, 3], metadata(4, None)))
        .collect();
    let mut socket = Socket::new(TestSocket {
        entries,
        ..TestSocket::default()
    })
    .unwrap();
    let mut cycle = WorkCycle::with_allowance(BATCH_SIZE);
    recv.poll_socket(
        &mut cx,
        &mut engine,
        &mut socket,
        Instant::now(),
        &budget,
        &mut cycle,
    )
    .into_result()
    .unwrap();
    assert_eq!(
        recv.received_datagrams,
        (3 * BATCH_SIZE) as u64,
        "an exhausted allowance ends the poll after the current batch"
    );
}

#[test]
fn receive_entry_count_and_truncation_guards_each_fire_alone() {
    let endpoint = proto::Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        None,
        false,
        None,
    );
    let budget = PacketBudget::new(endpoint.config().endpoint_receive_queue);
    let mut cx = Context::from_waker(Waker::noop());
    // A receive reporting zero entries is invalid.
    let mut engine = endpoint;
    let mut recv = RecvState::new(1, &engine);
    let mut socket = Socket::new(TestSocket {
        entries: [(vec![], metadata(0, None))].into(),
        report_count: Some(0),
        ..TestSocket::default()
    })
    .unwrap();
    let mut cycle = recv.recv_limiter.start_cycle(Instant::now);
    assert_eq!(
        recv.poll_socket(
            &mut cx,
            &mut engine,
            &mut socket,
            Instant::now(),
            &budget,
            &mut cycle
        )
        .into_result()
        .unwrap_err()
        .kind(),
        io::ErrorKind::InvalidData
    );
    // A receive reporting more entries than buffers is invalid.
    let mut socket = Socket::new(TestSocket {
        entries: [(vec![0], metadata(1, None))].into(),
        report_count: Some(BATCH_SIZE + 1),
        ..TestSocket::default()
    })
    .unwrap();
    let mut cycle = recv.recv_limiter.start_cycle(Instant::now);
    assert_eq!(
        recv.poll_socket(
            &mut cx,
            &mut engine,
            &mut socket,
            Instant::now(),
            &budget,
            &mut cycle
        )
        .into_result()
        .unwrap_err()
        .kind(),
        io::ErrorKind::InvalidData
    );
    // Truncation flag alone, and length mismatch alone, each discard the entry.
    let mut flagged = metadata(4, None);
    flagged.truncated = true;
    let mut longer = metadata(4, None);
    longer.original_len = 9;
    let mut socket = Socket::new(TestSocket {
        entries: [(vec![0; 4], flagged), (vec![0; 4], longer)].into(),
        ..TestSocket::default()
    })
    .unwrap();
    let mut cycle = recv.recv_limiter.start_cycle(Instant::now);
    recv.poll_socket(
        &mut cx,
        &mut engine,
        &mut socket,
        Instant::now(),
        &budget,
        &mut cycle,
    )
    .into_result()
    .unwrap();
    assert_eq!(recv.truncated_receive_entries, 2);
    assert_eq!(recv.received_datagrams, 0);
}

#[test]
fn connection_reset_on_receive_is_ignored_but_other_errors_are_fatal() {
    let mut engine = proto::Endpoint::new(
        Arc::new(EndpointConfig::try_with_rand_key().unwrap()),
        None,
        false,
        None,
    );
    let budget = PacketBudget::new(engine.config().endpoint_receive_queue);
    let mut cx = Context::from_waker(Waker::noop());
    let mut recv = RecvState::new(1, &engine);
    let mut socket = Socket::new(TestSocket {
        recv_errors: [io::ErrorKind::ConnectionReset].into(),
        ..TestSocket::default()
    })
    .unwrap();
    let mut cycle = recv.recv_limiter.start_cycle(Instant::now);
    recv.poll_socket(
        &mut cx,
        &mut engine,
        &mut socket,
        Instant::now(),
        &budget,
        &mut cycle,
    )
    .into_result()
    .expect("a reset is attacker-injectable noise and must be ignored");
    let mut socket = Socket::new(TestSocket {
        recv_errors: [io::ErrorKind::PermissionDenied].into(),
        ..TestSocket::default()
    })
    .unwrap();
    let mut cycle = recv.recv_limiter.start_cycle(Instant::now);
    assert_eq!(
        recv.poll_socket(
            &mut cx,
            &mut engine,
            &mut socket,
            Instant::now(),
            &budget,
            &mut cycle
        )
        .into_result()
        .unwrap_err()
        .kind(),
        io::ErrorKind::PermissionDenied
    );
}

/// Responses queued on a socket that is then replaced finish from the endpoint's own
/// continuation wakes: no further packet or timer is needed, the old socket is retired once
/// they left, and the endpoint's counters account for it exactly once.
#[tokio::test]
async fn queued_responses_on_a_replaced_socket_finish_from_their_own_continuation() {
    struct SelfWake(AtomicUsize);
    impl Wake for SelfWake {
        fn wake(self: Arc<Self>) {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }
    let first = Captured::default();
    let endpoint = test_endpoint(TestSocket {
        captured: first.clone(),
        ..TestSocket::default()
    });
    let mut driver = std::pin::pin!(EndpointDriver(endpoint.inner.0.clone()));
    let wake = Arc::new(SelfWake(AtomicUsize::new(0)));
    let waker = Waker::from(wake.clone());
    let mut cx = Context::from_waker(&waker);
    assert!(driver.as_mut().poll(&mut cx).is_pending());
    let queued = RESPONSE_WORK_LIMIT + 8;
    for _ in 0..queued {
        endpoint.inner.state.lock().respond_active(
            proto::Transmit {
                destination: ([127, 0, 0, 2], 5555).into(),
                ecn: None,
                size: 1,
                segment_size: None,
                local: None,
                cid_used: None,
            },
            b"x",
        );
    }
    let second = Captured::default();
    endpoint
        .rebind_abstract(
            Socket::new(TestSocket {
                captured: second.clone(),
                ..TestSocket::default()
            })
            .unwrap(),
        )
        .unwrap();
    assert_eq!(
        endpoint.stats().retained_sockets,
        2,
        "the replaced socket stays while its responses are queued"
    );
    // One poll sends one budget's worth from the old socket and wakes itself for the rest.
    let wakes_before = wake.0.load(Ordering::Relaxed);
    assert!(driver.as_mut().poll(&mut cx).is_pending());
    assert_eq!(first.lock().len(), RESPONSE_WORK_LIMIT);
    assert!(
        wake.0.load(Ordering::Relaxed) > wakes_before,
        "the driver must request its own continuation for the remaining responses"
    );
    assert!(driver.as_mut().poll(&mut cx).is_pending());
    assert_eq!(first.lock().len(), queued, "the rest left on the next poll");
    assert!(
        second.lock().is_empty(),
        "nothing was re-routed to the new socket"
    );
    let wakes_before = wake.0.load(Ordering::Relaxed);
    assert!(driver.as_mut().poll(&mut cx).is_pending());
    assert_eq!(
        wake.0.load(Ordering::Relaxed),
        wakes_before,
        "no continuation once every response has left"
    );
    let stats = endpoint.stats();
    assert_eq!(stats.retained_sockets, 1, "the drained socket retired");
    assert_eq!(stats.retired_sockets, 1);
    assert_eq!(stats.dropped_responses, 0);
}

/// A retiring socket whose receive path fails is marked and skipped: its queued responses
/// are dropped and counted, the endpoint driver keeps running on the active socket, and the
/// failed socket is retired once nothing depends on it. The active socket's failure stays
/// fatal.
#[tokio::test]
async fn a_failing_retiring_socket_is_isolated_and_the_active_socket_keeps_serving() {
    let old_captured = Captured::default();
    let endpoint = test_endpoint(TestSocket {
        captured: old_captured,
        recv_errors: [io::ErrorKind::PermissionDenied].into(),
        send_failure: Some(io::ErrorKind::HostUnreachable),
        ..TestSocket::default()
    });
    let mut driver = std::pin::pin!(EndpointDriver(endpoint.inner.0.clone()));
    let mut cx = Context::from_waker(Waker::noop());
    // Queue responses on the old socket: one is refused by the socket (failed_responses),
    // then the remaining ones keep the socket alive across the rebind.
    let respond = |endpoint: &Endpoint| {
        endpoint.inner.state.lock().respond_active(
            proto::Transmit {
                destination: ([127, 0, 0, 2], 5555).into(),
                ecn: None,
                size: 1,
                segment_size: None,
                local: None,
                cid_used: None,
            },
            b"x",
        )
    };
    // The old socket's first poll fails on receive while it is still active: fatal.
    respond(&endpoint);
    let fatal = test_endpoint(TestSocket {
        recv_errors: [io::ErrorKind::PermissionDenied].into(),
        ..TestSocket::default()
    });
    let mut fatal_driver = std::pin::pin!(EndpointDriver(fatal.inner.0.clone()));
    assert_matches!(
        fatal_driver.as_mut().poll(&mut cx),
        Poll::Ready(Err(_)),
        "a failing active socket ends the endpoint driver",
    );
    // Rebind first, so the old socket is retiring when its receive fails.
    let new_captured = Captured::default();
    endpoint
        .rebind_abstract(
            Socket::new(TestSocket {
                captured: new_captured.clone(),
                ..TestSocket::default()
            })
            .unwrap(),
        )
        .unwrap();
    assert_eq!(endpoint.stats().retained_sockets, 2);
    assert!(
        driver.as_mut().poll(&mut cx).is_pending(),
        "a retiring socket's failure is not fatal"
    );
    let stats = endpoint.stats();
    assert_eq!(
        stats.retained_sockets, 1,
        "the failed socket had no other dependents and was retired"
    );
    assert_eq!(stats.retired_sockets, 1);
    assert_eq!(
        stats.dropped_responses, 1,
        "its queued response was dropped and counted exactly once"
    );
    assert!(new_captured.lock().is_empty(), "nothing was re-routed");
    // The active socket keeps serving stateless responses.
    respond(&endpoint);
    assert!(driver.as_mut().poll(&mut cx).is_pending());
    assert_eq!(new_captured.lock().len(), 1);
    assert_eq!(
        endpoint.stats().dropped_responses,
        1,
        "counters survive retirement"
    );
}

/// A queued response whose sender is not writable parks the endpoint: no synchronous
/// self-wake, no spin. When the sender becomes writable it wakes the task through the waker
/// it registered, and the next poll sends the response without any other packet or timer.
#[tokio::test]
async fn a_pending_response_sender_parks_the_endpoint_until_it_is_writable() {
    struct SelfWake(AtomicUsize);
    impl Wake for SelfWake {
        fn wake(self: Arc<Self>) {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }
    let captured = Captured::default();
    let ready = Arc::new(SendReady::default());
    let endpoint = test_endpoint(TestSocket {
        captured: captured.clone(),
        send_ready: Some(ready.clone()),
        ..TestSocket::default()
    });
    let mut driver = std::pin::pin!(EndpointDriver(endpoint.inner.0.clone()));
    let wake = Arc::new(SelfWake(AtomicUsize::new(0)));
    let waker = Waker::from(wake.clone());
    let mut cx = Context::from_waker(&waker);
    assert!(driver.as_mut().poll(&mut cx).is_pending());
    // The queued response wakes the driver once (that is the endpoint asking to run), then
    // the poll finds the sender pending and parks without asking to run again.
    endpoint.inner.state.lock().respond_active(
        proto::Transmit {
            destination: ([127, 0, 0, 2], 5555).into(),
            ecn: None,
            size: 1,
            segment_size: None,
            local: None,
            cid_used: None,
        },
        b"x",
    );
    let wakes_before = wake.0.load(Ordering::Relaxed);
    for _ in 0..3 {
        assert!(driver.as_mut().poll(&mut cx).is_pending());
        assert_eq!(
            wake.0.load(Ordering::Relaxed),
            wakes_before,
            "a pending sender must not make the endpoint wake itself"
        );
    }
    assert!(captured.lock().is_empty());
    // Becoming writable wakes the task through the registered waker; the next poll sends.
    ready.open();
    assert_eq!(wake.0.load(Ordering::Relaxed), wakes_before + 1);
    assert!(driver.as_mut().poll(&mut cx).is_pending());
    assert_eq!(captured.lock().len(), 1, "sent on the poll after the wake");
    assert_eq!(
        wake.0.load(Ordering::Relaxed),
        wakes_before + 1,
        "nothing left: no continuation requested"
    );
}

#[tokio::test]
async fn receive_queue_limits_must_hold_one_datagram_and_one_attempt() {
    let cases = [
        (
            ReceiveQueueLimits::new(1, 100).unwrap(),
            ReceiveQueueLimits::new(1, 100_000).unwrap(),
        ),
        (
            ReceiveQueueLimits::new(4, 100_000).unwrap(),
            ReceiveQueueLimits::new(2, 100_000).unwrap(),
        ),
        (
            ReceiveQueueLimits::new(1, 2_000).unwrap(),
            ReceiveQueueLimits::new(1, 2_000).unwrap(),
        ),
    ];
    for (connection, endpoint) in cases {
        let mut config = EndpointConfig::try_with_rand_key().unwrap();
        config.set_receive_queue_limits(connection, endpoint);
        let socket = Socket::new(TestSocket::default()).unwrap();
        let error = Endpoint::new_with_advertised(
            config,
            None,
            socket,
            Vec::new(),
            rama_core::rt::Executor::new(),
            Duration::from_secs(1),
        )
        .unwrap_err();
        assert_eq!(
            error.kind(),
            io::ErrorKind::InvalidInput,
            "{connection:?} / {endpoint:?}"
        );
    }
    ReceiveQueueLimits::new(0, 1).unwrap_err();
    ReceiveQueueLimits::new(1, 0).unwrap_err();
}

// These suites establish real TLS connections.
#[cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
mod construction;
#[cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
mod lifecycle;
#[cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
mod preferred;

#[cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
mod spin;

#[test]
fn receive_grows_for_a_later_socket_gro_capability() {
    let mut config = EndpointConfig::try_with_rand_key().unwrap();
    config.max_udp_payload_size(1200).unwrap();
    let mut endpoint = proto::Endpoint::new(Arc::new(config), None, false, None);
    // The endpoint's first socket accepted one segment; the next accepts four.
    let mut recv = RecvState::new(1, &endpoint);
    let original_capacity = recv.recv_buf.len();
    let mut socket = Socket::new(TestSocket {
        entries: [(vec![0; 4 * 1200], metadata(4 * 1200, Some(1200)))].into(),
        ..TestSocket::default()
    })
    .unwrap();
    let budget = PacketBudget::new(endpoint.config().endpoint_receive_queue);
    let mut cycle = recv.start_recv_cycle();
    recv.poll_socket(
        &mut Context::from_waker(Waker::noop()),
        &mut endpoint,
        &mut socket,
        Instant::now(),
        &budget,
        &mut cycle,
    )
    .into_result()
    .unwrap();
    assert_eq!(recv.received_datagrams, 4);
    assert_eq!(recv.truncated_receive_entries, 0);
    assert_eq!(recv.recv_buf.len(), original_capacity * 4);

    // Ordinary polls reuse the allocation; this is not a per-packet resize.
    let allocation = recv.recv_buf.as_ptr();
    let mut cycle = recv.start_recv_cycle();
    recv.poll_socket(
        &mut Context::from_waker(Waker::noop()),
        &mut endpoint,
        &mut socket,
        Instant::now(),
        &budget,
        &mut cycle,
    )
    .into_result()
    .unwrap();
    assert_eq!(recv.recv_buf.as_ptr(), allocation);
}

#[test]
fn receive_gro_capacity_bounds_socket_capability_claims() {
    let mut config = EndpointConfig::try_with_rand_key().unwrap();
    config.max_udp_payload_size(1200).unwrap();
    let endpoint = proto::Endpoint::new(Arc::new(config), None, false, None);
    for (segments, expected) in [
        (0, 1),
        (1, 1),
        (63, 63),
        (64, 64),
        (65, 64),
        (usize::MAX, 64),
    ] {
        let recv = RecvState::new(segments, &endpoint);
        assert_eq!(recv.recv_buf.len(), 1200 * expected * BATCH_SIZE);
    }
}
