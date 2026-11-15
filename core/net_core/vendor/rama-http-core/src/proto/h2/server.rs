use std::{
    convert::Infallible,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll, ready},
    time::Duration,
};

use pin_project_lite::pin_project;
use rama_core::{
    Service,
    bytes::Bytes,
    error::BoxError,
    extensions::ExtensionsRef,
    rt::Executor,
    telemetry::tracing::{Instrument, debug, trace, trace_root_span, warn},
};
use rama_http::{
    StreamingBody,
    io::upgrade::{self, Pending, Upgraded},
    opentelemetry::version_as_protocol_version,
};
use rama_http_types::{
    Method, Request, Response, StatusCode,
    header::{self, trailer::ForbiddenTrailers},
    proto::h2::frame::Settings,
    proto::{ext::Protocol, h2::ext::ResetStream},
};
use tokio::io::{AsyncRead, AsyncWrite};

use super::{PipeToSendStream, SendBuf, ping};
use crate::{
    body::Incoming as IncomingBody,
    common::date,
    h2::{
        Reason, RecvStream,
        server::{Connection, Handshake, SendResponse},
    },
    headers,
    proto::{Dispatched, h2::ping::Recorder},
    server::conn::timeout::{Activity, ConnTimer, Expired, HeaderReadTimeout, IdleTimeout},
};

// Our defaults are chosen for the "majority" case, which usually are not
// resource constrained, and so the spec default of 64kb can be too limiting
// for performance.
//
// At the same time, a server more often has multiple clients connected, and
// so is more likely to use more resources than a client would.
const DEFAULT_CONN_WINDOW: u32 = 1024 * 1024; // 1mb
const DEFAULT_STREAM_WINDOW: u32 = 1024 * 1024; // 1mb
const DEFAULT_MAX_FRAME_SIZE: u32 = 1024 * 16; // 16kb
const DEFAULT_MAX_SEND_BUF_SIZE: u32 = 1024 * 400; // 400kb
const DEFAULT_SETTINGS_MAX_HEADER_LIST_SIZE: u32 = 1024 * 16; // 16kb
const DEFAULT_MAX_LOCAL_ERROR_RESET_STREAMS: usize = 1024;

#[derive(Clone, Debug)]
pub(crate) struct Config {
    pub(crate) initial_settings: Option<Arc<Settings>>,
    pub(crate) adaptive_window: bool,
    pub(crate) initial_conn_window_size: u32,
    pub(crate) initial_stream_window_size: u32,
    pub(crate) max_frame_size: u32,
    pub(crate) enable_connect_protocol: bool,
    pub(crate) send_alt_svc: bool,
    pub(crate) observe_early_frames: bool,
    pub(crate) max_concurrent_streams: Option<u32>,
    pub(crate) max_pending_accept_reset_streams: Option<usize>,
    pub(crate) max_local_error_reset_streams: Option<usize>,
    pub(crate) data_frame_budget: Option<usize>,
    pub(crate) keep_alive_interval: Option<Duration>,
    pub(crate) keep_alive_timeout: Duration,
    pub(crate) max_send_buffer_size: u32,
    pub(crate) header_table_size: Option<u32>,
    pub(crate) max_header_list_size: u32,
    pub(crate) date_header: bool,
    pub(crate) strict_connect_framing: bool,
    pub(crate) header_read_timeout: Option<HeaderReadTimeout>,
    pub(crate) idle_timeout: Option<IdleTimeout>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            initial_settings: None,
            adaptive_window: false,
            initial_conn_window_size: DEFAULT_CONN_WINDOW,
            initial_stream_window_size: DEFAULT_STREAM_WINDOW,
            max_frame_size: DEFAULT_MAX_FRAME_SIZE,
            enable_connect_protocol: false,
            send_alt_svc: false,
            observe_early_frames: false,
            max_concurrent_streams: Some(200),
            max_pending_accept_reset_streams: None,
            max_local_error_reset_streams: Some(DEFAULT_MAX_LOCAL_ERROR_RESET_STREAMS),
            data_frame_budget: None,
            header_table_size: None,
            keep_alive_interval: None,
            keep_alive_timeout: Duration::from_secs(20),
            max_send_buffer_size: DEFAULT_MAX_SEND_BUF_SIZE,
            max_header_list_size: DEFAULT_SETTINGS_MAX_HEADER_LIST_SIZE,
            date_header: true,
            strict_connect_framing: false,
            header_read_timeout: Some(HeaderReadTimeout::default()),
            idle_timeout: Some(IdleTimeout::default()),
        }
    }
}

/// Per-response options, copied to every stream of a connection.
#[derive(Debug, Clone, Copy)]
struct ResponseOptions {
    date_header: bool,
    /// Refuse, rather than drop, framing fields on a 2xx to CONNECT.
    strict_connect_framing: bool,
}

pin_project! {
    pub(crate) struct Server<T, S>
    where
        S: Service<Request<IncomingBody>, Output = Response, Error = Infallible>
    {
        exec: Executor,
        service: S,
        state: State<T>,
        options: ResponseOptions,
        close_pending: bool,
        timer: ConnTimer,
    }
}

//#[expect(clippy::large_enum_variant, reason = "the whole future is boxed")]
#[expect(clippy::large_enum_variant)]
enum State<T> {
    Handshaking {
        ping_config: ping::Config,
        hs: Handshake<T, SendBuf<Bytes>>,
    },
    Serving(Serving<T>),
}

struct Serving<T> {
    /// What the deadlines observed at the last poll.
    activity: Activity,
    /// How this server closes the connection, once it decided to.
    closing: Option<Closing>,
    ping: Option<(ping::Recorder, ping::Ponger)>,
    conn: Connection<T, SendBuf<Bytes>>,
    options: ResponseOptions,
}

/// The stages of a close this server started.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Closing {
    /// A graceful GOAWAY went out; requests that raced it may still complete.
    Draining,
    /// The final GOAWAY went out; the connection closes once it is flushed.
    Final,
    /// A request head timed out: a GOAWAY with `ENHANCE_YOUR_CALM` went out.
    HeadTimeout,
}

impl<T, S> Server<T, S>
where
    T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef,
    S: Service<Request<IncomingBody>, Output = Response, Error = Infallible>,
{
    pub(crate) fn new(
        io: T,
        service: S,
        config: &Config,
        exec: Executor,
        mut timer: ConnTimer,
    ) -> Self {
        let mut builder = crate::h2::server::Builder::default()
            .with_initial_window_size(config.initial_stream_window_size)
            .with_initial_connection_window_size(config.initial_conn_window_size)
            .with_max_frame_size(config.max_frame_size)
            .with_max_header_list_size(config.max_header_list_size)
            .maybe_with_max_local_error_reset_streams(config.max_local_error_reset_streams)
            .maybe_with_data_frame_budget(config.data_frame_budget)
            .with_max_send_buffer_size(config.max_send_buffer_size);

        if let Some(max) = config.max_concurrent_streams {
            builder.set_max_concurrent_streams(max);
        }
        if let Some(size) = config.header_table_size {
            builder.set_header_table_size(size);
        }

        if let Some(max) = config.max_pending_accept_reset_streams {
            builder.set_max_pending_accept_reset_streams(max);
        }

        if config.enable_connect_protocol {
            builder.set_enable_connect_protocol();
        }

        if let Some(settings) = &config.initial_settings {
            builder.set_initial_settings(settings.clone());
        }
        builder.set_alt_svc(config.send_alt_svc);
        builder.set_observe_early_frames(config.observe_early_frames);
        let handshake = builder.handshake(io);

        let bdp = config
            .adaptive_window
            .then_some(config.initial_stream_window_size);

        let ping_config = ping::Config {
            bdp_initial_window: bdp,
            keep_alive_interval: config.keep_alive_interval,
            keep_alive_timeout: config.keep_alive_timeout,
            // If keep-alive is enabled for servers, always enabled while
            // idle, so it can more aggressively close dead connections.
            keep_alive_while_idle: true,
        };

        timer.reconfigure(config.idle_timeout, config.header_read_timeout);

        Self {
            exec,
            state: State::Handshaking {
                ping_config,
                hs: handshake,
            },
            service,
            options: ResponseOptions {
                date_header: config.date_header,
                strict_connect_framing: config.strict_connect_framing,
            },
            close_pending: false,
            timer,
        }
    }

    pub(crate) fn graceful_shutdown(&mut self) {
        trace!("graceful_shutdown");
        match &mut self.state {
            State::Handshaking { .. } => {
                self.close_pending = true;
            }
            State::Serving(srv) => {
                srv.conn.graceful_shutdown();
            }
        }
    }
}

impl<T, S> Future for Server<T, S>
where
    T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef,
    S: Service<Request<IncomingBody>, Output = Response, Error = Infallible> + Clone,
{
    type Output = crate::Result<Dispatched>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let me = &mut *self;
        loop {
            let next = match &mut me.state {
                State::Handshaking { hs, ping_config } => {
                    let mut conn =
                        match Pin::new(&mut *hs).poll(cx).map_err(crate::Error::new_h2)? {
                            Poll::Ready(conn) => conn,
                            Poll::Pending => {
                                let activity =
                                    hs.preface_progress().map_or(Activity::Idle, |bytes| {
                                        Activity::Head { bytes, block: 0 }
                                    });
                                return match me.timer.poll(cx, activity) {
                                    Poll::Ready(Expired::Head) => {
                                        debug!("client preface deadline elapsed");
                                        Poll::Ready(Err(crate::Error::new_header_timeout()))
                                    }
                                    Poll::Ready(Expired::Idle | Expired::Drain) => {
                                        debug!("idle before the client preface, closing");
                                        Poll::Ready(Ok(Dispatched::Shutdown))
                                    }
                                    Poll::Pending => Poll::Pending,
                                };
                            }
                        };
                    // The preface is not a request head: the first one starts fresh.
                    me.timer.mark_busy();
                    let ping = if ping_config.is_enabled() {
                        let Some(pp) = conn.ping_pong() else {
                            return Poll::Ready(Err(
                                crate::Error::new_parse_internal()
                                    .with_display("bug: report in rama crate: server: conn.ping_pong not available while ping config is enabled"),
                            ));
                        };
                        Some(ping::channel(pp, ping_config))
                    } else {
                        None
                    };
                    State::Serving(Serving {
                        activity: Activity::Busy,
                        closing: None,
                        ping,
                        conn,
                        options: me.options,
                    })
                }
                State::Serving(srv) => {
                    // graceful_shutdown was called before handshaking finished,
                    if me.close_pending {
                        srv.conn.graceful_shutdown();
                    }
                    ready!(srv.poll_server(cx, &mut me.service, &me.exec, &mut me.timer))?;
                    return Poll::Ready(Ok(Dispatched::Shutdown));
                }
            };
            me.state = next;
        }
    }
}

impl<T> Serving<T>
where
    T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef,
{
    #[expect(clippy::needless_pass_by_ref_mut)]
    fn poll_server<S>(
        &mut self,
        cx: &mut Context<'_>,
        service: &mut S,
        exec: &Executor,
        timer: &mut ConnTimer,
    ) -> Poll<crate::Result<()>>
    where
        S: Service<Request<IncomingBody>, Output = Response, Error = Infallible> + Clone,
    {
        loop {
            self.poll_ping(cx, timer);

            // A head that ran out while unpolled must not be completed by bytes ready now.
            if let Activity::Head { bytes, .. } = self.activity
                && timer.head_elapsed(bytes)
                && let Some(result) = self.expire(timer, Expired::Head)
            {
                return Poll::Ready(result);
            }

            let (req, mut respond) = match self.conn.poll_accept(cx) {
                Poll::Ready(Some(Ok(accepted))) => accepted,
                Poll::Ready(Some(Err(e))) => {
                    return Poll::Ready(Err(self.close_error(crate::Error::new_h2(e))));
                }
                Poll::Ready(None) => {
                    // no more incoming streams...
                    if let Some((ref ping, _)) = self.ping {
                        ping.ensure_not_timed_out()?;
                    }

                    trace!("incoming connection complete");
                    return Poll::Ready(self.closed());
                }
                Poll::Pending => {
                    if !timer.is_enabled() {
                        return Poll::Pending;
                    }
                    self.activity = match self.closing {
                        None | Some(Closing::Draining) => self.conn.timeout_activity(),
                        // Only the bound on flushing the close is left.
                        Some(Closing::Final | Closing::HeadTimeout) => Activity::Idle,
                    };
                    match timer.poll(cx, self.activity) {
                        Poll::Pending => return Poll::Pending,
                        Poll::Ready(expired) => {
                            if let Some(result) = self.expire(timer, expired) {
                                return Poll::Ready(result);
                            }
                            // Drive the GOAWAY this queued.
                            continue;
                        }
                    }
                }
            };

            timer.request_received();
            self.activity = Activity::Busy;
            trace!("incoming request");
            let content_length = headers::content_length_parse_all(req.headers());
            let ping = self
                .ping
                .as_ref()
                .map(|ping| ping.0.clone())
                .unwrap_or_else(ping::disabled);

            // Record the headers received
            ping.record_non_data();

            let is_connect = req.method() == Method::CONNECT;
            let is_head = req.method() == Method::HEAD;
            let (parts, stream) = req.into_parts();
            let (req, connect_parts) = if !is_connect {
                (
                    Request::from_parts(
                        parts,
                        IncomingBody::h2(stream, content_length.into(), ping),
                    ),
                    None,
                )
            } else {
                if content_length.is_some_and(|len| len != 0) {
                    warn!("h2 connect request with non-zero body not supported");
                    respond.send_reset(Reason::INTERNAL_ERROR);
                    return Poll::Ready(Ok(()));
                }
                let extended = parts.extensions.contains::<Protocol>();
                let (pending, upgrade) = upgrade::pending();
                parts.extensions.insert(upgrade);
                (
                    Request::from_parts(parts, IncomingBody::empty()),
                    Some(ConnectParts {
                        pending,
                        ping,
                        recv_stream: stream,
                        extended,
                    }),
                )
            };

            let serve_span = trace_root_span!(
                "h2::stream",
                otel.kind = "server",
                http.request.method = %req.method().as_str(),
                url.full = %req.request_uri(),
                url.path = %req.uri().path_or_root().as_ref(),
                url.query = %req.uri().query_or_empty().as_ref(),
                url.scheme = %req.uri().scheme_str().unwrap_or_default(),
                network.protocol.name = "http",
                network.protocol.version = version_as_protocol_version(req.version()),
            );

            let serve_fut = {
                let service = service.clone();
                async move { service.serve(req).await }
            };

            let fut = H2Stream::new(
                serve_fut,
                connect_parts,
                respond,
                self.options,
                is_head,
                exec.clone(),
            );

            exec.spawn_task(fut.instrument(serve_span));
        }
    }

    /// Act on an elapsed deadline: `Some` ends the connection right away.
    fn expire(&mut self, timer: &mut ConnTimer, expired: Expired) -> Option<crate::Result<()>> {
        match (expired, self.closing) {
            (Expired::Idle, _) => {
                debug!("idle deadline elapsed, sending a graceful GOAWAY");
                self.conn.graceful_shutdown();
                self.closing = Some(Closing::Draining);
            }
            (Expired::Head, _) => {
                debug!("request head deadline elapsed, sending GOAWAY");
                self.conn.abrupt_shutdown(Reason::ENHANCE_YOUR_CALM);
                self.closing = Some(Closing::HeadTimeout);
            }
            (Expired::Drain, Some(Closing::Draining)) => {
                // Flushes what raced the first GOAWAY, then closes the transport.
                debug!("graceful close not completed by the peer, sending the final GOAWAY");
                self.conn.abrupt_shutdown(Reason::NO_ERROR);
                self.closing = Some(Closing::Final);
            }
            (Expired::Drain, None | Some(Closing::Final | Closing::HeadTimeout)) => {
                debug!("connection close not flushed in time, dropping it");
                return Some(self.closed());
            }
        }
        timer.start_drain();
        None
    }

    /// How a connection that ended reports to its caller.
    fn closed(&self) -> crate::Result<()> {
        match self.closing {
            Some(Closing::HeadTimeout) => Err(crate::Error::new_header_timeout()),
            None | Some(Closing::Draining | Closing::Final) => Ok(()),
        }
    }

    /// A head timeout is what ended a connection that failed while closing for it.
    fn close_error(&self, error: crate::Error) -> crate::Error {
        match self.closing {
            Some(Closing::HeadTimeout) => crate::Error::new_header_timeout(),
            None | Some(Closing::Draining | Closing::Final) => error,
        }
    }

    fn poll_ping(&mut self, cx: &mut Context<'_>, timer: &mut ConnTimer) {
        if let Some(rtt) = self.conn.take_settings_rtt() {
            timer.set_rtt(rtt);
        }
        if let Some((_, estimator)) = &mut self.ping {
            match estimator.poll(cx) {
                Poll::Ready(ping::Ponged::SizeUpdate(wnd)) => {
                    if let Err(err) = self.conn.try_set_target_window_size(wnd) {
                        let reason = err.reason().unwrap_or(Reason::INTERNAL_ERROR);
                        debug!("target window size failed to update: {err}; reason = {reason}");
                        self.conn.abrupt_shutdown(reason);
                    }
                    if let Err(err) = self.conn.try_set_initial_window_size(wnd) {
                        let reason = err.reason().unwrap_or(Reason::INTERNAL_ERROR);
                        trace!("initial window size failed to update: {err}; reason = {reason}");
                        // this may fail for legit reasons...so we only log it
                    }
                }
                Poll::Ready(ping::Ponged::KeepAliveTimedOut) => {
                    debug!("keep-alive timed out, closing connection");
                    self.conn.abrupt_shutdown(Reason::NO_ERROR);
                }
                Poll::Pending => {}
            }
            if let Some(rtt) = estimator.latest_rtt() {
                timer.set_rtt(rtt);
            }
        }
    }
}

pin_project! {
    pub struct H2Stream<F, B>
    where
        B: StreamingBody,
        B: Send,
        B: 'static,
        B: Unpin,
        B::Data: Send,
        B::Data: 'static,
        B::Error: Into<BoxError>,
    {
        reply: SendResponse<SendBuf<B::Data>>,
        #[pin]
        state: H2StreamState<F, B>,
        options: ResponseOptions,
        is_head: bool,
        exec: Executor,
    }
}

pin_project! {
    #[project = H2StreamStateProj]
    enum H2StreamState<F, B>
    where
        B: StreamingBody,
        B: Send,
        B: 'static,
        B: Unpin,
        B::Data: Send,
        B::Data: 'static,
        B::Error: Into<BoxError>,
    {
        Service {
            #[pin]
            fut: F,
            connect_parts: Option<ConnectParts>,
        },
        Body {
            #[pin]
            pipe: PipeToSendStream<B>,
        },
    }
}

struct ConnectParts {
    pending: Pending,
    ping: Recorder,
    recv_stream: RecvStream,
    extended: bool,
}

impl<F, B> H2Stream<F, B>
where
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
{
    fn new(
        fut: F,
        connect_parts: Option<ConnectParts>,
        respond: SendResponse<SendBuf<B::Data>>,
        options: ResponseOptions,
        is_head: bool,
        exec: Executor,
    ) -> Self {
        Self {
            reply: respond,
            state: H2StreamState::Service { fut, connect_parts },
            options,
            is_head,
            exec,
        }
    }
}

macro_rules! reply {
    ($me:expr, $res:expr, $eos:expr) => {{
        match $me.reply.send_response($res, $eos) {
            Ok(tx) => tx,
            Err(e) => {
                debug!("send response error: {:?}", e);
                $me.reply.send_reset(Reason::INTERNAL_ERROR);
                return Poll::Ready(Err(crate::Error::new_h2(e)));
            }
        }
    }};
}

impl<F, B, E> H2Stream<F, B>
where
    F: Future<Output = Result<Response<B>, E>>,
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
    E: Into<BoxError>,
{
    fn poll2(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<crate::Result<()>> {
        let mut me = self.as_mut().project();
        loop {
            let next = match me.state.as_mut().project() {
                H2StreamStateProj::Service {
                    fut: h,
                    connect_parts,
                } => {
                    let res = match h.poll(cx) {
                        Poll::Ready(Ok(r)) => r,
                        Poll::Pending => {
                            // Response is not yet ready, so we want to check if the client has sent a
                            // RST_STREAM frame which would cancel the current request.
                            if let Poll::Ready(reason) =
                                me.reply.poll_reset(cx).map_err(crate::Error::new_h2)?
                            {
                                debug!("stream received RST_STREAM: {:?}", reason);
                                return Poll::Ready(Err(crate::Error::new_h2(reason.into())));
                            }
                            return Poll::Pending;
                        }
                        Poll::Ready(Err(e)) => {
                            let err = crate::Error::new_user_service(e);
                            warn!("http2 service errored: {}", err);
                            me.reply.send_reset(err.h2_reason());
                            return Poll::Ready(Err(err));
                        }
                    };

                    if let Some(ResetStream(reason)) = res.extensions().get_ref().copied() {
                        debug!("reset stream as requested by response: {reason:?}");
                        me.reply.send_reset(reason);
                        return Poll::Ready(Ok(()));
                    }

                    let (head, body) = res.into_parts();
                    let mut res = Response::from_parts(head, ());
                    if connect_parts.is_some()
                        && res.status().is_success()
                        && me.options.strict_connect_framing
                        && (res.headers().contains_key(header::CONTENT_LENGTH)
                            || res.headers().contains_key(header::TRANSFER_ENCODING))
                    {
                        warn!("framing headers on a successful response to CONNECT, refusing");
                        me.reply.send_reset(Reason::INTERNAL_ERROR);
                        return Poll::Ready(Err(crate::Error::new_user_header()));
                    }
                    super::strip_connection_headers(
                        res.headers_mut(),
                        super::MessageKind::Response,
                    );

                    // set Date header if it isn't already set if instructed
                    if me.options.date_header {
                        res.headers_mut()
                            .entry(header::DATE)
                            .or_insert_with(date::update_and_header_value);
                    }

                    let method = if *me.is_head {
                        Some(&Method::HEAD)
                    } else if connect_parts.is_some() {
                        Some(&Method::CONNECT)
                    } else {
                        None
                    };
                    let response_length = headers::ResponseLength::of(method, res.status());
                    if response_length == headers::ResponseLength::Forbidden
                        && res.headers().contains_key(header::CONTENT_LENGTH)
                    {
                        debug!("content-length dropped: forbidden for this response");
                        res.headers_mut().remove(header::CONTENT_LENGTH);
                    }

                    if let Some(connect_parts) = connect_parts.take()
                        && res.status().is_success()
                    {
                        if body.size_hint().exact().is_some_and(|len| len != 0) {
                            warn!(
                                "body of a successful response to CONNECT dropped: a tunnel follows"
                            );
                        }
                        let send_stream = reply!(me, res, false);
                        let h2_up = super::upgrade::upgraded(
                            send_stream,
                            connect_parts.recv_stream,
                            connect_parts.ping,
                            connect_parts.extended,
                        );
                        connect_parts
                            .pending
                            .fulfill(Upgraded::new(h2_up, Bytes::new()));
                        return Poll::Ready(Ok(()));
                    }

                    // RFC 9110 §9.3.2: the server MUST NOT send a message body
                    // for HEAD responses. Forward Content-Length so the client
                    // knows what a GET would return, but close the stream with
                    // END_STREAM immediately (no DATA frames).
                    if *me.is_head
                        || matches!(
                            res.status(),
                            StatusCode::NO_CONTENT | StatusCode::NOT_MODIFIED
                        )
                    {
                        if let Some(len) = response_length.implied(body.size_hint().exact()) {
                            headers::set_content_length_if_missing(res.headers_mut(), len);
                        }
                        reply!(me, res, true);
                        return Poll::Ready(Ok(()));
                    }

                    if !body.is_end_stream() {
                        // automatically set Content-Length from body...
                        if let Some(len) = response_length.implied(body.size_hint().exact()) {
                            headers::set_content_length_if_missing(res.headers_mut(), len);
                        }

                        let allowed_trailers = res.extensions().get_arc::<ForbiddenTrailers>();
                        let body_tx = reply!(me, res, false);
                        H2StreamState::Body {
                            pipe: PipeToSendStream::new(body, body_tx, allowed_trailers),
                        }
                    } else {
                        reply!(me, res, true);
                        return Poll::Ready(Ok(()));
                    }
                }
                H2StreamStateProj::Body { pipe } => {
                    return pipe.poll(cx);
                }
            };
            me.state.set(next);
        }
    }
}

impl<F, B, E> Future for H2Stream<F, B>
where
    F: Future<Output = Result<Response<B>, E>>,
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
    E: Into<BoxError>,
{
    type Output = ();

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        self.poll2(cx).map(|res| {
            if let Err(_e) = res {
                debug!("stream error: {:?}", _e);
            }
        })
    }
}
