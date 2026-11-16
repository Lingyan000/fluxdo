//! Logical HTTP origins, service candidates and connection-selection metadata.
//!
//! Discovery supplies immutable candidates. A connector selects one before
//! pooling and records the established service only after validating the peer.
//! These types do not impose Alt-Svc or DNS freshness and retry rules.

use rama_core::{
    error::{BoxError, BoxErrorExt as _},
    extensions::Extension,
};
use rama_net::{
    Protocol,
    address::{Host, HostWithPort},
    client::ProxyRouteContext,
    tls::ApplicationProtocol,
};
use rama_utils::macros::generate_set_and_with;
use std::sync::Arc;

/// An HTTP origin, including its scheme and effective port.
///
/// Alternative services change the dial target, never this authentication and
/// request identity. HTTP and HTTPS origins remain distinct even at the same port.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct HttpOrigin {
    protocol: Protocol,
    authority: HostWithPort,
}

impl HttpOrigin {
    /// Validate an HTTP(S) scheme and network-usable origin authority.
    pub fn new(protocol: Protocol, authority: HostWithPort) -> Result<Self, BoxError> {
        if protocol != Protocol::HTTP && protocol != Protocol::HTTPS {
            return Err(BoxError::from_static_str(
                "HTTP service origin requires HTTP or HTTPS",
            ));
        }
        if authority.port == 0 {
            return Err(BoxError::from_static_str(
                "HTTP service origin requires a nonzero port",
            ));
        }
        let authority = authority.canonicalize();
        if !matches!(authority.host, Host::Name(_) | Host::Address(_)) {
            return Err(BoxError::from_static_str(
                "HTTP service origin requires a DNS name or IP address",
            ));
        }
        Ok(Self {
            protocol,
            authority,
        })
    }

    /// Logical HTTP scheme.
    pub fn protocol(&self) -> &Protocol {
        &self.protocol
    }

    /// Logical host and effective port, independently of the dial target.
    pub fn authority(&self) -> &HostWithPort {
        &self.authority
    }

    /// Whether the logical origin uses HTTPS.
    pub fn is_secure(&self) -> bool {
        self.protocol == Protocol::HTTPS
    }
}

/// Where a service candidate was learned.
///
/// Discovery sources have different authorization, freshness and request-header
/// rules. Merely selecting an endpoint must not turn it into an Alt-Svc hint.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum HttpServiceSource {
    /// Explicit application configuration, independent of response advertisements.
    #[default]
    Configured,
    /// An HTTP alternative-service advertisement (RFC 7838).
    ///
    /// The RFC defines the `Alt-Svc` response header and HTTP/2 ALTSVC frame.
    /// Rama learns response headers and connection-local HTTP/2 frames.
    /// DNS HTTPS/SVCB records are a separate discovery mechanism,
    /// with different authorization, freshness and selection rules.
    AltSvc,
}

/// A protocol and endpoint offered for a logical HTTP origin.
///
/// The protocol identifies the required negotiated application protocol; it is
/// not permission to downgrade the request or skip origin authentication.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct HttpServiceCandidate {
    /// Required negotiated application protocol.
    pub protocol: ApplicationProtocol,
    /// Physical endpoint, independently of the logical origin.
    pub target: HostWithPort,
    /// Discovery mechanism whose policies apply to this candidate.
    pub source: HttpServiceSource,
}

impl HttpServiceCandidate {
    /// Describe an endpoint and the protocol it must provide.
    pub fn new(protocol: ApplicationProtocol, target: HostWithPort) -> Self {
        Self {
            protocol,
            target: target.canonicalize(),
            source: HttpServiceSource::Configured,
        }
    }

    generate_set_and_with! {
        /// Record the discovery mechanism whose policies apply to this candidate.
        pub fn source(mut self, source: HttpServiceSource) -> Self {
            self.source = source;
            self
        }
    }
}

/// An immutable, ordered discovery snapshot for one origin.
///
/// Share snapshots through `Arc<HttpServiceCandidates>`, including the Arc
/// already provided by request extensions. Discovery-specific freshness and
/// availability remain with the source; inspect those before trying a candidate.
#[derive(Debug, Extension)]
#[extension(tags(http))]
pub struct HttpServiceCandidates {
    origin: HttpOrigin,
    candidates: Box<[HttpServiceCandidate]>,
}

impl HttpServiceCandidates {
    /// Create a new discovery snapshot in preference order.
    pub fn new(origin: HttpOrigin, candidates: impl Into<Box<[HttpServiceCandidate]>>) -> Self {
        Self {
            origin,
            candidates: candidates.into(),
        }
    }

    /// The origin all candidates serve.
    pub fn origin(&self) -> &HttpOrigin {
        &self.origin
    }

    /// Candidates in source preference order.
    pub fn iter(&self) -> std::slice::Iter<'_, HttpServiceCandidate> {
        self.candidates.iter()
    }

    /// Candidate at the given stable snapshot index.
    pub fn get(&self, index: usize) -> Option<&HttpServiceCandidate> {
        self.candidates.get(index)
    }

    /// Number of advertised candidates, including any since expired or suppressed.
    pub fn len(&self) -> usize {
        self.candidates.len()
    }

    /// Whether this snapshot has no candidates.
    pub fn is_empty(&self) -> bool {
        self.candidates.is_empty()
    }
}

/// Advertisement selected for this request, independent of pooled connection state.
///
/// Selectors publish this on the winning input, never on a shared connection.
/// Response middleware uses the snapshot to invalidate a rejected advertisement
/// without deleting a newer one. Consumers must verify that the candidate matches
/// the request origin and [`EstablishedHttpService`]; selection alone proves no
/// successful connection or authentication.
#[derive(Clone, Debug, Extension)]
#[extension(tags(http))]
pub struct HttpServiceSelection {
    /// Immutable discovery generation used for selection.
    pub candidates: Arc<HttpServiceCandidates>,
    /// Candidate index within this generation.
    pub index: usize,
    /// Route plan used for availability lookup, before an inner connector chooses
    /// a winning route. Response outcomes must update this same discovery scope.
    pub route: Option<ProxyRouteContext>,
}

/// One candidate selected for an isolated connection attempt.
#[derive(Clone, Debug, Extension)]
#[extension(tags(http))]
pub struct SelectedHttpService {
    /// Original request and authentication identity.
    pub origin: HttpOrigin,
    /// Endpoint and protocol selected for this attempt.
    pub candidate: HttpServiceCandidate,
}

impl SelectedHttpService {
    /// Record a decision before connection establishment.
    pub fn new(origin: HttpOrigin, candidate: HttpServiceCandidate) -> Self {
        Self { origin, candidate }
    }
}

/// An alternative whose protocol and origin authorization were verified.
///
/// Publish only after successful establishment, and retain on pool reuse. A
/// selected candidate alone is not evidence that this service was established.
/// For HTTP origins, authorization includes RFC 8164's additional requirements;
/// a TLS handshake alone is insufficient.
#[derive(Clone, Debug, Extension)]
#[extension(tags(http))]
pub struct EstablishedHttpService {
    /// Authenticated origin of the request that established this connection,
    /// unchanged when other verified origins coalesce onto it.
    pub origin: HttpOrigin,
    /// Verified protocol and connected endpoint.
    pub candidate: HttpServiceCandidate,
}

impl EstablishedHttpService {
    /// Record an alternative after validating protocol and origin authorization.
    pub fn new(origin: HttpOrigin, candidate: HttpServiceCandidate) -> Self {
        Self { origin, candidate }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn origins_canonicalize_hosts_and_preserve_scheme_and_port() {
        let origin = |protocol, authority: &str| {
            HttpOrigin::new(protocol, authority.parse().unwrap()).unwrap()
        };
        let https = origin(Protocol::HTTPS, "EXAMPLE.com:443");
        assert_eq!(https, origin(Protocol::HTTPS, "example.com:443"));
        assert_ne!(https, origin(Protocol::HTTP, "example.com:443"));
        assert_ne!(https, origin(Protocol::HTTPS, "example.com:8443"));
        HttpOrigin::new(Protocol::WS, "example.com:21".parse().unwrap()).unwrap_err();
        HttpOrigin::new(Protocol::HTTPS, "example.com:0".parse().unwrap()).unwrap_err();
        HttpOrigin::new(Protocol::HTTPS, "[v1.a]:443".parse().unwrap()).unwrap_err();
    }

    #[test]
    fn provenance_survives_selection_and_establishment() {
        let origin = HttpOrigin::new(Protocol::HTTPS, "example.com:443".parse().unwrap()).unwrap();
        let configured = HttpServiceCandidate::new(
            ApplicationProtocol::HTTP_2,
            "alt.example:8443".parse().unwrap(),
        );
        assert_eq!(configured.source, HttpServiceSource::Configured);
        let advertised = configured.with_source(HttpServiceSource::AltSvc);
        let selected = SelectedHttpService::new(origin.clone(), advertised.clone());
        let established = EstablishedHttpService::new(origin, advertised);
        assert_eq!(selected.candidate.source, HttpServiceSource::AltSvc);
        assert_eq!(established.candidate.source, HttpServiceSource::AltSvc);
    }

    #[test]
    fn snapshots_share_storage_but_new_advertisements_have_new_identity() {
        let origin = HttpOrigin::new(Protocol::HTTPS, "example.com:443".parse().unwrap()).unwrap();
        let candidate = HttpServiceCandidate::new(
            ApplicationProtocol::HTTP_2,
            "alt.example:8443".parse().unwrap(),
        );
        let first = Arc::new(HttpServiceCandidates::new(
            origin.clone(),
            vec![candidate.clone()],
        ));
        assert!(Arc::ptr_eq(&first, &first.clone()));
        let replacement = Arc::new(HttpServiceCandidates::new(origin, vec![candidate]));
        assert!(!Arc::ptr_eq(&first, &replacement));
        assert_eq!(first.get(0), replacement.get(0));
    }
}
