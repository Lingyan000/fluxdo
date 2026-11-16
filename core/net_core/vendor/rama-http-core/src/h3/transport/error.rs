use rama_quic_proto::{ConnectionError, VarInt};

/// Why a stream write failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WriteError {
    /// The peer sent STOP_SENDING with this code.
    Stopped(VarInt),
    ConnectionLost(ConnectionError),
    /// Finished or reset already, or discarded with rejected 0-RTT.
    Closed,
}

/// Why a stream read failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReadError {
    /// The peer reset its send direction with this code.
    Reset(VarInt),
    ConnectionLost(ConnectionError),
    /// Stopped already, or discarded with rejected 0-RTT.
    Closed,
}

/// Why [`SendStream::stopped`](super::SendStream::stopped) ended without a peer code or full
/// acknowledgement.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StoppedError {
    /// This side reset the stream with this code.
    LocallyReset(VarInt),
    ConnectionLost(ConnectionError),
    /// The stream was opened in 0-RTT, which the server rejected.
    ZeroRttRejected,
}

/// Why a datagram was not queued.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SendDatagramError {
    /// Datagrams are off locally, or the peer does not accept them.
    Unavailable,
    TooLarge,
    /// The send buffer is full.
    Blocked,
    /// The stream's send side or the connection ended.
    Closed,
}

/// The stream was already finished, reset or stopped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClosedStream;
