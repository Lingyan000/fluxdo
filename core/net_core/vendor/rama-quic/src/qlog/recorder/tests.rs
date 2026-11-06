use super::*;
use crate::qlog::{
    QlogEventView, QlogOutput,
    event::packet::{Packet, PacketEvent, PacketHeader, PacketType},
};
use rama_core::error::{BoxError, error_chain};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[derive(Clone, Default)]
struct Reports(Arc<Mutex<Vec<BoxError>>>);

impl ErrorSink for Reports {
    fn sink_error(&self, error: BoxError) {
        self.0.lock().push(error);
    }
}

fn packet(number: u64) -> EventFields {
    PacketEvent::PacketReceived(Packet {
        header: PacketHeader {
            packet_type: PacketType::OneRtt,
            packet_number: number,
        },
        raw: None,
        is_mtu_probe_packet: None,
    })
    .into()
}

fn event_with_heap(number: u64, storage: String) -> EventFields {
    crate::qlog::event::lifecycle::LifecycleEvent::Closed(
        crate::qlog::event::lifecycle::ConnectionClosed {
            error_code: Some(number),
            reason: Some(crate::qlog::event::lifecycle::ReasonView::Bytes(
                std::borrow::Cow::Owned(storage.into_bytes()),
            )),
            ..Default::default()
        },
    )
    .into()
}

fn observation(group: u8, number: u64, time: Instant) -> QlogEvent {
    QlogEvent {
        group_id: ConnectionId::new(&[group]),
        time,
        fields: packet(number),
    }
}

fn number(event: &QlogEventView<'_>) -> u64 {
    match &event.fields.event {
        crate::qlog::event::EventView::Packet(PacketEvent::PacketReceived(packet)) => {
            packet.header.packet_number
        }
        crate::qlog::event::EventView::Lifecycle(
            crate::qlog::event::lifecycle::LifecycleEventView::Closed(closed),
        ) => closed.error_code.unwrap(),
        _ => panic!("unexpected test event"),
    }
}

fn recorded_number(event: &RecordedEvent) -> u64 {
    match event {
        RecordedEvent::Typed(event) => number(event),
        RecordedEvent::Named(_) => panic!("expected typed history event"),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    Begin,
    Event,
    Flush,
    Finish,
    Drop,
}

#[derive(Default)]
struct Observed {
    calls: Vec<(Phase, Option<tokio::task::Id>)>,
    events: Vec<(ConnectionId, Instant, u64)>,
}

type Log = Arc<Mutex<Observed>>;

struct Block {
    entered: oneshot::Sender<()>,
    release: oneshot::Receiver<()>,
}

fn block() -> (Block, oneshot::Receiver<()>, oneshot::Sender<()>) {
    let (entered, waiting) = oneshot::channel();
    let (release, receiver) = oneshot::channel();
    (
        Block {
            entered,
            release: receiver,
        },
        waiting,
        release,
    )
}

struct Probe {
    log: Log,
    block: Option<(Phase, Block)>,
    fail: Option<Phase>,
    panic: Option<Phase>,
}

impl Probe {
    fn new(log: &Log) -> Self {
        Self {
            log: log.clone(),
            block: None,
            fail: None,
            panic: None,
        }
    }

    async fn call(&mut self, phase: Phase) -> io::Result<()> {
        self.log.lock().calls.push((phase, tokio::task::try_id()));
        if self
            .block
            .as_ref()
            .is_some_and(|(target, _)| *target == phase)
        {
            let (_, block) = self.block.take().unwrap();
            block.entered.send(()).unwrap_or_default();
            // Waiting suspends only the recorder task. Dropping the release handle also
            // unblocks it when an assertion unwinds.
            block.release.await.unwrap_or_default();
        }
        assert_ne!(self.panic, Some(phase), "test output panic");
        if self.fail == Some(phase) {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "test destination failure",
            ));
        }
        Ok(())
    }
}

impl QlogOutput for Probe {
    async fn named_event(&mut self, _event: &NamedQlogEventView<'_>) -> io::Result<()> {
        Ok(())
    }

    async fn begin(&mut self, _: &TraceInfo) -> io::Result<()> {
        self.call(Phase::Begin).await
    }

    async fn event(&mut self, event: &QlogEventView<'_>) -> io::Result<()> {
        self.call(Phase::Event).await?;
        self.log
            .lock()
            .events
            .push((event.group_id, event.time, number(event)));
        Ok(())
    }

    async fn flush(&mut self) -> io::Result<()> {
        self.call(Phase::Flush).await
    }

    async fn finish(&mut self) -> io::Result<()> {
        self.call(Phase::Finish).await
    }
}

impl Drop for Probe {
    fn drop(&mut self) {
        self.log
            .lock()
            .calls
            .push((Phase::Drop, tokio::task::try_id()));
    }
}

fn config(output: Probe) -> QlogConfig {
    QlogConfig::default().with_output(output)
}

fn emit(recorder: &QlogRecorder, number: u64) {
    recorder.emit(ConnectionId::new(&[1]), Instant::now(), || {
        Some(packet(number))
    });
}

fn must_skip(recorder: &QlogRecorder) {
    recorder.emit(
        ConnectionId::new(&[1]),
        Instant::now(),
        || -> Option<EventFields> {
            panic!("unavailable recorder must not construct diagnostic data")
        },
    );
}

#[tokio::test]
async fn blocked_destination_leaves_current_thread_runtime_and_emission_available() {
    for phase in [Phase::Begin, Phase::Event] {
        let log = Log::default();
        let (gate, entered, release) = block();
        let mut output = Probe::new(&log);
        output.block = Some((phase, gate));
        let recorder = config(output).start().unwrap();
        if phase == Phase::Event {
            emit(&recorder, 0);
        }
        entered.await.unwrap();

        // This is a current-thread runtime. Both emission and an unrelated task must progress
        // while asynchronous output remains pending on this same runtime.
        emit(&recorder, 1);
        let progressed = tokio::spawn(async { 42 });
        assert_eq!(progressed.await.unwrap(), 42);
        assert!(log.lock().events.is_empty());
        release.send(()).unwrap();
        recorder.flush().await.unwrap();
        assert_eq!(
            log.lock().events.len(),
            if phase == Phase::Event { 2 } else { 1 }
        );
        recorder.shutdown().await.unwrap();
    }
}

#[tokio::test]
async fn admission_respects_event_count_and_byte_limits_before_building() {
    let size = std::mem::size_of::<QueuedEvent>();
    for limits in [
        QueueLimits {
            max_queued_events: 2,
            max_queued_bytes: size * 4,
            max_event_bytes: size,
        },
        QueueLimits {
            max_queued_events: 4,
            max_queued_bytes: size * 2,
            max_event_bytes: size,
        },
    ] {
        let log = Log::default();
        let (gate, entered, release) = block();
        let mut output = Probe::new(&log);
        output.block = Some((Phase::Begin, gate));
        let recorder = config(output).with_queue_limits(limits).start().unwrap();
        entered.await.unwrap();
        emit(&recorder, 0);
        emit(&recorder, 1);
        assert_eq!(recorder.stats().queued_events, 2);
        assert_eq!(recorder.stats().queued_bytes, size * 2);
        must_skip(&recorder);
        assert_eq!(recorder.stats().submitted_events, 2);
        assert_eq!(recorder.stats().dropped_events, 1);
        release.send(()).unwrap();
        recorder.flush().await.unwrap();
        assert_eq!(recorder.stats().queued_events, 0);
        assert_eq!(recorder.stats().queued_bytes, 0);
        emit(&recorder, 2);
        recorder.shutdown().await.unwrap();
        assert_eq!(log.lock().events.len(), 3);
    }
}

#[tokio::test]
async fn reservations_are_released_for_skipped_oversized_and_panicking_builders() {
    let log = Log::default();
    let size = std::mem::size_of::<QueuedEvent>();
    let recorder = config(Probe::new(&log))
        .with_queue_limits(QueueLimits {
            max_queued_events: 1,
            max_queued_bytes: size,
            max_event_bytes: size,
        })
        .start()
        .unwrap();
    recorder.emit(
        ConnectionId::new(&[]),
        Instant::now(),
        || None::<EventFields>,
    );
    assert_eq!(recorder.stats().queued_events, 0);
    assert_eq!(recorder.stats().queued_bytes, 0);
    recorder.emit(ConnectionId::new(&[]), Instant::now(), || {
        Some(event_with_heap(1, String::with_capacity(1)))
    });
    assert_eq!(recorder.stats().oversized_events, 1);
    assert_eq!(recorder.stats().dropped_events, 1);
    assert_eq!(recorder.stats().queued_events, 0);
    assert_eq!(recorder.stats().queued_bytes, 0);
    assert!(
        catch_unwind(AssertUnwindSafe(|| {
            recorder.emit(
                ConnectionId::new(&[]),
                Instant::now(),
                || -> Option<EventFields> { panic!("test builder panic") },
            );
        }))
        .is_err()
    );
    assert_eq!(recorder.stats().queued_events, 0);
    assert_eq!(recorder.stats().queued_bytes, 0);
    emit(&recorder, 2);
    recorder.shutdown().await.unwrap();
    assert_eq!(log.lock().events.len(), 1);
}

#[tokio::test]
async fn global_and_connection_toggles_share_controls_without_affecting_other_connections() {
    let log = Log::default();
    let recorder = config(Probe::new(&log))
        .with_enabled(false)
        .start()
        .unwrap();
    let first = recorder.connection(ConnectionId::new(&[1]));
    let first_clone = first.clone();
    let second = recorder.connection(ConnectionId::new(&[2]));
    must_skip(&recorder);
    assert!(!first.is_enabled());
    recorder.set_enabled(true);
    first.set_enabled(false);
    assert!(!first_clone.is_enabled());
    assert!(second.is_enabled());
    first.emit(
        first.group_id(),
        Instant::now(),
        || -> Option<EventFields> { panic!("disabled connection") },
    );
    second.emit(second.group_id(), Instant::now(), || Some(packet(1)));
    first_clone.set_enabled(true);
    first.emit(first.group_id(), Instant::now(), || Some(packet(2)));
    recorder.set_enabled(false);
    assert!(!first.is_enabled());
    assert!(!second.is_enabled());
    must_skip(&recorder);
    recorder.shutdown().await.unwrap();
    assert_eq!(
        log.lock()
            .events
            .iter()
            .map(|(id, _, number)| (*id, *number))
            .collect::<Vec<_>>(),
        [(second.group_id(), 1), (first.group_id(), 2),]
    );
    assert_eq!(
        recorder.stats().dropped_events,
        0,
        "disabled recording is not queue loss"
    );
}

#[tokio::test]
async fn shutdown_drains_after_its_waiter_is_cancelled_and_rejects_new_builders() {
    let log = Log::default();
    let (gate, entered, release) = block();
    let mut output = Probe::new(&log);
    output.block = Some((Phase::Event, gate));
    let recorder = config(output).start().unwrap();
    emit(&recorder, 0);
    entered.await.unwrap();
    emit(&recorder, 1);
    {
        let mut shutdown = std::pin::pin!(recorder.shutdown());
        tokio::select! {
            biased;
            result = &mut shutdown => panic!("shutdown completed while output blocked: {result:?}"),
            () = std::future::ready(()) => {}
        }
    }
    assert_eq!(recorder.state(), RecorderState::Draining);
    must_skip(&recorder);
    release.send(()).unwrap();
    recorder.shutdown().await.unwrap();
    assert_eq!(recorder.state(), RecorderState::Closed);
    recorder.flush().await.unwrap();
    assert_eq!(
        log.lock()
            .events
            .iter()
            .map(|(_, _, pn)| *pn)
            .collect::<Vec<_>>(),
        [0, 1]
    );
    assert_eq!(
        log.lock()
            .calls
            .iter()
            .filter(|(phase, _)| *phase == Phase::Finish)
            .count(),
        1
    );
}

#[tokio::test]
async fn flush_waits_for_output_and_survives_cancellation_of_another_flush_waiter() {
    let log = Log::default();
    let (gate, entered, release) = block();
    let mut output = Probe::new(&log);
    output.block = Some((Phase::Event, gate));
    let recorder = config(output).start().unwrap();
    emit(&recorder, 0);
    entered.await.unwrap();
    {
        let mut flush = std::pin::pin!(recorder.flush());
        tokio::select! {
            biased;
            result = &mut flush => panic!("flush completed before event output: {result:?}"),
            () = std::future::ready(()) => {}
        }
    }
    assert!(log.lock().events.is_empty());
    release.send(()).unwrap();
    recorder.flush().await.unwrap();
    assert_eq!(log.lock().events.len(), 1);
    assert_eq!(
        log.lock()
            .calls
            .iter()
            .filter(|(phase, _)| *phase == Phase::Flush)
            .count(),
        2
    );
    recorder.shutdown().await.unwrap();
}

#[tokio::test]
async fn output_errors_and_panics_end_admission_and_preserve_completion() {
    for panics in [false, true] {
        for phase in [Phase::Begin, Phase::Event, Phase::Flush, Phase::Finish] {
            let log = Log::default();
            let mut output = Probe::new(&log);
            if panics {
                output.panic = Some(phase);
            } else {
                output.fail = Some(phase);
            }
            let reports = Reports::default();
            let recorder = config(output)
                .with_error_sink(reports.clone())
                .start()
                .unwrap();
            emit(&recorder, 0);
            let error = if phase == Phase::Finish {
                recorder.shutdown().await.unwrap_err()
            } else {
                recorder.flush().await.unwrap_err()
            };
            assert_eq!(
                error.kind(),
                if panics {
                    io::ErrorKind::Other
                } else {
                    io::ErrorKind::PermissionDenied
                }
            );
            let completion = recorder.shutdown().await.unwrap_err();
            assert_eq!(completion.kind(), error.kind());
            assert_eq!(completion.to_string(), error.to_string());
            assert_eq!(recorder.state(), RecorderState::Failed);
            assert!(!recorder.is_enabled());
            must_skip(&recorder);
            let count = log.lock().calls.len();
            recorder.flush().await.unwrap_err();
            assert_eq!(log.lock().calls.len(), count);
            assert_eq!(recorder.stats().queued_events, 0);
            assert_eq!(recorder.stats().queued_bytes, 0);
            let reports = reports.0.lock();
            assert_eq!(
                reports.len(),
                1,
                "explicit error observation never reports twice"
            );
            assert_eq!(reports[0].to_string(), error.to_string());
            assert_eq!(
                reports[0].downcast_ref::<io::Error>().unwrap().kind(),
                error.kind()
            );
        }
    }
}

#[tokio::test]
async fn custom_output_lifecycle_and_destruction_stay_on_one_recorder_task() {
    let log = Log::default();
    let caller = tokio::task::try_id();
    let recorder = config(Probe::new(&log)).start().unwrap();
    emit(&recorder, 0);
    recorder.flush().await.unwrap();
    recorder.shutdown().await.unwrap();
    let log = log.lock();
    assert_eq!(
        log.calls
            .iter()
            .map(|(phase, _)| *phase)
            .collect::<Vec<_>>(),
        [
            Phase::Begin,
            Phase::Event,
            Phase::Flush,
            Phase::Finish,
            Phase::Drop,
        ]
    );
    let worker = log.calls[0].1;
    assert!(worker.is_some());
    assert_ne!(worker, caller);
    assert!(log.calls.iter().all(|(_, task)| *task == worker));
}

struct StreamingOutput {
    log: Log,
    writer: tokio::io::DuplexStream,
}

impl StreamingOutput {
    fn call(&self, phase: Phase) {
        self.log.lock().calls.push((phase, tokio::task::try_id()));
    }
}

impl QlogOutput for StreamingOutput {
    async fn named_event(&mut self, _event: &NamedQlogEventView<'_>) -> io::Result<()> {
        Ok(())
    }

    async fn begin(&mut self, _: &TraceInfo) -> io::Result<()> {
        self.call(Phase::Begin);
        self.writer.write_all(b"begin\n").await
    }

    async fn event(&mut self, _: &QlogEventView<'_>) -> io::Result<()> {
        self.call(Phase::Event);
        self.writer.write_all(b"event\n").await
    }

    async fn flush(&mut self) -> io::Result<()> {
        self.call(Phase::Flush);
        self.writer.flush().await
    }

    async fn finish(&mut self) -> io::Result<()> {
        self.call(Phase::Finish);
        self.writer.write_all(b"finish\n").await?;
        self.flush().await
    }
}

impl Drop for StreamingOutput {
    fn drop(&mut self) {
        self.call(Phase::Drop);
    }
}

#[tokio::test]
async fn custom_async_output_streams_through_capacity_one_destination() {
    let log = Log::default();
    let (writer, mut reader) = tokio::io::duplex(1);
    let read = tokio::spawn(async move {
        let mut bytes = Vec::new();
        reader.read_to_end(&mut bytes).await.unwrap();
        bytes
    });
    let recorder = QlogConfig::default()
        .with_output(StreamingOutput {
            log: log.clone(),
            writer,
        })
        .start()
        .unwrap();
    emit(&recorder, 0);
    recorder.shutdown().await.unwrap();
    assert_eq!(read.await.unwrap(), b"begin\nevent\nfinish\n");
    let log = log.lock();
    assert_eq!(
        log.calls
            .iter()
            .map(|(phase, _)| *phase)
            .collect::<Vec<_>>(),
        [
            Phase::Begin,
            Phase::Event,
            Phase::Finish,
            Phase::Flush,
            Phase::Drop,
        ]
    );
    let worker = log.calls[0].1;
    assert!(worker.is_some());
    assert_ne!(worker, tokio::task::try_id());
    assert!(log.calls.iter().all(|(_, task)| *task == worker));
}

#[tokio::test]
async fn history_dump_consumes_only_selected_group_and_preserves_original_event_times() {
    let log = Log::default();
    let recorder = config(Probe::new(&log))
        .with_history(HistoryConfig {
            window: Duration::from_secs(60),
            max_bytes: rama_utils::octets::mib(1),
        })
        .start()
        .unwrap();
    let first = recorder.connection(ConnectionId::new(&[1]));
    let second = recorder.connection(ConnectionId::new(&[2]));
    let now = Instant::now();
    let old = now.checked_sub(Duration::from_secs(100)).unwrap();
    first.emit(first.group_id(), old, || Some(packet(1)));
    second.emit(second.group_id(), now, || Some(packet(2)));
    first.emit(first.group_id(), now, || Some(packet(3)));
    recorder.flush().await.unwrap();
    assert!(log.lock().events.is_empty());
    assert_eq!(recorder.stats().queued_events, 0);
    assert_eq!(recorder.stats().history_events, 3);
    first.dump_recent().await.unwrap();
    assert_eq!(
        log.lock().events,
        [(first.group_id(), old, 1), (first.group_id(), now, 3)]
    );
    assert_eq!(recorder.stats().history_events, 1);
    first.dump_recent().await.unwrap();
    assert_eq!(log.lock().events.len(), 2);
    second.dump_recent().await.unwrap();
    assert_eq!(log.lock().events[2], (second.group_id(), now, 2));
    assert_eq!(recorder.stats().history_events, 0);
    assert_eq!(recorder.stats().history_bytes, 0);
    recorder.shutdown().await.unwrap();
}

#[test]
fn history_age_bound_uses_intake_time_and_expires_at_exact_boundary() {
    let now = Instant::now();
    let mut history = History::new(HistoryConfig {
        window: Duration::from_secs(10),
        max_bytes: rama_utils::octets::mib(1),
    });
    // Event timestamps may be out of order; retention follows monotonically ordered intake.
    history.push(
        observation(1, 1, now),
        now.checked_sub(Duration::from_secs(11)).unwrap(),
    );
    history.push(
        observation(1, 2, now.checked_sub(Duration::from_secs(20)).unwrap()),
        now.checked_sub(Duration::from_secs(10)).unwrap(),
    );
    history.push(
        observation(1, 3, now),
        now.checked_sub(Duration::from_secs(9)).unwrap(),
    );
    history.push(
        observation(1, 4, now.checked_sub(Duration::from_secs(40)).unwrap()),
        now.checked_sub(Duration::from_secs(1)).unwrap(),
    );
    history.expire(now);
    assert_eq!(
        history
            .events
            .iter()
            .map(|entry| recorded_number(&entry.event))
            .collect::<Vec<_>>(),
        [3, 4]
    );
    assert_eq!(history.bytes, 2 * Retained::storage_size());
    history.expire(now + Duration::from_secs(9));
    assert!(history.events.is_empty());
    assert_eq!(history.bytes, 0);
}

#[tokio::test]
async fn history_memory_bound_evicts_oldest_and_rejects_oversized_history_entry() {
    let now = Instant::now();
    let size = Retained::storage_size();
    let mut history = History::new(HistoryConfig {
        window: Duration::from_secs(10),
        max_bytes: size * 2,
    });
    for pn in 1..=3 {
        history.push(observation(1, pn, now), now);
    }
    assert_eq!(history.bytes, size * 2);
    assert_eq!(
        history
            .events
            .iter()
            .map(|entry| recorded_number(&entry.event))
            .collect::<Vec<_>>(),
        [2, 3]
    );
    let mut oversized = observation(1, 4, now);
    oversized.fields = event_with_heap(4, String::with_capacity(size * 2));
    history.push(oversized, now);
    assert_eq!(history.bytes, size * 2);
    let log = Log::default();
    history
        .dump(ConnectionId::new(&[1]), &mut Probe::new(&log))
        .await
        .unwrap();
    assert_eq!(
        log.lock()
            .events
            .iter()
            .map(|(_, _, pn)| *pn)
            .collect::<Vec<_>>(),
        [2, 3]
    );
    assert_eq!(history.bytes, 0);
    assert!(history.events.is_empty());
}

#[tokio::test]
async fn invalid_queue_and_history_limits_are_rejected_before_starting_output() {
    let size = std::mem::size_of::<QueuedEvent>();
    for limits in [
        QueueLimits {
            max_queued_events: usize::MAX,
            max_queued_bytes: size,
            max_event_bytes: size,
        },
        QueueLimits {
            max_queued_events: 0,
            max_queued_bytes: size,
            max_event_bytes: size,
        },
        QueueLimits {
            max_queued_events: 1,
            max_queued_bytes: size - 1,
            max_event_bytes: size,
        },
        QueueLimits {
            max_queued_events: 1,
            max_queued_bytes: size,
            max_event_bytes: size - 1,
        },
    ] {
        let log = Log::default();
        let error = config(Probe::new(&log))
            .with_queue_limits(limits)
            .start()
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
        assert!(
            log.lock()
                .calls
                .iter()
                .all(|(phase, _)| *phase != Phase::Begin)
        );
    }
    for history in [
        HistoryConfig {
            window: Duration::ZERO,
            max_bytes: 1,
        },
        HistoryConfig {
            window: Duration::from_secs(1),
            max_bytes: 0,
        },
    ] {
        let error = config(Probe::new(&Log::default()))
            .with_history(history)
            .start()
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
    }
    assert_eq!(
        QlogConfig::default().start().unwrap_err().kind(),
        io::ErrorKind::InvalidInput
    );
}

#[tokio::test]
async fn maximum_supported_channel_capacity_accepts_events() {
    let log = Log::default();
    let size = std::mem::size_of::<QueuedEvent>();
    let recorder = config(Probe::new(&log))
        .with_queue_limits(QueueLimits {
            max_queued_events: tokio::sync::Semaphore::MAX_PERMITS,
            max_queued_bytes: size,
            max_event_bytes: size,
        })
        .start()
        .unwrap();
    emit(&recorder, 1);
    recorder.shutdown().await.unwrap();
    assert_eq!(recorder.stats().submitted_events, 1);
    assert_eq!(recorder.stats().dropped_events, 0);
    assert_eq!(log.lock().events.len(), 1);
}

#[tokio::test]
async fn dropping_last_handle_wakes_idle_worker_and_finishes_destination() {
    let log = Log::default();
    let recorder = config(Probe::new(&log)).start().unwrap();
    recorder.flush().await.unwrap();
    let mut completion = recorder.shared.done.subscribe();
    drop(recorder);
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Some(result) = completion.borrow_and_update().as_ref() {
                result.as_ref().unwrap();
                break;
            }
            completion.changed().await.unwrap();
        }
    })
    .await
    .expect("dropping the last sender wakes the idle recorder");
    assert_eq!(
        log.lock()
            .calls
            .iter()
            .map(|(phase, _)| *phase)
            .collect::<Vec<_>>(),
        [Phase::Begin, Phase::Flush, Phase::Finish, Phase::Drop,]
    );
}

#[tokio::test]
async fn cancelled_shutdown_wakes_after_only_queue_permit_is_released() {
    let log = Log::default();
    let recorder = config(Probe::new(&log))
        .with_queue_limits(QueueLimits {
            max_queued_events: 1,
            ..QueueLimits::default()
        })
        .start()
        .unwrap();
    recorder.flush().await.unwrap();
    let reservation = recorder.reserve().unwrap();
    let permit = recorder.sender.try_reserve().unwrap();
    assert_eq!(recorder.stats().queued_events, 1);
    {
        let mut shutdown = std::pin::pin!(recorder.shutdown());
        tokio::select! {
            biased;
            result = &mut shutdown => panic!("shutdown ignored an outstanding reservation: {result:?}"),
            () = std::future::ready(()) => {}
        }
    }
    drop(permit);
    drop(reservation);
    tokio::time::timeout(Duration::from_secs(5), recorder.wait_done())
        .await
        .unwrap()
        .unwrap();

    assert_eq!(recorder.stats().queued_events, 0);
    assert_eq!(recorder.stats().queued_bytes, 0);
    assert!(
        log.lock().events.is_empty(),
        "releasing an unfinished observation does not submit it"
    );
}

#[tokio::test]
async fn cancelled_dump_waiter_does_not_duplicate_or_retract_submitted_history() {
    let log = Log::default();
    let (gate, entered, release) = block();
    let mut output = Probe::new(&log);
    output.block = Some((Phase::Event, gate));
    let recorder = config(output)
        .with_history(HistoryConfig {
            window: Duration::from_secs(60),
            max_bytes: rama_utils::octets::mib(1),
        })
        .start()
        .unwrap();
    let control = recorder.connection(ConnectionId::new(&[1]));
    emit(&recorder, 1);
    {
        let mut dump = std::pin::pin!(control.dump_recent());
        tokio::select! {
            biased;
            result = &mut dump => panic!("dump completed while event output blocked: {result:?}"),
            result = entered => { result.unwrap(); }
        }
    }
    release.send(()).unwrap();
    control.dump_recent().await.unwrap();
    assert_eq!(log.lock().events.len(), 1);
    assert_eq!(recorder.stats().history_events, 0);
    recorder.shutdown().await.unwrap();
}

#[tokio::test]
async fn history_trigger_requires_history_and_an_open_recorder() {
    let recorder = config(Probe::new(&Log::default())).start().unwrap();
    assert_eq!(
        recorder
            .connection(ConnectionId::new(&[1]))
            .dump_recent()
            .await
            .unwrap_err()
            .kind(),
        io::ErrorKind::Unsupported
    );
    recorder.shutdown().await.unwrap();
    let recorder = config(Probe::new(&Log::default()))
        .with_history(HistoryConfig {
            window: Duration::from_secs(60),
            max_bytes: rama_utils::octets::mib(1),
        })
        .start()
        .unwrap();
    let control = recorder.connection(ConnectionId::new(&[1]));
    emit(&recorder, 1);
    recorder.shutdown().await.unwrap();
    assert_eq!(recorder.stats().history_events, 0);
    assert_eq!(
        control.dump_recent().await.unwrap_err().kind(),
        io::ErrorKind::BrokenPipe
    );
}

#[tokio::test]
async fn event_being_written_still_counts_against_admission_limits() {
    let log = Log::default();
    let (gate, entered, release) = block();
    let mut output = Probe::new(&log);
    output.block = Some((Phase::Event, gate));
    let size = std::mem::size_of::<QueuedEvent>();
    let recorder = config(output)
        .with_queue_limits(QueueLimits {
            max_queued_events: 1,
            max_queued_bytes: size,
            max_event_bytes: size,
        })
        .start()
        .unwrap();
    emit(&recorder, 1);
    entered.await.unwrap();
    assert_eq!(recorder.stats().queued_events, 1);
    assert_eq!(recorder.stats().queued_bytes, size);
    must_skip(&recorder);
    release.send(()).unwrap();
    recorder.flush().await.unwrap();
    assert_eq!(recorder.stats().queued_events, 0);
    assert_eq!(recorder.stats().queued_bytes, 0);
    recorder.shutdown().await.unwrap();
}

#[tokio::test]
async fn byte_accounting_retains_owned_capacity_and_returns_unused_reservation() {
    let log = Log::default();
    let (gate, entered, release) = block();
    let mut output = Probe::new(&log);
    output.block = Some((Phase::Begin, gate));
    let size = std::mem::size_of::<QueuedEvent>();
    let spare = String::with_capacity(128);
    let capacity = spare.capacity();
    let limit = size + capacity;
    let recorder = config(output)
        .with_queue_limits(QueueLimits {
            max_queued_events: 2,
            max_queued_bytes: limit * 2,
            max_event_bytes: limit,
        })
        .start()
        .unwrap();
    entered.await.unwrap();
    recorder.emit(ConnectionId::new(&[1]), Instant::now(), || {
        Some(event_with_heap(1, spare))
    });
    emit(&recorder, 2);
    assert_eq!(recorder.stats().queued_bytes, limit + size);
    assert_eq!(recorder.stats().queued_events, 2);
    release.send(()).unwrap();
    recorder.shutdown().await.unwrap();
    assert_eq!(recorder.stats().queued_bytes, 0);
    assert_eq!(recorder.stats().queued_events, 0);
    assert_eq!(log.lock().events.len(), 2);
}

struct DefaultFinish(Probe);

impl QlogOutput for DefaultFinish {
    async fn named_event(&mut self, _event: &NamedQlogEventView<'_>) -> io::Result<()> {
        Ok(())
    }

    async fn begin(&mut self, info: &TraceInfo) -> io::Result<()> {
        self.0.begin(info).await
    }

    async fn event(&mut self, event: &QlogEventView<'_>) -> io::Result<()> {
        self.0.event(event).await
    }

    async fn flush(&mut self) -> io::Result<()> {
        self.0.flush().await
    }
}

#[tokio::test]
async fn default_output_finish_flushes_pending_output() {
    let log = Log::default();
    let recorder = QlogConfig::default()
        .with_output(DefaultFinish(Probe::new(&log)))
        .start()
        .unwrap();
    emit(&recorder, 1);
    recorder.shutdown().await.unwrap();
    assert_eq!(log.lock().events.len(), 1);
    assert_eq!(
        log.lock()
            .calls
            .iter()
            .map(|(phase, _)| *phase)
            .collect::<Vec<_>>(),
        [Phase::Begin, Phase::Event, Phase::Flush, Phase::Drop,]
    );
}

fn borrowed_reason(text: &str) -> EventFieldsView<'_> {
    crate::qlog::event::lifecycle::LifecycleEventView::Closed(
        crate::qlog::event::lifecycle::ConnectionClosedView {
            error_code: Some(1),
            reason: Some(crate::qlog::event::lifecycle::ReasonView::Text(text)),
            ..Default::default()
        },
    )
    .into()
}

#[tokio::test]
async fn borrowed_admission_accepts_exact_event_limit_and_rejects_larger_views() {
    const TEXT_BYTES: usize = 32;
    let log = Log::default();
    let (gate, entered, release) = block();
    let mut output = Probe::new(&log);
    output.block = Some((Phase::Begin, gate));
    let limit = std::mem::size_of::<QueuedEvent>() + TEXT_BYTES;
    let recorder = config(output)
        .with_queue_limits(QueueLimits {
            max_queued_events: 8,
            max_queued_bytes: limit * 8,
            max_event_bytes: limit,
        })
        .start()
        .unwrap();
    entered.await.unwrap();
    let exact = "x".repeat(TEXT_BYTES);
    let below = &exact[..TEXT_BYTES - 1];
    let oversized = "x".repeat(TEXT_BYTES + 1);
    let now = Instant::now();
    let group = ConnectionId::new(&[1]);
    for text in [below, exact.as_str()] {
        assert!(recorder.emit_view(group, now, || Some(borrowed_reason(text))));
        assert!(QlogSink::emit(
            &recorder,
            &QlogEventView {
                group_id: group,
                time: now,
                fields: borrowed_reason(text)
            }
        ));
    }
    assert!(!recorder.emit_view(group, now, || Some(borrowed_reason(&oversized))));
    assert!(!QlogSink::emit(
        &recorder,
        &QlogEventView {
            group_id: group,
            time: now,
            fields: borrowed_reason(&oversized)
        }
    ));
    assert_eq!(recorder.stats().submitted_events, 4);
    assert_eq!(recorder.stats().oversized_events, 2);
    assert_eq!(recorder.stats().dropped_events, 2);
    assert_eq!(recorder.stats().queued_events, 4);
    assert_eq!(recorder.stats().queued_bytes, 4 * limit - 2);
    release.send(()).unwrap();
    recorder.shutdown().await.unwrap();
    assert_eq!(log.lock().events.len(), 4);
}

#[tokio::test]
async fn observer_trait_gate_tracks_disabled_and_closed_recorders() {
    let recorder = config(Probe::new(&Log::default()))
        .with_enabled(false)
        .start()
        .unwrap();
    let observer: &dyn QlogSink = &recorder;
    assert!(!observer.is_enabled());
    recorder.set_enabled(true);
    assert!(observer.is_enabled());
    recorder.set_enabled(false);
    assert!(!observer.is_enabled());
    recorder.shutdown().await.unwrap();
    recorder.set_enabled(true);
    assert!(
        !observer.is_enabled(),
        "a closed recorder never reopens admission"
    );
}

#[tokio::test]
async fn history_budget_accounts_for_inline_event_and_both_list_links() {
    // LinkedList stores each retained value with previous/next node links. Derive the node
    // layout independently of History's accounting helper, including any layout padding.
    type HistoryNodeLayout = (Retained, [Option<std::ptr::NonNull<()>>; 2]);
    let node_bytes = std::mem::size_of::<HistoryNodeLayout>();
    assert!(node_bytes > std::mem::size_of::<Retained>());
    let log = Log::default();
    let recorder = config(Probe::new(&log))
        .with_history(HistoryConfig {
            window: Duration::from_secs(60),
            max_bytes: node_bytes * 2,
        })
        .start()
        .unwrap();
    for number in 1..=3 {
        emit(&recorder, number);
    }
    recorder.flush().await.unwrap();
    assert_eq!(
        recorder.stats().history_events,
        2,
        "the third entry evicts the oldest allocation"
    );
    assert_eq!(recorder.stats().history_bytes, node_bytes * 2);
    recorder
        .connection(ConnectionId::new(&[1]))
        .dump_recent()
        .await
        .unwrap();
    assert_eq!(
        log.lock()
            .events
            .iter()
            .map(|(_, _, pn)| *pn)
            .collect::<Vec<_>>(),
        [2, 3]
    );
    assert_eq!(recorder.stats().history_bytes, 0);
    recorder.shutdown().await.unwrap();
}

#[tokio::test]
async fn in_flight_count_limit_rejects_before_builder_even_with_spare_channel_and_bytes() {
    let log = Log::default();
    let (gate, entered, release) = block();
    let mut output = Probe::new(&log);
    output.block = Some((Phase::Event, gate));
    let size = std::mem::size_of::<QueuedEvent>();
    let recorder = config(output)
        .with_queue_limits(QueueLimits {
            max_queued_events: 1,
            max_queued_bytes: size * 2,
            max_event_bytes: size,
        })
        .start()
        .unwrap();
    emit(&recorder, 1);
    entered.await.unwrap();
    assert_eq!(
        recorder.sender.capacity(),
        1,
        "the worker dequeued the in-flight event"
    );
    assert_eq!(recorder.stats().queued_bytes, size);
    must_skip(&recorder);
    assert_eq!(recorder.stats().dropped_events, 1);
    assert_eq!(recorder.stats().submitted_events, 1);
    release.send(()).unwrap();
    recorder.shutdown().await.unwrap();
    assert_eq!(log.lock().events.len(), 1);
}

#[tokio::test]
async fn history_accepts_an_entry_exactly_equal_to_its_entire_budget() {
    type HistoryNodeLayout = (Retained, [Option<std::ptr::NonNull<()>>; 2]);
    let node_bytes = std::mem::size_of::<HistoryNodeLayout>();
    let log = Log::default();
    let recorder = config(Probe::new(&log))
        .with_history(HistoryConfig {
            window: Duration::from_secs(60),
            max_bytes: node_bytes,
        })
        .start()
        .unwrap();
    emit(&recorder, 1);
    recorder.flush().await.unwrap();
    assert_eq!(recorder.stats().history_events, 1);
    assert_eq!(recorder.stats().history_bytes, node_bytes);
    recorder
        .connection(ConnectionId::new(&[1]))
        .dump_recent()
        .await
        .unwrap();
    assert_eq!(log.lock().events.len(), 1);
    assert_eq!(recorder.stats().history_events, 0);
    assert_eq!(recorder.stats().history_bytes, 0);
    recorder.shutdown().await.unwrap();
}

#[tokio::test]
async fn partial_history_dumps_release_only_selected_connections_storage() {
    type HistoryNodeLayout = (Retained, [Option<std::ptr::NonNull<()>>; 2]);
    let node_bytes = std::mem::size_of::<HistoryNodeLayout>();
    let log = Log::default();
    let recorder = config(Probe::new(&log))
        .with_history(HistoryConfig {
            window: Duration::from_secs(60),
            max_bytes: node_bytes * 5,
        })
        .start()
        .unwrap();
    for (group, pn) in [(1, 1), (2, 2), (1, 3), (3, 4), (2, 5)] {
        assert!(
            recorder.emit(ConnectionId::new(&[group]), Instant::now(), || Some(
                packet(pn)
            ))
        );
    }
    recorder.flush().await.unwrap();
    assert_eq!(recorder.stats().history_events, 5);
    assert_eq!(recorder.stats().history_bytes, node_bytes * 5);
    recorder
        .connection(ConnectionId::new(&[1]))
        .dump_recent()
        .await
        .unwrap();
    assert_eq!(recorder.stats().history_events, 3);
    assert_eq!(recorder.stats().history_bytes, node_bytes * 3);
    recorder
        .connection(ConnectionId::new(&[2]))
        .dump_recent()
        .await
        .unwrap();
    assert_eq!(recorder.stats().history_events, 1);
    assert_eq!(recorder.stats().history_bytes, node_bytes);
    recorder
        .connection(ConnectionId::new(&[3]))
        .dump_recent()
        .await
        .unwrap();
    assert_eq!(recorder.stats().history_events, 0);
    assert_eq!(recorder.stats().history_bytes, 0);
    assert_eq!(
        log.lock()
            .events
            .iter()
            .map(|(_, _, pn)| *pn)
            .collect::<Vec<_>>(),
        [1, 3, 2, 5, 4]
    );
    recorder.shutdown().await.unwrap();
}

#[tokio::test]
async fn graceful_executor_stops_admission_while_output_waits_and_drains_before_guard_finishes() {
    for (phase, cancel_waiter) in [
        (Phase::Begin, false),
        (Phase::Event, false),
        (Phase::Event, true),
    ] {
        let log = Log::default();
        let (gate, entered, release) = block();
        let mut output = Probe::new(&log);
        output.block = Some((phase, gate));
        let (signal, cancelled) = oneshot::channel();
        let shutdown = rama_core::graceful::Shutdown::new(async move {
            cancelled.await.unwrap_or_default();
        });
        let recorder = QlogConfig::default()
            .with_output(DefaultFinish(output))
            .with_executor(rama_core::rt::Executor::graceful(shutdown.guard()))
            .start()
            .unwrap();
        if phase == Phase::Event {
            emit(&recorder, 0);
        }
        entered.await.unwrap();
        if phase == Phase::Begin {
            emit(&recorder, 0);
        }
        emit(&recorder, 1);
        let finished = tokio::spawn(shutdown.shutdown());
        signal.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(5), async {
            while recorder.state() != RecorderState::Draining {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("graceful shutdown closes admission while output is pending");
        must_skip(&recorder);
        assert!(
            !finished.is_finished(),
            "the graceful guard waits for accepted output"
        );
        assert!(log.lock().events.is_empty());
        if cancel_waiter {
            finished.abort();
            assert!(finished.await.unwrap_err().is_cancelled());
            release.send(()).unwrap();
            tokio::time::timeout(Duration::from_secs(5), recorder.wait_done())
                .await
                .unwrap()
                .unwrap();
        } else {
            release.send(()).unwrap();
            tokio::time::timeout(Duration::from_secs(5), finished)
                .await
                .unwrap()
                .unwrap();
        }
        assert_eq!(recorder.state(), RecorderState::Closed);
        assert_eq!(
            log.lock()
                .events
                .iter()
                .map(|(_, _, pn)| *pn)
                .collect::<Vec<_>>(),
            [0, 1]
        );
        assert_eq!(
            log.lock()
                .calls
                .iter()
                .map(|(phase, _)| *phase)
                .collect::<Vec<_>>(),
            [
                Phase::Begin,
                Phase::Event,
                Phase::Event,
                Phase::Flush,
                Phase::Drop,
            ]
        );
        recorder.shutdown().await.unwrap();
    }
}

#[test]
fn dropping_runtime_reports_interrupted_for_unpolled_and_pending_outputs() {
    for phase in [None, Some(Phase::Begin), Some(Phase::Event)] {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let log = Log::default();
        let (gate, entered, release) = block();
        let mut output = Probe::new(&log);
        if let Some(phase) = phase {
            output.block = Some((phase, gate));
        }
        let reports = Reports::default();
        let recorder = {
            let _entered = runtime.enter();
            config(output)
                .with_error_sink(reports.clone())
                .start()
                .unwrap()
        };
        if phase.is_some() {
            runtime.block_on(async {
                if phase == Some(Phase::Event) {
                    emit(&recorder, 1);
                }
                entered.await.unwrap();
            });
        }
        // Keep the release sender alive: the pending operation is cancelled by runtime
        // destruction, not completed by disconnecting its test signal.
        drop(runtime);
        assert_eq!(recorder.state(), RecorderState::Failed);
        assert_eq!(recorder.error().unwrap().kind(), io::ErrorKind::Interrupted);
        assert_eq!(reports.0.lock().len(), 1);
        assert_eq!(
            reports.0.lock()[0]
                .downcast_ref::<io::Error>()
                .unwrap()
                .kind(),
            io::ErrorKind::Interrupted
        );
        assert!(!recorder.is_enabled());
        must_skip(&recorder);
        assert_eq!(recorder.stats().queued_events, 0);
        assert_eq!(recorder.stats().queued_bytes, 0);
        assert_eq!(
            log.lock().calls.last().map(|(phase, _)| *phase),
            Some(Phase::Drop)
        );
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            let (flushed, closed) = tokio::time::timeout(Duration::from_secs(5), async {
                tokio::join!(recorder.flush(), recorder.shutdown())
            })
            .await
            .expect("aborted output completes all recorder waiters");
            assert_eq!(flushed.unwrap_err().kind(), io::ErrorKind::Interrupted);
            assert_eq!(closed.unwrap_err().kind(), io::ErrorKind::Interrupted);
        });
        assert_eq!(reports.0.lock().len(), 1);
        drop(release);
    }
}

struct ConstructionPanic {
    panic_on_flush: bool,
}

impl QlogOutput for ConstructionPanic {
    async fn named_event(&mut self, _event: &NamedQlogEventView<'_>) -> io::Result<()> {
        Ok(())
    }

    async fn begin(&mut self, _: &TraceInfo) -> io::Result<()> {
        Ok(())
    }

    async fn event(&mut self, _: &QlogEventView<'_>) -> io::Result<()> {
        Ok(())
    }

    fn flush(&mut self) -> impl Future<Output = io::Result<()>> + Send {
        assert!(
            !self.panic_on_flush,
            "output panicked while constructing its flush future"
        );
        std::future::ready(Ok(()))
    }
}

#[tokio::test]
async fn panic_constructing_output_future_is_published_before_flush_waiter_returns() {
    let recorder = QlogConfig::default()
        .with_output(ConstructionPanic {
            panic_on_flush: true,
        })
        .start()
        .unwrap();
    let error = recorder.flush().await.unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::Other);
    assert_eq!(recorder.state(), RecorderState::Failed);
    assert!(!recorder.is_enabled());
    assert_eq!(recorder.error().unwrap().to_string(), error.to_string());
    must_skip(&recorder);
    assert_eq!(
        recorder.shutdown().await.unwrap_err().to_string(),
        error.to_string()
    );
}

struct ReadyOutput {
    events: Arc<AtomicUsize>,
    observed: Option<oneshot::Sender<usize>>,
}

impl QlogOutput for ReadyOutput {
    async fn named_event(&mut self, _event: &NamedQlogEventView<'_>) -> io::Result<()> {
        Ok(())
    }

    async fn begin(&mut self, _: &TraceInfo) -> io::Result<()> {
        let events = self.events.clone();
        let observed = self.observed.take().unwrap();
        tokio::spawn(async move {
            observed
                .send(events.load(Ordering::Acquire))
                .unwrap_or_default();
        });
        Ok(())
    }

    async fn event(&mut self, _: &QlogEventView<'_>) -> io::Result<()> {
        self.events.fetch_add(1, Ordering::Release);
        Ok(())
    }

    async fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[tokio::test]
async fn ready_output_yields_to_other_tasks_before_draining_a_large_queue() {
    const EVENTS: usize = 1024;
    let events = Arc::new(AtomicUsize::new(0));
    let (observed, progress) = oneshot::channel();
    let recorder = QlogConfig::default()
        .with_output(ReadyOutput {
            events: events.clone(),
            observed: Some(observed),
        })
        .start()
        .unwrap();
    for pn in 0..EVENTS {
        assert!(
            recorder.emit(ConnectionId::new(&[1]), Instant::now(), || Some(packet(
                pn as u64
            )))
        );
    }
    recorder.shutdown().await.unwrap();
    assert_eq!(events.load(Ordering::Acquire), EVENTS);
    assert!(
        progress.await.unwrap() < EVENTS,
        "ready output must not monopolize the current-thread runtime until its entire queue drains"
    );
}

#[tokio::test]
async fn graceful_shutdown_reports_final_flush_and_finish_failures_without_recorder_shutdown() {
    for phase in [None, Some(Phase::Flush), Some(Phase::Finish)] {
        let reports = Reports::default();
        let log = Log::default();
        let mut output = Probe::new(&log);
        output.fail = phase;
        let (signal, cancelled) = oneshot::channel();
        let shutdown = rama_core::graceful::Shutdown::new(async move {
            cancelled.await.unwrap_or_default();
        });
        let config = QlogConfig::default()
            .with_executor(rama_core::rt::Executor::graceful(shutdown.guard()))
            .with_error_sink(reports.clone());
        let config = if phase == Some(Phase::Flush) {
            config.with_output(DefaultFinish(output))
        } else {
            config.with_output(output)
        };
        let recorder = config.start().unwrap();
        emit(&recorder, 1);
        let finished = tokio::spawn(shutdown.shutdown());
        signal.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(5), finished)
            .await
            .unwrap()
            .unwrap();
        // The shared graceful shutdown is all the application needs to await: no recorder
        // flush, completion poll or shutdown call was used to obtain this report.
        assert_eq!(log.lock().events.len(), 1);
        assert_eq!(
            log.lock().calls.last().map(|(phase, _)| *phase),
            Some(Phase::Drop)
        );
        assert_eq!(reports.0.lock().len(), usize::from(phase.is_some()));
        if phase.is_some() {
            assert_eq!(recorder.state(), RecorderState::Failed);
            assert_eq!(
                reports.0.lock()[0]
                    .downcast_ref::<io::Error>()
                    .unwrap()
                    .kind(),
                io::ErrorKind::PermissionDenied
            );
            assert_eq!(
                recorder.shutdown().await.unwrap_err().kind(),
                io::ErrorKind::PermissionDenied
            );
            assert_eq!(reports.0.lock().len(), 1);
        } else {
            assert_eq!(recorder.state(), RecorderState::Closed);
            recorder.shutdown().await.unwrap();
        }
    }
}

#[derive(Debug)]
struct StorageFailure;

impl std::fmt::Display for StorageFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("typed storage failure")
    }
}

impl std::error::Error for StorageFailure {}

// A worker owns its output; an output that is Send but not Sync remains supported.
struct SourceFailureOutput(std::cell::Cell<bool>);

impl QlogOutput for SourceFailureOutput {
    async fn named_event(&mut self, _event: &NamedQlogEventView<'_>) -> io::Result<()> {
        Ok(())
    }

    async fn begin(&mut self, _: &TraceInfo) -> io::Result<()> {
        self.0.set(true);
        Ok(())
    }

    async fn event(&mut self, _: &QlogEventView<'_>) -> io::Result<()> {
        assert!(self.0.get());
        Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            StorageFailure,
        ))
    }

    async fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[tokio::test]
async fn error_sink_and_completion_retain_operation_context_and_original_error() {
    let reports = Reports::default();
    let recorder = QlogConfig::default()
        .with_output(SourceFailureOutput(std::cell::Cell::new(false)))
        .with_error_sink(reports.clone())
        .start()
        .unwrap();
    emit(&recorder, 1);
    let flushed = recorder.flush().await.unwrap_err();
    let completed = recorder.shutdown().await.unwrap_err();
    let observed = recorder.error().unwrap();
    let reports = reports.0.lock();
    assert_eq!(reports.len(), 1);
    for error in [reports[0].as_ref(), &flushed, &completed, &observed] {
        assert!(error.to_string().contains("qlog event output failed"));
        assert!(
            error_chain(error).any(|cause| {
                cause.downcast_ref::<StorageFailure>().is_some()
                    || cause
                        .downcast_ref::<io::Error>()
                        .and_then(io::Error::get_ref)
                        .is_some_and(|inner| inner.downcast_ref::<StorageFailure>().is_some())
            }),
            "the original typed error must survive reporting and completion: {error:?}"
        );
    }
    assert_eq!(flushed.kind(), io::ErrorKind::PermissionDenied);
    assert_eq!(completed.kind(), flushed.kind());
}

struct PanicOnDrop;

impl Drop for PanicOnDrop {
    fn drop(&mut self) {
        panic!("a sink panic payload must not be dropped during recorder cleanup");
    }
}

#[tokio::test]
async fn panicking_sink_observes_published_failure_outside_locks_and_cannot_lose_completion() {
    let calls = Arc::new(AtomicUsize::new(0));
    let checked = Arc::new(AtomicBool::new(false));
    let shared = Arc::new(Mutex::new(None::<std::sync::Weak<Shared>>));
    let log = Log::default();
    let mut output = Probe::new(&log);
    output.fail = Some(Phase::Flush);
    let recorder = config(output)
        .with_error_sink({
            let calls = calls.clone();
            let checked = checked.clone();
            let shared = shared.clone();
            move |error: BoxError| {
                calls.fetch_add(1, Ordering::Relaxed);
                let shared = shared.lock().as_ref().unwrap().upgrade().unwrap();
                assert!(!shared.accepting());
                let stored = shared
                    .failure
                    .try_lock()
                    .expect("the sink runs outside recorder locks");
                assert_eq!(
                    stored.as_ref().unwrap().error().to_string(),
                    error.to_string()
                );
                drop(stored);
                checked.store(true, Ordering::Release);
                std::panic::panic_any(PanicOnDrop);
            }
        })
        .start()
        .unwrap();
    *shared.lock() = Some(Arc::downgrade(&recorder.shared));
    let flushed = tokio::time::timeout(Duration::from_secs(5), recorder.flush())
        .await
        .unwrap()
        .unwrap_err();
    let completed = tokio::time::timeout(Duration::from_secs(5), recorder.shutdown())
        .await
        .unwrap()
        .unwrap_err();
    assert_eq!(flushed.kind(), io::ErrorKind::PermissionDenied);
    assert_eq!(completed.to_string(), flushed.to_string());
    assert_eq!(calls.load(Ordering::Relaxed), 1);
    assert!(
        checked.load(Ordering::Acquire),
        "the callback checked publication and lock availability before its intentional panic"
    );
    assert_eq!(
        log.lock().calls.last().map(|(phase, _)| *phase),
        Some(Phase::Drop)
    );
}

#[test]
fn panicking_sink_during_runtime_cancellation_preserves_completion() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let recorder = {
        let _entered = runtime.enter();
        config(Probe::new(&Log::default()))
            .with_error_sink({
                let calls = calls.clone();
                move |_: BoxError| {
                    calls.fetch_add(1, Ordering::Relaxed);
                    std::panic::panic_any(PanicOnDrop);
                }
            })
            .start()
            .unwrap()
    };
    drop(runtime);
    assert_eq!(calls.load(Ordering::Relaxed), 1);
    assert_eq!(recorder.state(), RecorderState::Failed);
    let completion = recorder.shared.done.borrow();
    assert_eq!(
        completion.as_ref().unwrap().as_ref().unwrap_err().kind,
        io::ErrorKind::Interrupted
    );
}

#[tokio::test]
async fn dropping_last_handle_reports_finish_failure() {
    let reports = Reports::default();
    let (reported, received) = oneshot::channel();
    let reported = Mutex::new(Some(reported));
    let log = Log::default();
    let mut output = Probe::new(&log);
    output.fail = Some(Phase::Finish);
    let recorder = config(output)
        .with_error_sink({
            let reports = reports.clone();
            move |error: BoxError| {
                reports.sink_error(error);
                if let Some(reported) = reported.lock().take() {
                    reported.send(()).unwrap_or_default();
                }
            }
        })
        .start()
        .unwrap();
    drop(recorder);
    tokio::time::timeout(Duration::from_secs(5), received)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(reports.0.lock().len(), 1);
    assert_eq!(
        reports.0.lock()[0]
            .downcast_ref::<io::Error>()
            .unwrap()
            .kind(),
        io::ErrorKind::PermissionDenied
    );
}

struct DestructorFailureOutput;

impl QlogOutput for DestructorFailureOutput {
    async fn named_event(&mut self, _event: &NamedQlogEventView<'_>) -> io::Result<()> {
        Ok(())
    }

    async fn begin(&mut self, _: &TraceInfo) -> io::Result<()> {
        Ok(())
    }

    async fn event(&mut self, _: &QlogEventView<'_>) -> io::Result<()> {
        Ok(())
    }

    async fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Drop for DestructorFailureOutput {
    fn drop(&mut self) {
        panic!("test output destructor failure");
    }
}

#[tokio::test]
async fn output_destructor_failure_is_reported_once_and_preserved_for_completion() {
    let reports = Reports::default();
    let recorder = QlogConfig::default()
        .with_output(DestructorFailureOutput)
        .with_error_sink(reports.clone())
        .start()
        .unwrap();
    let error = recorder.shutdown().await.unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::Other);
    assert!(
        error
            .to_string()
            .contains("qlog output destructor panicked")
    );
    assert_eq!(reports.0.lock().len(), 1);
    assert_eq!(reports.0.lock()[0].to_string(), error.to_string());
    assert_eq!(
        recorder.flush().await.unwrap_err().to_string(),
        error.to_string()
    );
    assert_eq!(reports.0.lock().len(), 1);
}

#[tokio::test]
async fn flush_waiting_for_queue_capacity_observes_shutdown_completion() {
    for fail in [false, true] {
        let log = Log::default();
        let (gate, entered, release) = block();
        let mut output = Probe::new(&log);
        output.block = Some((Phase::Begin, gate));
        output.fail = fail.then_some(Phase::Finish);
        let recorder = config(output)
            .with_queue_limits(QueueLimits {
                max_queued_events: 1,
                ..QueueLimits::default()
            })
            .start()
            .unwrap();
        entered.await.unwrap();
        emit(&recorder, 1);
        let mut flush = std::pin::pin!(recorder.flush());
        tokio::select! {
            biased;
            result = &mut flush => panic!("flush must wait for queue capacity: {result:?}"),
            () = std::future::ready(()) => {}
        }
        recorder.shared.drain();
        release.send(()).unwrap();
        let result = flush.await;
        if fail {
            let error = result.unwrap_err();
            assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
            assert!(error.to_string().contains("qlog output finish failed"));
        } else {
            result.unwrap();
            assert_eq!(recorder.state(), RecorderState::Closed);
        }
        assert_eq!(log.lock().events.len(), 1);
    }
}

#[tokio::test]
async fn terminal_admission_and_interrupted_capture_count_as_dropped() {
    for fail in [false, true] {
        let mut output = Probe::new(&Log::default());
        output.fail = fail.then_some(Phase::Finish);
        let recorder = config(output).start().unwrap();
        recorder.flush().await.unwrap();
        assert!(!recorder.emit(ConnectionId::new(&[1]), Instant::now(), || {
            recorder.set_enabled(false);
            Some(packet(1))
        }));
        assert_eq!(recorder.stats().dropped_events, 1);
        must_skip(&recorder);
        assert_eq!(recorder.stats().dropped_events, 1);
        recorder.set_enabled(true);
        assert!(!recorder.emit(ConnectionId::new(&[1]), Instant::now(), || {
            recorder.shared.drain();
            Some(packet(2))
        }));
        must_skip(&recorder);
        assert_eq!(recorder.stats().dropped_events, 3);
        assert_eq!(recorder.shutdown().await.is_err(), fail);
        must_skip(&recorder);
        let stats = recorder.stats();
        assert_eq!(stats.dropped_events, 4);
        assert_eq!(stats.submitted_events, 0);
        assert_eq!(stats.queued_events, 0);
        assert_eq!(stats.queued_bytes, 0);
        recorder.set_enabled(false);
        must_skip(&recorder);
        assert_eq!(recorder.stats().dropped_events, 4);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn concurrent_admission_accounts_for_every_attempt_and_bounds_storage() {
    const PRODUCERS: usize = 8;
    const ATTEMPTS: usize = 256;
    let size = std::mem::size_of::<QueuedEvent>();
    for limits in [
        QueueLimits {
            max_queued_events: 16,
            max_queued_bytes: size * 32,
            max_event_bytes: size,
        },
        QueueLimits {
            max_queued_events: 32,
            max_queued_bytes: size * 16,
            max_event_bytes: size,
        },
    ] {
        let log = Log::default();
        let (gate, entered, release) = block();
        let mut output = Probe::new(&log);
        output.block = Some((Phase::Begin, gate));
        let recorder = config(output).with_queue_limits(limits).start().unwrap();
        entered.await.unwrap();
        let barrier = std::sync::Barrier::new(PRODUCERS);
        let accepted = AtomicU64::new(0);
        std::thread::scope(|scope| {
            for _ in 0..PRODUCERS {
                scope.spawn(|| {
                    barrier.wait();
                    for number in 0..ATTEMPTS {
                        if recorder.emit(ConnectionId::new(&[1]), Instant::now(), || {
                            Some(packet(number as u64))
                        }) {
                            accepted.fetch_add(1, Ordering::Relaxed);
                        }
                        let stats = recorder.stats();
                        assert!(stats.queued_events <= limits.max_queued_events);
                        assert!(stats.queued_bytes <= limits.max_queued_bytes);
                    }
                    barrier.wait();
                    recorder.shared.drain();
                    for _ in 0..ATTEMPTS {
                        must_skip(&recorder);
                    }
                });
            }
        });
        let stats = recorder.stats();
        assert_eq!(stats.submitted_events, accepted.load(Ordering::Relaxed));
        assert_eq!(
            stats.submitted_events + stats.dropped_events,
            (PRODUCERS * ATTEMPTS * 2) as u64
        );
        assert_eq!(stats.queued_events, stats.submitted_events as usize);
        assert_eq!(stats.queued_bytes, stats.queued_events * size);
        release.send(()).unwrap();
        recorder.shutdown().await.unwrap();
        assert_eq!(log.lock().events.len(), stats.submitted_events as usize);
        assert_eq!(recorder.stats().queued_events, 0);
        assert_eq!(recorder.stats().queued_bytes, 0);
    }
}

#[tokio::test(start_paused = true)]
async fn worker_history_expiry_includes_queue_wait_and_wakes_while_idle() {
    for delay in [9, 10] {
        let log = Log::default();
        let (gate, entered, release) = block();
        let mut output = Probe::new(&log);
        output.block = Some((Phase::Begin, gate));
        let recorder = config(output)
            .with_history(HistoryConfig {
                window: Duration::from_secs(10),
                max_bytes: rama_utils::octets::mib(1),
            })
            .start()
            .unwrap();
        entered.await.unwrap();
        emit(&recorder, 1);
        tokio::time::advance(Duration::from_secs(delay)).await;
        release.send(()).unwrap();
        recorder.flush().await.unwrap();
        assert_eq!(recorder.stats().history_events, usize::from(delay < 10));
        if delay < 10 {
            tokio::time::advance(Duration::from_secs(1)).await;
            tokio::task::yield_now().await;
        }
        assert_eq!(recorder.stats().history_events, 0);
        assert_eq!(recorder.stats().history_bytes, 0);
        recorder.dump_recent(ConnectionId::new(&[1])).await.unwrap();
        assert!(log.lock().events.is_empty());
        recorder.shutdown().await.unwrap();
    }
}

#[test]
fn history_orders_concurrent_admission_times_for_expiry_and_eviction() {
    let now = Instant::now();
    let mut history = History::new(HistoryConfig {
        window: Duration::from_secs(10),
        max_bytes: Retained::storage_size() * 3,
    });
    for (number, age) in [(0, 0), (2, 2), (1, 0)] {
        history.push(observation(1, number, now), now + Duration::from_secs(age));
    }
    assert_eq!(
        history
            .events
            .iter()
            .map(|entry| recorded_number(&entry.event))
            .collect::<Vec<_>>(),
        [0, 1, 2]
    );
    history.push(observation(1, 3, now), now + Duration::from_secs(3));
    history.push(
        observation(1, 0, now),
        now.checked_sub(Duration::from_secs(1)).unwrap(),
    );
    assert_eq!(
        history
            .events
            .iter()
            .map(|entry| recorded_number(&entry.event))
            .collect::<Vec<_>>(),
        [1, 2, 3]
    );
    history.expire(now + Duration::from_secs(11));
    assert_eq!(
        history
            .events
            .iter()
            .map(|entry| recorded_number(&entry.event))
            .collect::<Vec<_>>(),
        [2, 3]
    );
    assert_eq!(history.bytes, Retained::storage_size() * 2);
}

#[tokio::test]
async fn failed_history_dump_preserves_other_groups_and_remaining_storage() {
    let now = Instant::now();
    let mut history = History::new(HistoryConfig {
        window: Duration::from_secs(10),
        max_bytes: rama_utils::octets::mib(1),
    });
    for (group, number) in [(2, 0), (1, 1), (2, 2), (1, 3), (3, 4)] {
        history.push(observation(group, number, now), now);
    }
    let log = Log::default();
    let mut output = Probe::new(&log);
    output.fail = Some(Phase::Event);
    assert_eq!(
        history
            .dump(ConnectionId::new(&[1]), &mut output)
            .await
            .unwrap_err()
            .kind(),
        io::ErrorKind::PermissionDenied
    );
    assert_eq!(
        history
            .events
            .iter()
            .map(|entry| recorded_number(&entry.event))
            .collect::<Vec<_>>(),
        [0, 2, 3, 4]
    );
    assert_eq!(
        history.bytes,
        history
            .events
            .iter()
            .map(|entry| entry.bytes)
            .sum::<usize>()
    );
    output.fail = None;
    history
        .dump(ConnectionId::new(&[2]), &mut output)
        .await
        .unwrap();
    assert_eq!(
        log.lock()
            .events
            .iter()
            .map(|(_, _, number)| *number)
            .collect::<Vec<_>>(),
        [0, 2]
    );
    assert_eq!(history.bytes, Retained::storage_size() * 2);
}

#[tokio::test]
async fn borrowed_capture_is_skipped_when_disabled_full_or_closed() {
    let log = Log::default();
    let (gate, entered, release) = block();
    let mut output = Probe::new(&log);
    output.block = Some((Phase::Begin, gate));
    let recorder = config(output)
        .with_queue_limits(QueueLimits {
            max_queued_events: 1,
            ..QueueLimits::default()
        })
        .start()
        .unwrap();
    entered.await.unwrap();
    let text = String::from("borrowed diagnostic storage");
    let built = std::cell::Cell::new(0);
    let attempt = || {
        recorder.emit_view(ConnectionId::new(&[1]), Instant::now(), || {
            built.set(built.get() + 1);
            Some(borrowed_reason(&text))
        })
    };
    recorder.set_enabled(false);
    assert!(!attempt());
    recorder.set_enabled(true);
    // Control commands share channel slots with event admission.
    let (reply, _response) = oneshot::channel();
    recorder.sender.try_send(Command::Flush(reply)).unwrap();
    assert!(!attempt());
    assert_eq!(recorder.stats().queued_events, 0);
    assert_eq!(recorder.stats().queued_bytes, 0);
    assert_eq!(built.get(), 0, "rejected views never reach owned capture");
    release.send(()).unwrap();
    recorder.flush().await.unwrap();
    assert!(attempt());
    assert!(!attempt());
    recorder.shutdown().await.unwrap();
    assert!(!attempt());
    assert_eq!(built.get(), 1);
    assert_eq!(recorder.stats().submitted_events, 1);
    assert_eq!(recorder.stats().dropped_events, 3);
}
