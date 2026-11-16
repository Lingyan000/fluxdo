//! Http1 or Http2 connection.

use rama_core::error::BoxErrorExt as _;
use std::convert::Infallible;
use std::io;
use std::marker::PhantomPinned;
use std::mem;
use std::pin::Pin;
use std::task::ready;
use std::task::{Context, Poll};

use pin_project_lite::pin_project;
use rama_core::Service;
use rama_core::extensions::ExtensionsRef;
use rama_http::{Request, Response};
use tokio::io::AsyncRead;
use tokio::io::AsyncWrite;
use tokio::io::ReadBuf;

use rama_core::bytes::Bytes;
use rama_core::error::BoxError;
use rama_core::io::rewind::Rewind;
use rama_core::rt::Executor;

use crate::body::Incoming;

use super::{
    HeaderReadTimeout, IdleTimeout, http1, http2,
    timeout::{Activity, ConnTimer},
};

const H2_PREFACE: &[u8] = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

/// Http1 or Http2 connection builder.
#[derive(Clone, Debug)]
pub struct Builder {
    http1: http1::Builder,
    http2: http2::Builder,
    version: Option<Version>,
}

impl Builder {
    /// Create a new auto connection builder.
    #[must_use]
    pub fn new(executor: Executor) -> Self {
        Self {
            http1: http1::Builder::new(),
            http2: http2::Builder::new(executor),
            version: None,
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set the request-head deadline of both protocols.
        ///
        /// Protocol detection follows the HTTP/1 deadline, as HTTP/1 serves a
        /// connection that did not send the HTTP/2 preface in time.
        /// Defaults to [`HeaderReadTimeout::DEFAULT`]; `None` disables it.
        pub fn header_read_timeout(mut self, timeout: Option<HeaderReadTimeout>) -> Self {
            self.http1.maybe_set_header_read_timeout(timeout);
            self.http2.maybe_set_header_read_timeout(timeout);
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Set the idle budget of both protocols.
        ///
        /// Protocol detection follows the HTTP/1 budget, and the detected
        /// protocol continues the window it started.
        /// Defaults to [`IdleTimeout::DEFAULT`]; `None` disables it.
        pub fn idle_timeout(mut self, timeout: Option<IdleTimeout>) -> Self {
            self.http1.maybe_set_idle_timeout(timeout);
            self.http2.maybe_set_idle_timeout(timeout);
            self
        }
    }

    /// Http1 builder.
    pub fn http1(&self) -> &http1::Builder {
        &self.http1
    }

    /// Http1 nutable builder.
    pub fn http1_mut(&mut self) -> &mut http1::Builder {
        &mut self.http1
    }

    /// H2 builder.
    pub fn h2(&self) -> &http2::Builder {
        &self.http2
    }

    /// H2 mutable builder.
    pub fn h2_mut(&mut self) -> &mut http2::Builder {
        &mut self.http2
    }

    /// Only accepts HTTP/2
    ///
    /// Does not do anything if used with [`serve_connection_with_upgrades`]
    ///
    /// [`serve_connection_with_upgrades`]: Builder::serve_connection_with_upgrades
    #[must_use]
    pub fn h2_only(mut self) -> Self {
        assert!(self.version.is_none());
        self.version = Some(Version::H2);
        self
    }

    /// Only accepts HTTP/1
    ///
    /// Does not do anything if used with [`serve_connection_with_upgrades`]
    ///
    /// [`serve_connection_with_upgrades`]: Builder::serve_connection_with_upgrades
    #[must_use]
    pub fn http1_only(mut self) -> Self {
        assert!(self.version.is_none());
        self.version = Some(Version::H1);
        self
    }

    /// Returns `true` if this builder can serve an HTTP/1.1-based connection.
    #[must_use]
    pub fn is_http1_available(&self) -> bool {
        match self.version {
            None | Some(Version::H1) => true,
            Some(Version::H2) => false,
        }
    }

    /// Returns `true` if this builder can serve an HTTP/2-based connection.
    #[must_use]
    pub fn is_http2_available(&self) -> bool {
        match self.version {
            Some(Version::H1) => false,
            None | Some(Version::H2) => true,
        }
    }

    /// Gets the [`SETTINGS_MAX_CONCURRENT_STREAMS`][spec] option used
    /// for HTTP2 connections.
    ///
    /// [spec]: https://httpwg.org/specs/rfc9113.html#SETTINGS_MAX_CONCURRENT_STREAMS
    pub fn max_concurrent_streams(&self) -> u32 {
        self.http2.max_concurrent_streams()
    }

    /// Bind a connection together with a [`Service`].
    pub fn serve_connection<I, S>(&self, io: I, service: S) -> Connection<'_, I, S>
    where
        S: Service<Request<Incoming>, Output = Response, Error = Infallible> + Clone,
        I: AsyncRead + AsyncWrite + Send + Unpin + ExtensionsRef + 'static,
    {
        let state = match self.version {
            Some(Version::H1) => {
                let io = Rewind::new_buffered(io, Bytes::new());
                let conn = self.http1.serve_connection(io, service);
                ConnState::H1 { conn }
            }
            Some(Version::H2) => {
                let io = Rewind::new_buffered(io, Bytes::new());
                let conn = self.http2.serve_connection(io, service);
                ConnState::H2 { conn }
            }
            _ => ConnState::ReadVersion {
                read_version: read_version(io, self.detection_timer()),
                builder: Cow::Borrowed(self),
                service: Some(service),
            },
        };

        Connection { state }
    }

    /// Bind a connection together with a [`Service`], with the ability to
    /// handle HTTP upgrades. This requires that the IO object implements
    /// `Send`.
    pub fn serve_connection_with_upgrades<I, S>(
        &self,
        io: I,
        service: S,
    ) -> UpgradeableConnection<'_, I, S>
    where
        S: Service<Request<Incoming>, Output = Response, Error = Infallible>,
        I: AsyncRead + AsyncWrite + Send + Unpin + 'static,
    {
        UpgradeableConnection {
            state: UpgradeableConnState::ReadVersion {
                read_version: read_version(io, self.detection_timer()),
                builder: Cow::Borrowed(self),
                service: Some(service),
            },
        }
    }

    /// The deadlines of protocol detection, handed on to the detected protocol.
    fn detection_timer(&self) -> ConnTimer {
        ConnTimer::new(
            self.http1.h1_idle_timeout,
            self.http1.h1_header_read_timeout,
        )
    }
}

#[derive(Copy, Clone, Debug)]
enum Version {
    H1,
    H2,
}

fn read_version<I>(io: I, timer: ConnTimer) -> ReadVersion<I>
where
    I: AsyncRead + Unpin,
{
    ReadVersion {
        io: Some(io),
        buf: [0; 24],
        filled: 0,
        version: Version::H2,
        cancelled: false,
        timer,
        _pin: PhantomPinned,
    }
}

pin_project! {
    struct ReadVersion<I> {
        io: Option<I>,
        buf: [u8; 24],
        // the amount of `buf` thats been filled
        filled: usize,
        version: Version,
        cancelled: bool,
        timer: ConnTimer,
        // Make this future `!Unpin` for compatibility with async trait methods.
        #[pin]
        _pin: PhantomPinned,
    }
}

impl<I> ReadVersion<I> {
    pub fn cancel(self: Pin<&mut Self>) {
        *self.project().cancelled = true;
    }
}

impl<I> Future for ReadVersion<I>
where
    I: AsyncRead + Unpin,
{
    type Output = io::Result<(Version, Rewind<I>, ConnTimer)>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let this = self.project();
        if *this.cancelled {
            return Poll::Ready(Err(io::Error::new(io::ErrorKind::Interrupted, "Cancelled")));
        }

        let mut buf = ReadBuf::new(&mut *this.buf);
        buf.advance(*this.filled);

        // We start as H2 and switch to H1 as soon as we don't have the preface.
        while buf.filled().len() < H2_PREFACE.len() {
            let Some(io) = this.io.as_mut() else {
                return Poll::Ready(Err(std::io::Error::other(BoxError::from_static_str(
                    "unexpected error: ReadVersion(..., >IO<) already taken in earlier Poll::ready, cannot read from it, report bug in rama repo",
                ))));
            };

            let len = buf.filled().len();
            match Pin::new(io).poll_read(cx, &mut buf) {
                Poll::Ready(result) => result?,
                Poll::Pending => {
                    let activity = if buf.filled().is_empty() {
                        Activity::Idle
                    } else {
                        Activity::Head {
                            bytes: buf.filled().len() as u64,
                            block: 0,
                        }
                    };
                    if this.timer.poll(cx, activity).is_pending() {
                        return Poll::Pending;
                    }
                    // HTTP/1 serves what did not become HTTP/2 in time: it closes an
                    // idle connection cleanly and reports a stalled head.
                    *this.version = Version::H1;
                    break;
                }
            }
            *this.filled = buf.filled().len();

            // We starts as H2 and switch to H1 when we don't get the preface.
            if buf.filled().len() == len
                || buf.filled()[len..] != H2_PREFACE[len..buf.filled().len()]
            {
                *this.version = Version::H1;
                break;
            }
        }

        let Some(io) = this.io.take() else {
            return Poll::Ready(Err(std::io::Error::other(BoxError::from_static_str(
                "unexpected error: ReadVersion(..., >IO<) already taken in earlier Poll::ready, cannot take it again, report bug in rama repo",
            ))));
        };

        let buf = buf.filled().to_vec();
        Poll::Ready(Ok((
            *this.version,
            Rewind::new_buffered(io, Bytes::from(buf)),
            mem::replace(this.timer, ConnTimer::new(None, None)),
        )))
    }
}

pin_project! {
    /// A [`Future`] representing an HTTP/1 connection, returned from
    /// [`Builder::serve_connection`](struct.Builder.html#method.serve_connection).
    ///
    /// To drive HTTP on this connection this future **must be polled**, typically with
    /// `.await`. If it isn't polled, no progress will be made on this connection.
    #[must_use = "futures do nothing unless polled"]
    pub struct Connection<'a, I, S>
    where
        S: Service<Request<Incoming>, Output = Response, Error = Infallible>,
    {
        #[pin]
        state: ConnState<'a, I, S>,
    }
}

// A custom COW, since the libstd is has ToOwned bounds that are too eager.
enum Cow<'a, T> {
    Borrowed(&'a T),
    Owned(T),
}

impl<T> std::ops::Deref for Cow<'_, T> {
    type Target = T;
    fn deref(&self) -> &T {
        match self {
            Cow::Borrowed(t) => t,
            Cow::Owned(t) => t,
        }
    }
}

type Http1Connection<I, S> = http1::Connection<Rewind<I>, S>;

type Http2Connection<I, S> = http2::Connection<Rewind<I>, S>;

pin_project! {
    #[project = ConnStateProj]
    enum ConnState<'a, I, S>
    where
        S: Service<Request<Incoming>, Output = Response, Error = Infallible>,
    {
        ReadVersion {
            #[pin]
            read_version: ReadVersion<I>,
            builder: Cow<'a, Builder>,
            service: Option<S>,
        },
        H1 {
            #[pin]
            conn: Http1Connection<I, S>,
        },
        H2 {
            #[pin]
            conn: Http2Connection<I, S>,
        },
    }
}

impl<I, S> Connection<'_, I, S>
where
    S: Service<Request<Incoming>, Output = Response, Error = Infallible> + Clone,
    I: AsyncRead + AsyncWrite + Send + Unpin + ExtensionsRef + 'static,
{
    /// Start a graceful shutdown process for this connection.
    ///
    /// This `Connection` should continue to be polled until shutdown can finish.
    ///
    /// # Note
    ///
    /// This should only be called while the `Connection` future is still pending. If called after
    /// `Connection::poll` has resolved, this does nothing.
    pub fn graceful_shutdown(self: Pin<&mut Self>) {
        match self.project().state.project() {
            ConnStateProj::ReadVersion { read_version, .. } => read_version.cancel(),
            ConnStateProj::H1 { conn } => conn.graceful_shutdown(),
            ConnStateProj::H2 { conn } => conn.graceful_shutdown(),
        }
    }

    /// Make this Connection static, instead of borrowing from Builder.
    pub fn into_owned(self) -> Connection<'static, I, S>
    where
        Builder: Clone,
    {
        Connection {
            state: match self.state {
                ConnState::ReadVersion {
                    read_version,
                    builder,
                    service,
                } => ConnState::ReadVersion {
                    read_version,
                    service,
                    builder: Cow::Owned(builder.clone()),
                },
                ConnState::H1 { conn } => ConnState::H1 { conn },
                ConnState::H2 { conn } => ConnState::H2 { conn },
            },
        }
    }
}

impl<I, S> Future for Connection<'_, I, S>
where
    S: Service<Request<Incoming>, Output = Response, Error = Infallible> + Clone,
    I: AsyncRead + AsyncWrite + Send + Unpin + ExtensionsRef + 'static,
{
    type Output = Result<(), BoxError>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        loop {
            let mut this = self.as_mut().project();

            match this.state.as_mut().project() {
                ConnStateProj::ReadVersion {
                    read_version,
                    builder,
                    service,
                } => {
                    let (version, io, timer) = ready!(read_version.poll(cx))?;
                    let Some(service) = service.take() else {
                        return Poll::Ready(Err(BoxError::from_static_str(
                            "unexpected error: auto http svc in connection already taken, report bug in rama repo",
                        )));
                    };
                    match version {
                        Version::H1 => {
                            let conn = builder
                                .http1
                                .serve_connection_with_timer(io, service, timer);
                            this.state.set(ConnState::H1 { conn });
                        }
                        Version::H2 => {
                            let conn = builder
                                .http2
                                .serve_connection_with_timer(io, service, timer);
                            this.state.set(ConnState::H2 { conn });
                        }
                    }
                }
                ConnStateProj::H1 { conn } => {
                    return conn.poll(cx).map_err(Into::into);
                }
                ConnStateProj::H2 { conn } => {
                    return conn.poll(cx).map_err(Into::into);
                }
            }
        }
    }
}

pin_project! {
    /// An upgradable [`Connection`], returned by
    /// [`Builder::serve_upgradable_connection`](struct.Builder.html#method.serve_connection_with_upgrades).
    ///
    /// To drive HTTP on this connection this future **must be polled**, typically with
    /// `.await`. If it isn't polled, no progress will be made on this connection.
    #[must_use = "futures do nothing unless polled"]
    pub struct UpgradeableConnection<'a, I, S>
    where
        S: Service<Request<Incoming>, Output = Response, Error = Infallible>,
    {
        #[pin]
        state: UpgradeableConnState<'a, I, S>,
    }
}

type Http1UpgradeableConnection<I, S> = http1::UpgradeableConnection<I, S>;

pin_project! {
    #[project = UpgradeableConnStateProj]
    enum UpgradeableConnState<'a, I, S>
    where
        S: Service<Request<Incoming>, Output = Response, Error = Infallible>,
    {
        ReadVersion {
            #[pin]
            read_version: ReadVersion<I>,
            builder: Cow<'a, Builder>,
            service: Option<S>,
        },
        H1 {
            #[pin]
            conn: Http1UpgradeableConnection<Rewind<I>, S>,
        },
        H2 {
            #[pin]
            conn: Http2Connection<I, S>,
        },
    }
}

impl<I, S> UpgradeableConnection<'_, I, S>
where
    S: Service<Request<Incoming>, Output = Response, Error = Infallible> + Clone,
    I: AsyncRead + AsyncWrite + Send + Unpin + ExtensionsRef + 'static,
{
    /// Start a graceful shutdown process for this connection.
    ///
    /// This `UpgradeableConnection` should continue to be polled until shutdown can finish.
    ///
    /// # Note
    ///
    /// This should only be called while the `Connection` future is still nothing. pending. If
    /// called after `UpgradeableConnection::poll` has resolved, this does nothing.
    pub fn graceful_shutdown(self: Pin<&mut Self>) {
        match self.project().state.project() {
            UpgradeableConnStateProj::ReadVersion { read_version, .. } => read_version.cancel(),
            UpgradeableConnStateProj::H1 { conn } => conn.graceful_shutdown(),
            UpgradeableConnStateProj::H2 { conn } => conn.graceful_shutdown(),
        }
    }

    /// Make this Connection static, instead of borrowing from Builder.
    pub fn into_owned(self) -> UpgradeableConnection<'static, I, S>
    where
        Builder: Clone,
    {
        UpgradeableConnection {
            state: match self.state {
                UpgradeableConnState::ReadVersion {
                    read_version,
                    builder,
                    service,
                } => UpgradeableConnState::ReadVersion {
                    read_version,
                    service,
                    builder: Cow::Owned(builder.clone()),
                },
                UpgradeableConnState::H1 { conn } => UpgradeableConnState::H1 { conn },
                UpgradeableConnState::H2 { conn } => UpgradeableConnState::H2 { conn },
            },
        }
    }
}

impl<I, S> Future for UpgradeableConnection<'_, I, S>
where
    S: Service<Request<Incoming>, Output = Response, Error = Infallible> + Clone,
    I: AsyncRead + AsyncWrite + Send + Unpin + ExtensionsRef + 'static,
{
    type Output = Result<(), BoxError>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        loop {
            let mut this = self.as_mut().project();

            match this.state.as_mut().project() {
                UpgradeableConnStateProj::ReadVersion {
                    read_version,
                    builder,
                    service,
                } => {
                    let (version, io, timer) = ready!(read_version.poll(cx))?;
                    let Some(service) = service.take() else {
                        return Poll::Ready(Err(BoxError::from_static_str(
                            "unexpected error: auto http svc in upgradeable connection already taken, report bug in rama repo",
                        )));
                    };
                    match version {
                        Version::H1 => {
                            let conn = builder
                                .http1
                                .serve_connection_with_timer(io, service, timer)
                                .with_upgrades();
                            this.state.set(UpgradeableConnState::H1 { conn });
                        }
                        Version::H2 => {
                            let conn = builder
                                .http2
                                .serve_connection_with_timer(io, service, timer);
                            this.state.set(UpgradeableConnState::H2 { conn });
                        }
                    }
                }
                UpgradeableConnStateProj::H1 { conn } => {
                    return conn.poll(cx).map_err(Into::into);
                }
                UpgradeableConnStateProj::H2 { conn } => {
                    return conn.poll(cx).map_err(Into::into);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::client::conn::http1;
    use crate::server::conn::auto;
    use crate::service::RamaHttpService;
    use crate::{body::Bytes, client};
    use rama_core::ServiceInput;
    use rama_core::error::BoxError;
    use rama_core::rt::Executor;
    use rama_core::service::service_fn;
    use rama_http::StreamingBody;
    use rama_http_types::body::util::{BodyExt, Empty};
    use rama_http_types::{Request, Response};
    use std::{convert::Infallible, net::SocketAddr, time::Duration};
    use tokio::{
        net::{TcpListener, TcpStream},
        pin,
    };

    const BODY: &[u8] = b"Hello, world!";

    #[test]
    fn configuration() {
        // Using variable.
        let mut builder = auto::Builder::new(Executor::new());

        builder.http1_mut().set_keep_alive(true);
        builder.h2_mut().maybe_set_keep_alive_interval(None);
        // builder.serve_connection(io, service);
    }

    #[cfg(not(miri))]
    #[tokio::test]
    async fn http1() {
        let addr = start_server(false, false).await;
        let mut sender = connect_h1(addr).await;

        let response = sender
            .send_request(Request::new(Empty::<Bytes>::new()))
            .await
            .unwrap();

        let body = response.into_body().collect().await.unwrap().to_bytes();

        assert_eq!(body, BODY);
    }

    #[cfg(not(miri))]
    #[tokio::test]
    async fn http2() {
        let addr = start_server(false, false).await;
        let mut sender = connect_h2(addr).await;

        let response = sender
            .send_request(Request::new(Empty::<Bytes>::new()))
            .await
            .unwrap();

        let body = response.into_body().collect().await.unwrap().to_bytes();

        assert_eq!(body, BODY);
    }

    #[cfg(not(miri))]
    #[tokio::test]
    async fn http2_only() {
        let addr = start_server(false, true).await;
        let mut sender = connect_h2(addr).await;

        let response = sender
            .send_request(Request::new(Empty::<Bytes>::new()))
            .await
            .unwrap();

        let body = response.into_body().collect().await.unwrap().to_bytes();

        assert_eq!(body, BODY);
    }

    #[cfg(not(miri))]
    #[tokio::test]
    async fn http2_only_fail_if_client_is_http1() {
        let addr = start_server(false, true).await;
        let mut sender = connect_h1(addr).await;

        _ = sender
            .send_request(Request::new(Empty::<Bytes>::new()))
            .await
            .expect_err("should fail");
    }

    #[cfg(not(miri))]
    #[tokio::test]
    async fn http1_only() {
        let addr = start_server(true, false).await;
        let mut sender = connect_h1(addr).await;

        let response = sender
            .send_request(Request::new(Empty::<Bytes>::new()))
            .await
            .unwrap();

        let body = response.into_body().collect().await.unwrap().to_bytes();

        assert_eq!(body, BODY);
    }

    #[cfg(not(miri))]
    #[tokio::test]
    async fn http1_only_fail_if_client_is_http2() {
        let addr = start_server(true, false).await;
        let mut sender = connect_h2(addr).await;

        _ = sender
            .send_request(Request::new(Empty::<Bytes>::new()))
            .await
            .expect_err("should fail");
    }

    #[cfg(not(miri))]
    #[tokio::test]
    async fn graceful_shutdown() {
        use rama_core::{ServiceInput, service::service_fn};

        use crate::service::RamaHttpService;

        let listener = TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], 0)))
            .await
            .unwrap();

        let listener_addr = listener.local_addr().unwrap();

        // Spawn the task in background so that we can connect there
        let listen_task = tokio::spawn(async move { listener.accept().await.unwrap() });
        // Only connect a stream, do not send headers or anything
        let _stream = TcpStream::connect(listener_addr).await.unwrap();

        let (stream, _) = listen_task.await.unwrap();
        let stream = ServiceInput::new(stream);

        let builder = auto::Builder::new(Executor::new());
        let connection = builder.serve_connection(stream, RamaHttpService::new(service_fn(hello)));

        pin!(connection);

        connection.as_mut().graceful_shutdown();

        let connection_error = tokio::time::timeout(Duration::from_millis(200), connection)
            .await
            .expect("Connection should have finished in a timely manner after graceful shutdown.")
            .expect_err("Connection should have been interrupted.");

        let connection_error = connection_error
            .downcast_ref::<std::io::Error>()
            .expect("The error should have been `std::io::Error`.");
        assert_eq!(connection_error.kind(), std::io::ErrorKind::Interrupted);
    }

    async fn connect_h1<B>(addr: SocketAddr) -> client::conn::http1::SendRequest<B>
    where
        B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
    {
        let stream = TcpStream::connect(addr).await.unwrap();
        let stream = ServiceInput::new(stream);
        let (sender, connection) = http1::handshake(stream).await.unwrap();

        tokio::spawn(connection);

        sender
    }

    async fn connect_h2<B>(addr: SocketAddr) -> client::conn::http2::SendRequest<B>
    where
        B: StreamingBody<Data: Send + 'static, Error: Into<BoxError>> + Send + 'static + Unpin,
    {
        let stream = TcpStream::connect(addr).await.unwrap();
        let stream = ServiceInput::new(stream);
        let (sender, connection) = client::conn::http2::Builder::new(Executor::new())
            .handshake(stream)
            .await
            .unwrap();

        tokio::spawn(connection);

        sender
    }

    async fn start_server(h1_only: bool, h2_only: bool) -> SocketAddr {
        let addr: SocketAddr = ([127, 0, 0, 1], 0).into();
        let listener = TcpListener::bind(addr).await.unwrap();

        let local_addr = listener.local_addr().unwrap();

        tokio::spawn(async move {
            loop {
                let (stream, _) = listener.accept().await.unwrap();
                let stream = ServiceInput::new(stream);
                tokio::spawn(async move {
                    let mut builder = auto::Builder::new(Executor::new());
                    if h1_only {
                        builder = builder.http1_only();
                        builder
                            .serve_connection(stream, RamaHttpService::new(service_fn(hello)))
                            .await
                    } else if h2_only {
                        builder = builder.h2_only();
                        builder
                            .serve_connection(stream, RamaHttpService::new(service_fn(hello)))
                            .await
                    } else {
                        builder.h2_mut().set_max_header_list_size(4096);
                        builder
                            .serve_connection(stream, RamaHttpService::new(service_fn(hello)))
                            .await
                    }
                    .unwrap();
                });
            }
        });

        local_addr
    }

    async fn hello(_req: Request) -> Result<Response, Infallible> {
        Ok(Response::new(rama_http_types::Body::from(BODY)))
    }
}

#[cfg(test)]
mod timeout_tests {
    use super::{Builder, H2_PREFACE, Version, read_version};
    use crate::{
        server::conn::{HeaderReadTimeout, IdleTimeout, timeout::ConnTimer},
        service::RamaHttpService,
    };
    use rama_core::{ServiceInput, error::BoxError, rt::Executor, service::service_fn};
    use rama_http_types::{Body, Request, Response};
    use std::{convert::Infallible, future::poll_fn, task::Poll, time::Duration};
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt, DuplexStream, duplex},
        pin, spawn,
        task::{JoinHandle, yield_now},
        time::{Instant, advance},
    };

    const SECOND: Duration = Duration::from_secs(1);

    fn default_timer() -> ConnTimer {
        ConnTimer::new(Some(IdleTimeout::DEFAULT), Some(HeaderReadTimeout::DEFAULT))
    }

    fn serve(builder: Builder) -> (DuplexStream, JoinHandle<Result<(), BoxError>>) {
        let (client, server) = duplex(64 * 1024);
        let task = spawn(async move {
            builder
                .serve_connection(
                    ServiceInput::new(server),
                    RamaHttpService::new(service_fn(async |_: Request| {
                        Ok::<_, Infallible>(Response::new(Body::empty()))
                    })),
                )
                .await
        });
        (client, task)
    }

    async fn settle() {
        for _ in 0..16 {
            yield_now().await;
        }
    }

    fn is_header_timeout(error: &BoxError) -> bool {
        error
            .downcast_ref::<crate::Error>()
            .is_some_and(crate::Error::is_timeout)
    }

    #[tokio::test(start_paused = true)]
    async fn a_late_preface_is_handed_to_http1_with_its_timer() {
        for partial in [false, true] {
            let (mut client, server) = duplex(64);
            if partial {
                client.write_all(b"PRI *").await.unwrap();
            }
            let started = Instant::now();
            let (version, mut io, _timer) = read_version(server, default_timer()).await.unwrap();
            assert!(matches!(version, Version::H1));
            assert_eq!(started.elapsed(), SECOND * 10);
            if partial {
                let mut bytes = [0; 5];
                io.read_exact(&mut bytes).await.unwrap();
                assert_eq!(&bytes, b"PRI *", "the received bytes are rewound");
            }
        }
    }

    #[tokio::test(start_paused = true)]
    async fn fragmented_preface_survives_repoll_and_is_rewound() {
        let (mut client, server) = duplex(64);
        client.write_all(&H2_PREFACE[..5]).await.unwrap();
        let future = read_version(server, default_timer());
        pin!(future);
        assert!(
            poll_fn(|cx| Poll::Ready(future.as_mut().poll(cx)))
                .await
                .is_pending()
        );
        client.write_all(&H2_PREFACE[5..]).await.unwrap();
        let (version, mut io, _timer) = future.await.unwrap();
        assert!(matches!(version, Version::H2));
        let mut bytes = [0; 24];
        io.read_exact(&mut bytes).await.unwrap();
        assert_eq!(bytes, H2_PREFACE);
    }

    #[tokio::test(start_paused = true)]
    async fn protocol_preface_deadlines_can_be_disabled() {
        let (_client, server) = duplex(64);
        let future = read_version(server, ConnTimer::new(None, None));
        pin!(future);
        assert!(
            poll_fn(|cx| Poll::Ready(future.as_mut().poll(cx)))
                .await
                .is_pending()
        );
        advance(Duration::from_hours(1)).await;
        assert!(
            poll_fn(|cx| Poll::Ready(future.as_mut().poll(cx)))
                .await
                .is_pending()
        );
    }

    #[tokio::test(start_paused = true)]
    async fn idle_before_any_byte_closes_cleanly() {
        let (mut client, task) = serve(Builder::new(Executor::new()));
        let started = Instant::now();
        task.await.unwrap().unwrap();
        assert_eq!(started.elapsed(), SECOND * 10);
        let mut rest = Vec::new();
        client.read_to_end(&mut rest).await.unwrap();
        assert!(rest.is_empty());
    }

    #[tokio::test(start_paused = true)]
    async fn stalled_preface_is_a_head_timeout() {
        let (mut client, task) = serve(Builder::new(Executor::new()));
        client.write_all(b"PRI * HTTP/2.0").await.unwrap();
        let started = Instant::now();
        let error = task.await.unwrap().unwrap_err();
        assert!(is_header_timeout(&error), "{error}");
        assert_eq!(started.elapsed(), SECOND * 10);
    }

    #[tokio::test(start_paused = true)]
    async fn http1_detected_late_keeps_the_head_start() {
        let (mut client, task) = serve(Builder::new(Executor::new()));
        let started = Instant::now();
        // Matches the HTTP/2 preface, so detection waits for the next byte.
        client.write_all(b"P").await.unwrap();
        settle().await;
        advance(SECOND * 5).await;
        client.write_all(b"OST / HTTP/1.1\r\n").await.unwrap();
        settle().await;
        assert!(!task.is_finished());
        let error = task.await.unwrap().unwrap_err();
        assert!(is_header_timeout(&error), "{error}");
        assert_eq!(
            started.elapsed(),
            SECOND * 10,
            "the head started with its first byte, before detection"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn http2_detected_late_keeps_the_first_request_window() {
        let (mut client, task) = serve(Builder::new(Executor::new()));
        let started = Instant::now();
        settle().await;
        advance(SECOND * 5).await;
        client.write_all(H2_PREFACE).await.unwrap();
        // An empty SETTINGS frame.
        client
            .write_all(&[0, 0, 0, 4, 0, 0, 0, 0, 0])
            .await
            .unwrap();
        task.await.unwrap().unwrap();
        // The GOAWAY at 10 s plus the unacknowledged drain.
        assert_eq!(
            started.elapsed(),
            SECOND * 11,
            "the first request window counts from the connection's first idle phase"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn http1_request_over_auto_earns_the_idle_budget() {
        let (mut client, task) = serve(Builder::new(Executor::new()));
        client
            .write_all(b"GET / HTTP/1.1\r\nHost: test\r\n\r\n")
            .await
            .unwrap();
        let mut response = [0; 1024];
        let n = client.read(&mut response).await.unwrap();
        assert!(response[..n].starts_with(b"HTTP/1.1 200"));
        let idle = Instant::now();
        task.await.unwrap().unwrap();
        assert_eq!(idle.elapsed(), SECOND * 90);
    }
}
