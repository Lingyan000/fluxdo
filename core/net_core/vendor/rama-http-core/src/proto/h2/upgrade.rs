use std::io::Cursor;
use std::pin::Pin;
use std::sync::{
    Arc, Weak,
    atomic::{AtomicU32, Ordering},
};
use std::task::{Context, Poll};

use rama_core::bytes::{Buf, Bytes};
use rama_core::extensions::{Extensions, ExtensionsRef};
use rama_core::futures::ready;
use rama_core::io::AbortIo;
use rama_core::telemetry::tracing::trace;
use rama_http::io::upgrade::OnMalformedMessage;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

use super::SendBuf;
use super::ping::Recorder;
use crate::h2::{Reason, RecvStream, SendStream};

/// `extended` marks an Extended CONNECT tunnel (RFC 8441), else a CONNECT one (RFC 9113 §8.5).
pub(super) fn upgraded<B>(
    send_stream: SendStream<SendBuf<B>>,
    recv_stream: RecvStream,
    ping: Recorder,
    extended: bool,
) -> H2Upgraded
where
    B: Buf + Send + 'static,
{
    // The upgraded IO owns this HTTP/2 stream's transport metadata. Message
    // extensions may contain OnUpgrade itself, creating a cycle through the
    // queued Upgraded, and may describe the opposite side of a proxy.
    let extensions = recv_stream.extensions();
    // The hooks live in the stream's own extensions, so they only hold a weak reference to
    // the tunnel's reset handle. RFC 9297 §3.3 via RFC 9113 §8.1.1: a malformed data stream
    // resets PROTOCOL_ERROR at once, also after a local END_STREAM.
    let reset: Arc<TunnelReset> = Arc::new(TunnelReset {
        reason: AtomicU32::new(0),
        reset: Box::new(send_stream.reset_handle()),
    });
    let hook = |reason: Reason| {
        let reset = Arc::downgrade(&reset);
        move || {
            if let Some(reset) = Weak::upgrade(&reset) {
                reset.trigger(reason);
            }
        }
    };
    extensions.insert(OnMalformedMessage::new(hook(Reason::PROTOCOL_ERROR)));
    // A TCP RST maps to CANCEL (RFC 8441 §5) or CONNECT_ERROR (RFC 9113 §8.5).
    extensions.insert(AbortIo::new(hook(if extended {
        Reason::CANCEL
    } else {
        Reason::CONNECT_ERROR
    })));
    H2Upgraded {
        send_stream: Box::new(send_stream),
        send_closed: false,
        reset,
        recv_stream,
        ping,
        buf: Bytes::new(),
        extensions,
    }
}

/// The h2 send half of a tunnel with the body type erased, so the upgraded IO
/// writes into the stream directly instead of hopping through a channel and a
/// writer task per tunnel.
trait TunnelSink: Send {
    fn reserve_capacity(&mut self, capacity: usize);
    fn poll_capacity(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<usize, crate::h2::Error>>>;
    fn poll_reset(&mut self, cx: &mut Context<'_>) -> Poll<Result<Reason, crate::h2::Error>>;
    fn send_data(&mut self, data: Box<[u8]>) -> Result<(), crate::h2::Error>;
    fn send_end_of_stream(&mut self) -> Result<(), crate::h2::Error>;
}

impl<B> TunnelSink for SendStream<SendBuf<B>>
where
    B: Buf + Send + 'static,
{
    fn reserve_capacity(&mut self, capacity: usize) {
        Self::reserve_capacity(self, capacity);
    }

    fn poll_capacity(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<usize, crate::h2::Error>>> {
        Self::poll_capacity(self, cx)
    }

    fn poll_reset(&mut self, cx: &mut Context<'_>) -> Poll<Result<Reason, crate::h2::Error>> {
        Self::poll_reset(self, cx)
    }

    fn send_data(&mut self, data: Box<[u8]>) -> Result<(), crate::h2::Error> {
        Self::send_data(self, SendBuf::Cursor(Cursor::new(data)), false)
    }

    fn send_end_of_stream(&mut self) -> Result<(), crate::h2::Error> {
        Self::send_data(self, SendBuf::None, true)
    }
}

/// The tunnel's local reset; `reason` is zero while open (a reset never uses NO_ERROR).
struct TunnelReset {
    reason: AtomicU32,
    reset: Box<dyn Fn(Reason) + Send + Sync>,
}

impl TunnelReset {
    fn trigger(&self, reason: Reason) {
        if self
            .reason
            .compare_exchange(0, reason.into(), Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            (self.reset)(reason);
        }
    }

    fn reason(&self) -> Option<Reason> {
        match self.reason.load(Ordering::Acquire) {
            0 => None,
            reason => Some(reason.into()),
        }
    }
}

pub(super) struct H2Upgraded {
    ping: Recorder,
    send_stream: Box<dyn TunnelSink>,
    send_closed: bool,
    reset: Arc<TunnelReset>,
    recv_stream: RecvStream,
    buf: Bytes,
    extensions: Extensions,
}

impl ExtensionsRef for H2Upgraded {
    fn extensions(&self) -> &Extensions {
        &self.extensions
    }
}

impl H2Upgraded {
    /// A tunnel reset by one of its hooks fails both directions, buffered data included.
    fn check_reset(&self) -> Result<(), std::io::Error> {
        match self.reset.reason() {
            None => Ok(()),
            Some(Reason::PROTOCOL_ERROR) => Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "malformed tunnel data stream",
            )),
            Some(_) => Err(std::io::Error::new(
                std::io::ErrorKind::ConnectionAborted,
                "tunnel aborted locally",
            )),
        }
    }
}

impl Drop for H2Upgraded {
    fn drop(&mut self) {
        // Half-close as a TCP close would: a reset discards what h2 still queues (aborts go
        // through the stream's `AbortIo`).
        if !self.send_closed && self.reset.reason().is_none() {
            _ = self.send_stream.send_end_of_stream();
        }
    }
}

// ===== impl H2Upgraded =====

impl AsyncRead for H2Upgraded {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        read_buf: &mut ReadBuf<'_>,
    ) -> Poll<Result<(), std::io::Error>> {
        // A malformed abort also discards data still buffered here.
        self.check_reset()?;
        if self.buf.is_empty() {
            self.buf = loop {
                match ready!(self.recv_stream.poll_data(cx)) {
                    None => return Poll::Ready(Ok(())),
                    Some(Ok(buf)) if buf.is_empty() && !self.recv_stream.is_end_stream() => {}
                    Some(Ok(buf)) => {
                        self.ping.record_data(buf.len());
                        break buf;
                    }
                    Some(Err(e)) => {
                        return Poll::Ready(match e.reason() {
                            // A reset without error ends the stream as a FIN would.
                            Some(Reason::NO_ERROR) => Ok(()),
                            reason => Err(reset_to_io_error(reason, e)),
                        });
                    }
                }
            };
        }
        let cnt = std::cmp::min(self.buf.len(), read_buf.remaining());
        read_buf.put_slice(&self.buf[..cnt]);
        self.buf.advance(cnt);
        _ = self.recv_stream.flow_control().release_capacity(cnt);
        Poll::Ready(Ok(()))
    }
}

impl AsyncWrite for H2Upgraded {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<Result<usize, std::io::Error>> {
        if buf.is_empty() {
            return Poll::Ready(Ok(0));
        }
        self.check_reset()?;
        if self.send_closed {
            return Poll::Ready(Err(std::io::ErrorKind::BrokenPipe.into()));
        }

        // Flow control decides how much of this write fits; a partial write is
        // fine for `AsyncWrite`. Errors from the capacity and data paths are
        // read off `poll_reset`, which carries the peer's actual reason.
        self.send_stream.reserve_capacity(buf.len());
        let sent = loop {
            match ready!(self.send_stream.poll_capacity(cx)) {
                // No longer open for sending: report the reset rather than a zero write.
                None => {
                    return Poll::Ready(Err(match self.send_stream.poll_reset(cx) {
                        Poll::Ready(result) => poll_reset_to_io_error(result),
                        Poll::Pending => std::io::ErrorKind::BrokenPipe.into(),
                    }));
                }
                // a zero grant is not a grant yet; poll again
                Some(Ok(0)) => {}
                Some(Ok(cnt)) => {
                    let cnt = cnt.min(buf.len());
                    break self
                        .send_stream
                        .send_data(buf[..cnt].into())
                        .ok()
                        .map(|()| cnt);
                }
                Some(Err(_)) => break None,
            }
        };
        if let Some(sent) = sent {
            return Poll::Ready(Ok(sent));
        }

        Poll::Ready(Err(poll_reset_to_io_error(ready!(
            self.send_stream.poll_reset(cx)
        ))))
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<Result<(), std::io::Error>> {
        // data handed to h2 is flushed by the connection task
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Result<(), std::io::Error>> {
        self.check_reset()?;
        if self.send_closed {
            return Poll::Ready(Ok(()));
        }
        self.send_closed = true;
        Poll::Ready(self.send_stream.send_end_of_stream().map_err(|error| {
            // A stream the peer reset reports that reset, as a write would.
            match self.send_stream.poll_reset(cx) {
                Poll::Ready(result) => poll_reset_to_io_error(result),
                Poll::Pending => h2_to_io_error(error),
            }
        }))
    }
}

/// A stream reset is a `ConnectionReset` carrying its reason, so a relay can reflect it
/// (RFC 9113 §8.5); only a reset without error is a `BrokenPipe`. A stream that ended in order
/// never carries a reason, so `STREAM_CLOSED` is a reset like any other.
fn reset_to_io_error(reason: Option<Reason>, e: crate::h2::Error) -> std::io::Error {
    match reason {
        Some(Reason::NO_ERROR) => std::io::Error::new(std::io::ErrorKind::BrokenPipe, e),
        Some(_) if e.is_reset() => std::io::Error::new(std::io::ErrorKind::ConnectionReset, e),
        _ => h2_to_io_error(e),
    }
}

fn poll_reset_to_io_error(result: Result<Reason, crate::h2::Error>) -> std::io::Error {
    match result {
        Ok(reason) => {
            trace!("stream received RST_STREAM: {:?}", reason);
            match reason {
                Reason::NO_ERROR => std::io::ErrorKind::BrokenPipe.into(),
                reason => std::io::Error::new(
                    std::io::ErrorKind::ConnectionReset,
                    crate::h2::Error::from(reason),
                ),
            }
        }
        Err(e) => reset_to_io_error(e.reason(), e),
    }
}

#[inline(always)]
fn h2_to_io_error(e: crate::h2::Error) -> std::io::Error {
    e.force_into_io()
}
