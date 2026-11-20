use std::fmt;
use std::pin::Pin;
use std::task::{Context, Poll, ready};

use rama_core::bytes::Bytes;
use rama_http_types::body::{Frame, SizeHint, StreamingBody};

use super::{
    DecodedLength,
    chan::{self, Sender},
};
use crate::h2;
use crate::proto::h2::ping;

/// A stream of `Bytes`, used when receiving bodies from the network.
///
/// Note that Users should not instantiate this struct directly. When working with the client,
/// `Incoming` is returned to you in responses. Similarly, when operating with the server,
/// it is provided within requests.
#[must_use = "streams do nothing unless polled"]
pub struct Incoming {
    kind: Kind,
}

enum Kind {
    Empty,
    Chan {
        content_length: DecodedLength,
        rx: chan::Receiver,
    },
    H2 {
        content_length: DecodedLength,
        data_done: bool,
        ping: ping::Recorder,
        recv: h2::RecvStream,
    },
    // H2's receive stream is a handle into its connection driver. H3 owns its
    // frame reader, QUIC stream, and trailer decoding state here. Keep that
    // larger state off the enum so HTTP/1 and HTTP/2 bodies retain their size.
    #[cfg(feature = "quic")]
    H3(Pin<Box<dyn StreamingBody<Data = Bytes, Error = crate::Error> + Send + Sync>>),
}

impl Incoming {
    #[cfg(feature = "quic")]
    pub(crate) fn h3(
        body: impl StreamingBody<Data = Bytes, Error = crate::Error> + Send + Sync + 'static,
    ) -> Self {
        Self::new(Kind::H3(Box::pin(body)))
    }

    /// Create a `Body` stream with an associated sender half.
    ///
    /// Useful when wanting to stream chunks from another thread.
    #[inline]
    #[cfg(test)]
    pub(crate) fn channel() -> (Sender, Self) {
        Self::new_channel(DecodedLength::CHUNKED, /*wanter =*/ false)
    }

    pub(crate) fn new_channel(content_length: DecodedLength, wanter: bool) -> (Sender, Self) {
        let (tx, rx) = chan::channel(wanter);
        (tx, Self::new(Kind::Chan { content_length, rx }))
    }

    fn new(kind: Kind) -> Self {
        Self { kind }
    }

    pub(crate) fn empty() -> Self {
        Self::new(Kind::Empty)
    }

    pub(crate) fn h2(
        recv: h2::RecvStream,
        mut content_length: DecodedLength,
        ping: ping::Recorder,
    ) -> Self {
        // If the stream is already EOS, then the "unknown length" is clearly
        // actually ZERO.
        if !content_length.is_exact() && recv.is_end_stream() {
            content_length = DecodedLength::ZERO;
        }

        Self::new(Kind::H2 {
            data_done: false,
            ping,
            content_length,
            recv,
        })
    }
}

impl StreamingBody for Incoming {
    type Data = Bytes;
    type Error = crate::Error;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        match &mut self.kind {
            #[cfg(feature = "quic")]
            Kind::H3(body) => body.as_mut().poll_frame(cx),
            Kind::Empty => Poll::Ready(None),
            Kind::Chan {
                content_length: len,
                rx,
            } => {
                if let Some(chunk) = ready!(rx.poll_next(cx)?) {
                    len.sub_if(chunk.len() as u64);
                    return Poll::Ready(Some(Ok(Frame::data(chunk))));
                }
                Poll::Ready(rx.take_trailers().map(Frame::trailers).map(Ok))
            }
            Kind::H2 {
                data_done,
                ping,
                recv: h2,
                content_length: len,
            } => {
                if !*data_done {
                    match ready!(h2.poll_data(cx)) {
                        Some(Ok(bytes)) => {
                            _ = h2.flow_control().release_capacity(bytes.len());
                            len.sub_if(bytes.len() as u64);
                            ping.record_data(bytes.len());
                            return Poll::Ready(Some(Ok(Frame::data(bytes))));
                        }
                        Some(Err(e)) => {
                            if e.reason() == Some(h2::Reason::NO_ERROR) {
                                // As mentioned in RFC 7540 Section 8.1, a RST_STREAM with NO_ERROR
                                // indicates an early response, and should cause the body reading
                                // to stop, but not fail it:
                                return Poll::Ready(None);
                            } else {
                                return Poll::Ready(Some(Err(crate::Error::new_body(e))));
                            }
                        }
                        None => {
                            *data_done = true;
                            // fall through to trailers
                        }
                    }
                }

                // after data, check trailers
                match ready!(h2.poll_trailers(cx)) {
                    Ok(t) => {
                        ping.record_non_data();
                        Poll::Ready(Ok(t.map(Frame::trailers)).transpose())
                    }
                    Err(e) => {
                        if e.reason() == Some(h2::Reason::NO_ERROR) {
                            // Same as above, a RST_STREAM with NO_ERROR indicates an early
                            // response, and should cause reading the trailers to stop, but
                            // not fail it:
                            Poll::Ready(None)
                        } else {
                            Poll::Ready(Some(Err(crate::Error::new_h2(e))))
                        }
                    }
                }
            }
        }
    }

    fn is_end_stream(&self) -> bool {
        match &self.kind {
            #[cfg(feature = "quic")]
            Kind::H3(body) => body.is_end_stream(),
            Kind::Empty => true,
            Kind::Chan { content_length, .. } => *content_length == DecodedLength::ZERO,
            Kind::H2 { recv: h2, .. } => h2.is_end_stream(),
        }
    }

    fn size_hint(&self) -> SizeHint {
        fn opt_len(decoded_length: DecodedLength) -> SizeHint {
            if let Some(content_length) = decoded_length.into_opt() {
                SizeHint::with_exact(content_length)
            } else {
                SizeHint::default()
            }
        }

        match self.kind {
            #[cfg(feature = "quic")]
            Kind::H3(ref body) => body.size_hint(),
            Kind::Empty => SizeHint::with_exact(0),
            Kind::Chan { content_length, .. } | Kind::H2 { content_length, .. } => {
                opt_len(content_length)
            }
        }
    }
}

impl fmt::Debug for Incoming {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        #[derive(Debug)]
        struct Streaming;
        #[derive(Debug)]
        struct Empty;

        let mut builder = f.debug_tuple("Body");
        match self.kind {
            Kind::Empty => builder.field(&Empty),
            _ => builder.field(&Streaming),
        };

        builder.finish()
    }
}

#[cfg(test)]
mod tests {
    use std::mem;
    use std::task::Poll;

    use super::{DecodedLength, Incoming, Sender, SizeHint};
    use rama_http::{StreamingBody, body::util::BodyExt};

    #[test]
    fn test_size_of() {
        // These are mostly to help catch *accidentally* increasing
        // the size by too much.

        let body_size = mem::size_of::<Incoming>();
        let body_expected_size = mem::size_of::<u64>() * 5;
        assert!(
            body_size <= body_expected_size,
            "Body size = {body_size} <= {body_expected_size}",
        );

        assert_eq!(
            mem::size_of::<Sender>(),
            mem::size_of::<usize>() * 2,
            "Sender"
        );

        assert_eq!(
            mem::size_of::<Sender>(),
            mem::size_of::<Option<Sender>>(),
            "Option<Sender>"
        );
    }

    #[test]
    fn size_hint() {
        #[expect(clippy::needless_pass_by_value)]
        fn eq(body: Incoming, b: SizeHint, note: &str) {
            let a = body.size_hint();
            assert_eq!(a.lower(), b.lower(), "lower for {note:?}");
            assert_eq!(a.upper(), b.upper(), "upper for {note:?}");
        }

        eq(Incoming::empty(), SizeHint::with_exact(0), "empty");

        eq(Incoming::channel().1, SizeHint::new(), "channel");

        eq(
            Incoming::new_channel(DecodedLength::new(4), /*wanter =*/ false).1,
            SizeHint::with_exact(4),
            "channel with length",
        );
    }

    #[cfg(not(miri))]
    #[tokio::test]
    async fn channel_abort() {
        let (tx, mut rx) = Incoming::channel();

        tx.abort();

        let err = rx.frame().await.unwrap().unwrap_err();
        assert!(err.is_body_write_aborted(), "{err:?}");
    }

    #[cfg(not(miri))]
    #[tokio::test]
    async fn channel_abort_when_buffer_is_full() {
        let (mut tx, mut rx) = Incoming::channel();

        tx.try_send_data("chunk 1".into()).expect("send 1");
        // buffer is full, but can still send abort
        tx.abort();

        let chunk1 = rx
            .frame()
            .await
            .expect("item 1")
            .expect("chunk 1")
            .into_data()
            .unwrap();
        assert_eq!(chunk1, "chunk 1");

        let err = rx.frame().await.unwrap().unwrap_err();
        assert!(err.is_body_write_aborted(), "{err:?}");
    }

    #[test]
    fn channel_buffers_one() {
        let (mut tx, _rx) = Incoming::channel();

        tx.try_send_data("chunk 1".into()).expect("send 1");

        // buffer is now full
        let chunk2 = tx.try_send_data("chunk 2".into()).expect_err("send 2");
        assert_eq!(chunk2, "chunk 2");
    }

    #[cfg(not(miri))]
    #[tokio::test]
    async fn channel_empty() {
        let (_, mut rx) = Incoming::channel();

        assert!(rx.frame().await.is_none());
    }

    #[test]
    fn channel_ready() {
        let (mut tx, _rx) = Incoming::new_channel(DecodedLength::CHUNKED, /*wanter = */ false);

        let mut tx_ready = tokio_test::task::spawn(tx.ready());

        assert!(tx_ready.poll().is_ready(), "tx is ready immediately");
    }

    #[test]
    fn channel_wanter() {
        let (mut tx, mut rx) =
            Incoming::new_channel(DecodedLength::CHUNKED, /*wanter = */ true);

        let mut tx_ready = tokio_test::task::spawn(tx.ready());
        let mut rx_data = tokio_test::task::spawn(rx.frame());

        assert!(
            tx_ready.poll().is_pending(),
            "tx isn't ready before rx has been polled"
        );

        assert!(rx_data.poll().is_pending(), "poll rx.data");
        assert!(tx_ready.is_woken(), "rx poll wakes tx");

        assert!(
            tx_ready.poll().is_ready(),
            "tx is ready after rx has been polled"
        );
    }

    #[test]
    fn channel_notices_closure() {
        let (mut tx, rx) = Incoming::new_channel(DecodedLength::CHUNKED, /*wanter = */ true);

        let mut tx_ready = tokio_test::task::spawn(tx.ready());

        assert!(
            tx_ready.poll().is_pending(),
            "tx isn't ready before rx has been polled"
        );

        drop(rx);
        assert!(tx_ready.is_woken(), "dropping rx wakes tx");

        match &tx_ready.poll() {
            Poll::Ready(Err(e)) if e.is_closed() => (),
            unexpected => panic!("tx poll ready unexpected: {unexpected:?}"),
        }
    }
}
