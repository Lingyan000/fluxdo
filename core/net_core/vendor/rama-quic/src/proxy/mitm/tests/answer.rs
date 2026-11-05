use rama_crypto::dep::boring::ssl::SslContentType;
use rama_tls::{
    CipherSuite,
    fingerprint::Ja4S,
    server::{ServerHello, TlsServerConfig, parse_encrypted_extensions},
};

use super::*;

/// The ServerHello and EncryptedExtensions one side of a handshake saw.
#[derive(Default, Clone)]
struct Answer(Arc<Mutex<(Option<Vec<u8>>, Option<Vec<u8>>)>>);

impl Answer {
    /// Record the messages `ssl` writes (`written`) or receives.
    fn observe(&self, ssl: &mut SslRef, written: bool) {
        let answer = self.0.clone();
        ssl.set_msg_callback(move |_, message| {
            if message.is_written() != written
                || message.content_type() != SslContentType::HANDSHAKE
            {
                return;
            }
            let bytes = message.bytes().to_vec();
            match bytes.first() {
                Some(2) => answer.lock().0 = Some(bytes),
                Some(8) => answer.lock().1 = Some(bytes),
                _ => {}
            }
        });
    }

    fn server_hello(&self) -> Vec<u8> {
        self.0.lock().0.clone().unwrap()
    }

    fn encrypted_extensions(&self) -> Vec<u8> {
        self.0.lock().1.clone().unwrap()
    }
}

/// The origin answers with AES-256 and a non-native extension order; the client offers
/// `client_ciphers`. Returns what the origin sent and what the client received.
async fn exchange(client_ciphers: Option<Vec<CipherSuite>>, port: u16) -> (Answer, Answer) {
    let mitm_identity = identity();
    let origin_identity = untrusted_identity();
    let address = |offset: u16| SocketAddr::from(([127, 0, 0, 1], port + offset));
    let capacity = NonZeroUsize::new(64).unwrap();
    let (client_socket, ingress) = MemoryDatagramSocket::pair(address(0), address(1), capacity);
    let (egress, origin_socket) = MemoryDatagramSocket::pair(address(2), address(3), capacity);

    let sent = Answer::default();
    let origin_tls = TlsServerConfig::new()
        .with_alpn([ALPN.into()].into_iter().collect())
        .with_server_auth(origin_identity.clone());
    let observed = sent.clone();
    origin_tls.insert(HandshakeInitializer(Arc::new(move |ssl: &mut SslRef| {
        ssl.set_strict_tls13_server_ciphers(&[u16::from(CipherSuite::TLS13_AES_256_GCM_SHA384)])?;
        ssl.set_server_extension_order(&[0x002b, 0x0033, 0x0039, 0x0010])?;
        observed.observe(ssl, true);
        Ok(())
    })));
    let origin = Endpoint::build(Executor::new())
        .with_server_config(
            ServerConfig::try_from_rama_tls_with_provider(
                &origin_tls,
                TlsOptions::default(),
                &BoringTlsProvider,
            )
            .unwrap(),
        )
        .with_datagram_socket(origin_socket)
        .unwrap();
    let origin_task = tokio::spawn(async move {
        let connection = origin.accept().await.unwrap().await.unwrap();
        connection.closed().await;
        origin
    });

    let service = PeekQuicClientHelloService::new(
        BoringTlsProvider,
        // A mirrored offer would bound the origin to the client's own ciphers; this
        // checks the answer when the relay's egress offer differs from the client's.
        relay(issuer(&mitm_identity), &origin_identity)
            .with_mirror_client(false)
            .into_layer(service_fn(
                async |BridgeIo(ingress, egress): BridgeIo<Connection, Connection>| {
                    egress.handshake_confirmed().await?;
                    ingress.handshake_confirmed().await?;
                    ingress.close(VarInt::from_u32(0), b"checked");
                    egress.close(VarInt::from_u32(0), b"checked");
                    Ok::<_, BoxError>(())
                },
            )),
    );
    let relaying = tokio::spawn(async move { service.serve(BridgeIo(ingress, egress)).await });

    let received = Answer::default();
    let mut client_tls = trusting(&mitm_identity);
    if let Some(ciphers) = client_ciphers {
        client_tls.set_cipher_suites(ciphers);
    }
    let observed = received.clone();
    client_tls.insert(HandshakeInitializer(Arc::new(move |ssl: &mut SslRef| {
        observed.observe(ssl, false);
        Ok(())
    })));
    let config = ClientConfig::try_from_rama_tls_with_provider(
        &client_tls,
        TlsOptions::default(),
        &BoringTlsProvider,
    )
    .unwrap();
    let client = Endpoint::build(Executor::new())
        .with_datagram_socket(client_socket)
        .unwrap();
    let connection = client
        .connect_with(config, address(1), "localhost")
        .unwrap()
        .await
        .unwrap();
    relaying.await.unwrap().unwrap();
    connection.closed().await;
    drop(origin_task.await.unwrap());
    (sent, received)
}

#[tokio::test]
async fn the_client_gets_the_answer_the_origin_gave() {
    timeout(LIMIT, async {
        let (sent, received) = exchange(None, 24800).await;
        let origin = Ja4S::compute_from_server_hello(
            &ServerHello::parse_quic_handshake(&sent.server_hello()).unwrap(),
        )
        .unwrap();
        let ingress = Ja4S::compute_from_server_hello(
            &ServerHello::parse_quic_handshake(&received.server_hello()).unwrap(),
        )
        .unwrap();
        assert_eq!(ingress.to_human_string(), origin.to_human_string());
        assert_eq!(ingress.to_string(), origin.to_string());
        assert_eq!(
            parse_encrypted_extensions(&received.encrypted_extensions()).unwrap(),
            parse_encrypted_extensions(&sent.encrypted_extensions()).unwrap()
        );
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn an_origin_cipher_the_client_did_not_offer_is_not_forced_on_it() {
    timeout(LIMIT, async {
        let (sent, received) =
            exchange(Some(vec![CipherSuite::TLS13_AES_128_GCM_SHA256]), 24810).await;
        let origin = ServerHello::parse_handshake(&sent.server_hello()).unwrap();
        let ingress = ServerHello::parse_handshake(&received.server_hello()).unwrap();
        assert_eq!(origin.cipher_suite(), CipherSuite::TLS13_AES_256_GCM_SHA384);
        assert_eq!(
            ingress.cipher_suite(),
            CipherSuite::TLS13_AES_128_GCM_SHA256
        );
        // The order is still the origin's.
        assert_eq!(ingress.extensions(), origin.extensions());
    })
    .await
    .unwrap();
}
