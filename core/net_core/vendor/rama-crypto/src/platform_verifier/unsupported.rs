//! Platforms without an operating system certificate verifier.

use std::time::SystemTime;

use rama_core::error::BoxError;

use super::{PlatformVerifyError, PlatformVerifyErrorKind};
use crate::pki_types::CertificateDer;

pub(super) struct Verifier;

impl Verifier {
    pub(super) fn new() -> Self {
        Self
    }

    pub(super) fn try_with_extra_roots(
        _roots: &[CertificateDer<'static>],
    ) -> Result<Self, BoxError> {
        Ok(Self)
    }

    #[expect(clippy::unused_self, reason = "mirrors the platform verifiers")]
    pub(super) fn verify_server_chain(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &str,
        _ocsp_response: Option<&[u8]>,
        _now: SystemTime,
    ) -> Result<Vec<CertificateDer<'static>>, PlatformVerifyError> {
        Err(PlatformVerifyError::new(
            PlatformVerifyErrorKind::Unavailable,
        ))
    }
}
