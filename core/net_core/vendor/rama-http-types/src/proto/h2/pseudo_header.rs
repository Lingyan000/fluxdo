use rama_core::extensions::Extension;
use rama_core::telemetry::tracing;
use rama_utils::collections::smallvec::SmallVec;
use serde::{Deserialize, Serialize, de::Error};
use std::{fmt, str::FromStr};

#[derive(Debug, Clone, Copy, Eq, PartialEq, PartialOrd, Ord, Hash)]
#[repr(u8)]
/// Pseudo-header names shared by HTTP/2 and HTTP/3.
///
/// Used by wire decoders and by [`PseudoHeaderOrder`] to communicate the desired
/// HTTP/2 or HTTP/3 ordering. Protocol-specific message rules determine which names apply.
pub enum PseudoHeader {
    Method = 0b1000_0000,
    Scheme = 0b0100_0000,
    Authority = 0b0010_0000,
    Path = 0b0001_0000,
    Protocol = 0b0000_1000,
    Status = 0b0000_0100,
}

impl PseudoHeader {
    /// Parse an exact lowercase HTTP/2 or HTTP/3 wire name, including its colon.
    /// Unlike `FromStr`, this rejects whitespace, casing changes, and bare names.
    pub fn from_bytes(name: &[u8]) -> Result<Self, InvalidPseudoHeaderStr> {
        match name {
            b":method" => Ok(Self::Method),
            b":scheme" => Ok(Self::Scheme),
            b":authority" => Ok(Self::Authority),
            b":path" => Ok(Self::Path),
            b":protocol" => Ok(Self::Protocol),
            b":status" => Ok(Self::Status),
            _ => Err(InvalidPseudoHeaderStr),
        }
    }

    /// The exact HTTP/2 and HTTP/3 wire name.
    #[must_use]
    pub fn as_bytes(&self) -> &'static [u8] {
        self.as_str().as_bytes()
    }

    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Method => ":method",
            Self::Scheme => ":scheme",
            Self::Authority => ":authority",
            Self::Path => ":path",
            Self::Protocol => ":protocol",
            Self::Status => ":status",
        }
    }
}

impl fmt::Display for PseudoHeader {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

rama_utils::macros::error::static_str_error! {
    #[doc = "pseudo header string is invalid"]
    pub struct InvalidPseudoHeaderStr;
}

impl FromStr for PseudoHeader {
    type Err = InvalidPseudoHeaderStr;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let s = s.trim();
        let s = s.strip_prefix(':').unwrap_or(s);

        if s.eq_ignore_ascii_case("method") {
            Ok(Self::Method)
        } else if s.eq_ignore_ascii_case("scheme") {
            Ok(Self::Scheme)
        } else if s.eq_ignore_ascii_case("authority") {
            Ok(Self::Authority)
        } else if s.eq_ignore_ascii_case("path") {
            Ok(Self::Path)
        } else if s.eq_ignore_ascii_case("protocol") {
            Ok(Self::Protocol)
        } else if s.eq_ignore_ascii_case("status") {
            Ok(Self::Status)
        } else {
            Err(InvalidPseudoHeaderStr)
        }
    }
}

impl Serialize for PseudoHeader {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        self.as_str().serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for PseudoHeader {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let s = <std::borrow::Cow<'de, str>>::deserialize(deserializer)?;
        s.parse().map_err(D::Error::custom)
    }
}

const PSEUDO_HEADERS_STACK_SIZE: usize = 5;

#[derive(Clone, Debug, Default, PartialEq, Eq, Extension)]
#[extension(tags(http))]
pub struct PseudoHeaderOrder {
    headers: SmallVec<[PseudoHeader; PSEUDO_HEADERS_STACK_SIZE]>,
    mask: u8,
}

impl PseudoHeaderOrder {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&mut self, header: PseudoHeader) {
        if self.mask & (header as u8) == 0 {
            self.mask |= header as u8;
            self.headers.push(header);
        } else {
            tracing::trace!("ignore duplicate psuedo header: {header:?}")
        }
    }

    pub fn extend(&mut self, iter: impl IntoIterator<Item = PseudoHeader>) {
        for header in iter {
            self.push(header);
        }
    }

    /// Borrow the configured order without cloning its storage.
    #[must_use]
    pub fn as_slice(&self) -> &[PseudoHeader] {
        &self.headers
    }

    #[must_use]
    pub fn iter(&self) -> PseudoHeaderOrderIter {
        self.clone().into_iter()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.headers.is_empty()
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.headers.len()
    }
}

impl IntoIterator for PseudoHeaderOrder {
    type Item = PseudoHeader;
    type IntoIter = PseudoHeaderOrderIter;

    fn into_iter(self) -> Self::IntoIter {
        let Self { mut headers, .. } = self;
        headers.reverse();
        PseudoHeaderOrderIter { headers }
    }
}

impl FromIterator<PseudoHeader> for PseudoHeaderOrder {
    fn from_iter<T: IntoIterator<Item = PseudoHeader>>(iter: T) -> Self {
        let mut this = Self::new();
        for header in iter {
            this.push(header);
        }
        this
    }
}

impl<'a> FromIterator<&'a PseudoHeader> for PseudoHeaderOrder {
    fn from_iter<T: IntoIterator<Item = &'a PseudoHeader>>(iter: T) -> Self {
        let mut this = Self::new();
        for header in iter {
            this.push(*header);
        }
        this
    }
}

#[derive(Debug)]
/// Iterator over a copy of [`PseudoHeaderOrder`].
pub struct PseudoHeaderOrderIter {
    headers: SmallVec<[PseudoHeader; PSEUDO_HEADERS_STACK_SIZE]>,
}

impl Iterator for PseudoHeaderOrderIter {
    type Item = PseudoHeader;

    fn next(&mut self) -> Option<Self::Item> {
        self.headers.pop()
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        (0, Some(self.headers.len()))
    }

    fn count(self) -> usize
    where
        Self: Sized,
    {
        self.headers.len()
    }
}

impl Serialize for PseudoHeaderOrder {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        self.headers.serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for PseudoHeaderOrder {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let v = <Vec<PseudoHeader>>::deserialize(deserializer)?;
        Ok(v.into_iter().collect())
    }
}

/// Pseudo-header fields that must retain HPACK/QPACK's never-index requirement when forwarded.
///
/// Regular fields carry this information in `HeaderValue::is_sensitive`. Pseudo
/// fields live in the request/response parts instead, so their sensitivity travels
/// in this extension. It remains applicable when a middleware changes a value.
/// RFC 7541 §7.1.3 and RFC 9204 §7.1.3 require intermediaries to retain this
/// requirement, including when translating between HTTP/2 and HTTP/3.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Extension)]
#[extension(tags(http))]
pub struct PseudoHeaderSensitivity(u8);

impl PseudoHeaderSensitivity {
    /// Whether the pseudo-header must be encoded with the never-index flag.
    #[must_use]
    pub fn is_sensitive(self, header: PseudoHeader) -> bool {
        self.0 & header as u8 != 0
    }

    /// Set or clear the never-index requirement for a pseudo-header.
    pub fn set_sensitive(&mut self, header: PseudoHeader, sensitive: bool) {
        if sensitive {
            self.0 |= header as u8;
        } else {
            self.0 &= !(header as u8);
        }
    }
}

#[cfg(test)]
mod wire_tests {
    use super::*;

    #[test]
    fn wire_names_are_exact_while_configuration_remains_lenient() {
        for header in [
            PseudoHeader::Method,
            PseudoHeader::Scheme,
            PseudoHeader::Authority,
            PseudoHeader::Path,
            PseudoHeader::Protocol,
            PseudoHeader::Status,
        ] {
            assert_eq!(PseudoHeader::from_bytes(header.as_bytes()), Ok(header));
        }
        for name in [
            b"method".as_slice(),
            b":Method",
            b" :method",
            b":method ",
            b":unknown",
            b":",
            b"",
        ] {
            PseudoHeader::from_bytes(name).unwrap_err();
        }
        assert_eq!(" Method ".parse(), Ok(PseudoHeader::Method));
    }
}
