use std::net::SocketAddr;
use std::ops::Range;

use rama_core::bytes::BytesMut;

use rama_quic_proto::{ConnectionId, EcnCodepoint, ResetToken, packet::PartialDecode};

use crate::proto::Instant;

/// Events sent from an Endpoint to a Connection
#[derive(Debug)]
pub(crate) struct ConnectionEvent(pub(crate) ConnectionEventInner);

#[derive(Debug)]
#[expect(
    clippy::large_enum_variant,
    reason = "`Datagram` is the common receive-path event and carries the datagram inline; boxing it would add a heap allocation for every received datagram"
)]
pub(crate) enum ConnectionEventInner {
    /// A datagram has been received for the Connection
    Datagram(DatagramConnectionEvent),
    /// New connection identifiers have been issued for the Connection
    NewIdentifiers(Vec<IssuedCid>, Instant),
    /// The route a stateless reset for this identifier at this address would arrive by is now
    /// installed, so a datagram carrying that identifier may go to that address. The last field
    /// names the installation, and an acknowledgement naming any other one is stale.
    ResetRouteInstalled(SocketAddr, u64, u64),
    /// The endpoint has no room to route a reset for this identifier at this address, so the
    /// route does not exist and the datagram waiting on it can never be sent.
    ResetRouteRefused(SocketAddr, u64, u64),
}

impl ConnectionEvent {
    /// Whether this event issues connection identifiers. Identifier issuance is the only thing
    /// the test seam that withholds events should withhold, and it is reached from more than one
    /// request — a connection asking for more, and a retirement that allows more.
    #[cfg(test)]
    pub(crate) fn is_new_identifiers(&self) -> bool {
        matches!(self.0, ConnectionEventInner::NewIdentifiers(..))
    }
}

/// Variant of [`ConnectionEventInner`].
#[derive(Debug)]
pub(crate) struct DatagramConnectionEvent {
    pub(crate) now: Instant,
    pub(crate) remote: SocketAddr,
    /// The local socket address the datagram arrived on (ip and port), when known. The ip may
    /// be unspecified for a wildcard-bound socket whose platform reports no destination address.
    pub(crate) local: Option<SocketAddr>,
    pub(crate) ecn: Option<EcnCodepoint>,
    pub(crate) first_decode: PartialDecode,
    pub(crate) remaining: Option<BytesMut>,
}

/// Events sent from a Connection to an Endpoint
#[derive(Debug)]
pub(crate) struct EndpointEvent(pub(crate) EndpointEventInner);

impl EndpointEvent {
    /// Construct an event that indicating that a `Connection` will no longer emit events
    ///
    /// Useful for notifying an `Endpoint` that a `Connection` has been destroyed outside of the
    /// usual state machine flow, e.g. when being dropped by the user.
    pub(crate) fn drained() -> Self {
        Self(EndpointEventInner::Drained)
    }

    /// Whether this event installs the route a stateless reset would arrive by. It is the only
    /// endpoint event the send path waits on, so a synchronous test harness applies these before
    /// offering a datagram and leaves the rest of its ordering alone.
    #[cfg(test)]
    pub(crate) fn is_reset_route(&self) -> bool {
        matches!(self.0, EndpointEventInner::ResetTokenUsed(..))
    }

    /// The refusal a full routing table would answer this installation with, if it is one.
    #[cfg(test)]
    pub(crate) fn route_refusal(&self) -> Option<ConnectionEvent> {
        match self.0 {
            EndpointEventInner::ResetTokenUsed(remote, seq, _, generation) => {
                Some(ConnectionEvent(ConnectionEventInner::ResetRouteRefused(
                    remote, seq, generation,
                )))
            }
            _ => None,
        }
    }

    /// Determine whether this is the last event a `Connection` will emit
    ///
    /// Useful for determining when connection-related event loop state can be freed.
    pub(crate) fn is_drained(&self) -> bool {
        self.0 == EndpointEventInner::Drained
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum EndpointEventInner {
    /// The connection has been drained
    Drained,
    /// The connection now sends the remote connection ID with this sequence number to this
    /// address: a stateless reset from there carrying this token belongs to it.
    /// A datagram carrying this identifier reached the network for this address: install the
    /// route a stateless reset would arrive by. The last field names the installation.
    ResetTokenUsed(SocketAddr, u64, ResetToken, u64),
    /// This identifier is no longer sent to this address: release that route. The last field names
    /// the installation being released, so a newer one is left in place.
    ResetTokenReleased(SocketAddr, u64, ResetToken, u64),
    /// The remote connection IDs with these sequence numbers were retired: their tokens no longer
    /// identify a reset for this connection.
    ResetTokensRetired(Range<u64>),
    /// The connection needs connection identifiers
    NeedIdentifiers(Instant, u64),
    /// Stop routing connection ID for this sequence number to the connection
    /// When `bool == true`, a new connection ID will be issued to peer
    RetireConnectionId(Instant, u64, bool),
}

#[derive(Debug, Copy, Clone)]
pub(crate) struct IssuedCid {
    pub(crate) sequence: u64,
    pub(crate) id: ConnectionId,
    pub(crate) reset_token: ResetToken,
}
