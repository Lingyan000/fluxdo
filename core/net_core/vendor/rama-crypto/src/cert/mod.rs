//! Certificate generation helpers.
//!
//! Provides a backend pluggable self-signed certificate generator. The actual
//! crypto provider is selected by cargo feature:
//!
//! - `boring`: generate using BoringSSL (via `rama-boring`), for stacks that
//!   already link boringssl and do not want a second crypto provider.
//! - `aws-lc` / `ring`: generate using `rcgen`.
//!
//! When several providers are enabled, `boring` is preferred. With none
//! enabled, certificate-generation functions return an error.

use std::{net::IpAddr, time::Duration};

use rama_core::error::{BoxError, BoxErrorExt as _};
use rama_net::address::{Domain, Host};
use serde::{Deserialize, Serialize};

use crate::pki_types::{CertificateDer, PrivateKeyDer};

#[cfg(feature = "boring")]
#[cfg_attr(docsrs, doc(cfg(feature = "boring")))]
pub mod boring;

#[cfg(any(feature = "aws-lc", feature = "ring"))]
pub mod rcgen;

/// DNS or IP service identity encoded in a certificate's SAN extension.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum CertificateIdentity {
    Dns(Domain),
    Ip(IpAddr),
}

impl CertificateIdentity {
    /// Classify a network host as a certificate identity.
    pub fn try_from_host(host: &Host) -> Result<Self, BoxError> {
        if let Ok(ip) = host.try_as_ip() {
            return Ok(Self::Ip(ip));
        }

        let domain = host.try_as_domain()?;
        Ok(domain
            .as_str()
            .parse()
            .map_or_else(|_| Self::Dns(domain.into_owned()), Self::Ip))
    }
}

impl From<Domain> for CertificateIdentity {
    fn from(domain: Domain) -> Self {
        domain
            .as_str()
            .parse()
            .map_or_else(|_| Self::Dns(domain), Self::Ip)
    }
}

impl From<IpAddr> for CertificateIdentity {
    fn from(ip: IpAddr) -> Self {
        Self::Ip(ip)
    }
}

impl TryFrom<&Host> for CertificateIdentity {
    type Error = BoxError;

    fn try_from(host: &Host) -> Result<Self, Self::Error> {
        Self::try_from_host(host)
    }
}

impl TryFrom<Host> for CertificateIdentity {
    type Error = BoxError;

    fn try_from(host: Host) -> Result<Self, Self::Error> {
        Self::try_from_host(&host)
    }
}

/// X.509 subject metadata. Service identities belong in SANs, not the CN.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CertificateSubject {
    pub organisation_name: Option<String>,
    pub common_name: Option<String>,
}

/// Validity policy relative to certificate generation time.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct CertificateValidity {
    /// Time between `notBefore` and `notAfter`; must be at least one second.
    pub lifetime: Duration,
    /// Amount by which `notBefore` is backdated for clock skew.
    pub not_before_skew: Duration,
}

impl CertificateValidity {
    #[must_use]
    pub const fn new(lifetime: Duration, not_before_skew: Duration) -> Self {
        Self {
            lifetime,
            not_before_skew,
        }
    }
}

impl Default for CertificateValidity {
    fn default() -> Self {
        Self::new(Duration::from_hours(90 * 24), Duration::from_mins(1))
    }
}

#[cfg(any(feature = "boring", feature = "aws-lc", feature = "ring"))]
pub(super) fn validate_certificate_lifetime(lifetime: Duration) -> Result<(), BoxError> {
    if lifetime < Duration::from_secs(1) {
        return Err(BoxError::from_static_str(
            "certificate lifetime must be at least one second",
        ));
    }
    Ok(())
}

/// Key algorithm to use when generating a self-signed key pair.
///
/// The default is [`CertificateKeyKind::EcP256`]: it is universally supported by
/// TLS clients, generates and signs far faster than any RSA variant, and offers
/// stronger security (128-bit) than RSA-2048 with much smaller certificates.
/// Pick [`CertificateKeyKind::EcP384`] for a higher security margin (e.g. a
/// long-lived CA) while staying faster than RSA-4096.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
pub enum CertificateKeyKind {
    /// 2048-bit RSA.
    Rsa2048,
    /// 4096-bit RSA.
    Rsa4096,
    /// ECDSA over NIST P-256 (secp256r1). Default.
    #[default]
    EcP256,
    /// ECDSA over NIST P-384 (secp384r1).
    EcP384,
    /// ECDSA over NIST P-521 (secp521r1).
    EcP521,
    /// Ed25519 (EdDSA).
    Ed25519,
}

/// Configuration for a generated self-signed certificate authority.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SelfSignedCaConfig {
    pub subject: CertificateSubject,
    pub validity: CertificateValidity,
    pub key_kind: CertificateKeyKind,
}

impl Default for SelfSignedCaConfig {
    fn default() -> Self {
        Self {
            subject: CertificateSubject::default(),
            validity: CertificateValidity::new(
                Duration::from_hours(365 * 20 * 24),
                Duration::from_mins(1),
            ),
            key_kind: CertificateKeyKind::default(),
        }
    }
}

#[cfg(any(feature = "boring", feature = "aws-lc", feature = "ring"))]
#[derive(Clone, Copy, PartialEq, Eq)]
enum LeafCertUsage {
    ServerAuth,
    ClientAuth,
}

/// Reusable policy for an end-entity certificate.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct LeafCertConfig {
    pub subject: CertificateSubject,
    pub validity: CertificateValidity,
    pub key_kind: CertificateKeyKind,
}

/// One concrete leaf-certificate request; the issuance method selects its TLS role.
/// Server certificates require a DNS/IP identity. Client certificates may instead
/// use an explicit nonempty subject, with no SAN extension.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LeafCertRequest {
    pub config: LeafCertConfig,
    pub identities: Vec<CertificateIdentity>,
}

impl Default for LeafCertRequest {
    fn default() -> Self {
        Self {
            config: LeafCertConfig::default(),
            identities: vec![CertificateIdentity::Dns(Domain::from_static("localhost"))],
        }
    }
}

impl LeafCertRequest {
    #[must_use]
    pub fn new(identity: impl Into<CertificateIdentity>) -> Self {
        Self {
            config: LeafCertConfig::default(),
            identities: vec![identity.into()],
        }
    }
}

/// Name an issued leaf after its first identity when it would otherwise carry
/// its issuer's exact subject: some path builders, Android's among them, then
/// take it for self-issued and never reach the issuer.
#[cfg(any(feature = "boring", feature = "aws-lc", feature = "ring"))]
fn keep_leaf_subject_apart_from_issuer(
    request: &mut LeafCertRequest,
    issuer_organisation: Option<&str>,
    issuer_has_common_name: bool,
) {
    let subject = &mut request.config.subject;
    if subject.common_name.is_some()
        || issuer_has_common_name
        || subject.organisation_name.as_deref() != issuer_organisation
    {
        return;
    }
    subject.common_name = request.identities.first().map(|identity| match identity {
        CertificateIdentity::Dns(domain) => domain.as_str().to_owned(),
        CertificateIdentity::Ip(ip) => ip.to_string(),
    });
}

#[cfg(any(feature = "boring", feature = "aws-lc", feature = "ring"))]
fn validate_leaf_request(request: &LeafCertRequest, usage: LeafCertUsage) -> Result<(), BoxError> {
    if !request.identities.is_empty() {
        return Ok(());
    }
    if usage == LeafCertUsage::ServerAuth {
        return Err(BoxError::from_static_str(
            "server leaf certificate requires at least one DNS or IP identity",
        ));
    }
    let subject = &request.config.subject;
    if ![&subject.common_name, &subject.organisation_name]
        .into_iter()
        .any(|value| value.as_ref().is_some_and(|value| !value.is_empty()))
    {
        return Err(BoxError::from_static_str(
            "client leaf certificate requires a nonempty subject or DNS/IP identity",
        ));
    }
    Ok(())
}

/// Configuration for generating static server-authentication material.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum GeneratedServerAuthConfig {
    /// One end-entity certificate signed with its own key.
    SelfSignedLeaf(LeafCertRequest),
    /// A generated self-signed CA plus a leaf signed by that CA.
    GeneratedCa {
        ca: SelfSignedCaConfig,
        leaf: LeafCertRequest,
    },
}

impl Default for GeneratedServerAuthConfig {
    fn default() -> Self {
        Self::GeneratedCa {
            ca: SelfSignedCaConfig::default(),
            leaf: LeafCertRequest::default(),
        }
    }
}

impl GeneratedServerAuthConfig {
    #[must_use]
    pub fn generated_ca_for(identity: impl Into<CertificateIdentity>) -> Self {
        Self::GeneratedCa {
            ca: SelfSignedCaConfig::default(),
            leaf: LeafCertRequest::new(identity),
        }
    }
}

/// An issuing CA chain and its private key.
#[derive(Debug)]
pub struct CertificateAuthorityData {
    /// Issuing CA first, followed by any parent certificates.
    certificate_chain: Vec<CertificateDer<'static>>,
    private_key: PrivateKeyDer<'static>,
}

impl CertificateAuthorityData {
    pub fn try_new(
        certificate_chain: Vec<CertificateDer<'static>>,
        private_key: PrivateKeyDer<'static>,
    ) -> Result<Self, BoxError> {
        if certificate_chain.is_empty() {
            return Err(BoxError::from_static_str(
                "certificate authority chain cannot be empty",
            ));
        }
        validate_certificate_authority_key(&certificate_chain[0], &private_key)?;
        for (index, certificate) in certificate_chain.iter().enumerate() {
            use rama_core::error::ErrorContext as _;
            let (_, parsed) = x509_parser::parse_x509_certificate(certificate.as_ref())
                .context("parse certificate authority chain")?;
            let is_ca = parsed
                .basic_constraints()
                .context("parse CA basic constraints")?
                .is_some_and(|extension| extension.value.ca);
            if !is_ca {
                return Err(BoxError::from_static_str(
                    "certificate authority chain certificate must have CA basic constraints",
                ));
            }
            let key_usage = parsed.key_usage().context("parse CA key usage")?;
            if key_usage.is_some_and(|extension| !extension.value.key_cert_sign()) {
                return Err(BoxError::from_static_str(
                    "certificate authority chain certificate must permit certificate signing",
                ));
            }
            if let Some(parent) = certificate_chain.get(index + 1) {
                let (_, parent) = x509_parser::parse_x509_certificate(parent.as_ref())
                    .context("parse parent certificate authority")?;
                if parsed.issuer() != parent.subject() {
                    return Err(BoxError::from_static_str(
                        "certificate authority chain is not ordered issuer-first",
                    ));
                }
            }
        }
        validate_certificate_authority_chain(&certificate_chain)?;
        Ok(Self {
            certificate_chain,
            private_key,
        })
    }

    pub fn generate(config: SelfSignedCaConfig) -> Result<Self, BoxError> {
        generate_certificate_authority(config)
    }

    #[must_use]
    pub fn certificate_chain(&self) -> &[CertificateDer<'static>] {
        &self.certificate_chain
    }

    #[must_use]
    pub fn private_key(&self) -> &PrivateKeyDer<'static> {
        &self.private_key
    }

    #[must_use]
    pub fn into_parts(self) -> (Vec<CertificateDer<'static>>, PrivateKeyDer<'static>) {
        (self.certificate_chain, self.private_key)
    }

    /// Issue a server-authentication leaf.
    pub fn issue_leaf(
        &self,
        request: LeafCertRequest,
    ) -> Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>), BoxError> {
        issue_certificate_authority_leaf(self, request)
    }

    /// Issue a client-authentication leaf using the same CA and key policy.
    /// The request may use a nonempty subject instead of a DNS/IP identity.
    pub fn issue_client_leaf(
        &self,
        request: LeafCertRequest,
    ) -> Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>), BoxError> {
        #[cfg(feature = "boring")]
        {
            boring::issue_certificate_authority_leaf_with_usage(
                self,
                request,
                LeafCertUsage::ClientAuth,
            )
        }
        #[cfg(all(not(feature = "boring"), any(feature = "aws-lc", feature = "ring")))]
        {
            rcgen::issue_certificate_authority_leaf_with_usage(
                self,
                request,
                LeafCertUsage::ClientAuth,
            )
        }
        #[cfg(not(any(feature = "boring", feature = "aws-lc", feature = "ring")))]
        {
            issue_certificate_authority_leaf(self, request)
        }
    }
}

#[cfg(feature = "boring")]
fn validate_certificate_authority_key(
    certificate: &CertificateDer<'_>,
    private_key: &PrivateKeyDer<'_>,
) -> Result<(), BoxError> {
    boring::validate_certificate_authority_key(certificate, private_key)
}

#[cfg(all(not(feature = "boring"), any(feature = "aws-lc", feature = "ring")))]
fn validate_certificate_authority_key(
    certificate: &CertificateDer<'_>,
    private_key: &PrivateKeyDer<'_>,
) -> Result<(), BoxError> {
    rcgen::validate_certificate_authority_key(certificate, private_key)
}

#[cfg(not(any(feature = "boring", feature = "aws-lc", feature = "ring")))]
fn validate_certificate_authority_key(
    _certificate: &CertificateDer<'_>,
    _private_key: &PrivateKeyDer<'_>,
) -> Result<(), BoxError> {
    Err(BoxError::from_static_str(
        "enable a rama-crypto cert provider to validate a certificate authority key",
    ))
}

#[cfg(feature = "boring")]
fn validate_certificate_authority_chain(
    certificate_chain: &[CertificateDer<'_>],
) -> Result<(), BoxError> {
    boring::validate_certificate_authority_chain(certificate_chain)
}

#[cfg(all(not(feature = "boring"), any(feature = "aws-lc", feature = "ring")))]
fn validate_certificate_authority_chain(
    certificate_chain: &[CertificateDer<'_>],
) -> Result<(), BoxError> {
    rcgen::validate_certificate_authority_chain(certificate_chain)
}

#[cfg(not(any(feature = "boring", feature = "aws-lc", feature = "ring")))]
fn validate_certificate_authority_chain(
    certificate_chain: &[CertificateDer<'_>],
) -> Result<(), BoxError> {
    if certificate_chain.len() > 1 {
        return Err(BoxError::from_static_str(
            "enable a rama-crypto cert provider to validate a certificate authority chain",
        ));
    }
    Ok(())
}

impl Clone for CertificateAuthorityData {
    fn clone(&self) -> Self {
        Self {
            certificate_chain: self.certificate_chain.clone(),
            private_key: self.private_key.clone_key(),
        }
    }
}

/// Compute the SHA-256 digest of the certificate's `SubjectPublicKeyInfo`.
///
/// This is the industry-standard TLS pin input, usually exchanged in the
/// `sha256/<base64 digest>` format.
pub fn spki_sha256(certificate: &CertificateDer<'_>) -> Result<[u8; 32], BoxError> {
    use rama_core::error::ErrorContext as _;
    use sha2::Digest as _;
    use x509_parser::prelude::FromDer as _;

    let (_, cert) = x509_parser::certificate::X509Certificate::from_der(certificate.as_ref())
        .context("parse x509 certificate for spki digest")?;
    Ok(sha2::Sha256::digest(cert.public_key().raw).into())
}

/// SHA-256 of `bytes`, e.g. a DER-encoded `SubjectPublicKeyInfo`.
#[must_use]
pub fn sha256(bytes: &[u8]) -> [u8; 32] {
    use sha2::Digest as _;
    sha2::Sha256::digest(bytes).into()
}

#[cfg(feature = "boring")]
pub fn generate_server_auth(
    config: GeneratedServerAuthConfig,
) -> Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>), BoxError> {
    boring::generate_server_auth(config)
}

#[cfg(all(not(feature = "boring"), any(feature = "aws-lc", feature = "ring")))]
pub fn generate_server_auth(
    config: GeneratedServerAuthConfig,
) -> Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>), BoxError> {
    rcgen::generate_server_auth(config)
}

#[cfg(not(any(feature = "boring", feature = "aws-lc", feature = "ring")))]
pub fn generate_server_auth(
    _config: GeneratedServerAuthConfig,
) -> Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>), BoxError> {
    use rama_core::error::BoxErrorExt;

    Err(BoxError::from_static_str(
        "enable one of the rama-crypto cert providers (boring, aws-lc, ring) to generate server auth",
    ))
}

#[cfg(feature = "boring")]
pub fn generate_certificate_authority(
    config: SelfSignedCaConfig,
) -> Result<CertificateAuthorityData, BoxError> {
    boring::generate_certificate_authority(config)
}

#[cfg(all(not(feature = "boring"), any(feature = "aws-lc", feature = "ring")))]
pub fn generate_certificate_authority(
    config: SelfSignedCaConfig,
) -> Result<CertificateAuthorityData, BoxError> {
    rcgen::generate_certificate_authority(config)
}

#[cfg(not(any(feature = "boring", feature = "aws-lc", feature = "ring")))]
pub fn generate_certificate_authority(
    _config: SelfSignedCaConfig,
) -> Result<CertificateAuthorityData, BoxError> {
    Err(BoxError::from_static_str(
        "enable one of the rama-crypto cert providers to generate a certificate authority",
    ))
}

#[cfg(feature = "boring")]
pub fn issue_certificate_authority_leaf(
    ca: &CertificateAuthorityData,
    request: LeafCertRequest,
) -> Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>), BoxError> {
    boring::issue_certificate_authority_leaf(ca, request)
}

#[cfg(all(not(feature = "boring"), any(feature = "aws-lc", feature = "ring")))]
pub fn issue_certificate_authority_leaf(
    ca: &CertificateAuthorityData,
    request: LeafCertRequest,
) -> Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>), BoxError> {
    rcgen::issue_certificate_authority_leaf(ca, request)
}

#[cfg(not(any(feature = "boring", feature = "aws-lc", feature = "ring")))]
pub fn issue_certificate_authority_leaf(
    _ca: &CertificateAuthorityData,
    _request: LeafCertRequest,
) -> Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>), BoxError> {
    Err(BoxError::from_static_str(
        "enable one of the rama-crypto cert providers to issue a leaf certificate",
    ))
}

#[cfg(test)]
mod spki_tests {
    use base64::{Engine as _, prelude::BASE64_STANDARD};

    use super::*;

    const EXAMPLE_COM_CRT_B64: &str = "MIIE3DCCAsSgAwIBAgIJAN4TBpLFs4VhMA0GCSqGSIb3DQEBCwUAMBYxFDASBgNVBAMMC2V4YW1wbGUuY29tMB4XDTI0MTIwOTIwMDUxN1oXDTM0MTIwNzIwMDUxN1owFjEUMBIGA1UEAwwLZXhhbXBsZS5jb20wggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC14A6yHqrF+5+VPljtBd9vgjTQxBCqQ7Af/7cNlFtZjOKmXz0bOCfZRjaxNNjjveztFH+VhRpH/JyM7Qd7R0FX84IyH4Z9a58jgKW/l/YM1Q4Y50WGpM9Sk5p9Q8xTWIoZPrjvh6zV4PKef87LxxqoO9QXv34d5g7dsQLbSwJ93SeggH0E5e1VvP1DW0kvu1BF6rsmF5eTyK/VNg/el9mGyMbcyhBKTpTyVT2FQYRFuZtHXHRnAocCdv887c/TsYVDffTwv7peVoOotO0twKn0SMdtybiNJyDEdcgw2bFbQu7oV/95cBurpxePzED31E64QI8emTvZ62L/c5QvP0OY3x2CSb5ctd6z7wWTJ8wkl7N8+y7Xgn1aAAfki4rWk5qfWAO3BNZo/TGyiWeoNttJ+NddfwI3+h6phK7X56vRhYSqwSnxWyQYlTJAnFQb7TMEP/k9ov2S9MzLTURLLeNiiXjvkOxi+12HzhlTNgk3X49y9f8PLxkNw37TghunAl4OvA+LdslSayFMmZbx9fm+6ZGkjcsDYnf1Mff+aoCkkUcAFg5DQFDkmvu08mJL2D+9I9OK/Yvn/qXWjhVdWLJ/k5hrQmLIs1KbQtlGvvYeC7kHY3yBK+3wt/Cnx9qwhOPJcufuEChiMcVcseGAZJhUT7gQM22v9jb9QZfhihGMpQIDAQABoy0wKzApBgNVHREEIjAgggtleGFtcGxlLmNvbYILZXhhbXBsZS5jb22HBAoAAAEwDQYJKoZIhvcNAQELBQADggIBAJBG9KcH0FG7xn2u4SA4nlwaP/v2ZWZlOwjVjHEQJF7AGaEZFVofzLoRncVnQs14Xr3SGstIBG/P30LC4zHO4Lhz0M+g/lbXhrDjTJLNX7ZNv2ZJj+6XBysJK2IuZX14YCtxhwFCuPBK1cxPDkP4nZm4u5tozLHPtZEHc4kGVQflurkTVmfhJMi5ndAOevXVgfAHRbHfh6x1kNZWDpybiPeeBvZOjRoxecsD7LA54knsSFCQe6zQRlfBUUD+RDI/ggDi3XnKdDHEkLZCH3/db4CcneyzzVkaNcvpOS6ZT6akDLmR8qAglTrADdsnNVzyWzNbBhXQEFoygY3F2rVQndTLoEFGMx7U2d3Fz8sVN/F2SzBYxtrwgj5rQC8tOhHZPVgQLXu6NRRZHEQgypDtGP0H4SUNcGb1Lw27E43KSIT9CpY8Z3SG34G4bYGfpdMN3wtoXG7BtrdmInNWiT+ygh+iJCSaSsAWtaPRnx/9uGLwUNVjzVxJhxGKBbf1hJ5g1x3zMeL73wrsiY6RBa6tWx9SHbRoq8htbkQAnP0tMOavGiTApFquBYDe2gYbuq5jh4yTbNyuxR4WW6m6Bvj7YhUREXQnTDonUwHzw2P29T95z52aPb5PaZYHgg4S26zRV+/Dc8E3oLkjgCyaDuQO4uUpmtT8ssTolIFNr2QUzD12";

    #[test]
    fn spki_sha256_matches_openssl_pin() {
        let der = BASE64_STANDARD.decode(EXAMPLE_COM_CRT_B64).unwrap();
        let digest = spki_sha256(&CertificateDer::from(der)).unwrap();
        assert_eq!(
            BASE64_STANDARD.encode(digest),
            "xg6kqyS+uaJikboVvZPxNOYXMD3XPakJAakHSfGau/M="
        );
    }

    #[test]
    fn spki_sha256_rejects_invalid_der() {
        spki_sha256(&CertificateDer::from(vec![1, 2, 3])).unwrap_err();
    }

    #[cfg(not(any(feature = "boring", feature = "aws-lc", feature = "ring")))]
    #[test]
    fn certificate_authority_key_validation_requires_a_provider() {
        use crate::pki_types::PrivatePkcs8KeyDer;

        let error = CertificateAuthorityData::try_new(
            vec![CertificateDer::from(vec![1])],
            PrivatePkcs8KeyDer::from(vec![1]).into(),
        )
        .expect_err("missing provider must fail before accepting CA data");
        assert_eq!(
            error.to_string(),
            "enable a rama-crypto cert provider to validate a certificate authority key"
        );
    }
}

#[cfg(all(test, any(feature = "boring", feature = "aws-lc", feature = "ring")))]
mod tests {
    use std::assert_matches;
    use x509_parser::prelude::*;

    use super::*;

    #[expect(clippy::expect_used)]
    fn parse_certificate<'a>(der: &'a CertificateDer<'_>) -> X509Certificate<'a> {
        X509Certificate::from_der(der.as_ref())
            .expect("parse certificate DER")
            .1
    }

    #[test]
    fn issued_leaves_never_carry_their_issuers_subject() {
        type Generate =
            fn(
                GeneratedServerAuthConfig,
            )
                -> Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>), BoxError>;
        let generators: &[(&str, Generate)] = &[
            ("default", generate_server_auth),
            #[cfg(any(feature = "aws-lc", feature = "ring"))]
            ("rcgen", rcgen::generate_server_auth),
        ];
        for (name, generate) in generators {
            let (chain, _) = generate(GeneratedServerAuthConfig::generated_ca_for(
                Domain::from_static("leaf.rama.test"),
            ))
            .unwrap();
            let (leaf, ca) = (parse_certificate(&chain[0]), parse_certificate(&chain[1]));
            assert_ne!(leaf.subject(), ca.subject(), "{name}");
            assert_eq!(
                leaf.subject()
                    .iter_common_name()
                    .next()
                    .and_then(|entry| entry.as_str().ok()),
                Some("leaf.rama.test"),
                "{name}"
            );

            let mut named = SelfSignedCaConfig::default();
            named.subject.common_name = Some("Rama Test CA".to_owned());
            let (chain, _) = generate(GeneratedServerAuthConfig::GeneratedCa {
                ca: named,
                leaf: LeafCertRequest::new(Domain::from_static("leaf.rama.test")),
            })
            .unwrap();
            assert_eq!(
                parse_certificate(&chain[0])
                    .subject()
                    .iter_common_name()
                    .count(),
                0,
                "{name}: a distinct issuer leaves the leaf subject as configured"
            );
        }
    }

    #[test]
    fn issued_leaf_usage_controls_eku_and_rsa_key_usage() {
        let ca = CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap();
        let kinds = [
            CertificateKeyKind::EcP256,
            #[cfg(any(feature = "boring", feature = "aws-lc"))]
            CertificateKeyKind::Rsa2048,
        ];
        for key_kind in kinds {
            for usage in [LeafCertUsage::ServerAuth, LeafCertUsage::ClientAuth] {
                let request = LeafCertRequest {
                    config: LeafCertConfig {
                        key_kind,
                        ..Default::default()
                    },
                    ..Default::default()
                };
                let (chain, _) = match usage {
                    LeafCertUsage::ServerAuth => ca.issue_leaf(request),
                    LeafCertUsage::ClientAuth => ca.issue_client_leaf(request),
                }
                .unwrap();
                let leaf = parse_certificate(&chain[0]);
                let eku = leaf.extended_key_usage().unwrap().unwrap().value;
                assert_eq!(eku.server_auth, usage == LeafCertUsage::ServerAuth);
                assert_eq!(eku.client_auth, usage == LeafCertUsage::ClientAuth);
                assert!(!eku.any);
                let key_usage = leaf.key_usage().unwrap().unwrap().value;
                assert!(key_usage.digital_signature());
                assert!(!key_usage.key_cert_sign());
                assert_eq!(
                    key_usage.key_encipherment(),
                    usage == LeafCertUsage::ServerAuth && key_kind == CertificateKeyKind::Rsa2048
                );
                assert!(!leaf.basic_constraints().unwrap().unwrap().value.ca);
                assert!(leaf.subject_alternative_name().unwrap().is_some());
                assert_eq!(leaf.issuer(), parse_certificate(&chain[1]).subject());
            }
        }
    }

    #[test]
    fn client_leaf_can_use_subject_without_san() {
        let ca = CertificateAuthorityData::generate(SelfSignedCaConfig::default()).unwrap();
        let mut request = LeafCertRequest {
            config: LeafCertConfig {
                subject: CertificateSubject {
                    common_name: Some("device-42".to_owned()),
                    ..Default::default()
                },
                ..Default::default()
            },
            identities: vec![],
        };
        let (chain, _) = ca.issue_client_leaf(request.clone()).unwrap();
        let leaf = parse_certificate(&chain[0]);
        assert!(leaf.subject_alternative_name().unwrap().is_none());
        assert_eq!(
            leaf.subject()
                .iter_common_name()
                .next()
                .unwrap()
                .as_str()
                .unwrap(),
            "device-42"
        );
        assert!(
            leaf.extended_key_usage()
                .unwrap()
                .unwrap()
                .value
                .client_auth
        );
        assert!(
            ca.issue_leaf(request.clone())
                .unwrap_err()
                .to_string()
                .contains("at least one DNS or IP identity")
        );
        for name in [None, Some(String::new())] {
            request.config.subject.common_name = name;
            assert!(
                ca.issue_client_leaf(request.clone())
                    .unwrap_err()
                    .to_string()
                    .contains("nonempty subject")
            );
        }
    }

    #[test]
    fn server_auth_entry_points_always_issue_server_eku() {
        let request = LeafCertRequest::default();
        for config in [
            GeneratedServerAuthConfig::SelfSignedLeaf(request.clone()),
            GeneratedServerAuthConfig::GeneratedCa {
                ca: SelfSignedCaConfig::default(),
                leaf: request,
            },
        ] {
            let (chain, _) = generate_server_auth(config).unwrap();
            let leaf = parse_certificate(&chain[0]);
            let eku = leaf.extended_key_usage().unwrap().unwrap().value;
            assert!(eku.server_auth);
            assert!(!eku.client_auth);
        }
    }

    #[test]
    fn genuine_self_signed_leaf_has_no_ca_certificate() {
        let (chain, _key) = generate_server_auth(GeneratedServerAuthConfig::SelfSignedLeaf(
            LeafCertRequest::new(Domain::from_static("self-signed.rama.test")),
        ))
        .expect("generate self-signed leaf");
        assert_eq!(chain.len(), 1);
        let leaf = parse_certificate(&chain[0]);
        assert_eq!(leaf.subject(), leaf.issuer());
        assert!(leaf.issuer().iter().next().is_some());
        assert_eq!(leaf.subject().iter_common_name().count(), 0);
        assert_eq!(
            leaf.subject()
                .iter_organization()
                .next()
                .and_then(|entry| entry.as_str().ok()),
            Some("Anonymous")
        );
        assert!(
            !leaf
                .basic_constraints()
                .expect("basic constraints")
                .is_some_and(|extension| extension.value.ca)
        );
    }

    #[test]
    fn ca_issued_leaf_has_end_entity_and_key_identifier_extensions() {
        let (chain, _key) = generate_server_auth(GeneratedServerAuthConfig::default())
            .expect("generate CA-issued leaf");
        let leaf = parse_certificate(&chain[0]);
        let basic_constraints = leaf
            .basic_constraints()
            .expect("parse basic constraints")
            .expect("basic constraints present");
        assert!(!basic_constraints.value.ca);
        assert!(leaf.extensions().iter().any(|extension| {
            matches!(
                extension.parsed_extension(),
                ParsedExtension::SubjectKeyIdentifier(_)
            )
        }));
        assert!(leaf.extensions().iter().any(|extension| {
            matches!(
                extension.parsed_extension(),
                ParsedExtension::AuthorityKeyIdentifier(authority)
                    if authority.key_identifier.is_some()
            )
        }));
    }

    #[test]
    fn self_signed_leaf_rejects_subsecond_lifetime() {
        let error =
            generate_server_auth(GeneratedServerAuthConfig::SelfSignedLeaf(LeafCertRequest {
                config: LeafCertConfig {
                    validity: CertificateValidity::new(Duration::from_millis(999), Duration::ZERO),
                    ..Default::default()
                },
                ..Default::default()
            }))
            .expect_err("subsecond leaf lifetime must fail");
        assert!(
            error
                .to_string()
                .contains("certificate lifetime must be at least one second")
        );
    }

    #[test]
    fn self_signed_leaf_accepts_one_second_lifetime() {
        generate_server_auth(GeneratedServerAuthConfig::SelfSignedLeaf(LeafCertRequest {
            config: LeafCertConfig {
                validity: CertificateValidity::new(Duration::from_secs(1), Duration::ZERO),
                ..Default::default()
            },
            ..Default::default()
        }))
        .expect("one-second leaf lifetime must be accepted");
    }

    #[test]
    fn certificate_authority_rejects_subsecond_lifetime() {
        let error = CertificateAuthorityData::generate(SelfSignedCaConfig {
            validity: CertificateValidity::new(Duration::from_millis(999), Duration::ZERO),
            ..Default::default()
        })
        .expect_err("subsecond CA lifetime must fail");
        assert!(
            error
                .to_string()
                .contains("certificate lifetime must be at least one second")
        );
    }

    #[test]
    fn certificate_authority_rejects_subsecond_leaf_lifetime() {
        let ca =
            CertificateAuthorityData::generate(SelfSignedCaConfig::default()).expect("generate CA");
        let error = ca
            .issue_leaf(LeafCertRequest {
                config: LeafCertConfig {
                    validity: CertificateValidity::new(Duration::from_millis(999), Duration::ZERO),
                    ..Default::default()
                },
                ..Default::default()
            })
            .expect_err("subsecond issued leaf lifetime must fail");
        assert!(
            error
                .to_string()
                .contains("certificate lifetime must be at least one second")
        );
    }

    #[test]
    fn certificate_authority_rejects_out_of_range_lifetime() {
        let result = CertificateAuthorityData::generate(SelfSignedCaConfig {
            validity: CertificateValidity::new(
                Duration::from_hours(8_000 * 365 * 24),
                Duration::ZERO,
            ),
            ..Default::default()
        });
        assert!(result.is_err(), "out-of-range CA lifetime must fail");
    }

    #[test]
    fn certificate_authority_clamps_out_of_range_skew_to_epoch() {
        for skew in [
            Duration::from_hours(100 * 365 * 24),
            Duration::from_hours(3_000 * 365 * 24),
            Duration::from_hours(20_000 * 365 * 24),
            Duration::MAX,
        ] {
            let ca = CertificateAuthorityData::generate(SelfSignedCaConfig {
                validity: CertificateValidity::new(Duration::from_hours(24), skew),
                ..Default::default()
            })
            .expect("out-of-range skew must clamp to the Unix epoch");
            let issuer = parse_certificate(&ca.certificate_chain[0]);
            assert_eq!(issuer.validity().not_before.timestamp(), 0);
        }
    }

    #[test]
    fn generated_ca_for_sets_only_the_requested_identity() {
        let identity = CertificateIdentity::Ip(std::net::Ipv6Addr::LOCALHOST.into());
        let config = GeneratedServerAuthConfig::generated_ca_for(identity.clone());
        assert_matches!(
            config,
            GeneratedServerAuthConfig::GeneratedCa {
                leaf: LeafCertRequest { identities, .. },
                ..
            } if identities == [identity],
        );
    }

    #[test]
    fn explicit_common_names_do_not_add_anonymous_organisations() {
        let (chain, _key) = generate_server_auth(GeneratedServerAuthConfig::GeneratedCa {
            ca: SelfSignedCaConfig {
                subject: CertificateSubject {
                    common_name: Some("Named CA".to_owned()),
                    ..Default::default()
                },
                ..Default::default()
            },
            leaf: LeafCertRequest {
                config: LeafCertConfig {
                    subject: CertificateSubject {
                        common_name: Some("Named leaf".to_owned()),
                        ..Default::default()
                    },
                    ..Default::default()
                },
                ..Default::default()
            },
        })
        .expect("generate named chain");

        for certificate in &chain {
            let certificate = parse_certificate(certificate);
            let subject = certificate.subject();
            assert_eq!(subject.iter_organization().count(), 0);
        }
    }

    #[test]
    fn self_signed_leaf_common_name_does_not_add_anonymous_organisation() {
        let (chain, _key) =
            generate_server_auth(GeneratedServerAuthConfig::SelfSignedLeaf(LeafCertRequest {
                config: LeafCertConfig {
                    subject: CertificateSubject {
                        common_name: Some("Named self-signed leaf".to_owned()),
                        ..Default::default()
                    },
                    ..Default::default()
                },
                ..Default::default()
            }))
            .expect("generate named self-signed leaf");
        let leaf = parse_certificate(&chain[0]);
        assert_eq!(leaf.subject().iter_organization().count(), 0);
    }

    #[test]
    fn issued_leaf_validity_is_clamped_to_issuing_ca() {
        let ca = CertificateAuthorityData::generate(SelfSignedCaConfig {
            validity: CertificateValidity::new(Duration::from_hours(2), Duration::from_mins(1)),
            ..Default::default()
        })
        .expect("generate short-lived CA");
        let (chain, _key) = ca
            .issue_leaf(LeafCertRequest {
                config: LeafCertConfig {
                    validity: CertificateValidity::new(
                        Duration::from_hours(4),
                        Duration::from_mins(2),
                    ),
                    ..Default::default()
                },
                ..Default::default()
            })
            .expect("issue validity-clamped leaf");
        let leaf = parse_certificate(&chain[0]);
        let issuer = parse_certificate(&chain[1]);
        assert_eq!(leaf.validity().not_before, issuer.validity().not_before);
        assert_eq!(leaf.validity().not_after, issuer.validity().not_after);
    }

    #[cfg(feature = "boring")]
    #[test]
    fn boring_rsa_leaf_permits_key_encipherment() {
        let (chain, _key) =
            generate_server_auth(GeneratedServerAuthConfig::SelfSignedLeaf(LeafCertRequest {
                config: LeafCertConfig {
                    key_kind: CertificateKeyKind::Rsa2048,
                    ..Default::default()
                },
                ..Default::default()
            }))
            .expect("generate RSA leaf");
        let leaf = parse_certificate(&chain[0]);
        let usage = leaf
            .key_usage()
            .expect("parse key usage")
            .expect("key usage present");
        assert!(usage.value.digital_signature());
        assert!(usage.value.key_encipherment());
    }

    #[test]
    fn existing_ca_issues_configured_ip_leaf_in_one_call() {
        let mut ca_validity = SelfSignedCaConfig::default().validity;
        ca_validity.not_before_skew = Duration::from_mins(2);
        let ca = CertificateAuthorityData::generate(SelfSignedCaConfig {
            subject: CertificateSubject {
                organisation_name: Some("Rama Issuer".to_owned()),
                common_name: Some("Rama test CA".to_owned()),
            },
            validity: ca_validity,
            ..Default::default()
        })
        .expect("generate CA");
        let lifetime = Duration::from_hours(365 * 24);
        let (chain, _key) = ca
            .issue_leaf(LeafCertRequest {
                config: LeafCertConfig {
                    subject: CertificateSubject {
                        common_name: Some("descriptive leaf label".to_owned()),
                        ..Default::default()
                    },
                    validity: CertificateValidity::new(lifetime, Duration::from_mins(2)),
                    key_kind: CertificateKeyKind::EcP384,
                },
                identities: vec![CertificateIdentity::Ip(
                    std::net::Ipv4Addr::LOCALHOST.into(),
                )],
            })
            .expect("issue leaf");

        assert_eq!(chain.len(), ca.certificate_chain.len() + 1);
        let leaf = parse_certificate(&chain[0]);
        let issuer = parse_certificate(&chain[1]);
        assert_eq!(leaf.issuer(), issuer.subject());
        assert_eq!(
            leaf.validity().not_after.timestamp() - leaf.validity().not_before.timestamp(),
            i64::try_from(lifetime.as_secs()).unwrap()
        );
        assert_eq!(
            leaf.subject()
                .iter_organization()
                .next()
                .and_then(|entry| entry.as_str().ok()),
            Some("Rama Issuer")
        );
        let san = leaf
            .subject_alternative_name()
            .expect("parse SAN")
            .expect("SAN present");
        assert!(san.value.general_names.iter().any(|name| {
            matches!(name, GeneralName::IPAddress(bytes) if *bytes == [127, 0, 0, 1])
        }));
    }

    #[test]
    fn certificate_authority_rejects_mismatched_private_key() {
        let first = CertificateAuthorityData::generate(SelfSignedCaConfig::default())
            .expect("generate first CA");
        let second = CertificateAuthorityData::generate(SelfSignedCaConfig::default())
            .expect("generate second CA");
        CertificateAuthorityData::try_new(first.certificate_chain, second.private_key)
            .expect_err("mismatched key must fail");
    }

    #[test]
    fn certificate_authority_rejects_same_name_unrelated_parent() {
        let config = SelfSignedCaConfig {
            subject: CertificateSubject {
                organisation_name: Some("Same Name Issuer".to_owned()),
                common_name: None,
            },
            ..Default::default()
        };
        let child = CertificateAuthorityData::generate(config.clone()).expect("generate child CA");
        let unrelated_parent =
            CertificateAuthorityData::generate(config).expect("generate unrelated parent CA");
        let (mut chain, key) = child.into_parts();
        chain.push(unrelated_parent.certificate_chain()[0].clone());

        CertificateAuthorityData::try_new(chain, key)
            .expect_err("same-name parent with the wrong key must fail");
    }

    #[test]
    fn certificate_authority_rejects_non_ca_parent() {
        let subject = CertificateSubject {
            organisation_name: Some("Same Name Issuer".to_owned()),
            common_name: None,
        };
        let child = CertificateAuthorityData::generate(SelfSignedCaConfig {
            subject: subject.clone(),
            ..Default::default()
        })
        .expect("generate child CA");
        let (parent_chain, _parent_key) =
            generate_server_auth(GeneratedServerAuthConfig::SelfSignedLeaf(LeafCertRequest {
                config: LeafCertConfig {
                    subject,
                    ..Default::default()
                },
                ..Default::default()
            }))
            .expect("generate non-CA parent");
        let (mut chain, key) = child.into_parts();
        chain.push(parent_chain[0].clone());

        CertificateAuthorityData::try_new(chain, key).expect_err("non-CA parent must fail");
    }

    #[cfg(feature = "boring")]
    #[test]
    fn certificate_authority_accepts_valid_intermediate_chain() {
        use crate::pki_types::PrivatePkcs8KeyDer;

        let (root_cert, root_key) =
            boring::generate_certificate_authority_x509(&SelfSignedCaConfig {
                subject: CertificateSubject {
                    common_name: Some("Rama Root CA".to_owned()),
                    ..Default::default()
                },
                ..Default::default()
            })
            .expect("generate root CA");
        let (intermediate_template, _) =
            boring::generate_certificate_authority_x509(&SelfSignedCaConfig {
                subject: CertificateSubject {
                    common_name: Some("Rama Intermediate CA".to_owned()),
                    ..Default::default()
                },
                ..Default::default()
            })
            .expect("generate intermediate CA template");
        let (intermediate_cert, intermediate_key) = boring::self_signed_server_auth_mirror_cert(
            intermediate_template.as_ref(),
            &root_cert,
            &root_key,
        )
        .expect("sign intermediate CA");

        let chain = vec![
            CertificateDer::from(
                intermediate_cert
                    .to_der()
                    .expect("serialize intermediate CA"),
            ),
            CertificateDer::from(root_cert.to_der().expect("serialize root CA")),
        ];
        let key = PrivatePkcs8KeyDer::from(
            intermediate_key
                .private_key_to_der_pkcs8()
                .expect("serialize intermediate CA key"),
        )
        .into();
        let ca = CertificateAuthorityData::try_new(chain, key).expect("accept valid CA chain");
        assert_eq!(ca.certificate_chain().len(), 2);
    }

    #[cfg(all(not(feature = "boring"), any(feature = "aws-lc", feature = "ring")))]
    #[test]
    fn rcgen_certificate_authority_accepts_valid_intermediate_chain() {
        use crate::pki_types::PrivatePkcs8KeyDer;

        fn ca_params(common_name: &str) -> ::rcgen::CertificateParams {
            let mut params = ::rcgen::CertificateParams::new(Vec::new()).expect("CA parameters");
            params.distinguished_name = ::rcgen::DistinguishedName::new();
            params
                .distinguished_name
                .push(::rcgen::DnType::CommonName, common_name);
            params.is_ca = ::rcgen::IsCa::Ca(::rcgen::BasicConstraints::Unconstrained);
            params.key_usages = vec![
                ::rcgen::KeyUsagePurpose::KeyCertSign,
                ::rcgen::KeyUsagePurpose::CrlSign,
            ];
            params
        }

        let root_params = ca_params("Rama rcgen Root CA");
        let root_key = ::rcgen::KeyPair::generate().expect("generate root key");
        let root_cert = root_params
            .self_signed(&root_key)
            .expect("generate root certificate");
        let root_issuer = ::rcgen::Issuer::new(root_params, root_key);

        let intermediate_params = ca_params("Rama rcgen Intermediate CA");
        let intermediate_key = ::rcgen::KeyPair::generate().expect("generate intermediate key");
        let intermediate_cert = intermediate_params
            .signed_by(&intermediate_key, &root_issuer)
            .expect("generate intermediate certificate");
        let intermediate_key_der = intermediate_key.serialize_der();

        let ca = CertificateAuthorityData::try_new(
            vec![intermediate_cert.into(), root_cert.into()],
            PrivatePkcs8KeyDer::from(intermediate_key_der).into(),
        )
        .expect("accept valid rcgen CA chain");
        assert_eq!(ca.certificate_chain().len(), 2);
    }

    #[test]
    fn generated_leaf_san_covers_dns_names_and_ip_addresses() {
        let leaf = LeafCertRequest {
            config: LeafCertConfig {
                subject: CertificateSubject {
                    common_name: Some("display label, not an identity".to_owned()),
                    ..Default::default()
                },
                ..Default::default()
            },
            identities: vec![
                CertificateIdentity::Dns(Domain::from_static("primary.rama.test")),
                CertificateIdentity::Dns(Domain::from_static("alt-one.rama.test")),
                CertificateIdentity::Dns(Domain::from_static("alt-two.rama.test")),
                CertificateIdentity::Ip(std::net::Ipv4Addr::LOCALHOST.into()),
                CertificateIdentity::Ip(std::net::Ipv4Addr::new(127, 0, 0, 2).into()),
                CertificateIdentity::Ip(std::net::Ipv6Addr::LOCALHOST.into()),
            ],
        };
        let (chain, _key) = generate_server_auth(GeneratedServerAuthConfig::GeneratedCa {
            ca: SelfSignedCaConfig::default(),
            leaf,
        })
        .expect("generate server auth");

        let (_, cert) =
            X509Certificate::from_der(chain[0].as_ref()).expect("parse leaf certificate DER");
        let common_names = cert
            .subject()
            .iter_common_name()
            .filter_map(|entry| entry.as_str().ok())
            .collect::<Vec<_>>();
        assert_eq!(common_names, ["display label, not an identity"]);
        let mut dns = Vec::new();
        let mut ips = Vec::new();
        for ext in cert.extensions() {
            if let ParsedExtension::SubjectAlternativeName(san) = ext.parsed_extension() {
                for gn in &san.general_names {
                    match gn {
                        GeneralName::DNSName(name) => dns.push((*name).to_owned()),
                        GeneralName::IPAddress(ip) => ips.push(ip.to_vec()),
                        _ => {}
                    }
                }
            }
        }

        for expected in [
            "primary.rama.test",
            "alt-one.rama.test",
            "alt-two.rama.test",
        ] {
            assert!(
                dns.iter().any(|n| n == expected),
                "leaf SAN must contain {expected}; got {dns:?}"
            );
        }
        assert!(
            !dns.iter()
                .any(|name| name == "display label, not an identity"),
            "commonName must not be copied into SAN"
        );
        assert!(
            ips.contains(&vec![127, 0, 0, 1]),
            "missing IPv4 SAN: {ips:?}"
        );
        assert!(
            ips.contains(&vec![127, 0, 0, 2]),
            "numeric domain must be an IPv4 SAN: {ips:?}"
        );
        assert!(
            ips.contains(&std::net::Ipv6Addr::LOCALHOST.octets().to_vec()),
            "missing IPv6 SAN: {ips:?}"
        );
    }
}
