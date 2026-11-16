//! Server identity matching for verifiers that only validate the chain.

use std::net::IpAddr;

use rama_net::address::{DomainLabels as _, DomainRef};
use x509_parser::{certificate::X509Certificate, extensions::GeneralName, prelude::FromDer as _};

/// Whether the subject alternative names of `leaf` cover `server_name`, or
/// `None` when `leaf` is not a certificate.
///
/// A wildcard covers exactly one left-most label, and IP addresses match
/// `iPAddress` entries. The subject common name is not consulted.
#[cfg_attr(
    not(any(
        target_os = "android",
        all(test, any(feature = "boring", feature = "aws-lc", feature = "ring"))
    )),
    expect(dead_code, reason = "only Android's verifier leaves names to rama")
)]
pub(super) fn leaf_matches(leaf: &[u8], server_name: &str) -> Option<bool> {
    let (_, certificate) = X509Certificate::from_der(leaf).ok()?;
    let Ok(Some(names)) = certificate.subject_alternative_name() else {
        return Some(false);
    };
    let names = &names.value.general_names;

    if let Ok(ip) = server_name.parse::<IpAddr>() {
        return Some(names.iter().any(|name| match name {
            GeneralName::IPAddress(bytes) => ip_matches(ip, bytes),
            _ => false,
        }));
    }
    let Ok(server_name) = DomainRef::try_from(server_name) else {
        return Some(false);
    };
    Some(names.iter().any(|name| match name {
        GeneralName::DNSName(pattern) => {
            DomainRef::try_from(*pattern).is_ok_and(|pattern| dns_matches(pattern, server_name))
        }
        _ => false,
    }))
}

fn ip_matches(ip: IpAddr, bytes: &[u8]) -> bool {
    match ip {
        IpAddr::V4(ip) => bytes == ip.octets(),
        IpAddr::V6(ip) => bytes == ip.octets(),
    }
}

fn dns_matches(pattern: DomainRef<'_>, server_name: DomainRef<'_>) -> bool {
    let mut pattern_labels = pattern.labels();
    if !pattern_labels
        .next()
        .is_some_and(|label| label.is_wildcard())
    {
        return pattern == server_name;
    }
    // Never a wildcard over a single label such as `*.com`.
    pattern.label_count() > 2
        && pattern.label_count() == server_name.label_count()
        && pattern_labels.eq(server_name.labels().skip(1))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn matches(pattern: &str, server_name: &str) -> bool {
        match (
            DomainRef::try_from(pattern),
            DomainRef::try_from(server_name),
        ) {
            (Ok(pattern), Ok(server_name)) => dns_matches(pattern, server_name),
            _ => false,
        }
    }

    #[test]
    fn dns_names_match_case_insensitively() {
        assert!(matches("Example.COM", "example.com"));
        assert!(matches("example.com.", "example.com"));
        assert!(!matches("example.com", "www.example.com"));
    }

    #[test]
    fn wildcards_cover_exactly_one_leftmost_label() {
        assert!(matches("*.example.com", "www.example.com"));
        assert!(!matches("*.example.com", "example.com"));
        assert!(!matches("*.example.com", "a.b.example.com"));
        assert!(!matches("*.com", "example.com"));
        assert!(!matches("w*.example.com", "www.example.com"));
        assert!(!matches("*.*.example.com", "a.b.example.com"));
    }

    #[test]
    #[cfg(any(feature = "boring", feature = "aws-lc", feature = "ring"))]
    fn leaf_names_come_from_subject_alternative_names() {
        use crate::cert::{GeneratedServerAuthConfig, generate_server_auth};
        use rama_net::address::Domain;

        let (chain, _) = generate_server_auth(GeneratedServerAuthConfig::generated_ca_for(
            Domain::from_static("leaf.example.com"),
        ))
        .unwrap();
        assert_eq!(leaf_matches(&chain[0], "leaf.example.com"), Some(true));
        assert_eq!(leaf_matches(&chain[0], "LEAF.example.com"), Some(true));
        assert_eq!(leaf_matches(&chain[0], "other.example.com"), Some(false));

        let (chain, _) = generate_server_auth(GeneratedServerAuthConfig::generated_ca_for(
            std::net::IpAddr::from([127, 0, 0, 1]),
        ))
        .unwrap();
        assert_eq!(leaf_matches(&chain[0], "127.0.0.1"), Some(true));
        assert_eq!(leaf_matches(&chain[0], "127.0.0.2"), Some(false));
        assert_eq!(leaf_matches(&[0x30], "127.0.0.1"), None);
    }

    #[test]
    fn ip_addresses_match_by_octets() {
        assert!(ip_matches("127.0.0.1".parse().unwrap(), &[127, 0, 0, 1]));
        assert!(!ip_matches("127.0.0.1".parse().unwrap(), &[127, 0, 0, 2]));
        assert!(ip_matches(
            "::1".parse().unwrap(),
            &[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        ));
    }
}
