use std::fmt;

use super::{
    Error, Frame, FrameSize, Head, Kind, Setting, SettingId, SettingOrder, SettingsConfig,
    StreamId, util,
};

use rama_core::bytes::BytesMut;
use rama_core::telemetry::tracing;
use serde::{Deserialize, Serialize};

#[derive(Clone, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct Settings {
    pub flags: SettingsFlags,
    pub config: SettingsConfig,
    /// Optional bounded wire observation. Semantic configuration is independent.
    #[serde(skip)]
    pub observation: Option<Box<SettingsObservation>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingsObservation {
    pub entries: Box<[Setting]>,
    pub complete: bool,
    exact_replay: bool,
    replay_config: Option<SettingsConfig>,
}

#[derive(Copy, Clone, Eq, PartialEq, Default, Serialize, Deserialize)]
pub struct SettingsFlags(u8);

const ACK: u8 = 0x1;
const ALL: u8 = ACK;

/// The default value of SETTINGS_HEADER_TABLE_SIZE
pub const DEFAULT_SETTINGS_HEADER_TABLE_SIZE: usize = 4_096;

/// The default value of SETTINGS_INITIAL_WINDOW_SIZE
pub const DEFAULT_INITIAL_WINDOW_SIZE: u32 = 65_535;

/// The default value of MAX_FRAME_SIZE
pub const DEFAULT_MAX_FRAME_SIZE: FrameSize = 16_384;

/// INITIAL_WINDOW_SIZE upper bound
const MAX_INITIAL_WINDOW_SIZE: usize = (1 << 31) - 1;

/// MAX_FRAME_SIZE upper bound
pub const MAX_MAX_FRAME_SIZE: FrameSize = (1 << 24) - 1;

// ===== impl Settings =====

impl Settings {
    #[must_use]
    pub fn ack() -> Self {
        Self {
            flags: SettingsFlags::ack(),
            ..Self::default()
        }
    }

    rama_utils::macros::generate_set_and_with! {
        pub fn config(mut self, config: SettingsConfig) -> Self {
            self.config = config;
            self.observation = None;
            self
        }
    }

    pub fn merge(&mut self, other: Self) {
        self.config.merge(other.config);
        self.observation = None;
    }

    /// Build a SETTINGS frame from validated entries in their original wire order.
    ///
    /// Unlike [`SettingsConfig`], this retains unknown identifiers and repeated
    /// occurrences. Any later semantic configuration change discards the exact
    /// sequence so stale wire values cannot override the new configuration.
    pub fn from_ordered_entries(entries: Box<[Setting]>) -> Result<Self, Error> {
        let mut payload = BytesMut::with_capacity(entries.len().saturating_mul(6));
        for entry in &entries {
            entry.encode(&mut payload);
        }
        let mut settings = Self::load(Head::new(Kind::Settings, 0, StreamId::zero()), &payload)?;
        settings.observation = Some(Box::new(SettingsObservation {
            entries,
            complete: true,
            exact_replay: true,
            replay_config: Some(settings.config.clone()),
        }));
        Ok(settings)
    }

    /// Produce a validated literal non-ACK frame, retaining complete observed order.
    ///
    /// Reject incomplete observations or semantic changes made after observation.
    /// Without an observation, preserve the explicitly configured fields and order.
    pub fn to_literal(&self) -> Result<Self, Error> {
        if self.flags.is_ack() {
            return Err(Error::InvalidSettingValue);
        }
        if let Some(observation) = &self.observation {
            if !observation.complete {
                return Err(Error::InvalidSettingValue);
            }
            let literal = Self::from_ordered_entries(observation.entries.clone())?;
            if literal.config != self.config
                || literal.config.setting_order != self.config.setting_order
            {
                return Err(Error::InvalidSettingValue);
            }
            return Ok(literal);
        }
        Self::from_ordered_entries(self.encoded_entries().collect())
    }

    pub fn load(head: Head, payload: &[u8]) -> Result<Self, Error> {
        Self::load_inner(head, payload, Some(usize::MAX))
    }

    /// Decode semantic settings without allocating optional observation data.
    /// When enabled, at most 256 ordered occurrences are retained. Exceeding the
    /// observation limit does not reject otherwise valid peer settings.
    pub fn load_observed(head: Head, payload: &[u8], observe: bool) -> Result<Self, Error> {
        let mut settings = Self::load_inner(head, payload, observe.then_some(256))?;
        if observe {
            const MAXIMUM: usize = 256;
            let count = payload.len() / 6;
            let entries = payload
                .as_chunks::<6>()
                .0
                .iter()
                .take(MAXIMUM)
                .map(|entry| Setting::load(entry))
                .collect::<Result<Vec<_>, _>>()?;
            settings.observation = Some(Box::new(SettingsObservation {
                entries: entries.into_boxed_slice(),
                complete: count <= MAXIMUM,
                exact_replay: false,
                replay_config: None,
            }));
        }
        Ok(settings)
    }

    fn load_inner(head: Head, payload: &[u8], order_limit: Option<usize>) -> Result<Self, Error> {
        debug_assert_eq!(head.kind(), super::Kind::Settings);

        if !head.stream_id().is_zero() {
            return Err(Error::InvalidStreamId);
        }

        // Load the flag
        let flag = SettingsFlags::load(head.flag());

        if flag.is_ack() {
            // Ensure that the payload is empty
            if !payload.is_empty() {
                return Err(Error::InvalidPayloadLength);
            }

            // Return the ACK frame
            return Ok(Self::ack());
        }

        // Ensure the payload length is correct, each setting is 6 bytes long.
        if !payload.len().is_multiple_of(6) {
            tracing::debug!("invalid settings payload length; len={:?}", payload.len());
            return Err(Error::InvalidPayloadAckSettings);
        }

        let mut settings = Self::default();
        debug_assert!(!settings.flags.is_ack());

        let mut setting_order = SettingOrder::default();

        for raw in payload.chunks(6) {
            let setting = Setting::load(raw)?;
            if order_limit.is_some_and(|limit| setting_order.len() < limit) {
                setting_order.push(setting.id);
            }
            match setting.id {
                SettingId::HeaderTableSize => {
                    settings.config.header_table_size = Some(setting.value);
                }
                SettingId::EnablePush => match setting.value {
                    0 | 1 => {
                        settings.config.enable_push = Some(setting.value);
                    }
                    _ => {
                        return Err(Error::InvalidSettingValue);
                    }
                },
                SettingId::MaxConcurrentStreams => {
                    settings.config.max_concurrent_streams = Some(setting.value);
                }
                SettingId::InitialWindowSize => {
                    if setting.value as usize > MAX_INITIAL_WINDOW_SIZE {
                        // RFC 9113 §6.5.2: this is specifically a FLOW_CONTROL_ERROR,
                        // not a generic PROTOCOL_ERROR.
                        return Err(Error::InvalidInitialWindowSize);
                    } else {
                        settings.config.initial_window_size = Some(setting.value);
                    }
                }
                SettingId::MaxFrameSize => {
                    if (DEFAULT_MAX_FRAME_SIZE..=MAX_MAX_FRAME_SIZE).contains(&setting.value) {
                        settings.config.max_frame_size = Some(setting.value);
                    } else {
                        return Err(Error::InvalidSettingValue);
                    }
                }
                SettingId::MaxHeaderListSize => {
                    settings.config.max_header_list_size = Some(setting.value);
                }
                SettingId::EnableConnectProtocol => match setting.value {
                    0 | 1 => {
                        settings.config.enable_connect_protocol = Some(setting.value);
                    }
                    _ => {
                        return Err(Error::InvalidSettingValue);
                    }
                },
                SettingId::NoRfc7540Priorities => match setting.value {
                    0 | 1 => settings.config.no_rfc7540_priorities = Some(setting.value),
                    _ => return Err(Error::InvalidSettingValue),
                },
                SettingId::Unknown(id) => {
                    tracing::trace!(
                        "ignore unknown h2 frame setting w/ id {id}: value = {}",
                        setting.value
                    );
                }
            }
        }

        if !setting_order.is_empty() {
            settings.config.setting_order = Some(setting_order);
        }

        Ok(settings)
    }

    fn payload_len(&self) -> usize {
        self.encoded_entries().count() * 6
    }

    pub fn encode(&self, dst: &mut BytesMut) {
        // Create & encode an appropriate frame head
        let head = Head::new(Kind::Settings, self.flags.into(), StreamId::zero());
        let payload_len = self.payload_len();

        tracing::trace!("encoding SETTINGS; len={}", payload_len);

        head.encode(payload_len, dst);

        // Encode the settings
        for setting in self.encoded_entries() {
            tracing::trace!("encoding setting; val={:?}", setting);
            setting.encode(dst);
        }
    }

    /// Iterate over the ordered entries this frame will encode, without copying.
    ///
    /// A current literal replay retains duplicate and unknown occurrences.
    /// Otherwise entries follow the semantic configuration's explicit/default
    /// order. This is the outgoing representation, not an incomplete observation.
    /// Semantic [`SettingsConfig`] equality deliberately ignores this order.
    pub fn encoded_entries(&self) -> impl Iterator<Item = Setting> + Clone + '_ {
        let exact = self.observation.as_deref().filter(|observation| {
            !self.flags.is_ack()
                && observation.complete
                && observation.exact_replay
                && observation.replay_config.as_ref().is_some_and(|config| {
                    config == &self.config && config.setting_order == self.config.setting_order
                })
        });
        let semantic = exact
            .is_none()
            .then_some(&self.config)
            .into_iter()
            .flat_map(|config| {
                let order = config.setting_order.as_ref();
                let explicit = order.into_iter().flat_map(SettingOrder::iter);
                let defaults = SettingOrder::DEFAULT_SETTINGS
                    .into_iter()
                    .filter(move |id| order.is_none_or(|order| !order.contains_standard(*id)));
                explicit.chain(defaults).filter_map(move |id| {
                    let value = match id {
                        SettingId::HeaderTableSize => config.header_table_size,
                        SettingId::EnablePush => config.enable_push,
                        SettingId::MaxConcurrentStreams => config.max_concurrent_streams,
                        SettingId::InitialWindowSize => config.initial_window_size,
                        SettingId::MaxFrameSize => config.max_frame_size,
                        SettingId::MaxHeaderListSize => config.max_header_list_size,
                        SettingId::EnableConnectProtocol => config.enable_connect_protocol,
                        SettingId::NoRfc7540Priorities => config.no_rfc7540_priorities,
                        SettingId::Unknown(_) => None,
                    };
                    value.map(|value| Setting { id, value })
                })
            });
        exact
            .into_iter()
            .flat_map(|observation| observation.entries.iter().copied())
            .chain(semantic)
    }
}

impl<T> From<Settings> for Frame<T> {
    fn from(src: Settings) -> Self {
        Self::Settings(src)
    }
}

impl fmt::Debug for Settings {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        let mut builder = f.debug_struct("Settings");
        builder.field("flags", &self.flags);
        builder.field("config", &self.config);
        builder.finish()
    }
}

// ===== impl SettingsFlags =====

impl SettingsFlags {
    pub fn empty() -> Self {
        Self(0)
    }

    pub fn load(bits: u8) -> Self {
        Self(bits & ALL)
    }

    pub fn ack() -> Self {
        Self(ACK)
    }

    pub fn is_ack(self) -> bool {
        self.0 & ACK == ACK
    }
}

impl From<SettingsFlags> for u8 {
    fn from(src: SettingsFlags) -> Self {
        src.0
    }
}

impl fmt::Debug for SettingsFlags {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        util::debug_flags(f, self.0)
            .flag_if(self.is_ack(), "ACK")
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::assert_matches;

    /// RFC 9113 §6.5.2: a SETTINGS_INITIAL_WINDOW_SIZE value above
    /// 2^31-1 MUST be treated as a FLOW_CONTROL_ERROR — distinct from a
    /// generic PROTOCOL_ERROR. Verify the dedicated error variant fires.

    #[test]
    fn encoded_entries_match_emission_when_private_replay_snapshot_is_stale() {
        let original = Settings::from_ordered_entries(
            [
                Setting::new(2_u16, 0),
                Setting::new(0xa0a1_u16, 7),
                Setting::new(1_u16, 32),
                Setting::new(1_u16, 64),
            ]
            .into(),
        )
        .unwrap();
        let mut stale = original.clone();
        stale
            .observation
            .as_mut()
            .unwrap()
            .replay_config
            .as_mut()
            .unwrap()
            .setting_order = Some(
            [SettingId::HeaderTableSize, SettingId::EnablePush]
                .into_iter()
                .collect(),
        );
        assert_eq!(
            original, stale,
            "semantic Eq intentionally ignores snapshot order"
        );
        assert_ne!(
            original.encoded_entries().collect::<Vec<_>>(),
            stale.encoded_entries().collect::<Vec<_>>()
        );
        for frame in [original, stale] {
            let mut bytes = BytesMut::new();
            frame.encode(&mut bytes);
            let raw = bytes[9..]
                .as_chunks::<6>()
                .0
                .iter()
                .map(|entry| {
                    Setting::new(
                        u16::from_be_bytes(entry[..2].try_into().unwrap()),
                        u32::from_be_bytes(entry[2..].try_into().unwrap()),
                    )
                })
                .collect::<Vec<_>>();
            assert_eq!(frame.encoded_entries().collect::<Vec<_>>(), raw);
        }
    }

    #[test]
    fn settings_initial_window_size_overflow_is_flow_control_error() {
        let head = Head::new(Kind::Settings, 0, StreamId::zero());
        // SettingId::InitialWindowSize = 0x4, value = 2^31 (one over the cap).
        let mut payload = [0u8; 6];
        payload[0] = 0x00;
        payload[1] = 0x04; // setting id
        payload[2..6].copy_from_slice(&(1u32 << 31).to_be_bytes());

        let err = Settings::load(head, &payload).expect_err("must reject");
        assert_matches!(
            err,
            Error::InvalidInitialWindowSize,
            "expected InvalidInitialWindowSize, got {err:?}",
        );
    }

    /// A valid INITIAL_WINDOW_SIZE just at the boundary (2^31-1) must succeed.
    #[test]
    fn settings_initial_window_size_max_ok() {
        let head = Head::new(Kind::Settings, 0, StreamId::zero());
        let mut payload = [0u8; 6];
        payload[0] = 0x00;
        payload[1] = 0x04;
        payload[2..6].copy_from_slice(&((1u32 << 31) - 1).to_be_bytes());

        let settings = Settings::load(head, &payload).expect("must accept boundary");
        assert_eq!(settings.config.initial_window_size, Some((1 << 31) - 1));
    }
}

#[cfg(test)]
mod observation_tests {
    use super::*;
    use crate::proto::h2::frame::Kind;

    #[test]
    fn settings_observation_retains_unknowns_and_repeated_values_only_when_enabled() {
        let entries = [(1_u16, 100_u32), (0x42, 99), (1, 200), (0x42, 7)];
        let mut payload = Vec::new();
        for (id, value) in entries {
            payload.extend_from_slice(&id.to_be_bytes());
            payload.extend_from_slice(&value.to_be_bytes());
        }
        let head = Head::new(Kind::Settings, 0, StreamId::zero());
        let observed = Settings::load_observed(head, &payload, true).unwrap();
        assert_eq!(observed.config.header_table_size, Some(200));
        let wire = observed.observation.unwrap();
        assert!(wire.complete);
        assert_eq!(
            wire.entries
                .iter()
                .map(|entry| (u16::from(entry.id), entry.value))
                .collect::<Vec<_>>(),
            entries
        );
        let ordinary = Settings::load_observed(head, &payload, false).unwrap();
        assert_eq!(ordinary.config.header_table_size, Some(200));
        assert!(ordinary.observation.is_none());
        assert!(ordinary.config.setting_order.is_none());
        let legacy = Settings::load(head, &payload).unwrap();
        assert!(legacy.observation.is_none());
        assert!(legacy.config.setting_order.is_some());
    }

    #[test]
    fn settings_observation_caps_never_change_protocol_admission() {
        for count in [0, 1, 255, 256, 257, 1024] {
            let mut payload = Vec::new();
            for value in 0..count {
                payload.extend_from_slice(&0x42_u16.to_be_bytes());
                payload.extend_from_slice(&(value as u32).to_be_bytes());
            }
            let head = Head::new(Kind::Settings, 0, StreamId::zero());
            let observed = Settings::load_observed(head, &payload, true).unwrap();
            let wire = observed.observation.unwrap();
            assert_eq!(wire.entries.len(), count.min(256));
            assert_eq!(wire.complete, count <= 256);
            assert!(
                Settings::load_observed(head, &payload, false)
                    .unwrap()
                    .observation
                    .is_none()
            );
        }
        let head = Head::new(Kind::Settings, 0, StreamId::zero());
        for observe in [false, true] {
            Settings::load_observed(head, &[0, 2, 0, 0, 0, 2], observe).unwrap_err();
            Settings::load_observed(head, &[0], observe).unwrap_err();
            let ack = Head::new(Kind::Settings, 1, StreamId::zero());
            Settings::load_observed(ack, &[0; 6], observe).unwrap_err();
        }
    }

    #[test]
    fn exact_replay_preserves_unknown_and_repeated_settings() {
        let entries: Box<[_]> = [
            Setting::new(1_u16, 4_096),
            Setting::new(0xfefe_u16, 99),
            Setting::new(1_u16, 8_192),
        ]
        .into();
        let settings = Settings::from_ordered_entries(entries.clone()).unwrap();
        assert_eq!(settings.config.header_table_size, Some(8_192));

        let mut encoded = BytesMut::new();
        settings.encode(&mut encoded);
        assert_eq!(encoded.len(), 9 + entries.len() * 6);
        assert_eq!(
            &encoded[9..],
            &[
                0, 1, 0, 0, 16, 0, 0xfe, 0xfe, 0, 0, 0, 99, 0, 1, 0, 0, 32, 0,
            ]
        );
    }

    #[test]
    fn semantic_changes_discard_exact_replay_entries() {
        let exact = Settings::from_ordered_entries(
            [Setting::new(0xfefe_u16, 99), Setting::new(1_u16, 8_192)].into(),
        )
        .unwrap();

        let mut configured = exact.clone();
        configured.set_config(SettingsConfig {
            header_table_size: Some(1_024),
            ..Default::default()
        });
        assert!(configured.observation.is_none());
        let mut encoded = BytesMut::new();
        configured.encode(&mut encoded);
        assert_eq!(&encoded[9..], &[0, 1, 0, 0, 4, 0]);

        let mut merged = exact;
        merged.merge(Settings {
            config: SettingsConfig {
                header_table_size: Some(2_048),
                ..Default::default()
            },
            ..Default::default()
        });
        assert!(merged.observation.is_none());
        let mut encoded = BytesMut::new();
        merged.encode(&mut encoded);
        assert_eq!(&encoded[9..], &[0, 1, 0, 0, 8, 0]);

        let mut directly_changed = Settings::from_ordered_entries(
            [Setting::new(0xfefe_u16, 99), Setting::new(1_u16, 8_192)].into(),
        )
        .unwrap();
        directly_changed.config.header_table_size = Some(1_024);
        let mut encoded = BytesMut::new();
        directly_changed.encode(&mut encoded);
        assert_eq!(&encoded[9..], &[0, 1, 0, 0, 4, 0]);
    }

    #[test]
    fn exact_replay_rejects_invalid_setting_values() {
        assert!(matches!(
            Settings::from_ordered_entries([Setting::new(2_u16, 2)].into()),
            Err(Error::InvalidSettingValue),
        ));
    }
}

#[cfg(test)]
mod boolean_setting_tests {
    use super::*;

    #[test]
    fn all_boolean_settings_reject_non_boolean_values_on_every_decode_path() {
        let head = Head::new(Kind::Settings, 0, StreamId::zero());
        for id in [2u16, 8, 9] {
            for value in [0u32, 1, 2, 255, u32::MAX] {
                let payload: Vec<_> = id
                    .to_be_bytes()
                    .into_iter()
                    .chain(value.to_be_bytes())
                    .collect();
                for observe in [None, Some(false), Some(true)] {
                    let result = match observe {
                        None => Settings::load(head, &payload),
                        Some(observe) => Settings::load_observed(head, &payload, observe),
                    };
                    if value <= 1 {
                        result.unwrap();
                    } else {
                        assert!(
                            matches!(result, Err(Error::InvalidSettingValue)),
                            "id={id}, value={value}, observe={observe:?}"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn observed_settings_convert_to_literal_without_losing_wire_entries() {
        let payload = [
            0, 5, 0, 0, 128, 0, 0, 1, 0, 0, 0, 32, 0, 1, 0, 0, 0, 64, 0xa0, 0xa1, 0, 0, 0, 9,
        ];
        let head = Head::new(Kind::Settings, 0, StreamId::zero());
        let observed = Settings::load_observed(head, &payload, true).unwrap();
        let mut wire = BytesMut::new();
        observed.to_literal().unwrap().encode(&mut wire);
        assert_eq!(&wire[9..], payload);
        let mut changed = observed.clone();
        changed.config.max_frame_size = Some(65536);
        changed
            .to_literal()
            .expect_err("stale semantic values cannot become literal replay");
        let mut incomplete = observed;
        incomplete.observation.as_mut().unwrap().complete = false;
        incomplete
            .to_literal()
            .expect_err("incomplete observations cannot become literal replay");
        Settings::ack()
            .to_literal()
            .expect_err("ACK is not an initial SETTINGS promise");
    }
}
