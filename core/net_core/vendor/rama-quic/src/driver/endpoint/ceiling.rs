//! Keep an endpoint's packet sizes within what its socket carries, such as a UDP tunnel
//! through a proxy whose payload limit is below the usual path MTU.

use std::{fmt, sync::Arc};

use rama_core::telemetry::tracing;
use rama_udp::{DatagramCapabilities, MAX_UDP_PAYLOAD_IPV4};

use crate::{
    driver::EndpointConfig,
    proto::{ClientConfig, INITIAL_MTU, ServerConfig, TransportConfig},
};

/// Smallest UDP payload QUIC runs on (RFC 9000 §14).
pub const MIN_UDP_PAYLOAD: usize = INITIAL_MTU as usize;

/// A socket too small for QUIC: it carries payloads below [`MIN_UDP_PAYLOAD`], such as a
/// UDP tunnel through a proxy whose path is too small. No handshake starts on such a socket,
/// and a connection whose socket shrinks below it ends with this error.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SocketCapacityError {
    /// The largest payload the socket carries.
    pub max_payload: usize,
}

impl fmt::Display for SocketCapacityError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "socket carries {} byte payloads, QUIC needs {MIN_UDP_PAYLOAD}",
            self.max_payload
        )
    }
}

impl std::error::Error for SocketCapacityError {}

/// The largest UDP payload the socket carries in either family, refused below QUIC's minimum.
pub(crate) fn payload_ceiling(
    capabilities: &DatagramCapabilities,
) -> Result<u16, SocketCapacityError> {
    let max_payload = capabilities
        .max_payload_ipv4
        .min(capabilities.max_payload_ipv6);
    if max_payload < MIN_UDP_PAYLOAD {
        return Err(SocketCapacityError { max_payload });
    }
    Ok(u16::try_from(max_payload).unwrap_or(u16::MAX))
}

/// What the socket's peer can deliver: the send ceiling, narrowed by the socket's estimate of
/// its return direction, never below QUIC's minimum.
pub(super) fn receive_ceiling(capabilities: &DatagramCapabilities, ceiling: u16) -> u16 {
    capabilities
        .max_receive_payload
        .map_or(ceiling, |receive| {
            ceiling.min(u16::try_from(receive).unwrap_or(u16::MAX))
        })
        .max(INITIAL_MTU)
}

/// On a constrained socket, lower the advertised receive size to the ceiling; an ordinary UDP
/// socket keeps the configured or profiled size, which only the peer's sends are bound by.
pub(super) fn fit_endpoint(config: &mut EndpointConfig, ceiling: u16) {
    if !is_constrained(ceiling) {
        return;
    }
    config.payload_ceiling = Some(ceiling);
    let advertised = config.get_max_udp_payload_size();
    if advertised > u64::from(ceiling) && config.max_udp_payload_size(ceiling).is_ok() {
        tracing::debug!(
            advertised,
            ceiling,
            "QUIC endpoint lowers max_udp_payload_size to what its socket carries"
        );
    }
}

/// Whether the socket carries less than any UDP datagram, as a tunnel does: its limit can
/// shrink, so connections on it must be able to fall back to QUIC's minimum.
fn is_constrained(ceiling: u16) -> bool {
    usize::from(ceiling) < MAX_UDP_PAYLOAD_IPV4
}

/// The transport fitted to the socket: its starting packet size lowered to the ceiling, and on
/// a constrained socket its fallback size lowered to QUIC's minimum, so black-hole detection
/// can recover from a shrink that still carries 1200 bytes.
fn fit_transport(transport: &Arc<TransportConfig>, ceiling: u16) -> Option<Arc<TransportConfig>> {
    let initial = transport.get_initial_mtu();
    let lower_initial = initial > ceiling;
    let lower_min = is_constrained(ceiling) && transport.min_mtu > INITIAL_MTU;
    if !lower_initial && !lower_min {
        return None;
    }
    let mut fitted = (**transport).clone();
    if lower_min {
        tracing::debug!(
            min_mtu = transport.min_mtu,
            ceiling,
            "QUIC connection on a constrained socket falls back to the QUIC minimum"
        );
        fitted.set_min_mtu(INITIAL_MTU);
    }
    if lower_initial {
        tracing::debug!(
            initial,
            ceiling,
            "QUIC connection lowers its initial MTU to what its socket carries"
        );
        fitted.set_initial_mtu(ceiling);
    }
    Some(Arc::new(fitted))
}

pub(super) fn fit_client(mut config: ClientConfig, ceiling: u16) -> ClientConfig {
    if let Some(transport) = fit_transport(&config.transport, ceiling) {
        config.transport = transport;
    }
    config
}

pub(super) fn fit_server(mut config: ServerConfig, ceiling: u16) -> ServerConfig {
    if let Some(transport) = fit_transport(&config.transport, ceiling) {
        config.transport = transport;
    }
    config
}

#[cfg(test)]
mod tests {
    use super::*;

    fn capabilities(ipv4: usize, ipv6: usize) -> DatagramCapabilities {
        let mut capabilities = DatagramCapabilities::portable();
        capabilities.max_payload_ipv4 = ipv4;
        capabilities.max_payload_ipv6 = ipv6;
        capabilities
    }

    #[test]
    fn the_ceiling_is_the_smaller_family_limit_and_refused_below_quic_minimum() {
        assert_eq!(payload_ceiling(&capabilities(1300, 1412)), Ok(1300));
        assert_eq!(payload_ceiling(&capabilities(1200, 1200)), Ok(1200));
        assert_eq!(
            payload_ceiling(&capabilities(1199, 1412)),
            Err(SocketCapacityError { max_payload: 1199 })
        );
        assert_eq!(
            payload_ceiling(&DatagramCapabilities::portable()),
            Ok(65_507)
        );
    }

    #[test]
    fn a_receive_size_above_a_constrained_ceiling_is_lowered() {
        let mut config = EndpointConfig::try_with_rand_key().unwrap();
        config.max_udp_payload_size(1472).unwrap();
        fit_endpoint(&mut config, 1300);
        assert_eq!(config.get_max_udp_payload_size(), 1300);
        fit_endpoint(&mut config, 1400);
        assert_eq!(config.get_max_udp_payload_size(), 1300);
    }

    #[test]
    fn the_receive_ceiling_follows_the_return_direction_estimate() {
        let mut caps = capabilities(1300, 1300);
        assert_eq!(receive_ceiling(&caps, 1300), 1300);
        caps.max_receive_payload = Some(1231);
        assert_eq!(receive_ceiling(&caps, 1300), 1231);
        // Never above what the socket sends, never below QUIC's minimum.
        caps.max_receive_payload = Some(1400);
        assert_eq!(receive_ceiling(&caps, 1300), 1300);
        caps.max_receive_payload = Some(900);
        assert_eq!(receive_ceiling(&caps, 1300), INITIAL_MTU);
    }

    #[test]
    fn an_ordinary_udp_socket_keeps_the_advertised_receive_size() {
        let mut config = EndpointConfig::try_with_rand_key().unwrap();
        config.max_udp_payload_size(65_527).unwrap();
        fit_endpoint(&mut config, 65_507);
        assert_eq!(config.get_max_udp_payload_size(), 65_527);
        assert_eq!(config.payload_ceiling, None);
    }

    #[test]
    fn a_constrained_socket_falls_back_to_quic_minimum_and_others_keep_theirs() {
        let transport = Arc::new(
            TransportConfig::default()
                .with_min_mtu(1300)
                .with_initial_mtu(1300),
        );
        // A 1400-byte tunnel: the start fits, but the fallback must reach 1200.
        let fitted = fit_transport(&transport, 1400).unwrap();
        assert_eq!(fitted.min_mtu, INITIAL_MTU);
        assert_eq!(fitted.get_initial_mtu(), 1300);
        // An ordinary UDP socket keeps the application's minimum.
        assert!(fit_transport(&transport, 65_507).is_none());
    }

    #[test]
    fn a_starting_size_above_the_ceiling_is_lowered_and_within_it_kept() {
        let transport = Arc::new(TransportConfig::default().with_initial_mtu(1350));
        let fitted = fit_transport(&transport, 1300).unwrap();
        assert_eq!(fitted.get_initial_mtu(), 1300);
        assert!(fit_transport(&transport, 1350).is_none());
        assert!(fit_transport(&Arc::new(TransportConfig::default()), 1300).is_none());
    }
}
