use std::fmt;

use rama_core::error::BoxError;
use rama_net::tls::AlpnPolicy;
pub use rama_tls::client::ClientHandshake;
use rama_utils::macros::generate_set_and_with;

/// Client TLS ticket policy, independent of transport connection pooling.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[non_exhaustive]
pub enum ClientSessionPolicy {
    /// Store and offer compatible tickets when the provider has a session cache.
    #[default]
    Reuse,
    /// Always use a full handshake; do not read or retain session tickets.
    /// This also prevents client 0-RTT, even when early application data is allowed.
    Fresh,
}

/// QUIC requirements applied to the common Rama TLS configuration.
#[derive(Clone, Copy, Debug, Default)]
pub struct TlsOptions {
    pub(crate) alpn: AlpnPolicy,
    pub(crate) early_data: bool,
    pub(crate) client_sessions: ClientSessionPolicy,
}

impl TlsOptions {
    generate_set_and_with! {
        /// Client ticket policy. Servers ignore this client-only option.
        /// Connection pooling remains an independent application decision.
        pub fn client_sessions(mut self, policy: ClientSessionPolicy) -> Self {
            self.client_sessions = policy;
            self
        }
    }

    generate_set_and_with! {
        /// How peers agree on their application protocol.
        /// Direct constructors honor this value over the common TLS configuration.
        /// ClientConfigCache resolves request/config overrides before calling constructors.
        pub fn alpn(mut self, policy: AlpnPolicy) -> Self {
            self.alpn = policy;
            self
        }
    }
    generate_set_and_with! {
        /// Allow early application data, which a peer may replay. Disabled by default.
        pub fn early_data(mut self, allowed: bool) -> Self {
            self.early_data = allowed;
            self
        }
    }
}

#[derive(Debug)]
pub enum TlsConfigError {
    BackendUnavailable,
    UnsupportedOutOfBandAgreement,
    Tls13Required,
    AlpnRequired,
    InvalidAlpn,
    UnsupportedDynamicConfig,
    EarlyDataNotEnabled,
    NoInitialCipherSuite(NoInitialCipherSuite),
    InvalidConfiguration(BoxError),
}

impl fmt::Display for TlsConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BackendUnavailable => {
                f.write_str("no built-in QUIC TLS configuration provider is available")
            }
            Self::UnsupportedOutOfBandAgreement => f.write_str(
                "this QUIC TLS backend requires ALPN even with out-of-band protocol agreement",
            ),
            Self::Tls13Required => f.write_str("QUIC requires TLS 1.3"),
            Self::AlpnRequired => {
                f.write_str("QUIC requires ALPN unless another protocol agreement is explicit")
            }
            Self::InvalidAlpn => f.write_str("invalid ALPN protocol list"),
            Self::UnsupportedDynamicConfig => f.write_str(
                "per-ClientHello TLS configuration needs a resolving QUIC server configuration",
            ),
            Self::EarlyDataNotEnabled => {
                f.write_str("TLS configuration enables early data without QUIC application opt-in")
            }
            Self::NoInitialCipherSuite(error) => error.fmt(f),
            Self::InvalidConfiguration(error) => {
                write!(f, "invalid QUIC TLS configuration: {error}")
            }
        }
    }
}

impl std::error::Error for TlsConfigError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::NoInitialCipherSuite(error) => Some(error),
            Self::InvalidConfiguration(error) => Some(error.as_ref()),
            _ => None,
        }
    }
}

impl From<BoxError> for TlsConfigError {
    fn from(error: BoxError) -> Self {
        Self::InvalidConfiguration(error)
    }
}

impl From<NoInitialCipherSuite> for TlsConfigError {
    fn from(error: NoInitialCipherSuite) -> Self {
        Self::NoInitialCipherSuite(error)
    }
}

/// The QUIC initial cipher suite, AES-128-GCM-SHA256, is unavailable or invalid.
#[derive(Clone, Debug)]
pub struct NoInitialCipherSuite {
    pub(crate) specific: bool,
}

impl fmt::Display for NoInitialCipherSuite {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(if self.specific {
            "invalid cipher suite specified"
        } else {
            "no initial cipher suite found"
        })
    }
}

impl std::error::Error for NoInitialCipherSuite {}
