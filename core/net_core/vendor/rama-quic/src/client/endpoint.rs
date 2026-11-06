use std::{collections::VecDeque, fmt, net::SocketAddr, sync::Arc};

use rama_core::{
    Service,
    error::{BoxError, BoxErrorExt as _},
    extensions::{Extensions, ExtensionsRef},
    futures::FutureExt as _,
    rt::Executor,
    telemetry::tracing,
};
use rama_net::{
    address::SocketAddress,
    client::{
        ConnectRequest, ConnectionError, ConnectionErrorKind, ConnectorService,
        EstablishedClientConnection,
    },
    stream::Socket as _,
};
use rama_quic_proto::profile::QuicProfile;
use rama_udp::{DatagramError, DatagramSocket};
use tokio::sync::{Mutex as AsyncMutex, OwnedSemaphorePermit, Semaphore};

use crate::{Endpoint, EndpointBuilder, EndpointConfig, SocketCapacityError};

pub(super) const MAX_CACHED_PROFILE_ENDPOINTS: usize = 8;

/// A QUIC endpoint to open one client connection from, as an endpoint connector hands it out
/// to a [`QuicConnector`](super::QuicConnector).
///
/// Its extensions are the facts of the path below the endpoint, such as the
/// [`EstablishedProxyRoute`](rama_net::client::EstablishedProxyRoute) of a proxy tunnel.
pub struct ClientEndpoint {
    endpoint: Endpoint,
    peer: Option<SocketAddr>,
    extensions: Extensions,
    // An endpoint that serves one connection at a time is held for one attempt.
    _exclusive: Option<OwnedSemaphorePermit>,
}

impl fmt::Debug for ClientEndpoint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ClientEndpoint")
            .field("endpoint", &self.endpoint)
            .field("peer", &self.peer)
            .finish_non_exhaustive()
    }
}

impl ClientEndpoint {
    /// An endpoint that can reach any remote.
    #[must_use]
    pub fn new(endpoint: Endpoint) -> Self {
        Self {
            endpoint,
            peer: None,
            extensions: Extensions::new(),
            _exclusive: None,
        }
    }

    /// An endpoint whose socket reaches `peer` only, such as a connected socket or a
    /// tunnel: connections from it are opened to `peer`.
    #[must_use]
    pub fn with_peer(mut self, peer: SocketAddr) -> Self {
        self.peer = Some(peer);
        self
    }

    /// The endpoint.
    #[must_use]
    pub fn endpoint(&self) -> &Endpoint {
        &self.endpoint
    }

    /// The only remote this endpoint reaches, when its socket is fixed to one.
    #[must_use]
    pub fn peer(&self) -> Option<SocketAddr> {
        self.peer
    }
}

impl ExtensionsRef for ClientEndpoint {
    fn extensions(&self) -> &Extensions {
        &self.extensions
    }
}

/// Hands out one shared QUIC endpoint for every client connection, as a connection pool hands
/// out connections: all connections multiplex over one UDP socket.
///
/// A managed endpoint is bound on first use (dual-stack, falling back to IPv4) and rebound if
/// its driver was lost with its runtime. A [`QuicProfile`] on the request selects an endpoint
/// for its endpoint-wide properties (connection-ID length, QUIC-bit greasing, receive size);
/// at most eight such endpoints are cached. Zero-length local connection IDs get a fresh
/// endpoint per connection. A supplied endpoint is used as is and never replaced; with
/// zero-length connection IDs it serves one connection attempt at a time.
#[derive(Debug, Clone)]
pub struct SharedQuicEndpoint {
    source: Arc<Source>,
    executor: Executor,
}

#[derive(Debug)]
enum Source {
    Supplied {
        endpoint: Endpoint,
        exclusive: Arc<Semaphore>,
    },
    Managed(AsyncMutex<ManagedEndpoints>),
}

#[derive(Debug, Default)]
struct ManagedEndpoints {
    default: Option<Endpoint>,
    profiles: VecDeque<(EndpointProfileKey, Endpoint)>,
}

// Only endpoint-wide wire properties determine socket compatibility. Packet
// layouts and parameter permutations remain per-connection client configuration.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct EndpointProfileKey {
    cid_len: u8,
    grease_quic_bit: bool,
    max_udp_payload_size: u64,
}

impl EndpointProfileKey {
    fn of(profile: &QuicProfile) -> Self {
        Self {
            cid_len: profile.connection_ids().local_len(),
            grease_quic_bit: profile.greases_quic_bit(),
            max_udp_payload_size: profile.limits().max_udp_payload_size,
        }
    }
}

impl SharedQuicEndpoint {
    /// Bind and manage the endpoints on first use; `executor` runs their drivers.
    #[must_use]
    pub fn managed(executor: Executor) -> Self {
        Self {
            source: Arc::new(Source::Managed(
                AsyncMutex::new(ManagedEndpoints::default()),
            )),
            executor,
        }
    }

    /// Share an application-managed endpoint.
    #[must_use]
    pub fn supplied(endpoint: Endpoint, executor: Executor) -> Self {
        Self {
            source: Arc::new(Source::Supplied {
                endpoint,
                exclusive: Arc::new(Semaphore::new(1)),
            }),
            executor,
        }
    }

    /// Bind the default managed endpoint now instead of on first use.
    pub async fn prepare(&self) -> Result<(), BoxError> {
        self.endpoint_for(None).await.map(drop)
    }

    async fn endpoint_for(
        &self,
        profile: Option<&QuicProfile>,
    ) -> Result<ClientEndpoint, BoxError> {
        let managed = match self.source.as_ref() {
            Source::Supplied {
                endpoint,
                exclusive,
            } => {
                let mut client = ClientEndpoint::new(endpoint.clone());
                if profile.is_some_and(|profile| profile.connection_ids().local_len() == 0) {
                    // Without connection IDs the endpoint tells connections apart by nothing.
                    client._exclusive = Some(exclusive.clone().acquire_owned().await?);
                }
                return Ok(client);
            }
            Source::Managed(managed) => managed,
        };
        if self
            .executor
            .guard()
            .is_some_and(|guard| guard.cancelled().now_or_never().is_some())
        {
            return Err(BoxError::from_static_str("QUIC connector is shutting down"));
        }
        let Some(profile) = profile else {
            let mut managed = managed.lock().await;
            if let Some(endpoint) = managed.default.as_ref().filter(|e| !e.is_closed()) {
                return Ok(ClientEndpoint::new(endpoint.clone()));
            }
            // A driver lost with its runtime is recreated in the requesting runtime;
            // the configured graceful executor still controls its shutdown lifetime.
            let endpoint = self.bind(None).await?;
            managed.default = Some(endpoint.clone());
            return Ok(ClientEndpoint::new(endpoint));
        };
        if profile.connection_ids().local_len() == 0 {
            return Ok(ClientEndpoint::new(self.bind(Some(profile)).await?));
        }
        let key = EndpointProfileKey::of(profile);
        let mut managed = managed.lock().await;
        if let Some(index) = managed
            .profiles
            .iter()
            .position(|(stored, _)| *stored == key)
            && let Some((key, endpoint)) = managed.profiles.remove(index)
            && !endpoint.is_closed()
        {
            managed.profiles.push_back((key, endpoint.clone()));
            return Ok(ClientEndpoint::new(endpoint));
        }
        let endpoint = self.bind(Some(profile)).await?;
        if managed.profiles.len() == MAX_CACHED_PROFILE_ENDPOINTS {
            // Active connections keep their endpoint driver and socket alive;
            // dropping a cached handle does not close a connection using it.
            managed.profiles.pop_front();
        }
        managed.profiles.push_back((key, endpoint.clone()));
        Ok(ClientEndpoint::new(endpoint))
    }

    /// Reuse QUIC's dual-stack client socket policy, including IPv4 fallback.
    async fn bind(&self, profile: Option<&QuicProfile>) -> Result<Endpoint, BoxError> {
        let mut config = EndpointConfig::try_with_rand_key()?;
        if let Some(profile) = profile {
            config.apply_quic_profile(profile)?;
        }
        match EndpointBuilder::new(self.executor.clone())
            .with_config(config.clone())
            .bind_client_address(SocketAddress::default_ipv6(0))
            .await
        {
            Ok(endpoint) => Ok(endpoint),
            Err(error) => {
                tracing::debug!(%error, "binding IPv4 QUIC endpoint after IPv6 bind failed");
                Ok(EndpointBuilder::new(self.executor.clone())
                    .with_config(config)
                    .bind_client_address(SocketAddress::default_ipv4(0))
                    .await?)
            }
        }
    }
}

#[cfg(all(
    test,
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )
))]
impl SharedQuicEndpoint {
    /// Whether a managed default endpoint is bound, and how many profile endpoints are cached.
    pub(super) fn managed_state(&self) -> Option<(bool, usize)> {
        match self.source.as_ref() {
            Source::Supplied { .. } => None,
            Source::Managed(managed) => managed
                .try_lock()
                .ok()
                .map(|managed| (managed.default.is_some(), managed.profiles.len())),
        }
    }
}

impl Service<ConnectRequest> for SharedQuicEndpoint {
    type Output = EstablishedClientConnection<ClientEndpoint, ConnectRequest>;
    type Error = ConnectionError;

    async fn serve(&self, input: ConnectRequest) -> Result<Self::Output, Self::Error> {
        let profile = input.extensions.get_arc::<QuicProfile>();
        let conn = self
            .endpoint_for(profile.as_deref())
            .await
            .map_err(|error| {
                ConnectionError::local(error, ConnectionErrorKind::Unavailable)
                    .context("binding QUIC endpoint")
            })?;
        Ok(EstablishedClientConnection { input, conn })
    }
}

/// Builds one QUIC endpoint on each datagram socket its inner connector establishes, such as
/// a connected UDP socket or a UDP tunnel through a proxy: one socket and endpoint per
/// connection.
///
/// The endpoint applies the request's [`QuicProfile`], keeps its packets within what the
/// socket carries, and opens its connection to the socket's peer. The socket's extensions,
/// such as an established proxy route, become the endpoint's.
#[derive(Debug, Clone)]
pub struct QuicEndpointConnector<C> {
    inner: C,
    executor: Executor,
}

impl<C> QuicEndpointConnector<C> {
    /// Endpoints on the sockets `inner` establishes; `executor` runs their drivers.
    pub fn new(inner: C, executor: Executor) -> Self {
        Self { inner, executor }
    }
}

impl<C> Service<ConnectRequest> for QuicEndpointConnector<C>
where
    C: ConnectorService<ConnectRequest, Connection: DatagramSocket>,
{
    type Output = EstablishedClientConnection<ClientEndpoint, ConnectRequest>;
    type Error = ConnectionError;

    async fn serve(&self, input: ConnectRequest) -> Result<Self::Output, Self::Error> {
        let EstablishedClientConnection {
            input,
            conn: socket,
        } = self.inner.connect(input).await?;
        let peer = socket.peer_addr().ok().map(SocketAddr::from);
        let extensions = socket.extensions().clone();
        let mut config = EndpointConfig::try_with_rand_key()
            .map_err(|error| ConnectionError::local(error, ConnectionErrorKind::Internal))?;
        if let Some(profile) = input.extensions.get_arc::<QuicProfile>() {
            config.apply_quic_profile(&profile).map_err(|error| {
                ConnectionError::local(error, ConnectionErrorKind::InvalidInput)
            })?;
        }
        let endpoint = EndpointBuilder::new(self.executor.clone())
            .with_config(config)
            .with_datagram_socket(socket)
            .map_err(|error| {
                // A socket too small for QUIC is the path's limit, not a local fault.
                let too_small = matches!(&error, DatagramError::Io(io)
                    if io.get_ref().is_some_and(|inner| inner.is::<SocketCapacityError>()));
                if too_small {
                    ConnectionError::transport(error, ConnectionErrorKind::Unavailable)
                } else {
                    ConnectionError::local(error, ConnectionErrorKind::Internal)
                }
                .context("building the QUIC endpoint on the socket")
            })?;
        let mut conn = ClientEndpoint::new(endpoint);
        conn.peer = peer;
        conn.extensions = extensions;
        Ok(EstablishedClientConnection { input, conn })
    }
}
