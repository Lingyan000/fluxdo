use super::{DecoderError, NeedMore};
use crate::proto::{ext::Protocol, h2::PseudoHeader};
use crate::{HeaderName, HeaderValue, Method, StatusCode};

use rama_core::bytes::Bytes;
use std::fmt;

/// HTTP/2 Header
#[derive(Debug, Clone, Eq, PartialEq)]
pub enum Header<T = HeaderName> {
    Field {
        name: T,
        value: HeaderValue,
    },
    // Authority/Scheme/Path stay as raw `BytesStr`: HPACK needs the exact wire
    // bytes for dynamic-table sizing, re-encoding and equality. Typed parsing
    // (into `rama_net` URI components) happens at the h2 request-decode layer.
    Authority(BytesStr),
    Method(Method),
    Scheme(BytesStr),
    Path(BytesStr),
    Protocol(Protocol),
    Status(StatusCode),
    /// A pseudo-header carrying the HPACK never-indexed requirement.
    NeverIndexed(NeverIndexedPseudo),
}

/// Typed pseudo-header value that must be encoded as a never-indexed literal.
///
/// Values remain inline: marking an existing field does not allocate or copy it.
#[derive(Debug, Clone, Eq, PartialEq)]
pub enum NeverIndexedPseudo {
    Authority(BytesStr),
    Method(Method),
    Scheme(BytesStr),
    Path(BytesStr),
    Protocol(Protocol),
    Status(StatusCode),
}

impl NeverIndexedPseudo {
    pub fn name(&self) -> PseudoHeader {
        match self {
            Self::Authority(..) => PseudoHeader::Authority,
            Self::Method(..) => PseudoHeader::Method,
            Self::Scheme(..) => PseudoHeader::Scheme,
            Self::Path(..) => PseudoHeader::Path,
            Self::Protocol(..) => PseudoHeader::Protocol,
            Self::Status(..) => PseudoHeader::Status,
        }
    }

    fn value_slice(&self) -> &[u8] {
        match self {
            Self::Authority(value) | Self::Scheme(value) | Self::Path(value) => value.as_ref(),
            Self::Method(value) => value.as_str().as_bytes(),
            Self::Protocol(value) => value.as_ref(),
            Self::Status(value) => value.as_str().as_bytes(),
        }
    }

    pub fn into_header<T>(self) -> Header<T> {
        match self {
            Self::Authority(value) => Header::Authority(value),
            Self::Method(value) => Header::Method(value),
            Self::Scheme(value) => Header::Scheme(value),
            Self::Path(value) => Header::Path(value),
            Self::Protocol(value) => Header::Protocol(value),
            Self::Status(value) => Header::Status(value),
        }
    }
}

impl<T> Header<T> {
    /// Set the HPACK never-indexed requirement without copying the field value.
    #[must_use]
    pub fn with_sensitive(self, sensitive: bool) -> Self {
        if !sensitive {
            return match self {
                Self::NeverIndexed(value) => value.into_header(),
                Self::Field { name, mut value } => {
                    value.set_sensitive(false);
                    Self::Field { name, value }
                }
                header => header,
            };
        }

        let value = match self {
            Self::Field { name, mut value } => {
                value.set_sensitive(true);
                return Self::Field { name, value };
            }
            Self::NeverIndexed(value) => return Self::NeverIndexed(value),
            Self::Authority(value) => NeverIndexedPseudo::Authority(value),
            Self::Method(value) => NeverIndexedPseudo::Method(value),
            Self::Scheme(value) => NeverIndexedPseudo::Scheme(value),
            Self::Path(value) => NeverIndexedPseudo::Path(value),
            Self::Protocol(value) => NeverIndexedPseudo::Protocol(value),
            Self::Status(value) => NeverIndexedPseudo::Status(value),
        };
        Self::NeverIndexed(value)
    }
}

/// The header field name
#[derive(Debug, Clone, Eq, PartialEq, Hash)]
pub enum Name<'a> {
    Field(&'a HeaderName),
    Authority,
    Method,
    Scheme,
    Path,
    Protocol,
    Status,
}

#[doc(hidden)]
#[derive(Clone, Eq, PartialEq, Default)]
pub struct BytesStr(
    // Safety invariant: the bytes are valid UTF-8.
    Bytes,
);

fn len(name: &HeaderName, value: &HeaderValue) -> usize {
    let n: &str = name.as_ref();
    32 + n.len() + value.len()
}

impl Header<Option<HeaderName>> {
    pub fn reify(self) -> Result<Header, HeaderValue> {
        Ok(match self {
            Self::Field {
                name: Some(n),
                value,
            } => Header::Field { name: n, value },
            Self::Field { name: None, value } => return Err(value),
            Self::Authority(v) => Header::Authority(v),
            Self::Method(v) => Header::Method(v),
            Self::Scheme(v) => Header::Scheme(v),
            Self::Path(v) => Header::Path(v),
            Self::Protocol(v) => Header::Protocol(v),
            Self::Status(v) => Header::Status(v),
            Self::NeverIndexed(v) => Header::NeverIndexed(v),
        })
    }
}

impl Header {
    pub fn try_new(name: &Bytes, value: Bytes) -> Result<Self, DecoderError> {
        if name.is_empty() {
            return Err(DecoderError::NeedMore(NeedMore::UnexpectedEndOfStream));
        }
        if name[0] == b':' {
            match PseudoHeader::from_bytes(name)
                .map_err(|_error| DecoderError::InvalidPseudoheader)?
            {
                PseudoHeader::Authority => {
                    let value = BytesStr::try_from(value)?;
                    Ok(Self::Authority(value))
                }
                PseudoHeader::Method => {
                    let method = Method::from_bytes(&value)?;
                    Ok(Self::Method(method))
                }
                PseudoHeader::Scheme => {
                    let value = BytesStr::try_from(value)?;
                    Ok(Self::Scheme(value))
                }
                PseudoHeader::Path => {
                    let value = BytesStr::try_from(value)?;
                    Ok(Self::Path(value))
                }
                PseudoHeader::Protocol => {
                    let value = Protocol::try_from(value)?;
                    Ok(Self::Protocol(value))
                }
                PseudoHeader::Status => {
                    let status = StatusCode::from_bytes(&value)?;
                    Ok(Self::Status(status))
                }
            }
        } else {
            // HTTP/2 requires lower case header names
            let name = HeaderName::from_lowercase(name)?;
            let value = HeaderValue::from_maybe_shared(value)?;

            Ok(Self::field(name, value))
        }
    }

    /// This header in bytes of its own, for keeping past the block it was decoded from. Field
    /// names and values are copied when decoded; pseudo-header values may share that block.
    pub(crate) fn detached(&self) -> Self {
        match self {
            Self::Authority(value) => Self::Authority(value.detached()),
            Self::Scheme(value) => Self::Scheme(value.detached()),
            Self::Path(value) => Self::Path(value.detached()),
            Self::Protocol(value) => Self::Protocol(value.detached()),
            Self::NeverIndexed(value) => Self::NeverIndexed(match value {
                NeverIndexedPseudo::Authority(value) => {
                    NeverIndexedPseudo::Authority(value.detached())
                }
                NeverIndexedPseudo::Scheme(value) => NeverIndexedPseudo::Scheme(value.detached()),
                NeverIndexedPseudo::Path(value) => NeverIndexedPseudo::Path(value.detached()),
                NeverIndexedPseudo::Protocol(value) => {
                    NeverIndexedPseudo::Protocol(value.detached())
                }
                other => other.clone(),
            }),
            other => other.clone(),
        }
    }

    fn field(name: HeaderName, mut value: HeaderValue) -> Self {
        if name.is_sensitive() {
            value.set_sensitive(true);
        }
        Self::Field { name, value }
    }

    #[expect(clippy::len_without_is_empty)]
    pub fn len(&self) -> usize {
        match *self {
            Self::Field {
                ref name,
                ref value,
            } => len(name, value),
            Self::Authority(ref v) => 32 + 10 + v.len(),
            Self::Method(ref v) => 32 + 7 + v.as_ref().len(),
            Self::Scheme(ref v) => 32 + 7 + v.len(),
            Self::Path(ref v) => 32 + 5 + v.len(),
            Self::Protocol(ref v) => 32 + 9 + v.as_str().len(),
            Self::Status(_) => 32 + 7 + 3,
            Self::NeverIndexed(ref value) => {
                32 + value.name().as_bytes().len() + value.value_slice().len()
            }
        }
    }

    /// Returns the header name
    pub fn name(&self) -> Name<'_> {
        match *self {
            Self::Field { ref name, .. } => Name::Field(name),
            Self::Authority(..) => Name::Authority,
            Self::Method(..) => Name::Method,
            Self::Scheme(..) => Name::Scheme,
            Self::Path(..) => Name::Path,
            Self::Protocol(..) => Name::Protocol,
            Self::Status(..) => Name::Status,
            Self::NeverIndexed(ref value) => match value.name() {
                PseudoHeader::Authority => Name::Authority,
                PseudoHeader::Method => Name::Method,
                PseudoHeader::Scheme => Name::Scheme,
                PseudoHeader::Path => Name::Path,
                PseudoHeader::Protocol => Name::Protocol,
                PseudoHeader::Status => Name::Status,
            },
        }
    }

    pub fn value_slice(&self) -> &[u8] {
        match *self {
            Self::Field { ref value, .. } => value.as_ref(),
            Self::Authority(ref v) | Self::Scheme(ref v) | Self::Path(ref v) => v.as_ref(),
            Self::Method(ref v) => v.as_ref().as_ref(),
            Self::Protocol(ref v) => v.as_ref(),
            Self::Status(ref v) => v.as_str().as_ref(),
            Self::NeverIndexed(ref value) => value.value_slice(),
        }
    }

    pub fn value_eq(&self, other: &Self) -> bool {
        if matches!(other, Self::NeverIndexed(_)) {
            return self.name() == other.name() && self.value_slice() == other.value_slice();
        }
        match *self {
            Self::Field { ref value, .. } => {
                let a = value;
                match *other {
                    Self::Field { ref value, .. } => a == value,
                    _ => false,
                }
            }
            Self::Authority(ref a) => match *other {
                Self::Authority(ref b) => a == b,
                _ => false,
            },
            Self::Method(ref a) => match *other {
                Self::Method(ref b) => a == b,
                _ => false,
            },
            Self::Scheme(ref a) => match *other {
                Self::Scheme(ref b) => a == b,
                _ => false,
            },
            Self::Path(ref a) => match *other {
                Self::Path(ref b) => a == b,
                _ => false,
            },
            Self::Protocol(ref a) => match *other {
                Self::Protocol(ref b) => a == b,
                _ => false,
            },
            Self::Status(ref a) => match *other {
                Self::Status(ref b) => a == b,
                _ => false,
            },
            Self::NeverIndexed(_) => {
                self.name() == other.name() && self.value_slice() == other.value_slice()
            }
        }
    }

    pub fn is_sensitive(&self) -> bool {
        match *self {
            Self::Field { ref value, .. } => value.is_sensitive(),
            Self::NeverIndexed(_) => true,
            _ => false,
        }
    }

    pub fn skip_value_index(&self) -> bool {
        use crate::header;

        match *self {
            Self::Field { ref name, .. } => {
                name.is_sensitive()
                    || matches!(
                        name.standard(),
                        Some(
                            header::StandardHeader::Age
                                | header::StandardHeader::ContentLength
                                | header::StandardHeader::Etag
                                | header::StandardHeader::IfModifiedSince
                                | header::StandardHeader::IfNoneMatch
                                | header::StandardHeader::Location
                        )
                    )
            }
            Self::Path(..) => true,
            _ => false,
        }
    }
}

// Mostly for tests
impl From<Header> for Header<Option<HeaderName>> {
    fn from(src: Header) -> Self {
        match src {
            Header::Field { name, value } => Self::Field {
                name: Some(name),
                value,
            },
            Header::Authority(v) => Self::Authority(v),
            Header::Method(v) => Self::Method(v),
            Header::Scheme(v) => Self::Scheme(v),
            Header::Path(v) => Self::Path(v),
            Header::Protocol(v) => Self::Protocol(v),
            Header::Status(v) => Self::Status(v),
            Header::NeverIndexed(v) => Self::NeverIndexed(v),
        }
    }
}

impl Name<'_> {
    pub fn into_entry(self, value: Bytes) -> Result<Header, DecoderError> {
        match self {
            Name::Field(name) => Ok(Header::field(
                name.clone(),
                HeaderValue::from_maybe_shared(value)?,
            )),
            Name::Authority => Ok(Header::Authority(BytesStr::try_from(value)?)),
            Name::Method => Ok(Header::Method(Method::from_bytes(&value)?)),
            Name::Scheme => Ok(Header::Scheme(BytesStr::try_from(value)?)),
            Name::Path => Ok(Header::Path(BytesStr::try_from(value)?)),
            Name::Protocol => Ok(Header::Protocol(Protocol::try_from(value)?)),
            Name::Status => {
                match StatusCode::from_bytes(&value) {
                    Ok(status) => Ok(Header::Status(status)),
                    // TODO: better error handling
                    Err(_) => Err(DecoderError::InvalidStatusCode),
                }
            }
        }
    }

    pub fn as_slice(&self) -> &[u8] {
        match *self {
            Name::Field(ref name) => name.as_ref(),
            Name::Authority => b":authority",
            Name::Method => b":method",
            Name::Scheme => b":scheme",
            Name::Path => b":path",
            Name::Protocol => b":protocol",
            Name::Status => b":status",
        }
    }
}

// ===== impl BytesStr =====

impl BytesStr {
    pub(crate) const fn from_static(value: &'static str) -> Self {
        Self(Bytes::from_static(value.as_bytes()))
    }

    pub(crate) fn from(value: &str) -> Self {
        Self(Bytes::copy_from_slice(value.as_bytes()))
    }

    #[doc(hidden)]
    pub fn try_from(bytes: Bytes) -> Result<Self, std::str::Utf8Error> {
        std::str::from_utf8(bytes.as_ref())?;
        Ok(Self(bytes))
    }

    /// The same text in bytes of its own, not shared with whatever it was decoded from.
    pub(crate) fn detached(&self) -> Self {
        Self(Bytes::copy_from_slice(self.0.as_ref()))
    }

    pub(crate) fn as_str(&self) -> &str {
        // SAFETY: `str::from_utf8_unchecked` requires valid UTF-8, which the
        // `BytesStr` safety invariant gives.
        unsafe { std::str::from_utf8_unchecked(self.0.as_ref()) }
    }
}

impl std::ops::Deref for BytesStr {
    type Target = str;
    fn deref(&self) -> &str {
        self.as_str()
    }
}

impl AsRef<[u8]> for BytesStr {
    fn as_ref(&self) -> &[u8] {
        self.0.as_ref()
    }
}

impl fmt::Debug for BytesStr {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn marks_literal_sensitive_fields() {
        let header = Header::try_new(
            &Bytes::from_static(b"authorization"),
            Bytes::from_static(b"Bearer secret"),
        )
        .unwrap();
        assert!(header.is_sensitive());

        let name = HeaderName::from_static("cookie");
        let header = Name::Field(&name)
            .into_entry(Bytes::from_static(b"session=secret"))
            .unwrap();
        assert!(header.is_sensitive());
    }
}
