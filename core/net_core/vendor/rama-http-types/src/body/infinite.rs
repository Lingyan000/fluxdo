use rama_core::stream::io::ReaderStream;
use rama_core::telemetry::tracing;
use rama_utils::macros::generate_set_and_with;
use rand::{Rng, RngExt as _, rng};
use std::{
    io,
    pin::Pin,
    task::{Context, Poll},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, ReadBuf},
    time::Sleep,
};

/// A(n) (in)finite random byte stream implementing [`AsyncRead`].
///
/// Cheap to serve, expensive to download.
/// Eat while it's hot my dear little bots.
pub struct InfiniteReader {
    chunk_size: usize,
    limit: Option<usize>,
    byte_count: usize,
    max_delay: Option<Duration>,
    sleep: Option<Pin<Box<Sleep>>>,
}

impl Default for InfiniteReader {
    #[inline]
    fn default() -> Self {
        Self::new()
    }
}

impl InfiniteReader {
    /// Create an new default [`InfiniteReader`].
    #[must_use]
    pub fn new() -> Self {
        Self {
            chunk_size: 4096,
            limit: None,
            byte_count: 0,
            max_delay: None,
            sleep: None,
        }
    }

    generate_set_and_with! {
        /// Define the max throttle to be used for the intervals.
        ///
        /// Setting it will ensure that we have randomised throttles between
        /// reads, making it more effective.
        pub fn throttle(mut self, delay: Option<Duration>) -> Self {
            self.max_delay = delay.and_then(|d| (!d.is_zero()).then_some(d));
            self
        }
    }

    generate_set_and_with! {
        /// Set a limit on how much data will be served,
        /// by default it will be an infinite amount of data.
        pub fn size_limit(mut self, limit: Option<usize>) -> Self {
            self.limit = limit.and_then(|n| (n > 0).then_some(n));
            self
        }
    }

    generate_set_and_with! {
        /// Define the chunk size for downloads.
        ///
        /// The default value is used if a value of 0 is given.
        pub fn chunk_size(mut self, size: usize) -> Self {
            self.chunk_size = if size == 0 {
                4096
            } else {
                size
            };
            self
        }
    }

    /// Turn this [`InfiniteReader`] into a [`Body`].
    ///
    /// [`Body`]: super::Body
    pub fn into_body(self) -> super::Body {
        let stream = ReaderStream::new(self);
        super::Body::from_stream(stream)
    }
}

impl AsyncRead for InfiniteReader {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if self.limit.map(|n| n <= self.byte_count).unwrap_or_default() {
            tracing::trace!(
                "InfiniteReader finished reading, reached limit ({:?}): {}",
                self.limit,
                self.byte_count,
            );
            return Poll::Ready(Ok(()));
        }

        let mut rng = rng();

        if let Some(max_delay) = self.max_delay {
            if let Some(sleep) = self.sleep.as_mut() {
                match sleep.as_mut().poll(cx) {
                    Poll::Ready(_) => {
                        tracing::trace!(
                            "InfiniteReader throttle finished (limit: {}ms)",
                            max_delay.as_millis()
                        );
                        self.sleep = None;
                    }
                    Poll::Pending => {
                        tracing::trace!("InfiniteReader still throttling...");
                        return Poll::Pending;
                    }
                }
            } else {
                let max_ms = max_delay.as_millis() as u64;
                let rand_ms = rng.random_range(0..=max_ms);
                let delay = Duration::from_millis(rand_ms);
                tracing::trace!("InfiniteReader start throttle: {rand_ms}ms",);
                let mut sleep = Box::pin(tokio::time::sleep(delay));
                if sleep.as_mut().poll(cx).is_pending() {
                    self.sleep = Some(sleep);
                    return Poll::Pending;
                };
            }
        }

        let len = self.chunk_size.min(buf.remaining());
        self.byte_count += len;
        tracing::trace!("InfiniteReader feeding data: {len} random byte(s)");
        let mut data = vec![0u8; len];
        rng.fill_bytes(&mut data);
        buf.put_slice(&data);
        Poll::Ready(Ok(()))
    }
}

impl From<InfiniteReader> for super::Body {
    #[inline]
    fn from(reader: InfiniteReader) -> Self {
        reader.into_body()
    }
}
