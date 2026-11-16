//! HTTP CONNECT request-header policy for an outbound proxy hop.

use crate::{
    HeaderName,
    header::{CONTENT_LENGTH, HOST, PROXY_AUTHORIZATION, TRANSFER_ENCODING},
};

/// Return whether Rama owns this field while constructing an HTTP proxy
/// CONNECT request.
///
/// `Host` and message framing are derived from the CONNECT request itself.
/// `Proxy-Authorization` is derived from the selected proxy route. Allowing a
/// caller-provided custom header to replace any of them would make the
/// handshake ambiguous or address credentials to the wrong proxy hop.
#[must_use]
pub fn is_managed_proxy_connect_request_header(name: &HeaderName) -> bool {
    name == PROXY_AUTHORIZATION
        || name == HOST
        || name == CONTENT_LENGTH
        || name == TRANSFER_ENCODING
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identifies_headers_owned_by_connect_builder() {
        for name in [
            &PROXY_AUTHORIZATION,
            &HOST,
            &CONTENT_LENGTH,
            &TRANSFER_ENCODING,
        ] {
            assert!(is_managed_proxy_connect_request_header(name));
        }
        assert!(!is_managed_proxy_connect_request_header(
            &crate::header::USER_AGENT
        ));
    }
}
