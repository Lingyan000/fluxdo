#![expect(
    clippy::needless_pass_by_ref_mut,
    reason = "vendored from upstream `h2`: many `&mut self` methods preserve API symmetry/locking-position semantics that the `&self` form would lose"
)]

use super::recv::RecvHeaderBlockError;
use super::store::{self, Entry, Resolve, Store};
use super::{
    Buffer, BufferStatus, Config, Counts, LocalStreams, Prioritized, Recv, Send, Stream, StreamId,
};
use crate::h2::codec::{Codec, UserError};
use crate::h2::proto::{Error, Initiator, Open, Peer, WindowSize, peer};
use crate::h2::{client, proto, server};

use parking_lot::Mutex;
use rama_core::bytes::{Buf, Bytes};
use rama_core::extensions::{Egress, Extensions, ExtensionsRef};
use rama_core::telemetry::tracing;
use rama_http::proto::RequestHeaders;
use rama_http::proto::h2::frame::EarlyFrameStreamContext;
use rama_http_types::conn::HttpOrigin;
use rama_http_types::proto::ext::Protocol;
use rama_http_types::proto::h2::PseudoHeaderOrder;
use rama_http_types::proto::h2::alt_svc::AltSvcObserverExtension;
use rama_http_types::proto::h2::frame::{self, Frame, Reason, Settings};
use rama_http_types::{HeaderMap, Request, Response};
use rama_net::conn::{ConnectionHealthWatcher, MaxConcurrency};
use rama_net::{AuthorityInputExt, ProtocolInputExt};
use std::task::{Context, Poll, Waker};
use tokio::io::AsyncWrite;

use std::sync::Arc;
use std::{fmt, io};

/// Whether replay advanced, must wait for stream state, or queued SETTINGS.
pub(crate) enum ReplayStep {
    Idle,
    Advanced,
    Settings(Settings),
}

#[derive(Debug)]
pub(crate) struct Streams<B, P>
where
    P: Peer,
{
    /// Holds most of the connection and stream related state for processing
    /// HTTP/2 frames associated with streams.
    inner: Arc<Mutex<Inner>>,

    /// This is the queue of frames to be written to the wire. This is split out
    /// to avoid requiring a `B` generic on all public API types even if `B` is
    /// not technically required.
    ///
    /// Currently, splitting this out requires a second `Arc` + `Mutex`.
    /// However, it should be possible to avoid this duplication with a little
    /// bit of unsafe code. This optimization has been postponed until it has
    /// been shown to be necessary.
    send_buffer: Arc<SendBuffer<B>>,

    _p: ::std::marker::PhantomData<P>,
}

// Like `Streams` but with a `peer::Dyn` field instead of a static `P: Peer` type parameter.
// Ensures that the methods only get one instantiation, instead of two (client and server)
#[derive(Debug)]
pub(crate) struct DynStreams<'a, B> {
    inner: &'a Mutex<Inner>,

    send_buffer: &'a SendBuffer<B>,

    peer: peer::Dyn,
}

/// Outcome of receiving a frame that can open a stream.
#[derive(Debug)]
#[must_use = "a refused stream must be reset by the connection"]
pub(crate) enum RecvOutcome {
    /// The frame was handled, including any intentional ignoring of it.
    Processed,
    /// The connection must send REFUSED_STREAM for this stream ID.
    Refused(StreamId),
}

/// Reference to the stream state
#[derive(Debug)]
pub(crate) struct StreamRef<B> {
    opaque: OpaqueStreamRef,
    send_buffer: Arc<SendBuffer<B>>,
}

/// Reference to the stream state that hides the send data chunk generic
pub(crate) struct OpaqueStreamRef {
    inner: Arc<Mutex<Inner>>,
    key: store::Key,
}

/// Fields needed to manage state related to managing the set of streams. This
/// is mostly split out to make ownership happy.
///
/// TODO: better name
#[derive(Debug)]
struct Inner {
    extensions: Extensions,

    /// Tracks send & recv stream concurrency.
    counts: Counts,

    /// Connection level state and performs actions on streams
    actions: Actions,

    /// Stores stream state
    store: Store,

    /// The number of stream refs to this shared state.
    refs: usize,

    /// Pseudo order of the headers stream
    headers_pseudo_order: Option<PseudoHeaderOrder>,

    /// early frame ctx
    early_frame_ctx: EarlyFrameStreamContext,
}

#[derive(Debug)]
struct Actions {
    /// Manages state transitions initiated by receiving frames
    recv: Recv,

    /// Manages state transitions initiated by sending frames
    send: Send,

    /// Task that calls `poll_complete`.
    task: Option<Waker>,

    /// If the connection errors, a copy is kept for any StreamRefs.
    conn_error: Option<proto::Error>,

    /// The connection was dropped: nothing drains the queues any more.
    conn_dropped: bool,
}

/// Contains the buffer of frames to be written to the wire.
#[derive(Debug)]
struct SendBuffer<B> {
    inner: Mutex<Buffer<Frame<B>>>,
}

// ===== impl Streams =====

impl<B, P> Streams<B, P>
where
    B: Buf,
    P: Peer,
{
    pub(crate) fn try_new(
        config: Config,
        extensions: Extensions,
    ) -> Result<Self, crate::h2::proto::Error> {
        let peer = P::r#dyn();

        ConnectionHealthWatcher::install(&extensions);
        // same install-at-this-level rule: extensions forked off another
        // connection must not adopt that connection's concurrency limit
        extensions.self_get_ref_or_insert(|| MaxConcurrency::new(config.initial_max_send_streams));

        Ok(Self {
            inner: Inner::try_new(peer, config, extensions)?,
            send_buffer: Arc::new(SendBuffer::new()),
            _p: ::std::marker::PhantomData,
        })
    }

    pub(crate) fn set_target_connection_window_size(
        &mut self,
        size: WindowSize,
    ) -> Result<(), Reason> {
        self.inner.lock().set_target_connection_window(size)
    }

    pub(crate) fn next_incoming(&mut self) -> Option<StreamRef<B>> {
        let mut me = self.inner.lock();
        let me = &mut *me;
        me.actions.recv.next_incoming(&mut me.store).map(|key| {
            let stream = &mut me.store.resolve(key);
            tracing::trace!(
                "next_incoming; id={:?}, state={:?}",
                stream.id,
                stream.state
            );
            // TODO: ideally, OpaqueStreamRefs::new would do this, but we're holding
            // the lock, so it can't.
            me.refs += 1;

            // Pending-accepted remotely-reset streams are counted.
            if stream.state.is_remote_reset() {
                me.counts.dec_num_remote_reset_streams();
            }

            StreamRef {
                opaque: OpaqueStreamRef::new(self.inner.clone(), stream),
                send_buffer: self.send_buffer.clone(),
            }
        })
    }

    /// Count a refused stream toward the local error reset limit.
    pub(crate) fn count_pending_refusal(&mut self) -> Result<(), Error> {
        let mut me = self.inner.lock();
        if !me.counts.can_inc_num_local_error_resets() {
            return Err(Error::library_go_away_data(
                Reason::ENHANCE_YOUR_CALM,
                "too_many_internal_resets",
            ));
        }
        me.counts.inc_num_local_error_resets();
        Ok(())
    }

    /// Replays the next early frame. SETTINGS waits for any outstanding local
    /// SETTINGS acknowledgment. Stream window raises are sent with their HEADERS.
    pub(crate) fn send_pending<T>(
        &mut self,
        cx: &mut Context,
        dst: &mut Codec<T, Prioritized<B>>,
        settings_synced: bool,
    ) -> Poll<Result<ReplayStep, Error>>
    where
        T: AsyncWrite + Unpin,
    {
        // Ensure an early frame can be buffered before consuming it from the
        // replay context. Do not wait on write readiness when there is no
        // replay frame: doing so can starve reads while an unrelated DATA
        // frame is blocked in the codec (for example, a peer error that should
        // terminate that blocked write).
        {
            let me = self.inner.lock();
            let next_stream_id = me.actions.send.peek_next_id();
            if !me.early_frame_ctx.can_replay_next_frame(next_stream_id) {
                // A stream-targeted frame can precede the request which creates
                // that stream. Retain it until opening the stream wakes us.
                return Poll::Ready(Ok(ReplayStep::Idle));
            }
            if !settings_synced && me.early_frame_ctx.next_frame_is_settings() {
                return Poll::Ready(Ok(ReplayStep::Idle));
            }
        }
        ready!(dst.poll_ready(cx))?;

        let mut me = self.inner.lock();
        let me = &mut *me;

        let next_stream_id = me.actions.send.peek_next_id();
        let first_connection_window = !me.early_frame_ctx.has_replayed_connection_window();
        match me.early_frame_ctx.replay_next_frame(next_stream_id) {
            Some(early_frame) => {
                let has_more = me.early_frame_ctx.has_replay_frame();
                let frame: Frame<Prioritized<B>> = match early_frame {
                    frame::EarlyFrame::Priority(priority) => priority.into(),
                    frame::EarlyFrame::Settings(settings) => {
                        // NOTE: if ever issues, we might need to do something locally with settings as well
                        if has_more {
                            cx.waker().wake_by_ref();
                        }
                        return Poll::Ready(Ok(if settings.flags.is_ack() {
                            ReplayStep::Advanced
                        } else {
                            ReplayStep::Settings(settings)
                        }));
                    }
                    frame::EarlyFrame::WindowUpdate(window_update) => {
                        tracing::trace!(
                            "replay: increment h2 window update size w/ {}",
                            window_update.size_increment
                        );
                        let replay = match me.actions.recv.prepare_replayed_connection_window(
                            window_update.size_increment,
                            first_connection_window,
                        ) {
                            Ok(replay) => replay,
                            Err(reason) => {
                                tracing::debug!(
                                    "h2 streams: failed to replay window update: reason = {reason}; go away"
                                );
                                return Poll::Ready(Err(Error::library_go_away(reason)));
                            }
                        };
                        if let Err(error) = dst.buffer(window_update.into()) {
                            return Poll::Ready(Err(error.into()));
                        }
                        let target = replay.target;
                        me.actions.recv.commit_replayed_connection_window(replay);
                        me.counts.set_target_connection_window_size(target);
                        if has_more {
                            cx.waker().wake_by_ref();
                        }
                        return Poll::Ready(Ok(ReplayStep::Advanced));
                    }
                };
                let result = match dst.buffer(frame) {
                    Ok(_) => Ok(ReplayStep::Advanced),
                    Err(err) => Err(err.into()),
                };
                if result.is_ok() && has_more {
                    cx.waker().wake_by_ref();
                }
                Poll::Ready(result)
            }
            None => Poll::Ready(Ok(ReplayStep::Idle)),
        }
    }

    pub(crate) fn clear_expired_reset_streams(&mut self) {
        let mut me = self.inner.lock();
        let me = &mut *me;
        me.actions
            .recv
            .clear_expired_reset_streams(&mut me.store, &mut me.counts);
    }

    pub(crate) fn poll_complete<T>(
        &mut self,
        cx: &mut Context,
        dst: &mut Codec<T, Prioritized<B>>,
    ) -> Poll<Result<(), crate::h2::proto::Error>>
    where
        T: AsyncWrite + Unpin,
    {
        loop {
            // Make any required socket progress before taking stream locks.
            ready!(dst.poll_ready(cx))?;

            let status = {
                let mut me = self.inner.lock();
                let status = me.buffer_pending(&self.send_buffer, dst)?;

                // Register the task while holding the same lock used to
                // observe that all pending frames have been buffered. A
                // producer that queues another frame while the codec is being
                // flushed will then take and wake this task.
                if status == BufferStatus::Complete {
                    me.actions.task = Some(cx.waker().clone());
                }

                status
            };

            match status {
                BufferStatus::Complete => {}
                BufferStatus::CodecFull => continue,
            }

            // Flush any frames staged by `buffer_pending` without holding the
            // stream-state or send-buffer mutexes.
            ready!(dst.flush(cx))?;

            let reclaimed = {
                let mut me = self.inner.lock();
                me.reclaim_written_frame(&self.send_buffer, dst)
            };

            if !reclaimed {
                return Poll::Ready(Ok(()));
            }
        }
    }

    pub(crate) fn apply_remote_settings(
        &mut self,
        frame: &frame::Settings,
        is_initial: bool,
    ) -> Result<(), Error> {
        let mut me = self.inner.lock();
        let me = &mut *me;

        // A server must not enable push (RFC 9113 §6.5.2).
        if !me.counts.peer().is_server() && frame.config.enable_push.is_some_and(|value| value != 0)
        {
            return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
        }

        let mut send_buffer = self.send_buffer.inner.lock();
        let send_buffer = &mut *send_buffer;

        me.counts.apply_remote_settings(frame, is_initial);

        // Update MaxConcurrency with this new config so a connection pool
        // can take this into account (multiplex pool supports this being dynamic)
        if let Some(max) = frame.config.max_concurrent_streams
            && let Some(concurrency) = me.extensions.get_ref::<MaxConcurrency>()
        {
            concurrency.set(max as usize);
        }

        me.actions.send.apply_remote_settings(
            frame,
            send_buffer,
            &mut me.store,
            &mut me.counts,
            &mut me.actions.task,
        )?;

        Ok(())
    }

    pub(crate) fn record_remote_settings(&mut self, frame: &frame::Settings) {
        let mut me = self.inner.lock();
        me.early_frame_ctx.record_settings_frame(frame);
    }

    pub(crate) fn apply_local_settings(
        &mut self,
        frame: &frame::Settings,
        ack: &frame::Settings,
    ) -> Result<(), Error> {
        let mut me = self.inner.lock();

        me.early_frame_ctx.record_settings_frame(ack);

        let me = &mut *me;

        me.actions.recv.apply_local_settings(frame, &mut me.store)
    }

    pub(crate) fn send_request(
        &mut self,
        request: Request<()>,
        end_of_stream: bool,
        pending: Option<&OpaqueStreamRef>,
    ) -> Result<(StreamRef<B>, bool), crate::h2::Error> {
        use super::stream::ContentLength;
        use rama_http_types::Method;

        let protocol = request.extensions().get_ref::<Protocol>().cloned();

        // TODO: There is a hazard with assigning a stream ID before the
        // prioritize layer. If prioritization reorders new streams, this
        // implicitly closes the earlier stream IDs.
        //
        // See: hyperium/h2#11
        let mut me = self.inner.lock();
        let me = &mut *me;

        let mut send_buffer = self.send_buffer.inner.lock();
        let send_buffer = &mut *send_buffer;

        me.actions.ensure_no_conn_error()?;
        me.actions.send.ensure_next_stream_id()?;
        // RFC 8441 §4: `:protocol` only extends CONNECT, as on HTTP/3.
        if protocol.is_some() && request.method() != Method::CONNECT {
            return Err(UserError::MalformedHeaders.into());
        }
        if protocol.is_some() && !me.actions.send.is_extended_connect_protocol_enabled() {
            return Err(UserError::ExtendedConnectNotEnabled.into());
        }

        // The `pending` argument is provided by the `Client`, and holds
        // a store `Key` of a `Stream` that may have been not been opened
        // yet.
        //
        // If that stream is still pending, the Client isn't allowed to
        // queue up another pending stream. They should use `poll_ready`.
        if let Some(stream) = pending
            && me.store.resolve(stream.key).is_pending_open
        {
            return Err(UserError::Rejected.into());
        }

        if me.counts.peer().is_server() {
            // Servers cannot open streams. PushPromise must first be reserved.
            return Err(UserError::UnexpectedFrameType.into());
        }

        let stream_id = me.actions.send.open()?;

        // Convert the message
        let alt_svc_origin = me
            .extensions
            .contains::<AltSvcObserverExtension>()
            .then(|| {
                request.target_protocol().and_then(|protocol| {
                    let authority = request
                        .target_authority()?
                        .into_host_with_port(protocol.default_port())?;
                    HttpOrigin::new(protocol.clone(), authority).ok()
                })
            })
            .flatten();
        let request_method = request.method().clone();
        let (mut headers, req_ext) = client::Peer::convert_send_message(
            stream_id,
            request,
            protocol,
            end_of_stream,
            me.headers_pseudo_order.clone(),
            None,
        )?;
        // The fields the frame sends, shared rather than copied.
        req_ext.insert(RequestHeaders::from(headers.share_fields()));

        let mut stream = Stream::try_new(
            stream_id,
            me.actions.send.init_window_sz(),
            me.actions.recv.init_window_sz(),
            &me.extensions,
        ).map_err(|err| {
            tracing::warn!("failed to create stream for id {stream_id:?} in send_request: {err}; library GO AWAY");
            Error::library_go_away(err)
        })?;

        // Refine the connection snapshot to this HTTP/2 stream, including
        // stream-specific metadata that was unavailable to the outer layers.
        req_ext.insert(Egress(stream.extensions.clone()));
        stream.req_extensions = Some(req_ext);
        stream.alt_svc_origin = alt_svc_origin;

        match request_method {
            Method::HEAD => stream.content_length = ContentLength::Head,
            Method::CONNECT => stream.content_length = ContentLength::Connect,
            _ => {}
        }

        let mut stream = me.store.insert(stream.id, stream);

        let sent = me.actions.send.send_headers(
            headers,
            send_buffer,
            &mut stream,
            &mut me.counts,
            &mut me.actions.task,
        );

        // send_headers can return a UserError, if it does,
        // we should forget about this stream.
        if let Err(err) = sent {
            stream.unlink();
            stream.remove();
            return Err(err.into());
        }

        // Given that the stream has been initialized, it should not be in the
        // closed state.
        debug_assert!(!stream.state.is_closed());
        me.counts.open_local(&mut stream);

        // TODO: ideally, OpaqueStreamRefs::new would do this, but we're holding
        // the lock, so it can't.
        me.refs += 1;

        let is_full = me.counts.next_send_stream_will_reach_capacity();
        Ok((
            StreamRef {
                opaque: OpaqueStreamRef::new(self.inner.clone(), &mut stream),
                send_buffer: self.send_buffer.clone(),
            },
            is_full,
        ))
    }

    pub(crate) fn is_extended_connect_protocol_enabled(&self) -> bool {
        self.inner
            .lock()
            .actions
            .send
            .is_extended_connect_protocol_enabled()
    }

    /// Cheap clone of the shared `PeerSettingsState` cell — the canonical
    /// handle for observing the peer's initial SETTINGS frame. Holding
    /// the returned `Arc` does NOT extend the connection's lifetime.
    pub(crate) fn peer_settings_state(
        &self,
    ) -> std::sync::Arc<crate::h2::proto::PeerSettingsState> {
        self.inner.lock().actions.send.peer_settings_state()
    }

    pub(crate) fn current_max_send_streams(&self) -> usize {
        let me = self.inner.lock();
        me.counts.max_send_streams()
    }

    pub(crate) fn local_streams(&self) -> Arc<LocalStreams> {
        self.inner.lock().counts.local_streams()
    }

    pub(crate) fn current_max_recv_streams(&self) -> usize {
        let me = self.inner.lock();
        me.counts.max_recv_streams()
    }
}

impl<B> DynStreams<'_, B> {
    pub(crate) fn is_buffer_empty(&self) -> bool {
        self.send_buffer.is_empty()
    }

    pub(crate) fn is_server(&self) -> bool {
        self.peer.is_server()
    }

    /// Reports whether the connection must refuse the stream opened by the peer.
    pub(crate) fn recv_headers(&mut self, frame: frame::Headers) -> Result<RecvOutcome, Error> {
        let mut me = self.inner.lock();
        me.recv_headers(self.peer, self.send_buffer, frame)
    }

    pub(crate) fn recv_data(&mut self, frame: frame::Data) -> Result<(), Error> {
        let mut me = self.inner.lock();
        me.recv_data(self.peer, self.send_buffer, frame)
    }

    pub(crate) fn recv_reset(&mut self, frame: frame::Reset) -> Result<(), Error> {
        let mut me = self.inner.lock();

        me.recv_reset(self.send_buffer, frame)
    }

    /// Notify all streams that a connection-level error happened.
    pub(crate) fn handle_error(&mut self, err: proto::Error) -> StreamId {
        let mut me = self.inner.lock();
        me.handle_error(self.send_buffer, err)
    }

    pub(crate) fn recv_go_away(&mut self, frame: &frame::GoAway) -> Result<(), Error> {
        let mut me = self.inner.lock();
        me.recv_go_away(self.send_buffer, frame)
    }

    pub(crate) fn last_processed_id(&self) -> StreamId {
        self.inner.lock().actions.recv.last_processed_id()
    }

    pub(crate) fn recv_window_update(&mut self, frame: frame::WindowUpdate) -> Result<(), Error> {
        let mut me = self.inner.lock();
        me.early_frame_ctx.record_windows_update_frame(frame);
        me.recv_window_update(self.send_buffer, frame)
    }

    pub(crate) fn alt_svc_origin(&mut self, id: StreamId) -> Option<HttpOrigin> {
        let mut me = self.inner.lock();
        let stream = me.store.find_mut(id)?;
        if stream.is_pending_open {
            return None;
        }
        stream.alt_svc_origin.clone()
    }

    pub(crate) fn recv_priority(&mut self, frame: &frame::Priority) -> Result<(), Error> {
        let mut me = self.inner.lock();
        me.early_frame_ctx.record_priority_frame(frame);
        Ok(())
    }

    /// Reports whether the connection must refuse the promised stream.
    pub(crate) fn recv_push_promise(
        &mut self,
        frame: frame::PushPromise,
    ) -> Result<RecvOutcome, Error> {
        let mut me = self.inner.lock();
        me.recv_push_promise(self.send_buffer, frame)
    }

    pub(crate) fn recv_eof(&mut self, clear_pending_accept: bool) {
        let mut me = self.inner.lock();
        me.recv_eof(self.send_buffer, clear_pending_accept)
    }

    pub(crate) fn send_reset(
        &mut self,
        id: StreamId,
        reason: Reason,
    ) -> Result<(), crate::h2::proto::error::GoAway> {
        let mut me = self.inner.lock();
        me.send_reset(self.send_buffer, id, reason)
    }

    pub(crate) fn send_go_away(&mut self, last_processed_id: StreamId) {
        let mut me = self.inner.lock();
        me.actions.recv.go_away(last_processed_id);
    }
}

impl Inner {
    fn try_new(
        peer: peer::Dyn,
        config: Config,
        extensions: Extensions,
    ) -> Result<Arc<Mutex<Self>>, crate::h2::proto::Error> {
        Ok(Arc::new(Mutex::new(Self {
            counts: Counts::new(peer, &config),
            extensions,
            actions: Actions {
                recv: Recv::try_new(peer, &config)?,
                send: Send::try_new(&config)?,
                task: None,
                conn_error: None,
                conn_dropped: false,
            },
            store: Store::new(),
            refs: 1,
            headers_pseudo_order: config.headers_pseudo_order,
            early_frame_ctx: config.early_frame_ctx,
        })))
    }

    /// Sets the target connection window and the DATA frame budget following it.
    fn set_target_connection_window(&mut self, size: WindowSize) -> Result<(), Reason> {
        self.actions
            .recv
            .set_target_connection_window(size, &mut self.actions.task)?;
        self.counts.set_target_connection_window_size(size);
        Ok(())
    }

    fn recv_headers<B>(
        &mut self,
        peer: peer::Dyn,
        send_buffer: &SendBuffer<B>,
        frame: frame::Headers,
    ) -> Result<RecvOutcome, Error> {
        let id = frame.stream_id();

        // The GOAWAY process has begun. All streams with a greater ID than
        // specified as part of GOAWAY should be ignored.
        if id > self.actions.recv.max_stream_id() {
            tracing::trace!(
                "id ({:?}) > max_stream_id ({:?}), ignoring HEADERS",
                id,
                self.actions.recv.max_stream_id()
            );
            return Ok(RecvOutcome::Processed);
        }

        let key = match self.store.find_entry(id) {
            Entry::Occupied(e) => e.key(),
            Entry::Vacant(e) => {
                // Client: it's possible to send a request, and then send
                // a RST_STREAM while the response HEADERS were in transit.
                //
                // Server: we can't reset a stream before having received
                // the request headers, so don't allow.
                if !peer.is_server() {
                    // This may be response headers for a stream we've already
                    // forgotten about...
                    if self.actions.may_have_forgotten_stream(peer, id) {
                        tracing::debug!(
                            "recv_headers for old stream={:?}, sending STREAM_CLOSED",
                            id,
                        );
                        return Err(Error::library_reset(id, Reason::STREAM_CLOSED));
                    }
                }

                match self.actions.recv.open(id, Open::Headers, &self.counts)? {
                    Some(stream_id) => {
                        let stream = Stream::try_new(
                            stream_id,
                            self.actions.send.init_window_sz(),
                            self.actions.recv.init_window_sz(),
                            &self.extensions,
                        )
                        .map_err(|err| {
                            tracing::warn!("failed to create recv stream for id {stream_id:?}: {err}; library GO AWAY");
                            Error::library_go_away(err)
                        })?;

                        e.insert(stream)
                    }
                    None => return Ok(RecvOutcome::Refused(id)),
                }
            }
        };

        let stream = self.store.resolve(key);

        if stream.is_pending_open {
            proto_err!(conn: "recv_headers: received frame on idle stream {id:?}");
            return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
        }

        if stream.state.is_local_error() {
            // Locally reset streams must ignore frames "for some time".
            // This is because the remote may have sent trailers before
            // receiving the RST_STREAM frame.
            tracing::trace!("recv_headers; ignoring trailers on {:?}", stream.id);
            return Ok(RecvOutcome::Processed);
        }

        let actions = &mut self.actions;

        self.counts.transition(stream, |counts, stream| {
            tracing::trace!(
                "recv_headers; stream={:?}; state={:?}",
                stream.id,
                stream.state
            );

            let res = if stream.state.is_recv_headers() {
                match actions.recv.recv_headers(frame, stream, counts) {
                    Ok(()) => Ok(()),
                    Err(RecvHeaderBlockError::Oversize(resp)) => {
                        if let Some(resp) = resp {
                            let mut send_buffer = send_buffer.inner.lock();
                            let sent = actions.send.send_headers(
                                resp, &mut send_buffer, stream, counts, &mut actions.task);
                            debug_assert!(sent.is_ok(), "oversize response should not fail");

                            actions.send.schedule_implicit_reset(
                                stream,
                                Reason::PROTOCOL_ERROR,
                                counts,
                                &mut actions.task);

                            actions.recv.enqueue_reset_expiration(stream, counts);

                            Ok(())
                        } else {
                            Err(Error::library_reset(stream.id, Reason::PROTOCOL_ERROR))
                        }
                    },
                    Err(RecvHeaderBlockError::State(err)) => Err(err),
                }
            } else {
                if !frame.is_end_stream() {
                    // Receiving trailers that don't set EOS is a "malformed"
                    // message. Malformed messages are a stream error.
                    proto_err!(stream: "recv_headers: trailers frame was not EOS; stream={:?}", stream.id);
                    return Err(Error::library_reset(stream.id, Reason::PROTOCOL_ERROR));
                }

                actions.recv.recv_trailers(frame, stream)
            };

            actions.reset_on_recv_stream_err_deferred(send_buffer, stream, counts, res)
        })?;

        Ok(RecvOutcome::Processed)
    }

    fn recv_data<B>(
        &mut self,
        peer: peer::Dyn,
        send_buffer: &SendBuffer<B>,
        frame: frame::Data,
    ) -> Result<(), Error> {
        let id = frame.stream_id();

        let Some(stream) = self.store.find_mut(id) else {
            // The GOAWAY process has begun. All streams with a greater ID
            // than specified as part of GOAWAY should be ignored.
            if id > self.actions.recv.max_stream_id() {
                tracing::trace!(
                    "id ({:?}) > max_stream_id ({:?}), ignoring DATA",
                    id,
                    self.actions.recv.max_stream_id()
                );

                // We still need to account for connection-level flow control.
                let sz = frame.flow_controlled_len();
                assert!(sz <= super::MAX_WINDOW_SIZE as usize);
                let sz = sz as WindowSize;
                self.actions.recv.ignore_data(sz)?;

                return Ok(());
            }

            if self.actions.may_have_forgotten_stream(peer, id) {
                tracing::debug!("recv_data for old stream={:?}, sending STREAM_CLOSED", id,);

                let sz = frame.flow_controlled_len();
                // This should have been enforced at the codec::FramedRead layer, so
                // this is just a sanity check.
                debug_assert!(sz <= super::MAX_WINDOW_SIZE as usize);
                let sz = sz as WindowSize;

                self.actions.recv.ignore_data(sz)?;

                return Err(Error::library_reset(id, Reason::STREAM_CLOSED));
            }

            proto_err!(conn: "recv_data: stream not found; id={:?}", id);
            return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
        };

        let actions = &mut self.actions;

        self.counts.transition(stream, |counts, stream| {
            let sz = frame.flow_controlled_len();
            let payload_len = frame.payload().len();
            let is_end_stream = frame.is_end_stream();
            let mut res = actions.recv.recv_data(frame, stream);
            // A stream can receive at most one final DATA frame, so it cannot
            // be used to create unbounded framing overhead on that stream.
            if res.is_ok() && !is_end_stream {
                res = counts
                    .record_data_frame(payload_len)
                    .map_err(|_budget_exhausted| {
                        tracing::debug!("too many small DATA frames");
                        Error::library_go_away_data(
                            Reason::ENHANCE_YOUR_CALM,
                            "too_many_data_frames",
                        )
                    });
            }

            // Any stream error after receiving a DATA frame means
            // we won't give the data to the user, and so they can't
            // release the capacity. We do it automatically.
            if let Err(Error::Reset(..)) = res {
                actions
                    .recv
                    .release_connection_capacity(sz as WindowSize, &mut None);
            }
            actions.reset_on_recv_stream_err_deferred(send_buffer, stream, counts, res)
        })
    }

    fn recv_reset<B>(
        &mut self,
        send_buffer: &SendBuffer<B>,
        frame: frame::Reset,
    ) -> Result<(), Error> {
        let id = frame.stream_id();

        if id.is_zero() {
            proto_err!(conn: "recv_reset: invalid stream ID 0");
            return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
        }

        // The GOAWAY process has begun. All streams with a greater ID than
        // specified as part of GOAWAY should be ignored.
        if id > self.actions.recv.max_stream_id() {
            tracing::trace!(
                "id ({:?}) > max_stream_id ({:?}), ignoring RST_STREAM",
                id,
                self.actions.recv.max_stream_id()
            );
            return Ok(());
        }

        let Some(stream) = self.store.find_mut(id) else {
            // TODO: Are there other error cases?
            self.actions
                .ensure_not_idle(self.counts.peer(), id)
                .map_err(Error::library_go_away)?;

            return Ok(());
        };

        if stream.is_pending_open {
            proto_err!(conn: "recv_reset: received frame on idle stream {id:?}");
            return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
        }

        let mut send_buffer = send_buffer.inner.lock();
        let send_buffer = &mut *send_buffer;

        let actions = &mut self.actions;

        self.counts.transition(stream, |counts, stream| {
            actions.recv.recv_reset(frame, stream, counts)?;
            actions.send.handle_error(send_buffer, stream, counts);
            debug_assert!(stream.state.is_closed());
            Ok(())
        })
    }

    fn recv_window_update<B>(
        &mut self,
        send_buffer: &SendBuffer<B>,
        frame: frame::WindowUpdate,
    ) -> Result<(), Error> {
        let id = frame.stream_id;

        let mut send_buffer = send_buffer.inner.lock();
        let send_buffer = &mut *send_buffer;

        if id.is_zero() {
            self.actions
                .send
                .recv_connection_window_update(frame, &mut self.store, &mut self.counts)
                .map_err(Error::library_go_away)?;
        } else {
            // The remote may send window updates for streams that the local now
            // considers closed. It's ok...
            if let Some(mut stream) = self.store.find_mut(id) {
                if stream.is_pending_open {
                    proto_err!(conn: "recv_window_update: received frame on idle stream {id:?}");
                    return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
                }

                let res = self
                    .actions
                    .send
                    .recv_stream_window_update(
                        frame.size_increment,
                        send_buffer,
                        &mut stream,
                        &mut self.counts,
                        &mut self.actions.task,
                    )
                    .map_err(|reason| Error::library_reset(id, reason));

                return self.actions.reset_on_recv_stream_err(
                    send_buffer,
                    &mut stream,
                    &mut self.counts,
                    res,
                );
            } else {
                self.actions
                    .ensure_not_idle(self.counts.peer(), id)
                    .map_err(Error::library_go_away)?;
            }
        }

        Ok(())
    }

    fn handle_error<B>(&mut self, send_buffer: &SendBuffer<B>, err: proto::Error) -> StreamId {
        let actions = &mut self.actions;
        let counts = &mut self.counts;
        let mut send_buffer = send_buffer.inner.lock();
        let send_buffer = &mut *send_buffer;

        let last_processed_id = actions.recv.last_processed_id();

        self.extensions
            .get_ref_or_insert(ConnectionHealthWatcher::default)
            .mark_broken();

        self.store.for_each(|stream| {
            counts.transition(stream, |counts, stream| {
                actions.recv.handle_error(&err, &mut *stream);
                actions.send.handle_error(send_buffer, stream, counts);
            })
        });

        actions.conn_error = Some(err);

        last_processed_id
    }

    fn recv_go_away<B>(
        &mut self,
        send_buffer: &SendBuffer<B>,
        frame: &frame::GoAway,
    ) -> Result<(), Error> {
        let actions = &mut self.actions;
        let counts = &mut self.counts;
        let mut send_buffer = send_buffer.inner.lock();
        let send_buffer = &mut *send_buffer;

        let last_stream_id = frame.last_stream_id();

        self.extensions
            .get_ref_or_insert(ConnectionHealthWatcher::default)
            .mark_broken();

        actions.send.recv_go_away(last_stream_id)?;

        let err = Error::remote_go_away(frame.debug_data().clone(), frame.reason());

        let peer = counts.peer();
        self.store.for_each(|stream| {
            if stream.id > last_stream_id && peer.is_local_init(stream.id) {
                counts.transition(stream, |counts, stream| {
                    actions.recv.handle_error(&err, &mut *stream);
                    actions.send.handle_error(send_buffer, stream, counts);
                })
            }
        });

        actions.conn_error = Some(err);

        Ok(())
    }

    fn recv_push_promise<B>(
        &mut self,
        send_buffer: &SendBuffer<B>,
        frame: frame::PushPromise,
    ) -> Result<RecvOutcome, Error> {
        let id = frame.stream_id();
        let promised_id = frame.promised_id();

        // First, ensure that the initiating stream is still in a valid state.
        let parent_key = if let Some(stream) = self.store.find_mut(id) {
            // The GOAWAY process has begun. All streams with a greater ID
            // than specified as part of GOAWAY should be ignored.
            if id > self.actions.recv.max_stream_id() {
                tracing::trace!(
                    "id ({:?}) > max_stream_id ({:?}), ignoring PUSH_PROMISE",
                    id,
                    self.actions.recv.max_stream_id()
                );
                return Ok(RecvOutcome::Processed);
            }

            // The stream must be receive open
            if !stream.state.ensure_recv_open()? {
                proto_err!(conn: "recv_push_promise: initiating stream is not opened");
                return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
            }

            stream.key()
        } else {
            proto_err!(conn: "recv_push_promise: initiating stream is in an invalid state");
            return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
        };

        // Ensure that we can reserve streams
        self.actions.recv.ensure_can_reserve()?;

        // Next, open the stream.
        //
        // If `None` is returned, then the stream is being refused. There is no
        // further work to be done.
        if self
            .actions
            .recv
            .open(promised_id, Open::PushPromise, &self.counts)?
            .is_none()
        {
            return Ok(RecvOutcome::Refused(promised_id));
        }

        // Try to handle the frame and create a corresponding key for the pushed stream
        // this requires a bit of indirection to make the borrow checker happy.
        let child_key: Option<store::Key> = {
            // Create state for the stream
            let stream = self.store.insert(promised_id, {
                Stream::try_new(
                    promised_id,
                    self.actions.send.init_window_sz(),
                    self.actions.recv.init_window_sz(),
                    &self.extensions,
                ).map_err(|err| {
                    tracing::warn!("failed to create pushed stream for promised id {promised_id:?}: {err}; library GO AWAY");
                    Error::library_go_away(err)
                })?
            });

            let actions = &mut self.actions;

            self.counts.transition(stream, |counts, stream| {
                // RFC 9113 excludes reserved streams from the concurrent stream
                // count. Still, account reserved remote streams against the local
                // receive limit so a peer cannot create an unbounded number of
                // them by withholding the response HEADERS. `recv_headers` will
                // see `is_counted` and avoid counting the stream a second time.
                counts.inc_num_recv_streams(stream);
                let stream_valid = actions.recv.recv_push_promise(frame, stream);

                if matches!(stream_valid, Ok(())) {
                    Ok(Some(stream.key()))
                } else {
                    let mut send_buffer = send_buffer.inner.lock();
                    actions
                        .reset_on_recv_stream_err(&mut *send_buffer, stream, counts, stream_valid)
                        .map(|()| None)
                }
            })?
        };
        // If we're successful, push the headers and stream...
        if let Some(child) = child_key {
            let mut ppp = self.store[parent_key].pending_push_promises.take();
            ppp.push(&mut self.store.resolve(child));

            let parent = &mut self.store.resolve(parent_key);
            parent.pending_push_promises = ppp;
            parent.notify_push();
        };

        Ok(RecvOutcome::Processed)
    }

    fn recv_eof<B>(&mut self, send_buffer: &SendBuffer<B>, clear_pending_accept: bool) {
        let actions = &mut self.actions;
        let counts = &mut self.counts;
        let mut send_buffer = send_buffer.inner.lock();
        let send_buffer = &mut *send_buffer;

        // Only `Connection::drop` clears the pending accepts.
        actions.conn_dropped |= clear_pending_accept;

        if actions.conn_error.is_none() {
            actions.conn_error = Some(
                io::Error::new(
                    io::ErrorKind::BrokenPipe,
                    "connection closed because of a broken pipe",
                )
                .into(),
            );
        }

        // Wake any task awaiting peer SETTINGS so they can resolve to
        // `None` instead of hanging when the connection dies before the
        // peer's initial SETTINGS frame arrives.
        actions.send.notify_peer_settings_closed();

        self.extensions
            .get_ref_or_insert(ConnectionHealthWatcher::default)
            .mark_broken();

        tracing::trace!("Streams::recv_eof");

        self.store.for_each(|stream| {
            counts.transition(stream, |counts, stream| {
                actions.recv.recv_eof(stream);

                // This handles resetting send state associated with the
                // stream
                actions.send.handle_error(send_buffer, stream, counts);
            })
        });

        actions.clear_queues(clear_pending_accept, &mut self.store, counts);
    }

    fn buffer_pending<T, B>(
        &mut self,
        send_buffer: &SendBuffer<B>,
        dst: &mut Codec<T, Prioritized<B>>,
    ) -> Result<BufferStatus, crate::h2::proto::Error>
    where
        T: AsyncWrite + Unpin,
        B: Buf,
    {
        let mut send_buffer = send_buffer.inner.lock();
        let send_buffer = &mut *send_buffer;

        // Send WINDOW_UPDATE frames first
        //
        // TODO: It would probably be better to interleave updates w/ data
        // frames.
        if self
            .actions
            .recv
            .buffer_pending(&mut self.store, &mut self.counts, dst)?
            == BufferStatus::CodecFull
        {
            return Ok(BufferStatus::CodecFull);
        }

        // Send any other pending frames
        if self
            .actions
            .send
            .buffer_pending(send_buffer, &mut self.store, &mut self.counts, dst)?
            == BufferStatus::CodecFull
        {
            return Ok(BufferStatus::CodecFull);
        }

        Ok(BufferStatus::Complete)
    }

    fn reclaim_written_frame<T, B>(
        &mut self,
        send_buffer: &SendBuffer<B>,
        dst: &mut Codec<T, Prioritized<B>>,
    ) -> bool
    where
        B: Buf,
    {
        let mut send_buffer = send_buffer.inner.lock();
        let send_buffer = &mut *send_buffer;

        self.actions
            .send
            .reclaim_written_frame(send_buffer, &mut self.store, dst)
    }

    fn send_reset<B>(
        &mut self,
        send_buffer: &SendBuffer<B>,
        id: StreamId,
        reason: Reason,
    ) -> Result<(), crate::h2::proto::error::GoAway> {
        let key = match self.store.find_entry(id) {
            Entry::Occupied(e) => e.key(),
            Entry::Vacant(e) => {
                // Resetting a stream we don't know about? That could be OK...
                //
                // 1. As a server, we just received a request, but that request
                //    was bad, so we're resetting before even accepting it.
                //    This is totally fine.
                //
                // 2. The remote may have sent us a frame on new stream that
                //    it's *not* supposed to have done, and thus, we don't know
                //    the stream. In that case, sending a reset will "open" the
                //    stream in our store. Maybe that should be a connection
                //    error instead? At least for now, we need to update what
                //    our vision of the next stream is.
                if self.counts.peer().is_local_init(id) {
                    // We normally would open this stream, so update our
                    // next-send-id record.
                    self.actions.send.maybe_reset_next_stream_id(id);
                } else {
                    // We normally would recv this stream, so update our
                    // next-recv-id record.
                    self.actions.recv.maybe_reset_next_stream_id(id);
                }

                match Stream::try_new(id, 0, 0, &self.extensions) {
                    Ok(stream) => e.insert(stream),
                    Err(reason) => {
                        tracing::debug!(
                            "h2 streams: failed to create new stream in send_reset: reason = {reason}; go away"
                        );
                        return Err(crate::h2::proto::error::GoAway {
                            debug_data: Default::default(),
                            reason,
                        });
                    }
                }
            }
        };

        let stream = self.store.resolve(key);
        let mut send_buffer = send_buffer.inner.lock();
        let send_buffer = &mut *send_buffer;

        self.actions.send_reset(
            stream,
            reason,
            Initiator::Library,
            &mut self.counts,
            send_buffer,
        )
    }
}

impl<B> Streams<B, client::Peer>
where
    B: Buf,
{
    pub(crate) fn poll_pending_open(
        &mut self,
        cx: &Context,
        pending: Option<&OpaqueStreamRef>,
    ) -> Poll<Result<(), crate::h2::Error>> {
        let mut me = self.inner.lock();
        let me = &mut *me;

        me.actions.ensure_no_conn_error()?;
        me.actions.send.ensure_next_stream_id()?;

        if let Some(pending) = pending {
            let mut stream = me.store.resolve(pending.key);
            tracing::trace!("poll_pending_open; stream = {:?}", stream.is_pending_open);
            if stream.is_pending_open {
                stream.wait_send(cx);
                return Poll::Pending;
            }
        }
        Poll::Ready(Ok(()))
    }
}

impl<B, P> Streams<B, P>
where
    P: Peer,
{
    pub(crate) fn as_dyn(&self) -> DynStreams<'_, B> {
        let Self {
            inner,
            send_buffer,
            _p,
        } = self;
        DynStreams {
            inner,
            send_buffer,
            peer: P::r#dyn(),
        }
    }

    /// This function is safe to call multiple times.
    pub(crate) fn recv_eof(&mut self, clear_pending_accept: bool) {
        self.as_dyn().recv_eof(clear_pending_accept)
    }

    pub(crate) fn max_send_streams(&self) -> usize {
        self.inner.lock().counts.max_send_streams()
    }

    pub(crate) fn max_recv_streams(&self) -> usize {
        self.inner.lock().counts.max_recv_streams()
    }

    #[cfg(feature = "unstable")]
    pub(crate) fn num_active_streams(&self) -> usize {
        let me = self.inner.lock();
        me.store.num_active_streams()
    }

    pub(crate) fn has_streams(&self) -> bool {
        let me = self.inner.lock();
        me.counts.has_streams()
    }

    pub(crate) fn has_streams_or_other_references(&self) -> bool {
        let me = self.inner.lock();
        me.counts.has_streams() || me.refs > 1
    }

    #[cfg(feature = "unstable")]
    pub(crate) fn num_wired_streams(&self) -> usize {
        let me = self.inner.lock();
        me.store.num_wired_streams()
    }
}

// no derive because we don't need B and P to be Clone.
impl<B, P> Clone for Streams<B, P>
where
    P: Peer,
{
    fn clone(&self) -> Self {
        self.inner.lock().refs += 1;
        Self {
            inner: self.inner.clone(),
            send_buffer: self.send_buffer.clone(),
            _p: ::std::marker::PhantomData,
        }
    }
}

impl<B, P> Drop for Streams<B, P>
where
    P: Peer,
{
    fn drop(&mut self) {
        let mut inner = self.inner.lock();

        inner.refs -= 1;
        if inner.refs == 1
            && let Some(task) = inner.actions.task.take()
        {
            task.wake();
        }
    }
}

// ===== impl StreamRef =====

impl<B> StreamRef<B> {
    pub(crate) fn send_data(&mut self, data: B, end_stream: bool) -> Result<(), UserError>
    where
        B: Buf,
    {
        let mut me = self.opaque.inner.lock();
        let me = &mut *me;

        let stream = me.store.resolve(self.opaque.key);
        let actions = &mut me.actions;
        let mut send_buffer = self.send_buffer.inner.lock();
        let send_buffer = &mut *send_buffer;

        me.counts.transition(stream, |counts, stream| {
            // Create the data frame. `stream.id` is server/client-allocated
            // and is guaranteed non-zero by the time we reach send_data,
            // so the `InvalidStreamId` arm cannot fire here.
            #[expect(
                clippy::expect_used,
                reason = "internal stream ids are non-zero by construction"
            )]
            let mut frame =
                frame::Data::new(stream.id, data).expect("internal stream id is non-zero");
            frame.set_end_stream(end_stream);

            // Send the data frame
            actions
                .send
                .send_data(frame, send_buffer, stream, counts, &mut actions.task)
        })
    }

    pub(crate) fn send_trailers(&mut self, trailers: HeaderMap) -> Result<(), UserError> {
        let mut me = self.opaque.inner.lock();
        let me = &mut *me;

        let stream = me.store.resolve(self.opaque.key);
        let actions = &mut me.actions;
        let mut send_buffer = self.send_buffer.inner.lock();
        let send_buffer = &mut *send_buffer;

        me.counts.transition(stream, |counts, stream| {
            // Create the trailers frame
            let frame = frame::Headers::trailers(stream.id, trailers);

            // Send the trailers frame
            actions
                .send
                .send_trailers(frame, send_buffer, stream, counts, &mut actions.task)
        })
    }

    pub(crate) fn send_reset(&self, reason: Reason) {
        let mut me = self.opaque.inner.lock();
        let me = &mut *me;

        let stream = me.store.resolve(self.opaque.key);
        let mut send_buffer = self.send_buffer.inner.lock();
        let send_buffer = &mut *send_buffer;

        match me
            .actions
            .send_reset(stream, reason, Initiator::User, &mut me.counts, send_buffer)
        {
            Ok(()) => (),
            Err(crate::h2::proto::error::GoAway { .. }) => {
                // this should never happen, because Initiator::User resets do
                // not count toward the local limit.
                // we could perhaps make this state impossible, if we made the
                // initiator argument a generic, and so this could return
                // Infallible instead of an impossible GoAway, but oh well.
                unreachable!("Initiator::User should not error sending reset");
            }
        }
    }

    pub fn send_informational_headers(&mut self, frame: frame::Headers) -> Result<(), UserError> {
        let mut me = self.opaque.inner.lock();
        let me = &mut *me;

        let stream = me.store.resolve(self.opaque.key);
        let actions = &mut me.actions;
        let mut send_buffer = self.send_buffer.inner.lock();
        let send_buffer = &mut *send_buffer;

        me.counts.transition(stream, |counts, stream| {
            // For informational responses (1xx), we need to send headers without
            // changing the stream state. This allows multiple informational responses
            // to be sent before the final response.

            // Validate that this is actually an informational response
            debug_assert!(
                frame.is_informational(),
                "Frame must be informational after conversion from informational response"
            );

            // Ensure the frame is not marked as end_stream for informational responses
            if frame.is_end_stream() {
                return Err(UserError::UnexpectedFrameType);
            }
            // Send the interim informational headers directly to the buffer without state changes
            // This bypasses the normal send_headers flow that would transition the stream state
            actions.send.send_interim_informational_headers(
                frame,
                send_buffer,
                stream,
                counts,
                &mut actions.task,
            )
        })
    }

    pub(crate) fn send_response(
        &mut self,
        response: Response<()>,
        end_of_stream: bool,
    ) -> Result<(), UserError> {
        if response.status().is_informational() {
            return Err(UserError::InformationalFinalResponse);
        }
        // We need to only drop extensions after we release our locks or there is risk for deadlocking
        let _extensions_ref = &mut Option::None;

        let mut me = self.opaque.inner.lock();
        let me = &mut *me;

        let stream = me.store.resolve(self.opaque.key);
        let actions = &mut me.actions;
        let mut send_buffer = self.send_buffer.inner.lock();
        let send_buffer = &mut *send_buffer;

        me.counts.transition(stream, |counts, stream| {
            let (frame, extensions) =
                server::Peer::convert_send_message(stream.id, response, end_of_stream);
            *_extensions_ref = Some(extensions);

            actions
                .send
                .send_headers(frame, send_buffer, stream, counts, &mut actions.task)
        })
    }

    pub(crate) fn send_push_promise(&mut self, request: Request<()>) -> Result<Self, Error> {
        // We need to keep extensions around so they are dropped after our locks or we risk deadlocking
        let _extensions_ref = request.extensions().clone();

        let mut me = self.opaque.inner.lock();
        let me = &mut *me;

        let mut send_buffer = self.send_buffer.inner.lock();
        let send_buffer = &mut *send_buffer;

        let actions = &mut me.actions;
        actions.ensure_no_conn_error()?;
        if !me.store.resolve(self.opaque.key).state.is_push_open() {
            return Err(UserError::UnexpectedFrameType.into());
        }
        let promised_id = actions.send.reserve_local()?;

        let child_key = {
            let mut child_stream = me.store.insert(
                promised_id,
                Stream::try_new(
                    promised_id,
                    actions.send.init_window_sz(),
                    actions.recv.init_window_sz(),
                    &me.extensions,
                ).map_err(|err| {
                    tracing::warn!("failed to create stream for promised id {promised_id:?} in send_push_promise: {err}; library GO AWAY");
                    Error::library_go_away(err)
                })?,
            );
            child_stream.state.reserve_local()?;
            child_stream.is_pending_push = true;
            child_stream.key()
        };

        let pushed = {
            let mut stream = me.store.resolve(self.opaque.key);

            let frame =
                crate::h2::server::Peer::convert_push_message(stream.id, promised_id, request)?;

            actions
                .send
                .send_push_promise(frame, send_buffer, &mut stream, &mut actions.task)
        };

        if let Err(err) = pushed {
            let mut child_stream = me.store.resolve(child_key);
            child_stream.unlink();
            child_stream.remove();
            return Err(err.into());
        }

        me.refs += 1;
        let opaque =
            OpaqueStreamRef::new(self.opaque.inner.clone(), &mut me.store.resolve(child_key));

        Ok(Self {
            opaque,
            send_buffer: self.send_buffer.clone(),
        })
    }

    /// Called by the server after the stream is accepted. Given that clients
    /// initialize streams by sending HEADERS, the request will always be
    /// available.
    ///
    /// # Panics
    ///
    /// This function panics if the request isn't present.
    pub(crate) fn take_request(&self) -> Request<()> {
        let mut me = self.opaque.inner.lock();
        let me = &mut *me;

        let mut stream = me.store.resolve(self.opaque.key);
        let request = me.actions.recv.take_request(&mut stream);
        if let Some(capture) = me.early_frame_ctx.freeze_recorder() {
            request.extensions().insert(capture);
        }
        request
    }

    /// Called by a client to see if the current stream is pending open
    pub(crate) fn is_pending_open(&self) -> bool {
        let mut me = self.opaque.inner.lock();
        me.store.resolve(self.opaque.key).is_pending_open
    }

    /// Request capacity to send data
    pub(crate) fn reserve_capacity(&mut self, capacity: WindowSize) {
        let mut me = self.opaque.inner.lock();
        let me = &mut *me;

        let mut stream = me.store.resolve(self.opaque.key);

        me.actions
            .send
            .reserve_capacity(capacity, &mut stream, &mut me.counts)
    }

    /// Returns the stream's current send capacity.
    pub(crate) fn capacity(&self) -> WindowSize {
        let mut me = self.opaque.inner.lock();
        let me = &mut *me;

        let mut stream = me.store.resolve(self.opaque.key);

        me.actions.send.capacity(&mut stream)
    }

    /// Request to be notified when the stream's capacity increases
    pub(crate) fn poll_capacity(
        &mut self,
        cx: &Context,
    ) -> Poll<Option<Result<WindowSize, UserError>>> {
        let mut me = self.opaque.inner.lock();
        let me = &mut *me;

        let mut stream = me.store.resolve(self.opaque.key);

        me.actions.send.poll_capacity(cx, &mut stream)
    }

    /// Request to be notified for if a `RST_STREAM` is received for this stream.
    pub(crate) fn poll_reset(
        &mut self,
        cx: &Context,
        mode: proto::PollReset,
    ) -> Poll<Result<Reason, crate::h2::Error>> {
        let mut me = self.opaque.inner.lock();
        let me = &mut *me;

        let mut stream = me.store.resolve(self.opaque.key);

        me.actions.send.poll_reset(cx, &mut stream, mode)
    }

    pub(crate) fn clone_to_opaque(&self) -> OpaqueStreamRef {
        self.opaque.clone()
    }

    pub(crate) fn stream_id(&self) -> StreamId {
        self.opaque.stream_id()
    }
}

impl<B> Clone for StreamRef<B> {
    fn clone(&self) -> Self {
        Self {
            opaque: self.opaque.clone(),
            send_buffer: self.send_buffer.clone(),
        }
    }
}

// ===== impl OpaqueStreamRef =====

impl OpaqueStreamRef {
    pub(crate) fn extensions(&self) -> Extensions {
        self.inner.lock().store.resolve(self.key).extensions.clone()
    }

    fn new(inner: Arc<Mutex<Inner>>, stream: &mut store::Ptr) -> Self {
        stream.ref_inc();
        Self {
            inner,
            key: stream.key(),
        }
    }
    /// Called by a client to check for a received response.
    pub(crate) fn poll_response(
        &mut self,
        cx: &Context,
    ) -> Poll<Result<Response<()>, proto::Error>> {
        let mut me = self.inner.lock();
        let me = &mut *me;

        let mut stream = me.store.resolve(self.key);

        me.actions.recv.poll_response(cx, &mut stream)
    }

    /// Called by a client to check for informational responses (1xx status codes)
    pub fn poll_informational(
        &mut self,
        cx: &Context,
    ) -> Poll<Option<Result<Response<()>, proto::Error>>> {
        let mut me = self.inner.lock();
        let me = &mut *me;

        let mut stream = me.store.resolve(self.key);

        me.actions.recv.poll_informational(cx, &mut stream)
    }

    /// Called by a client to check for a pushed request.
    pub(crate) fn poll_pushed(
        &mut self,
        cx: &Context,
    ) -> Poll<Option<Result<(Request<()>, Self), proto::Error>>> {
        let mut me = self.inner.lock();
        let me = &mut *me;

        let mut stream = me.store.resolve(self.key);
        me.actions
            .recv
            .poll_pushed(cx, &mut stream)
            .map_ok(|(h, key)| {
                me.refs += 1;
                let opaque_ref = Self::new(self.inner.clone(), &mut me.store.resolve(key));
                (h, opaque_ref)
            })
    }

    pub(crate) fn is_end_stream(&self) -> bool {
        let mut me = self.inner.lock();
        let me = &mut *me;

        let stream = me.store.resolve(self.key);

        me.actions.recv.is_end_stream(&stream)
    }

    pub(crate) fn poll_data(&mut self, cx: &Context) -> Poll<Option<Result<Bytes, proto::Error>>> {
        let mut me = self.inner.lock();
        let me = &mut *me;

        let mut stream = me.store.resolve(self.key);

        me.actions
            .recv
            .poll_data(cx, &mut stream)
            .map(|result| match result {
                Some(Ok(data)) => {
                    if data.is_budgeted {
                        me.counts.release_data_frame(data.payload.len());
                    }
                    Some(Ok(data.payload))
                }
                Some(Err(err)) => Some(Err(err)),
                None => None,
            })
    }

    pub(crate) fn poll_trailers(
        &mut self,
        cx: &Context,
    ) -> Poll<Option<Result<HeaderMap, proto::Error>>> {
        let mut me = self.inner.lock();
        let me = &mut *me;

        let mut stream = me.store.resolve(self.key);

        me.actions.recv.poll_trailers(cx, &mut stream)
    }

    pub(crate) fn available_recv_capacity(&self) -> isize {
        let me = self.inner.lock();
        let me = &*me;

        let stream = &me.store[self.key];
        stream.recv_flow.available().into()
    }

    pub(crate) fn used_recv_capacity(&self) -> WindowSize {
        let me = self.inner.lock();
        let me = &*me;

        let stream = &me.store[self.key];
        stream.in_flight_recv_data
    }

    /// Releases recv capacity back to the peer. This may result in sending
    /// WINDOW_UPDATE frames on both the stream and connection.
    pub(crate) fn release_capacity(&mut self, capacity: WindowSize) -> Result<(), UserError> {
        let mut me = self.inner.lock();
        let me = &mut *me;

        let mut stream = me.store.resolve(self.key);

        me.actions
            .recv
            .release_capacity(capacity, &mut stream, &mut me.actions.task)
    }

    /// Clear the receive queue and set the status to no longer receive data frames.
    pub(crate) fn clear_recv_buffer(&mut self) {
        let mut me = self.inner.lock();
        let me = &mut *me;

        let mut stream = me.store.resolve(self.key);
        stream.is_recv = false;
        me.actions
            .recv
            .clear_recv_buffer(&mut stream, &mut me.actions.task, &mut me.counts);
    }

    pub(crate) fn stream_id(&self) -> StreamId {
        self.inner.lock().store[self.key].id
    }
}

impl fmt::Debug for OpaqueStreamRef {
    fn fmt(&self, fmt: &mut fmt::Formatter) -> fmt::Result {
        if let Some(me) = self.inner.try_lock() {
            let stream = &me.store[self.key];
            fmt.debug_struct("OpaqueStreamRef")
                .field("stream_id", &stream.id)
                .field("ref_count", &stream.ref_count)
                .finish()
        } else {
            fmt.debug_struct("OpaqueStreamRef")
                .field("inner", &"<Locked>")
                .finish()
        }
    }
}

impl Clone for OpaqueStreamRef {
    fn clone(&self) -> Self {
        // Increment the ref count
        let mut inner = self.inner.lock();
        inner.store.resolve(self.key).ref_inc();
        inner.refs += 1;

        Self {
            inner: self.inner.clone(),
            key: self.key,
        }
    }
}

impl Drop for OpaqueStreamRef {
    fn drop(&mut self) {
        drop_stream_ref(&self.inner, self.key);
    }
}

// TODO: Move back in fn above
fn drop_stream_ref(inner: &Mutex<Inner>, key: store::Key) {
    let mut me = inner.lock();

    let me = &mut *me;
    me.refs -= 1;
    let mut stream = me.store.resolve(key);

    tracing::trace!("drop_stream_ref; stream={:?}", stream);

    // decrement the stream's ref count by 1.
    stream.ref_dec();

    let actions = &mut me.actions;

    // If the stream is not referenced and it is already
    // closed (does not have to go through logic below
    // of canceling the stream), we should notify the task
    // (connection) so that it can close properly
    if stream.ref_count == 0
        && stream.is_closed()
        && let Some(task) = actions.task.take()
    {
        task.wake();
    }

    me.counts.transition(stream, |counts, stream| {
        maybe_cancel(stream, actions, counts);

        if stream.ref_count == 0 {
            // Release any recv window back to connection, no one can access
            // it anymore.
            actions
                .recv
                .release_closed_capacity(stream, &mut actions.task, counts);

            // We won't be able to reach our push promises anymore
            let mut ppp = stream.pending_push_promises.take();
            while let Some(promise) = ppp.pop(stream.store_mut()) {
                counts.transition(promise, |counts, stream| {
                    maybe_cancel(stream, actions, counts);
                });
            }
        }
    });

    // A dropped connection drains no queue: what a handle queued would hold its stream.
    if me.actions.conn_dropped {
        me.actions.clear_queues(true, &mut me.store, &mut me.counts);
    }
}

fn maybe_cancel(stream: &mut store::Ptr, actions: &mut Actions, counts: &mut Counts) {
    if stream.is_canceled_interest() {
        // Server is allowed to early respond without fully consuming the client input stream
        // But per the RFC, must send a RST_STREAM(NO_ERROR) in such cases. https://www.rfc-editor.org/rfc/rfc7540#section-8.1
        // Some other http2 implementation may interpret other error code as fatal if not respected (i.e: nginx https://trac.nginx.org/nginx/ticket/2376)
        let reason = if counts.peer().is_server()
            && stream.state.is_send_closed()
            && stream.state.is_recv_streaming()
        {
            Reason::NO_ERROR
        } else {
            Reason::CANCEL
        };

        actions
            .send
            .schedule_implicit_reset(stream, reason, counts, &mut actions.task);
        actions.recv.enqueue_reset_expiration(stream, counts);
    }
}

// ===== impl SendBuffer =====

impl<B> SendBuffer<B> {
    fn new() -> Self {
        let inner = Mutex::new(Buffer::new());
        Self { inner }
    }

    pub(crate) fn is_empty(&self) -> bool {
        let buf = self.inner.lock();
        buf.is_empty()
    }
}

// ===== impl Actions =====

impl Actions {
    fn send_reset<B>(
        &mut self,
        stream: store::Ptr,
        reason: Reason,
        initiator: Initiator,
        counts: &mut Counts,
        send_buffer: &mut Buffer<Frame<B>>,
    ) -> Result<(), crate::h2::proto::error::GoAway> {
        counts.transition(stream, |counts, stream| {
            if initiator.is_library() {
                if counts.can_inc_num_local_error_resets() {
                    counts.inc_num_local_error_resets();
                } else {
                    tracing::warn!(
                        "locally-reset streams reached limit ({:?})",
                        counts.max_local_error_resets(),
                    );
                    return Err(crate::h2::proto::error::GoAway {
                        reason: Reason::ENHANCE_YOUR_CALM,
                        debug_data: "too_many_internal_resets".into(),
                    });
                }
            }

            self.send.send_reset(
                reason,
                initiator,
                send_buffer,
                stream,
                counts,
                &mut self.task,
            );
            self.recv.enqueue_reset_expiration(stream, counts);
            // if a RecvStream is parked, ensure it's notified
            stream.notify_recv();

            Ok(())
        })
    }

    fn reset_on_recv_stream_err_deferred<B>(
        &mut self,
        send_buffer: &SendBuffer<B>,
        stream: &mut store::Ptr,
        counts: &mut Counts,
        res: Result<(), Error>,
    ) -> Result<(), Error> {
        if matches!(res, Err(Error::Reset(..))) {
            let mut send_buffer = send_buffer.inner.lock();
            self.reset_on_recv_stream_err(&mut send_buffer, stream, counts, res)
        } else {
            res
        }
    }

    fn reset_on_recv_stream_err<B>(
        &mut self,
        buffer: &mut Buffer<Frame<B>>,
        stream: &mut store::Ptr,
        counts: &mut Counts,
        res: Result<(), Error>,
    ) -> Result<(), Error> {
        if let Err(Error::Reset(stream_id, reason, initiator)) = res {
            debug_assert_eq!(stream_id, stream.id);

            if counts.can_inc_num_local_error_resets() {
                counts.inc_num_local_error_resets();

                // Reset the stream.
                self.send
                    .send_reset(reason, initiator, buffer, stream, counts, &mut self.task);
                self.recv.enqueue_reset_expiration(stream, counts);
                // if a RecvStream is parked, ensure it's notified
                stream.notify_recv();
                Ok(())
            } else {
                tracing::warn!(
                    "reset_on_recv_stream_err; locally-reset streams reached limit ({:?})",
                    counts.max_local_error_resets(),
                );
                Err(Error::library_go_away_data(
                    Reason::ENHANCE_YOUR_CALM,
                    "too_many_internal_resets",
                ))
            }
        } else {
            res
        }
    }

    fn ensure_not_idle(&mut self, peer: peer::Dyn, id: StreamId) -> Result<(), Reason> {
        if peer.is_local_init(id) {
            self.send.ensure_not_idle(id)
        } else {
            self.recv.ensure_not_idle(id)
        }
    }

    fn ensure_no_conn_error(&self) -> Result<(), proto::Error> {
        if let Some(ref err) = self.conn_error {
            Err(err.clone())
        } else {
            Ok(())
        }
    }

    /// Check if we possibly could have processed and since forgotten this stream.
    ///
    /// If we send a RST_STREAM for a stream, we will eventually "forget" about
    /// the stream to free up memory. It's possible that the remote peer had
    /// frames in-flight, and by the time we receive them, our own state is
    /// gone. We *could* tear everything down by sending a GOAWAY, but it
    /// is more likely to be latency/memory constraints that caused this,
    /// and not a bad actor. So be less catastrophic, the spec allows
    /// us to send another RST_STREAM of STREAM_CLOSED.
    fn may_have_forgotten_stream(&self, peer: peer::Dyn, id: StreamId) -> bool {
        if id.is_zero() {
            return false;
        }
        if peer.is_local_init(id) {
            self.send.may_have_created_stream(id)
        } else {
            self.recv.may_have_created_stream(id)
        }
    }

    fn clear_queues(&mut self, clear_pending_accept: bool, store: &mut Store, counts: &mut Counts) {
        self.recv.clear_queues(clear_pending_accept, store, counts);
        self.send.clear_queues(store, counts);
    }
}
