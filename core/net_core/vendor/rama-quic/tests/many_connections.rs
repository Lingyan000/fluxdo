#![cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "an integration test's fixtures fail the test by panicking; the workspace allows this inside test functions and this file is one, but its helpers are not #[test] themselves"
)]
//! Fifty connections at once, each carrying a megabyte, through the public API. Every payload is
//! named by its connection and checked by digest on arrival, every task is joined, and the whole
//! run is bounded: a transfer that is lost, corrupted or reset fails this test rather than
//! leaving it to notice nothing.

use std::{
    convert::TryInto,
    net::{IpAddr, Ipv4Addr, SocketAddr},
    sync::Arc,
    time::Duration,
};

use rama_crypto::pki_types::CertificateDer;
use rama_net::tls::ApplicationProtocol;
use rama_quic::{ClientConfig, Endpoint, ServerConfig, TransportConfig, tls::TlsOptions};
use rama_tls::{
    client::TlsClientConfig,
    server::{GeneratedServerAuthConfig, ServerAuthData, TlsServerConfig},
};
use rama_utils::{collections::smallvec::smallvec, octets};
use sha2::{Digest as _, Sha256};
use tokio::runtime::Builder;

const ALPN: &[u8] = b"many-connections";
/// The digest prefixed to every payload.
const DIGEST: usize = 32;
/// How many connections carry a payload at once.
const CONNECTIONS: usize = 50;
/// The whole run, including cleanup, has to fit in this.
const LIMIT: Duration = Duration::from_secs(120);

#[test]
#[ignore = "heavy: many nodes each send 1 MiB"]
fn connect_n_nodes_to_1_and_send_1mb_data() {
    let _initialised = tracing_subscriber::FmtSubscriber::builder()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_test_writer()
        .try_init();

    let runtime = Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(async {
        match tokio::time::timeout(LIMIT, run()).await {
            Ok(()) => {}
            Err(_) => panic!("the run did not finish within {LIMIT:?}"),
        }
    });
}

async fn run() {
    let auth = ServerAuthData::new_generated(GeneratedServerAuthConfig::default()).unwrap();
    let anchor = auth.cert_chain.last().unwrap().clone();
    let endpoint = Endpoint::bind_server(
        rama_core::rt::Executor::new(),
        listener_config(&auth),
        SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
    )
    .await
    .unwrap();
    let listener_addr = endpoint.local_addr().unwrap();

    // The server reads one stream per connection and reports which payload it saw.
    let listener = {
        let endpoint = endpoint.clone();
        tokio::spawn(async move {
            let mut readers = Vec::with_capacity(CONNECTIONS);
            for _ in 0..CONNECTIONS {
                let incoming = endpoint.accept().await.expect("an attempt arrives");
                readers.push(tokio::spawn(async move {
                    let conn = incoming
                        .accept()
                        .expect("the attempt is accepted")
                        .await
                        .expect("the handshake completes");
                    let mut stream = conn.accept_uni().await.expect("the stream arrives");
                    let data = stream
                        .read_to_end(octets::mib(2))
                        .await
                        .expect("the stream completes");
                    let seen = check(&data);
                    conn.close(0u32, b"received");
                    seen
                }));
            }
            let mut seen = Vec::with_capacity(CONNECTIONS);
            for reader in readers {
                seen.push(reader.await.expect("a reader finished without panicking"));
            }
            seen
        })
    };

    let client_cfg = connector_config(anchor);
    let mut writers = Vec::with_capacity(CONNECTIONS);
    for index in 0..CONNECTIONS {
        let connecting = endpoint
            .connect_with(client_cfg.clone(), listener_addr, "localhost")
            .unwrap();
        writers.push(tokio::spawn(async move {
            let conn = connecting.await.expect("the handshake completes");
            let mut stream = conn.open_uni().await.expect("a stream");
            stream
                .write_all(&payload(index))
                .await
                .expect("the payload is written");
            stream.finish().expect("the stream ends");
            // The peer closes the connection once it has the whole payload; a stream reset or a
            // connection lost before that is a lost transfer, and the reader will say so.
            let _stopped = stream.stopped().await;
        }));
    }
    for writer in writers {
        writer.await.expect("a writer finished without panicking");
    }

    let mut seen = listener
        .await
        .expect("the listener finished without panicking");
    seen.sort_unstable();
    let expected: Vec<usize> = (0..CONNECTIONS).collect();
    assert_eq!(
        seen, expected,
        "every connection's own payload arrived whole, exactly once"
    );

    endpoint.shutdown().await;
}

fn alpn() -> ApplicationProtocol {
    ApplicationProtocol::from(ALPN)
}

/// Client configuration trusting the listener's identity, and nothing else.
fn connector_config(anchor: CertificateDer<'static>) -> ClientConfig {
    let tls = TlsClientConfig::new()
        .with_alpn(smallvec![alpn()])
        .try_with_server_trust_anchors([anchor])
        .unwrap();
    let mut config = ClientConfig::try_from_rama_tls(&tls, TlsOptions::default()).unwrap();
    config.set_transport_config(Arc::new(transport()));
    config
}

/// Listener configuration presenting the generated identity.
fn listener_config(auth: &ServerAuthData) -> ServerConfig {
    let tls = TlsServerConfig::new()
        .with_alpn(smallvec![alpn()])
        .with_server_auth(auth.clone());
    let mut config = ServerConfig::try_from_rama_tls(&tls, TlsOptions::default()).unwrap();
    config.set_transport_config(Arc::new(transport()));
    config
}

fn transport() -> TransportConfig {
    let mut transport = TransportConfig::default();
    transport.set_max_idle_timeout(Duration::from_secs(20).try_into().unwrap());
    transport
}

/// A megabyte that says which connection it belongs to, prefixed with its own digest. The bytes
/// are derived from the index, so a payload that arrives on the wrong connection, or arrives
/// changed, is caught by the digest and by the index it carries.
fn payload(index: usize) -> Vec<u8> {
    let mut data = vec![0u8; DIGEST + 8 + octets::mib(1)];
    data[DIGEST..DIGEST + 8].copy_from_slice(&(index as u64).to_be_bytes());
    let seed = index as u8;
    for (offset, byte) in data[DIGEST + 8..].iter_mut().enumerate() {
        *byte = (offset as u8) ^ seed;
    }
    let hash = Sha256::digest(&data[DIGEST..]);
    data[..DIGEST].copy_from_slice(hash.as_ref());
    data
}

/// The index the payload names, once its digest is confirmed.
fn check(data: &[u8]) -> usize {
    let (carried, rest) = data.split_at_checked(DIGEST).expect("a digest prefix");
    assert_eq!(
        &Sha256::digest(rest)[..],
        carried,
        "the payload arrived as it was sent"
    );
    let (index, _) = rest.split_at_checked(8).expect("an index");
    let index = u64::from_be_bytes(index.try_into().expect("eight bytes")) as usize;
    assert_eq!(
        payload(index).len(),
        data.len(),
        "the payload is the whole of connection {index}'s"
    );
    index
}
