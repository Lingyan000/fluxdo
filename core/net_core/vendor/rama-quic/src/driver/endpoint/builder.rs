//! Building an endpoint on an application's own executor.
//!
//! Tasks are spawned through that executor onto the caller's Tokio runtime. An executor
//! carrying a graceful guard ties the endpoint to the application's shutdown.
//!
//! The supervisor takes the executor, and with it the strong guard. Endpoint handles hold only
//! a weak cancellation reference, so a handle the application keeps does not hold the shutdown
//! open.

use std::{io, time::Duration};

use rama_core::rt::Executor;
use rama_net::address::SocketAddress;
use rama_udp::{DatagramError, DatagramSocket, UdpPacketSocket, UdpSocketConfig, UdpSocketFactory};

use crate::driver::{
    EndpointConfig,
    endpoint::{Endpoint, bind_advertised},
    endpoint::{client_socket_config, default_socket_config},
    udp::Socket,
};
use crate::proto::ServerConfig;

/// How long a shutdown gives drivers to finish before it stops waiting and forces them.
pub const DEFAULT_SHUTDOWN_BUDGET: Duration = Duration::from_secs(5);

/// An endpoint being built: the runtime it will live on, what it is configured with, and the
/// socket it will bind.
#[derive(Debug, Clone)]
pub struct EndpointBuilder {
    exec: Executor,
    config: Option<EndpointConfig>,
    server_config: Option<ServerConfig>,
    shutdown_budget: Duration,
    #[cfg(feature = "opentelemetry")]
    metrics: Option<crate::telemetry::QuicMetrics>,
}

impl EndpointBuilder {
    /// Build a client endpoint whose tasks run through `exec`.
    ///
    /// Unless configured otherwise, construction generates a fresh secret reset key.
    /// A random-source failure is returned when binding or attaching a socket.
    #[must_use]
    pub fn new(exec: Executor) -> Self {
        Self {
            exec,
            config: None,
            server_config: None,
            shutdown_budget: DEFAULT_SHUTDOWN_BUDGET,
            #[cfg(feature = "opentelemetry")]
            metrics: None,
        }
    }

    #[cfg(feature = "opentelemetry")]
    rama_utils::macros::generate_set_and_with! {
        /// Record this endpoint and its connections in `value`; nothing is recorded without it.
        pub fn metrics(mut self, value: Option<crate::telemetry::QuicMetrics>) -> Self {
            self.metrics = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// The endpoint configuration; when omitted, construction generates a random reset key.
        pub fn config(mut self, value: Option<EndpointConfig>) -> Self {
            self.config = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// What this endpoint serves incoming connections with
        ///
        /// Without a server config, the default, it is a client.
        pub fn server_config(mut self, value: Option<ServerConfig>) -> Self {
            self.server_config = value;
            self
        }
    }

    rama_utils::macros::generate_set_and_with! {
        /// How long a shutdown gives the drivers before it stops waiting and forces them. Zero
        /// forces immediately.
        pub fn shutdown_budget(mut self, value: Duration) -> Self {
            self.shutdown_budget = value;
            self
        }
    }

    /// Bind the address, and the addresses this endpoint advertises as preferred with it.
    ///
    /// The advertised sockets are bound before the endpoint exists, so it advertises the
    /// addresses its sockets have, including ports the platform assigned. The sockets get
    /// Rama's UDP defaults and the buffer floor of
    /// [`DEFAULT_SOCKET_BUFFER_SIZE`](crate::DEFAULT_SOCKET_BUFFER_SIZE).
    pub async fn bind_address(
        self,
        address: impl Into<SocketAddress>,
    ) -> Result<Endpoint, DatagramError> {
        self.bind_address_with_socket_config(address, default_socket_config())
            .await
    }

    /// Bind an outbound endpoint with the client's best-effort dual-stack policy.
    ///
    /// This retains the endpoint configuration selected on this builder. IPv6
    /// bindings request a dual-stack socket; unsupported platforms retain their
    /// system policy. Callers can retry with an IPv4 address if binding fails.
    pub async fn bind_client_address(
        self,
        address: impl Into<SocketAddress>,
    ) -> Result<Endpoint, DatagramError> {
        let address = address.into();
        self.bind_address_with_socket_config(address, client_socket_config(address))
            .await
    }

    /// Same as [`Self::bind_address`] but with a custom [`UdpSocketConfig`], applied as given.
    pub async fn bind_address_with_socket_config(
        self,
        address: impl Into<SocketAddress>,
        socket_config: UdpSocketConfig,
    ) -> Result<Endpoint, DatagramError> {
        let Self {
            exec,
            config,
            server_config,
            shutdown_budget,
            #[cfg(feature = "opentelemetry")]
            metrics,
        } = self;

        let config = match config {
            Some(config) => config,
            None => EndpointConfig::try_with_rand_key().map_err(io::Error::other)?,
        };
        let factory = UdpSocketFactory::new(socket_config);
        let listener = factory.bind(address.into()).await?;
        let (server_config, advertised) = bind_advertised(&factory, server_config).await?;
        let advertised = advertised
            .into_iter()
            .map(Socket::new)
            .collect::<io::Result<Vec<_>>>()?;

        let endpoint = Endpoint::new_with_advertised(
            config,
            server_config,
            Socket::new(listener)?,
            advertised,
            exec,
            shutdown_budget,
        )?;
        #[cfg(feature = "opentelemetry")]
        if let Some(metrics) = metrics {
            endpoint.attach_metrics(&metrics);
        }
        Ok(endpoint)
    }

    /// Build on a packet socket the caller prepared, with its packet metadata set up and its
    /// required features validated.
    ///
    /// This does not bind preferred-address sockets or change the supplied socket options.
    pub fn with_packet_socket(self, socket: UdpPacketSocket) -> Result<Endpoint, DatagramError> {
        self.with_datagram_socket(socket)
    }

    /// Build on an application's packet-oriented datagram transport.
    ///
    /// The supplied socket owns receive readiness and creates independently
    /// wakeable send handles, as required by [`DatagramSocket`]. It must preserve
    /// datagram boundaries, provide accurate packet metadata and advertise only
    /// the capabilities it supports. The endpoint and connection drivers run on
    /// this builder's executor; an operating-system socket is not required.
    ///
    /// Like [`Self::with_packet_socket`], this does not configure the transport
    /// or bind preferred-address sockets. The supplied socket's local address
    /// identifies the endpoint, and it must accept the destinations the
    /// application intends to connect to or serve.
    pub fn with_datagram_socket(
        self,
        socket: impl DatagramSocket,
    ) -> Result<Endpoint, DatagramError> {
        self.on_socket(Socket::new(socket).map_err(DatagramError::from)?)
    }

    /// Build on a bound standard socket. The packet metadata a [`UdpSocketConfig`] describes is
    /// not set up here; a caller that needs it wraps the socket first and uses
    /// [`with_packet_socket`](Self::with_packet_socket).
    pub fn with_std_socket(self, socket: std::net::UdpSocket) -> Result<Endpoint, DatagramError> {
        self.on_socket(Socket::from_std(socket).map_err(DatagramError::from)?)
    }

    /// Where a prepared socket becomes an endpoint.
    fn on_socket(self, socket: Socket) -> Result<Endpoint, DatagramError> {
        let Self {
            exec,
            config,
            server_config,
            shutdown_budget,
            #[cfg(feature = "opentelemetry")]
            metrics,
        } = self;

        let config = match config {
            Some(config) => config,
            None => EndpointConfig::try_with_rand_key().map_err(io::Error::other)?,
        };

        let endpoint = Endpoint::new_with_advertised(
            config,
            server_config,
            socket,
            Vec::new(),
            exec,
            shutdown_budget,
        )?;
        #[cfg(feature = "opentelemetry")]
        if let Some(metrics) = metrics {
            endpoint.attach_metrics(&metrics);
        }
        Ok(endpoint)
    }
}
