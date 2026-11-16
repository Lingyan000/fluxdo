use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Duration;

use bytes::{Buf, Bytes};
use futures_core::ready;
use pin_project_lite::pin_project;
use rama_core::error::BoxError;
use rama_utils::macros::generate_set_and_with;

use crate::body::http_body_util::combinators::Chain;
use crate::body::http_body_util::{CollectError, CollectErrorKind, Collected, Full};
use crate::body::{Body, Frame, StreamingBody};

/// Options for [`BodyExt::collect_with`]: an optional size cap and/or timeout.
///
/// When either bound is hit the collect stops with a [`CollectError`] that
/// still carries the bytes read so far *and* the unread remainder, so the
/// original body can be reassembled and forwarded untouched.
///
/// This is the soft, recoverable counterpart to [`Limited`], which hard-fails
/// and discards the body the moment its limit is crossed.
///
/// [`BodyExt::collect_with`]: crate::body::http_body_util::BodyExt::collect_with
/// [`Limited`]: crate::body::http_body_util::Limited
#[derive(Debug, Clone, Default)]
pub struct CollectOptions {
    pub(crate) max_size: Option<usize>,
    pub(crate) timeout: Option<Duration>,
}

impl CollectOptions {
    /// Create empty options (no cap, no timeout) — equivalent to a plain
    /// [`collect`](crate::body::http_body_util::BodyExt::collect) that also
    /// retains read bytes on a stream error.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            max_size: None,
            timeout: None,
        }
    }

    generate_set_and_with! {
        /// Cap the number of bytes buffered. When reached, collecting stops with
        /// [`CollectErrorKind::CapReached`]; the bytes up to the cap are read and
        /// the remainder stays forwardable.
        pub fn max_size(mut self, max_size: usize) -> Self {
            self.max_size = Some(max_size);
            self
        }
    }

    generate_set_and_with! {
        /// Cap the time spent collecting. When elapsed, collecting stops with
        /// [`CollectErrorKind::TimedOut`]; whatever was read is kept and the
        /// remainder stays forwardable.
        pub fn timeout(mut self, timeout: Duration) -> Self {
            self.timeout = Some(timeout);
            self
        }
    }
}

pin_project! {
    /// Future returned by [`BodyExt::collect_with`].
    ///
    /// Resolves to the [`Collected`] body on success, or a [`CollectError`]
    /// carrying the read bytes plus (for size/time stops) the forwardable
    /// remainder.
    ///
    /// [`BodyExt::collect_with`]: crate::body::http_body_util::BodyExt::collect_with
    pub struct CollectWith<B> {
        collected: Option<Collected<Bytes>>,
        read_len: usize,
        max_size: Option<usize>,
        timeout: Option<Duration>,
        body: Option<B>,
        #[pin]
        sleep: Option<tokio::time::Sleep>,
    }
}

impl<B> CollectWith<B> {
    pub(crate) fn new(body: B, opts: CollectOptions) -> Self {
        Self {
            collected: Some(Collected::default()),
            read_len: 0,
            max_size: opts.max_size,
            timeout: opts.timeout,
            body: Some(body),
            sleep: opts.timeout.map(tokio::time::sleep),
        }
    }
}

impl<B> Future for CollectWith<B>
where
    B: StreamingBody<Data = Bytes, Error: Into<BoxError>> + Send + Sync + Unpin + 'static,
{
    type Output = Result<Collected<Bytes>, CollectError>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let mut this = self.project();

        // Race the deadline first so a stalled body still stops on time.
        if let Some(sleep) = this.sleep.as_mut().as_pin_mut() {
            if sleep.poll(cx).is_ready() {
                let read = this.collected.take().expect("polled after complete");
                let body = this.body.take().expect("polled after complete");
                let after = this.timeout.expect("sleep present implies a timeout");
                return Poll::Ready(Err(CollectError::stopped(
                    read.to_bytes(),
                    Body::new(body),
                    CollectErrorKind::TimedOut { after },
                )));
            }
        }

        loop {
            let frame = {
                let body = this.body.as_mut().expect("polled after complete");
                ready!(Pin::new(body).poll_frame(cx))
            };

            match frame {
                Some(Ok(frame)) => {
                    let data_len = frame.data_ref().map(Buf::remaining);
                    match (data_len, *this.max_size) {
                        (Some(len), Some(max)) if *this.read_len + len > max => {
                            // Split precisely at the cap: keep `take` bytes, push
                            // the rest back in front of the still-unread remainder.
                            let mut data = frame.into_data().ok().expect("checked via data_ref");
                            let take = max - *this.read_len;
                            let head = data.split_to(take);
                            if head.has_remaining() {
                                this.collected
                                    .as_mut()
                                    .unwrap()
                                    .push_frame(Frame::data(head));
                            }
                            *this.read_len = max;

                            let read = this.collected.take().expect("polled after complete");
                            let body = this.body.take().expect("polled after complete");
                            let remainder = Body::new(Chain::new(Full::new(data), body));
                            return Poll::Ready(Err(CollectError::stopped(
                                read.to_bytes(),
                                remainder,
                                CollectErrorKind::CapReached { limit: max },
                            )));
                        }
                        (Some(len), _) => {
                            *this.read_len += len;
                            this.collected.as_mut().unwrap().push_frame(frame);
                        }
                        (None, _) => {
                            // non-data frame (e.g. trailers)
                            this.collected.as_mut().unwrap().push_frame(frame);
                        }
                    }
                }
                Some(Err(err)) => {
                    let read = this.collected.take().expect("polled after complete");
                    return Poll::Ready(Err(CollectError::stream(read.to_bytes(), err.into())));
                }
                None => {
                    return Poll::Ready(Ok(this.collected.take().expect("polled after complete")));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::CollectOptions;
    use crate::Body;
    use crate::body::util::{BodyExt, CollectErrorKind};
    use bytes::Bytes;
    use rama_core::error::BoxError;
    use rama_core::futures::{StreamExt, stream};
    use std::assert_matches;
    use std::time::Duration;

    fn body_from_chunks(chunks: &[&'static [u8]]) -> Body {
        let items: Vec<Result<Bytes, BoxError>> =
            chunks.iter().map(|c| Ok(Bytes::from_static(c))).collect();
        Body::from_stream(stream::iter(items))
    }

    async fn drain(body: Body) -> Vec<u8> {
        body.collect().await.unwrap().to_bytes().to_vec()
    }

    #[tokio::test]
    async fn complete_under_cap_returns_all_bytes() {
        let body = body_from_chunks(&[b"hello", b"world"]);
        let collected = body
            .collect_with(CollectOptions::new().with_max_size(100))
            .await
            .unwrap();
        assert_eq!(&collected.to_bytes()[..], b"helloworld");
    }

    #[tokio::test]
    async fn complete_with_empty_options() {
        let body = body_from_chunks(&[b"abc", b"def"]);
        let collected = body.collect_with(CollectOptions::new()).await.unwrap();
        assert_eq!(&collected.to_bytes()[..], b"abcdef");
    }

    #[tokio::test]
    async fn cap_splits_exactly_across_chunk_boundary() {
        let body = body_from_chunks(&[b"hello", b"world"]);
        let err = body
            .collect_with(CollectOptions::new().with_max_size(7))
            .await
            .unwrap_err();
        assert!(err.is_cap_reached());
        assert_matches!(err.kind(), CollectErrorKind::CapReached { limit: 7 });
        assert_eq!(&err.bytes_read()[..], b"hellowo");
        assert_eq!(drain(err.into_full_body().unwrap()).await, b"helloworld");
    }

    #[tokio::test]
    async fn cap_splits_within_first_chunk() {
        let body = body_from_chunks(&[b"helloworld"]);
        let err = body
            .collect_with(CollectOptions::new().with_max_size(4))
            .await
            .unwrap_err();
        assert_eq!(&err.bytes_read()[..], b"hell");
        assert_eq!(drain(err.into_full_body().unwrap()).await, b"helloworld");
    }

    #[tokio::test]
    async fn cap_zero_reads_nothing_keeps_everything() {
        let body = body_from_chunks(&[b"data"]);
        let err = body
            .collect_with(CollectOptions::new().with_max_size(0))
            .await
            .unwrap_err();
        assert!(err.bytes_read().is_empty());
        assert_eq!(drain(err.into_full_body().unwrap()).await, b"data");
    }

    #[tokio::test]
    async fn into_remainder_returns_only_unread_tail() {
        let body = body_from_chunks(&[b"abcdef"]);
        let err = body
            .collect_with(CollectOptions::new().with_max_size(2))
            .await
            .unwrap_err();
        assert_eq!(&err.bytes_read()[..], b"ab");
        assert_eq!(drain(err.into_remainder().unwrap()).await, b"cdef");
    }

    #[tokio::test]
    async fn cap_error_into_parts_exposes_bytes_remainder_and_kind() {
        let body = body_from_chunks(&[b"abcdef"]);
        let err = body
            .collect_with(CollectOptions::new().with_max_size(2))
            .await
            .unwrap_err();
        let (bytes, remainder, kind) = err.into_parts();
        assert_eq!(&bytes[..], b"ab");
        assert_matches!(kind, CollectErrorKind::CapReached { limit: 2 });
        assert_eq!(drain(remainder.unwrap()).await, b"cdef");
    }

    #[tokio::test]
    async fn timeout_keeps_read_bytes_and_forwardable_remainder() {
        // First chunk is immediate; the tail is intentionally far slower than
        // the timeout, so collecting stops after reading just the first chunk.
        let s = stream::once(async { Ok::<_, BoxError>(Bytes::from_static(b"hello")) }).chain(
            stream::once(async {
                tokio::time::sleep(Duration::from_hours(1)).await;
                Ok::<_, BoxError>(Bytes::from_static(b"world"))
            }),
        );
        let body = Body::from_stream(s);
        let err = body
            .collect_with(CollectOptions::new().with_timeout(Duration::from_millis(50)))
            .await
            .unwrap_err();
        assert!(err.is_timed_out());
        assert_eq!(&err.bytes_read()[..], b"hello");
        // The unread remainder stays forwardable (full reassembly is exercised
        // by the cap tests; here we avoid draining the deliberately-slow tail).
        assert!(err.into_full_body().is_some());
    }

    #[tokio::test]
    async fn collect_with_stream_error_keeps_read_no_remainder() {
        let items: Vec<Result<Bytes, BoxError>> =
            vec![Ok(Bytes::from_static(b"hi")), Err(BoxError::from("boom"))];
        let body = Body::from_stream(stream::iter(items));
        let err = body.collect_with(CollectOptions::new()).await.unwrap_err();
        assert!(err.is_stream_error());
        assert_eq!(&err.bytes_read()[..], b"hi");
        assert!(err.into_full_body().is_none());
    }

    #[tokio::test]
    async fn plain_collect_preserves_read_bytes_on_stream_error() {
        let items: Vec<Result<Bytes, BoxError>> = vec![
            Ok(Bytes::from_static(b"partial")),
            Err(BoxError::from("boom")),
        ];
        let body = Body::from_stream(stream::iter(items));
        let err = body.collect().await.unwrap_err();
        assert!(err.is_stream_error());
        assert_eq!(&err.bytes_read()[..], b"partial");
        assert!(err.into_full_body().is_none());
    }
}
