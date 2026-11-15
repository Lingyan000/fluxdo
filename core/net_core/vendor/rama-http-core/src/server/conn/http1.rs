//! HTTP/1 Server Connections.

use rama_core::error::{BoxError, BoxErrorExt};
use std::convert::Infallible;
use std::fmt;
use std::pin::Pin;
use std::task::{Context, Poll};

use httparse::ParserConfig;
use rama_core::Service;
use rama_core::bytes::Bytes;
use rama_core::extensions::ExtensionsRef;
use rama_http::io::upgrade::Upgraded;
use rama_http::{Body, Request, Response};
use rama_net::conn::LingeringClose;
use rama_net::extensions::StreamTransformed;
use std::task::ready;
use tokio::io::{AsyncRead, AsyncWrite};

use super::{HeaderReadTimeout, IdleTimeout, timeout::ConnTimer};
use crate::{body::Incoming as IncomingBody, proto};

type Http1Dispatcher<T, B, S> = proto::h1::Dispatcher<
    proto::h1::dispatch::Server<S, IncomingBody>,
    B,
    T,
    proto::ServerTransaction,
>;

pin_project_lite::pin_project! {
    /// A [`Future`] representing an HTTP/1 connection, bound to a
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
        conn: Http1Dispatcher<T, Body, S>,
    }
}

/// A configuration builder for HTTP/1 server connections.
///
/// **Note**: The default values of options are *not considered stable*. They
/// are subject to change at any time.
///
/// # Example
///
/// ```
/// # use rama_http_core::server::conn::http1::Builder;
/// # fn main() {
/// let mut http = Builder::new();
/// // Set options one at a time
/// http.set_half_close(false);
///
/// // Or, chain multiple options
/// http.set_keep_alive(false).set_title_case_headers(true).try_set_max_buf_size(8192).unwrap();
///
/// # }
/// ```
///
/// Use [`Builder::serve_connection`](struct.Builder.html#method.serve_connection)
/// to bind the built connection to a service.
#[derive(Clone, Debug)]
pub struct Builder {
    h1_parser_config: ParserConfig,
    h1_half_close: bool,
    h1_keep_alive: bool,
    h1_title_case_headers: bool,
    h1_max_headers: Option<usize>,
    h1_max_header_size: Option<usize>,
    pub(super) h1_header_read_timeout: Option<HeaderReadTimeout>,
    pub(super) h1_idle_timeout: Option<IdleTimeout>,
    h1_lingering_close: Option<LingeringClose>,
    h1_writev: Option<bool>,
    max_buf_size: Option<usize>,
    pipeline_flush: bool,
    date_header: bool,
    strict_connect_framing: bool,
}

/// Deconstructed parts of a `Connection`.
///
/// This allows taking apart a `Connection` at a later time, in order to
/// reclaim the IO object, and additional related pieces.
#[derive(Debug)]
#[non_exhaustive]
pub struct Parts<T, S> {
    /// The original IO object used in the handshake.
    pub io: T,
    /// A buffer of bytes that have been read but not processed as HTTP.
    ///
    /// If the client sent additional bytes after its last request, and
    /// this connection "ended" with an upgrade, the read buffer will contain
    /// those bytes.
    ///
    /// You will want to check for any existing bytes if you plan to continue
    /// communicating on the IO object.
    pub read_buf: Bytes,
    /// The `Service` used to serve this connection.
    pub service: S,
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
    S: Service<Request<IncomingBody>, Output = Response, Error = Infallible> + Clone,
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
        self.conn.disable_keep_alive();
    }

    /// Return the inner IO object, and additional information.
    ///
    /// If the IO object has been "rewound" the io will not contain those bytes rewound.
    /// This should only be called after `poll_without_shutdown` signals
    /// that the connection is "done". Otherwise, it may not have finished
    /// flushing all necessary HTTP bytes.
    ///
    /// # Panics
    /// This method will panic if this connection is using an h2 protocol.
    pub fn into_parts(self) -> Parts<I, S> {
        let (io, read_buf, dispatch) = self.conn.into_inner();
        Parts {
            io,
            read_buf,
            service: dispatch.into_service(),
        }
    }

    /// Poll the connection for completion, but without calling `shutdown`
    /// on the underlying IO.
    ///
    /// This is useful to allow running a connection while doing an HTTP
    /// upgrade. Once the upgrade is completed, the connection would be "done",
    /// but it is not desired to actually shutdown the IO object. Instead you
    /// would take it back using `into_parts`.
    pub fn poll_without_shutdown(&mut self, cx: &mut Context<'_>) -> Poll<crate::Result<()>>
    where
        S: Unpin,
    {
        self.conn.poll_without_shutdown(cx)
    }

    /// Prevent shutdown of the underlying IO object at the end of service the request,
    /// instead run `into_parts`. This is a convenience wrapper over `poll_without_shutdown`.
    ///
    /// # Error
    ///
    /// This errors if the underlying connection protocol is not HTTP/1.
    pub fn without_shutdown(self) -> impl Future<Output = crate::Result<Parts<I, S>>> {
        let mut this = Some(self);
        std::future::poll_fn(move |cx| {
            if let Some(Self { mut conn }) = this.take() {
                match conn.poll_without_shutdown(cx) {
                    Poll::Ready(Err(err)) => Poll::Ready(Err(err)),
                    Poll::Ready(Ok(())) => Poll::Ready(Ok(Self { conn }.into_parts())),
                    Poll::Pending => {
                        this = Some(Self { conn });
                        Poll::Pending
                    }
                }
            } else {
                Poll::Ready(Err(
                    crate::Error::new_parse_internal().with_display(
                        "h1 server connection w/o shutdown: poll: inner connection already taken: poll after ready?",
                    )))
            }
        })
    }

    /// Enable this connection to support higher-level HTTP upgrades.
    pub fn with_upgrades(self) -> UpgradeableConnection<I, S>
    where
        I: Send,
    {
        UpgradeableConnection { inner: Some(self) }
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
            Ok(done) => {
                match done {
                    proto::Dispatched::Shutdown => {}
                    proto::Dispatched::Upgrade(pending) => {
                        // With no `Send` bound on `I`, we can't try to do
                        // upgrades here. In case a user was trying to use
                        // `Body::on_upgrade` with this API, send a special
                        // error letting them know about that.
                        pending.manual();
                    }
                }
                Poll::Ready(Ok(()))
            }
            Err(e) => Poll::Ready(Err(e)),
        }
    }
}

// ===== impl Builder =====

impl Default for Builder {
    fn default() -> Self {
        Self::new()
    }
}

impl Builder {
    /// Create a new connection builder.
    #[must_use]
    pub fn new() -> Self {
        Self {
            h1_parser_config: ParserConfig::default(),
            h1_half_close: false,
            h1_keep_alive: true,
            h1_title_case_headers: false,
            h1_max_headers: None,
            h1_max_header_size: None,
            h1_header_read_timeout: Some(HeaderReadTimeout::DEFAULT),
            h1_idle_timeout: Some(IdleTimeout::DEFAULT),
            h1_lingering_close: Some(LingeringClose::default()),
            h1_writev: None,
            max_buf_size: None,
            pipeline_flush: false,
            date_header: true,
            strict_connect_framing: false,
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set whether HTTP/1 connections should support half-closures.
        ///
        /// Clients can chose to shutdown their write-side while waiting
        /// for the server to respond. Setting this to `true` will
        /// prevent closing the connection immediately if `read`
        /// detects an EOF in the middle of a request.
        ///
        /// Default is `false`.
        pub fn half_close(mut self, val: bool) -> Self {
            self.h1_half_close = val;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Enables or disables HTTP/1 keep-alive.
        ///
        /// Default is `true`.
        pub fn keep_alive(mut self, val: bool) -> Self {
            self.h1_keep_alive = val;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set whether HTTP/1 connections will write header names as title case at
        /// the socket level.
        ///
        /// Default is `false`.
        pub fn title_case_headers(mut self, enabled: bool) -> Self {
            self.h1_title_case_headers = enabled;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set whether multiple spaces are allowed as delimiters in request lines.
        ///
        /// Default is `false`.
        pub fn allow_multiple_spaces_in_request_line_delimiters(mut self, enabled: bool) -> Self {
            self.h1_parser_config
                .allow_multiple_spaces_in_request_line_delimiters(enabled);
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set whether HTTP/1 connections will silently ignored malformed header lines.
        ///
        /// If this is enabled and a header line does not start with a valid header
        /// name, or does not include a colon at all, the line will be silently ignored
        /// and no error will be reported.
        ///
        /// Default is `false`.
        pub fn ignore_invalid_headers(mut self, enabled: bool) -> Self {
            self.h1_parser_config
                .ignore_invalid_headers_in_requests(enabled);
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set the maximum number of headers.
        ///
        /// When a request is received, the parser will reserve a buffer to store headers for optimal
        /// performance.
        ///
        /// If server receives more headers than the buffer size, it responds to the client with
        /// "431 Request Header Fields Too Large".
        ///
        /// Note that headers is allocated on the stack by default, which has higher performance. After
        /// setting this value, headers will be allocated in heap memory, that is, heap memory
        /// allocation will occur for each request, and there will be a performance drop of about 5%.
        ///
        /// Default is `100`.
        pub fn max_headers(mut self, val: Option<usize>) -> Self {
            self.h1_max_headers = val;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set the maximum size in bytes of a request head, its request line included.
        ///
        /// If the client sends a larger head, the server responds with
        /// "431 Request Header Fields Too Large" and closes the connection.
        ///
        /// This also bounds the size of chunked trailers.
        ///
        /// Default is `None`: the head is only bounded by the maximum buffer size,
        /// and trailers by 16 KiB.
        pub fn max_header_size(mut self, val: Option<usize>) -> Self {
            self.h1_max_header_size = val;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set the lingering close of a connection the server closes while
        /// the client may still be sending: while writing its response and after
        /// shutting down its side, the server reads and discards input within
        /// these bounds before closing the socket. The allowance is shared by both
        /// phases; if the total timeout or byte limit is reached before an idle
        /// end and the response is blocked, the connection ends with a
        /// write error. A client that went idle stops the lingering, not the
        /// response.
        ///
        /// If `idle_timeout >= timeout`, the total limit wins even for an idle
        /// client and can abort a blocked response. Keep the idle timeout shorter
        /// to let idle clients continue reading; the defaults are 2 s and 30 s.
        ///
        /// Closing with unread input makes the connection reset instead of
        /// ending cleanly, and a Windows client then drops the response it
        /// has not read yet: for instance a 413 sent while it is still
        /// uploading, or the 400 or 431 for a bad request head.
        ///
        /// It only applies when input may be left unread: a request body the
        /// service did not read, buffered input such as a pipelined request,
        /// or a rejected request head. A clean close, a client that already
        /// ended its stream, an upgraded connection, a service or IO error,
        /// and a graceful shutdown of the server skip it.
        ///
        /// Default is [`LingeringClose::default`]: up to 2 seconds without
        /// data and 30 seconds in total. `None` disables it.
        pub fn lingering_close(mut self, linger: Option<LingeringClose>) -> Self {
            self.h1_lingering_close = linger;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set the deadline for receiving a request head, from its first byte.
        ///
        /// Defaults to [`HeaderReadTimeout::DEFAULT`]; `None` disables it.
        pub fn header_read_timeout(mut self, timeout: Option<HeaderReadTimeout>) -> Self {
            self.h1_header_read_timeout = timeout;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set the budget while no request is open nor a request head in progress,
        /// after which the connection closes.
        ///
        /// Defaults to [`IdleTimeout::DEFAULT`]; `None` disables it.
        pub fn idle_timeout(mut self, timeout: Option<IdleTimeout>) -> Self {
            self.h1_idle_timeout = timeout;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set whether HTTP/1 connections should try to use vectored writes,
        /// or always flatten into a single buffer.
        ///
        /// Note that setting this to false may mean more copies of body data,
        /// but may also improve performance when an IO transport doesn't
        /// support vectored writes well, such as most TLS implementations.
        ///
        /// Setting this to true will force rama_http_core to use queued strategy,
        /// which may eliminate unnecessary cloning on some TLS backends.
        ///
        /// Default is `auto`. In this mode rama_http_core will try to guess which
        /// mode to use.
        pub fn writev(mut self, val: Option<bool>) -> Self {
            self.h1_writev = val;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set the maximum buffer size for the connection.
        ///
        /// Default is ~400kb.
        ///
        /// # Error
        ///
        /// The minimum value allowed is 8192. This method errors if the passed `max` is less than the minimum.
        pub fn max_buf_size(mut self, max: Option<usize>) -> Result<Self, BoxError> {
            if max.map(|max| max < proto::h1::MINIMUM_MAX_BUFFER_SIZE).unwrap_or_default() {
                return Err(BoxError::from_static_str("the max_buf_size cannot be smaller than the minimum that h1 specifies"));
            }
            self.max_buf_size = max;
            Ok(self)
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set whether the `date` header should be included in HTTP responses.
        ///
        /// Note that including the `date` header is recommended by RFC 7231.
        ///
        /// Default is `true`.
        pub fn auto_date_header(mut self, enabled: bool) -> Self {
            self.date_header = enabled;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set whether a successful response to CONNECT that carries `Content-Length` or
        /// `Transfer-Encoding` fails, rather than having those fields dropped.
        ///
        /// RFC 9110 §9.3.6 forbids both fields there, as a tunnel follows the response.
        ///
        /// Default is `false`: the fields are dropped and the tunnel opens.
        pub fn strict_connect_framing(mut self, enabled: bool) -> Self {
            self.strict_connect_framing = enabled;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Aggregates flushes to better support pipelined responses.
        ///
        /// Experimental, may have bugs.
        ///
        /// Default is `false`.
        pub fn pipeline_flush(mut self, enabled: bool) -> Self {
            self.pipeline_flush = enabled;
            self
        }
    }

    /// Bind a connection together with a [`Service`].
    ///
    /// This returns a Future that must be polled in order for HTTP to be
    /// driven on the connection.
    ///
    pub fn serve_connection<I, S>(&self, io: I, service: S) -> Connection<I, S>
    where
        S: Service<Request<IncomingBody>, Output = Response, Error = Infallible> + Clone,
        I: AsyncRead + AsyncWrite + Send + Unpin + ExtensionsRef + 'static,
    {
        let timer = ConnTimer::new(self.h1_idle_timeout, self.h1_header_read_timeout);
        self.serve_connection_with_timer(io, service, timer)
    }

    /// Bind a connection whose deadlines already started, as during protocol detection.
    pub(super) fn serve_connection_with_timer<I, S>(
        &self,
        io: I,
        service: S,
        mut timer: ConnTimer,
    ) -> Connection<I, S>
    where
        S: Service<Request<IncomingBody>, Output = Response, Error = Infallible> + Clone,
        I: AsyncRead + AsyncWrite + Send + Unpin + ExtensionsRef + 'static,
    {
        io.extensions().insert(StreamTransformed {
            by: "rama-http-core::h1::server",
        });
        let mut conn = proto::Conn::new(io);
        conn.set_h1_parser_config(self.h1_parser_config.clone());
        if !self.h1_keep_alive {
            conn.disable_keep_alive();
        }
        if self.h1_half_close {
            conn.set_allow_half_close();
        }
        if self.h1_title_case_headers {
            conn.set_title_case_headers();
        }
        if let Some(max_headers) = self.h1_max_headers {
            conn.set_http1_max_headers(max_headers);
        }
        if let Some(max_header_size) = self.h1_max_header_size {
            conn.set_http1_max_header_size(max_header_size);
        }
        timer.reconfigure(self.h1_idle_timeout, self.h1_header_read_timeout);
        conn.set_timer(timer);
        conn.set_lingering_close(self.h1_lingering_close);
        if let Some(writev) = self.h1_writev {
            if writev {
                conn.set_write_strategy_queue();
            } else {
                conn.set_write_strategy_flatten();
            }
        }
        conn.set_flush_pipeline(self.pipeline_flush);
        if let Some(max) = self.max_buf_size {
            conn.set_max_buf_size(max);
        }
        if !self.date_header {
            conn.disable_date_header();
        }
        if self.strict_connect_framing {
            conn.set_strict_connect_framing();
        }
        let sd = proto::h1::dispatch::Server::new(service);
        let proto = proto::h1::Dispatcher::new(sd, conn);
        Connection { conn: proto }
    }
}

/// A future binding a connection with a Service with Upgrade support.
#[must_use = "futures do nothing unless polled"]
#[expect(missing_debug_implementations)]
pub struct UpgradeableConnection<T, S>
where
    S: Service<Request<IncomingBody>, Output = Response, Error = Infallible>,
{
    pub(super) inner: Option<Connection<T, S>>,
}

impl<I, S> UpgradeableConnection<I, S>
where
    S: Service<Request<IncomingBody>, Output = Response, Error = Infallible> + Clone,
    I: AsyncRead + AsyncWrite + Send + Unpin + ExtensionsRef + 'static,
{
    /// Start a graceful shutdown process for this connection.
    ///
    /// This `Connection` should continue to be polled until shutdown
    /// can finish.
    pub fn graceful_shutdown(mut self: Pin<&mut Self>) {
        // Connection (`inner`) is `None` if it was upgraded (and `poll` is `Ready`).
        // In that case, we don't need to call `graceful_shutdown`.
        if let Some(conn) = self.inner.as_mut() {
            Pin::new(conn).graceful_shutdown();
        }
    }

    /// Return the inner IO object, and additional information provided the connection
    /// has not yet been upgraded.
    pub fn into_parts(self) -> Option<Parts<I, S>> {
        self.inner.map(|conn| conn.into_parts())
    }
}

impl<I, S> Future for UpgradeableConnection<I, S>
where
    S: Service<Request<IncomingBody>, Output = Response, Error = Infallible> + Clone,
    I: AsyncRead + AsyncWrite + Send + Unpin + ExtensionsRef + 'static,
{
    type Output = crate::Result<()>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        if let Some(conn) = self.inner.as_mut() {
            match ready!(Pin::new(&mut conn.conn).poll(cx)) {
                Ok(proto::Dispatched::Shutdown) => Poll::Ready(Ok(())),
                Ok(proto::Dispatched::Upgrade(pending)) => {
                    let Some(Connection { conn }) = self.inner.take() else {
                        return Poll::Ready(Err(
                            crate::Error::new_parse_internal().with_display(
                                "h1 server upgradeable connection: dispatch upgrade: inner connection already taken",
                            )));
                    };
                    let (io, buf, _) = conn.into_inner();
                    pending.fulfill(Upgraded::new(io, buf));
                    Poll::Ready(Ok(()))
                }
                Err(e) => Poll::Ready(Err(e)),
            }
        } else {
            // inner is `None`, meaning the connection was upgraded, thus it's `Poll::Ready(Ok(()))`
            Poll::Ready(Ok(()))
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
        g::<UpgradeableConnection<TcpStream, VoidHttpService>>();
    }
}

/// Lingering close over real sockets: the server rejects an upload without
/// reading it and closes while the client is still sending.
#[cfg(test)]
#[cfg(not(miri))]
mod lingering_tests {
    use std::{
        convert::Infallible,
        io,
        net::SocketAddr,
        time::{Duration, Instant},
    };

    use rama_core::{ServiceInput, service::service_fn};
    use rama_http::StatusCode;
    use tokio::{
        io::{AsyncRead, AsyncReadExt, AsyncWriteExt},
        net::{TcpListener, TcpStream},
        task::JoinHandle,
    };

    use super::*;
    use crate::service::RamaHttpService;

    /// Lingers until something other than a timeout ends it.
    fn patient_linger() -> LingeringClose {
        LingeringClose::new().with_idle_timeout(Duration::from_secs(30))
    }

    const UPLOAD_HEAD: &[u8] =
        b"POST /upload HTTP/1.1\r\nhost: localhost\r\ncontent-length: 104857600\r\n\r\n";

    /// Answers a request to `/read` once it read the body, with 400 if that
    /// fails to decode; any other request with 413, without reading its body.
    async fn answer(req: Request) -> Result<Response, Infallible> {
        use rama_http_types::body::util::BodyExt as _;

        let status = if req.uri().path().is_some_and(|path| path == *"/read") {
            match req.into_body().collect().await {
                Ok(_) => StatusCode::OK,
                Err(_) => StatusCode::BAD_REQUEST,
            }
        } else {
            StatusCode::PAYLOAD_TOO_LARGE
        };
        let mut response = Response::new(Body::from("answer"));
        *response.status_mut() = status;
        Ok(response)
    }

    /// Serve one connection with [`answer`]. The task returns how long the
    /// connection lived.
    async fn reject_uploads(builder: Builder) -> (SocketAddr, JoinHandle<Duration>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let task = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let started = Instant::now();
            _ = builder
                .serve_connection(
                    ServiceInput::new(stream),
                    RamaHttpService::new(service_fn(answer)),
                )
                .await;
            started.elapsed()
        });
        (addr, task)
    }

    async fn read_until_end(reader: &mut (impl AsyncRead + Unpin)) -> (Vec<u8>, io::Result<()>) {
        let mut bytes = Vec::new();
        let mut buf = [0; 4096];
        loop {
            match reader.read(&mut buf).await {
                Ok(0) => return (bytes, Ok(())),
                Ok(n) => bytes.extend_from_slice(&buf[..n]),
                Err(err) => return (bytes, Err(err)),
            }
        }
    }

    // Both ordinary Upgrade and CONNECT requests must be rejected as HTTP,
    // even when the caller enabled the upgrade driver.
    #[tokio::test]
    async fn rejected_upgrades_linger_and_do_not_fulfill_on_upgrade() {
        for request in [
            b"POST / HTTP/1.1\r\nhost: localhost\r\nconnection: upgrade\r\nupgrade: example\r\ncontent-length: 10000\r\n\r\n".as_slice(),
            b"CONNECT localhost:443 HTTP/1.1\r\nhost: localhost\r\ncontent-length: 10000\r\n\r\n".as_slice(),
        ] {
            let (mut client, server_io) = tokio::io::duplex(256);
            let (upgrade_tx, mut upgrade_rx) = tokio::sync::mpsc::unbounded_channel();
            let service = service_fn(move |req: Request| {
                let upgrade = req.extensions().get_ref::<rama_http::io::upgrade::OnUpgrade>().unwrap().clone();
                upgrade_tx.send(upgrade).unwrap();
                answer(req)
            });
            let server = tokio::spawn(async move {
                Builder::new().with_lingering_close(patient_linger())
                    .serve_connection(ServiceInput::new(server_io), RamaHttpService::new(service))
                    .with_upgrades().await
            });
            client.write_all(request).await.unwrap();
            let mut head = [0; 12];
            client.read_exact(&mut head).await.unwrap();
            assert!(is_413(&head));
            let upgrade = upgrade_rx.recv().await.unwrap();
            assert!(tokio::time::timeout(Duration::from_secs(1), upgrade).await.unwrap().is_err(),
                "a rejected request fulfilled OnUpgrade");
            assert!(!server.is_finished(), "a rejected upgrade skipped lingering");
            client.write_all(b"remaining upload").await.unwrap();
            client.shutdown().await.unwrap();
            let (_, end) = read_until_end(&mut client).await;
            end.unwrap();
            tokio::time::timeout(Duration::from_secs(1), server).await.unwrap().unwrap().unwrap();
        }
    }

    // Neither direction can buffer the full message. The client deliberately
    // finishes uploading before reading, reproducing the two full buffers.
    #[tokio::test]
    async fn lingering_drains_upload_while_large_response_is_blocked() {
        let (mut client, server_io) = tokio::io::duplex(256);
        let server = tokio::spawn(async move {
            let service = service_fn(|_req: Request| async {
                let mut response = Response::new(Body::from(vec![b'r'; 64 * 1024]));
                *response.status_mut() = StatusCode::PAYLOAD_TOO_LARGE;
                Ok::<_, Infallible>(response)
            });
            Builder::new()
                .serve_connection(ServiceInput::new(server_io), RamaHttpService::new(service))
                .await
        });
        let exchange = async {
            client.write_all(UPLOAD_HEAD).await.unwrap();
            client.write_all(&vec![b'x'; 64 * 1024]).await.unwrap();
            client.shutdown().await.unwrap();
            let (bytes, end) = read_until_end(&mut client).await;
            end.unwrap();
            assert!(is_413(&bytes));
            assert!(bytes.ends_with(&vec![b'r'; 64 * 1024]));
            server.await.unwrap().unwrap();
        };
        tokio::time::timeout(Duration::from_secs(2), exchange)
            .await
            .expect("response flushing and the upload deadlocked");
    }
    #[tokio::test]
    async fn accepted_upgrades_preserve_buffered_protocol_bytes() {
        for (method, status) in [
            ("GET", StatusCode::SWITCHING_PROTOCOLS),
            ("CONNECT", StatusCode::OK),
            ("CONNECT", StatusCode::NO_CONTENT),
        ] {
            let (mut client, server_io) = tokio::io::duplex(256);
            let (upgrade_tx, mut upgrade_rx) = tokio::sync::mpsc::unbounded_channel();
            let service = service_fn(move |req: Request| {
                upgrade_tx
                    .send(
                        req.extensions()
                            .get_ref::<rama_http::io::upgrade::OnUpgrade>()
                            .unwrap()
                            .clone(),
                    )
                    .unwrap();
                async move {
                    let mut response = Response::new(Body::empty());
                    *response.status_mut() = status;
                    Ok::<_, Infallible>(response)
                }
            });
            let server = tokio::spawn(async move {
                Builder::new()
                    .serve_connection(ServiceInput::new(server_io), RamaHttpService::new(service))
                    .with_upgrades()
                    .await
            });
            let target = if method == "CONNECT" {
                "localhost:443"
            } else {
                "/"
            };
            client.write_all(format!("{method} {target} HTTP/1.1\r\nhost: localhost\r\nconnection: upgrade\r\nupgrade: example\r\n\r\ntail").as_bytes()).await.unwrap();
            let exchange = async {
                let mut upgraded = upgrade_rx.recv().await.unwrap().await.unwrap();
                let mut tail = [0; 4];
                upgraded.read_exact(&mut tail).await.unwrap();
                assert_eq!(&tail, b"tail");
                server.await.unwrap().unwrap();
            };
            tokio::time::timeout(Duration::from_secs(2), exchange)
                .await
                .unwrap();
        }
    }

    #[tokio::test]
    async fn blocked_response_ends_when_lingering_allowance_expires() {
        use std::sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        };

        use rama_core::io::AbortIo;

        // A client that went idle is not what blocks the response, see
        // `lingering_idle_end_does_not_cut_a_slow_reader_off`.
        for linger in [
            patient_linger().with_timeout(Duration::from_millis(100)),
            patient_linger().with_max_bytes(1),
        ] {
            let (mut client, server_io) = tokio::io::duplex(256);
            let aborted = Arc::new(AtomicBool::new(false));
            let abort = aborted.clone();
            let server_io = ServiceInput::new(server_io);
            server_io.extensions().insert(AbortIo::new(move || {
                abort.store(true, Ordering::SeqCst);
            }));
            let server = tokio::spawn(async move {
                let service = service_fn(|_req: Request| async {
                    let mut response = Response::new(Body::from(vec![b'r'; 64 * 1024]));
                    *response.status_mut() = StatusCode::PAYLOAD_TOO_LARGE;
                    Ok::<_, Infallible>(response)
                });
                Builder::new()
                    .with_lingering_close(linger)
                    .serve_connection(server_io, RamaHttpService::new(service))
                    .await
            });
            client.write_all(UPLOAD_HEAD).await.unwrap();
            let upload =
                tokio::spawn(async move { while client.write_all(&[b'x'; 4096]).await.is_ok() {} });
            let result = tokio::time::timeout(Duration::from_secs(2), server).await;
            upload.abort();
            let err = result
                .expect("stuck response outlived its drain allowance")
                .unwrap()
                .unwrap_err();
            assert_eq!(
                std::error::Error::source(&err)
                    .and_then(|source| source.downcast_ref::<io::Error>())
                    .map(io::Error::kind),
                Some(io::ErrorKind::TimedOut),
                "{err:?}"
            );
            assert!(
                aborted.load(Ordering::SeqCst),
                "a truncated response must abort the transport before it is dropped"
            );
        }
    }
    #[tokio::test]
    async fn lingering_expiry_does_not_truncate_a_slow_response_producer() {
        let (mut client, server_io) = tokio::io::duplex(256);
        let server = tokio::spawn(async move {
            let service = service_fn(|_req: Request| async {
                let body = Body::from_stream(rama_core::futures::stream::once(async {
                    tokio::time::sleep(Duration::from_millis(300)).await;
                    Ok::<_, Infallible>(Bytes::from_static(b"tail"))
                }));
                let mut response = Response::new(body);
                *response.status_mut() = StatusCode::PAYLOAD_TOO_LARGE;
                response.headers_mut().insert(
                    rama_http::header::CONTENT_LENGTH,
                    rama_http::HeaderValue::from_static("4"),
                );
                Ok::<_, Infallible>(response)
            });
            Builder::new()
                .with_lingering_close(patient_linger().with_idle_timeout(Duration::from_millis(50)))
                .serve_connection(ServiceInput::new(server_io), RamaHttpService::new(service))
                .await
        });
        client.write_all(UPLOAD_HEAD).await.unwrap();
        let exchange = async {
            let (bytes, end) = read_until_end(&mut client).await;
            end.unwrap();
            assert!(
                bytes.ends_with(b"tail"),
                "a writable response was truncated: {bytes:?}"
            );
            server.await.unwrap().unwrap();
        };
        tokio::time::timeout(Duration::from_secs(2), exchange)
            .await
            .unwrap();
    }
    // The client sent its whole body, which the service left unread, and is
    // now only slow to read a large response: it is not uploading, so the
    // idle end of the drain must not cut the response off.
    #[tokio::test]
    async fn lingering_idle_end_does_not_cut_a_slow_reader_off() {
        let (mut client, server_io) = tokio::io::duplex(1024);
        let server = tokio::spawn(async move {
            let service = service_fn(|_req: Request| async {
                Ok::<_, Infallible>(Response::new(Body::from(vec![b'r'; 64 * 1024])))
            });
            Builder::new()
                .with_lingering_close(patient_linger().with_idle_timeout(Duration::from_millis(50)))
                .serve_connection(ServiceInput::new(server_io), RamaHttpService::new(service))
                .await
        });
        client
            .write_all(b"POST / HTTP/1.1\r\nhost: localhost\r\ncontent-length: 65536\r\n\r\n")
            .await
            .unwrap();
        // Only drained by the lingering, as the service never reads it.
        client.write_all(&vec![b'x'; 64 * 1024]).await.unwrap();
        tokio::time::sleep(Duration::from_millis(200)).await;
        let exchange = async {
            let (bytes, end) = read_until_end(&mut client).await;
            end.unwrap();
            assert!(
                bytes.ends_with(&vec![b'r'; 64 * 1024]),
                "a slow reader lost its response: {} bytes",
                bytes.len()
            );
            server.await.unwrap().unwrap();
        };
        tokio::time::timeout(Duration::from_secs(2), exchange)
            .await
            .unwrap();
    }
    #[tokio::test]
    async fn lingering_byte_limit_flushes_a_pipelined_response() {
        let (mut client, server_io) = tokio::io::duplex(2048);
        let server = tokio::spawn(async move {
            Builder::new()
                .with_pipeline_flush(true)
                .with_lingering_close(patient_linger().with_max_bytes(1))
                .serve_connection(
                    ServiceInput::new(server_io),
                    RamaHttpService::new(service_fn(answer)),
                )
                .await
        });
        client.write_all(b"GET / HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\nunused pipelined input").await.unwrap();
        let exchange = async {
            let (bytes, end) = read_until_end(&mut client).await;
            end.unwrap();
            assert!(
                is_413(&bytes) && bytes.ends_with(b"answer"),
                "lost a writable pipelined response: {bytes:?}"
            );
            server.await.unwrap().unwrap();
        };
        tokio::time::timeout(Duration::from_secs(2), exchange)
            .await
            .unwrap();
    }
    /// Upload at a modest pace and only read the response once `ready`, as a
    /// client busy writing its request does.
    async fn upload_then_read(
        addr: SocketAddr,
        ready: impl Future<Output = ()>,
    ) -> (Vec<u8>, io::Result<()>) {
        let stream = TcpStream::connect(addr).await.unwrap();
        let (mut reader, mut writer) = stream.into_split();
        writer.write_all(UPLOAD_HEAD).await.unwrap();
        let uploading = tokio::spawn(async move {
            let chunk = [b'x'; 16 * 1024];
            for _ in 0..20 {
                if writer.write_all(&chunk).await.is_err() {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            writer
        });
        ready.await;
        let received = read_until_end(&mut reader).await;
        drop(uploading.await.unwrap());
        received
    }

    fn is_413(bytes: &[u8]) -> bool {
        bytes.starts_with(b"HTTP/1.1 413")
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn lingering_keeps_the_response_of_a_rejected_upload() {
        for _ in 0..10 {
            let (addr, server) = reject_uploads(Builder::new()).await;
            let later = tokio::time::sleep(Duration::from_millis(150));
            let (bytes, end) = upload_then_read(addr, later).await;
            assert!(is_413(&bytes), "{:?}", String::from_utf8_lossy(&bytes));
            end.unwrap();
            tokio::time::timeout(Duration::from_secs(5), server)
                .await
                .expect("the server kept lingering after the client closed")
                .unwrap();
        }
    }

    /// The control: without lingering, Windows drops the response. The
    /// client only reads once the server closed and the upload that went on
    /// had the time to draw a reset.
    #[cfg(target_os = "windows")]
    #[tokio::test(flavor = "multi_thread")]
    async fn without_lingering_windows_drops_the_response() {
        for _ in 0..10 {
            let (addr, server) = reject_uploads(Builder::new().without_lingering_close()).await;
            let closed = async {
                server.await.unwrap();
                tokio::time::sleep(Duration::from_millis(100)).await;
            };
            let (bytes, end) = upload_then_read(addr, closed).await;
            assert!(!is_413(&bytes), "the response survived without lingering");
            assert!(end.is_err());
        }
    }

    /// Lingering ends as soon as the client ends its stream.
    #[tokio::test(flavor = "multi_thread")]
    async fn lingering_ends_once_the_client_ended_its_stream() {
        let builder = Builder::new().with_lingering_close(patient_linger());
        let (addr, server) = reject_uploads(builder).await;
        let mut client = TcpStream::connect(addr).await.unwrap();
        client.write_all(UPLOAD_HEAD).await.unwrap();
        client.write_all(&[b'x'; 1024]).await.unwrap();
        let mut head = [0; 12];
        client.read_exact(&mut head).await.unwrap();
        assert!(is_413(&head));
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(!server.is_finished(), "the server did not linger");
        client.shutdown().await.unwrap();
        tokio::time::timeout(Duration::from_secs(2), server)
            .await
            .expect("the server kept lingering after the client ended its stream")
            .unwrap();
    }

    /// A clean close after a fully read request leaves nothing unread: the
    /// server closes right away, even while the client keeps its end open.
    #[tokio::test(flavor = "multi_thread")]
    async fn no_lingering_after_a_clean_close() {
        let builder = Builder::new().with_lingering_close(patient_linger());
        let (addr, server) = reject_uploads(builder).await;
        let mut client = TcpStream::connect(addr).await.unwrap();
        client
            .write_all(b"GET / HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n")
            .await
            .unwrap();
        let (bytes, end) = read_until_end(&mut client).await;
        assert!(is_413(&bytes));
        end.unwrap();
        tokio::time::timeout(Duration::from_secs(2), server)
            .await
            .expect("the server lingered after a clean close")
            .unwrap();
        drop(client);
    }

    /// A request head too large to parse gets its 431 through while the
    /// client is still sending that head.
    #[tokio::test(flavor = "multi_thread")]
    async fn lingering_keeps_the_response_to_a_rejected_head() {
        for linger in [true, false] {
            let builder = Builder::new().try_with_max_buf_size(8192).unwrap();
            let builder = if linger {
                builder
            } else {
                builder.without_lingering_close()
            };
            let (addr, server) = reject_uploads(builder).await;
            let stream = TcpStream::connect(addr).await.unwrap();
            let (mut reader, mut writer) = stream.into_split();
            writer
                .write_all(b"GET / HTTP/1.1\r\nhost: localhost\r\nx-big: ")
                .await
                .unwrap();
            let sending = tokio::spawn(async move {
                let chunk = [b'a'; 4096];
                for _ in 0..20 {
                    if writer.write_all(&chunk).await.is_err() {
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
                writer
            });
            let lingering = if linger {
                tokio::time::sleep(Duration::from_millis(150)).await;
                Some(server)
            } else {
                // Read only once the server closed and the head that went on
                // had the time to draw a reset.
                server.await.unwrap();
                tokio::time::sleep(Duration::from_millis(100)).await;
                None
            };
            let (bytes, end) = read_until_end(&mut reader).await;
            drop(sending.await.unwrap());
            if let Some(server) = lingering {
                assert!(
                    bytes.starts_with(b"HTTP/1.1 431"),
                    "{:?}",
                    String::from_utf8_lossy(&bytes)
                );
                end.unwrap();
                tokio::time::timeout(Duration::from_secs(5), server)
                    .await
                    .expect("the server kept lingering after the client closed")
                    .unwrap();
            } else if cfg!(target_os = "windows") {
                assert!(bytes.is_empty() && end.is_err(), "the 431 survived");
            }
        }
    }

    /// A head rejected after it was read in full, here for its invalid
    /// `content-length`, leaves nothing buffered, but the client may still
    /// send the body it announced.
    #[tokio::test(flavor = "multi_thread")]
    async fn lingering_keeps_the_response_to_a_rejected_complete_head() {
        let (addr, server) =
            reject_uploads(Builder::new().with_lingering_close(patient_linger())).await;
        let mut client = TcpStream::connect(addr).await.unwrap();
        client
            .write_all(b"POST / HTTP/1.1\r\nhost: localhost\r\ncontent-length: nope\r\n\r\n")
            .await
            .unwrap();
        let mut head = [0; 12];
        client.read_exact(&mut head).await.unwrap();
        assert_eq!(&head, b"HTTP/1.1 400");
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(!server.is_finished(), "the server closed without lingering");
        client.write_all(b"the announced body").await.unwrap();
        client.shutdown().await.unwrap();
        let (_, end) = read_until_end(&mut client).await;
        end.unwrap();
        tokio::time::timeout(Duration::from_secs(2), server)
            .await
            .expect("the server kept lingering after the client closed")
            .unwrap();
    }

    /// A body that fails to decode, here on the last byte read of a bad
    /// chunk size, may be followed by more of it: the answer to it is kept,
    /// though nothing of the request is left buffered.
    #[tokio::test(flavor = "multi_thread")]
    async fn lingering_keeps_the_response_to_a_body_that_failed_to_decode() {
        let (addr, server) =
            reject_uploads(Builder::new().with_lingering_close(patient_linger())).await;
        let mut client = TcpStream::connect(addr).await.unwrap();
        client
            .write_all(
                b"POST /read HTTP/1.1\r\nhost: localhost\r\ntransfer-encoding: chunked\r\n\r\n5z",
            )
            .await
            .unwrap();
        let mut head = [0; 12];
        client.read_exact(&mut head).await.unwrap();
        assert_eq!(&head, b"HTTP/1.1 400");
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(!server.is_finished(), "the server closed without lingering");
        client.write_all(b"more of the body").await.unwrap();
        client.shutdown().await.unwrap();
        let (_, end) = read_until_end(&mut client).await;
        end.unwrap();
        tokio::time::timeout(Duration::from_secs(2), server)
            .await
            .expect("the server kept lingering after the client closed")
            .unwrap();
    }

    /// A parse error that is answered with nothing, here for an HTTP/2
    /// client, leaves nothing to protect: the server closes right away.
    #[tokio::test(flavor = "multi_thread")]
    async fn no_lingering_after_a_parse_error_without_response() {
        let (addr, server) =
            reject_uploads(Builder::new().with_lingering_close(patient_linger())).await;
        let mut client = TcpStream::connect(addr).await.unwrap();
        client
            .write_all(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(2), server)
            .await
            .expect("the server lingered with nothing to protect")
            .unwrap();
        drop(client);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn lingering_is_bounded_by_its_idle_timeout() {
        let idle = Duration::from_millis(200);
        let builder =
            Builder::new().with_lingering_close(LingeringClose::new().with_idle_timeout(idle));
        let (addr, server) = reject_uploads(builder).await;
        let mut client = TcpStream::connect(addr).await.unwrap();
        client.write_all(UPLOAD_HEAD).await.unwrap();
        client.write_all(&[b'x'; 1024]).await.unwrap();
        // The client neither sends more nor ends its stream.
        let lived = tokio::time::timeout(Duration::from_secs(5), server)
            .await
            .expect("lingering was not bounded by its idle timeout")
            .unwrap();
        assert!(lived >= idle, "lingered only {lived:?}");
        drop(client);
    }

    /// A client that keeps sending, just often enough to never idle out, is
    /// cut off by the total timeout.
    #[tokio::test(flavor = "multi_thread")]
    async fn lingering_is_bounded_by_its_total_timeout() {
        let timeout = Duration::from_millis(600);
        let builder = Builder::new().with_lingering_close(
            LingeringClose::new()
                .with_idle_timeout(Duration::from_millis(300))
                .with_timeout(timeout),
        );
        let (addr, server) = reject_uploads(builder).await;
        let mut client = TcpStream::connect(addr).await.unwrap();
        // Nagle would hold each byte back until the last one is acknowledged,
        // which a delayed ACK can stretch past the idle timeout.
        client.set_nodelay(true).unwrap();
        client.write_all(UPLOAD_HEAD).await.unwrap();
        let trickle = tokio::spawn(async move {
            let until = Instant::now() + Duration::from_secs(5);
            while Instant::now() < until && client.write_all(b"x").await.is_ok() {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        });
        let lived = tokio::time::timeout(Duration::from_secs(5), server)
            .await
            .expect("lingering was not bounded by its total timeout")
            .unwrap();
        assert!(lived >= timeout, "lingered only {lived:?}");
        assert!(lived < Duration::from_secs(3), "lingered {lived:?}");
        trickle.abort();
    }

    /// A client that uploads without end and always has the next bytes
    /// ready: reading never waits, which must not stop the lingering from
    /// ending or from yielding.
    struct EndlessUpload {
        sent: usize,
    }

    impl EndlessUpload {
        fn serve(
            builder: &Builder,
        ) -> Connection<
            ServiceInput<Self>,
            impl Service<Request<IncomingBody>, Output = Response, Error = Infallible> + Clone,
        > {
            builder.serve_connection(
                ServiceInput::new(Self { sent: 0 }),
                RamaHttpService::new(service_fn(answer)),
            )
        }
    }

    impl AsyncRead for EndlessUpload {
        fn poll_read(
            mut self: Pin<&mut Self>,
            _: &mut Context<'_>,
            buf: &mut tokio::io::ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            let head = &UPLOAD_HEAD[self.sent.min(UPLOAD_HEAD.len())..];
            if head.is_empty() {
                let n = buf.initialize_unfilled().len();
                buf.advance(n);
            } else {
                let n = head.len().min(buf.remaining());
                buf.put_slice(&head[..n]);
                self.sent += n;
            }
            Poll::Ready(Ok(()))
        }
    }

    impl tokio::io::AsyncWrite for EndlessUpload {
        fn poll_write(
            self: Pin<&mut Self>,
            _: &mut Context<'_>,
            buf: &[u8],
        ) -> Poll<io::Result<usize>> {
            Poll::Ready(Ok(buf.len()))
        }

        fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
            Poll::Ready(Ok(()))
        }

        fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
            Poll::Ready(Ok(()))
        }
    }

    // A current-thread runtime only fires timers when the task yields.
    #[tokio::test]
    async fn lingering_on_an_always_ready_client_ends_at_its_timeout() {
        let timeout = Duration::from_millis(200);
        let builder = Builder::new().with_lingering_close(patient_linger().with_timeout(timeout));
        let started = Instant::now();
        EndlessUpload::serve(&builder).await.unwrap();
        let lived = started.elapsed();
        assert!(lived >= timeout, "lingered only {lived:?}");
        assert!(lived < Duration::from_secs(2), "lingered {lived:?}");
    }

    /// On a runtime of its own, so that a connection that never yields fails
    /// the test rather than hang it.
    #[test]
    fn lingering_on_an_always_ready_client_yields() {
        let (done, finished) = std::sync::mpsc::channel();
        let thread = std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            let lived = rt.block_on(async {
                let connection =
                    EndlessUpload::serve(&Builder::new().with_lingering_close(patient_linger()));
                tokio::pin!(connection);
                let started = Instant::now();
                tokio::select! {
                    _ = &mut connection => panic!("the connection ended instead of lingering"),
                    () = tokio::time::sleep(Duration::from_millis(100)) => {}
                }
                connection.as_mut().graceful_shutdown();
                connection.await.unwrap();
                started.elapsed()
            });
            _ = done.send(lived);
        });
        match finished.recv_timeout(Duration::from_secs(10)) {
            Ok(lived) => assert!(lived < Duration::from_secs(2), "lingered {lived:?}"),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                panic!("the lingering connection never yielded")
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                std::panic::resume_unwind(thread.join().unwrap_err())
            }
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn lingering_is_bounded_by_its_bytes() {
        let builder =
            Builder::new().with_lingering_close(patient_linger().with_max_bytes(64 * 1024));
        let (addr, server) = reject_uploads(builder).await;
        let mut client = TcpStream::connect(addr).await.unwrap();
        client.write_all(UPLOAD_HEAD).await.unwrap();
        let flood = tokio::spawn(async move {
            let chunk = [b'x'; 16 * 1024];
            while client.write_all(&chunk).await.is_ok() {}
        });
        tokio::time::timeout(Duration::from_secs(5), server)
            .await
            .expect("lingering was not bounded by its byte limit")
            .unwrap();
        flood.abort();
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn graceful_shutdown_cuts_lingering_short() {
        let builder = Builder::new().with_lingering_close(patient_linger());
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let mut client = TcpStream::connect(addr).await.unwrap();
        let (stream, _) = listener.accept().await.unwrap();
        client.write_all(UPLOAD_HEAD).await.unwrap();

        let connection = builder.serve_connection(
            ServiceInput::new(stream),
            RamaHttpService::new(service_fn(answer)),
        );
        tokio::pin!(connection);
        // The connection only answers while polled, so poll it while the answer is read.
        let mut head = [0; 12];
        tokio::select! {
            _ = &mut connection => panic!("the connection ended before its answer was read"),
            read = client.read_exact(&mut head) => {
                read.unwrap();
            }
        }
        assert!(is_413(&head));
        tokio::select! {
            _ = &mut connection => panic!("the connection ended instead of lingering"),
            () = tokio::time::sleep(Duration::from_millis(200)) => {}
        }

        connection.as_mut().graceful_shutdown();
        tokio::time::timeout(Duration::from_secs(1), connection)
            .await
            .expect("graceful shutdown waited for the lingering client")
            .unwrap();
        drop(client);
    }
}
