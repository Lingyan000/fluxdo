//! Native session ownership, engine parameters and failure before connection admission.

use crate::tls::{ClientHandshake, ClientSessionPolicy};
use rama_net::address::Host;
use rama_tls::client::{ClientHello, ClientHelloExtension};

use super::*;

fn count_initializations(config: &TlsClientConfig) -> Arc<AtomicUsize> {
    let count = Arc::new(AtomicUsize::new(0));
    let seen = count.clone();
    config
        .as_extensions()
        .insert(HandshakeInitializer(Arc::new(move |_| {
            seen.fetch_add(1, Ordering::SeqCst);
            Ok(())
        })));
    count
}

#[test]
fn prepared_ssl_is_consumed_once_and_retries_keep_fresh_native_state() {
    for version in [Version::V1, Version::V2] {
        let (client, server) = configs();
        let observed = Arc::new(parking_lot::Mutex::new(Vec::new()));
        let seen = observed.clone();
        let initializations = Arc::new(AtomicUsize::new(0));
        let initialized = initializations.clone();
        let completed = Arc::new(AtomicUsize::new(0));
        let finished = completed.clone();
        client
            .as_extensions()
            .insert(HandshakeInitializer(Arc::new(move |ssl| {
                initialized.fetch_add(1, Ordering::SeqCst);
                let seen = seen.clone();
                ssl.set_msg_callback(move |_, message| {
                    if message.is_written()
                        && message.content_type()
                            == rama_crypto::dep::boring::ssl::SslContentType::HANDSHAKE
                        && message.bytes().first() == Some(&1)
                    {
                        let ClientHelloHandshakePrefix::Complete(hello) =
                            parse_client_hello_message_prefix(message.bytes())
                        else {
                            panic!("native ClientHello must be complete");
                        };
                        seen.lock().push(hello);
                    }
                });
                let finished = finished.clone();
                // This native hook must survive preparation into the actual session.
                // Counting construction alone would miss discarding the prepared SSL.
                on_handshake_completed(ssl, move |_| {
                    finished.fetch_add(1, Ordering::SeqCst);
                })
            })));
        let client = BoringTlsProvider
            .prepare_fresh_client_config(&client, Host::try_from("localhost").unwrap())
            .unwrap()
            .crypto;
        assert_eq!(initializations.load(Ordering::SeqCst), 1);
        let server = BoringTlsProvider
            .server_config(&server, TlsOptions::default())
            .unwrap()
            .crypto
            .into_fixed();
        for attempt in 0..3 {
            let mut parameters = params(Side::Client);
            parameters.initial_src_cid = Some(ConnectionId::new(&[10 + attempt]));
            let mut c = client
                .clone()
                .start_session(version, "localhost", &parameters)
                .unwrap();
            assert_eq!(
                initializations.load(Ordering::SeqCst),
                usize::from(attempt) + 1
            );
            assert!(c.early_crypto().is_none());
            assert_eq!(client.resumable_version("localhost"), None);
            let mut s = server
                .clone()
                .start_session(version, &params(Side::Server))
                .unwrap();
            // Complete an authenticated exchange before comparing the test-only
            // observation with this connection's transport parameters.
            check_session(&mut *c, &mut *s, false);
            let mut encoded = Vec::new();
            parameters.write(&mut encoded);
            let observed = observed.lock();
            let actual = observed
                .last()
                .unwrap()
                .extensions()
                .iter()
                .find_map(|extension| match extension {
                    ClientHelloExtension::Opaque { id, data }
                        if *id == ExtensionId::QUIC_TRANSPORT_PARAMETERS =>
                    {
                        Some(data)
                    }
                    _ => None,
                })
                .unwrap();
            assert_eq!(actual.as_slice(), encoded);
            assert_eq!(completed.load(Ordering::SeqCst), usize::from(attempt) + 1);
        }
        let observed = observed.lock();
        assert_eq!(observed.len(), 3);
        for pair in observed.windows(2) {
            let shares = |hello: &ClientHello| {
                hello
                    .extensions()
                    .iter()
                    .find_map(|extension| match extension {
                        ClientHelloExtension::Opaque { id, data }
                            if *id == ExtensionId::KEY_SHARE =>
                        {
                            Some(data.clone())
                        }
                        _ => None,
                    })
                    .unwrap()
            };
            assert_ne!(shares(&pair[0]), shares(&pair[1]));
        }
    }
}

#[test]
fn wrong_peer_does_not_consume_the_prepared_ssl() {
    let (client, server) = configs();
    let count = count_initializations(&client);
    let client = BoringTlsProvider
        .prepare_fresh_client_config(
            &client,
            rama_net::address::Host::try_from("localhost").unwrap(),
        )
        .unwrap()
        .crypto;
    assert!(
        client
            .clone()
            .start_session(Version::V1, "other.invalid", &params(Side::Client))
            .is_err()
    );
    assert_eq!(count.load(Ordering::SeqCst), 1);
    let mut c = client
        .start_session(Version::V1, "localhost", &params(Side::Client))
        .unwrap();
    assert_eq!(count.load(Ordering::SeqCst), 1);
    let mut s = BoringTlsProvider
        .server_config(&server, TlsOptions::default())
        .unwrap()
        .crypto
        .into_fixed()
        .start_session(Version::V1, &params(Side::Server))
        .unwrap();
    check_session(&mut *c, &mut *s, false);
}

#[test]
fn racing_attempts_own_distinct_sessions_and_initialize_each_once() {
    let (client, server) = configs();
    let count = count_initializations(&client);
    let client = BoringTlsProvider
        .prepare_fresh_client_config(
            &client,
            rama_net::address::Host::try_from("localhost").unwrap(),
        )
        .unwrap()
        .crypto;
    assert_eq!(count.load(Ordering::SeqCst), 1);
    let server = BoringTlsProvider
        .server_config(&server, TlsOptions::default())
        .unwrap()
        .crypto
        .into_fixed();
    std::thread::scope(|scope| {
        let barrier = Arc::new(std::sync::Barrier::new(4));
        let attempts = (0..4)
            .map(|attempt| {
                let client = client.clone();
                let server = server.clone();
                let barrier = barrier.clone();
                scope.spawn(move || {
                    barrier.wait();
                    let version = if attempt % 2 == 0 {
                        Version::V1
                    } else {
                        Version::V2
                    };
                    let mut c = client
                        .start_session(version, "localhost", &params(Side::Client))
                        .unwrap();
                    let mut s = server
                        .start_session(version, &params(Side::Server))
                        .unwrap();
                    check_session(&mut *c, &mut *s, false);
                })
            })
            .collect::<Vec<_>>();
        for attempt in attempts {
            attempt.join().unwrap();
        }
    });
    assert_eq!(count.load(Ordering::SeqCst), 4);
}

/// The native seam is also useful to relays which do not depend on rama-ua.
/// Full offers retain live tickets; resumed offers require one for this peer/version.
#[test]
fn native_handshake_requirements_preserve_tickets_without_ua_profiles() {
    for version in [Version::V1, Version::V2] {
        let (policy, server) = configs();
        let cache = ClientConfigCache::new(Arc::new(BoringTlsProvider), TlsOptions::default());
        let server = BoringTlsProvider
            .server_config(&server, TlsOptions::default())
            .unwrap()
            .crypto
            .into_fixed();

        // An empty ticket domain cannot satisfy a resumed handshake.
        policy.as_extensions().insert(ClientHandshake::Resumed);
        let resumed = cache
            .client_config_for_peer(
                &policy,
                policy.as_extensions(),
                &Host::try_from("localhost").unwrap(),
            )
            .unwrap();
        assert!(
            resumed
                .crypto
                .start_session(version, "localhost", &params(Side::Client))
                .is_err()
        );

        // Full means no ticket offer even after the first exchange warms the store.
        for _ in 0..2 {
            policy.as_extensions().insert(ClientHandshake::Full);
            let full = cache
                .client_config_for_peer(
                    &policy,
                    policy.as_extensions(),
                    &Host::try_from("localhost").unwrap(),
                )
                .unwrap();
            assert_eq!(full.crypto.resumable_version("localhost"), None);
            let mut client = full
                .crypto
                .start_session(version, "localhost", &params(Side::Client))
                .unwrap();
            let mut peer = server
                .clone()
                .start_session(version, &params(Side::Server))
                .unwrap();
            check_session(&mut *client, &mut *peer, false);
        }

        // Tickets from those full offers remain usable by a subsequent resumed offer.
        policy.as_extensions().insert(ClientHandshake::Resumed);
        let resumed = cache
            .client_config_for_peer(
                &policy,
                policy.as_extensions(),
                &Host::try_from("localhost").unwrap(),
            )
            .unwrap();
        assert_eq!(resumed.crypto.resumable_version("localhost"), Some(version));
        let mut client = resumed
            .crypto
            .start_session(version, "localhost", &params(Side::Client))
            .unwrap();
        let mut peer = server
            .start_session(version, &params(Side::Server))
            .unwrap();
        check_session(&mut *client, &mut *peer, true);

        let fresh = ClientConfigCache::new(
            Arc::new(BoringTlsProvider),
            TlsOptions::default().with_client_sessions(ClientSessionPolicy::Fresh),
        );
        fresh
            .client_config_for_peer(
                &policy,
                policy.as_extensions(),
                &Host::try_from("localhost").unwrap(),
            )
            .unwrap_err();
    }
}

/// Direct native configuration consumes the same setting as the peer-bound cache.
#[test]
fn shared_handshake_settings_apply_without_peer_preparation() {
    for version in [Version::V1, Version::V2] {
        let (policy, server) = configs();
        policy
            .as_extensions()
            .extend(&BoringTlsProvider.session_defaults().unwrap());
        let server = BoringTlsProvider
            .server_config(&server, TlsOptions::default())
            .unwrap()
            .crypto
            .into_fixed();

        policy.as_extensions().insert(ClientHandshake::Resumed);
        let missing = BoringTlsProvider
            .client_config(&policy, TlsOptions::default())
            .unwrap();
        assert!(
            missing
                .crypto
                .start_session(version, "localhost", &params(Side::Client))
                .is_err()
        );

        for _ in 0..2 {
            policy.as_extensions().insert(ClientHandshake::Full);
            let full = BoringTlsProvider
                .client_config(&policy, TlsOptions::default())
                .unwrap();
            let mut client = full
                .crypto
                .start_session(version, "localhost", &params(Side::Client))
                .unwrap();
            let mut peer = server
                .clone()
                .start_session(version, &params(Side::Server))
                .unwrap();
            check_session(&mut *client, &mut *peer, false);
        }

        policy.as_extensions().insert(ClientHandshake::Resumed);
        let resumed = BoringTlsProvider
            .client_config(&policy, TlsOptions::default())
            .unwrap();
        let mut client = resumed
            .crypto
            .start_session(version, "localhost", &params(Side::Client))
            .unwrap();
        let mut peer = server
            .start_session(version, &params(Side::Server))
            .unwrap();
        check_session(&mut *client, &mut *peer, true);
        BoringTlsProvider
            .client_config(
                &policy,
                TlsOptions::default().with_client_sessions(ClientSessionPolicy::Fresh),
            )
            .unwrap_err();
    }
}
