//! Deterministic QUIC v1 protocol engine.
//!
//! This module contains the protocol state machines only: no sockets, no timers and no clock.
//! The async driver feeds it received datagrams and the current time and transmits what it
//! produces, which keeps the engine fully testable with the simulator in `tests`.
//!
//! `Endpoint` represents the protocol state for a single socket: it manages configuration and
//! dispatches incoming datagrams to the related `Connection`. `Connection` holds the bulk of the
//! per-connection logic and state (streams, recovery, congestion control, migration).

#![cfg_attr(test, allow(dead_code))]
#![expect(clippy::too_many_arguments)]

use std::{net::SocketAddr, num::NonZeroUsize};

use rama_quic_proto::{EcnCodepoint, Version};

mod admission;
pub use admission::AdmissionConfig;
pub(crate) use admission::{Admission, AdmissionLease, Decision, Refusal, SourceKey};
pub(crate) mod cid_queue;
#[cfg(test)]
#[cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
mod tests;
pub(crate) mod transport_parameters;

mod observation;

mod bloom_token_log;
pub use bloom_token_log::BloomTokenLog;

mod connection;
#[cfg(feature = "test-utils")]
pub(crate) use connection::benchmarks;
#[cfg(test)]
pub(crate) use connection::qlog::ConnectionQlog;

/// Names the crate's own tests reach for through this module.
#[cfg(test)]
pub(crate) use crate::proto::connection::RecvStream;
pub use crate::proto::connection::{
    Chunk, ClosedStream, ConnectionError, ConnectionStats, FrameStats, GatedDatagramStats,
    PathStats, UdpStats, Written,
};
pub(crate) use crate::proto::connection::{
    Chunks, Connection, Event, FinishError, ReadError, ReadableError, SendDatagramError,
    SendStream, StreamEvent, WriteError,
};
#[cfg(all(
    test,
    any(
        feature = "boring",
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    )
))]
pub(crate) use crate::proto::connection::{Datagrams, StreamResourceUsage, Streams};
#[cfg(all(
    test,
    any(
        feature = "boring",
        any(
            feature = "boring",
            all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
        )
    )
))]
pub(crate) use crate::proto::endpoint::AcceptError;

mod config;
#[cfg(any(feature = "aws-lc", feature = "ring", feature = "boring"))]
pub use config::AddressTokenKey;
pub(crate) use config::ServerCrypto;
pub use config::{
    AckFrequencyConfig, ClientConfig, ConfigError, CongestionControl, EndpointConfig, IdleTimeout,
    KEY_MATERIAL_SIZE, MIN_INITIAL_CONGESTION_WINDOW, MtuDiscoveryConfig, PreferredAddressPolicy,
    ReceiveQueueLimits, ServerConfig, StatelessResetKey, StdSystemTime, TimeSource,
    TransportConfig, ValidationTokenConfig,
};

pub(crate) mod crypto;

/// Whether a datagram carrying a particular connection ID may go to a particular address.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SendPermit {
    /// It may go now.
    Sendable,
    /// The endpoint has not yet confirmed the route a stateless reset for it would arrive by.
    /// The datagram is kept, exactly as it is, until the confirmation lands.
    AwaitingInstallation,
    /// The identifier may never be sent again: retired, or bound to another path. Only the part
    /// of the datagram that has not already left is dropped.
    Obsolete,
}

mod endpoint;
pub use crate::proto::endpoint::{ConnectError, RetryRefused};
mod first_flight;
pub(crate) use first_flight::ClientHelloPeek;

pub use crate::proto::crypto::{ExportKeyingMaterialError, NegotiatedTlsParameters};
pub(crate) use crate::proto::endpoint::{
    ConnectionHandle, DatagramEvent, Endpoint, Incoming, RetryError,
};

mod shared;
pub(crate) use crate::proto::shared::{ConnectionEvent, EndpointEvent};

pub(crate) mod congestion;

pub(crate) mod cid_generator;
pub use crate::proto::cid_generator::{
    ConnectionIdGenerator, ConnectionIdGeneratorFactory, HashedConnectionIdGenerator,
    RandomConnectionIdGenerator,
};

mod token;
// Only the backend-gated endpoint lifecycle tests reach for this through `proto::`; matching their
// cfg keeps it from being an unused import in a backend-less test build.
#[cfg(all(
    test,
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )
))]
pub(crate) use token::reset_token;
pub use token::{NoneTokenLog, NoneTokenStore, StoredToken, TokenLog, TokenReuseError, TokenStore};

mod token_memory_cache;
pub(crate) use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub use token_memory_cache::TokenMemoryCache;

#[cfg(fuzzing)]
pub(crate) mod fuzzing {
    pub use super::observation::fuzzing::observe_sequence;
    #[cfg(any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    ))]
    pub use crate::proto::connection::{datagram_sequence, token_sequence};

    pub use crate::proto::admission::fuzz_admission;
    pub use rama_core::bytes::{BufMut, Bytes, BytesMut};
    use rama_quic_proto::{
        TransportError,
        frame::{Frame, Iter},
    };

    pub use crate::proto::connection::{
        Retransmits, SendStream, State as ConnectionState, Streams, StreamsState,
    };

    /// Decode `payload` as the frames of one received packet, up to its end or the first
    /// frame it rejects, walking every ACK range as loss detection would. Answers how many
    /// frames it decoded.
    pub fn decode_frames(payload: Bytes) -> Result<usize, TransportError> {
        let mut decoded = 0;
        for frame in Iter::new(payload)? {
            if let Frame::Ack(ack) = frame? {
                // Ranges are decoded lazily from bytes `Iter` only scanned: each must sit strictly
                // below the one before it.
                let mut floor = None;
                for range in ack.iter() {
                    assert!(range.start() <= range.end());
                    assert!(floor.is_none_or(|floor| *range.end() < floor));
                    floor = Some(*range.start());
                }
            }
            decoded += 1;
        }
        Ok(decoded)
    }

    #[cfg(feature = "fuzz-utils")]
    use arbitrary::{Arbitrary, Result, Unstructured};

    #[derive(Debug)]
    pub struct PacketParams {
        pub local_cid_len: usize,
        pub buf: BytesMut,
        pub grease_quic_bit: bool,
    }

    #[cfg(feature = "fuzz-utils")]
    impl<'arbitrary> Arbitrary<'arbitrary> for PacketParams {
        fn arbitrary(u: &mut Unstructured<'arbitrary>) -> Result<Self> {
            let local_cid_len: usize = u.int_in_range(0..=rama_quic_proto::MAX_CID_SIZE)?;
            let bytes: Vec<u8> = Vec::arbitrary(u)?;
            let mut buf = BytesMut::new();
            buf.put_slice(&bytes[..]);
            Ok(Self {
                local_cid_len,
                buf,
                grease_quic_bit: bool::arbitrary(u)?,
            })
        }
    }
}

/// The QUIC protocol versions accepted by default: version 1 and version 2.
///
/// Draft versions remain decodable for explicit test fixtures but are not offered as
/// product support.
pub(crate) const DEFAULT_SUPPORTED_VERSIONS: &[Version] = &[Version::V1, Version::V2];

/// Pre-standard draft versions 29 through 34, kept only for explicit tests.
#[cfg(test)]
pub(crate) const DRAFT_VERSIONS: &[Version] = &[
    Version::from_u32(0xff00_001d),
    Version::from_u32(0xff00_001e),
    Version::from_u32(0xff00_001f),
    Version::from_u32(0xff00_0020),
    Version::from_u32(0xff00_0021),
    Version::from_u32(0xff00_0022),
];

#[derive(Debug)]
#[must_use]
pub(crate) struct Transmit {
    /// The socket this datagram should be sent to
    pub(crate) destination: SocketAddr,
    /// Explicit congestion notification bits to set on the packet
    pub(crate) ecn: Option<EcnCodepoint>,
    /// Amount of data written to the caller-supplied buffer
    pub(crate) size: usize,
    /// The segment size if this transmission contains multiple datagrams.
    /// This is `None` if the transmit only contains a single datagram
    pub(crate) segment_size: Option<NonZeroUsize>,
    /// The local socket address this datagram belongs to (ip and port): the socket that received
    /// the path's packets, when the endpoint knows it. The driver sends from that socket and
    /// selects the source ip when it is specified.
    pub(crate) local: Option<SocketAddr>,
    /// Sequence number of the peer's connection ID this datagram carries, when it carries one.
    /// The sender asks whether that identifier may still be sent and reports the datagram once
    /// it is gone, which is what makes the identifier one this connection has used.
    pub(crate) cid_used: Option<u64>,
}

// Useful internal constants

/// The maximum number of CIDs we bother to issue per connection
const LOC_CID_COUNT: u64 = 8;
pub(crate) const MIN_INITIAL_SIZE: u16 = 1200;
/// <https://www.rfc-editor.org/rfc/rfc9000.html#name-datagram-size>
pub(crate) const INITIAL_MTU: u16 = 1200;
const MAX_UDP_PAYLOAD: u16 = 65527;
const TIMER_GRANULARITY: Duration = Duration::from_millis(1);
