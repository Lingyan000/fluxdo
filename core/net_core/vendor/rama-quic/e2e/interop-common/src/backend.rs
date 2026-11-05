//! Verify Rama's native provider even when an independent peer enables another Rustls backend.

use rama::quic::tls::{QuicClientConfigProvider, QuicServerConfigProvider, TlsOptions};
use std::sync::Arc;

#[cfg(feature = "boring")]
use rama::{quic::tls::BoringTlsProvider, tls::boring::core::ssl::quic::QuicError};
#[cfg(not(feature = "boring"))]
use rama::{
    quic::tls::{default_server_tls_provider, default_tls_provider},
    tls::rustls::{client::RustlsClientConfigExt, server::RustlsServerConfigExt},
};

#[cfg(not(feature = "boring"))]
mod rustls_backend {
    use rama::{error::BoxError, tls::rustls::dep::rustls};

    fn expected_provider() -> rustls::crypto::CryptoProvider {
        #[cfg(feature = "rustls-aws-lc")]
        let expected = rustls::crypto::aws_lc_rs::default_provider();
        #[cfg(not(feature = "rustls-aws-lc"))]
        let expected = rustls::crypto::ring::default_provider();
        expected
    }

    fn verify_provider(provider: &rustls::crypto::CryptoProvider) -> Result<(), BoxError> {
        let expected = expected_provider();
        let mut has_tls13 = false;
        // Suite identities include the concrete packet and handshake cryptography. Comparing
        // wire cipher IDs alone would accept the same cipher supplied by the wrong backend.
        for suite in &provider.cipher_suites {
            let Some(actual) = suite.tls13() else {
                continue;
            };
            has_tls13 = true;
            if !expected.cipher_suites.iter().any(|candidate| {
                candidate
                    .tls13()
                    .is_some_and(|wanted| std::ptr::eq(actual, wanted))
            }) {
                return Err(
                    "Rama interop did not select the requested Rustls crypto provider".into(),
                );
            }
        }
        if !has_tls13 {
            return Err("Rama interop requires at least one TLS 1.3 cipher suite".into());
        }
        Ok(())
    }

    /// Check the provider selected by Rama without replacing its native client configuration.
    pub fn verify_client(config: rustls::ClientConfig) -> Result<rustls::ClientConfig, BoxError> {
        verify_provider(config.crypto_provider())?;
        Ok(config)
    }

    /// Check the provider selected by Rama without replacing its native server configuration.
    pub fn verify_server(config: rustls::ServerConfig) -> Result<rustls::ServerConfig, BoxError> {
        verify_provider(config.crypto_provider())?;
        Ok(config)
    }

    #[cfg(test)]
    mod tests {
        #[test]
        fn empty_cipher_suites_are_rejected() {
            let mut provider = super::expected_provider();
            provider.cipher_suites.clear();
            let error = super::verify_provider(&provider)
                .expect_err("empty suites cannot verify a backend");
            assert_eq!(
                error.to_string(),
                "Rama interop requires at least one TLS 1.3 cipher suite"
            );
        }

        #[test]
        fn tls12_only_cipher_suites_are_rejected() {
            let mut provider = super::expected_provider();
            provider
                .cipher_suites
                .retain(|suite| suite.tls13().is_none());
            assert!(
                !provider.cipher_suites.is_empty(),
                "fixture includes TLS 1.2 suites"
            );
            let error = super::verify_provider(&provider)
                .expect_err("TLS 1.2 cannot verify a QUIC backend");
            assert_eq!(
                error.to_string(),
                "Rama interop requires at least one TLS 1.3 cipher suite"
            );
        }

        #[test]
        fn rama_builders_use_selected_provider() {
            let identity = crate::identity::server_identity();
            let _ = crate::identity::rama_client_config(crate::identity::anchor_of(&identity));
            let _ = crate::identity::rama_server_config(&identity);
        }
    }
}

#[cfg(not(feature = "boring"))]
pub use rustls_backend::{verify_client, verify_server};

/// Install native provider checks only for the TLS backend selected by the case.
pub trait VerifyBackend: Sized {
    fn verify_backend(self) -> Self;
}

impl VerifyBackend for rama::tls::client::TlsClientConfig {
    fn verify_backend(self) -> Self {
        #[cfg(not(feature = "boring"))]
        {
            self.with_modify_rustls_config(verify_client)
        }
        #[cfg(feature = "boring")]
        {
            self
        }
    }
}

impl VerifyBackend for rama::tls::server::TlsServerConfig {
    fn verify_backend(self) -> Self {
        #[cfg(not(feature = "boring"))]
        {
            self.with_modify_rustls_config(verify_server)
        }
        #[cfg(feature = "boring")]
        {
            self
        }
    }
}

/// TLS alert wire values used by the independent peers.
pub const UNKNOWN_CA: u8 = 48;
pub const BAD_CERTIFICATE: u8 = 42;

/// Select the Rama backend explicitly; peer dependencies may enable other implementations.
pub fn options() -> TlsOptions {
    TlsOptions::default()
}

pub fn tls_provider() -> Arc<dyn QuicClientConfigProvider> {
    #[cfg(feature = "boring")]
    {
        Arc::new(BoringTlsProvider)
    }
    #[cfg(not(feature = "boring"))]
    {
        default_tls_provider().unwrap()
    }
}

pub fn server_tls_provider() -> Arc<dyn QuicServerConfigProvider> {
    #[cfg(feature = "boring")]
    {
        Arc::new(BoringTlsProvider)
    }
    #[cfg(not(feature = "boring"))]
    {
        default_server_tls_provider().unwrap()
    }
}

#[cfg(feature = "boring")]
pub fn assert_certificate_failure(error: &rama::quic::proto::TransportError) {
    let Some(QuicError::Tls(native)) = error
        .cause()
        .and_then(|cause| cause.downcast_ref::<QuicError>())
    else {
        panic!(
            "a native TLS verification failure was due: {:?}",
            error.cause()
        );
    };
    assert!(
        native.ssl_error().is_some_and(|stack| stack
            .errors()
            .iter()
            .any(|entry| entry.reason() == Some("CERTIFICATE_VERIFY_FAILED"))),
        "the native failure must be certificate verification: {native:?}"
    );
}
