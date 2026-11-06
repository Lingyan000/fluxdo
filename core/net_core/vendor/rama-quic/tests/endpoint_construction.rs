//! Endpoint construction needs secure HMAC keys even without a TLS backend.

use rama_core::rt::Executor;
use rama_crypto::hmac::HmacSha2;
use rama_quic::{Endpoint, EndpointConfig};
use rama_udp::UdpSocketConfig;
use std::net::{Ipv4Addr, SocketAddr, UdpSocket};

fn localhost() -> SocketAddr {
    (Ipv4Addr::LOCALHOST, 0).into()
}

#[tokio::test]
async fn client_binding_generates_a_key_without_a_tls_provider() {
    let endpoint = Endpoint::bind_client(Executor::new(), localhost())
        .await
        .unwrap();
    assert_ne!(endpoint.local_addr().unwrap().port(), 0);
    endpoint.shutdown().await;
}

#[tokio::test]
async fn prepared_client_sockets_preserve_their_bound_addresses() {
    let socket = UdpSocket::bind(localhost()).unwrap();
    let address = socket.local_addr().unwrap();
    let endpoint = Endpoint::new_client_with_std_socket(Executor::new(), socket).unwrap();
    assert_eq!(endpoint.local_addr().unwrap(), address);
    endpoint.shutdown().await;

    let socket = UdpSocket::bind(localhost()).unwrap();
    let address = socket.local_addr().unwrap();
    let prepared = UdpSocketConfig::default().wrap_std(socket).unwrap();
    let endpoint = Endpoint::new_client_with_packet_socket(Executor::new(), prepared).unwrap();
    assert_eq!(endpoint.local_addr().unwrap(), address);
    endpoint.shutdown().await;
}

#[tokio::test]
async fn builder_accepts_explicit_sha256_and_sha512_reset_keys() {
    for key in [
        HmacSha2::new_256(&[0x4b; 32]),
        HmacSha2::new_512(&[0x4b; 64]),
    ] {
        let endpoint = Endpoint::build(Executor::new())
            .with_config(EndpointConfig::new(key))
            .bind_address(localhost())
            .await
            .unwrap();
        assert_ne!(endpoint.local_addr().unwrap().port(), 0);
        endpoint.shutdown().await;
    }
}
