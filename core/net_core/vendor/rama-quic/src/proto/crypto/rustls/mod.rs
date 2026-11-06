use std::{future::ready, io, str, sync::Arc, task::Context};

use ahash::HashMap;
use parking_lot::Mutex;
use rama_core::{
    bytes::BytesMut,
    conversion::RamaFrom as _,
    error::{BoxError, BoxErrorExt as _},
};
#[cfg(all(feature = "aws-lc", not(feature = "ring")))]
use rama_crypto::dep::aws_lc_rs::aead;
#[cfg(feature = "ring")]
use rama_crypto::dep::ring::aead;
use rama_net::{address::Domain, tls::ApplicationProtocol};
use rama_quic_proto::{
    ConnectionId, Side, TransportError, TransportErrorCode,
    crypto::{CryptoError, HeaderKey},
    packet::SpaceId,
    transport_parameters::TransportParameters,
};
use rama_tls::client::NegotiatedTlsAlgorithms;
#[cfg(all(test, feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
use rama_tls_rustls::dep::rustls::{
    client::danger::ServerCertVerifier,
    pki_types::{CertificateDer, PrivateKeyDer},
};
use rama_tls_rustls::{
    dep::rustls::{
        self, CipherSuite, HandshakeKind,
        pki_types::ServerName,
        quic::{Connection, HeaderProtectionKey, KeyChange, PacketKey, Secrets, Suite, Version},
    },
    server::RustlsDynamicConfig,
};

use crate::proto::{
    ConnectError,
    crypto::{
        self, DirectionalKeys, ExportKeyingMaterialError, HandshakeEvent, KeyPair, Keys,
        UnsupportedVersion,
    },
};

/// Convert a server name into the backend's own type, returning the name in the error when the
/// backend refuses it.
fn server_name_of(server_name: &str) -> Result<ServerName<'static>, ConnectError> {
    match ServerName::try_from(server_name) {
        Ok(name) => Ok(name.to_owned()),
        Err(_) => Err(ConnectError::InvalidServerName(server_name.into())),
    }
}

/// Convert the name the backend reports into a [`Domain`]. A name it accepts that `Domain` does
/// not is a disagreement between this crate and its backend, so it ends the connection locally
/// rather than being reported as an absent name.
fn received_server_name(name: &str) -> Result<Domain, TransportError> {
    Domain::try_from(name).map_err(|error| {
        TransportError::INTERNAL_ERROR("received server name is not a domain").with_cause(error)
    })
}

mod config;
#[cfg(test)]
pub(crate) use config::TlsOptions;
pub(crate) use config::server_config_from_rama;
use rama_net::tls::AlpnPolicy;

pub(crate) use super::config::NoInitialCipherSuite;

/// A rustls TLS session
pub(crate) struct TlsSession {
    alpn_policy: AlpnPolicy,
    /// Put the peer's certificate chain in the handshake summary.
    store_peer_chain: bool,
    version: Version,
    got_handshake_data: bool,
    /// The name the peer asked for, converted once when the backend first has it.
    server_name: Option<Domain>,
    next_secrets: Option<Secrets>,
    write_level: SpaceId,
    output: std::collections::VecDeque<HandshakeEvent>,
    inner: Connection,
    suite: Suite,
}

impl TlsSession {
    fn peer_certificates(&self) -> Option<Vec<rama_crypto::pki_types::CertificateDer<'static>>> {
        Some(
            self.inner
                .peer_certificates()?
                .iter()
                .map(|certificate| certificate.clone().into_owned())
                .collect(),
        )
    }

    fn collect_output(&mut self) {
        let mut bytes = Vec::new();
        let change = self.inner.write_hs(&mut bytes);
        if !bytes.is_empty() {
            self.output
                .push_back(HandshakeEvent::Data(self.write_level, bytes));
        }
        if let Some(change) = change {
            let (level, keys) = match change {
                KeyChange::Handshake { keys } => (SpaceId::Handshake, keys),
                KeyChange::OneRtt { keys, next } => {
                    self.next_secrets = Some(next);
                    (SpaceId::Data, keys)
                }
            };
            self.write_level = level;
            self.output.push_back(HandshakeEvent::Keys(
                level,
                Keys {
                    local: DirectionalKeys {
                        header: Box::new(RustlsHeaderKey(keys.local.header)),
                        packet: Box::new(RustlsPacketKey(keys.local.packet)),
                    },
                    remote: None,
                },
            ));
            self.output.push_back(HandshakeEvent::ReadKeys(
                level,
                DirectionalKeys {
                    header: Box::new(RustlsHeaderKey(keys.remote.header)),
                    packet: Box::new(RustlsPacketKey(keys.remote.packet)),
                },
            ));
        }
    }

    fn side(&self) -> Side {
        match self.inner {
            Connection::Client(_) => Side::Client,
            Connection::Server(_) => Side::Server,
        }
    }
}

impl crypto::Session for TlsSession {
    fn initial_keys(
        &self,
        version: rama_quic_proto::Version,
        dst_cid: &ConnectionId,
        side: Side,
    ) -> Result<Keys, TransportError> {
        let version = interpret_version(version)
            .map_err(|_error| TransportError::INTERNAL_ERROR("unsupported QUIC version"))?;
        Ok(initial_keys(version, *dst_cid, side, &self.suite))
    }

    fn switch_version(
        &mut self,
        _version: rama_quic_proto::Version,
    ) -> Result<(), crypto::UnsupportedVersion> {
        // rustls hands out finished packet keys, which cannot be re-labelled.
        Err(crypto::UnsupportedVersion)
    }

    #[cfg(test)]
    fn negotiated_key_exchange_group(&self) -> Option<u16> {
        self.inner
            .negotiated_key_exchange_group()
            .map(|group| u16::from(group.name()))
    }

    fn negotiated_alpn(&self) -> Option<&[u8]> {
        if self.got_handshake_data {
            self.inner.alpn_protocol()
        } else {
            None
        }
    }

    fn handshake_summary(&self) -> Option<rama_tls::client::NegotiatedTlsParameters> {
        if !self.got_handshake_data {
            return None;
        }
        Some(rama_tls::client::NegotiatedTlsParameters {
            protocol_version: rama_tls::ProtocolVersion::TLSv1_3,
            peer_certificate_chain: if self.store_peer_chain {
                self.peer_certificates()
            } else {
                None
            },
            // Read afresh: the protocol can still be settling when the name is already known.
            application_layer_protocol: self.inner.alpn_protocol().map(ApplicationProtocol::from),
            server_name: self.server_name.clone(),
            // The session's own answer, once it has one. A resumption is the whole handshake
            // having taken up a session, not a session having been looked up.
            resumed: self
                .inner
                .handshake_kind()
                .map(|kind| kind == HandshakeKind::Resumed),
            algorithms: NegotiatedTlsAlgorithms::rama_from(&*self.inner),
            server_hello: None,
        })
    }

    fn early_crypto(&self) -> Option<(Box<dyn HeaderKey>, Box<dyn crypto::PacketKey>)> {
        let keys = self.inner.zero_rtt_keys()?;
        Some((
            Box::new(RustlsHeaderKey(keys.header)),
            Box::new(RustlsPacketKey(keys.packet)),
        ))
    }

    fn early_data_accepted(&self) -> Option<bool> {
        match self.inner {
            Connection::Client(ref session) => Some(session.is_early_data_accepted()),
            Connection::Server(_) => None,
        }
    }

    fn is_handshaking(&self) -> bool {
        self.inner.is_handshaking()
    }

    // Rustls has no asynchronous callbacks to resume.
    fn poll_pending_callbacks(
        &mut self,
        _: &mut Context<'_>,
    ) -> Result<Option<bool>, TransportError> {
        Ok(None)
    }

    fn cancel_pending_callbacks(&mut self) {}

    fn read_handshake(&mut self, _level: SpaceId, buf: &[u8]) -> Result<bool, TransportError> {
        self.inner.read_hs(buf).map_err(|e| {
            if let Some(alert) = self.inner.alert() {
                TransportError::new(TransportErrorCode::crypto(alert.into()), e.to_string())
                    .with_cause(e)
            } else {
                TransportError::PROTOCOL_VIOLATION(format!("TLS error: {e}")).with_cause(e)
            }
        })?;
        // Drain each TLS transition before processing bytes from the next encryption level.
        self.collect_output();
        if !self.inner.is_handshaking()
            && self.alpn_policy == AlpnPolicy::Require
            && self.inner.alpn_protocol().is_none()
        {
            return Err(TransportError::new(
                TransportErrorCode::crypto(0x78),
                "TLS handshake completed without an application protocol",
            ));
        }
        if !self.got_handshake_data {
            // Hack around the lack of an explicit signal from rustls to reflect ClientHello being
            // ready on incoming connections, or ALPN negotiation completing on outgoing
            // connections.
            let have_server_name = match self.inner {
                Connection::Client(_) => false,
                Connection::Server(ref session) => session.server_name().is_some(),
            };
            if self.inner.alpn_protocol().is_some() || have_server_name || !self.is_handshaking() {
                if let Connection::Server(ref session) = self.inner
                    && let Some(name) = session.server_name()
                {
                    self.server_name = Some(received_server_name(name)?);
                }
                self.got_handshake_data = true;
                return Ok(true);
            }
        }
        Ok(false)
    }

    fn transport_parameters(&self) -> Result<Option<TransportParameters>, TransportError> {
        match self.inner.quic_transport_parameters() {
            None => Ok(None),
            Some(buf) => match TransportParameters::read(self.side(), &mut io::Cursor::new(buf)) {
                Ok(params) => Ok(Some(params)),
                Err(e) => Err(e.into()),
            },
        }
    }

    fn poll_handshake(&mut self) -> Result<Option<HandshakeEvent>, TransportError> {
        if let Some(event) = self.output.pop_front() {
            return Ok(Some(event));
        }
        self.collect_output();
        Ok(self.output.pop_front())
    }

    fn next_1rtt_keys(
        &mut self,
    ) -> Result<Option<KeyPair<Box<dyn crypto::PacketKey>>>, TransportError> {
        let Some(secrets) = self.next_secrets.as_mut() else {
            return Ok(None);
        };
        let keys = secrets.next_packet_keys();
        Ok(Some(KeyPair {
            local: Box::new(RustlsPacketKey(keys.local)),
            remote: Box::new(RustlsPacketKey(keys.remote)),
        }))
    }

    fn is_valid_retry(&self, orig_dst_cid: &ConnectionId, header: &[u8], payload: &[u8]) -> bool {
        let Some(tag_start) = payload.len().checked_sub(16) else {
            return false;
        };

        let mut pseudo_packet =
            Vec::with_capacity(header.len() + payload.len() + orig_dst_cid.len() + 1);
        pseudo_packet.push(orig_dst_cid.len() as u8);
        pseudo_packet.extend_from_slice(orig_dst_cid);
        pseudo_packet.extend_from_slice(header);
        let tag_start = tag_start + pseudo_packet.len();
        pseudo_packet.extend_from_slice(payload);

        let wire = retry_wire(self.version);
        let nonce = aead::Nonce::assume_unique_for_key(wire.retry_nonce);
        #[expect(
            clippy::unwrap_used,
            reason = "the Retry integrity keys are 16-byte constants"
        )]
        let key = aead::LessSafeKey::new(
            aead::UnboundKey::new(&aead::AES_128_GCM, &wire.retry_key).unwrap(),
        );

        let (aad, tag) = pseudo_packet.split_at_mut(tag_start);
        key.open_in_place(nonce, aead::Aad::from(aad), tag).is_ok()
    }

    fn export_keying_material(
        &self,
        output: &mut [u8],
        label: &[u8],
        context: &[u8],
    ) -> Result<(), ExportKeyingMaterialError> {
        // The backend fails this only for an output length it cannot serve, which is what
        // this error says.
        if self
            .inner
            .export_keying_material(output, label, Some(context))
            .is_err()
        {
            return Err(ExportKeyingMaterialError);
        }
        Ok(())
    }
}

/// Retry integrity constants for a rustls version; rustls derives the packet keys itself.
fn retry_wire(version: Version) -> &'static rama_quic_proto::version::Wire {
    #[expect(
        clippy::expect_used,
        reason = "`interpret_version` maps only versions with a wire image"
    )]
    match version {
        Version::V1 => rama_quic_proto::Version::V1.wire(),
        Version::V1Draft => rama_quic_proto::Version::from_u32(0xff00_001d).wire(),
        Version::V2 => rama_quic_proto::Version::V2.wire(),
        #[expect(
            clippy::unreachable,
            reason = "`interpret_version` only produces the three versions above; the wildcard exists because rustls marks `Version` non-exhaustive"
        )]
        _ => unreachable!(),
    }
    .expect("a version with a wire image")
}

/// Local wrappers so this crate can implement the `rama-quic-proto` key traits for the backend's
/// own key types; the orphan rule forbids implementing a foreign trait for a foreign type.
struct RustlsHeaderKey(Box<dyn HeaderProtectionKey>);
struct RustlsPacketKey(Box<dyn PacketKey>);

impl crypto::HeaderKey for RustlsHeaderKey {
    #[expect(
        clippy::unwrap_used,
        reason = "the sample has `sample_size()` bytes and the first byte plus at most four packet-number bytes are the only inputs rustls checks"
    )]
    fn decrypt(&self, pn_offset: usize, packet: &mut [u8]) {
        let (header, sample) = packet.split_at_mut(pn_offset + 4);
        let (first, rest) = header.split_at_mut(1);
        let pn_end = Ord::min(pn_offset + 3, rest.len());
        self.0
            .decrypt_in_place(
                &sample[..self.sample_size()],
                &mut first[0],
                &mut rest[pn_offset - 1..pn_end],
            )
            .unwrap();
    }

    #[expect(
        clippy::unwrap_used,
        reason = "the sample has `sample_size()` bytes and the first byte plus at most four packet-number bytes are the only inputs rustls checks"
    )]
    fn encrypt(&self, pn_offset: usize, packet: &mut [u8]) {
        let (header, sample) = packet.split_at_mut(pn_offset + 4);
        let (first, rest) = header.split_at_mut(1);
        let pn_end = Ord::min(pn_offset + 3, rest.len());
        self.0
            .encrypt_in_place(
                &sample[..self.sample_size()],
                &mut first[0],
                &mut rest[pn_offset - 1..pn_end],
            )
            .unwrap();
    }

    fn sample_size(&self) -> usize {
        self.0.sample_len()
    }
}

/// A QUIC-compatible TLS client configuration
///
/// A `QuicClientConfig` with reasonable defaults is constructed implicitly within
/// `ClientConfig::with_root_certificates()`.
/// Alternatively, `QuicClientConfig`'s [`TryFrom`] implementation can be used to wrap around a
/// custom [`rama_tls_rustls::dep::rustls::ClientConfig`], in which case care should be taken around certain points:
///
/// - If `enable_early_data` is not set to true, then sending 0-RTT data will not be possible on
///   outgoing connections.
/// - The [`rama_tls_rustls::dep::rustls::ClientConfig`] must have TLS 1.3 support enabled for conversion to succeed.
///
/// The object in the `resumption` field of the inner [`rama_tls_rustls::dep::rustls::ClientConfig`] determines whether
/// calling `into_0rtt` on outgoing connections returns `Ok` or `Err`. It typically allows
/// `into_0rtt` to proceed if it recognizes the server name, and defaults to an in-memory cache of
/// 256 server names.
///
pub(crate) struct QuicClientConfig {
    alpn_policy: AlpnPolicy,
    client_sessions: config::ClientSessionPolicy,
    store_peer_chain: bool,
    pub(crate) inner: Arc<rustls::ClientConfig>,
    /// `inner` per version other than v1, each with its own session cache: a ticket must not
    /// resume a connection in another version (RFC 9369 §5), and rustls gives no way to scope
    /// the configured store, so v1 keeps it and every other version gets a cache of its own.
    scoped: Mutex<HashMap<rama_quic_proto::Version, Arc<rustls::ClientConfig>>>,
    initial: Suite,
}

impl QuicClientConfig {
    fn config_for(&self, version: rama_quic_proto::Version) -> Arc<rustls::ClientConfig> {
        if version == rama_quic_proto::Version::V1
            || self.client_sessions == config::ClientSessionPolicy::Fresh
        {
            return self.inner.clone();
        }
        self.scoped
            .lock()
            .entry(version)
            .or_insert_with(|| {
                let mut config = (*self.inner).clone();
                config.resumption = rustls::client::Resumption::store(Arc::new(
                    rustls::client::ClientSessionMemoryCache::new(256),
                ));
                Arc::new(config)
            })
            .clone()
    }
}

impl QuicClientConfig {
    #[cfg(all(test, feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
    /// Initialize a sane QUIC-compatible TLS client configuration
    ///
    /// QUIC requires that TLS 1.3 be enabled. Advanced users can use any [`rama_tls_rustls::dep::rustls::ClientConfig`] that
    /// satisfies this requirement.
    #[expect(
        clippy::expect_used,
        reason = "`inner` is built on `configured_provider()`, whose ring and aws-lc defaults include TLS13_AES_128_GCM_SHA256"
    )]
    pub(crate) fn new(verifier: Arc<dyn ServerCertVerifier>) -> Self {
        let inner = Self::inner(verifier);
        Self {
            alpn_policy: AlpnPolicy::OutOfBandAgreement,
            store_peer_chain: false,
            client_sessions: config::ClientSessionPolicy::Reuse,
            // We're confident that the *ring* default provider contains TLS13_AES_128_GCM_SHA256
            initial: initial_suite_from_provider(inner.crypto_provider())
                .expect("no initial cipher suite found"),
            inner: Arc::new(inner),
            scoped: Mutex::new(HashMap::default()),
        }
    }

    /// Initialize a QUIC-compatible TLS client configuration with a separate initial cipher suite
    ///
    /// This is useful if you want to avoid the initial cipher suite for traffic encryption.
    pub(crate) fn with_initial(
        inner: Arc<rustls::ClientConfig>,
        initial: Suite,
    ) -> Result<Self, NoInitialCipherSuite> {
        match initial.suite.common.suite {
            CipherSuite::TLS13_AES_128_GCM_SHA256 => Ok(Self {
                inner,
                initial,
                alpn_policy: AlpnPolicy::OutOfBandAgreement,
                store_peer_chain: false,
                client_sessions: config::ClientSessionPolicy::Reuse,
                scoped: Mutex::new(HashMap::default()),
            }),
            _ => Err(NoInitialCipherSuite { specific: true }),
        }
    }

    #[cfg(all(test, feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
    pub(crate) fn inner(verifier: Arc<dyn ServerCertVerifier>) -> rustls::ClientConfig {
        #[expect(
            clippy::unwrap_used,
            reason = "the configured providers support TLS 1.3"
        )]
        let mut config = rustls::ClientConfig::builder_with_provider(configured_provider())
            .with_protocol_versions(&[&rustls::version::TLS13])
            .unwrap() // The default providers support TLS 1.3
            .dangerous()
            .with_custom_certificate_verifier(verifier)
            .with_no_client_auth();

        config.enable_early_data = true;
        config
    }
}

impl crypto::ClientConfig for QuicClientConfig {
    fn start_session(
        self: Arc<Self>,
        version: rama_quic_proto::Version,
        server_name: &str,
        params: &TransportParameters,
    ) -> Result<Box<dyn crypto::Session>, ConnectError> {
        let quic_version = version;
        let version = interpret_version(version)?;
        Ok(Box::new(TlsSession {
            alpn_policy: self.alpn_policy,
            store_peer_chain: self.store_peer_chain,
            version,
            got_handshake_data: false,
            server_name: None,
            next_secrets: None,
            write_level: SpaceId::Initial,
            output: Default::default(),
            inner: rustls::quic::Connection::Client(
                rustls::quic::ClientConnection::new(
                    self.config_for(quic_version),
                    version,
                    server_name_of(server_name)?,
                    to_vec(params),
                )
                .map_err(|error| ConnectError::Crypto(session_error(error)))?,
            ),
            suite: self.initial,
        }))
    }

    fn supports_version_switch(&self) -> bool {
        false
    }

    fn resumable_version(&self, _server_name: &str) -> Option<rama_quic_proto::Version> {
        // rustls keeps its tickets to itself; a resuming client starts in its default version.
        None
    }
}

impl TryFrom<rustls::ClientConfig> for QuicClientConfig {
    type Error = NoInitialCipherSuite;

    fn try_from(inner: rustls::ClientConfig) -> Result<Self, Self::Error> {
        Arc::new(inner).try_into()
    }
}

impl TryFrom<Arc<rustls::ClientConfig>> for QuicClientConfig {
    type Error = NoInitialCipherSuite;

    fn try_from(inner: Arc<rustls::ClientConfig>) -> Result<Self, Self::Error> {
        Ok(Self {
            alpn_policy: AlpnPolicy::OutOfBandAgreement,
            store_peer_chain: false,
            client_sessions: config::ClientSessionPolicy::Reuse,
            initial: initial_suite_from_provider(inner.crypto_provider())
                .ok_or(NoInitialCipherSuite { specific: false })?,
            inner,
            scoped: Mutex::new(HashMap::default()),
        })
    }
}

/// A QUIC-compatible TLS server configuration
///
/// A `QuicServerConfig` with reasonable defaults is constructed implicitly within
/// `ServerConfig::with_single_cert()`. Alternatively, `QuicServerConfig`'s [`TryFrom`]
/// implementation or `with_initial` method can be used to wrap around a custom
/// [`rama_tls_rustls::dep::rustls::ServerConfig`], in which case care should be taken around certain points:
///
/// - If `max_early_data_size` is not set to `u32::MAX`, the server will not be able to accept
///   incoming 0-RTT data. QUIC prohibits `max_early_data_size` values other than 0 or `u32::MAX`.
/// - The `rama_tls_rustls::dep::rustls::ServerConfig` must have TLS 1.3 support enabled for conversion to succeed.
///
pub(crate) struct QuicServerConfig {
    alpn_policy: AlpnPolicy,
    store_peer_chain: bool,
    inner: Arc<rustls::ServerConfig>,
    /// `inner` per (version, early data allowed), built on first use. Tickets and stored
    /// sessions are tagged with the version so one version's cannot resume another's
    /// (RFC 9369 §5). rustls labels 0-RTT keys with the session's version, but a client sends
    /// 0-RTT only in its original version (RFC 9369 §4.1), so a session moved to another
    /// version refuses early data instead of failing to open it.
    scoped: Mutex<HashMap<(rama_quic_proto::Version, bool), Arc<rustls::ServerConfig>>>,
    initial: Suite,
}

/// Tags every ticket with the version that issued it and refuses the others' (RFC 9369 §5).
#[derive(Debug)]
struct VersionedTicketer {
    inner: Arc<dyn rustls::server::ProducesTickets>,
    version: rama_quic_proto::Version,
}

impl rustls::server::ProducesTickets for VersionedTicketer {
    fn enabled(&self) -> bool {
        self.inner.enabled()
    }
    fn lifetime(&self) -> u32 {
        self.inner.lifetime()
    }
    fn encrypt(&self, plain: &[u8]) -> Option<Vec<u8>> {
        let mut tagged = self.version.to_be_bytes().to_vec();
        tagged.extend_from_slice(plain);
        self.inner.encrypt(&tagged)
    }
    fn decrypt(&self, cipher: &[u8]) -> Option<Vec<u8>> {
        let plain = self.inner.decrypt(cipher)?;
        plain
            .strip_prefix(&self.version.to_be_bytes())
            .map(<[u8]>::to_vec)
    }
}

/// Keys stored sessions by version, so a session ID from one version misses in another.
#[derive(Debug)]
struct VersionedSessionStorage {
    inner: Arc<dyn rustls::server::StoresServerSessions>,
    version: rama_quic_proto::Version,
}

impl VersionedSessionStorage {
    fn key(&self, key: &[u8]) -> Vec<u8> {
        let mut tagged = self.version.to_be_bytes().to_vec();
        tagged.extend_from_slice(key);
        tagged
    }
}

impl rustls::server::StoresServerSessions for VersionedSessionStorage {
    fn put(&self, key: Vec<u8>, value: Vec<u8>) -> bool {
        self.inner.put(self.key(&key), value)
    }
    fn get(&self, key: &[u8]) -> Option<Vec<u8>> {
        self.inner.get(&self.key(key))
    }
    fn take(&self, key: &[u8]) -> Option<Vec<u8>> {
        self.inner.take(&self.key(key))
    }
    fn can_cache(&self) -> bool {
        self.inner.can_cache()
    }
}

impl QuicServerConfig {
    fn config_for(
        &self,
        version: rama_quic_proto::Version,
        early_data: bool,
    ) -> Arc<rustls::ServerConfig> {
        self.scoped
            .lock()
            .entry((version, early_data))
            .or_insert_with(|| {
                let mut config = (*self.inner).clone();
                config.ticketer = Arc::new(VersionedTicketer {
                    inner: self.inner.ticketer.clone(),
                    version,
                });
                config.session_storage = Arc::new(VersionedSessionStorage {
                    inner: self.inner.session_storage.clone(),
                    version,
                });
                if !early_data {
                    config.max_early_data_size = 0;
                }
                Arc::new(config)
            })
            .clone()
    }
}

impl QuicServerConfig {
    #[cfg(all(test, feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
    #[expect(
        clippy::expect_used,
        reason = "`inner` is built on `configured_provider()`, whose ring and aws-lc defaults include TLS13_AES_128_GCM_SHA256"
    )]
    pub(crate) fn new(
        cert_chain: Vec<CertificateDer<'static>>,
        key: PrivateKeyDer<'static>,
    ) -> Result<Self, rustls::Error> {
        let inner = Self::inner(cert_chain, key)?;
        Ok(Self {
            alpn_policy: AlpnPolicy::OutOfBandAgreement,
            store_peer_chain: false,
            // We're confident that the *ring* default provider contains TLS13_AES_128_GCM_SHA256
            initial: initial_suite_from_provider(inner.crypto_provider())
                .expect("no initial cipher suite found"),
            scoped: Mutex::new(HashMap::default()),
            inner: Arc::new(inner),
        })
    }

    #[cfg(all(test, feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
    /// Initialize a QUIC-compatible TLS client configuration with a separate initial cipher suite
    ///
    /// This is useful if you want to avoid the initial cipher suite for traffic encryption.
    pub(crate) fn with_initial(
        inner: Arc<rustls::ServerConfig>,
        initial: Suite,
    ) -> Result<Self, NoInitialCipherSuite> {
        match initial.suite.common.suite {
            CipherSuite::TLS13_AES_128_GCM_SHA256 => Ok(Self {
                scoped: Mutex::new(HashMap::default()),
                inner,
                initial,
                alpn_policy: AlpnPolicy::OutOfBandAgreement,
                store_peer_chain: false,
            }),
            _ => Err(NoInitialCipherSuite { specific: true }),
        }
    }

    #[cfg(all(test, feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
    /// Initialize a sane QUIC-compatible TLS server configuration
    ///
    /// QUIC requires that TLS 1.3 be enabled, and that the maximum early data size is either 0 or
    /// `u32::MAX`. Advanced users can use any [`rama_tls_rustls::dep::rustls::ServerConfig`] that satisfies these
    /// requirements.
    pub(crate) fn inner(
        cert_chain: Vec<CertificateDer<'static>>,
        key: PrivateKeyDer<'static>,
    ) -> Result<rustls::ServerConfig, rustls::Error> {
        #[expect(
            clippy::unwrap_used,
            reason = "the configured providers support TLS 1.3"
        )]
        let mut inner = rustls::ServerConfig::builder_with_provider(configured_provider())
            .with_protocol_versions(&[&rustls::version::TLS13])
            .unwrap() // The *ring* default provider supports TLS 1.3
            .with_no_client_auth()
            .with_single_cert(cert_chain, key)?;

        inner.max_early_data_size = u32::MAX;
        Ok(inner)
    }
}

impl TryFrom<rustls::ServerConfig> for QuicServerConfig {
    type Error = NoInitialCipherSuite;

    fn try_from(inner: rustls::ServerConfig) -> Result<Self, Self::Error> {
        Arc::new(inner).try_into()
    }
}

impl TryFrom<Arc<rustls::ServerConfig>> for QuicServerConfig {
    type Error = NoInitialCipherSuite;

    fn try_from(inner: Arc<rustls::ServerConfig>) -> Result<Self, Self::Error> {
        Ok(Self {
            alpn_policy: AlpnPolicy::OutOfBandAgreement,
            store_peer_chain: false,
            initial: initial_suite_from_provider(inner.crypto_provider())
                .ok_or(NoInitialCipherSuite { specific: false })?,
            scoped: Mutex::new(HashMap::default()),
            inner,
        })
    }
}

impl QuicServerConfig {
    fn start_with(
        &self,
        config: Arc<rustls::ServerConfig>,
        version: rama_quic_proto::Version,
        params: &TransportParameters,
    ) -> Result<Box<dyn crypto::Session>, TransportError> {
        let Ok(version) = interpret_version(version) else {
            // The only thing that fails here is the version, which the reason names.
            return Err(TransportError::INTERNAL_ERROR("unsupported QUIC version"));
        };
        Ok(Box::new(TlsSession {
            alpn_policy: self.alpn_policy,
            store_peer_chain: self.store_peer_chain,
            version,
            got_handshake_data: false,
            server_name: None,
            next_secrets: None,
            write_level: SpaceId::Initial,
            output: Default::default(),
            inner: rustls::quic::Connection::Server(
                rustls::quic::ServerConnection::new(config, version, to_vec(params))
                    .map_err(session_error)?,
            ),
            suite: self.initial,
        }))
    }
}

impl crypto::InitialServerConfig for QuicServerConfig {
    fn initial_keys(
        &self,
        version: rama_quic_proto::Version,
        dst_cid: &ConnectionId,
    ) -> Result<Keys, crypto::InitialKeysError> {
        server_initial_keys(version, dst_cid, &self.initial)
    }

    fn retry_tag(
        &self,
        version: rama_quic_proto::Version,
        orig_dst_cid: &ConnectionId,
        packet: &[u8],
    ) -> Result<[u8; 16], CryptoError> {
        retry_tag(version, orig_dst_cid, packet)
    }
}

impl crypto::ServerConfig for QuicServerConfig {
    fn start_session(
        self: Arc<Self>,
        version: rama_quic_proto::Version,
        params: &TransportParameters,
    ) -> Result<Box<dyn crypto::Session>, TransportError> {
        self.start_with(self.config_for(version, true), version, params)
    }

    fn supports_compatible_negotiation(&self) -> bool {
        true
    }

    fn start_negotiated_session(
        self: Arc<Self>,
        _original: rama_quic_proto::Version,
        negotiated: rama_quic_proto::Version,
        params: &TransportParameters,
    ) -> Result<Box<dyn crypto::Session>, TransportError> {
        self.start_with(self.config_for(negotiated, false), negotiated, params)
    }
}

/// A server configuration whose rustls configuration a [`RustlsDynamicConfig`] resolves per
/// ClientHello, before each connection's session starts.
pub(crate) struct QuicDynamicServerConfig {
    dynamic: RustlsDynamicConfig,
    initial: Suite,
    options: config::TlsOptions,
    store_peer_chain: bool,
    /// Configurations already checked for QUIC, by the native configuration they wrap:
    /// a provider handing out the same one for many connections pays for that once.
    resolved: Mutex<Vec<(Arc<rustls::ServerConfig>, Arc<QuicServerConfig>)>>,
}

/// Native configurations whose QUIC configuration stays resolved.
const RESOLVED_CAPACITY: usize = 16;

impl QuicDynamicServerConfig {
    pub(crate) fn new(
        dynamic: RustlsDynamicConfig,
        provider: &Arc<rustls::crypto::CryptoProvider>,
        options: config::TlsOptions,
        store_peer_chain: bool,
    ) -> Result<Self, NoInitialCipherSuite> {
        Ok(Self {
            dynamic,
            initial: initial_suite_from_provider(provider)
                .ok_or(NoInitialCipherSuite { specific: false })?,
            options,
            store_peer_chain,
            resolved: Mutex::new(Vec::with_capacity(RESOLVED_CAPACITY)),
        })
    }
}

impl crypto::InitialServerConfig for QuicDynamicServerConfig {
    fn initial_keys(
        &self,
        version: rama_quic_proto::Version,
        dst_cid: &ConnectionId,
    ) -> Result<Keys, crypto::InitialKeysError> {
        server_initial_keys(version, dst_cid, &self.initial)
    }

    fn retry_tag(
        &self,
        version: rama_quic_proto::Version,
        orig_dst_cid: &ConnectionId,
        packet: &[u8],
    ) -> Result<[u8; 16], CryptoError> {
        retry_tag(version, orig_dst_cid, packet)
    }
}

impl crypto::ServerConfigResolver for QuicDynamicServerConfig {
    fn resolve(
        self: Arc<Self>,
        client_hello: crypto::ClientHelloMessage,
    ) -> crypto::ServerConfigLookup {
        // The provider is opaque: any configuration it hands out may cost it real work.
        let work = Box::pin(self.native_config(client_hello));
        Box::pin(ready(Ok(crypto::ServerConfigResolution::Pending(work))))
    }
}

impl QuicDynamicServerConfig {
    async fn native_config(
        self: Arc<Self>,
        client_hello: crypto::ClientHelloMessage,
    ) -> Result<Arc<dyn crypto::ServerConfig>, BoxError> {
        // rustls hands its own ClientHello view only to an acceptor reading TLS records,
        // so the bare handshake message is framed as handshake records first.
        let mut framed = Vec::with_capacity(client_hello.message().len() + 5);
        for fragment in client_hello.message().chunks(MAX_RECORD_PAYLOAD) {
            framed.extend_from_slice(&[0x16, 0x03, 0x01]);
            framed.extend_from_slice(&(fragment.len() as u16).to_be_bytes());
            framed.extend_from_slice(fragment);
        }
        let mut acceptor = rustls::server::Acceptor::default();
        // Each read takes at most a few KiB; feed every record.
        let mut records = framed.as_slice();
        while !records.is_empty() {
            acceptor.read_tls(&mut records)?;
        }
        let accepted = acceptor
            .accept()
            .map_err(|(error, _alert)| error)?
            .ok_or_else(|| BoxError::from_static_str("incomplete ClientHello"))?;
        let native = self.dynamic.get_config(accepted.client_hello()).await?;
        if let Some((_, config)) = self
            .resolved
            .lock()
            .iter()
            .find(|(held, _)| Arc::ptr_eq(held, &native))
        {
            return Ok(config.clone() as Arc<dyn crypto::ServerConfig>);
        }
        let mut quic = rustls::ServerConfig::clone(&native);
        quic.max_early_data_size = if self.options.early_data { u32::MAX } else { 0 };
        let config = Arc::new(QuicServerConfig::from_native(
            quic,
            self.options,
            self.store_peer_chain,
        )?);
        let mut resolved = self.resolved.lock();
        if resolved.len() == RESOLVED_CAPACITY {
            resolved.remove(0);
        }
        resolved.push((native, config.clone()));
        Ok(config as Arc<dyn crypto::ServerConfig>)
    }
}

/// The most plaintext one TLS record carries (RFC 8446 §5.1).
const MAX_RECORD_PAYLOAD: usize = 1 << 14;

pub(crate) fn server_initial_keys(
    version: rama_quic_proto::Version,
    dst_cid: &ConnectionId,
    initial: &Suite,
) -> Result<Keys, crypto::InitialKeysError> {
    let version = interpret_version(version)?;
    Ok(initial_keys(version, *dst_cid, Side::Server, initial))
}

fn retry_tag(
    version: rama_quic_proto::Version,
    orig_dst_cid: &ConnectionId,
    packet: &[u8],
) -> Result<[u8; 16], CryptoError> {
    let wire = interpret_version(version)
        .map(retry_wire)
        .map_err(|_error| CryptoError::new())?;

    let mut pseudo_packet = Vec::with_capacity(packet.len() + orig_dst_cid.len() + 1);
    pseudo_packet.push(orig_dst_cid.len() as u8);
    pseudo_packet.extend_from_slice(orig_dst_cid);
    pseudo_packet.extend_from_slice(packet);

    let nonce = aead::Nonce::assume_unique_for_key(wire.retry_nonce);
    let key = aead::LessSafeKey::new(
        aead::UnboundKey::new(&aead::AES_128_GCM, &wire.retry_key)
            .map_err(|_error| CryptoError::new())?,
    );
    let tag = key
        .seal_in_place_separate_tag(nonce, aead::Aad::from(pseudo_packet), &mut [])
        .map_err(|_error| CryptoError::new())?;
    let mut result = [0; 16];
    result.copy_from_slice(tag.as_ref());
    Ok(result)
}

pub(crate) fn initial_suite_from_provider(
    provider: &Arc<rustls::crypto::CryptoProvider>,
) -> Option<Suite> {
    provider
        .cipher_suites
        .iter()
        .find_map(|cs| match (cs.suite(), cs.tls13()) {
            (rustls::CipherSuite::TLS13_AES_128_GCM_SHA256, Some(suite)) => {
                Some(suite.quic_suite())
            }
            _ => None,
        })
        .flatten()
}

pub(crate) fn configured_provider() -> Arc<rustls::crypto::CryptoProvider> {
    #[cfg(all(feature = "aws-lc", not(feature = "ring")))]
    let provider = rustls::crypto::aws_lc_rs::default_provider();
    #[cfg(feature = "ring")]
    let provider = rustls::crypto::ring::default_provider();
    Arc::new(provider)
}

fn to_vec(params: &TransportParameters) -> Vec<u8> {
    let mut bytes = Vec::new();
    params.write(&mut bytes);
    bytes
}

pub(crate) fn initial_keys(
    version: Version,
    dst_cid: ConnectionId,
    side: Side,
    suite: &Suite,
) -> Keys {
    let side = match side {
        Side::Client => rustls::Side::Client,
        Side::Server => rustls::Side::Server,
    };
    let keys = suite.keys(&dst_cid, side, version);
    Keys {
        local: DirectionalKeys {
            header: Box::new(RustlsHeaderKey(keys.local.header)),
            packet: Box::new(RustlsPacketKey(keys.local.packet)),
        },
        remote: Some(DirectionalKeys {
            header: Box::new(RustlsHeaderKey(keys.remote.header)),
            packet: Box::new(RustlsPacketKey(keys.remote.packet)),
        }),
    }
}

impl crypto::PacketKey for RustlsPacketKey {
    fn encrypt(&self, packet: u64, buf: &mut [u8], header_len: usize) -> Result<(), CryptoError> {
        let (header, payload_tag) = buf.split_at_mut(header_len);
        let (payload, tag_storage) = payload_tag.split_at_mut(payload_tag.len() - self.tag_len());
        let tag = self
            .0
            .encrypt_in_place(packet, &*header, payload)
            .map_err(|_error| CryptoError::new())?;
        tag_storage.copy_from_slice(tag.as_ref());
        Ok(())
    }

    fn decrypt(
        &self,
        packet: u64,
        header: &[u8],
        payload: &mut BytesMut,
    ) -> Result<(), CryptoError> {
        // The backend reports only that it failed, which is all `CryptoError` says.
        let Ok(plain) = self.0.decrypt_in_place(packet, header, payload.as_mut()) else {
            return Err(CryptoError::new());
        };
        let plain_len = plain.len();
        payload.truncate(plain_len);
        Ok(())
    }

    fn tag_len(&self) -> usize {
        self.0.tag_len()
    }

    fn confidentiality_limit(&self) -> u64 {
        self.0.confidentiality_limit()
    }

    fn integrity_limit(&self) -> u64 {
        self.0.integrity_limit()
    }
}

fn interpret_version(version: rama_quic_proto::Version) -> Result<Version, UnsupportedVersion> {
    match version.as_u32() {
        0xff00_001d..=0xff00_0020 => Ok(Version::V1Draft),
        0x0000_0001 | 0xff00_0021..=0xff00_0022 => Ok(Version::V1),
        0x6b33_43cf => Ok(Version::V2),
        _ => Err(UnsupportedVersion),
    }
}

fn session_error(error: rustls::Error) -> TransportError {
    TransportError::INTERNAL_ERROR("initialize TLS session").with_cause(error)
}

#[cfg(test)]
mod tests {
    use std::assert_matches;

    use rama_tls_rustls::dep::rustls::pki_types::DnsName;

    use super::*;

    #[test]
    fn handshake_error_without_alert_preserves_its_source() {
        use std::error::Error as _;

        use crate::proto::crypto::ClientConfig as _;

        let native = rustls::ClientConfig::builder_with_provider(configured_provider())
            .with_protocol_versions(&[&rustls::version::TLS13])
            .unwrap()
            .with_root_certificates(rustls::RootCertStore::empty())
            .with_no_client_auth();
        let config = Arc::new(QuicClientConfig::try_from(native).unwrap());
        let mut session = config
            .start_session(
                rama_quic_proto::Version::V1,
                "example.com",
                &TransportParameters::default(),
            )
            .unwrap();

        // An oversized handshake header fails in rustls's deframer before an alert is set.
        let error = session
            .read_handshake(SpaceId::Initial, &[2, 0xff, 0xff, 0xff])
            .unwrap_err();
        assert_eq!(error.code(), TransportErrorCode::PROTOCOL_VIOLATION);
        let source = error
            .source()
            .and_then(|source| source.downcast_ref::<rustls::Error>())
            .expect("the original rustls error remains in the source chain");
        assert_matches!(
            source,
            rustls::Error::InvalidMessage(rustls::InvalidMessage::HandshakePayloadTooLarge),
        );
        assert_eq!(error.reason(), format!("TLS error: {source}"));
    }

    /// RFC 9001 §6.6 and Appendix B, as this backend's provider reports them for every TLS 1.3
    /// suite it offers: the AES-GCM suites stop at 2^23 packets per key and 2^52 forgeries per
    /// connection; ChaCha20-Poly1305 at 2^36 forgeries, with a confidentiality limit beyond the
    /// 2^62 packets a connection can number. Both directions of a key set answer alike.
    #[test]
    fn packet_keys_report_the_rfc_9001_aead_limits() {
        let provider = configured_provider();
        let mut suites = Vec::new();
        for suite in &provider.cipher_suites {
            let Some(quic) = suite.tls13().and_then(|tls13| tls13.quic_suite()) else {
                continue;
            };
            let (confidentiality, integrity) = match suite.suite() {
                CipherSuite::TLS13_AES_128_GCM_SHA256 | CipherSuite::TLS13_AES_256_GCM_SHA384 => {
                    (1 << 23..=1 << 23, 1 << 52)
                }
                CipherSuite::TLS13_CHACHA20_POLY1305_SHA256 => (1 << 62..=u64::MAX, 1 << 36),
                other => panic!("an unexpected QUIC suite: {other:?}"),
            };
            let keys = quic.keys(&[1, 2, 3, 4, 5, 6, 7, 8], rustls::Side::Client, Version::V1);
            for key in [&*keys.local.packet, &*keys.remote.packet] {
                assert!(
                    confidentiality.contains(&key.confidentiality_limit()),
                    "{:?}: {} packets per key",
                    suite.suite(),
                    key.confidentiality_limit()
                );
                assert_eq!(key.integrity_limit(), integrity, "{:?}", suite.suite());
            }
            suites.push(suite.suite());
        }
        for expected in [
            CipherSuite::TLS13_AES_128_GCM_SHA256,
            CipherSuite::TLS13_AES_256_GCM_SHA384,
            CipherSuite::TLS13_CHACHA20_POLY1305_SHA256,
        ] {
            assert!(suites.contains(&expected), "{expected:?} is offered");
        }
    }

    /// The contract the handshake summary rests on: a name this backend validated as a DNS name
    /// reads as a domain. Rustls checks label shape, length and the 253-octet total, and a
    /// domain's rules are no stricter. Each of these has to be accepted by both, so a backend
    /// that started rejecting them would fail here rather than pass quietly.
    #[test]
    fn a_name_the_backend_accepts_is_a_domain() {
        let long_label = "a".repeat(63);
        let long_name = format!("{long_label}.{long_label}.{long_label}.{}", "a".repeat(61));
        let accepted = [
            "localhost",
            "example.com",
            "EXAMPLE.com",
            "sub.example.com.",
            "under_score.example.com",
            "1.2.3.example.com",
            "xn--bcher-kva.example",
            "a",
            "a-b.example",
            long_label.as_str(),
            long_name.as_str(),
        ];
        for name in accepted {
            let validated = DnsName::try_from(name)
                .unwrap_or_else(|error| panic!("the backend accepts {name:?}: {error}"));
            let seen = received_server_name(validated.as_ref())
                .unwrap_or_else(|error| panic!("the backend accepts {name:?}: {error}"));
            assert_eq!(seen.as_str(), validated.as_ref(), "and it keeps its text");
        }
    }

    /// The other side of that boundary: what the backend refuses never reaches the adapter, and
    /// this says which shapes those are. An IP address is among them, which is why a client
    /// connecting to one sends no SNI at all (RFC 6066 §3).
    #[test]
    fn the_backend_refuses_what_is_not_a_dns_name() {
        let too_long = format!("{}.example", "a".repeat(250));
        let refused = [
            "",
            // A label of digits alone is refused, which is how a bare number and an address are
            // kept out of a name.
            "9",
            "127.0.0.1",
            "::1",
            "exa mple.com",
            "example..com",
            too_long.as_str(),
        ];
        for name in refused {
            assert!(
                DnsName::try_from(name).is_err(),
                "the backend refuses {name:?}"
            );
        }
    }

    /// If this crate and its backend ever disagreed about a name, the connection would end on a
    /// local error rather than reporting no name at all. The input here is one the backend
    /// would itself have refused.
    #[test]
    fn a_name_that_is_not_a_domain_is_a_local_error() {
        let refused = received_server_name("").expect_err("an empty name is not a domain");
        assert_eq!(refused.code(), TransportErrorCode::INTERNAL_ERROR);
        assert_eq!(refused.reason(), "received server name is not a domain");
        assert!(
            refused.cause().is_some(),
            "and it keeps what the conversion said"
        );
    }
}
