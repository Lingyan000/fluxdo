mod common;

use common::*;
use rama::{
    quic::{ConnectionError, Endpoint},
    rt::Executor,
    utils::octets,
};

#[tokio::test]
async fn gnutls_client_exchanges_streams_and_datagrams_with_aioquic_after_key_update() {
    eprintln!("GnuTLS {}", rama_quic_gnutls_interop::version());
    let identity = Identity::generate();
    let mut peer = Peer::spawn(
        "server",
        &[
            "--cert",
            &identity.certificate,
            "--key",
            &identity.key,
            "--datagram-frame",
            "1200",
        ],
    );
    let address = peer.listening().await;
    let endpoint = client_endpoint().await;
    let connection = within(
        endpoint
            .connect_with(identity.client(), address, "localhost")
            .unwrap(),
    )
    .await
    .unwrap();
    metadata(&connection, true);
    let before = payload(17, octets::kib(64));
    exchange(&connection, &before).await;
    // Stream data can arrive before HANDSHAKE_DONE; wait for confirmation before
    // requesting the update, as required by RFC 9001 section 6.1. A routine update may
    // already be in flight, unacknowledged until the next exchange carries it.
    within(async {
        while connection.stats().key_updates == 0 && !connection.force_key_update() {
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await;
    let after = payload(29, octets::kib(96));
    exchange(&connection, &after).await;
    let datagram = payload(41, 512);
    connection.send_datagram(datagram.clone().into()).unwrap();
    assert_eq!(
        within(connection.read_datagram()).await.unwrap().as_ref(),
        datagram
    );
    assert!(connection.stats().key_updates > 0);
    connection.close(0u32, b"done");
    within(endpoint.shutdown()).await;
    peer.finish().await;
    peer.observed("stream", &before);
    peer.observed("stream", &after);
    peer.observed("datagram", &datagram);
    assert!(
        peer.events
            .iter()
            .any(|e| e["event"] == "handshake" && e["alpn"] == ALPN)
    );
}

#[tokio::test]
async fn aioquic_client_exchanges_streams_and_datagrams_with_gnutls_after_retry() {
    let identity = Identity::generate();
    let endpoint = Endpoint::bind_server(Executor::new(), identity.server(), localhost())
        .await
        .unwrap();
    let port = endpoint.local_addr().unwrap().port().to_string();
    let bytes = payload(23, octets::kib(64));
    let datagram: Vec<u8> = (0..512).map(|index| (index & 0xff) as u8 ^ 31).collect();
    let length = bytes.len().to_string();
    let mut peer = Peer::spawn(
        "client",
        &[
            "--ca",
            &identity.ca,
            "--port",
            &port,
            "--seed",
            "23",
            "--length",
            &length,
            "--datagram-frame",
            "1200",
            "--datagrams",
            "1",
            "--datagram-out-seed",
            "31",
            "--datagram-out-length",
            "512",
        ],
    );
    let first = within(endpoint.accept()).await.unwrap();
    assert!(first.may_retry());
    first.retry().unwrap();
    let incoming = within(endpoint.accept()).await.unwrap();
    assert!(
        incoming.remote_address_validated(),
        "the Retry token was authenticated"
    );
    let connection = within(incoming).await.unwrap();
    metadata(&connection, false);
    let mut uni = within(connection.accept_uni()).await.unwrap();
    assert_eq!(
        within(uni.read_to_end(bytes.len() + 1)).await.unwrap(),
        bytes
    );
    let (mut send, mut recv) = within(connection.accept_bi()).await.unwrap();
    assert_eq!(
        within(recv.read_to_end(bytes.len() + 1)).await.unwrap(),
        bytes
    );
    within(send.write_all(&bytes)).await.unwrap();
    send.finish().unwrap();
    assert_eq!(
        within(connection.read_datagram()).await.unwrap().as_ref(),
        datagram
    );
    connection.send_datagram(datagram.clone().into()).unwrap();
    peer.finish().await;
    peer.observed("stream", &bytes);
    peer.observed("datagram", &datagram);
    assert!(
        peer.events
            .iter()
            .any(|e| e["event"] == "handshake" && e["alpn"] == ALPN)
    );
    within(endpoint.shutdown()).await;
}

#[tokio::test]
async fn gnutls_rejects_untrusted_certificates_and_wrong_hostnames_from_aioquic() {
    let identity = Identity::generate();
    let stranger = Identity::generate();
    struct Rejection<'a> {
        anchor: &'a Identity,
        name: &'a str,
        status: u32,
    }

    let rejections = [
        Rejection {
            anchor: &stranger,
            name: "localhost",
            status: 1 << 6,
        },
        Rejection {
            anchor: &identity,
            name: "wrong.example",
            status: 1 << 14,
        },
    ];
    for Rejection {
        anchor,
        name,
        status,
    } in rejections
    {
        let mut peer = Peer::spawn(
            "server",
            &["--cert", &identity.certificate, "--key", &identity.key],
        );
        let address = peer.listening().await;
        let endpoint = client_endpoint().await;
        let error = within(
            endpoint
                .connect_with(anchor.client(), address, name)
                .unwrap(),
        )
        .await
        .unwrap_err();
        let ConnectionError::TransportError(error) = error else {
            panic!("expected certificate transport error, got {error:?}");
        };
        let cause = error
            .cause()
            .unwrap()
            .downcast_ref::<rama_quic_gnutls_interop::GnuTlsError>()
            .unwrap();
        assert_ne!(
            cause.certificate_status & status,
            0,
            "issuer/hostname rejection status"
        );
        assert!(error.code().tls_alert().is_some());
        within(endpoint.shutdown()).await;
        peer.finish().await;
        assert!(!peer.events.iter().any(|e| e["event"] == "handshake"));
    }
}

#[tokio::test]
async fn external_providers_agree_on_exporters_and_accept_retry() {
    let identity = Identity::generate();
    let server = Endpoint::bind_server(Executor::new(), identity.server(), localhost())
        .await
        .unwrap();
    let client = client_endpoint().await;
    let connecting = client
        .connect_with(identity.client(), server.local_addr().unwrap(), "localhost")
        .unwrap();
    let accepting = async {
        within(server.accept()).await.unwrap().retry().unwrap();
        let incoming = within(server.accept()).await.unwrap();
        assert!(incoming.remote_address_validated());
        within(incoming).await.unwrap()
    };
    let (from_client, at_server) = within(async { tokio::join!(connecting, accepting) }).await;
    let from_client = from_client.unwrap();
    metadata(&from_client, true);
    metadata(&at_server, false);
    let mut client_export = [0; 32];
    let mut server_export = [0; 32];
    from_client
        .export_keying_material(&mut client_export, b"interop", b"context")
        .unwrap();
    at_server
        .export_keying_material(&mut server_export, b"interop", b"context")
        .unwrap();
    assert_eq!(client_export, server_export);
    at_server
        .export_keying_material(&mut server_export, b"another label", b"context")
        .unwrap();
    assert_ne!(client_export, server_export);
    at_server
        .export_keying_material(&mut server_export, b"interop", b"another context")
        .unwrap();
    assert_ne!(client_export, server_export);
    from_client.close(0u32, b"done");
    within(async {
        tokio::join!(client.shutdown(), server.shutdown());
    })
    .await;
}
