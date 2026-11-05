use std::sync::Arc;

use rama_quic_proto::{
    TransportErrorCode,
    profile::{QuicProfile, TransportLimits},
};

use super::{
    ConnectionError, EndpointConfig, Pair,
    util::{IncomingConnectionBehavior, client_config, server_config},
};

#[test]
fn profile_endpoint_mismatch_releases_pending_server_routing() {
    let standard = QuicProfile::standard();
    let mismatches = [
        standard
            .clone()
            .with_connection_ids((*standard.connection_ids()).try_with_local_len(3).unwrap()),
        standard
            .clone()
            .with_grease_quic_bit(!standard.greases_quic_bit()),
        standard
            .clone()
            .try_with_limits(TransportLimits {
                max_udp_payload_size: 1400,
                ..standard.limits().clone()
            })
            .unwrap(),
    ];
    for profile in mismatches {
        for override_at_accept in [false, true] {
            let mut endpoint = EndpointConfig::try_with_rand_key().unwrap();
            endpoint.apply_quic_profile(&standard).unwrap();
            let mut incompatible = server_config();
            incompatible.apply_quic_profile(&profile).unwrap();
            let default = if override_at_accept {
                server_config()
            } else {
                incompatible.clone()
            };
            let mut pair = Pair::new(Arc::new(endpoint), default);
            pair.server.handle_incoming = Box::new(|_| IncomingConnectionBehavior::Wait);
            pair.begin_connect(client_config());
            pair.drive_client();
            let datagram = pair.server.inbound.front().unwrap().clone();
            pair.drive_server();
            let incoming = pair.server.waiting_incoming.pop().unwrap();

            let mut response = Vec::new();
            let result = pair.server.endpoint.accept(
                incoming,
                pair.time,
                &mut response,
                override_at_accept.then(|| Arc::new(incompatible)),
            );
            let Err(error) = result else {
                panic!("mismatched endpoint profile was accepted");
            };
            assert!(
                matches!(error.cause, ConnectionError::TransportError(ref cause)
                if cause.code == TransportErrorCode::INTERNAL_ERROR)
            );
            assert!(error.response.is_none());
            assert!(response.is_empty());
            assert_eq!(pair.server.endpoint.open_connections(), 0);
            assert_eq!(pair.server.endpoint.incoming_buffer_bytes(), 0);

            // The rejected Initial must no longer route to a dead pending entry.
            // Re-deliver the same datagram and accept it with compatible settings.
            pair.server.inbound.push_back(datagram);
            pair.drive_server();
            let incoming = pair.server.waiting_incoming.pop().unwrap();
            pair.server
                .endpoint
                .accept(
                    incoming,
                    pair.time,
                    &mut response,
                    Some(Arc::new(server_config())),
                )
                .unwrap();
            assert_eq!(pair.server.endpoint.open_connections(), 1);
        }
    }
}
