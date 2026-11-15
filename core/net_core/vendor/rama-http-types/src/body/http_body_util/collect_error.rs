use std::fmt;
use std::time::Duration;

use bytes::Bytes;
use rama_core::error::BoxError;

use crate::body::Body;
use crate::body::http_body_util::Full;
use crate::body::http_body_util::combinators::Chain;

/// Error returned by [`BodyExt::collect`] and [`BodyExt::collect_with`] when a
/// body could not be fully buffered.
///
/// Unlike [`Limited`], which hard-fails and discards the body the moment the
/// limit is crossed, a `CollectError` always retains the bytes read so far via
/// [`bytes_read`](Self::bytes_read), and — for size/time stops — the unread
/// remainder, so the original body can be reassembled and forwarded untouched
/// (handy for proxies, see [`into_full_body`](Self::into_full_body)).
///
/// [`BodyExt::collect`]: crate::body::http_body_util::BodyExt::collect
/// [`BodyExt::collect_with`]: crate::body::http_body_util::BodyExt::collect_with
/// [`Limited`]: crate::body::http_body_util::Limited
pub struct CollectError {
    bytes_read: Bytes,
    body_rem: Option<Body>,
    kind: CollectErrorKind,
}

/// Why a [`CollectError`] occurred.
///
/// [`BodyExt::collect`] only ever produces [`Stream`](Self::Stream).
/// [`BodyExt::collect_with`] adds [`CapReached`](Self::CapReached) and
/// [`TimedOut`](Self::TimedOut). The body-extraction helpers (e.g.
/// [`try_into_string_with`]) may additionally produce [`Decode`](Self::Decode)
/// when a fully-buffered body is not valid for the target type.
///
/// [`BodyExt::collect`]: crate::body::http_body_util::BodyExt::collect
/// [`BodyExt::collect_with`]: crate::body::http_body_util::BodyExt::collect_with
/// [`try_into_string_with`]: crate::body::BodyExtractExt::try_into_string_with
#[derive(Debug)]
#[non_exhaustive]
pub enum CollectErrorKind {
    /// The configured size cap was reached. `limit` bytes were buffered; the
    /// rest stayed in the (forwardable) remainder.
    CapReached {
        /// The byte cap that was hit.
        limit: usize,
    },
    /// The configured timeout elapsed before the body finished.
    TimedOut {
        /// The timeout that elapsed.
        after: Duration,
    },
    /// The body yielded an error mid-stream. The remainder is unrecoverable,
    /// but [`bytes_read`](CollectError::bytes_read) still holds what was read.
    Stream(BoxError),
    /// The body was fully buffered but could not be decoded into the requested
    /// type (e.g. invalid UTF-8 or JSON). The full body is still recoverable.
    Decode(BoxError),
}

impl CollectError {
    /// A size/time stop that kept the unread remainder.
    pub(crate) fn stopped(bytes_read: Bytes, remainder: Body, kind: CollectErrorKind) -> Self {
        Self {
            bytes_read,
            body_rem: Some(remainder),
            kind,
        }
    }

    /// A mid-stream body failure: no recoverable remainder.
    pub(crate) fn stream(bytes_read: Bytes, err: BoxError) -> Self {
        Self {
            bytes_read,
            body_rem: None,
            kind: CollectErrorKind::Stream(err),
        }
    }

    /// A decode failure on an otherwise fully-buffered body: everything lives in
    /// `bytes_read`, so the remainder is empty and the body stays forwardable.
    pub(crate) fn decode(bytes_read: Bytes, err: BoxError) -> Self {
        Self {
            bytes_read,
            body_rem: Some(Body::empty()),
            kind: CollectErrorKind::Decode(err),
        }
    }

    /// The bytes that were successfully read before stopping.
    ///
    /// Always available, regardless of [`kind`](Self::kind). Cheap to clone
    /// (a refcounted [`Bytes`]).
    #[must_use]
    pub fn bytes_read(&self) -> Bytes {
        self.bytes_read.clone()
    }

    /// Why the collect stopped.
    #[must_use]
    pub fn kind(&self) -> &CollectErrorKind {
        &self.kind
    }

    /// `true` if stopped because the size cap was reached.
    #[must_use]
    pub fn is_cap_reached(&self) -> bool {
        matches!(self.kind, CollectErrorKind::CapReached { .. })
    }

    /// `true` if stopped because the timeout elapsed.
    #[must_use]
    pub fn is_timed_out(&self) -> bool {
        matches!(self.kind, CollectErrorKind::TimedOut { .. })
    }

    /// `true` if the body errored mid-stream.
    #[must_use]
    pub fn is_stream_error(&self) -> bool {
        matches!(self.kind, CollectErrorKind::Stream(_))
    }

    /// `true` if the body was fully buffered but failed to decode.
    #[must_use]
    pub fn is_decode_error(&self) -> bool {
        matches!(self.kind, CollectErrorKind::Decode(_))
    }

    /// Borrow the unread remainder, if any.
    ///
    /// `None` for a [`Stream`](CollectErrorKind::Stream) error, where the body
    /// cannot be recovered.
    #[must_use]
    pub fn body_rem(&self) -> Option<&Body> {
        self.body_rem.as_ref()
    }

    /// Reassemble the bytes read followed by the unread remainder into a single
    /// [`Body`], ready to forward untouched (e.g. in a proxy).
    ///
    /// Returns `None` for a [`Stream`](CollectErrorKind::Stream) error, where
    /// the remainder is unrecoverable — [`bytes_read`](Self::bytes_read) is
    /// still readable in that case (grab it before calling this).
    #[must_use]
    pub fn into_full_body(self) -> Option<Body> {
        let rem = self.body_rem?;
        Some(Body::new(Chain::new(Full::new(self.bytes_read), rem)))
    }

    /// Take just the unread remainder, dropping the bytes already read.
    ///
    /// `None` for a [`Stream`](CollectErrorKind::Stream) error.
    #[must_use]
    pub fn into_remainder(self) -> Option<Body> {
        self.body_rem
    }

    /// Decompose into the bytes read, the unread remainder (if any), and the kind.
    #[must_use]
    pub fn into_parts(self) -> (Bytes, Option<Body>, CollectErrorKind) {
        (self.bytes_read, self.body_rem, self.kind)
    }
}

impl fmt::Debug for CollectError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CollectError")
            .field("bytes_read", &self.bytes_read.len())
            .field("has_remainder", &self.body_rem.is_some())
            .field("kind", &self.kind)
            .finish()
    }
}

impl fmt::Display for CollectError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let read = self.bytes_read.len();
        match &self.kind {
            CollectErrorKind::CapReached { limit } => {
                write!(f, "body collect stopped: size cap of {limit} bytes reached")
            }
            CollectErrorKind::TimedOut { after } => {
                write!(
                    f,
                    "body collect stopped: timed out after {after:?} ({read} bytes read)"
                )
            }
            CollectErrorKind::Stream(err) => {
                write!(f, "body collect failed after {read} bytes: {err}")
            }
            CollectErrorKind::Decode(err) => {
                write!(
                    f,
                    "body collected ({read} bytes) but failed to decode: {err}"
                )
            }
        }
    }
}

impl std::error::Error for CollectError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match &self.kind {
            CollectErrorKind::Stream(err) | CollectErrorKind::Decode(err) => Some(&**err),
            CollectErrorKind::CapReached { .. } | CollectErrorKind::TimedOut { .. } => None,
        }
    }
}
