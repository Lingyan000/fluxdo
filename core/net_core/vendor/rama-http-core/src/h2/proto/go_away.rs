use crate::h2::codec::Codec;

use rama_core::bytes::Buf;
use rama_http_types::proto::h2::frame::{self, Reason, StreamId};
use std::task::{Context, Poll};
use tokio::io::AsyncWrite;

/// Manages our sending of GOAWAY frames.
#[derive(Debug)]
pub(super) struct GoAway {
    /// Whether the connection should close now, or wait until idle.
    close_now: bool,
    /// Records if we've sent any GOAWAY before.
    going_away: Option<GoingAway>,
    /// Whether the user started the GOAWAY by calling `abrupt_shutdown`.
    is_user_initiated: bool,
    /// A GOAWAY frame that must be buffered in the Codec immediately.
    pending: Option<frame::GoAway>,
}

/// Keeps a memory of any GOAWAY frames we've sent before.
///
/// This looks very similar to a `frame::GoAway`, but is a separate type. Why?
/// Mostly for documentation purposes. This type is to record status. If it
/// were a `frame::GoAway`, it might appear like we eventually wanted to
/// serialize it. We **only** want to be able to look up these fields at a
/// later time.
#[derive(Debug)]
pub(crate) struct GoingAway {
    /// Stores the highest stream ID of a GOAWAY that has been sent.
    ///
    /// It's illegal to send a subsequent GOAWAY with a higher ID.
    last_processed_id: StreamId,

    /// Records the error code of any GOAWAY frame sent.
    reason: Reason,
}

impl GoAway {
    pub(super) fn new() -> Self {
        Self {
            close_now: false,
            going_away: None,
            is_user_initiated: false,
            pending: None,
        }
    }

    /// Enqueue a GOAWAY frame to be written.
    ///
    /// The connection is expected to continue to run until idle.
    pub(super) fn go_away(&mut self, f: frame::GoAway) {
        if let Some(ref going_away) = self.going_away {
            assert!(
                f.last_stream_id() <= going_away.last_processed_id,
                "GOAWAY stream IDs shouldn't be higher; \
                 last_processed_id = {:?}, f.last_stream_id() = {:?}",
                going_away.last_processed_id,
                f.last_stream_id(),
            );
        }

        self.going_away = Some(GoingAway {
            last_processed_id: f.last_stream_id(),
            reason: f.reason(),
        });
        self.pending = Some(f);
    }

    pub(super) fn go_away_now(&mut self, f: frame::GoAway) {
        self.close_now = true;
        if let Some(ref going_away) = self.going_away {
            // Prevent sending the same GOAWAY twice.
            if going_away.last_processed_id == f.last_stream_id() && going_away.reason == f.reason()
            {
                return;
            }
        }
        self.go_away(f);
    }

    pub(super) fn go_away_from_user(&mut self, f: frame::GoAway) {
        self.is_user_initiated = true;
        self.go_away_now(f);
    }

    /// Return if a GOAWAY has ever been scheduled.
    pub(super) fn is_going_away(&self) -> bool {
        self.going_away.is_some()
    }

    pub(super) fn is_user_initiated(&self) -> bool {
        self.is_user_initiated
    }

    /// Returns the going away info, if any.
    pub(super) fn going_away(&self) -> Option<&GoingAway> {
        self.going_away.as_ref()
    }

    /// Returns if the connection should close now, or wait until idle.
    pub(super) fn should_close_now(&self) -> bool {
        self.pending.is_none() && self.close_now
    }

    /// Returns if the connection should be closed when idle.
    pub(super) fn should_close_on_idle(&self) -> bool {
        !self.close_now
            && self
                .going_away
                .as_ref()
                .map(|g| g.last_processed_id != StreamId::MAX)
                .unwrap_or(false)
    }

    /// Try to write a pending GOAWAY frame to the buffer.
    ///
    /// If a frame is written, the `Reason` of the GOAWAY is returned.
    pub(super) fn send_pending_go_away<T, B>(
        &mut self,
        cx: &mut Context,
        dst: &mut Codec<T, B>,
    ) -> Poll<Option<Result<Reason, crate::h2::proto::Error>>>
    where
        T: AsyncWrite + Unpin,
        B: Buf,
    {
        if let Some(frame) = self.pending.take() {
            if !dst.poll_ready(cx)?.is_ready() {
                self.pending = Some(frame);
                return Poll::Pending;
            }

            let reason = frame.reason();
            if let Err(err) = dst.buffer(frame.into()) {
                return Poll::Ready(Some(Err(err.into())));
            }

            return Poll::Ready(Some(Ok(reason)));
        } else if self.should_close_now() {
            return match self.going_away().map(|going_away| going_away.reason) {
                Some(reason) => Poll::Ready(Some(Ok(reason))),
                None => Poll::Ready(None),
            };
        }

        Poll::Ready(None)
    }
}

impl GoingAway {
    pub(crate) fn reason(&self) -> Reason {
        self.reason
    }
}
