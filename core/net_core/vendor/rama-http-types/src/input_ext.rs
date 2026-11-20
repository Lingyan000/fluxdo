//! Request authority and protocol resolution, centralized for every HTTP version.
//!
//! Two views, as for [`HttpVersionInputExt`] and [`TargetHttpVersionInputExt`]:
//!
//! - **contextual** ([`AuthorityInputExt::authority`], [`ProtocolInputExt::protocol`]): what the
//!   end client asked for, for routing, matching, telemetry and URL generation. A
//!   [`Forwarded`] extension comes first: it exists only when a layer the service chose put
//!   it there (such as one trusting a proxy's `Forwarded` header). Then the target view.
//! - **target** ([`AuthorityInputExt::target_authority`], [`ProtocolInputExt::target_protocol`]):
//!   the request's own target, for where this hop connects, its TLS SNI, proxy selection,
//!   pooling and the `Host` it sends. It never reads [`Forwarded`], which describes an earlier
//!   hop: a reverse proxy that rewrote the URI to its backend must connect to the backend.
//!
//! The target authority is the URI authority (absolute-form, or `:authority` on HTTP/2 and
//! HTTP/3), then `Host`, then TLS SNI. The URI authority wins over `Host` (RFC 9112 §3.2.2,
//! RFC 9113 §8.3.1); a `Host` may differ from SNI on a reused connection (RFC 9113 §9.1.1,
//! RFC 9114 §3.3), so SNI only names a request that names no authority at all, such as
//! HTTP/1.0 without `Host` (RFC 9112 §3.3). Established proxies route the same way; a
//! policy that requires SNI and `Host` to agree answers 421 (RFC 9110 §15.5.20).
//!
//! Only explicit ports are reported; [`AuthorityInputExt::authority_with_default_port`] and
//! the connector target add the protocol's default.

#[cfg(not(feature = "tls"))]
use rama_core::extensions::Extension;
use rama_core::{
    extensions::{Extensions, ExtensionsRef},
    telemetry::tracing,
};
use rama_net::{
    AuthorityInputExt, HttpVersionInputExt, PathInputExt, Protocol, ProtocolInputExt,
    TargetHttpVersionInputExt, TransportProtocolInputExt, UriInputExt,
    address::{Domain, Host, HostWithOptPort},
    forwarded::ForwardedClientExt as _,
    http::TargetHttpVersion,
    transport::TransportProtocol,
};
#[cfg(feature = "tls")]
use rama_tls::SecureTransport;

use crate::{HttpRequestParts, Request, Uri, Version, request::Parts};

#[cfg(feature = "tls")]
fn try_get_sni_from_secure_transport(t: &SecureTransport) -> Option<Domain> {
    use rama_tls::client::ClientHelloExtension;

    t.client_hello().and_then(|h| {
        h.extensions().iter().find_map(|e| match e {
            ClientHelloExtension::ServerName(maybe_domain) => maybe_domain.clone(),
            _ => None,
        })
    })
}

#[cfg(not(feature = "tls"))]
#[derive(Debug, Clone, Extension)]
#[extension(tags(tls))]
#[non_exhaustive]
struct SecureTransport;

#[cfg(not(feature = "tls"))]
fn try_get_sni_from_secure_transport(_: &SecureTransport) -> Option<Domain> {
    None
}

/// The request's own target: URI authority, then `Host`, then TLS SNI.
fn target_authority_from_http_parts(parts: &impl HttpRequestParts) -> Option<HostWithOptPort> {
    let uri = parts.uri();
    if let Some(host) = uri.host() {
        let host: Host = host.into_owned();
        tracing::trace!(url.full = %uri, "request target: host {host} from the uri");
        return Some(match uri.port_u16() {
            Some(port) => (host, port).into(),
            None => host.into(),
        });
    }
    parts
        .headers()
        .get(crate::header::HOST)
        .and_then(|host| HostWithOptPort::try_from(host.as_bytes()).ok())
        .or_else(|| {
            let host = parts
                .extensions()
                .get_ref()
                .and_then(try_get_sni_from_secure_transport)?;
            tracing::trace!(url.full = %uri, "request target: host {host} from TLS SNI");
            Some(Host::from(host).into())
        })
}

/// What the end client asked for: a [`Forwarded`] host, then the request's own target.
pub(crate) fn authority_from_http_parts(parts: &impl HttpRequestParts) -> Option<HostWithOptPort> {
    parts
        .extensions()
        .forwarded_client_host()
        .map(|forwarded| {
            tracing::trace!("request authority: {} from forwarded info", forwarded.0);
            forwarded.0.clone()
        })
        .or_else(|| target_authority_from_http_parts(parts))
}

/// Resolve the HTTP [`Version`] from `parts`: the `Forwarded` client version
/// when present, otherwise the request's own version.
pub(crate) fn http_version_from_http_parts(parts: &impl HttpRequestParts) -> Version {
    parts
        .extensions()
        .forwarded_client_version()
        .map(|v| match v {
            rama_net::forwarded::ForwardedVersion::HTTP_09 => Version::HTTP_09,
            rama_net::forwarded::ForwardedVersion::HTTP_10 => Version::HTTP_10,
            rama_net::forwarded::ForwardedVersion::HTTP_11 => Version::HTTP_11,
            rama_net::forwarded::ForwardedVersion::HTTP_2 => Version::HTTP_2,
            rama_net::forwarded::ForwardedVersion::HTTP_3 => Version::HTTP_3,
        })
        .unwrap_or_else(|| parts.version())
}

/// The request's own [`Protocol`]: URI scheme, then a [`Protocol`] extension a server stack
/// inserted (an HTTPS server on HTTP/1 has no scheme in its targets), then TLS.
///
/// Exposed so layers holding only `(&Extensions, &Uri)`, such as the HTTP/1 encoder, decide
/// secure or not as [`ProtocolInputExt::target_protocol`] does.
pub(crate) fn target_protocol_from_uri_or_extensions<'a>(
    ext: &'a Extensions,
    uri: &'a Uri,
) -> &'a Protocol {
    uri.scheme()
        .or_else(|| ext.get_ref::<Protocol>())
        .unwrap_or_else(|| {
            if ext.contains::<SecureTransport>() {
                &Protocol::HTTPS
            } else {
                &Protocol::HTTP
            }
        })
}

/// What the end client used: a [`Forwarded`] proto, then the request's own protocol.
fn protocol_from_uri_or_extensions<'a>(ext: &'a Extensions, uri: &'a Uri) -> &'a Protocol {
    ext.forwarded_client_proto()
        .map(|proto| {
            tracing::trace!(url.full = %uri, "request protocol from forwarded client proto");
            if proto.is_secure() {
                &Protocol::HTTPS
            } else {
                &Protocol::HTTP
            }
        })
        .unwrap_or_else(|| target_protocol_from_uri_or_extensions(ext, uri))
}

impl<Body> AuthorityInputExt for Request<Body> {
    fn authority(&self) -> Option<HostWithOptPort> {
        authority_from_http_parts(self)
    }

    fn target_authority(&self) -> Option<HostWithOptPort> {
        target_authority_from_http_parts(self)
    }
}

impl AuthorityInputExt for Parts {
    fn authority(&self) -> Option<HostWithOptPort> {
        authority_from_http_parts(self)
    }

    fn target_authority(&self) -> Option<HostWithOptPort> {
        target_authority_from_http_parts(self)
    }
}

impl<Body> ProtocolInputExt for Request<Body> {
    fn protocol(&self) -> Option<&Protocol> {
        Some(protocol_from_uri_or_extensions(
            self.extensions(),
            self.uri(),
        ))
    }

    fn target_protocol(&self) -> Option<&Protocol> {
        Some(target_protocol_from_uri_or_extensions(
            self.extensions(),
            self.uri(),
        ))
    }
}

impl ProtocolInputExt for Parts {
    fn protocol(&self) -> Option<&Protocol> {
        Some(protocol_from_uri_or_extensions(
            self.extensions(),
            HttpRequestParts::uri(self),
        ))
    }

    fn target_protocol(&self) -> Option<&Protocol> {
        Some(target_protocol_from_uri_or_extensions(
            self.extensions(),
            HttpRequestParts::uri(self),
        ))
    }
}

impl<Body> HttpVersionInputExt for Request<Body> {
    fn http_version(&self) -> Option<Version> {
        Some(http_version_from_http_parts(self))
    }
}

impl HttpVersionInputExt for Parts {
    fn http_version(&self) -> Option<Version> {
        Some(http_version_from_http_parts(self))
    }
}

impl<Body> TargetHttpVersionInputExt for Request<Body> {
    fn target_http_version(&self) -> Option<Version> {
        self.target_http_version_with_fallback(None)
    }

    fn target_http_version_with_fallback(&self, fallback: Option<Version>) -> Option<Version> {
        self.extensions()
            .get_ref::<TargetHttpVersion>()
            .map(|target| target.0)
            .or(fallback)
            .or(Some(self.version()))
    }
}

impl TargetHttpVersionInputExt for Parts {
    fn target_http_version(&self) -> Option<Version> {
        self.target_http_version_with_fallback(None)
    }

    fn target_http_version_with_fallback(&self, fallback: Option<Version>) -> Option<Version> {
        self.extensions()
            .get_ref::<TargetHttpVersion>()
            .map(|target| target.0)
            .or(fallback)
            .or(Some(self.version()))
    }
}

/// The target HTTP version determines the logical transport: HTTP/3 rides on
/// UDP; every other HTTP version on TCP. Without an explicit target,
/// `target_http_version()` returns the request's own version. Physical route
/// overrides remain the responsibility of `ConnectorTransportProtocolInputExt`.
fn transport_protocol_for_http_version(version: Version) -> TransportProtocol {
    match version {
        Version::HTTP_3 => TransportProtocol::Udp,
        _ => TransportProtocol::Tcp,
    }
}

impl<Body> TransportProtocolInputExt for Request<Body> {
    fn transport_protocol(&self) -> Option<TransportProtocol> {
        self.target_http_version()
            .map(transport_protocol_for_http_version)
    }
}

impl TransportProtocolInputExt for Parts {
    fn transport_protocol(&self) -> Option<TransportProtocol> {
        self.target_http_version()
            .map(transport_protocol_for_http_version)
    }
}

impl<Body> UriInputExt for Request<Body> {
    fn uri(&self) -> &Uri {
        HttpRequestParts::uri(self)
    }
}

impl UriInputExt for Parts {
    fn uri(&self) -> &Uri {
        HttpRequestParts::uri(self)
    }
}

impl<Body> PathInputExt for Request<Body> {
    fn path_ref(&self) -> rama_net::uri::PathRef<'_> {
        self.uri().path_ref_or_root()
    }
}

impl PathInputExt for Parts {
    fn path_ref(&self) -> rama_net::uri::PathRef<'_> {
        HttpRequestParts::uri(self).path_ref_or_root()
    }
}

#[cfg(test)]
mod tests {
    use rama_core::extensions::ExtensionsRef;
    use rama_net::{
        ConnectorTargetInputExt,
        client::ConnectorTarget,
        forwarded::{Forwarded, ForwardedElement, ForwardedVersion, NodeId},
    };

    use super::*;
    use crate::{Request, header::FORWARDED};

    #[cfg(feature = "tls")]
    fn sni(name: &'static str) -> SecureTransport {
        use rama_tls::{
            ProtocolVersion,
            client::{ClientHello, ClientHelloExtension},
        };
        SecureTransport::with_client_hello(ClientHello::new(
            ProtocolVersion::TLSv1_3,
            Vec::new(),
            Vec::new(),
            vec![ClientHelloExtension::ServerName(Some(Domain::from_static(
                name,
            )))],
        ))
    }

    /// The target is the URI authority, then `Host`, then TLS SNI, never `Forwarded`; the
    /// contextual authority is a `Forwarded` host first, then the target. Ports are explicit.
    #[cfg(feature = "tls")]
    #[test]
    fn authority_views_resolve_in_order_on_every_target_form() {
        for (uri, host, with_sni, forwarded, target, contextual) in [
            // The URI authority (absolute-form, or :authority) wins over Host and SNI.
            (
                "https://uri.test/path",
                Some("host.test"),
                true,
                false,
                Some("uri.test"),
                "uri.test",
            ),
            (
                "https://uri.test:8443/",
                None,
                false,
                false,
                Some("uri.test:8443"),
                "uri.test:8443",
            ),
            // Host wins over SNI: a reused connection may serve another origin.
            (
                "/path",
                Some("host.test"),
                true,
                false,
                Some("host.test"),
                "host.test",
            ),
            (
                "/path",
                Some("host.test:9443"),
                true,
                false,
                Some("host.test:9443"),
                "host.test:9443",
            ),
            // SNI names only a request that names no authority, such as HTTP/1.0 without Host.
            ("/path", None, true, false, Some("sni.test"), "sni.test"),
            (
                "/path",
                Some("invalid host"),
                true,
                false,
                Some("sni.test"),
                "sni.test",
            ),
            ("/path", None, false, false, None, ""),
            (
                "*",
                Some("host.test:8443"),
                true,
                false,
                Some("host.test:8443"),
                "host.test:8443",
            ),
            // Forwarded comes first in the contextual view only, whatever the target form.
            (
                "https://uri.test/path",
                Some("host.test"),
                true,
                true,
                Some("uri.test"),
                "ingress.test:8080",
            ),
            (
                "/path",
                Some("host.test"),
                true,
                true,
                Some("host.test"),
                "ingress.test:8080",
            ),
            (
                "*",
                Some("host.test"),
                false,
                true,
                Some("host.test"),
                "ingress.test:8080",
            ),
            ("/path", None, false, true, None, "ingress.test:8080"),
        ] {
            let mut builder = Request::builder().uri(uri);
            if let Some(host) = host {
                builder = builder.header(crate::header::HOST, host);
            }
            let request = builder.body(()).unwrap();
            if with_sni {
                request.extensions().insert(sni("sni.test"));
            }
            if forwarded {
                request
                    .extensions()
                    .insert(Forwarded::try_from(r#"host="ingress.test:8080";proto=http"#).unwrap());
            }
            let target = target.map(|target| HostWithOptPort::try_from(target).unwrap());
            let contextual =
                (!contextual.is_empty()).then(|| HostWithOptPort::try_from(contextual).unwrap());
            let case = format!("{uri} Host={host:?} sni={with_sni} forwarded={forwarded}");
            assert_eq!(request.target_authority(), target, "{case}");
            assert_eq!(request.authority(), contextual, "{case}");
            let (parts, ()) = request.into_parts();
            assert_eq!(parts.target_authority(), target, "{case}");
            assert_eq!(parts.authority(), contextual, "{case}");
        }
    }

    /// A reverse proxy that trusted `Forwarded` and rewrote the URI to its backend connects
    /// to the backend, sends the backend's protocol, and still reports the client's view.
    #[test]
    fn a_rewritten_request_connects_to_its_own_target_not_the_forwarded_one() {
        let request = Request::builder()
            .uri("http://backend.internal:8080/api")
            .body(())
            .unwrap();
        request
            .extensions()
            .insert(Forwarded::try_from(r#"host="public.test";proto=https"#).unwrap());
        assert_eq!(
            request.connector_target(),
            Some("backend.internal:8080".parse().unwrap())
        );
        assert_eq!(request.target_protocol(), Some(&Protocol::HTTP));
        assert_eq!(
            request.authority(),
            Some(HostWithOptPort::try_from("public.test").unwrap())
        );
        assert_eq!(request.protocol(), Some(&Protocol::HTTPS));
        assert_eq!(
            request.authority_with_default_port(None),
            Some("public.test:443".parse().unwrap())
        );
    }

    #[test]
    fn logical_authority_defaults_and_connector_overrides_work_on_parts() {
        for (host, protocol, expected) in [
            (
                "example.test:8443",
                Protocol::HTTPS,
                Some("example.test:8443"),
            ),
            ("example.test", Protocol::HTTPS, Some("example.test:443")),
            ("example.test", Protocol::from_static("custom"), None),
        ] {
            let req = Request::builder()
                .uri("/path")
                .header(crate::header::HOST, host)
                .extension(protocol)
                .body(())
                .unwrap();
            let expected = expected.map(|authority| authority.parse().unwrap());
            assert_eq!(req.authority_with_default_port(None), expected);
            assert_eq!(req.connector_target(), expected);
            let fallback = expected
                .clone()
                .unwrap_or_else(|| "example.test:9000".parse().unwrap());
            assert_eq!(
                req.authority_with_default_port(Some(9000)),
                Some(fallback.clone())
            );
            assert_eq!(req.connector_target_with_default_port(9000), Some(fallback));

            let physical = "127.0.0.1:3128".parse().unwrap();
            req.extensions().insert(ConnectorTarget(physical));
            let (parts, ()) = req.into_parts();
            assert_eq!(parts.authority_with_default_port(None), expected);
            assert_eq!(
                parts.connector_target(),
                Some("127.0.0.1:3128".parse().unwrap())
            );
            assert_eq!(
                parts.connector_target_with_default_port(9000),
                parts.connector_target()
            );
        }
    }

    #[test]
    fn accessors_from_request() {
        let req = Request::builder()
            .uri("http://example.com:8080")
            .version(Version::HTTP_11)
            .body(())
            .unwrap();

        assert_eq!(req.http_version(), Some(Version::HTTP_11));
        assert_eq!(req.protocol(), Some(&Protocol::HTTP));
        assert_eq!(req.authority().unwrap().to_string(), "example.com:8080");
    }

    #[test]
    fn path_accessor_from_request_and_parts() {
        let req = Request::builder()
            .uri("http://example.com/a%2Fb?q=1")
            .body(())
            .unwrap();

        assert_eq!(req.path_ref(), "/a%2Fb");
        assert_ne!(req.path_ref(), "/a/b");

        let (parts, _) = req.into_parts();
        assert_eq!(parts.path_ref(), "/a%2Fb");
        assert_ne!(parts.path_ref(), "/a/b");
    }

    #[test]
    fn accessors_resolve() {
        let req = Request::builder()
            .uri("https://example.com:8443")
            .version(Version::HTTP_2)
            .body(())
            .unwrap();
        assert_eq!(req.authority().unwrap().to_string(), "example.com:8443");
        assert_eq!(req.protocol(), Some(&Protocol::HTTPS));
        assert_eq!(req.http_version(), Some(Version::HTTP_2));

        // origin-form with no resolvable authority -> None, but protocol and
        // version still resolve (they don't depend on the authority).
        let req = Request::builder().uri("/path").body(()).unwrap();
        assert_eq!(req.authority(), None);
        assert_eq!(req.protocol(), Some(&Protocol::HTTP));
        assert_eq!(req.http_version(), Some(Version::HTTP_11));
    }

    #[test]
    fn accessors_from_parts() {
        let req = Request::builder()
            .uri("http://example.com:8080")
            .version(Version::HTTP_11)
            .body(())
            .unwrap();

        let (parts, _) = req.into_parts();

        assert_eq!(parts.http_version(), Some(Version::HTTP_11));
        assert_eq!(parts.protocol(), Some(&Protocol::HTTP));
        assert_eq!(
            parts.authority().unwrap(),
            HostWithOptPort::try_from("example.com:8080").unwrap()
        );
    }

    #[test]
    fn target_version_ignores_forwarded_client_version() {
        let req = Request::builder()
            .version(Version::HTTP_11)
            .body(())
            .unwrap();
        req.extensions()
            .insert(Forwarded::new(ForwardedElement::new_forwarded_version(
                ForwardedVersion::HTTP_2,
            )));

        assert_eq!(req.http_version(), Some(Version::HTTP_2));
        assert_eq!(req.target_http_version(), Some(Version::HTTP_11));
    }

    #[test]
    fn explicit_target_version_overrides_request_version_for_request_and_parts() {
        let req = Request::builder()
            .version(Version::HTTP_11)
            .body(())
            .unwrap();
        req.extensions().insert(TargetHttpVersion(Version::HTTP_2));

        assert_eq!(req.target_http_version(), Some(Version::HTTP_2));

        let (parts, _) = req.into_parts();
        assert_eq!(parts.target_http_version(), Some(Version::HTTP_2));
    }

    #[test]
    fn target_version_fallback_precedes_request_version_but_not_explicit_target() {
        let req = Request::builder()
            .version(Version::HTTP_11)
            .body(())
            .unwrap();

        assert_eq!(
            req.target_http_version_with_fallback(Some(Version::HTTP_10)),
            Some(Version::HTTP_10),
        );

        req.extensions().insert(TargetHttpVersion(Version::HTTP_2));
        assert_eq!(
            req.target_http_version_with_fallback(Some(Version::HTTP_10)),
            Some(Version::HTTP_2),
        );
    }

    #[test]
    fn transport_follows_target_version_for_requests_and_parts() {
        for ingress in [Version::HTTP_11, Version::HTTP_2, Version::HTTP_3] {
            for egress in [Version::HTTP_11, Version::HTTP_2, Version::HTTP_3] {
                let request = Request::builder().version(ingress).body(()).unwrap();
                request.extensions().insert(TargetHttpVersion(egress));
                let expected = Some(if egress == Version::HTTP_3 {
                    TransportProtocol::Udp
                } else {
                    TransportProtocol::Tcp
                });

                assert_eq!(request.transport_protocol(), expected);
                assert_eq!(request.version(), ingress);

                let (parts, _) = request.into_parts();
                assert_eq!(parts.transport_protocol(), expected);
            }
        }
    }

    #[test]
    fn transport_uses_request_version_without_an_explicit_target() {
        for version in [
            Version::HTTP_10,
            Version::HTTP_11,
            Version::HTTP_2,
            Version::HTTP_3,
        ] {
            let request = Request::builder().version(version).body(()).unwrap();
            assert!(!request.extensions().contains::<TargetHttpVersion>());
            let expected = Some(if version == Version::HTTP_3 {
                TransportProtocol::Udp
            } else {
                TransportProtocol::Tcp
            });
            assert_eq!(request.target_http_version(), Some(version));
            assert_eq!(request.transport_protocol(), expected);

            let (parts, _) = request.into_parts();
            assert_eq!(parts.target_http_version(), Some(version));
            assert_eq!(parts.transport_protocol(), expected);
        }
    }

    #[test]
    fn connector_transport_overrides_http_version_transport() {
        use rama_net::{ConnectorTransportProtocolInputExt, client::ConnectorTransportProtocol};

        let request = Request::builder()
            .version(Version::HTTP_3)
            .body(())
            .unwrap();
        request
            .extensions()
            .insert(ConnectorTransportProtocol(TransportProtocol::Tcp));
        assert_eq!(request.transport_protocol(), Some(TransportProtocol::Udp));
        assert_eq!(
            request.connector_transport_protocol(),
            Some(TransportProtocol::Tcp)
        );

        let (parts, _) = request.into_parts();
        assert_eq!(parts.transport_protocol(), Some(TransportProtocol::Udp));
        assert_eq!(
            parts.connector_transport_protocol(),
            Some(TransportProtocol::Tcp)
        );
    }

    #[test]
    fn forwarded_parsing() {
        for (forwarded_str_vec, expected_authority) in [
            // base
            (
                vec!["host=192.0.2.60;proto=http;by=203.0.113.43"],
                "192.0.2.60",
            ),
            // ipv6
            (
                vec!["host=\"[2001:db8:cafe::17]:4711\""],
                "[2001:db8:cafe::17]:4711",
            ),
            // multiple values: the rightmost element, by the default selection policy
            (vec!["host=192.0.2.60, host=127.0.0.1"], "127.0.0.1"),
            // multiple header lines: this test parses only the first
            (vec!["host=192.0.2.60", "host=127.0.0.1"], "192.0.2.60"),
        ] {
            let mut req_builder = Request::builder();
            for header in forwarded_str_vec.clone() {
                req_builder = req_builder.header(FORWARDED, header);
            }

            let req = req_builder.body(()).unwrap();

            let forwarded: Forwarded = req
                .headers()
                .get(FORWARDED)
                .unwrap()
                .as_bytes()
                .try_into()
                .unwrap();
            req.extensions().insert(forwarded);

            assert_eq!(
                req.authority().map(|a| a.to_string()).as_deref(),
                Some(expected_authority),
                "Failed for {forwarded_str_vec:?}"
            );
            assert_eq!(
                req.protocol(),
                Some(&Protocol::HTTP),
                "Failed for {forwarded_str_vec:?}"
            );
            assert_eq!(
                req.http_version(),
                Some(Version::HTTP_11),
                "Failed for {forwarded_str_vec:?}"
            );
        }
    }

    #[test]
    fn https_request_behind_haproxy_plain() {
        let req = Request::builder()
            .uri("/en/reservation/roomdetails")
            .version(Version::HTTP_11)
            .header("host", "echo.ramaproxy.org")
            .header("user-agent", "curl/8.6.0")
            .header("accept", "*/*")
            .body(())
            .unwrap();

        req.extensions()
            .insert(Forwarded::new(ForwardedElement::new_forwarded_for(
                NodeId::try_from("127.0.0.1:61234").unwrap(),
            )));

        assert_eq!(req.http_version(), Some(Version::HTTP_11));
        assert_eq!(req.protocol(), Some(&Protocol::HTTP));
        let authority = req.authority().unwrap();
        assert_eq!(authority.to_string(), "echo.ramaproxy.org");
        let default_port = req
            .protocol_default_port()
            .unwrap_or(Protocol::HTTP_DEFAULT_PORT);
        assert_eq!(
            authority.into_host_with_port_or(default_port).to_string(),
            "echo.ramaproxy.org:80"
        );
    }

    // An origin-form request (no scheme) carrying a TLS `SecureTransport` marker
    // — the shape of a request read off a terminated TLS connection — must
    // resolve its protocol as HTTPS; the marker is the only secure signal here.
    // This guards the `SecureTransport` fallback in `protocol_from_uri_or_extensions`
    // against the real type being swapped for the tls-off dummy. See the matching
    // cross-crate regression in rama-http-backend's `svc` tests, which catches the
    // feature wiring (`rama-http-types/tls` must follow `rama-tls`).
    #[cfg(feature = "tls")]
    #[test]
    fn secure_transport_marks_origin_form_request_https() {
        let req = Request::builder()
            .uri("/ping")
            .header("host", "example.com")
            .body(())
            .unwrap();
        req.extensions().insert(SecureTransport::default());

        assert_eq!(req.protocol(), Some(&Protocol::HTTPS));
    }
}
