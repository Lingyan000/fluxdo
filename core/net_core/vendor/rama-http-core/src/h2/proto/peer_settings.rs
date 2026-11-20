//! Shared per-connection cell for the peer's initial h2 SETTINGS frame.
//! `Arc<PeerSettingsState>` is held by the connection's `Send` struct
//! (writer) and by any number of observer handles (readers); observers
//! carry no dispatcher reference, so they don't extend conn lifetime.
//!
//! **INVARIANT:** `set_snapshot` / `mark_closed` are only called from
//! the connection-driver task (single writer); observers run on any
//! task. Lifting this invariant would require auditing `await_settings`
//! for missed/double wakes and the `snapshot=Some + closed=true` race.

use rama_http_types::conn::PeerH2Settings;
use rama_http_types::proto::h2::frame;
use std::sync::Arc;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::sync::Notify;

/// Per-conn state: captured initial peer SETTINGS + closed-before-settings
/// signal. Stored as `Arc<PeerH2Settings>` so the per-response hot path
/// reuses one Arc via [`rama_core::extensions::Extensions::insert_arc`].
#[derive(Debug)]
pub(crate) struct PeerSettingsState {
    /// First non-ACK SETTINGS frame from peer, pre-wrapped in the
    /// extension type for zero-alloc per-response insertion.
    snapshot: OnceLock<Arc<PeerH2Settings>>,
    /// `true` iff EOF observed before any SETTINGS — lets
    /// `await_settings` resolve to `None` instead of hanging.
    closed: AtomicBool,
    /// Wakes `await_settings` waiters on first capture or on EOF.
    notify: Notify,
}

impl PeerSettingsState {
    #[must_use]
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self {
            snapshot: OnceLock::new(),
            closed: AtomicBool::new(false),
            notify: Notify::new(),
        })
    }

    /// Cheap fast-path: return the captured peer SETTINGS extension if any.
    #[must_use]
    pub(crate) fn snapshot(&self) -> Option<Arc<PeerH2Settings>> {
        self.snapshot.get().cloned()
    }

    /// True iff the connection terminated before any SETTINGS arrived.
    #[must_use]
    pub(crate) fn is_closed(&self) -> bool {
        self.closed.load(Ordering::Acquire)
    }

    /// Called from `Send::apply_remote_settings` on the first non-ACK
    /// SETTINGS receipt; `OnceLock::set` enforces once-only. Note: this
    /// runs *before* any later validation in `apply_remote_settings`,
    /// so the captured frame is "first received," not "first validated".
    pub(crate) fn set_snapshot(&self, settings: &frame::Settings) {
        if self
            .snapshot
            .set(Arc::new(PeerH2Settings(settings.clone())))
            .is_ok()
        {
            self.notify.notify_waiters();
        }
    }

    /// Called from `Streams::recv_eof`. No-op if a snapshot was already
    /// captured (any waiters already resolved through the success path).
    pub(crate) fn mark_closed(&self) {
        if self.snapshot.get().is_none() && !self.closed.swap(true, Ordering::AcqRel) {
            self.notify.notify_waiters();
        }
    }

    /// Resolves to the peer's initial SETTINGS once captured, or `None`
    /// if the connection terminates before SETTINGS arrive. Uses the
    /// standard Notify `register-interest → recheck → await` pattern to
    /// avoid missed wakes.
    pub(crate) async fn await_settings(&self) -> Option<Arc<PeerH2Settings>> {
        // Fast path: already captured (or already closed).
        if let Some(s) = self.snapshot() {
            return Some(s);
        }
        if self.is_closed() {
            return None;
        }

        loop {
            let notified = self.notify.notified();
            let mut notified = std::pin::pin!(notified);
            // Enable interest BEFORE re-checking the state to avoid
            // racing with a notify between the check and the await.
            notified.as_mut().enable();
            if let Some(s) = self.snapshot() {
                return Some(s);
            }
            if self.is_closed() {
                return None;
            }
            notified.await;
        }
    }
}
