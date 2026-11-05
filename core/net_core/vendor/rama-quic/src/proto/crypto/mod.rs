//! Traits and implementations for the QUIC cryptography protocol
//!
//! The protocol logic is contained in types that abstract over the actual
//! cryptographic protocol used. This module contains the traits used for this
//! abstraction layer, with built-in adapters for Rustls and BoringSSL.
//!
//! Note that usage of any protocol (version) other than TLS 1.3 does not conform to any
//! published versions of the specification, and will not be supported in QUIC v1.

use std::{fmt, future::Future, pin::Pin, str, sync::Arc, task::Context};

use rama_core::{bytes::Bytes, error::BoxError};
use rama_quic_proto::{
    ConnectionId, Side, TransportError, Version,
    crypto::{CryptoError, HeaderKey, PacketKey},
    packet::SpaceId,
    transport_parameters::TransportParameters,
};
use rama_tls::client::ClientHello;
pub use rama_tls::client::NegotiatedTlsParameters;

use crate::proto::ConnectError;

pub(crate) mod config;

#[cfg(feature = "boring")]
pub(crate) mod boring;

/// Cryptography interface based on *ring*
#[cfg(any(feature = "aws-lc", feature = "ring"))]
pub(crate) mod ring_like;
/// TLS interface based on rustls
#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
pub(crate) mod rustls;

/// A cryptographic session (commonly TLS)
pub trait Session: Send + Sync + 'static {
    /// Create the initial set of keys for `version` given the client's initial destination
    /// ConnectionId.
    ///
    /// `version` is the version of the connection, or the version compatible version
    /// negotiation (RFC 9368) is moving it to; the salt and labels follow it (RFC 9369 §3.3).
    fn initial_keys(
        &self,
        version: Version,
        dst_cid: &ConnectionId,
        side: Side,
    ) -> Result<Keys, TransportError>;

    /// Move the session to a compatible `version` before any Handshake or 1-RTT key is
    /// derived (RFC 9368 §2.3, RFC 9369 §4.1).
    ///
    /// Called at most once, before the handshake keys are drained, and only for sessions of a
    /// [`ClientConfig`] that [supports switching](ClientConfig::supports_version_switch). A
    /// provider that derives its own packet keys from TLS secrets can re-label them for a
    /// compatible version; one that receives finished keys returns [`UnsupportedVersion`].
    fn switch_version(&mut self, version: Version) -> Result<(), UnsupportedVersion>;

    /// What the handshake has settled, when the session has it. `None` until the connection
    /// emits `HandshakeDataReady`.
    fn handshake_summary(&self) -> Option<NegotiatedTlsParameters>;

    /// Borrow negotiated ALPN bytes for diagnostics without allocating a handshake summary.
    fn negotiated_alpn(&self) -> Option<&[u8]>;

    /// The negotiated key exchange group as an IANA `NamedGroup` code (test observation point)
    #[cfg(test)]
    fn negotiated_key_exchange_group(&self) -> Option<u16>;

    /// Get the 0-RTT keys if available (clients only)
    ///
    /// On the client side, this method can be used to see if 0-RTT key material is available
    /// to start sending data before the protocol handshake has completed.
    ///
    /// Returns `None` if the key material is not available. This might happen if you have
    /// not connected to this server before.
    fn early_crypto(&self) -> Option<(Box<dyn HeaderKey>, Box<dyn PacketKey>)>;

    /// If the 0-RTT-encrypted data has been accepted by the peer
    fn early_data_accepted(&self) -> Option<bool>;

    /// Returns `true` until the connection is fully established.
    fn is_handshaking(&self) -> bool;

    /// Read bytes of handshake data
    ///
    /// This should be called with the contents of `CRYPTO` frames. If it returns `Ok`, the
    /// caller should call `poll_handshake()` to check if the crypto protocol has anything
    /// to send to the peer. This method will only return `true` the first time that
    /// handshake data is available. Future calls will always return false.
    ///
    /// On success, returns `true` when `handshake_summary()` first becomes available.
    fn read_handshake(&mut self, level: SpaceId, buf: &[u8]) -> Result<bool, TransportError>;

    /// Resume asynchronous TLS callback work, such as certificate selection a relay
    /// answers later, under `cx`'s waker.
    ///
    /// `None` when no callback is waiting; otherwise whether `handshake_summary()` first
    /// became available, as for `read_handshake`. The caller then drains `poll_handshake()`
    /// without waiting for a peer packet. With nothing waiting it only remembers the waker.
    fn poll_pending_callbacks(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Result<Option<bool>, TransportError>;

    /// Drop pending asynchronous TLS callback work for good: the connection closed, though
    /// it may keep this session while it drains. Repeated calls are harmless.
    fn cancel_pending_callbacks(&mut self);

    /// The peer's QUIC transport parameters
    ///
    /// These are only available after the first flight from the peer has been received.
    fn transport_parameters(&self) -> Result<Option<TransportParameters>, TransportError>;

    /// Drain ordered handshake output and directional key changes.
    fn poll_handshake(&mut self) -> Result<Option<HandshakeEvent>, TransportError>;

    /// Compute keys for the next key update
    fn next_1rtt_keys(&mut self) -> Result<Option<KeyPair<Box<dyn PacketKey>>>, TransportError>;

    /// Verify the integrity of a retry packet
    fn is_valid_retry(&self, orig_dst_cid: &ConnectionId, header: &[u8], payload: &[u8]) -> bool;

    /// Fill `output` with `output.len()` bytes of keying material derived
    /// from the [Session]'s secrets, using `label` and `context` for domain
    /// separation.
    ///
    /// This function will fail, returning [ExportKeyingMaterialError],
    /// if the requested output length is too large.
    fn export_keying_material(
        &self,
        output: &mut [u8],
        label: &[u8],
        context: &[u8],
    ) -> Result<(), ExportKeyingMaterialError>;
}

/// A pair of keys for bidirectional communication
pub struct KeyPair<T> {
    /// Key for encrypting data
    pub local: T,
    /// Key for decrypting data
    pub remote: T,
}

/// Packet and header protection for one direction.
pub struct DirectionalKeys {
    pub header: Box<dyn HeaderKey>,
    pub packet: Box<dyn PacketKey>,
}

/// Write keys become available before read keys on a TLS server.
pub struct Keys {
    pub local: DirectionalKeys,
    pub remote: Option<DirectionalKeys>,
}

/// Ordered TLS output and packet-key installation events.
pub enum HandshakeEvent {
    /// Handshake bytes to send at this encryption level before subsequent events.
    Data(SpaceId, Vec<u8>),
    /// Install write keys and any already available read keys for this level.
    Keys(SpaceId, Keys),
    /// Install read keys that became available after the write keys.
    ReadKeys(SpaceId, DirectionalKeys),
}

/// Client-side configuration for the crypto protocol
pub trait ClientConfig: Send + Sync {
    /// Start a client session with this configuration
    fn start_session(
        self: Arc<Self>,
        version: Version,
        server_name: &str,
        params: &TransportParameters,
    ) -> Result<Box<dyn Session>, ConnectError>;

    /// Whether every session from this configuration can [switch](Session::switch_version) to
    /// a compatible version during the handshake. Decides at configuration time whether a
    /// version policy that needs a switch is usable.
    fn supports_version_switch(&self) -> bool;

    /// The version of the newest session ticket held for `server_name`, if the provider can
    /// tell without consuming it.
    ///
    /// A ticket resumes only a connection in the version that issued it (RFC 9369 §5), so a
    /// client that wants to resume starts in that version.
    fn resumable_version(&self, server_name: &str) -> Option<Version>;
}

/// What a server needs before any session starts: the keys of a client's Initial packets and
/// the integrity tags of Retry packets.
pub trait InitialServerConfig: Send + Sync {
    /// Create the initial set of keys given the client's initial destination ConnectionId
    fn initial_keys(
        &self,
        version: Version,
        dst_cid: &ConnectionId,
    ) -> Result<Keys, InitialKeysError>;

    /// Generate the integrity tag for a retry packet
    ///
    /// Never called if `initial_keys` rejected `version`.
    fn retry_tag(
        &self,
        version: Version,
        orig_dst_cid: &ConnectionId,
        packet: &[u8],
    ) -> Result<[u8; 16], CryptoError>;
}

/// Server-side configuration for the crypto protocol: every session starts from it.
pub trait ServerConfig: InitialServerConfig {
    /// Start a server session with this configuration
    ///
    /// Never called if `initial_keys` rejected `version`.
    fn start_session(
        self: Arc<Self>,
        version: Version,
        params: &TransportParameters,
    ) -> Result<Box<dyn Session>, TransportError>;

    /// Whether [`Self::start_negotiated_session`] can start sessions.
    fn supports_compatible_negotiation(&self) -> bool;

    /// Start a server session for a connection the server moves from the client's `original`
    /// version to the compatible `negotiated` version (RFC 9368 §2.3).
    ///
    /// Handshake and 1-RTT keys follow `negotiated`; 0-RTT keys, if the session accepts early
    /// data at all, follow `original`, which is the only version the client sends 0-RTT in
    /// (RFC 9369 §4.1). Never called with equal versions, nor when
    /// [`Self::supports_compatible_negotiation`] is `false`.
    fn start_negotiated_session(
        self: Arc<Self>,
        original: Version,
        negotiated: Version,
        params: &TransportParameters,
    ) -> Result<Box<dyn Session>, TransportError>;
}

/// Server-side configuration resolved per connection from its ClientHello, for instance to
/// issue a certificate for the requested server name.
///
/// A connection is accepted only once its whole ClientHello arrived and resolved: awaiting
/// the `Incoming` does both. A ClientHello larger than 16 KiB is refused, and until the
/// connection is accepted nothing is acknowledged, so the resolution time adds to the
/// client's first round-trip sample.
pub trait ServerConfigResolver: InitialServerConfig {
    /// Look up the configuration a connection's session starts from, given its ClientHello.
    ///
    /// The lookup must stay cheap and hand back real work, such as issuing a certificate, as
    /// [`ServerConfigResolution::Pending`]:
    /// [`Incoming::accept_or_retry`](crate::Incoming::accept_or_retry), which
    /// [`Endpoint::serve`](crate::Endpoint::serve) uses, drops that work unpolled to first
    /// validate an unproven client address with a Retry (RFC 9000 §8.1.2).
    /// A failure refuses the connection.
    fn resolve(self: Arc<Self>, client_hello: ClientHelloMessage) -> ServerConfigLookup;
}

/// The lookup a [`ServerConfigResolver`] runs for a ClientHello.
pub type ServerConfigLookup =
    Pin<Box<dyn Future<Output = Result<ServerConfigResolution, BoxError>> + Send>>;

/// What a [`ServerConfigResolver`] looked up for a ClientHello.
pub enum ServerConfigResolution {
    /// At hand, such as a configuration with a cached certificate it holds.
    Ready(Arc<dyn ServerConfig>),
    /// Still to resolve with real work, such as issuing a certificate, which starts once
    /// polled: the endpoint may drop it unpolled to validate the client's address first.
    Pending(PendingServerConfig),
}

impl fmt::Debug for ServerConfigResolution {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Ready(_) => f.write_str("ServerConfigResolution::Ready"),
            Self::Pending(_) => f.write_str("ServerConfigResolution::Pending"),
        }
    }
}

/// The work that resolves a server configuration; see [`ServerConfigResolution::Pending`].
pub type PendingServerConfig =
    Pin<Box<dyn Future<Output = Result<Arc<dyn ServerConfig>, BoxError>> + Send>>;

/// A client's ClientHello as its first flight carried it.
///
/// QUIC carries the bare TLS handshake message, without a record layer (RFC 9001 §4).
#[derive(Clone)]
pub struct ClientHelloMessage {
    message: Bytes,
    client_hello: ClientHello,
}

impl ClientHelloMessage {
    /// A ClientHello `message`, from its type byte to the end of its body, and what it says.
    ///
    /// Useful to exercise [`ServerConfigResolver::resolve`]; the endpoint only hands out
    /// consistent pairs.
    #[must_use]
    pub fn new(message: Bytes, client_hello: ClientHello) -> Self {
        Self {
            message,
            client_hello,
        }
    }

    /// The handshake message, from its type byte to the end of its body.
    #[must_use]
    pub fn message(&self) -> &[u8] {
        &self.message
    }

    /// What the ClientHello says.
    #[must_use]
    pub fn client_hello(&self) -> &ClientHello {
        &self.client_hello
    }

    /// Take what the ClientHello says.
    #[must_use]
    pub fn into_client_hello(self) -> ClientHello {
        self.client_hello
    }
}

impl fmt::Debug for ClientHelloMessage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ClientHelloMessage")
            .field("len", &self.message.len())
            .field("client_hello", &self.client_hello)
            .finish()
    }
}

rama_utils::macros::error::static_str_error! {
    #[doc = "failed to export keying material"]
    ///
    /// The requested output length exceeds the exporter's limit.
    pub struct ExportKeyingMaterialError;
}

/// A pseudo random key for HKDF
pub trait HandshakeTokenKey: Send + Sync {
    /// Derive AEAD using hkdf
    ///
    /// Fails when the provider cannot expand or load the derived key.
    fn aead_from_hkdf(&self, random_bytes: &[u8]) -> Result<Box<dyn AeadKey>, CryptoError>;
}

/// A key for sealing data with AEAD-based algorithms
pub trait AeadKey {
    /// Method for sealing message `data`
    fn seal(&self, data: &mut Vec<u8>, additional_data: &[u8]) -> Result<(), CryptoError>;
    /// Method for opening a sealed message `data`
    fn open<'a>(
        &self,
        data: &'a mut [u8],
        additional_data: &[u8],
    ) -> Result<&'a mut [u8], CryptoError>;
}

/// Error indicating that the specified QUIC version is not supported
#[derive(Debug)]
pub struct UnsupportedVersion;

#[derive(Debug)]
pub enum InitialKeysError {
    UnsupportedVersion,
    Crypto(rama_core::error::BoxError),
}

impl From<UnsupportedVersion> for InitialKeysError {
    fn from(_: UnsupportedVersion) -> Self {
        Self::UnsupportedVersion
    }
}

impl From<UnsupportedVersion> for ConnectError {
    fn from(_: UnsupportedVersion) -> Self {
        Self::UnsupportedVersion
    }
}
