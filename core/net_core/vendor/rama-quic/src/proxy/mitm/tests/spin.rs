use super::*;

#[tokio::test]
async fn spin_mitm_applies_unilateral_policy_to_each_terminated_hop() {
    timeout(LIMIT, async {
        for ingress_allowed in [false, true] {
            let mitm_identity = identity();
            let origin_identity = untrusted_identity();
            let Sockets {
                client,
                ingress,
                ingress_address,
                egress,
                origin,
            } = sockets(&origin_identity, 24510);
            let ingress_transport = Arc::new(
                TransportConfig::default()
                    .with_allow_spin(ingress_allowed)
                    .maybe_with_datagram_receive_buffer_size(None),
            );
            let egress_transport = Arc::new(
                TransportConfig::default()
                    .with_allow_spin(!ingress_allowed)
                    .maybe_with_datagram_receive_buffer_size(None),
            );
            let forward = service_fn(
                move |connections: BridgeIo<Connection, Connection>| async move {
                    let BridgeIo(ingress, egress) = connections;
                    // Permission can still be randomly suppressed; the administratively
                    // disabled hop must always be off, whichever direction was selected.
                    let disabled = if ingress_allowed { &egress } else { &ingress };
                    assert!(!disabled.spin_enabled_for_test());
                    QuicRelay::new(VarInt::from_u32(0x0101))
                        .serve(BridgeIo(ingress, egress))
                        .await
                },
            );
            let service = PeekQuicClientHelloService::new(
                BoringTlsProvider,
                relay(issuer(&mitm_identity), &origin_identity)
                    .with_ingress_transport(ingress_transport)
                    .with_egress_transport(egress_transport)
                    .into_layer(forward),
            );
            let relaying =
                tokio::spawn(async move { service.serve(BridgeIo(ingress, egress)).await });

            let origin_task = tokio::spawn(async move {
                let connection = origin.accept().await.unwrap().await.unwrap();
                let (mut send, mut recv) = connection.accept_bi().await.unwrap();
                let request = recv.read_to_end(64).await.unwrap();
                send.write_all(&[b"pong:", request.as_slice()].concat())
                    .await
                    .unwrap();
                send.finish().unwrap();
                connection.closed().await;
                origin
            });

            let config = ClientConfig::try_from_rama_tls(
                &trusting(&mitm_identity).with_store_server_cert_chain(true),
                TlsOptions::default(),
            )
            .unwrap();
            let connection = client
                .connect_with(config, ingress_address, "localhost")
                .unwrap()
                .await
                .unwrap();
            // The client authenticated the relay's certificate, not the origin's.
            let tls = connection
                .extensions()
                .get_ref::<NegotiatedTlsParameters>()
                .unwrap();
            assert_eq!(
                tls.peer_certificate_chain.as_deref().unwrap()[0],
                mitm_identity.cert_chain[0]
            );
            let (mut send, mut recv) = connection.open_bi().await.unwrap();
            send.write_all(b"ping").await.unwrap();
            send.finish().unwrap();
            assert_eq!(recv.read_to_end(64).await.unwrap(), b"pong:ping");
            connection.close(VarInt::from_u32(0), b"done");
            relaying.await.unwrap().unwrap();
            drop(origin_task.await.unwrap());
        }
    })
    .await
    .unwrap();
}
