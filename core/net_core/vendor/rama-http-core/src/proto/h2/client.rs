use std::{
    convert::Infallible,
    marker::PhantomData,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll, ready},
    time::Duration,
};

use futures_channel::{
    mpsc,
    mpsc::{Receiver, Sender},
    oneshot,
};
use pin_project_lite::pin_project;
use rama_core::{
    bytes::Bytes,
    combinators::Either,
    error::BoxError,
    extensions::ExtensionsRef,
    futures::{Stream, future::FusedFuture, stream::FusedStream},
    rt::Executor,
    telemetry::tracing::{Instrument, debug, trace, trace_root_span, warn},
};
use rama_http::{
    StreamingBody,
    io::upgrade::{self, Upgraded},
};
use rama_http_types::{
    Method, Request, Response, Version,
    header::trailer::ForbiddenTrailers,
    opentelemetry::version_as_protocol_version,
    proto::{
        ext::Protocol,
        h2::frame::{SettingOrder, Settings},
    },
};
use rama_net::{client::pool::ConnectionAdmission, conn::MaxConcurrency};
use tokio::io::{AsyncRead, AsyncWrite};

use super::{
    PipeToSendStream, SendBuf,
    admission::AdmissionOwner,
    ping,
    ping::{Ponger, Recorder},
};
use crate::{
    body::Incoming as IncomingBody,
    client::dispatch::{Callback, SendWhen, TrySendError},
    h2::{
        SendStream,
        client::{Builder, Connection, ResponseFuture, SendRequest},
    },
    headers,
    proto::Dispatched,
};

type ClientRx<B> = crate::client::dispatch::Receiver<Request<B>, Response<IncomingBody>>;

///// An mpsc channel is used to help notify the `Connection` task when *all*
///// other handles to it have been dropped, so that it can shutdown.
type ConnDropRef = mpsc::Sender<Infallible>;

///// A oneshot channel watches the `Connection` task, and when it completes,
///// the "dispatch" task will be notified and can shutdown sooner.
type ConnEof = oneshot::Receiver<Infallible>;

// Our defaults are chosen for the "majority" case, which usually are not
// resource constrained, and so the spec default of 64kb can be too limiting
// for performance.
const DEFAULT_CONN_WINDOW: u32 = 1024 * 1024 * 5; // 5mb
const DEFAULT_STREAM_WINDOW: u32 = 1024 * 1024 * 2; // 2mb
const DEFAULT_MAX_FRAME_SIZE: u32 = 1024 * 16; // 16kb
const DEFAULT_MAX_SEND_BUF_SIZE: u32 = 1024 * 1024; // 1mb
const DEFAULT_MAX_HEADER_LIST_SIZE: u32 = 1024 * 16; // 16kb

// The maximum number of concurrent streams that the client is allowed to open
// before it receives the initial SETTINGS frame from the server.
// This default value is derived from what the HTTP/2 spec recommends as the
// minimum value that endpoints advertise to their peers. It means that using
// this value will minimize the chance of the failure where the local endpoint
// attempts to open too many streams and gets rejected by the remote peer with
// the `REFUSED_STREAM` error.
const DEFAULT_INITIAL_MAX_SEND_STREAMS: usize = 100;

#[derive(Clone, Debug)]
pub(crate) struct Config {
    pub(crate) initial_settings: Option<Arc<Settings>>,
    pub(crate) observe_peer_settings: bool,
    pub(crate) adaptive_window: bool,
    pub(crate) initial_conn_window_size: u32,
    pub(crate) initial_stream_window_size: u32, // alias for initial_window_size
    pub(crate) initial_max_send_streams: usize,
    pub(crate) refuse_push_promises: bool,
    pub(crate) max_frame_size: Option<u32>,
    pub(crate) max_header_list_size: u32,
    pub(crate) keep_alive_interval: Option<Duration>,
    pub(crate) keep_alive_timeout: Duration,
    pub(crate) keep_alive_while_idle: bool,
    pub(crate) max_concurrent_reset_streams: Option<usize>,
    pub(crate) max_send_buffer_size: u32,
    pub(crate) max_pending_accept_reset_streams: Option<usize>,
    pub(crate) max_local_error_reset_streams: Option<usize>,
    pub(crate) data_frame_budget: Option<usize>,
    pub(crate) header_table_size: Option<u32>,
    pub(crate) max_concurrent_streams: Option<u32>,
    pub(crate) reset_stream_duration: Option<Duration>,
    pub(crate) enable_push: bool,
    pub(crate) enable_connect_protocol: Option<u32>,
    pub(crate) no_rfc7540_priorities: Option<u32>,
    pub(crate) setting_order: Option<SettingOrder>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            initial_settings: None,
            observe_peer_settings: false,
            adaptive_window: false,
            initial_conn_window_size: DEFAULT_CONN_WINDOW,
            initial_stream_window_size: DEFAULT_STREAM_WINDOW,
            initial_max_send_streams: DEFAULT_INITIAL_MAX_SEND_STREAMS,
            refuse_push_promises: false,
            max_frame_size: Some(DEFAULT_MAX_FRAME_SIZE),
            max_header_list_size: DEFAULT_MAX_HEADER_LIST_SIZE,
            keep_alive_interval: None,
            keep_alive_timeout: Duration::from_secs(20),
            keep_alive_while_idle: false,
            max_concurrent_reset_streams: None,
            max_send_buffer_size: DEFAULT_MAX_SEND_BUF_SIZE,
            max_pending_accept_reset_streams: None,
            max_local_error_reset_streams: Some(1024),
            data_frame_budget: None,
            header_table_size: None,
            max_concurrent_streams: None,
            reset_stream_duration: None,
            enable_push: false,
            enable_connect_protocol: None,
            no_rfc7540_priorities: None,
            setting_order: None,
        }
    }
}

pub(crate) fn new_builder(config: &Config) -> Builder {
    let mut builder = Builder::default()
        .with_initial_max_send_streams(config.initial_max_send_streams)
        .with_refuse_push_promises(config.refuse_push_promises)
        .with_initial_window_size(config.initial_stream_window_size)
        .with_initial_connection_window_size(config.initial_conn_window_size)
        .with_max_header_list_size(config.max_header_list_size)
        .with_max_send_buffer_size(config.max_send_buffer_size)
        .maybe_with_max_local_error_reset_streams(config.max_local_error_reset_streams)
        .maybe_with_data_frame_budget(config.data_frame_budget)
        .with_enable_push(config.enable_push);

    if let Some(max) = config.max_frame_size {
        builder.set_max_frame_size(max);
    }
    if let Some(max) = config.max_concurrent_reset_streams {
        builder.set_max_concurrent_reset_streams(max);
    }
    builder.set_observe_peer_settings(config.observe_peer_settings);
    if let Some(settings) = &config.initial_settings {
        builder.set_initial_settings(settings.clone());
    }
    if let Some(max) = config.max_pending_accept_reset_streams {
        builder.set_max_pending_accept_reset_streams(max);
    }
    if let Some(size) = config.header_table_size {
        builder.set_header_table_size(size);
    }
    if let Some(max) = config.max_concurrent_streams {
        builder.set_max_concurrent_streams(max);
    }
    if let Some(dur) = config.reset_stream_duration {
        builder.set_reset_stream_duration(dur);
    }
    if let Some(connect_protocol) = config.enable_connect_protocol {
        builder.set_enable_connect_protocol(connect_protocol);
    }
    if let Some(no_rfc7540_priorities) = config.no_rfc7540_priorities {
        builder.set_no_rfc7540_priorities(no_rfc7540_priorities);
    }
    if let Some(setting_order) = config.setting_order.clone() {
        builder.set_setting_order(setting_order);
    }
    builder
}

fn new_ping_config(config: &Config) -> ping::Config {
    ping::Config {
        bdp_initial_window: if config.adaptive_window {
            Some(config.initial_stream_window_size)
        } else {
            None
        },
        keep_alive_interval: config.keep_alive_interval,
        keep_alive_timeout: config.keep_alive_timeout,
        keep_alive_while_idle: config.keep_alive_while_idle,
    }
}

#[expect(dead_code)]
pub(crate) async fn handshake<T, B>(
    io: T,
    req_rx: ClientRx<B>,
    config: &Config,
    exec: Executor,
) -> crate::Result<ClientTask<B, T>>
where
    T: AsyncRead + AsyncWrite + Send + Unpin + ExtensionsRef + 'static,
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
{
    handshake_with_builder(new_builder(config), io, req_rx, config, exec).await
}

pub(crate) async fn handshake_with_builder<T, B>(
    builder: Builder,
    io: T,
    req_rx: ClientRx<B>,
    config: &Config,
    exec: Executor,
) -> crate::Result<ClientTask<B, T>>
where
    T: AsyncRead + AsyncWrite + Send + Unpin + ExtensionsRef + 'static,
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
{
    let extensions = io.extensions().clone();
    let (h2_tx, mut conn) = builder
        .handshake::<_, SendBuf<B::Data>>(io)
        .await
        .map_err(crate::Error::new_h2)?;
    // The connection keeps the peer's live stream limit at this level, following its SETTINGS.
    let max = extensions
        .self_get_arc_or_insert(|| Arc::new(MaxConcurrency::new(h2_tx.current_max_send_streams())));
    let admission = AdmissionOwner::new(h2_tx.local_streams(), max);

    // An mpsc channel is used entirely to detect when the
    // 'Client' has been dropped. This is to get around a bug
    // in h2 where dropping all SendRequests won't notify a
    // parked Connection.
    let (conn_drop_ref, conn_drop_rx) = mpsc::channel(1);
    let (cancel_tx, conn_eof) = oneshot::channel();

    let ping_config = new_ping_config(config);

    let (conn, ping) = if ping_config.is_enabled() {
        let Some(pp) = conn.ping_pong() else {
            return Err(
                crate::Error::new_parse_internal()
                    .with_display("bug: report in rama crate: client: conn.ping_pong not available while ping config is enabled"),
            );
        };
        let (recorder, ponger) = ping::channel(pp, &ping_config);

        let conn: Conn<_, B> = Conn::new(ponger, conn);
        (Either::A(conn), recorder)
    } else {
        (Either::B(conn), ping::disabled())
    };
    let conn: ConnMapErr<T, B> = ConnMapErr {
        conn,
        is_terminated: false,
    };

    let task_span = trace_root_span!(
        "h2::task",
        otel.kind = "client",
        network.protocol.name = "http",
        network.protocol.version = version_as_protocol_version(Version::HTTP_2),
    );

    exec.spawn_task(
        H2ClientFuture::Task {
            task: ConnTask::new(conn, conn_drop_rx, cancel_tx),
        }
        .instrument(task_span),
    );

    Ok(ClientTask {
        ping,
        conn_drop_ref,
        conn_eof,
        executor: exec,
        h2_tx,
        req_rx,
        fut_ctx: None,
        closing: None,
        admission,
        marker: PhantomData,
    })
}

pin_project! {
    struct Conn<T, B>
    where
        B: StreamingBody,
        B: Send,
        B: 'static,
        B: Unpin,
        B::Data: Send,
        B::Data: 'static,
        B::Error: Into<BoxError>,
    {
        #[pin]
        ponger: Ponger,
        #[pin]
        conn: Connection<T, SendBuf<<B as StreamingBody>::Data>>,
    }
}

impl<T, B> Conn<T, B>
where
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
    T: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    fn new(ponger: Ponger, conn: Connection<T, SendBuf<<B as StreamingBody>::Data>>) -> Self {
        Self { ponger, conn }
    }
}

impl<T, B> Future for Conn<T, B>
where
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
    T: AsyncRead + AsyncWrite + Unpin + Send + ExtensionsRef + 'static,
{
    type Output = Result<(), crate::h2::Error>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let mut this = self.project();
        match this.ponger.poll(cx) {
            Poll::Ready(ping::Ponged::SizeUpdate(wnd)) => {
                this.conn.try_set_target_window_size(wnd)?;
                this.conn.try_set_initial_window_size(wnd)?;
            }
            Poll::Ready(ping::Ponged::KeepAliveTimedOut) => {
                debug!("connection keep-alive timed out");
                return Poll::Ready(Ok(()));
            }
            Poll::Pending => {}
        }

        Pin::new(&mut this.conn).poll(cx)
    }
}

pin_project! {
    struct ConnMapErr<T, B>
    where
        B: StreamingBody,
        B: Send,
        B: 'static,
        B: Unpin,
        B::Data: Send,
        B::Data: 'static,
        B::Error: Into<BoxError>,
        T: AsyncRead,
        T: AsyncWrite,
        T: Unpin,
        T: Send,
        T: 'static,
    {
        #[pin]
        conn: Either<Conn<T, B>, Connection<T, SendBuf<<B as StreamingBody>::Data>>>,
        #[pin]
        is_terminated: bool,
    }
}

impl<T, B> Future for ConnMapErr<T, B>
where
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
    T: AsyncRead + AsyncWrite + Unpin + Send + ExtensionsRef,
{
    type Output = Result<(), ()>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let mut this = self.project();

        if *this.is_terminated {
            return Poll::Pending;
        }
        let polled = this.conn.poll(cx);
        if polled.is_ready() {
            *this.is_terminated = true;
        }
        polled.map_err(|_e| {
            // GoAway(NO_ERROR) is a clean graceful shutdown — not a real error.
            if _e.is_go_away() && _e.reason() == Some(crate::h2::Reason::NO_ERROR) {
                trace!("connection closed gracefully (GoAway NO_ERROR)");
            } else {
                debug!("connection error: {_e:?}");
            }
        })
    }
}

impl<T, B> FusedFuture for ConnMapErr<T, B>
where
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
    T: AsyncRead + AsyncWrite + Unpin + Send + ExtensionsRef + 'static,
{
    fn is_terminated(&self) -> bool {
        self.is_terminated
    }
}

pin_project! {
    pub struct ConnTask<T, B>
    where
        B: StreamingBody,
        B: Send,
        B: 'static,
        B: Unpin,
        B::Data: Send,
        B::Data: 'static,
        B::Error: Into<BoxError>,
        T: AsyncRead,
        T: AsyncWrite,
        T: Unpin,
        T: Send,
        T: 'static,
    {
        #[pin]
        drop_rx: Receiver<Infallible>,
        #[pin]
        cancel_tx: Option<oneshot::Sender<Infallible>>,
        #[pin]
        conn: ConnMapErr<T, B>,
    }
}

impl<T, B> ConnTask<T, B>
where
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
    T: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    fn new(
        conn: ConnMapErr<T, B>,
        drop_rx: Receiver<Infallible>,
        cancel_tx: oneshot::Sender<Infallible>,
    ) -> Self {
        Self {
            drop_rx,
            cancel_tx: Some(cancel_tx),
            conn,
        }
    }
}

impl<T, B> Future for ConnTask<T, B>
where
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
    T: AsyncRead + AsyncWrite + Unpin + Send + ExtensionsRef + 'static,
{
    type Output = ();

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let mut this = self.project();

        if !this.conn.is_terminated() && Pin::new(&mut this.conn).poll(cx).is_ready() {
            // ok or err, the `conn` has finished.
            return Poll::Ready(());
        }

        if !this.drop_rx.is_terminated() && Pin::new(&mut this.drop_rx).poll_next(cx).is_ready() {
            // mpsc has been dropped, hopefully polling
            // the connection some more should start shutdown
            // and then close.
            trace!("send_request dropped, starting conn shutdown");
            if let Some(cancel_tx) = this.cancel_tx.take() {
                drop(cancel_tx);
            } else {
                warn!("h2 client: ConnTask Future polled twice: cancel_tx was already None");
            }
        }

        Poll::Pending
    }
}

pin_project! {
    #[project = H2ClientFutureProject]
    pub enum H2ClientFuture<B, T>
    where
        B: StreamingBody,
        B: Send,
        B: 'static,
        B: Unpin,
        B::Data: Send,
        B::Data: 'static,
        B::Error: Into<BoxError>,
        T: AsyncRead,
        T: AsyncWrite,
        T: Unpin,
        T: Send,
        T: 'static,
    {
        Pipe {
            #[pin]
            pipe: PipeMap<B>,
        },
        Send {
            #[pin]
            send_when: SendWhen<B>,
        },
        Task {
            #[pin]
            task: ConnTask<T, B>,
        },
    }
}

impl<B, T> Future for H2ClientFuture<B, T>
where
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
    T: AsyncRead + AsyncWrite + Unpin + Send + ExtensionsRef + 'static,
{
    type Output = ();

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> std::task::Poll<Self::Output> {
        let this = self.project();

        match this {
            H2ClientFutureProject::Pipe { pipe } => pipe.poll(cx),
            H2ClientFutureProject::Send { send_when } => send_when.poll(cx),
            H2ClientFutureProject::Task { task } => task.poll(cx),
        }
    }
}

struct FutCtx<B>
where
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
{
    is_connect: bool,
    // Extended CONNECT (RFC 8441): a `:protocol` tunnel.
    extended: bool,
    eos: bool,
    fut: ResponseFuture,
    body_tx: SendStream<SendBuf<B::Data>>,
    body: B,
    allowed_trailers: Option<Arc<ForbiddenTrailers>>,
    cb: Callback<Request<B>, Response<IncomingBody>>,
}

impl<B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin> Unpin
    for FutCtx<B>
{
}

pub(crate) struct ClientTask<B, T>
where
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
    T: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    ping: ping::Recorder,
    conn_drop_ref: ConnDropRef,
    conn_eof: ConnEof,
    executor: Executor,
    h2_tx: SendRequest<SendBuf<B::Data>>,
    req_rx: ClientRx<B>,
    fut_ctx: Option<FutCtx<B>>,
    // The outcome, kept while the request queue drains.
    closing: Option<crate::Result<Dispatched>>,
    admission: AdmissionOwner,
    marker: PhantomData<T>,
}

impl<B, T> ClientTask<B, T>
where
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
    T: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    pub(crate) fn is_extended_connect_protocol_enabled(&self) -> bool {
        self.h2_tx.is_extended_connect_protocol_enabled()
    }
    pub(crate) fn current_max_send_streams(&self) -> usize {
        self.h2_tx.current_max_send_streams()
    }
    pub(crate) fn current_max_recv_streams(&self) -> usize {
        self.h2_tx.current_max_recv_streams()
    }
    pub(crate) fn peer_settings_handle(&self) -> crate::client::conn::http2::H2PeerSettingsHandle {
        crate::client::conn::http2::H2PeerSettingsHandle::from_h2_sender(&self.h2_tx)
    }

    pub(crate) fn connection_admission(&self) -> ConnectionAdmission {
        self.admission.policy()
    }
}

pin_project! {
    pub struct PipeMap<S>
    where
        S: StreamingBody,
    {
        #[pin]
        pipe: PipeToSendStream<S>,
        #[pin]
        conn_drop_ref: Option<Sender<Infallible>>,
        #[pin]
        ping: Option<Recorder>,
        cancel_rx: Option<oneshot::Receiver<()>>,
    }
}

impl<B> Future for PipeMap<B>
where
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
{
    type Output = ();

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> std::task::Poll<Self::Output> {
        let mut this = self.project();

        // Check if the client cancelled the request (e.g. dropped the
        // response future due to a timeout). If so, reset the h2 stream
        // so that a RST_STREAM is sent and flow-control capacity is freed.
        let cancel_result = this.cancel_rx.as_mut().map(|rx| Pin::new(rx).poll(cx));
        match cancel_result {
            Some(Poll::Ready(Ok(()))) => {
                debug!("client request body send cancelled, resetting stream");
                this.pipe.as_mut().send_reset(crate::h2::Reason::CANCEL);

                if let Some(conn_drop_ref) = this.conn_drop_ref.take() {
                    drop(conn_drop_ref);
                } else {
                    warn!(
                        "h2 client: CancelResult: ConnTask PipeMap polled twice: conn_drop_ref was already None"
                    );
                }

                if let Some(ping) = this.ping.take() {
                    drop(ping);
                } else {
                    warn!(
                        "h2 client: CancelResult: ConnTask PipeMap polled twice: ping was already None"
                    );
                }

                return Poll::Ready(());
            }
            Some(Poll::Ready(Err(_))) => {
                // Sender dropped without cancelling (normal response or error).
                // Stop polling the receiver.
                *this.cancel_rx = None;
            }
            Some(Poll::Pending) | None => {}
        }

        match Pin::new(&mut this.pipe).poll(cx) {
            Poll::Ready(result) => {
                if let Err(_e) = result {
                    debug!("client request body error: {_e:?}");
                }

                if let Some(conn_drop_ref) = this.conn_drop_ref.take() {
                    drop(conn_drop_ref);
                } else {
                    warn!(
                        "h2 client: ThisPipe: ConnTask PipeMap polled twice: conn_drop_ref was already None"
                    );
                }

                if let Some(ping) = this.ping.take() {
                    drop(ping);
                } else {
                    warn!(
                        "h2 client: ThisPipe: ConnTask PipeMap polled twice: ping was already None"
                    );
                }

                return Poll::Ready(());
            }
            Poll::Pending => (),
        }
        Poll::Pending
    }
}

impl<B, T> ClientTask<B, T>
where
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
    T: AsyncRead + AsyncWrite + Send + Unpin + ExtensionsRef,
{
    #[expect(clippy::needless_pass_by_ref_mut)]
    fn poll_pipe(&mut self, f: FutCtx<B>, cx: &mut Context<'_>) {
        let ping = self.ping.clone();

        // A one-shot channel so that send_task can tell pipe_task to
        // reset the stream when the client cancels the request.
        let (cancel_tx, cancel_rx) = oneshot::channel::<()>();

        let send_stream = if !f.is_connect {
            if !f.eos {
                let mut pipe = PipeToSendStream::new(f.body, f.body_tx, f.allowed_trailers);

                // eagerly see if the body pipe is ready and
                // can thus skip allocating in the executor
                match Pin::new(&mut pipe).poll(cx) {
                    Poll::Ready(_) => (),
                    Poll::Pending => {
                        let conn_drop_ref = self.conn_drop_ref.clone();
                        // keep the ping recorder's knowledge of an
                        // "open stream" alive while this body is
                        // still sending...
                        let ping = ping.clone();

                        let pipe = PipeMap {
                            pipe,
                            conn_drop_ref: Some(conn_drop_ref),
                            ping: Some(ping),
                            cancel_rx: Some(cancel_rx),
                        };

                        let pipe_span = trace_root_span!(
                            "h2::pipe",
                            otel.kind = "client",
                            network.protocol.name = "http",
                            network.protocol.version = version_as_protocol_version(Version::HTTP_2),
                        );

                        // Clear send task
                        let fut: H2ClientFuture<_, T> = H2ClientFuture::Pipe { pipe };
                        self.executor.spawn_task(fut.instrument(pipe_span));
                    }
                }
            }

            None
        } else {
            Some(f.body_tx)
        };

        let send_span = trace_root_span!(
            "h2::send",
            otel.kind = "client",
            network.protocol.name = "http",
            network.protocol.version = version_as_protocol_version(Version::HTTP_2),
        );

        let fut: H2ClientFuture<_, T> = H2ClientFuture::Send {
            send_when: SendWhen {
                when: ResponseFutMap {
                    fut: f.fut,
                    ping: Some(ping),
                    send_stream: Some(send_stream),
                    extended: f.extended,
                    exec: self.executor.clone(),
                    cancel_tx: Some(cancel_tx),
                    h2_tx: self.h2_tx.clone(),
                },
                call_back: Some(f.cb),
            },
        };
        self.executor.spawn_task(fut.instrument(send_span));
    }
}

pin_project! {
    pub(crate) struct ResponseFutMap<B>
    where
        B: StreamingBody,
        B: Send,
        B: 'static,
        B: Unpin,
        B::Data: Send,
        B::Data: 'static,
        B::Error: Into<BoxError>,
    {
        #[pin]
        fut: ResponseFuture,
        #[pin]
        ping: Option<Recorder>,
        #[pin]
        send_stream: Option<Option<SendStream<SendBuf<<B as StreamingBody>::Data>>>>,
        extended: bool,
        exec: Executor,
        cancel_tx: Option<oneshot::Sender<()>>,
        // Handle to the underlying h2 connection, kept solely so we can
        // snapshot the peer's initial SETTINGS frame at response-receipt
        // time and surface it as a `PeerH2Settings` response extension.
        h2_tx: SendRequest<SendBuf<<B as StreamingBody>::Data>>,
    }
}

impl<B> ResponseFutMap<B>
where
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
{
    /// Signal the `pipe_task` to reset the stream (e.g. on client cancellation).
    pub(crate) fn cancel(self: Pin<&mut Self>) {
        if let Some(cancel_tx) = self.project().cancel_tx.take() {
            _ = cancel_tx.send(());
        }
    }
}

impl<B> Future for ResponseFutMap<B>
where
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
{
    type Output = Result<Response<crate::body::Incoming>, (crate::Error, Option<Request<B>>)>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let mut this = self.as_mut().project();

        let result = ready!(this.fut.poll(cx));

        let Some((ping, send_stream)) = this.ping.take().zip(this.send_stream.take()) else {
            return Poll::Ready(Err((
                crate::Error::new_parse_internal()
                    .with_display("ResponseFutMap polled twice (bug: polled after ready)"),
                None::<Request<B>>,
            )));
        };

        match result {
            Ok(res) => {
                // record that we got the response headers
                ping.record_non_data();

                // Snapshot the peer's initial SETTINGS frame and attach it
                // to the response extensions. By the time HEADERS arrives
                // the peer's SETTINGS frame has already been received
                // (h2 spec requires it first), so this is reliable.
                let peer_settings = this.h2_tx.peer_initial_settings();
                if let Some(peer) = &peer_settings {
                    res.extensions().insert_arc(peer.clone());
                }

                let content_length = headers::content_length_parse_all(res.headers());
                if let (Some(send_stream), status) = (send_stream, res.status())
                    && status.is_success()
                {
                    // Successful CONNECT switches this stream to tunnel mode.
                    // RFC 9110 requires Content-Length and Transfer-Encoding
                    // to be ignored; subsequent DATA belongs to the tunnel.
                    let (parts, recv_stream) = res.into_parts();
                    let res = Response::from_parts(parts, IncomingBody::empty());

                    let (pending, on_upgrade) = upgrade::pending();

                    let h2_up =
                        super::upgrade::upgraded(send_stream, recv_stream, ping, *this.extended);
                    let upgraded = Upgraded::new(h2_up, Bytes::new());
                    // Preserve the peer's connection metadata explicitly; sharing
                    // its immutable snapshot cannot retain the handshake message.
                    if let Some(peer) = peer_settings {
                        upgraded.extensions().insert_arc(peer);
                    }

                    pending.fulfill(upgraded);
                    res.extensions().insert(on_upgrade);

                    Poll::Ready(Ok(res))
                } else {
                    let res = res.map(|stream| {
                        let ping = ping.for_stream(&stream);
                        IncomingBody::h2(stream, content_length.into(), ping)
                    });
                    Poll::Ready(Ok(res))
                }
            }
            Err(err) => {
                ping.ensure_not_timed_out().map_err(|e| (e, None))?;

                debug!("client response error: {err:?}");
                Poll::Ready(Err((crate::Error::new_h2_request(err), None::<Request<B>>)))
            }
        }
    }
}

impl<B, T> ClientTask<B, T>
where
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
    T: AsyncRead + AsyncWrite + Unpin + Send + ExtensionsRef,
{
    fn poll_dispatch(&mut self, cx: &mut Context<'_>) -> Poll<crate::Result<Dispatched>> {
        loop {
            match ready!(self.h2_tx.poll_ready(cx)) {
                Ok(()) => (),
                Err(err) => {
                    // an opened stream reports its own outcome, not the connection's
                    if let Some(f) = self.fut_ctx.take() {
                        self.poll_pipe(f, cx);
                    }
                    self.ping.ensure_not_timed_out()?;
                    return if err.reason() == Some(crate::h2::Reason::NO_ERROR) {
                        trace!("connection gracefully shutdown");
                        Poll::Ready(Ok(Dispatched::Shutdown))
                    } else {
                        Poll::Ready(Err(crate::Error::new_h2(err)))
                    };
                }
            }

            // If we were waiting on pending open
            // continue where we left off.
            if let Some(f) = self.fut_ctx.take() {
                self.poll_pipe(f, cx);
                continue;
            }

            match self.req_rx.poll_recv(cx) {
                Poll::Ready(Some((req, cb))) => {
                    // check that future hasn't been canceled already
                    if cb.is_canceled() {
                        trace!("request callback is canceled");
                        continue;
                    }
                    let checkout = self.admission.checkout(req.extensions());
                    let (head, body) = req.into_parts();
                    let mut req = Request::from_parts(head, ());
                    super::strip_connection_headers(req.headers_mut(), super::MessageKind::Request);
                    let eos = body.is_end_stream();
                    if eos {
                        headers::drop_undeliverable_content_length(req.headers_mut());
                    }
                    if let Some(len) = body.size_hint().exact()
                        && (len != 0 || headers::method_has_defined_payload_semantics(req.method()))
                    {
                        headers::set_content_length_if_missing(req.headers_mut(), len);
                    }

                    let allowed_trailers = req.extensions().get_arc::<ForbiddenTrailers>();
                    let is_connect = req.method() == Method::CONNECT;
                    let extended = is_connect && req.extensions().contains::<Protocol>();

                    if is_connect
                        && headers::content_length_parse_all(req.headers())
                            .is_some_and(|len| len != 0)
                    {
                        warn!("h2 connect request with non-zero body not supported");
                        cb.send(Err(TrySendError {
                            error: crate::Error::new_h2(crate::h2::Reason::INTERNAL_ERROR.into()),
                            message: None,
                        }));
                        continue;
                    }

                    let (fut, body_tx) = match self.h2_tx.send_request(req, !is_connect && eos) {
                        Ok(ok) => {
                            // h2 counts the stream from here until it closes.
                            if let Some(checkout) = checkout {
                                checkout.dispatched();
                            }
                            ok
                        }
                        Err(err) => {
                            debug!("client send request error: {}", err);
                            cb.send(Err(TrySendError {
                                error: crate::Error::new_h2_request(err),
                                message: None,
                            }));
                            continue;
                        }
                    };

                    let f = FutCtx {
                        is_connect,
                        extended,
                        eos,
                        fut,
                        body_tx,
                        body,
                        allowed_trailers,
                        cb,
                    };

                    // Check poll_ready() again.
                    // If the call to send_request() resulted in the new stream being pending open
                    // we have to wait for the open to complete before accepting new requests.
                    // On a connection error this opened stream still reports its own outcome.
                    if self.h2_tx.poll_ready(cx).is_pending() {
                        // Save Context
                        self.fut_ctx = Some(f);
                        return Poll::Pending;
                    }
                    self.poll_pipe(f, cx);
                }

                Poll::Ready(None) => {
                    trace!("dispatch::Sender dropped");
                    return Poll::Ready(Ok(Dispatched::Shutdown));
                }

                Poll::Pending => {
                    let Err(_conn_is_eof) = ready!(Pin::new(&mut self.conn_eof).poll(cx));
                    trace!("connection task is closed, closing dispatch task");
                    return Poll::Ready(Ok(Dispatched::Shutdown));
                }
            }
        }
    }
}

impl<B, T> Future for ClientTask<B, T>
where
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
    T: AsyncRead + AsyncWrite + Unpin + Send + ExtensionsRef,
{
    type Output = crate::Result<Dispatched>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let result = match self.closing.take() {
            Some(result) => result,
            None => ready!(self.poll_dispatch(cx)),
        };
        // A send that began before the close may still publish its request,
        // whose caller can hold a sender while awaiting the response.
        if self.req_rx.poll_close(cx).is_pending() {
            self.closing = Some(result);
            return Poll::Pending;
        }
        Poll::Ready(result)
    }
}
