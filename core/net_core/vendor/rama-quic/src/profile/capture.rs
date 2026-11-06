//! Engine glue for capturing a QUIC first flight.
//!
//! The crypto-free pipeline and its [`KeyProvider`] seam live in [`rama_quic_proto::capture`]; this
//! module supplies the Initial keys from the engine's TLS backend and offers the convenience entry
//! point the profile tests read a flight through.

use rama_quic_proto::{
    ConnectionId, Side, Version,
    capture::*,
    crypto::{HeaderKey, PacketKey},
};

use crate::proto::crypto::{InitialServerConfig, Keys};

/// Bridges an engine Initial-key implementation to the capture pipeline (RFC 9001 §5.2).
///
/// The built-in `RustlsTlsProvider` and `BoringTlsProvider` also
/// implement [`KeyProvider`] directly, without a certificate, private key or server configuration.
pub struct ProviderKeys<'a>(pub &'a dyn InitialServerConfig);

impl KeyProvider for ProviderKeys<'_> {
    // The engine's TLS backend hands back erased keys, so the seam carries them boxed.
    type Header = Box<dyn HeaderKey>;
    type Packet = Box<dyn PacketKey>;

    fn initial_keys(
        &self,
        version: Version,
        dcid: &[u8],
        side: Side,
    ) -> Result<InitialKeys<Self::Header, Self::Packet>, CaptureError> {
        let dcid = connection_id(dcid)?;
        let keys = self
            .0
            .initial_keys(version, &dcid)
            .map_err(|_error| CaptureError::Undecryptable)?;
        receiving_keys(keys, side)
    }
}

/// Read a client's first flight, deriving the Initial keys from `provider`.
pub fn first_flight(
    datagrams: &[&[u8]],
    provider: &dyn InitialServerConfig,
) -> Result<FirstFlight, CaptureError> {
    rama_quic_proto::capture::first_flight(datagrams, &ProviderKeys(provider))
}

pub(crate) fn connection_id(dcid: &[u8]) -> Result<ConnectionId, CaptureError> {
    ConnectionId::try_from_bytes(dcid)
        .map_err(|_error| CaptureError::Malformed("connection ID longer than 20 bytes"))
}

/// The engine derives this pair in the server role; a passive client opens its local packets.
pub(crate) fn receiving_keys(
    keys: Keys,
    side: Side,
) -> Result<InitialKeys<Box<dyn HeaderKey>, Box<dyn PacketKey>>, CaptureError> {
    let directional = match side {
        Side::Server => keys.remote.ok_or(CaptureError::Undecryptable)?,
        Side::Client => keys.local,
    };
    Ok(InitialKeys {
        header: directional.header,
        packet: directional.packet,
    })
}
