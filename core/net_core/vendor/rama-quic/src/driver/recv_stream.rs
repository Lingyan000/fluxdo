use std::{
    future::{Future, poll_fn},
    io,
    pin::Pin,
    task::{Context, Poll, ready},
};

use rama_core::bytes::Bytes;
use rama_quic_proto::{StreamId, VarInt};
use tokio::io::ReadBuf;

use crate::{
    driver::{connection::ConnectionRef, gate::GateStack},
    proto::{
        Chunk, Chunks, ClosedStream, ConnectionError, ReadError as ProtoReadError, ReadableError,
    },
};

/// A stream that can only be used to receive data
///
/// `stop(0)` is implicitly called on drop unless:
/// - A variant of [`ReadError`] has been yielded by a read call
/// - [`stop()`] was called explicitly
///
/// # Cancellation
///
/// A `read` method is said to be *cancel-safe* when dropping its future before the future becomes
/// ready cannot lead to loss of stream data. This is true of methods which succeed immediately when
/// any progress is made, and is not true of methods which might need to perform multiple reads
/// internally before succeeding. Each `read` method documents whether it is cancel-safe.
///
/// # Common issues
///
/// ## Data never received on a locally-opened stream
///
/// Peers are not notified of streams until they or a later-numbered stream are used to send
/// data. If a bidirectional stream is locally opened but never used to send, then the peer may
/// never see it. Application protocols should always arrange for the endpoint which will first
/// transmit on a stream to be the endpoint responsible for opening it.
///
/// ## Data never received on a remotely-opened stream
///
/// Verify that the stream you are receiving is the same one that the server is sending on, e.g. by
/// logging the [`id`] of each. Streams are always accepted in the same order as they are created,
/// i.e. ascending order by [`StreamId`]. For example, even if a sender first transmits on
/// bidirectional stream 1, the first stream yielded by [`Connection::accept_bi`] on the receiver
/// will be bidirectional stream 0.
///
/// [`ReadError`]: crate::driver::ReadError
/// [`stop()`]: RecvStream::stop
/// [`SendStream::finish`]: crate::driver::SendStream::finish
/// [`WriteError::Stopped`]: crate::driver::WriteError::Stopped
/// [`id`]: RecvStream::id
/// [`Connection::accept_bi`]: crate::driver::Connection::accept_bi
#[derive(Debug)]
pub struct RecvStream {
    conn: ConnectionRef,
    stream: StreamId,
    is_0rtt: bool,
    all_data_read: bool,
    reset: Option<VarInt>,
    gates: Option<GateStack>,
}

impl RecvStream {
    pub(crate) fn new(conn: ConnectionRef, stream: StreamId, is_0rtt: bool) -> Self {
        Self {
            conn,
            stream,
            is_0rtt,
            all_data_read: false,
            reset: None,
            gates: None,
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Pace reading with `gates`.
        pub(crate) fn gates(mut self, gates: Option<GateStack>) -> Self {
            self.gates = gates;
            self
        }
    }

    /// Read data contiguously from the stream.
    ///
    /// [Stream gates](crate::Connection::add_stream_gates) may admit less than is buffered.
    ///
    /// Yields the number of bytes read into `buf` on success, or `None` if the stream was finished.
    ///
    /// This operation is cancel-safe.
    pub async fn read(&mut self, buf: &mut [u8]) -> Result<Option<usize>, ReadError> {
        Read {
            stream: self,
            buf: ReadBuf::new(buf),
        }
        .await
    }

    /// Read an exact number of bytes contiguously from the stream.
    ///
    /// See [`read()`] for details. This operation is *not* cancel-safe.
    ///
    /// [`read()`]: RecvStream::read
    pub async fn read_exact(&mut self, buf: &mut [u8]) -> Result<(), ReadExactError> {
        ReadExact {
            stream: self,
            buf: ReadBuf::new(buf),
        }
        .await
    }

    /// Attempts to read from the stream into the provided buffer
    ///
    /// On success, returns `Poll::Ready(Ok(num_bytes_read))` and places data into `buf`. If this
    /// returns zero bytes read (and `buf` has a non-zero length), that indicates that the remote
    /// side has [`finish`]ed the stream and the local side has already read all bytes.
    ///
    /// If no data is available for reading, this returns `Poll::Pending` and arranges for the
    /// current task (via `cx.waker()`) to be notified when the stream becomes readable or is
    /// closed.
    ///
    /// [`finish`]: crate::driver::SendStream::finish
    pub fn poll_read(
        &mut self,
        cx: &mut Context,
        buf: &mut [u8],
    ) -> Poll<Result<usize, ReadError>> {
        let mut buf = ReadBuf::new(buf);
        ready!(self.poll_read_buf(cx, &mut buf))?;
        Poll::Ready(Ok(buf.filled().len()))
    }

    /// Attempts to read from the stream into the provided buffer, which may be uninitialized
    ///
    /// On success, returns `Poll::Ready(Ok(()))` and places data into the unfilled portion of
    /// `buf`. If this does not write any bytes to `buf` (and `buf.remaining()` is non-zero), that
    /// indicates that the remote side has [`finish`]ed the stream and the local side has already
    /// read all bytes.
    ///
    /// If no data is available for reading, this returns `Poll::Pending` and arranges for the
    /// current task (via `cx.waker()`) to be notified when the stream becomes readable or is
    /// closed.
    ///
    /// [`finish`]: crate::driver::SendStream::finish
    pub fn poll_read_buf(
        &mut self,
        cx: &mut Context,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<Result<(), ReadError>> {
        if buf.remaining() == 0 {
            return Poll::Ready(Ok(()));
        }

        let want = buf.remaining();
        self.poll_read_generic(cx, true, want, |chunks| {
            let mut read = false;
            loop {
                if buf.remaining() == 0 {
                    // We know `read` is `true` because `buf.remaining()` was not 0 before
                    return ReadStatus::Readable(());
                }

                match chunks.next(buf.remaining()) {
                    Ok(Some(chunk)) => {
                        buf.put_slice(&chunk.bytes);
                        read = true;
                    }
                    res => return (if read { Some(()) } else { None }, res.err()).into(),
                }
            }
        })
        .map(|res| res.map(|_| ()))
    }

    /// Read the next segment of data
    ///
    /// Yields `None` if the stream was finished. Otherwise, yields a segment of data and its
    /// offset in the stream. If `ordered` is `true`, the chunk's offset will be immediately after
    /// the last data yielded by `read()` or `read_chunk()`. If `ordered` is `false`, segments may
    /// be received in any order, and the `Chunk`'s `offset` field can be used to determine
    /// ordering in the caller. Unordered reads are less prone to head-of-line blocking within a
    /// stream, but require the application to manage reassembling the original data.
    ///
    /// Slightly more efficient than `read` due to not copying. Chunk boundaries do not correspond
    /// to peer writes, and hence cannot be used as framing.
    ///
    /// This operation is cancel-safe.
    pub async fn read_chunk(
        &mut self,
        max_length: usize,
        ordered: bool,
    ) -> Result<Option<Chunk>, ReadError> {
        ReadChunk {
            stream: self,
            max_length,
            ordered,
        }
        .await
    }

    /// Attempts to read a chunk from the stream.
    ///
    /// On success, returns `Poll::Ready(Ok(Some(chunk)))`. If `Poll::Ready(Ok(None))`
    /// is returned, it implies that EOF has been reached.
    ///
    /// If no data is available for reading, the method returns `Poll::Pending`
    /// and arranges for the current task (via cx.waker()) to receive a notification
    /// when the stream becomes readable or is closed.
    pub fn poll_read_chunk(
        &mut self,
        cx: &mut Context,
        max_length: usize,
        ordered: bool,
    ) -> Poll<Result<Option<Chunk>, ReadError>> {
        self.poll_read_generic(cx, ordered, max_length, |chunks| {
            match chunks.next(max_length) {
                Ok(Some(chunk)) => ReadStatus::Readable(chunk),
                res => (None, res.err()).into(),
            }
        })
    }

    /// Read the next segments of data
    ///
    /// Fills `bufs` with the segments of data beginning immediately after the
    /// last data yielded by `read` or `read_chunk`, or `None` if the stream was
    /// finished.
    ///
    /// Slightly more efficient than `read` due to not copying. Chunk boundaries
    /// do not correspond to peer writes, and hence cannot be used as framing.
    ///
    /// This operation is cancel-safe.
    pub async fn read_chunks(&mut self, bufs: &mut [Bytes]) -> Result<Option<usize>, ReadError> {
        ReadChunks { stream: self, bufs }.await
    }

    /// Polling equivalent of [`Self::read_chunks`], retaining zero-copy segments.
    pub fn poll_read_chunks(
        &mut self,
        cx: &mut Context,
        bufs: &mut [Bytes],
    ) -> Poll<Result<Option<usize>, ReadError>> {
        if bufs.is_empty() {
            return Poll::Ready(Ok(Some(0)));
        }

        self.poll_read_generic(cx, true, usize::MAX, |chunks| {
            let mut read = 0;
            loop {
                if read >= bufs.len() {
                    // We know `read > 0` because `bufs` cannot be empty here
                    return ReadStatus::Readable(read);
                }

                match chunks.next(usize::MAX) {
                    Ok(Some(chunk)) => {
                        bufs[read] = chunk.bytes;
                        read += 1;
                    }
                    res => return (if read == 0 { None } else { Some(read) }, res.err()).into(),
                }
            }
        })
    }

    /// Convenience method to read all remaining data into a buffer
    ///
    /// Fails with [`ReadToEndError::TooLong`] on reading more than `size_limit` bytes, discarding
    /// all data read. Uses unordered reads to be more efficient than using `AsyncRead` would
    /// allow. `size_limit` should be set to limit worst-case memory use.
    ///
    /// If unordered reads have already been made, the resulting buffer may have gaps containing
    /// arbitrary data.
    ///
    /// This operation is *not* cancel-safe.
    ///
    /// [`ReadToEndError::TooLong`]: crate::driver::ReadToEndError::TooLong
    pub async fn read_to_end(&mut self, size_limit: usize) -> Result<Vec<u8>, ReadToEndError> {
        ReadToEnd {
            stream: self,
            size_limit,
            read: Vec::new(),
            start: u64::MAX,
            end: 0,
        }
        .await
    }

    /// Stop accepting data
    ///
    /// Discards unread data and notifies the peer to stop transmitting. Once stopped, further
    /// attempts to operate on a stream will yield `ClosedStream` errors.
    pub fn stop(&mut self, error_code: impl Into<VarInt>) -> Result<(), ClosedStream> {
        let error_code = error_code.into();
        let mut conn = self.conn.state.lock();
        if self.is_0rtt && conn.check_0rtt().is_err() {
            return Ok(());
        }
        conn.inner.recv_stream(self.stream).stop(error_code)?;
        conn.wake();
        self.all_data_read = true;
        // Clean up shared state that might be left over from a cancalled read
        // operation, so `drop` doesn't have to
        conn.blocked_readers.remove(&self.stream);
        Ok(())
    }

    /// Check if this stream has been opened during 0-RTT.
    ///
    /// In which case any non-idempotent request should be considered dangerous at the application
    /// level. Because read data is subject to replay attacks.
    pub fn is_0rtt(&self) -> bool {
        self.is_0rtt
    }

    /// Get the identity of this stream
    pub fn id(&self) -> StreamId {
        self.stream
    }

    /// Completes when the stream has been reset by the peer or otherwise closed
    ///
    /// Yields `Some` with the reset error code when the stream is reset by the peer. Yields `None`
    /// when the stream was previously [`stop()`](Self::stop)ed, or when the stream was
    /// [`finish()`](crate::driver::SendStream::finish)ed by the peer and all data has been received, after
    /// which it is no longer meaningful for the stream to be reset.
    ///
    /// This operation is cancel-safe.
    pub async fn received_reset(&mut self) -> Result<Option<VarInt>, ResetError> {
        poll_fn(|cx| {
            let mut conn = self.conn.state.lock();
            if self.is_0rtt && conn.check_0rtt().is_err() {
                return Poll::Ready(Err(ResetError::ZeroRttRejected));
            }

            // A cancelled read or reset wait may have left its registration behind.
            conn.blocked_readers.remove(&self.stream);
            if let Some(code) = self.reset {
                return Poll::Ready(Ok(Some(code)));
            }

            match conn.inner.recv_stream(self.stream).received_reset() {
                Err(_) => Poll::Ready(Ok(None)),
                Ok(Some(error_code)) => {
                    // Stream state has just now been freed, so the connection may need to issue new
                    // stream ID flow control credit
                    conn.wake();
                    Poll::Ready(Ok(Some(error_code)))
                }
                Ok(None) => {
                    if let Some(e) = &conn.error {
                        return Poll::Ready(Err(e.clone().into()));
                    }
                    // Resets always notify readers, since a reset is an immediate read error. We
                    // could introduce a dedicated channel to reduce the risk of spurious wakeups,
                    // but that increased complexity is probably not justified, as an application
                    // that is expecting a reset is not likely to receive large amounts of data.
                    conn.blocked_readers.insert(self.stream, cx.waker().clone());
                    Poll::Pending
                }
            }
        })
        .await
    }

    /// Handle common logic related to reading out of a receive stream
    ///
    /// This takes an `FnMut` closure that takes care of the actual reading process, matching
    /// the detailed read semantics for the calling function with a particular return type.
    /// The closure can read from the passed `&mut BudgetedChunks` and has to return the status
    /// after reading: the amount of data read, and the status after the final read call.
    ///
    /// A gated stream reads (up to) `want` bytes only as its gates admit them.
    fn poll_read_generic<T, U>(
        &mut self,
        cx: &mut Context,
        ordered: bool,
        want: usize,
        mut read_fn: T,
    ) -> Poll<Result<Option<U>, ReadError>>
    where
        T: FnMut(&mut BudgetedChunks<'_, '_>) -> ReadStatus<U>,
    {
        if self.all_data_read {
            return Poll::Ready(Ok(None));
        }
        if want == 0 || self.gates.is_none() {
            return self
                .poll_read_pass(cx, ordered, usize::MAX, &mut read_fn)
                .poll;
        }
        // Only data waits for the gates: a pass that admits nothing reports the stream's end,
        // reset or failure at once and registers this task for its events. Data it held back
        // is read first, even past a lost connection, as an ungated stream reads it.
        let pass = self.poll_read_pass(cx, ordered, 0, &mut read_fn);
        if !pass.held_back {
            return pass.poll;
        }
        let Some(gates) = self.gates.as_mut() else {
            return pass.poll;
        };
        let admitted = ready!(gates.poll_admit(cx, want as u64));
        let budget = usize::try_from(admitted).unwrap_or(usize::MAX);
        let pass = self.poll_read_pass(cx, ordered, budget, &mut read_fn);
        if let Some(gates) = self.gates.as_mut() {
            gates.settle(pass.read as u64);
        }
        pass.poll
    }

    /// One read under the connection lock, of at most `budget` bytes.
    fn poll_read_pass<T, U>(
        &mut self,
        cx: &mut Context,
        ordered: bool,
        budget: usize,
        read_fn: &mut T,
    ) -> ReadPass<U>
    where
        T: FnMut(&mut BudgetedChunks<'_, '_>) -> ReadStatus<U>,
    {
        let mut read = 0;
        let mut held_back = false;
        let poll = self.poll_read_inner(cx, ordered, budget, read_fn, &mut read, &mut held_back);
        ReadPass {
            poll,
            read,
            held_back,
        }
    }

    fn poll_read_inner<T, U>(
        &mut self,
        cx: &mut Context,
        ordered: bool,
        budget: usize,
        read_fn: &mut T,
        read: &mut usize,
        held_back: &mut bool,
    ) -> Poll<Result<Option<U>, ReadError>>
    where
        T: FnMut(&mut BudgetedChunks<'_, '_>) -> ReadStatus<U>,
    {
        let mut conn = self.conn.state.lock();
        if self.is_0rtt {
            conn.check_0rtt().map_err(|()| ReadError::ZeroRttRejected)?;
        }

        // This poll replaces any registration left by a cancelled read or reset wait.
        conn.blocked_readers.remove(&self.stream);

        // If we stored an error during a previous call, return it now. This can happen if a
        // `read_fn` both wants to return data and also returns an error in its final stream status.
        let status = if let Some(code) = self.reset {
            ReadStatus::Failed(None, ProtoReadError::Reset(code))
        } else {
            let mut recv = conn.inner.recv_stream(self.stream);
            let mut chunks = recv.read(ordered)?;
            let mut budgeted = BudgetedChunks {
                chunks: &mut chunks,
                left: budget,
                held_back: false,
            };
            let status = read_fn(&mut budgeted);
            *read = budget - budgeted.left;
            *held_back = budgeted.held_back;
            if chunks.finalize().should_transmit() {
                conn.wake();
            }
            status
        };

        match status {
            ReadStatus::Readable(read) => Poll::Ready(Ok(Some(read))),
            ReadStatus::Finished(read) => {
                self.all_data_read = true;
                // Nothing will wake this stream again; a waker left from an earlier pass is stale.
                conn.blocked_readers.remove(&self.stream);
                Poll::Ready(Ok(read))
            }
            ReadStatus::Failed(read, ProtoReadError::Blocked) => {
                if let Some(val) = read {
                    Poll::Ready(Ok(Some(val)))
                } else {
                    if let Some(ref x) = conn.error {
                        return Poll::Ready(Err(ReadError::ConnectionLost(x.clone())));
                    }
                    conn.blocked_readers.insert(self.stream, cx.waker().clone());
                    Poll::Pending
                }
            }
            ReadStatus::Failed(read, ProtoReadError::Reset(error_code)) => match read {
                None => {
                    self.all_data_read = true;
                    self.reset = Some(error_code);
                    conn.blocked_readers.remove(&self.stream);
                    Poll::Ready(Err(ReadError::Reset(error_code)))
                }
                done => {
                    self.reset = Some(error_code);
                    Poll::Ready(Ok(done))
                }
            },
        }
    }
}

/// One read pass and what it left for the gates.
struct ReadPass<U> {
    poll: Poll<Result<Option<U>, ReadError>>,
    read: usize,
    /// Data is waiting that the pass had no budget for.
    held_back: bool,
}

/// The chunks of a stream, yielded within the budget its gates admitted.
struct BudgetedChunks<'a, 'b> {
    chunks: &'a mut Chunks<'b>,
    left: usize,
    held_back: bool,
}

impl BudgetedChunks<'_, '_> {
    /// Like [`Chunks::next`]; data past the budget reads as [`ProtoReadError::Blocked`], while
    /// what ends the stream passes.
    fn next(&mut self, max_length: usize) -> Result<Option<Chunk>, ProtoReadError> {
        if self.left == 0 {
            // An empty read looks without consuming.
            return match self.chunks.next(0) {
                Ok(Some(_)) => {
                    self.held_back = true;
                    Err(ProtoReadError::Blocked)
                }
                other => other,
            };
        }
        let chunk = self.chunks.next(max_length.min(self.left))?;
        if let Some(chunk) = &chunk {
            self.left -= chunk.bytes.len();
        }
        Ok(chunk)
    }
}

enum ReadStatus<T> {
    Readable(T),
    Finished(Option<T>),
    Failed(Option<T>, crate::proto::ReadError),
}

impl<T> From<(Option<T>, Option<crate::proto::ReadError>)> for ReadStatus<T> {
    fn from(status: (Option<T>, Option<crate::proto::ReadError>)) -> Self {
        match status {
            (read, None) => Self::Finished(read),
            (read, Some(e)) => Self::Failed(read, e),
        }
    }
}

/// Future produced by [`RecvStream::read_to_end()`].
///
/// [`RecvStream::read_to_end()`]: crate::driver::RecvStream::read_to_end
struct ReadToEnd<'a> {
    stream: &'a mut RecvStream,
    read: Vec<(Bytes, u64)>,
    start: u64,
    end: u64,
    size_limit: usize,
}

impl Future for ReadToEnd<'_> {
    type Output = Result<Vec<u8>, ReadToEndError>;
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context) -> Poll<Self::Output> {
        loop {
            if let Some(chunk) = ready!(self.stream.poll_read_chunk(cx, usize::MAX, false))? {
                self.start = self.start.min(chunk.offset);
                let end = chunk.bytes.len() as u64 + chunk.offset;
                self.end = self.end.max(end);
                if (self.end - self.start) > self.size_limit as u64 {
                    return Poll::Ready(Err(ReadToEndError::TooLong));
                }
                self.read.push((chunk.bytes, chunk.offset));
            } else {
                if self.end == 0 {
                    // Never received anything
                    return Poll::Ready(Ok(Vec::new()));
                }
                let start = self.start;
                let mut buffer = vec![0; (self.end - start) as usize];
                for (data, offset) in self.read.drain(..) {
                    let offset = (offset - start) as usize;
                    buffer[offset..offset + data.len()].copy_from_slice(&data);
                }
                return Poll::Ready(Ok(buffer));
            }
        }
    }
}

/// Errors from [`RecvStream::read_to_end`]
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReadToEndError {
    /// An error occurred during reading
    Read(ReadError),
    /// The stream is larger than the user-supplied limit
    TooLong,
}

impl core::fmt::Display for ReadToEndError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::Read(field0) => write!(f, "read error: {field0}"),
            Self::TooLong => f.write_str("stream too long"),
        }
    }
}

impl std::error::Error for ReadToEndError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Read(inner) => Some(inner),
            Self::TooLong => None,
        }
    }
}

impl From<ReadError> for ReadToEndError {
    fn from(value: ReadError) -> Self {
        Self::Read(value)
    }
}

impl tokio::io::AsyncRead for RecvStream {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        ready!(Self::poll_read_buf(self.get_mut(), cx, buf))?;
        Poll::Ready(Ok(()))
    }
}

impl Drop for RecvStream {
    fn drop(&mut self) {
        let mut conn = self.conn.state.lock();
        // A rejected early stream's ID may already belong to a new 1-RTT stream.
        if self.is_0rtt && conn.check_0rtt().is_err() {
            return;
        }
        if self.all_data_read {
            debug_assert!(
                !conn.blocked_readers.contains_key(&self.stream),
                "Stream {} should not have a blocked reader when all data read is true",
                self.stream
            );
            return;
        }
        conn.blocked_readers.remove(&self.stream);
        if conn.error.is_some() {
            return;
        }

        // Ignore ClosedStream errors
        let _stopped = conn.inner.recv_stream(self.stream).stop(0u32.into());
        conn.wake();
    }
}

/// Errors that arise from reading from a stream.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReadError {
    /// The peer abandoned transmitting data on this stream
    ///
    /// Carries an application-defined error code.
    Reset(VarInt),
    /// The connection was lost
    ConnectionLost(ConnectionError),
    /// The stream has already been stopped, finished, or reset
    ClosedStream,
    /// Attempted an ordered read following an unordered read
    ///
    /// Performing an unordered read allows discontinuities to arise in the receive buffer of a
    /// stream which cannot be recovered, making further ordered reads impossible.
    IllegalOrderedRead,
    /// This was a 0-RTT stream and the server rejected it
    ///
    /// Can only occur on clients for 0-RTT streams, which can be opened using
    /// [`Connecting::into_0rtt()`].
    ///
    /// [`Connecting::into_0rtt()`]: crate::driver::Connecting::into_0rtt()
    ZeroRttRejected,
}

impl core::fmt::Display for ReadError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::Reset(field0) => write!(f, "stream reset by peer: error {field0}"),
            Self::ConnectionLost(_) => f.write_str("connection lost"),
            Self::ClosedStream => f.write_str("closed stream"),
            Self::IllegalOrderedRead => f.write_str("ordered read after unordered read"),
            Self::ZeroRttRejected => f.write_str("0-RTT rejected"),
        }
    }
}

impl std::error::Error for ReadError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::ConnectionLost(inner) => Some(inner),
            _ => None,
        }
    }
}

impl From<ConnectionError> for ReadError {
    fn from(value: ConnectionError) -> Self {
        Self::ConnectionLost(value)
    }
}

impl From<ReadableError> for ReadError {
    fn from(e: ReadableError) -> Self {
        match e {
            ReadableError::ClosedStream => Self::ClosedStream,
            ReadableError::IllegalOrderedRead => Self::IllegalOrderedRead,
        }
    }
}

impl From<ResetError> for ReadError {
    fn from(e: ResetError) -> Self {
        match e {
            ResetError::ConnectionLost(e) => Self::ConnectionLost(e),
            ResetError::ZeroRttRejected => Self::ZeroRttRejected,
        }
    }
}

impl From<ReadError> for io::Error {
    fn from(x: ReadError) -> Self {
        let kind = match x {
            ReadError::Reset { .. } | ReadError::ZeroRttRejected => io::ErrorKind::ConnectionReset,
            ReadError::ConnectionLost(_) | ReadError::ClosedStream => io::ErrorKind::NotConnected,
            ReadError::IllegalOrderedRead => io::ErrorKind::InvalidInput,
        };
        Self::new(kind, x)
    }
}

/// Errors that arise while waiting for a stream to be reset
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResetError {
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

impl core::fmt::Display for ResetError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::ConnectionLost(_) => f.write_str("connection lost"),
            Self::ZeroRttRejected => f.write_str("0-RTT rejected"),
        }
    }
}

impl std::error::Error for ResetError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::ConnectionLost(inner) => Some(inner),
            Self::ZeroRttRejected => None,
        }
    }
}

impl From<ConnectionError> for ResetError {
    fn from(value: ConnectionError) -> Self {
        Self::ConnectionLost(value)
    }
}

impl From<ResetError> for io::Error {
    fn from(x: ResetError) -> Self {
        let kind = match x {
            ResetError::ZeroRttRejected => io::ErrorKind::ConnectionReset,
            ResetError::ConnectionLost(_) => io::ErrorKind::NotConnected,
        };
        Self::new(kind, x)
    }
}

/// Future produced by [`RecvStream::read()`].
///
/// [`RecvStream::read()`]: crate::driver::RecvStream::read
struct Read<'a> {
    stream: &'a mut RecvStream,
    buf: ReadBuf<'a>,
}

impl Future for Read<'_> {
    type Output = Result<Option<usize>, ReadError>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context) -> Poll<Self::Output> {
        let this = self.get_mut();
        ready!(this.stream.poll_read_buf(cx, &mut this.buf))?;
        match this.buf.filled().len() {
            0 if this.buf.capacity() != 0 => Poll::Ready(Ok(None)),
            n => Poll::Ready(Ok(Some(n))),
        }
    }
}

/// Future produced by [`RecvStream::read_exact()`].
///
/// [`RecvStream::read_exact()`]: crate::driver::RecvStream::read_exact
struct ReadExact<'a> {
    stream: &'a mut RecvStream,
    buf: ReadBuf<'a>,
}

impl Future for ReadExact<'_> {
    type Output = Result<(), ReadExactError>;
    fn poll(self: Pin<&mut Self>, cx: &mut Context) -> Poll<Self::Output> {
        let this = self.get_mut();
        let mut remaining = this.buf.remaining();
        while remaining > 0 {
            ready!(this.stream.poll_read_buf(cx, &mut this.buf))?;
            let new = this.buf.remaining();
            if new == remaining {
                return Poll::Ready(Err(ReadExactError::FinishedEarly(this.buf.filled().len())));
            }
            remaining = new;
        }
        Poll::Ready(Ok(()))
    }
}

/// Errors that arise from reading from a stream.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReadExactError {
    /// The stream finished before all bytes were read
    FinishedEarly(usize),
    /// A read error occurred
    ReadError(ReadError),
}

impl core::fmt::Display for ReadExactError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::FinishedEarly(field0) => write!(f, "stream finished early ({field0} bytes read)"),
            Self::ReadError(inner) => core::fmt::Display::fmt(inner, f),
        }
    }
}

impl std::error::Error for ReadExactError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::ReadError(inner) => Some(inner),
            Self::FinishedEarly(_) => None,
        }
    }
}

impl From<ReadError> for ReadExactError {
    fn from(value: ReadError) -> Self {
        Self::ReadError(value)
    }
}

/// Future produced by [`RecvStream::read_chunk()`].
///
/// [`RecvStream::read_chunk()`]: crate::driver::RecvStream::read_chunk
struct ReadChunk<'a> {
    stream: &'a mut RecvStream,
    max_length: usize,
    ordered: bool,
}

impl Future for ReadChunk<'_> {
    type Output = Result<Option<Chunk>, ReadError>;
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context) -> Poll<Self::Output> {
        let (max_length, ordered) = (self.max_length, self.ordered);
        self.stream.poll_read_chunk(cx, max_length, ordered)
    }
}

/// Future produced by [`RecvStream::read_chunks()`].
///
/// [`RecvStream::read_chunks()`]: crate::driver::RecvStream::read_chunks
struct ReadChunks<'a> {
    stream: &'a mut RecvStream,
    bufs: &'a mut [Bytes],
}

impl Future for ReadChunks<'_> {
    type Output = Result<Option<usize>, ReadError>;
    fn poll(self: Pin<&mut Self>, cx: &mut Context) -> Poll<Self::Output> {
        let this = self.get_mut();
        this.stream.poll_read_chunks(cx, this.bufs)
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
    async fn cancelled_reset_wait_does_not_leave_a_reader_after_eof() {
        tokio::time::timeout(Duration::from_secs(10), async {
            let endpoint = crate::driver::tests::endpoint();
            let (client, server) = tokio::join!(
                endpoint
                    .connect(endpoint.local_addr().unwrap(), "localhost")
                    .unwrap(),
                async { endpoint.accept().await.unwrap().await },
            );
            let (client, server) = (client.unwrap(), server.unwrap());
            let mut send = server.open_uni().await.unwrap();
            send.write_all(b"abcd").await.unwrap();
            send.finish().unwrap();
            let mut recv = client.accept_uni().await.unwrap();
            assert_eq!(send.stopped().await.unwrap(), None);

            let mut cx = Context::from_waker(std::task::Waker::noop());
            {
                let wait = std::pin::pin!(recv.received_reset());
                assert!(wait.poll(&mut cx).is_pending());
            }

            // The data and FIN are already buffered, so no driver event can clear the
            // cancelled wait's registration between the wait and this read.
            {
                let read = std::pin::pin!(recv.read_to_end(4));
                assert_eq!(read.poll(&mut cx), Poll::Ready(Ok(b"abcd".to_vec())));
            }
            assert!(
                !recv
                    .conn
                    .state
                    .lock()
                    .blocked_readers
                    .contains_key(&recv.stream)
            );
            drop(recv);
            endpoint.shutdown().await;
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn read_to_end_checks_previously_received_high_offsets() {
        tokio::time::timeout(Duration::from_secs(10), async {
            let endpoint = crate::driver::tests::endpoint();
            let (client, server) = tokio::join!(
                endpoint
                    .connect(endpoint.local_addr().unwrap(), "localhost")
                    .unwrap(),
                async { endpoint.accept().await.unwrap().await },
            );
            let (client, server) = (client.unwrap(), server.unwrap());
            let mut send = server.open_uni().await.unwrap();
            send.write_all(b"abcd").await.unwrap();
            send.finish().unwrap();
            let mut recv = client.accept_uni().await.unwrap();
            // Resume after an unordered read already consumed a higher-offset chunk.
            // The newly arriving lower offset must be checked against that prior end.
            let read = ReadToEnd {
                stream: &mut recv,
                read: vec![(Bytes::from_static(b"z"), 16)],
                start: 16,
                end: 17,
                size_limit: 8,
            };
            assert_eq!(read.await, Err(ReadToEndError::TooLong));
            client.close(0u32, b"done");
            endpoint.shutdown().await;
        })
        .await
        .unwrap();
    }
}
