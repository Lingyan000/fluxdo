//! QUIC transport for Rama: version 1 (RFC 9000) and version 2 (RFC 9369), with RFC 9368
//! version negotiation between them.
//!
//! The deterministic protocol engine lives in the private `proto` module and
//! the asynchronous connection driver in `driver`; only Rama-owned types are
//! part of this crate's public API.
//!
//! UDP I/O is provided by [`rama_udp`]; TLS 1.3 comes from the common
//! [`rama_tls`] configuration converted through `rama-tls-rustls` or `rama-tls-boring`.
//! Custom TLS implementations can use [`tls::provider`].
//!
//! # Rama
//!
//! Crate used by the end-user `rama` crate and `rama` crate authors alike.
//!
//! Learn more about `rama`:
//!
//! - Github: <https://github.com/plabayo/rama>
//! - Book: <https://ramaproxy.org/book/>

#![doc(
    html_favicon_url = "https://raw.githubusercontent.com/plabayo/rama/main/docs/img/rama_logo.svg"
)]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/plabayo/rama/main/docs/img/rama_logo.svg"
)]
#![cfg_attr(docsrs, feature(doc_cfg))]

#[cfg(feature = "test-utils")]
#[doc(hidden)]
pub mod benchmarks;
pub mod client;
#[cfg(feature = "test-utils")]
#[doc(hidden)]
pub mod test_utils;

#[cfg(all(
    test,
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )
))]
mod test_helpers;

#[cfg(feature = "dial9")]
#[cfg_attr(docsrs, doc(cfg(feature = "dial9")))]
pub mod dial9;
pub mod profile;
mod proto;
pub mod proxy;
pub mod qlog;
#[cfg(feature = "opentelemetry")]
pub mod telemetry;

// Engine types that are part of the public transport API. The runtime facade
// (endpoints, connections, streams) is Rama-owned and lives in `driver`.
#[cfg(any(feature = "aws-lc", feature = "ring", feature = "boring"))]
pub use proto::AddressTokenKey;
pub use proto::{
    AckFrequencyConfig, AdmissionConfig, BloomTokenLog, Chunk, ClientConfig, ClosedStream,
    ConfigError, CongestionControl, ConnectError, ConnectionError, ConnectionIdGenerator,
    ConnectionIdGeneratorFactory, ConnectionStats, EndpointConfig, ExportKeyingMaterialError,
    FrameStats, GatedDatagramStats, HashedConnectionIdGenerator, IdleTimeout, KEY_MATERIAL_SIZE,
    MIN_INITIAL_CONGESTION_WINDOW, MtuDiscoveryConfig, NegotiatedTlsParameters, NoneTokenLog,
    NoneTokenStore, PathStats, PreferredAddressPolicy, RandomConnectionIdGenerator,
    ReceiveQueueLimits, RetryRefused, ServerConfig, StatelessResetKey, StdSystemTime, StoredToken,
    TimeSource, TokenLog, TokenMemoryCache, TokenReuseError, TokenStore, TransportConfig, UdpStats,
    ValidationTokenConfig, Written,
};

/// TLS for QUIC: how a connection's identity and application protocol are configured.
///
/// The configuration itself is the common Rama TLS client and server configuration; this module
/// carries only what QUIC adds to it. Inject a configuration provider explicitly,
/// or use the convenience constructors to select the feature-default provider.
pub mod tls {
    mod cache;
    pub use cache::ClientConfigCache;

    mod factory;
    pub use factory::*;

    /// Interfaces for supplying a QUIC TLS 1.3 implementation.
    ///
    /// Implement [`provider::ClientConfig`] and [`provider::ServerConfig`] and pass them to
    /// [`crate::ClientConfig::new`] and [`crate::ServerConfig::new`]; a
    /// [`provider::ServerConfigResolver`] that resolves the server configuration per
    /// ClientHello goes to [`crate::ServerConfig::new_resolving`]. The server constructors also
    /// take a custom address-token key, so no built-in crypto feature is required.
    /// A provider encodes local [`rama_quic_proto::transport_parameters::TransportParameters`]
    /// into its TLS extension and decodes its peer's extension with that type's `read`.
    ///
    /// Sessions must preserve the order of [`provider::HandshakeEvent`] values, distinguish read
    /// and write keys, and report TLS failures through Rama's transport error types.
    pub mod provider {
        pub use crate::proto::crypto::{
            AeadKey, ClientConfig, ClientHelloMessage, DirectionalKeys, ExportKeyingMaterialError,
            HandshakeEvent, HandshakeTokenKey, InitialKeysError, InitialServerConfig, KeyPair,
            Keys, PendingServerConfig, ServerConfig, ServerConfigLookup, ServerConfigResolution,
            ServerConfigResolver, Session, UnsupportedVersion,
        };
    }

    pub use crate::proto::crypto::config::{
        ClientHandshake, ClientSessionPolicy, NoInitialCipherSuite, TlsConfigError, TlsOptions,
    };
}

mod driver;

// The runtime: endpoints, connections, streams and the errors they report. Rama owns these
// types; the engine that drives them and the TLS provider behind them stay private.
pub use driver::{
    Accept, AcceptBi, AcceptUni, BiStreamReservation, CloseLease, Connecting, Connection,
    DEFAULT_SHUTDOWN_BUDGET, DEFAULT_SOCKET_BUFFER_SIZE, DatagramSendReady, DriverStats, Endpoint,
    EndpointBuilder, EndpointStats, Incoming, IncomingFuture, IncomingOutcome, MIN_UDP_PAYLOAD,
    OpenBi, OpenUni, PacketQueueStats, QuicConnectionInfo, ReadDatagram, ReadError, ReadExactError,
    ReadToEndError, RecvStream, ResetError, RetryError, SendDatagram, SendDatagramError,
    SendStream, ShutdownOutcome, SocketCapacityError, StoppedError, StreamHandle, WriteError,
    ZeroRttAccepted,
};

#[cfg(fuzzing)]
pub mod fuzzing {
    //! Byte-oriented entry points for the workspace fuzz targets.
    pub use crate::proto::fuzzing::*;
}
