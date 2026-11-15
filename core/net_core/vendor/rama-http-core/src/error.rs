//! Error and Result module.

use rama_core::error::BoxErrorExt as _;
use std::error::Error as StdError;
use std::fmt;

use crate::h2;
use rama_core::error::{BoxError, ErrorExt as _};
use rama_http_types as http;

/// Result type often returned from methods that can have hyper `Error`s.
pub type Result<T> = std::result::Result<T, Error>;

/// Represents errors that can occur handling HTTP streams.
///
/// # Formatting
///
/// The `Display` implementation of this type will only print the details of
/// this level of error, even though it may have been caused by another error
/// and contain that error in its source. To print all the relevant
/// information, including the source chain, using something like
/// `std::error::Report`, or equivalent 3rd party types.
///
/// The contents of the formatted error message of this specific `Error` type
/// is unspecified. **You must not depend on it.** The wording and details may
/// change in any version, with the goal of improving error messages.
///
/// # Source
///
/// A `rama_http_core::Error` may be caused by another error. To aid in debugging,
/// those are exposed in `Error::source()` as erased types. While it is
/// possible to check the exact type of the sources, they **can not be depended
/// on**. They may come from private internal dependencies, and are subject to
/// change at any moment.
pub struct Error {
    inner: Box<ErrorImpl>,
}

struct ErrorImpl {
    kind: Kind,
    cause: Option<BoxError>,
}

#[derive(Debug)]
pub(super) enum Kind {
    Parse(Parse),
    User(User),
    /// A message reached EOF, but is not complete.
    IncompleteMessage,
    /// A connection received a message (or bytes) when not waiting for one.
    UnexpectedMessage,
    /// A pending item was dropped before ever being processed.
    Canceled,
    /// Indicates a channel (client or body sender) is closed.
    ChannelClosed,
    /// An `io::Error` that occurred while trying to read or write to a network stream.
    Io,
    /// User took too long to send headers.
    HeaderTimeout,
    /// Error while reading a body from connection.
    Body,
    /// Error while writing a body to connection.
    BodyWrite,
    /// Error calling `AsyncWrite::shutdown()`.
    Shutdown,

    /// A general error from h2.
    Http2,
    /// The h2 peer refused a request without processing it.
    Http2Refused,
}

#[derive(Debug)]
pub(super) enum Parse {
    Method,
    Version,
    VersionH2,
    Uri,
    UriTooLong,
    Header(Header),
    TooLarge,
    Status,
    Internal,
}

#[derive(Debug)]
pub(super) enum Header {
    Token,
    ContentLengthInvalid,
    TransferEncodingInvalid,
    TransferEncodingUnexpected,
}

#[derive(Debug)]
pub(super) enum User {
    /// Error calling the user's `Body::poll_data()`.
    Body,
    /// The user aborted writing of the outgoing body.
    BodyWriteAborted,
    /// Error from future of user's Service.
    Service,
    /// User tried to send a certain header in an unexpected context.
    ///
    /// For example, sending both `content-length` and `transfer-encoding`.
    UnexpectedHeader,
    /// User tried to send a request target its method cannot carry, such as a CONNECT
    /// without a port.
    InvalidTarget,
    /// User tried to respond with a 1xx (not 101) response code.
    UnsupportedStatusCode,

    /// The dispatch task is gone.
    DispatchGone,
}

// Sentinel type to indicate the error was caused by a timeout.
#[derive(Debug)]
pub(super) struct TimedOut;

impl Error {
    /// Returns true if this was an HTTP parse error.
    ///
    /// This can be caused by a malformed HTTP message, an invalid header,
    /// an invalid URI, an invalid HTTP version, or a message head that is
    /// too large. Use the more specific `is_parse_*` methods to determine
    /// the exact cause.
    #[must_use]
    #[inline(always)]
    pub fn is_parse(&self) -> bool {
        matches!(self.inner.kind, Kind::Parse(_))
    }

    /// Returns true if this was an HTTP parse error caused by a message that was too large.
    ///
    /// This is triggered when the message head (request line plus headers for
    /// HTTP/1, or header frame for HTTP/2) exceeds the configured
    /// `max_buf_size`. It also covers the case where the URI alone exceeds the internal
    /// maximum URI length.
    #[must_use]
    #[inline(always)]
    pub fn is_parse_too_large(&self) -> bool {
        matches!(
            self.inner.kind,
            Kind::Parse(Parse::TooLarge | Parse::UriTooLong)
        )
    }

    /// Returns true if this was an HTTP parse error caused by an invalid response status code or
    /// reason phrase.
    #[must_use]
    #[inline(always)]
    pub fn is_parse_status(&self) -> bool {
        matches!(self.inner.kind, Kind::Parse(Parse::Status))
    }

    /// Returns true if this error was caused by user code.
    ///
    /// For example, this can be returned when the user's `Service` returns
    /// an error, the user's `Body` stream yields an error, or the user
    /// sends an unexpected header combination (such as both
    /// `content-length` and `transfer-encoding`).
    #[must_use]
    #[inline(always)]
    pub fn is_user(&self) -> bool {
        matches!(self.inner.kind, Kind::User(_))
    }

    /// Returns true if this was an HTTP parse error caused by HTTP2 preface sent over an HTTP1
    /// connection.
    ///
    /// This can happen when a client sends an HTTP/2 connection preface to a
    /// server that is only expecting HTTP/1.x requests.
    pub fn is_parse_version_h2(&self) -> bool {
        matches!(self.inner.kind, Kind::Parse(Parse::VersionH2))
    }

    /// Returns true if this was about a `Request` that was canceled.
    ///
    /// This typically happens when a pending request is dropped before
    /// it can be dispatched to the connection, for example because the
    /// connection was not ready.
    #[must_use]
    #[inline(always)]
    pub fn is_canceled(&self) -> bool {
        matches!(self.inner.kind, Kind::Canceled)
    }

    /// Returns true if a sender's channel is closed.
    ///
    /// This can occur when the other side of a client or body channel
    /// has been dropped, indicating that the receiver is no longer
    /// interested in the data.
    #[must_use]
    #[inline(always)]
    pub fn is_closed(&self) -> bool {
        matches!(self.inner.kind, Kind::ChannelClosed)
    }

    /// Returns true if the HTTP/2 peer refused this request without processing it,
    /// which makes it safe to retry, even when not idempotent (RFC 9113 section 8.7).
    ///
    /// The peer either reset its stream with `REFUSED_STREAM`, or went away
    /// with a `GOAWAY` that does not cover its stream. Only a request's own
    /// error can be refused, never a connection's.
    #[must_use]
    #[inline(always)]
    pub fn is_refused(&self) -> bool {
        matches!(self.inner.kind, Kind::Http2Refused)
    }

    /// Returns true if the connection closed before a message could complete.
    ///
    /// This means that the supplied IO connection reported EOF (closed) while
    /// hyper's HTTP state indicates more of the message (either request or
    /// response) needed to be transmitted.
    ///
    /// Some cases this could happen (not exhaustive):
    ///
    /// - A request is written on a connection, and the next `read` reports
    ///   EOF (perhaps a server just closed an "idle" connection).
    /// - A message body is only partially receive before the connection
    ///   reports EOF.
    /// - A client writes a request to your server, and then closes the write
    ///   half while waiting for your response. If you need to support this,
    ///   consider enabling [`half_close`].
    ///
    /// [`half_close`]: crate::server::conn::http1::Builder::with_half_close()
    #[inline(always)]
    #[must_use]
    pub fn is_incomplete_message(&self) -> bool {
        matches!(self.inner.kind, Kind::IncompleteMessage)
    }

    /// Returns true if the body write was aborted.
    ///
    /// This occurs when the user's code explicitly aborts writing of the
    /// outgoing body before it completes, for example by dropping the
    /// body sender.
    #[inline(always)]
    #[must_use]
    pub fn is_body_write_aborted(&self) -> bool {
        matches!(self.inner.kind, Kind::User(User::BodyWriteAborted))
    }

    /// Returns true if the error was caused while calling `AsyncWrite::shutdown()`.
    ///
    /// This can happen when the connection is being gracefully shut down
    /// and the underlying IO reports an error during the shutdown sequence.
    #[inline(always)]
    #[must_use]
    pub fn is_shutdown(&self) -> bool {
        matches!(self.inner.kind, Kind::Shutdown)
    }

    /// Returns true if the error was caused by a timeout.
    ///
    /// For HTTP/1 and HTTP/2 servers, this includes the header read timeout (see
    /// [`http1::Builder::set_header_read_timeout`](crate::server::conn::http1::Builder::set_header_read_timeout)
    /// and [`http2::Builder::set_header_read_timeout`](crate::server::conn::http2::Builder::set_header_read_timeout)).
    /// It also covers any timeout set via a user-provided timer
    #[inline(always)]
    #[must_use]
    pub fn is_timeout(&self) -> bool {
        if matches!(self.inner.kind, Kind::HeaderTimeout) {
            return true;
        }
        self.find_source::<TimedOut>().is_some()
    }

    #[inline(always)]
    pub(super) fn new(kind: Kind) -> Self {
        Self {
            inner: Box::new(ErrorImpl { kind, cause: None }),
        }
    }

    #[inline(always)]
    pub(super) fn with<C: Into<BoxError>>(mut self, cause: C) -> Self {
        self.inner.cause = Some(cause.into());
        self
    }

    #[inline(always)]
    pub(super) fn with_display(
        mut self,
        msg: impl std::fmt::Display + std::fmt::Debug + Send + Sync + 'static,
    ) -> Self {
        self.inner.cause = Some(BoxError::from_static_str("http error cause").context(msg));
        self
    }

    #[inline(always)]
    pub(super) fn kind(&self) -> &Kind {
        &self.inner.kind
    }

    pub(crate) fn find_source<E: StdError + 'static>(&self) -> Option<&E> {
        // Public predicates also inspect user-provided causes, which may cycle.
        rama_core::error::error_chain(self.source()?).find_map(|error| error.downcast_ref())
    }

    pub(super) fn h2_reason(&self) -> h2::Reason {
        // Find an h2::Reason somewhere in the cause stack, if it exists,
        // otherwise assume an INTERNAL_ERROR.
        self.find_source::<h2::Error>()
            .and_then(|h2_err| h2_err.reason())
            .unwrap_or(h2::Reason::INTERNAL_ERROR)
    }

    #[inline(always)]
    pub(super) fn new_canceled() -> Self {
        Self::new(Kind::Canceled)
    }

    #[inline(always)]
    pub(super) fn new_parse_internal() -> Self {
        Self::new(Kind::Parse(Parse::Internal))
    }

    #[inline(always)]
    pub(super) fn new_incomplete() -> Self {
        Self::new(Kind::IncompleteMessage)
    }

    #[inline(always)]
    pub(super) fn new_too_large() -> Self {
        Self::new(Kind::Parse(Parse::TooLarge))
    }

    #[inline(always)]
    pub(super) fn new_version_h2() -> Self {
        Self::new(Kind::Parse(Parse::VersionH2))
    }

    #[inline(always)]
    pub(super) fn new_unexpected_message() -> Self {
        Self::new(Kind::UnexpectedMessage)
    }

    #[inline(always)]
    pub(super) fn new_io(cause: std::io::Error) -> Self {
        Self::new(Kind::Io).with(cause)
    }

    #[inline(always)]
    pub(super) fn new_closed() -> Self {
        Self::new(Kind::ChannelClosed)
    }

    #[inline(always)]
    pub(super) fn new_body<E: Into<BoxError>>(cause: E) -> Self {
        Self::new(Kind::Body).with(cause)
    }

    #[inline(always)]
    pub(super) fn new_body_write<E: Into<BoxError>>(cause: E) -> Self {
        Self::new(Kind::BodyWrite).with(cause)
    }

    #[inline(always)]
    pub(super) fn new_body_write_aborted() -> Self {
        Self::new(Kind::User(User::BodyWriteAborted))
    }

    #[inline(always)]
    fn new_user(user: User) -> Self {
        Self::new(Kind::User(user))
    }

    #[inline(always)]
    pub(super) fn new_user_header() -> Self {
        Self::new_user(User::UnexpectedHeader)
    }

    #[inline(always)]
    pub(super) fn new_user_target() -> Self {
        Self::new_user(User::InvalidTarget)
    }

    #[inline(always)]
    pub(super) fn new_header_timeout() -> Self {
        Self::new(Kind::HeaderTimeout)
    }

    #[inline(always)]
    pub(super) fn new_user_unsupported_status_code() -> Self {
        Self::new_user(User::UnsupportedStatusCode)
    }

    #[inline(always)]
    pub(super) fn new_user_service<E: Into<BoxError>>(cause: E) -> Self {
        Self::new_user(User::Service).with(cause)
    }

    #[inline(always)]
    pub(super) fn new_user_body<E: Into<BoxError>>(cause: E) -> Self {
        Self::new_user(User::Body).with(cause)
    }

    #[inline(always)]
    pub(super) fn new_shutdown(cause: std::io::Error) -> Self {
        Self::new(Kind::Shutdown).with(cause)
    }

    #[inline(always)]
    pub(super) fn new_user_dispatch_gone() -> Self {
        Self::new(Kind::User(User::DispatchGone))
    }

    #[inline(always)]
    pub(super) fn new_h2(cause: h2::Error) -> Self {
        match cause.try_into_io() {
            Ok(io_err) => Self::new_io(io_err),
            Err(cause) => Self::new(Kind::Http2).with(cause),
        }
    }

    /// Only for the error of one request: its own stream outcome, or it was never opened.
    pub(super) fn new_h2_request(cause: h2::Error) -> Self {
        // a remote GOAWAY only reaches a request when it does not cover that request
        if cause.is_remote()
            && (cause.is_go_away() || cause.reason() == Some(h2::Reason::REFUSED_STREAM))
        {
            Self::new(Kind::Http2Refused).with(cause)
        } else {
            Self::new_h2(cause)
        }
    }

    fn description(&self) -> &str {
        match self.inner.kind {
            Kind::Parse(Parse::Method) => "invalid HTTP method parsed",
            Kind::Parse(Parse::Version) => "invalid HTTP version parsed",
            Kind::Parse(Parse::VersionH2) => "invalid HTTP version parsed (found HTTP2 preface)",
            Kind::Parse(Parse::Uri) => "invalid URI",
            Kind::Parse(Parse::UriTooLong) => "URI too long",
            Kind::Parse(Parse::Header(Header::Token)) => "invalid HTTP header parsed",
            Kind::Parse(Parse::Header(Header::ContentLengthInvalid)) => {
                "invalid content-length parsed"
            }
            Kind::Parse(Parse::Header(Header::TransferEncodingInvalid)) => {
                "invalid transfer-encoding parsed"
            }
            Kind::Parse(Parse::Header(Header::TransferEncodingUnexpected)) => {
                "unexpected transfer-encoding parsed"
            }
            Kind::Parse(Parse::TooLarge) => "message head is too large",
            Kind::Parse(Parse::Status) => "invalid HTTP status-code parsed",
            Kind::Parse(Parse::Internal) => {
                "internal error inside rama_http_core and/or its dependencies, please report"
            }
            Kind::IncompleteMessage => "connection closed before message completed",
            Kind::UnexpectedMessage => "received unexpected message from connection",
            Kind::ChannelClosed => "channel closed",
            Kind::Canceled => "operation was canceled",
            Kind::HeaderTimeout => "read header from client timeout",
            Kind::Body => "error reading a body from connection",
            Kind::BodyWrite => "error writing a body to connection",
            Kind::Shutdown => "error shutting down connection",
            Kind::Http2 => "http2 error",
            Kind::Http2Refused => "http2 request refused by peer",
            Kind::Io => "connection error",
            Kind::User(User::Body) => "error from user's Body stream",
            Kind::User(User::BodyWriteAborted) => "user body write aborted",
            Kind::User(User::Service) => "error from user's Service",
            Kind::User(User::UnexpectedHeader) => "user sent unexpected header",
            Kind::User(User::InvalidTarget) => "user sent an invalid request target",
            Kind::User(User::UnsupportedStatusCode) => {
                "response has 1xx status code, not supported by server"
            }
            Kind::User(User::DispatchGone) => "dispatch task is gone",
        }
    }
}

impl fmt::Debug for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut f = f.debug_tuple("rama_http_core::Error");
        f.field(&self.inner.kind);
        if let Some(cause) = &self.inner.cause {
            f.field(cause);
        }
        f.finish()
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.description())
    }
}

impl StdError for Error {
    fn source(&self) -> Option<&(dyn StdError + 'static)> {
        self.inner
            .cause
            .as_ref()
            .map(|cause| &**cause as &(dyn StdError + 'static))
    }
}

#[doc(hidden)]
impl From<Parse> for Error {
    fn from(err: Parse) -> Self {
        Self::new(Kind::Parse(err))
    }
}

impl Parse {
    pub(crate) fn content_length_invalid() -> Self {
        Self::Header(Header::ContentLengthInvalid)
    }

    pub(crate) fn transfer_encoding_invalid() -> Self {
        Self::Header(Header::TransferEncodingInvalid)
    }

    pub(crate) fn transfer_encoding_unexpected() -> Self {
        Self::Header(Header::TransferEncodingUnexpected)
    }
}

impl From<httparse::Error> for Parse {
    fn from(err: httparse::Error) -> Self {
        match err {
            httparse::Error::HeaderName
            | httparse::Error::HeaderValue
            | httparse::Error::NewLine
            | httparse::Error::Token => Self::Header(Header::Token),
            httparse::Error::Status => Self::Status,
            httparse::Error::TooManyHeaders => Self::TooLarge,
            httparse::Error::Version => Self::Version,
        }
    }
}

impl From<http::method::InvalidMethod> for Parse {
    fn from(_: http::method::InvalidMethod) -> Self {
        Self::Method
    }
}

impl From<http::status::InvalidStatusCode> for Parse {
    fn from(_: http::status::InvalidStatusCode) -> Self {
        Self::Status
    }
}

impl From<rama_net::uri::ParseError> for Parse {
    fn from(_: rama_net::uri::ParseError) -> Self {
        Self::Uri
    }
}

// ===== impl TimedOut ====

impl fmt::Display for TimedOut {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("operation timed out")
    }
}

impl StdError for TimedOut {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem;

    fn assert_send_sync<T: Send + Sync + 'static>() {}

    #[test]
    fn error_satisfies_send_sync() {
        assert_send_sync::<Error>()
    }

    #[test]
    fn error_size_of() {
        assert_eq!(mem::size_of::<Error>(), mem::size_of::<usize>());
    }

    #[test]
    fn source_inspection_terminates_for_cyclic_causes() {
        #[derive(Debug)]
        struct Cycle;

        impl fmt::Display for Cycle {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str("cycle")
            }
        }

        impl StdError for Cycle {
            fn source(&self) -> Option<&(dyn StdError + 'static)> {
                Some(self)
            }
        }

        let error = Error::new_canceled().with(Cycle);
        assert!(!error.is_timeout());
        assert_eq!(error.h2_reason(), h2::Reason::INTERNAL_ERROR);
    }

    #[test]
    fn timeout_source_inspection_respects_depth_limit() {
        let mut error = Error::new_canceled().with(TimedOut);
        for _ in 0..63 {
            error = Error::new_canceled().with(error);
        }
        assert!(error.is_timeout());
        assert!(!Error::new_canceled().with(error).is_timeout());
    }

    #[test]
    fn h2_reason_unknown() {
        let closed = Error::new_closed();
        assert_eq!(closed.h2_reason(), h2::Reason::INTERNAL_ERROR);
    }

    #[test]
    fn h2_reason_one_level() {
        let body_err = Error::new_user_body(h2::Error::from(h2::Reason::ENHANCE_YOUR_CALM));
        assert_eq!(body_err.h2_reason(), h2::Reason::ENHANCE_YOUR_CALM);
    }

    #[test]
    fn h2_reason_nested() {
        let recvd = Error::new_h2(h2::Error::from(h2::Reason::HTTP_1_1_REQUIRED));
        // Suppose a user were proxying the received error
        let svc_err = Error::new_user_service(recvd);
        assert_eq!(svc_err.h2_reason(), h2::Reason::HTTP_1_1_REQUIRED);
    }
}
