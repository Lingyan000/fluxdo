use super::{
    EventSchema, HistoryConfig, NamedQlogEventView, QlogConfig, QlogEvent, QlogEventView,
    QlogOutput, QlogSink, QueueLimits, TraceInfo,
    event::{EventFields, EventFieldsView},
    named::{self, EncodeError, NamedEvent},
};
use crate::driver;
use parking_lot::Mutex;
use rama_core::{
    error::{ArcError, ErrorContext as _, ErrorExt as _},
    error_sink::ErrorSink,
    futures::FutureExt as _,
};
use rama_quic_proto::ConnectionId;
use serde::Serialize;
#[cfg(test)]
use std::time::Duration;
use std::{
    collections::LinkedList,
    io,
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU8, AtomicU64, AtomicUsize, Ordering},
    },
    time::Instant,
};
use tokio::sync::{Notify, mpsc, oneshot, watch};

/// Lifecycle of the output worker, independent of whether event admission is enabled.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum RecorderState {
    /// Output initialization is pending; enabled admission can already queue events.
    Starting,
    /// Output initialization succeeded; the recording gate controls admission.
    Ready,
    /// Admission is closed while accepted events drain and output finishes.
    Draining,
    /// The recording task finished successfully and released its output.
    Closed,
    /// Output or task failure closed admission; inspect [`QlogRecorder::error`].
    Failed,
}

/// Cumulative admission counters and current retained storage. Counters are observational;
/// concurrent updates can occur between reading individual fields.
#[derive(Debug, Clone, Copy)]
pub struct RecorderStats {
    /// Total events admitted to the recording task, including history-only events.
    pub submitted_events: u64,
    /// Rejected recorder admission attempts, including closed admission, full queues,
    /// oversized events and attempts interrupted by a recording toggle. Observations
    /// skipped before admission while recording is disabled are not counted.
    pub dropped_events: u64,
    /// Events exceeding the per-event byte limit; also included in `dropped_events`.
    pub oversized_events: u64,
    /// Current event reservations, including capture and the event being processed.
    pub queued_events: usize,
    /// Bytes reserved for capture, queued events and the event being processed.
    pub queued_bytes: usize,
    /// Events currently retained in the recorder's shared history window.
    pub history_events: usize,
    /// Accounted history storage, including list nodes and owned field capacities.
    pub history_bytes: usize,
}

#[derive(Debug, Clone)]
struct Failure {
    kind: io::ErrorKind,
    cause: ArcError,
}

impl Failure {
    fn error(&self) -> io::Error {
        io::Error::new(self.kind, self.cause.clone())
    }
}

type Completion = Result<(), Failure>;

struct Shared {
    state: AtomicU8,
    enabled: AtomicBool,
    generation: AtomicU64,
    limits: QueueLimits,
    schemas: &'static [EventSchema],
    history: bool,
    events: AtomicUsize,
    bytes: AtomicUsize,
    submitted: AtomicU64,
    dropped: AtomicU64,
    oversized: AtomicU64,
    history_events: AtomicUsize,
    history_bytes: AtomicUsize,
    failure: Mutex<Option<Failure>>,
    error_sink: Arc<dyn ErrorSink>,
    done: watch::Sender<Option<Completion>>,
    stop: Notify,
}

impl Shared {
    fn drain(&self) {
        let _previous = self
            .state
            .try_update(Ordering::AcqRel, Ordering::Acquire, |state| {
                (state < RecorderState::Draining as u8).then_some(RecorderState::Draining as u8)
            });
        self.stop.notify_one();
    }

    fn accepting(&self) -> bool {
        self.state.load(Ordering::Acquire) < RecorderState::Draining as u8
    }

    fn fail(&self, error: io::Error) -> Failure {
        let (failure, report) = {
            let mut stored = self.failure.lock();
            let report = stored.is_none();
            let failure = stored
                .get_or_insert_with(|| Failure {
                    kind: error.kind(),
                    cause: ArcError::new(error),
                })
                .clone();
            self.state
                .store(RecorderState::Failed as u8, Ordering::Release);
            (failure, report)
        };
        if report {
            // Publish failure before invoking user code, without holding the failure lock.
            // A sink panic must not replace the original error or interrupt completion,
            // including cancellation while this task is itself being dropped.
            if let Err(payload) = catch_unwind(AssertUnwindSafe(|| {
                self.error_sink.sink_error(failure.error().into());
            })) {
                // An arbitrary panic payload can itself panic in Drop. Keep that second
                // panic out of the recorder's cleanup, which may already be unwinding.
                #[expect(
                    clippy::mem_forget,
                    reason = "a panicking sink may return a panic payload whose destructor also panics"
                )]
                std::mem::forget(payload);
            }
        }
        failure
    }

    fn unavailable(&self) -> io::Error {
        self.failure.lock().as_ref().map_or_else(
            || io::Error::new(io::ErrorKind::BrokenPipe, "qlog recorder is closed"),
            Failure::error,
        )
    }
}

/// A cloneable handle to one worker. Clones share the destination and recording gate.
/// Keep a handle to await completion; dropping it never waits for output.
#[derive(Clone)]
pub struct QlogRecorder {
    sender: mpsc::Sender<Command>,
    shared: Arc<Shared>,
}

impl std::fmt::Debug for QlogRecorder {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("QlogRecorder")
            .field("state", &self.state())
            .field("enabled", &self.is_enabled())
            .finish_non_exhaustive()
    }
}

struct Reservation {
    shared: Arc<Shared>,
    bytes: usize,
}

impl Drop for Reservation {
    fn drop(&mut self) {
        self.shared.bytes.fetch_sub(self.bytes, Ordering::AcqRel);
        self.shared.events.fetch_sub(1, Ordering::AcqRel);
    }
}

enum RecordedEvent {
    Typed(QlogEvent),
    Named(NamedEvent),
}

impl From<QlogEvent> for RecordedEvent {
    fn from(event: QlogEvent) -> Self {
        Self::Typed(event)
    }
}

impl RecordedEvent {
    fn group_id(&self) -> ConnectionId {
        match self {
            Self::Typed(event) => event.group_id,
            Self::Named(event) => event.group_id,
        }
    }

    fn heap_size(&self) -> usize {
        match self {
            Self::Typed(event) => event.fields.heap_size(),
            Self::Named(event) => event.data.len(),
        }
    }

    async fn write(&self, output: &mut impl QlogOutput) -> io::Result<()> {
        match self {
            Self::Typed(event) => output.event(event).await,
            Self::Named(event) => output.named_event(&event.view()).await,
        }
    }
}

struct QueuedEvent {
    event: RecordedEvent,
    observed: Instant,
    reservation: Reservation,
}

enum Command {
    Event(Box<QueuedEvent>),
    Flush(oneshot::Sender<io::Result<()>>),
    Dump(ConnectionId, oneshot::Sender<io::Result<()>>),
}

impl QlogRecorder {
    pub(super) fn start(mut config: QlogConfig) -> io::Result<Self> {
        named::validate_schemas(config.info.event_schemas)?;
        let limits = config.limits;
        if limits.max_queued_events == 0
            || limits.max_queued_events > tokio::sync::Semaphore::MAX_PERMITS
            || limits.max_event_bytes < std::mem::size_of::<QueuedEvent>()
            || limits.max_queued_bytes < limits.max_event_bytes
            || config
                .history
                .is_some_and(|history| history.window.is_zero() || history.max_bytes == 0)
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid qlog queue/history limits",
            ));
        }
        let output = config.output.take().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "qlog destination is missing")
        })?;
        tokio::runtime::Handle::try_current()
            .context("starting a qlog recorder requires a Tokio runtime")
            .map_err(io::Error::other)?;
        let (sender, receiver) = mpsc::channel(limits.max_queued_events);
        let (done, _) = watch::channel(None);
        let shared = Arc::new(Shared {
            state: AtomicU8::new(RecorderState::Starting as u8),
            enabled: AtomicBool::new(config.enabled),
            generation: AtomicU64::new(0),
            limits,
            schemas: config.info.event_schemas,
            history: config.history.is_some(),
            events: AtomicUsize::new(0),
            bytes: AtomicUsize::new(0),
            submitted: AtomicU64::new(0),
            dropped: AtomicU64::new(0),
            oversized: AtomicU64::new(0),
            history_events: AtomicUsize::new(0),
            history_bytes: AtomicUsize::new(0),
            failure: Mutex::new(None),
            error_sink: config.error_sink,
            done,
            stop: Notify::new(),
        });
        output.spawn(Worker {
            receiver,
            shared: shared.clone(),
            info: config.info,
            history: config.history,
            executor: config.executor,
        });
        Ok(Self { sender, shared })
    }

    /// Current task lifecycle; use [`Self::is_enabled`] to check the recording gate too.
    pub fn state(&self) -> RecorderState {
        match self.shared.state.load(Ordering::Acquire) {
            0 => RecorderState::Starting,
            1 => RecorderState::Ready,
            2 => RecorderState::Draining,
            3 => RecorderState::Closed,
            _ => RecorderState::Failed,
        }
    }

    /// Whether the recording gate is enabled and the task still accepts events.
    /// A `true` result does not guarantee available queue capacity.
    pub fn is_enabled(&self) -> bool {
        self.shared.enabled.load(Ordering::Acquire) && self.shared.accepting()
    }

    /// Change admission for all attached connections. Already submitted events still drain.
    /// Re-enabling records subsequent observations only; it does not recreate missed history
    /// or restart a closed or failed task.
    pub fn set_enabled(&self, enabled: bool) {
        if self.shared.enabled.swap(enabled, Ordering::AcqRel) != enabled {
            self.shared.generation.fetch_add(1, Ordering::AcqRel);
        }
    }

    /// Read admission counters and current storage use without waiting for output.
    /// Concurrent activity can change individual fields while this snapshot is read.
    pub fn stats(&self) -> RecorderStats {
        RecorderStats {
            submitted_events: self.shared.submitted.load(Ordering::Relaxed),
            dropped_events: self.shared.dropped.load(Ordering::Relaxed),
            oversized_events: self.shared.oversized.load(Ordering::Relaxed),
            queued_events: self.shared.events.load(Ordering::Relaxed),
            queued_bytes: self.shared.bytes.load(Ordering::Relaxed),
            history_events: self.shared.history_events.load(Ordering::Relaxed),
            history_bytes: self.shared.history_bytes.load(Ordering::Relaxed),
        }
    }

    /// The first published output or task failure, if any.
    /// Reading the error does not consume it or retry partially written records.
    pub fn error(&self) -> Option<io::Error> {
        self.shared.failure.lock().as_ref().map(Failure::error)
    }

    /// Wait until every event submitted before this command has been processed and output
    /// flushed. In history mode this retains events; use [`Self::dump_recent`] to write them.
    /// Also reports output initialization failure.
    pub async fn flush(&self) -> io::Result<()> {
        if self.state() == RecorderState::Failed {
            return Err(self.shared.unavailable());
        }
        if !self.shared.accepting() {
            return self.wait_done().await;
        }
        let (sender, receiver) = oneshot::channel();
        if self.sender.send(Command::Flush(sender)).await.is_ok()
            && let Ok(result) = receiver.await
        {
            return result;
        }
        if let Some(error) = self.error() {
            return Err(error);
        }
        self.wait_done().await
    }

    /// Close admission immediately, drain submitted events, finish and drop the destination.
    /// This waits asynchronously. Cancellation of the waiter does not cancel shutdown.
    /// Undumped history is discarded. All clones observe the same completion.
    pub async fn shutdown(&self) -> io::Result<()> {
        self.shared.drain();
        self.wait_done().await
    }

    async fn wait_done(&self) -> io::Result<()> {
        let mut receiver = self.shared.done.subscribe();
        loop {
            if let Some(result) = receiver.borrow_and_update().as_ref() {
                return result.as_ref().map(|_| ()).map_err(Failure::error);
            }
            receiver
                .changed()
                .await
                .map_err(|_channel_closed| self.shared.unavailable())?;
        }
    }

    pub(crate) fn connection(&self, group: ConnectionId) -> ConnectionQlogControl {
        ConnectionQlogControl {
            destination: Destination::Recorder(self.clone()),
            group,
            gate: Arc::new(Gate {
                enabled: AtomicBool::new(true),
                generation: AtomicU64::new(0),
            }),
        }
    }

    fn reserve(&self) -> Option<Reservation> {
        let shared = &self.shared;
        if !shared.enabled.load(Ordering::Acquire) {
            return None;
        }
        if !shared.accepting() {
            shared.dropped.fetch_add(1, Ordering::Relaxed);
            return None;
        }
        if shared
            .events
            .try_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                (count < shared.limits.max_queued_events).then(|| count + 1)
            })
            .is_err()
        {
            shared.dropped.fetch_add(1, Ordering::Relaxed);
            return None;
        }
        let bytes = shared.limits.max_event_bytes;
        if shared
            .bytes
            .try_update(Ordering::AcqRel, Ordering::Acquire, |used| {
                used.checked_add(bytes)
                    .filter(|total| *total <= shared.limits.max_queued_bytes)
            })
            .is_err()
        {
            shared.events.fetch_sub(1, Ordering::AcqRel);
            shared.dropped.fetch_add(1, Ordering::Relaxed);
            return None;
        }
        Some(Reservation {
            shared: shared.clone(),
            bytes,
        })
    }

    #[cfg(test)]
    pub(crate) fn emit<E: Into<EventFields>>(
        &self,
        group: ConnectionId,
        now: Instant,
        build: impl FnOnce() -> Option<E>,
    ) -> bool {
        self.emit_checked(group, now, || Ok(build().map(Into::into)))
    }

    fn emit_view<'a, E: Into<EventFieldsView<'a>>>(
        &self,
        group: ConnectionId,
        now: Instant,
        build: impl FnOnce() -> Option<E>,
    ) -> bool {
        self.emit_checked(group, now, || {
            let Some(fields) = build().map(Into::into) else {
                return Ok(None);
            };
            if std::mem::size_of::<QueuedEvent>().saturating_add(fields.owned_heap_size())
                > self.shared.limits.max_event_bytes
            {
                return Err(());
            }
            Ok(Some(fields.into_owned()))
        })
    }

    fn emit_checked(
        &self,
        group: ConnectionId,
        now: Instant,
        build: impl FnOnce() -> Result<Option<EventFields>, ()>,
    ) -> bool {
        self.enqueue(now, |_limit| {
            build()
                .map(|fields| {
                    fields.map(|fields| {
                        RecordedEvent::Typed(QlogEvent {
                            group_id: group,
                            time: now,
                            fields,
                        })
                    })
                })
                .map_err(|()| EncodeError::Oversized)
        })
    }

    fn enqueue(
        &self,
        now: Instant,
        build: impl FnOnce(usize) -> Result<Option<RecordedEvent>, EncodeError>,
    ) -> bool {
        let Some(mut reservation) = self.reserve() else {
            return false;
        };
        let Ok(permit) = self.sender.try_reserve() else {
            self.shared.dropped.fetch_add(1, Ordering::Relaxed);
            return false;
        };
        let limit = reservation.bytes - std::mem::size_of::<QueuedEvent>();
        let event = match build(limit) {
            Ok(Some(event)) => event,
            Ok(None) => return true,
            Err(error) => {
                if matches!(error, EncodeError::Oversized) {
                    self.shared.oversized.fetch_add(1, Ordering::Relaxed);
                }
                self.shared.dropped.fetch_add(1, Ordering::Relaxed);
                return false;
            }
        };
        let bytes = std::mem::size_of::<QueuedEvent>().saturating_add(event.heap_size());
        if bytes > reservation.bytes {
            self.shared.oversized.fetch_add(1, Ordering::Relaxed);
            self.shared.dropped.fetch_add(1, Ordering::Relaxed);
            return false;
        }
        self.shared
            .bytes
            .fetch_sub(reservation.bytes - bytes, Ordering::AcqRel);
        reservation.bytes = bytes;
        if !self.is_enabled() {
            self.shared.dropped.fetch_add(1, Ordering::Relaxed);
            return false;
        }
        let event = Box::new(QueuedEvent {
            event,
            observed: if self.shared.history {
                driver::now()
            } else {
                now
            },
            reservation,
        });
        permit.send(Command::Event(event));
        self.shared.submitted.fetch_add(1, Ordering::Relaxed);
        true
    }

    fn declares(&self, schema: &EventSchema) -> bool {
        self.shared
            .schemas
            .iter()
            .any(|declared| declared.id() == schema.id())
    }

    fn emit_named_with<T: Serialize>(
        &self,
        group: ConnectionId,
        schema: &'static EventSchema,
        name: &'static str,
        build: impl FnOnce() -> T,
    ) {
        if !self.declares(schema) {
            return;
        }
        // The driver's clock, so named events order with the QUIC events around them.
        let time = driver::now();
        self.enqueue(time, |limit| {
            let data = named::encode(schema, name, &build(), limit)?;
            Ok(Some(RecordedEvent::Named(NamedEvent {
                group_id: group,
                time,
                schema,
                name,
                data,
            })))
        });
    }

    #[cfg(test)]
    pub(crate) fn emit_event<E: Into<EventFields>>(
        &self,
        group: ConnectionId,
        event: E,
        now: Instant,
    ) {
        self.emit(group, now, || Some(event));
    }
}

impl QlogSink for QlogRecorder {
    fn is_enabled(&self) -> bool {
        Self::is_enabled(self)
    }

    fn generation(&self) -> u64 {
        self.shared.generation.load(Ordering::Acquire)
    }

    fn accepts_named(&self, schema: &EventSchema) -> bool {
        self.declares(schema)
    }

    fn emit_named(&self, event: &NamedQlogEventView<'_>) {
        if !self.is_enabled() || !self.declares(event.schema()) {
            return;
        }
        self.enqueue(event.time(), |limit| {
            if event.data().len() > limit {
                return Err(EncodeError::Oversized);
            }
            Ok(Some(RecordedEvent::Named(NamedEvent {
                group_id: event.group_id(),
                time: event.time(),
                schema: event.schema(),
                name: event.name(),
                data: event.data().into(),
            })))
        });
    }

    fn emit(&self, event: &QlogEventView<'_>) -> bool {
        self.emit_checked(event.group_id, event.time, || {
            if std::mem::size_of::<QueuedEvent>().saturating_add(event.fields.owned_heap_size())
                > self.shared.limits.max_event_bytes
            {
                return Err(());
            }
            Ok(Some(event.fields.to_owned()))
        })
    }
}

#[derive(Clone)]
enum Destination {
    Recorder(QlogRecorder),
    Sink(Arc<dyn QlogSink>),
}

impl Destination {
    fn is_enabled(&self) -> bool {
        match self {
            Self::Recorder(recorder) => recorder.is_enabled(),
            Self::Sink(sink) => sink.is_enabled(),
        }
    }
}

struct Gate {
    enabled: AtomicBool,
    generation: AtomicU64,
}

/// Recording controls obtained from [`crate::Connection::qlog_control`].
/// Clones share this connection's gate and retain its sink, never the QUIC connection.
/// Implements Rama's extension trait for propagation through request context.
#[derive(Clone)]
pub struct ConnectionQlogControl {
    destination: Destination,
    group: ConnectionId,
    gate: Arc<Gate>,
}

impl std::fmt::Debug for ConnectionQlogControl {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConnectionQlogControl")
            .field("group", &self.group)
            .field("enabled", &self.is_enabled())
            .finish()
    }
}

impl rama_core::extensions::Extension for ConnectionQlogControl {}

impl ConnectionQlogControl {
    /// Stable event group identifier, matching the connection's `trace_id()`.
    pub fn group_id(&self) -> ConnectionId {
        self.group
    }

    /// The recorder configured directly through `qlog_recorder` or `qlog`.
    /// Returns `None` for custom or composed sinks; retain their recorder handles separately.
    pub fn recorder(&self) -> Option<&QlogRecorder> {
        match &self.destination {
            Destination::Recorder(recorder) => Some(recorder),
            Destination::Sink(_) => None,
        }
    }

    /// Whether both this connection's gate and its configured sink are enabled.
    /// Queue capacity can still cause individual observations to be rejected.
    pub fn is_enabled(&self) -> bool {
        self.gate.enabled.load(Ordering::Acquire) && self.destination.is_enabled()
    }

    pub(crate) fn from_sink(sink: Arc<dyn QlogSink>, group: ConnectionId) -> Self {
        Self {
            destination: Destination::Sink(sink),
            group,
            gate: Arc::new(Gate {
                enabled: AtomicBool::new(true),
                generation: AtomicU64::new(0),
            }),
        }
    }

    pub(crate) fn for_connection(&self, group: ConnectionId) -> Self {
        Self {
            destination: self.destination.clone(),
            group,
            gate: Arc::new(Gate {
                enabled: AtomicBool::new(true),
                generation: AtomicU64::new(0),
            }),
        }
    }

    /// Toggle only this connection; enabling it does not override a disabled sink.
    /// Previously submitted observations still drain, and retained history stays available.
    pub fn set_enabled(&self, enabled: bool) {
        if self.gate.enabled.swap(enabled, Ordering::AcqRel) != enabled {
            self.gate.generation.fetch_add(1, Ordering::AcqRel);
        }
    }

    /// Consume this connection's recent history and flush it to the configured destination.
    /// The request is ordered with submitted events. Concurrent triggers are serialized;
    /// a cancelled waiter does not retract a command already submitted to the worker.
    /// Requires a directly configured recorder with history enabled.
    pub async fn dump_recent(&self) -> io::Result<()> {
        let recorder = self.recorder().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::Unsupported,
                "use the custom sink's recording controls",
            )
        })?;
        recorder.dump_recent(self.group).await
    }

    pub(crate) fn generation(&self) -> (u64, u64) {
        (
            match &self.destination {
                Destination::Recorder(recorder) => QlogSink::generation(recorder),
                Destination::Sink(sink) => sink.generation(),
            },
            self.gate.generation.load(Ordering::Acquire),
        )
    }

    /// Record an event of a schema declared through [`QlogConfig::with_event_schemas`].
    /// `build` runs only while recording is enabled; failures never affect the connection.
    /// The event timestamp is taken here, when emitted, from the clock QUIC events use.
    pub fn emit_named<T: Serialize>(
        &self,
        schema: &'static EventSchema,
        name: &'static str,
        build: impl FnOnce() -> T,
    ) {
        if !self.is_enabled() {
            return;
        }
        match &self.destination {
            Destination::Recorder(recorder) => {
                recorder.emit_named_with(self.group, schema, name, build);
            }
            Destination::Sink(sink) => {
                if !sink.accepts_named(schema) {
                    return;
                }
                let time = driver::now();
                let Ok(data) = named::encode(schema, name, &build(), named::MAX_DATA_BYTES) else {
                    return;
                };
                sink.emit_named(&NamedQlogEventView {
                    group_id: self.group,
                    time,
                    schema,
                    name,
                    data: &data,
                });
            }
        }
    }

    pub(crate) fn emit<'a, E: Into<EventFieldsView<'a>>>(
        &self,
        group: ConnectionId,
        now: Instant,
        build: impl FnOnce() -> Option<E>,
    ) -> bool {
        if !self.is_enabled() {
            return false;
        }
        match &self.destination {
            Destination::Recorder(recorder) => recorder.emit_view(group, now, build),
            Destination::Sink(sink) => {
                let Some(fields) = build() else {
                    return true;
                };
                sink.emit(&QlogEventView {
                    group_id: group,
                    time: now,
                    fields: fields.into(),
                })
            }
        }
    }
}

impl QlogRecorder {
    /// Write, consume and flush retained observations for the given connection group.
    /// Use the connection's `trace_id()` when retaining a recorder inside composed sinks.
    /// Requires history recording; the request is ordered after previously submitted events.
    /// Cancelling the waiter does not retract a command already submitted to the task.
    pub async fn dump_recent(&self, group: ConnectionId) -> io::Result<()> {
        if !self.shared.history {
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "qlog history is not configured",
            ));
        }
        if !self.shared.accepting() {
            return Err(self.shared.unavailable());
        }
        let (sender, receiver) = oneshot::channel();
        self.sender
            .send(Command::Dump(group, sender))
            .await
            .map_err(|_closed| self.shared.unavailable())?;
        receiver
            .await
            .map_err(|_closed| self.shared.unavailable())?
    }
}

struct Retained {
    event: RecordedEvent,
    observed: Instant,
    bytes: usize,
}

impl Retained {
    fn storage_size() -> usize {
        std::mem::size_of::<Self>() + 2 * std::mem::size_of::<usize>()
    }
}

#[expect(
    clippy::linkedlist,
    reason = "node storage is accounted and released per retained event, without spare container capacity"
)]
struct History {
    config: HistoryConfig,
    events: LinkedList<Retained>,
    bytes: usize,
}

impl History {
    fn new(config: HistoryConfig) -> Self {
        Self {
            config,
            events: LinkedList::new(),
            bytes: 0,
        }
    }

    fn within_window(&self, observed: Instant, now: Instant) -> bool {
        now.saturating_duration_since(observed) < self.config.window
    }

    fn expire(&mut self, now: Instant) {
        while self
            .events
            .front()
            .is_some_and(|event| !self.within_window(event.observed, now))
            && let Some(event) = self.events.pop_front()
        {
            self.bytes -= event.bytes;
        }
    }

    fn push(&mut self, event: impl Into<RecordedEvent>, observed: Instant) {
        let event = event.into();
        let bytes = Retained::storage_size().saturating_add(event.heap_size());
        if bytes > self.config.max_bytes {
            return;
        }
        while self.bytes > self.config.max_bytes - bytes
            && let Some(old) = self.events.pop_front()
        {
            if old.observed > observed {
                self.events.push_front(old);
                return;
            }
            self.bytes -= old.bytes;
        }
        self.bytes += bytes;
        let entry = Retained {
            event,
            observed,
            bytes,
        };
        if self
            .events
            .back()
            .is_none_or(|last| last.observed <= observed)
        {
            self.events.push_back(entry);
        } else {
            // Concurrent emitters can enqueue in a different order from admission.
            let index = self
                .events
                .iter()
                .position(|entry| entry.observed > observed)
                .unwrap_or(self.events.len());
            let mut later = self.events.split_off(index);
            self.events.push_back(entry);
            self.events.append(&mut later);
        }
    }

    async fn dump(&mut self, group: ConnectionId, output: &mut impl QlogOutput) -> io::Result<()> {
        let mut pending = std::mem::take(&mut self.events);
        while let Some(first) = pending.front() {
            tokio::task::consume_budget().await;
            if first.event.group_id() == group
                && let Some(entry) = pending.pop_front()
            {
                self.bytes -= entry.bytes;
                if let Err(error) = entry.event.write(output).await {
                    self.events.append(&mut pending);
                    return Err(error);
                }
            } else {
                // Preserve unmatched nodes without freeing and reallocating them.
                let rest = pending.split_off(1);
                self.events.append(&mut pending);
                pending = rest;
            }
        }
        output.flush().await
    }

    fn stats(&self, shared: &Shared) {
        shared
            .history_events
            .store(self.events.len(), Ordering::Relaxed);
        shared.history_bytes.store(self.bytes, Ordering::Relaxed);
    }
}

async fn output_call(
    shared: &Shared,
    context: &'static str,
    operation: impl Future<Output = io::Result<()>>,
) -> io::Result<()> {
    AssertUnwindSafe(operation)
        .catch_unwind()
        .await
        .unwrap_or_else(|_| Err(io::Error::other("qlog output panicked")))
        .map_err(|error| {
            shared
                .fail(io::Error::new(error.kind(), error.context(context)))
                .error()
        })
}

async fn run(
    receiver: &mut mpsc::Receiver<Command>,
    output: &mut impl QlogOutput,
    info: &TraceInfo,
    history: Option<HistoryConfig>,
    shared: &Shared,
) -> io::Result<()> {
    output_call(shared, "qlog output initialization failed", async {
        output.begin(info).await
    })
    .await?;
    let _previous_state = shared.state.compare_exchange(
        RecorderState::Starting as u8,
        RecorderState::Ready as u8,
        Ordering::AcqRel,
        Ordering::Acquire,
    );
    let mut history = history.map(History::new);
    loop {
        // Immediate outputs and history retention must still cooperate with the executor.
        tokio::task::consume_budget().await;
        if !shared.accepting() {
            receiver.close();
        }
        if let Some(history) = &mut history {
            history.expire(driver::now());
            history.stats(shared);
        }
        let command = match receiver.try_recv() {
            Ok(command) => Some(command),
            Err(mpsc::error::TryRecvError::Disconnected) => break,
            Err(mpsc::error::TryRecvError::Empty) => {
                let expiry = history.as_ref().and_then(|history| {
                    history
                        .events
                        .front()
                        .and_then(|event| event.observed.checked_add(history.config.window))
                });
                let result = async {
                    tokio::select! {
                        command = receiver.recv() => Some(command),
                        _ = shared.stop.notified() => None,
                        _ = async {
                            if let Some(expiry) = expiry { tokio::time::sleep_until(expiry.into()).await; }
                            else { std::future::pending::<()>().await; }
                        } => None,
                    }
                }.await;
                let Some(command) = result else {
                    continue;
                };
                command
            }
        };
        let Some(command) = command else {
            break;
        };
        match command {
            Command::Event(queued) => {
                let QueuedEvent {
                    event,
                    observed,
                    reservation,
                } = *queued;
                if let Some(history) = &mut history {
                    let now = driver::now();
                    if history.within_window(observed, now) {
                        history.push(event, observed);
                    }
                    history.stats(shared);
                } else {
                    output_call(shared, "qlog event output failed", async {
                        event.write(output).await
                    })
                    .await?;
                }
                drop(reservation);
            }
            Command::Flush(reply) => {
                let result = output_call(shared, "qlog output flush failed", async {
                    output.flush().await
                })
                .await;
                let failed = result.is_err();
                drop(reply.send(result));
                if failed {
                    return Err(shared.unavailable());
                }
            }
            Command::Dump(group, reply) => {
                let result = if let Some(history) = &mut history {
                    history.expire(driver::now());
                    let result = output_call(
                        shared,
                        "qlog history dump failed",
                        history.dump(group, output),
                    )
                    .await;
                    history.stats(shared);
                    result
                } else {
                    Err(io::Error::new(
                        io::ErrorKind::Unsupported,
                        "qlog history is not configured",
                    ))
                };
                let result = result.map_err(|error| shared.fail(error).error());
                let failed = result.is_err();
                drop(reply.send(result));
                if failed {
                    return Err(shared.unavailable());
                }
            }
        }
    }
    output_call(shared, "qlog output finish failed", async {
        output.finish().await
    })
    .await
}

pin_project_lite::pin_project! {
    struct RecordingTask<F> {
        #[pin]
        future: F,
        shared: Arc<Shared>,
    }

    impl<F> PinnedDrop for RecordingTask<F> {
        fn drop(this: Pin<&mut Self>) {
            let this = this.project();
            let unfinished = this.shared.done.borrow().is_none();
            if unfinished {
                // Publish cancellation before the operation drops its replies or output futures.
                this.shared.fail(io::Error::new(io::ErrorKind::Interrupted, "qlog recording task was cancelled"));
                this.shared.history_events.store(0, Ordering::Relaxed);
                this.shared.history_bytes.store(0, Ordering::Relaxed);
                let failure = this.shared.failure.lock().as_ref().cloned();
                if let Some(failure) = failure { this.shared.done.send_replace(Some(Err(failure))); }
            }
        }
    }
}

impl<F: Future> Future for RecordingTask<F> {
    type Output = F::Output;

    fn poll(
        self: std::pin::Pin<&mut Self>,
        context: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Self::Output> {
        self.project().future.poll(context)
    }
}

/// Erase output types once when starting a worker; each event uses the concrete async output.
pub(super) trait OutputFactory: Send {
    fn spawn(self: Box<Self>, worker: Worker);
}

pub(super) struct Worker {
    receiver: mpsc::Receiver<Command>,
    shared: Arc<Shared>,
    info: TraceInfo,
    history: Option<HistoryConfig>,
    executor: rama_core::rt::Executor,
}

impl<O: QlogOutput> OutputFactory for O {
    fn spawn(self: Box<Self>, mut worker: Worker) {
        let executor = std::mem::take(&mut worker.executor);
        let graceful = executor.guard().cloned();
        let shared = worker.shared.clone();
        let future = async move {
            let mut output = self;
            let result = {
                let operation = AssertUnwindSafe(run(
                    &mut worker.receiver,
                    &mut *output,
                    &worker.info,
                    worker.history,
                    &worker.shared,
                ))
                .catch_unwind();
                let mut operation = std::pin::pin!(operation);
                if let Some(guard) = graceful {
                    tokio::select! {
                        result = &mut operation => result,
                        _ = guard.cancelled() => {
                            worker.shared.drain();
                            operation.await
                        },
                    }
                } else {
                    operation.await
                }
            };
            let result =
                result.unwrap_or_else(|_| Err(io::Error::other("qlog recording task panicked")));
            let result = result.map_err(|error| worker.shared.fail(error));
            worker.shared.history_events.store(0, Ordering::Relaxed);
            worker.shared.history_bytes.store(0, Ordering::Relaxed);
            worker.receiver.close();
            while let Ok(command) = worker.receiver.try_recv() {
                drop(command);
            }
            drop(worker.receiver);
            let dropped = catch_unwind(AssertUnwindSafe(|| drop(output)));
            let result = if dropped.is_err() && result.is_ok() {
                Err(worker
                    .shared
                    .fail(io::Error::other("qlog output destructor panicked")))
            } else {
                result
            };
            if result.is_ok() {
                worker
                    .shared
                    .state
                    .store(RecorderState::Closed as u8, Ordering::Release);
            }
            worker.shared.done.send_replace(Some(result));
        };
        executor.spawn_task(RecordingTask { future, shared });
    }
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod benches;
