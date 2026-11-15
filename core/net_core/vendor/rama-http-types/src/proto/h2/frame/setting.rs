use super::Error;
use rama_core::bytes::{BufMut as _, BytesMut};
use rama_core::telemetry::tracing;
use rama_utils::collections::smallvec::{self, SmallVec};
use rama_utils::macros::enums::enum_builder;
use rama_utils::octets::{unpack_octets_as_u16, unpack_octets_as_u32};
use serde::{Deserialize, Serialize};
use std::hash::{Hash, Hasher};

/// A struct representing the combination of a [`SettingId`] with its u32 value.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Setting {
    pub id: SettingId,
    pub value: u32,
}

enum_builder! {
    /// An enum that lists all valid settings that can be sent in a SETTINGS
    /// frame.
    ///
    /// Each setting has a value that is a 32 bit unsigned integer (6.5.1.).
    ///
    /// See <https://datatracker.ietf.org/doc/html/rfc9113#name-defined-settings.
    @U16
    pub enum SettingId {
        /// This setting allows the sender to inform the remote endpoint
        /// of the maximum size of the compression table used to decode field blocks,
        /// in units of octets. The encoder can select any size equal to or less than
        /// this value by using signaling specific to the compression format inside
        /// a field block (see [COMPRESSION]). The initial value is 4,096 octets.
        ///
        /// [COMPRESSION]: https://datatracker.ietf.org/doc/html/rfc7541
        HeaderTableSize => 0x0001,
        /// This setting can be used to enable or disable server push.
        /// A server MUST NOT send a PUSH_PROMISE frame if it receives this
        /// parameter set to a value of 0; see Section 8.4. A client that has
        /// both set this parameter to 0 and had it acknowledged MUST treat the
        /// receipt of a PUSH_PROMISE frame as a connection error (Section 5.4.1)
        /// of type PROTOCOL_ERROR.
        ///
        /// The initial value of SETTINGS_ENABLE_PUSH is 1.
        /// For a client, this value indicates that it is willing to
        /// receive PUSH_PROMISE frames. For a server,
        /// this initial value has no effect,
        /// and is equivalent to the value 0.
        /// Any value other than 0 or 1 MUST be treated as
        /// a connection error (Section 5.4.1) of type PROTOCOL_ERROR.
        ///
        /// A server MUST NOT explicitly set this value to 1. A server
        /// MAY choose to omit this setting when it sends a SETTINGS frame,
        /// but if a server does include a value, it MUST be 0.
        /// A client MUST treat receipt of a SETTINGS frame with
        /// SETTINGS_ENABLE_PUSH set to 1 as a connection error (Section 5.4.1)
        /// of type PROTOCOL_ERROR.
        EnablePush => 0x0002,
        /// This setting indicates the maximum number of concurrent streams
        /// that the sender will allow. This limit is directional: it applies
        /// to the number of streams that the sender permits the receiver to create.
        /// Initially, there is no limit to this value.
        /// It is recommended that this value be no smaller than 100,
        /// so as to not unnecessarily limit parallelism.
        ///
        /// A value of 0 for SETTINGS_MAX_CONCURRENT_STREAMS SHOULD NOT be treated as
        /// special by endpoints. A zero value does prevent the creation
        /// of new streams; however, this can also happen for any limit
        /// that is exhausted with active streams. Servers SHOULD only
        /// set a zero value for short durations; if a server does not
        /// wish to accept requests, closing the connection is more appropriate.
        MaxConcurrentStreams => 0x0003,
        /// This setting indicates the sender's initial window size
        /// (in units of octets) for stream-level flow control.
        /// The initial value is 216-1 (65,535) octets.
        ///
        /// This setting affects the window size of all streams (see Section 6.9.2).
        ///
        /// Values above the maximum flow-control window size
        /// of 231-1 MUST be treated as a connection error (Section 5.4.1)
        /// of type FLOW_CONTROL_ERROR.
        InitialWindowSize => 0x0004,
        /// his setting indicates the size of the largest frame payload
        /// that the sender is willing to receive, in units of octets.
        ///
        /// The initial value is 214 (16,384) octets.
        /// The value advertised by an endpoint MUST be between
        /// this initial value and the maximum allowed frame size
        /// (224-1 or 16,777,215 octets), inclusive.
        /// Values outside this range MUST be treated as a connection error
        /// (Section 5.4.1) of type PROTOCOL_ERROR.
        MaxFrameSize => 0x0005,
        /// This advisory setting informs a peer of the maximum field section
        /// size that the sender is prepared to accept,
        /// in units of octets. The value is based
        /// on the uncompressed size of field lines,
        /// including the length of the name and value
        /// in units of octets plus an overhead of 32 octets
        /// for each field line.
        ///
        /// For any given request, a lower limit than what is advertised
        /// MAY be enforced. The initial value of this setting is unlimited.
        MaxHeaderListSize => 0x0006,
        /// EnableConnectProtocol, if true, enables support for
        /// the Extended CONNECT protocol defined in [RFC 8441].
        /// When enabled, HTTP/2 servers will advertise support for Extended CONNECT.
        /// Extended CONNECT requests will include a ":protocol" pseudo header
        /// in the request headers.
        ///
        /// [RFC 8441]: https://datatracker.ietf.org/doc/html/rfc8441
        EnableConnectProtocol => 0x0008,
        /// Disable RFC 7540 Stream Priorities.
        ///
        /// [RFC 9218]: https://datatracker.ietf.org/doc/html/rfc9218
        NoRfc7540Priorities => 0x0009,
    }
}

impl SettingId {
    const DEFAULT_MASK: u16 = 0b_0000_0001_1011_1111;

    /// Whether this identifier has the `0x?a?a` form clients use to grease SETTINGS.
    #[must_use]
    pub fn is_grease(self) -> bool {
        u16::from(self) & 0x0f0f == 0x0a0a
    }

    fn mask_id(self) -> u16 {
        let n = u16::from(self);
        if n == 0 || n > 15 {
            return 0;
        }
        1 << ((u16::from(self) - 1) as usize)
    }
}

impl Setting {
    /// Creates a new [`Setting`] with the correct variant corresponding to the
    /// given setting id, based on the settings IDs defined in section
    /// 6.5.2.
    pub fn new(id: impl Into<SettingId>, value: u32) -> Self {
        Self {
            id: id.into(),
            value,
        }
    }

    /// Creates a new `Setting` by parsing the given buffer of 6 bytes, which
    /// contains the raw byte representation of the setting, according to the
    /// "SETTINGS format" defined in section 6.5.1.
    ///
    /// Errors with [`Error::ShortBuffer`] when `raw.len() < 6`.
    pub fn load(raw: &[u8]) -> Result<Self, Error> {
        if raw.len() < 6 {
            return Err(Error::ShortBuffer {
                needed: 6,
                got: raw.len(),
            });
        }
        let id: u16 = unpack_octets_as_u16(raw, 0);
        let val: u32 = unpack_octets_as_u32(raw, 2);

        Ok(Self::new(id, val))
    }

    pub fn encode(&self, dst: &mut BytesMut) {
        dst.put_u16(self.id.into());
        dst.put_u32(self.value);
    }
}

impl Serialize for Setting {
    #[inline]
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        (&self.id, &self.value).serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for Setting {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let (id, value) = <(SettingId, u32)>::deserialize(deserializer)?;
        Ok(Self::new(id, value))
    }
}

const SETTING_ORDER_STACK_SIZE: usize = 8;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SettingOrder {
    ids: SmallVec<[SettingId; SETTING_ORDER_STACK_SIZE]>,
    mask: u16,
}

impl SettingOrder {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub(super) const DEFAULT_SETTINGS: [SettingId; 8] = [
        SettingId::HeaderTableSize,
        SettingId::EnablePush,
        SettingId::InitialWindowSize,
        SettingId::MaxConcurrentStreams,
        SettingId::MaxFrameSize,
        SettingId::MaxHeaderListSize,
        SettingId::EnableConnectProtocol,
        SettingId::NoRfc7540Priorities,
    ];

    #[must_use]
    pub fn default_settings() -> Self {
        Self::DEFAULT_SETTINGS.into_iter().collect()
    }

    pub(super) fn contains_standard(&self, id: SettingId) -> bool {
        self.mask & id.mask_id() != 0
    }

    pub fn push(&mut self, id: SettingId) {
        let mask_id = id.mask_id();
        if self.mask & mask_id == 0 {
            self.mask |= mask_id;
            self.ids.push(id);
        } else {
            tracing::trace!("ignore duplicate setting id: {id:?}")
        }
    }

    pub fn extend(&mut self, iter: impl IntoIterator<Item = SettingId>) {
        for header in iter {
            self.push(header);
        }
    }

    pub fn extend_with_default(&mut self) {
        if self.mask & SettingId::DEFAULT_MASK == SettingId::DEFAULT_MASK {
            return;
        }
        self.extend(Self::default_settings());
    }

    pub fn iter(&self) -> impl Iterator<Item = SettingId> + Clone {
        self.ids.iter().copied()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.ids.len()
    }
}

impl IntoIterator for SettingOrder {
    type Item = SettingId;
    type IntoIter = smallvec::IntoIter<[SettingId; SETTING_ORDER_STACK_SIZE]>;

    fn into_iter(self) -> Self::IntoIter {
        self.ids.into_iter()
    }
}

impl FromIterator<SettingId> for SettingOrder {
    fn from_iter<T: IntoIterator<Item = SettingId>>(iter: T) -> Self {
        let mut this = Self::default();
        for header in iter {
            this.push(header);
        }
        this
    }
}

impl<'a> FromIterator<&'a SettingId> for SettingOrder {
    fn from_iter<T: IntoIterator<Item = &'a SettingId>>(iter: T) -> Self {
        let mut this = Self::default();
        for header in iter {
            this.push(*header);
        }
        this
    }
}

impl Serialize for SettingOrder {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        self.ids.serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for SettingOrder {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let v = <Vec<SettingId>>::deserialize(deserializer)?;
        Ok(v.into_iter().collect())
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SettingsConfig {
    /// See [`SettingId::HeaderTableSize`] for more info.
    pub header_table_size: Option<u32>,
    /// See [`SettingId::EnablePush`] for more info.
    pub enable_push: Option<u32>,
    /// See [`SettingId::MaxConcurrentStreams`] for more info.
    pub max_concurrent_streams: Option<u32>,
    /// See [`SettingId::InitialWindowSize`] for more info.
    pub initial_window_size: Option<u32>,
    /// See [`SettingId::MaxFrameSize`] for more info.
    pub max_frame_size: Option<u32>,
    /// See [`SettingId::MaxHeaderListSize`] for more info.
    pub max_header_list_size: Option<u32>,
    /// See [`SettingId::EnableConnectProtocol`] for more info.
    pub enable_connect_protocol: Option<u32>,
    /// See [`SettingId::NoRfc7540Priorities`] for more info.
    pub no_rfc7540_priorities: Option<u32>,
    /// Order in which settings appeared.
    pub setting_order: Option<SettingOrder>,
}

impl SettingsConfig {
    pub fn merge(&mut self, other: Self) {
        macro_rules! merge_fields {
            ($($field:ident),+$(,)?) => {
                $(
                    if let Some(value) = other.$field {
                        self.$field = Some(value);
                    }
                )+
            };
        }

        merge_fields!(
            header_table_size,
            enable_push,
            max_concurrent_streams,
            initial_window_size,
            max_frame_size,
            max_header_list_size,
            enable_connect_protocol,
            no_rfc7540_priorities,
            setting_order,
        );
    }
}

impl PartialEq for SettingsConfig {
    fn eq(&self, other: &Self) -> bool {
        let Self {
            header_table_size,
            enable_push,
            max_concurrent_streams,
            initial_window_size,
            max_frame_size,
            max_header_list_size,
            enable_connect_protocol,
            no_rfc7540_priorities,
            setting_order: _,
        } = self;

        let Self {
            header_table_size: other_header_table_size,
            enable_push: other_enable_push,
            max_concurrent_streams: other_max_concurrent_streams,
            initial_window_size: other_initial_window_size,
            max_frame_size: other_max_frame_size,
            max_header_list_size: other_max_header_list_size,
            enable_connect_protocol: other_enable_connect_protocol,
            no_rfc7540_priorities: other_no_rfc7540_priorities,
            setting_order: _,
        } = other;

        header_table_size == other_header_table_size
            && enable_push == other_enable_push
            && max_concurrent_streams == other_max_concurrent_streams
            && initial_window_size == other_initial_window_size
            && max_frame_size == other_max_frame_size
            && max_header_list_size == other_max_header_list_size
            && enable_connect_protocol == other_enable_connect_protocol
            && no_rfc7540_priorities == other_no_rfc7540_priorities
    }
}

impl Eq for SettingsConfig {}

// Like semantic equality, hashing excludes the outgoing occurrence order.
impl Hash for SettingsConfig {
    fn hash<H: Hasher>(&self, state: &mut H) {
        let Self {
            header_table_size,
            enable_push,
            max_concurrent_streams,
            initial_window_size,
            max_frame_size,
            max_header_list_size,
            enable_connect_protocol,
            no_rfc7540_priorities,
            setting_order: _,
        } = self;

        (
            header_table_size,
            enable_push,
            max_concurrent_streams,
            initial_window_size,
            max_frame_size,
            max_header_list_size,
            enable_connect_protocol,
            no_rfc7540_priorities,
        )
            .hash(state);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::hash_map::DefaultHasher;

    #[test]
    fn grease_ids_have_the_reserved_nibbles() {
        for id in [0x0a0a, 0x4a4a, 0x1aba, 0xfafa] {
            assert!(SettingId::from(id).is_grease(), "{id:#x}");
        }
        for id in [0x0001, 0x0009, 0x0a0b, 0xface] {
            assert!(!SettingId::from(id).is_grease(), "{id:#x}");
        }
    }

    #[test]
    fn semantic_hash_ignores_order_but_tracks_settings() {
        let initial = SettingsConfig {
            header_table_size: Some(4096),
            initial_window_size: Some(65535),
            setting_order: Some(
                [SettingId::HeaderTableSize, SettingId::InitialWindowSize]
                    .into_iter()
                    .collect(),
            ),
            ..SettingsConfig::default()
        };
        let mut reordered = initial.clone();
        reordered.setting_order = Some(
            [SettingId::InitialWindowSize, SettingId::HeaderTableSize]
                .into_iter()
                .collect(),
        );
        let mut omitted_order = initial.clone();
        omitted_order.setting_order = None;
        let mut changed = initial.clone();
        changed.header_table_size = Some(8192);

        let hash = |config: &SettingsConfig| {
            let mut state = DefaultHasher::new();
            config.hash(&mut state);
            state.finish()
        };
        assert_eq!(initial, reordered);
        assert_eq!(initial, omitted_order);
        assert_eq!(hash(&initial), hash(&reordered));
        assert_eq!(hash(&initial), hash(&omitted_order));
        assert_ne!(initial, changed);
        assert_ne!(hash(&initial), hash(&changed));
    }

    #[test]
    fn test_extend_with_default() {
        let mut order = SettingOrder::default();
        assert!(order.is_empty());
        order.extend_with_default();
        assert_eq!(order.len(), SETTING_ORDER_STACK_SIZE);
        let orig_order = order.clone();
        let n = order.len();
        order.extend_with_default();
        assert_eq!(order.len(), n);
        assert_eq!(order, orig_order);
    }

    #[test]
    fn test_extend_with_default_fill() {
        let mut order: SettingOrder = [SettingId::Unknown(0x42)].into_iter().collect();
        order.extend_with_default();
        assert_eq!(order.len(), SETTING_ORDER_STACK_SIZE + 1);
    }
}
