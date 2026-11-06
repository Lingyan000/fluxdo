//! Applying a QUIC wire profile to this engine's configuration.
//!
//! The [`QuicProfile`] descriptor and its parts live in [`rama_quic_proto::profile`]; this module
//! turns one into this engine's [`EndpointConfig`], [`ClientConfig`] and [`ServerConfig`], and
//! reads a first flight back through [`capture`].

use std::{error::Error, fmt, sync::Arc};

use rama_core::telemetry::tracing;
use rama_quic_proto::{VarInt, profile::*};

pub mod capture;

#[cfg(feature = "ua")]
pub mod replay;

#[cfg(all(
    test,
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )
))]
pub(crate) mod browsers;

#[cfg(all(
    test,
    any(
        feature = "boring",
        all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
    )
))]
mod tests;

use crate::proto::{
    ClientConfig, ConfigError, EndpointConfig, ServerConfig, TransportConfig,
    cid_generator::{ConnectionIdGenerator as _, RandomConnectionIdGenerator},
    cid_queue::CidQueue,
};

/// Largest `active_connection_id_limit` this engine can advertise without
/// discarding a connection ID the peer is entitled to keep active.
pub const MAX_ACTIVE_CONNECTION_ID_LIMIT: u64 = CidQueue::LIMIT;

/// The parts of a profile a connection consults as it forms packets.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct WireProfile {
    pub(crate) parameters: TransportParameterProfile,
    pub(crate) packetization: PacketizationProfile,
    endpoint: Option<EndpointProfile>,
}

/// An endpoint-wide setting that contradicts a connection's QUIC profile.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProfileEndpointMismatch {
    /// The endpoint generates local connection IDs of a different length.
    ConnectionIdLength,
    /// The endpoint advertises a different QUIC fixed-bit greasing policy.
    QuicBitGreasing,
    /// The endpoint advertises a different maximum received UDP payload.
    MaximumUdpPayload,
}

impl fmt::Display for ProfileEndpointMismatch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::ConnectionIdLength => "QUIC profile disagrees with endpoint connection ID length",
            Self::QuicBitGreasing => "QUIC profile disagrees with endpoint fixed-bit greasing",
            Self::MaximumUdpPayload => "QUIC profile disagrees with endpoint maximum UDP payload",
        })
    }
}

impl Error for ProfileEndpointMismatch {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct EndpointProfile {
    cid_len: usize,
    grease_quic_bit: bool,
    max_udp_payload_size: u64,
}

impl Default for WireProfile {
    fn default() -> Self {
        Self {
            parameters: TransportParameterProfile::standard(),
            packetization: PacketizationProfile::standard(),
            endpoint: None,
        }
    }
}

impl WireProfile {
    /// Zero-CID emulation uses one socket per connection, including supplied endpoints.
    pub(crate) fn requires_dedicated_endpoint(&self) -> bool {
        self.endpoint.is_some_and(|profile| profile.cid_len == 0)
    }

    pub(crate) fn validate_endpoint(
        &self,
        config: &EndpointConfig,
        cid_len: usize,
    ) -> Result<(), ProfileEndpointMismatch> {
        let Some(expected) = self.endpoint else {
            return Ok(());
        };

        if expected.cid_len != cid_len {
            return Err(ProfileEndpointMismatch::ConnectionIdLength);
        }
        if expected.grease_quic_bit != config.grease_quic_bit {
            return Err(ProfileEndpointMismatch::QuicBitGreasing);
        }
        // A constrained socket advertises at most what it carries (the profile's value otherwise).
        let expected_payload = config
            .payload_ceiling
            .map_or(expected.max_udp_payload_size, |ceiling| {
                expected.max_udp_payload_size.min(u64::from(ceiling))
            });
        if expected_payload != config.get_max_udp_payload_size() {
            return Err(ProfileEndpointMismatch::MaximumUdpPayload);
        }
        Ok(())
    }

    fn of(profile: &QuicProfile) -> Self {
        Self {
            parameters: profile.transport_parameters().clone(),
            packetization: profile.packetization().clone(),
            endpoint: Some(EndpointProfile {
                cid_len: usize::from(profile.connection_ids().local_len()),
                grease_quic_bit: profile.greases_quic_bit(),
                max_udp_payload_size: profile.limits().max_udp_payload_size,
            }),
        }
    }
}

impl TransportConfig {
    /// A transport configuration advertising this profile's limits and carrying its layout.
    /// Everything else keeps [`TransportConfig::default`]. See [`Self::try_with_quic_profile`]
    /// for the parts this engine lowers. Connection creation also checks that the
    /// endpoint-wide settings match this profile.
    pub fn from_quic_profile(profile: &QuicProfile) -> Result<Self, ConfigError> {
        Self::default().try_with_quic_profile(profile)
    }

    /// This configuration advertising `profile`'s limits and carrying its layout; every other
    /// setting stays as it is.
    ///
    /// An `active_connection_id_limit` above [`MAX_ACTIVE_CONNECTION_ID_LIMIT`] is clamped to
    /// it, and a `max_datagram_frame_size` without a datagram receive buffer is dropped;
    /// both are traced.
    pub fn try_with_quic_profile(self, profile: &QuicProfile) -> Result<Self, ConfigError> {
        let limits = profile.limits();
        let mut wire = WireProfile::of(profile);
        if limits.datagram_receive_buffer_size.is_none()
            && let Some(size) = wire.parameters.max_datagram_frame_size()
        {
            tracing::debug!(
                size,
                "QUIC profile drops max_datagram_frame_size: datagram reception is disabled"
            );
            wire.parameters = wire
                .parameters
                .try_with_max_datagram_frame_size(None)
                .map_err(|_error| ConfigError::OutOfBounds)?;
        }
        let initial_max_streams_bidi = VarInt::from_u64(limits.initial_max_streams_bidi)?;
        let initial_max_streams_uni = VarInt::from_u64(limits.initial_max_streams_uni)?;
        let initial_max_data = VarInt::from_u64(limits.initial_max_data)?;
        let initial_max_stream_data_bidi_local =
            VarInt::from_u64(limits.initial_max_stream_data_bidi_local)?;
        let initial_max_stream_data_bidi_remote =
            VarInt::from_u64(limits.initial_max_stream_data_bidi_remote)?;
        let initial_max_stream_data_uni = VarInt::from_u64(limits.initial_max_stream_data_uni)?;
        let mut config = self
            .with_max_concurrent_bidi_streams(initial_max_streams_bidi)
            .with_max_concurrent_uni_streams(initial_max_streams_uni)
            .with_receive_window(initial_max_data)
            .with_stream_receive_window(initial_max_stream_data_bidi_local)
            .with_stream_receive_window_bidi_remote(initial_max_stream_data_bidi_remote)
            .with_stream_receive_window_uni(initial_max_stream_data_uni)
            .maybe_with_datagram_receive_buffer_size(limits.datagram_receive_buffer_size)
            .with_wire(wire);
        // Initial datagrams cannot exceed the path's current MTU, so a profile that pads them
        // larger raises the starting MTU to match.
        config = config.with_initial_mtu(profile.packetization().initial_datagram_size());
        config.try_set_max_ack_delay(limits.max_ack_delay)?;
        let idle = u64::try_from(limits.max_idle_timeout.as_millis())?;
        config.maybe_set_max_idle_timeout(if idle == 0 {
            None
        } else {
            Some(VarInt::from_u64(idle)?.into())
        });
        let cid_limit = limits
            .active_connection_id_limit
            .map(|limit| {
                if limit > MAX_ACTIVE_CONNECTION_ID_LIMIT {
                    tracing::debug!(
                        limit,
                        local = MAX_ACTIVE_CONNECTION_ID_LIMIT,
                        "QUIC profile clamps active_connection_id_limit to retained CID storage"
                    );
                }
                VarInt::from_u64(limit.min(MAX_ACTIVE_CONNECTION_ID_LIMIT))
            })
            .transpose()?;
        config.try_maybe_set_active_connection_id_limit(cid_limit)?;
        Ok(config)
    }
}

impl EndpointConfig {
    /// Apply the endpoint-wide parts of a profile: local connection ID length, QUIC bit greasing
    /// and the advertised maximum UDP payload.
    pub fn apply_quic_profile(&mut self, profile: &QuicProfile) -> Result<(), ConfigError> {
        let len = usize::from(profile.connection_ids().local_len());
        self.set_connection_id_generator_factory(Arc::new(move || {
            #[expect(
                clippy::expect_used,
                reason = "`try_with_local_len` bounds the length to what the generator accepts"
            )]
            Box::new(RandomConnectionIdGenerator::new(len).expect("a valid connection ID length"))
        }));
        self.set_grease_quic_bit(profile.greases_quic_bit());
        let payload = u16::try_from(profile.limits().max_udp_payload_size)
            .map_err(|_error| ConfigError::OutOfBounds)?;
        self.max_udp_payload_size(payload)?;
        Ok(())
    }
}

impl ClientConfig {
    /// Apply the client parts of a profile: the version policy, the first destination connection
    /// ID length and a transport configuration with this profile's limits and layout.
    pub fn apply_quic_profile(&mut self, profile: &QuicProfile) -> Result<(), ConfigError> {
        // Validate every fallible component before changing the live configuration.
        // A rejected profile must leave a caller's reusable defaults intact.
        let transport = Arc::new(TransportConfig::from_quic_profile(profile)?);
        self.set_versions(profile.versions().clone())?;
        let len = usize::from(profile.connection_ids().initial_destination_len());
        self.set_initial_dst_cid_provider(Arc::new(move || {
            #[expect(
                clippy::expect_used,
                reason = "`try_with_initial_destination_len` bounds the length to what the generator accepts"
            )]
            RandomConnectionIdGenerator::new(len)
                .expect("a valid connection ID length")
                .generate_cid()
        }));
        self.set_transport_config(transport);
        Ok(())
    }
}

impl ServerConfig {
    /// Apply the server parts of a profile: a transport configuration with this profile's limits
    /// and layout.
    pub fn apply_quic_profile(&mut self, profile: &QuicProfile) -> Result<(), ConfigError> {
        self.set_transport_config(Arc::new(TransportConfig::from_quic_profile(profile)?));
        Ok(())
    }
}
