//! `Matcher<Request>` impls for `rama-net`'s socket matchers.
//!
//! The matcher *types* live in `rama_net::stream::matcher`; these blocks add
//! the HTTP-`Request` matching surface now that `Request` is local to
//! `rama-http-types`. Each impl pulls the peer [`SocketAddress`] from the
//! request's [`SocketInfo`] extension and delegates to the matcher's existing
//! [`Matcher<Socket>`] impl via a tiny [`Socket`] adapter — this keeps the
//! matchers' internals private to `rama-net` (orphan-rule safe), and preserves
//! the original behavior: when no [`SocketInfo`] is present the matcher's own
//! `optional` fallback is exercised (the adapter's `peer_addr` errors).
//!
//! [`Matcher<Socket>`]: rama_core::matcher::Matcher
//! [`SocketAddress`]: rama_net::address::SocketAddress
//! [`SocketInfo`]: rama_net::stream::SocketInfo
//! [`Socket`]: rama_net::stream::Socket

use rama_core::extensions::{Extensions, ExtensionsRef};
use rama_core::matcher::Matcher;
use rama_net::address::SocketAddress;
use rama_net::stream::matcher::{
    IpNetMatcher, LoopbackMatcher, PortMatcher, PrivateIpNetMatcher, SocketAddressMatcher,
    SocketMatcher,
};
use rama_net::stream::{Socket, SocketInfo};

use crate::Request;

/// Adapter that exposes a request's optional peer [`SocketAddress`] as a
/// [`Socket`]. An absent peer addr makes `peer_addr` error, mirroring the
/// "no socket info" path so the socket matchers' `optional` fallback applies.
struct PeerSocket(Option<SocketAddress>);

impl Socket for PeerSocket {
    #[inline]
    fn local_addr(&self) -> std::io::Result<SocketAddress> {
        Err(std::io::Error::from(std::io::ErrorKind::AddrNotAvailable))
    }

    #[inline]
    fn peer_addr(&self) -> std::io::Result<SocketAddress> {
        self.0
            .ok_or_else(|| std::io::Error::from(std::io::ErrorKind::AddrNotAvailable))
    }
}

macro_rules! impl_request_matcher {
    ($matcher:ty) => {
        impl<Body> Matcher<Request<Body>> for $matcher {
            fn matches(&self, _ext: Option<&Extensions>, req: &Request<Body>) -> bool {
                let peer = SocketInfo::ingress(req.extensions()).map(SocketInfo::peer_addr);
                self.matches(None, &PeerSocket(peer))
            }
        }
    };
}

impl_request_matcher!(SocketAddressMatcher);
impl_request_matcher!(IpNetMatcher);
impl_request_matcher!(LoopbackMatcher);
impl_request_matcher!(PortMatcher);
impl_request_matcher!(PrivateIpNetMatcher);

/// The composite [`SocketMatcher`] delegates to the leaf impls above (and any
/// custom/nested matchers) through its public `matches_input` helper, so its
/// `All`/`Any`/`Custom`/negation logic applies to an HTTP `Request` too.
impl<Body: 'static> Matcher<Request<Body>> for SocketMatcher<Request<Body>> {
    fn matches(&self, ext: Option<&Extensions>, req: &Request<Body>) -> bool {
        self.matches_input(ext, req)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rama_core::extensions::{Egress, Ingress};

    #[test]
    fn requests_match_on_their_ingress_peer() {
        let socket = |peer: &str| {
            let extensions = Extensions::new();
            extensions.insert(SocketInfo::new(None, peer.parse().unwrap()));
            extensions
        };
        for (client, upstream, loopback) in [
            ("127.0.0.1:1000", "198.51.100.7:443", true),
            ("198.51.100.7:1000", "127.0.0.1:443", false),
        ] {
            let req = Request::new(());
            req.extensions().insert(Ingress(socket(client)));
            req.extensions().insert(Egress(socket(upstream)));
            assert_eq!(
                LoopbackMatcher::new().matches(None, &req),
                loopback,
                "{client} via {upstream}"
            );
        }
    }
}
