//! Client QUIC connections as connector services.
//!
//! A [`QuicConnector`] establishes authenticated QUIC connections from the endpoints of an
//! endpoint connector below it, as a TLS connector does over a stream connector:
//!
//! - [`SharedQuicEndpoint`]: every connection multiplexes over one shared endpoint;
//! - [`QuicEndpointConnector`]: one endpoint per connection, on each datagram socket its own
//!   inner connector establishes, such as a connected UDP socket or a UDP tunnel through a
//!   proxy.

mod endpoint;
#[doc(inline)]
pub use endpoint::{ClientEndpoint, QuicEndpointConnector, SharedQuicEndpoint};

#[cfg(test)]
mod tests;

use std::{
    error::Error as StdError,
    fmt,
    io::{Error as IoError, ErrorKind as IoErrorKind},
    net::SocketAddr,
    pin::Pin,
    sync::Arc,
};

use parking_lot::Mutex;
use rama_core::{
    Service,
    error::{ArcError, BoxError, BoxErrorExt as _, error_chain},
    extensions::ExtensionsRef,
    futures::{StreamExt as _, stream},
    telemetry::tracing,
};
use rama_net::{
    ConnectorTargetInputExt,
    address::{Host, HostWithPort, ProxyAddress},
    client::{
        ConnectRequest, ConnectionAttempt, ConnectionError,
        ConnectionErrorDomain::{self, Application, Local, Transport},
        ConnectionErrorKind::{
            self, Authentication, Internal, InvalidInput, Protocol as ProtocolError, Rejected,
            Timeout, Unavailable,
        },
        ConnectionPolicyScope, ConnectorService, ConnectorTarget, ConnectorTargetStream,
        EstablishedClientConnection, EstablishedProxyRoute, ProxyRoute, race_connect,
    },
    mode::ConnectIpMode,
    tls::{AlpnPolicy, ApplicationProtocol, TlsAlpn},
};
use rama_quic_proto::{TransportErrorCode, profile::QuicProfile};
use rama_tls::client::{
    TlsClientConfig, TlsConnectionReuse, TlsServerAuthentication, TlsServerName,
};
use rama_utils::macros::generate_set_and_with;

use crate::{
    ClientConfig, ConnectError as QuicConnectError, Connection,
    ConnectionError as QuicConnectionError, NegotiatedTlsParameters, TransportConfig,
    tls::{ClientConfigCache, QuicClientConfigProvider, TlsOptions},
};

// Allow the alternate address family to progress while one QUIC handshake is waiting,
// without starting a handshake (and its retransmission state) for every DNS result.
const MAX_IN_FLIGHT_CONNECT_ATTEMPTS: usize = 2;

/// Establishes authenticated QUIC connections from the endpoints its endpoint connector `E`
/// hands out ([`ClientEndpoint`]).
///
/// The TLS defaults can be overridden per request. A non-empty default ALPN offer is what the
/// connections serve: a request offer sharing none of it is replaced by it, and the protocol
/// negotiated must be one of it. Otherwise an offered protocol must be negotiated unless the
/// [`AlpnPolicy`] agrees it out of band (RFC 9001 §8.1). A
/// [`QuicProfile`] on the request applies to the client and transport. The origin hostname remains the TLS verification target even when routing
/// selects a different physical address.
///
/// Direct targets are raced over their addresses: an IP target directly, a name through the
/// candidates of an outer DNS connector, each attempt on its own endpoint from `E` with that
/// address as its [`ConnectorTarget`]. A request on a proxy route is not resolved here: `E`
/// must establish the route (publishing [`EstablishedProxyRoute`]) or the request is refused
/// before any attempt, so an explicit proxy is never bypassed. A request addressed to its own
/// MASQUE proxy ([`ProxyRoute::addresses_proxy`]) goes straight to the proxy and is published
/// as [`EstablishedProxyRoute::Forward`].
pub struct QuicConnector<E> {
    endpoints: E,
    tls: TlsClientConfig,
    tls_configs: ClientConfigCache,
    transport: Arc<TransportConfig>,
}

impl<E: Clone> Clone for QuicConnector<E> {
    fn clone(&self) -> Self {
        Self {
            endpoints: self.endpoints.clone(),
            tls: self.tls.clone(),
            tls_configs: self.tls_configs.clone(),
            transport: self.transport.clone(),
        }
    }
}

impl<E: fmt::Debug> fmt::Debug for QuicConnector<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("QuicConnector")
            .field("endpoints", &self.endpoints)
            .finish_non_exhaustive()
    }
}

impl<E> QuicConnector<E> {
    /// Connections from the endpoints of `endpoints`, with `tls` defaults configured by
    /// `provider`.
    pub fn new(
        endpoints: E,
        tls: TlsClientConfig,
        provider: Arc<dyn QuicClientConfigProvider>,
    ) -> Self {
        Self {
            endpoints,
            tls,
            tls_configs: ClientConfigCache::new(provider, TlsOptions::default()),
            transport: Arc::new(TransportConfig::default()),
        }
    }

    generate_set_and_with! {
        /// The transport connections start from; a request's [`QuicProfile`] replaces it.
        pub fn transport(mut self, transport: Arc<TransportConfig>) -> Self {
            self.transport = transport;
            self
        }
    }

    generate_set_and_with! {
        /// The TLS defaults; client configurations built from the previous ones are dropped.
        pub fn tls_config(mut self, tls: TlsClientConfig) -> Self {
            self.tls_configs =
                ClientConfigCache::new(self.tls_configs.provider().clone(), TlsOptions::default());
            self.tls = tls;
            self
        }
    }

    /// The endpoint connector.
    #[must_use]
    pub fn endpoints(&self) -> &E {
        &self.endpoints
    }

    /// The fixed TLS defaults. Rebuild the pool when these defaults or behavior captured by
    /// native TLS hooks change.
    #[must_use]
    pub fn tls_config(&self) -> &TlsClientConfig {
        &self.tls
    }

    /// Provider selection used for establishment and TLS pool identity.
    #[must_use]
    pub fn tls_provider(&self) -> &Arc<dyn QuicClientConfigProvider> {
        self.tls_configs.provider()
    }

    /// The transport connections start from without a [`QuicProfile`].
    #[must_use]
    pub fn transport(&self) -> &Arc<TransportConfig> {
        &self.transport
    }

    /// The TLS configuration a connection for `input` is established with: the defaults with
    /// the request's overrides, its ALPN offer kept within what the connections serve.
    #[must_use]
    pub fn tls_config_for(&self, input: &ConnectRequest) -> TlsClientConfig {
        let mut tls = self.tls.clone().with_overrides(input.extensions());
        let Some(served) = self.served_alpn() else {
            return tls;
        };
        let extensions = tls.as_extensions();
        let out_of_band =
            extensions.get_ref::<AlpnPolicy>() == Some(&AlpnPolicy::OutOfBandAgreement);
        let keep = extensions.get_ref::<TlsAlpn>().is_none_or(|offer| {
            if offer.0.is_empty() {
                out_of_band
            } else {
                offer.0.iter().any(|protocol| serves(served, protocol))
            }
        });
        if !keep {
            tracing::debug!(
                ?served,
                "QUIC ALPN offer lacks what the connector serves; offering that"
            );
            tls.set_alpn(served.0.clone());
        }
        tls
    }

    /// The application protocols the connections serve: the non-empty default ALPN offer.
    fn served_alpn(&self) -> Option<&TlsAlpn> {
        self.tls
            .as_extensions()
            .get_ref::<TlsAlpn>()
            .filter(|offer| !offer.0.is_empty())
    }

    fn prepare(&self, input: &ConnectRequest) -> Result<Prepared, ConnectionError> {
        let profile = input.extensions().get_arc::<QuicProfile>();
        let tls = self.tls_config_for(input);
        let alpn_policy = tls
            .as_extensions()
            .get_ref::<AlpnPolicy>()
            .copied()
            .unwrap_or_default();
        let alpn_offered = tls
            .as_extensions()
            .get_ref::<TlsAlpn>()
            .is_some_and(|offer| !offer.0.is_empty());
        let server_identity = tls
            .as_extensions()
            .get_ref::<TlsServerName>()
            .map_or_else(|| input.authority.host.clone(), |name| name.0.clone());
        let authenticated_identity = self
            .tls_provider()
            .authenticates_server(tls.as_extensions())
            .then(|| server_identity.clone());
        let reuse = TlsConnectionReuse::new(self.tls_provider().clone(), input.extensions());
        let policy_scope = reuse.policy_scope();
        let policy_scope = if let Some(attempt) = input.extensions().get_ref::<ConnectionAttempt>()
        {
            let identity = self
                .tls_provider()
                .authenticates_origin(tls.as_extensions(), &input.authority.host)
                .then_some(authenticated_identity.as_ref())
                .flatten();
            attempt.check_policy(policy_scope, identity)?;
            attempt.policy_scope()
        } else {
            policy_scope
        };
        let mut config = self
            .tls_configs
            .client_config_for_peer(&tls, input.extensions(), &server_identity)
            .map_err(|error| ConnectionError::local(error, InvalidInput))?;
        if let Some(profile) = &profile {
            config
                .apply_quic_profile(profile)
                .map_err(|error| ConnectionError::local(error, InvalidInput))?;
        } else {
            config.set_transport_config(self.transport.clone());
        }
        let server_name = if let Ok(ip) = server_identity.try_as_ip() {
            ip.to_string()
        } else {
            server_identity
                .try_as_domain()
                .map_err(|_error| {
                    ConnectionError::local(
                        BoxError::from_static_str("invalid TLS origin host"),
                        InvalidInput,
                    )
                })?
                .to_string()
        };
        Ok(Prepared {
            alpn_policy,
            alpn_offered,
            config,
            server_name,
            authenticated_identity,
            policy_scope,
            reuse,
        })
    }

    async fn dial(
        &self,
        endpoint: ClientEndpoint,
        address: SocketAddr,
        prepared: &Prepared,
    ) -> Result<(ClientEndpoint, Connection), BoxError> {
        let remote = endpoint.peer().unwrap_or(address);
        let connection = endpoint
            .endpoint()
            .connect_with(prepared.config.clone(), remote, &prepared.server_name)?
            .await?;
        connection.handshake_confirmed().await?;
        self.check_negotiated_alpn(&connection, prepared)?;
        Ok((endpoint, connection))
    }

    /// Refuse a connection whose negotiated protocol the connector does not serve, or that
    /// negotiated none of an offer without out-of-band agreement (RFC 9001 §8.1), closing it.
    fn check_negotiated_alpn(
        &self,
        connection: &Connection,
        prepared: &Prepared,
    ) -> Result<(), BoxError> {
        let negotiated = connection
            .extensions()
            .get_ref::<NegotiatedTlsParameters>()
            .and_then(|tls| tls.application_layer_protocol.as_ref());
        let accepted = match negotiated {
            Some(protocol) => self
                .served_alpn()
                .is_none_or(|served| serves(served, protocol)),
            None => {
                !prepared.alpn_offered || prepared.alpn_policy == AlpnPolicy::OutOfBandAgreement
            }
        };
        if accepted {
            return Ok(());
        }
        connection.close(0u32, b"ALPN required");
        Err(ConnectionError::application(
            BoxError::from_static_str("QUIC requires ALPN agreement or out-of-band agreement"),
            ProtocolError,
        )
        .into())
    }
}

/// Whether `protocol` is one of `served`, by its wire identifier.
fn serves(served: &TlsAlpn, protocol: &ApplicationProtocol) -> bool {
    served
        .0
        .iter()
        .any(|served| served.as_bytes() == protocol.as_bytes())
}

/// Values derived once from the effective TLS configuration for one connection.
struct Prepared {
    alpn_policy: AlpnPolicy,
    alpn_offered: bool,
    config: ClientConfig,
    server_name: String,
    authenticated_identity: Option<Host>,
    policy_scope: ConnectionPolicyScope,
    reuse: TlsConnectionReuse<Arc<dyn QuicClientConfigProvider>>,
}

impl<E> QuicConnector<E>
where
    E: ConnectorService<ConnectRequest, Connection = ClientEndpoint>,
{
    /// The one attempt of a request on a proxy route the endpoint connector establishes.
    async fn connect_through(
        &self,
        input: &ConnectRequest,
        prepared: &Prepared,
        proxy: &ProxyAddress,
    ) -> Result<(Connection, EstablishedProxyRoute), ConnectionError> {
        let attempt =
            ConnectRequest::new_with_extensions(input.authority.clone(), input.extensions().fork());
        let EstablishedClientConnection { conn: endpoint, .. } =
            self.endpoints.connect(attempt).await?;
        let route = endpoint
            .extensions()
            .get_ref::<EstablishedProxyRoute>()
            .filter(|route| route.proxy_address() == Some(proxy))
            .cloned();
        let (Some(route), Some(peer)) = (route, endpoint.peer()) else {
            return Err(ConnectionError::local(
                BoxError::from_static_str(
                    "no connector below this QUIC connector serves the proxy route",
                ),
                Unavailable,
            ));
        };
        let failures = ConnectFailures::default();
        let attempt = input
            .extensions()
            .get_arc::<ConnectionAttempt>()
            .unwrap_or_default();
        let (_endpoint, connection) =
            self.dial(endpoint, peer, prepared).await.map_err(|error| {
                failures
                    .finish(failures.record(error, &attempt))
                    .context("QUIC connection establishment through a proxy")
            })?;
        Ok((connection, route))
    }

    /// Race the target's addresses, each attempt on its own endpoint.
    async fn connect_direct(
        &self,
        input: &ConnectRequest,
        prepared: &Prepared,
    ) -> Result<Connection, ConnectionError> {
        let target = input.connector_target().ok_or_else(|| {
            ConnectionError::local(
                BoxError::from_static_str("QUIC connector target is missing"),
                InvalidInput,
            )
        })?;
        let attempt = input
            .extensions()
            .get_arc::<ConnectionAttempt>()
            .unwrap_or_default();
        let attempt = &attempt;
        let failures = ConnectFailures::default();
        let failures = &failures;
        let dial = |address: SocketAddr| async move {
            let result: Result<_, BoxError> = async {
                let request = ConnectRequest::new_with_extensions(
                    input.authority.clone(),
                    input.extensions().fork(),
                );
                request
                    .extensions()
                    .insert(ConnectorTarget(HostWithPort::from(address)));
                // Erased: a deep endpoint connector stack would otherwise overflow the
                // compiler's auto-trait recursion for every stack built on top of this one.
                let connect: Pin<Box<dyn Future<Output = _> + Send + '_>> =
                    Box::pin(self.endpoints.connect(request));
                let EstablishedClientConnection { conn: endpoint, .. } = connect.await?;
                self.dial(endpoint, address, prepared).await
            }
            .await;
            result.map_err(|error| failures.record(error, attempt))
        };
        let mode = input
            .extensions()
            .get_ref::<ConnectIpMode>()
            .copied()
            .unwrap_or_default();
        let raced = if let Ok(ip) = target.host.try_as_ip() {
            let ip = mode
                .validate_ip(ip)
                .map_err(|error| ConnectionError::local(error, InvalidInput))?;
            race_connect(
                stream::once(async move { Ok(SocketAddr::new(ip, target.port)) }),
                1,
                dial,
            )
            .await
        } else {
            let domain = target.host.try_as_domain().map_err(|_error| {
                ConnectionError::local(
                    BoxError::from_static_str("unsupported QUIC target host"),
                    InvalidInput,
                )
            })?;
            let candidates = input
                .extensions()
                .get_ref::<ConnectorTargetStream>()
                .filter(|c| c.domain() == domain.as_ref())
                .ok_or_else(|| {
                    ConnectionError::local(
                        BoxError::from_static_str(
                            "QUIC domain targets require an outer DNS connector",
                        ),
                        InvalidInput,
                    )
                })?;
            // Resolution policy chooses which records to query; connection
            // policy independently constrains every result, including custom
            // candidate sources and IPv4-mapped IPv6 answers.
            let addresses = candidates.stream(input.extensions()).map(|result| {
                result.and_then(|ip| {
                    mode.validate_ip(ip)
                        .map(|ip| SocketAddr::new(ip, target.port))
                        .map_err(|error| ConnectionError::local(error, InvalidInput).into())
                })
            });
            race_connect(addresses, MAX_IN_FLIGHT_CONNECT_ATTEMPTS, dial).await
        };
        raced
            .map(|(_address, (_endpoint, connection))| connection)
            .map_err(|error| {
                failures
                    .finish(error)
                    .context("QUIC connection establishment")
            })
    }
}

impl<E> Service<ConnectRequest> for QuicConnector<E>
where
    E: ConnectorService<ConnectRequest, Connection = ClientEndpoint>,
{
    type Output = EstablishedClientConnection<Connection, ConnectRequest>;
    type Error = ConnectionError;

    async fn serve(&self, input: ConnectRequest) -> Result<Self::Output, Self::Error> {
        let route = input.extensions().get_ref::<ProxyRoute>().cloned();
        let proxy = route.as_ref().and_then(ProxyRoute::proxy_address).cloned();
        let prepared = self.prepare(&input)?;
        // Keep QUIC address-race and handshake state out of enclosing pool and
        // service-selection futures.
        let (connection, established) = match (&route, proxy) {
            (Some(route), Some(proxy)) if route.addresses_proxy(&input.authority) => (
                Box::pin(self.connect_direct(&input, &prepared)).await?,
                Some(EstablishedProxyRoute::Forward(proxy)),
            ),
            (_, Some(proxy)) => {
                let (connection, route) =
                    Box::pin(self.connect_through(&input, &prepared, &proxy)).await?;
                (connection, Some(route))
            }
            (Some(_), None) => (
                Box::pin(self.connect_direct(&input, &prepared)).await?,
                Some(EstablishedProxyRoute::Direct),
            ),
            (None, None) => (
                Box::pin(self.connect_direct(&input, &prepared)).await?,
                None,
            ),
        };
        // Populate only connection facts: inheriting the request store here would
        // retain request metadata and could create a cycle through Egress.
        let extensions = connection.extensions();
        prepared.reuse.publish(extensions);
        extensions.insert(prepared.alpn_policy);
        extensions.insert(TlsServerAuthentication(prepared.authenticated_identity));
        extensions.insert(prepared.policy_scope);
        if let Some(established) = established {
            extensions.insert(established);
        }
        Ok(EstablishedClientConnection {
            input,
            conn: connection,
        })
    }
}

// Keep the first terminal failure when a later address merely times out. An
// authentication failure takes precedence, including when an outer speculative
// deadline cancels the race. Only failed dials acquire this lock or share errors.
#[derive(Default)]
struct ConnectFailures(Mutex<Option<ConnectionError>>);

impl ConnectFailures {
    fn record(&self, error: BoxError, attempt: &ConnectionAttempt) -> BoxError {
        let (domain, kind) = classify_connect_error(error.as_ref());
        if domain == Transport && matches!(kind, Unavailable | Timeout) {
            return error;
        }
        attempt.reject_with_kind(kind);
        let mut terminal = self.0.lock();
        if terminal.is_none() || kind == Authentication {
            let error = ArcError::from_box_error(error);
            *terminal = Some(ConnectionError::new(error.clone(), domain, kind));
            return error.into();
        }
        error
    }

    fn finish(&self, error: BoxError) -> ConnectionError {
        self.0.lock().take().unwrap_or_else(|| {
            let (domain, kind) = classify_connect_error(error.as_ref());
            ConnectionError::new(error, domain, kind)
        })
    }
}

// RFC 7301 §3.2: negotiation failed because the peer supports no offered ALPN.
const TLS_NO_APPLICATION_PROTOCOL: u8 = 120;

// Classify QUIC address-race failures at the transport boundary. Generic service selection
// consumes ConnectionError classifications, never QUIC errors.
fn classify_connect_error(
    error: &(dyn StdError + 'static),
) -> (ConnectionErrorDomain, ConnectionErrorKind) {
    for error in error_chain(error) {
        if let Some(error) = error.downcast_ref::<ConnectionError>() {
            return (error.domain(), error.kind());
        }
        if let Some(error) = error.downcast_ref::<QuicConnectionError>() {
            return match error {
                QuicConnectionError::TimedOut => (Transport, Timeout),
                QuicConnectionError::VersionMismatch { .. } | QuicConnectionError::Reset => {
                    (Transport, Unavailable)
                }
                QuicConnectionError::ApplicationClosed(_) => (Application, Rejected),
                QuicConnectionError::CidsExhausted
                | QuicConnectionError::EndpointInUse
                | QuicConnectionError::LocallyClosed => (Local, Unavailable),
                QuicConnectionError::TransportError(error) => classify_transport_code(error.code),
                QuicConnectionError::ConnectionClosed(error) => {
                    classify_transport_code(error.error_code)
                }
            };
        }
        if let Some(error) = error.downcast_ref::<QuicConnectError>() {
            return match error {
                QuicConnectError::EndpointStopping
                | QuicConnectError::CidsExhausted
                | QuicConnectError::EndpointInUse => (Local, Unavailable),
                QuicConnectError::Crypto(error) => classify_transport_code(error.code),
                QuicConnectError::InvalidRemoteAddress(address)
                    if address.port() != 0 && !address.ip().is_unspecified() =>
                {
                    // A valid address may have an unsupported family for the
                    // configured endpoint. Other candidates can still work.
                    (Transport, Unavailable)
                }
                _ => (Local, InvalidInput),
            };
        }
        if let Some(error) = error.downcast_ref::<IoError>() {
            return match error.kind() {
                IoErrorKind::TimedOut => (Transport, Timeout),
                IoErrorKind::ConnectionRefused
                | IoErrorKind::ConnectionReset
                | IoErrorKind::ConnectionAborted
                | IoErrorKind::NetworkUnreachable
                | IoErrorKind::HostUnreachable => (Transport, Unavailable),
                _ => (Local, Internal),
            };
        }
    }
    // DNS streams may finish without an address or return resolver-specific errors.
    (Transport, Unavailable)
}

fn classify_transport_code(
    code: TransportErrorCode,
) -> (ConnectionErrorDomain, ConnectionErrorKind) {
    if code == TransportErrorCode::CONNECTION_REFUSED {
        (Transport, Unavailable)
    } else if code.tls_alert() == Some(TLS_NO_APPLICATION_PROTOCOL) {
        (Application, ProtocolError)
    } else if code.tls_alert().is_some() {
        // TLS alerts include certificate failures; fail closed across speculative races.
        (Application, Authentication)
    } else {
        (Application, ProtocolError)
    }
}
