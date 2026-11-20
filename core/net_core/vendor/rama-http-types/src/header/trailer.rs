//! Which fields a trailer section carries (RFC 9110 §6.5).
//!
//! An outgoing trailer section sends a field when its definition allows trailers
//! ([`HeaderName::is_allowed_in_trailers`]), or when the message's [`ForbiddenTrailers`]
//! allows it anyway, as a relay forwarding what it received does. A field that frames or
//! routes a message, or belongs to one connection, is never sent nor kept on receipt: HTTP/2
//! and HTTP/3 treat it as malformed, and over HTTP/1.1 it could smuggle framing past a
//! recipient that merges trailers into headers. HTTP/1.1, HTTP/2 and HTTP/3 share these
//! rules: their RFCs give no reason to differ.

use rama_core::extensions::Extension;

use crate::header::{self, HeaderName, hop_by_hop::CONNECTION_SPECIFIC_HEADERS};

/// Which fields a message's trailer section sends although their definitions do not allow
/// them in trailers.
///
/// Insert it into a message's extensions; without one, [`Self::DenyAll`] applies. A response
/// inherits it from its request, so a relay inserts it once into the request it forwards, and
/// a message can override what it inherits. Fields that [`is_never_a_trailer`] names are never
/// sent, whatever it allows.
#[derive(Debug, Clone, Default, Extension)]
#[extension(tags(http))]
pub enum ForbiddenTrailers {
    /// None of them: only fields whose definitions allow trailers are sent.
    #[default]
    DenyAll,
    /// All of them, as a relay forwarding what it received does.
    AllowAll,
    /// These only.
    AllowSome(Box<[HeaderName]>),
    /// All but these.
    DenySome(Box<[HeaderName]>),
}

impl ForbiddenTrailers {
    fn allows(&self, name: &HeaderName) -> bool {
        match self {
            Self::DenyAll => false,
            Self::AllowAll => true,
            Self::AllowSome(names) => names.contains(name),
            Self::DenySome(names) => !names.contains(name),
        }
    }
}

/// Whether an outgoing trailer section sends `name`, given what its message `allowed`; `None`
/// is [`ForbiddenTrailers::DenyAll`].
#[must_use]
pub fn is_sent_in_trailers(name: &HeaderName, allowed: Option<&ForbiddenTrailers>) -> bool {
    !is_never_a_trailer(name)
        && (name.is_allowed_in_trailers() || allowed.is_some_and(|allowed| allowed.allows(name)))
}

/// Whether `name` frames or routes a message, or belongs to one connection: no trailer section
/// carries it, sent or received.
#[must_use]
pub fn is_never_a_trailer(name: &HeaderName) -> bool {
    CONNECTION_SPECIFIC_HEADERS.contains(&name)
        || [header::TE, header::CONTENT_LENGTH, header::HOST].contains(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trailers_send_allowed_fields_and_opted_in_ones_but_never_framing() {
        let allow_some = ForbiddenTrailers::AllowSome([header::SET_COOKIE].into());
        let deny_some = ForbiddenTrailers::DenySome([header::SET_COOKIE].into());
        // name, none, DenyAll, AllowAll, AllowSome(set-cookie), DenySome(set-cookie)
        for (name, expected) in [
            ("x-checksum", [true; 5]),
            ("grpc-status", [true; 5]),
            ("etag", [true; 5]),
            ("set-cookie", [false, false, true, true, false]),
            ("cookie", [false, false, true, false, true]),
            ("content-type", [false, false, true, false, true]),
            ("content-length", [false; 5]),
            ("host", [false; 5]),
            ("te", [false; 5]),
            ("transfer-encoding", [false; 5]),
            ("connection", [false; 5]),
            ("keep-alive", [false; 5]),
            ("proxy-connection", [false; 5]),
            ("upgrade", [false; 5]),
        ] {
            let name = HeaderName::from_static(name);
            let sent = [
                None,
                Some(&ForbiddenTrailers::DenyAll),
                Some(&ForbiddenTrailers::AllowAll),
                Some(&allow_some),
                Some(&deny_some),
            ]
            .map(|allowed| is_sent_in_trailers(&name, allowed));
            assert_eq!(sent, expected, "{name}");
        }
    }
}
