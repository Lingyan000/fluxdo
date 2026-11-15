use rama_core::{bytes::BytesMut, telemetry::tracing::debug};
use rama_http_types::{
    HeaderMap, HeaderName, HeaderValue, Method, StatusCode,
    header::{CONNECTION, CONTENT_LENGTH, OccupiedEntry, TE, TRANSFER_ENCODING, ValueIter},
};
use rama_utils::{bytes::trim_ows, collections::smallvec::SmallVec};

pub(super) type ConnectionHeaderNames = SmallVec<[HeaderName; 4]>;

/// What a response's `Content-Length` may carry, from its request method and status
/// (RFC 9110 §8.6, §9.3.2, §9.3.6, §15.4.5): one rule for every HTTP version.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ResponseLength {
    /// 1xx, 204 and a 2xx to CONNECT: never sent, so a field the response sets is dropped.
    Forbidden,
    /// 304: only a field the response sets, as it describes the selected representation.
    ExplicitOnly,
    /// HEAD: a field the response sets or a known non-zero length, never an invented `0`.
    NonZero,
    /// Any other response: a field the response sets, or the body's known length.
    Known,
}

impl ResponseLength {
    pub(crate) fn of(method: Option<&Method>, status: StatusCode) -> Self {
        if status.is_informational()
            || status == StatusCode::NO_CONTENT
            || is_tunnel_response(method, status)
        {
            Self::Forbidden
        } else if status == StatusCode::NOT_MODIFIED {
            Self::ExplicitOnly
        } else if method == Some(&Method::HEAD) {
            Self::NonZero
        } else {
            Self::Known
        }
    }

    /// The length to add when the response sets none, from the body's exact length.
    pub(crate) fn implied(self, body_len: Option<u64>) -> Option<u64> {
        match self {
            Self::Forbidden | Self::ExplicitOnly => None,
            Self::NonZero => body_len.filter(|len| *len != 0),
            Self::Known => body_len,
        }
    }
}

/// Whether a response is a 2xx to CONNECT, after which the connection is a tunnel.
pub(crate) fn is_tunnel_response(method: Option<&Method>, status: StatusCode) -> bool {
    method == Some(&Method::CONNECT) && status.is_success()
}

pub(super) fn connection_keep_alive(value: &HeaderValue) -> bool {
    connection_has(value, "keep-alive")
}

pub(super) fn connection_close(value: &HeaderValue) -> bool {
    connection_has(value, "close")
}

// Returns true if any `Connection` header field carries a `close` token.
// A message may have more than one `Connection` header line, so all of them
// must be inspected (`get`/`connection_close` alone only sees the first).
pub(super) fn connection_any_close(headers: &HeaderMap) -> bool {
    headers.get_all(CONNECTION).iter().any(connection_close)
}

pub(super) fn connection_any_keep_alive(headers: &HeaderMap) -> bool {
    headers
        .get_all(CONNECTION)
        .iter()
        .any(connection_keep_alive)
}

/// Makes `Connection` carry `close` instead of any `keep-alive`, keeping the
/// other options as they nominate the message's hop-by-hop fields.
pub(super) fn connection_set_close(headers: &mut HeaderMap) {
    const CLOSE: &str = "close";
    const KEEP_ALIVE: &str = "keep-alive";

    if !connection_any_keep_alive(headers) {
        if !connection_any_close(headers) {
            headers.append(CONNECTION, HeaderValue::from_static(CLOSE));
        }
        return;
    }

    let kept = || {
        headers
            .get_all(CONNECTION)
            .iter()
            .flat_map(|value| value.as_bytes().split(|byte| *byte == b','))
            .map(trim_ows)
            .filter(|option| {
                !option.is_empty()
                    && !option.eq_ignore_ascii_case(CLOSE.as_bytes())
                    && !option.eq_ignore_ascii_case(KEEP_ALIVE.as_bytes())
            })
    };
    // Exactly sized, so the line moves into the value without a copy or slack.
    let len = kept().map(|option| option.len() + 2).sum::<usize>() + CLOSE.len();
    let mut line = BytesMut::with_capacity(len);
    for option in kept() {
        line.extend_from_slice(option);
        line.extend_from_slice(b", ");
    }
    line.extend_from_slice(CLOSE.as_bytes());
    let value = HeaderValue::from_maybe_shared(line.freeze())
        .unwrap_or_else(|_| HeaderValue::from_static(CLOSE));
    headers.insert(CONNECTION, value);
}

pub(super) fn connection_header_names(headers: &HeaderMap) -> ConnectionHeaderNames {
    comma_header_names(headers.get_all(CONNECTION).iter()).collect()
}

fn comma_header_names(values: ValueIter<'_, HeaderValue>) -> impl Iterator<Item = HeaderName> + '_ {
    values
        .flat_map(|value| value.as_bytes().split(|byte| *byte == b','))
        .map(trim_ows)
        .filter_map(|name| HeaderName::from_bytes(name).ok())
}

fn connection_has(value: &HeaderValue, needle: &str) -> bool {
    if let Ok(s) = value.to_str() {
        for val in s.split(',') {
            if val.trim().eq_ignore_ascii_case(needle) {
                return true;
            }
        }
    }
    false
}

pub(super) fn te_is_trailers(headers: &HeaderMap) -> bool {
    header_value_list_has(headers.get_all(TE).into_iter(), "trailers")
}

fn header_value_list_has(values: ValueIter<'_, HeaderValue>, needle: &str) -> bool {
    for value in values {
        if let Ok(line) = value.to_str() {
            for token in line.split(',') {
                if token.trim().eq_ignore_ascii_case(needle) {
                    return true;
                }
            }
        }
    }

    false
}

pub(super) fn content_length_parse(value: &HeaderValue) -> Option<u64> {
    from_digits(value.as_bytes())
}

pub(super) fn content_length_parse_all(headers: &HeaderMap) -> Option<u64> {
    content_length_parse_all_values(headers.get_all(CONTENT_LENGTH).into_iter())
}

pub(super) fn content_length_parse_all_values(values: ValueIter<'_, HeaderValue>) -> Option<u64> {
    // If multiple Content-Length headers were sent, everything can still
    // be alright if they all contain the same value, and all parse
    // correctly. If not, then it's an error.

    let mut content_length: Option<u64> = None;
    for h in values {
        if let Ok(line) = h.to_str() {
            for v in line.split(',') {
                let n = from_digits(v.trim().as_bytes())?;
                if content_length.is_none() {
                    content_length = Some(n)
                } else if content_length != Some(n) {
                    return None;
                }
            }
        } else {
            return None;
        }
    }

    content_length
}

fn from_digits(bytes: &[u8]) -> Option<u64> {
    // cannot use FromStr for u64, since it allows a signed prefix
    let mut result = 0u64;
    const RADIX: u64 = 10;

    if bytes.is_empty() {
        return None;
    }

    for &b in bytes {
        // can't use char::to_digit, since we haven't verified these bytes
        // are utf-8.
        match b {
            b'0'..=b'9' => {
                result = result.checked_mul(RADIX)?;
                result = result.checked_add(u64::from(b - b'0'))?;
            }
            _ => {
                // not a DIGIT, get outta here!
                return None;
            }
        }
    }

    Some(result)
}

pub(super) fn method_has_defined_payload_semantics(method: &Method) -> bool {
    !matches!(
        *method,
        Method::GET | Method::HEAD | Method::DELETE | Method::CONNECT
    )
}

/// A body known to be empty cannot deliver a positive (or unreadable) length, which would
/// stall or fail the peer reading it.
pub(super) fn drop_undeliverable_content_length(headers: &mut HeaderMap) {
    if content_length_parse_all(headers).is_none_or(|len| len != 0) {
        headers.remove(CONTENT_LENGTH);
    }
}

pub(super) fn set_content_length_if_missing(headers: &mut HeaderMap, len: u64) {
    headers
        .entry(CONTENT_LENGTH)
        .or_insert_with(|| HeaderValue::from(len));
}

pub(super) fn transfer_encoding_is_chunked(headers: &HeaderMap) -> bool {
    is_chunked(headers.get_all(TRANSFER_ENCODING).into_iter())
}

pub(super) fn is_chunked(mut encodings: ValueIter<'_, HeaderValue>) -> bool {
    // chunked must always be the last encoding, according to spec
    if let Some(line) = encodings.next_back() {
        return is_chunked_(line);
    }

    false
}

pub(super) fn is_chunked_(value: &HeaderValue) -> bool {
    // chunked must always be the last encoding, according to spec
    if let Ok(s) = value.to_str()
        && let Some(encoding) = s.rsplit(',').next()
    {
        return encoding.trim().eq_ignore_ascii_case("chunked");
    }

    false
}

/// Track `chunked` across a message's Transfer-Encoding field lines.
///
/// RFC 9112 §6.1 forbids applying it more than once. `seen` carries whether an
/// earlier coding named it; the current comma-separated list updates that fact
/// and returns true on a repeat, ignoring case and surrounding whitespace.
pub(super) fn has_duplicate_chunked(value: &HeaderValue, seen: &mut bool) -> bool {
    let Ok(s) = value.to_str() else {
        return false;
    };
    for coding in s.split(',') {
        if coding.trim().eq_ignore_ascii_case("chunked") {
            if *seen {
                return true;
            }
            *seen = true;
        }
    }
    false
}

pub(super) fn add_chunked(mut entry: OccupiedEntry<'_, HeaderValue>) {
    const CHUNKED: &str = "chunked";

    if let Some(line) = entry.iter_mut().next_back() {
        // + 2 for ", "
        let new_cap = line.as_bytes().len() + CHUNKED.len() + 2;
        let mut buf = BytesMut::with_capacity(new_cap);
        buf.extend_from_slice(line.as_bytes());
        buf.extend_from_slice(b", ");
        buf.extend_from_slice(CHUNKED.as_bytes());

        match HeaderValue::from_maybe_shared(buf.freeze()) {
            Ok(v) => *line = v,
            Err(err) => {
                debug!(
                    "failed to create header with chunked added from original header value: {err}; append entry instead"
                );
                entry.append(HeaderValue::from_static(CHUNKED));
            }
        }
        return;
    }

    entry.insert(HeaderValue::from_static(CHUNKED));
}

#[cfg(test)]
mod tests {
    use super::*;
    use ResponseLength::{ExplicitOnly, Forbidden, Known, NonZero};

    #[test]
    fn response_length_follows_method_and_status() {
        let (get, head, connect) = (
            Some(&Method::GET),
            Some(&Method::HEAD),
            Some(&Method::CONNECT),
        );
        let cases = [
            (get, 100, Forbidden),
            (get, 103, Forbidden),
            (get, 200, Known),
            (get, 204, Forbidden),
            (get, 206, Known),
            (get, 304, ExplicitOnly),
            (get, 404, Known),
            (head, 200, NonZero),
            (head, 204, Forbidden),
            (head, 304, ExplicitOnly),
            (head, 404, NonZero),
            (connect, 200, Forbidden),
            (connect, 299, Forbidden),
            (connect, 407, Known),
            (None, 200, Known),
        ];
        for (method, status, expected) in cases {
            let status = StatusCode::from_u16(status).unwrap();
            assert_eq!(
                ResponseLength::of(method, status),
                expected,
                "{method:?} {status}"
            );
        }
    }

    /// The safety properties every response relies on, over any method, status and body.
    #[test]
    fn response_length_never_invents_contradicts_or_frames_the_unframeable() {
        fn property(method: u8, status: u16, body_len: Option<u64>) -> bool {
            let method = [
                None,
                Some(Method::GET),
                Some(Method::HEAD),
                Some(Method::CONNECT),
                Some(Method::POST),
            ][usize::from(method % 5)]
            .clone();
            let Ok(status) = StatusCode::from_u16(100 + status % 500) else {
                return true;
            };
            let implied = ResponseLength::of(method.as_ref(), status).implied(body_len);
            // Never a length other than the body's own.
            let faithful = implied.is_none() || implied == body_len;
            // Never a zero on HEAD: an empty HEAD body says nothing about the GET's.
            let no_invented_zero = method != Some(Method::HEAD) || implied != Some(0);
            // Never a length where the status or a tunnel forbids one, nor on 304.
            let unframeable = status.is_informational()
                || status == StatusCode::NO_CONTENT
                || status == StatusCode::NOT_MODIFIED
                || (method == Some(Method::CONNECT) && status.is_success());
            faithful && no_invented_zero && (!unframeable || implied.is_none())
        }
        quickcheck::QuickCheck::new()
            .tests(10_000)
            .quickcheck(property as fn(u8, u16, Option<u64>) -> bool);
    }

    #[test]
    fn has_duplicate_chunked_detects_dupes() {
        let cases_dup: &[&[u8]] = &[
            b"chunked, chunked",
            b"chunked,chunked",
            b"Chunked, CHUNKED",
            b"gzip, chunked, chunked",
            b"chunked, gzip, chunked",
        ];
        for v in cases_dup {
            let hv = HeaderValue::from_bytes(v).unwrap();
            let mut seen = false;
            assert!(
                has_duplicate_chunked(&hv, &mut seen),
                "expected duplicate chunked detected in {:?}",
                std::str::from_utf8(v).unwrap()
            );
        }

        let cases_ok: &[&[u8]] = &[
            b"chunked",
            b"gzip, chunked",
            b"identity",
            b"deflate, gzip",
            b"",
        ];
        for v in cases_ok {
            let hv = HeaderValue::from_bytes(v).unwrap();
            let mut seen = false;
            assert!(
                !has_duplicate_chunked(&hv, &mut seen),
                "expected no duplicate chunked in {:?}",
                std::str::from_utf8(v).unwrap()
            );
        }
    }

    #[test]
    fn connection_set_close_keeps_nominated_fields() {
        let cases: &[(&[&str], &[&str])] = &[
            (&[], &["close"]),
            (&["close"], &["close"]),
            (&["close, x-hop"], &["close, x-hop"]),
            (&["x-hop"], &["x-hop", "close"]),
            (&["x-a", "Close"], &["x-a", "Close"]),
            (&["keep-alive"], &["close"]),
            (&["keep-alive, x-hop"], &["x-hop, close"]),
            (&["Keep-Alive", " x-a ,x-b"], &["x-a, x-b, close"]),
            (&["close", "keep-alive"], &["close"]),
            (&["x-hop,, keep-alive"], &["x-hop, close"]),
        ];
        for &(lines, expected) in cases {
            let mut headers = HeaderMap::new();
            for &line in lines {
                headers.append(CONNECTION, HeaderValue::from_static(line));
            }
            connection_set_close(&mut headers);
            let actual: Vec<_> = headers
                .get_all(CONNECTION)
                .iter()
                .map(|value| value.to_str().unwrap())
                .collect();
            assert_eq!(actual, expected, "{lines:?}");
        }
    }

    #[test]
    fn te_is_trailers_accepts_comma_separated_values() {
        let mut headers = HeaderMap::new();
        headers.insert(TE, HeaderValue::from_static("gzip, Trailers"));

        assert!(te_is_trailers(&headers));
    }

    #[test]
    fn te_is_trailers_accepts_multiple_header_lines() {
        let mut headers = HeaderMap::new();
        headers.append(TE, HeaderValue::from_static("gzip"));
        headers.append(TE, HeaderValue::from_static("trailers"));

        assert!(te_is_trailers(&headers));
    }

    #[test]
    fn te_is_trailers_rejects_missing_trailers_token() {
        let mut headers = HeaderMap::new();
        headers.insert(TE, HeaderValue::from_static("gzip"));

        assert!(!te_is_trailers(&headers));
    }
}
