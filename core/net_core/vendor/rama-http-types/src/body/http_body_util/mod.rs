// Forked from the `http-body-util` crate — vendored alongside the forked
// `http-body`. See `docs/thirdparty/fork/README.md`. Fork-style lint allows
// (also cover the child combinator modules).
#![allow(
    unreachable_pub,
    clippy::allow_attributes,
    clippy::style,
    clippy::complexity,
    clippy::perf,
    clippy::suspicious,
    clippy::pedantic,
    clippy::nursery,
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::unreachable,
    clippy::get_unwrap,
    clippy::assertions_on_result_states,
    clippy::let_underscore_must_use,
    clippy::map_err_ignore,
    dead_code,
    mismatched_lifetime_syntaxes
)]
// The group allows above must not cover the workspace's unsafe hygiene lints.
#![warn(
    clippy::missing_safety_doc,
    clippy::missing_transmute_annotations,
    clippy::ptr_as_ptr,
    clippy::ptr_cast_constness,
    clippy::as_ptr_cast_mut,
    clippy::borrow_as_ptr,
    clippy::ref_as_ptr,
    clippy::cast_ptr_alignment,
    clippy::transmute_ptr_to_ptr
)]

//! Utilities for [`crate::body::http_body::Body`].
//!
//! [`BodyExt`] adds extensions to the common trait.
//!
//! [`Empty`] and [`Full`] provide simple implementations.

pub mod channel;
mod collect_error;
mod collect_with;
mod collected;
pub mod combinators;
mod either;
mod empty;
mod error;
mod full;
mod future;
mod limited;
mod pending;
mod stream;

mod util;

use self::combinators::{BoxBody, MapErr, MapFrame, UnsyncBoxBody};
use rama_core::error::BoxError;

pub use self::channel::Channel;
pub use self::collect_error::{CollectError, CollectErrorKind};
pub use self::collect_with::{CollectOptions, CollectWith};
pub use self::collected::Collected;
pub use self::either::Either;
pub use self::empty::Empty;
pub use self::error::ErrorBody;
pub use self::full::Full;
pub use self::future::TryFutureBody;
pub use self::limited::{LengthLimitError, Limited};
pub use self::pending::Pending;
pub use self::stream::{BodyDataStream, BodyStream, StreamBody};

/// An extension trait for [`crate::body::http_body::Body`] adding various combinators and adapters
pub trait BodyExt: crate::body::http_body::Body {
    /// Returns a future that resolves to the next [`Frame`], if any.
    ///
    /// [`Frame`]: combinators::Frame
    fn frame(&mut self) -> combinators::Frame<'_, Self>
    where
        Self: Unpin,
    {
        combinators::Frame(self)
    }

    /// Maps this body's frame to a different kind.
    fn map_frame<F, B>(self, f: F) -> MapFrame<Self, F>
    where
        Self: Sized,
        F: FnMut(crate::body::http_body::Frame<Self::Data>) -> crate::body::http_body::Frame<B>,
        B: bytes::Buf,
    {
        MapFrame::new(self, f)
    }

    /// A body that calls a function with a reference to each frame before yielding it.
    fn inspect_frame<F>(self, f: F) -> combinators::InspectFrame<Self, F>
    where
        Self: Sized,
        F: FnMut(&crate::body::http_body::Frame<Self::Data>),
    {
        combinators::InspectFrame::new(self, f)
    }

    /// Forward this byte body while asynchronously sending owned frame copies to a sink.
    fn capture<S>(self, sink: S) -> crate::body::CaptureBody<Self, S>
    where
        Self: Sized + crate::body::http_body::Body<Data = bytes::Bytes>,
        S: crate::body::BodyCaptureSink,
    {
        crate::body::CaptureBody::new(self, sink)
    }

    /// Forward this byte body while retaining a bounded or unlimited copy in memory.
    fn capture_buffered(
        self,
        limit: crate::body::CaptureLimit,
    ) -> (
        crate::body::CaptureBody<Self, crate::body::BufferedBodyCapture>,
        crate::body::CaptureHandle,
    )
    where
        Self: Sized + crate::body::http_body::Body<Data = bytes::Bytes>,
    {
        crate::body::CaptureBody::buffered(self, limit)
    }

    /// Maps this body's error value to a different value.
    fn map_err<F, E>(self, f: F) -> MapErr<Self, F>
    where
        Self: Sized,
        F: FnMut(Self::Error) -> E,
    {
        MapErr::new(self, f)
    }

    /// A body that calls a function with a reference to an error before yielding it.
    fn inspect_err<F>(self, f: F) -> combinators::InspectErr<Self, F>
    where
        Self: Sized,
        F: FnMut(&Self::Error),
    {
        combinators::InspectErr::new(self, f)
    }

    /// Turn this body into a boxed trait object.
    fn boxed(self) -> BoxBody<Self::Data, Self::Error>
    where
        Self: Sized + Send + Sync + 'static,
    {
        BoxBody::new(self)
    }

    /// Turn this body into a boxed trait object that is !Sync.
    fn boxed_unsync(self) -> UnsyncBoxBody<Self::Data, Self::Error>
    where
        Self: Sized + Send + 'static,
    {
        UnsyncBoxBody::new(self)
    }

    /// Turn this body into a [`Limited`] body with the given limit.
    fn limited(self, limit: usize) -> Limited<Self>
    where
        Self: Sized,
    {
        Limited::new(self, limit)
    }

    /// Turn this body into [`Collected`] body which will collect all the DATA frames
    /// and trailers.
    ///
    /// On a body stream error the returned future yields a [`CollectError`] that
    /// still carries the bytes read before the failure. Use [`collect_with`] to
    /// additionally bound the size and/or time and keep the unread remainder
    /// forwardable.
    ///
    /// [`collect_with`]: BodyExt::collect_with
    fn collect(self) -> combinators::Collect<Self>
    where
        Self: Sized,
    {
        combinators::Collect {
            body: self,
            collected: Some(crate::body::http_body_util::Collected::default()),
        }
    }

    /// Collect this body, but bounded by the size cap and/or timeout in
    /// [`CollectOptions`].
    ///
    /// On success returns the [`Collected`] body, exactly like [`collect`]. When
    /// a bound is hit it stops early with a [`CollectError`] that retains the
    /// bytes read so far *and* the unread remainder — call
    /// [`CollectError::into_full_body`] to reassemble and forward the body on
    /// untouched (handy for proxies).
    ///
    /// This is the soft, recoverable counterpart to [`Limited`]: where `Limited`
    /// hard-fails with a [`LengthLimitError`] and discards the body the moment
    /// its cap is crossed, `collect_with` loses nothing — the bytes read and the
    /// remainder are both preserved.
    ///
    /// [`collect`]: BodyExt::collect
    /// [`Limited`]: crate::body::http_body_util::Limited
    /// [`LengthLimitError`]: crate::body::http_body_util::LengthLimitError
    /// [`CollectError::into_full_body`]: crate::body::http_body_util::CollectError::into_full_body
    fn collect_with(self, opts: CollectOptions) -> CollectWith<Self>
    where
        Self: Sized
            + crate::body::http_body::Body<Data = bytes::Bytes, Error: Into<BoxError>>
            + Send
            + Sync
            + Unpin
            + 'static,
    {
        CollectWith::new(self, opts)
    }

    /// Add trailers to the body.
    ///
    /// The trailers will be sent when all previous frames have been sent and the `trailers` future
    /// resolves.
    ///
    /// # Example
    ///
    /// ```
    /// use rama_http_types::HeaderMap;
    /// use rama_http_types::body::util::{Full, BodyExt};
    /// use rama_core::bytes::Bytes;
    ///
    /// # #[tokio::main]
    /// async fn main() {
    /// let (tx, rx) = tokio::sync::oneshot::channel::<HeaderMap>();
    ///
    /// let body = Full::<Bytes>::from("Hello, World!")
    ///     // add trailers via a future
    ///     .with_trailers(async move {
    ///         match rx.await {
    ///             Ok(trailers) => Some(Ok(trailers)),
    ///             Err(_err) => None,
    ///         }
    ///     });
    ///
    /// // compute the trailers in the background
    /// tokio::spawn(async move {
    ///     let _ = tx.send(compute_trailers().await);
    /// });
    ///
    /// async fn compute_trailers() -> HeaderMap {
    ///     // ...
    ///     # unimplemented!()
    /// }
    /// # }
    /// ```
    fn with_trailers<F>(self, trailers: F) -> combinators::WithTrailers<Self, F>
    where
        Self: Sized,
        F: std::future::Future<Output = Option<Result<crate::HeaderMap, Self::Error>>>,
    {
        combinators::WithTrailers::new(self, trailers)
    }

    /// Turn this body into [`BodyDataStream`].
    fn into_data_stream(self) -> BodyDataStream<Self>
    where
        Self: Sized,
    {
        BodyDataStream::new(self)
    }

    /// Turn this body into [`BodyStream`].
    ///
    /// This can be combined with stream combinators to observe each frame or
    /// error asynchronously without changing it. The observer is awaited before
    /// the item is yielded, so it naturally applies backpressure without
    /// blocking an executor thread or cloning the frame:
    ///
    /// ```
    /// use rama_core::futures::StreamExt as _;
    /// use rama_http_types::body::{Body, Frame, util::{BodyExt, StreamBody}};
    ///
    /// async fn observe<D, E>(_item: &Result<Frame<D>, E>) {}
    ///
    /// # #[tokio::main]
    /// # async fn main() {
    /// let body = Body::from("hello");
    /// let body = StreamBody::new(body.into_stream().then(|item| async move {
    ///     observe(&item).await;
    ///     item
    /// }));
    ///
    /// let collected = BodyExt::collect(body).await.unwrap();
    /// assert_eq!(collected.to_bytes(), "hello");
    /// # }
    /// ```
    ///
    /// Stream combinators observe yielded items, not the normal end marker
    /// (`None`). Use an appropriate body or layer lifecycle hook when normal
    /// end-of-stream must also be observed. Converting the resulting stream
    /// back with [`StreamBody`] does not preserve the original body's
    /// [`SizeHint`](crate::body::http_body::SizeHint) or early
    /// [`Body::is_end_stream`](crate::body::http_body::Body::is_end_stream)
    /// indication.
    fn into_stream(self) -> BodyStream<Self>
    where
        Self: Sized,
    {
        BodyStream::new(self)
    }

    /// Creates a fused body.
    ///
    /// This [`Body`][crate::body::http_body::Body] yields `Poll::Ready(None)` forever after the
    /// underlying body yields `Poll::Ready(None)`, or an error `Poll::Ready(Some(Err(_)))`, once.
    ///
    /// See [`Fuse<B>`][combinators::Fuse] for more information.
    fn fuse(self) -> combinators::Fuse<Self>
    where
        Self: Sized,
    {
        combinators::Fuse::new(self)
    }

    /// Chain this body with another one, like [`Iterator::chain`].
    ///
    /// The returned [`Chain`][combinators::Chain] yields every frame of this body,
    /// followed by every frame of `other`.
    ///
    /// Trailers of this body are held back and merged into those of `other`, whose
    /// values win on conflicts. An error of either body ends the chain: `other` is
    /// not polled after this body failed.
    ///
    /// # Examples
    ///
    /// ```
    /// use rama_core::bytes::Bytes;
    /// use rama_http_types::body::util::{BodyExt, Full};
    ///
    /// # #[tokio::main]
    /// # async fn main() {
    /// let first = Full::new(Bytes::from("hello "));
    /// let second = Full::new(Bytes::from("world!"));
    ///
    /// let collected = first.chain(second).collect().await.unwrap();
    /// assert_eq!(collected.to_bytes(), "hello world!");
    /// # }
    /// ```
    ///
    /// ```
    /// use rama_core::bytes::Bytes;
    /// use rama_http_types::body::util::{BodyExt, Full};
    /// use rama_http_types::{HeaderMap, HeaderName, HeaderValue};
    ///
    /// # #[tokio::main]
    /// # async fn main() {
    /// let mut trailers = HeaderMap::new();
    /// trailers.insert(
    ///     HeaderName::from_static("name"),
    ///     HeaderValue::from_static("value"),
    /// );
    ///
    /// let first = Full::new(Bytes::from("trailers"))
    ///     .with_trailers(std::future::ready(Some(Ok(trailers))));
    /// let second = Full::new(Bytes::from(" too!"));
    ///
    /// let collected = first.chain(second).collect().await.unwrap();
    /// assert_eq!(collected.trailers().unwrap()["name"], "value");
    /// assert_eq!(collected.to_bytes(), "trailers too!");
    /// # }
    /// ```
    fn chain<B>(self, other: B) -> combinators::Chain<Self, B>
    where
        Self: Sized,
    {
        combinators::Chain::new(self, other)
    }
}

impl<T: ?Sized> BodyExt for T where T: crate::body::http_body::Body {}
