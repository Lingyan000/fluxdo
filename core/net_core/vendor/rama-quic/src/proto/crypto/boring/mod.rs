use rama_quic_proto::{
    Side, Version,
    capture::{CaptureError, InitialKeys, KeyProvider},
    crypto::{HeaderKey, PacketKey},
};

use crate::{profile::capture, tls::BoringTlsProvider};

mod config;
#[cfg(test)]
pub(crate) use config::QuicServerConfig;
pub(crate) use config::{
    HandshakeInitializer, QuicClientConfig, SharedClientSessions, on_handshake_completed,
    retry_tag, server_config_from_rama, server_initial_keys,
};
mod packet;
mod session;
#[cfg(any(test, not(any(feature = "ring", feature = "aws-lc"))))]
pub(crate) mod token;

#[cfg(test)]
mod tests;

impl KeyProvider for BoringTlsProvider {
    type Header = Box<dyn HeaderKey>;
    type Packet = Box<dyn PacketKey>;

    fn initial_keys(
        &self,
        version: Version,
        dcid: &[u8],
        side: Side,
    ) -> Result<InitialKeys<Self::Header, Self::Packet>, CaptureError> {
        let dcid = capture::connection_id(dcid)?;
        let wire = version
            .wire()
            .ok_or(CaptureError::UnknownVersion(version))?;
        let keys = packet::initial_keys(wire, &dcid, Side::Server)
            .map_err(|_error| CaptureError::Undecryptable)?;
        capture::receiving_keys(keys, side)
    }
}
