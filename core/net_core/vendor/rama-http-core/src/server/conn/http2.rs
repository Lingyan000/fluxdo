//! HTTP/2 Server Connections.

use std::convert::Infallible;
use std::fmt;
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Duration;

use pin_project_lite::pin_project;
use rama_core::Service;
use rama_core::extensions::ExtensionsRef;
use rama_core::rt::Executor;
use rama_http::{Request, Response};
use rama_http_types::conn::H2ServerContextParams;
use std::borrow::Cow;
use std::task::ready;
use tokio::io::{AsyncRead, AsyncWrite};

use super::{HeaderReadTimeout, IdleTimeout, timeout::ConnTimer};
use crate::{body::Incoming as IncomingBody, proto};

pin_project! {
    /// A [`Future`] representing an HTTP/2 connection, bound to a
    /// [`Service`](crate::service::Service), returned from
    /// [`Builder::serve_connection`](struct.Builder.html#method.serve_connection).
    ///
    /// To drive HTTP on this connection this future **must be polled**, typically with
    /// `.await`. If it isn't polled, no progress will be made on this connection.
    #[must_use = "futures do nothing unless polled"]
    pub struct Connection<T, S>
    where
        S: Service<Request<IncomingBody>, Output = Response, Error = Infallible>,
    {
        conn: proto::h2::Server<T, S>,
    }
}

/// A configuration builder for HTTP/2 server connections.
///
/// **Note**: The default values of options are *not considered stable*. They
/// are subject to change at any time.
#[derive(Clone, Debug)]
pub struct Builder {
    exec: Executor,
    h2_builder: proto::h2::server::Config,
}

// ===== impl Connection =====

impl<I, S> fmt::Debug for Connection<I, S>
where
    S: Service<Request<IncomingBody>, Output = Response, Error = Infallible>,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Connection").finish()
    }
}

impl<I, S> Connection<I, S>
where
    S: Service<Request<IncomingBody>, Output = Response, Error = Infallible>,
    I: AsyncRead + AsyncWrite + Send + Unpin + ExtensionsRef + 'static,
{
    /// Start a graceful shutdown process for this connection.
    ///
    /// This `Connection` should continue to be polled until shutdown
    /// can finish.
    ///
    /// # Note
    ///
    /// This should only be called while the `Connection` future is still
    /// pending. If called after `Connection::poll` has resolved, this does
    /// nothing.
    pub fn graceful_shutdown(mut self: Pin<&mut Self>) {
        self.conn.graceful_shutdown();
    }
}

impl<I, S> Future for Connection<I, S>
where
    S: Service<Request<IncomingBody>, Output = Response, Error = Infallible> + Clone,
    I: AsyncRead + AsyncWrite + Send + Unpin + ExtensionsRef + 'static,
{
    type Output = crate::Result<()>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        match ready!(Pin::new(&mut self.conn).poll(cx)) {
            Ok(_done) => {
                //TODO: the proto::h2::Server no longer needs to return
                //the Dispatched enum
                Poll::Ready(Ok(()))
            }
            Err(e) => Poll::Ready(Err(e)),
        }
    }
}

// ===== impl Builder =====

impl Builder {
    /// Create a new connection builder.
    #[must_use]
    pub fn new(exec: Executor) -> Self {
        Self {
            exec,
            h2_builder: proto::h2::server::Config::default(),
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Retain bounded early frames and ordered SETTINGS for observation.
        /// Disabled by default; enable only for fingerprinting or preservation.
        pub fn observe_early_frames(mut self, enabled: bool) -> Self {
            self.h2_builder.observe_early_frames = enabled;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Configures the maximum number of pending reset streams allowed before a GOAWAY will be sent.
        ///
        /// This will default to the default value set by the [`h2` crate](https://crates.io/crates/h2).
        /// As of v0.4.0, it is 20.
        ///
        /// See <https://github.com/hyperium/hyper/issues/2877> for more information.
        pub fn max_pending_accept_reset_streams(mut self, max: Option<usize>) -> Self {
            self.h2_builder.max_pending_accept_reset_streams = max;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Configures the maximum number of local reset streams allowed before a GOAWAY will be sent.
        ///
        /// If not set, rama_http_core will use a default, currently of 1024.
        ///
        /// If `None` is supplied, rama_http_core will not apply any limit.
        /// This is not advised, as it can potentially expose servers to DOS vulnerabilities.
        ///
        /// See <https://rustsec.org/advisories/RUSTSEC-2024-0003.html> for more information.
        pub fn max_local_error_reset_streams(mut self, max: Option<usize>) -> Self {
            self.h2_builder.max_local_error_reset_streams = max;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Configures the connection-level budget for the memory overhead of
        /// received small DATA frames, exhausting it closes the connection.
        ///
        /// See the documentation of [`crate::h2::server::Builder::with_data_frame_budget`] for more
        /// details.
        ///
        /// The default, `None`, is half the target connection window, at least 25,600 bytes.
        pub fn data_frame_budget(mut self, budget: Option<usize>) -> Self {
            self.h2_builder.data_frame_budget = budget;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets the [`SETTINGS_INITIAL_WINDOW_SIZE`][spec] option for HTTP2
        /// stream-level flow control.
        ///
        /// If not set, rama_http_core will use a default.
        ///
        /// [spec]: https://httpwg.org/specs/rfc9113.html#SETTINGS_INITIAL_WINDOW_SIZE
        pub fn initial_stream_window_size(mut self, sz: u32) -> Self {
            self.h2_builder.adaptive_window = false;
            self.h2_builder.initial_stream_window_size = sz;

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
        /// If not set, rama_http_core will use a default.
        pub fn max_frame_size(mut self, sz: u32) -> Self {
            self.h2_builder.max_frame_size = sz;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets the [`SETTINGS_MAX_CONCURRENT_STREAMS`][spec] option for HTTP2
        /// connections.
        ///
        /// Default is 200, but not part of the stability of rama_http_core. It could change
        /// in a future release. You are encouraged to set your own limit.
        ///
        /// Passing `None` will remove any limit.
        ///
        /// [spec]: https://httpwg.org/specs/rfc9113.html#SETTINGS_MAX_CONCURRENT_STREAMS
        pub fn max_concurrent_streams(mut self, max: Option<u32>) -> Self {
            self.h2_builder.max_concurrent_streams = max;
            self
        }
    }

    /// Gets the [`SETTINGS_MAX_CONCURRENT_STREAMS`][spec] option used
    /// for HTTP2 connections.
    ///
    /// [spec]: https://httpwg.org/specs/rfc9113.html#SETTINGS_MAX_CONCURRENT_STREAMS
    pub fn max_concurrent_streams(&self) -> u32 {
        self.h2_builder.max_concurrent_streams.unwrap_or(200)
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets an interval for HTTP2 Ping frames should be sent to keep a
        /// connection alive.
        ///
        /// Pass `None` to disable HTTP2 keep-alive.
        ///
        /// Default is currently disabled.
        pub fn keep_alive_interval(mut self, interval: Option<Duration>) -> Self {
            self.h2_builder.keep_alive_interval = interval;
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
        /// Set the maximum write buffer size for each HTTP/2 stream.
        ///
        /// Default is currently ~400KB, but may change.
        pub fn max_send_buf_size(mut self, max: u32) -> Self {
            self.h2_builder.max_send_buffer_size = max;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Enable bounded ALTSVC frame emission through request extensions.
        ///
        /// Disabled by default. Ordinary response Alt-Svc headers do not need
        /// this option, and client-side frame observation is configured separately.
        pub fn alt_svc(mut self, enabled: bool) -> Self {
            self.h2_builder.send_alt_svc = enabled;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Enables the [extended CONNECT protocol].
        ///
        /// [extended CONNECT protocol]: https://datatracker.ietf.org/doc/html/rfc8441#section-4
        pub fn enable_connect_protocol(mut self) -> Self {
            self.h2_builder.enable_connect_protocol = true;
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
        /// The default value of crate `h2` is 4,096.
        pub fn header_table_size(mut self, size: Option<u32>) -> Self {
            self.h2_builder.header_table_size = size;
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
        /// Set the deadline for receiving a request head: the client preface and
        /// every HEADERS block with its CONTINUATION frames.
        ///
        /// Defaults to [`HeaderReadTimeout::DEFAULT`]; `None` disables it.
        pub fn header_read_timeout(mut self, timeout: Option<HeaderReadTimeout>) -> Self {
            self.h2_builder.header_read_timeout = timeout;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set the budget while no stream is open nor a request head in progress,
        /// after which the connection closes with a graceful GOAWAY.
        ///
        /// Defaults to [`IdleTimeout::DEFAULT`]; `None` disables it.
        pub fn idle_timeout(mut self, timeout: Option<IdleTimeout>) -> Self {
            self.h2_builder.idle_timeout = timeout;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set whether a successful response to CONNECT that carries `Content-Length`
        /// resets its stream, rather than having that field dropped.
        ///
        /// RFC 9110 §9.3.6 forbids the field there, as a tunnel follows the response.
        ///
        /// Default is `false`: the field is dropped and the tunnel opens.
        pub fn strict_connect_framing(mut self, enabled: bool) -> Self {
            self.h2_builder.strict_connect_framing = enabled;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set whether the `date` header should be included in HTTP responses.
        ///
        /// Note that including the `date` header is recommended by RFC 7231.
        ///
        /// Default is `true`.
        pub fn auto_date_header(mut self, enabled: bool) -> Self {
            self.h2_builder.date_header = enabled;
            self
        }
    }

    /// Bind a connection together with a [`Service`].
    ///
    /// This returns a Future that must be polled in order for HTTP to be
    /// driven on the connection.
    ///
    /// The IO's [`Extensions`] are checked for an [`H2ServerContextParams`]:
    /// if present, its fields override the corresponding builder defaults
    /// for *this* connection only, before the initial SETTINGS frame is
    /// sent. Used primarily by MITM relays mirroring upstream SETTINGS.
    ///
    /// [`Extensions`]: rama_core::extensions::Extensions
    pub fn serve_connection<S, I>(&self, io: I, service: S) -> Connection<I, S>
    where
        S: Service<Request<IncomingBody>, Output = Response, Error = Infallible>,
        I: AsyncRead + AsyncWrite + Send + Unpin + ExtensionsRef + 'static,
    {
        let timer = ConnTimer::new(
            self.h2_builder.idle_timeout,
            self.h2_builder.header_read_timeout,
        );
        self.serve_connection_with_timer(io, service, timer)
    }

    /// Bind a connection whose deadlines already started, as during protocol detection.
    pub(super) fn serve_connection_with_timer<S, I>(
        &self,
        io: I,
        service: S,
        timer: ConnTimer,
    ) -> Connection<I, S>
    where
        S: Service<Request<IncomingBody>, Output = Response, Error = Infallible>,
        I: AsyncRead + AsyncWrite + Send + Unpin + ExtensionsRef + 'static,
    {
        let h2_builder = if let Some(params) = io.extensions().get_ref::<H2ServerContextParams>() {
            let mut cfg = self.h2_builder.clone();
            apply_h2_server_context_params(&mut cfg, params);
            Cow::Owned(cfg)
        } else {
            Cow::Borrowed(&self.h2_builder)
        };
        let proto = proto::h2::Server::new(io, service, &h2_builder, self.exec.clone(), timer);
        Connection { conn: proto }
    }
}

/// Per-conn override: applies non-`None` fields of `params` onto `cfg`,
/// overriding the relay's baseline builder defaults. Mirrors the public
/// builder setters one-to-one; when both `initial_*_window_size` and
/// `adaptive_window` are set, adaptive runs last (resets windows). Use
/// `adaptive_window: Some(false)` to keep explicit window sizes.
///
/// SEE: `rama_http_backend::proxy::mitm::HttpMitmRelay::new` for the
/// builder baseline this override path wins over (closes #932 for TLS h2).
fn apply_h2_server_context_params(
    cfg: &mut proto::h2::server::Config,
    params: &H2ServerContextParams,
) {
    if let Some(settings) = &params.initial_settings {
        cfg.initial_settings = Some(settings.clone());
    }
    if let Some(v) = params.enable_connect_protocol {
        cfg.enable_connect_protocol = v;
    }
    if let Some(v) = params.max_concurrent_streams {
        cfg.max_concurrent_streams = Some(v);
    }
    if let Some(v) = params.header_table_size {
        cfg.header_table_size = Some(v);
    }
    if let Some(v) = params.max_frame_size {
        cfg.max_frame_size = v;
    }
    if let Some(v) = params.max_header_list_size {
        cfg.max_header_list_size = v;
    }
    if let Some(v) = params.initial_stream_window_size {
        cfg.adaptive_window = false;
        cfg.initial_stream_window_size = v;
    }
    if let Some(v) = params.initial_connection_window_size {
        cfg.adaptive_window = false;
        cfg.initial_conn_window_size = v;
    }
    if let Some(adaptive) = params.adaptive_window {
        cfg.adaptive_window = adaptive;
        if adaptive {
            cfg.initial_conn_window_size = proto::h2::SPEC_WINDOW_SIZE;
            cfg.initial_stream_window_size = proto::h2::SPEC_WINDOW_SIZE;
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::service::VoidHttpService;
    use tokio::net::TcpStream;

    use super::*;

    #[test]
    fn test_assert_send_static() {
        fn g<T: Send + 'static>() {}
        g::<Connection<TcpStream, VoidHttpService>>();
    }
}
