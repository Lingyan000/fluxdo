use std::{fmt, io};

use crate::h2::codec::UserError;
use crate::h2::proto::{self, Error, Initiator, PollReset};

use rama_core::telemetry::tracing;
use rama_http_types::proto::h2::frame::{self, Reason, StreamId};

/// Represents the state of an H2 stream
///
/// ```not_rust
///                              +--------+
///                      send PP |        | recv PP
///                     ,--------|  idle  |--------.
///                    /         |        |         \
///                   v          +--------+          v
///            +----------+          |           +----------+
///            |          |          | send H /  |          |
///     ,------| reserved |          | recv H    | reserved |------.
///     |      | (local)  |          |           | (remote) |      |
///     |      +----------+          v           +----------+      |
///     |          |             +--------+             |          |
///     |          |     recv ES |        | send ES     |          |
///     |   send H |     ,-------|  open  |-------.     | recv H   |
///     |          |    /        |        |        \    |          |
///     |          v   v         +--------+         v   v          |
///     |      +----------+          |           +----------+      |
///     |      |   half   |          |           |   half   |      |
///     |      |  closed  |          | send R /  |  closed  |      |
///     |      | (remote) |          | recv R    | (local)  |      |
///     |      +----------+          |           +----------+      |
///     |           |                |                 |           |
///     |           | send ES /      |       recv ES / |           |
///     |           | send R /       v        send R / |           |
///     |           | recv R     +--------+   recv R   |           |
///     | send R /  `----------->|        |<-----------'  send R / |
///     | recv R                 | closed |               recv R   |
///     `----------------------->|        |<----------------------'
///                              +--------+
///
///        send:   endpoint sends this frame
///        recv:   endpoint receives this frame
///
///        H:  HEADERS frame (with implied CONTINUATIONs)
///        PP: PUSH_PROMISE frame (with implied CONTINUATIONs)
///        ES: END_STREAM flag
///        R:  RST_STREAM frame
/// ```
#[derive(Clone)]
pub(super) struct State {
    inner: Inner,
}

// remove some noise for debug output
impl fmt::Debug for State {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.inner.fmt(f)
    }
}

#[derive(Debug, Clone)]
enum Inner {
    Idle,
    // TODO: these states shouldn't count against concurrency limits:
    ReservedLocal,
    ReservedRemote,
    Open { local: Peer, remote: Peer },
    HalfClosedLocal(Peer), // TODO: explicitly name this value
    HalfClosedRemote(Peer),
    Closed(Cause),
}

#[derive(Debug, Copy, Clone, Default)]
enum Peer {
    #[default]
    AwaitingHeaders,
    Streaming,
}

#[derive(Debug, Clone)]
enum Cause {
    EndStream,
    Error(Error),
    /// The stream was reset, or the connection failed, after the receive half
    /// had already reached EOS.
    ErrorAfterEndStream(Error),

    /// This indicates to the connection that a reset frame must be sent out
    /// once the send queue has been flushed.
    ///
    /// Examples of when this could happen:
    /// - User drops all references to a stream, so we want to CANCEL the it.
    /// - Header block size was too large, so we want to REFUSE, possibly
    ///   after sending a 431 response frame.
    ScheduledLibraryReset(Reason),
}

impl State {
    /// Opens the send-half of a stream if it is not already open.
    pub(super) fn send_open(&mut self, eos: bool) -> Result<(), UserError> {
        let local = Peer::Streaming;

        self.inner = match self.inner {
            Inner::Idle => {
                if eos {
                    Inner::HalfClosedLocal(Peer::AwaitingHeaders)
                } else {
                    Inner::Open {
                        local,
                        remote: Peer::AwaitingHeaders,
                    }
                }
            }
            Inner::Open {
                local: Peer::AwaitingHeaders,
                remote,
            } => {
                if eos {
                    Inner::HalfClosedLocal(remote)
                } else {
                    Inner::Open { local, remote }
                }
            }
            Inner::HalfClosedRemote(Peer::AwaitingHeaders) | Inner::ReservedLocal => {
                if eos {
                    Inner::Closed(Cause::EndStream)
                } else {
                    Inner::HalfClosedRemote(local)
                }
            }
            _ => {
                // All other transitions result in a protocol error
                return Err(UserError::UnexpectedFrameType);
            }
        };

        Ok(())
    }

    /// Opens the receive-half of the stream when a HEADERS frame is received.
    ///
    /// Returns true if this transitions the state to Open.
    pub(super) fn recv_open(&mut self, frame: &frame::Headers) -> Result<bool, Error> {
        let mut initial = false;
        let eos = frame.is_end_stream();

        self.inner = match self.inner {
            Inner::Idle => {
                initial = true;

                if eos {
                    Inner::HalfClosedRemote(Peer::AwaitingHeaders)
                } else {
                    Inner::Open {
                        local: Peer::AwaitingHeaders,
                        remote: if frame.is_informational() {
                            tracing::trace!("skipping 1xx response headers");
                            Peer::AwaitingHeaders
                        } else {
                            Peer::Streaming
                        },
                    }
                }
            }
            Inner::ReservedRemote => {
                initial = true;

                if eos {
                    Inner::Closed(Cause::EndStream)
                } else if frame.is_informational() {
                    tracing::trace!("skipping 1xx response headers");
                    Inner::ReservedRemote
                } else {
                    Inner::HalfClosedLocal(Peer::Streaming)
                }
            }
            Inner::Open {
                local,
                remote: Peer::AwaitingHeaders,
            } => {
                if eos {
                    Inner::HalfClosedRemote(local)
                } else {
                    Inner::Open {
                        local,
                        remote: if frame.is_informational() {
                            tracing::trace!("skipping 1xx response headers");
                            Peer::AwaitingHeaders
                        } else {
                            Peer::Streaming
                        },
                    }
                }
            }
            Inner::HalfClosedLocal(Peer::AwaitingHeaders) => {
                if eos {
                    Inner::Closed(Cause::EndStream)
                } else if frame.is_informational() {
                    tracing::trace!("skipping 1xx response headers");
                    Inner::HalfClosedLocal(Peer::AwaitingHeaders)
                } else {
                    Inner::HalfClosedLocal(Peer::Streaming)
                }
            }
            ref state => {
                // All other transitions result in a protocol error
                proto_err!(conn: "recv_open: in unexpected state {:?}", state);
                return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
            }
        };

        Ok(initial)
    }

    /// Transition from Idle -> ReservedRemote
    pub(super) fn reserve_remote(&mut self) -> Result<(), Error> {
        match self.inner {
            Inner::Idle => {
                self.inner = Inner::ReservedRemote;
                Ok(())
            }
            ref state => {
                proto_err!(conn: "reserve_remote: in unexpected state {:?}", state);
                Err(Error::library_go_away(Reason::PROTOCOL_ERROR))
            }
        }
    }

    /// Transition from Idle -> ReservedLocal
    pub(super) fn reserve_local(&mut self) -> Result<(), UserError> {
        match self.inner {
            Inner::Idle => {
                self.inner = Inner::ReservedLocal;
                Ok(())
            }
            _ => Err(UserError::UnexpectedFrameType),
        }
    }

    /// Indicates that the remote side will not send more data to the local.
    pub(super) fn recv_close(&mut self) -> Result<(), Error> {
        match self.inner {
            Inner::Open { local, .. } => {
                // The remote side will continue to receive data.
                tracing::trace!("recv_close: Open => HalfClosedRemote({:?})", local);
                self.inner = Inner::HalfClosedRemote(local);
                Ok(())
            }
            Inner::HalfClosedLocal(..) => {
                tracing::trace!("recv_close: HalfClosedLocal => Closed");
                self.inner = Inner::Closed(Cause::EndStream);
                Ok(())
            }
            ref state => {
                proto_err!(conn: "recv_close: in unexpected state {:?}", state);
                Err(Error::library_go_away(Reason::PROTOCOL_ERROR))
            }
        }
    }

    /// The remote explicitly sent a RST_STREAM.
    ///
    /// # Arguments
    /// - `frame`: the received RST_STREAM frame.
    /// - `queued`: true if this stream has frames in the pending send queue.
    pub(super) fn recv_reset(&mut self, frame: frame::Reset, queued: bool) {
        let recv_end_stream = self.is_recv_end_stream();
        match self.inner {
            // If the stream is already in a `Closed` state, do nothing,
            // provided that there are no frames still in the send queue.
            Inner::Closed(..) if !queued => {}
            // A notionally `Closed` stream may still have queued frames in
            // the following cases:
            //
            // - if the cause is `Cause::Scheduled(..)` (i.e. we have not
            //   actually closed the stream yet).
            // - if the cause is `Cause::EndStream`: we transition to this
            //   state when an EOS frame is *enqueued* (so that it's invalid
            //   to enqueue more frames), not when the EOS frame is *sent*;
            //   therefore, there may still be frames ahead of the EOS frame
            //   in the send queue.
            //
            // In either of these cases, we want to overwrite the stream's
            // previous state with the received RST_STREAM, so that the queue
            // will be cleared by `Prioritize::pop_frame`.
            ref state => {
                tracing::trace!(
                    "recv_reset; frame={:?}; state={:?}; queued={:?}",
                    frame,
                    state,
                    queued
                );
                let error = Error::remote_reset(frame.stream_id(), frame.reason());
                // Preserve the received EOS while retaining the reset for the send half.
                self.inner = Inner::Closed(if recv_end_stream {
                    Cause::ErrorAfterEndStream(error)
                } else {
                    Cause::Error(error)
                });
            }
        }
    }

    /// Handle a connection-level error.
    pub(super) fn handle_error(&mut self, err: &proto::Error) {
        let recv_end_stream = self.is_recv_end_stream();
        if let Inner::Closed(..) = self.inner {
        } else {
            tracing::trace!("handle_error; err={:?}", err);
            self.inner = Inner::Closed(if recv_end_stream {
                Cause::ErrorAfterEndStream(err.clone())
            } else {
                Cause::Error(err.clone())
            });
        }
    }

    pub(super) fn recv_eof(&mut self) {
        let recv_end_stream = self.is_recv_end_stream();
        match self.inner {
            Inner::Closed(..) => {}
            ref state => {
                tracing::trace!("recv_eof; state={:?}", state);
                let error = io::Error::new(
                    io::ErrorKind::BrokenPipe,
                    "stream closed because of a broken pipe",
                )
                .into();
                self.inner = Inner::Closed(if recv_end_stream {
                    Cause::ErrorAfterEndStream(error)
                } else {
                    Cause::Error(error)
                });
            }
        }
    }

    /// Indicates that the local side will not send more data to the local.
    pub(super) fn send_close(&mut self) {
        match self.inner {
            Inner::Open { remote, .. } => {
                // The remote side will continue to receive data.
                tracing::trace!("send_close: Open => HalfClosedLocal({:?})", remote);
                self.inner = Inner::HalfClosedLocal(remote);
            }
            Inner::HalfClosedRemote(..) => {
                tracing::trace!("send_close: HalfClosedRemote => Closed");
                self.inner = Inner::Closed(Cause::EndStream);
            }
            ref state => panic!("send_close: unexpected state {state:?}"),
        }
    }

    /// Set the stream state to reset locally.
    pub(super) fn set_reset(&mut self, stream_id: StreamId, reason: Reason, initiator: Initiator) {
        self.inner = Inner::Closed(Cause::Error(Error::Reset(stream_id, reason, initiator)));
    }

    /// Set the stream state to a scheduled reset.
    pub(super) fn set_scheduled_reset(&mut self, reason: Reason) {
        debug_assert!(!self.is_closed());
        self.inner = Inner::Closed(Cause::ScheduledLibraryReset(reason));
    }

    pub(super) fn get_scheduled_reset(&self) -> Option<Reason> {
        match self.inner {
            Inner::Closed(Cause::ScheduledLibraryReset(reason)) => Some(reason),
            _ => None,
        }
    }

    pub(super) fn is_scheduled_reset(&self) -> bool {
        matches!(self.inner, Inner::Closed(Cause::ScheduledLibraryReset(..)))
    }

    pub(super) fn is_local_error(&self) -> bool {
        match self.inner {
            Inner::Closed(Cause::Error(ref e) | Cause::ErrorAfterEndStream(ref e)) => e.is_local(),
            Inner::Closed(Cause::ScheduledLibraryReset(..)) => true,
            _ => false,
        }
    }

    pub(super) fn is_remote_reset(&self) -> bool {
        matches!(
            self.inner,
            Inner::Closed(
                Cause::Error(Error::Reset(_, _, Initiator::Remote))
                    | Cause::ErrorAfterEndStream(Error::Reset(_, _, Initiator::Remote))
            )
        )
    }

    /// Returns true if the stream is already reset.
    pub(super) fn is_reset(&self) -> bool {
        match self.inner {
            Inner::Closed(Cause::EndStream) => false,
            Inner::Closed(_) => true,
            _ => false,
        }
    }

    pub(super) fn is_send_streaming(&self) -> bool {
        matches!(
            self.inner,
            Inner::Open {
                local: Peer::Streaming,
                ..
            } | Inner::HalfClosedRemote(Peer::Streaming)
        )
    }

    /// Returns true when the stream is in a state to receive headers
    pub(super) fn is_recv_headers(&self) -> bool {
        matches!(
            self.inner,
            Inner::Idle
                | Inner::Open {
                    remote: Peer::AwaitingHeaders,
                    ..
                }
                | Inner::HalfClosedLocal(Peer::AwaitingHeaders)
                | Inner::ReservedRemote
        )
    }

    /// Returns true when the stream is in a state to send headers
    pub(super) fn is_send_headers(&self) -> bool {
        matches!(
            self.inner,
            Inner::Idle
                | Inner::Open {
                    local: Peer::AwaitingHeaders,
                    ..
                }
                | Inner::HalfClosedRemote(Peer::AwaitingHeaders)
                | Inner::ReservedLocal
        )
    }

    /// Returns true when the stream may carry a PUSH_PROMISE (RFC 9113 §8.4)
    pub(super) fn is_push_open(&self) -> bool {
        matches!(self.inner, Inner::Open { .. } | Inner::HalfClosedRemote(..))
    }

    pub(super) fn is_recv_streaming(&self) -> bool {
        matches!(
            self.inner,
            Inner::Open {
                remote: Peer::Streaming,
                ..
            } | Inner::HalfClosedLocal(Peer::Streaming)
        )
    }

    pub(super) fn is_recv_end_stream(&self) -> bool {
        // In each case END_STREAM has been received.
        matches!(
            self.inner,
            Inner::Closed(Cause::EndStream | Cause::ErrorAfterEndStream(_))
                | Inner::HalfClosedRemote(..)
        )
    }

    pub(super) fn is_closed(&self) -> bool {
        matches!(self.inner, Inner::Closed(_))
    }

    pub(super) fn is_send_closed(&self) -> bool {
        matches!(
            self.inner,
            Inner::Closed(..) | Inner::HalfClosedLocal(..) | Inner::ReservedRemote
        )
    }

    pub(super) fn is_idle(&self) -> bool {
        matches!(self.inner, Inner::Idle)
    }

    pub(super) fn ensure_recv_open(&self) -> Result<bool, proto::Error> {
        // TODO: Is this correct?
        match self.inner {
            Inner::Closed(Cause::Error(ref e)) => Err(e.clone()),
            Inner::Closed(Cause::ScheduledLibraryReset(reason)) => {
                Err(proto::Error::library_go_away(reason))
            }
            Inner::Closed(Cause::EndStream | Cause::ErrorAfterEndStream(_))
            | Inner::HalfClosedRemote(..)
            | Inner::ReservedLocal => Ok(false),
            _ => Ok(true),
        }
    }

    /// Returns a reason if the stream has been reset.
    pub(super) fn ensure_reason(
        &self,
        mode: PollReset,
    ) -> Result<Option<Reason>, crate::h2::Error> {
        match self.inner {
            Inner::Closed(
                Cause::Error(Error::Reset(_, reason, _) | Error::GoAway(_, reason, _))
                | Cause::ErrorAfterEndStream(
                    Error::Reset(_, reason, _) | Error::GoAway(_, reason, _),
                )
                | Cause::ScheduledLibraryReset(reason),
            ) => Ok(Some(reason)),
            Inner::Closed(Cause::Error(ref e) | Cause::ErrorAfterEndStream(ref e)) => {
                Err(e.clone().into())
            }
            Inner::Open {
                local: Peer::Streaming,
                ..
            }
            | Inner::HalfClosedRemote(Peer::Streaming) => match mode {
                PollReset::AwaitingHeaders => Err(UserError::PollResetAfterSendResponse.into()),
                PollReset::Streaming => Ok(None),
            },
            _ => Ok(None),
        }
    }
}

impl Default for State {
    fn default() -> Self {
        Self { inner: Inner::Idle }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rama_http_types::HeaderMap;

    #[test]
    fn recv_reset_preserves_received_end_stream() {
        let stream_id = StreamId::from(1);
        let mut state = State::default();
        state.send_open(false).unwrap();

        let mut headers =
            frame::Headers::new(stream_id, Default::default(), HeaderMap::new(), None);
        headers.set_end_stream();
        state.recv_open(&headers).unwrap();
        assert!(state.is_recv_end_stream());

        state.recv_reset(frame::Reset::new(stream_id, Reason::NO_ERROR), true);

        assert!(state.is_recv_end_stream());
        assert!(!state.ensure_recv_open().unwrap());
        assert_eq!(
            state.ensure_reason(PollReset::Streaming).unwrap(),
            Some(Reason::NO_ERROR)
        );
    }

    fn half_closed_remote() -> State {
        let mut state = State::default();
        state.send_open(false).unwrap();

        let mut headers = frame::Headers::new(
            StreamId::from(1),
            Default::default(),
            HeaderMap::new(),
            None,
        );
        headers.set_end_stream();
        state.recv_open(&headers).unwrap();
        assert!(state.is_recv_end_stream());
        state
    }

    #[test]
    fn handle_error_preserves_received_end_stream() {
        let mut state = half_closed_remote();

        state.handle_error(&Error::library_go_away(Reason::INTERNAL_ERROR));

        assert!(state.is_recv_end_stream());
        assert!(!state.ensure_recv_open().unwrap());
        assert_eq!(
            state.ensure_reason(PollReset::Streaming).unwrap(),
            Some(Reason::INTERNAL_ERROR)
        );
    }

    #[test]
    fn recv_eof_preserves_received_end_stream() {
        let mut state = half_closed_remote();

        state.recv_eof();

        assert!(state.is_recv_end_stream());
        assert!(!state.ensure_recv_open().unwrap());
        state.ensure_reason(PollReset::Streaming).unwrap_err();
    }
}
