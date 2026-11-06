//! Asynchronous QUIC driver.
//!
//! [QUIC](https://en.wikipedia.org/wiki/QUIC) is a modern transport protocol addressing
//! shortcomings of TCP, such as head-of-line blocking, poor security, slow handshakes, and
//! inefficient congestion control. This module drives the deterministic engine in `proto` with
//! real sockets, timers and tasks.
//!
//! The entry point of this module is the [`Endpoint`].
//!
//! # About QUIC
//!
//! A QUIC connection is an association between two endpoints. The endpoint which initiates the
//! connection is termed the client, and the endpoint which accepts it is termed the server. A
//! single endpoint may function as both client and server for different connections, for example
//! in a peer-to-peer application. To communicate application data, each endpoint may open streams
//! up to a limit dictated by its peer. Typically, that limit is increased as old streams are
//! finished.
//!
//! Streams may be unidirectional or bidirectional, and are cheap to create and disposable. For
//! example, a traditionally datagram-oriented application could use a new stream for every
//! message it wants to send, no longer needing to worry about MTUs. Bidirectional streams behave
//! much like a traditional TCP connection, and are useful for sending messages that have an
//! immediate response, such as an HTTP request. Stream data is delivered reliably, and there is no
//! ordering enforced between data on different streams.
//!
//! By avoiding head-of-line blocking and providing unified congestion control across all streams
//! of a connection, QUIC is able to provide higher throughput and lower latency than one or
//! multiple TCP connections between the same two hosts, while providing more useful behavior than
//! raw UDP sockets.
//!
//! Unreliable datagrams are also exposed; they are a low-level primitive preferred when
//! automatic fragmentation and retransmission of certain data is not desired.
//!
//! QUIC uses encryption and identity verification built directly on TLS 1.3. Just as with a TLS
//! server, it is useful for a QUIC server to be identified by a certificate signed by a trusted
//! authority. If this is infeasible--for example, if servers are short-lived or not associated
//! with a domain name--then as with TLS, self-signed certificates can be used to provide
//! encryption alone.

mod connection;
mod endpoint;
mod gate;
mod incoming;
mod lifecycle;
pub(crate) mod queue;
mod recv_stream;
mod send_stream;
mod sockets;
mod timer;
mod udp;
mod work_limiter;

pub(crate) use std::time::{Duration, Instant};

pub use crate::driver::{
    connection::{
        AcceptBi, AcceptUni, BiStreamReservation, CloseLease, Connecting, Connection,
        DatagramSendReady, DriverStats, OpenBi, OpenUni, QuicConnectionInfo, ReadDatagram,
        SendDatagram, SendDatagramError, ZeroRttAccepted,
    },
    endpoint::{
        Accept, DEFAULT_SHUTDOWN_BUDGET, DEFAULT_SOCKET_BUFFER_SIZE, Endpoint, EndpointBuilder,
        EndpointStats,
        ceiling::{MIN_UDP_PAYLOAD, SocketCapacityError},
    },
    incoming::{Incoming, IncomingFuture, IncomingOutcome, RetryError},
    lifecycle::ShutdownOutcome,
    queue::PacketQueueStats,
    recv_stream::{ReadError, ReadExactError, ReadToEndError, RecvStream, ResetError},
    send_stream::{SendStream, StoppedError, StreamHandle, WriteError},
};
pub(crate) use crate::proto::EndpointConfig;
/// Names the driver's own tests reach for through this module.
#[cfg(all(
    test,
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )
))]
pub(crate) use crate::proto::{ClientConfig, ConnectionError, ServerConfig, TransportConfig};

#[cfg(test)]
mod tests;

/// One received datagram queued for a connection driver, holding its budget charge.
///
/// Packets are the only queued messages between drivers; control is applied directly
/// (see `connection::EndpointLink`), so this queue can be bounded without losing control.
#[derive(Debug)]
pub(crate) struct QueuedPacket {
    event: crate::proto::ConnectionEvent,
    _permit: queue::PacketPermit,
}

/// The driver's clock: Tokio's, so paused test time and deadlines stay consistent, converted at
/// the deterministic engine boundary which takes `std::time::Instant`.
pub(crate) fn now() -> Instant {
    tokio::time::Instant::now().into_std()
}

/// Maximum number of datagrams processed in send/recv calls to make before moving on to other processing
///
/// This helps ensure we don't starve anything when the CPU is slower than the link.
/// Value is selected by picking a low number which didn't degrade throughput in benchmarks.
const IO_LOOP_BOUND: usize = 160;

/// The maximum amount of time that should be spent in `recvmsg()` calls per endpoint iteration
///
/// 50us are chosen so that an endpoint iteration with a 50us sendmsg limit blocks
/// the runtime for a maximum of about 100us.
/// Going much lower does not yield any noticeable difference, since a single `recvmmsg`
/// batch of size 32 was observed to take 30us on some systems.
const RECV_TIME_BOUND: Duration = Duration::from_micros(50);
