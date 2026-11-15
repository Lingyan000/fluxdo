use bytes::Bytes;

use std::convert::TryFrom;
use std::error::Error;
use std::hash::{Hash, Hasher};
use std::str::FromStr;
use std::{cmp, fmt, str};

use crate::header::name::HeaderName;
use rama_utils::collections::smallvec::SmallVec;

/// Represents an HTTP header field value.
///
/// In practice, HTTP header field values are usually valid ASCII. However, the
/// HTTP spec allows for a header value to contain opaque bytes as well. In this
/// case, the header field value is not able to be represented as a string.
///
/// To handle this, the `HeaderValue` is usable as a type and can be compared
/// with strings and implements `Debug`. A `to_str` fn is provided that returns
/// an `Err` if the header value contains non visible ascii characters.
///
/// Its human-readable Serde form is a string when possible and a byte sequence
/// otherwise. The sensitivity marker controls diagnostics and compression, not
/// wire data, and is intentionally not preserved by Serde.
#[derive(Clone)]
pub struct HeaderValue {
    inner: Bytes,
    is_sensitive: bool,
}

/// A possible error when converting a `HeaderValue` from a string or byte
/// slice.
pub struct InvalidHeaderValue {
    _priv: (),
}

/// A possible error when converting a `HeaderValue` to a string representation.
///
/// Header field values may contain opaque bytes, in which case it is not
/// possible to represent the value as a string.
#[derive(Debug)]
pub struct ToStrError {
    _priv: (),
}

impl HeaderValue {
    /// Convert a static string to a `HeaderValue`.
    ///
    /// This function will not perform any copying, however the string is
    /// checked to ensure that no invalid characters are present. Only visible
    /// ASCII characters (32-126) and horizontal tab are permitted.
    ///
    /// # Panics
    ///
    /// This function panics if the argument contains invalid header value
    /// characters.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::HeaderValue;
    /// let val = HeaderValue::from_static("hello");
    /// assert_eq!(val, "hello");
    /// ```
    #[inline]
    pub const fn from_static(src: &'static str) -> HeaderValue {
        let bytes = src.as_bytes();
        let mut i = 0;
        while i < bytes.len() {
            if !is_valid_ascii(bytes[i]) {
                panic!("HeaderValue::from_static with invalid bytes")
            }
            i += 1;
        }

        HeaderValue {
            inner: Bytes::from_static(bytes),
            is_sensitive: false,
        }
    }

    /// Attempt to convert a string to a `HeaderValue`.
    ///
    /// If the argument contains invalid header value characters, an error is
    /// returned. Only visible ASCII characters (32-126) and horizontal tab are
    /// permitted. Use
    /// `from_bytes` to create a `HeaderValue` that includes opaque octets
    /// (128-255).
    ///
    /// This function is intended to be replaced in the future by a `TryFrom`
    /// implementation once the trait is stabilized in std.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::HeaderValue;
    /// let val = HeaderValue::from_str("hello").unwrap();
    /// assert_eq!(val, "hello");
    /// ```
    ///
    /// An invalid value
    ///
    /// ```
    /// # use rama_http_types::header::HeaderValue;
    /// let val = HeaderValue::from_str("\n");
    /// assert!(val.is_err());
    /// ```
    #[inline]
    #[allow(clippy::should_implement_trait)]
    pub fn from_str(src: &str) -> Result<HeaderValue, InvalidHeaderValue> {
        HeaderValue::try_from_generic(
            src,
            |s| Bytes::copy_from_slice(s.as_bytes()),
            is_valid_ascii,
        )
    }

    /// Converts a HeaderName into a HeaderValue
    ///
    /// Since every valid HeaderName is a valid HeaderValue this is done infallibly.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::{HeaderValue, HeaderName};
    /// # use rama_http_types::header::ACCEPT;
    /// let val = HeaderValue::from_name(ACCEPT);
    /// assert_eq!(val, HeaderValue::from_bytes(b"accept").unwrap());
    /// ```
    #[inline]
    pub fn from_name(name: HeaderName) -> HeaderValue {
        name.into()
    }

    /// Attempt to convert a byte slice to a `HeaderValue`.
    ///
    /// If the argument contains invalid header value bytes, an error is
    /// returned. Only byte values between 32 and 255 (inclusive) are permitted,
    /// excluding byte 127 (DEL).
    ///
    /// This function is intended to be replaced in the future by a `TryFrom`
    /// implementation once the trait is stabilized in std.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::HeaderValue;
    /// let val = HeaderValue::from_bytes(b"hello\xfa").unwrap();
    /// assert_eq!(val, &b"hello\xfa"[..]);
    /// ```
    ///
    /// An invalid value
    ///
    /// ```
    /// # use rama_http_types::header::HeaderValue;
    /// let val = HeaderValue::from_bytes(b"\n");
    /// assert!(val.is_err());
    /// ```
    #[inline]
    pub fn from_bytes(src: &[u8]) -> Result<HeaderValue, InvalidHeaderValue> {
        HeaderValue::try_from_generic(src, Bytes::copy_from_slice, is_valid_ascii_or_opaque_byte)
    }

    /// Attempt to convert a `Bytes` buffer to a `HeaderValue`.
    ///
    /// This will try to prevent a copy if the type passed is the type used
    /// internally, and will copy the data if it is not.
    pub fn from_maybe_shared<T>(src: T) -> Result<HeaderValue, InvalidHeaderValue>
    where
        T: AsRef<[u8]> + 'static,
    {
        if_downcast_into!(T, Bytes, src, {
            return HeaderValue::from_shared(src);
        });

        HeaderValue::from_bytes(src.as_ref())
    }

    /// Convert a `Bytes` directly into a `HeaderValue` without validating.
    ///
    /// This function does NOT validate that illegal bytes are not contained
    /// within the buffer.
    ///
    /// ## Panics
    /// In a debug build this panics if `src` contains a byte that
    /// [`HeaderValue::from_bytes`] rejects.
    ///
    /// # Safety
    ///
    /// The caller must ensure that every byte of `src` is one that
    /// [`HeaderValue::from_bytes`] accepts: HTAB, or any byte in `0x20..=0xFF`
    /// other than DEL (`0x7F`). Obs-text (`0x80..=0xFF`) is allowed; the bytes
    /// need not be UTF-8.
    ///
    /// This is a semantic precondition, not a memory-safety one: no unsafe code
    /// relies on it, and breaking it cannot cause undefined behavior. The
    /// function is `unsafe` because this byte rule keeps CR, LF and NUL out of
    /// field values, so a caller that breaks it can inject or split field lines
    /// at any outgoing boundary that does not re-validate (see
    /// [`is_valid_h2_h3_field_value`]).
    pub unsafe fn from_maybe_shared_unchecked<T>(src: T) -> HeaderValue
    where
        T: AsRef<[u8]> + 'static,
    {
        if cfg!(debug_assertions) {
            match HeaderValue::from_maybe_shared(src) {
                Ok(val) => val,
                Err(_err) => {
                    panic!("HeaderValue::from_maybe_shared_unchecked() with invalid bytes");
                }
            }
        } else {
            if_downcast_into!(T, Bytes, src, {
                return HeaderValue {
                    inner: src,
                    is_sensitive: false,
                };
            });

            let src = Bytes::copy_from_slice(src.as_ref());
            HeaderValue {
                inner: src,
                is_sensitive: false,
            }
        }
    }

    /// Join `values` with `separator` into one exactly sized value, as field lines combine
    /// (RFC 9110 §5.3), or `None` without values.
    ///
    /// A lone value is shared rather than copied; the result is sensitive if any value is.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::HeaderValue;
    /// let lines = [HeaderValue::from_static("gzip"), HeaderValue::from_static("br")];
    /// let joined = HeaderValue::join(&lines, &HeaderValue::from_static(", ")).unwrap();
    /// assert_eq!(joined, "gzip, br");
    /// assert!(HeaderValue::join(&[], &HeaderValue::from_static(", ")).is_none());
    /// ```
    pub fn join<'a, I>(values: I, separator: &HeaderValue) -> Option<HeaderValue>
    where
        I: IntoIterator<Item = &'a HeaderValue>,
    {
        let values: SmallVec<[&HeaderValue; 4]> = values.into_iter().collect();
        let (first, rest) = values.split_first()?;
        if rest.is_empty() {
            return Some((*first).clone());
        }

        let len =
            values.iter().map(|value| value.len()).sum::<usize>() + rest.len() * separator.len();
        let mut joined = Vec::with_capacity(len);
        joined.extend_from_slice(first.as_bytes());
        for value in rest {
            joined.extend_from_slice(separator.as_bytes());
            joined.extend_from_slice(value.as_bytes());
        }

        // Validity is per byte, so valid values joined by a valid separator stay valid.
        Some(HeaderValue {
            inner: Bytes::from(joined),
            is_sensitive: values.iter().any(|value| value.is_sensitive()),
        })
    }

    fn from_shared(src: Bytes) -> Result<HeaderValue, InvalidHeaderValue> {
        HeaderValue::try_from_generic(src, std::convert::identity, is_valid_ascii_or_opaque_byte)
    }

    fn try_from_generic<T: AsRef<[u8]>, F: FnOnce(T) -> Bytes, V: Fn(u8) -> bool>(
        src: T,
        into: F,
        is_valid: V,
    ) -> Result<HeaderValue, InvalidHeaderValue> {
        // Avoid an early return so the loop vectorizes.
        let mut bad = false;
        for &b in src.as_ref() {
            bad |= !is_valid(b);
        }
        if bad {
            return Err(InvalidHeaderValue { _priv: () });
        }
        Ok(HeaderValue {
            inner: into(src),
            is_sensitive: false,
        })
    }

    /// Yields a `&str` slice if the `HeaderValue` only contains visible ASCII
    /// chars.
    ///
    /// This function will perform a scan of the header value, checking all the
    /// characters.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::HeaderValue;
    /// let val = HeaderValue::from_static("hello");
    /// assert_eq!(val.to_str().unwrap(), "hello");
    /// ```
    pub fn to_str(&self) -> Result<&str, ToStrError> {
        let bytes = self.as_ref();

        // Avoid an early return so the loop vectorizes.
        let mut bad = false;
        for &b in bytes {
            bad |= !is_valid_ascii(b);
        }
        if bad {
            return Err(ToStrError { _priv: () });
        }

        // SAFETY: `str::from_utf8_unchecked` requires valid UTF-8. The loop
        // above checked every byte of `bytes` with `is_valid_ascii`, so by its
        // safety-usable invariant `bytes` is ASCII, which is valid UTF-8.
        Ok(unsafe { str::from_utf8_unchecked(bytes) })
    }

    /// Returns the length of `self`.
    ///
    /// This length is in bytes.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::HeaderValue;
    /// let val = HeaderValue::from_static("hello");
    /// assert_eq!(val.len(), 5);
    /// ```
    #[inline]
    pub fn len(&self) -> usize {
        self.as_ref().len()
    }

    /// Returns true if the `HeaderValue` has a length of zero bytes.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::HeaderValue;
    /// let val = HeaderValue::from_static("");
    /// assert!(val.is_empty());
    ///
    /// let val = HeaderValue::from_static("hello");
    /// assert!(!val.is_empty());
    /// ```
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Converts a `HeaderValue` to a byte slice.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::HeaderValue;
    /// let val = HeaderValue::from_static("hello");
    /// assert_eq!(val.as_bytes(), b"hello");
    /// ```
    #[inline]
    pub fn as_bytes(&self) -> &[u8] {
        self.as_ref()
    }

    /// Whether the value starts or ends with SP or HTAB.
    ///
    /// HTTP/1 permits this optional whitespace around field content, whereas
    /// HTTP/2 and HTTP/3 require it to be removed before encoding. Safe
    /// constructors already reject NUL, CR and LF, so a typed value only needs
    /// this constant-time boundary check for those protocols.
    #[inline]
    pub fn has_outer_whitespace(&self) -> bool {
        has_outer_whitespace(self.as_bytes())
    }

    /// Mark that the header value represents sensitive information.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::HeaderValue;
    /// let mut val = HeaderValue::from_static("my secret");
    ///
    /// val.set_sensitive(true);
    /// assert!(val.is_sensitive());
    ///
    /// val.set_sensitive(false);
    /// assert!(!val.is_sensitive());
    /// ```
    #[inline]
    pub const fn set_sensitive(&mut self, val: bool) {
        self.is_sensitive = val;
    }

    /// Returns `true` if the value represents sensitive data.
    ///
    /// Sensitive data could represent passwords or other data that should not
    /// be stored on disk or in memory. By marking header values as sensitive,
    /// components using this crate can be instructed to treat them with special
    /// care for security reasons. For example, caches can avoid storing
    /// sensitive values, and HPACK encoders used by HTTP/2.0 implementations
    /// can choose not to compress them.
    ///
    /// Additionally, sensitive values will be masked by the `Debug`
    /// implementation of `HeaderValue`.
    ///
    /// Note that sensitivity is not factored into equality or ordering.
    ///
    /// # Examples
    ///
    /// ```
    /// # use rama_http_types::header::HeaderValue;
    /// let mut val = HeaderValue::from_static("my secret");
    ///
    /// val.set_sensitive(true);
    /// assert!(val.is_sensitive());
    ///
    /// val.set_sensitive(false);
    /// assert!(!val.is_sensitive());
    /// ```
    #[inline]
    pub fn is_sensitive(&self) -> bool {
        self.is_sensitive
    }
}

impl AsRef<[u8]> for HeaderValue {
    #[inline]
    fn as_ref(&self) -> &[u8] {
        self.inner.as_ref()
    }
}

impl fmt::Debug for HeaderValue {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.is_sensitive {
            f.write_str("Sensitive")
        } else {
            f.write_str("\"")?;
            // `bytes[from..i]` only holds bytes that passed `is_valid_ascii`:
            // `from` moves past every byte that fails the check below.
            let mut from = 0;
            let bytes = self.as_bytes();
            for (i, &b) in bytes.iter().enumerate() {
                if !is_valid_ascii(b) || b == b'"' {
                    if from != i {
                        // SAFETY: `str::from_utf8_unchecked` requires valid
                        // UTF-8. Every byte in `bytes[from..i]` passed
                        // `is_valid_ascii` (loop invariant above), so by its
                        // safety-usable invariant the slice is ASCII, which is
                        // valid UTF-8.
                        f.write_str(unsafe { str::from_utf8_unchecked(&bytes[from..i]) })?;
                    }
                    if b == b'"' {
                        f.write_str("\\\"")?;
                    } else {
                        write!(f, "\\x{:x}", b)?;
                    }
                    from = i + 1;
                }
            }

            // SAFETY: as above; the loop ended, so every byte in
            // `bytes[from..]` passed `is_valid_ascii` and, by its safety-usable
            // invariant, the slice is ASCII.
            f.write_str(unsafe { str::from_utf8_unchecked(&bytes[from..]) })?;
            f.write_str("\"")
        }
    }
}

impl From<HeaderName> for HeaderValue {
    #[inline]
    fn from(h: HeaderName) -> HeaderValue {
        HeaderValue {
            inner: h.into_bytes(),
            is_sensitive: false,
        }
    }
}

macro_rules! from_integers {
    ($($name:ident: $t:ident),*) => {$(
        impl From<$t> for HeaderValue {
            fn from(num: $t) -> HeaderValue {
                // An exact copy is one allocation.
                HeaderValue {
                    inner: Bytes::copy_from_slice(::itoa::Buffer::new().format(num).as_bytes()),
                    is_sensitive: false,
                }
            }
        }

        #[test]
        fn $name() {
            let n: $t = 55;
            let val = HeaderValue::from(n);
            assert_eq!(val, &n.to_string());

            let n = <$t>::MAX;
            let val = HeaderValue::from(n);
            assert_eq!(val, &n.to_string());
        }
    )*};
}

from_integers! {
    // u8 purposely left off... HeaderValue::from(b'3') could be confusing
    from_u16: u16,
    from_i16: i16,
    from_u32: u32,
    from_i32: i32,
    from_u64: u64,
    from_i64: i64
}

#[cfg(target_pointer_width = "16")]
from_integers! {
    from_usize: usize,
    from_isize: isize
}

#[cfg(target_pointer_width = "32")]
from_integers! {
    from_usize: usize,
    from_isize: isize
}

#[cfg(target_pointer_width = "64")]
from_integers! {
    from_usize: usize,
    from_isize: isize
}

#[cfg(test)]
mod from_header_name_tests {
    use super::*;
    use crate::header::map::HeaderMap;
    use crate::header::name;

    #[test]
    fn it_can_insert_header_name_as_header_value() {
        let mut map = HeaderMap::new();
        map.insert(name::UPGRADE, name::SEC_WEBSOCKET_PROTOCOL.into());
        map.insert(
            name::ACCEPT,
            name::HeaderName::from_bytes(b"hello-world").unwrap().into(),
        );

        assert_eq!(
            map.get(name::UPGRADE).unwrap(),
            HeaderValue::from_bytes(b"sec-websocket-protocol").unwrap()
        );

        assert_eq!(
            map.get(name::ACCEPT).unwrap(),
            HeaderValue::from_bytes(b"hello-world").unwrap()
        );
    }
}

impl FromStr for HeaderValue {
    type Err = InvalidHeaderValue;

    #[inline]
    fn from_str(s: &str) -> Result<HeaderValue, Self::Err> {
        HeaderValue::from_str(s)
    }
}

impl From<&HeaderValue> for HeaderValue {
    #[inline]
    fn from(t: &HeaderValue) -> Self {
        t.clone()
    }
}

impl From<HeaderValue> for Bytes {
    #[inline]
    fn from(value: HeaderValue) -> Self {
        value.inner
    }
}

impl TryFrom<&str> for HeaderValue {
    type Error = InvalidHeaderValue;

    #[inline]
    fn try_from(t: &str) -> Result<Self, Self::Error> {
        t.parse()
    }
}

impl TryFrom<&String> for HeaderValue {
    type Error = InvalidHeaderValue;
    #[inline]
    fn try_from(s: &String) -> Result<Self, Self::Error> {
        Self::from_str(s)
    }
}

impl TryFrom<&[u8]> for HeaderValue {
    type Error = InvalidHeaderValue;

    #[inline]
    fn try_from(t: &[u8]) -> Result<Self, Self::Error> {
        HeaderValue::from_bytes(t)
    }
}

impl TryFrom<String> for HeaderValue {
    type Error = InvalidHeaderValue;

    #[inline]
    fn try_from(t: String) -> Result<Self, Self::Error> {
        HeaderValue::try_from_generic(t, |s| s.into(), is_valid_ascii)
    }
}

impl TryFrom<Vec<u8>> for HeaderValue {
    type Error = InvalidHeaderValue;

    #[inline]
    fn try_from(vec: Vec<u8>) -> Result<Self, Self::Error> {
        HeaderValue::from_shared(vec.into())
    }
}

#[cfg(test)]
mod try_from_header_name_tests {
    use super::*;
    use crate::header::name;

    #[test]
    fn it_converts_using_try_from() {
        assert_eq!(
            HeaderValue::try_from(name::UPGRADE).unwrap(),
            HeaderValue::from_bytes(b"upgrade").unwrap()
        );
    }
}

/// Check raw field-value constraints shared by HTTP/2 and HTTP/3.
///
/// RFC 9113 Section 8.2.1 and RFC 9114 Section 4.2 reject NUL, CR, LF and
/// leading or trailing SP/HTAB. This also applies to pseudo-header values,
/// before their individual syntax is validated. Immediately after constructing
/// a value through a checked [`HeaderValue`] constructor, use
/// [`HeaderValue::has_outer_whitespace`] to avoid scanning the octets again.
/// Values supplied by other code can use the unchecked constructor, so validate
/// them fully at an outgoing protocol boundary.
#[inline]
pub fn is_valid_h2_h3_field_value(value: &[u8]) -> bool {
    !has_outer_whitespace(value) && memchr::memchr3(0, b'\r', b'\n', value).is_none()
}

#[inline]
fn has_outer_whitespace(value: &[u8]) -> bool {
    matches!(value.first(), Some(b' ' | b'\t')) || matches!(value.last(), Some(b' ' | b'\t'))
}

/// Visible ASCII (32-126) or horizontal tab.
///
/// # Safety-usable invariant
///
/// `is_valid_ascii(b)` implies `b < 0x80`, so a byte slice whose every byte
/// passes is ASCII and therefore valid UTF-8.
const fn is_valid_ascii(b: u8) -> bool {
    b >= 32 && b < 127 || b == b'\t'
}

// This validator is only for byte-oriented constructors. HTTP field values
// may contain opaque bytes, even though those bytes cannot be exposed by
// `HeaderValue::to_str`.
#[inline]
fn is_valid_ascii_or_opaque_byte(b: u8) -> bool {
    b >= 32 && b != 127 || b == b'\t'
}

impl fmt::Debug for InvalidHeaderValue {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.debug_struct("InvalidHeaderValue")
            // skip _priv noise
            .finish()
    }
}

impl fmt::Display for InvalidHeaderValue {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("failed to parse header value")
    }
}

impl Error for InvalidHeaderValue {}

impl fmt::Display for ToStrError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("failed to convert header to a str")
    }
}

impl Error for ToStrError {}

// ===== PartialEq / PartialOrd =====

impl Hash for HeaderValue {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.inner.hash(state);
    }
}

impl PartialEq for HeaderValue {
    #[inline]
    fn eq(&self, other: &HeaderValue) -> bool {
        self.inner == other.inner
    }
}

impl Eq for HeaderValue {}

impl PartialOrd for HeaderValue {
    #[inline]
    fn partial_cmp(&self, other: &HeaderValue) -> Option<cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for HeaderValue {
    #[inline]
    fn cmp(&self, other: &Self) -> cmp::Ordering {
        self.inner.cmp(&other.inner)
    }
}

impl PartialEq<str> for HeaderValue {
    #[inline]
    fn eq(&self, other: &str) -> bool {
        self.inner == other.as_bytes()
    }
}

impl PartialEq<[u8]> for HeaderValue {
    #[inline]
    fn eq(&self, other: &[u8]) -> bool {
        self.inner == other
    }
}

impl PartialOrd<str> for HeaderValue {
    #[inline]
    fn partial_cmp(&self, other: &str) -> Option<cmp::Ordering> {
        (*self.inner).partial_cmp(other.as_bytes())
    }
}

impl PartialOrd<[u8]> for HeaderValue {
    #[inline]
    fn partial_cmp(&self, other: &[u8]) -> Option<cmp::Ordering> {
        (*self.inner).partial_cmp(other)
    }
}

impl PartialEq<HeaderValue> for str {
    #[inline]
    fn eq(&self, other: &HeaderValue) -> bool {
        *other == *self
    }
}

impl PartialEq<HeaderValue> for [u8] {
    #[inline]
    fn eq(&self, other: &HeaderValue) -> bool {
        *other == *self
    }
}

impl PartialOrd<HeaderValue> for str {
    #[inline]
    fn partial_cmp(&self, other: &HeaderValue) -> Option<cmp::Ordering> {
        self.as_bytes().partial_cmp(other.as_bytes())
    }
}

impl PartialOrd<HeaderValue> for [u8] {
    #[inline]
    fn partial_cmp(&self, other: &HeaderValue) -> Option<cmp::Ordering> {
        self.partial_cmp(other.as_bytes())
    }
}

impl PartialEq<String> for HeaderValue {
    #[inline]
    fn eq(&self, other: &String) -> bool {
        *self == other[..]
    }
}

impl PartialOrd<String> for HeaderValue {
    #[inline]
    fn partial_cmp(&self, other: &String) -> Option<cmp::Ordering> {
        self.inner.partial_cmp(other.as_bytes())
    }
}

impl PartialEq<HeaderValue> for String {
    #[inline]
    fn eq(&self, other: &HeaderValue) -> bool {
        *other == *self
    }
}

impl PartialOrd<HeaderValue> for String {
    #[inline]
    fn partial_cmp(&self, other: &HeaderValue) -> Option<cmp::Ordering> {
        self.as_bytes().partial_cmp(other.as_bytes())
    }
}

impl PartialEq<HeaderValue> for &HeaderValue {
    #[inline]
    fn eq(&self, other: &HeaderValue) -> bool {
        **self == *other
    }
}

impl PartialOrd<HeaderValue> for &HeaderValue {
    #[inline]
    fn partial_cmp(&self, other: &HeaderValue) -> Option<cmp::Ordering> {
        (**self).partial_cmp(other)
    }
}

impl<T: ?Sized> PartialEq<&T> for HeaderValue
where
    HeaderValue: PartialEq<T>,
{
    #[inline]
    fn eq(&self, other: &&T) -> bool {
        *self == **other
    }
}

impl<T: ?Sized> PartialOrd<&T> for HeaderValue
where
    HeaderValue: PartialOrd<T>,
{
    #[inline]
    fn partial_cmp(&self, other: &&T) -> Option<cmp::Ordering> {
        self.partial_cmp(*other)
    }
}

impl serde::Serialize for HeaderValue {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        match self.to_str() {
            Ok(value) if serializer.is_human_readable() => serializer.serialize_str(value),
            _ => serializer.serialize_bytes(self.as_bytes()),
        }
    }
}

/// Human-readable formats must support `deserialize_any` because textual
/// values deserialize from strings while opaque values deserialize from byte
/// sequences. Formats that represent `serialize_bytes` as text cannot retain
/// that distinction and are not suitable for lossless opaque header values.
impl<'de> serde::Deserialize<'de> for HeaderValue {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        struct HeaderValueVisitor;

        impl<'de> serde::de::Visitor<'de> for HeaderValueVisitor {
            type Value = HeaderValue;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a valid HTTP header value as text or bytes")
            }

            fn visit_borrowed_str<E>(self, value: &str) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                HeaderValue::from_str(value).map_err(E::custom)
            }

            fn visit_str<E>(self, value: &str) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                self.visit_borrowed_str(value)
            }

            fn visit_string<E>(self, value: String) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                HeaderValue::try_from(value).map_err(E::custom)
            }

            fn visit_borrowed_bytes<E>(self, value: &[u8]) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                HeaderValue::from_bytes(value).map_err(E::custom)
            }

            fn visit_bytes<E>(self, value: &[u8]) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                self.visit_borrowed_bytes(value)
            }

            fn visit_byte_buf<E>(self, value: Vec<u8>) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                HeaderValue::from_maybe_shared(value).map_err(E::custom)
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: serde::de::SeqAccess<'de>,
            {
                let mut bytes = Vec::new();
                while let Some(byte) = seq.next_element()? {
                    bytes.push(byte);
                }
                self.visit_byte_buf(bytes)
            }
        }

        if deserializer.is_human_readable() {
            deserializer.deserialize_any(HeaderValueVisitor)
        } else {
            deserializer.deserialize_bytes(HeaderValueVisitor)
        }
    }
}

impl PartialEq<HeaderValue> for &str {
    #[inline]
    fn eq(&self, other: &HeaderValue) -> bool {
        *other == *self
    }
}

impl PartialOrd<HeaderValue> for &str {
    #[inline]
    fn partial_cmp(&self, other: &HeaderValue) -> Option<cmp::Ordering> {
        self.as_bytes().partial_cmp(other.as_bytes())
    }
}

#[test]
fn test_try_from() {
    HeaderValue::try_from(vec![127]).unwrap_err();
}

#[test]
fn test_join_exact_shared_and_sensitive() {
    let separator = HeaderValue::from_static("; ");
    let mut secret = HeaderValue::from_bytes(b"a=1").unwrap();
    secret.set_sensitive(true);

    let lone = HeaderValue::join([&secret], &separator).unwrap();
    assert_eq!(lone.as_bytes().as_ptr(), secret.as_bytes().as_ptr());
    assert!(lone.is_sensitive());

    let joined =
        HeaderValue::join([&HeaderValue::from_static("b=2"), &secret], &separator).unwrap();
    assert_eq!(joined, "b=2; a=1");
    assert!(joined.is_sensitive());
}

#[test]
fn test_string_constructors_reject_non_ascii() {
    let value = String::from("hello \u{e9}");

    assert!(HeaderValue::from_str(&value).is_err());
    assert!(HeaderValue::try_from(value.as_str()).is_err());
    assert!(HeaderValue::try_from(&value).is_err());
    assert!(HeaderValue::try_from(value).is_err());
}

#[test]
fn test_byte_constructors_allow_opaque_bytes_but_reject_del() {
    assert!(HeaderValue::from_bytes(b"hello\xff").is_ok());
    assert!(HeaderValue::try_from(&b"hello\xff"[..]).is_ok());
    assert!(HeaderValue::try_from(b"hello\xff".to_vec()).is_ok());

    assert!(HeaderValue::from_bytes(b"hello\x7f").is_err());
}

#[test]
fn test_string_and_byte_constructors_allow_horizontal_tab() {
    assert!(HeaderValue::from_str("hello\tworld").is_ok());
    assert!(HeaderValue::from_bytes(b"hello\tworld").is_ok());
}

#[test]
#[should_panic(expected = "HeaderValue::from_static with invalid bytes")]
fn test_static_constructor_rejects_non_ascii() {
    HeaderValue::from_static("hello \u{e9}");
}

#[test]
fn test_debug() {
    let cases = &[
        ("hello", "\"hello\""),
        ("hello \"world\"", "\"hello \\\"world\\\"\""),
        ("\u{7FFF}hello", "\"\\xe7\\xbf\\xbfhello\""),
    ];

    for &(value, expected) in cases {
        let val = HeaderValue::from_bytes(value.as_bytes()).unwrap();
        let actual = format!("{:?}", val);
        assert_eq!(expected, actual);
    }

    let mut sensitive = HeaderValue::from_static("password");
    sensitive.set_sensitive(true);
    assert_eq!("Sensitive", format!("{:?}", sensitive));
}

#[test]
fn h2_h3_value_constraints_cover_every_octet_and_position() {
    assert!(is_valid_h2_h3_field_value(b""));
    for length in [1, 3, 64, 257] {
        for position in 0..length {
            for byte in 0..=u8::MAX {
                let mut value = vec![b'a'; length];
                value[position] = byte;
                let forbidden = matches!(byte, 0 | b'\r' | b'\n')
                    || ((position == 0 || position == length - 1) && matches!(byte, b' ' | b'\t'));
                assert_eq!(is_valid_h2_h3_field_value(&value), !forbidden);
                if let Ok(typed) = HeaderValue::from_bytes(&value) {
                    assert_eq!(typed.has_outer_whitespace(), forbidden);
                }
            }
        }
    }
}

#[test]
fn quoted_field_values_remain_valid() {
    let value = HeaderValue::from_static("\"quoted field value\"");
    assert!(!value.has_outer_whitespace());
    assert!(is_valid_h2_h3_field_value(value.as_bytes()));
}
