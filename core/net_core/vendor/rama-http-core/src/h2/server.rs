//! Server implementation of the HTTP/2 protocol.
//!
//! # Getting started
//!
//! Running an HTTP/2 server requires the caller to manage accepting the
//! connections as well as getting the connections to a state that is ready to
//! begin the HTTP/2 handshake. See [here](../index.html#handshake) for more
//! details.
//!
//! This could be as basic as using Tokio's [`TcpListener`] to accept
//! connections, but usually it means using either ALPN or HTTP/1.1 protocol
//! upgrades.
//!
//! Once a connection is obtained, it is passed to [`handshake`],
//! which will begin the [HTTP/2 handshake]. This returns a future that
//! completes once the handshake process is performed and HTTP/2 streams may
//! be received.
//!
//! [`handshake`] uses default configuration values. There are a number of
//! settings that can be changed by using [`Builder`] instead.
//!
//! # Inbound streams
//!
//! The [`Connection`] instance is used to accept inbound HTTP/2 streams. It
//! does this by implementing [`rama_core::futures::Stream`]. When a new stream is
//! received, a call to [`Connection::accept`] will return `(request, response)`.
//! The `request` handle (of type [`http::Request<RecvStream>`]) contains the
//! HTTP request head as well as provides a way to receive the inbound data
//! stream and the trailers. The `response` handle (of type [`SendResponse`])
//! allows responding to the request, stream the response payload, send
//! trailers, and send push promises.
//!
//! The send ([`SendStream`]) and receive ([`RecvStream`]) halves of the stream
//! can be operated independently.
//!
//! # Managing the connection
//!
//! The [`Connection`] instance is used to manage connection state. The caller
//! is required to call either [`Connection::accept`] or
//! [`Connection::poll_close`] in order to advance the connection state. Simply
//! operating on [`SendStream`] or [`RecvStream`] will have no effect unless the
//! connection state is advanced.
//!
//! It is not required to call **both** [`Connection::accept`] and
//! [`Connection::poll_close`]. If the caller is ready to accept a new stream,
//! then only [`Connection::accept`] should be called. When the caller **does
//! not** want to accept a new stream, [`Connection::poll_close`] should be
//! called.
//!
//! The [`Connection`] instance should only be dropped once
//! [`Connection::poll_close`] returns `Ready`. Once [`Connection::accept`]
//! returns `Ready(None)`, there will no longer be any more inbound streams. At
//! this point, only [`Connection::poll_close`] should be called.
//!
//! # Shutting down the server
//!
//! Graceful shutdown of the server is [not yet
//! implemented](https://github.com/hyperium/h2/issues/69).
//!
//! # Example
//!
//! A basic HTTP/2 server example that runs over TCP and assumes [prior
//! knowledge], i.e. both the client and the server assume that the TCP socket
//! will use the HTTP/2 protocol without prior negotiation.
//!
//! ```no_run
//! use rama_core::ServiceInput;
//! use rama_http_core::h2::server;
//! use rama_http_types::{Response, StatusCode};
//! use tokio::net::TcpListener;
//!
//! #[tokio::main]
//! pub async fn main() {
//!     let mut listener = TcpListener::bind("127.0.0.1:5928").await.unwrap();
//!
//!     // Accept all incoming TCP connections.
//!     loop {
//!         if let Ok((socket, _peer_addr)) = listener.accept().await {
//!             // Convert socket to a rama compatible socket (one that implements ExtensionsRef)
//!             let socket = ServiceInput::new(socket);
//!             // Spawn a new task to process each connection.
//!             tokio::spawn(async {
//!                 // Start the HTTP/2 connection handshake
//!                 let mut h2 = server::handshake(socket).await.unwrap();
//!                 // Accept all inbound HTTP/2 streams sent over the
//!                 // connection.
//!                 while let Some(request) = h2.accept().await {
//!                     let (request, mut respond) = request.unwrap();
//!                     println!("Received request: {:?}", request);
//!
//!                     // Build a response with no body
//!                     let response = Response::builder()
//!                         .status(StatusCode::OK)
//!                         .body(())
//!                         .unwrap();
//!
//!                     // Send the response back to the client
//!                     respond.send_response(response, true)
//!                         .unwrap();
//!                 }
//!
//!             });
//!         }
//!     }
//! }
//! ```
//!
//! [prior knowledge]: http://httpwg.org/specs/rfc7540.html#known-http
//! [`handshake`]: fn.handshake.html
//! [HTTP/2 handshake]: http://httpwg.org/specs/rfc7540.html#ConnectionHeader
//! [`Builder`]: struct.Builder.html
//! [`Connection`]: struct.Connection.html
//! [`Connection::poll`]: struct.Connection.html#method.poll
//! [`Connection::poll_close`]: struct.Connection.html#method.poll_close
//! [`rama_core::futures::Stream`]: https://docs.rs/rama-core/latest/rama_core/futures/stream/trait.Stream.html
//! [`http::Request<RecvStream>`]: ../struct.RecvStream.html
//! [`RecvStream`]: ../struct.RecvStream.html
//! [`SendStream`]: ../struct.SendStream.html
//! [`TcpListener`]: https://docs.rs/tokio-core/0.1/tokio_core/net/struct.TcpListener.html

use crate::h2::codec::{Codec, UserError};
use crate::h2::proto::{self, Config, Error, Prioritized};
use crate::h2::{FlowControl, PingPong, RecvStream, SendStream};
use crate::proto::target::{
    AsteriskHostError, asterisk_host, normalize_received, received_authority, several_hosts,
};
use crate::server::conn::timeout::Activity;

use rama_core::bytes::{Buf, Bytes, BytesMut};
use rama_core::extensions::{Extensions, ExtensionsRef};
use rama_core::telemetry::tracing::warn;
use rama_core::telemetry::tracing::{
    self,
    instrument::{Instrument, Instrumented},
};
use rama_core::{futures::StreamExt as _, io::rewind::Rewind};
use rama_http::proto::HeaderByteLength;
use rama_http::proto::h2::frame::EarlyFrameStreamContext;
use rama_http_types::conn::H2SettingsLimits;
use rama_http_types::proto::h2::alt_svc::AltSvcSendError;
use rama_http_types::proto::h2::frame::{
    self, Pseudo, PushPromiseHeaderError, Reason, Settings, StreamId,
};
use rama_http_types::proto::{
    ext,
    h2::{PseudoHeader, PseudoHeaderOrder, PseudoHeaderSensitivity},
};
use rama_http_types::{HeaderMap, Method, Request, Response, StatusCode, Version};
use rama_net::extensions::StreamTransformed;
use rama_net::uri;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;
use std::{fmt, io};
use tokio::{
    io::{AsyncRead, AsyncReadExt as _, AsyncWrite, ReadBuf},
    time::Instant,
};

/// In progress HTTP/2 connection handshake future.
///
/// This type implements `Future`, yielding a `Connection` instance once the
/// handshake has completed.
///
/// The handshake is completed once the connection preface is fully received
/// from the client **and** the initial settings frame is sent to the client.
///
/// The handshake future does not wait for the initial settings frame from the
/// client.
///
/// See [module] level docs for more details.
///
/// [module]: index.html
#[must_use = "futures do nothing unless polled"]
pub struct Handshake<T, B: Buf = Bytes> {
    /// The config to pass to Connection::new after handshake succeeds.
    builder: Builder,
    /// The current state of the handshake.
    state: Handshaking<T, B>,
    /// When the initial SETTINGS were flushed.
    settings_sent_at: Option<Instant>,
    /// Span tracking the handshake
    span: tracing::Span,
}

/// Accepts inbound HTTP/2 streams on a connection.
///
/// A `Connection` is backed by an I/O resource (usually a TCP socket) and
/// implements the HTTP/2 server logic for that connection. It is responsible
/// for receiving inbound streams initiated by the client as well as driving the
/// internal state forward.
///
/// `Connection` values are created by calling [`handshake`]. Once a
/// `Connection` value is obtained, the caller must call [`poll`] or
/// [`poll_close`] in order to drive the internal connection state forward.
///
/// See [module level] documentation for more details
///
/// [module level]: index.html
/// [`handshake`]: struct.Connection.html#method.handshake
/// [`poll`]: struct.Connection.html#method.poll
/// [`poll_close`]: struct.Connection.html#method.poll_close
///
/// # Examples
///
/// ```
/// # use tokio::io::{AsyncRead, AsyncWrite};
/// # use rama_http_core::h2::server;
/// # use rama_http_core::h2::server::*;
/// # use rama_core::extensions::ExtensionsRef;
/// #
/// # async fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T) {
/// let mut server = server::handshake(my_io).await.unwrap();
/// while let Some(request) = server.accept().await {
///     tokio::spawn(async move {
///         let (request, respond) = request.unwrap();
///         // Process the request and send the response back to the client
///         // using `respond`.
///     });
/// }
/// # }
/// #
/// # pub fn main() {}
/// ```
#[must_use = "streams do nothing unless polled"]
pub struct Connection<T, B: Buf> {
    connection: proto::Connection<T, Peer, B>,
}

/// Builds server connections with custom configuration values.
///
/// Methods can be chained in order to set the configuration values.
///
/// The server is constructed by calling [`handshake`] and passing the I/O
/// handle that will back the HTTP/2 server.
///
/// New instances of `Builder` are obtained via [`Builder::new`].
///
/// See function level documentation for details on the various server
/// configuration settings.
///
/// [`Builder::new`]: struct.Builder.html#method.new
/// [`handshake`]: struct.Builder.html#method.handshake
///
/// # Examples
///
/// ```
/// # use tokio::io::{AsyncRead, AsyncWrite};
/// # use rama_http_core::h2::server::*;
/// # use rama_core::extensions::ExtensionsRef;
/// #
/// # fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
/// # -> Handshake<T>
/// # {
/// // `server_fut` is a future representing the completion of the HTTP/2
/// // handshake.
/// let server_fut = Builder::new()
///     .with_initial_window_size(1_000_000)
///     .with_max_concurrent_streams(1000)
///     .handshake(my_io);
/// # server_fut
/// # }
/// #
/// # pub fn main() {}
/// ```
#[derive(Clone, Debug)]
pub struct Builder {
    /// Time to keep locally reset streams around before reaping.
    reset_stream_duration: Duration,

    /// Whether application handlers can emit ALTSVC frames.
    send_alt_svc: bool,

    observe_early_frames: bool,

    /// Maximum number of locally reset streams to keep at a time.
    reset_stream_max: usize,

    /// Maximum number of remotely reset streams to allow in the pending
    /// accept queue.
    pending_accept_reset_stream_max: usize,

    /// Initial `Settings` frame to send as part of the handshake.
    initial_settings: Option<Arc<Settings>>,
    settings: Settings,

    /// Initial target window size for new connections.
    initial_target_connection_window_size: Option<u32>,

    /// Maximum amount of bytes to "buffer" for writing per stream.
    max_send_buffer_size: u32,

    /// Maximum number of locally reset streams due to protocol error across
    /// the lifetime of the connection.
    ///
    /// When this gets exceeded, we issue GOAWAYs.
    local_max_error_reset_streams: Option<usize>,

    /// connection-level budget for DATA framing overhead.
    ///
    /// When this gets exhausted, we issue a GOAWAY with `ENHANCE_YOUR_CALM`.
    data_frame_budget: proto::DataFrameBudget,
}

/// Send a response back to the client
///
/// A `SendResponse` instance is provided when receiving a request and is used
/// to send the associated response back to the client. It is also used to
/// explicitly reset the stream with a custom reason.
///
/// It will also be used to initiate push promises linked with the associated
/// stream.
///
/// If the `SendResponse` instance is dropped without sending a response, then
/// the HTTP/2 stream will be reset.
///
/// See [module] level docs for more details.
///
/// [module]: index.html
#[derive(Debug)]
pub struct SendResponse<B: Buf> {
    inner: proto::StreamRef<B>,
}

/// Send a response to a promised request
///
/// A `SendPushedResponse` instance is provided when promising a request and is used
/// to send the associated response to the client. It is also used to
/// explicitly reset the stream with a custom reason.
///
/// It can not be used to initiate push promises.
///
/// If the `SendPushedResponse` instance is dropped without sending a response, then
/// the HTTP/2 stream will be reset.
///
/// See [module] level docs for more details.
///
/// [module]: index.html
pub struct SendPushedResponse<B: Buf> {
    inner: SendResponse<B>,
}

// Manual implementation necessary because of rust-lang/rust#26925
impl<B: Buf + fmt::Debug> fmt::Debug for SendPushedResponse<B> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "SendPushedResponse {{ {:?} }}", self.inner)
    }
}

/// Stages of an in-progress handshake.
enum Handshaking<T, B: Buf> {
    Failed(Option<crate::h2::Error>),
    /// State 1. Connection is flushing pending SETTINGS frame.
    Flushing(Instrumented<Flush<T, Prioritized<B>>>),
    /// State 2. Connection is waiting for the client preface.
    ReadingPreface(Instrumented<ReadPreface<T, Prioritized<B>>>),
    /// State 3. Handshake is done, polling again would panic.
    Done,
}

/// Flush a Sink
struct Flush<T, B> {
    codec: Option<Codec<T, B>>,
}

/// Read the client connection preface
struct ReadPreface<T, B> {
    codec: Option<Codec<T, B>>,
    pos: usize,
}

#[derive(Debug)]
pub(crate) struct Peer;

const PREFACE: [u8; 24] = *b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

fn valid_preface_part(offset: usize, bytes: &[u8]) -> bool {
    PREFACE.get(offset..offset + bytes.len()) == Some(bytes)
}

/// What a client sent first on an H2 connection, before any server output.
#[derive(Debug, Clone)]
#[non_exhaustive]
pub struct ClientInitialFrames {
    /// The client's initial SETTINGS, in wire order.
    pub settings: Settings,
    /// The increment of a connection WINDOW_UPDATE read together with SETTINGS
    /// and directly following it, the client's initial connection credit.
    pub connection_window_increment: Option<u32>,
}

/// Inspect only a client's mandatory H2 prefix without emitting server bytes.
///
/// A different protocol returns None and rewinds every consumed byte. An H2
/// client must send its initial SETTINGS before waiting for server output, so
/// this never waits for request HEADERS or a WINDOW_UPDATE. The caller owns the
/// overall deadline. Native framing/settings validation and bounded observation
/// are reused here.
pub async fn inspect_client_initial_settings<T>(
    mut io: T,
) -> Result<(Rewind<T>, Option<ClientInitialFrames>), crate::h2::Error>
where
    T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef,
{
    let mut prefix = [0; PREFACE.len()];
    let mut received = 0;
    while received != prefix.len() {
        let count = io
            .read(&mut prefix[received..])
            .await
            .map_err(crate::h2::Error::from_io)?;
        if count == 0 {
            return Err(crate::h2::Error::from_io(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "incomplete client preface",
            )));
        }
        if !valid_preface_part(received, &prefix[received..received + count]) {
            return Ok((
                Rewind::new_buffered(io, Bytes::copy_from_slice(&prefix[..received + count])),
                None,
            ));
        }
        received += count;
    }
    let mut header = [0; frame::HEADER_LEN];
    io.read_exact(&mut header)
        .await
        .map_err(crate::h2::Error::from_io)?;
    let head = frame::Head::parse(&header).map_err(|error| {
        tracing::debug!(?error, "invalid initial HTTP/2 SETTINGS framing or literal");
        crate::h2::Error::from(Reason::PROTOCOL_ERROR)
    })?;
    if head.kind() != frame::Kind::Settings || !head.stream_id().is_zero() {
        return Err(Reason::PROTOCOL_ERROR.into());
    }
    // Let the existing Codec handle length bounds, flags, values and observation.
    let mut codec = Codec::<_, Bytes>::new(Rewind::new_buffered(
        &mut io,
        Bytes::copy_from_slice(&header),
    ));
    codec.set_observe_early_frames(true);
    let Some(frame::Frame::Settings(settings)) = codec.next().await.transpose()? else {
        return Err(Reason::PROTOCOL_ERROR.into());
    };
    let settings = settings.to_literal().map_err(|error| {
        tracing::debug!(?error, "invalid initial HTTP/2 SETTINGS framing or literal");
        crate::h2::Error::from(Reason::PROTOCOL_ERROR)
    })?;
    let read_ahead = codec.into_read_buffer();
    let connection_window_increment = buffered_connection_window_update(&read_ahead);
    let mut encoded = BytesMut::new();
    settings.encode(&mut encoded);
    let mut rewind = BytesMut::with_capacity(prefix.len() + encoded.len() + read_ahead.len());
    rewind.extend_from_slice(&prefix);
    // Preserve ignored flags as well as the literal ordered setting payload.
    rewind.extend_from_slice(&header);
    rewind.extend_from_slice(&encoded[frame::HEADER_LEN..]);
    rewind.extend_from_slice(&read_ahead);
    Ok((
        Rewind::new_buffered(io, rewind.freeze()),
        Some(ClientInitialFrames {
            settings,
            connection_window_increment,
        }),
    ))
}

/// The increment of a complete stream-0 WINDOW_UPDATE at the start of `buffered`.
fn buffered_connection_window_update(buffered: &[u8]) -> Option<u32> {
    let header = buffered.get(..frame::HEADER_LEN)?;
    let head = frame::Head::parse(header).ok()?;
    let payload = buffered.get(frame::HEADER_LEN..frame::HEADER_LEN + 4)?;
    if head.kind() != frame::Kind::WindowUpdate
        || !head.stream_id().is_zero()
        || header[..3] != [0, 0, 4]
    {
        return None;
    }
    // The reserved bit is ignored (RFC 9113 §6.9); a zero increment is an error the
    // native connection reports itself, so it is not credit to mirror.
    let increment = u32::from_be_bytes(payload.try_into().ok()?) & 0x7fff_ffff;
    (increment != 0).then_some(increment)
}

/// Creates a new configured HTTP/2 server with default configuration
/// values backed by `io`.
///
/// It is expected that `io` already be in an appropriate state to commence
/// the [HTTP/2 handshake]. See [Handshake] for more details.
///
/// Returns a future which resolves to the [`Connection`] instance once the
/// HTTP/2 handshake has been completed. The returned [`Connection`]
/// instance will be using default configuration values. Use [`Builder`] to
/// customize the configuration values used by a [`Connection`] instance.
///
/// [HTTP/2 handshake]: http://httpwg.org/specs/rfc7540.html#ConnectionHeader
/// [Handshake]: ../index.html#handshake
/// [`Connection`]: struct.Connection.html
///
/// # Examples
///
/// ```
/// # use tokio::io::{AsyncRead, AsyncWrite};
/// # use rama_http_core::h2::server;
/// # use rama_http_core::h2::server::*;
/// # use rama_core::extensions::ExtensionsRef;
/// #
/// # async fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
/// # {
/// let connection = server::handshake(my_io).await.unwrap();
/// // The HTTP/2 handshake has completed, now use `connection` to
/// // accept inbound HTTP/2 streams.
/// # }
/// #
/// # pub fn main() {}
/// ```
pub fn handshake<T>(io: T) -> Handshake<T, Bytes>
where
    T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef,
{
    Builder::new().handshake(io)
}

// ===== impl Connection =====

impl<T, B> Connection<T, B>
where
    T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef,
    B: Buf,
{
    /// Queue a bounded, connection-local alternative-service advertisement.
    ///
    /// Enable this with [`Builder::with_alt_svc`] before the handshake.
    /// Stream zero requires an explicit origin; request-stream frames must
    /// omit it and identify the request whose origin is being advertised.
    /// The caller supplies that association; this low-level API does not infer it.
    /// The connection must continue being polled to transmit the frame.
    pub fn send_alt_svc(&self, frame: frame::AltSvc) -> Result<(), AltSvcSendError> {
        self.connection.send_alt_svc(frame)
    }

    fn handshake2(io: T, mut builder: Builder) -> Handshake<T, B> {
        let span = tracing::trace_span!("server_handshake");
        let entered = span.enter();

        io.extensions().insert(StreamTransformed {
            by: "rama-http-core::h2::server",
        });

        let mut advertised = None;
        if let Some(exact) = &builder.initial_settings {
            match exact.to_literal() {
                Ok(settings)
                    if settings.config.enable_push.is_none_or(|value| value == 0)
                        && io
                            .extensions()
                            .get_ref::<H2SettingsLimits>()
                            .is_none_or(|limits| limits.validate(&settings).is_ok()) =>
                {
                    builder.settings =
                        proto::with_local_caps(settings.clone(), &builder.settings.config);
                    advertised = Some(settings);
                }
                _ => {
                    return Handshake {
                        builder,
                        state: Handshaking::Failed(Some(Reason::PROTOCOL_ERROR.into())),
                        settings_sent_at: None,
                        span: span.clone(),
                    };
                }
            }
        }

        // Create the codec.
        let mut codec = Codec::new(io);
        // ALTSVC is a server-to-client extension, never input to a server.
        codec.set_recv_alt_svc(false);
        codec.set_observe_early_frames(builder.observe_early_frames);

        if let Some(max) = builder.settings.config.max_frame_size {
            codec.set_max_recv_frame_size(max as usize);
        }

        if let Some(max) = builder.settings.config.max_header_list_size {
            codec.set_max_recv_header_list_size(max as usize);
        }

        // Send initial settings frame.
        let advertised = advertised.unwrap_or_else(|| builder.settings.clone());
        if let Err(err) = codec.buffer(advertised.into()) {
            warn!(
                "h2 server: invalid SETTINGS frame: failed to buffer: {err}; continue regardless (report bug in rama)"
            );
        }

        // Create the handshake future.
        let state =
            Handshaking::Flushing(Flush::new(codec).instrument(tracing::trace_span!("flush")));

        drop(entered);

        Handshake {
            builder,
            state,
            settings_sent_at: None,
            span,
        }
    }

    /// Accept the next incoming request on this connection.
    pub async fn accept(
        &mut self,
    ) -> Option<Result<(Request<RecvStream>, SendResponse<B>), crate::h2::Error>> {
        crate::h2::poll_fn(move |cx| self.poll_accept(cx)).await
    }

    pub(crate) fn timeout_activity(&self) -> Activity {
        self.connection.timeout_activity()
    }

    /// The round trip of the initial SETTINGS, once, when their ACK arrived.
    pub(crate) fn take_settings_rtt(&mut self) -> Option<Duration> {
        self.connection.take_settings_rtt()
    }

    #[doc(hidden)]
    pub fn poll_accept(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<(Request<RecvStream>, SendResponse<B>), crate::h2::Error>>> {
        // Always try to advance the internal state. Getting Pending also is
        // needed to allow this function to return Pending.
        if self.poll_closed(cx)?.is_ready() {
            // If the socket is closed, don't return anything
            // TODO: drop any pending streams
            return Poll::Ready(None);
        }

        if let Some(inner) = self.connection.next_incoming() {
            tracing::trace!("received incoming");
            let (head, _) = inner.take_request().into_parts();
            let body = RecvStream::new(FlowControl::new(inner.clone_to_opaque()));

            let request = Request::from_parts(head, body);
            let respond = SendResponse { inner };

            return Poll::Ready(Some(Ok((request, respond))));
        }

        Poll::Pending
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
        /// # Errors
        ///
        /// Returns an error if the given size is invalid.
        ///
        /// See [`FlowControl`] documentation for more details.
        ///
        /// [`FlowControl`]: ../struct.FlowControl.html
        /// [library level]: ../index.html#flow-control
        pub fn target_window_size(mut self, size: u32) -> Result<Self, crate::h2::Error> {
            if size > proto::MAX_WINDOW_SIZE {
                return Err(UserError::InvalidSettingValue.into());
            }
            self.connection.try_set_target_window_size(size)?;
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
                return Err(UserError::InvalidSettingValue.into());
            }
            self.connection.try_set_initial_window_size(size)?;
            Ok(self)
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Enables the [extended CONNECT protocol].
        ///
        /// [extended CONNECT protocol]: https://datatracker.ietf.org/doc/html/rfc8441#section-4
        ///
        /// # Errors
        ///
        /// Returns an error if a previous call is still pending acknowledgement
        /// from the remote endpoint.
        pub fn enable_connect_protocol(mut self) -> Result<Self, crate::h2::Error> {
            self.connection.try_set_enable_connect_protocol()?;
            Ok(self)
        }
    }

    /// Returns `Ready` when the underlying connection has closed.
    ///
    /// If any new inbound streams are received during a call to `poll_closed`,
    /// they will be queued and returned on the next call to [`poll_accept`].
    ///
    /// This function will advance the internal connection state, driving
    /// progress on all the other handles (e.g. [`RecvStream`] and [`SendStream`]).
    ///
    /// See [here](index.html#managing-the-connection) for more details.
    ///
    /// [`poll_accept`]: struct.Connection.html#method.poll_accept
    /// [`RecvStream`]: ../struct.RecvStream.html
    /// [`SendStream`]: ../struct.SendStream.html
    pub fn poll_closed(&mut self, cx: &mut Context) -> Poll<Result<(), crate::h2::Error>> {
        self.connection.poll(cx).map_err(Into::into)
    }

    /// Sets the connection to a GOAWAY state.
    ///
    /// Does not terminate the connection. Must continue being polled to close
    /// connection.
    ///
    /// After flushing the GOAWAY frame, the connection is closed. Any
    /// outstanding streams do not prevent the connection from closing. This
    /// should usually be reserved for shutting down when something bad
    /// external to `h2` has happened, and open streams cannot be properly
    /// handled.
    ///
    /// For graceful shutdowns, see [`graceful_shutdown`](Connection::graceful_shutdown).
    pub fn abrupt_shutdown(&mut self, reason: Reason) {
        self.connection.go_away_from_user(reason);
    }

    /// Starts a [graceful shutdown][1] process.
    ///
    /// Must continue being polled to close connection.
    ///
    /// It's possible to receive more requests after calling this method, since
    /// they might have been in-flight from the client already. After about
    /// 1 RTT, no new requests should be accepted. Once all active streams
    /// have completed, the connection is closed.
    ///
    /// [1]: http://httpwg.org/specs/rfc7540.html#GOAWAY
    pub fn graceful_shutdown(&mut self) {
        self.connection.go_away_gracefully();
    }

    /// Takes a `PingPong` instance from the connection.
    ///
    /// # Note
    ///
    /// This may only be called once. Calling multiple times will return `None`.
    pub fn ping_pong(&mut self) -> Option<PingPong> {
        self.connection.take_user_pings().map(PingPong::new)
    }

    /// Checks if there are any streams
    pub fn has_streams(&self) -> bool {
        self.connection.has_streams()
    }

    /// Returns the maximum number of concurrent streams that may be initiated
    /// by the server on this connection.
    ///
    /// This limit is configured by the client peer by sending the
    /// [`SETTINGS_MAX_CONCURRENT_STREAMS` parameter][1] in a `SETTINGS` frame.
    /// This method returns the currently acknowledged value received from the
    /// remote.
    ///
    /// [1]: https://tools.ietf.org/html/rfc7540#section-5.1.2
    pub fn max_concurrent_send_streams(&self) -> usize {
        self.connection.max_send_streams()
    }

    /// Returns the maximum number of concurrent streams that may be initiated
    /// by the client on this connection.
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
        self.connection.max_recv_streams()
    }

    // Could disappear at anytime.
    #[doc(hidden)]
    #[cfg(feature = "unstable")]
    #[cfg_attr(docsrs, doc(cfg(feature = "unstable")))]
    pub fn num_wired_streams(&self) -> usize {
        self.connection.num_wired_streams()
    }
}

impl<T, B> rama_core::futures::Stream for Connection<T, B>
where
    T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef,
    B: Buf,
{
    type Item = Result<(Request<RecvStream>, SendResponse<B>), crate::h2::Error>;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        self.poll_accept(cx)
    }
}

impl<T, B> fmt::Debug for Connection<T, B>
where
    T: fmt::Debug,
    B: fmt::Debug + Buf,
{
    fn fmt(&self, fmt: &mut fmt::Formatter) -> fmt::Result {
        fmt.debug_struct("Connection")
            .field("connection", &self.connection)
            .finish()
    }
}

// ===== impl Builder =====

impl Builder {
    /// Returns a new server builder instance initialized with default
    /// configuration values.
    ///
    /// Configuration methods can be chained on the return value.
    ///
    /// # Examples
    ///
    /// ```
    /// # use tokio::io::{AsyncRead, AsyncWrite};
    /// # use rama_http_core::h2::server::*;
    /// # use rama_core::extensions::ExtensionsRef;
    /// #
    /// # fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
    /// # -> Handshake<T>
    /// # {
    /// // `server_fut` is a future representing the completion of the HTTP/2
    /// // handshake.
    /// let server_fut = Builder::new()
    ///     .with_initial_window_size(1_000_000)
    ///     .with_max_concurrent_streams(1000)
    ///     .handshake(my_io);
    /// # server_fut
    /// # }
    /// #
    /// # pub fn main() {}
    /// ```
    #[must_use]
    pub fn new() -> Self {
        Self {
            reset_stream_duration: Duration::from_secs(proto::DEFAULT_RESET_STREAM_SECS),
            send_alt_svc: false,
            observe_early_frames: false,
            reset_stream_max: proto::DEFAULT_RESET_STREAM_MAX,
            pending_accept_reset_stream_max: proto::DEFAULT_REMOTE_RESET_STREAM_MAX,
            initial_settings: None,
            settings: Settings::default(),
            initial_target_connection_window_size: None,
            max_send_buffer_size: proto::DEFAULT_MAX_SEND_BUFFER_SIZE,
            local_max_error_reset_streams: Some(proto::DEFAULT_LOCAL_RESET_COUNT_MAX),
            data_frame_budget: proto::DataFrameBudget::Auto,
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Replace the complete initial SETTINGS frame, validated before any write.
        /// A server frame must not advertise SETTINGS_ENABLE_PUSH.
        pub fn initial_settings(mut self, settings: Option<Arc<Settings>>) -> Self {
            self.initial_settings = settings;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Retain bounded early-frame observations for fingerprinting or preservation.
        /// Disabled by default; ordinary servers retain no optional capture data.
        pub fn observe_early_frames(mut self, enabled: bool) -> Self {
            self.observe_early_frames = enabled;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Enable bounded server-side ALTSVC frame emission.
        ///
        /// Disabled by default, so ordinary connections allocate no advertisement
        /// queue. When enabled, request extensions expose an `AltSvcSender`.
        pub fn alt_svc(mut self, enabled: bool) -> Self {
            self.send_alt_svc = enabled;
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
        /// # use rama_http_core::h2::server::*;
        /// # use rama_core::extensions::ExtensionsRef;
        /// #
        /// # fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
        /// # -> Handshake<T>
        /// # {
        /// // `server_fut` is a future representing the completion of the HTTP/2
        /// // handshake.
        /// let server_fut = Builder::new()
        ///     .with_initial_window_size(1_000_000)
        ///     .handshake(my_io);
        /// # server_fut
        /// # }
        /// #
        /// # pub fn main() {}
        /// ```
        pub fn initial_window_size(mut self, size: Option<u32>) -> Self {
            self.settings.config.initial_window_size = size;
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
        /// # use rama_http_core::h2::server::*;
        /// # use rama_core::extensions::ExtensionsRef;
        /// #
        /// # fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
        /// # -> Handshake<T>
        /// # {
        /// // `server_fut` is a future representing the completion of the HTTP/2
        /// // handshake.
        /// let server_fut = Builder::new()
        ///     .with_initial_connection_window_size(1_000_000)
        ///     .handshake(my_io);
        /// # server_fut
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
        /// configured server is able to accept.
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
        /// # use rama_http_core::h2::server::*;
        /// # use rama_core::extensions::ExtensionsRef;
        /// #
        /// # fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
        /// # -> Handshake<T>
        /// # {
        /// // `server_fut` is a future representing the completion of the HTTP/2
        /// // handshake.
        /// let server_fut = Builder::new()
        ///     .with_max_frame_size(1_000_000)
        ///     .handshake(my_io);
        /// # server_fut
        /// # }
        /// #
        /// # pub fn main() {}
        /// ```
        pub fn max_frame_size(mut self, max: Option<u32>) -> Self {
            self.settings.config.max_frame_size = max;
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
        /// # use rama_http_core::h2::server::*;
        /// # use rama_core::extensions::ExtensionsRef;
        /// #
        /// # fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
        /// # -> Handshake<T>
        /// # {
        /// // `server_fut` is a future representing the completion of the HTTP/2
        /// // handshake.
        /// let server_fut = Builder::new()
        ///     .with_max_header_list_size(16 * 1024)
        ///     .handshake(my_io);
        /// # server_fut
        /// # }
        /// #
        /// # pub fn main() {}
        /// ```
        pub fn max_header_list_size(mut self, max: Option<u32>) -> Self {
            self.settings.config.max_header_list_size = max;
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
        pub fn header_table_size(mut self, size: u32) ->Self {
            self.settings.config.header_table_size = Some(size);
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
        /// # use rama_http_core::h2::server::*;
        /// # use rama_core::extensions::ExtensionsRef;
        /// #
        /// # fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
        /// # -> Handshake<T>
        /// # {
        /// // `server_fut` is a future representing the completion of the HTTP/2
        /// // handshake.
        /// let server_fut = Builder::new()
        ///     .with_max_concurrent_streams(1000)
        ///     .handshake(my_io);
        /// # server_fut
        /// # }
        /// #
        /// # pub fn main() {}
        /// ```
        pub fn max_concurrent_streams(mut self, max: Option<u32>) -> Self {
            self.settings.config.max_concurrent_streams = max;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets the maximum number of concurrent locally reset streams.
        ///
        /// When a stream is explicitly reset by either calling
        /// [`SendResponse::send_reset`] or by dropping a [`SendResponse`] instance
        /// before completing the stream, the HTTP/2 specification requires that
        /// any further frames received for that stream must be ignored for "some
        /// time".
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
        /// # use rama_http_core::h2::server::*;
        /// # use rama_core::extensions::ExtensionsRef;
        /// #
        /// # fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
        /// # -> Handshake<T>
        /// # {
        /// // `server_fut` is a future representing the completion of the HTTP/2
        /// // handshake.
        /// let server_fut = Builder::new()
        ///     .with_max_concurrent_reset_streams(1000)
        ///     .handshake(my_io);
        /// # server_fut
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
        /// Sets the maximum number of local resets due to protocol errors made by the remote end.
        ///
        /// Invalid frames and many other protocol errors will lead to resets being generated for those streams.
        /// Too many of these often indicate a malicious client, and there are attacks which can abuse this to DOS servers.
        /// This limit protects against these DOS attacks by limiting the amount of resets we can be forced to generate.
        ///
        /// When the number of local resets exceeds this threshold, the server will issue GOAWAYs with an error code of
        /// `ENHANCE_YOUR_CALM` to the client.
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
        ///
        /// ```
        /// # use tokio::io::{AsyncRead, AsyncWrite};
        /// # use rama_http_core::h2::server::*;
        /// # use rama_core::extensions::ExtensionsRef;
        /// #
        /// # fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
        /// # -> Handshake<T>
        /// # {
        /// // `server_fut` is a future representing the completion of the HTTP/2
        /// // handshake.
        /// let server_fut = Builder::new()
        ///     .with_max_pending_accept_reset_streams(100)
        ///     .handshake(my_io);
        /// # server_fut
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
        /// Sets the maximum number of concurrent locally reset streams.
        ///
        /// When a stream is explicitly reset by either calling
        /// [`SendResponse::send_reset`] or by dropping a [`SendResponse`] instance
        /// before completing the stream, the HTTP/2 specification requires that
        /// any further frames received for that stream must be ignored for "some
        /// time".
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
        /// # use rama_http_core::h2::server::*;
        /// # use std::time::Duration;
        /// # use rama_core::extensions::ExtensionsRef;
        /// #
        /// # fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
        /// # -> Handshake<T>
        /// # {
        /// // `server_fut` is a future representing the completion of the HTTP/2
        /// // handshake.
        /// let server_fut = Builder::new()
        ///     .with_reset_stream_duration(Duration::from_secs(10))
        ///     .handshake(my_io);
        /// # server_fut
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
        /// Enables the [extended CONNECT protocol].
        ///
        /// [extended CONNECT protocol]: https://datatracker.ietf.org/doc/html/rfc8441#section-4
        pub fn enable_connect_protocol(mut self) -> Self {
            self.settings.config.enable_connect_protocol = Some(1);
            self
        }
    }

    /// Creates a new configured HTTP/2 server backed by `io`.
    ///
    /// It is expected that `io` already be in an appropriate state to commence
    /// the [HTTP/2 handshake]. See [Handshake] for more details.
    ///
    /// Returns a future which resolves to the [`Connection`] instance once the
    /// HTTP/2 handshake has been completed.
    ///
    /// This function also allows the caller to configure the send payload data
    /// type. See [Outbound data type] for more details.
    ///
    /// [HTTP/2 handshake]: http://httpwg.org/specs/rfc7540.html#ConnectionHeader
    /// [Handshake]: ../index.html#handshake
    /// [`Connection`]: struct.Connection.html
    /// [Outbound data type]: ../index.html#outbound-data-type.
    ///
    /// # Examples
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use tokio::io::{AsyncRead, AsyncWrite};
    /// # use rama_http_core::h2::server::*;
    /// # use rama_core::extensions::ExtensionsRef;
    /// #
    /// # fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
    /// # -> Handshake<T>
    /// # {
    /// // `server_fut` is a future representing the completion of the HTTP/2
    /// // handshake.
    /// let server_fut = Builder::new()
    ///     .handshake(my_io);
    /// # server_fut
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
    /// # use rama_http_core::h2::server::*;
    /// # use rama_core::extensions::ExtensionsRef;
    /// #
    /// # fn doc<T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef>(my_io: T)
    /// # -> Handshake<T, &'static [u8]>
    /// # {
    /// // `server_fut` is a future representing the completion of the HTTP/2
    /// // handshake.
    /// let server_fut: Handshake<_, &'static [u8]> = Builder::new()
    ///     .handshake(my_io);
    /// # server_fut
    /// # }
    /// #
    /// # pub fn main() {}
    /// ```
    pub fn handshake<T, B>(&self, io: T) -> Handshake<T, B>
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

// ===== impl SendResponse =====

impl<B: Buf> SendResponse<B> {
    /// Send an interim informational response (1xx status codes)
    ///
    /// This method can be called multiple times before calling `send_response()`
    /// to send the final response. Only 1xx status codes are allowed.
    ///
    /// Interim informational responses are used to provide early feedback to the client
    /// before the final response is ready. Common examples include:
    ///
    /// - 100 Continue: Indicates the client should continue with the request
    /// - 103 Early Hints: Provides early hints about resources to preload
    ///
    /// # Arguments
    ///
    /// * `response` - HTTP response with 1xx status code and headers
    ///
    /// # Returns
    ///
    /// * `Ok(())` - Interim Informational response sent successfully
    /// * `Err(Error)` - Failed to send (invalid status code, connection error, etc.)
    ///
    /// # Examples
    ///
    /// ```rust
    /// use rama_core::bytes;
    /// use rama_http_core::h2::{self, server};
    /// use rama_http_types::{Response, StatusCode};
    ///
    /// # async fn example(mut send_response: h2::server::SendResponse<bytes::Bytes>) -> Result<(), h2::Error> {
    /// // Send 100 Continue before processing request body
    /// let continue_response = Response::builder()
    ///     .status(StatusCode::CONTINUE)
    ///     .body(())
    ///     .unwrap();
    /// send_response.send_informational(continue_response)?;
    ///
    /// // Later send the final response
    /// let final_response = Response::builder()
    ///     .status(StatusCode::OK)
    ///     .body(())
    ///     .unwrap();
    /// let _stream = send_response.send_response(final_response, false)?;
    /// # Ok(())
    /// # }
    /// ```
    ///
    /// # Errors
    /// This method will return an error if:
    /// - The response status code is not in the 1xx range, or is 101
    /// - The final response has already been sent
    /// - There is a connection-level error
    pub fn send_informational(&mut self, response: Response<()>) -> Result<(), crate::h2::Error> {
        let stream_id = self.inner.stream_id();
        let status = response.status();

        tracing::trace!(
            "send_informational called with status: {} on stream: {:?}",
            status,
            stream_id
        );

        // Only a 1xx is informational, and HTTP/2 has no 101 (RFC 9113 §8.6).
        if !response.status().is_informational() || status == StatusCode::SWITCHING_PROTOCOLS {
            tracing::trace!(
                "invalid informational status code: {} on stream: {:?}",
                status,
                stream_id
            );

            return Err(crate::h2::Error::from(
                UserError::InvalidInformationalStatusCode,
            ));
        }

        tracing::trace!(
            "converting informational response to HEADERS frame without END_STREAM flag for stream: {:?}",
            stream_id
        );

        // NOTE: we are dropping extensions here for this frame... if not intended please fix
        let (frame, _extensions) = Peer::convert_send_message(
            stream_id, response, false, // NOT end_of_stream for informational responses
        );

        tracing::trace!(
            "sending interim informational headers frame for stream: {:?}",
            stream_id
        );

        // Use the proper H2 streams API for sending interim informational headers
        // This bypasses the normal response flow and allows multiple informational responses
        let result = self
            .inner
            .send_informational_headers(frame)
            .map_err(Into::into);

        match &result {
            Ok(()) => tracing::trace!(
                "Successfully sent informational headers for stream: {:?}",
                stream_id
            ),
            Err(e) => tracing::trace!(
                "Failed to send informational headers for stream: {:?}: {:?}",
                stream_id,
                e
            ),
        }

        result
    }

    /// Send a response to a client request.
    ///
    /// On success, a [`SendStream`] instance is returned. This instance can be
    /// used to stream the response body and send trailers.
    ///
    /// If a body or trailers will be sent on the returned [`SendStream`]
    /// instance, then `end_of_stream` must be set to `false` when calling this
    /// function.
    ///
    /// The [`SendResponse`] instance is already associated with a received
    /// request.  This function may only be called once per instance and only if
    /// [`send_reset`] has not been previously called.
    ///
    /// [`SendResponse`]: #
    /// [`SendStream`]: ../struct.SendStream.html
    /// [`send_reset`]: #method.send_reset
    pub fn send_response(
        &mut self,
        response: Response<()>,
        end_of_stream: bool,
    ) -> Result<SendStream<B>, crate::h2::Error> {
        self.inner
            .send_response(response, end_of_stream)
            .map(|_| SendStream::new(self.inner.clone()))
            .map_err(Into::into)
    }

    /// Push a request and response to the client
    ///
    /// On success, a [`SendResponse`] instance is returned.
    ///
    /// [`SendResponse`]: #
    pub fn push_request(
        &mut self,
        request: Request<()>,
    ) -> Result<SendPushedResponse<B>, crate::h2::Error> {
        self.inner
            .send_push_promise(request)
            .map(|inner| SendPushedResponse {
                inner: Self { inner },
            })
            .map_err(Into::into)
    }

    /// Send a stream reset to the peer.
    ///
    /// This essentially cancels the stream, including any inbound or outbound
    /// data streams.
    ///
    /// If this function is called before [`send_response`], a call to
    /// [`send_response`] will result in an error.
    ///
    /// If this function is called while a [`SendStream`] instance is active,
    /// any further use of the instance will result in an error.
    ///
    /// This function should only be called once.
    ///
    /// [`send_response`]: #method.send_response
    /// [`SendStream`]: ../struct.SendStream.html
    pub fn send_reset(&mut self, reason: Reason) {
        self.inner.send_reset(reason)
    }

    /// Polls to be notified when the client resets this stream.
    ///
    /// If stream is still open, this returns `Poll::Pending`, and
    /// registers the task to be notified if a `RST_STREAM` is received.
    ///
    /// If a `RST_STREAM` frame is received for this stream, calling this
    /// method will yield the `Reason` for the reset.
    ///
    /// # Error
    ///
    /// Calling this method after having called `send_response` will return
    /// a user error.
    pub fn poll_reset(&mut self, cx: &mut Context) -> Poll<Result<Reason, crate::h2::Error>> {
        self.inner.poll_reset(cx, proto::PollReset::AwaitingHeaders)
    }

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

// ===== impl SendPushedResponse =====

impl<B: Buf> SendPushedResponse<B> {
    /// Send a response to a promised request.
    ///
    /// On success, a [`SendStream`] instance is returned. This instance can be
    /// used to stream the response body and send trailers.
    ///
    /// If a body or trailers will be sent on the returned [`SendStream`]
    /// instance, then `end_of_stream` must be set to `false` when calling this
    /// function.
    ///
    /// The [`SendPushedResponse`] instance is associated with a promised
    /// request.  This function may only be called once per instance and only if
    /// [`send_reset`] has not been previously called.
    ///
    /// [`SendPushedResponse`]: #
    /// [`SendStream`]: ../struct.SendStream.html
    /// [`send_reset`]: #method.send_reset
    pub fn send_response(
        &mut self,
        response: Response<()>,
        end_of_stream: bool,
    ) -> Result<SendStream<B>, crate::h2::Error> {
        self.inner.send_response(response, end_of_stream)
    }

    /// Send a stream reset to the peer.
    ///
    /// This essentially cancels the stream, including any inbound or outbound
    /// data streams.
    ///
    /// If this function is called before [`send_response`], a call to
    /// [`send_response`] will result in an error.
    ///
    /// If this function is called while a [`SendStream`] instance is active,
    /// any further use of the instance will result in an error.
    ///
    /// This function should only be called once.
    ///
    /// [`send_response`]: #method.send_response
    /// [`SendStream`]: ../struct.SendStream.html
    pub fn send_reset(&mut self, reason: Reason) {
        self.inner.send_reset(reason)
    }

    /// Polls to be notified when the client resets this stream.
    ///
    /// If stream is still open, this returns `Poll::Pending`, and
    /// registers the task to be notified if a `RST_STREAM` is received.
    ///
    /// If a `RST_STREAM` frame is received for this stream, calling this
    /// method will yield the `Reason` for the reset.
    ///
    /// # Error
    ///
    /// Calling this method after having called `send_response` will return
    /// a user error.
    pub fn poll_reset(&mut self, cx: &mut Context) -> Poll<Result<Reason, crate::h2::Error>> {
        self.inner.poll_reset(cx)
    }

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

// ===== impl Flush =====

impl<T, B: Buf> Flush<T, B> {
    fn new(codec: Codec<T, B>) -> Self {
        Self { codec: Some(codec) }
    }
}

impl<T, B> Future for Flush<T, B>
where
    T: AsyncWrite + Unpin,
    B: Buf,
{
    type Output = Result<Codec<T, B>, crate::h2::Error>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        if let Some(codec) = self.codec.as_mut() {
            ready!(codec.flush(cx)).map_err(crate::h2::Error::from_io)?;
            #[expect(clippy::expect_used, reason = "memory cannot move in between polls")]
            let codec = self
                .codec
                .take()
                .expect("codec from Flush future was Some above");
            Poll::Ready(Ok(codec))
        } else {
            warn!(
                "h2 server: Flush: codec no longer available: future polled after ready, report bug in rama repo"
            );
            Poll::Ready(Err(crate::h2::Error::from(
                crate::h2::UserError::PollAfterReady,
            )))
        }
    }
}

impl<T, B: Buf> ReadPreface<T, B> {
    fn new(codec: Codec<T, B>) -> Self {
        Self {
            codec: Some(codec),
            pos: 0,
        }
    }
}

impl<T, B> Future for ReadPreface<T, B>
where
    T: AsyncRead + Unpin,
    B: Buf,
{
    type Output = Result<Codec<T, B>, crate::h2::Error>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let mut buf = [0; 24];
        let mut rem = PREFACE.len() - self.pos;

        while rem > 0 {
            let mut buf = ReadBuf::new(&mut buf[..rem]);

            let Some(inner) = self.codec.as_mut() else {
                warn!(
                    "h2 server: ReadPreface: poll read: codec no longer available: future polled after ready, report bug in rama repo"
                );
                return Poll::Ready(Err(crate::h2::Error::from(
                    crate::h2::UserError::PollAfterReady,
                )));
            };

            ready!(Pin::new(inner.get_mut()).poll_read(cx, &mut buf))
                .map_err(crate::h2::Error::from_io)?;
            let n = buf.filled().len();
            if n == 0 {
                return Poll::Ready(Err(crate::h2::Error::from_io(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "connection closed before reading preface",
                ))));
            }

            if !valid_preface_part(self.pos, buf.filled()) {
                proto_err!(conn: "read_preface: invalid preface");
                // TODO: Should this just write the GO_AWAY frame directly?
                return Poll::Ready(Err(Error::library_go_away(Reason::PROTOCOL_ERROR).into()));
            }

            self.pos += n;
            rem -= n; // TODO test
        }

        Poll::Ready(if let Some(codec) = self.codec.take() {
            Ok(codec)
        } else {
            warn!(
                "h2 server: ReadPreface: codec no longer available: future polled after ready, report bug in rama repo"
            );
            Err(crate::h2::Error::from(crate::h2::UserError::PollAfterReady))
        })
    }
}

// ===== impl Handshake =====

impl<T, B: Buf> Future for Handshake<T, B>
where
    T: AsyncRead + AsyncWrite + Unpin + ExtensionsRef,
    B: Buf,
{
    type Output = Result<Connection<T, B>, crate::h2::Error>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let span = self.span.clone(); // XXX(eliza): T_T
        let _e = span.enter();
        tracing::trace!("state = {:?}", self.state);

        loop {
            match &mut self.state {
                Handshaking::Failed(error) => {
                    let error = error
                        .take()
                        .unwrap_or_else(|| crate::h2::Error::from(UserError::PollAfterReady));
                    self.state = Handshaking::Done;
                    return Poll::Ready(Err(error));
                }
                Handshaking::Flushing(flush) => {
                    // We're currently flushing a pending SETTINGS frame. Poll the
                    // flush future, and, if it's completed, advance our state to wait
                    // for the client preface.
                    let codec = match Pin::new(flush).poll(cx)? {
                        Poll::Pending => {
                            tracing::trace!("flush poll pending");
                            return Poll::Pending;
                        }
                        Poll::Ready(flushed) => {
                            tracing::trace!("flush poll ready");
                            flushed
                        }
                    };
                    self.settings_sent_at = Some(Instant::now());
                    self.state = Handshaking::ReadingPreface(
                        ReadPreface::new(codec).instrument(tracing::trace_span!("read_preface")),
                    );
                }
                Handshaking::ReadingPreface(read) => {
                    let codec = ready!(Pin::new(read).poll(cx)?);

                    self.state = Handshaking::Done;

                    let connection = proto::Connection::try_new(
                        codec,
                        Config {
                            next_stream_id: 2.into(),
                            // Server does not need to locally initiate any streams
                            initial_max_send_streams: 0,
                            refuse_push_promises: false,
                            max_send_buffer_size: self.builder.max_send_buffer_size,
                            reset_stream_duration: self.builder.reset_stream_duration,
                            reset_stream_max: self.builder.reset_stream_max,
                            remote_reset_stream_max: self.builder.pending_accept_reset_stream_max,
                            local_error_reset_streams_max: self
                                .builder
                                .local_max_error_reset_streams,
                            settings: self.builder.settings.clone(),
                            send_alt_svc: self.builder.send_alt_svc,
                            headers_pseudo_order: None,
                            early_frame_ctx: if self.builder.observe_early_frames {
                                EarlyFrameStreamContext::new_recorder()
                            } else {
                                EarlyFrameStreamContext::new_nop()
                            },
                            data_frame_budget: self.builder.data_frame_budget,
                            settings_sent_at: self.settings_sent_at,
                        },
                    )?;

                    tracing::trace!("connection established!");
                    let mut c = Connection { connection };
                    if let Some(sz) = self.builder.initial_target_connection_window_size {
                        c.try_set_target_window_size(sz)?;
                    }

                    return Poll::Ready(Ok(c));
                }
                Handshaking::Done => {
                    panic!("Handshaking::poll() called again after handshaking was complete")
                }
            }
        }
    }
}

impl<T, B: Buf> Handshake<T, B> {
    /// Bytes of the client preface received so far, once it started arriving.
    pub(crate) fn preface_progress(&self) -> Option<u64> {
        match &self.state {
            Handshaking::ReadingPreface(read) => {
                let received = read.inner().pos;
                (received != 0).then_some(received as u64)
            }
            Handshaking::Failed(_) | Handshaking::Flushing(_) | Handshaking::Done => None,
        }
    }
}

impl<T, B> fmt::Debug for Handshake<T, B>
where
    T: AsyncRead + AsyncWrite + fmt::Debug,
    B: fmt::Debug + Buf,
{
    fn fmt(&self, fmt: &mut fmt::Formatter) -> fmt::Result {
        write!(fmt, "server::Handshake")
    }
}

impl Peer {
    pub(crate) fn convert_send_message(
        id: StreamId,
        response: Response<()>,
        end_of_stream: bool,
    ) -> (frame::Headers, Extensions) {
        use rama_http_types::response::Parts;

        // Extract the components of the HTTP request
        let (
            Parts {
                status,
                headers,
                extensions,
                ..
            },
            _,
        ) = response.into_parts();

        // Build the set pseudo header set. All requests will include `method`
        // and `path`.
        let mut pseudo = Pseudo::response(status);

        // reuse order if defined
        if let Some(order) = extensions.get_ref::<PseudoHeaderOrder>().cloned()
            && !order.is_empty()
        {
            pseudo.order = order;
        }
        pseudo.sensitivity = extensions
            .get_ref::<PseudoHeaderSensitivity>()
            .copied()
            .unwrap_or_default();

        // Create the HEADERS frame
        let mut frame = frame::Headers::new(id, pseudo, headers, None);

        if end_of_stream {
            frame.set_end_stream()
        }

        (frame, extensions)
    }

    pub(crate) fn convert_push_message(
        stream_id: StreamId,
        promised_id: StreamId,
        request: Request<()>,
    ) -> Result<frame::PushPromise, UserError> {
        use rama_http_types::request::Parts;

        if let Err(e) = frame::PushPromise::validate_request(&request) {
            match e {
                PushPromiseHeaderError::NotSafeAndCacheable => tracing::debug!(
                    "convert_push_message: method {} is not safe and cacheable (promised id: {:?})",
                    request.method(),
                    promised_id,
                ),
                PushPromiseHeaderError::InvalidContentLength(e) => tracing::debug!(
                    "convert_push_message; promised request has invalid content-length {:?}: (promised id: {:?})",
                    e,
                    promised_id,
                ),
            }
            return Err(UserError::MalformedHeaders);
        }

        // Extract the components of the HTTP request
        let (
            Parts {
                method,
                uri,
                headers,
                extensions,
                ..
            },
            _,
        ) = request.into_parts();

        let mut pseudo = Pseudo::request(method, &uri, None);

        // reuse order if defined
        if let Some(order) = extensions.get_ref::<PseudoHeaderOrder>().cloned()
            && !order.is_empty()
        {
            pseudo.order = order;
        }
        pseudo.sensitivity = extensions
            .get_ref::<PseudoHeaderSensitivity>()
            .copied()
            .unwrap_or_default();

        Ok(frame::PushPromise::new(
            stream_id,
            promised_id,
            pseudo,
            headers,
        ))
    }
}

impl proto::Peer for Peer {
    type Poll = Request<()>;

    const NAME: &'static str = "Server";

    /*
    fn is_server() -> bool {
        true
    }
    */

    fn r#dyn() -> proto::DynPeer {
        proto::DynPeer::Server
    }

    fn convert_poll_message(
        pseudo: Pseudo,
        fields: HeaderMap,
        header_size: usize,
        stream_id: StreamId,
        extensions: Extensions,
    ) -> Result<Self::Poll, Error> {
        let mut b = Request::builder_with_extensions(extensions);

        macro_rules! malformed {
            ($($arg:tt)*) => {{
                tracing::debug!($($arg)*);
                return Err(Error::library_reset(stream_id, Reason::PROTOCOL_ERROR));
            }}
        }

        b = b.version(Version::HTTP_2);

        let is_connect;
        let is_options;
        if let Some(method) = pseudo.method {
            is_connect = method == Method::CONNECT;
            is_options = method == Method::OPTIONS;
            b = b.method(method);
        } else {
            malformed!("malformed headers: missing method");
        }

        let authority_sensitive = pseudo.sensitivity.is_sensitive(PseudoHeader::Authority);
        let has_protocol = if let Some(protocol) = pseudo.protocol {
            if is_connect {
                // Assert that we have the right type.
                b = b.extension::<ext::Protocol>(protocol);
            } else {
                malformed!("malformed headers: :protocol on non-CONNECT request");
            }
            true
        } else {
            false
        };

        if pseudo.status.is_some() {
            malformed!("malformed headers: :status field on request");
        }

        // Convert the URI from the validated pseudo-headers — the inverse of
        // the `write_h2_*` writers.

        // A request translated from HTTP/1 must not include the :authority
        // header.
        let raw_authority = pseudo.authority;
        let authority = if let Some(authority) = raw_authority.as_ref() {
            let Some(received) = received_authority(authority) else {
                malformed!("malformed headers: malformed authority ({:?})", authority);
            };
            Some(received)
        } else {
            None
        };

        // A :scheme is required, except CONNECT.
        let scheme = if let Some(scheme) = pseudo.scheme {
            if is_connect && !has_protocol {
                malformed!("malformed headers: :scheme in CONNECT");
            }
            match scheme.parse::<rama_net::Protocol>() {
                // RFC 8441 §5: a ws/wss target is carried as http/https, whatever the peer sent.
                Ok(scheme) if has_protocol => {
                    Some(ext::extended_connect_pseudo_scheme(&scheme).clone())
                }
                // Kept with or without an authority, as on HTTP/3.
                Ok(scheme) => Some(scheme),
                Err(why) => malformed!(
                    "malformed headers: malformed scheme ({:?}): {}",
                    scheme,
                    why,
                ),
            }
        } else if !is_connect || has_protocol {
            malformed!("malformed headers: missing scheme");
        } else {
            None
        };

        let path = if let Some(path) = pseudo.path {
            if is_connect && !has_protocol {
                malformed!("malformed headers: :path in CONNECT");
            }
            // RFC 9113 §8.3.1: only an http(s) target needs a non-empty path.
            if path.is_empty() && scheme.as_ref().is_none_or(rama_net::Protocol::is_http) {
                malformed!("malformed headers: missing path");
            }
            Some(path)
        } else if is_connect && has_protocol {
            malformed!("malformed headers: missing path in extended CONNECT");
        } else if is_connect {
            // Non-extended CONNECT carries no `:path`; the target is the
            // authority-form `:authority`.
            None
        } else {
            // RFC 9113 §8.3.1: every non-CONNECT request MUST carry `:path`.
            malformed!("malformed headers: missing path");
        };

        let mut asterisk = false;
        let mut asterisk_scheme = None;
        let target = match path.as_deref() {
            // A path-less OPTIONS is the server-wide request, as on every version.
            Some("") if is_options => Some("*"),
            target => target,
        };
        let uri = match target {
            // RFC 9113 §8.3.1: `*` is only for a server-wide OPTIONS.
            Some("*") if !is_options => malformed!("malformed headers: `*` path without OPTIONS"),
            // The asterisk URI holds neither scheme nor authority: the scheme is kept beside
            // it and the authority becomes `Host`, as on HTTP/1 and HTTP/3.
            Some("*") => {
                asterisk = true;
                asterisk_scheme = scheme;
                uri::Uri::from_static("*")
            }
            // A target of another scheme without a path (RFC 9113 §8.3.1).
            Some("") => {
                let mut uri = uri::Uri::default().without_path();
                if let Some(authority) = authority {
                    uri.set_authority(authority);
                }
                if let Some(scheme) = scheme {
                    uri.set_scheme(scheme);
                }
                uri
            }
            // origin-form: parse the path/query, then graft the typed authority and scheme.
            Some(path) => {
                let mut uri = match uri::Uri::parse(path) {
                    Ok(uri) => uri,
                    Err(why) => {
                        malformed!("malformed headers: malformed path ({:?}): {}", path, why)
                    }
                };
                // RFC 9113 §8.3.1: `:path` carries only the path/query of the
                // target — the scheme and authority have their own pseudo-headers
                // and MUST NOT appear here. Reject absolute-form values such as
                // `https://evil/x`, which would otherwise inject an
                // attacker-chosen authority when `:authority` is absent.
                if uri.scheme().is_some() || uri.authority().is_some() {
                    malformed!(
                        "malformed headers: :path must be origin-form, not absolute-form ({:?})",
                        path
                    );
                }
                if let Some(authority) = authority {
                    uri.set_authority(authority);
                }
                if let Some(scheme) = scheme {
                    uri.set_scheme(scheme);
                }
                uri
            }
            // authority-form (CONNECT).
            None => match authority {
                // The authority is already parsed; build the authority-form URI
                // directly instead of re-serializing and re-parsing it.
                Some(authority) if authority.port_u16().is_some() => {
                    uri::Uri::from_authority_form(authority)
                }
                // RFC 9113 §8.5: CONNECT names a host and port; there is no default to guess.
                _ => malformed!("malformed headers: CONNECT without a host and port"),
            },
        };

        b = b.uri(uri);

        let mut request = match b.body(()) {
            Ok(request) => request,
            Err(e) => {
                // TODO: Should there be more specialized handling for different
                // kinds of errors
                proto_err!(stream: "error building request: {}; stream={:?}", e, stream_id);
                return Err(Error::library_reset(stream_id, Reason::PROTOCOL_ERROR));
            }
        };

        if let Some(scheme) = asterisk_scheme {
            request.extensions().insert(scheme);
        }
        if !pseudo.order.is_empty() {
            request.extensions().insert(pseudo.order);
        }
        if pseudo.sensitivity != PseudoHeaderSensitivity::default() {
            request.extensions().insert(pseudo.sensitivity);
        }

        request.extensions().insert(HeaderByteLength(header_size));

        // Several Host lines leave the routed authority ambiguous.
        if several_hosts(&fields) {
            malformed!("malformed headers: several Host lines");
        }
        *request.headers_mut() = fields;
        if asterisk && let Some(authority) = raw_authority.as_deref() {
            match asterisk_host(
                authority.as_bytes(),
                request.headers_mut(),
                authority_sensitive,
            ) {
                Ok(()) => {}
                Err(AsteriskHostError::InvalidAuthority) => {
                    malformed!("malformed headers: malformed authority ({:?})", authority);
                }
                Err(AsteriskHostError::TooManyFields) => {
                    malformed!("malformed headers: too many header fields");
                }
            }
        }
        let mut uri = std::mem::take(request.uri_mut());
        normalize_received(&mut uri, request.headers_mut(), authority_sensitive);
        *request.uri_mut() = uri;

        Ok(request)
    }
}

// ===== impl Handshaking =====

impl<T, B> fmt::Debug for Handshaking<T, B>
where
    B: Buf,
{
    #[inline]
    fn fmt(&self, f: &mut fmt::Formatter) -> Result<(), fmt::Error> {
        match *self {
            Self::Failed(_) => f.write_str("Failed(_)"),
            Self::Flushing(_) => f.write_str("Flushing(_)"),
            Self::ReadingPreface(_) => f.write_str("ReadingPreface(_)"),
            Self::Done => f.write_str("Done"),
        }
    }
}

#[cfg(test)]
#[cfg(feature = "quic")]
pub(crate) mod test_util {
    use super::*;

    /// The request an HTTP/2 server receives for these fields.
    pub(crate) fn receive(pseudo: Pseudo, headers: HeaderMap) -> Result<Request<()>, Error> {
        <Peer as proto::Peer>::convert_poll_message(
            pseudo,
            headers,
            0,
            StreamId::from(1),
            Extensions::new(),
        )
    }
}

#[cfg(test)]
mod path_form_tests {
    use super::*;
    use rama_http_types::proto::h2::hpack::BytesStr;

    fn bs(s: &'static str) -> BytesStr {
        BytesStr::try_from(rama_core::bytes::Bytes::from_static(s.as_bytes())).unwrap()
    }

    fn decode(pseudo: Pseudo) -> Result<Request<()>, Error> {
        <Peer as proto::Peer>::convert_poll_message(
            pseudo,
            HeaderMap::new(),
            0,
            StreamId::from(1),
            Extensions::new(),
        )
    }

    #[test]
    fn incoming_pseudo_sensitivity_is_retained_as_shared_metadata() {
        let mut pseudo =
            Pseudo::request(Method::GET, &"https://example.com/".parse().unwrap(), None);
        pseudo
            .sensitivity
            .set_sensitive(rama_http_types::proto::h2::PseudoHeader::Path, true);
        let request = decode(pseudo).unwrap();
        assert!(
            request
                .extensions()
                .get_ref::<PseudoHeaderSensitivity>()
                .unwrap()
                .is_sensitive(rama_http_types::proto::h2::PseudoHeader::Path)
        );
    }

    #[test]
    fn promised_request_retains_pseudo_sensitivity() {
        let request = Request::builder()
            .uri("https://example.com/")
            .body(())
            .unwrap();
        let mut sensitivity = PseudoHeaderSensitivity::default();
        sensitivity.set_sensitive(rama_http_types::proto::h2::PseudoHeader::Path, true);
        request.extensions().insert(sensitivity);
        let promise =
            Peer::convert_push_message(StreamId::from(1), StreamId::from(2), request).unwrap();
        let (pseudo, _) = promise.into_parts();
        assert_eq!(pseudo.sensitivity, sensitivity);
    }

    // RFC 9113 §8.3.1: an absolute-form `:path` (carrying scheme/authority) must
    // be rejected — otherwise, with `:authority` absent, the embedded host would
    // be injected into the request URI.
    #[test]
    fn h2_rejects_absolute_form_path() {
        let pseudo = Pseudo {
            method: Some(Method::GET),
            scheme: Some(bs("https")),
            authority: None,
            path: Some(bs("https://evil.example/x")),
            ..Default::default()
        };
        assert!(
            decode(pseudo).is_err(),
            "absolute-form :path must be rejected"
        );
    }

    #[test]
    fn h2_accepts_origin_form_path() {
        let pseudo = Pseudo {
            method: Some(Method::GET),
            scheme: Some(bs("https")),
            authority: Some(bs("real.example")),
            path: Some(bs("/x?y=1")),
            ..Default::default()
        };
        let req = decode(pseudo).expect("origin-form :path is valid");
        assert_eq!(req.uri().host_str().as_deref(), Some("real.example"),);
    }

    // RFC 9113 §8.3.1 (h2spec 8.1.2.3/4): a non-CONNECT request that omits
    // `:path` is malformed and must be rejected (PROTOCOL_ERROR).
    #[test]
    fn h2_rejects_missing_path_non_connect() {
        let pseudo = Pseudo {
            method: Some(Method::GET),
            scheme: Some(bs("https")),
            authority: Some(bs("real.example")),
            path: None,
            ..Default::default()
        };
        assert!(
            decode(pseudo).is_err(),
            "non-CONNECT request without :path must be rejected"
        );
    }

    // CONNECT carries no `:path`; its target is the authority-form `:authority`.
    #[test]
    fn h2_accepts_connect_without_path() {
        let pseudo = Pseudo {
            method: Some(Method::CONNECT),
            scheme: None,
            authority: Some(bs("real.example:443")),
            path: None,
            ..Default::default()
        };
        let req = decode(pseudo).expect("CONNECT without :path is valid");
        assert_eq!(req.method(), Method::CONNECT);
        assert_eq!(req.uri().host_str().as_deref(), Some("real.example"),);
    }

    // Every Extended CONNECT scheme is accepted; ws/wss is carried as http/https (RFC 8441 §5).
    #[test]
    fn extended_connect_schemes_are_accepted_and_ws_is_carried_as_http() {
        for (protocol, scheme, carried) in [
            ("websocket", "https", "https"),
            ("websocket", "http", "http"),
            ("WebSocket", "https", "https"),
            ("websocket", "custom", "custom"),
            ("WebSocket", "ftp", "ftp"),
            ("websocket", "wss", "https"),
            ("x", "custom", "custom"),
            ("x", "ws", "http"),
            ("x", "wss", "https"),
        ] {
            let pseudo = Pseudo {
                method: Some(Method::CONNECT),
                scheme: Some(bs(scheme)),
                authority: Some(bs("real.example")),
                path: Some(bs("/chat")),
                protocol: Some(ext::Protocol::from_static(protocol)),
                ..Default::default()
            };
            let request = decode(pseudo).unwrap();
            assert_eq!(
                request.uri().scheme_str(),
                Some(carried),
                "{protocol} {scheme}"
            );
        }
    }

    #[test]
    fn received_targets_are_normalized() {
        let pseudo = Pseudo {
            method: Some(Method::GET),
            scheme: Some(bs("https")),
            authority: Some(bs("user:pw@real.example")),
            path: Some(bs("/x")),
            ..Default::default()
        };
        let mut headers = HeaderMap::new();
        headers.insert(
            rama_http_types::header::HOST,
            rama_http_types::HeaderValue::from_static("other.example"),
        );
        let request = <Peer as proto::Peer>::convert_poll_message(
            pseudo,
            headers,
            0,
            StreamId::from(1),
            Extensions::new(),
        )
        .unwrap();
        assert_eq!(request.uri().to_string(), "https://real.example/x");
        assert_eq!(
            request.headers()[rama_http_types::header::HOST],
            "real.example"
        );
    }
}

#[cfg(test)]
mod observation_tests {
    use super::*;
    use rama_core::ServiceInput;
    use rama_http_types::proto::h2::frame::{EarlyFrame, EarlyFrameCapture};
    use rama_utils::octets::kib;

    #[tokio::test]
    async fn server_observation_requires_explicit_opt_in() {
        for enabled in [false, true] {
            let (client_io, server_io) = tokio::io::duplex(kib(16));
            let client = async move {
                let (mut sender, connection) =
                    crate::h2::client::handshake(ServiceInput::new(client_io))
                        .await
                        .unwrap();
                let request = Request::builder()
                    .uri("https://example.com/")
                    .body(())
                    .unwrap();
                let (_response, _stream) = sender.send_request(request, true).unwrap();
                let _result = connection.await;
            };
            let server = async move {
                let mut builder = Builder::new();
                if enabled {
                    builder.set_observe_early_frames(true);
                }
                let mut connection = builder
                    .handshake::<_, Bytes>(ServiceInput::new(server_io))
                    .await
                    .unwrap();
                let (request, _response) = connection.accept().await.unwrap().unwrap();
                let capture = request.extensions().get_ref::<EarlyFrameCapture>();
                assert_eq!(capture.is_some(), enabled);
                if let Some(capture) = capture {
                    assert!(capture.is_complete());
                    assert!(capture.iter().any(|frame| matches!(frame, EarlyFrame::Settings(settings) if settings.observation.as_ref().is_some_and(|wire| wire.complete))));
                }
            };
            tokio::time::timeout(Duration::from_secs(5), async {
                tokio::join!(client, server);
            })
            .await
            .unwrap();
        }
    }
}
