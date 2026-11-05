//! Where a connection is in its life, which side it is, and what it reports to the driver.

use std::sync::Arc;

use rama_core::bytes::Bytes;

use crate::proto::{
    TokenStore,
    config::{PreferredAddressPolicy, ServerConfig, TimeSource},
    connection::{ConnectionError, streams::StreamEvent},
    token::bounded_token,
};
use rama_quic_proto::{ConnectionId, Side, Version, frame::Close, version::ClientVersionPolicy};

/// Fields of `Connection` specific to it being client-side or server-side
pub(super) enum ConnectionSide {
    Client {
        /// Sent in every outgoing Initial packet. Always empty after Initial keys are discarded
        token: Bytes,
        token_store: Arc<dyn TokenStore>,
        server_name: String,
        /// What to do with an address the server advertises as preferred
        preferred_address_policy: PreferredAddressPolicy,
        /// Which versions this attempt offered the server (RFC 9368)
        versions: ClientVersionPolicy,
        /// The Version Negotiation offer this attempt reacts to, if any (RFC 9368 §4)
        negotiation_offer: Option<Vec<Version>>,
        /// The clock tokens are dated with
        time_source: Arc<dyn TimeSource>,
        /// RFC 9287 §3.1: whether the QUIC bit may already be cleared before the server's
        /// parameters arrive, because a recent token from a greasing server is in use.
        grease_quic_bit_early: bool,
    },
    Server {
        server_config: Arc<ServerConfig>,
    },
}

impl ConnectionSide {
    pub(super) fn is_client(&self) -> bool {
        self.side().is_client()
    }

    pub(super) fn is_server(&self) -> bool {
        self.side().is_server()
    }

    pub(super) fn side(&self) -> Side {
        match *self {
            Self::Client { .. } => Side::Client,
            Self::Server { .. } => Side::Server,
        }
    }
}

impl From<SideArgs> for ConnectionSide {
    fn from(side: SideArgs) -> Self {
        match side {
            SideArgs::Client {
                token_store,
                server_name,
                preferred_address_policy,
                versions,
                negotiation_offer,
                time_source,
            } => {
                let stored = token_store
                    .take(&server_name, versions.original())
                    .and_then(|mut stored| {
                        stored.token = bounded_token(&stored.token)?;
                        Some(stored)
                    });
                let grease_quic_bit_early = stored
                    .as_ref()
                    .is_some_and(|stored| stored.allows_early_quic_bit_grease(time_source.now()));
                Self::Client {
                    token: stored.map(|stored| stored.token).unwrap_or_default(),
                    token_store,
                    server_name,
                    preferred_address_policy,
                    versions,
                    negotiation_offer,
                    time_source,
                    grease_quic_bit_early,
                }
            }
            SideArgs::Server {
                server_config,
                pref_addr_cid: _,
                path_validated: _,
                orig_dst_cid: _,
                original_version: _,
            } => Self::Server { server_config },
        }
    }
}

/// Parameters to `Connection::new` specific to it being client-side or server-side
pub(crate) enum SideArgs {
    Client {
        token_store: Arc<dyn TokenStore>,
        server_name: String,
        preferred_address_policy: PreferredAddressPolicy,
        versions: ClientVersionPolicy,
        negotiation_offer: Option<Vec<Version>>,
        time_source: Arc<dyn TimeSource>,
    },
    Server {
        server_config: Arc<ServerConfig>,
        pref_addr_cid: Option<ConnectionId>,
        path_validated: bool,
        /// The version of the client's first flight, when the server moves the connection to
        /// another compatible one (RFC 9368 §2.3); otherwise the connection's version.
        original_version: Version,
        /// The destination the client's first Initial named, before any Retry. It is what both
        /// ends call this connection in a trace.
        orig_dst_cid: ConnectionId,
    },
}

impl SideArgs {
    /// The identifier a trace names this connection by: the destination of the client's first
    /// Initial. A client knows it because it chose it; a server is told it by the token, since
    /// a Retry changes what the packets carry.
    pub(crate) fn trace_cid(&self, init_cid: ConnectionId) -> ConnectionId {
        match *self {
            Self::Client { .. } => init_cid,
            Self::Server { orig_dst_cid, .. } => orig_dst_cid,
        }
    }

    pub(crate) fn pref_addr_cid(&self) -> Option<ConnectionId> {
        match *self {
            Self::Client { .. } => None,
            Self::Server { pref_addr_cid, .. } => pref_addr_cid,
        }
    }

    pub(crate) fn path_validated(&self) -> bool {
        match *self {
            Self::Client { .. } => true,
            Self::Server { path_validated, .. } => path_validated,
        }
    }

    pub(crate) fn side(&self) -> Side {
        match *self {
            Self::Client { .. } => Side::Client,
            Self::Server { .. } => Side::Server,
        }
    }

    /// The version of the client's first flight, given the version the connection runs in.
    pub(crate) fn original_version(&self, version: Version) -> Version {
        match *self {
            Self::Client { .. } => version,
            Self::Server {
                original_version, ..
            } => original_version,
        }
    }
}

#[cfg_attr(
    not(fuzzing),
    expect(
        unreachable_pub,
        reason = "reachable through `fuzzing` under cfg(fuzzing)"
    )
)]
#[derive(Clone)]
pub enum State {
    Handshake(state::Handshake),
    Established,
    Closed(state::Closed),
    Draining,
    /// Waiting for application to call close so we can dispose of the resources
    Drained,
}

impl State {
    pub(super) fn closed<R: Into<Close>>(reason: R) -> Self {
        Self::Closed(state::Closed {
            reason: reason.into(),
        })
    }

    pub(super) fn is_handshake(&self) -> bool {
        matches!(*self, Self::Handshake(_))
    }

    pub(super) fn is_established(&self) -> bool {
        matches!(*self, Self::Established)
    }

    pub(super) fn is_closed(&self) -> bool {
        matches!(*self, Self::Closed(_) | Self::Draining | Self::Drained)
    }

    pub(super) fn is_drained(&self) -> bool {
        matches!(*self, Self::Drained)
    }
}

pub(super) mod state {
    use rama_core::bytes::Bytes;

    use rama_quic_proto::frame::Close;

    #[cfg_attr(
        not(fuzzing),
        expect(
            unreachable_pub,
            reason = "reachable through `fuzzing` under cfg(fuzzing)"
        )
    )]
    #[derive(Clone)]
    pub struct Handshake {
        /// Whether the remote CID has been set by the peer yet
        ///
        /// Always set for servers
        pub(in crate::proto::connection) rem_cid_set: bool,
        /// Stateless retry token received in the first Initial by a server.
        ///
        /// Must be present in every Initial. Always empty for clients.
        pub(in crate::proto::connection) expected_token: Bytes,
        /// First cryptographic message
        ///
        /// Only set for clients
        pub(in crate::proto::connection) client_hello: Option<Bytes>,
    }

    #[cfg_attr(
        not(fuzzing),
        expect(
            unreachable_pub,
            reason = "reachable through `fuzzing` under cfg(fuzzing)"
        )
    )]
    #[derive(Clone)]
    pub struct Closed {
        pub(in crate::proto::connection) reason: Close,
    }
}

/// Events of interest to the application
#[derive(Debug)]
pub(crate) enum Event {
    /// The connection's handshake data is ready
    HandshakeDataReady,
    /// The connection was successfully established
    Connected,
    /// The TLS handshake was confirmed (RFC 9001 §4.1.2)
    HandshakeConfirmed,
    /// The connection was lost
    ///
    /// Emitted if the peer closes the connection or an error is encountered.
    ConnectionLost {
        /// Reason that the connection was closed
        reason: ConnectionError,
    },
    /// Stream events
    Stream(StreamEvent),
    /// One or more application datagrams have been received
    DatagramReceived,
    /// One or more application datagrams have been sent after blocking
    DatagramsUnblocked,
}
