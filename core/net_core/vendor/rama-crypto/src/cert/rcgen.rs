//! rcgen-backed certificate generation (feature `aws-lc` / `ring`).

use std::time::SystemTime;

use super::{
    CertificateAuthorityData, CertificateIdentity, CertificateKeyKind, CertificateSubject,
    CertificateValidity, GeneratedServerAuthConfig, LeafCertRequest, LeafCertUsage,
    SelfSignedCaConfig, validate_certificate_lifetime, validate_leaf_request,
};
use crate::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rama_core::error::{BoxError, BoxErrorExt as _, ErrorContext};
use rcgen::PublicKeyData as _;
use time::{OffsetDateTime, SignedDuration};

pub(super) fn validate_certificate_authority_key(
    certificate: &CertificateDer<'_>,
    private_key: &PrivateKeyDer<'_>,
) -> Result<(), BoxError> {
    let key = rcgen::KeyPair::try_from(private_key).context("parse CA private key")?;
    let (_, certificate) = x509_parser::parse_x509_certificate(certificate.as_ref())
        .context("parse CA certificate")?;
    if key.subject_public_key_info() != certificate.public_key().raw {
        return Err(BoxError::from_static_str(
            "certificate authority private key does not match its certificate",
        ));
    }
    Ok(())
}

#[cfg(not(feature = "boring"))]
pub(super) fn validate_certificate_authority_chain(
    certificate_chain: &[CertificateDer<'_>],
) -> Result<(), BoxError> {
    for pair in certificate_chain.windows(2) {
        let (_, child) = x509_parser::parse_x509_certificate(pair[0].as_ref())
            .context("parse child CA certificate")?;
        let (_, parent) = x509_parser::parse_x509_certificate(pair[1].as_ref())
            .context("parse parent CA certificate")?;
        child
            .verify_signature(Some(parent.public_key()))
            .context("verify child CA certificate signature")?;
    }
    Ok(())
}

fn signature_algorithm(
    kind: CertificateKeyKind,
) -> Result<&'static rcgen::SignatureAlgorithm, BoxError> {
    match kind {
        CertificateKeyKind::EcP256 => Ok(&rcgen::PKCS_ECDSA_P256_SHA256),
        CertificateKeyKind::EcP384 => Ok(&rcgen::PKCS_ECDSA_P384_SHA384),
        #[cfg(feature = "aws-lc")]
        CertificateKeyKind::EcP521 => Ok(&rcgen::PKCS_ECDSA_P521_SHA512),
        #[cfg(not(feature = "aws-lc"))]
        CertificateKeyKind::EcP521 => Err(BoxError::from_static_str(
            "EC P-521 key generation requires the aws-lc certificate provider",
        )),
        CertificateKeyKind::Ed25519 => Ok(&rcgen::PKCS_ED25519),
        CertificateKeyKind::Rsa2048 | CertificateKeyKind::Rsa4096 => Ok(&rcgen::PKCS_RSA_SHA256),
    }
}

fn generate_key(kind: CertificateKeyKind) -> Result<rcgen::KeyPair, BoxError> {
    #[cfg(feature = "aws-lc")]
    match kind {
        CertificateKeyKind::Rsa2048 => {
            return rcgen::KeyPair::generate_rsa_for(
                &rcgen::PKCS_RSA_SHA256,
                rcgen::RsaKeySize::_2048,
            )
            .context("generate RSA-2048 key pair");
        }
        CertificateKeyKind::Rsa4096 => {
            return rcgen::KeyPair::generate_rsa_for(
                &rcgen::PKCS_RSA_SHA256,
                rcgen::RsaKeySize::_4096,
            )
            .context("generate RSA-4096 key pair");
        }
        _ => {}
    }
    #[cfg(not(feature = "aws-lc"))]
    if matches!(
        kind,
        CertificateKeyKind::Rsa2048 | CertificateKeyKind::Rsa4096
    ) {
        return Err(BoxError::from_static_str(
            "RSA key generation requires the aws-lc or boring certificate provider",
        ));
    }
    rcgen::KeyPair::generate_for(signature_algorithm(kind)?)
        .context("generate certificate key pair")
}

fn duration(value: std::time::Duration) -> Result<SignedDuration, BoxError> {
    let seconds =
        i64::try_from(value.as_secs()).context("certificate duration exceeds i64 seconds")?;
    Ok(SignedDuration::seconds(seconds)
        + SignedDuration::nanoseconds(i64::from(value.subsec_nanos())))
}

fn validity_bounds(
    validity: CertificateValidity,
    now: SystemTime,
) -> Result<(OffsetDateTime, OffsetDateTime), BoxError> {
    validate_certificate_lifetime(validity.lifetime)?;
    let now = crate::asn1::datetime(now).context("read system time for certificate validity")?;
    let lifetime = duration(validity.lifetime)?;
    // Match BoringSSL: backdating before the Unix epoch clamps to the epoch.
    let not_before = duration(validity.not_before_skew)
        .ok()
        .and_then(|skew| now.checked_sub(skew))
        .map_or(OffsetDateTime::UNIX_EPOCH, |t| {
            t.max(OffsetDateTime::UNIX_EPOCH)
        });
    let not_after = not_before
        .checked_add(lifetime)
        .ok_or_else(|| BoxError::from_static_str("certificate validity exceeds timestamp range"))?;
    // rcgen panics encoding years past 9999, which `time/large-dates` allows.
    if not_after.year() > 9999 {
        return Err(BoxError::from_static_str(
            "certificate validity past ASN.1 year 9999",
        ));
    }
    Ok((not_before, not_after))
}

fn apply_subject(params: &mut rcgen::CertificateParams, subject: &CertificateSubject) {
    if let Some(value) = subject.organisation_name.as_ref() {
        params
            .distinguished_name
            .push(rcgen::DnType::OrganizationName, value.clone());
    }
    if let Some(value) = subject.common_name.as_ref() {
        params
            .distinguished_name
            .push(rcgen::DnType::CommonName, value.clone());
    }
}

fn leaf_params(
    request: &LeafCertRequest,
    usage: LeafCertUsage,
) -> Result<rcgen::CertificateParams, BoxError> {
    validate_leaf_request(request, usage)?;

    let mut params = rcgen::CertificateParams::new(Vec::new())
        .context("certificate leaf: create certificate parameters")?;
    params.distinguished_name = rcgen::DistinguishedName::new();
    for identity in &request.identities {
        let san = match identity {
            CertificateIdentity::Dns(domain) => rcgen::SanType::DnsName(
                domain
                    .as_str()
                    .try_into()
                    .context("certificate leaf: encode DNS SAN")?,
            ),
            CertificateIdentity::Ip(ip) => rcgen::SanType::IpAddress(*ip),
        };
        if !params.subject_alt_names.contains(&san) {
            params.subject_alt_names.push(san);
        }
    }
    apply_subject(&mut params, &request.config.subject);
    params.is_ca = rcgen::IsCa::ExplicitNoCa;
    params.key_usages = vec![rcgen::KeyUsagePurpose::DigitalSignature];
    if usage == LeafCertUsage::ServerAuth
        && matches!(
            request.config.key_kind,
            CertificateKeyKind::Rsa2048 | CertificateKeyKind::Rsa4096
        )
    {
        params
            .key_usages
            .push(rcgen::KeyUsagePurpose::KeyEncipherment);
    }
    params.extended_key_usages = vec![match usage {
        LeafCertUsage::ServerAuth => rcgen::ExtendedKeyUsagePurpose::ServerAuth,
        LeafCertUsage::ClientAuth => rcgen::ExtendedKeyUsagePurpose::ClientAuth,
    }];
    let (not_before, not_after) = validity_bounds(request.config.validity, SystemTime::now())?;
    params.not_before = not_before;
    params.not_after = not_after;
    Ok(params)
}

fn ca_params(config: &SelfSignedCaConfig) -> Result<rcgen::CertificateParams, BoxError> {
    let mut params = rcgen::CertificateParams::new(Vec::new())
        .context("certificate authority: create certificate parameters")?;
    params.distinguished_name = rcgen::DistinguishedName::new();
    apply_subject(&mut params, &config.subject);
    if config.subject.organisation_name.is_none() && config.subject.common_name.is_none() {
        params
            .distinguished_name
            .push(rcgen::DnType::OrganizationName, "Anonymous");
    }
    params.is_ca = rcgen::IsCa::Ca(rcgen::BasicConstraints::Unconstrained);
    params.key_usages = vec![
        rcgen::KeyUsagePurpose::KeyCertSign,
        rcgen::KeyUsagePurpose::CrlSign,
    ];
    let (not_before, not_after) = validity_bounds(config.validity, SystemTime::now())?;
    params.not_before = not_before;
    params.not_after = not_after;
    Ok(params)
}

fn inherit_ca_organisation(ca: &CertificateDer<'_>, request: &mut LeafCertRequest) {
    let Ok((_, cert)) = x509_parser::parse_x509_certificate(ca.as_ref()) else {
        return;
    };
    let issuer_organisation = cert
        .subject()
        .iter_organization()
        .find_map(|entry| entry.as_str().ok().map(ToOwned::to_owned));
    if request.config.subject.organisation_name.is_none() {
        request
            .config
            .subject
            .organisation_name
            .clone_from(&issuer_organisation);
    }
    let issuer_has_common_name = cert.subject().iter_common_name().next().is_some();
    super::keep_leaf_subject_apart_from_issuer(
        request,
        issuer_organisation.as_deref(),
        issuer_has_common_name,
    );
}

fn constrain_validity_to_ca(
    ca: &CertificateDer<'_>,
    params: &mut rcgen::CertificateParams,
) -> Result<(), BoxError> {
    let (_, cert) = x509_parser::parse_x509_certificate(ca.as_ref())
        .context("certificate authority: parse validity")?;
    let ca_not_before = OffsetDateTime::from_unix_timestamp(cert.validity().not_before.timestamp())
        .context("certificate authority: parse notBefore")?;
    let ca_not_after = OffsetDateTime::from_unix_timestamp(cert.validity().not_after.timestamp())
        .context("certificate authority: parse notAfter")?;
    params.not_before = params.not_before.max(ca_not_before);
    params.not_after = params.not_after.min(ca_not_after);
    if params.not_before >= params.not_after {
        return Err(BoxError::from_static_str(
            "certificate authority validity cannot contain requested leaf validity",
        ));
    }
    Ok(())
}

pub fn generate_server_auth(
    config: GeneratedServerAuthConfig,
) -> Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>), BoxError> {
    match config {
        GeneratedServerAuthConfig::SelfSignedLeaf(mut request) => {
            if request.config.subject.organisation_name.is_none()
                && request.config.subject.common_name.is_none()
            {
                request.config.subject.organisation_name = Some("Anonymous".to_owned());
            }
            let key = generate_key(request.config.key_kind)
                .context("self-signed leaf: generate key pair")?;
            let cert = leaf_params(&request, LeafCertUsage::ServerAuth)?
                .self_signed(&key)
                .context("self-signed leaf: generate certificate")?;
            Ok((
                vec![cert.into()],
                PrivatePkcs8KeyDer::from(key.serialize_der()).into(),
            ))
        }
        GeneratedServerAuthConfig::GeneratedCa { ca, leaf } => {
            let ca = generate_certificate_authority(ca)?;
            issue_certificate_authority_leaf(&ca, leaf)
        }
    }
}

#[expect(clippy::needless_pass_by_value)]
pub fn generate_certificate_authority(
    config: SelfSignedCaConfig,
) -> Result<CertificateAuthorityData, BoxError> {
    let key = generate_key(config.key_kind).context("certificate authority: generate key pair")?;
    let cert = ca_params(&config)?
        .self_signed(&key)
        .context("certificate authority: generate self-signed certificate")?;
    CertificateAuthorityData::try_new(
        vec![cert.into()],
        PrivatePkcs8KeyDer::from(key.serialize_der()).into(),
    )
}

pub fn issue_certificate_authority_leaf(
    ca: &CertificateAuthorityData,
    request: LeafCertRequest,
) -> Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>), BoxError> {
    issue_certificate_authority_leaf_with_usage(ca, request, LeafCertUsage::ServerAuth)
}

pub(super) fn issue_certificate_authority_leaf_with_usage(
    ca: &CertificateAuthorityData,
    mut request: LeafCertRequest,
    usage: LeafCertUsage,
) -> Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>), BoxError> {
    validate_leaf_request(&request, usage)?;
    let issuer_cert = ca
        .certificate_chain
        .first()
        .ok_or_else(|| BoxError::from_static_str("certificate authority chain cannot be empty"))?;
    inherit_ca_organisation(issuer_cert, &mut request);
    validate_certificate_authority_key(issuer_cert, &ca.private_key)?;

    let issuer_key = rcgen::KeyPair::try_from(&ca.private_key)
        .context("certificate authority: parse issuer private key")?;
    let issuer = rcgen::Issuer::from_ca_cert_der(issuer_cert, issuer_key)
        .context("certificate authority: parse issuer certificate")?;
    let leaf_key =
        generate_key(request.config.key_kind).context("certificate leaf: generate key pair")?;
    let mut params = leaf_params(&request, usage)?;
    constrain_validity_to_ca(issuer_cert, &mut params)?;
    params.use_authority_key_identifier_extension = true;
    let leaf = params
        .signed_by(&leaf_key, &issuer)
        .context("certificate leaf: sign with certificate authority")?;

    let mut chain = Vec::with_capacity(ca.certificate_chain.len() + 1);
    chain.push(leaf.into());
    chain.extend(ca.certificate_chain.iter().cloned());
    Ok((
        chain,
        PrivatePkcs8KeyDer::from(leaf_key.serialize_der()).into(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn duration_converts_seconds_and_nanoseconds() {
        assert_eq!(
            duration(std::time::Duration::from_millis(1_500)).unwrap(),
            SignedDuration::milliseconds(1_500)
        );
        assert_eq!(
            duration(std::time::Duration::from_nanos(1)).unwrap(),
            SignedDuration::nanoseconds(1)
        );
    }

    fn at(secs: u64) -> SystemTime {
        SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(secs)
    }

    #[test]
    fn validity_bounds_backdate_the_start() {
        let (not_before, not_after) = validity_bounds(
            CertificateValidity::new(
                std::time::Duration::from_millis(1_500),
                std::time::Duration::from_secs(2),
            ),
            at(1_800_000_000),
        )
        .unwrap();

        assert_eq!(
            not_before,
            OffsetDateTime::from_unix_timestamp(1_799_999_998).unwrap()
        );
        assert_eq!(not_after - not_before, SignedDuration::milliseconds(1_500));
    }

    #[test]
    fn validity_bounds_reject_years_past_9999() {
        validity_bounds(
            CertificateValidity::new(
                std::time::Duration::from_hours(8_000 * 365 * 24),
                std::time::Duration::ZERO,
            ),
            at(1_800_000_000),
        )
        .unwrap_err();
    }

    #[test]
    fn validity_bounds_reject_an_unrepresentable_clock() {
        let validity = CertificateValidity::new(
            std::time::Duration::from_hours(24),
            std::time::Duration::ZERO,
        );
        validity_bounds(validity, at(253_402_300_800)).unwrap_err();
        validity_bounds(
            validity,
            SystemTime::UNIX_EPOCH - std::time::Duration::from_secs(1),
        )
        .unwrap_err();
    }
}
