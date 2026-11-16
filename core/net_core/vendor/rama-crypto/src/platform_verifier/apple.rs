//! Verification through the Security framework's `SecTrust`.

use std::time::{SystemTime, UNIX_EPOCH};

use core_foundation::date::CFDate;
use rama_core::error::BoxError;
use security_framework::{
    certificate::SecCertificate, policy::SecPolicy, secure_transport::SslProtocolSide,
    trust::SecTrust,
};

use super::{PlatformVerifyError, PlatformVerifyErrorKind};
use crate::pki_types::CertificateDer;

// OSStatus codes reported by `SecTrustEvaluateWithError`.
const ERR_SEC_CREATE_CHAIN_FAILED: isize = -25318;
const ERR_SEC_HOST_NAME_MISMATCH: isize = -67602;
const ERR_SEC_INVALID_EXTENDED_KEY_USAGE: isize = -67609;
const ERR_SEC_CERTIFICATE_EXPIRED: isize = -67818;
const ERR_SEC_CERTIFICATE_NOT_VALID_YET: isize = -67819;
const ERR_SEC_CERTIFICATE_REVOKED: isize = -67820;
const ERR_SEC_NOT_TRUSTED: isize = -67843;

/// `kCFAbsoluteTimeIntervalSince1970`: seconds between the Unix and the
/// CoreFoundation (2001-01-01) epochs.
const CF_EPOCH_SINCE_UNIX_SECS: f64 = 978_307_200.0;

pub(super) struct Verifier {
    extra_roots: Vec<SecCertificate>,
}

impl Verifier {
    pub(super) fn new() -> Self {
        Self {
            extra_roots: Vec::new(),
        }
    }

    pub(super) fn try_with_extra_roots(
        roots: &[CertificateDer<'static>],
    ) -> Result<Self, BoxError> {
        let extra_roots = roots
            .iter()
            .map(|root| {
                SecCertificate::from_der(root).map_err(|err| {
                    PlatformVerifyError::with_source(PlatformVerifyErrorKind::BadEncoding, err)
                })
            })
            .collect::<Result<_, _>>()?;
        Ok(Self { extra_roots })
    }

    pub(super) fn verify_server_chain(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        server_name: &str,
        ocsp_response: Option<&[u8]>,
        now: SystemTime,
    ) -> Result<Vec<CertificateDer<'static>>, PlatformVerifyError> {
        let certificates = std::iter::once(end_entity)
            .chain(intermediates)
            .map(|certificate| {
                SecCertificate::from_der(certificate).map_err(|err| {
                    PlatformVerifyError::with_source(PlatformVerifyErrorKind::BadEncoding, err)
                })
            })
            .collect::<Result<Vec<_>, _>>()?;

        let policy = SecPolicy::create_ssl(SslProtocolSide::SERVER, Some(server_name));
        let mut trust = SecTrust::create_with_certificates(&certificates, &[policy])
            .map_err(|err| PlatformVerifyError::with_source(PlatformVerifyErrorKind::Other, err))?;

        trust
            .set_trust_verify_date(&cf_date(now)?)
            .map_err(|err| PlatformVerifyError::with_source(PlatformVerifyErrorKind::Other, err))?;

        if let Some(ocsp_response) = ocsp_response {
            trust
                .set_trust_ocsp_response(std::iter::once(ocsp_response))
                .map_err(|err| {
                    PlatformVerifyError::with_source(PlatformVerifyErrorKind::Other, err)
                })?;
        }

        if !self.extra_roots.is_empty() {
            // Setting anchors makes them the only ones trusted unless the
            // system anchors are explicitly kept as well.
            trust
                .set_anchor_certificates(&self.extra_roots)
                .map_err(|err| {
                    PlatformVerifyError::with_source(PlatformVerifyErrorKind::Other, err)
                })?;
            trust
                .set_trust_anchor_certificates_only(false)
                .map_err(|err| {
                    PlatformVerifyError::with_source(PlatformVerifyErrorKind::Other, err)
                })?;
        }

        if let Err(err) = trust.evaluate_with_error() {
            let kind = match err.code() {
                ERR_SEC_HOST_NAME_MISMATCH => PlatformVerifyErrorKind::NotValidForName,
                ERR_SEC_CREATE_CHAIN_FAILED | ERR_SEC_NOT_TRUSTED => {
                    PlatformVerifyErrorKind::UnknownIssuer
                }
                ERR_SEC_INVALID_EXTENDED_KEY_USAGE => PlatformVerifyErrorKind::InvalidPurpose,
                ERR_SEC_CERTIFICATE_REVOKED => PlatformVerifyErrorKind::Revoked,
                ERR_SEC_CERTIFICATE_EXPIRED | ERR_SEC_CERTIFICATE_NOT_VALID_YET => {
                    PlatformVerifyErrorKind::Expired
                }
                _ => PlatformVerifyErrorKind::Other,
            };
            return Err(PlatformVerifyError::with_source(
                kind,
                BoxError::from(err.description().to_string()),
            ));
        }

        Ok(evaluated_chain(&trust))
    }
}

// `SecTrustCopyCertificateChain` needs macOS 12, the index accessors work on
// every supported release.
#[expect(
    deprecated,
    reason = "SecTrustGetCertificateAtIndex is the chain accessor available before macOS 12"
)]
fn evaluated_chain(trust: &SecTrust) -> Vec<CertificateDer<'static>> {
    (0..trust.certificate_count())
        .filter_map(|index| trust.certificate_at_index(index))
        .map(|certificate| CertificateDer::from(certificate.to_der()))
        .collect()
}

fn cf_date(time: SystemTime) -> Result<CFDate, PlatformVerifyError> {
    let unix = time
        .duration_since(UNIX_EPOCH)
        .map_err(|err| PlatformVerifyError::with_source(PlatformVerifyErrorKind::Other, err))?;
    Ok(CFDate::new(unix.as_secs_f64() - CF_EPOCH_SINCE_UNIX_SECS))
}
