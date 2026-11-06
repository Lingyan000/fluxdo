//! QUIC qlog observations shared by inline sinks and owned recording adapters.
//!
//! Views borrow variable-size data during synchronous delivery. Conversion to owned data is
//! explicit; compact packet, address, connection ID, and tuple values need no heap storage.

use rama_quic_proto::ConnectionId;
use serde::{Serialize, Serializer, ser::SerializeSeq};
use std::fmt;

pub mod drops;
pub mod lifecycle;
pub mod negotiation;
pub mod packet;
pub mod path;

pub use drops::{DropEvent, PacketBuffered, PacketDropped};
pub use lifecycle::{LifecycleEvent, LifecycleEventView};
pub use negotiation::{NegotiationEvent, NegotiationEventView};
pub use packet::PacketEvent;
pub use path::PathEvent;

/// Endpoint responsible for an observed change.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Initiator {
    /// The logging endpoint.
    Local,

    /// The peer endpoint.
    Remote,
}

/// A compact tuple identifier, formatted only by an encoder.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TupleId {
    /// Initial network tuple, serialized as an empty identifier.
    Default,

    /// Network tuple identified by its monotonically increasing generation.
    Generation(u64),

    /// Candidate network tuple identified by its probe sequence.
    Probe(u64),
}

impl fmt::Display for TupleId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Default => Ok(()),
            Self::Generation(value) => write!(f, "{value}"),
            Self::Probe(value) => write!(f, "probe-{value}"),
        }
    }
}

impl Serialize for TupleId {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}

/// An event from the implemented QUIC event schemas, borrowing variable-size observations.
#[derive(Clone, Debug, Serialize)]
#[serde(untagged)]
pub enum EventView<'a> {
    /// Packet transmission, reception, loss, and recovery metrics.
    Packet(PacketEvent),

    /// Version, ALPN, transport parameter, and traffic-key changes.
    Negotiation(NegotiationEventView<'a>),

    /// Connection endpoints, lifecycle transitions, and closure details.
    Lifecycle(LifecycleEventView<'a>),

    /// Network tuples, migration, connection IDs, and recovery configuration.
    Path(PathEvent),

    /// Discarded or held-back packets and the reasons.
    Drop(DropEvent),
}

/// An event that may outlive the observed connection.
pub type Event = EventView<'static>;

/// Event fields independent of the recorder's timestamp and connection grouping.
#[derive(Clone, Debug, Serialize)]
pub struct EventFieldsView<'a> {
    /// Explicit network tuple, omitted for the initial handshake tuple.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tuple: Option<TupleId>,

    /// Event name and schema-specific data.
    #[serde(flatten)]
    pub event: EventView<'a>,
}

/// Event fields whose backing storage is owned or static.
pub type EventFields = EventFieldsView<'static>;

macro_rules! event_from {
    ($($ty:ty => $variant:ident),* $(,)?) => {$ (
        impl<'a> From<$ty> for EventView<'a> {
            fn from(value: $ty) -> Self { Self::$variant(value) }
        }

        impl<'a> From<$ty> for EventFieldsView<'a> {
            fn from(value: $ty) -> Self { EventView::from(value).into() }
        }
    )*};
}

event_from! {
    PacketEvent => Packet,
    NegotiationEventView<'a> => Negotiation,
    LifecycleEventView<'a> => Lifecycle,
    PathEvent => Path,
    DropEvent => Drop,
}

impl<'a> From<PacketDropped> for EventView<'a> {
    fn from(value: PacketDropped) -> Self {
        DropEvent::PacketDropped(value).into()
    }
}

impl<'a> From<PacketDropped> for EventFieldsView<'a> {
    fn from(value: PacketDropped) -> Self {
        EventView::from(value).into()
    }
}

impl<'a> From<PacketBuffered> for EventView<'a> {
    fn from(value: PacketBuffered) -> Self {
        DropEvent::PacketBuffered(value).into()
    }
}

impl<'a> From<PacketBuffered> for EventFieldsView<'a> {
    fn from(value: PacketBuffered) -> Self {
        EventView::from(value).into()
    }
}

impl<'a> From<EventView<'a>> for EventFieldsView<'a> {
    fn from(event: EventView<'a>) -> Self {
        Self { tuple: None, event }
    }
}

impl EventFieldsView<'_> {
    /// Retain these fields beyond synchronous observation, copying only borrowed storage.
    pub fn into_owned(self) -> EventFields {
        EventFieldsView {
            tuple: self.tuple,
            event: self.event.into_owned(),
        }
    }

    /// Copy these fields into independent storage suitable for a queue or history buffer.
    pub fn to_owned(&self) -> EventFields {
        self.clone().into_owned()
    }

    /// Retained heap bytes, including spare capacity; excludes borrowed data, inline fields, and allocator metadata.
    pub fn heap_size(&self) -> usize {
        self.event.heap_size()
    }

    /// Conservative heap bytes needed by `to_owned`, before copying any borrowed data.
    pub fn owned_heap_size(&self) -> usize {
        self.event.owned_heap_size()
    }
}

impl EventView<'_> {
    /// Retain this event, copying borrowed storage and moving existing owned storage.
    pub fn into_owned(self) -> Event {
        match self {
            Self::Packet(value) => EventView::Packet(value),
            Self::Negotiation(value) => EventView::Negotiation(value.into_owned()),
            Self::Lifecycle(value) => EventView::Lifecycle(value.into_owned()),
            Self::Path(value) => EventView::Path(value),
            Self::Drop(value) => EventView::Drop(value),
        }
    }

    /// Copy this event into independent owned storage.
    pub fn to_owned(&self) -> Event {
        self.clone().into_owned()
    }

    /// Owned heap bytes currently retained, excluding inline fields and allocator metadata.
    pub fn heap_size(&self) -> usize {
        match self {
            Self::Negotiation(value) => value.heap_size(),
            Self::Lifecycle(value) => value.heap_size(),
            Self::Packet(_) | Self::Path(_) | Self::Drop(_) => 0,
        }
    }

    /// Conservative owned heap bytes after retaining this observation.
    pub fn owned_heap_size(&self) -> usize {
        match self {
            Self::Negotiation(value) => value.owned_heap_size(),
            Self::Lifecycle(value) => value.owned_heap_size(),
            Self::Packet(_) | Self::Path(_) | Self::Drop(_) => 0,
        }
    }
}

fn serialize_cid<S: Serializer>(value: &ConnectionId, serializer: S) -> Result<S::Ok, S::Error> {
    rama_utils::bytes::serde_hex::serialize(&value[..], serializer)
}

#[derive(Serialize)]
struct Cid<'a>(#[serde(serialize_with = "serialize_cid")] &'a ConnectionId);

#[expect(
    clippy::ref_option,
    reason = "serde serialize_with receives a reference to the Option field"
)]
fn serialize_optional_cid<S: Serializer>(
    value: &Option<ConnectionId>,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    value.as_ref().map(Cid).serialize(serializer)
}

fn serialize_cids<S: Serializer>(value: &[ConnectionId], serializer: S) -> Result<S::Ok, S::Error> {
    let mut sequence = serializer.serialize_seq(Some(value.len()))?;
    for cid in value {
        sequence.serialize_element(&Cid(cid))?;
    }
    sequence.end()
}

#[cfg(test)]
mod tests;
