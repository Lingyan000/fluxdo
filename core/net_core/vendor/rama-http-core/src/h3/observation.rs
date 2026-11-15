//! Opt-in observation with immutable, budgeted request snapshots.

use super::{connection::Shared, frame::FrameEvent};
use rama_core::extensions::Extension;
use rama_http_types::proto::h3::{
    Code, FrameHeader, Settings, StreamType,
    observation::{
        H3ObservationSnapshot, ObservationCompleteness, ObservationLimits, ObservedControlFrame,
        ObservedEncoderBindings, ObservedEncoderInstruction, ObservedInsertionBinding,
        ObservedSetting, ObservedUniStream,
    },
};
use std::{
    fmt,
    sync::{Arc, OnceLock, Weak},
};
use tokio::time::Instant;

/// Connection observer attached to captured HTTP/3 requests.
#[derive(Clone)]
pub struct H3Observer {
    shared: Weak<Shared>,
    unavailable: Arc<H3ObservationSnapshot>,
}
impl Extension for H3Observer {}
impl fmt::Debug for H3Observer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("H3Observer").finish_non_exhaustive()
    }
}

/// A SETTINGS wait always reports its termination condition separately from its data.
#[derive(Debug, Clone)]
pub enum SettingsObservation {
    Received(Arc<H3ObservationSnapshot>),
    TimedOut(Arc<H3ObservationSnapshot>),
    Closed {
        snapshot: Arc<H3ObservationSnapshot>,
        error: Option<Code>,
    },
}

/// Publication of the native first-request boundary, separate from completeness.
#[derive(Debug, Clone)]
pub enum FirstRequestObservation {
    /// Frozen native publication; completeness and connection errors remain explicit.
    Ready(Arc<H3ObservationSnapshot>),
    /// Live fallback at this consumer's deadline; it may be incomplete.
    TimedOut(Arc<H3ObservationSnapshot>),
    /// Best available fallback after closure or loss of the observer's owner; it may be incomplete.
    Closed {
        snapshot: Arc<H3ObservationSnapshot>,
        error: Option<Code>,
    },
}

impl H3Observer {
    pub(crate) fn new(shared: &Arc<Shared>, unavailable: Arc<H3ObservationSnapshot>) -> Self {
        Self {
            shared: Arc::downgrade(shared),
            unavailable,
        }
    }

    /// Return immediately; old snapshots never change as later frames arrive.
    #[must_use]
    pub fn snapshot(&self) -> Arc<H3ObservationSnapshot> {
        self.shared
            .upgrade()
            .and_then(|s| s.observation_snapshot())
            .unwrap_or_else(|| self.unavailable.clone())
    }

    /// Wait for the native first-request observation to be published.
    /// Stream/control facts follow native processing, not packet chronology;
    /// QPACK instructions stop at the first decoded head. Completeness remains
    /// explicit. Optional peer streams and ordinary request delivery never wait.
    pub async fn first_request(&self, deadline: Instant) -> FirstRequestObservation {
        match self.shared.upgrade() {
            Some(shared) => {
                shared
                    .observation_first_request(deadline, &self.unavailable)
                    .await
            }
            None => FirstRequestObservation::Closed {
                snapshot: self.unavailable.clone(),
                error: None,
            },
        }
    }

    /// Wait for SETTINGS and the available CONTROL chunk, up to this consumer's deadline.
    /// Ordinary requests do not wait for observation.
    pub async fn settings(&self, deadline: Instant) -> SettingsObservation {
        match self.shared.upgrade() {
            Some(shared) => {
                shared
                    .observation_settings(deadline, &self.unavailable)
                    .await
            }
            None => SettingsObservation::Closed {
                snapshot: self.unavailable.clone(),
                error: None,
            },
        }
    }
}

/// QPACK evidence stops when the first decoded request head is delivered.
#[derive(Debug, Clone, Copy)]
pub(super) struct RequestQpackPrefix {
    pub(super) instruction_count: usize,
    pub(super) complete: bool,
    pub(super) bindings_complete: bool,
}

pub(super) struct Recorder {
    limits: ObservationLimits,
    bytes: usize,
    value: H3ObservationSnapshot,
    pending: Option<FrameHeader>,
    current: Option<Arc<H3ObservationSnapshot>>,
    pub(super) first_request: Arc<OnceLock<Arc<H3ObservationSnapshot>>>,
    pub(super) request_qpack: Option<RequestQpackPrefix>,
    // A ready control-stream chunk must be decoded before publishing its prefix.
    pub(super) control_batch_active: bool,
    live: Vec<Weak<H3ObservationSnapshot>>,
    pub(super) unavailable: Arc<H3ObservationSnapshot>,
}

impl Recorder {
    pub(super) fn new(limits: ObservationLimits, local: &Settings) -> Self {
        let mut this = Self {
            limits,
            bytes: 0,
            value: H3ObservationSnapshot {
                completeness: ObservationCompleteness {
                    settings: false,
                    local_settings: true,
                    streams: true,
                    control: true,
                    qpack: true,
                    fields: true,
                    snapshot: true,
                },
                ..H3ObservationSnapshot::default()
            },
            pending: None,
            current: None,
            first_request: Arc::new(OnceLock::new()),
            request_qpack: None,
            control_batch_active: false,
            live: Vec::new(),
            unavailable: Arc::new(H3ObservationSnapshot::default()),
        };
        let bytes = local
            .entries()
            .len()
            .saturating_mul(size_of::<ObservedSetting>());
        if this.reserve(bytes) {
            this.value.local_settings = settings(local);
        } else {
            this.value.completeness.local_settings = false;
        }
        this
    }

    fn reserve(&mut self, bytes: usize) -> bool {
        if bytes > self.limits.bytes.saturating_sub(self.bytes) {
            return false;
        }
        self.bytes += bytes;
        true
    }

    pub(super) fn changed(&mut self) {
        self.value.revision = self.value.revision.saturating_add(1);
    }

    pub(super) fn stream(&mut self, stream_id: u64, ty: StreamType) {
        if self.value.streams.len() >= self.limits.streams
            || !self.reserve(size_of::<ObservedUniStream>())
        {
            if self.value.completeness.streams {
                self.value.completeness.streams = false;
                self.changed();
            }
            return;
        }
        self.changed();
        self.value.streams.push(ObservedUniStream {
            sequence: self.value.revision,
            stream_id,
            stream_type: ty.value(),
            grease: ty.is_reserved(),
        });
    }

    pub(super) fn control(&mut self, event: &FrameEvent) {
        if let FrameEvent::Header(header) = event {
            self.pending = Some(*header);
            return;
        }
        let Some(header) = self.pending.take() else {
            return;
        };
        let (element_id, value) = match event {
            FrameEvent::CancelPush(id) | FrameEvent::GoAway(id) | FrameEvent::MaxPushId(id) => {
                (Some(*id), &[][..])
            }
            FrameEvent::PriorityUpdate {
                element_id,
                field_value,
                ..
            } => (Some(*element_id), &field_value[..]),
            FrameEvent::Ignored {
                payload: Some(payload),
                ..
            } => (None, &payload[..]),
            _ => (None, &[][..]),
        };
        if matches!(event, FrameEvent::Ignored { ty, len, payload: None } if ty.is_reserved() && *len != 0)
            && self.value.completeness.control
        {
            self.value.completeness.control = false;
            self.changed();
        }
        if let FrameEvent::Settings(peer) = event {
            self.value.settings_received = true;
            self.changed();
            let charge = peer
                .entries()
                .len()
                .saturating_mul(size_of::<ObservedSetting>());
            if self.reserve(charge) {
                self.value.settings = Some(settings(peer));
                self.value.completeness.settings = true;
            }
        }
        if self.value.control.len() >= self.limits.events
            || !self.reserve(size_of::<ObservedControlFrame>().saturating_add(value.len()))
        {
            if self.value.completeness.control {
                self.value.completeness.control = false;
                self.changed();
            }
            return;
        }
        self.changed();
        self.value.control.push(ObservedControlFrame {
            sequence: self.value.revision,
            frame_type: header.ty.value(),
            length: header.len,
            element_id,
            value: value.into(),
        });
    }

    pub(super) fn control_payload_budget(&self) -> usize {
        if self.value.completeness.control {
            self.limits
                .bytes
                .saturating_sub(self.bytes.saturating_add(size_of::<ObservedControlFrame>()))
        } else {
            0
        }
    }

    pub(super) fn snapshot(
        &mut self,
        instructions: Option<(&[ObservedEncoderInstruction], bool)>,
        bindings: Option<&ObservedEncoderBindings>,
        error: Option<Code>,
    ) -> Arc<H3ObservationSnapshot> {
        self.make_snapshot(
            instructions,
            bindings.map(|bindings| (bindings, bindings.complete)),
            error,
            true,
        )
    }

    pub(super) fn request_snapshot(
        &mut self,
        instructions: Option<(&[ObservedEncoderInstruction], bool)>,
        bindings: Option<(&ObservedEncoderBindings, bool)>,
        error: Option<Code>,
    ) -> Arc<H3ObservationSnapshot> {
        // A live snapshot at this revision may contain later QPACK instructions.
        // A frozen prefix must neither reuse nor replace that live cache.
        self.make_snapshot(instructions, bindings, error, false)
    }

    fn make_snapshot(
        &mut self,
        instructions: Option<(&[ObservedEncoderInstruction], bool)>,
        bindings: Option<(&ObservedEncoderBindings, bool)>,
        error: Option<Code>,
        cache: bool,
    ) -> Arc<H3ObservationSnapshot> {
        if cache
            && let Some(current) = &self.current
            && current.revision == self.value.revision
            && current.connection_error == error.map(Code::value)
        {
            return current.clone();
        }
        if cache {
            self.current = None;
        }
        self.live.retain(|snapshot| snapshot.strong_count() > 0);
        if self.live.len() >= self.limits.retained_snapshots {
            return self.unavailable.clone();
        }
        let mut value = self.value.clone();
        value.connection_error = error.map(Code::value);
        if let Some((instructions, complete)) = instructions {
            let available = self.limits.bytes.saturating_sub(self.bytes)
                / size_of::<ObservedEncoderInstruction>();
            let retained = instructions.len().min(available);
            value.encoder_instructions = instructions[..retained].to_vec();
            value.completeness.qpack = complete && retained == instructions.len();
            let available = self
                .limits
                .bytes
                .saturating_sub(self.bytes + retained * size_of::<ObservedEncoderInstruction>());
            if let Some((bindings, complete)) = bindings {
                let count = available.saturating_sub(size_of::<ObservedEncoderBindings>())
                    / size_of::<ObservedInsertionBinding>();
                if available >= size_of::<ObservedEncoderBindings>() {
                    value.encoder_bindings = Some(ObservedEncoderBindings {
                        stream_id: bindings.stream_id,
                        insertions: bindings.insertions[..bindings.insertions.len().min(count)]
                            .to_vec(),
                        complete: complete && count >= bindings.insertions.len(),
                    });
                }
            }
        }
        let snapshot = Arc::new(value);
        self.live.push(Arc::downgrade(&snapshot));
        if cache {
            self.current = Some(snapshot.clone());
        }
        snapshot
    }
}

fn settings(value: &Settings) -> Vec<ObservedSetting> {
    value
        .entries()
        .iter()
        .map(|setting| ObservedSetting {
            id: setting.id.value(),
            value: setting.value,
            grease: setting.id.is_reserved(),
        })
        .collect()
}
