use super::streams::ReplayStep;
use crate::{
    h2::{
        client,
        codec::{HeadProgress, UserError},
        proto::*,
        server,
    },
    server::conn::timeout::Activity,
};

use rama_core::bytes::Bytes;
use rama_core::extensions::{Extensions, ExtensionsRef};
use rama_core::futures::Stream;
use rama_core::telemetry::tracing;
use rama_http::proto::h2::frame::EarlyFrameStreamContext;
use rama_http_types::proto::h2::PseudoHeaderOrder;
use rama_http_types::proto::h2::alt_svc::{
    ALT_SVC_MAX_PAYLOAD, ALT_SVC_QUEUE_CAPACITY, AltSvcEvent, AltSvcObserverExtension,
    AltSvcOrigin, AltSvcReceivedAt, AltSvcSendError, AltSvcSender,
};
use rama_http_types::proto::h2::frame::DEFAULT_INITIAL_WINDOW_SIZE;
use rama_http_types::proto::h2::frame::{Reason, StreamId};
use std::io;
use std::marker::PhantomData;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::{io::AsyncRead, sync::mpsc, time::Instant};

/// An H2 connection
#[derive(Debug)]
pub(crate) struct Connection<T, P, B: Buf = Bytes>
where
    P: Peer,
{
    /// Read / write frame values
    codec: Codec<T, Prioritized<B>>,

    inner: ConnectionInner<P, B>,
}

// Extracted part of `Connection` which does not depend on `T`. Reduces the amount of duplicated
// method instantiations.
#[derive(Debug)]
struct ConnectionInner<P, B: Buf = Bytes>
where
    P: Peer,
{
    /// Tracks the connection level state transitions.
    state: State,

    /// An error to report back once complete.
    ///
    /// This exists separately from State in order to support
    /// graceful shutdown.
    error: Option<frame::GoAway>,

    /// Pending GOAWAY frames to write.
    go_away: GoAway,

    /// A refused stream to reset before receiving another frame.
    pending_refusal: Option<StreamId>,

    /// Ping/pong handler
    ping_pong: PingPong,

    /// Connection settings
    settings: Settings,

    /// Stream state handler
    streams: Streams<B, P>,

    /// Optional connection-local observation, with established transport metadata.
    alt_svc_observer: Option<(Arc<AltSvcObserverExtension>, Extensions)>,

    /// Explicit server advertisements, bounded independently of stream data.
    alt_svc_send: Option<mpsc::Receiver<frame::AltSvc>>,

    /// A `tracing` span tracking the lifetime of the connection.
    span: tracing::Span,

    /// Client or server
    _phantom: PhantomData<P>,
}

struct DynConnection<'a, B: Buf = Bytes> {
    state: &'a mut State,

    go_away: &'a mut GoAway,

    streams: DynStreams<'a, B>,

    error: &'a mut Option<frame::GoAway>,

    ping_pong: &'a mut PingPong,

    alt_svc_observer: &'a Option<(Arc<AltSvcObserverExtension>, Extensions)>,
}

#[derive(Debug, Clone)]
pub(crate) struct Config {
    pub next_stream_id: StreamId,
    pub initial_max_send_streams: usize,
    pub refuse_push_promises: bool,
    pub max_send_buffer_size: u32,
    pub reset_stream_duration: Duration,
    pub reset_stream_max: usize,
    pub remote_reset_stream_max: usize,
    pub local_error_reset_streams_max: Option<usize>,
    pub settings: frame::Settings,
    pub send_alt_svc: bool,
    pub headers_pseudo_order: Option<PseudoHeaderOrder>,
    pub early_frame_ctx: EarlyFrameStreamContext,
    pub data_frame_budget: DataFrameBudget,
    /// When the initial SETTINGS left, so their ACK measures a round trip.
    pub settings_sent_at: Option<Instant>,
}

#[derive(Clone, Copy, Debug)]
pub(crate) enum DataFrameBudget {
    Auto,
    Configured(usize),
}

impl DataFrameBudget {
    pub(crate) fn resolve(self, connection_window: Option<WindowSize>) -> usize {
        match self {
            Self::Configured(budget) => budget,
            Self::Auto => {
                let window = connection_window.unwrap_or(DEFAULT_INITIAL_WINDOW_SIZE);
                let budget = window as usize / 2;

                budget.max(DEFAULT_DATA_FRAME_BUDGET)
            }
        }
    }

    pub(crate) fn is_auto(self) -> bool {
        matches!(self, Self::Auto)
    }
}

#[derive(Debug)]
enum State {
    /// Currently open in a sane state
    Open,

    /// The codec must be flushed
    Closing(Reason, Initiator),

    /// In a closed state
    Closed(Reason, Initiator),
}

impl<T, P, B> Connection<T, P, B>
where
    T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef,
    P: Peer,
    B: Buf,
{
    pub(crate) fn try_new(
        mut codec: Codec<T, Prioritized<B>>,
        config: Config,
    ) -> Result<Self, crate::h2::proto::Error> {
        fn streams_config(config: &Config) -> streams::Config {
            streams::Config {
                initial_max_send_streams: config.initial_max_send_streams,
                local_max_buffer_size: config.max_send_buffer_size,
                local_next_stream_id: config.next_stream_id,
                local_push_enabled: config
                    .settings
                    .config
                    .enable_push
                    .map(|v| v != 0)
                    .unwrap_or(true),
                refuse_push_promises: config.refuse_push_promises,
                extended_connect_protocol_enabled: config
                    .settings
                    .config
                    .enable_connect_protocol
                    .map(|v| v != 0)
                    .unwrap_or_default(),
                local_reset_duration: config.reset_stream_duration,
                local_reset_max: config.reset_stream_max,
                remote_reset_max: config.remote_reset_stream_max,
                remote_init_window_sz: DEFAULT_INITIAL_WINDOW_SIZE,
                remote_max_initiated: config
                    .settings
                    .config
                    .max_concurrent_streams
                    .map(|max| max as usize),
                local_max_error_reset_streams: config.local_error_reset_streams_max,
                headers_pseudo_order: config.headers_pseudo_order.clone(),
                early_frame_ctx: config.early_frame_ctx.clone(),
                data_frame_budget: config.data_frame_budget,
            }
        }
        // Transfer ownership of extensions to Streams as at this point our connection is esthablished
        // and we only need these extensions as parents for our inner Stream's
        let (alt_svc_observer, alt_svc_send) = if P::r#dyn().is_server() {
            let receiver = config.send_alt_svc.then(|| {
                let (sender, receiver) = AltSvcSender::channel();
                codec.extensions().insert(sender);
                receiver
            });
            (None, receiver)
        } else {
            let observer = codec
                .extensions()
                .get_arc::<AltSvcObserverExtension>()
                .map(|observer| (observer, codec.extensions().clone()));
            (observer, None)
        };
        codec.set_recv_alt_svc(alt_svc_observer.is_some());
        let streams = Streams::try_new(streams_config(&config), codec.extensions().clone())?;
        let span = tracing::debug_root_span!(
            "Connection",
            peer = %P::NAME,
        );
        Ok(Self {
            codec,
            inner: ConnectionInner {
                state: State::Open,
                error: None,
                go_away: GoAway::new(),
                pending_refusal: None,
                ping_pong: PingPong::new(),
                settings: Settings::new(config.settings, config.settings_sent_at),
                streams,
                alt_svc_observer,
                alt_svc_send,
                span,
                _phantom: PhantomData,
            },
        })
    }

    rama_utils::macros::generate_set_and_with! {
        /// connection flow control
        pub(crate) fn target_window_size(mut self, size: WindowSize) -> Result<Self, Reason> {
            self.inner.streams.set_target_connection_window_size(size)?;
            Ok(self)
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Send a new SETTINGS frame with an updated initial window size.
        pub(crate) fn initial_window_size(mut self, size: WindowSize) -> Result<Self, UserError> {
            tracing::trace!("set_initial_window_size(%size)");
            let mut settings = frame::Settings::default();
            settings.config.initial_window_size = Some(size);
            self.inner.settings.send_settings(settings)?;
            Ok(self)
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Send a new SETTINGS frame with extended CONNECT protocol enabled.
        pub(crate) fn enable_connect_protocol(mut self) -> Result<Self, UserError> {
            tracing::trace!("set_enable_connect_protocol");
            let mut settings = frame::Settings::default();
            settings.config.enable_connect_protocol = Some(1);
            self.inner.settings.send_settings(settings)?;
            Ok(self)
        }
    }

    /// Returns the maximum number of concurrent streams that may be initiated
    /// by this peer.
    pub(crate) fn max_send_streams(&self) -> usize {
        self.inner.streams.max_send_streams()
    }

    /// Returns the maximum number of concurrent streams that may be initiated
    /// by the remote peer.
    pub(crate) fn max_recv_streams(&self) -> usize {
        self.inner.streams.max_recv_streams()
    }

    #[cfg(feature = "unstable")]
    pub(crate) fn num_wired_streams(&self) -> usize {
        self.inner.streams.num_wired_streams()
    }

    /// Returns `Ready` when the connection is ready to receive a frame.
    ///
    /// Returns `Error` as this may raise errors that are caused by delayed
    /// processing of received frames.
    fn poll_ready(&mut self, cx: &mut Context) -> Poll<Result<(), Error>> {
        let _e = self.inner.span.enter();
        let span = tracing::trace_span!("poll_ready");
        let _e = span.enter();
        // The order of these calls don't really matter too much
        ready!(self.inner.ping_pong.send_pending_pong(cx, &mut self.codec))?;
        ready!(self.inner.ping_pong.send_pending_ping(cx, &mut self.codec))?;
        ready!(
            self.inner
                .settings
                .poll_send(cx, &mut self.codec, &mut self.inner.streams)
        )?;
        if let Some(id) = self.inner.pending_refusal {
            // Keep the refusal pending if making room requires socket progress.
            ready!(self.codec.poll_ready(cx))?;
            self.inner.streams.count_pending_refusal()?;
            self.codec
                .buffer(frame::Reset::new(id, Reason::REFUSED_STREAM).into())?;
            self.inner.pending_refusal = None;
        }

        let settings_synced = self.inner.settings.is_synced();
        // Drain only frames which actually advance replay. A future or
        // concurrency-blocked stream must let the connection continue reading.
        loop {
            match ready!(
                self.inner
                    .streams
                    .send_pending(cx, &mut self.codec, settings_synced)
            )? {
                ReplayStep::Idle => break,
                ReplayStep::Advanced => {}
                ReplayStep::Settings(settings) => {
                    tracing::trace!("send replayed early settings frame: {settings:?}");
                    self.inner.settings.send_settings(settings)?;
                    // The frame is queued; another poll passes it to the codec.
                    cx.waker().wake_by_ref();
                    break;
                }
            }
        }

        Poll::Ready(Ok(()))
    }

    // Advisory advertisements run only after control frames and stream output
    // have progressed, so a full queue cannot starve responses or SETTINGS.
    fn poll_alt_svc(&mut self, cx: &mut Context) -> Poll<Result<(), Error>> {
        let Some(receiver) = &mut self.inner.alt_svc_send else {
            return Poll::Ready(Ok(()));
        };
        let mut buffered = false;
        // Poll even an empty channel to wake the driver when a handler emits
        // an advertisement while the connection is otherwise idle.
        for index in 0..ALT_SVC_QUEUE_CAPACITY {
            ready!(self.codec.poll_ready(cx))?;
            let Poll::Ready(Some(frame)) = receiver.poll_recv(cx) else {
                break;
            };
            self.codec.buffer(frame.into())?;
            buffered = true;
            if index + 1 == ALT_SVC_QUEUE_CAPACITY {
                // Resume after this bounded batch, including frames queued
                // concurrently while the batch was drained.
                cx.waker().wake_by_ref();
            }
        }

        if buffered {
            self.codec.flush(cx).map_err(Into::into)
        } else {
            Poll::Ready(Ok(()))
        }
    }

    /// Send any pending GOAWAY frames.
    ///
    /// This will return `Some(reason)` if the connection should be closed
    /// afterwards. If this is a graceful shutdown, this returns `None`.
    fn poll_go_away(&mut self, cx: &mut Context) -> Poll<Option<Result<Reason, Error>>> {
        self.inner.go_away.send_pending_go_away(cx, &mut self.codec)
    }

    pub(crate) fn go_away_from_user(&mut self, e: Reason) {
        self.inner.as_dyn().go_away_from_user(e)
    }

    fn take_error(&mut self, ours: Reason, initiator: Initiator) -> Result<(), Error> {
        let (debug_data, theirs) = self
            .inner
            .error
            .take()
            .as_ref()
            .map_or((Bytes::new(), Reason::NO_ERROR), |frame| {
                (frame.debug_data().clone(), frame.reason())
            });

        match (ours, theirs) {
            (Reason::NO_ERROR, Reason::NO_ERROR) => Ok(()),
            (ours, Reason::NO_ERROR) => Err(Error::GoAway(Bytes::new(), ours, initiator)),
            // If both sides reported an error, give their
            // error back to th user. We assume our error
            // was a consequence of their error, and less
            // important.
            (_, theirs) => Err(Error::remote_go_away(debug_data, theirs)),
        }
    }

    /// Closes the connection by transitioning to a GOAWAY state
    /// iff there are no streams or references
    pub(crate) fn maybe_close_connection_if_no_streams(&mut self) {
        // If we poll() and realize that there are no streams or references
        // then we can close the connection by transitioning to GOAWAY
        if !self.inner.streams.has_streams_or_other_references() {
            self.inner.as_dyn().go_away_now(Reason::NO_ERROR);
        }
    }

    /// Checks if there are any streams
    pub fn has_streams(&self) -> bool {
        self.inner.streams.has_streams()
    }

    /// Checks if there are any streams or references left
    pub(crate) fn has_streams_or_other_references(&self) -> bool {
        // If we poll() and realize that there are no streams or references
        // then we can close the connection by transitioning to GOAWAY
        self.inner.streams.has_streams_or_other_references()
    }

    pub(crate) fn take_user_pings(&mut self) -> Option<UserPings> {
        self.inner.ping_pong.take_user_pings()
    }

    /// Advances the internal state of the connection.
    pub(crate) fn poll(&mut self, cx: &mut Context) -> Poll<Result<(), Error>> {
        // XXX(eliza): cloning the span is unfortunately necessary here in
        // order to placate the borrow checker — `self` is mutably borrowed by
        // `poll2`, which means that we can't borrow `self.span` to enter it.
        // The clone is just an atomic ref bump.
        let span = self.inner.span.clone();
        let _e = span.enter();
        let span = tracing::trace_span!("poll");
        let _e = span.enter();

        loop {
            tracing::trace!("connection state = {:?}", self.inner.state);
            // TODO: probably clean up this glob of code
            match self.inner.state {
                // When open, continue to poll a frame
                State::Open => {
                    let result = match self.poll2(cx) {
                        Poll::Ready(result) => result,
                        // The connection is not ready to make progress
                        Poll::Pending => {
                            // Ensure all window updates have been sent.
                            //
                            // This will also handle flushing `self.codec`
                            ready!(self.inner.streams.poll_complete(cx, &mut self.codec))?;
                            ready!(self.poll_alt_svc(cx))?;

                            if (self.inner.error.is_some()
                                || self.inner.go_away.should_close_on_idle())
                                && !self.inner.streams.has_streams()
                            {
                                self.inner.as_dyn().go_away_now(Reason::NO_ERROR);
                                continue;
                            }

                            return Poll::Pending;
                        }
                    };

                    self.inner.as_dyn().handle_poll2_result(result)?
                }
                State::Closing(reason, initiator) => {
                    tracing::trace!("connection closing after flush");
                    // Flush/shutdown the codec
                    ready!(self.codec.shutdown(cx))?;

                    // Transition the state to error
                    self.inner.state = State::Closed(reason, initiator);
                }
                State::Closed(reason, initiator) => {
                    return Poll::Ready(self.take_error(reason, initiator));
                }
            }
        }
    }

    fn poll2(&mut self, cx: &mut Context) -> Poll<Result<(), Error>> {
        // This happens outside of the loop to prevent needing to do a clock
        // check and then comparison of the queue possibly multiple times a
        // second (and thus, the clock wouldn't have changed enough to matter).
        self.clear_expired_reset_streams();

        loop {
            // First, ensure that the `Connection` is able to receive a frame
            //
            // The order here matters:
            // - poll_go_away may buffer a graceful shutdown GOAWAY frame
            // - If it has, we've also added a PING to be sent in poll_ready
            if let Some(reason) = ready!(self.poll_go_away(cx)?) {
                if self.inner.go_away.should_close_now() {
                    if self.inner.go_away.is_user_initiated() {
                        // A user initiated abrupt shutdown shouldn't return
                        // the same error back to the user.
                        return Poll::Ready(Ok(()));
                    } else {
                        return Poll::Ready(Err(Error::library_go_away(reason)));
                    }
                }
                // Only NO_ERROR should be waiting for idle
                debug_assert_eq!(
                    reason,
                    Reason::NO_ERROR,
                    "graceful GOAWAY should be NO_ERROR"
                );
            }
            ready!(self.poll_ready(cx))?;

            match self
                .inner
                .as_dyn()
                .recv_frame(ready!(Pin::new(&mut self.codec).poll_next(cx)?))?
            {
                ReceivedFrame::Settings(frame) => {
                    self.inner.settings.recv_settings(
                        frame,
                        &mut self.codec,
                        &mut self.inner.streams,
                    )?;
                }
                ReceivedFrame::Refused(id) => {
                    debug_assert!(self.inner.pending_refusal.is_none());
                    self.inner.pending_refusal = Some(id);
                }
                ReceivedFrame::Continue => (),
                ReceivedFrame::Done => {
                    return Poll::Ready(Ok(()));
                }
            }
        }
    }

    fn clear_expired_reset_streams(&mut self) {
        self.inner.streams.clear_expired_reset_streams();
    }
}

impl<P, B> ConnectionInner<P, B>
where
    P: Peer,
    B: Buf,
{
    fn as_dyn(&mut self) -> DynConnection<'_, B> {
        let Self {
            state,
            go_away,
            streams,
            error,
            ping_pong,
            alt_svc_observer,
            ..
        } = self;
        let streams = streams.as_dyn();
        DynConnection {
            state,
            go_away,
            streams,
            error,
            ping_pong,
            alt_svc_observer,
        }
    }
}

impl<B> DynConnection<'_, B>
where
    B: Buf,
{
    fn go_away(&mut self, id: StreamId, e: Reason) {
        let frame = frame::GoAway::new(id, e);
        self.streams.send_go_away(id);
        self.go_away.go_away(frame);
    }

    fn go_away_now(&mut self, e: Reason) {
        let last_processed_id = self.streams.last_processed_id();
        let frame = frame::GoAway::new(last_processed_id, e);
        self.go_away.go_away_now(frame);
    }

    fn go_away_now_data(&mut self, e: Reason, data: Bytes) {
        let last_processed_id = self.streams.last_processed_id();
        let frame = frame::GoAway::with_debug_data(last_processed_id, e, data);
        self.go_away.go_away_now(frame);
    }

    fn go_away_from_user(&mut self, e: Reason) {
        let last_processed_id = self.streams.last_processed_id();
        let frame = frame::GoAway::new(last_processed_id, e);
        self.go_away.go_away_from_user(frame);

        // Notify all streams of reason we're abruptly closing.
        self.streams.handle_error(Error::user_go_away(e));
    }

    fn handle_poll2_result(&mut self, result: Result<(), Error>) -> Result<(), Error> {
        match result {
            // The connection has shutdown normally
            Ok(()) => {
                *self.state = State::Closing(Reason::NO_ERROR, Initiator::Library);
                Ok(())
            }
            // Attempting to read a frame resulted in a connection level
            // error. This is handled by setting a GOAWAY frame followed by
            // terminating the connection.
            Err(Error::GoAway(debug_data, reason, initiator)) => {
                self.handle_go_away(reason, debug_data, initiator);
                Ok(())
            }
            // Attempting to read a frame resulted in a stream level error.
            // Locally detected stream errors are reported to the peer with
            // RST_STREAM. Remotely initiated resets have already been applied
            // by the streams state machine and must not be echoed back.
            Err(Error::Reset(id, reason, initiator)) => {
                if initiator == Initiator::Remote {
                    tracing::trace!(?id, ?reason, ?initiator, "stream reset");
                    return Ok(());
                }

                debug_assert_eq!(initiator, Initiator::Library);
                tracing::trace!(?id, ?reason, ?initiator, "stream error");
                match self.streams.send_reset(id, reason) {
                    Ok(()) => (),
                    Err(crate::h2::proto::error::GoAway { debug_data, reason }) => {
                        self.handle_go_away(reason, debug_data, Initiator::Library);
                    }
                }
                Ok(())
            }
            Err(Error::User(err)) => {
                tracing::debug!("connection::poll; user error: {err:?}");
                let e = Error::User(err);

                // Reset all active streams
                self.streams.handle_error(e.clone());

                Err(e)
            }
            // Attempting to read a frame resulted in an I/O error. All
            // active streams must be reset.
            //
            // TODO: Are I/O errors recoverable?
            Err(Error::Io(kind, inner)) => {
                tracing::debug!("Connection::poll; IO error: {kind:?}");
                let e = Error::Io(kind, inner);

                // Reset all active streams
                self.streams.handle_error(e.clone());

                // Some client implementations drop the connections without notifying its peer
                // Attempting to read after the client dropped the connection results in UnexpectedEof
                // If as a server, we don't have anything more to send, just close the connection
                // without error
                //
                // See https://github.com/hyperium/hyper/issues/3427
                if self.streams.is_buffer_empty()
                    && matches!(kind, io::ErrorKind::UnexpectedEof)
                    && (self.streams.is_server()
                        || self.error.as_ref().map(|f| f.reason() == Reason::NO_ERROR)
                            == Some(true))
                {
                    *self.state = State::Closed(Reason::NO_ERROR, Initiator::Library);
                    return Ok(());
                }

                // Return the error
                Err(e)
            }
        }
    }

    fn handle_go_away(&mut self, reason: Reason, debug_data: Bytes, initiator: Initiator) {
        let e = Error::GoAway(debug_data.clone(), reason, initiator);
        // GoAway(NO_ERROR) is a clean graceful shutdown — not an error.
        if reason == Reason::NO_ERROR {
            tracing::trace!(error = ?e, "Connection::poll; connection closing gracefully (GoAway NO_ERROR)");
        } else {
            tracing::debug!(error = ?e, "Connection::poll; connection error");
        }

        // We may have already sent a GOAWAY for this error,
        // if so, don't send another, just flush and close up.
        if self
            .go_away
            .going_away()
            .is_some_and(|frame| frame.reason() == reason)
        {
            tracing::trace!("    -> already going away");
            *self.state = State::Closing(reason, initiator);
            return;
        }

        // Reset all active streams
        self.streams.handle_error(e);
        self.go_away_now_data(reason, debug_data);
    }

    fn recv_frame(&mut self, frame: Option<Frame>) -> Result<ReceivedFrame, Error> {
        match frame {
            Some(Frame::Headers(frame)) => {
                tracing::trace!("recv HEADERS: {frame:?}");
                match self.streams.recv_headers(frame)? {
                    streams::RecvOutcome::Processed => (),
                    streams::RecvOutcome::Refused(id) => return Ok(ReceivedFrame::Refused(id)),
                }
            }
            Some(Frame::Data(frame)) => {
                tracing::trace!("recv DATA: {frame:?}");
                self.streams.recv_data(frame)?;
            }
            Some(Frame::Reset(frame)) => {
                tracing::trace!("recv RST_STREAM: {frame:?}");
                self.streams.recv_reset(frame)?;
            }
            Some(Frame::PushPromise(frame)) => {
                tracing::trace!("recv PUSH_PROMISE: {frame:?}");
                match self.streams.recv_push_promise(frame)? {
                    streams::RecvOutcome::Processed => (),
                    streams::RecvOutcome::Refused(id) => return Ok(ReceivedFrame::Refused(id)),
                }
            }
            Some(Frame::Settings(frame)) => {
                tracing::trace!("recv SETTINGS: {frame:?}");
                return Ok(ReceivedFrame::Settings(frame));
            }
            Some(Frame::GoAway(frame)) => {
                tracing::trace!("recv GOAWAY: {frame:?}");
                // This should prevent starting new streams,
                // but should allow continuing to process current streams
                // until they are all EOS. Once they are, State should
                // transition to GoAway.
                self.streams.recv_go_away(&frame)?;
                *self.error = Some(frame);
            }
            Some(Frame::Ping(frame)) => {
                tracing::trace!("recv PING: {frame:?}");
                let status = self.ping_pong.recv_ping(frame);
                if status.is_shutdown() {
                    assert!(
                        self.go_away.is_going_away(),
                        "received unexpected shutdown ping"
                    );

                    let last_processed_id = self.streams.last_processed_id();
                    self.go_away(last_processed_id, Reason::NO_ERROR);
                }
            }
            Some(Frame::WindowUpdate(frame)) => {
                tracing::trace!("recv WINDOW_UPDATE: {frame:?}");
                self.streams.recv_window_update(frame)?;
            }
            Some(Frame::AltSvc(frame)) => {
                if let Some((observer, extensions)) = self.alt_svc_observer
                    && frame.payload_len() <= ALT_SVC_MAX_PAYLOAD
                {
                    let (id, explicit_origin, field_value) = frame.into_parts();
                    let origin = if id.is_zero() {
                        Some(AltSvcOrigin::Explicit(explicit_origin))
                    } else {
                        self.streams.alt_svc_origin(id).map(AltSvcOrigin::Request)
                    };
                    if let Some(origin) = origin {
                        let received = AltSvcReceivedAt::now();
                        observer.observe(
                            AltSvcEvent {
                                origin,
                                field_value,
                                received_at: received.instant.into(),
                                sequence: received.sequence,
                            },
                            extensions,
                        );
                    }
                }
            }
            Some(Frame::Priority(frame)) => {
                tracing::trace!("recv PRIORITY: {frame:?}");
                self.streams.recv_priority(&frame)?;
            }
            None => {
                tracing::trace!("codec closed");
                self.streams.recv_eof(false);
                return Ok(ReceivedFrame::Done);
            }
        }
        Ok(ReceivedFrame::Continue)
    }
}

enum ReceivedFrame {
    Refused(StreamId),
    Settings(frame::Settings),
    Continue,
    Done,
}

impl<T, B> Connection<T, client::Peer, B>
where
    T: AsyncRead + AsyncWrite,
    B: Buf,
{
    pub(crate) fn streams(&self) -> &Streams<B, client::Peer> {
        &self.inner.streams
    }
}

impl<T, B> Connection<T, server::Peer, B>
where
    T: AsyncRead + AsyncWrite + Unpin,
    B: Buf,
{
    pub(crate) fn send_alt_svc(&self, frame: frame::AltSvc) -> Result<(), AltSvcSendError>
    where
        T: ExtensionsRef,
    {
        self.codec
            .extensions()
            .get_ref::<AltSvcSender>()
            .ok_or(AltSvcSendError::Disabled)?
            .try_send(frame)
    }

    /// What the deadlines see: a header block in progress, open streams, or neither.
    ///
    /// A few bytes whose frame type has not arrived yet are a head in progress
    /// only on a connection without streams, where nothing else can be pending.
    pub(crate) fn timeout_activity(&self) -> Activity {
        match self.codec.head_progress() {
            Some(HeadProgress {
                bytes,
                block,
                certain: true,
            }) => Activity::Head { bytes, block },
            _ if self.inner.streams.has_streams() => Activity::Busy,
            Some(HeadProgress { bytes, block, .. }) => Activity::Head { bytes, block },
            None => Activity::Idle,
        }
    }

    /// The round trip of the initial SETTINGS, once, when their ACK arrived.
    pub(crate) fn take_settings_rtt(&mut self) -> Option<Duration> {
        self.inner.settings.take_rtt()
    }

    pub(crate) fn next_incoming(&mut self) -> Option<StreamRef<B>> {
        self.inner.streams.next_incoming()
    }

    // Graceful shutdown only makes sense for server peers.
    pub(crate) fn go_away_gracefully(&mut self) {
        if self.inner.go_away.is_going_away() {
            // No reason to start a new one.
            return;
        }

        // According to http://httpwg.org/specs/rfc7540.html#GOAWAY:
        //
        // > A server that is attempting to gracefully shut down a connection
        // > SHOULD send an initial GOAWAY frame with the last stream
        // > identifier set to 2^31-1 and a NO_ERROR code. This signals to the
        // > client that a shutdown is imminent and that initiating further
        // > requests is prohibited. After allowing time for any in-flight
        // > stream creation (at least one round-trip time), the server can
        // > send another GOAWAY frame with an updated last stream identifier.
        // > This ensures that a connection can be cleanly shut down without
        // > losing requests.
        self.inner.as_dyn().go_away(StreamId::MAX, Reason::NO_ERROR);

        // We take the advice of waiting 1 RTT literally, and wait
        // for a pong before proceeding.
        self.inner.ping_pong.ping_shutdown();
    }
}

impl<T, P, B> Drop for Connection<T, P, B>
where
    P: Peer,
    B: Buf,
{
    fn drop(&mut self) {
        self.inner.streams.recv_eof(true);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auto_data_frame_budget_scales_with_connection_window() {
        assert_eq!(
            DataFrameBudget::Auto.resolve(None),
            DEFAULT_INITIAL_WINDOW_SIZE as usize / 2
        );
        assert_eq!(
            DataFrameBudget::Auto.resolve(Some(DEFAULT_INITIAL_WINDOW_SIZE)),
            DEFAULT_INITIAL_WINDOW_SIZE as usize / 2
        );
        assert_eq!(DataFrameBudget::Auto.resolve(Some(1024 * 1024)), 512 * 1024);
    }

    #[test]
    fn auto_data_frame_budget_has_minimum() {
        assert_eq!(
            DataFrameBudget::Auto.resolve(Some(1)),
            DEFAULT_DATA_FRAME_BUDGET
        );
        assert_eq!(
            DataFrameBudget::Auto.resolve(Some(MAX_WINDOW_SIZE)),
            MAX_WINDOW_SIZE as usize / 2
        );
    }

    #[test]
    fn configured_data_frame_budget_is_unchanged() {
        assert_eq!(
            DataFrameBudget::Configured(123).resolve(Some(MAX_WINDOW_SIZE)),
            123
        );
    }
}
