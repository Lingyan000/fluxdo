//! What a connection's own statistics say about the close it sent.
//!
//! A CONNECTION_CLOSE goes out in every space the close reaches (RFC 9000 §10.2.3), and each
//! one is counted, so a case that wants to know whether a close was written can ask rather
//! than infer it from datagrams that may carry anything.

use std::time::Duration;

use rama_net::tls::ApplicationProtocol;
use rama_tls::{
    client::TlsClientConfig,
    server::{GeneratedServerAuthConfig, ServerAuthData, TlsServerConfig},
};
use rama_utils::collections::smallvec::smallvec;
use tokio::time::timeout;

use crate::{
    driver::{ClientConfig, Endpoint, ServerConfig},
    tls::TlsOptions,
};

use super::{owned::Owned, subscribe};

/// How long the case may take altogether.
const LIMIT: Duration = Duration::from_secs(20);

/// The protocol both ends agree on.
const ALPN: &[u8] = b"rama-quic-closing";

/// A closing side counts the frames it wrote, and the side it closed on writes no more than
/// the single response RFC 9000 §10.2.2 permits before draining.
#[tokio::test]
async fn a_close_is_counted_where_it_is_written() {
    let _guard = subscribe();
    let case = async {
        let identity = ServerAuthData::new_generated(GeneratedServerAuthConfig::default())
            .expect("an identity is generated");
        let anchor = identity.cert_chain.last().expect("a chain").clone();
        let tls = TlsServerConfig::new()
            .with_alpn(smallvec![ApplicationProtocol::from(ALPN)])
            .with_server_auth(identity);
        let mut endpoint = Endpoint::bind_server(
            rama_core::rt::Executor::new(),
            ServerConfig::try_from_rama_tls(&tls, TlsOptions::default())
                .expect("the server config is built"),
            crate::driver::tests::localhost(),
        )
        .await
        .expect("the endpoint binds");
        let client_tls = TlsClientConfig::new()
            .with_alpn(smallvec![ApplicationProtocol::from(ALPN)])
            .try_with_server_trust_anchors([anchor])
            .expect("the trust anchor is accepted");
        endpoint.set_default_client_config(
            ClientConfig::try_from_rama_tls(&client_tls, TlsOptions::default())
                .expect("the client config is built"),
        );

        let accepting = Owned::spawn({
            let endpoint = endpoint.clone();
            async move {
                let connection = endpoint
                    .accept()
                    .await
                    .expect("an attempt arrives")
                    .await
                    .expect("the handshake completes");
                connection.closed().await;
                // Handed back rather than counted here: what this side writes in answer is
                // encoded after the close is known about, so the count is read once the
                // endpoint has nothing left to send.
                connection
            }
        });
        let connection = endpoint
            .connect(endpoint.local_addr().unwrap(), "localhost")
            .unwrap()
            .await
            .expect("the handshake completes");
        assert_eq!(
            connection.stats().frame_tx.connection_close,
            0,
            "nothing has been closed yet"
        );
        connection.close(0x2au32, b"counted");
        connection.closed().await;
        let answered = accepting.join().await;
        // The frames are written when each connection next transmits, which is after the
        // close is applied, so both counts are read once the endpoint has nothing left to
        // send.
        endpoint.wait_idle().await;
        assert!(
            connection.stats().frame_tx.connection_close > 0,
            "the side that closed wrote at least one close frame"
        );
        // RFC 9000 §10.2.2: an endpoint that receives a CONNECTION_CLOSE may send one packet
        // containing one of its own in response, and once it is draining it sends nothing
        // further. So one is the most this side can have written.
        assert!(
            answered.stats().frame_tx.connection_close <= 1,
            "the side that was closed on wrote at most the one response that section allows"
        );
    };
    timeout(LIMIT, case)
        .await
        .expect("the case ran out of time");
}
