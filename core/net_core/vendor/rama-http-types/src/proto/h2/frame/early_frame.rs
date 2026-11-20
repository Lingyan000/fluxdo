use crate::proto::h2::frame::{Frame, Priority, Settings, StreamId, WindowUpdate};
use rama_core::extensions::Extension;
use rama_core::telemetry::tracing;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

#[derive(Debug, Clone, Eq, PartialEq, Serialize, Deserialize)]
/// A [`Frame`] which is sent often early before any data
pub enum EarlyFrame {
    Priority(Priority),
    Settings(Settings),
    WindowUpdate(WindowUpdate),
}

impl EarlyFrame {
    /// returns true if this early frame applies to a stream already created
    #[must_use]
    pub fn stream_created(&self, next_stream_id: StreamId) -> bool {
        match self {
            Self::Priority(priority) => next_stream_id > priority.stream_id,
            Self::Settings(_) => true,
            Self::WindowUpdate(window_update) => next_stream_id > window_update.stream_id,
        }
    }
}

impl<T> From<EarlyFrame> for Frame<T> {
    fn from(value: EarlyFrame) -> Self {
        match value {
            EarlyFrame::Priority(priority) => Self::Priority(priority),
            EarlyFrame::Settings(settings) => Self::Settings(settings),
            EarlyFrame::WindowUpdate(window_update) => Self::WindowUpdate(window_update),
        }
    }
}

#[derive(Debug, Clone)]
pub struct EarlyFrameStreamContext {
    kind: EarlyFrameKind,
}

impl EarlyFrameStreamContext {
    #[must_use]
    pub fn new_nop() -> Self {
        Self {
            kind: EarlyFrameKind::Nop,
        }
    }

    #[must_use]
    pub fn new_recorder() -> Self {
        Self {
            kind: EarlyFrameKind::Recorder(EarlyFrameRecorder {
                recording: Some(Vec::with_capacity(8)),
                frozen: None,
                truncated: false,
            }),
        }
    }

    /// Replay `frames`, the client's captured start of a connection.
    ///
    /// A captured stream WINDOW_UPDATE follows the HEADERS of the first request, and browsers
    /// that send one raise every stream's window that way. It is replayed as that policy: the
    /// same increment right after the HEADERS of each new stream, starting from the captured
    /// stream, rather than once for a stream ID the replaying client may never open.
    #[must_use]
    pub fn new_replayer(mut frames: Vec<EarlyFrame>) -> (Self, Option<Settings>) {
        let stream_window = frames.iter().find_map(|frame| match frame {
            EarlyFrame::WindowUpdate(update)
                if !update.stream_id.is_zero() && update.stream_id.is_client_initiated() =>
            {
                Some(StreamWindow {
                    first_stream: update.stream_id,
                    increment: update.size_increment,
                })
            }
            _ => None,
        });
        frames.retain(|frame| {
            !matches!(frame, EarlyFrame::WindowUpdate(update) if !update.stream_id.is_zero())
        });
        frames.reverse();
        let settings = match frames.pop() {
            Some(frame) => match frame {
                EarlyFrame::Settings(settings) => Some(settings),
                EarlyFrame::Priority(_) | EarlyFrame::WindowUpdate(_) => {
                    frames.push(frame);
                    None
                }
            },
            None if stream_window.is_none() => {
                return (
                    Self {
                        kind: EarlyFrameKind::Nop,
                    },
                    None,
                );
            }
            None => None,
        };
        (
            Self {
                kind: EarlyFrameKind::Replayer {
                    frames,
                    connection_window_replayed: false,
                    stream_window,
                },
            },
            settings,
        )
    }

    /// The stream a replayed connection opens first: the one its capture opened first, when
    /// the capture shows it.
    #[must_use]
    pub fn first_stream_id(&self) -> Option<StreamId> {
        match &self.kind {
            EarlyFrameKind::Replayer {
                stream_window: Some(window),
                ..
            } => Some(window.first_stream),
            _ => None,
        }
    }

    /// The window increment a replaying client sends right after each new stream's HEADERS.
    #[must_use]
    pub fn stream_window_increment(&self) -> Option<u32> {
        match &self.kind {
            EarlyFrameKind::Replayer {
                stream_window: Some(window),
                ..
            } => Some(window.increment),
            _ => None,
        }
    }
}

impl EarlyFrameStreamContext {
    /// Returns whether the next replay frame can be consumed for the current
    /// stream state.
    ///
    /// Callers that need codec capacity before consuming a replay frame can
    /// use this to avoid waiting on write readiness when there is no frame to
    /// replay. The actual replay still goes through [`Self::replay_next_frame`].
    #[must_use]
    pub fn can_replay_next_frame(&self, next_stream_id: Option<StreamId>) -> bool {
        let EarlyFrameKind::Replayer { frames, .. } = &self.kind else {
            return false;
        };

        let Some(frame) = frames.last() else {
            return false;
        };

        next_stream_id.is_none_or(|next_stream_id| frame.stream_created(next_stream_id))
    }

    /// Returns whether the next replay frame is a non-ACK SETTINGS frame.
    #[must_use]
    pub fn next_frame_is_settings(&self) -> bool {
        matches!(
            &self.kind,
            EarlyFrameKind::Replayer { frames, .. }
                if matches!(
                    frames.last(),
                    Some(EarlyFrame::Settings(settings)) if !settings.flags.is_ack()
                )
        )
    }

    /// Returns whether another captured frame remains to be replayed.
    #[must_use]
    pub fn has_replay_frame(&self) -> bool {
        matches!(&self.kind, EarlyFrameKind::Replayer { frames, .. } if !frames.is_empty())
    }

    /// Whether a connection WINDOW_UPDATE was consumed from this replay.
    /// Only meaningful while a replay still has pending frames.
    #[must_use]
    pub fn has_replayed_connection_window(&self) -> bool {
        matches!(
            &self.kind,
            EarlyFrameKind::Replayer {
                connection_window_replayed: true,
                ..
            }
        )
    }

    pub fn record_priority_frame(&mut self, frame: &Priority) {
        tracing::trace!("record priority frame: {frame:?}");
        if let EarlyFrameKind::Recorder(ref mut recorder) = self.kind {
            recorder.record_priority_frame(frame);
        }
    }

    pub fn record_settings_frame(&mut self, frame: &Settings) {
        tracing::trace!("record settings frame: {frame:?}");
        if let EarlyFrameKind::Recorder(ref mut recorder) = self.kind {
            recorder.record_settings_frame(frame);
        }
    }

    pub fn record_windows_update_frame(&mut self, frame: WindowUpdate) {
        tracing::trace!("record windows update frame: {frame:?}");
        if let EarlyFrameKind::Recorder(ref mut recorder) = self.kind {
            recorder.record_windows_update_frame(frame);
        }
    }

    /// Does nothing in case the ctx is not a recorder.
    pub fn freeze_recorder(&mut self) -> Option<EarlyFrameCapture> {
        if let EarlyFrameKind::Recorder(ref mut recorder) = self.kind {
            tracing::trace!("freeze recorder");
            return recorder.freeze();
        }
        tracing::trace!("ctx::freeze_recorder: nop");
        None
    }

    pub fn replay_next_frame(&mut self, next_stream_id: Option<StreamId>) -> Option<EarlyFrame> {
        if let EarlyFrameKind::Replayer {
            frames: v,
            connection_window_replayed,
            ..
        } = &mut self.kind
        {
            if let Some(next_stream_id) = next_stream_id
                && !v
                    .last()
                    .map(|f| f.stream_created(next_stream_id))
                    .unwrap_or_default()
            {
                tracing::trace!("wait to replay an early frame until its target stream exists");
                return None;
            }

            let next = v.pop();
            if matches!(&next, Some(EarlyFrame::WindowUpdate(frame)) if frame.stream_id.is_zero()) {
                *connection_window_replayed = true;
            }
            if v.is_empty() {
                self.kind = EarlyFrameKind::Nop;
            }
            tracing::trace!("replay_next_frame: frame = {:?}", next);
            return next;
        }
        tracing::trace!("replay_next_frame: EOF");
        None
    }
}

#[derive(Debug, Default, Clone)]
enum EarlyFrameKind {
    Recorder(EarlyFrameRecorder),
    Replayer {
        frames: Vec<EarlyFrame>,
        connection_window_replayed: bool,
        stream_window: Option<StreamWindow>,
    },
    #[default]
    Nop,
}

/// The window raise a captured client sends right after each new stream's HEADERS.
#[derive(Debug, Clone, Copy)]
struct StreamWindow {
    first_stream: StreamId,
    increment: u32,
}

#[derive(Debug, Clone)]
/// Can be used by an h2 backend to record early frames.
struct EarlyFrameRecorder {
    recording: Option<Vec<EarlyFrame>>,
    frozen: Option<Arc<[EarlyFrame]>>,
    truncated: bool,
}

#[derive(Debug, Clone, Extension)]
#[extension(tags(http))]
pub struct EarlyFrameCapture {
    frames: Arc<[EarlyFrame]>,
    complete: bool,
}

impl EarlyFrameCapture {
    /// Whether recording reached the first request without dropping a frame.
    /// The legacy serialized frame array does not carry this evidence; importing
    /// that array never establishes completeness for profile analysis.
    #[must_use]
    pub fn is_complete(&self) -> bool {
        self.complete
    }

    #[must_use]
    pub fn as_slice(&self) -> &[EarlyFrame] {
        &self.frames
    }

    pub fn iter(&self) -> impl Iterator<Item = &EarlyFrame> {
        self.frames.iter()
    }
}

impl serde::Serialize for EarlyFrameCapture {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        self.as_slice().serialize(serializer)
    }
}

impl<'de> serde::Deserialize<'de> for EarlyFrameCapture {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let v = <Vec<EarlyFrame>>::deserialize(deserializer)?;
        Ok(Self {
            frames: v.into(),
            complete: false,
        })
    }
}

impl EarlyFrameRecorder {
    const MAX_FRAMES: usize = 16;

    fn record_frame_internal<F: Clone>(&mut self, frame: F, map: impl FnOnce(F) -> EarlyFrame) {
        if let Some(mut recording) = self.recording.take() {
            if recording.len() == Self::MAX_FRAMES {
                self.truncated = true;
                self.frozen = Some(recording.into());
            } else {
                recording.push(map(frame));
                self.recording = Some(recording);
            }
        }
    }

    #[inline(always)]
    fn record_priority_frame(&mut self, frame: &Priority) {
        self.record_frame_internal(frame, |f| EarlyFrame::Priority(f.clone()));
    }

    #[inline(always)]
    fn record_settings_frame(&mut self, frame: &Settings) {
        self.record_frame_internal(frame, |f| EarlyFrame::Settings(f.clone()));
    }

    fn record_windows_update_frame(&mut self, frame: WindowUpdate) {
        self.record_frame_internal(frame, EarlyFrame::WindowUpdate);
    }

    fn freeze(&mut self) -> Option<EarlyFrameCapture> {
        if let Some(fc) = self.frozen.clone() {
            return Some(EarlyFrameCapture {
                frames: fc,
                complete: !self.truncated,
            });
        }

        let c = std::mem::take(&mut self.recording)?;
        if c.is_empty() {
            return None;
        }

        let fc: Arc<[EarlyFrame]> = c.into();
        self.frozen = Some(fc.clone());
        Some(EarlyFrameCapture {
            frames: fc,
            complete: !self.truncated,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn early_capture_distinguishes_exact_capacity_from_dropped_frames() {
        for count in [0, 1, 15, 16, 17, 64] {
            let mut context = EarlyFrameStreamContext::new_recorder();
            for _ in 0..count {
                context.record_settings_frame(&Settings::default());
            }
            let captured = context.freeze_recorder();
            if count == 0 {
                assert!(captured.is_none());
                continue;
            }
            let captured = captured.unwrap();
            assert_eq!(
                captured.as_slice().len(),
                count.min(EarlyFrameRecorder::MAX_FRAMES)
            );
            assert_eq!(
                captured.is_complete(),
                count <= EarlyFrameRecorder::MAX_FRAMES
            );
            let frozen = context.freeze_recorder().unwrap();
            assert!(Arc::ptr_eq(&captured.frames, &frozen.frames));
            for _ in 0..64 {
                context.record_settings_frame(&Settings::default());
            }
            let after_request = context.freeze_recorder().unwrap();
            assert!(Arc::ptr_eq(&captured.frames, &after_request.frames));
            assert_eq!(captured.is_complete(), after_request.is_complete());
        }
    }

    #[test]
    fn legacy_early_frame_arrays_do_not_invent_completeness() {
        let mut context = EarlyFrameStreamContext::new_recorder();
        context.record_settings_frame(&Settings::default());
        let captured = context.freeze_recorder().unwrap();
        assert!(captured.is_complete());
        let json = serde_json::to_vec(&captured).unwrap();
        assert_eq!(json[0], b'[');
        let restored: EarlyFrameCapture = serde_json::from_slice(&json).unwrap();
        assert!(!restored.is_complete());
        assert_eq!(restored.as_slice(), captured.as_slice());
        let mut disabled = EarlyFrameStreamContext::new_nop();
        for _ in 0..64 {
            disabled.record_settings_frame(&Settings::default());
        }
        assert!(disabled.freeze_recorder().is_none());
    }

    #[test]
    fn replay_preserves_repeated_connection_window_updates() {
        let frames = vec![
            EarlyFrame::Settings(Settings::default()),
            EarlyFrame::WindowUpdate(WindowUpdate::new(StreamId::zero(), 100)),
            EarlyFrame::WindowUpdate(WindowUpdate::new(StreamId::zero(), 200)),
        ];
        let (mut replay, settings) = EarlyFrameStreamContext::new_replayer(frames);
        assert!(settings.is_some());

        for expected in [100, 200] {
            let Some(EarlyFrame::WindowUpdate(frame)) = replay.replay_next_frame(None) else {
                panic!("missing captured connection WINDOW_UPDATE");
            };
            assert_eq!(frame.size_increment, expected);
        }
        assert!(replay.replay_next_frame(None).is_none());
    }
}
