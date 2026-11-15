//! Client implementation of the HTTP/2 protocol.
//!
//! # Getting started
//!
//! Running an HTTP/2 client requires the caller to establish the underlying
//! connection as well as get the connection to a state that is ready to begin
//! the HTTP/2 handshake. See [here](../index.html#handshake) for more
//! details.
//!
//! This could be as basic as using Tokio's [`TcpStream`] to connect to a remote
//! host, but usually it means using either ALPN or HTTP/1.1 protocol upgrades.
//!
//! Once a connection is obtained, it is passed to [`handshake`], which will
//! begin the [HTTP/2 handshake]. This returns a future that completes once
//! the handshake process is performed and HTTP/2 streams may be initialized.
//!
//! [`handshake`] uses default configuration values. There are a number of
//! settings that can be changed by using [`Builder`] instead.
//!
//! Once the handshake future completes, the caller is provided with a
//! [`Connection`] instance and a [`SendRequest`] instance. The [`Connection`]
//! instance is used to drive the connection (see [Managing the connection]).
//! The [`SendRequest`] instance is used to initialize new streams (see [Making
//! requests]).
//!
//! # Making requests
//!
//! Requests are made using the [`SendRequest`] handle provided by the handshake
//! future. Once a request is submitted, an HTTP/2 stream is initialized and
//! the request is sent to the server.
//!
//! A request body and request trailers are sent using [`SendRequest`] and the
//! server's response is returned once the [`ResponseFuture`] future completes.
//! Both the [`SendStream`] and [`ResponseFuture`] instances are returned by
//! [`SendRequest::send_request`] and are tied to the HTTP/2 stream
//! initialized by the sent request.
//!
//! The [`SendRequest::poll_ready`] function returns `Ready` when a new HTTP/2
//! stream can be created, i.e. as long as the current number of active streams
//! is below [`MAX_CONCURRENT_STREAMS`]. If a new stream cannot be created, the
//! caller will be notified once an existing stream closes, freeing capacity for
//! the caller.  The caller should use [`SendRequest::poll_ready`] to check for
//! capacity before sending a request to the server.
//!
//! [`SendRequest`] enforces the [`MAX_CONCURRENT_STREAMS`] setting. The user
//! must not send a request if `poll_ready` does not return `Ready`. Attempting
//! to do so will result in an [`Error`] being returned.
//!
//! # Managing the connection
//!
//! The [`Connection`] instance is used to manage connection state. The caller
//! is required to call [`Connection::poll`] in order to advance state.
//! [`SendRequest::send_request`] and other functions have no effect unless
//! [`Connection::poll`] is called.
//!
//! The [`Connection`] instance should only be dropped once [`Connection::poll`]
//! returns `Ready`. At this point, the underlying socket has been closed and no
//! further work needs to be done.
//!
//! The easiest way to ensure that the [`Connection`] instance gets polled is to
//! submit the [`Connection`] instance to an [executor]. The executor will then
//! manage polling the connection until the connection is complete.
//! Alternatively, the caller can call `poll` manually.
//!
//! # Example
//!
//! ```rust, no_run
//!
//! use rama_core::ServiceInput;
//! use rama_http_core::h2::client;
//! use rama_http_types::{Request, Method};
//! use std::error::Error;
//! use tokio::net::TcpStream;
//!
//! #[tokio::main]
//! pub async fn main() -> Result<(), Box<dyn Error>> {
//!     // Establish TCP connection to the server.
//!     let tcp = TcpStream::connect("127.0.0.1:5928").await?;
//!     // Convert to a rama compatible tcp stream
//!     let tcp = ServiceInput::new(tcp);
//!     let (h2, connection) = client::handshake(tcp).await?;
//!     tokio::spawn(async move {
//!         connection.await.unwrap();
//!     });
//!
//!     let mut h2 = h2.ready().await?;
//!     // Prepare the HTTP request to send to the server.
//!     let request = Request::builder()
//!                     .method(Method::GET)
//!                     .uri("https://www.example.com/")
//!                     .body(())
//!                     .unwrap();
//!
//!     // Send the request. The second tuple item allows the caller
//!     // to stream a request body.
//!     let (response, _) = h2.send_request(request, true).unwrap();
//!
//!     let (head, mut body) = response.await?.into_parts();
//!
//!     println!("Received response: {:?}", head);
//!
//!     // The `flow_control` handle allows the caller to manage
//!     // flow control.
//!     //
//!     // Whenever data is received, the caller is responsible for
//!     // releasing capacity back to the server once it has freed
//!     // the data from memory.
//!     let mut flow_control = body.flow_control().clone();
//!
//!     while let Some(chunk) = body.data().await {
//!         let chunk = chunk?;
//!         println!("RX: {:?}", chunk);
//!
//!         // Let the server send more data.
//!         _ = flow_control.release_capacity(chunk.len());
//!     }
//!
//!     Ok(())
//! }
//! ```
//!
//! [`TcpStream`]: https://docs.rs/tokio-core/0.1/tokio_core/net/struct.TcpStream.html
//! [`handshake`]: fn.handshake.html
//! [executor]: https://docs.rs/futures/0.1/futures/future/trait.Executor.html
//! [`SendRequest`]: struct.SendRequest.html
//! [`SendStream`]: ../struct.SendStream.html
//! [Making requests]: #making-requests
//! [Managing the connection]: #managing-the-connection
//! [`Connection`]: struct.Connection.html
//! [`Connection::poll`]: struct.Connection.html#method.poll
//! [`SendRequest::send_request`]: struct.SendRequest.html#method.send_request
//! [`MAX_CONCURRENT_STREAMS`]: http://httpwg.org/specs/rfc7540.html#SettingValues
//! [`SendRequest`]: struct.SendRequest.html
//! [`ResponseFuture`]: struct.ResponseFuture.html
//! [`SendRequest::poll_ready`]: struct.SendRequest.html#method.poll_ready
//! [HTTP/2 handshake]: http://httpwg.org/specs/rfc7540.html#ConnectionHeader
//! [`Builder`]: struct.Builder.html
//! [`Error`]: ../struct.Error.html

use crate::h2::codec::{Codec, SendError, UserError};
use crate::h2::proto::{self, Error};
use crate::h2::{FlowControl, PingPong, RecvStream, SendStream};
use crate::proto::target::{OutgoingHost, host_is_wire_authority, outgoing_host};
use rama_core::bytes::{Buf, Bytes};
use rama_core::error::{BoxError, BoxErrorExt};
use rama_core::extensions::{Extensions, ExtensionsRef};
use rama_core::telemetry::tracing::{self, Instrument, debug, warn};
use rama_http::proto::HeaderByteLength;
use rama_http::proto::h2::frame::{EarlyFrame, EarlyFrameStreamContext};
use rama_http_types::conn::H2SettingsLimits;
use rama_http_types::proto::ext::Protocol;
use rama_http_types::proto::h2::frame::StreamDependency;
use rama_http_types::proto::h2::frame::{Headers, Pseudo, Reason, Settings, StreamId};
use rama_http_types::proto::h2::frame::{SettingOrder, SettingsConfig};
use rama_http_types::proto::h2::hpack::BytesStr;
use rama_http_types::proto::h2::{PseudoHeader, PseudoHeaderOrder, PseudoHeaderSensitivity};
use rama_http_types::request;
use rama_http_types::{HeaderMap, Method, Request, Response, Version};
use rama_net::address::AuthorityRef;
use rama_net::extensions::StreamTransformed;
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Duration;
use std::{fmt, sync::Arc};
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};

/// Initializes new HTTP/2 streams on a connection by sending a request.
///
/// This type does no work itself. Instead, it is a handle to the inner
/// connection state held by [`Connection`]. If the associated connection
/// instance is dropped, all `SendRequest` functions will return [`Error`].
///
/// [`SendRequest`] instances are able to move to and operate on separate tasks
/// / threads than their associated [`Connection`] instance. Internally, there
/// is a buffer used to stage requests before they get written to the
/// connection. There is no guarantee that requests get written to the
/// connection in FIFO order as HTTP/2 prioritization logic can play a role.
///
/// [`SendRequest`] implements [`Clone`], enabling the creation of many
/// instances that are backed by a single connection.
///
/// See [module] level documentation for more details.
///
/// [module]: index.html
/// [`Connection`]: struct.Connection.html
/// [`Clone`]: https://doc.rust-lang.org/std/clone/trait.Clone.html
/// [`Error`]: ../struct.Error.html
pub struct SendRequest<B: Buf> {
    inner: proto::Streams<B, Peer>,
    pending: Option<proto::OpaqueStreamRef>,
}

/// Returns a `SendRequest` instance once it is ready to send at least one
/// request.
#[derive(Debug)]
pub struct ReadySendRequest<B: Buf> {
    inner: Option<SendRequest<B>>,
}

/// Manages all state associated with an HTTP/2 client connection.
///
/// A `Connection` is backed by an I/O resource (usually a TCP socket) and
/// implements the HTTP/2 client logic for that connection. It is responsible
/// for driving the internal state forward, performing the work requested of the
/// associated handles ([`SendRequest`], [`ResponseFuture`], [`SendStream`],
/// [`RecvStream`]).
///
/// `Connection` values are created by calling [`handshake`]. Once a
/// `Connection` value is obtained, the caller must repeatedly call [`poll`]
/// until `Ready` is returned. The easiest way to do this is to submit the
/// `Connection` instance to an [executor].
///
/// [module]: index.html
/// [`handshake`]: fn.handshake.html
/// [`SendRequest`]: struct.SendRequest.html
/// [`ResponseFuture`]: struct.ResponseFuture.html
/// [`SendStream`]: ../struct.SendStream.html
/// [`RecvStream`]: ../struct.RecvStream.html
/// [`poll`]: #method.poll
/// [executor]: https://docs.rs/futures/0.1/futures/future/trait.Executor.html
///
/// # Examples
///
/// ```
/// # use tokio::io::{AsyncRead, AsyncWrite};
/// # use rama_http_core::h2::client;
/// # use rama_http_core::h2::client::*;
/// # use rama_core::extensions::ExtensionsRef;
/// #
/// # async fn doc<T>(my_io: T) -> Result<(), rama_http_core::h2::Error>
/// # where T: AsyncRead + AsyncWrite + Send + Unpin + ExtensionsRef + 'static,
/// # {
///     let (send_request, connection) = client::handshake(my_io).await?;
///     // Submit the connection handle to an executor.
///     tokio::spawn(async { connection.await.expect("connection failed"); });
///
///     // Now, use `send_request` to initialize HTTP/2 streams.
///     // ...
/// # Ok(())
/// # }
/// #
/// # pub fn main() {}
/// ```
#[must_use = "futures do nothing unless polled"]
pub struct Connection<T, B: Buf = Bytes> {
    inner: proto::Connection<T, Peer, B>,
}

/// A future of an HTTP response.
#[derive(Debug)]
#[must_use = "futures do nothing unless polled"]
pub struct ResponseFuture {
    inner: proto::OpaqueStreamRef,
    push_promise_consumed: bool,
}

/// A future of a pushed HTTP response.
///
/// We have to differentiate between pushed and non pushed because of the spec
/// <https://httpwg.org/specs/rfc7540.html#PUSH_PROMISE>
/// > PUSH_PROMISE frames MUST only be sent on a peer-initiated stream
/// > that is in either the "open" or "half-closed (remote)" state.
#[derive(Debug)]
#[must_use = "futures do nothing unless polled"]
pub struct PushedResponseFuture {
    inner: ResponseFuture,
}

/// A pushed response and corresponding request headers
#[derive(Debug)]
pub struct PushPromise {
    /// The request headers
    request: Request<()>,

    /// The pushed response
    response: PushedResponseFuture,
}

/// A stream of pushed responses and corresponding promised requests
#[derive(Debug)]
#[must_use = "streams do nothing unless polled"]
pub struct PushPromises {
    inner: proto::OpaqueStreamRef,
}

/// Builds client connections with custom configuration values.
///
/// Methods can be chained in order to set the configuration values.
///
/// The client is constructed by calling [`handshake`] and passing the I/O
/// handle that will back the HTTP/2 server.
///
/// New instances of `Builder` are obtained via [`Builder::new`].
///
/// See function level documentation for details on the various client
/// configuration settings.
///
/// [`Builder::new`]: struct.Builder.html#method.new
/// [`handshake`]: struct.Builder.html#method.handshake
///
/// # Examples
///
/// ```
/// # use tokio::io::{AsyncRead, AsyncWrite};
/// # use rama_http_core::h2::client::*;
/// # use rama_core::bytes::Bytes;
/// # use rama_core::extensions::ExtensionsRef;
/// #
/// # async fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
///     -> Result<((SendRequest<Bytes>, Connection<T, Bytes>)), rama_http_core::h2::Error>
/// # {
/// // `client_fut` is a future representing the completion of the HTTP/2
/// // handshake.
/// let client_fut = Builder::new()
///     .with_initial_window_size(1_000_000)
///     .with_max_concurrent_streams(1000)
///     .handshake(my_io);
/// # client_fut.await
/// # }
/// #
/// # pub fn main() {}
/// ```
#[derive(Clone, Debug)]
pub struct Builder {
    initial_settings: Option<Arc<Settings>>,
    observe_peer_settings: bool,
    /// Time to keep locally reset streams around before reaping.
    reset_stream_duration: Duration,

    /// Initial maximum number of locally initiated (send) streams.
    /// After receiving a SETTINGS frame from the remote peer,
    /// the connection will overwrite this value with the
    /// MAX_CONCURRENT_STREAMS specified in the frame.
    /// If no value is advertised by the remote peer in the initial SETTINGS
    /// frame, it will be set to usize::MAX.
    initial_max_send_streams: usize,

    /// Reset every PUSH_PROMISE with REFUSED_STREAM.
    refuse_push_promises: bool,

    /// Initial target window size for new connections.
    initial_target_connection_window_size: Option<u32>,

    /// Maximum amount of bytes to "buffer" for writing per stream.
    max_send_buffer_size: u32,

    /// Maximum number of locally reset streams to keep at a time.
    reset_stream_max: usize,

    /// Maximum number of remotely reset streams to allow in the pending
    /// accept queue.
    pending_accept_reset_stream_max: usize,

    /// Initial `Settings` frame to send as part of the handshake.
    settings: Option<Settings>,

    /// If true and if `Settings` are set, the settings defined will overwrite initial
    /// settings given by the replay
    overwrite_replay_settings: bool,

    /// The stream ID of the first (lowest) stream. Subsequent streams will use
    /// monotonically increasing stream IDs.
    stream_id: StreamId,

    /// Maximum number of locally reset streams due to protocol error across
    /// the lifetime of the connection.
    ///
    /// When this gets exceeded, we issue GOAWAYs.
    local_max_error_reset_streams: Option<usize>,

    /// connection-level budget for DATA framing overhead.
    ///
    /// When this gets exhausted, we issue a GOAWAY with `ENHANCE_YOUR_CALM`.
    data_frame_budget: proto::DataFrameBudget,

    /// The headers frame pseudo order
    headers_pseudo_order: Option<PseudoHeaderOrder>,

    /// The early frames to be used by the client
    early_frames: Option<Vec<EarlyFrame>>,
}

#[derive(Debug)]
pub(crate) struct Peer;

// ===== impl SendRequest =====

impl<B> SendRequest<B>
where
    B: Buf,
{
    /// Returns `Ready` when the connection can initialize a new HTTP/2
    /// stream.
    ///
    /// This function must return `Ready` before `send_request` is called. When
    /// `Poll::Pending` is returned, the task will be notified once the readiness
    /// state changes.
    ///
    /// See [module] level docs for more details.
    ///
    /// [module]: index.html
    pub fn poll_ready(&mut self, cx: &mut Context) -> Poll<Result<(), crate::h2::Error>> {
        ready!(self.inner.poll_pending_open(cx, self.pending.as_ref()))?;
        self.pending = None;
        Poll::Ready(Ok(()))
    }

    /// Consumes `self`, returning a future that returns `self` back once it is
    /// ready to send a request.
    ///
    /// This function should be called before calling `send_request`.
    ///
    /// This is a functional combinator for [`poll_ready`]. The returned future
    /// will call `SendStream::poll_ready` until `Ready`, then returns `self` to
    /// the caller.
    ///
    /// # Examples
    ///
    /// ```rust
    /// # use rama_http_core::h2::client::*;
    /// # use rama_http_types::*;
    /// # async fn doc(send_request: SendRequest<&'static [u8]>)
    /// # {
    /// // First, wait until the `send_request` handle is ready to send a new
    /// // request
    /// let mut send_request = send_request.ready().await.unwrap();
    /// // Use `send_request` here.
    /// # }
    /// # pub fn main() {}
    /// ```
    ///
    /// See [module] level docs for more details.
    ///
    /// [`poll_ready`]: #method.poll_ready
    /// [module]: index.html
    #[must_use]
    pub fn ready(self) -> ReadySendRequest<B> {
        ReadySendRequest { inner: Some(self) }
    }

    /// Sends a HTTP/2 request to the server.
    ///
    /// `send_request` initializes a new HTTP/2 stream on the associated
    /// connection, then sends the given request using this new stream. Only the
    /// request head is sent.
    ///
    /// On success, a [`ResponseFuture`] instance and [`SendStream`] instance
    /// are returned. The [`ResponseFuture`] instance is used to get the
    /// server's response and the [`SendStream`] instance is used to send a
    /// request body or trailers to the server over the same HTTP/2 stream.
    ///
    /// To send a request body or trailers, set `end_of_stream` to `false`.
    /// Then, use the returned [`SendStream`] instance to stream request body
    /// chunks or send trailers. If `end_of_stream` is **not** set to `false`
    /// then attempting to call [`SendStream::send_data`] or
    /// [`SendStream::send_trailers`] will result in an error.
    ///
    /// If no request body or trailers are to be sent, set `end_of_stream` to
    /// `true` and drop the returned [`SendStream`] instance.
    ///
    /// # A note on HTTP versions
    ///
    /// The provided `Request` will be encoded differently depending on the
    /// value of its version field. If the version is set to 2.0, then the
    /// request is encoded as per the specification recommends.
    ///
    /// If the version is set to a lower value, then the request is encoded to
    /// preserve the characteristics of HTTP 1.1 and lower. Specifically, host
    /// headers are permitted and the `:authority` pseudo header is not
    /// included.
    ///
    /// The caller should always set the request's version field to 2.0 unless
    /// specifically transmitting an HTTP 1.1 request over 2.0.
    ///
    /// # Examples
    ///
    /// Sending a request with no body
    ///
    /// ```rust
    /// # use rama_http_core::h2::client::*;
    /// # use rama_http_types::*;
    /// # async fn doc(send_request: SendRequest<&'static [u8]>)
    /// # {
    /// // First, wait until the `send_request` handle is ready to send a new
    /// // request
    /// let mut send_request = send_request.ready().await.unwrap();
    /// // Prepare the HTTP request to send to the server.
    /// let request = Request::get("https://www.example.com/")
    ///     .body(())
    ///     .unwrap();
    ///
    /// // Send the request to the server. Since we are not sending a
    /// // body or trailers, we can drop the `SendStream` instance.
    /// let (response, _) = send_request.send_request(request, true).unwrap();
    /// let response = response.await.unwrap();
    /// // Process the response
    /// # }
    /// # pub fn main() {}
    /// ```
    ///
    /// Sending a request with a body and trailers
    ///
    /// ```rust
    /// # use rama_http_core::h2::client::*;
    /// # use rama_http_types::*;
    /// # async fn doc(send_request: SendRequest<&'static [u8]>)
    /// # {
    /// // First, wait until the `send_request` handle is ready to send a new
    /// // request
    /// let mut send_request = send_request.ready().await.unwrap();
    ///
    /// // Prepare the HTTP request to send to the server.
    /// let request = Request::get("https://www.example.com/")
    ///     .body(())
    ///     .unwrap();
    ///
    /// // Send the request to the server. If we are not sending a
    /// // body or trailers, we can drop the `SendStream` instance.
    /// let (response, mut send_stream) = send_request
    ///     .send_request(request, false).unwrap();
    ///
    /// // At this point, one option would be to wait for send capacity.
    /// // Doing so would allow us to not hold data in memory that
    /// // cannot be sent. However, this is not a requirement, so this
    /// // example will skip that step. See `SendStream` documentation
    /// // for more details.
    /// send_stream.send_data(b"hello", false).unwrap();
    /// send_stream.send_data(b"world", false).unwrap();
    ///
    /// // Send the trailers.
    /// let mut trailers = HeaderMap::new();
    /// trailers.insert(
    ///     header::HeaderName::from_bytes(b"my-trailer").unwrap(),
    ///     header::HeaderValue::from_bytes(b"hello").unwrap());
    ///
    /// send_stream.send_trailers(trailers).unwrap();
    ///
    /// let response = response.await.unwrap();
    /// // Process the response
    /// # }
    /// # pub fn main() {}
    /// ```
    ///
    /// [`ResponseFuture`]: struct.ResponseFuture.html
    /// [`SendStream`]: ../struct.SendStream.html
    /// [`SendStream::send_data`]: ../struct.SendStream.html#method.send_data
    /// [`SendStream::send_trailers`]: ../struct.SendStream.html#method.send_trailers
    pub fn send_request(
        &mut self,
        request: Request<()>,
        end_of_stream: bool,
    ) -> Result<(ResponseFuture, SendStream<B>), crate::h2::Error> {
        self.inner
            .send_request(request, end_of_stream, self.pending.as_ref())
            .map(|(stream, is_full)| {
                if stream.is_pending_open() && is_full {
                    // Only prevent sending another request when the request queue
                    // is not full.
                    self.pending = Some(stream.clone_to_opaque());
                }

                let response = ResponseFuture {
                    inner: stream.clone_to_opaque(),
                    push_promise_consumed: false,
                };

                let stream = SendStream::new(stream);

                (response, stream)
            })
    }

    /// Returns whether the [extended CONNECT protocol][1] is enabled or not.
    ///
    /// This setting is configured by the server peer by sending the
    /// [`SETTINGS_ENABLE_CONNECT_PROTOCOL` parameter][2] in a `SETTINGS` frame.
    /// This method returns the currently acknowledged value received from the
    /// remote.
    ///
    /// [1]: https://datatracker.ietf.org/doc/html/rfc8441#section-4
    /// [2]: https://datatracker.ietf.org/doc/html/rfc8441#section-3
    #[must_use]
    pub fn is_extended_connect_protocol_enabled(&self) -> bool {
        self.inner.is_extended_connect_protocol_enabled()
    }

    /// Returns the peer's initial SETTINGS frame, wrapped in the
    /// extension type [`rama_http_types::conn::PeerH2Settings`], if one
    /// has been observed on this connection yet.
    ///
    /// The frame is captured the first time it is received and is not
    /// overwritten by subsequent SETTINGS updates from the peer. The
    /// returned `Arc` is cheap to clone — the connection stores the
    /// pre-built extension once and reuses it for every response via
    /// `Extensions::insert_arc`, so per-response observers pay only a
    /// single atomic bump.
    #[must_use]
    pub fn peer_initial_settings(
        &self,
    ) -> Option<std::sync::Arc<rama_http_types::conn::PeerH2Settings>> {
        self.inner.peer_settings_state().snapshot()
    }

    /// Returns a cheap clone of the connection's shared
    /// `PeerSettingsState` cell. Observer handles built on this clone do
    /// NOT prolong the connection's lifetime — the cell lives
    /// independently of the request dispatcher.
    #[must_use]
    pub(crate) fn peer_settings_state(&self) -> std::sync::Arc<crate::h2::PeerSettingsState> {
        self.inner.peer_settings_state()
    }

    /// Resolves to the initial `SETTINGS` frame sent by the remote peer.
    ///
    /// Returns `Some(settings)` once the peer's initial SETTINGS frame has
    /// been received and processed by the connection task. Returns `None`
    /// if the connection terminates before SETTINGS arrives (e.g. the peer
    /// is non-compliant or the transport dies during handshake).
    ///
    /// The h2 spec requires the server's first frame to be `SETTINGS`, so
    /// this future will normally resolve very shortly after a successful
    /// handshake — typically within one or two poll cycles of the spawned
    /// connection task. There is no need to send a request first.
    ///
    /// Even so, callers handling untrusted peers should wrap this in a
    /// timeout (e.g. [`tokio::time::timeout`]): a non-compliant peer that
    /// keeps the transport alive without sending SETTINGS would otherwise
    /// keep this future pending indefinitely until the underlying
    /// connection eventually times out at the transport layer.
    pub async fn await_peer_initial_settings(
        &self,
    ) -> Option<std::sync::Arc<rama_http_types::conn::PeerH2Settings>> {
        self.inner.peer_settings_state().await_settings().await
    }

    /// Returns the current max send streams
    #[must_use]
    pub fn current_max_send_streams(&self) -> usize {
        self.inner.current_max_send_streams()
    }

    /// Local streams not yet closed, for exact pool admission.
    pub(crate) fn local_streams(&self) -> std::sync::Arc<crate::h2::proto::LocalStreams> {
        self.inner.local_streams()
    }

    /// Returns the current max recv streams
    #[must_use]
    pub fn current_max_recv_streams(&self) -> usize {
        self.inner.current_max_recv_streams()
    }
}

impl<B> fmt::Debug for SendRequest<B>
where
    B: Buf,
{
    fn fmt(&self, fmt: &mut fmt::Formatter) -> fmt::Result {
        fmt.debug_struct("SendRequest").finish()
    }
}

impl<B> Clone for SendRequest<B>
where
    B: Buf,
{
    fn clone(&self) -> Self {
        Self {
            inner: self.inner.clone(),
            pending: None,
        }
    }
}

#[cfg(feature = "unstable")]
impl<B> SendRequest<B>
where
    B: Buf,
{
    /// Returns the number of active streams.
    ///
    /// An active stream is a stream that has not yet transitioned to a closed
    /// state.
    #[must_use]
    pub fn num_active_streams(&self) -> usize {
        self.inner.num_active_streams()
    }

    /// Returns the number of streams that are held in memory.
    ///
    /// A wired stream is a stream that is either active or is closed but must
    /// stay in memory for some reason. For example, there are still outstanding
    /// userspace handles pointing to the slot.
    #[must_use]
    pub fn num_wired_streams(&self) -> usize {
        self.inner.num_wired_streams()
    }
}

// ===== impl ReadySendRequest =====

impl<B> Future for ReadySendRequest<B>
where
    B: Buf,
{
    type Output = Result<SendRequest<B>, crate::h2::Error>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        if let Some(send_request) = self.inner.as_mut() {
            ready!(send_request.poll_ready(cx))?;
            #[expect(clippy::expect_used, reason = "memory cannot move in between polls")]
            let send_request = self.inner.take().expect("inner SendRequest was Some above");
            Poll::Ready(Ok(send_request))
        } else {
            warn!(
                "h2 client: ReadySendRequest: (inner) SendRequest no longer available: future polled after ready, report bug in rama repo"
            );
            Poll::Ready(Err(crate::h2::Error::from(
                crate::h2::UserError::PollAfterReady,
            )))
        }
    }
}

// ===== impl Builder =====

impl Builder {
    /// Returns a new client builder instance initialized with default
    /// configuration values.
    ///
    /// Configuration methods can be chained on the return value.
    ///
    /// # Examples
    ///
    /// ```
    /// # use tokio::io::{AsyncRead, AsyncWrite};
    /// # use rama_http_core::h2::client::*;
    /// # use rama_core::bytes::Bytes;
    /// # use rama_core::extensions::ExtensionsRef;
    /// #
    /// # async fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
    /// # -> Result<((SendRequest<Bytes>, Connection<T, Bytes>)), rama_http_core::h2::Error>
    /// # {
    /// // `client_fut` is a future representing the completion of the HTTP/2
    /// // handshake.
    /// let client_fut = Builder::new()
    ///     .with_initial_window_size(1_000_000)
    ///     .with_max_concurrent_streams(1000)
    ///     .handshake(my_io);
    /// # client_fut.await
    /// # }
    /// #
    /// # pub fn main() {}
    /// ```
    #[must_use]
    pub fn new() -> Self {
        Self {
            max_send_buffer_size: proto::DEFAULT_MAX_SEND_BUFFER_SIZE,
            reset_stream_duration: Duration::from_secs(proto::DEFAULT_RESET_STREAM_SECS),
            reset_stream_max: proto::DEFAULT_RESET_STREAM_MAX,
            pending_accept_reset_stream_max: proto::DEFAULT_REMOTE_RESET_STREAM_MAX,
            initial_target_connection_window_size: None,
            initial_max_send_streams: usize::MAX,
            refuse_push_promises: false,
            settings: None,
            overwrite_replay_settings: false,
            stream_id: 1.into(),
            local_max_error_reset_streams: Some(proto::DEFAULT_LOCAL_RESET_COUNT_MAX),
            data_frame_budget: proto::DataFrameBudget::Auto,
            headers_pseudo_order: None,
            early_frames: None,
            initial_settings: None,
            observe_peer_settings: false,
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Replace the initial SETTINGS frame, validated when the handshake begins.
        /// None keeps the configured scalar/replay settings.
        pub fn initial_settings(mut self, settings: Option<Arc<Settings>>) -> Self {
            self.initial_settings = settings;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Retain bounded peer SETTINGS occurrences and wire order. Disabled by default.
        pub fn observe_peer_settings(mut self, enabled: bool) -> Self {
            self.observe_peer_settings = enabled;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        pub fn headers_pseudo_order(mut self, order: Option<PseudoHeaderOrder>) -> Self {
            self.headers_pseudo_order = order;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        pub fn setting_order(mut self, order: Option<SettingOrder>) -> Self {
            self.settings
                .get_or_insert_default()
                .config
                .setting_order = order;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        pub fn early_frames(mut self, early_frames: Option<Vec<EarlyFrame>>) -> Self {
            self.early_frames = early_frames;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        pub fn setting_config(mut self, config: SettingsConfig) ->Self {
            self.settings.get_or_insert_default().set_config(config);
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Indicates the initial window size (in octets) for stream-level
        /// flow control for received data.
        ///
        /// The initial window of a stream is used as part of flow control. For more
        /// details, see [`FlowControl`].
        ///
        /// The default value is 65,535.
        ///
        /// [`FlowControl`]: ../struct.FlowControl.html
        ///
        /// # Examples
        ///
        /// ```
        /// # use tokio::io::{AsyncRead, AsyncWrite};
        /// # use rama_http_core::h2::client::*;
        /// # use rama_core::bytes::Bytes;
        /// # use rama_core::extensions::ExtensionsRef;
        /// #
        /// # async fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
        /// # -> Result<((SendRequest<Bytes>, Connection<T, Bytes>)), rama_http_core::h2::Error>
        /// # {
        /// // `client_fut` is a future representing the completion of the HTTP/2
        /// // handshake.
        /// let client_fut = Builder::new()
        ///     .with_initial_window_size(1_000_000)
        ///     .handshake(my_io);
        /// # client_fut.await
        /// # }
        /// #
        /// # pub fn main() {}
        /// ```
        pub fn initial_window_size(mut self, size: Option<u32>) -> Self {
            self.settings
                .get_or_insert_default()
                .config
                .initial_window_size = size;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Indicates the initial window size (in octets) for connection-level flow control
        /// for received data.
        ///
        /// The initial window of a connection is used as part of flow control. For more details,
        /// see [`FlowControl`].
        ///
        /// The default value is 65,535.
        ///
        /// [`FlowControl`]: ../struct.FlowControl.html
        ///
        /// # Examples
        ///
        /// ```
        /// # use tokio::io::{AsyncRead, AsyncWrite};
        /// # use rama_http_core::h2::client::*;
        /// # use rama_core::bytes::Bytes;
        /// # use rama_core::extensions::ExtensionsRef;
        /// #
        /// # async fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
        /// # -> Result<((SendRequest<Bytes>, Connection<T, Bytes>)), rama_http_core::h2::Error>
        /// # {
        /// // `client_fut` is a future representing the completion of the HTTP/2
        /// // handshake.
        /// let client_fut = Builder::new()
        ///     .with_initial_connection_window_size(1_000_000)
        ///     .handshake(my_io);
        /// # client_fut.await
        /// # }
        /// #
        /// # pub fn main() {}
        /// ```
        pub fn initial_connection_window_size(mut self, size: Option<u32>) -> Self {
            self.initial_target_connection_window_size = size;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Indicates the size (in octets) of the largest HTTP/2 frame payload that the
        /// configured client is able to accept.
        ///
        /// The sender may send data frames that are **smaller** than this value,
        /// but any data larger than `max` will be broken up into multiple `DATA`
        /// frames.
        ///
        /// The value **must** be between 16,384 and 16,777,215. The default value is 16,384.
        ///
        /// # Examples
        ///
        /// ```
        /// # use tokio::io::{AsyncRead, AsyncWrite};
        /// # use rama_http_core::h2::client::*;
        /// # use rama_core::bytes::Bytes;
        /// # use rama_core::extensions::ExtensionsRef;
        /// #
        /// # async fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
        /// # -> Result<((SendRequest<Bytes>, Connection<T, Bytes>)), rama_http_core::h2::Error>
        /// # {
        /// // `client_fut` is a future representing the completion of the HTTP/2
        /// // handshake.
        /// let client_fut = Builder::new()
        ///     .with_max_frame_size(1_000_000)
        ///     .handshake(my_io);
        /// # client_fut.await
        /// # }
        /// #
        /// # pub fn main() {}
        /// ```
        pub fn max_frame_size(mut self, max: Option<u32>) -> Self {
            self.settings
                .get_or_insert_default()
                .config
                .max_frame_size = max;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets the max size of received header frames.
        ///
        /// This advisory setting informs a peer of the maximum size of header list
        /// that the sender is prepared to accept, in octets. The value is based on
        /// the uncompressed size of header fields, including the length of the name
        /// and value in octets plus an overhead of 32 octets for each header field.
        ///
        /// This setting is also used to limit the maximum amount of data that is
        /// buffered to decode HEADERS frames.
        ///
        /// # Examples
        ///
        /// ```
        /// # use tokio::io::{AsyncRead, AsyncWrite};
        /// # use rama_http_core::h2::client::*;
        /// # use rama_core::bytes::Bytes;
        /// # use rama_core::extensions::ExtensionsRef;
        /// #
        /// # async fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
        /// # -> Result<((SendRequest<Bytes>, Connection<T, Bytes>)), rama_http_core::h2::Error>
        /// # {
        /// // `client_fut` is a future representing the completion of the HTTP/2
        /// // handshake.
        /// let client_fut = Builder::new()
        ///     .with_max_header_list_size(16 * 1024)
        ///     .handshake(my_io);
        /// # client_fut.await
        /// # }
        /// #
        /// # pub fn main() {}
        /// ```
        pub fn max_header_list_size(mut self, max: Option<u32>) -> Self {
            self.settings
                .get_or_insert_default()
                .config
                .max_header_list_size = max;
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
        /// Although the HTTP/2 specification excludes streams in the reserved state
        /// from this limit, reserved push streams count against this setting to
        /// protect resources. This includes push promises whose response streams
        /// have not yet started.
        ///
        /// Also note that if the remote *does* exceed the value set here, it is not
        /// a protocol level error. Instead, the `h2` library will immediately reset
        /// the stream.
        ///
        /// See [Section 5.1.2] in the HTTP/2 spec for more details.
        ///
        /// [Section 5.1.2]: https://httpwg.org/specs/rfc7540.html#rfc.section.5.1.2
        ///
        /// # Examples
        ///
        /// ```
        /// # use tokio::io::{AsyncRead, AsyncWrite};
        /// # use rama_http_core::h2::client::*;
        /// # use rama_core::bytes::Bytes;
        /// # use rama_core::extensions::ExtensionsRef;
        /// #
        /// # async fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
        /// # -> Result<((SendRequest<Bytes>, Connection<T, Bytes>)), rama_http_core::h2::Error>
        /// # {
        /// // `client_fut` is a future representing the completion of the HTTP/2
        /// // handshake.
        /// let client_fut = Builder::new()
        ///     .with_max_concurrent_streams(1000)
        ///     .handshake(my_io);
        /// # client_fut.await
        /// # }
        /// #
        /// # pub fn main() {}
        /// ```
        pub fn max_concurrent_streams(mut self, max: Option<u32>) -> Self {
            self.settings
                .get_or_insert_default()
                .config
                .max_concurrent_streams = max;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets the initial maximum of locally initiated (send) streams.
        ///
        /// The initial settings will be overwritten by the remote peer when
        /// the SETTINGS frame is received. The new value will be set to the
        /// `max_concurrent_streams()` from the frame. If no value is advertised in
        /// the initial SETTINGS frame from the remote peer as part of
        /// [HTTP/2 Connection Preface], `usize::MAX` will be set.
        ///
        /// This setting prevents the caller from exceeding this number of
        /// streams that are counted towards the concurrency limit.
        ///
        /// Sending streams past the limit returned by the peer will be treated
        /// as a stream error of type PROTOCOL_ERROR or REFUSED_STREAM.
        ///
        /// See [Section 5.1.2] in the HTTP/2 spec for more details.
        ///
        /// The default value is `usize::MAX`.
        ///
        /// [HTTP/2 Connection Preface]: https://httpwg.org/specs/rfc9113.html#preface
        /// [Section 5.1.2]: https://httpwg.org/specs/rfc9113.html#rfc.section.5.1.2
        ///
        /// # Examples
        ///
        /// ```
        /// # use tokio::io::{AsyncRead, AsyncWrite};
        /// # use rama_http_core::h2::client::*;
        /// # use rama_core::bytes::Bytes;
        /// # use rama_core::extensions::ExtensionsRef;
        /// #
        /// # async fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
        /// # -> Result<((SendRequest<Bytes>, Connection<T, Bytes>)), rama_http_core::h2::Error>
        /// # {
        /// // `client_fut` is a future representing the completion of the HTTP/2
        /// // handshake.
        /// let client_fut = Builder::new()
        ///     .with_initial_max_send_streams(1000)
        ///     .handshake(my_io);
        /// # client_fut.await
        /// # }
        /// #
        /// # pub fn main() {}
        /// ```
        pub fn initial_max_send_streams(mut self, initial: usize) -> Self {
            self.initial_max_send_streams = initial;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Reset every PUSH_PROMISE with REFUSED_STREAM, whatever ENABLE_PUSH this
        /// client advertises (RFC 9113 §8.4). Off by default.
        pub fn refuse_push_promises(mut self, refuse: bool) -> Self {
            self.refuse_push_promises = refuse;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets the maximum number of concurrent locally reset streams.
        ///
        /// When a stream is explicitly reset, the HTTP/2 specification requires
        /// that any further frames received for that stream must be ignored for
        /// "some time".
        ///
        /// In order to satisfy the specification, internal state must be maintained
        /// to implement the behavior. This state grows linearly with the number of
        /// streams that are locally reset.
        ///
        /// The `max_concurrent_reset_streams` setting configures sets an upper
        /// bound on the amount of state that is maintained. When this max value is
        /// reached, the oldest reset stream is purged from memory.
        ///
        /// Once the stream has been fully purged from memory, any additional frames
        /// received for that stream will result in a connection level protocol
        /// error, forcing the connection to terminate.
        ///
        /// The default value is 10.
        ///
        /// # Examples
        ///
        /// ```
        /// # use tokio::io::{AsyncRead, AsyncWrite};
        /// # use rama_http_core::h2::client::*;
        /// # use rama_core::bytes::Bytes;
        /// # use rama_core::extensions::ExtensionsRef;
        /// #
        /// # async fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
        /// # -> Result<((SendRequest<Bytes>, Connection<T, Bytes>)), rama_http_core::h2::Error>
        /// # {
        /// // `client_fut` is a future representing the completion of the HTTP/2
        /// // handshake.
        /// let client_fut = Builder::new()
        ///     .with_max_concurrent_reset_streams(1000)
        ///     .handshake(my_io);
        /// # client_fut.await
        /// # }
        /// #
        /// # pub fn main() {}
        /// ```
        pub fn max_concurrent_reset_streams(mut self, max: usize) -> Self {
            self.reset_stream_max = max;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets the duration to remember locally reset streams.
        ///
        /// When a stream is explicitly reset, the HTTP/2 specification requires
        /// that any further frames received for that stream must be ignored for
        /// "some time".
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
        /// The default value is 30 seconds.
        ///
        /// # Examples
        ///
        /// ```
        /// # use tokio::io::{AsyncRead, AsyncWrite};
        /// # use rama_http_core::h2::client::*;
        /// # use std::time::Duration;
        /// # use rama_core::bytes::Bytes;
        /// # use rama_core::extensions::ExtensionsRef;
        /// #
        /// # async fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
        /// # -> Result<((SendRequest<Bytes>, Connection<T, Bytes>)), rama_http_core::h2::Error>
        /// # {
        /// // `client_fut` is a future representing the completion of the HTTP/2
        /// // handshake.
        /// let client_fut = Builder::new()
        ///     .with_reset_stream_duration(Duration::from_secs(10))
        ///     .handshake(my_io);
        /// # client_fut.await
        /// # }
        /// #
        /// # pub fn main() {}
        /// ```
        pub fn reset_stream_duration(mut self, dur: Duration) -> Self {
            self.reset_stream_duration = dur;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets the maximum number of local resets due to protocol errors made by the remote end.
        ///
        /// Invalid frames and many other protocol errors will lead to resets being generated for those streams.
        /// Too many of these often indicate a malicious client, and there are attacks which can abuse this to DOS servers.
        /// This limit protects against these DOS attacks by limiting the amount of resets we can be forced to generate.
        ///
        /// When the number of local resets exceeds this threshold, the client will close the connection.
        ///
        /// If you really want to disable this, supply [`Option::None`] here.
        /// Disabling this is not recommended and may expose you to DOS attacks.
        ///
        /// The default value is currently 1024, but could change.
        pub fn max_local_error_reset_streams(mut self, max: Option<usize>) -> Self {
            self.local_max_error_reset_streams = max;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets a connection-level budget for limiting memory overhead from
        /// received small DATA frames.
        ///
        /// HTTP/2 flow control accounts for DATA payload bytes, but not the
        /// additional memory required to buffer each DATA frame. An excessive
        /// number of small frames may therefore consume disproportionate memory.
        ///
        /// Small DATA frames consume this budget. The budget is restored when
        /// buffered frames are consumed by the application, while sufficiently
        /// large frames may also restore budget. Empty DATA frames are limited
        /// separately and do not consume this budget.
        ///
        /// When this budget is exhausted, the connection is closed with
        /// `ENHANCE_YOUR_CALM`.
        ///
        /// With [`Option::None`], the default, the budget is half the target
        /// connection window, with a minimum of 25,600 bytes. Changing the target
        /// window at runtime also updates the permitted framing overhead.
        pub fn data_frame_budget(mut self, budget: Option<usize>) -> Self {
            self.data_frame_budget = budget.map_or(
                proto::DataFrameBudget::Auto,
                proto::DataFrameBudget::Configured,
            );
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets the maximum number of pending-accept remotely-reset streams.
        ///
        /// Streams that have been received by the peer, but not accepted by the
        /// user, can also receive a RST_STREAM. This is a legitimate pattern: one
        /// could send a request and then shortly after, realize it is not needed,
        /// sending a CANCEL.
        ///
        /// However, since those streams are now "closed", they don't count towards
        /// the max concurrent streams. So, they will sit in the accept queue,
        /// using memory.
        ///
        /// When the number of remotely-reset streams sitting in the pending-accept
        /// queue reaches this maximum value, a connection error with the code of
        /// `ENHANCE_YOUR_CALM` will be sent to the peer, and returned by the
        /// `Future`.
        ///
        /// The default value is currently 20, but could change.
        ///
        /// # Examples
        ///
        /// ```
        /// # use tokio::io::{AsyncRead, AsyncWrite};
        /// # use rama_http_core::h2::client::*;
        /// # use rama_core::bytes::Bytes;
        /// # use rama_core::extensions::ExtensionsRef;
        /// #
        /// # async fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
        /// # -> Result<((SendRequest<Bytes>, Connection<T, Bytes>)), rama_http_core::h2::Error>
        /// # {
        /// // `client_fut` is a future representing the completion of the HTTP/2
        /// // handshake.
        /// let client_fut = Builder::new()
        ///     .with_max_pending_accept_reset_streams(100)
        ///     .handshake(my_io);
        /// # client_fut.await
        /// # }
        /// #
        /// # pub fn main() {}
        /// ```
        pub fn max_pending_accept_reset_streams(mut self, max: usize) -> Self {
            self.pending_accept_reset_stream_max = max;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets the maximum send buffer size per stream.
        ///
        /// Once a stream has buffered up to (or over) the maximum, the stream's
        /// flow control will not "poll" additional capacity. Once bytes for the
        /// stream have been written to the connection, the send buffer capacity
        /// will be freed up again.
        ///
        /// The default is currently ~400KB, but may change.
        pub fn max_send_buffer_size(mut self, max: u32) -> Self {
            self.max_send_buffer_size = max;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Enables or disables server push promises.
        ///
        /// This value is included in the initial SETTINGS handshake.
        /// Setting this value to value to
        /// false in the initial SETTINGS handshake guarantees that the remote server
        /// will never send a push promise.
        ///
        /// This setting can be changed during the life of a single HTTP/2
        /// connection by sending another settings frame updating the value.
        ///
        /// Default value: `true`.
        ///
        /// # Examples
        ///
        /// ```
        /// # use tokio::io::{AsyncRead, AsyncWrite};
        /// # use rama_http_core::h2::client::*;
        /// # use std::time::Duration;
        /// # use rama_core::bytes::Bytes;
        /// # use rama_core::extensions::ExtensionsRef;
        /// #
        /// # async fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
        /// # -> Result<((SendRequest<Bytes>, Connection<T, Bytes>)), rama_http_core::h2::Error>
        /// # {
        /// // `client_fut` is a future representing the completion of the HTTP/2
        /// // handshake.
        /// let client_fut = Builder::new()
        ///     .with_enable_push(false)
        ///     .handshake(my_io);
        /// # client_fut.await
        /// # }
        /// #
        /// # pub fn main() {}
        /// ```
        pub fn enable_push(mut self, enabled: bool) -> Self {
            self.settings
                .get_or_insert_default()
                .config
                .enable_push = Some(enabled as u32);
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        pub fn enable_connect_protocol(mut self, value: Option<u32>) -> Self {
            self.settings
                .get_or_insert_default()
                .config
                .enable_connect_protocol = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        pub fn no_rfc7540_priorities(mut self, value: Option<u32>) -> Self {
            self.settings
                .get_or_insert_default()
                .config
                .no_rfc7540_priorities = value;
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
        ///
        /// # Examples
        ///
        /// ```
        /// # use tokio::io::{AsyncRead, AsyncWrite};
        /// # use rama_http_core::h2::client::*;
        /// # use rama_core::bytes::Bytes;
        /// # use rama_core::extensions::ExtensionsRef;
        /// #
        /// # async fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
        /// # -> Result<((SendRequest<Bytes>, Connection<T, Bytes>)), rama_http_core::h2::Error>
        /// # {
        /// // `client_fut` is a future representing the completion of the HTTP/2
        /// // handshake.
        /// let client_fut = Builder::new()
        ///     .with_header_table_size(1_000_000)
        ///     .handshake(my_io);
        /// # client_fut.await
        /// # }
        /// #
        /// # pub fn main() {}
        /// ```
        pub fn header_table_size(mut self, size: Option<u32>) -> Self {
            self.settings
                .get_or_insert_default()
                .config
                .header_table_size = size;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets the first stream ID to something other than 1.
        pub fn initial_stream_id(mut self, stream_id: u32) -> Result<Self, BoxError> {
            self.stream_id = stream_id.into();
            if !self.stream_id.is_client_initiated() {
                return Err(BoxError::from_static_str("stream id must be odd"));
            }
            Ok(self)
        }
    }

    /// Creates a new configured HTTP/2 client backed by `io`.
    ///
    /// It is expected that `io` already be in an appropriate state to commence
    /// the [HTTP/2 handshake]. The handshake is completed once both the connection
    /// preface and the initial settings frame is sent by the client.
    ///
    /// The handshake future does not wait for the initial settings frame from the
    /// server.
    ///
    /// Returns a future which resolves to the [`Connection`] / [`SendRequest`]
    /// tuple once the HTTP/2 handshake has been completed.
    ///
    /// This function also allows the caller to configure the send payload data
    /// type. See [Outbound data type] for more details.
    ///
    /// [HTTP/2 handshake]: http://httpwg.org/specs/rfc7540.html#ConnectionHeader
    /// [`Connection`]: struct.Connection.html
    /// [`SendRequest`]: struct.SendRequest.html
    /// [Outbound data type]: ../index.html#outbound-data-type.
    ///
    /// # Examples
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use tokio::io::{AsyncRead, AsyncWrite};
    /// # use rama_http_core::h2::client::*;
    /// # use rama_core::bytes::Bytes;
    /// # use rama_core::extensions::ExtensionsRef;
    /// #
    /// # async fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
    ///     -> Result<((SendRequest<Bytes>, Connection<T, Bytes>)), rama_http_core::h2::Error>
    /// # {
    /// // `client_fut` is a future representing the completion of the HTTP/2
    /// // handshake.
    /// let client_fut = Builder::new()
    ///     .handshake(my_io);
    /// # client_fut.await
    /// # }
    /// #
    /// # pub fn main() {}
    /// ```
    ///
    /// Configures the send-payload data type. In this case, the outbound data
    /// type will be `&'static [u8]`.
    ///
    /// ```
    /// # use tokio::io::{AsyncRead, AsyncWrite};
    /// # use rama_http_core::h2::client::*;
    /// # use rama_core::extensions::ExtensionsRef;
    /// #
    /// # async fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
    /// # -> Result<((SendRequest<&'static [u8]>, Connection<T, &'static [u8]>)), rama_http_core::h2::Error>
    /// # {
    /// // `client_fut` is a future representing the completion of the HTTP/2
    /// // handshake.
    /// let client_fut = Builder::new()
    ///     .handshake::<_, &'static [u8]>(my_io);
    /// # client_fut.await
    /// # }
    /// #
    /// # pub fn main() {}
    /// ```
    pub fn handshake<T, B>(
        &self,
        io: T,
    ) -> impl Future<Output = Result<(SendRequest<B>, Connection<T, B>), crate::h2::Error>> + use<T, B>
    where
        T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef,
        B: Buf,
    {
        Connection::handshake2(io, self.clone())
    }
}

impl Default for Builder {
    fn default() -> Self {
        Self::new()
    }
}

/// Creates a new configured HTTP/2 client with default configuration
/// values backed by `io`.
///
/// It is expected that `io` already be in an appropriate state to commence
/// the [HTTP/2 handshake]. See [Handshake] for more details.
///
/// Returns a future which resolves to the [`Connection`] / [`SendRequest`]
/// tuple once the HTTP/2 handshake has been completed. The returned
/// [`Connection`] instance will be using default configuration values. Use
/// [`Builder`] to customize the configuration values used by a [`Connection`]
/// instance.
///
/// [HTTP/2 handshake]: http://httpwg.org/specs/rfc7540.html#ConnectionHeader
/// [Handshake]: ../index.html#handshake
/// [`Connection`]: struct.Connection.html
/// [`SendRequest`]: struct.SendRequest.html
///
/// # Examples
///
/// ```
/// # use tokio::io::{AsyncRead, AsyncWrite};
/// # use rama_http_core::h2::client;
/// # use rama_http_core::h2::client::*;
/// # use rama_core::extensions::ExtensionsRef;
/// #
/// # async fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T) -> Result<(), rama_http_core::h2::Error>
/// # {
/// let (send_request, connection) = client::handshake(my_io).await?;
/// // The HTTP/2 handshake has completed, now start polling
/// // `connection` and use `send_request` to send requests to the
/// // server.
/// # Ok(())
/// # }
/// #
/// # pub fn main() {}
/// ```
pub async fn handshake<T>(
    io: T,
) -> Result<(SendRequest<Bytes>, Connection<T, Bytes>), crate::h2::Error>
where
    T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef,
{
    let builder = Builder::new();
    builder
        .handshake(io)
        .instrument(tracing::trace_span!("client_handshake"))
        .await
}

// ===== impl Connection =====

async fn bind_connection<T>(io: &mut T) -> Result<(), crate::h2::Error>
where
    T: AsyncRead + AsyncWrite + Unpin,
{
    tracing::debug!("binding client connection");

    let msg: &'static [u8] = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    io.write_all(msg).await.map_err(crate::h2::Error::from_io)?;

    tracing::debug!("client connection bound");

    Ok(())
}

impl<T, B> Connection<T, B>
where
    T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef,
    B: Buf,
{
    async fn handshake2(
        mut io: T,
        builder: Builder,
    ) -> Result<(SendRequest<B>, Self), crate::h2::Error> {
        bind_connection(&mut io).await?;
        io.extensions().insert(StreamTransformed {
            by: "rama-http-core::h2::client",
        });

        // Create the codec
        let mut codec = Codec::new(io);
        codec.set_observe_early_frames(builder.observe_peer_settings);

        let (mut initial_settings, early_frame_ctx) = if let Some(frames) = builder.early_frames {
            let (ctx, settings) = EarlyFrameStreamContext::new_replayer(frames);
            if let Some(mut settings) = settings {
                tracing::trace!(
                    "early frame replayer used for client w/ custom settings {settings:?}; builder settings = {:?}",
                    builder.settings,
                );
                if let Some(overwrites) = builder.settings {
                    if builder.overwrite_replay_settings {
                        settings.merge(overwrites);
                        tracing::trace!(
                            "overwrites from builder have been applied on top of of early frame replayer: settings = {settings:?}",
                        );
                    } else {
                        tracing::trace!(
                            "overwrites {overwrites:?} from builder have been ignored in favor of of early frame replayer w/ settings {settings:?}",
                        );
                    }
                }
                (settings, ctx)
            } else {
                let settings = builder.settings.unwrap_or_default();
                tracing::trace!(
                    "early frame replayer used for client w/o settings; use builder settings (or default): {settings:?}",
                );
                (settings, ctx)
            }
        } else {
            let settings = builder.settings.unwrap_or_default();
            tracing::trace!(
                "no early frames replayer used for client, use builder settings (or default): {settings:?}",
            );
            (settings, EarlyFrameStreamContext::new_nop())
        };

        // new_replayer returned and removed its leading SETTINGS. Its context
        // retains only later frames/policies; replace the initial frame and its
        // native local-settings state together, without reinserting the old one.
        let mut advertised = None;
        if let Some(exact) = builder.initial_settings {
            let literal = exact.to_literal().map_err(|error| {
                tracing::debug!(?error, "invalid initial HTTP/2 SETTINGS framing or literal");
                crate::h2::Error::from(Reason::PROTOCOL_ERROR)
            })?;
            if let Some(limits) = codec.extensions().get_ref::<H2SettingsLimits>() {
                limits.validate(&literal).map_err(|error| {
                    tracing::debug!(?error, "initial HTTP/2 SETTINGS exceed receive limits");
                    crate::h2::Error::from(Reason::ENHANCE_YOUR_CALM)
                })?;
            }
            initial_settings = proto::with_local_caps(literal.clone(), &initial_settings.config);
            advertised = Some(literal);
        }

        if let Some(max) = initial_settings.config.max_frame_size {
            codec.set_max_recv_frame_size(max as usize);
        }

        if let Some(max) = initial_settings.config.max_header_list_size {
            codec.set_max_recv_header_list_size(max as usize);
        }

        // Send initial settings frame
        let advertised = advertised.unwrap_or_else(|| initial_settings.clone());
        if let Err(err) = codec.buffer(advertised.into()) {
            debug!(
                "h2 client: invalid SETTINGS frame: failed to buffer: {err}; return error; report bug in rama"
            );
            return Err(err.into());
        }

        // A replayed capture starts where it started, unless the builder chose otherwise.
        let next_stream_id = match early_frame_ctx.first_stream_id() {
            Some(first) if builder.stream_id == StreamId::from(1) => first,
            _ => builder.stream_id,
        };
        let inner = proto::Connection::try_new(
            codec,
            proto::Config {
                next_stream_id,
                initial_max_send_streams: builder.initial_max_send_streams,
                refuse_push_promises: builder.refuse_push_promises,
                max_send_buffer_size: builder.max_send_buffer_size,
                reset_stream_duration: builder.reset_stream_duration,
                reset_stream_max: builder.reset_stream_max,
                remote_reset_stream_max: builder.pending_accept_reset_stream_max,
                local_error_reset_streams_max: builder.local_max_error_reset_streams,
                settings: initial_settings,
                send_alt_svc: false,
                headers_pseudo_order: builder.headers_pseudo_order,
                early_frame_ctx,
                data_frame_budget: builder.data_frame_budget,
                settings_sent_at: None,
            },
        )?;
        let send_request = SendRequest {
            inner: inner.streams().clone(),
            pending: None,
        };

        let mut connection = Self { inner };
        if let Some(sz) = builder.initial_target_connection_window_size {
            connection.try_set_target_window_size(sz)?;
        }

        Ok((send_request, connection))
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets the target window size for the whole connection.
        ///
        /// If `size` is greater than the current value, then a `WINDOW_UPDATE`
        /// frame will be immediately sent to the remote, increasing the connection
        /// level window by `size - current_value`.
        ///
        /// If `size` is less than the current value, nothing will happen
        /// immediately. However, as window capacity is released by
        /// [`FlowControl`] instances, no `WINDOW_UPDATE` frames will be sent
        /// out until the number of "in flight" bytes drops below `size`.
        ///
        /// The default value is 65,535.
        ///
        /// The automatic small DATA frame budget follows this target.
        ///
        /// See [`FlowControl`] documentation for more details.
        ///
        /// [`FlowControl`]: ../struct.FlowControl.html
        /// [library level]: ../index.html#flow-control
        pub fn target_window_size(mut self, size: u32) -> Result<Self, crate::h2::Error> {
            if size > proto::MAX_WINDOW_SIZE {
                return Err(crate::h2::Error::from(UserError::InvalidSettingValue));
            }
            self.inner.try_set_target_window_size(size)?;
            Ok(self)
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set a new `INITIAL_WINDOW_SIZE` setting (in octets) for stream-level
        /// flow control for received data.
        ///
        /// The `SETTINGS` will be sent to the remote, and only applied once the
        /// remote acknowledges the change.
        ///
        /// This can be used to increase or decrease the window size for existing
        /// streams.
        ///
        /// # Errors
        ///
        /// Returns an error if a previous call is still pending acknowledgement
        /// from the remote endpoint or if the given size is invalid.
        pub fn initial_window_size(mut self, size: u32) -> Result<Self, crate::h2::Error> {
            if size > proto::MAX_WINDOW_SIZE {
                return Err(crate::h2::Error::from(UserError::InvalidSettingValue));
            }
            self.inner.try_set_initial_window_size(size)?;
            Ok(self)
        }
    }

    /// Takes a `PingPong` instance from the connection.
    ///
    /// # Note
    ///
    /// This may only be called once. Calling multiple times will return `None`.
    pub fn ping_pong(&mut self) -> Option<PingPong> {
        self.inner.take_user_pings().map(PingPong::new)
    }

    /// Returns the maximum number of concurrent streams that may be initiated
    /// by this client.
    ///
    /// This limit is configured by the server peer by sending the
    /// [`SETTINGS_MAX_CONCURRENT_STREAMS` parameter][1] in a `SETTINGS` frame.
    /// This method returns the currently acknowledged value received from the
    /// remote.
    ///
    /// [1]: https://tools.ietf.org/html/rfc7540#section-5.1.2
    pub fn max_concurrent_send_streams(&self) -> usize {
        self.inner.max_send_streams()
    }
    /// Returns the maximum number of concurrent streams that may be initiated
    /// by the server on this connection.
    ///
    /// This returns the value of the [`SETTINGS_MAX_CONCURRENT_STREAMS`
    /// parameter][1] sent in a `SETTINGS` frame that has been
    /// acknowledged by the remote peer. The value to be sent is configured by
    /// the [`Builder::max_concurrent_streams`][2] method before handshaking
    /// with the remote peer.
    ///
    /// [1]: https://tools.ietf.org/html/rfc7540#section-5.1.2
    /// [2]: ../struct.Builder.html#method.max_concurrent_streams
    pub fn max_concurrent_recv_streams(&self) -> usize {
        self.inner.max_recv_streams()
    }
}

impl<T, B> Future for Connection<T, B>
where
    T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef,
    B: Buf,
{
    type Output = Result<(), crate::h2::Error>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        // Snapshot before checking for shutdown: the last reference may be
        // dropped after the shutdown check, before inner.poll registers a
        // waker. A snapshot taken after that drop would be false and skip the
        // self-wake below, leaving the connection pending without closing.
        let had_streams_or_refs = self.inner.has_streams_or_other_references();
        self.inner.maybe_close_connection_if_no_streams();
        let result = self.inner.poll(cx).map_err(Into::into);
        // if we had streams/refs, and don't anymore, wake up one more time to
        // ensure proper shutdown
        if result.is_pending()
            && had_streams_or_refs
            && !self.inner.has_streams_or_other_references()
        {
            tracing::trace!("last stream closed during poll, wake again");
            cx.waker().wake_by_ref();
        }
        result
    }
}

impl<T, B> fmt::Debug for Connection<T, B>
where
    T: AsyncRead + AsyncWrite,
    T: fmt::Debug,
    B: fmt::Debug + Buf,
{
    fn fmt(&self, fmt: &mut fmt::Formatter) -> fmt::Result {
        fmt::Debug::fmt(&self.inner, fmt)
    }
}

// ===== impl ResponseFuture =====

impl Future for ResponseFuture {
    type Output = Result<Response<RecvStream>, crate::h2::Error>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let (parts, _) = ready!(self.inner.poll_response(cx))?.into_parts();
        let body = RecvStream::new(FlowControl::new(self.inner.clone()));

        Poll::Ready(Ok(Response::from_parts(parts, body)))
    }
}

impl ResponseFuture {
    /// Returns the stream ID of the response stream.
    ///
    /// # Panics
    ///
    /// If the lock on the stream store has been poisoned.
    #[must_use]
    pub fn stream_id(&self) -> StreamId {
        self.inner.stream_id()
    }

    /// Polls for informational responses (1xx status codes).
    ///
    /// This method should be called before polling the main response future
    /// to check for any informational responses that have been received.
    ///
    /// Returns `Poll::Ready(Some(response))` if an informational response is available,
    /// `Poll::Ready(None)` if no more informational responses are expected,
    /// or `Poll::Pending` if no informational response is currently available.
    pub fn poll_informational(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Response<()>, crate::h2::Error>>> {
        self.inner.poll_informational(cx).map_err(Into::into)
    }

    /// Returns a stream of PushPromises
    ///
    /// # Panics
    ///
    /// If this method has been called before
    /// or the stream was itself was pushed
    pub fn push_promises(&mut self) -> PushPromises {
        if self.push_promise_consumed {
            panic!("Reference to push promises stream taken!");
        }
        self.push_promise_consumed = true;
        PushPromises {
            inner: self.inner.clone(),
        }
    }
}

// ===== impl PushPromises =====

impl PushPromises {
    /// Get the next `PushPromise`.
    pub async fn push_promise(&mut self) -> Option<Result<PushPromise, crate::h2::Error>> {
        crate::h2::poll_fn(move |cx| self.poll_push_promise(cx)).await
    }

    #[doc(hidden)]
    pub fn poll_push_promise(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<PushPromise, crate::h2::Error>>> {
        match self.inner.poll_pushed(cx) {
            Poll::Ready(Some(Ok((request, response)))) => {
                let response = PushedResponseFuture {
                    inner: ResponseFuture {
                        inner: response,
                        push_promise_consumed: false,
                    },
                };
                Poll::Ready(Some(Ok(PushPromise { request, response })))
            }
            Poll::Ready(Some(Err(e))) => Poll::Ready(Some(Err(e.into()))),
            Poll::Ready(None) => Poll::Ready(None),
            Poll::Pending => Poll::Pending,
        }
    }
}

impl rama_core::futures::Stream for PushPromises {
    type Item = Result<PushPromise, crate::h2::Error>;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        self.poll_push_promise(cx)
    }
}

// ===== impl PushPromise =====

impl PushPromise {
    /// Returns a reference to the push promise's request headers.
    pub fn request(&self) -> &Request<()> {
        &self.request
    }

    /// Returns a mutable reference to the push promise's request headers.
    pub fn request_mut(&mut self) -> &mut Request<()> {
        &mut self.request
    }

    /// Consumes `self`, returning the push promise's request headers and
    /// response future.
    pub fn into_parts(self) -> (Request<()>, PushedResponseFuture) {
        (self.request, self.response)
    }
}

// ===== impl PushedResponseFuture =====

impl Future for PushedResponseFuture {
    type Output = Result<Response<RecvStream>, crate::h2::Error>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        Pin::new(&mut self.inner).poll(cx)
    }
}

impl PushedResponseFuture {
    /// Returns the stream ID of the response stream.
    ///
    /// # Panics
    ///
    /// If the lock on the stream store has been poisoned.
    #[must_use]
    pub fn stream_id(&self) -> StreamId {
        self.inner.stream_id()
    }
}

// ===== impl Peer =====

/// A single valid `Host` becomes `:authority` when [`host_is_wire_authority`] says so,
/// keeping its sensitivity; the `Host` line itself is sent unchanged. Any other `Host` next to
/// `:authority` is dropped, so one authority reaches the wire. An ordinary CONNECT's final
/// authority must name a port (RFC 9113 §8.5).
fn host_as_authority(
    pseudo: &mut Pseudo,
    headers: &mut HeaderMap,
    ordinary_connect: bool,
) -> Result<(), UserError> {
    let mut drop_host = false;
    match outgoing_host(headers) {
        OutgoingHost::Usable(host, parsed) => {
            let projected = pseudo
                .authority
                .as_deref()
                .map(str::as_bytes)
                .map(AuthorityRef::parse);
            if let Some(Ok(projected)) = projected
                && host_is_wire_authority(projected, parsed)
                && let Ok(value) = BytesStr::try_from(Bytes::copy_from_slice(host.as_bytes()))
            {
                let sensitive = host.is_sensitive();
                pseudo.set_authority(value);
                if sensitive {
                    pseudo
                        .sensitivity
                        .set_sensitive(PseudoHeader::Authority, true);
                }
            }
        }
        // Without `:authority` it would be the only one, and it cannot be.
        OutgoingHost::Unusable if pseudo.authority.is_none() => {
            return Err(UserError::MalformedHeaders);
        }
        OutgoingHost::Unusable => drop_host = true,
        OutgoingHost::Absent => {}
    }
    if drop_host {
        headers.remove(rama_http_types::header::HOST);
    }
    // RFC 9113 §8.5: an ordinary CONNECT names a host and port, whichever field supplied them.
    if ordinary_connect
        && pseudo
            .authority
            .as_deref()
            .and_then(|authority| AuthorityRef::parse(authority.as_bytes()).ok())
            .is_none_or(|authority| authority.port_u16().is_none())
    {
        return Err(UserError::MalformedHeaders);
    }
    Ok(())
}

impl Peer {
    pub(crate) fn convert_send_message(
        id: StreamId,
        request: Request<()>,
        protocol: Option<Protocol>,
        end_of_stream: bool,
        headers_pseudo_order: Option<PseudoHeaderOrder>,
        headers_priority: Option<StreamDependency>,
    ) -> Result<(Headers, Extensions), SendError> {
        use request::Parts;

        let (
            Parts {
                method,
                uri,
                mut headers,
                version,
                extensions,
                ..
            },
            _,
        ) = request.into_parts();

        // 每个请求携带自身的优先级，避免把导航优先级应用到所有请求。
        let headers_priority = extensions
            .get_ref::<StreamDependency>()
            .cloned()
            .or_else(|| extensions
                .get_ref::<rama_http_types::proto::h2::frame::ReceivedStreamDependency>()
                .filter(|p| p.0.dependency_id == StreamId::zero())
                .map(|p| p.0.clone()))
            .or(headers_priority);

        let is_connect = method == Method::CONNECT;
        let ordinary_connect = is_connect && protocol.is_none();

        // Build the set pseudo header set. All requests will include `method`
        // and `path`.
        let mut pseudo = Pseudo::request(method, &uri, protocol);

        // reuse order if defined
        if let Some(order) = extensions
            .get_ref::<PseudoHeaderOrder>()
            .cloned()
            .or(headers_pseudo_order)
            && !order.is_empty()
        {
            pseudo.order = order;
        }
        pseudo.sensitivity = extensions
            .get_ref::<PseudoHeaderSensitivity>()
            .copied()
            .unwrap_or_default();
        host_as_authority(&mut pseudo, &mut headers, ordinary_connect)?;
        // An asterisk URI holds neither scheme nor authority: a decoder keeps the scheme beside
        // the request and the authority as `Host`. The target's authority is that `Host`
        // (RFC 9112 §3.3), so it is sent as `:authority` (RFC 9113 §8.3.1), as on HTTP/3.
        if uri.is_asterisk() {
            if pseudo.scheme.is_none()
                && let Some(scheme) = extensions.get_ref::<rama_net::Protocol>()
            {
                pseudo.set_scheme(scheme);
            }
            if pseudo.authority.is_none()
                && let OutgoingHost::Usable(host, _) = outgoing_host(&headers)
                && let Ok(value) = BytesStr::try_from(Bytes::copy_from_slice(host.as_bytes()))
            {
                let sensitive = host.is_sensitive();
                pseudo.set_authority(value);
                if sensitive {
                    pseudo
                        .sensitivity
                        .set_sensitive(PseudoHeader::Authority, true);
                }
            }
        }

        if pseudo.scheme.is_none() {
            // If the scheme is not set, then there are a two options.
            //
            // 1) Authority is not set. In this case, a request was issued with
            //    a relative URI. This is permitted **only** when forwarding
            //    HTTP 1.x requests. If the HTTP version is set to 2.0, then
            //    this is an error.
            //
            // 2) Authority is set, then the HTTP method *must* be CONNECT.
            //
            // It is not possible to have a scheme but not an authority set (the
            // `http` crate does not allow it).
            //
            if pseudo.authority.is_none() {
                if version == Version::HTTP_2 {
                    return Err(UserError::MissingUriSchemeAndAuthority.into());
                } else {
                    // This is acceptable as per the above comment. However,
                    // HTTP/2 requires that a scheme is set. Since we are
                    // forwarding an HTTP 1.1 request, the scheme is set to
                    // "http".
                    pseudo.set_scheme(&rama_net::Protocol::HTTP);
                }
            } else if !is_connect {
                // TODO: Error
            }
        }

        // Create the HEADERS frame
        let mut frame = Headers::new(id, pseudo, headers, headers_priority);

        if end_of_stream {
            frame.set_end_stream()
        }

        Ok((frame, extensions))
    }
}

impl proto::Peer for Peer {
    type Poll = Response<()>;

    const NAME: &'static str = "Client";

    fn r#dyn() -> proto::DynPeer {
        proto::DynPeer::Client
    }

    /*
    fn is_server() -> bool {
        false
    }
    */

    fn convert_poll_message(
        pseudo: Pseudo,
        fields: HeaderMap,
        header_size: usize,
        stream_id: StreamId,
        extensions: Extensions,
    ) -> Result<Self::Poll, Error> {
        let mut b = Response::builder_with_extensions(extensions);

        b = b.version(Version::HTTP_2);

        if let Some(status) = pseudo.status {
            b = b.status(status);
        } else {
            // Every response must include :status (RFC 9113, section 8.3.2).
            // https://www.rfc-editor.org/rfc/rfc9113.html#section-8.3.2
            proto_err!(stream: "missing :status; stream={:?}", stream_id);
            return Err(Error::library_reset(stream_id, Reason::PROTOCOL_ERROR));
        }

        let Ok(mut response) = b.body(()) else {
            // TODO: Should there be more specialized handling for different
            // kinds of errors
            return Err(Error::library_reset(stream_id, Reason::PROTOCOL_ERROR));
        };

        if !pseudo.order.is_empty() {
            response.extensions().insert(pseudo.order);
        }
        if pseudo.sensitivity != PseudoHeaderSensitivity::default() {
            response.extensions().insert(pseudo.sensitivity);
        }

        response.extensions().insert(HeaderByteLength(header_size));

        *response.headers_mut() = fields;

        Ok(response)
    }
}

#[cfg(test)]
mod pseudo_sensitivity_tests {
    use super::*;
    use rama_http_types::{StatusCode, proto::h2::PseudoHeader};

    #[test]
    fn a_host_naming_another_authority_is_the_http2_authority() {
        for (uri, host, expected) in [
            ("https://example.com/", "other.example", "other.example"),
            ("https://example.com/", "EXAMPLE.com:443", "EXAMPLE.com:443"),
            ("https://example.com/", "EXAMPLE.com", "EXAMPLE.com"),
            // A Host cannot carry userinfo, so it never replaces the projection then.
            ("ftp://user@example.com/", "example.com", "user@example.com"),
            ("https://example.com/", "user@other.example", "example.com"),
        ] {
            let mut request = Request::builder().uri(uri).body(()).unwrap();
            let mut value = rama_http_types::HeaderValue::from_static(host);
            value.set_sensitive(true);
            request
                .headers_mut()
                .insert(rama_http_types::header::HOST, value);
            let (frame, _) =
                Peer::convert_send_message(StreamId::from(1), request, None, true, None, None)
                    .unwrap();
            assert_eq!(
                frame.pseudo().authority.as_deref(),
                Some(expected),
                "{uri} {host}"
            );
            assert_eq!(
                frame
                    .pseudo()
                    .sensitivity
                    .is_sensitive(PseudoHeader::Authority),
                expected == host,
                "{uri} {host}"
            );
        }
    }

    #[test]
    fn host_only_request_keeps_sensitive_host_without_synthesizing_authority() {
        let mut request = Request::builder().uri("/").body(()).unwrap();
        let mut host = rama_http_types::HeaderValue::from_static("example.com");
        host.set_sensitive(true);
        request
            .headers_mut()
            .insert(rama_http_types::header::HOST, host);
        let (frame, _) =
            Peer::convert_send_message(StreamId::from(1), request, None, true, None, None).unwrap();
        assert!(frame.pseudo().authority.is_none());
        assert!(frame.fields()[rama_http_types::header::HOST].is_sensitive());
    }

    #[test]
    fn response_retains_pseudo_sensitivity_in_both_directions() {
        let mut pseudo = Pseudo::response(StatusCode::OK);
        pseudo.sensitivity.set_sensitive(PseudoHeader::Status, true);
        let response = <Peer as proto::Peer>::convert_poll_message(
            pseudo,
            HeaderMap::new(),
            0,
            StreamId::from(1),
            Extensions::new(),
        )
        .unwrap();
        assert!(
            response
                .extensions()
                .get_ref::<PseudoHeaderSensitivity>()
                .unwrap()
                .is_sensitive(PseudoHeader::Status)
        );
        let (frame, _) =
            crate::h2::server::Peer::convert_send_message(StreamId::from(1), response, true);
        assert!(
            frame
                .pseudo()
                .sensitivity
                .is_sensitive(PseudoHeader::Status)
        );
    }
}

#[cfg(test)]
mod observation_tests {
    use super::*;
    use rama_core::ServiceInput;
    use rama_utils::octets::kib;
    use tokio::io::AsyncWriteExt;

    #[tokio::test]
    async fn peer_settings_wire_order_requires_explicit_client_opt_in() {
        for enabled in [false, true] {
            let (client_io, mut server_io) = tokio::io::duplex(kib(16));
            let mut builder = Builder::new();
            builder.set_observe_peer_settings(enabled);
            let (sender, connection) = builder
                .handshake::<_, Bytes>(ServiceInput::new(client_io))
                .await
                .unwrap();
            // Unknown, known, duplicate unknown: all three occurrences are observable.
            let frame = [
                0, 0, 18, 4, 0, 0, 0, 0, 0, 0xfe, 0xfe, 0, 0, 0, 7, 0, 1, 0, 0, 16, 0, 0xfe, 0xfe,
                0, 0, 0, 8,
            ];
            server_io.write_all(&frame).await.unwrap();
            let peer = tokio::time::timeout(Duration::from_secs(5), async {
                tokio::select! {
                    peer = sender.await_peer_initial_settings() => peer.unwrap(),
                    result = connection => panic!("connection ended before peer settings: {result:?}"),
                }
            }).await.unwrap();
            assert_eq!(peer.0.config.header_table_size, Some(4096));
            assert_eq!(peer.0.config.setting_order.is_some(), enabled);
            assert_eq!(peer.0.observation.is_some(), enabled);
            if let Some(wire) = &peer.0.observation {
                assert!(wire.complete);
                assert_eq!(
                    wire.entries
                        .iter()
                        .map(|entry| (u16::from(entry.id), entry.value))
                        .collect::<Vec<_>>(),
                    [(0xfefe, 7), (1, 4096), (0xfefe, 8)]
                );
            }
        }
    }
}
