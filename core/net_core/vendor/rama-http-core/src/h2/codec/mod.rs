mod error;
mod framed_read;
mod framed_write;

pub use self::error::{SendError, UserError};
pub(crate) use self::framed_read::HeadProgress;

use self::framed_read::FramedRead;
use self::framed_write::FramedWrite;

use crate::h2::proto::Error;

use rama_core::bytes::{Buf, BytesMut};
use rama_core::extensions::ExtensionsRef;
use rama_core::futures::Sink;
use rama_core::futures::Stream;
use rama_core::stream::codec::length_delimited;

use rama_http_types::proto::h2::frame::{self, Data, Frame};
use std::pin::Pin;
use std::task::{Context, Poll};
use tokio::io::{AsyncRead, AsyncWrite};

use std::io;

#[derive(Debug)]
pub struct Codec<T, B> {
    inner: FramedRead<FramedWrite<T, B>>,
}

impl<T, B> Codec<T, B>
where
    T: AsyncRead + AsyncWrite + Unpin,
    B: Buf,
{
    /// Returns a new `Codec` with the default max frame size
    #[inline]
    pub fn new(io: T) -> Self {
        Self::with_max_recv_frame_size(io, frame::DEFAULT_MAX_FRAME_SIZE as usize)
    }

    /// Returns a new `Codec` with the given maximum frame size
    pub fn with_max_recv_frame_size(io: T, max_frame_size: usize) -> Self {
        // Wrap with writer
        let framed_write = FramedWrite::new(io);

        // Delimit the frames
        let delimited = length_delimited::Builder::new()
            .big_endian()
            .length_field_length(3)
            .length_adjustment(9)
            .num_skip(0) // Don't skip the header
            .new_read(framed_write);

        let mut inner = FramedRead::new(delimited);

        // Use FramedRead's method since it checks the value is within range.
        inner.set_max_frame_size(max_frame_size);

        Self { inner }
    }
}

impl<T, B> Codec<T, B> {
    pub(crate) fn into_read_buffer(self) -> BytesMut {
        self.inner.into_read_buffer()
    }

    pub fn set_observe_early_frames(&mut self, enabled: bool) {
        self.inner.set_observe_early_frames(enabled);
    }

    /// The request head the peer started but did not complete, if any.
    pub(crate) fn head_progress(&self) -> Option<HeadProgress> {
        self.inner.head_progress()
    }

    /// Enable decoding ALTSVC advertisements. Servers must disable this:
    /// RFC 7838 §4 requires them to ignore client advertisements entirely.
    /// Header-block continuity and the receive frame-size limit still apply.
    pub fn set_recv_alt_svc(&mut self, enabled: bool) {
        self.inner.set_recv_alt_svc(enabled);
    }

    /// Updates the max received frame size.
    ///
    /// The change takes effect the next time a frame is decoded. In other
    /// words, if a frame is currently in process of being decoded with a frame
    /// size greater than `val` but less than the max frame size in effect
    /// before calling this function, then the frame will be allowed.
    #[inline]
    pub fn set_max_recv_frame_size(&mut self, val: usize) {
        self.inner.set_max_frame_size(val)
    }

    /// Returns the current max received frame size setting.
    ///
    /// This is the largest size this codec will accept from the wire. Larger
    /// frames will be rejected.
    #[cfg(feature = "unstable")]
    #[inline]
    #[cfg_attr(docsrs, doc(cfg(feature = "unstable")))]
    pub fn max_recv_frame_size(&self) -> usize {
        self.inner.max_frame_size()
    }

    /// Returns the max frame size that can be sent to the peer.
    pub fn max_send_frame_size(&self) -> usize {
        self.inner.get_ref().max_frame_size()
    }

    /// Set the peer's max frame size.
    pub fn set_max_send_frame_size(&mut self, val: usize) {
        self.framed_write().set_max_frame_size(val)
    }

    /// Set the peer's header table size size.
    pub fn set_send_header_table_size(&mut self, val: usize) {
        self.framed_write().set_header_table_size(val)
    }

    /// Set the decoder header table size size.
    pub fn set_recv_header_table_size(&mut self, val: usize) {
        self.inner.set_header_table_size(val)
    }

    /// Set the max header list size that can be received.
    pub fn set_max_recv_header_list_size(&mut self, val: usize) {
        self.inner.set_max_header_list_size(val);
    }

    /// Get a reference to the inner stream.
    #[cfg(feature = "unstable")]
    #[cfg_attr(docsrs, doc(cfg(feature = "unstable")))]
    pub fn get_ref(&self) -> &T {
        self.inner.get_ref().get_ref()
    }

    /// Get a mutable reference to the inner stream.
    pub fn get_mut(&mut self) -> &mut T {
        self.inner.get_mut().get_mut()
    }

    /// Takes the data payload value that was fully written to the socket
    pub(crate) fn take_last_data_frame(&mut self) -> Option<Data<B>> {
        self.framed_write().take_last_data_frame()
    }

    fn framed_write(&mut self) -> &mut FramedWrite<T, B> {
        self.inner.get_mut()
    }
}

impl<T, B> Codec<T, B>
where
    T: AsyncWrite + Unpin,
    B: Buf,
{
    /// Returns `Ready` when the codec can buffer a frame
    pub fn poll_ready(&mut self, cx: &mut Context) -> Poll<io::Result<()>> {
        self.framed_write().poll_ready(cx)
    }

    /// Returns whether the codec can buffer a frame without flushing the
    /// underlying I/O object.
    pub(crate) fn has_send_capacity(&mut self) -> bool {
        self.framed_write().has_capacity()
    }

    /// Buffer a frame.
    ///
    /// `poll_ready` must be called first to ensure that a frame may be
    /// accepted.
    ///
    /// TODO: Rename this to avoid conflicts with Sink::buffer
    pub fn buffer(&mut self, item: Frame<B>) -> Result<(), UserError> {
        self.framed_write().buffer(item)
    }

    /// Flush buffered data to the wire
    pub fn flush(&mut self, cx: &mut Context) -> Poll<io::Result<()>> {
        self.framed_write().flush(cx)
    }

    /// Shutdown the send half
    pub fn shutdown(&mut self, cx: &mut Context) -> Poll<io::Result<()>> {
        self.framed_write().shutdown(cx)
    }
}

impl<T: ExtensionsRef, B> ExtensionsRef for Codec<T, B> {
    fn extensions(&self) -> &rama_core::extensions::Extensions {
        self.inner.extensions()
    }
}

impl<T, B> Stream for Codec<T, B>
where
    T: AsyncRead + Unpin,
{
    type Item = Result<Frame, Error>;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        Pin::new(&mut self.inner).poll_next(cx)
    }
}

impl<T, B> Sink<Frame<B>> for Codec<T, B>
where
    T: AsyncWrite + Unpin,
    B: Buf,
{
    type Error = SendError;

    fn start_send(mut self: Pin<&mut Self>, item: Frame<B>) -> Result<(), Self::Error> {
        Self::buffer(&mut self, item)?;
        Ok(())
    }
    /// Returns `Ready` when the codec can buffer a frame
    fn poll_ready(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        self.framed_write().poll_ready(cx).map_err(Into::into)
    }

    /// Flush buffered data to the wire
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        self.framed_write().flush(cx).map_err(Into::into)
    }

    fn poll_close(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        ready!(self.shutdown(cx))?;
        Poll::Ready(Ok(()))
    }
}

// TODO: remove (or improve) this
impl<T> From<T> for Codec<T, rama_core::bytes::Bytes>
where
    T: AsyncRead + AsyncWrite + Unpin,
{
    fn from(src: T) -> Self {
        Self::new(src)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rama_core::bytes::{Bytes, BytesMut};
    use rama_core::futures::{FutureExt, StreamExt};
    use rama_http_types::proto::h2::frame::{AltSvc, Head, Kind, Ping, Reason, StreamId};
    use std::assert_matches;
    use tokio::io::AsyncWriteExt;

    fn advertisement() -> AltSvc {
        AltSvc::new(
            StreamId::zero(),
            Bytes::from_static(b"https://example.com"),
            Bytes::from_static(b"h2=\":443\"; ma=60"),
        )
        .unwrap()
    }

    #[tokio::test]
    async fn buffered_altsvc_bursts_yield_without_losing_clear() {
        tokio::spawn(async {
            let mut wire = BytesMut::new();
            for _ in 0..1024 {
                advertisement().encode(&mut wire);
            }
            let clear = AltSvc::new(
                StreamId::zero(),
                Bytes::from_static(b"https://example.com"),
                Bytes::from_static(b"clear"),
            )
            .unwrap();
            clear.encode(&mut wire);
            let mut codec = Codec::<_, Bytes>::new(io::Cursor::new(wire.to_vec()));
            let mut received = 0;
            while let Some(frame) = codec.next().now_or_never() {
                assert_eq!(frame.unwrap().unwrap(), Frame::AltSvc(advertisement()));
                received += 1;
            }
            assert!(received > 0 && received < 1024);
            while received < 1024 {
                assert_eq!(
                    codec.next().await.unwrap().unwrap(),
                    Frame::AltSvc(advertisement())
                );
                received += 1;
            }
            assert_eq!(codec.next().await.unwrap().unwrap(), Frame::AltSvc(clear));
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn ignored_altsvc_bursts_yield_before_following_control_frame() {
        tokio::spawn(async {
            let mut wire = BytesMut::new();
            for _ in 0..1024 {
                advertisement().encode(&mut wire);
            }
            let ping = Ping::new(*b"abcdefgh");
            ping.encode(&mut wire);
            let mut codec = Codec::<_, Bytes>::new(io::Cursor::new(wire.to_vec()));
            codec.set_recv_alt_svc(false);
            assert!(codec.next().now_or_never().is_none());
            assert_eq!(codec.next().await.unwrap().unwrap(), Frame::Ping(ping));
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn altsvc_decodes_at_every_fragment_boundary() {
        let expected = advertisement();
        let mut wire = BytesMut::new();
        expected.encode(&mut wire);
        for split in 0..wire.len() {
            let (io, mut peer) = tokio::io::duplex(wire.len());
            let mut codec = Codec::<_, Bytes>::new(io);
            peer.write_all(&wire[..split]).await.unwrap();
            assert!(codec.next().now_or_never().is_none(), "split {split}");
            peer.write_all(&wire[split..]).await.unwrap();
            assert_eq!(
                codec.next().await.unwrap().unwrap(),
                Frame::AltSvc(expected.clone())
            );
        }
    }

    #[tokio::test]
    async fn invalid_altsvc_is_ignored_without_losing_the_following_frame() {
        for (id, payload) in [(0, b"\x00\x00clear".as_slice()), (1, b"\x00\x01xclear")] {
            let mut wire = BytesMut::new();
            Head::new(Kind::AltSvc, 0, StreamId::from(id)).encode(payload.len(), &mut wire);
            wire.extend_from_slice(payload);
            let ping = Ping::new(*b"abcdefgh");
            ping.encode(&mut wire);
            let (io, mut peer) = tokio::io::duplex(wire.len());
            let mut codec = Codec::<_, Bytes>::new(io);
            peer.write_all(&wire).await.unwrap();
            assert_eq!(codec.next().await.unwrap().unwrap(), Frame::Ping(ping));
        }
    }

    #[tokio::test]
    async fn truncated_altsvc_is_a_frame_size_error_but_servers_ignore_it() {
        for payload in [b"".as_slice(), b"\x00", b"\x00\x01", b"\xff\xffx"] {
            for enabled in [true, false] {
                let mut wire = BytesMut::new();
                Head::new(Kind::AltSvc, 0, StreamId::zero()).encode(payload.len(), &mut wire);
                wire.extend_from_slice(payload);
                let ping = Ping::new(*b"abcdefgh");
                ping.encode(&mut wire);
                let (io, mut peer) = tokio::io::duplex(wire.len());
                let mut codec = Codec::<_, Bytes>::new(io);
                codec.set_recv_alt_svc(enabled);
                peer.write_all(&wire).await.unwrap();
                let result = codec.next().await.unwrap();
                if enabled {
                    assert_matches!(result, Err(Error::GoAway(_, Reason::FRAME_SIZE_ERROR, _)));
                } else {
                    assert_eq!(result.unwrap(), Frame::Ping(ping));
                }
            }
        }
    }

    #[tokio::test]
    async fn altsvc_cannot_interrupt_a_header_block_even_when_invalid() {
        for payload in [b"".as_slice(), b"\x00\x00clear"] {
            for enabled in [true, false] {
                let mut wire = BytesMut::new();
                Head::new(Kind::Headers, 0, StreamId::from(1)).encode(0, &mut wire);
                Head::new(Kind::AltSvc, 0, StreamId::from(1)).encode(payload.len(), &mut wire);
                wire.extend_from_slice(payload);
                let (io, mut peer) = tokio::io::duplex(wire.len());
                let mut codec = Codec::<_, Bytes>::new(io);
                codec.set_recv_alt_svc(enabled);
                peer.write_all(&wire).await.unwrap();
                assert_matches!(
                    codec.next().await.unwrap(),
                    Err(Error::GoAway(_, Reason::PROTOCOL_ERROR, _)),
                );
            }
        }
    }

    #[tokio::test]
    async fn altsvc_encoding_roundtrips_through_the_codec() {
        let (writer, reader) = tokio::io::duplex(128);
        let mut sender = Codec::<_, Bytes>::new(writer);
        let mut receiver = Codec::<_, Bytes>::new(reader);
        let expected = advertisement();
        sender.buffer(expected.clone().into()).unwrap();
        std::future::poll_fn(|cx| sender.flush(cx)).await.unwrap();
        assert_eq!(
            receiver.next().await.unwrap().unwrap(),
            Frame::AltSvc(expected)
        );
    }

    #[tokio::test]
    async fn altsvc_respects_negotiated_frame_size_in_both_directions() {
        let frame = AltSvc::new(
            StreamId::from(1),
            Bytes::new(),
            Bytes::from(vec![b'a'; frame::DEFAULT_MAX_FRAME_SIZE as usize]),
        )
        .unwrap();
        let mut wire = BytesMut::new();
        frame.encode(&mut wire);
        let (io, mut peer) = tokio::io::duplex(wire.len());
        let mut codec = Codec::<_, Bytes>::new(io);
        assert_matches!(codec.buffer(frame.into()), Err(UserError::PayloadTooBig));
        peer.write_all(&wire).await.unwrap();
        assert_matches!(
            codec.next().await.unwrap(),
            Err(Error::GoAway(_, Reason::FRAME_SIZE_ERROR, _)),
        );
    }
}

#[cfg(test)]
mod observation_tests {
    use super::*;
    use rama_core::{
        bytes::{Bytes, BytesMut},
        futures::StreamExt as _,
    };
    use rama_http_types::proto::h2::frame::{Head, Kind, Ping, StreamId};

    #[tokio::test]
    async fn settings_wire_observation_is_opt_in_and_preserves_occurrences() {
        for enabled in [false, true] {
            let entries = [(1_u16, 100_u32), (0x42, 99), (1, 200), (0x42, 7)];
            let mut wire = BytesMut::new();
            Head::new(Kind::Settings, 0, StreamId::zero()).encode(entries.len() * 6, &mut wire);
            for (id, value) in entries {
                wire.extend_from_slice(&id.to_be_bytes());
                wire.extend_from_slice(&value.to_be_bytes());
            }
            let ping = Ping::new(*b"abcdefgh");
            ping.encode(&mut wire);
            let mut codec = Codec::<_, Bytes>::new(io::Cursor::new(wire.to_vec()));
            if enabled {
                codec.set_observe_early_frames(true);
            }
            let Frame::Settings(settings) = codec.next().await.unwrap().unwrap() else {
                panic!("expected settings")
            };
            assert_eq!(settings.config.header_table_size, Some(200));
            assert_eq!(settings.observation.is_some(), enabled);
            assert_eq!(settings.config.setting_order.is_some(), enabled);
            if let Some(observation) = settings.observation {
                assert!(observation.complete);
                assert_eq!(
                    observation
                        .entries
                        .iter()
                        .map(|entry| (u16::from(entry.id), entry.value))
                        .collect::<Vec<_>>(),
                    entries
                );
            }
            assert_eq!(codec.next().await.unwrap().unwrap(), Frame::Ping(ping));
        }
    }
}
