use super::{EncodedWriter, EventSchema, JsonSeqEncoder, QlogOutput, QlogRecorder, TraceInfo};
use crate::driver;
use rama_core::error_sink::{ErrorSink, TracingErrorSink};
use rama_utils::{octets, str::arcstr::ArcStr};
use std::{
    io,
    sync::Arc,
    time::{Duration, Instant},
};

/// Admission limits for owned events, including the event currently being processed.
/// Byte accounting covers event storage and owned field capacities, not allocator overhead.
#[derive(Debug, Clone, Copy)]
pub struct QueueLimits {
    /// Maximum pending and currently processed events. Full admission drops the incoming event.
    pub max_queued_events: usize,
    /// Maximum retained event bytes across pending and currently processed events.
    pub max_queued_bytes: usize,
    /// Reserved before constructing an event, then reduced to its actual retained size.
    /// Oversized observations are discarded; construction can temporarily exceed this limit.
    pub max_event_bytes: usize,
}

impl Default for QueueLimits {
    fn default() -> Self {
        Self {
            max_queued_events: 4096,
            max_queued_bytes: octets::mib(8),
            max_event_bytes: octets::kib(64),
        }
    }
}

/// A rolling history shared by all connections on this recorder.
/// Age is measured from admission using a monotonic clock; original event timestamps
/// are preserved. Queue wait counts toward the window. Node storage and retained field
/// capacities fit `max_bytes` (allocator bookkeeping excluded).
/// No events are written until explicitly dumped.
#[derive(Debug, Clone, Copy)]
pub struct HistoryConfig {
    /// Retention duration measured from admission.
    pub window: Duration,
    /// Maximum retained history storage across all connections.
    pub max_bytes: usize,
}

/// Configure a worker and destination. The default has no destination and records nothing.
/// Built-in output uses qlog main draft 14 / QUIC events draft 13 JSON text sequences.
/// See [qlog](crate::qlog) for specification links and reader compatibility.
/// Supply an output for custom storage, or an `EncodedWriter` for a custom serializer.
pub struct QlogConfig {
    pub(super) output: Option<Box<dyn super::recorder::OutputFactory>>,
    pub(super) info: TraceInfo,
    pub(super) limits: QueueLimits,
    pub(super) history: Option<HistoryConfig>,
    pub(super) enabled: bool,
    pub(super) executor: rama_core::rt::Executor,
    pub(super) error_sink: Arc<dyn ErrorSink>,
}

impl QlogConfig {
    rama_utils::macros::generate_set_and_with! {
        /// Event schemas recorded in addition to QUIC, such as HTTP/3; events of other
        /// schemas are not recorded. Schemas must be unique, else `start` fails.
        pub fn event_schemas(mut self, schemas: &'static [EventSchema]) -> Self {
            self.info.event_schemas = schemas;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Asynchronous destination for JSON text sequences, buffered with an 8 KiB buffer.
        /// Flush and shutdown drain the buffer. Use `output` with an [`EncodedWriter`] to
        /// control buffering explicitly or use a custom encoder.
        pub fn writer(mut self, writer: impl tokio::io::AsyncWrite + Unpin + Send + 'static) -> Self {
            self.output = Some(Box::new(EncodedWriter::new(
                tokio::io::BufWriter::with_capacity(
                    octets::kib(8),
                    super::output::RetryInterrupted::new(writer),
                ),
                JsonSeqEncoder,
            )));
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Custom asynchronous output, owned and invoked by the recording task.
        pub fn output(mut self, output: impl QlogOutput) -> Self {
            self.output = Some(Box::new(output));
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Trace label. Use Rama’s `arcstr!` for allocation-free static text.
        pub fn title(mut self, title: Option<ArcStr>) -> Self {
            self.info.title = title;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Optional trace context. Runtime text converts into shared `ArcStr` storage.
        pub fn description(mut self, description: Option<ArcStr>) -> Self {
            self.info.description = description;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Monotonic reference point for event timestamps.
        pub fn start_time(mut self, start_time: Instant) -> Self {
            self.info.start_time = start_time;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Configure bounded admission. Invalid limits are rejected by `start`.
        pub fn queue_limits(mut self, limits: QueueLimits) -> Self {
            self.limits = limits;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Retain recent history instead of writing each observation immediately.
        pub fn history(mut self, history: Option<HistoryConfig>) -> Self {
            self.history = history;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Initial recording gate. A disabled recorder still initializes its destination.
        pub fn enabled(mut self, enabled: bool) -> Self {
            self.enabled = enabled;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Executor for the recording task. A graceful executor closes admission on shutdown,
        /// then waits for accepted events and output finalization, including writer shutdown.
        pub fn executor(mut self, executor: rama_core::rt::Executor) -> Self {
            self.executor = executor;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Observe the first terminal output or recording-task failure, including graceful
        /// shutdown and runtime cancellation. Defaults to [`TracingErrorSink::default`].
        /// The sink receives a [`rama_core::error::BoxError`] retaining the original cause.
        /// It runs outside recorder locks and must return promptly; offload slow work.
        /// Sink panics are isolated. Explicit flush and shutdown still return the failure.
        pub fn error_sink(mut self, error_sink: impl ErrorSink) -> Self {
            self.error_sink = Arc::new(error_sink);
            self
        }
    }

    /// Start a task on the current Rama/Tokio runtime. Await `flush` to observe destination
    /// initialization. Submitting observations afterwards requires no runtime on the caller.
    pub fn start(self) -> io::Result<QlogRecorder> {
        QlogRecorder::start(self)
    }
}

impl Default for QlogConfig {
    fn default() -> Self {
        Self {
            output: None,
            info: TraceInfo {
                event_schemas: &[],
                title: None,
                description: None,
                start_time: driver::now(),
            },
            limits: QueueLimits::default(),
            history: None,
            enabled: true,
            executor: rama_core::rt::Executor::new(),
            error_sink: Arc::new(TracingErrorSink::default()),
        }
    }
}
