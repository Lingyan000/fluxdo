//! Full native handshakes, including tickets issued before a fresh policy is selected.

use super::*;
use crate::tls::ClientSessionPolicy;

#[test]
fn fresh_client_policy_keeps_full_handshakes_across_providers_and_versions() {
    #[cfg(all(feature = "rustls", any(feature = "ring", feature = "aws-lc")))]
    let rustls = RustlsTlsProvider::new(configured_provider());
    let providers: &[&dyn TestTlsProvider] = &[
        &BoringTlsProvider,
        #[cfg(all(feature = "rustls", any(feature = "ring", feature = "aws-lc")))]
        &rustls,
    ];
    for provider in providers {
        for policy in [ClientSessionPolicy::Reuse, ClientSessionPolicy::Fresh] {
            let (client, server) = configs();
            let options = TlsOptions::default()
                .with_early_data(true)
                .with_client_sessions(policy);
            let client = provider.client_config(&client, options).unwrap().crypto;
            let server = provider
                .server_config(&server, options)
                .unwrap()
                .crypto
                .into_fixed();
            for version in [Version::V1, Version::V2] {
                for attempt in 0..3 {
                    let mut c = client
                        .clone()
                        .start_session(version, "localhost", &params(Side::Client))
                        .unwrap();
                    let mut s = server
                        .clone()
                        .start_session(version, &params(Side::Server))
                        .unwrap();
                    let resumed = policy == ClientSessionPolicy::Reuse && attempt != 0;
                    assert_eq!(c.early_crypto().is_some(), resumed);
                    check_session(&mut *c, &mut *s, resumed);
                    assert_eq!(c.early_data_accepted(), Some(resumed));
                }
            }
        }
    }
}

#[test]
fn fresh_boring_sessions_neither_consume_warm_tickets_nor_retain_new_ones() {
    for warm in [false, true] {
        let (client, server) = configs();
        client
            .as_extensions()
            .extend(&SharedClientSessions::defaults());
        let options = TlsOptions::default().with_early_data(true);
        let reusable = Arc::new(QuicClientConfig::from_rama(&client, options).unwrap());
        let server = Arc::new(QuicServerConfig::from_rama(&server, options).unwrap());
        if warm {
            for version in [Version::V1, Version::V2] {
                let mut c = reusable
                    .clone()
                    .start_session(version, "localhost", &params(Side::Client))
                    .unwrap();
                let mut s = server
                    .clone()
                    .start_session(version, &params(Side::Server))
                    .unwrap();
                check_session(&mut *c, &mut *s, false);
            }
        }
        let fresh = Arc::new(
            QuicClientConfig::from_rama(
                &client,
                options.with_client_sessions(ClientSessionPolicy::Fresh),
            )
            .unwrap(),
        );
        for version in [Version::V1, Version::V2] {
            for _ in 0..3 {
                assert_eq!(fresh.resumable_version("localhost"), None);
                let mut c = fresh
                    .clone()
                    .start_session(version, "localhost", &params(Side::Client))
                    .unwrap();
                let mut s = server
                    .clone()
                    .start_session(version, &params(Side::Server))
                    .unwrap();
                assert!(c.early_crypto().is_none());
                check_session(&mut *c, &mut *s, false);
            }
            let mut c = reusable
                .clone()
                .start_session(version, "localhost", &params(Side::Client))
                .unwrap();
            let mut s = server
                .clone()
                .start_session(version, &params(Side::Server))
                .unwrap();
            // Three fresh handshakes would exhaust the two retained tickets if
            // they consulted the store, or populate an initially empty store.
            check_session(&mut *c, &mut *s, warm);
        }
    }
}
