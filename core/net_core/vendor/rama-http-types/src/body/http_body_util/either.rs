//! [`Body`] support for the [`Either`] combinator.
//!
//! Unlike upstream `http-body-util` (which ships its own `Left`/`Right` enum and
//! a hand-expanded `pin-project-lite` projection — see fork README), this
//! re-uses rama's own [`rama_core::combinators::Either`]: the variants and the
//! pinned projection (`as_pin_mut`) come from there, and the [`Body`] impl is
//! generated with [`impl_either!`] exactly like the `Future`/`AsyncRead`/…
//! impls in rama-core.

use std::error::Error;
use std::pin::Pin;
use std::task::{Context, Poll};

use rama_core::bytes::Buf;
use rama_core::combinators::{
    Either3, Either4, Either5, Either6, Either7, Either8, Either9, impl_either,
};

#[doc(inline)]
pub use rama_core::combinators::Either;

use crate::body::http_body::{Body, Frame, SizeHint};

macro_rules! impl_body_either {
    ($id:ident, $($param:ident),+ $(,)?) => {
        impl<$($param),+, Data> Body for $id<$($param),+>
        where
            $($param: Body<Data = Data>),+,
            $($param::Error: Into<Box<dyn Error + Send + Sync>>),+,
            Data: Buf,
        {
            type Data = Data;
            type Error = Box<dyn Error + Send + Sync>;

            fn poll_frame(
                self: Pin<&mut Self>,
                cx: &mut Context<'_>,
            ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
                match self.as_pin_mut() {
                    $(
                        $id::$param(body) => body
                            .poll_frame(cx)
                            .map(|poll| poll.map(|opt| opt.map_err(Into::into))),
                    )+
                }
            }

            fn is_end_stream(&self) -> bool {
                match self {
                    $(
                        $id::$param(body) => body.is_end_stream(),
                    )+
                }
            }

            fn size_hint(&self) -> SizeHint {
                match self {
                    $(
                        $id::$param(body) => body.size_hint(),
                    )+
                }
            }
        }
    };
}

impl_either!(impl_body_either);

#[cfg(test)]
mod tests {
    use super::*;
    use crate::body::http_body_util::{BodyExt, Empty, Full};

    #[tokio::test]
    async fn data_left() {
        let full = Full::new(&b"hello"[..]);

        let mut value: Either<_, Empty<&[u8]>> = Either::A(full);

        assert_eq!(value.size_hint().exact(), Some(b"hello".len() as u64));
        assert_eq!(
            value.frame().await.unwrap().unwrap().into_data().unwrap(),
            &b"hello"[..]
        );
        assert!(value.frame().await.is_none());
    }

    #[tokio::test]
    async fn data_right() {
        let full = Full::new(&b"hello!"[..]);

        let mut value: Either<Empty<&[u8]>, _> = Either::B(full);

        assert_eq!(value.size_hint().exact(), Some(b"hello!".len() as u64));
        assert_eq!(
            value.frame().await.unwrap().unwrap().into_data().unwrap(),
            &b"hello!"[..]
        );
        assert!(value.frame().await.is_none());
    }
}
