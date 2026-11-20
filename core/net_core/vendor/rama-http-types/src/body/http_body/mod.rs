// Forked from the `http-body` crate — vendored so its `Frame` trailers use
// rama's `HeaderMap`. See `docs/thirdparty/fork/README.md`.
// Fork-style lint allows (also cover the `frame`/`size_hint` child modules).
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

//! Asynchronous HTTP request or response body.
//!
//! See [`Body`] for more details.
//!
//! [`Body`]: trait.Body.html

mod frame;
mod size_hint;

pub use self::frame::Frame;
pub use self::size_hint::SizeHint;

use bytes::{Buf, Bytes};
use std::convert::Infallible;
use std::ops;
use std::pin::Pin;
use std::task::{Context, Poll};

/// Trait representing a streaming body of a Request or Response.
///
/// Individual frames are streamed via the `poll_frame` function, which asynchronously yields
/// instances of [`Frame<Data>`].
///
/// Frames can contain a data buffer of type `Self::Data`. Frames can also contain an optional
/// set of trailers used to finalize the request/response exchange. This is mostly used when using
/// the HTTP/2.0 protocol.
///
/// The `size_hint` function provides insight into the total number of bytes that will be streamed.
pub trait Body {
    /// Values yielded by the `Body`.
    type Data: Buf;

    /// The error type this `Body` might generate.
    type Error;

    #[allow(clippy::type_complexity)]
    /// Attempt to pull out the next frame of this stream.
    ///
    /// # Return value
    ///
    /// This function returns:
    ///
    /// - `Poll::Pending` if the next frame is not ready yet.
    /// - `Poll::Ready(Some(Ok(frame)))` when the next frame is available.
    /// - `Poll::Ready(Some(Err(error)))` when an error has been reached.
    /// - `Poll::Ready(None)` means that all of the frames in this stream have been returned, and
    ///   that the end of the stream has been reached.
    ///
    /// If `Poll::Ready(Some(Err(error)))` is returned, this body should be discarded.
    ///
    /// Once the end of the stream is reached, implementations should continue to return
    /// `Poll::Ready(None)`.
    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>>;

    /// A hint that may return `true` when the end of stream has been reached.
    ///
    /// An end of stream means that `poll_frame` will return `None`.
    ///
    /// A return value of `false` **does not** guarantee that a value will be
    /// returned from `poll_frame`. Combinators or other implementations may
    /// not be able to know the end of stream has been reached for this hint.
    ///
    /// Returning `true` allows consumers of this body to optimize, such as not
    /// calling `poll_frame` again.
    fn is_end_stream(&self) -> bool {
        false
    }

    /// A hint that returns the bounds on the remaining length of the stream.
    ///
    /// When the **exact** remaining length of the stream is known, the upper bound will be set and
    /// will equal the lower bound.
    fn size_hint(&self) -> SizeHint {
        SizeHint::default()
    }
}

impl<T: Body + Unpin + ?Sized> Body for &mut T {
    type Data = T::Data;
    type Error = T::Error;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        Pin::new(&mut **self).poll_frame(cx)
    }

    fn is_end_stream(&self) -> bool {
        Pin::new(&**self).is_end_stream()
    }

    fn size_hint(&self) -> SizeHint {
        Pin::new(&**self).size_hint()
    }
}

impl<P> Body for Pin<P>
where
    P: Unpin + ops::DerefMut,
    P::Target: Body,
{
    type Data = <<P as ops::Deref>::Target as Body>::Data;
    type Error = <<P as ops::Deref>::Target as Body>::Error;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        Pin::get_mut(self).as_mut().poll_frame(cx)
    }

    fn is_end_stream(&self) -> bool {
        self.as_ref().is_end_stream()
    }

    fn size_hint(&self) -> SizeHint {
        self.as_ref().size_hint()
    }
}

impl<T: Body + Unpin + ?Sized> Body for Box<T> {
    type Data = T::Data;
    type Error = T::Error;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        Pin::new(&mut **self).poll_frame(cx)
    }

    fn is_end_stream(&self) -> bool {
        self.as_ref().is_end_stream()
    }

    fn size_hint(&self) -> SizeHint {
        self.as_ref().size_hint()
    }
}

impl Body for String {
    type Data = Bytes;
    type Error = Infallible;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        if !self.is_empty() {
            let s = std::mem::take(&mut *self);
            Poll::Ready(Some(Ok(Frame::data(s.into_bytes().into()))))
        } else {
            Poll::Ready(None)
        }
    }

    fn is_end_stream(&self) -> bool {
        self.is_empty()
    }

    fn size_hint(&self) -> SizeHint {
        SizeHint::with_exact(self.len() as u64)
    }
}

#[cfg(test)]
fn _assert_bounds() {
    fn can_be_trait_object(_: &dyn Body<Data = std::io::Cursor<Vec<u8>>, Error = std::io::Error>) {}
}
