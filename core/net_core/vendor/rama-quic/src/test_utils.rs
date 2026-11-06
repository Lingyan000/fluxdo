//! TLS selection for downstream protocol tests.

use crate::tls::{QuicClientConfigProvider, QuicServerConfigProvider, TlsConfigError};
use std::sync::Arc;

/// Prefer Boring when enabled, otherwise use the default TLS providers.
///
/// Downstream test commands can enable `rama-quic/boring` directly, even when
/// their dev-dependencies also enable Rustls. Production provider selection
/// remains independent of this test-only choice.
pub fn tls_providers() -> Result<
    (
        Arc<dyn QuicClientConfigProvider>,
        Arc<dyn QuicServerConfigProvider>,
    ),
    TlsConfigError,
> {
    #[cfg(feature = "boring")]
    {
        Ok((
            Arc::new(crate::tls::BoringTlsProvider),
            Arc::new(crate::tls::BoringTlsProvider),
        ))
    }
    #[cfg(not(feature = "boring"))]
    {
        Ok((
            crate::tls::default_tls_provider()?,
            crate::tls::default_server_tls_provider()?,
        ))
    }
}
