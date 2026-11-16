use super::*;
use crate::h2::codec::UserError;
use crate::h2::proto;
use rama_core::extensions::{Egress, Extensions, Ingress};
use rama_core::telemetry::tracing::{self, warn};
use rama_http_types::proto::h2::alt_svc::{AltSvcObserverExtension, AltSvcReceivedAt};
use rama_http_types::proto::h2::frame::{
    DEFAULT_INITIAL_WINDOW_SIZE, PushPromiseHeaderError, Reason,
};
use rama_http_types::{HeaderMap, Request, Response, header};
use rama_net::conn::ConnectionHealthWatcher;

use std::cmp::Ordering;
use std::task::{Context, Poll, Waker};
use std::time::Instant;

#[derive(Debug)]
pub(super) struct Recv {
    /// Initial window size of remote initiated streams
    init_window_sz: WindowSize,

    /// Connection level flow control governing received data
    flow: FlowControl,

    /// Amount of connection window capacity currently used by outstanding streams.
    in_flight_data: WindowSize,

    /// The lowest stream ID that is still idle
    next_stream_id: Result<StreamId, StreamIdOverflow>,

    /// The stream ID of the last processed stream
    last_processed_id: StreamId,

    /// Any streams with a higher ID are ignored.
    ///
    /// This starts as MAX, but is lowered when a GOAWAY is received.
    ///
    /// > After sending a GOAWAY frame, the sender can discard frames for
    /// > streams initiated by the receiver with identifiers higher than
    /// > the identified last stream.
    max_stream_id: StreamId,

    /// Streams that have pending window updates
    pending_window_updates: store::Queue<stream::NextWindowUpdate>,

    /// New streams to be accepted
    pending_accept: store::Queue<stream::NextAccept>,

    /// Locally reset streams that should be reaped when they expire
    pending_reset_expired: store::Queue<stream::NextResetExpire>,

    /// How long locally reset streams should ignore received frames
    reset_duration: Duration,

    /// Holds frames that are waiting to be read
    buffer: Buffer<Event>,

    /// If push promises are allowed to be received.
    is_push_enabled: bool,

    /// Reset every received push promise with REFUSED_STREAM.
    refuse_push_promises: bool,

    /// If extended connect protocol is enabled.
    is_extended_connect_protocol_enabled: bool,
}

#[derive(Debug)]
pub(super) struct ReplayedConnectionWindow {
    flow: FlowControl,
    pub(super) target: WindowSize,
}

#[derive(Debug)]
pub(super) enum Event {
    Headers(peer::PollMessage),
    Data(DataEvent),
    Trailers(HeaderMap),
    InformationalHeaders(peer::PollMessage),
}

#[derive(Debug)]
pub(super) struct DataEvent {
    pub(super) payload: Bytes,
    pub(super) is_budgeted: bool,
}

#[derive(Debug)]
pub(super) enum RecvHeaderBlockError<T> {
    Oversize(T),
    State(Error),
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum Open {
    PushPromise,
    Headers,
}

impl Recv {
    pub(super) fn try_new(
        peer: peer::Dyn,
        config: &Config,
    ) -> Result<Self, crate::h2::proto::Error> {
        let next_stream_id = if peer.is_server() { 1 } else { 2 };

        let mut flow = FlowControl::new();

        // connections always have the default window size,
        // regardless of settings
        flow.inc_window(DEFAULT_INITIAL_WINDOW_SIZE).map_err(|reason| {
            warn!("h2 proto: stream recv: invalid initial remote window size: reason = {reason}; report bug to rama");
            crate::h2::proto::Error::library_go_away(reason)
        })?;
        flow.assign_capacity(DEFAULT_INITIAL_WINDOW_SIZE).map_err(|reason| {
            warn!("h2 proto: stream recv: failed to assign initial window size capacity: reason = {reason}; report bug to rama");
            crate::h2::proto::Error::library_go_away(reason)
        })?;

        Ok(Self {
            init_window_sz: DEFAULT_INITIAL_WINDOW_SIZE,
            flow,
            in_flight_data: 0 as WindowSize,
            next_stream_id: Ok(next_stream_id.into()),
            pending_window_updates: store::Queue::new(),
            last_processed_id: StreamId::ZERO,
            max_stream_id: StreamId::MAX,
            pending_accept: store::Queue::new(),
            pending_reset_expired: store::Queue::new(),
            reset_duration: config.local_reset_duration,
            buffer: Buffer::new(),
            is_push_enabled: config.local_push_enabled,
            refuse_push_promises: config.refuse_push_promises,
            is_extended_connect_protocol_enabled: config.extended_connect_protocol_enabled,
        })
    }

    /// Returns the initial receive window size
    pub(super) fn init_window_sz(&self) -> WindowSize {
        self.init_window_sz
    }

    /// Returns the ID of the last processed stream
    pub(super) fn last_processed_id(&self) -> StreamId {
        self.last_processed_id
    }

    /// Update state reflecting a new, remotely opened stream
    ///
    /// Returns the stream state if successful. `None` if refused
    pub(super) fn open(
        &mut self,
        id: StreamId,
        mode: Open,
        counts: &Counts,
    ) -> Result<Option<StreamId>, Error> {
        counts.peer().ensure_can_open(id, mode)?;

        let next_id = self.next_stream_id()?;
        if id < next_id {
            proto_err!(conn: "id ({:?}) < next_id ({:?})", id, next_id);
            return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
        }

        self.next_stream_id = id.next_id();

        if !counts.can_inc_num_recv_streams() {
            return Ok(None);
        }

        Ok(Some(id))
    }

    // TODO: revisit to see if we can avoid large result here

    /// Transition the stream state based on receiving headers
    ///
    /// The caller ensures that the frame represents headers and not trailers.
    pub(super) fn recv_headers(
        &mut self,
        frame: frame::Headers,
        stream: &mut store::Ptr,
        counts: &mut Counts,
    ) -> Result<(), RecvHeaderBlockError<Option<frame::Headers>>> {
        tracing::trace!("opening stream; init_window={}", self.init_window_sz);
        let is_initial = stream.state.recv_open(&frame)?;

        // Informational responses do not transition a remotely reserved stream
        // out of `ReservedRemote`. As a result, `recv_open` reports each of them
        // as initial. Only account for the stream once.
        if is_initial {
            if frame.stream_id() > self.last_processed_id {
                self.last_processed_id = frame.stream_id();
            }

            if !stream.is_counted {
                // Increment the number of concurrent streams
                counts.inc_num_recv_streams(stream);
            }
        }

        use super::stream::ContentLength;

        let ignore_content_length = match stream.content_length {
            ContentLength::Head => {
                // Not counted, as a HEAD response has no content, but its lines
                // must still agree.
                if frame.fields().contains_key(header::CONTENT_LENGTH)
                    && crate::headers::content_length_parse_all(frame.fields()).is_none()
                {
                    proto_err!(stream: "conflicting content-length headers; stream={:?}", stream.id);
                    return Err(Error::library_reset(stream.id, Reason::PROTOCOL_ERROR).into());
                }
                true
            }
            ContentLength::Connect => match frame.pseudo().status {
                Some(status) if status.is_success() => {
                    // A successful CONNECT switches this stream to tunnel
                    // data. RFC 9110 requires response framing headers to be
                    // ignored, regardless of their value.
                    stream.content_length = ContentLength::Omitted;
                    true
                }
                Some(status) if status.is_informational() => true,
                Some(_) => {
                    // A rejected CONNECT is an ordinary HTTP response and its
                    // body retains normal Content-Length validation.
                    stream.content_length = ContentLength::Omitted;
                    false
                }
                None => true,
            },
            ContentLength::Omitted | ContentLength::Remaining(_) => false,
        };

        if !ignore_content_length && frame.fields().contains_key(header::CONTENT_LENGTH) {
            // Every line counts and must agree (RFC 9110 §8.6), as on HTTP/1 and HTTP/3.
            let Some(content_length) = crate::headers::content_length_parse_all(frame.fields())
            else {
                proto_err!(stream: "could not parse content-length; stream={:?}", stream.id);
                return Err(Error::library_reset(stream.id, Reason::PROTOCOL_ERROR).into());
            };

            // CONNECT requests have no HTTP content: subsequent DATA is
            // tunnel traffic (RFC 9110 section 9.3.6 / RFC 9113 section 8.5).
            // Validate the field syntax, but do not count tunnel bytes
            // against it, including when a client sends Content-Length: 0.
            let is_connect = frame.pseudo().method == Some(rama_http_types::Method::CONNECT);
            if !is_connect {
                stream.content_length = ContentLength::Remaining(content_length);
            }
            // END_STREAM on headers frame with non-zero content-length is malformed.
            // https://datatracker.ietf.org/doc/html/rfc9113#section-8.1.1
            if !is_connect
                && frame.is_end_stream()
                && content_length > 0
                && frame
                    .pseudo()
                    .status
                    .is_none_or(|status| status != 204 && status != 304)
            {
                proto_err!(stream: "recv_headers with END_STREAM: content-length is not zero; stream={:?};", stream.id);
                return Err(Error::library_reset(stream.id, Reason::PROTOCOL_ERROR).into());
            }
        }

        if frame.is_over_size() {
            // A frame is over size if the decoded header block was bigger than
            // SETTINGS_MAX_HEADER_LIST_SIZE.
            //
            // > A server that receives a larger header block than it is willing
            // > to handle can send an HTTP 431 (Request Header Fields Too
            // > Large) status code [RFC6585]. A client can discard responses
            // > that it cannot process.
            //
            // So, if peer is a server, we'll send a 431. In either case,
            // an error is recorded, which will send a REFUSED_STREAM,
            // since we don't want any of the data frames either.
            tracing::debug!(
                "stream error REQUEST_HEADER_FIELDS_TOO_LARGE -- \
                 recv_headers: frame is over size; stream={:?}",
                stream.id
            );
            return if counts.peer().is_server() && is_initial {
                let mut res = frame::Headers::new(
                    stream.id,
                    frame::Pseudo::response(
                        rama_http_types::StatusCode::REQUEST_HEADER_FIELDS_TOO_LARGE,
                    ),
                    HeaderMap::new(),
                    None,
                );
                res.set_end_stream();
                Err(RecvHeaderBlockError::Oversize(Some(res)))
            } else {
                Err(RecvHeaderBlockError::Oversize(None))
            };
        }

        let stream_id = frame.stream_id();
        let header_size = frame.calculate_header_list_size();
        let headers_priority = frame.stream_dependency().cloned();
        let (pseudo, fields) = frame.into_parts();

        if pseudo.protocol.is_some()
            && counts.peer().is_server()
            && !self.is_extended_connect_protocol_enabled
        {
            proto_err!(stream: "cannot use :protocol if extended connect protocol is disabled; stream={:?}", stream.id);
            return Err(Error::library_reset(stream.id, Reason::PROTOCOL_ERROR).into());
        }

        if pseudo.status.is_some() && counts.peer().is_server() {
            proto_err!(stream: "cannot use :status header for requests; stream={:?}", stream.id);
            return Err(Error::library_reset(stream.id, Reason::PROTOCOL_ERROR).into());
        }

        // RFC 9113 §8.3.2: every response carries `:status`.
        if pseudo.status.is_none() && !counts.peer().is_server() {
            proto_err!(stream: "missing :status in response; stream={:?}", stream.id);
            return Err(Error::library_reset(stream.id, Reason::PROTOCOL_ERROR).into());
        }

        if !pseudo.is_informational() {
            let extensions = if counts.peer().is_server() {
                // Server receiving a request
                let ext = Extensions::new();
                ext.insert(Ingress(stream.extensions.clone()));
                if let Some(priority) = headers_priority {
                    ext.insert(frame::ReceivedStreamDependency(priority));
                }
                ext
            } else {
                // Client receiving a response
                stream
                    .req_extensions
                    .as_ref()
                    .map(|req_ext| req_ext.fork())
                    .unwrap_or_else(|| {
                        tracing::warn!(
                            "req_extensions should always be set in recv_headers but it was missing; falling back to default; report bug in rama"
                        );
                        Extensions::new()
                    })
            };
            if !counts.peer().is_server()
                && fields.contains_key(header::ALT_SVC)
                && stream.extensions.contains::<AltSvcObserverExtension>()
            {
                extensions.insert(AltSvcReceivedAt::now());
            }
            let message = counts.peer().convert_poll_message(
                pseudo,
                fields,
                header_size,
                stream_id,
                extensions,
            )?;

            // Push the frame onto the stream's recv buffer
            stream
                .pending_recv
                .push_back(&mut self.buffer, Event::Headers(message));
            stream.notify_recv();

            // Only servers can receive a headers frame that initiates the stream.
            // This is verified in `Streams` before calling this function.
            if counts.peer().is_server() {
                // Correctness: never push a stream to `pending_accept` without having the
                // corresponding headers frame pushed to `stream.pending_recv`.
                self.pending_accept.push(stream);
            }
        } else {
            // Client receiving an informational response
            let extensions =  stream
                .req_extensions
                .as_ref()
                .map(|req_ext| req_ext.fork())
                .unwrap_or_else(|| {
                    tracing::warn!(
                        "req_extensions should always be set in recv_headers but it was missing; falling back to default; report bug in rama"
                    );
                    Extensions::new()
                });
            let message = counts.peer().convert_poll_message(
                pseudo,
                fields,
                header_size,
                stream_id,
                extensions,
            )?;

            tracing::trace!("Received informational response: stream_id={:?}", stream_id);

            // Push the informational response onto the stream's recv buffer
            // with a special event type so it can be polled separately
            stream
                .pending_recv
                .push_back(&mut self.buffer, Event::InformationalHeaders(message));
            stream.notify_recv();
        }

        Ok(())
    }

    /// Called by the server to get the request
    ///
    /// # Panics
    ///
    /// Panics if `stream.pending_recv` has no `Event::Headers` queued.
    ///
    pub(super) fn take_request(&mut self, stream: &mut store::Ptr) -> Request<()> {
        match stream.pending_recv.pop_front(&mut self.buffer) {
            Some(Event::Headers(peer::PollMessage::Server(request))) => request,
            _ => unreachable!("server stream queue must start with Headers"),
        }
    }

    /// Called by the client to get pushed response
    pub(super) fn poll_pushed(
        &mut self,
        cx: &Context,
        stream: &mut store::Ptr,
    ) -> Poll<Option<Result<(Request<()>, store::Key), proto::Error>>> {
        let mut ppp = stream.pending_push_promises.take();
        let pushed = ppp.pop(stream.store_mut()).map(|mut pushed| {
            match pushed.pending_recv.pop_front(&mut self.buffer) {
                Some(Event::Headers(peer::PollMessage::Server(headers))) => (headers, pushed.key()),
                // When frames are pushed into the queue, it is verified that
                // the first frame is a HEADERS frame.
                _ => panic!("Headers not set on pushed stream"),
            }
        });
        stream.pending_push_promises = ppp;
        if let Some(p) = pushed {
            Poll::Ready(Some(Ok(p)))
        } else {
            let is_open = stream.state.ensure_recv_open()?;

            if is_open {
                stream.push_task = Some(cx.waker().clone());
                Poll::Pending
            } else {
                Poll::Ready(None)
            }
        }
    }

    /// Called by the client to get the response
    pub(super) fn poll_response(
        &mut self,
        cx: &Context,
        stream: &mut store::Ptr,
    ) -> Poll<Result<Response<()>, proto::Error>> {
        // Skip over any interim informational headers to find the main response
        loop {
            match stream.pending_recv.pop_front(&mut self.buffer) {
                Some(Event::Headers(peer::PollMessage::Client(response))) => {
                    return Poll::Ready(Ok(response));
                }
                Some(Event::InformationalHeaders(_)) => {
                    tracing::trace!(
                        "Skipping informational response in poll_response - should be consumed via poll_informational; stream_id={:?}",
                        stream.id,
                    );
                }
                Some(evt) => {
                    tracing::warn!("poll_response called after response returned: {evt:?}");
                    return Poll::Ready(Err(proto::Error::library_go_away(Reason::INTERNAL_ERROR)));
                }
                None => {
                    if !stream.state.ensure_recv_open()? {
                        proto_err!(stream: "poll_response: stream={:?} is not opened;",  stream.id);
                        return Poll::Ready(Err(Error::library_reset(
                            stream.id,
                            Reason::PROTOCOL_ERROR,
                        )));
                    }

                    stream.recv_task = Some(cx.waker().clone());
                    return Poll::Pending;
                }
            }
        }
    }

    /// Called by the client to get informational responses (1xx status codes)
    pub fn poll_informational(
        &mut self,
        cx: &Context,
        stream: &mut store::Ptr,
    ) -> Poll<Option<Result<Response<()>, proto::Error>>> {
        // Try to pop the front event and check if it's an informational response
        // If it's not, we put it back
        if let Some(event) = stream.pending_recv.pop_front(&mut self.buffer) {
            match event {
                Event::Headers(peer::PollMessage::Client(response)) => {
                    // Final response
                    stream.pending_recv.push_front(
                        &mut self.buffer,
                        Event::Headers(peer::PollMessage::Client(response)),
                    );
                    return Poll::Ready(None);
                }
                Event::InformationalHeaders(peer::PollMessage::Client(response)) => {
                    // Found an informational response, return it
                    return Poll::Ready(Some(Ok(response)));
                }
                other => {
                    // Not an informational response, put it back at the front
                    stream.pending_recv.push_front(&mut self.buffer, other);
                }
            }
        }

        // No informational response available at the front
        if stream.state.ensure_recv_open()? {
            // Request to get notified once more frames arrive
            stream.recv_task = Some(cx.waker().clone());
            Poll::Pending
        } else {
            // No more frames will be received
            Poll::Ready(None)
        }
    }

    /// Transition the stream based on receiving trailers
    pub(super) fn recv_trailers(
        &mut self,
        frame: frame::Headers,
        stream: &mut store::Ptr,
    ) -> Result<(), Error> {
        // Transition the state
        stream.state.recv_close()?;

        if stream.ensure_content_length_zero().is_err() {
            proto_err!(stream: "recv_trailers: content-length is not zero; stream={:?};",  stream.id);
            return Err(Error::library_reset(stream.id, Reason::PROTOCOL_ERROR));
        }

        // RFC 9113 §8.1: a HEADERS frame carrying trailers MUST NOT contain
        // pseudo-header fields. The HPACK decoder will have populated the
        // pseudo block if any appeared on the wire; reject the stream.
        if !frame.pseudo().is_empty() {
            proto_err!(stream: "recv_trailers: pseudo-headers present in trailers; stream={:?};", stream.id);
            return Err(Error::library_reset(stream.id, Reason::PROTOCOL_ERROR));
        }

        let trailers = frame.into_fields();

        // Push the frame onto the stream's recv buffer
        stream
            .pending_recv
            .push_back(&mut self.buffer, Event::Trailers(trailers));
        stream.notify_recv();

        Ok(())
    }

    /// Releases capacity of the connection
    pub(super) fn release_connection_capacity(
        &mut self,
        capacity: WindowSize,
        task: &mut Option<Waker>,
    ) {
        tracing::trace!(
            "release_connection_capacity; size={}, connection in_flight_data={}",
            capacity,
            self.in_flight_data,
        );

        // Decrement in-flight data
        self.in_flight_data -= capacity;

        // Assign capacity to connection
        // TODO: proper error handling
        let _res = self.flow.assign_capacity(capacity);
        debug_assert!(_res.is_ok());

        if self.flow.unclaimed_capacity().is_some()
            && let Some(task) = task.take()
        {
            task.wake();
        }
    }

    /// Releases capacity back to the connection & stream
    pub(super) fn release_capacity(
        &mut self,
        capacity: WindowSize,
        stream: &mut store::Ptr,
        task: &mut Option<Waker>,
    ) -> Result<(), UserError> {
        tracing::trace!("release_capacity; size={}", capacity);

        if capacity > stream.in_flight_recv_data {
            return Err(UserError::ReleaseCapacityTooBig);
        }

        self.release_connection_capacity(capacity, task);

        // Decrement in-flight data
        stream.in_flight_recv_data -= capacity;

        // Assign capacity to stream
        // TODO: proper error handling
        let _res = stream.recv_flow.assign_capacity(capacity);
        debug_assert!(_res.is_ok());

        if stream.recv_flow.unclaimed_capacity().is_some() {
            // Queue the stream for sending the WINDOW_UPDATE frame.
            self.pending_window_updates.push(stream);

            if let Some(task) = task.take() {
                task.wake();
            }
        }

        Ok(())
    }

    /// Release any unclaimed capacity for a closed stream.
    pub(super) fn release_closed_capacity(
        &mut self,
        stream: &mut store::Ptr,
        task: &mut Option<Waker>,
        counts: &mut Counts,
    ) {
        debug_assert_eq!(stream.ref_count, 0);

        if stream.in_flight_recv_data != 0 {
            tracing::trace!(
                "auto-release closed stream ({:?}) capacity: {:?}",
                stream.id,
                stream.in_flight_recv_data,
            );

            self.release_connection_capacity(stream.in_flight_recv_data, task);
            stream.in_flight_recv_data = 0;
        }

        self.clear_recv_buffer(stream, task, counts);
    }

    /// Set the "target" connection window size.
    ///
    /// By default, all new connections start with 64kb of window size. As
    /// streams used and release capacity, we will send WINDOW_UPDATEs for the
    /// connection to bring it back up to the initial "target".
    ///
    /// Setting a target means that we will try to tell the peer about
    /// WINDOW_UPDATEs so the peer knows it has about `target` window to use
    /// for the whole connection.
    ///
    /// The `task` is an optional parked task for the `Connection` that might
    /// be blocked on needing more window capacity.
    pub(super) fn set_target_connection_window(
        &mut self,
        target: WindowSize,
        task: &mut Option<Waker>,
    ) -> Result<(), Reason> {
        tracing::trace!(
            "set_target_connection_window; target={}; available={}, reserved={}",
            target,
            self.flow.available(),
            self.in_flight_data,
        );

        // The current target connection window is our `available` plus any
        // in-flight data reserved by streams.
        //
        // Update the flow controller with the difference between the new
        // target and the current target.
        let current = self
            .flow
            .available()
            .add(self.in_flight_data)?
            .checked_size();
        if target > current {
            self.flow.assign_capacity(target - current)?;
        } else {
            self.flow.claim_capacity(current - target)?;
        }

        // If changing the target capacity means we gained a bunch of capacity,
        // enough that we went over the update threshold, then schedule sending
        // a connection WINDOW_UPDATE.
        if self.flow.unclaimed_capacity().is_some()
            && let Some(task) = task.take()
        {
            task.wake();
        }
        Ok(())
    }

    /// Validate the local receive-flow state after writing a captured
    /// connection WINDOW_UPDATE. The first captured increment overrides a
    /// configured target; later captured increments accumulate exactly as
    /// they do on the wire.
    pub(super) fn prepare_replayed_connection_window(
        &self,
        increment: WindowSize,
        first: bool,
    ) -> Result<ReplayedConnectionWindow, Reason> {
        let mut flow = self.flow;
        // Only the first capture replaces the configured target. Subsequent
        // captures add credit without losing capacity released between frames.
        let current = flow.available().add(self.in_flight_data)?.checked_size();
        let base = if first {
            DEFAULT_INITIAL_WINDOW_SIZE
        } else {
            current
        };
        let target = base
            .checked_add(increment)
            .filter(|target| *target <= proto::MAX_WINDOW_SIZE)
            .ok_or(Reason::FLOW_CONTROL_ERROR)?;
        flow.inc_window(increment)?;
        if target > current {
            flow.assign_capacity(target - current)?;
        } else {
            flow.claim_capacity(current - target)?;
        }
        Ok(ReplayedConnectionWindow { flow, target })
    }

    #[expect(
        clippy::needless_pass_by_value,
        reason = "consume the validated update so it cannot be committed twice"
    )]
    pub(super) fn commit_replayed_connection_window(&mut self, replay: ReplayedConnectionWindow) {
        self.flow = replay.flow;
    }

    pub(super) fn apply_local_settings(
        &mut self,
        settings: &frame::Settings,
        store: &mut Store,
    ) -> Result<(), proto::Error> {
        if let Some(val) = settings.config.enable_connect_protocol.map(|v| v != 0) {
            self.is_extended_connect_protocol_enabled = val;
        }

        if let Some(target) = settings.config.initial_window_size {
            let old_sz = self.init_window_sz;
            self.init_window_sz = target;

            tracing::trace!("update_initial_window_size; new={}; old={}", target, old_sz,);

            // Per RFC 7540 §6.9.2:
            //
            // In addition to changing the flow-control window for streams that are
            // not yet active, a SETTINGS frame can alter the initial flow-control
            // window size for streams with active flow-control windows (that is,
            // streams in the "open" or "half-closed (remote)" state). When the
            // value of SETTINGS_INITIAL_WINDOW_SIZE changes, a receiver MUST adjust
            // the size of all stream flow-control windows that it maintains by the
            // difference between the new value and the old value.
            //
            // A change to `SETTINGS_INITIAL_WINDOW_SIZE` can cause the available
            // space in a flow-control window to become negative. A sender MUST
            // track the negative flow-control window and MUST NOT send new
            // flow-controlled frames until it receives WINDOW_UPDATE frames that
            // cause the flow-control window to become positive.

            match target.cmp(&old_sz) {
                Ordering::Less => {
                    // We must decrease the (local) window on every open stream.
                    let dec = old_sz - target;
                    tracing::trace!("decrementing all windows; dec={}", dec);

                    store.try_for_each(|mut stream| {
                        stream
                            .recv_flow
                            .dec_recv_window(dec)
                            .map_err(proto::Error::library_go_away)?;
                        Ok::<_, proto::Error>(())
                    })?;
                }
                Ordering::Greater => {
                    // We must increase the (local) window on every open stream.
                    let inc = target - old_sz;
                    tracing::trace!("incrementing all windows; inc={}", inc);
                    store.try_for_each(|mut stream| {
                        // XXX: Shouldn't the peer have already noticed our
                        // overflow and sent us a GOAWAY?
                        stream
                            .recv_flow
                            .inc_window(inc)
                            .map_err(proto::Error::library_go_away)?;
                        stream
                            .recv_flow
                            .assign_capacity(inc)
                            .map_err(proto::Error::library_go_away)?;
                        Ok::<_, proto::Error>(())
                    })?;
                }
                Ordering::Equal => (),
            }
        }

        Ok(())
    }

    #[expect(clippy::unused_self)]
    pub(super) fn is_end_stream(&self, stream: &store::Ptr) -> bool {
        if !stream.state.is_recv_end_stream() {
            return false;
        }

        stream.pending_recv.is_empty()
    }

    pub(super) fn recv_data(
        &mut self,
        frame: frame::Data,
        stream: &mut store::Ptr,
    ) -> Result<(), Error> {
        // could include padding
        let sz = frame.flow_controlled_len();

        // This should have been enforced at the codec::FramedRead layer, so
        // this is just a sanity check.
        debug_assert!(sz <= MAX_WINDOW_SIZE as usize);

        let sz = sz as WindowSize;

        let is_ignoring_frame = stream.state.is_local_error();

        if !is_ignoring_frame && !stream.state.is_recv_streaming() {
            // TODO: There are cases where this can be a stream error of
            // STREAM_CLOSED instead...

            // Receiving a DATA frame when not expecting one is a protocol
            // error.
            proto_err!(conn: "unexpected DATA frame; stream={:?}", stream.id);
            return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
        }

        tracing::trace!(
            "recv_data; size={}; connection={}; stream={}",
            sz,
            self.flow.window_size(),
            stream.recv_flow.window_size()
        );

        if is_ignoring_frame {
            tracing::trace!(
                "recv_data; frame ignored on locally reset {:?} for some time",
                stream.id,
            );
            return self.ignore_data(sz);
        }

        // Ensure that there is enough capacity on the connection before acting
        // on the stream.
        self.consume_connection_window(sz)?;

        if stream.recv_flow.window_size() < sz {
            // http://httpwg.org/specs/rfc7540.html#WINDOW_UPDATE
            // > A receiver MAY respond with a stream error (Section 5.4.2) or
            // > connection error (Section 5.4.1) of type FLOW_CONTROL_ERROR if
            // > it is unable to accept a frame.
            //
            // So, for violating the **stream** window, we can send either a
            // stream or connection error. We've opted to send a stream
            // error.
            return Err(Error::library_reset(stream.id, Reason::FLOW_CONTROL_ERROR));
        }

        // use payload len, padding doesn't count for content-length
        if stream.dec_content_length(frame.payload().len()).is_err() {
            proto_err!(stream:
                "recv_data: content-length overflow; stream={:?}; len={:?}",
                stream.id,
                frame.payload().len(),
            );
            return Err(Error::library_reset(stream.id, Reason::PROTOCOL_ERROR));
        }

        if frame.is_end_stream() {
            if stream.ensure_content_length_zero().is_err() {
                proto_err!(stream:
                    "recv_data: content-length underflow; stream={:?}; len={:?}",
                    stream.id,
                    frame.payload().len(),
                );
                return Err(Error::library_reset(stream.id, Reason::PROTOCOL_ERROR));
            }

            if stream.state.recv_close().is_err() {
                proto_err!(conn: "recv_data: failed to transition to closed state; stream={:?}", stream.id);
                return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
            }
        }

        // Received a frame, but no one cared about it. fix issue#648
        if !stream.is_recv {
            tracing::trace!(
                "recv_data; frame ignored on stream release {:?} for some time",
                stream.id,
            );
            self.release_connection_capacity(sz, &mut None);
            return Ok(());
        }

        // Update stream level flow control
        stream
            .recv_flow
            .send_data(sz)
            .map_err(proto::Error::library_go_away)?;

        // Track the data as in-flight
        stream.in_flight_recv_data += sz;

        // Auto-release padding overhead (pad_len field + padding bytes),
        // since the user only sees the data payload via `payload()`.
        let padding = (frame.flow_controlled_len() - frame.payload().len()) as WindowSize;
        if padding > 0 {
            tracing::trace!(
                "recv_data; auto-releasing padding of {:?} for {:?}",
                padding,
                stream.id,
            );
            let _res = self.release_capacity(padding, stream, &mut None);
            // cannot fail, we JUST added more in_flight data above.

            debug_assert!(_res.is_ok());
        }

        // An empty DATA frame without END_STREAM has no effect on the HTTP
        // message. Padding has already been accounted for and released above,
        // so there is no event to pass to the user.
        if frame.payload().is_empty() && !frame.is_end_stream() {
            return Ok(());
        }

        let is_budgeted = !frame.is_end_stream();
        let event = Event::Data(DataEvent {
            payload: frame.into_payload(),
            is_budgeted,
        });

        // Push the frame onto the recv buffer
        stream.pending_recv.push_back(&mut self.buffer, event);
        stream.notify_recv();

        Ok(())
    }

    pub(super) fn ignore_data(&mut self, sz: WindowSize) -> Result<(), Error> {
        // Ensure that there is enough capacity on the connection...
        self.consume_connection_window(sz)?;

        // Since we are ignoring this frame,
        // we aren't returning the frame to the user. That means they
        // have no way to release the capacity back to the connection. So
        // we have to release it automatically.
        //
        // This call doesn't send a WINDOW_UPDATE immediately, just marks
        // the capacity as available to be reclaimed. When the available
        // capacity meets a threshold, a WINDOW_UPDATE is then sent.
        self.release_connection_capacity(sz, &mut None);
        Ok(())
    }

    pub(super) fn consume_connection_window(&mut self, sz: WindowSize) -> Result<(), Error> {
        if self.flow.window_size() < sz {
            tracing::debug!(
                "connection error FLOW_CONTROL_ERROR -- window_size ({:?}) < sz ({:?});",
                self.flow.window_size(),
                sz,
            );
            return Err(Error::library_go_away(Reason::FLOW_CONTROL_ERROR));
        }

        // Update connection level flow control
        self.flow.send_data(sz).map_err(Error::library_go_away)?;

        // Track the data as in-flight
        self.in_flight_data += sz;
        Ok(())
    }

    pub(super) fn recv_push_promise(
        &mut self,
        frame: frame::PushPromise,
        stream: &mut store::Ptr,
    ) -> Result<(), Error> {
        stream.state.reserve_remote()?;
        if self.refuse_push_promises {
            return Err(Error::library_reset(
                frame.promised_id(),
                Reason::REFUSED_STREAM,
            ));
        }
        if frame.is_over_size() {
            // A frame is over size if the decoded header block was bigger than
            // SETTINGS_MAX_HEADER_LIST_SIZE.
            //
            // > A server that receives a larger header block than it is willing
            // > to handle can send an HTTP 431 (Request Header Fields Too
            // > Large) status code [RFC6585]. A client can discard responses
            // > that it cannot process.
            //
            // So, if peer is a server, we'll send a 431. In either case,
            // an error is recorded, which will send a PROTOCOL_ERROR,
            // since we don't want any of the data frames either.
            tracing::debug!(
                "stream error PROTOCOL_ERROR -- recv_push_promise: \
                 headers frame is over size; promised_id={:?};",
                frame.promised_id(),
            );
            return Err(Error::library_reset(
                frame.promised_id(),
                Reason::PROTOCOL_ERROR,
            ));
        }

        let promised_id = frame.promised_id();
        let header_size = frame.calculate_header_list_size();
        let (pseudo, fields) = frame.into_parts();

        let push_ext = Extensions::new();
        push_ext.insert(Egress(stream.extensions.clone()));
        stream.req_extensions = Some(push_ext.clone());

        let req = crate::h2::server::Peer::convert_poll_message(
            pseudo,
            fields,
            header_size,
            promised_id,
            push_ext,
        )?;

        if let Err(e) = frame::PushPromise::validate_request(&req) {
            match e {
                PushPromiseHeaderError::NotSafeAndCacheable => proto_err!(
                    stream:
                    "recv_push_promise: method {} is not safe and cacheable; promised_id={:?}",
                    req.method(),
                    promised_id,
                ),
                PushPromiseHeaderError::InvalidContentLength(e) => proto_err!(
                    stream:
                    "recv_push_promise; promised request has invalid content-length {:?}; promised_id={:?}",
                    e,
                    promised_id,
                ),
            }
            return Err(Error::library_reset(promised_id, Reason::PROTOCOL_ERROR));
        }

        stream.pending_recv.push_back(
            &mut self.buffer,
            Event::Headers(peer::PollMessage::Server(req)),
        );
        stream.notify_recv();
        stream.notify_push();
        Ok(())
    }

    /// Ensures that `id` is not in the `Idle` state.
    pub(super) fn ensure_not_idle(&self, id: StreamId) -> Result<(), Reason> {
        if let Ok(next) = self.next_stream_id
            && id >= next
        {
            tracing::debug!(
                "stream ID implicitly closed, PROTOCOL_ERROR; stream={:?}",
                id
            );
            return Err(Reason::PROTOCOL_ERROR);
        }
        // if next_stream_id is overflowed, that's ok.

        Ok(())
    }

    /// Handle remote sending an explicit RST_STREAM.
    #[expect(clippy::unused_self, clippy::needless_pass_by_ref_mut)]
    pub(super) fn recv_reset(
        &mut self,
        frame: frame::Reset,
        stream: &mut Stream,
        counts: &mut Counts,
    ) -> Result<(), Error> {
        // Reseting a stream that the user hasn't accepted is possible,
        // but should be done with care. These streams will continue
        // to take up memory in the accept queue, but will no longer be
        // counted as "concurrent" streams.
        //
        // So, we have a separate limit for these.
        //
        // See https://github.com/hyperium/hyper/issues/2877
        if stream.is_pending_accept {
            if counts.can_inc_num_remote_reset_streams() {
                counts.inc_num_remote_reset_streams();
            } else {
                tracing::warn!(
                    "recv_reset; remotely-reset pending-accept streams reached limit ({:?})",
                    counts.max_remote_reset_streams(),
                );
                return Err(Error::library_go_away_data(
                    Reason::ENHANCE_YOUR_CALM,
                    "too_many_resets",
                ));
            }
        }

        // Notify the stream
        stream.state.recv_reset(frame, stream.is_pending_send);
        // Mark this specific stream as broken
        stream
            .extensions
            .self_get_ref_or_insert(ConnectionHealthWatcher::default)
            .mark_broken();

        stream.notify_send();
        stream.notify_recv();
        stream.notify_push();

        Ok(())
    }

    /// Handle a connection-level error
    #[expect(clippy::unused_self, clippy::needless_pass_by_ref_mut)]
    pub(super) fn handle_error(&mut self, err: &proto::Error, stream: &mut Stream) {
        // Receive an error
        stream.state.handle_error(err);

        // If a receiver is waiting, notify it
        stream.notify_send();
        stream.notify_recv();
        stream.notify_push();
    }

    pub(super) fn go_away(&mut self, last_processed_id: StreamId) {
        debug_assert!(self.max_stream_id >= last_processed_id);
        self.max_stream_id = last_processed_id;
    }

    #[expect(clippy::unused_self, clippy::needless_pass_by_ref_mut)]
    pub(super) fn recv_eof(&mut self, stream: &mut Stream) {
        stream.state.recv_eof();
        stream.notify_send();
        stream.notify_recv();
        stream.notify_push();
    }

    pub(super) fn clear_recv_buffer(
        &mut self,
        stream: &mut Stream,
        task: &mut Option<Waker>,
        counts: &mut Counts,
    ) {
        let mut to_release: WindowSize = 0;
        while let Some(event) = stream.pending_recv.pop_front(&mut self.buffer) {
            if let Event::Data(data) = &event {
                if data.is_budgeted {
                    counts.release_data_frame(data.payload.len());
                }
                to_release = to_release
                    .saturating_add(data.payload.len() as WindowSize)
                    .min(stream.in_flight_recv_data);
            }
        }
        // Release flow control capacity. Cases:
        // * User read data but hasn't released: buf=0, in_flight>0 -> release 0
        // * User released without reading: buf>0, in_flight=0 -> release 0
        // * Normal drop without reading: buf=in_flight -> full release
        if to_release > 0 {
            stream.in_flight_recv_data -= to_release;
            self.release_connection_capacity(to_release, task);
        }
    }

    /// Get the max ID of streams we can receive.
    ///
    /// This gets lowered if we send a GOAWAY frame.
    pub(super) fn max_stream_id(&self) -> StreamId {
        self.max_stream_id
    }

    pub(super) fn next_stream_id(&self) -> Result<StreamId, Error> {
        if let Ok(id) = self.next_stream_id {
            Ok(id)
        } else {
            Err(Error::library_go_away(Reason::PROTOCOL_ERROR))
        }
    }

    pub(super) fn may_have_created_stream(&self, id: StreamId) -> bool {
        if let Ok(next_id) = self.next_stream_id {
            // Peer::is_local_init should have been called beforehand
            debug_assert_eq!(id.is_server_initiated(), next_id.is_server_initiated(),);
            id < next_id
        } else {
            true
        }
    }

    pub(super) fn maybe_reset_next_stream_id(&mut self, id: StreamId) {
        if let Ok(next_id) = self.next_stream_id {
            // !Peer::is_local_init should have been called beforehand
            debug_assert_eq!(id.is_server_initiated(), next_id.is_server_initiated());
            if id >= next_id {
                self.next_stream_id = id.next_id();
            }
        }
    }

    /// Returns true if the remote peer can reserve a stream with the given ID.
    pub(super) fn ensure_can_reserve(&self) -> Result<(), Error> {
        if !self.is_push_enabled {
            proto_err!(conn: "recv_push_promise: push is disabled");
            return Err(Error::library_go_away(Reason::PROTOCOL_ERROR));
        }

        Ok(())
    }

    /// Add a locally reset stream to queue to be eventually reaped.
    pub(super) fn enqueue_reset_expiration(
        &mut self,
        stream: &mut store::Ptr,
        counts: &mut Counts,
    ) {
        if !stream.state.is_local_error() || stream.is_pending_reset_expiration() {
            return;
        }

        if counts.can_inc_num_reset_streams() {
            counts.inc_num_reset_streams();
            tracing::trace!("enqueue_reset_expiration; {:?}", stream.id);
            self.pending_reset_expired.push(stream);
        } else {
            tracing::trace!(
                "enqueue_reset_expiration; dropped {:?}, over max_concurrent_reset_streams",
                stream.id
            );
        }
    }

    pub(super) fn clear_expired_reset_streams(&mut self, store: &mut Store, counts: &mut Counts) {
        if !self.pending_reset_expired.is_empty() {
            let now = Instant::now();
            let reset_duration = self.reset_duration;
            while let Some(stream) = self.pending_reset_expired.pop_if(store, |stream| {
                let Some(reset_at) = stream.reset_at else {
                    warn!("h2 proto stream: reset_at must be set if in queue; force expired; report bug to rama");
                    return true;
                };
                // rust-lang/rust#86470 tracks a bug in the standard library where `Instant`
                // subtraction can panic (because, on some platforms, `Instant` isn't actually
                // monotonic). We use a saturating operation to avoid this panic here.
                now.saturating_duration_since(reset_at) > reset_duration
            }) {
                counts.transition_after(stream, true);
            }
        }
    }

    pub(super) fn clear_queues(
        &mut self,
        clear_pending_accept: bool,
        store: &mut Store,
        counts: &mut Counts,
    ) {
        self.clear_stream_window_update_queue(store, counts);
        self.clear_all_reset_streams(store, counts);

        if clear_pending_accept {
            self.clear_all_pending_accept(store, counts);
        }
    }

    fn clear_stream_window_update_queue(&mut self, store: &mut Store, counts: &mut Counts) {
        while let Some(stream) = self.pending_window_updates.pop(store) {
            counts.transition(stream, |_, stream| {
                tracing::trace!("clear_stream_window_update_queue; stream={:?}", stream.id);
            })
        }
    }

    /// Called on EOF
    fn clear_all_reset_streams(&mut self, store: &mut Store, counts: &mut Counts) {
        while let Some(stream) = self.pending_reset_expired.pop(store) {
            counts.transition_after(stream, true);
        }
    }

    fn clear_all_pending_accept(&mut self, store: &mut Store, counts: &mut Counts) {
        while let Some(stream) = self.pending_accept.pop(store) {
            counts.transition_after(stream, false);
        }
    }

    pub(super) fn buffer_pending<T, B>(
        &mut self,
        store: &mut Store,
        counts: &mut Counts,
        dst: &mut Codec<T, Prioritized<B>>,
    ) -> Result<BufferStatus, crate::h2::proto::Error>
    where
        T: AsyncWrite + Unpin,
        B: Buf,
    {
        // Send any pending connection level window updates
        if self.send_connection_window_update(dst)? == BufferStatus::CodecFull {
            return Ok(BufferStatus::CodecFull);
        }

        // Send any pending stream level window updates
        if self.send_stream_window_updates(store, counts, dst)? == BufferStatus::CodecFull {
            return Ok(BufferStatus::CodecFull);
        }

        Ok(BufferStatus::Complete)
    }

    /// Send connection level window update
    fn send_connection_window_update<T, B>(
        &mut self,
        dst: &mut Codec<T, Prioritized<B>>,
    ) -> Result<BufferStatus, crate::h2::proto::Error>
    where
        T: AsyncWrite + Unpin,
        B: Buf,
    {
        if let Some(incr) = self.flow.unclaimed_capacity() {
            let frame = frame::WindowUpdate::new(StreamId::zero(), incr);

            // Ensure the codec has capacity
            if !dst.has_send_capacity() {
                return Ok(BufferStatus::CodecFull);
            }

            // Buffer the WINDOW_UPDATE frame
            dst.buffer(frame.into())?;

            // Update flow control
            self.flow.inc_window(incr).map_err(|reason| {
                warn!("h2 stream recv: unexpected update flow control error: reason = {reason}");
                crate::h2::proto::Error::library_go_away(reason)
            })?;
        }

        Ok(BufferStatus::Complete)
    }

    /// Send stream level window update
    pub(super) fn send_stream_window_updates<T, B>(
        &mut self,
        store: &mut Store,
        counts: &mut Counts,
        dst: &mut Codec<T, Prioritized<B>>,
    ) -> Result<BufferStatus, crate::h2::proto::Error>
    where
        T: AsyncWrite + Unpin,
        B: Buf,
    {
        loop {
            // Ensure the codec has capacity
            if !dst.has_send_capacity() {
                return Ok(BufferStatus::CodecFull);
            }

            // Get the next stream
            let Some(stream) = self.pending_window_updates.pop(store) else {
                return Ok(BufferStatus::Complete);
            };

            counts.transition(stream, |_, stream| {
                tracing::trace!("pending_window_updates -- pop; stream={:?}", stream.id);
                debug_assert!(!stream.is_pending_window_update);

                if !stream.state.is_recv_streaming() {
                    // No need to send window updates on the stream if the stream is
                    // no longer receiving data.
                    //
                    // TODO: is this correct? We could possibly send a window
                    // update on a ReservedRemote stream if we already know
                    // we want to stream the data faster...
                    return Ok::<_, crate::h2::proto::Error>(());
                }

                // TODO: de-dup
                if let Some(incr) = stream.recv_flow.unclaimed_capacity() {
                    // Create the WINDOW_UPDATE frame
                    let frame = frame::WindowUpdate::new(stream.id, incr);

                    // Buffer it
                    dst.buffer(frame.into())?;

                    // Update flow control
                    stream
                        .recv_flow
                        .inc_window(incr)
                        .map_err(|reason| {
                            warn!("h2 proto stream: unexpected flow control state error: reason = {reason}");
                            crate::h2::proto::Error::library_go_away(reason)
                        })?;
                }

                Ok(())
            })?;
        }
    }

    pub(super) fn next_incoming(&mut self, store: &mut Store) -> Option<store::Key> {
        self.pending_accept.pop(store).map(|ptr| ptr.key())
    }

    pub(super) fn poll_data(
        &mut self,
        cx: &Context,
        stream: &mut Stream,
    ) -> Poll<Option<Result<DataEvent, proto::Error>>> {
        match stream.pending_recv.pop_front(&mut self.buffer) {
            Some(Event::Data(data)) => Poll::Ready(Some(Ok(data))),
            Some(event) => {
                // Frame is trailer
                stream.pending_recv.push_front(&mut self.buffer, event);

                // Notify the recv task. This is done just in case
                // `poll_trailers` was called.
                //
                // It is very likely that `notify_recv` will just be a no-op (as
                // the task will be None), so this isn't really much of a
                // performance concern. It also means we don't have to track
                // state to see if `poll_trailers` was called before `poll_data`
                // returned `None`.
                stream.notify_recv();

                // No more data frames
                Poll::Ready(None)
            }
            None => self.schedule_recv(cx, stream),
        }
    }

    pub(super) fn poll_trailers(
        &mut self,
        cx: &Context,
        stream: &mut Stream,
    ) -> Poll<Option<Result<HeaderMap, proto::Error>>> {
        match stream.pending_recv.pop_front(&mut self.buffer) {
            Some(Event::Trailers(trailers)) => Poll::Ready(Some(Ok(trailers))),
            Some(event) => {
                // Frame is not trailers.. not ready to poll trailers yet.
                stream.pending_recv.push_front(&mut self.buffer, event);
                stream.recv_task = Some(cx.waker().clone());
                Poll::Pending
            }
            None => self.schedule_recv(cx, stream),
        }
    }

    #[expect(clippy::unused_self, clippy::needless_pass_by_ref_mut)]
    fn schedule_recv<T>(
        &mut self,
        cx: &Context,
        stream: &mut Stream,
    ) -> Poll<Option<Result<T, proto::Error>>> {
        if stream.state.ensure_recv_open()? {
            // Request to get notified once more frames arrive
            stream.recv_task = Some(cx.waker().clone());
            Poll::Pending
        } else {
            // No more frames will be received
            Poll::Ready(None)
        }
    }
}

// ===== impl Open =====

impl Open {
    pub(crate) fn is_push_promise(self) -> bool {
        matches!(self, Self::PushPromise)
    }
}

// ===== impl RecvHeaderBlockError =====

impl<T> From<Error> for RecvHeaderBlockError<T> {
    fn from(err: Error) -> Self {
        Self::State(err)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> Config {
        Config {
            initial_max_send_streams: 0,
            local_max_buffer_size: 0,
            local_next_stream_id: 2.into(),
            local_push_enabled: false,
            refuse_push_promises: false,
            extended_connect_protocol_enabled: false,
            local_reset_duration: Duration::ZERO,
            local_reset_max: 0,
            remote_reset_max: 0,
            remote_init_window_sz: DEFAULT_INITIAL_WINDOW_SIZE,
            remote_max_initiated: None,
            local_max_error_reset_streams: None,
            headers_pseudo_order: None,
            early_frame_ctx: frame::EarlyFrameStreamContext::new_nop(),
            data_frame_budget: DataFrameBudget::Configured(DEFAULT_DATA_FRAME_BUDGET),
        }
    }

    #[test]
    fn replayed_connection_window_keeps_released_capacity() {
        let mut recv = Recv::try_new(peer::Dyn::Server, &config()).unwrap();
        recv.set_target_connection_window(1_000_000, &mut None)
            .unwrap();
        let replay = recv.prepare_replayed_connection_window(100, true).unwrap();
        assert_eq!(replay.target, DEFAULT_INITIAL_WINDOW_SIZE + 100);
        recv.commit_replayed_connection_window(replay);

        // Received bytes have been consumed and released, but their automatic
        // WINDOW_UPDATE is still below its batching threshold.
        recv.flow.send_data(64).unwrap();
        recv.flow.assign_capacity(64).unwrap();
        let replay = recv.prepare_replayed_connection_window(200, false).unwrap();
        assert_eq!(replay.target, DEFAULT_INITIAL_WINDOW_SIZE + 300);
        recv.commit_replayed_connection_window(replay);
        assert_eq!(
            recv.flow.window_size(),
            DEFAULT_INITIAL_WINDOW_SIZE + 300 - 64
        );
        assert_eq!(
            recv.flow.available().checked_size(),
            DEFAULT_INITIAL_WINDOW_SIZE + 300
        );

        let window = recv.flow.window_size();
        let available = recv.flow.available();
        assert_eq!(
            recv.prepare_replayed_connection_window(proto::MAX_WINDOW_SIZE, false)
                .unwrap_err(),
            Reason::FLOW_CONTROL_ERROR
        );
        assert_eq!(recv.flow.window_size(), window);
        assert_eq!(recv.flow.available(), available);
    }

    #[test]
    fn clear_recv_buffer_caps_capacity_before_overflow() {
        const FRAME_LEN: usize = 1 << 20;
        const FRAME_COUNT: usize = (u32::MAX as usize / FRAME_LEN) + 1;

        let config = config();
        let mut recv = Recv::try_new(peer::Dyn::Server, &config).unwrap();
        let mut store = Store::new();
        let mut stream = store.insert(
            StreamId::from(1),
            Stream::try_new(
                StreamId::from(1),
                0,
                DEFAULT_INITIAL_WINDOW_SIZE,
                &Extensions::default(),
            )
            .unwrap(),
        );
        let data = Bytes::from(vec![0; FRAME_LEN]);

        for _ in 0..FRAME_COUNT {
            stream.pending_recv.push_back(
                &mut recv.buffer,
                Event::Data(DataEvent {
                    payload: data.clone(),
                    is_budgeted: true,
                }),
            );
        }
        stream.in_flight_recv_data = DEFAULT_INITIAL_WINDOW_SIZE;
        recv.in_flight_data = DEFAULT_INITIAL_WINDOW_SIZE;

        let mut counts = Counts::new(peer::Dyn::Server, &config);
        recv.clear_recv_buffer(&mut stream, &mut None, &mut counts);

        assert!(stream.pending_recv.is_empty());
        assert_eq!(stream.in_flight_recv_data, 0);
        assert_eq!(recv.in_flight_data, 0);

        stream.unlink();
        stream.remove();
    }
}
