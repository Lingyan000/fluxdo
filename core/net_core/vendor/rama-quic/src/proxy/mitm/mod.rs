//! Terminate a peeked QUIC association and the matching origin connection.
//!
//! Ingress and egress are independent QUIC connections: transport settings, RTT estimation
//! and optional spin signaling belong to each hop. Spin bits are not copied across them.

use std::{sync::Arc, time::Duration};

use parking_lot::Mutex;
use rama_core::{
    Layer, Service,
    error::{BoxError, BoxErrorExt as _},
    extensions::{Extensions, ExtensionsRef},
    io::BridgeIo,
    rt::Executor,
    telemetry::tracing,
};
use rama_crypto::{
    dep::boring::{
        ssl::{
            AsyncSelectCertError, BoxCertificateFinish, CertificateSelection, GreaseValues,
            SelectCertError, SslCredential, SslRef, UnknownValues,
        },
        x509::X509,
    },
    pki_types::{CertificateDer, PrivateKeyDer},
};
use rama_net::{
    address::Host,
    client::ConnectorTarget,
    http::{TargetHttpVersion, Version},
    tls::ApplicationProtocol,
};
use rama_quic_proto::{
    ConnectionId, Side, VarInt,
    capture::{CaptureLimits, RawParameter, transport_parameters_iter_from_hello},
    coding::{BufExt, Codec as _},
    crypto::CryptoError,
    peek::PeekedClientHello,
    profile::{
        ConnectionIdProfile, InitialFlightLayout, PacketizationProfile, QuicProfile,
        TransportLimits, TransportParameterProfile, initial::RecordedInitialFlight,
    },
    transport_parameters::{TransportParameterId, TransportParameters},
    version::{ClientVersionPolicy, ReservedVersionGrease},
};
#[cfg(test)]
use rama_tls::client::ClientHello;
use rama_tls::{
    client::TlsClientConfig,
    server::{ServerAuthData, TlsServerConfig},
};
use rama_tls_boring::client::{BoringClientConfigExt as _, ServerAnswerRecorder};
use rama_tls_boring::proxy::{
    cert_issuer::BoringMitmCertIssuer,
    client_auth::{
        TlsMitmCertificateRequest, TlsMitmClientAuthInput, TlsMitmClientAuthPlan,
        TlsMitmClientAuthPolicy, TlsMitmClientIdentity,
    },
};
use rama_udp::DatagramSocket;
use rama_utils::{guard::DropGuard, octets};
use tokio::{
    sync::oneshot,
    time::{Instant, timeout_at},
};

use super::InputWithQuicClientHello;
use crate::{
    ClientConfig, Connecting, Connection, ConnectionError, Endpoint, EndpointConfig,
    IncomingOutcome, NegotiatedTlsParameters, ServerConfig, TransportConfig,
    proto::ServerCrypto,
    proto::crypto::{
        self,
        boring::{
            HandshakeInitializer, SharedClientSessions, on_handshake_completed, retry_tag,
            server_config_from_rama, server_initial_keys,
        },
    },
    tls::{BoringTlsProvider, TlsOptions},
};

/// The default for [`QuicMitmRelay::with_handshake_timeout`].
pub const DEFAULT_QUIC_MITM_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);

/// What a mirrored client may make the relay hold on its egress connection
/// ([`QuicMitmRelay::with_mirror_client`]): larger receive windows and stream counts are
/// lowered to these, and the change is traced.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QuicMirrorCeiling {
    /// The connection receive window (`initial_max_data`).
    pub max_data: u64,
    /// Each stream receive window (`initial_max_stream_data_*`).
    pub max_stream_data: u64,
    /// Each stream count (`initial_max_streams_*`).
    pub max_streams: u64,
}

impl Default for QuicMirrorCeiling {
    fn default() -> Self {
        Self {
            max_data: octets::mib_u64(32),
            max_stream_data: octets::mib_u64(16),
            max_streams: 256,
        }
    }
}

impl QuicMirrorCeiling {
    /// Clamp `limits` to this ceiling, and its idle timeout to `idle` (the relay's own, which a
    /// client may shorten but never lift or disable); whether anything changed.
    fn bound(&self, limits: &mut TransportLimits, idle: Option<Duration>) -> bool {
        let before = limits.clone();
        let clamp = |value: &mut u64, ceiling: u64| *value = (*value).min(ceiling);
        clamp(&mut limits.initial_max_data, self.max_data);
        clamp(
            &mut limits.initial_max_stream_data_bidi_local,
            self.max_stream_data,
        );
        clamp(
            &mut limits.initial_max_stream_data_bidi_remote,
            self.max_stream_data,
        );
        clamp(
            &mut limits.initial_max_stream_data_uni,
            self.max_stream_data,
        );
        clamp(&mut limits.initial_max_streams_bidi, self.max_streams);
        clamp(&mut limits.initial_max_streams_uni, self.max_streams);
        if let Some(idle) = idle
            && (limits.max_idle_timeout.is_zero() || limits.max_idle_timeout > idle)
        {
            limits.max_idle_timeout = idle;
        }
        *limits != before
    }
}

/// Terminates a QUIC association whose ClientHello was peeked, using the egress socket the
/// producer prepared for its origin: the QUIC counterpart of the TLS MITM relay.
///
/// The client's attempt is admitted on the ingress socket first, by default only once a Retry
/// validated its address, and only if it carries the ClientHello that was peeked. Then the
/// origin handshake runs over the egress socket, with the client's QUIC version, server name
/// and the offered protocols the egress TLS configuration allows, in the client's order. The
/// origin's certificate is mirrored by the [`BoringMitmCertIssuer`], and the client is accepted
/// with it and the protocol the origin selected; a failure refuses the client. No origin
/// handshake or issuance runs for an unvalidated address. The inner service owns both
/// established connections; this service closes them only when establishment fails. Early
/// data is disabled on both hops, so a client's 0-RTT is rejected and resent after the
/// handshake. All of it shares one deadline, fixed when `serve` is called.
///
/// The origin sees the client's own first flight as far as this relay can reproduce it; see
/// [`Self::with_mirror_client`].
///
/// An origin requesting a client certificate is answered by the [`TlsMitmClientAuthPolicy`]
/// (a flow's own extension overrides the relay's): its plan configures the ingress handshake,
/// and its credential is released to the origin only once that handshake completed, with
/// proof of possession of any certificate the client presented. Without a policy, a
/// certificate request fails the association.
///
/// Destination selection is the producer's: this service dials nothing but the egress socket's
/// peer, and the received server name never changes where traffic goes.
#[derive(Debug, Clone)]
pub struct QuicMitmRelay<Issuer> {
    issuer: Issuer,
    exec: Executor,
    egress_tls: TlsClientConfig,
    ingress_transport: Arc<TransportConfig>,
    egress_transport: Arc<TransportConfig>,
    handshake_timeout: Duration,
    validate_address: bool,
    failure_code: VarInt,
    client_auth: Option<TlsMitmClientAuthPolicy>,
    mirror_client: bool,
    mirror_ceiling: QuicMirrorCeiling,
}

impl<Issuer> QuicMitmRelay<Issuer> {
    /// Verify origins with `egress_tls`, whose ALPN list (when set) bounds what is offered
    /// upstream, and close failed associations with application error `failure_code`.
    /// Datagrams are disabled on both hops until both transports enable them.
    pub fn new(
        issuer: Issuer,
        exec: Executor,
        egress_tls: TlsClientConfig,
        failure_code: VarInt,
    ) -> Self {
        // Datagrams stay off until both hops are configured for them: advertising them on one
        // hop only would promise what the relay cannot carry.
        let transport =
            Arc::new(TransportConfig::default().maybe_with_datagram_receive_buffer_size(None));
        Self {
            issuer,
            exec,
            egress_tls,
            ingress_transport: transport.clone(),
            egress_transport: transport,
            handshake_timeout: DEFAULT_QUIC_MITM_HANDSHAKE_TIMEOUT,
            validate_address: true,
            failure_code,
            client_auth: None,
            mirror_client: true,
            mirror_ceiling: QuicMirrorCeiling::default(),
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Whether the origin sees the client's own first flight instead of the egress
        /// configuration's (default: on). The ClientHello is mirrored without values the
        /// native TLS engine cannot negotiate and with GREASE codepoints pinned, the configured
        /// egress TLS layered over it (its trust and every setting it names win); the
        /// transport parameters keep
        /// the client's order, greased parameter, extra parameters and limits, while
        /// connection IDs stay fresh. Receive windows, stream counts and the idle timeout are
        /// lowered to [`Self::with_mirror_ceiling`] and the egress transport's idle timeout,
        /// and a datagram parameter is dropped unless both transports carry datagrams. A
        /// ClientHello or transport profile this relay cannot reproduce (including one whose
        /// peek did not retain the Initial structure) falls back to the egress configuration
        /// for that layer. Every change is traced.
        pub fn mirror_client(mut self, mirror: bool) -> Self {
            self.mirror_client = mirror;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// The most a mirrored client may make the relay hold on its egress connection.
        pub fn mirror_ceiling(mut self, ceiling: QuicMirrorCeiling) -> Self {
            self.mirror_ceiling = ceiling;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// The client-authentication policy for origins requesting a certificate. A flow's
        /// own [`TlsMitmClientAuthPolicy`] extension overrides it.
        pub fn client_auth(mut self, policy: Option<TlsMitmClientAuthPolicy>) -> Self {
            self.client_auth = policy;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Transport limits advertised to the client.
        pub fn ingress_transport(mut self, transport: Arc<TransportConfig>) -> Self {
            self.ingress_transport = transport;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Transport limits advertised to the origin.
        pub fn egress_transport(mut self, transport: Arc<TransportConfig>) -> Self {
            self.egress_transport = transport;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// The budget for both handshakes and certificate issuance, from `serve`. Defaults to
        /// [`DEFAULT_QUIC_MITM_HANDSHAKE_TIMEOUT`].
        pub fn handshake_timeout(mut self, timeout: Duration) -> Self {
            self.handshake_timeout = timeout;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// Whether a Retry validates the client's address before any origin work runs (the
        /// default). Without it, a spoofed first flight costs an origin handshake and issuance.
        pub fn validate_address(mut self, validate: bool) -> Self {
            self.validate_address = validate;
            self
        }
    }
}

impl<Issuer: Clone, S> Layer<S> for QuicMitmRelay<Issuer> {
    type Service = QuicMitmRelayService<Issuer, S>;

    fn layer(&self, inner: S) -> Self::Service {
        QuicMitmRelayService {
            relay: self.clone(),
            inner,
        }
    }

    fn into_layer(self, inner: S) -> Self::Service {
        QuicMitmRelayService { relay: self, inner }
    }
}

/// The service a [`QuicMitmRelay`] layer produces.
#[derive(Debug, Clone)]
pub struct QuicMitmRelayService<Issuer, S> {
    relay: QuicMitmRelay<Issuer>,
    inner: S,
}

impl<Issuer, S, Ingress, Egress> Service<InputWithQuicClientHello<BridgeIo<Ingress, Egress>>>
    for QuicMitmRelayService<Issuer, S>
where
    Issuer: BoringMitmCertIssuer<Error: Into<BoxError>> + Clone,
    S: Service<BridgeIo<Connection, Connection>, Error: Into<BoxError>>,
    Ingress: DatagramSocket + ExtensionsRef,
    Egress: DatagramSocket,
{
    type Output = S::Output;
    type Error = BoxError;

    fn serve(
        &self,
        input: InputWithQuicClientHello<BridgeIo<Ingress, Egress>>,
    ) -> impl Future<Output = Result<S::Output, BoxError>> + Send + '_ {
        // Fixed at hand-over, so a late first poll cannot renew the budget.
        let deadline = Instant::now() + self.relay.handshake_timeout;
        async move {
            let established = timeout_at(deadline, self.relay.establish(input))
                .await
                .map_err(|_elapsed| {
                    BoxError::from_static_str("QUIC MITM handshake deadline exceeded")
                })??;
            let Established {
                ingress,
                egress,
                endpoints,
            } = established;
            // One association relays one connection; its origin mirrors only that client.
            // Another attempt on the same socket is refused at once instead of being left
            // to its handshake timeout, so the client can fall back promptly.
            let refuse_more = async {
                while let Some(incoming) = endpoints[0].accept().await {
                    tracing::debug!(
                        remote = %incoming.remote_address(),
                        "QUIC MITM refuses another connection on an established association"
                    );
                    incoming.refuse();
                }
                // A closed endpoint has nothing left to refuse; the service decides the end.
                std::future::pending::<Result<S::Output, S::Error>>().await
            };
            let result = tokio::select! {
                result = self.inner.serve(BridgeIo(ingress, egress)) => result,
                result = refuse_more => result,
            };
            // The endpoints drive both connections until the inner service is done with them.
            drop(endpoints);
            result.map_err(Into::into)
        }
    }
}

struct Established {
    ingress: Connection,
    egress: Connection,
    endpoints: [Endpoint; 2],
}

impl<Issuer: BoringMitmCertIssuer<Error: Into<BoxError>> + Clone> QuicMitmRelay<Issuer> {
    async fn establish<Ingress, Egress>(
        &self,
        InputWithQuicClientHello {
            input: BridgeIo(ingress, egress),
            peeked,
        }: InputWithQuicClientHello<BridgeIo<Ingress, Egress>>,
    ) -> Result<Established, BoxError>
    where
        Ingress: DatagramSocket + ExtensionsRef,
        Egress: DatagramSocket,
    {
        let hello = &peeked.client_hello;
        if hello.ext_alpn().is_none() {
            return Err(BoxError::from_static_str("QUIC ClientHello offers no ALPN"));
        }
        let server_name = match hello.ext_server_name() {
            Some(name) => Host::Name(name.clone()),
            None => ingress
                .extensions()
                .get_ref::<ConnectorTarget>()
                .map(|target| target.0.host.clone())
                .ok_or_else(|| {
                    BoxError::from_static_str("QUIC MITM needs a server name or a target")
                })?,
        };

        // Flow extensions are only cloned when a policy will receive them.
        let client_auth = ingress
            .extensions()
            .get_ref::<TlsMitmClientAuthPolicy>()
            .cloned()
            .or_else(|| self.client_auth.clone())
            .map(|policy| (policy, ingress.extensions().clone()));

        let origin = Arc::new(Mutex::new(None::<Origin>));
        let failure_code = self.failure_code;
        // An origin reached for a client that is not accepted after all learns why. One paused
        // at its certificate request fails there, as its credential reply is dropped.
        let mut close_origin = DropGuard::new({
            let origin = origin.clone();
            move || {
                if let Some(Origin {
                    connection: OriginConnection::Established(connection),
                    ..
                }) = origin.lock().take()
                {
                    connection.close(failure_code, b"QUIC MITM establishment failed");
                }
            }
        });
        let mut server = ServerConfig::with_resolver(Arc::new(OriginResolver {
            relay: self.clone(),
            peeked,
            server_name,
            client_auth,
            egress: Mutex::new(Some(egress)),
            origin: origin.clone(),
        }));
        server.set_transport_config(self.ingress_transport.clone());
        let ingress_endpoint = Endpoint::build(self.exec.clone())
            .with_server_config(server)
            .with_datagram_socket(ingress)?;
        let ingress_connection = loop {
            let incoming = ingress_endpoint.accept().await.ok_or_else(|| {
                BoxError::from_static_str("QUIC MITM ingress closed before accept")
            })?;
            if !self.validate_address {
                break incoming.await?;
            }
            match incoming.accept_or_retry().await? {
                IncomingOutcome::Accepted(connection) => break connection,
                IncomingOutcome::Retried => {}
            }
        };
        let mut close_ingress = close_on_drop(&ingress_connection, failure_code);
        let (negotiated, client_auth) = {
            let mut origin = origin.lock();
            let origin = origin.as_mut().ok_or_else(|| {
                BoxError::from_static_str("QUIC MITM accepted a client without its origin")
            })?;
            (origin.negotiated.clone(), origin.client_auth.take())
        };
        let negotiated = negotiated
            .ok_or_else(|| BoxError::from_static_str("QUIC origin negotiated no ALPN"))?;
        if ingress_connection
            .extensions()
            .get_ref::<NegotiatedTlsParameters>()
            .and_then(|tls| tls.application_layer_protocol.as_ref())
            != Some(&negotiated)
        {
            return Err(BoxError::from_static_str(
                "QUIC MITM ingress ALPN differs from the origin's",
            ));
        }
        if let Some(client_auth) = client_auth {
            client_auth.release().await?;
        }
        let Origin {
            connection,
            endpoint: egress_endpoint,
            ..
        } = origin.lock().take().ok_or_else(|| {
            BoxError::from_static_str("QUIC MITM accepted a client without its origin")
        })?;
        close_origin.disarm();
        let egress_connection = match connection {
            OriginConnection::Established(connection) => connection,
            OriginConnection::AwaitingCredential(connecting) => (*connecting).await?,
        };
        let mut close_egress = close_on_drop(&egress_connection, failure_code);

        // As the TLS relay does: the HTTP version the origin agreed to, for the inner service.
        if let Ok(version) = Version::try_from(&negotiated) {
            egress_connection
                .extensions()
                .insert(TargetHttpVersion(version));
        }
        close_ingress.disarm();
        close_egress.disarm();
        Ok(Established {
            ingress: ingress_connection,
            egress: egress_connection,
            endpoints: [ingress_endpoint, egress_endpoint],
        })
    }
}

/// The origin of one association, reached for the client attempt its ingress admitted.
struct Origin {
    connection: OriginConnection,
    endpoint: Endpoint,
    negotiated: Option<ApplicationProtocol>,
    /// Taken once the ingress handshake, which the plan configured, completed.
    client_auth: Option<ClientAuthExchange>,
}

enum OriginConnection {
    Established(Connection),
    /// Paused at the origin's certificate request until the ingress client authenticated.
    AwaitingCredential(Box<Connecting>),
}

/// An origin's certificate request, seen from its paused handshake.
struct CertificateRequested {
    leaf: X509,
    alpn: Option<ApplicationProtocol>,
    request: TlsMitmCertificateRequest,
    reply: oneshot::Sender<Option<SslCredential>>,
}

/// The policy's plan for one association, and the origin's request it answers, if any.
struct ClientAuthExchange {
    plan: TlsMitmClientAuthPlan,
    reply: Option<oneshot::Sender<Option<SslCredential>>>,
    /// Filled by the ingress handshake once it completed.
    identity: Arc<Mutex<Option<TlsMitmClientIdentity>>>,
}

impl ClientAuthExchange {
    /// Resolve the egress credential for the identity the completed ingress handshake proved,
    /// and release it to the origin.
    async fn release(self) -> Result<(), BoxError> {
        // Ingress contexts live for one association, so no session resumes into it.
        let identity = self.identity.lock().take().ok_or_else(|| {
            BoxError::from_static_str("QUIC MITM ingress handshake has not completed")
        })?;
        let credential = self.plan.into_resolver().serve(identity).await?;
        match self.reply {
            Some(reply) => reply.send(credential).map_err(|_credential| {
                BoxError::from_static_str("QUIC MITM origin handshake closed before its credential")
            }),
            None if credential.is_some() => Err(BoxError::from_static_str(
                "QUIC MITM credential supplied without an origin request",
            )),
            None => Ok(()),
        }
    }
}

/// Apple keeps structured fields private; expose only a static refusal class.
fn origin_refusal(class: &'static str, error: impl Into<BoxError>) -> BoxError {
    tracing::warn!("QUIC MITM origin refused: {class}");
    error.into()
}

/// Only protocol-defined codes and static kinds are public, never peer reasons.
fn origin_handshake_refusal(error: ConnectionError) -> BoxError {
    let (kind, code) = match &error {
        ConnectionError::VersionMismatch { .. } => ("version-mismatch", None),
        ConnectionError::TransportError(error) => ("transport", Some(u64::from(error.code))),
        ConnectionError::ConnectionClosed(error) => {
            ("peer-transport", Some(u64::from(error.error_code)))
        }
        ConnectionError::ApplicationClosed(_) => ("application-closed", None),
        ConnectionError::Reset => ("reset", None),
        ConnectionError::TimedOut => ("timed-out", None),
        ConnectionError::LocallyClosed => ("locally-closed", None),
        ConnectionError::CidsExhausted => ("cids-exhausted", None),
        ConnectionError::EndpointInUse => ("endpoint-in-use", None),
    };
    match code {
        Some(code) if (0x100..0x200).contains(&code) => {
            tracing::warn!("QUIC MITM origin refused: origin-handshake:{kind}-crypto-0x{code:x}");
        }
        Some(code) => {
            tracing::warn!("QUIC MITM origin refused: origin-handshake:{kind}-0x{code:x}");
        }
        None => {
            tracing::warn!("QUIC MITM origin refused: origin-handshake:{kind}");
        }
    }
    error.into()
}

/// Resolves the ingress configuration of one association. The endpoint asks only for the
/// attempt it admits, and runs the work (the origin handshake and certificate issuance) only
/// after any Retry validated the client's address.
struct OriginResolver<Issuer, Egress> {
    relay: QuicMitmRelay<Issuer>,
    peeked: PeekedClientHello,
    server_name: Host,
    client_auth: Option<(TlsMitmClientAuthPolicy, Extensions)>,
    egress: Mutex<Option<Egress>>,
    origin: Arc<Mutex<Option<Origin>>>,
}

impl<Issuer, Egress> OriginResolver<Issuer, Egress>
where
    Issuer: BoringMitmCertIssuer<Error: Into<BoxError>> + Clone,
    Egress: DatagramSocket,
{
    async fn reach_origin(&self) -> Result<Arc<dyn crypto::ServerConfig>, BoxError> {
        let egress = self.egress.lock().take().ok_or_else(|| {
            origin_refusal(
                "egress-unavailable",
                BoxError::from_static_str("QUIC MITM origin already reached"),
            )
        })?;
        let (exchange, requested) = if self.client_auth.is_some() {
            // A resumed origin session would reuse an earlier client's authentication.
            if self
                .relay
                .egress_tls
                .as_extensions()
                .get_ref::<SharedClientSessions>()
                .is_some()
            {
                return Err(origin_refusal(
                    "client-auth-configuration",
                    BoxError::from_static_str(
                        "QUIC MITM client auth: shared egress sessions can bypass authentication",
                    ),
                ));
            }
            let (request_tx, request_rx) = oneshot::channel();
            (
                Some(Arc::new(Mutex::new(Some(request_tx)))),
                Some(request_rx),
            )
        } else {
            (None, None)
        };
        let answer = Arc::new(Mutex::new(None::<ServerAnswerRecorder>));
        let observed = answer.clone();
        let initializer = HandshakeInitializer(Arc::new(move |ssl: &mut SslRef| {
            *observed.lock() = Some(ServerAnswerRecorder::of(ssl)?);
            match &exchange {
                Some(exchange) => pause_at_certificate_request(ssl, exchange.clone()),
                None => ssl.set_certificate_callback(|_| Err(SelectCertError::ERROR)),
            }
            Ok(())
        }));
        let offered = self.peeked.client_hello.ext_alpn().unwrap_or_default();
        let client_config = |mut tls: TlsClientConfig| {
            // The client's order, bounded by what the egress configuration allows.
            let allowed = match self.relay.egress_tls.alpn() {
                Some(configured) => offered
                    .iter()
                    .filter(|protocol| configured.0.contains(protocol))
                    .cloned()
                    .collect(),
                None => offered.iter().cloned().collect(),
            };
            tls.set_alpn(allowed);
            // The mirrored certificate is built from the origin's leaf.
            tls.set_store_server_cert_chain(true);
            tls.insert(initializer.clone());
            ClientConfig::try_from_rama_tls_with_provider(
                &tls,
                TlsOptions::default(),
                &BoringTlsProvider,
            )
        };
        // The configured egress TLS layers over the mirror: its trust and every
        // setting it names win.
        let mirrored = self.relay.mirror_client.then(|| {
            tracing::debug!(
                "QUIC MITM mirrors the ClientHello without values the native engine cannot negotiate"
            );
            client_config(
                TlsClientConfig::new_from_client_hello(&self.peeked.client_hello)
                    .with_unknown_values(UnknownValues::Drop)
                    .with_grease_values(GreaseValues::Pinned)
                    .with_overrides(self.relay.egress_tls.as_extensions()),
            )
        });
        let mut client = match mirrored {
            Some(Ok(client)) => client,
            mirrored => {
                if let Some(Err(error)) = mirrored {
                    tracing::debug!(%error, "QUIC MITM uses the egress ClientHello: client's is not reproducible");
                }
                client_config(self.relay.egress_tls.clone())
                    .map_err(|error| origin_refusal("egress-tls-configuration", error))?
            }
        };
        let mirrored = self.relay.mirror_client.then(|| {
            let profile = mirrored_profile(
                &self.relay.egress_transport,
                self.relay
                    .ingress_transport
                    .datagram_receive_buffer_size
                    .is_some(),
                &self.relay.mirror_ceiling,
                &self.peeked,
            )?;
            let transport = TransportConfig::clone(&self.relay.egress_transport)
                .try_with_quic_profile(&profile)?;
            let mut endpoint = EndpointConfig::try_with_rand_key()?;
            endpoint.apply_quic_profile(&profile)?;
            // Last, as a rejected profile leaves the client unchanged: includes a fresh
            // destination CID of the requested length and the validated version policy.
            client.apply_quic_profile(&profile)?;
            Ok::<_, BoxError>((transport, endpoint))
        });
        let endpoint_config = if let Some(Ok((transport, endpoint))) = mirrored {
            // Preserve the caller's other transport configuration.
            client.set_transport_config(Arc::new(transport));
            Some(endpoint)
        } else {
            if let Some(Err(error)) = mirrored {
                tracing::debug!(%error, "QUIC MITM uses the egress transport: client's is not reproducible");
            }
            client.set_transport_config(self.relay.egress_transport.clone());
            client
                .set_version(self.peeked.version)
                .map_err(|error| origin_refusal("transport-configuration", error))?;
            None
        };

        let origin = egress
            .peer_addr()
            .map_err(|error| origin_refusal("origin-address", error))?;
        // QUIC bit greasing and the payload limit are endpoint-wide; a mirroring egress
        // advertises them as its client did.
        let endpoint = Endpoint::build(self.relay.exec.clone())
            .maybe_with_config(endpoint_config)
            .with_datagram_socket(egress)
            .map_err(|error| origin_refusal("origin-endpoint", error))?;
        let mut connecting = endpoint
            .connect_with(client, origin.into(), &self.server_name.to_string())
            .map_err(|error| origin_refusal("origin-connect", error))?;
        let (connection, negotiated, origin_leaf, request) = if let Some(requested) = requested {
            tokio::select! {
                biased;
                // The callback can report a request and fail in the same poll.
                connection = &mut connecting => {
                    let connection = connection.map_err(origin_handshake_refusal)?;
                    let (negotiated, leaf) = established_origin(&connection).map_err(|error| origin_refusal("origin-certificate", error))?;
                    (OriginConnection::Established(connection), negotiated, leaf, None)
                }
                requested = requested => {
                    let requested = requested.map_err(|_closed| {
                        origin_refusal("origin-handshake:credential-channel-closed", BoxError::from_static_str("QUIC MITM origin handshake closed"))
                    })?;
                    (
                        OriginConnection::AwaitingCredential(Box::new(connecting)),
                        requested.alpn.clone(),
                        requested.leaf.clone(),
                        Some(requested),
                    )
                }
            }
        } else {
            let connection = connecting.await.map_err(origin_handshake_refusal)?;
            let (negotiated, leaf) = established_origin(&connection)
                .map_err(|error| origin_refusal("origin-certificate", error))?;
            (
                OriginConnection::Established(connection),
                negotiated,
                leaf,
                None,
            )
        };
        // Held from here, so a failure ends the origin.
        *self.origin.lock() = Some(Origin {
            connection,
            endpoint,
            negotiated: negotiated.clone(),
            client_auth: None,
        });
        let negotiated = negotiated.ok_or_else(|| {
            origin_refusal(
                "origin-missing-alpn",
                BoxError::from_static_str("QUIC origin negotiated no ALPN"),
            )
        })?;

        let mirror = answer
            .lock()
            .as_ref()
            .map(|recorder| {
                recorder.mirror_for(Some(self.peeked.client_hello.cipher_suites()), true)
            })
            .unwrap_or_default();
        let mut server_tls = TlsServerConfig::new();
        let authenticates = if let Some((policy, extensions)) = &self.client_auth {
            let (request, reply) = match request {
                Some(CertificateRequested { request, reply, .. }) => (Some(request), Some(reply)),
                None => (None, None),
            };
            let plan = policy
                .serve(TlsMitmClientAuthInput {
                    request,
                    extensions: extensions.clone(),
                    server_name: Some(self.server_name.clone()),
                    server_certificate: origin_leaf.clone(),
                })
                .await
                .map_err(|error| origin_refusal("client-auth-policy", error))?;
            if let Some(origin) = self.origin.lock().as_mut() {
                origin.client_auth = Some(ClientAuthExchange {
                    plan,
                    reply,
                    identity: Arc::default(),
                });
            }
            true
        } else {
            false
        };
        // Configures the one ingress handshake this association accepts: the origin's answer
        // mirrored, and the client-auth plan.
        let origin = self.origin.clone();
        server_tls.insert(HandshakeInitializer(Arc::new(move |ssl: &mut SslRef| {
            mirror.apply(ssl);
            if !authenticates {
                return Ok(());
            }
            let mut origin = origin.lock();
            let exchange = origin
                .as_mut()
                .and_then(|origin| origin.client_auth.as_mut())
                .ok_or_else(|| {
                    BoxError::from_static_str("QUIC MITM client auth plan already released")
                })?;
            exchange.plan.configure_ingress(ssl)?;
            // Only a completed handshake proves the identity the policy resolves.
            let identity = exchange.identity.clone();
            on_handshake_completed(ssl, move |ssl| {
                *identity.lock() = TlsMitmClientIdentity::from_completed_handshake(ssl);
            })
        })));

        let issued = self
            .relay
            .issuer
            .issue_mitm_x509_cert(origin_leaf)
            .await
            .map_err(|error| {
                origin_refusal("certificate-issuance", Into::<BoxError>::into(error))
            })?;
        let mut identity = ServerAuthData::new(
            issued
                .crt_chain
                .iter()
                .map(|cert| cert.to_der().map(CertificateDer::from))
                .collect::<Result<_, _>>()
                .map_err(|error| origin_refusal("issued-identity", error))?,
            PrivateKeyDer::try_from(
                issued
                    .key
                    .private_key_to_der()
                    .map_err(|error| origin_refusal("issued-identity", error))?,
            )
            .map_err(|error| origin_refusal("issued-identity", BoxError::from_static_str(error)))?,
        );
        identity.ocsp = issued.ocsp_staple.map(|bytes| bytes.to_vec());
        server_tls.set_server_auth(identity);
        server_tls.set_alpn([negotiated].into_iter().collect());
        match server_config_from_rama(&server_tls, TlsOptions::default())
            .map_err(|error| origin_refusal("ingress-tls-configuration", error))?
        {
            ServerCrypto::Fixed(config) => Ok(config),
            ServerCrypto::Resolver(_) => Err(origin_refusal(
                "ingress-tls-configuration",
                BoxError::from_static_str("QUIC MITM issued identity resolves per ClientHello"),
            )),
        }
    }
}

impl<Issuer, Egress> crypto::InitialServerConfig for OriginResolver<Issuer, Egress>
where
    Issuer: Send + Sync,
    Egress: Send,
{
    fn initial_keys(
        &self,
        version: rama_quic_proto::Version,
        cid: &ConnectionId,
    ) -> Result<crypto::Keys, crypto::InitialKeysError> {
        server_initial_keys(version, cid)
    }

    fn retry_tag(
        &self,
        version: rama_quic_proto::Version,
        cid: &ConnectionId,
        packet: &[u8],
    ) -> Result<[u8; 16], CryptoError> {
        retry_tag(version, cid, packet)
    }
}

impl<Issuer, Egress> crypto::ServerConfigResolver for OriginResolver<Issuer, Egress>
where
    Issuer: BoringMitmCertIssuer<Error: Into<BoxError>> + Clone,
    Egress: DatagramSocket,
{
    fn resolve(
        self: Arc<Self>,
        client_hello: crypto::ClientHelloMessage,
    ) -> crypto::ServerConfigLookup {
        Box::pin(async move {
            // The attempt the endpoint admits must be the one the routing decision inspected.
            let attempt = client_hello.client_hello();
            let peeked = &self.peeked.client_hello;
            if attempt.ext_server_name() != peeked.ext_server_name()
                || attempt.ext_alpn() != peeked.ext_alpn()
            {
                return Err(origin_refusal(
                    "attempt-mismatch",
                    BoxError::from_static_str(
                        "QUIC MITM attempt differs from the peeked ClientHello",
                    ),
                ));
            }
            Ok(crypto::ServerConfigResolution::Pending(Box::pin(
                async move { self.reach_origin().await },
            )))
        })
    }
}

/// Project retained native facts into validated, executable native connection preferences.
/// No connection identifiers or cryptographic values are copied to the new connection.
fn mirrored_profile(
    base: &TransportConfig,
    ingress_datagrams: bool,
    ceiling: &QuicMirrorCeiling,
    peeked: &PeekedClientHello,
) -> Result<QuicProfile, BoxError> {
    let observed = peeked.first_flight.as_ref().ok_or_else(|| {
        BoxError::from_static_str("QUIC mirroring requires retained Initial structure")
    })?;
    if observed.version != peeked.version {
        return Err(BoxError::from_static_str(
            "retained QUIC version differs from ClientHello attempt",
        ));
    }
    let flight = RecordedInitialFlight::try_from(observed)?;
    let capture_limits = CaptureLimits::default();
    let parameters = transport_parameters_iter_from_hello(&peeked.client_hello, &capture_limits)?;
    let mut body = parameters.as_bytes();
    let mut sent: Vec<_> = parameters
        .require_minimal_encoding()
        .map(|parameter| {
            parameter.map(|(id, value)| RawParameter {
                id,
                value: value.to_vec(),
            })
        })
        .collect::<Result<_, _>>()?;
    // Dropped parameters must still be unique (RFC 9000 §7.4).
    if sent
        .iter()
        .enumerate()
        .any(|(index, parameter)| sent[..index].iter().any(|seen| seen.id == parameter.id))
    {
        return Err(BoxError::from_static_str(
            "client repeats a QUIC transport parameter",
        ));
    }
    // Native parsing also rejects malformed and server-only client parameters. The bounded
    // ordered collection above makes the only raw-value copies; this pass borrows the body.
    let native = TransportParameters::read(Side::Server, &mut body)?;
    let default_ack_delay_exponent = TransportParameters::default().ack_delay_exponent;
    let datagrams = ingress_datagrams && base.datagram_receive_buffer_size.is_some();
    let mut changed = false;
    // Drop what this relay cannot carry on its own connection: extensions and ACK or
    // migration preferences it does not implement, measured or connection-bound values,
    // and datagrams one hop lacks. Every other parameter keeps its order.
    sent.retain(|parameter| {
        let unsupported = match parameter.id {
            TransportParameterId::AckDelayExponent => {
                native.ack_delay_exponent != default_ack_delay_exponent
            }
            TransportParameterId::DisableActiveMigration
            | TransportParameterId::MinAckDelayDraft07 => true,
            TransportParameterId::MaxDatagramFrameSize => !datagrams,
            TransportParameterId::InitialSourceConnectionId => false,
            // An origin may act on an extension it understands and this relay does not.
            id => {
                id.is_observation_only()
                    || id.has_connection_specific_value()
                    || !(id.is_implemented()
                        || id.is_reserved()
                        || id == TransportParameterId::GoogleConnectionOptions)
            }
        };
        if unsupported {
            tracing::debug!(id = ?parameter.id, "QUIC MITM mirror drops a transport parameter");
            changed = true;
        }
        !unsupported
    });
    // Implemented integer values are encoded afresh; a wider client encoding becomes
    // its minimal form. Opaque bodies remain byte-for-byte preferences.
    for parameter in &mut sent {
        if parameter.id.has_native_integer_value() {
            let mut value = parameter.value.as_slice();
            let integer = BufExt::get::<VarInt>(&mut value)?;
            if !value.is_empty() {
                return Err(BoxError::from_static_str(
                    "client transport parameter carries trailing integer bytes",
                ));
            }
            if integer.size() != parameter.value.len() {
                tracing::debug!(id = ?parameter.id, "QUIC MITM mirror encodes an integer minimally");
                parameter.value.clear();
                integer.encode(&mut parameter.value);
                changed = true;
            }
        }
    }
    let parameters = TransportParameterProfile::try_from_sent(&sent)?;
    let mut limits = TransportLimits::try_from_sent(&sent)?;
    let idle = base
        .max_idle_timeout
        .map(|millis| Duration::from_millis(millis.into_inner()));
    if ceiling.bound(&mut limits, idle) {
        tracing::debug!("QUIC MITM mirror lowers client limits to the relay transport ceiling");
        changed = true;
    }
    // A changed ClientHello no longer fits the recorded Initial packet layout.
    let recorded_layout = !changed;
    limits.datagram_receive_buffer_size = parameters
        .max_datagram_frame_size()
        .and(base.datagram_receive_buffer_size);
    let versions = match native.version_information {
        Some(info) if info.chosen() == peeked.version => {
            let mut compatible = Vec::with_capacity(info.available().len());
            let mut grease = ReservedVersionGrease::None;
            let last = info.available().len().saturating_sub(1);
            for (index, &version) in info.available().iter().enumerate() {
                if !version.is_reserved() {
                    compatible.push(version);
                    continue;
                }
                // Native greasing places one reserved version first or last; any
                // other reserved entry is dropped.
                match (grease, index) {
                    (ReservedVersionGrease::None, 0) => grease = ReservedVersionGrease::First,
                    (ReservedVersionGrease::None, index) if index == last => {
                        grease = ReservedVersionGrease::Last;
                    }
                    _ => {
                        tracing::debug!("QUIC MITM mirror drops a reserved QUIC version");
                    }
                }
            }
            match ClientVersionPolicy::new(peeked.version)?.try_with_compatible(compatible) {
                Ok(policy) => policy.with_reserved_version_grease(grease),
                Err(error) => {
                    tracing::debug!(%error, "QUIC MITM mirror drops unusable version_information");
                    ClientVersionPolicy::new(peeked.version)?.try_with_version_information(false)?
                }
            }
        }
        Some(_) => {
            tracing::debug!("QUIC MITM mirror drops version_information naming another version");
            ClientVersionPolicy::new(peeked.version)?.try_with_version_information(false)?
        }
        None => ClientVersionPolicy::new(peeked.version)?.try_with_version_information(false)?,
    };
    let cids = ConnectionIdProfile::standard()
        .try_with_initial_destination_len(flight.destination_cid_len())?
        .try_with_local_len(flight.source_cid_len())?;
    let packetization = if recorded_layout {
        PacketizationProfile::standard().with_layout(InitialFlightLayout::Recorded(flight))
    } else {
        tracing::debug!("QUIC MITM mirror uses standard Initial packetization");
        PacketizationProfile::standard()
    };
    Ok(QuicProfile::standard()
        .with_versions(versions)
        .with_connection_ids(cids)
        .with_transport_parameters(parameters)
        .with_packetization(packetization)
        .try_with_limits(limits)?
        .with_grease_quic_bit(
            sent.iter()
                .any(|parameter| parameter.id == TransportParameterId::GreaseQuicBit),
        ))
}

/// The protocol an established origin negotiated, and the leaf it presented.
fn established_origin(
    connection: &Connection,
) -> Result<(Option<ApplicationProtocol>, X509), BoxError> {
    let tls = connection.extensions().get_ref::<NegotiatedTlsParameters>();
    let negotiated = tls.and_then(|tls| tls.application_layer_protocol.clone());
    let leaf = tls
        .and_then(|tls| tls.peer_certificate_chain.as_deref())
        .and_then(|chain| chain.first())
        .ok_or_else(|| BoxError::from_static_str("QUIC origin presented no certificate"))?;
    Ok((negotiated, X509::from_der(leaf)?))
}

/// Pause the origin handshake at its certificate request: the request is handed out, and the
/// handshake resumes with the credential sent back, or fails when the reply is dropped.
fn pause_at_certificate_request(ssl: &mut SslRef, exchange: Arc<Mutex<Option<RequestSender>>>) {
    ssl.set_async_certificate_callback(move |selection| {
        let request = exchange.lock().take().ok_or(AsyncSelectCertError)?;
        let ssl = selection.ssl();
        let leaf = ssl.peer_certificate().ok_or(AsyncSelectCertError)?;
        let alpn = ssl.selected_alpn_protocol().map(ApplicationProtocol::from);
        let (reply, credential) = oneshot::channel();
        request
            .send(CertificateRequested {
                leaf,
                alpn,
                request: TlsMitmCertificateRequest::from_selection(selection),
                reply,
            })
            .map_err(|_request| AsyncSelectCertError)?;
        Ok(Box::pin(async move {
            let credential = credential.await.map_err(|_closed| AsyncSelectCertError)?;
            Ok(Box::new(move |mut selection: CertificateSelection<'_>| {
                let ssl = selection.ssl_mut();
                ssl.clear_certificates();
                if let Some(credential) = credential {
                    ssl.add_credential(&credential)
                        .map_err(|_error| AsyncSelectCertError)?;
                }
                Ok(())
            }) as BoxCertificateFinish)
        }))
    });
}

type RequestSender = oneshot::Sender<CertificateRequested>;

/// Close `connection` with `failure_code` unless the guard is disarmed on hand-over.
fn close_on_drop(
    connection: &Connection,
    failure_code: VarInt,
) -> DropGuard<impl FnOnce() + use<>> {
    let connection = connection.clone();
    DropGuard::new(move || {
        connection.close(failure_code, b"QUIC MITM establishment failed");
    })
}

#[cfg(test)]
mod tests;
