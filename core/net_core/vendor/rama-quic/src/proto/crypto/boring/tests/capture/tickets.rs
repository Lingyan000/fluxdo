//! Captured full-to-resumed handshakes use tickets from the live peer only.

use super::{fixture::*, *};
use crate::{ClientConfig, tls::ClientSessionPolicy};
use rama_net::address::Host;
use rama_ua::profile::capture::tls::{TlsCapture, TlsCapturedExtensionValue};

fn prepared(
    cache: &ClientConfigCache,
    policy: &TlsClientConfig,
    source: &TlsCapture,
) -> ClientConfig {
    prepare_with_cache(cache, policy, &Host::try_from("localhost").unwrap(), source).unwrap()
}

fn exchange(
    client: Arc<dyn crypto::ClientConfig>,
    server: Arc<dyn crypto::ServerConfig>,
    version: Version,
    resumed: bool,
) {
    let mut client = client
        .start_session(version, "localhost", &params(Side::Client))
        .unwrap();
    let mut server = server
        .start_session(version, &params(Side::Server))
        .unwrap();
    check_session(&mut *client, &mut *server, resumed);
}

// Source and replay have independent client stores. Replaying only sanitized
// lengths succeeds because the replay obtains its own ticket from this peer.
fn sources(
    policy: &TlsClientConfig,
    server: Arc<dyn crypto::ServerConfig>,
    version: Version,
) -> (TlsCapture, TlsCapture) {
    let full = reference(policy, version);
    let client = BoringTlsProvider
        .client_config(policy, TlsOptions::default())
        .unwrap()
        .crypto;
    exchange(client.clone(), server, version, false);
    let resumed = first_capture(client, version);
    assert!(
        resumed
            .extensions
            .iter()
            .any(|field| field.id == u16::from(ExtensionId::PRE_SHARED_KEY))
    );
    (full, resumed)
}

#[test]
fn captured_full_offers_retain_current_tickets_for_captured_resumed_offers() {
    for version in [Version::V1, Version::V2] {
        let (policy, server) = policy();
        let server = BoringTlsProvider
            .server_config(&server, TlsOptions::default())
            .unwrap()
            .crypto
            .into_fixed();
        let (full, resumed) = sources(&policy, server.clone(), version);
        let cache = ClientConfigCache::new(Arc::new(BoringTlsProvider), TlsOptions::default());

        // Even a warm store must produce another full offer when selected.
        for _ in 0..3 {
            let client = prepared(&cache, &policy, &full).crypto;
            assert_eq!(client.resumable_version("localhost"), None);
            exchange(client, server.clone(), version, false);
        }
        let client = prepared(&cache, &policy, &resumed).crypto;
        assert_eq!(client.resumable_version("localhost"), Some(version));
        exchange(client, server, version, true);
    }
}

#[test]
fn captured_resumed_offers_resume_only_with_the_current_peer_version_and_policy() {
    for version in [Version::V1, Version::V2] {
        let (policy, server) = policy();
        let policy = policy
            .with_session_profile_scope(TlsSessionProfileScope("profile A / tenant A".into()));
        let server = BoringTlsProvider
            .server_config(&server, TlsOptions::default())
            .unwrap()
            .crypto
            .into_fixed();
        let (full, resumed) = sources(&policy, server.clone(), version);
        let cache = ClientConfigCache::new(Arc::new(BoringTlsProvider), TlsOptions::default());

        // Without a current peer-issued ticket a resumed offer is a full handshake.
        exchange(
            prepared(&cache, &policy, &resumed).crypto,
            server.clone(),
            version,
            false,
        );
        exchange(
            prepared(&cache, &policy, &full).crypto,
            server.clone(),
            version,
            false,
        );

        let other_version = if version == Version::V1 {
            Version::V2
        } else {
            Version::V1
        };
        let client = prepared(&cache, &policy, &resumed).crypto;
        let _session = client
            .start_session(other_version, "localhost", &params(Side::Client))
            .unwrap();
        let client = prepare_with_cache(
            &cache,
            &policy,
            &Host::try_from("other.invalid").unwrap(),
            &resumed,
        )
        .unwrap()
        .crypto;
        let _session = client
            .start_session(version, "other.invalid", &params(Side::Client))
            .unwrap();
        for other in [
            policy
                .clone()
                .with_session_profile_scope(TlsSessionProfileScope("profile B / tenant A".into())),
            policy
                .clone()
                .with_session_profile_scope(TlsSessionProfileScope("profile A / tenant B".into())),
            policy.clone().with_server_verify(ServerVerifyMode::Disable),
        ] {
            let client = prepared(&cache, &other, &resumed).crypto;
            let _session = client
                .start_session(version, "localhost", &params(Side::Client))
                .unwrap();
        }

        // Lookups for other bindings found no ticket and did not consume the current one.
        exchange(
            prepared(&cache, &policy, &resumed).crypto,
            server,
            version,
            true,
        );
    }
}

#[test]
fn fresh_capture_cache_neither_retains_tickets_nor_resumes_a_resumed_offer() {
    for version in [Version::V1, Version::V2] {
        let (policy, server) = policy();
        let server = BoringTlsProvider
            .server_config(&server, TlsOptions::default())
            .unwrap()
            .crypto
            .into_fixed();
        let (full, resumed) = sources(&policy, server.clone(), version);
        let fresh = ClientConfigCache::new(
            Arc::new(BoringTlsProvider),
            TlsOptions::default().with_client_sessions(ClientSessionPolicy::Fresh),
        );
        for _ in 0..3 {
            exchange(
                prepared(&fresh, &policy, &full).crypto,
                server.clone(),
                version,
                false,
            );
        }
        prepare_with_cache(
            &fresh,
            &policy,
            &Host::try_from("localhost").unwrap(),
            &resumed,
        )
        .unwrap();

        // A sibling cache has its own domain, including when policy is identical.
        let empty = ClientConfigCache::new(Arc::new(BoringTlsProvider), TlsOptions::default());
        let (_, resumed) = sources(&policy, server.clone(), version);
        let client = prepared(&empty, &policy, &resumed).crypto;
        let _session = client
            .start_session(version, "localhost", &params(Side::Client))
            .unwrap();
    }
}

#[test]
fn captured_ticket_lengths_do_not_replace_peer_issued_tickets() {
    for version in [Version::V1, Version::V2] {
        let (policy, server) = policy();
        let server = BoringTlsProvider
            .server_config(&server, TlsOptions::default())
            .unwrap()
            .crypto
            .into_fixed();
        let (full, resumed) = sources(&policy, server.clone(), version);
        let cache = ClientConfigCache::new(Arc::new(BoringTlsProvider), TlsOptions::default());
        exchange(
            prepared(&cache, &policy, &full).crypto,
            server.clone(),
            version,
            false,
        );
        let mut wrong = resumed.clone();
        let identities = wrong
            .extensions
            .iter_mut()
            .find_map(|field| match &mut field.value {
                TlsCapturedExtensionValue::PreSharedKeys { identities, .. } => Some(identities),
                _ => None,
            })
            .unwrap();
        identities[0] += 1;
        let client = prepared(&cache, &policy, &wrong).crypto;
        let actual = first_capture(client, version);
        assert_ne!(actual, wrong);
        assert_eq!(actual, resumed);
        exchange(
            prepared(&cache, &policy, &resumed).crypto,
            server,
            version,
            true,
        );
    }
}

#[test]
fn captured_cipher_grease_draws_share_current_tickets() {
    for version in [Version::V1, Version::V2] {
        let (policy, server) = policy();
        let server = BoringTlsProvider
            .server_config(&server, TlsOptions::default())
            .unwrap()
            .crypto
            .into_fixed();
        let (mut full, mut resumed) = sources(&policy, server.clone(), version);
        full.ciphers = std::iter::once(0x0a0a)
            .chain(full.ciphers.iter().copied())
            .collect();
        resumed.ciphers = std::iter::once(0x1a1a)
            .chain(resumed.ciphers.iter().copied())
            .collect();
        let cache = ClientConfigCache::new(Arc::new(BoringTlsProvider), TlsOptions::default());

        // GREASE draws change the offer; only peer-issued session state carries
        // across compatible native policies.
        exchange(
            prepared(&cache, &policy, &full).crypto,
            server.clone(),
            version,
            false,
        );
        // A changed real cipher policy still gets no access to this ticket.
        // Its missed lookup must not consume the compatible draw's session.
        let mut restricted = resumed.clone();
        restricted.ciphers = restricted.ciphers[..restricted.ciphers.len() - 1].into();
        let client = prepared(&cache, &policy, &restricted).crypto;
        let _session = client
            .start_session(version, "localhost", &params(Side::Client))
            .unwrap();
        exchange(
            prepared(&cache, &policy, &resumed).crypto,
            server,
            version,
            true,
        );
    }
}
