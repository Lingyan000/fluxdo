use std::{
    future::{Future, poll_fn},
    io,
    pin::{Pin, pin},
    sync::{
        Arc, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
    task::{Context, Poll, ready},
};

use rama_core::bytes::Bytes;
use rama_net::gate::GateDirection;
use rama_quic_proto::{StreamId, VarInt};
use tokio::sync::Notify;

use crate::{
    driver::{
        connection::{ConnectionRef, SendDatagramError, State},
        gate::GateStack,
    },
    proto::{
        ClosedStream, ConnectionError, FinishError, SendStream as ProtoSendStream,
        WriteError as ProtoWriteError, Written,
    },
};

/// A stream that can only be used to send data
///
/// If dropped, streams that haven't been explicitly [`reset()`] will be implicitly [`finish()`]ed,
/// continuing to (re)transmit previously written data until it has been fully acknowledged or the
/// connection is closed.
///
/// # Cancellation
///
/// A `write` method is said to be *cancel-safe* when dropping its future before the future becomes
/// ready will always result in no data being written to the stream. This is true of methods which
/// succeed immediately when any progress is made, and is not true of methods which might need to
/// perform multiple writes internally before succeeding. Each `write` method documents whether it is
/// cancel-safe.
///
/// [`reset()`]: SendStream::reset
/// [`finish()`]: SendStream::finish
#[derive(Debug)]
pub struct SendStream {
    conn: ConnectionRef,
    stream: StreamId,
    is_0rtt: bool,
    // Allocate shared reset state only when an independent observer or abort
    // handle exists. It dies with those handles, never with connection history.
    // Zero means not reset; QUIC's 62-bit code plus one fits losslessly.
    local_reset: u64,
    events: OnceLock<Arc<SendStreamEvents>>,
    gates: Option<GateStack>,
}

/// Cloneable handle to a stream, independent of its I/O owner: aborts the stream
/// (resets sending and, for bidirectional streams, stops receiving) and sends
/// datagrams bound to it. Dropping the handle has no effect on the stream.
#[derive(Debug, Clone)]
pub struct StreamHandle {
    conn: ConnectionRef,
    stream: StreamId,
    is_0rtt: bool,
    events: Arc<SendStreamEvents>,
}

impl StreamHandle {
    /// Queue a connection datagram bound to this stream, dropping the oldest queued ones for
    /// space (see [`Connection::send_datagram`](crate::Connection::send_datagram)).
    ///
    /// The stream's send side is checked under the lock that queues the datagram: once it is
    /// finished (even before the FIN is acknowledged), reset, stopped by the peer or lost, this
    /// returns [`SendDatagramError::StreamClosed`] (RFC 9297 §2.1). It never polls the stream.
    /// FIN waits until previously queued datagrams for this stream leave the local send
    /// queue through transmission or a permitted drop. Network delivery remains unreliable.
    pub fn send_datagram(&self, data: Bytes) -> Result<(), SendDatagramError> {
        self.send_stream_datagram(data, true)
    }

    /// As [`send_datagram`](Self::send_datagram), but a full send buffer returns
    /// [`SendDatagramError::Blocked`] instead of dropping queued datagrams.
    pub fn try_send_datagram(&self, data: Bytes) -> Result<(), SendDatagramError> {
        self.send_stream_datagram(data, false)
    }

    fn send_stream_datagram(
        &self,
        data: Bytes,
        drop_oldest: bool,
    ) -> Result<(), SendDatagramError> {
        let gates = {
            let mut conn = self.conn.state.lock();
            self.check_open(&mut conn)?;
            match conn.datagram_send_gates(data.len())? {
                Some(gates) => gates,
                None => return self.queue_datagram(&mut conn, data, drop_oldest),
            }
        };
        if !self
            .conn
            .admit_datagram(&gates, GateDirection::Write, data.len())
        {
            return Ok(());
        }
        let mut conn = self.conn.state.lock();
        self.check_open(&mut conn)?;
        self.queue_datagram(&mut conn, data, drop_oldest)
    }

    /// The connection is alive and this stream's send side still open (RFC 9297 §2.1).
    fn check_open(&self, conn: &mut State) -> Result<(), SendDatagramError> {
        if let Some(ref error) = conn.error {
            return Err(SendDatagramError::ConnectionLost(error.clone()));
        }
        if (self.is_0rtt && conn.check_0rtt().is_err())
            || !conn.inner.send_stream(self.stream).is_open()
        {
            return Err(SendDatagramError::StreamClosed);
        }
        Ok(())
    }

    fn queue_datagram(
        &self,
        conn: &mut State,
        data: Bytes,
        drop_oldest: bool,
    ) -> Result<(), SendDatagramError> {
        conn.send_datagram(data, drop_oldest)?;
        let position = conn.inner.datagrams().send_queue_end();
        conn.inner.send_stream(self.stream).track_datagram(position);
        Ok(())
    }

    /// Abort both available directions. Already closed directions are harmless.
    pub fn abort(&self, error_code: impl Into<VarInt>) {
        let code = error_code.into();
        let mut conn = self.conn.state.lock();
        if self.is_0rtt && conn.check_0rtt().is_err() {
            return;
        }
        if conn.inner.send_stream(self.stream).reset(code).is_ok() {
            self.events
                .local_reset
                .store(code.into_inner() + 1, Ordering::Relaxed);
            if let Some(stopped) = conn.stopped.get(&self.stream) {
                stopped.events.notify.notify_waiters();
            }
        }
        if self.stream.dir() == rama_quic_proto::Dir::Bi {
            _ = conn.inner.recv_stream(self.stream).stop(code);
        }
        if let Some(waker) = conn.blocked_writers.remove(&self.stream) {
            waker.wake();
        }
        if let Some(waker) = conn.blocked_readers.remove(&self.stream) {
            waker.wake();
        }
        conn.wake();
    }
}

impl SendStream {
    pub(crate) fn new(conn: ConnectionRef, stream: StreamId, is_0rtt: bool) -> Self {
        Self {
            conn,
            stream,
            is_0rtt,
            local_reset: 0,
            events: OnceLock::new(),
            gates: None,
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Pace writing with `gates`.
        pub(crate) fn gates(mut self, gates: Option<GateStack>) -> Self {
            self.gates = gates;
            self
        }
    }

    /// Obtain a handle to abort this stream or send its datagrams from another owner or task.
    pub fn handle(&self) -> StreamHandle {
        StreamHandle {
            conn: self.conn.clone(),
            stream: self.stream,
            is_0rtt: self.is_0rtt,
            events: self.events().clone(),
        }
    }

    fn events(&self) -> &Arc<SendStreamEvents> {
        self.events.get_or_init(|| {
            Arc::new(SendStreamEvents {
                local_reset: AtomicU64::new(self.local_reset),
                peer_stop: AtomicU64::new(0),
                notify: Notify::new(),
            })
        })
    }

    /// Write a buffer into this stream, returning how many bytes were written
    ///
    /// Unless this method errors, it waits until some amount of `buf` can be written into this
    /// stream, and then writes as much as it can without waiting again. Due to congestion, flow
    /// control and [stream gates](crate::Connection::add_stream_gates), this may be shorter than
    /// `buf.len()`. On success this yields the length of the prefix that was written.
    ///
    /// # Cancel safety
    ///
    /// This method is cancellation safe. If this does not resolve, no bytes were written.
    pub async fn write(&mut self, buf: &[u8]) -> Result<usize, WriteError> {
        poll_fn(|cx| self.execute_poll(cx, buf.len(), |s, budget| s.write_within(buf, budget)))
            .await
    }

    /// Write a buffer into this stream in its entirety
    ///
    /// This method repeatedly calls [`write`](Self::write) until all bytes are written, or an
    /// error occurs.
    ///
    /// # Cancel safety
    ///
    /// This method is *not* cancellation safe. Even if this does not resolve, some prefix of `buf`
    /// may have been written when previously polled.
    pub async fn write_all(&mut self, mut buf: &[u8]) -> Result<(), WriteError> {
        while !buf.is_empty() {
            let written = self.write(buf).await?;
            buf = &buf[written..];
        }
        Ok(())
    }

    /// Write a slice of [`Bytes`] into this stream, returning how much was written
    ///
    /// Bytes to try to write are provided to this method as an array of cheaply cloneable chunks.
    /// Unless this method errors, it waits until some amount of those bytes can be written into
    /// this stream, and then writes as much as it can without waiting again. Due to congestion,
    /// flow control and [stream gates](crate::Connection::add_stream_gates), this may be less than the
    /// total number of bytes.
    ///
    /// On success, this method both mutates `bufs` and yields an informative [`Written`] struct
    /// indicating how much was written:
    ///
    /// - [`Bytes`] chunks that were fully written are mutated to be [empty](Bytes::is_empty).
    /// - If a [`Bytes`] chunk was partially written, it is [split to](Bytes::split_to) contain
    ///   only the suffix of bytes that were not written.
    /// - The yielded [`Written`] struct indicates how many chunks were fully written as well as
    ///   how many bytes were written.
    ///
    /// # Cancel safety
    ///
    /// This method is cancellation safe. If this does not resolve, no bytes were written.
    pub async fn write_chunks(&mut self, bufs: &mut [Bytes]) -> Result<Written, WriteError> {
        poll_fn(|cx| self.poll_write_chunks(cx, bufs)).await
    }

    /// Polling equivalent of [`Self::write_chunks`].
    ///
    /// On `Pending`, no bytes are consumed and the current waker is registered.
    /// On success, `bufs` retains only unwritten suffixes, which the caller must
    /// preserve until the next poll. No payload copy is required.
    pub fn poll_write_chunks(
        &mut self,
        cx: &mut Context<'_>,
        bufs: &mut [Bytes],
    ) -> Poll<Result<Written, WriteError>> {
        let want = self.gated_len(bufs);
        self.execute_poll(cx, want, |s, budget| s.write_chunks_within(bufs, 0, budget))
    }

    /// Write a single [`Bytes`] into this stream in its entirety
    ///
    /// Bytes to write are provided to this method as an single cheaply cloneable chunk. This
    /// method repeatedly calls [`write_chunks`](Self::write_chunks) until all bytes are written,
    /// or an error occurs.
    ///
    /// # Cancel safety
    ///
    /// This method is *not* cancellation safe. Even if this does not resolve, some bytes may have
    /// been written when previously polled.
    pub async fn write_chunk(&mut self, buf: Bytes) -> Result<(), WriteError> {
        self.write_all_chunks(&mut [buf]).await?;
        Ok(())
    }

    /// Write chunks while leaving connection credit available for critical streams.
    /// The reserve is capped at half the peer's initial connection window and local send window,
    /// so even very small peer windows can make application progress.
    /// Bytes accepted by this call are removed from `chunks`, including partial chunks.
    pub fn poll_write_chunks_with_reserve(
        &mut self,
        cx: &mut Context<'_>,
        chunks: &mut [Bytes],
        reserve: u64,
    ) -> Poll<Result<Written, WriteError>> {
        let want = self.gated_len(chunks);
        self.execute_poll(cx, want, |stream, budget| {
            stream.write_chunks_within(chunks, reserve, budget)
        })
    }

    /// Generate and atomically admit one bounded chunk without waiting for credit.
    ///
    /// Never waits on [stream gates](crate::Connection::add_stream_gates) either: it is
    /// meant for small control data, such as QPACK encoder instructions.
    ///
    /// `generate` receives the available stream and connection credit and returns
    /// a chunk plus an application result. `reserve` leaves connection credit for
    /// other streams, capped at half the initial connection and local send windows. Returning an empty chunk is permitted,
    /// including when capacity is zero. This supports optional compression whose
    /// instructions must fit in their entirety before being committed.
    ///
    /// The callback runs under the connection lock: keep it bounded and do not
    /// call back into this connection. Panics if its chunk exceeds the supplied capacity.
    pub fn try_write_generated<R>(
        &mut self,
        reserve: u64,
        generate: impl FnOnce(usize) -> (Bytes, R),
    ) -> Result<R, WriteError> {
        let mut conn = self.conn.state.lock();
        if self.is_0rtt {
            conn.check_0rtt()
                .map_err(|()| WriteError::ZeroRttRejected)?;
        }
        if let Some(error) = &conn.error {
            return Err(WriteError::ConnectionLost(error.clone()));
        }
        let result = conn
            .inner
            .send_stream(self.stream)
            .write_generated(reserve, generate)
            .map_err(|error| match error {
                ProtoWriteError::Stopped(code) => WriteError::Stopped(code),
                ProtoWriteError::ClosedStream | ProtoWriteError::Blocked => {
                    WriteError::ClosedStream
                }
            })?;
        conn.wake();
        Ok(result)
    }

    /// Write a slice of [`Bytes`] into this stream in its entirety
    ///
    /// Bytes to write are provided to this method as an array of cheaply cloneable chunks. This
    /// method repeatedly calls [`write_chunks`](Self::write_chunks) until all bytes are written,
    /// or an error occurs. This method mutates `bufs` by mutating all chunks to be
    /// [empty](Bytes::is_empty).
    ///
    /// # Cancel safety
    ///
    /// This method is *not* cancellation safe. Even if this does not resolve, some bytes may have
    /// been written when previously polled.
    pub async fn write_all_chunks(&mut self, mut bufs: &mut [Bytes]) -> Result<(), WriteError> {
        while !bufs.is_empty() {
            let written = self.write_chunks(bufs).await?;
            bufs = &mut bufs[written.chunks..];
        }
        Ok(())
    }

    /// The bytes `chunks` would ask a gated stream's gates for; never summed ungated.
    fn gated_len(&self, chunks: &[Bytes]) -> usize {
        if self.gates.is_none() {
            return 0;
        }
        chunks
            .iter()
            .fold(0, |total: usize, chunk| total.saturating_add(chunk.len()))
    }

    /// Run a write of (up to) `want` bytes; a gated stream writes only what its gates admit.
    fn execute_poll<F, R>(
        &mut self,
        cx: &mut Context,
        want: usize,
        write_fn: F,
    ) -> Poll<Result<R, WriteError>>
    where
        F: FnOnce(&mut ProtoSendStream, u64) -> Result<R, ProtoWriteError>,
        R: WrittenBytes,
    {
        if want == 0 || self.gates.is_none() {
            return self.execute_write(cx, u64::MAX, write_fn);
        }
        // Only data waits for the gates: a lost connection or a closed stream is reported at
        // once, and a stop wakes this task while it waits.
        match self.writable(cx) {
            Err(error) => return Poll::Ready(Err(error)),
            Ok(false) => return self.execute_write(cx, u64::MAX, write_fn),
            Ok(true) => {}
        }
        let Some(gates) = self.gates.as_mut() else {
            return self.execute_write(cx, u64::MAX, write_fn);
        };
        let admitted = ready!(gates.poll_admit(cx, want as u64));
        let poll = self.execute_write(cx, admitted, write_fn);
        if let Some(gates) = self.gates.as_mut() {
            let written = match &poll {
                Poll::Ready(Ok(written)) => written.bytes() as u64,
                _ => 0,
            };
            gates.settle(written);
        }
        poll
    }

    /// Whether this stream may still send, registering the task to hear of its events.
    fn writable(&self, cx: &Context<'_>) -> Result<bool, WriteError> {
        let mut conn = self.conn.state.lock();
        if self.is_0rtt {
            conn.check_0rtt()
                .map_err(|()| WriteError::ZeroRttRejected)?;
        }
        if let Some(ref x) = conn.error {
            return Err(WriteError::ConnectionLost(x.clone()));
        }
        if !conn.inner.send_stream(self.stream).is_open() {
            return Ok(false);
        }
        conn.blocked_writers.insert(self.stream, cx.waker().clone());
        Ok(true)
    }

    fn execute_write<F, R>(
        &self,
        cx: &Context<'_>,
        budget: u64,
        write_fn: F,
    ) -> Poll<Result<R, WriteError>>
    where
        F: FnOnce(&mut ProtoSendStream, u64) -> Result<R, ProtoWriteError>,
    {
        let mut conn = self.conn.state.lock();
        if self.is_0rtt {
            conn.check_0rtt()
                .map_err(|()| WriteError::ZeroRttRejected)?;
        }
        if let Some(ref x) = conn.error {
            return Poll::Ready(Err(WriteError::ConnectionLost(x.clone())));
        }

        // This write replaces a registration made while the gates were asked.
        conn.blocked_writers.remove(&self.stream);
        let result = match write_fn(&mut conn.inner.send_stream(self.stream), budget) {
            Ok(result) => result,
            Err(ProtoWriteError::Blocked) => {
                conn.blocked_writers.insert(self.stream, cx.waker().clone());
                return Poll::Pending;
            }
            Err(ProtoWriteError::Stopped(error_code)) => {
                return Poll::Ready(Err(WriteError::Stopped(error_code)));
            }
            Err(ProtoWriteError::ClosedStream) => {
                return Poll::Ready(Err(WriteError::ClosedStream));
            }
        };

        conn.wake();
        Poll::Ready(Ok(result))
    }

    /// Notify the peer that no more data will ever be written to this stream
    ///
    /// It is an error to write to a [`SendStream`] after `finish()`ing it. [`reset()`](Self::reset)
    /// may still be called after `finish` to abandon transmission of any stream data that might
    /// still be buffered.
    ///
    /// To wait for the peer to receive all buffered stream data, see [`stopped()`](Self::stopped).
    ///
    /// May fail if [`finish()`](Self::finish) or [`reset()`](Self::reset) was previously
    /// called. This error is harmless and serves only to indicate that the caller may have
    /// incorrect assumptions about the stream's state.
    pub fn finish(&mut self) -> Result<(), ClosedStream> {
        let mut conn = self.conn.state.lock();
        if self.is_0rtt && conn.check_0rtt().is_err() {
            return Err(ClosedStream::new());
        }
        match conn.inner.send_stream(self.stream).finish() {
            Ok(()) => {
                conn.wake();
                Ok(())
            }
            Err(FinishError::ClosedStream) => Err(ClosedStream::new()),
            // Harmless. If the application needs to know about stopped streams at this point, it
            // should call `stopped`.
            Err(FinishError::Stopped(_)) => Ok(()),
        }
    }

    /// Close the send stream immediately.
    ///
    /// No new data can be written after calling this method. Locally buffered data is dropped, and
    /// previously transmitted data will no longer be retransmitted if lost. If an attempt has
    /// already been made to finish the stream, the peer may still receive all written data.
    ///
    /// May fail if [`finish()`](Self::finish) or [`reset()`](Self::reset) was previously
    /// called. This error is harmless and serves only to indicate that the caller may have
    /// incorrect assumptions about the stream's state.
    pub fn reset(&mut self, error_code: impl Into<VarInt>) -> Result<(), ClosedStream> {
        let error_code = error_code.into();
        let mut conn = self.conn.state.lock();
        if self.is_0rtt && conn.check_0rtt().is_err() {
            return Ok(());
        }
        conn.inner.send_stream(self.stream).reset(error_code)?;
        self.local_reset = error_code.into_inner() + 1;
        if let Some(reset) = self.events.get() {
            reset.local_reset.store(self.local_reset, Ordering::Relaxed);
        }
        if let Some(stopped) = conn.stopped.get(&self.stream) {
            stopped.events.notify.notify_waiters();
        }
        conn.wake();
        Ok(())
    }

    /// Set the priority of the send stream
    ///
    /// Every send stream has an initial priority of 0. Locally buffered data from streams with
    /// higher priority will be transmitted before data from streams with lower priority. Changing
    /// the priority of a stream with pending data may only take effect after that data has been
    /// transmitted. Using many different priority levels per connection may have a negative
    /// impact on performance.
    pub fn set_priority(&self, priority: i32) -> Result<(), ClosedStream> {
        let mut conn = self.conn.state.lock();
        if self.is_0rtt && conn.check_0rtt().is_err() {
            return Err(ClosedStream::new());
        }
        conn.inner.send_stream(self.stream).set_priority(priority)?;
        Ok(())
    }

    /// Get the priority of the send stream
    pub fn priority(&self) -> Result<i32, ClosedStream> {
        let mut conn = self.conn.state.lock();
        if self.is_0rtt && conn.check_0rtt().is_err() {
            return Err(ClosedStream::new());
        }
        conn.inner.send_stream(self.stream).priority()
    }

    /// Completes when the stream is reset or the peer acknowledges all sent data
    ///
    /// Yields `Some` with the stop error code if the peer stops the stream. Yields `None` if the
    /// local side [`finish()`](Self::finish)es the stream and then the peer acknowledges receipt
    /// of all stream data (although not necessarily the processing of it), after which the peer
    /// closing the stream is no longer meaningful. A local reset returns
    /// [`StoppedError::LocallyReset`], even after its RESET_STREAM is acknowledged.
    ///
    /// For a variety of reasons, the peer may not send acknowledgements immediately upon receiving
    /// data. As such, relying on `stopped` to know when the peer has read a stream to completion
    /// may introduce more latency than using an application-level response of some sort.
    ///
    /// # Cancellation
    ///
    /// The future owns its registration and does not borrow this stream handle.
    /// Dropping this future releases its notification registration without
    /// cancelling other waiters or changing the stream's state.
    pub fn stopped(
        &self,
    ) -> impl Future<Output = Result<Option<VarInt>, StoppedError>> + Send + Sync + 'static + use<>
    {
        let conn = self.conn.clone();
        let stream = self.stream;
        let is_0rtt = self.is_0rtt;
        let events = self.events().clone();
        async move {
            {
                let mut state = conn.state.lock();
                if let Some(output) = send_stream_stopped(&mut state, stream, is_0rtt, &events) {
                    return output;
                }
                let registered = state
                    .stopped
                    .entry(stream)
                    .or_insert_with(|| StoppedNotify {
                        events: events.clone(),
                        waiters: 0,
                    });
                registered.waiters += 1;
            }
            let registration = StoppedRegistration {
                conn,
                stream,
                events,
            };
            loop {
                // Register before checking state, so an event between that check
                // and awaiting the notification cannot be lost.
                let mut notified = pin!(registration.events.notify.notified());
                notified.as_mut().enable();
                {
                    let mut state = registration.conn.state.lock();
                    if let Some(output) =
                        send_stream_stopped(&mut state, stream, is_0rtt, &registration.events)
                    {
                        return output;
                    }
                }
                notified.await;
            }
        }
    }

    /// Get the identity of this stream
    pub fn id(&self) -> StreamId {
        self.stream
    }

    /// Attempt to write bytes from buf into the stream.
    ///
    /// On success, returns Poll::Ready(Ok(num_bytes_written)).
    ///
    /// If the stream is not ready for writing, the method returns Poll::Pending and arranges
    /// for the current task (via cx.waker().wake_by_ref()) to receive a notification when the
    /// stream becomes writable or is closed.
    pub fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context,
        buf: &[u8],
    ) -> Poll<Result<usize, WriteError>> {
        pin!(self.get_mut().write(buf)).as_mut().poll(cx)
    }
}

/// How many bytes a write admitted.
trait WrittenBytes {
    fn bytes(&self) -> usize;
}

impl WrittenBytes for usize {
    fn bytes(&self) -> usize {
        *self
    }
}

impl WrittenBytes for Written {
    fn bytes(&self) -> usize {
        self.bytes
    }
}

/// Registered observers of one send stream. The connection-state lock protects
/// the waiter count, including cancellation on other threads.
pub(crate) struct StoppedNotify {
    pub(crate) events: Arc<SendStreamEvents>,
    waiters: usize,
}

/// Notification and terminal outcome share one lazily allocated owner. A reset
/// result must survive protocol-state reclamation until the last observer drops.
#[derive(Debug)]
pub(crate) struct SendStreamEvents {
    local_reset: AtomicU64,
    peer_stop: AtomicU64,
    pub(crate) notify: Notify,
}

/// One independently cancellable waiter. Removing the last waiter releases its
/// registry entry even if a locally reset stream never produces a peer event.
struct StoppedRegistration {
    conn: ConnectionRef,
    stream: StreamId,
    events: Arc<SendStreamEvents>,
}

impl Drop for StoppedRegistration {
    fn drop(&mut self) {
        let mut state = self.conn.state.lock();
        if let std::collections::hash_map::Entry::Occupied(mut entry) =
            state.stopped.entry(self.stream)
            && Arc::ptr_eq(&entry.get().events, &self.events)
        {
            entry.get_mut().waiters -= 1;
            if entry.get().waiters == 0 {
                entry.remove();
            }
        }
    }
}

/// Check if a send stream is stopped.
///
/// Returns `Some` if the stream is stopped or the connection is closed.
/// Returns `None` if the stream is not stopped.
#[expect(
    clippy::expect_used,
    reason = "terminal outcomes store a validated VarInt plus one; subtraction restores its bounds"
)]
fn send_stream_stopped(
    conn: &mut State,
    stream: StreamId,
    is_0rtt: bool,
    events: &SendStreamEvents,
) -> Option<Result<Option<VarInt>, StoppedError>> {
    if is_0rtt && conn.check_0rtt().is_err() {
        return Some(Err(StoppedError::ZeroRttRejected));
    }
    if let Some(code) = events.local_reset.load(Ordering::Relaxed).checked_sub(1) {
        return Some(Err(StoppedError::LocallyReset(
            VarInt::from_u64(code).expect("stored local reset code is a QUIC varint"),
        )));
    }
    if let Some(code) = events.peer_stop.load(Ordering::Relaxed).checked_sub(1) {
        return Some(Ok(Some(
            VarInt::from_u64(code).expect("stored peer stop code is a QUIC varint"),
        )));
    }
    match conn.inner.send_stream(stream).stopped() {
        Err(ClosedStream { .. }) => Some(Ok(None)),
        Ok(Some(error_code)) => Some(Ok(Some(error_code))),
        Ok(None) => conn.error.clone().map(|error| Err(error.into())),
    }
}

impl tokio::io::AsyncWrite for SendStream {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        self.poll_write(cx, buf).map_err(Into::into)
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context) -> Poll<io::Result<()>> {
        Poll::Ready(self.get_mut().finish().map_err(Into::into))
    }
}

impl Drop for SendStream {
    fn drop(&mut self) {
        let mut conn = self.conn.state.lock();

        // Rejected early streams share their numeric IDs with new 1-RTT streams. Their
        // handles must not touch the replacement stream, including its registered waker.
        if self.is_0rtt && conn.check_0rtt().is_err() {
            return;
        }
        conn.blocked_writers.remove(&self.stream);
        if conn.error.is_some() {
            return;
        }
        match conn.inner.send_stream(self.stream).finish() {
            Ok(()) => conn.wake(),
            Err(FinishError::Stopped(reason)) => {
                if let Some(events) = self.events.get() {
                    events
                        .peer_stop
                        .store(reason.into_inner() + 1, Ordering::Relaxed);
                    events.notify.notify_waiters();
                }
                if conn.inner.send_stream(self.stream).reset(reason).is_ok() {
                    conn.wake();
                }
            }
            // Already finished or reset, which is fine.
            Err(FinishError::ClosedStream) => {}
        }
    }
}

/// Errors that arise from writing to a stream
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WriteError {
    /// The peer is no longer accepting data on this stream
    ///
    /// Carries an application-defined error code.
    Stopped(VarInt),
    /// The connection was lost
    ConnectionLost(ConnectionError),
    /// The stream has already been finished or reset
    ClosedStream,
    /// This was a 0-RTT stream and the server rejected it
    ///
    /// Can only occur on clients for 0-RTT streams, which can be opened using
    /// [`Connecting::into_0rtt()`].
    ///
    /// [`Connecting::into_0rtt()`]: crate::driver::Connecting::into_0rtt()
    ZeroRttRejected,
}

impl core::fmt::Display for WriteError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::Stopped(field0) => write!(f, "sending stopped by peer: error {field0}"),
            Self::ConnectionLost(_) => f.write_str("connection lost"),
            Self::ClosedStream => f.write_str("closed stream"),
            Self::ZeroRttRejected => f.write_str("0-RTT rejected"),
        }
    }
}

impl std::error::Error for WriteError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::ConnectionLost(inner) => Some(inner),
            _ => None,
        }
    }
}

impl From<ConnectionError> for WriteError {
    fn from(value: ConnectionError) -> Self {
        Self::ConnectionLost(value)
    }
}

impl From<ClosedStream> for WriteError {
    #[inline]
    fn from(_: ClosedStream) -> Self {
        Self::ClosedStream
    }
}

impl From<StoppedError> for WriteError {
    fn from(x: StoppedError) -> Self {
        match x {
            StoppedError::ConnectionLost(e) => Self::ConnectionLost(e),
            StoppedError::ZeroRttRejected => Self::ZeroRttRejected,
            StoppedError::LocallyReset(_) => Self::ClosedStream,
        }
    }
}

impl From<WriteError> for io::Error {
    fn from(x: WriteError) -> Self {
        let kind = match x {
            WriteError::Stopped(_) | WriteError::ZeroRttRejected => io::ErrorKind::ConnectionReset,
            WriteError::ConnectionLost(_) | WriteError::ClosedStream => io::ErrorKind::NotConnected,
        };
        Self::new(kind, x)
    }
}

/// Errors that arise while waiting for a send stream to complete.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StoppedError {
    /// The local application reset the stream before delivery was acknowledged.
    LocallyReset(VarInt),
    /// The connection was lost
    ConnectionLost(ConnectionError),
    /// This was a 0-RTT stream and the server rejected it
    ///
    /// Can only occur on clients for 0-RTT streams, which can be opened using
    /// [`Connecting::into_0rtt()`].
    ///
    /// [`Connecting::into_0rtt()`]: crate::driver::Connecting::into_0rtt()
    ZeroRttRejected,
}

impl core::fmt::Display for StoppedError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::ConnectionLost(_) => f.write_str("connection lost"),
            Self::LocallyReset(code) => write!(f, "stream locally reset: {code}"),
            Self::ZeroRttRejected => f.write_str("0-RTT rejected"),
        }
    }
}

impl std::error::Error for StoppedError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::ConnectionLost(inner) => Some(inner),
            Self::ZeroRttRejected | Self::LocallyReset(_) => None,
        }
    }
}

impl From<ConnectionError> for StoppedError {
    fn from(value: ConnectionError) -> Self {
        Self::ConnectionLost(value)
    }
}

#[cfg(all(
    test,
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )
))]
mod tests {
    use super::*;
    use crate::driver::Duration;

    #[tokio::test]
    async fn cancelled_stop_waiters_release_registration_after_local_resets() {
        tokio::time::timeout(Duration::from_secs(10), async {
            let endpoint = crate::driver::tests::endpoint();
            let (client, server) = tokio::join!(
                endpoint
                    .connect(endpoint.local_addr().unwrap(), "localhost")
                    .unwrap(),
                async { endpoint.accept().await.unwrap().await },
            );
            let (client, _server) = (client.unwrap(), server.unwrap());
            for iteration in 0..64 {
                let mut send = client.open_uni().await.unwrap();
                let mut first = Box::pin(send.stopped());
                let mut second = Box::pin(send.stopped());
                let mut cx = Context::from_waker(std::task::Waker::noop());
                assert!(first.as_mut().poll(&mut cx).is_pending());
                assert!(second.as_mut().poll(&mut cx).is_pending());
                assert_eq!(send.conn.state.lock().stopped.len(), 1);
                if iteration % 2 == 0 {
                    drop(first);
                    assert_eq!(send.conn.state.lock().stopped.len(), 1);
                    drop(second);
                } else {
                    let barrier = std::sync::Barrier::new(2);
                    std::thread::scope(|scope| {
                        scope.spawn(|| {
                            barrier.wait();
                            drop(first);
                        });
                        scope.spawn(|| {
                            barrier.wait();
                            drop(second);
                        });
                    });
                }
                assert!(send.conn.state.lock().stopped.is_empty());

                // Cancelling every waiter leaves the live stream unchanged; a
                // subsequent caller can register again independently.
                let mut stopped = Box::pin(send.stopped());
                assert!(stopped.as_mut().poll(&mut cx).is_pending());
                assert_eq!(send.conn.state.lock().stopped.len(), 1);

                // Model both an application body failing and cancellation by an
                // independent owner. Neither path produces StreamEvent::Finished.
                if iteration % 2 == 0 {
                    send.reset(0u32).unwrap();
                } else {
                    send.handle().abort(0u32);
                }
                drop(stopped);
                assert!(send.conn.state.lock().stopped.is_empty());
            }
            client.close(0u32, b"done");
            endpoint.shutdown().await;
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn local_resets_wake_all_observers_and_never_report_delivery() {
        tokio::time::timeout(Duration::from_secs(10), async {
            let endpoint = crate::driver::tests::endpoint();
            let (client, server) = tokio::join!(
                endpoint
                    .connect(endpoint.local_addr().unwrap(), "localhost")
                    .unwrap(),
                async { endpoint.accept().await.unwrap().await },
            );
            let (client, _server) = (client.unwrap(), server.unwrap());
            for use_handle in [false, true] {
                let mut send = client.open_uni().await.unwrap();
                let reset = send.handle();
                let first = tokio::spawn(send.stopped());
                let second = tokio::spawn(send.stopped());
                // Ensure both tasks have registered before cancelling.
                while send
                    .conn
                    .state
                    .lock()
                    .stopped
                    .get(&send.stream)
                    .is_none_or(|entry| entry.waiters != 2)
                {
                    tokio::task::yield_now().await;
                }
                let code = VarInt::MAX;
                if use_handle {
                    reset.abort(code);
                } else {
                    send.reset(code).unwrap();
                }
                for waiter in [first, second] {
                    assert_eq!(waiter.await.unwrap(), Err(StoppedError::LocallyReset(code)));
                }
                assert!(send.conn.state.lock().stopped.is_empty());
                // Late observers and surviving stream handles retain only this
                // stream's result, including after the send owner goes away.
                let late = send.stopped();
                drop(send);
                assert_eq!(late.await, Err(StoppedError::LocallyReset(code)));
                drop(reset);
            }
            client.close(0u32, b"done");
            endpoint.shutdown().await;
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn dropping_peer_stopped_sender_preserves_reason_for_late_observer() {
        tokio::time::timeout(Duration::from_secs(10), async {
            let endpoint = crate::driver::tests::endpoint();
            let (client, server) = tokio::join!(
                endpoint
                    .connect(endpoint.local_addr().unwrap(), "localhost")
                    .unwrap(),
                async { endpoint.accept().await.unwrap().await },
            );
            let (client, server) = (client.unwrap(), server.unwrap());
            let mut send = client.open_uni().await.unwrap();
            let late = send.stopped();
            send.write_all(b"payload").await.unwrap();
            let mut recv = server.accept_uni().await.unwrap();
            let code = VarInt::from_u32(42);
            recv.stop(code).unwrap();
            assert_eq!(send.stopped().await.unwrap(), Some(code));
            let conn = send.conn.clone();
            let stream = send.stream;
            drop(send);
            // Once RESET_STREAM is acknowledged the protocol forgets this
            // stream. The independently owned observer must retain its reason.
            while conn
                .state
                .lock()
                .inner
                .send_stream(stream)
                .stopped()
                .is_ok()
            {
                tokio::task::yield_now().await;
            }
            assert_eq!(late.await.unwrap(), Some(code));
            client.close(0u32, b"done");
            endpoint.shutdown().await;
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn reset_before_observation_never_reports_delivery() {
        tokio::time::timeout(Duration::from_secs(10), async {
            let endpoint = crate::driver::tests::endpoint();
            let (client, server) = tokio::join!(
                endpoint
                    .connect(endpoint.local_addr().unwrap(), "localhost")
                    .unwrap(),
                async { endpoint.accept().await.unwrap().await },
            );
            let (client, _server) = (client.unwrap(), server.unwrap());
            let mut send = client.open_uni().await.unwrap();
            send.reset(0u32).unwrap();
            assert!(
                send.events.get().is_none(),
                "an unobserved reset needs no allocation"
            );
            assert_eq!(
                send.stopped().await,
                Err(StoppedError::LocallyReset(VarInt::from_u32(0)))
            );
            client.close(0u32, b"done");
            endpoint.shutdown().await;
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn cancelling_one_stop_waiter_preserves_other_waiters_wakeup() {
        tokio::time::timeout(Duration::from_secs(10), async {
            let endpoint = crate::driver::tests::endpoint();
            let (client, server) = tokio::join!(
                endpoint
                    .connect(endpoint.local_addr().unwrap(), "localhost")
                    .unwrap(),
                async { endpoint.accept().await.unwrap().await },
            );
            let (client, server) = (client.unwrap(), server.unwrap());
            let mut send = client.open_uni().await.unwrap();
            let mut cancelled = Box::pin(send.stopped());
            let mut first = Box::pin(send.stopped());
            let mut second = Box::pin(send.stopped());
            let mut cx = Context::from_waker(std::task::Waker::noop());
            assert!(cancelled.as_mut().poll(&mut cx).is_pending());
            assert!(first.as_mut().poll(&mut cx).is_pending());
            assert!(second.as_mut().poll(&mut cx).is_pending());
            drop(cancelled);
            assert_eq!(send.conn.state.lock().stopped.len(), 1);

            send.write_all(b"payload").await.unwrap();
            let mut recv = server.accept_uni().await.unwrap();
            recv.stop(42u32).unwrap();
            let (first, second) = tokio::join!(first, second);
            assert_eq!(first.unwrap(), Some(42u32.into()));
            assert_eq!(second.unwrap(), Some(42u32.into()));
            assert!(send.conn.state.lock().stopped.is_empty());
            client.close(0u32, b"done");
            endpoint.shutdown().await;
        })
        .await
        .unwrap();
    }
}

impl From<StoppedError> for io::Error {
    fn from(x: StoppedError) -> Self {
        let kind = match x {
            StoppedError::ZeroRttRejected | StoppedError::LocallyReset(_) => {
                io::ErrorKind::ConnectionReset
            }
            StoppedError::ConnectionLost(_) => io::ErrorKind::NotConnected,
        };
        Self::new(kind, x)
    }
}
