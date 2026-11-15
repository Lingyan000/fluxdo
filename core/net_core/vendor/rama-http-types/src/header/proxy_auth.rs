//! Proxy authentication header sanitation utilities.
//!
//! These fields are not inherently hop-by-hop: a transparent intermediary
//! can be forwarding them to the proxy that owns the authentication exchange.
//! Apply these functions only at a boundary that consumes or separately
//! transports proxy authentication.

use rama_core::telemetry::tracing;

use crate::{HeaderMap, HeaderName, header};

fn remove_fields<'a>(headers: &mut HeaderMap, names: impl IntoIterator<Item = &'a HeaderName>) {
    for name in names {
        if headers.remove(name).is_some() {
            tracing::trace!(header = %name, "removed proxy auth header");
        }
    }
}

/// Remove credentials addressed to the current proxy from a request.
pub fn remove_proxy_auth_request_headers(headers: &mut HeaderMap) {
    remove_fields(headers, [&header::PROXY_AUTHORIZATION]);
}

/// Remove proxy authentication fields from a response.
pub fn remove_proxy_auth_response_headers(headers: &mut HeaderMap) {
    remove_fields(
        headers,
        [
            &header::PROXY_AUTHENTICATE,
            &header::PROXY_AUTHENTICATION_INFO,
        ],
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::HeaderValue;

    #[test]
    fn request_cleanup_is_explicit() {
        let mut headers = HeaderMap::new();
        headers.insert(
            header::PROXY_AUTHORIZATION,
            HeaderValue::from_static("Basic dGVzdA=="),
        );
        headers.insert(
            header::PROXY_AUTHENTICATE,
            HeaderValue::from_static("Basic"),
        );

        remove_proxy_auth_request_headers(&mut headers);

        assert!(!headers.contains_key(header::PROXY_AUTHORIZATION));
        assert!(headers.contains_key(header::PROXY_AUTHENTICATE));
    }

    #[test]
    fn response_cleanup_is_explicit() {
        let mut headers = HeaderMap::new();
        headers.insert(
            header::PROXY_AUTHENTICATE,
            HeaderValue::from_static("Basic"),
        );
        headers.insert(
            header::PROXY_AUTHENTICATION_INFO,
            HeaderValue::from_static("nextnonce=abc"),
        );
        headers.insert(
            header::PROXY_AUTHORIZATION,
            HeaderValue::from_static("Basic dGVzdA=="),
        );
        headers.insert(
            header::AUTHENTICATION_INFO,
            HeaderValue::from_static("nextnonce=origin"),
        );

        remove_proxy_auth_response_headers(&mut headers);

        assert!(!headers.contains_key(header::PROXY_AUTHENTICATE));
        assert!(!headers.contains_key(header::PROXY_AUTHENTICATION_INFO));
        assert!(headers.contains_key(header::PROXY_AUTHORIZATION));
        assert!(headers.contains_key(header::AUTHENTICATION_INFO));
    }
}
