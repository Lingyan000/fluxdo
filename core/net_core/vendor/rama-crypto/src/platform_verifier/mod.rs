//! Verify TLS server certificates with the operating system's own verifier,
//! in a tls-implementation agnostic way.
//!
//! Where [`native_certs`] reads a snapshot of the platform trust store into
//! memory, a [`PlatformVerifier`] hands every presented chain to the platform
//! verifier and lets it decide. That honours enterprise trust settings, the
//! platform's distrust decisions and revocation policy, and keeps working
//! where reading the trust store is restricted, such as inside a sandboxed
//! Apple network extension.
//!
//! Supported on Apple platforms (Security framework), Windows (CryptoAPI) and
//! Android (the platform `X509TrustManager`). Other platforms have no such
//! verifier: [`PlatformVerifier::IS_AVAILABLE`] is `false` there and
//! verification fails with [`PlatformVerifyErrorKind::Unavailable`].
//!
//! The TLS backend remains responsible for the handshake signatures; this
//! module only validates the certificate chain and server identity, and
//! returns the chain the platform built so callers can inspect it.
//!
//! On Android the verifier reads the process `JavaVM` through [`ndk-context`].
//! Native activities initialize it automatically; other embedders initialize
//! `ndk-context` themselves, preferably with an Application context. In an app,
//! default trust follows Network Security Config. Additional roots are separate
//! application authority: they are tried only after a missing-anchor failure
//! and do not inherit Network Security Config pins. Explicit platform rejections
//! (including pin failures) are never overridden by additional roots.
//!
//! Revocation follows the platform's capabilities. Windows checks the leaf and
//! soft-fails unavailable revocation information. Android API 24+ does the same,
//! fetching only for system-rooted chains unless a staple is supplied; API 23
//! has no supplementary revocation check. For a chain with an issuer, a supplied
//! Android staple must validate; malformed or invalid staples are rejected.
//! Apple uses Security framework policy.
//! These checks do not promise hard-fail revocation or revocation of every CA.
//!
//! Native verification may fetch intermediates or revocation data and cannot
//! be cancelled after it starts. Applications must bound connection concurrency
//! and size executor blocking pools for this work, especially when peers can
//! choose upstream destinations. A timeout alone does not bound native work.
//!
//! [`native_certs`]: crate::native_certs
//! [`ndk-context`]: https://docs.rs/ndk-context

use std::{
    fmt,
    sync::{Arc, LazyLock},
    time::SystemTime,
};

use rama_core::error::BoxError;
use rama_net::address::Host;

use crate::pki_types::CertificateDer;

#[cfg(any(target_os = "android", test))]
mod name;

#[cfg(target_vendor = "apple")]
mod apple;
#[cfg(target_vendor = "apple")]
use apple as imp;

#[cfg(windows)]
mod windows;
#[cfg(windows)]
use windows as imp;

#[cfg(target_os = "android")]
mod android;
#[cfg(target_os = "android")]
use android as imp;

#[cfg(not(any(target_vendor = "apple", windows, target_os = "android")))]
mod unsupported;
#[cfg(not(any(target_vendor = "apple", windows, target_os = "android")))]
use unsupported as imp;

/// Presented intermediates beyond which a chain is refused unverified.
const MAX_INTERMEDIATES: usize = 16;

/// A TLS server certificate verifier backed by the operating system.
///
/// Each instance owns its additional trust anchors. Building one may parse
/// certificates or create platform objects, so share instances where possible;
/// [`PlatformVerifier::shared`] is the process-wide instance without
/// additional anchors.
pub struct PlatformVerifier(imp::Verifier);

impl fmt::Debug for PlatformVerifier {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PlatformVerifier").finish_non_exhaustive()
    }
}

impl PlatformVerifier {
    /// Whether this platform has an operating system verifier.
    pub const IS_AVAILABLE: bool =
        cfg!(any(target_vendor = "apple", windows, target_os = "android"));

    /// Create a verifier that trusts what the operating system trusts.
    #[must_use]
    pub fn new() -> Self {
        Self(imp::Verifier::new())
    }

    /// Create a verifier that also trusts `roots`, in addition to what the
    /// operating system trusts.
    ///
    /// The operating system's trust rules apply to `roots`. On Windows only a
    /// self-signed root certificate can anchor a chain, as for any Windows
    /// application: an intermediate given here is not trusted on its own.
    /// Each Windows verification that needs `roots` builds its own chain
    /// engine, which measured about 7 ms against about 1 ms for a chain the
    /// system trusts.
    pub fn try_with_extra_roots(
        roots: impl IntoIterator<Item = CertificateDer<'static>>,
    ) -> Result<Self, BoxError> {
        let roots: Vec<_> = roots.into_iter().collect();
        if roots.is_empty() {
            return Ok(Self::new());
        }
        imp::Verifier::try_with_extra_roots(&roots).map(Self)
    }

    /// The process-wide verifier, which also trusts the
    /// [`shared_extra_trust_anchors`] from the environment.
    ///
    /// `SSL_CERT_FILE` and `SSL_CERT_DIR` are not consulted: they replace a
    /// root store, and the operating system's verifier has none to replace.
    ///
    /// [`shared_extra_trust_anchors`]: crate::native_certs::shared_extra_trust_anchors
    #[must_use]
    pub fn shared() -> Arc<Self> {
        static VERIFIER: LazyLock<Arc<PlatformVerifier>> = LazyLock::new(|| {
            let extra = crate::native_certs::shared_extra_trust_anchors();
            Arc::new(
                PlatformVerifier::try_with_extra_roots(extra.iter().cloned()).unwrap_or_else(
                    |err| {
                        rama_core::telemetry::tracing::warn!(
                            %err,
                            "rama platform verifier: extra root certificates rejected; verifying without them"
                        );
                        PlatformVerifier::new()
                    },
                ),
            )
        });
        VERIFIER.clone()
    }

    /// Verify a server certificate chain for `server_name` at time `now`.
    ///
    /// Android's initial TrustManager uses the wall clock. The supplied date
    /// additionally checks the leaf and the supplementary leaf revocation pass;
    /// it does not time-shift intermediate validation. Android therefore does
    /// not support general historical certificate validation.
    ///
    /// `intermediates` are the other certificates the server presented, and
    /// `ocsp_response` a stapled OCSP response, if any. On success the chain
    /// the platform built is returned, leaf first and ending at the trust
    /// anchor.
    ///
    /// This may block on network access, e.g. to fetch revocation information
    /// or missing intermediates, so do not call it on an async executor thread.
    /// A timeout cannot interrupt a running native call. Callers must bound
    /// concurrent work independently of handshake deadlines.
    pub fn verify_server_chain(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        server_name: &Host,
        ocsp_response: Option<&[u8]>,
        now: SystemTime,
    ) -> Result<Vec<CertificateDer<'static>>, PlatformVerifyError> {
        // Real chains are short; a long one only costs platform resources.
        if intermediates.len() > MAX_INTERMEDIATES {
            return Err(PlatformVerifyError::new(
                PlatformVerifyErrorKind::BadEncoding,
            ));
        }
        let server_name = server_name_str(server_name);
        let ocsp_response = ocsp_response.filter(|response| !response.is_empty());
        self.0
            .verify_server_chain(end_entity, intermediates, &server_name, ocsp_response, now)
    }
}

impl Default for PlatformVerifier {
    fn default() -> Self {
        Self::new()
    }
}

/// Platform verifiers compare names exactly, so a trailing root label would
/// fail an otherwise equivalent match.
fn server_name_str(server_name: &Host) -> String {
    if let Ok(ip) = server_name.try_as_ip() {
        return ip.to_string();
    }
    let name = server_name.to_string();
    match name.strip_suffix('.') {
        Some(stripped) => stripped.to_owned(),
        None => name,
    }
}

/// Why the platform verifier rejected a certificate chain.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum PlatformVerifyErrorKind {
    /// The chain does not lead to a trusted root.
    UnknownIssuer,
    /// A certificate is expired or not yet valid.
    Expired,
    /// The leaf is not valid for the server name.
    NotValidForName,
    /// A certificate was revoked.
    Revoked,
    /// The leaf is not valid for server authentication.
    InvalidPurpose,
    /// A certificate could not be decoded.
    BadEncoding,
    /// This platform has no usable certificate verifier.
    Unavailable,
    /// Any other rejection or platform failure.
    Other,
}

/// Error returned by [`PlatformVerifier::verify_server_chain`].
#[derive(Debug)]
pub struct PlatformVerifyError {
    kind: PlatformVerifyErrorKind,
    source: Option<BoxError>,
}

impl PlatformVerifyError {
    pub(crate) fn new(kind: PlatformVerifyErrorKind) -> Self {
        Self { kind, source: None }
    }

    #[cfg_attr(
        not(any(target_vendor = "apple", windows, target_os = "android")),
        expect(dead_code, reason = "no platform verifier to report a source")
    )]
    pub(crate) fn with_source(kind: PlatformVerifyErrorKind, source: impl Into<BoxError>) -> Self {
        Self {
            kind,
            source: Some(source.into()),
        }
    }

    /// Why the chain was rejected.
    #[must_use]
    pub fn kind(&self) -> PlatformVerifyErrorKind {
        self.kind
    }
}

impl fmt::Display for PlatformVerifyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let reason = match self.kind {
            PlatformVerifyErrorKind::UnknownIssuer => "certificate issuer is not trusted",
            PlatformVerifyErrorKind::Expired => "certificate is expired or not yet valid",
            PlatformVerifyErrorKind::NotValidForName => {
                "certificate is not valid for the server name"
            }
            PlatformVerifyErrorKind::Revoked => "certificate is revoked",
            PlatformVerifyErrorKind::InvalidPurpose => {
                "certificate is not valid for server authentication"
            }
            PlatformVerifyErrorKind::BadEncoding => "certificate could not be decoded",
            PlatformVerifyErrorKind::Unavailable => "no platform certificate verifier available",
            PlatformVerifyErrorKind::Other => "certificate rejected by the platform verifier",
        };
        f.write_str("platform verifier: ")?;
        f.write_str(reason)?;
        if let Some(source) = &self.source {
            write!(f, ": {source}")?;
        }
        Ok(())
    }
}

impl std::error::Error for PlatformVerifyError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        self.source
            .as_deref()
            .map(|source| source as &(dyn std::error::Error + 'static))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(not(any(target_vendor = "apple", windows, target_os = "android")))]
    fn unsupported_platforms_report_unavailable() {
        let err = PlatformVerifier::shared()
            .verify_server_chain(
                &CertificateDer::from(vec![0x30]),
                &[],
                &Host::EXAMPLE_NAME,
                None,
                SystemTime::now(),
            )
            .unwrap_err();
        assert_eq!(err.kind(), PlatformVerifyErrorKind::Unavailable);
    }

    #[test]
    fn overlong_chains_are_refused_before_the_platform_sees_them() {
        let certificate = CertificateDer::from(vec![0x30]);
        let intermediates = vec![certificate.clone(); MAX_INTERMEDIATES + 1];
        let err = PlatformVerifier::shared()
            .verify_server_chain(
                &certificate,
                &intermediates,
                &Host::EXAMPLE_NAME,
                None,
                SystemTime::now(),
            )
            .unwrap_err();
        assert_eq!(err.kind(), PlatformVerifyErrorKind::BadEncoding);
    }

    #[test]
    fn server_names_are_normalized_for_platform_matching() {
        assert_eq!(
            server_name_str(&"example.com.".parse().unwrap()),
            "example.com"
        );
        assert_eq!(server_name_str(&"[::1]".parse().unwrap()), "::1");
        assert_eq!(server_name_str(&"127.0.0.1".parse().unwrap()), "127.0.0.1");
    }
}
