use std::{
    fmt,
    num::NonZeroUsize,
    sync::{Arc, LazyLock},
};

use parking_lot::Mutex;
use rama_core::{
    error::{ArcError, BoxError},
    extensions::{Extension, Extensions},
};
use rama_crypto::dep::boring::{
    error::ErrorStack,
    ex_data::Index,
    ssl::{Ssl, SslAcceptorBuilder, SslContext, SslRef, SslVersion},
};
use rama_net::{
    address::Host,
    tls::{AlpnPolicy, TlsAlpn},
};
use rama_quic_proto::{
    ConnectionId, Side, TransportError, Version, transport_parameters::TransportParameters,
};
use rama_tls::{
    ProtocolVersion, TlsSupportedVersions,
    alpn::{self, AlpnError},
    client::TlsClientConfig,
    server::TlsServerConfig,
};
use rama_tls_boring::{
    client::{
        BoringTlsConnectorConfig, TlsClientSession, TlsClientSessionCache, TlsClientSessionDomain,
        TlsClientSessionKey, TlsConnectorContext, TlsConnectorContextBuilder,
    },
    server::{BoringTlsAcceptorConfig, IssuedCertificate, TlsAcceptorData},
};

use super::{
    packet,
    session::{TlsSession, crypto_error},
};
use crate::tls::ClientHandshake;

use crate::proto::{
    ConnectError, ServerCrypto,
    crypto::{
        self,
        config::{ClientSessionPolicy, TlsConfigError, TlsOptions},
    },
};

/// Per-connection TLS setup, in a TLS configuration's extensions: callbacks a relay needs on
/// one connection only, such as pausing egress at a CertificateRequest.
#[derive(Clone, Extension)]
#[extension(tags(tls))]
pub(crate) struct HandshakeInitializer(
    pub(crate) Arc<dyn Fn(&mut SslRef) -> Result<(), BoxError> + Send + Sync>,
);

impl fmt::Debug for HandshakeInitializer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("HandshakeInitializer")
            .finish_non_exhaustive()
    }
}

/// Runs once on a connection whose TLS handshake completed, with its finished session: for
/// state that may only be read once the peer proved what it presented.
#[derive(Clone)]
pub(crate) struct HandshakeCompleted(pub(crate) Arc<dyn Fn(&SslRef) + Send + Sync>);

static HANDSHAKE_COMPLETED_INDEX: LazyLock<Result<Index<Ssl, HandshakeCompleted>, ErrorStack>> =
    LazyLock::new(Ssl::new_ex_index::<HandshakeCompleted>);

/// Run `hook` once this connection's handshake completes.
pub(crate) fn on_handshake_completed(
    ssl: &mut SslRef,
    hook: impl Fn(&SslRef) + Send + Sync + 'static,
) -> Result<(), BoxError> {
    let index = HANDSHAKE_COMPLETED_INDEX.clone()?;
    ssl.set_ex_data(index, HandshakeCompleted(Arc::new(hook)));
    Ok(())
}

/// The hook [`on_handshake_completed`] installed on this connection, if any.
pub(crate) fn handshake_completed_hook(ssl: &SslRef) -> Option<HandshakeCompleted> {
    let index = HANDSHAKE_COMPLETED_INDEX.as_ref().ok()?;
    ssl.ex_data(*index).cloned()
}

struct Ticket {
    session: TlsClientSession,
    params: TransportParameters,
}

/// Tickets by server, security-derived session scope and negotiated QUIC version.
/// A connector cache retains at most 64 such keys, with two tickets per key;
/// native configuration eviction does not change its session domain (RFC 9369 §5).
type Tickets = TlsClientSessionCache<(TlsClientSessionKey, Version), Ticket>;

const MAX_TICKET_HOSTS: NonZeroUsize = NonZeroUsize::new(64).unwrap();
const TICKETS_PER_HOST: NonZeroUsize = NonZeroUsize::new(2).unwrap();

/// One bounded ticket store for a connector cache's sibling native configurations.
#[derive(Clone, Debug, Extension)]
#[extension(tags(tls))]
pub(crate) struct SharedClientSessions {
    tickets: Arc<Tickets>,
    domain: TlsClientSessionDomain,
}

impl SharedClientSessions {
    pub(crate) fn defaults() -> Extensions {
        let shared = Self {
            tickets: Arc::new(Tickets::new(MAX_TICKET_HOSTS, TICKETS_PER_HOST)),
            domain: TlsClientSessionDomain::new(),
        };
        let extensions = Extensions::new();
        extensions.insert(shared.domain);
        extensions.insert(shared);
        extensions
    }
}

struct TicketState {
    /// The connection's version, which compatible negotiation may still change.
    version: Arc<Mutex<Version>>,
    params: Arc<Mutex<Option<TransportParameters>>>,
}

// BoringSSL ex-data indices live for the process lifetime. Register one slot
// for this type; ticket contents and their caches remain connection/config local.
static TICKET_INDEX: LazyLock<Result<Index<Ssl, TicketState>, ErrorStack>> =
    LazyLock::new(Ssl::new_ex_index::<TicketState>);

pub(crate) struct QuicClientConfig {
    context: TlsConnectorContext,
    ech: Option<Vec<u8>>,
    ech_observation: Option<crate::tls::BoringEchObservation>,
    sessions: Option<ClientSessions>,
    early_data: bool,
    initializer: Option<HandshakeInitializer>,
    prepared: Option<Box<PreparedClient>>,
}

/// Preparation retains the first native SSL object; retries use the same context
/// and initializer but obtain their own ephemeral handshake state.
struct PreparedClient {
    peer: Host,
    first: Mutex<Option<Ssl>>,
}

// Keeping the cache and callback together makes Fresh incapable of consulting
// a ticket store or retaining new tickets. Full offers can retain new
// tickets while suppressing lookup of older ones.
struct ClientSessions {
    tickets: Arc<Tickets>,
    ticket_index: Index<Ssl, TicketState>,
    offer: ClientHandshake,
}

impl ClientSessions {
    fn resume(
        &self,
        context: &TlsConnectorContext,
        ssl: &mut SslRef,
        host: &Host,
        version: Version,
    ) -> Result<Option<TransportParameters>, BoxError> {
        let required = match self.offer {
            ClientHandshake::Auto => false,
            ClientHandshake::Full => return Ok(None),
            ClientHandshake::Resumed => true,
        };
        if let Some(key) = context.session_key(host)
            && let Some(ticket) = self.tickets.pop(&(key, version))
        {
            ticket.session.resume_on(ssl)?;
            return Ok(Some(ticket.params));
        }
        if required {
            return Err(BoxError::from(
                "resumed TLS requires a current peer-issued ticket",
            ));
        }
        Ok(None)
    }
}

fn validate_versions(versions: Option<&TlsSupportedVersions>) -> Result<(), TlsConfigError> {
    if versions.is_some_and(|v| !v.0.is_empty() && !v.0.contains(&ProtocolVersion::TLSv1_3)) {
        return Err(TlsConfigError::Tls13Required);
    }
    Ok(())
}

fn validate_alpn(alpn: Option<&TlsAlpn>, options: TlsOptions) -> Result<(), TlsConfigError> {
    alpn::validate_alpn(
        alpn.into_iter()
            .flat_map(|list| list.0.iter().map(|protocol| protocol.as_bytes())),
        AlpnPolicy::Require,
    )
    .map_err(|error| match error {
        AlpnError::Required if options.alpn == AlpnPolicy::OutOfBandAgreement => {
            TlsConfigError::UnsupportedOutOfBandAgreement
        }
        AlpnError::Required => TlsConfigError::AlpnRequired,
        AlpnError::Invalid => TlsConfigError::InvalidAlpn,
    })
}

impl QuicClientConfig {
    pub(crate) fn from_rama(
        config: &TlsClientConfig,
        options: TlsOptions,
    ) -> Result<Self, TlsConfigError> {
        let pieces = BoringTlsConnectorConfig::from_extensions(config.as_extensions());
        validate_versions(pieces.versions)?;
        validate_alpn(pieces.alpn, options)?;
        let handshake = pieces.client_handshake.copied().unwrap_or_default();
        if handshake == ClientHandshake::Resumed
            && options.client_sessions == ClientSessionPolicy::Fresh
        {
            return Err(TlsConfigError::InvalidConfiguration(BoxError::from(
                "resumed TLS conflicts with the fresh client policy",
            )));
        }
        let mut builder = TlsConnectorContextBuilder::try_from(pieces)?;
        if builder
            .max_proto_version()
            .is_some_and(|version| version != SslVersion::TLS1_3)
        {
            return Err(TlsConfigError::Tls13Required);
        }
        let sessions = if options.client_sessions == ClientSessionPolicy::Reuse {
            let tickets = config
                .as_extensions()
                .get_ref::<SharedClientSessions>()
                .map(|shared| shared.tickets.clone())
                .unwrap_or_else(|| Arc::new(Tickets::new(MAX_TICKET_HOSTS, TICKETS_PER_HOST)));
            let callback_tickets = tickets.clone();
            let ticket_index = *TICKET_INDEX
                .as_ref()
                .map_err(|error| TlsConfigError::InvalidConfiguration(error.clone().into()))?;
            builder.set_new_session_callback(move |ssl, session| {
                if let Some(state) = ssl.ex_data(ticket_index)
                    && let Some(params) = state.params.lock().clone()
                {
                    callback_tickets.insert(
                        (session.key().clone(), *state.version.lock()),
                        Ticket { session, params },
                    );
                }
            });
            Some(ClientSessions {
                tickets,
                ticket_index,
                offer: handshake,
            })
        } else {
            None
        };
        Ok(Self {
            context: builder.build(),
            ech_observation: config.as_extensions().get_ref::<crate::tls::BoringEchObservation>().cloned(),
            ech: config.as_extensions().get_ref::<crate::tls::BoringEchConfigList>().map(|v| v.0.clone()),
            prepared: None,
            sessions,
            early_data: options.early_data,
            initializer: config
                .as_extensions()
                .get_ref::<HandshakeInitializer>()
                .cloned(),
        })
    }
}

impl QuicClientConfig {
    pub(crate) fn prepare_fresh(
        config: &TlsClientConfig,
        peer: Host,
    ) -> Result<Self, TlsConfigError> {
        Self::from_rama(
            config,
            TlsOptions::default().with_client_sessions(ClientSessionPolicy::Fresh),
        )?
        .prepare_ssl(peer)
    }

    pub(crate) fn prepare_client(
        config: &TlsClientConfig,
        options: TlsOptions,
        peer: Host,
        handshake: ClientHandshake,
    ) -> Result<Self, TlsConfigError> {
        let mut config = Self::from_rama(config, options)?;
        match (&mut config.sessions, handshake) {
            (Some(sessions), offer) => sessions.offer = offer,
            (None, ClientHandshake::Auto | ClientHandshake::Full) => {}
            (None, ClientHandshake::Resumed) => {
                return Err(TlsConfigError::InvalidConfiguration(BoxError::from(
                    "resumed TLS conflicts with the fresh client policy",
                )));
            }
        }
        config.prepare_ssl(peer)
    }

    fn prepare_ssl(mut self, peer: Host) -> Result<Self, TlsConfigError> {
        let (_, mut ssl) = self.configure_ssl(peer.clone())?;
        if let Some(initializer) = &self.initializer {
            (initializer.0)(&mut ssl)?;
        }
        self.prepared = Some(Box::new(PreparedClient {
            peer,
            first: Mutex::new(Some(ssl)),
        }));
        Ok(self)
    }

    fn configure_ssl(&self, peer: Host) -> Result<(Host, Ssl), BoxError> {
        let mut data = self.context.configure()?;
        if let Some(ech) = &self.ech { data.config.set_ech_config_list(ech)?; }
        let host = data.server_name.get_or_insert(peer).clone();
        let mut ssl = data.into_ssl()?;
        if let Some(observer) = self.ech_observation.clone() {
            on_handshake_completed(&mut ssl, move |ssl| {
                observer.0.store(if ssl.ech_accepted() { 2 } else { 1 }, std::sync::atomic::Ordering::Release);
            })?;
        }
        Ok((host, ssl))
    }
}

impl crypto::ClientConfig for QuicClientConfig {
    fn start_session(
        self: Arc<Self>,
        version: Version,
        server_name: &str,
        params: &TransportParameters,
    ) -> Result<Box<dyn crypto::Session>, ConnectError> {
        let wire = packet::wire(version).ok_or(ConnectError::UnsupportedVersion)?;
        let host = Host::try_from(server_name)
            .map_err(|_error| ConnectError::InvalidServerName(server_name.into()))?;
        // Reject another destination before consuming the prepared session.
        let (host, mut ssl, initializer) = if let Some(prepared) = &self.prepared {
            if host != prepared.peer {
                return Err(ConnectError::InvalidServerName(server_name.into()));
            }
            let first = prepared.first.lock().take();
            let ssl = if let Some(ssl) = first {
                ssl
            } else {
                let (_, mut ssl) = self
                    .configure_ssl(host.clone())
                    .map_err(|error| ConnectError::Crypto(crypto_error(error)))?;
                if let Some(initializer) = &self.initializer {
                    (initializer.0)(&mut ssl)
                        .map_err(|error| ConnectError::Crypto(crypto_error(error)))?;
                }
                ssl
            };
            (host, ssl, None)
        } else {
            let (host, ssl) = self
                .configure_ssl(host)
                .map_err(|error| ConnectError::Crypto(crypto_error(error)))?;
            (host, ssl, self.initializer.as_ref())
        };
        let peer_params = Arc::new(Mutex::new(None));
        let negotiated = Arc::new(Mutex::new(version));
        let remembered = if let Some(sessions) = &self.sessions {
            ssl.set_ex_data(
                sessions.ticket_index,
                TicketState {
                    version: negotiated.clone(),
                    params: peer_params.clone(),
                },
            );
            sessions
                .resume(&self.context, &mut ssl, &host, version)
                .map_err(|error| ConnectError::Crypto(crypto_error(error)))?
        } else {
            None
        };
        let mut session = TlsSession::new(
            ssl,
            Side::Client,
            wire,
            wire,
            params,
            self.early_data,
            initializer,
            remembered,
            peer_params,
        )
        .map_err(ConnectError::Crypto)?;
        session.track_version(negotiated);
        session.store_peer_chain = self.context.stores_server_certificate_chain();
        Ok(Box::new(session))
    }
    fn supports_version_switch(&self) -> bool {
        true
    }
    fn resumable_version(&self, server_name: &str) -> Option<Version> {
        let sessions = self.sessions.as_ref()?;
        if sessions.offer == ClientHandshake::Full {
            return None;
        }
        let host = Host::try_from(server_name).ok()?;
        let key = self.context.session_key(&host)?;
        let keys = [Version::V1, Version::V2].map(|version| (key.clone(), version));
        sessions
            .tickets
            .most_recent(&keys)
            .map(|(_, version)| *version)
    }
}

impl QuicClientConfig {
    /// Tests: relabel the tickets for `server_name` from one version to another, to offer a
    /// ticket from one version to a server session in another.
    #[cfg(test)]
    pub(super) fn relabel_tickets(&self, server_name: &str, from: Version, to: Version) {
        let host = Host::try_from(server_name).unwrap();
        let key = self.context.session_key(&host).unwrap();
        let sessions = self.sessions.as_ref().unwrap();
        let mut tickets = Vec::new();
        while let Some(ticket) = sessions.tickets.pop(&(key.clone(), from)) {
            tickets.push(ticket);
        }
        for ticket in tickets.into_iter().rev() {
            sessions.tickets.insert((key.clone(), to), ticket);
        }
    }
}

pub(crate) struct QuicServerConfig {
    /// The certificate issued for this connection, installed on its session; without one the
    /// contexts carry the identity.
    issued: Option<IssuedCertificate>,
    /// One context per standardized version: BoringSSL resumes a session only under the
    /// session-ID context that issued it, which scopes tickets by version (RFC 9369 §5).
    contexts: [SslContext; 2],
    early_data: bool,
    store_peer_chain: bool,
    initializer: Option<HandshakeInitializer>,
}

/// Issues a certificate per ClientHello, installed on the session of a connection that shares
/// the contexts, and with them the session tickets they issue.
pub(crate) struct QuicServerCertIssuer {
    data: TlsAcceptorData,
    contexts: [SslContext; 2],
    early_data: bool,
    initializer: Option<HandshakeInitializer>,
}

/// The server TLS configured by `config`: fixed, or resolved per ClientHello when it issues
/// certificates.
pub(crate) fn server_config_from_rama(
    config: &TlsServerConfig,
    options: TlsOptions,
) -> Result<ServerCrypto, TlsConfigError> {
    let data = acceptor_data(config, options)?;
    let initializer = config
        .as_extensions()
        .get_ref::<HandshakeInitializer>()
        .cloned();
    Ok(if data.issues_certificates() {
        ServerCrypto::Resolver(Arc::new(QuicServerCertIssuer {
            contexts: contexts(|| data.acceptor_builder_without_identity())?,
            data,
            early_data: options.early_data,
            initializer,
        }))
    } else {
        ServerCrypto::Fixed(Arc::new(QuicServerConfig::fixed(
            &data,
            options,
            initializer,
        )?))
    })
}

fn acceptor_data(
    config: &TlsServerConfig,
    options: TlsOptions,
) -> Result<TlsAcceptorData, TlsConfigError> {
    let pieces = BoringTlsAcceptorConfig::from_extensions(config.as_extensions());
    validate_versions(pieces.versions)?;
    validate_alpn(pieces.alpn, options)?;
    Ok(TlsAcceptorData::try_from(pieces)?)
}

impl QuicServerConfig {
    /// A fixed identity; [`server_config_from_rama`] also takes certificate issuers.
    #[cfg(test)]
    pub(crate) fn from_rama(
        config: &TlsServerConfig,
        options: TlsOptions,
    ) -> Result<Self, TlsConfigError> {
        let data = acceptor_data(config, options)?;
        if data.issues_certificates() {
            return Err(TlsConfigError::UnsupportedDynamicConfig);
        }
        Self::fixed(&data, options, None)
    }

    fn fixed(
        data: &TlsAcceptorData,
        options: TlsOptions,
        initializer: Option<HandshakeInitializer>,
    ) -> Result<Self, TlsConfigError> {
        Ok(Self {
            issued: None,
            contexts: contexts(|| data.clone().into_static_acceptor_builder())?,
            early_data: options.early_data,
            store_peer_chain: data.stores_client_certificate_chain(),
            initializer,
        })
    }
}

fn contexts(
    builder: impl Fn() -> Result<SslAcceptorBuilder, BoxError>,
) -> Result<[SslContext; 2], TlsConfigError> {
    let context = |version: Version| -> Result<SslContext, TlsConfigError> {
        let mut builder = builder()?;
        let invalid = |error: ErrorStack| TlsConfigError::InvalidConfiguration(error.into());
        builder
            .set_min_proto_version(Some(SslVersion::TLS1_3))
            .map_err(invalid)?;
        builder
            .set_max_proto_version(Some(SslVersion::TLS1_3))
            .map_err(invalid)?;
        builder
            .set_session_id_context(&version.to_be_bytes())
            .map_err(invalid)?;
        Ok(builder.build().into_context())
    };
    Ok([context(Version::V1)?, context(Version::V2)?])
}

pub(crate) fn server_initial_keys(
    version: Version,
    cid: &ConnectionId,
) -> Result<crypto::Keys, crypto::InitialKeysError> {
    let wire = packet::wire(version).ok_or(crypto::InitialKeysError::UnsupportedVersion)?;
    packet::initial_keys(wire, cid, Side::Server).map_err(crypto::InitialKeysError::Crypto)
}

pub(crate) fn retry_tag(
    version: Version,
    cid: &ConnectionId,
    packet: &[u8],
) -> Result<[u8; 16], crypto::CryptoError> {
    let wire = packet::wire(version).ok_or(crypto::CryptoError::new())?;
    packet::retry_tag(wire, cid, packet).map_err(|_error| crypto::CryptoError::new())
}

impl crypto::InitialServerConfig for QuicServerConfig {
    fn initial_keys(
        &self,
        version: Version,
        cid: &ConnectionId,
    ) -> Result<crypto::Keys, crypto::InitialKeysError> {
        server_initial_keys(version, cid)
    }
    fn retry_tag(
        &self,
        version: Version,
        cid: &ConnectionId,
        packet: &[u8],
    ) -> Result<[u8; 16], crypto::CryptoError> {
        retry_tag(version, cid, packet)
    }
}

impl crypto::ServerConfig for QuicServerConfig {
    fn start_session(
        self: Arc<Self>,
        version: Version,
        params: &TransportParameters,
    ) -> Result<Box<dyn crypto::Session>, TransportError> {
        self.start_with(version, version, params)
    }
    fn supports_compatible_negotiation(&self) -> bool {
        true
    }
    fn start_negotiated_session(
        self: Arc<Self>,
        original: Version,
        negotiated: Version,
        params: &TransportParameters,
    ) -> Result<Box<dyn crypto::Session>, TransportError> {
        self.start_with(original, negotiated, params)
    }
}

impl crypto::InitialServerConfig for QuicServerCertIssuer {
    fn initial_keys(
        &self,
        version: Version,
        cid: &ConnectionId,
    ) -> Result<crypto::Keys, crypto::InitialKeysError> {
        server_initial_keys(version, cid)
    }
    fn retry_tag(
        &self,
        version: Version,
        cid: &ConnectionId,
        packet: &[u8],
    ) -> Result<[u8; 16], crypto::CryptoError> {
        retry_tag(version, cid, packet)
    }
}

impl crypto::ServerConfigResolver for QuicServerCertIssuer {
    fn resolve(
        self: Arc<Self>,
        client_hello: crypto::ClientHelloMessage,
    ) -> crypto::ServerConfigLookup {
        Box::pin(async move {
            if let Some(certificate) = self
                .data
                .reusable_certificate(client_hello.client_hello())
                .await
            {
                return Ok(crypto::ServerConfigResolution::Ready(
                    self.config_with(certificate),
                ));
            }
            Ok(crypto::ServerConfigResolution::Pending(Box::pin(
                async move {
                    let certificate = self
                        .data
                        .issue_certificate(client_hello.client_hello())
                        .await?;
                    Ok(self.config_with(certificate))
                },
            )))
        })
    }
}

impl QuicServerCertIssuer {
    fn config_with(&self, certificate: IssuedCertificate) -> Arc<dyn crypto::ServerConfig> {
        Arc::new(QuicServerConfig {
            issued: Some(certificate),
            contexts: self.contexts.clone(),
            early_data: self.early_data,
            store_peer_chain: self.data.stores_client_certificate_chain(),
            initializer: self.initializer.clone(),
        })
    }
}

impl QuicServerConfig {
    fn start_with(
        &self,
        original: Version,
        negotiated: Version,
        params: &TransportParameters,
    ) -> Result<Box<dyn crypto::Session>, TransportError> {
        let unsupported = || TransportError::INTERNAL_ERROR("unsupported QUIC version");
        let wire = packet::wire(negotiated).ok_or_else(unsupported)?;
        let early_wire = packet::wire(original).ok_or_else(unsupported)?;
        let context = match negotiated {
            Version::V2 => &self.contexts[1],
            _ => &self.contexts[0],
        };
        let mut ssl = Ssl::new(context).map_err(|error| crypto_error(error.into()))?;
        if let Some(certificate) = &self.issued {
            certificate.install(&mut ssl).map_err(|error| {
                TransportError::INTERNAL_ERROR("install the issued certificate")
                    .with_cause(ArcError::from_box_error(error))
            })?;
        }
        let mut session = TlsSession::new(
            ssl,
            Side::Server,
            wire,
            early_wire,
            params,
            self.early_data,
            self.initializer.as_ref(),
            None,
            Arc::new(Mutex::new(None)),
        )?;
        session.store_peer_chain = self.store_peer_chain;
        Ok(Box::new(session))
    }
}

#[cfg(test)]
mod tests {
    use rama_net::tls::ApplicationProtocol;

    use super::*;

    #[test]
    fn repeated_client_configs_reuse_the_process_ticket_slot() {
        let config =
            TlsClientConfig::new().with_alpn([ApplicationProtocol::HTTP_3].into_iter().collect());
        let first = QuicClientConfig::from_rama(&config, TlsOptions::default()).unwrap();
        for _ in 0..32 {
            let next = QuicClientConfig::from_rama(&config, TlsOptions::default()).unwrap();
            let first = first.sessions.as_ref().unwrap();
            let next = next.sessions.as_ref().unwrap();
            assert_eq!(next.ticket_index.as_raw(), first.ticket_index.as_raw());
            assert!(!Arc::ptr_eq(&next.tickets, &first.tickets));
        }
    }
}
