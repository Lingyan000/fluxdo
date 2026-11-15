//! HTTP/2 client connections.

use std::marker::PhantomData;
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Duration;
use std::{fmt, sync::Arc};

use rama_core::error::BoxError;
use rama_core::extensions::ExtensionsRef;
use rama_core::futures::future::Either;
use rama_core::rt::Executor;
use rama_core::telemetry::tracing::{debug, trace};
use rama_http::proto::h2::frame::EarlyFrame;
use rama_http_types::proto::h2::frame::{SettingOrder, Settings, SettingsConfig};
use rama_http_types::proto::{ext::Protocol, h2::PseudoHeaderOrder};
use rama_http_types::{Request, Response, StreamingBody};
use rama_net::client::pool::ConnectionAdmission;
use tokio::io::{AsyncRead, AsyncWrite};

use crate::body::Incoming as IncomingBody;
use crate::client::dispatch::{self, TrySendError};
use crate::proto;

/// The sender side of an established connection.
pub struct SendRequest<B> {
    dispatch: dispatch::UnboundedSender<Request<B>, Response<IncomingBody>>,
    peer_settings: H2PeerSettingsHandle,
    admission: ConnectionAdmission,
}

impl<B> Clone for SendRequest<B> {
    fn clone(&self) -> Self {
        Self {
            dispatch: self.dispatch.clone(),
            peer_settings: self.peer_settings.clone(),
            admission: self.admission.clone(),
        }
    }
}

/// A future that processes all HTTP state for the IO object.
///
/// In most cases, this should just be spawned into an executor, so that it
/// can process incoming and outgoing messages, notice hangups, and the like.
///
/// Instances of this type are typically created via the [`handshake`] function.
///
/// # Drop behavior
///
/// Dropping the `Connection` will close the underlying IO resource.
/// Any in-flight requests that have not received a response will be
/// interrupted. If graceful shutdown is desired, poll the connection
/// until it completes instead of dropping.
#[must_use = "futures do nothing unless polled"]
pub struct Connection<T, B>
where
    T: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
{
    inner: (PhantomData<T>, proto::h2::ClientTask<B, T>),
}

/// A builder to configure an HTTP connection.
///
/// After setting options, the builder is used to create a handshake future.
///
/// **Note**: The default values of options are *not considered stable*. They
/// are subject to change at any time.
#[derive(Clone, Debug)]
pub struct Builder {
    pub(super) exec: Executor,
    h2_builder: proto::h2::client::Config,
    headers_pseudo_order: Option<PseudoHeaderOrder>,
    early_frames: Option<Vec<EarlyFrame>>,
}

/// Returns a handshake future over some IO.
///
/// This is a shortcut for `Builder::new(exec).handshake(io)`.
/// See [`client::conn`](crate::client::conn) for more.
///
/// # Errors
///
/// Returns an error if the HTTP/2 connection handshake fails.
pub async fn handshake<T, B>(
    exec: Executor,
    io: T,
) -> crate::Result<(SendRequest<B>, Connection<T, B>)>
where
    T: AsyncRead + AsyncWrite + Send + Unpin + ExtensionsRef + 'static,
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
{
    Builder::new(exec).handshake(io).await
}

// ===== impl SendRequest

impl<B> SendRequest<B> {
    /// Polls to determine whether this sender can be used yet for a request.
    ///
    /// If the associated connection is closed, this returns an Error.
    pub fn poll_ready(&mut self, _cx: &mut Context<'_>) -> Poll<crate::Result<()>> {
        if self.is_closed() {
            Poll::Ready(Err(crate::Error::new_closed()))
        } else {
            Poll::Ready(Ok(()))
        }
    }

    /// Waits until the dispatcher is ready.
    ///
    /// # Errors
    ///
    /// If the associated connection is closed, this returns an Error.
    pub async fn ready(&mut self) -> crate::Result<()> {
        std::future::poll_fn(|cx| self.poll_ready(cx)).await
    }

    /// Checks if the connection is currently ready to send a request.
    ///
    /// # Note
    ///
    /// This is mostly a hint. Due to inherent latency of networks, it is
    /// possible that even after checking this is ready, sending a request
    /// may still fail because the connection was closed in the meantime.
    #[must_use]
    pub fn is_ready(&self) -> bool {
        self.dispatch.is_ready()
    }

    /// Publish exact request admission for a multiplexing connection pool.
    ///
    /// A checkout reserves one of the peer's concurrent streams until its request reaches the
    /// connection; the connection then counts the stream itself until it closes, including an
    /// upgraded tunnel or an upload that outlives its response. The policy holds the connection
    /// weakly.
    #[must_use]
    pub fn connection_admission(&self) -> ConnectionAdmission {
        self.admission.clone()
    }

    /// Checks if the connection side has been closed.
    #[must_use]
    pub fn is_closed(&self) -> bool {
        self.dispatch.is_closed()
    }
}

impl<B> SendRequest<B>
where
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
{
    /// Sends a `Request` on the associated connection.
    ///
    /// Returns a future that if successful, yields the `Response`.
    ///
    /// `req` must have a `Host` header.
    ///
    /// Absolute-form `Uri`s are not required. If received, they will be serialized
    /// as-is.
    ///
    /// # Cancel safety
    ///
    /// Dropping the returned future is the supported way to cancel an
    /// in-flight HTTP/2 request. The stream is reset with `RST_STREAM`
    /// (`CANCEL` error code); the shared connection remains usable for
    /// other in-flight and future requests. The peer is notified
    /// immediately rather than continuing to send a response body that
    /// would be discarded.
    ///
    /// # Errors
    ///
    /// Returns an error if the connection is not ready or if an error occurs while
    /// processing the request.
    pub fn send_request(
        &mut self,
        req: Request<B>,
    ) -> impl Future<Output = crate::Result<Response<IncomingBody>>> {
        // RFC 8441 §3: `:protocol` is only permitted once the server sent
        // SETTINGS_ENABLE_CONNECT_PROTOCOL; wait for its SETTINGS first. This rare
        // path is boxed so ordinary request futures keep their size.
        if req.extensions().contains::<Protocol>() {
            let peer_settings = self.peer_settings.clone();
            let dispatch = self.dispatch.clone();
            return Either::Left(Box::pin(async move {
                if peer_settings.await_settings().await.is_none() {
                    return Err(
                        crate::Error::new_canceled().with("connection closed before peer SETTINGS")
                    );
                }
                response(dispatch.send(req)).await
            }));
        }
        Either::Right(response(self.dispatch.send(req)))
    }

    /// Sends a `Request` on the associated connection.
    ///
    /// Returns a future that if successful, yields the `Response`.
    ///
    /// # Errors
    ///
    /// If there was an error before trying to serialize the request to the
    /// connection, the message will be returned as part of this error.
    pub fn try_send_request(
        &mut self,
        req: Request<B>,
    ) -> impl Future<Output = Result<Response<IncomingBody>, TrySendError<Request<B>>>> {
        if req.extensions().contains::<Protocol>() {
            let peer_settings = self.peer_settings.clone();
            let mut dispatch = self.dispatch.clone();
            return Either::Left(Box::pin(async move {
                if peer_settings.await_settings().await.is_none() {
                    return Err(TrySendError {
                        error: crate::Error::new_canceled()
                            .with("connection closed before peer SETTINGS"),
                        message: Some(req),
                    });
                }
                try_response(dispatch.try_send(req)).await
            }));
        }
        Either::Right(try_response(self.dispatch.try_send(req)))
    }
}

/// Await the dispatched request's response. A request that was not sent is dropped here,
/// so the future only holds the response promise.
fn response<B>(
    sent: Result<dispatch::Promise<Response<IncomingBody>>, Request<B>>,
) -> impl Future<Output = crate::Result<Response<IncomingBody>>> {
    let sent = sent.map_err(|_req| {
        debug!("connection was not ready");
        crate::Error::new_canceled().with("connection was not ready")
    });
    async move {
        match sent?.await {
            Ok(Ok(resp)) => Ok(resp),
            Ok(Err(err)) => Err(err),
            // this is definite bug if it happens, but it shouldn't happen!
            Err(_canceled) => panic!("dispatch dropped without returning error"),
        }
    }
}

async fn try_response<B>(
    sent: Result<dispatch::RetryPromise<Request<B>, Response<IncomingBody>>, Request<B>>,
) -> Result<Response<IncomingBody>, TrySendError<Request<B>>> {
    match sent {
        Ok(rx) => match rx.await {
            Ok(Ok(res)) => Ok(res),
            Ok(Err(err)) => Err(err),
            // this is definite bug if it happens, but it shouldn't happen!
            Err(_) => panic!("dispatch dropped without returning error"),
        },
        Err(req) => {
            debug!("connection was not ready");
            let error = crate::Error::new_canceled().with("connection was not ready");
            Err(TrySendError {
                error,
                message: Some(req),
            })
        }
    }
}

impl<B> fmt::Debug for SendRequest<B> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SendRequest").finish()
    }
}

// ===== impl Connection

impl<T, B> Connection<T, B>
where
    T: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
{
    /// Returns whether the [extended CONNECT protocol][1] is enabled or not.
    ///
    /// This setting is configured by the server peer by sending the
    /// [`SETTINGS_ENABLE_CONNECT_PROTOCOL` parameter][2] in a `SETTINGS` frame.
    /// This method returns the currently acknowledged value received from the
    /// remote.
    ///
    /// [1]: https://datatracker.ietf.org/doc/html/rfc8441#section-4
    /// [2]: https://datatracker.ietf.org/doc/html/rfc8441#section-3
    pub fn is_extended_connect_protocol_enabled(&self) -> bool {
        self.inner.1.is_extended_connect_protocol_enabled()
    }

    /// Returns the current maximum send stream count.
    ///
    /// This setting is configured in a [`SETTINGS_MAX_CONCURRENT_STREAMS` parameter][1] in a `SETTINGS` frame,
    /// and may change throughout the connection lifetime.
    ///
    /// [1]: https://datatracker.ietf.org/doc/html/rfc7540#section-5.1.2
    pub fn current_max_send_streams(&self) -> usize {
        self.inner.1.current_max_send_streams()
    }

    /// Returns the current maximum receive stream count.
    ///
    /// This setting is configured in a [`SETTINGS_MAX_CONCURRENT_STREAMS` parameter][1] in a `SETTINGS` frame,
    /// and may change throughout the connection lifetime.
    ///
    /// [1]: https://datatracker.ietf.org/doc/html/rfc7540#section-5.1.2
    pub fn current_max_recv_streams(&self) -> usize {
        self.inner.1.current_max_recv_streams()
    }

    /// Returns a cloneable, type-erased handle to query the peer's
    /// initial h2 SETTINGS frame on this connection. The handle stays
    /// usable after the connection is spawned (consumed as a future),
    /// so callers can `spawn(conn)` first and then `await` the handle.
    pub fn peer_settings_handle(&self) -> H2PeerSettingsHandle {
        self.inner.1.peer_settings_handle()
    }
}

/// Cloneable handle for querying the peer's initial h2 SETTINGS frame
/// on an established connection. Obtained from
/// [`Connection::peer_settings_handle`]; survives the connection being
/// spawned so callers can `spawn(conn)` first and then `await` here.
///
/// The handle holds only an `Arc` to a small shared state cell — it
/// carries **no** reference to the request dispatcher. Retaining a
/// handle therefore does not prolong the underlying connection: once
/// the last `SendRequest` is dropped, the connection task shuts down
/// normally regardless of how many handles remain.
#[derive(Clone)]
pub struct H2PeerSettingsHandle {
    state: Arc<crate::h2::PeerSettingsState>,
}

impl fmt::Debug for H2PeerSettingsHandle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("H2PeerSettingsHandle")
            .finish_non_exhaustive()
    }
}

impl H2PeerSettingsHandle {
    /// Constructs a handle from an underlying `h2::client::SendRequest`.
    /// The handle holds an `Arc` to the connection's `PeerSettingsState`
    /// cell only — *not* a SendRequest clone — so it does not prolong
    /// the connection's lifetime.
    pub(crate) fn from_h2_sender<B>(sender: &crate::h2::client::SendRequest<B>) -> Self
    where
        B: rama_core::bytes::Buf,
    {
        Self {
            state: sender.peer_settings_state(),
        }
    }

    /// Returns the peer's initial SETTINGS frame, wrapped in
    /// [`rama_http_types::conn::PeerH2Settings`], if it has been
    /// captured. `None` while the connection is still pre-SETTINGS, or
    /// if the connection died before SETTINGS arrived.
    #[must_use]
    pub fn snapshot(&self) -> Option<Arc<rama_http_types::conn::PeerH2Settings>> {
        self.state.snapshot()
    }

    /// Resolves to the peer's initial SETTINGS once captured, or `None`
    /// if the connection terminates before SETTINGS arrives. See
    /// [`crate::h2::client::SendRequest::await_peer_initial_settings`]
    /// for the underlying semantics — including the timeout caveat for
    /// adversarial peers.
    pub async fn await_settings(&self) -> Option<Arc<rama_http_types::conn::PeerH2Settings>> {
        self.state.await_settings().await
    }
}

impl<T, B> fmt::Debug for Connection<T, B>
where
    T: AsyncRead + AsyncWrite + fmt::Debug + Send + 'static + Unpin,
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Connection").finish()
    }
}

impl<T, B> Future for Connection<T, B>
where
    T: AsyncRead + AsyncWrite + Unpin + Send + ExtensionsRef + 'static,
    B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
{
    type Output = crate::Result<()>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        match std::task::ready!(Pin::new(&mut self.inner.1).poll(cx))? {
            proto::Dispatched::Shutdown => Poll::Ready(Ok(())),
            proto::Dispatched::Upgrade(_pending) => unreachable!("http2 cannot upgrade"),
        }
    }
}

// ===== impl Builder

impl Builder {
    /// Creates a new connection builder.
    #[inline]
    #[must_use]
    pub fn new(exec: Executor) -> Self {
        Self {
            exec,
            h2_builder: proto::h2::client::Config::default(),
            headers_pseudo_order: None,
            early_frames: None,
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Replace the complete initial SETTINGS frame. None keeps the normal builder path.
        /// The handshake validates and applies its actual codec/stream settings.
        pub fn initial_settings(mut self, settings: Option<Arc<Settings>>) -> Self {
            self.h2_builder.initial_settings = settings;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Retain bounded peer SETTINGS occurrences and wire order. Disabled by default.
        pub fn observe_peer_settings(mut self, enabled: bool) -> Self {
            self.h2_builder.observe_peer_settings = enabled;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        pub fn setting_config(mut self, config: &SettingsConfig) -> Self {
            self.set_header_table_size(config.header_table_size)
                .set_max_concurrent_streams(config.max_concurrent_streams)
                .set_initial_stream_window_size(config.initial_window_size)
                .set_max_frame_size(config.max_frame_size);

            if let Some(value) = config.enable_push {
                self.set_enable_push(value != 0);
            }

            if let Some(value) = config.max_header_list_size {
                self.set_max_header_list_size(value);
            }

            if let Some(value) = config.enable_connect_protocol {
                self.set_enable_connect_protocol(value);
            }

            if let Some(value) = config.no_rfc7540_priorities {
                self.set_no_rfc7540_priorities(value);
            }

            if let Some(order) = config.setting_order.clone() {
                self.set_setting_order(order);
            }

            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets the [`SETTINGS_INITIAL_WINDOW_SIZE`][spec] option for HTTP2
        /// stream-level flow control.
        ///
        /// Passing `None` will do nothing.
        ///
        /// If not set, rama_http_core will use a default.
        ///
        /// [spec]: https://httpwg.org/specs/rfc9113.html#SETTINGS_INITIAL_WINDOW_SIZE
        pub fn initial_stream_window_size(mut self, sz: impl Into<Option<u32>>) -> Self {
            if let Some(sz) = sz.into() {
                self.h2_builder.adaptive_window = false;
                self.h2_builder.initial_stream_window_size = sz;
            }
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets the max connection-level flow control for HTTP2.
        ///
        /// If not set, rama_http_core will use a default.
        pub fn initial_connection_window_size(mut self, sz: u32) -> Self {
            self.h2_builder.adaptive_window = false;
            self.h2_builder.initial_conn_window_size = sz;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets the initial maximum of locally initiated (send) streams.
        ///
        /// This value will be overwritten by the value included in the initial
        /// SETTINGS frame received from the peer as part of a [connection preface].
        ///
        /// If not set, rama_http_core will use a default.
        ///
        /// [connection preface]: https://httpwg.org/specs/rfc9113.html#preface
        pub fn initial_max_send_streams(mut self, initial: usize) -> Self {
            self.h2_builder.initial_max_send_streams = initial;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Reset every PUSH_PROMISE with REFUSED_STREAM, so advertising push in
        /// SETTINGS never makes this client hold pushed streams. Off by default.
        pub fn refuse_push_promises(mut self, refuse: bool) -> Self {
            self.h2_builder.refuse_push_promises = refuse;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets whether to use an adaptive flow control.
        ///
        /// Enabling this will override the limits set in
        /// `initial_stream_window_size` and
        /// `initial_connection_window_size`.
        pub fn adaptive_window(mut self, enabled: bool) -> Self {
            self.h2_builder.adaptive_window = enabled;
            if enabled {
                self.h2_builder.initial_conn_window_size = proto::h2::SPEC_WINDOW_SIZE;
                self.h2_builder.initial_stream_window_size = proto::h2::SPEC_WINDOW_SIZE;
            }
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets the maximum frame size to use for HTTP2.
        ///
        /// Default is currently 16KB, but can change.
        pub fn max_frame_size(mut self, sz: impl Into<Option<u32>>) -> Self {
            self.h2_builder.max_frame_size = sz.into();
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets the max size of received header frames.
        ///
        /// Default is currently 16KB, but can change.
        pub fn max_header_list_size(mut self, max: u32) -> Self {
            self.h2_builder.max_header_list_size = max;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets the header table size.
        ///
        /// This setting informs the peer of the maximum size of the header compression
        /// table used to encode header blocks, in octets. The encoder may select any value
        /// equal to or less than the header table size specified by the sender.
        ///
        /// The default value is 4,096.
        pub fn header_table_size(mut self, size: impl Into<Option<u32>>) -> Self {
            self.h2_builder.header_table_size = size.into();
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets the maximum number of concurrent streams.
        ///
        /// The maximum concurrent streams setting only controls the maximum number
        /// of streams that can be initiated by the remote peer. In other words,
        /// when this setting is set to 100, this does not limit the number of
        /// concurrent streams that can be created by the caller.
        ///
        /// It is recommended that this value be no smaller than 100, so as to not
        /// unnecessarily limit parallelism. However, any value is legal, including
        /// 0. If `max` is set to 0, then the remote will not be permitted to
        /// initiate streams.
        ///
        /// Note that streams in the reserved state, i.e., push promises that have
        /// been reserved but the stream has not started, do not count against this
        /// setting.
        ///
        /// Also note that if the remote *does* exceed the value set here, it is not
        /// a protocol level error. Instead, the `h2` code will immediately reset
        /// the stream.
        ///
        /// See [Section 5.1.2] in the HTTP/2 spec for more details.
        ///
        /// [Section 5.1.2]: https://httpwg.org/specs/rfc7540.html#rfc.section.5.1.2
        pub fn max_concurrent_streams(mut self, max: impl Into<Option<u32>>) -> Self {
            self.h2_builder.max_concurrent_streams = max.into();
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets an interval for HTTP2 Ping frames should be sent to keep a
        /// connection alive.
        ///
        /// Pass `None` to disable HTTP2 keep-alive.
        ///
        /// Default is currently disabled.
        pub fn keep_alive_interval(mut self, interval: impl Into<Option<Duration>>) -> Self {
            self.h2_builder.keep_alive_interval = interval.into();
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets a timeout for receiving an acknowledgement of the keep-alive ping.
        ///
        /// If the ping is not acknowledged within the timeout, the connection will
        /// be closed. Does nothing if `keep_alive_interval` is disabled.
        ///
        /// Default is 20 seconds.
        pub fn keep_alive_timeout(mut self, timeout: Duration) -> Self {
            self.h2_builder.keep_alive_timeout = timeout;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets whether HTTP2 keep-alive should apply while the connection is idle.
        ///
        /// If disabled, keep-alive pings are only sent while there are open
        /// request/responses streams. If enabled, pings are also sent when no
        /// streams are active. Does nothing if `keep_alive_interval` is
        /// disabled.
        ///
        /// Default is `false`.
        pub fn keep_alive_while_idle(mut self, enabled: bool) -> Self {
            self.h2_builder.keep_alive_while_idle = enabled;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets the maximum number of HTTP2 concurrent locally reset streams.
        ///
        /// See the documentation of [`crate::h2::client::Builder::with_max_concurrent_reset_streams`] for more
        /// details.
        ///
        /// The default value is determined by the `h2` code.
        pub fn max_concurrent_reset_streams(mut self, max: usize) -> Self {
            self.h2_builder.max_concurrent_reset_streams = Some(max);
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set the maximum write buffer size for each HTTP/2 stream.
        ///
        /// Default is currently 1MB, but may change.
        pub fn max_send_buf_size(mut self, max: u32) -> Self {
            self.h2_builder.max_send_buffer_size = max;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Configures the maximum number of pending reset streams allowed before a GOAWAY will be sent.
        ///
        /// This will default to the default value set by the `h2` module. For now this is `20`.
        pub fn max_pending_accept_reset_streams(mut self, max: impl Into<Option<usize>>) -> Self {
            self.h2_builder.max_pending_accept_reset_streams = max.into();
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        pub fn enable_push(mut self, enable: bool) -> Self {
            self.h2_builder.enable_push = enable;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        pub fn enable_connect_protocol(mut self, value: u32) -> Self {
            self.h2_builder.enable_connect_protocol = Some(value);
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        pub fn no_rfc7540_priorities(mut self, value: u32) -> Self {
            self.h2_builder.no_rfc7540_priorities = Some(value);
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        pub fn setting_order(mut self, order: SettingOrder) -> Self {
            self.h2_builder.setting_order = Some(order);
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        pub fn headers_pseudo_order(mut self, order: PseudoHeaderOrder) -> Self {
            self.headers_pseudo_order = Some(order);
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        pub fn early_frames(mut self, frames: Vec<EarlyFrame>) -> Self {
            self.early_frames = Some(frames);
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Configures the maximum number of local resets due to protocol errors made by the remote end.
        ///
        /// See the documentation of [`crate::h2::client::Builder::with_max_local_error_reset_streams`] for more
        /// details.
        ///
        /// The default value is 1024.
        pub fn max_local_error_reset_streams(mut self, max: impl Into<Option<usize>>) -> Self {
            self.h2_builder.max_local_error_reset_streams = max.into();
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Configures the connection-level budget for the memory overhead of
        /// received small DATA frames, exhausting it closes the connection.
        ///
        /// See the documentation of [`crate::h2::client::Builder::with_data_frame_budget`] for more
        /// details.
        ///
        /// The default, `None`, is half the target connection window, at least 25,600 bytes.
        pub fn data_frame_budget(mut self, budget: impl Into<Option<usize>>) -> Self {
            self.h2_builder.data_frame_budget = budget.into();
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets the duration to remember locally reset streams.
        ///
        /// When a stream is explicitly reset by either the client or the server,
        /// the HTTP/2 specification requires that any further frames received for
        /// that stream must be ignored for "some time".
        ///
        /// In order to satisfy the specification, internal state must be maintained
        /// to implement the behavior. This state grows linearly with the number of
        /// streams that are locally reset.
        ///
        /// The `reset_stream_duration` setting configures the max amount of time
        /// this state will be maintained in memory. Once the duration elapses, the
        /// stream state is purged from memory.
        ///
        /// Once the stream has been fully purged from memory, any additional frames
        /// received for that stream will result in a connection level protocol
        /// error, forcing the connection to terminate.
        ///
        /// The default value is determined by the `h2` crate, and is currently
        /// 1 second.
        ///
        /// See the documentation of [`h2::client::Builder::reset_stream_duration`] for more
        /// details.
        ///
        /// [`h2::client::Builder::reset_stream_duration`]: https://docs.rs/h2/client/struct.Builder.html#method.reset_stream_duration
        pub fn reset_stream_duration(mut self, dur: Duration) -> Self {
            self.h2_builder.reset_stream_duration = Some(dur);
            self
        }
    }

    /// Constructs a connection with the configured options and IO.
    /// See [`client::conn`](crate::client::conn) for more.
    ///
    /// Note, if [`Connection`] is not `await`-ed, [`SendRequest`] will
    /// do nothing.
    ///
    /// # Errors
    ///
    /// Returns an error if the HTTP/2 connection handshake fails.
    pub fn handshake<T, B>(
        &self,
        io: T,
    ) -> impl Future<Output = crate::Result<(SendRequest<B>, Connection<T, B>)>>
    where
        T: AsyncRead + AsyncWrite + Send + Unpin + ExtensionsRef + 'static,
        B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
    {
        let opts = self.clone();

        async move {
            trace!("client handshake HTTP/2");

            let mut client_builder = proto::h2::client::new_builder(&self.h2_builder);
            if let Some(order) = self.headers_pseudo_order.clone() {
                client_builder.set_headers_pseudo_order(order);
            }
            if let Some(frames) = self.early_frames.clone() {
                client_builder.set_early_frames(frames);
            }

            let (tx, rx) = dispatch::channel();

            let h2 = proto::h2::client::handshake_with_builder(
                client_builder,
                io,
                rx,
                &opts.h2_builder,
                opts.exec,
            )
            .await?;

            Ok((
                SendRequest {
                    dispatch: tx.unbound(),
                    peer_settings: h2.peer_settings_handle(),
                    admission: h2.connection_admission(),
                },
                Connection {
                    inner: (PhantomData, h2),
                },
            ))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Builder, Connection, SendRequest};
    use crate::{
        client::dispatch,
        h2::{Error as H2Error, server as h2_server},
        proto, server,
        service::RamaHttpService,
    };
    use rama_core::{
        ServiceInput,
        bytes::Bytes,
        extensions::{Extensions, ExtensionsRef},
        futures::{StreamExt as _, stream},
        rt::Executor,
        service::service_fn,
    };
    use rama_http_types::{
        Body, Method, Request, Response, StatusCode,
        body::util::{BodyExt as _, Empty},
        header::CONTENT_LENGTH,
        proto::ext::Protocol,
    };
    use std::{
        convert::Infallible,
        error::Error,
        future::poll_fn,
        marker::PhantomData,
        pin::pin,
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        },
        task::{Context, Waker},
        time::Duration,
    };
    use tokio::{
        io::{AsyncRead, AsyncWrite},
        time::timeout,
    };

    /// On the last client stream id, readiness fails right after that
    /// stream opened: the opened request must still get its own outcome.
    #[tokio::test]
    async fn opened_stream_outlives_readiness_error_after_open() {
        let (client_io, origin_io) = tokio::io::duplex(64 * 1024);
        tokio::spawn(async move {
            let mut origin = h2_server::handshake(ServiceInput::new(origin_io))
                .await
                .unwrap();
            let (req, mut respond) = origin.accept().await.unwrap().unwrap();
            assert_eq!(req.method(), Method::POST);
            let mut body = respond.send_response(Response::new(()), false).unwrap();
            body.send_data(Bytes::from_static(b"ok"), true).unwrap();
            _ = poll_fn(|cx| origin.poll_closed(cx)).await;
        });

        let opts = Builder::new(Executor::default());
        let builder = proto::h2::client::new_builder(&opts.h2_builder)
            .try_with_initial_stream_id(u32::MAX >> 1)
            .unwrap();
        let (tx, rx) = dispatch::channel();
        let task = proto::h2::client::handshake_with_builder(
            builder,
            ServiceInput::new(client_io),
            rx,
            &opts.h2_builder,
            opts.exec,
        )
        .await
        .unwrap();
        let mut client = SendRequest {
            dispatch: tx.unbound(),
            peer_settings: task.peer_settings_handle(),
            admission: task.connection_admission(),
        };
        tokio::spawn(Connection::<_, Body> {
            inner: (PhantomData, task),
        });

        let req = Request::post("https://example.test/")
            .body(Body::from("a=1"))
            .unwrap();
        let resp = timeout(Duration::from_secs(1), client.send_request(req))
            .await
            .unwrap()
            .expect("opened request gets its own response");
        assert_eq!(resp.status(), StatusCode::OK);
        let body = resp.into_body().collect().await.unwrap().to_bytes();
        assert_eq!(body, "ok");
    }

    #[tokio::test]
    #[ignore = "only compilation is checked"]
    async fn send_sync_executor_of_send_futures() {
        #[expect(unused)]
        async fn run(io: impl AsyncRead + AsyncWrite + Send + Unpin + ExtensionsRef + 'static) {
            let (_sender, conn) = crate::client::conn::http2::handshake::<
                _,
                Empty<rama_core::bytes::Bytes>,
            >(Executor::default(), io)
            .await
            .unwrap();

            tokio::task::spawn(async move {
                conn.await.unwrap();
            });
        }
    }

    /// Ordinary requests keep a small future: the Extended CONNECT wait is boxed, and a
    /// request that was not sent is not kept in it.
    #[tokio::test]
    async fn ordinary_request_futures_stay_small() {
        let (client_io, _server_io) = tokio::io::duplex(1024);
        let (mut sender, _connection) = crate::client::conn::http2::handshake::<_, Body>(
            Executor::default(),
            ServiceInput::new(client_io),
        )
        .await
        .unwrap();
        let send = size_of_val(&sender.send_request(Request::new(Body::empty())));
        // Measured 56 bytes; the base's future held the whole request (224).
        assert!(send <= 64, "{send}");
    }

    /// A connection to a server allowing one concurrent stream, once its SETTINGS have arrived.
    async fn one_stream_connection<S>(
        stream_window: u32,
        service: S,
    ) -> (
        crate::client::conn::http2::SendRequest<Body>,
        tokio::task::JoinHandle<crate::Result<()>>,
    )
    where
        S: rama_core::Service<Request, Output = Response, Error = Infallible> + Clone,
    {
        let (client_io, server_io) = tokio::io::duplex(1 << 20);
        let (mut sender, connection) = crate::client::conn::http2::handshake::<_, Body>(
            Executor::default(),
            ServiceInput::new(client_io),
        )
        .await
        .unwrap();
        let task = tokio::spawn(connection);
        let mut builder = server::conn::http2::Builder::new(Executor::default());
        builder.set_max_concurrent_streams(1);
        builder.set_initial_stream_window_size(stream_window);
        tokio::spawn(
            builder.serve_connection(ServiceInput::new(server_io), RamaHttpService::new(service)),
        );
        // One exchange, so the peer's stream limit is known.
        let warmup = Request::builder()
            .uri("https://example.com/")
            .body(Body::empty())
            .unwrap();
        let response = sender.send_request(warmup).await.unwrap();
        drop(response.into_body().collect().await.unwrap());
        (sender, task)
    }

    /// An empty body never announces a length it cannot deliver; the peer would reject it.
    #[tokio::test]
    async fn an_empty_body_drops_a_positive_content_length() {
        let service = service_fn(|request: Request| {
            let answer = request
                .headers()
                .get(CONTENT_LENGTH)
                .map_or_else(Bytes::new, |length| {
                    Bytes::copy_from_slice(length.as_bytes())
                });
            std::future::ready(Ok::<_, Infallible>(Response::new(Body::from(answer))))
        });
        let (mut sender, _task) = one_stream_connection(65_535, service).await;
        // As an empty body without a length: `0` where the method defines a payload.
        for (method, sent) in [(Method::POST, "0"), (Method::GET, "")] {
            let request = Request::builder()
                .method(method)
                .uri("https://example.com/")
                .header(CONTENT_LENGTH, "5")
                .body(Body::empty())
                .unwrap();
            let response = sender.send_request(request).await.unwrap();
            let body = response.into_body().collect().await.unwrap().to_bytes();
            assert_eq!(body, sent);
        }
    }

    fn answer_at_once()
    -> impl rama_core::Service<Request, Output = Response, Error = Infallible> + Clone {
        service_fn(|request: Request| {
            // Answer at once, and keep reading the upload.
            tokio::spawn(async move {
                _ = request.into_body().collect().await;
            });
            std::future::ready(Ok::<_, Infallible>(Response::new(Body::empty())))
        })
    }

    /// An upload that sends one chunk, then ends only when the returned sender is dropped.
    fn open_upload() -> (tokio::sync::oneshot::Sender<()>, Request<Body>) {
        let (finish, finished) = tokio::sync::oneshot::channel::<()>();
        let body = stream::once(async { Ok::<_, Infallible>(Bytes::from_static(b"part")) }).chain(
            stream::once(async move {
                _ = finished.await;
            })
            .filter_map(|()| async { None }),
        );
        let upload = Request::builder()
            .method(Method::POST)
            .uri("https://example.com/upload")
            .body(Body::from_stream(body))
            .unwrap();
        (finish, upload)
    }

    fn admits(sender: &crate::client::conn::http2::SendRequest<Body>) -> bool {
        sender
            .connection_admission()
            .try_acquire(&Extensions::new())
            .unwrap()
            .is_some()
    }

    /// Wait until a stream retires and the connection admits again.
    async fn admits_again(sender: &crate::client::conn::http2::SendRequest<Body>) {
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let changed = sender.connection_admission().changed();
                if admits(sender) {
                    return;
                }
                changed.await;
            }
        })
        .await
        .unwrap();
    }

    /// A stream counts until h2 retires it: an upload still buffered behind flow control keeps
    /// its slot after its response (RFC 9113 §5.1.2).
    #[tokio::test]
    async fn an_upload_buffered_behind_flow_control_keeps_its_slot() {
        // The server answers at once and never reads the upload.
        let held = Arc::new(parking_lot::Mutex::new(Vec::new()));
        let service = {
            let held = held.clone();
            service_fn(move |request: Request| {
                if request.method() == Method::POST {
                    held.lock().push(request.into_body());
                }
                std::future::ready(Ok::<_, Infallible>(Response::new(Body::empty())))
            })
        };
        let (sender, _task) = one_stream_connection(1, service).await;
        assert!(admits(&sender));
        for (len, buffered) in [(1, false), (65_536, true)] {
            let upload = Request::builder()
                .method(Method::POST)
                .uri("https://example.com/upload")
                .body(Body::from(vec![0; len]))
                .unwrap();
            let response = sender.clone().send_request(upload).await.unwrap();
            drop(response.into_body().collect().await.unwrap());
            if buffered {
                // No reader ever opens the one-byte window: the stream stays open.
                tokio::time::sleep(Duration::from_millis(50)).await;
                assert!(!admits(&sender), "{len}");
            } else {
                admits_again(&sender).await;
            }
        }
        // Releasing the unread upload resets its stream, which frees the slot.
        held.lock().clear();
        admits_again(&sender).await;
    }

    /// Requests sent directly, without a pool checkout, count like any other stream.
    #[tokio::test]
    async fn requests_without_a_checkout_are_counted() {
        let (sender, _task) = one_stream_connection(65_535, answer_at_once()).await;
        let (finish, upload) = open_upload();
        let response = sender.clone().send_request(upload).await.unwrap();
        drop(response.into_body().collect().await.unwrap());
        // The upload is still open.
        assert!(!admits(&sender));
        drop(finish);
        admits_again(&sender).await;
    }

    /// A checkout only counts on the connection it was made on.
    #[tokio::test]
    async fn a_checkout_sent_on_another_connection_is_not_spent() {
        let (first, _first_task) = one_stream_connection(65_535, answer_at_once()).await;
        let (second, _second_task) = one_stream_connection(65_535, answer_at_once()).await;
        let checkout = first
            .connection_admission()
            .try_acquire(&Extensions::new())
            .unwrap()
            .unwrap();
        let mut extensions = Extensions::new();
        checkout.bind(&mut extensions);
        let request = Request::builder_with_extensions(extensions)
            .uri("https://example.com/")
            .body(Body::empty())
            .unwrap();
        let response = second.clone().send_request(request).await.unwrap();
        drop(response.into_body().collect().await.unwrap());
        admits_again(&second).await;
        // Still reserved on the first connection.
        assert!(!admits(&first));
        drop(checkout);
        assert!(admits(&first));
    }

    /// Once the connection task ends, nothing more is admitted, even while a stream lives on.
    #[tokio::test]
    async fn an_ended_connection_task_admits_nothing() {
        let (sender, task) = one_stream_connection(65_535, answer_at_once()).await;
        let (_finish, upload) = open_upload();
        let response = sender.clone().send_request(upload).await.unwrap();
        drop(response.into_body().collect().await.unwrap());
        task.abort();
        _ = task.await;
        sender
            .connection_admission()
            .try_acquire(&Extensions::new())
            .unwrap_err();
    }

    /// An unused checkout gives its slot back; a used one hands it to its stream.
    #[tokio::test]
    async fn checkouts_hold_a_slot_until_dispatched_or_dropped() {
        let service = service_fn(|_: Request| {
            std::future::ready(Ok::<_, Infallible>(Response::new(Body::empty())))
        });
        let (sender, _task) = one_stream_connection(65_535, service).await;
        let admission = sender.connection_admission();
        let unused = admission.try_acquire(&Extensions::new()).unwrap().unwrap();
        assert!(!admits(&sender));
        drop(unused);
        assert!(admits(&sender));

        let used = admission.try_acquire(&Extensions::new()).unwrap().unwrap();
        let mut extensions = Extensions::new();
        used.bind(&mut extensions);
        let request = Request::builder_with_extensions(extensions)
            .uri("https://example.com/")
            .body(Body::empty())
            .unwrap();
        let response = sender.clone().send_request(request).await.unwrap();
        // Dispatched: the checkout is spent even while its handout lives on.
        drop(response.into_body().collect().await.unwrap());
        admits_again(&sender).await;
        drop(used);
        assert!(admits(&sender));
    }

    /// Subscribers wake as the connection ends; after that nothing signals any more, so
    /// pool waiters cannot spin on it.
    #[tokio::test]
    async fn an_ended_connection_stays_quiet() {
        let (sender, task) = one_stream_connection(65_535, answer_at_once()).await;
        let admission = sender.connection_admission();
        let before = admission.changed();
        task.abort();
        _ = task.await;
        tokio::time::timeout(Duration::from_secs(5), before)
            .await
            .expect("subscribers wake as the connection ends");
        let mut after = pin!(admission.changed());
        let cx = &mut Context::from_waker(Waker::noop());
        assert!(after.as_mut().poll(cx).is_pending());
        tokio::task::yield_now().await;
        assert!(after.as_mut().poll(cx).is_pending());
    }

    /// Handing a checkout's request to h2 frees nothing on a saturated connection, so no
    /// waiter is woken; the stream's retirement does wake them.
    #[tokio::test]
    async fn dispatching_on_a_saturated_connection_wakes_nobody() {
        let (release, upload) = open_upload();
        let (sender, _task) = one_stream_connection(65_535, answer_at_once()).await;
        let admission = sender.connection_admission();
        // An unused checkout returns its slot, which wakes waiters.
        let unused = admission.try_acquire(&Extensions::new()).unwrap().unwrap();
        let mut changed = pin!(admission.changed());
        let cx = &mut Context::from_waker(Waker::noop());
        assert!(changed.as_mut().poll(cx).is_pending());
        drop(unused);
        assert!(changed.as_mut().poll(cx).is_ready());

        let checkout = admission.try_acquire(&Extensions::new()).unwrap().unwrap();
        let mut extensions = Extensions::new();
        checkout.bind(&mut extensions);
        let request = Request::builder_with_extensions(extensions)
            .method(Method::POST)
            .uri("https://example.com/upload")
            .body(upload.into_body())
            .unwrap();
        let mut changed = pin!(admission.changed());
        assert!(changed.as_mut().poll(cx).is_pending());
        let response = sender.clone().send_request(request).await.unwrap();
        drop(checkout);
        assert!(
            changed.as_mut().poll(cx).is_pending(),
            "a dispatch woke waiters"
        );
        assert!(!admits(&sender));

        drop(release);
        drop(response.into_body().collect().await.unwrap());
        tokio::time::timeout(Duration::from_secs(5), changed)
            .await
            .expect("the retired stream wakes waiters");
    }

    /// RFC 8441 §4: a `:protocol` on another method fails locally, as on HTTP/3, even with the
    /// server's setting, and leaves the connection usable.
    #[tokio::test]
    async fn protocol_on_other_methods_fails_locally() {
        let (client_io, server_io) = tokio::io::duplex(65536);
        let served = Arc::new(AtomicUsize::new(0));
        let service = {
            let served = served.clone();
            service_fn(move |_request: Request| {
                served.fetch_add(1, Ordering::Relaxed);
                std::future::ready(Ok::<_, Infallible>(Response::new(Body::empty())))
            })
        };
        let (mut sender, connection) = crate::client::conn::http2::handshake::<_, Body>(
            Executor::default(),
            ServiceInput::new(client_io),
        )
        .await
        .unwrap();
        tokio::spawn(connection);
        let mut builder = server::conn::http2::Builder::new(Executor::default());
        builder.set_enable_connect_protocol();
        tokio::spawn(
            builder.serve_connection(ServiceInput::new(server_io), RamaHttpService::new(service)),
        );
        let request = Request::builder()
            .uri("https://example.com/chat")
            .body(Body::empty())
            .unwrap();
        request.extensions().insert(Protocol::WEBSOCKET);
        let error = sender.send_request(request).await.unwrap_err();
        let h2 = Error::source(&error)
            .and_then(|source| source.downcast_ref::<H2Error>())
            .expect("h2 error");
        assert_eq!(h2.to_string(), "user error: malformed headers");
        let request = Request::builder()
            .uri("https://example.com/")
            .body(Body::empty())
            .unwrap();
        sender.send_request(request).await.unwrap();
        assert_eq!(served.load(Ordering::Relaxed), 1);
    }

    /// RFC 8441 §3: `:protocol` is only sent after the server enabled it, even when the
    /// request is issued before the server's SETTINGS arrive.
    #[tokio::test]
    async fn extended_connect_waits_for_and_requires_server_setting() {
        for enabled in [false, true] {
            let (client_io, server_io) = tokio::io::duplex(65536);
            let served = Arc::new(AtomicUsize::new(0));
            let service = {
                let served = served.clone();
                service_fn(move |_request: Request| {
                    served.fetch_add(1, Ordering::Relaxed);
                    std::future::ready(Ok::<_, Infallible>(Response::new(Body::empty())))
                })
            };
            let (mut sender, connection) = crate::client::conn::http2::handshake::<_, Body>(
                Executor::default(),
                ServiceInput::new(client_io),
            )
            .await
            .unwrap();
            tokio::spawn(connection);
            let request = Request::builder()
                .method(Method::CONNECT)
                .uri("https://example.com/chat")
                .body(Body::empty())
                .unwrap();
            request.extensions().insert(Protocol::WEBSOCKET);
            // Issued before the server has written its SETTINGS.
            let response = tokio::spawn(async move { sender.send_request(request).await });
            tokio::task::yield_now().await;
            let mut builder = server::conn::http2::Builder::new(Executor::default());
            if enabled {
                builder.set_enable_connect_protocol();
            }
            tokio::spawn(
                builder
                    .serve_connection(ServiceInput::new(server_io), RamaHttpService::new(service)),
            );
            let result = tokio::time::timeout(Duration::from_secs(10), response)
                .await
                .unwrap()
                .unwrap();
            match result {
                Ok(_) => assert!(enabled),
                // Refused locally: a server-side reset would also leave the service unserved.
                Err(error) => {
                    assert!(!enabled, "{error:?}");
                    let h2 = Error::source(&error)
                        .and_then(|source| source.downcast_ref::<H2Error>())
                        .expect("h2 error");
                    assert_eq!(
                        h2.to_string(),
                        "user error: peer did not enable extended CONNECT"
                    );
                }
            }
            assert_eq!(served.load(Ordering::Relaxed), usize::from(enabled));
        }
    }
}
