//! HTTP-stack error type.
//!
//! Forked from the `http` crate's `Error`, adapted so the URI variant carries
//! rama's native [`rama_net::uri::ParseError`] instead of `http::uri::InvalidUri`
//! (the native [`Uri`](rama_net::uri::Uri) replaces the `http` crate's URI type).

use std::error;
use std::fmt;
use std::result;

use crate::header::MaxSizeReached;
use crate::{header, method, status};

/// A generic "error" for HTTP connections.
///
/// This error type is less specific than the error returned from other
/// functions in this crate, but all other errors can be converted to this
/// error. Consumers of this crate can typically consume and work with this form
/// of error for conversions with the `?` operator.
pub struct Error {
    inner: ErrorKind,
}

/// A `Result` typedef to use with the [`Error`] type.
pub type Result<T> = result::Result<T, Error>;

enum ErrorKind {
    StatusCode(status::InvalidStatusCode),
    Method(method::InvalidMethod),
    Version(rama_net::http::InvalidVersion),
    Uri(rama_net::uri::ParseError),
    HeaderName(header::InvalidHeaderName),
    HeaderValue(header::InvalidHeaderValue),
    MaxSizeReached(MaxSizeReached),
}

impl fmt::Debug for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("rama_http_types::Error")
            // Skip the noise of the ErrorKind enum
            .field(&self.get_ref())
            .finish()
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self.get_ref(), f)
    }
}

impl Error {
    /// Return true if the underlying error has the same type as `T`.
    pub fn is<T: error::Error + 'static>(&self) -> bool {
        self.get_ref().is::<T>()
    }

    /// Return a reference to the lower level, inner error.
    pub fn get_ref(&self) -> &(dyn error::Error + 'static) {
        match self.inner {
            ErrorKind::StatusCode(ref e) => e,
            ErrorKind::Method(ref e) => e,
            ErrorKind::Version(ref e) => e,
            ErrorKind::Uri(ref e) => e,
            ErrorKind::HeaderName(ref e) => e,
            ErrorKind::HeaderValue(ref e) => e,
            ErrorKind::MaxSizeReached(ref e) => e,
        }
    }
}

impl error::Error for Error {
    // Return any available cause from the inner error. Note the inner error is
    // not itself the cause.
    fn source(&self) -> Option<&(dyn error::Error + 'static)> {
        self.get_ref().source()
    }
}

impl From<status::InvalidStatusCode> for Error {
    fn from(err: status::InvalidStatusCode) -> Self {
        Self {
            inner: ErrorKind::StatusCode(err),
        }
    }
}

impl From<method::InvalidMethod> for Error {
    fn from(err: method::InvalidMethod) -> Self {
        Self {
            inner: ErrorKind::Method(err),
        }
    }
}

impl From<rama_net::http::InvalidVersion> for Error {
    fn from(err: rama_net::http::InvalidVersion) -> Self {
        Self {
            inner: ErrorKind::Version(err),
        }
    }
}

impl From<rama_net::uri::ParseError> for Error {
    fn from(err: rama_net::uri::ParseError) -> Self {
        Self {
            inner: ErrorKind::Uri(err),
        }
    }
}

impl From<header::InvalidHeaderName> for Error {
    fn from(err: header::InvalidHeaderName) -> Self {
        Self {
            inner: ErrorKind::HeaderName(err),
        }
    }
}

impl From<header::InvalidHeaderValue> for Error {
    fn from(err: header::InvalidHeaderValue) -> Self {
        Self {
            inner: ErrorKind::HeaderValue(err),
        }
    }
}

impl From<MaxSizeReached> for Error {
    fn from(err: MaxSizeReached) -> Self {
        Self {
            inner: ErrorKind::MaxSizeReached(err),
        }
    }
}

impl From<std::convert::Infallible> for Error {
    fn from(err: std::convert::Infallible) -> Self {
        match err {}
    }
}
