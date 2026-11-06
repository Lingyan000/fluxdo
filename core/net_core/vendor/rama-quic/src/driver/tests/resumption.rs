//! What `NegotiatedTlsParameters::resumed` reports, and what it does not.
//!
//! A session found in the server's store is not a resumption: rustls takes the bytes before it
//! parses them, so the store can answer a lookup that the handshake then refuses. These two
//! cases hold those apart, on the public configuration path.

use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

use rama_core::extensions::ExtensionsRef as _;
use rama_net::tls::ApplicationProtocol;
use rama_tls::{
    client::{NegotiatedTlsParameters, TlsClientConfig},
    server::{GeneratedServerAuthConfig, ServerAuthData, TlsServerConfig},
};
use rama_tls_rustls::{
    dep::rustls::server::{ServerSessionMemoryCache, StoresServerSessions},
    server::RustlsServerConfigExt,
};
use rama_utils::{collections::smallvec::smallvec, octets};
use tokio::time::timeout;

use crate::{
    driver::{ClientConfig, Endpoint, ServerConfig},
    proto::crypto::rustls::TlsOptions,
};

use super::{owned::Owned, subscribe};

/// How long either case may take altogether. A handshake that never settles fails here rather
/// than holding the suite.
const LIMIT: Duration = Duration::from_secs(20);

/// The protocol both ends of these cases agree on.
const ALPN: &[u8] = b"rama-quic-resumption";

/// A session store the server was asked for, so a case can tell a lookup from a resumption.
///
/// `finds` is what it hands back for any key: real bytes resume, anything else does not.
#[derive(Debug)]
struct AskedStore {
    finds: Option<Vec<u8>>,
    inner: Arc<dyn StoresServerSessions>,
    asked: AtomicUsize,
}

impl AskedStore {
    /// A store that keeps what it is given and hands it back, as rustls's own does.
    fn keeping() -> Arc<Self> {
        Arc::new(Self {
            finds: None,
            inner: ServerSessionMemoryCache::new(4),
            asked: AtomicUsize::new(0),
        })
    }

    /// A store that answers every lookup with bytes that are not a session.
    fn finding(bytes: &[u8]) -> Arc<Self> {
        Arc::new(Self {
            finds: Some(bytes.to_vec()),
            inner: ServerSessionMemoryCache::new(4),
            asked: AtomicUsize::new(0),
        })
    }

    fn asked(&self) -> usize {
        self.asked.load(Ordering::SeqCst)
    }
}

impl StoresServerSessions for AskedStore {
    fn put(&self, key: Vec<u8>, value: Vec<u8>) -> bool {
        self.inner.put(key, value)
    }

    fn get(&self, key: &[u8]) -> Option<Vec<u8>> {
        self.finds.clone().or_else(|| self.inner.get(key))
    }

    fn take(&self, key: &[u8]) -> Option<Vec<u8>> {
        self.asked.fetch_add(1, Ordering::SeqCst);
        self.finds.clone().or_else(|| self.inner.take(key))
    }

    fn can_cache(&self) -> bool {
        true
    }
}

/// An endpoint whose server keeps sessions in `store`, and whose client keeps whatever tickets
/// it is given, so two attempts from it can resume.
async fn endpoint_remembering(store: Arc<AskedStore>) -> Endpoint {
    let identity = ServerAuthData::new_generated(GeneratedServerAuthConfig::default())
        .expect("an identity is generated");
    let anchor = identity.cert_chain.last().expect("a chain").clone();
    let tls = TlsServerConfig::new()
        .with_alpn(smallvec![ApplicationProtocol::from(ALPN)])
        .with_server_auth(identity)
        .with_modify_rustls_config(move |mut native| {
            native.session_storage = store.clone();
            Ok(native)
        });
    let server_config = ServerConfig::try_from_rama_tls(&tls, TlsOptions::default())
        .expect("the server config is built");
    let mut endpoint = Endpoint::bind_server(
        rama_core::rt::Executor::new(),
        server_config,
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
    endpoint
}

/// One connection to that endpoint, answered, exchanged over and closed. Answers what each end
/// says about resumption once the exchange is through.
async fn resumption_reported_by_both_ends(endpoint: &Endpoint) -> (Option<bool>, Option<bool>) {
    let accepting = Owned::spawn({
        let endpoint = endpoint.clone();
        async move {
            let connection = endpoint
                .accept()
                .await
                .expect("an attempt arrives")
                .await
                .expect("the handshake completes");
            let mut stream = connection.accept_uni().await.expect("the stream arrives");
            let read = stream
                .read_to_end(octets::kib(1))
                .await
                .expect("it completes");
            let mut answer = connection.open_uni().await.expect("a stream of its own");
            answer
                .write_all(&read)
                .await
                .expect("the answer is written");
            answer.finish().expect("the answer ends");
            connection.closed().await;
            connection
                .extensions()
                .get_ref::<NegotiatedTlsParameters>()
                .expect("the handshake settled something")
                .resumed
        }
    });
    let connection = endpoint
        .connect(endpoint.local_addr().unwrap(), "localhost")
        .unwrap()
        .await
        .expect("the handshake completes");
    let mut stream = connection.open_uni().await.expect("a stream");
    stream.write_all(b"a payload").await.expect("it is written");
    stream.finish().expect("it ends");
    let mut answer = connection.accept_uni().await.expect("the answer arrives");
    let read = answer
        .read_to_end(octets::kib(1))
        .await
        .expect("it completes");
    assert_eq!(read, b"a payload", "the exchange completed");
    let client = connection
        .extensions()
        .get_ref::<NegotiatedTlsParameters>()
        .expect("the handshake settled something")
        .resumed;
    connection.close(0u32, b"done");
    connection.closed().await;
    (client, accepting.join().await)
}

/// A resumed handshake says so on both ends, and the first one says it was not resumed.
#[tokio::test]
async fn a_resumed_handshake_is_reported_on_both_ends() {
    let _guard = subscribe();
    let case = async {
        let store = AskedStore::keeping();
        let endpoint = endpoint_remembering(store.clone()).await;

        let (client, server) = resumption_reported_by_both_ends(&endpoint).await;
        assert_eq!(
            (client, server),
            (Some(false), Some(false)),
            "a first handshake resumes nothing"
        );

        let (client, server) = resumption_reported_by_both_ends(&endpoint).await;
        assert_eq!(
            (client, server),
            (Some(true), Some(true)),
            "the second takes up the session the first left"
        );
        assert!(store.asked() > 0, "and the server looked the session up");
        endpoint.wait_idle().await;
    };
    timeout(LIMIT, case)
        .await
        .expect("the case ran out of time");
}

/// A session found in the store is not a resumption. The store answers every lookup, so the
/// lookup succeeds and the bytes are still not a session: both ends report a full handshake.
#[tokio::test]
async fn a_session_found_is_not_a_resumption() {
    let _guard = subscribe();
    let case = async {
        let store = AskedStore::finding(b"bytes that are not a session");
        let endpoint = endpoint_remembering(store.clone()).await;

        let (client, server) = resumption_reported_by_both_ends(&endpoint).await;
        assert_eq!(
            (client, server),
            (Some(false), Some(false)),
            "a first handshake resumes nothing"
        );

        let (client, server) = resumption_reported_by_both_ends(&endpoint).await;
        assert!(
            store.asked() > 0,
            "the second attempt offered a ticket and the store answered it"
        );
        assert_eq!(
            (client, server),
            (Some(false), Some(false)),
            "and what came back was not a session, so neither end reports a resumption"
        );
        endpoint.wait_idle().await;
    };
    timeout(LIMIT, case)
        .await
        .expect("the case ran out of time");
}
