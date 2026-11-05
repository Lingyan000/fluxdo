//! An in-memory client and server, endpoint and connection each, for the fuzz harnesses that
//! drive QUIC through sequences of packets.

#![expect(
    clippy::unwrap_used,
    reason = "invalid fixed harness setup must fail the fuzz run"
)]

use std::{
    collections::VecDeque,
    net::SocketAddr,
    sync::{Arc, LazyLock},
};

use rama_core::bytes::BytesMut;
use rama_quic_proto::{
    ConnectionId, Version,
    packet::{FixedLengthConnectionIdParser, PartialDecode},
    version::ClientVersionPolicy,
};
use rama_tls::{
    client::TlsClientConfig,
    server::{LeafCertRequest, ServerAuthData, TlsServerConfig},
};

use super::Connection;
use crate::{
    ClientConfig, ServerConfig,
    proto::{
        ConnectionHandle, DEFAULT_SUPPORTED_VERSIONS, DatagramEvent, Duration, Endpoint,
        EndpointConfig, Instant, SendPermit,
    },
    tls::TlsOptions,
};

pub(super) static IDENTITY: LazyLock<ServerAuthData> =
    LazyLock::new(|| ServerAuthData::new_self_signed_leaf(LeafCertRequest::default()).unwrap());

/// How many transmits in a row a datagram may wait for a route that nothing is installing.
const WAITING_TRANSMITS: u32 = 8;

pub(super) struct Peer {
    pub(super) endpoint: Endpoint,
    pub(super) connection: Option<(ConnectionHandle, Connection)>,
    pub(super) outgoing: VecDeque<Vec<u8>>,
    pub(super) address: SocketAddr,
    /// A datagram whose route the endpoint has not confirmed yet, held as the driver holds it.
    held: Option<Held>,
    /// Datagrams held for their route, and those of them that went out after all.
    pub(super) waited: [u64; 2],
}

struct Held {
    sequence: u64,
    destination: SocketAddr,
    packet: Vec<u8>,
    /// Transmits since the endpoint last had anything to do.
    waits: u32,
}

impl Peer {
    fn new(config: Arc<EndpointConfig>, server: Option<Arc<ServerConfig>>, port: u16) -> Self {
        Self {
            endpoint: Endpoint::new(config, server, false, Some([port as u8; 32])),
            connection: None,
            outgoing: VecDeque::new(),
            address: ([127, 0, 0, 1], port).into(),
            held: None,
            waited: [0, 0],
        }
    }

    pub(super) fn receive(&mut self, now: Instant, remote: SocketAddr, packet: &[u8]) {
        let mut response = Vec::new();
        match self.endpoint.handle(
            now,
            remote,
            Some(self.address),
            None,
            BytesMut::from(packet),
            &mut response,
        ) {
            Some(DatagramEvent::NewConnection(incoming)) => {
                if self.connection.is_some() {
                    self.endpoint.ignore(incoming);
                } else {
                    let accepted = self
                        .endpoint
                        .start_accept(incoming, now, &mut response, None)
                        .and_then(|accepting| {
                            self.endpoint
                                .finish_accept(accepting.accept(), &mut response)
                        });
                    match accepted {
                        Ok(registered) => {
                            let mut connection = registered.connection;
                            for event in registered.late {
                                connection.handle_event(event);
                            }
                            self.connection = Some((registered.handle, connection))
                        }
                        Err(error) => {
                            if let Some(transmit) = error.response {
                                self.outgoing.push_back(response[..transmit.size].to_vec());
                            }
                        }
                    }
                }
            }
            Some(DatagramEvent::ConnectionEvent(handle, event)) => {
                if let Some((current, connection)) = &mut self.connection {
                    assert_eq!(handle, *current);
                    connection.handle_event(event);
                }
            }
            Some(DatagramEvent::Response(transmit) | DatagramEvent::Retry(transmit)) => {
                self.outgoing.push_back(response[..transmit.size].to_vec());
            }
            None => {}
        }
    }

    pub(super) fn routes(&mut self) {
        if let Some((handle, connection)) = &mut self.connection {
            while let Some(event) = connection.poll_endpoint_events() {
                if let Some(held) = &mut self.held {
                    held.waits = 0;
                }
                if let Some(reply) = self.endpoint.handle_event(*handle, event) {
                    connection.handle_event(reply);
                }
            }
        }
    }

    pub(super) fn transmit(&mut self, now: Instant) {
        self.routes();
        let Some((_, connection)) = &mut self.connection else {
            self.held = None;
            return;
        };
        // What waits for its route goes first, as built; nothing new is built behind it.
        if let Some(mut held) = self.held.take() {
            match connection.may_send_cid(held.sequence, held.destination) {
                SendPermit::Sendable => {
                    connection.cid_sent(held.sequence, held.destination);
                    self.outgoing.push_back(held.packet);
                    self.waited[1] += 1;
                }
                SendPermit::AwaitingInstallation => {
                    held.waits += 1;
                    assert!(
                        held.waits <= WAITING_TRANSMITS,
                        "a datagram has waited for a route across {} transmits with nothing left \
                         to install",
                        held.waits
                    );
                    self.held = Some(held);
                    return;
                }
                SendPermit::Obsolete => {}
            }
        }
        if connection.poll_timeout().is_some_and(|at| at <= now) {
            connection.handle_timeout(now);
        }
        let mut packet = Vec::new();
        let transmit = connection.poll_transmit(now, 1, &mut packet);
        self.routes();
        let Some(transmit) = transmit else {
            return;
        };
        assert_eq!(transmit.size, packet.len());
        let connection = &mut self.connection.as_mut().unwrap().1;
        // The driver holds a datagram whose route is not confirmed and drops one whose
        // identifier may never be sent again (RFC 9000 §9.5); so does this.
        if let Some(sequence) = transmit.cid_used {
            match connection.may_send_cid(sequence, transmit.destination) {
                SendPermit::Sendable => connection.cid_sent(sequence, transmit.destination),
                SendPermit::AwaitingInstallation => {
                    self.waited[0] += 1;
                    self.held = Some(Held {
                        sequence,
                        destination: transmit.destination,
                        packet,
                        waits: 0,
                    });
                    return;
                }
                SendPermit::Obsolete => return,
            }
        }
        self.outgoing.push_back(packet);
    }
}

pub(super) struct Pair {
    pub(super) client: Peer,
    pub(super) server: Peer,
    pub(super) now: Instant,
    pub(super) destination: ConnectionId,
    pub(super) source: ConnectionId,
    pub(super) version: Version,
    pub(super) server_config: Arc<ServerConfig>,
}

impl Pair {
    pub(super) fn new(
        client_config: ClientConfig,
        server_config: Arc<ServerConfig>,
        version: Version,
    ) -> Self {
        let mut endpoint_config = EndpointConfig::try_with_rand_key().unwrap();
        endpoint_config.max_udp_payload_size(65_527).unwrap();
        let endpoint_config = Arc::new(endpoint_config);
        let mut client = Peer::new(endpoint_config.clone(), None, 4434);
        let server = Peer::new(endpoint_config, Some(server_config.clone()), 4433);
        let now = Instant::now();
        client.connection = Some(
            client
                .endpoint
                .connect(now, client_config, server.address, "localhost")
                .unwrap(),
        );
        client.transmit(now);
        let (source, destination) = client
            .outgoing
            .front()
            .map(|packet| {
                let (decoded, _) = PartialDecode::new(
                    packet.as_slice().into(),
                    &FixedLengthConnectionIdParser::new(0),
                    DEFAULT_SUPPORTED_VERSIONS,
                    // A token from a server that greases the QUIC bit lets this client grease
                    // its first flight too (RFC 9287 §3.1).
                    true,
                )
                .unwrap();
                let header = decoded.initial_header().unwrap();
                (header.src_cid, header.dst_cid)
            })
            .unwrap_or((ConnectionId::new(&[]), ConnectionId::new(&[])));
        Self {
            client,
            server,
            now,
            source,
            destination,
            version,
            server_config,
        }
    }

    pub(super) fn drive(&mut self) {
        for _ in 0..64 {
            self.client.transmit(self.now);
            while let Some(packet) = self.client.outgoing.pop_front() {
                self.server.receive(self.now, self.client.address, &packet);
            }
            self.server.transmit(self.now);
            while let Some(packet) = self.server.outgoing.pop_front() {
                self.client.receive(self.now, self.server.address, &packet);
            }
            self.now += Duration::from_millis(1);
        }
    }
}

/// A client and a server configuration for `version`, negotiating `alpn`.
pub(super) fn configs(version: Version, alpn: &'static [u8]) -> (ClientConfig, Arc<ServerConfig>) {
    let tls = TlsClientConfig::new()
        .with_alpn([alpn.into()].into_iter().collect())
        .try_with_server_trust_anchors([IDENTITY.cert_chain.last().unwrap().clone()])
        .unwrap();
    let mut client_config = ClientConfig::try_from_rama_tls(&tls, TlsOptions::default()).unwrap();
    client_config
        .set_versions(ClientVersionPolicy::new(version).unwrap())
        .unwrap();
    let tls = TlsServerConfig::new()
        .with_alpn([alpn.into()].into_iter().collect())
        .with_server_auth(IDENTITY.clone());
    let server_config =
        Arc::new(ServerConfig::try_from_rama_tls(&tls, TlsOptions::default()).unwrap());
    (client_config, server_config)
}
