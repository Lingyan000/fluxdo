//! Establishment through [`QuicConnector`]: address races and proxy routes.

use std::{net::IpAddr, sync::Arc, time::Duration};

use parking_lot::Mutex;
use rama_core::{
    Service,
    error::BoxError,
    extensions::{Extensions, ExtensionsRef},
    futures::{
        StreamExt as _,
        stream::{self, BoxStream},
    },
    rt::{Executor, spawn},
};
use rama_net::{
    address::{Domain, HostWithPort, ProxyAddress, SocketAddress},
    client::{
        AddressCandidates, ConnectRequest, ConnectionError, ConnectionErrorDomain,
        ConnectionErrorKind, ConnectorTarget, ConnectorTargetStream, EstablishedClientConnection,
        EstablishedProxyRoute, ProxyRoute,
    },
    tls::ApplicationProtocol,
};
use rama_quic_proto::{
    profile::{ConnectionIdProfile, QuicProfile},
    version::{ClientVersionPolicy, Version as QuicVersion},
};
use rama_tls::{client::TlsClientConfig, server::ServerAuthData};

use crate::{
    Endpoint, EndpointConfig,
    client::{ClientEndpoint, QuicConnector, SharedQuicEndpoint},
    test_helpers::{identity, server},
    tls::default_tls_provider,
};

/// A QUIC connector over `endpoints` that trusts `identity` and offers the test ALPN.
pub(super) fn connector<E>(endpoints: E, identity: &ServerAuthData) -> QuicConnector<E> {
    let tls = TlsClientConfig::new()
        .try_with_server_trust_anchors([identity.cert_chain.last().unwrap().clone()])
        .unwrap()
        .with_alpn(
            [ApplicationProtocol::from(b"rama-quic-test")]
                .into_iter()
                .collect(),
        );
    QuicConnector::new(endpoints, tls, default_tls_provider().unwrap())
}

struct RepeatedAddress {
    domain: Domain,
    address: IpAddr,
}

impl AddressCandidates for RepeatedAddress {
    fn domain(&self) -> &Domain {
        &self.domain
    }

    fn stream<'a>(&'a self, _: &'a Extensions) -> BoxStream<'a, Result<IpAddr, BoxError>> {
        stream::iter([Ok(self.address), Ok(self.address)]).boxed()
    }
}

#[tokio::test]
async fn supplied_zero_cid_endpoint_retries_after_peer_refusal() {
    tokio::time::timeout(Duration::from_secs(10), async {
        let identity = identity();
        let server = Endpoint::bind_server(
            Executor::new(),
            server(&identity),
            SocketAddress::local_ipv4(0),
        )
        .await
        .unwrap();
        let address = server.local_addr().unwrap();
        let accept = server.clone();
        let serve = spawn(async move {
            // Reuse one peer address to isolate endpoint admission from DNS
            // ordering, IP-family policy and local-interface availability.
            let first = accept.accept().await.unwrap();
            let refused = first.orig_dst_cid();
            first.refuse();
            let connection = loop {
                let incoming = accept.accept().await.unwrap();
                // Refusal is stateless. A fragmented ClientHello or a retry
                // of the refused flight can produce another Incoming before
                // the client's next connection attempt reaches the server.
                if incoming.orig_dst_cid() == refused {
                    incoming.refuse();
                    continue;
                }
                break incoming.accept().unwrap().await.unwrap();
            };
            let (mut send, _) = connection.accept_bi().await.unwrap();
            send.write_all(b"accepted after refusal").await.unwrap();
            send.finish().unwrap();
            connection
        });
        let profile = QuicProfile::standard()
            .with_versions(ClientVersionPolicy::new(QuicVersion::V1).unwrap())
            .with_connection_ids(
                ConnectionIdProfile::standard()
                    .try_with_local_len(0)
                    .unwrap(),
            );
        let mut endpoint_config = EndpointConfig::try_with_rand_key().unwrap();
        endpoint_config.apply_quic_profile(&profile).unwrap();
        let endpoint = Endpoint::build(Executor::new())
            .with_config(endpoint_config)
            .bind_client_address(SocketAddress::local_ipv4(0))
            .await
            .unwrap();
        let quic = connector(
            SharedQuicEndpoint::supplied(endpoint.clone(), Executor::new()),
            &identity,
        );
        let input = ConnectRequest::new(HostWithPort::localhost_domain_with_port(address.port()));
        input.extensions().insert(profile);
        input
            .extensions()
            .insert(ConnectorTargetStream::new(RepeatedAddress {
                domain: "localhost".parse().unwrap(),
                address: address.ip(),
            }));
        let connection = quic.serve(input).await.unwrap().conn;
        let (mut send, mut recv) = connection.open_bi().await.unwrap();
        send.write_all(b"hello").await.unwrap();
        send.finish().unwrap();
        assert_eq!(
            recv.read_to_end(64).await.unwrap(),
            b"accepted after refusal"
        );
        let peer = serve.await.unwrap();
        connection.close(0u32, b"test complete");
        peer.close(0u32, b"test complete");
        endpoint.shutdown().await;
        server.shutdown().await;
    })
    .await
    .unwrap();
}

/// Hands out the shared endpoint with the given path facts, recording whether each request
/// was a direct address-race attempt.
#[derive(Debug, Clone)]
struct PathEndpoints {
    shared: SharedQuicEndpoint,
    route: Option<EstablishedProxyRoute>,
    peer: bool,
    direct_attempts: Arc<Mutex<Vec<bool>>>,
}

impl Service<ConnectRequest> for PathEndpoints {
    type Output = EstablishedClientConnection<ClientEndpoint, ConnectRequest>;
    type Error = ConnectionError;

    async fn serve(&self, input: ConnectRequest) -> Result<Self::Output, Self::Error> {
        self.direct_attempts
            .lock()
            .push(input.extensions().contains::<ConnectorTarget>());
        let EstablishedClientConnection { input, mut conn } = self.shared.serve(input).await?;
        if self.peer {
            let peer = conn.endpoint().local_addr().unwrap();
            conn = conn.with_peer(peer);
        }
        if let Some(route) = &self.route {
            conn.extensions().insert(route.clone());
        }
        Ok(EstablishedClientConnection { input, conn })
    }
}

#[tokio::test]
async fn proxy_route_its_endpoints_do_not_establish_is_refused() {
    let identity = identity();
    let endpoint = Endpoint::bind_client(Executor::new(), SocketAddress::local_ipv4(0))
        .await
        .unwrap();
    let proxy: ProxyAddress = "masque://proxy.example:443".parse().unwrap();
    let other: ProxyAddress = "masque://other.example:443".parse().unwrap();
    for (route, peer) in [
        (None, true),
        (Some(EstablishedProxyRoute::Direct), true),
        (Some(EstablishedProxyRoute::Tunnel(other)), true),
        // A route without a fixed peer gives the connection nowhere to go.
        (Some(EstablishedProxyRoute::Tunnel(proxy.clone())), false),
    ] {
        let direct_attempts = Arc::new(Mutex::new(Vec::new()));
        let quic = connector(
            PathEndpoints {
                shared: SharedQuicEndpoint::supplied(endpoint.clone(), Executor::new()),
                route,
                peer,
                direct_attempts: direct_attempts.clone(),
            },
            &identity,
        );
        // An IP origin would be directly dialable if the route were bypassed.
        let input = ConnectRequest::new(HostWithPort::local_ipv4(443));
        input.extensions().insert(ProxyRoute::Proxy(proxy.clone()));
        let error = quic.serve(input).await.err().unwrap();
        assert_eq!(error.domain(), ConnectionErrorDomain::Local);
        assert_eq!(error.kind(), ConnectionErrorKind::Unavailable);
        assert_eq!(*direct_attempts.lock(), [false]);
    }
    assert_eq!(endpoint.stats().outgoing_handshakes, 0);
    endpoint.close(0u32, b"test complete");
}

// Out-of-band agreement over QUIC needs a backend that supports it.
#[cfg(all(feature = "rustls", any(feature = "aws-lc", feature = "ring")))]
mod out_of_band {
    use std::future::pending;

    use rama_net::tls::{AlpnPolicy, TlsAlpn};
    use rama_tls::server::TlsServerConfig;

    use super::*;
    use crate::{ServerConfig, tls::TlsOptions};

    #[tokio::test]
    async fn an_alpn_offer_must_be_negotiated_unless_agreed_out_of_band() {
        tokio::time::timeout(Duration::from_secs(10), async {
            for (offer, policy, established) in [
                (true, AlpnPolicy::Require, false),
                (false, AlpnPolicy::OutOfBandAgreement, true),
            ] {
                let identity = identity();
                let tls = TlsServerConfig::new()
                    .with_alpn(Default::default())
                    .with_server_auth(identity.clone());
                let server = Endpoint::bind_server(
                    Executor::new(),
                    ServerConfig::try_from_rama_tls(
                        &tls,
                        TlsOptions::default().with_alpn(AlpnPolicy::OutOfBandAgreement),
                    )
                    .unwrap(),
                    SocketAddress::local_ipv4(0),
                )
                .await
                .unwrap();
                let address = server.local_addr().unwrap();
                let accept = server.clone();
                spawn(async move {
                    if let Some(incoming) = accept.accept().await
                        && let Ok(connecting) = incoming.accept()
                    {
                        let _connection = connecting.await;
                        pending::<()>().await;
                    }
                });
                let quic = connector(SharedQuicEndpoint::managed(Executor::new()), &identity);
                let input =
                    ConnectRequest::new(HostWithPort::localhost_domain_with_port(address.port()));
                input
                    .extensions()
                    .insert(ConnectorTarget(HostWithPort::local_ipv4(address.port())));
                if !offer {
                    input.extensions().insert(TlsAlpn::empty());
                }
                input.extensions().insert(policy);
                let result = quic.serve(input).await;
                assert_eq!(
                    result.is_ok(),
                    established,
                    "{policy:?}: {:?}",
                    result.err()
                );
                server.close(0u32, b"test complete");
            }
        })
        .await
        .unwrap();
    }
}
