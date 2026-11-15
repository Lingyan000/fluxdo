//! The `Content-Type` a recipient acts on, read as browsers do, so a proxy or server agrees
//! with them:
//!
//! - [`extract_mime_type`] and [`extract_essence`] read a response as browsers do: WHATWG Fetch's
//!   lenient "extract a MIME type" (§3.5) over every field line.
//! - [`parse_essence`] and [`parse_mime_type`] judge a request as the CORS safelist does: MIME
//!   Sniffing's "parse a MIME type" (§4.4) over the whole value. A decision that gates a request uses it, as the lenient
//!   reading finds `application/json` in a `text/plain;,application/json` sent without preflight.

use std::borrow::Cow;

use rama_utils::collections::smallvec::SmallVec;

use crate::{HeaderValue, header::is_token, mime::Mime};

/// The extracted type with its parameters, `None` when no line holds a valid one.
///
/// A parameter is left out unless it re-encodes to the octets it came from: printable ASCII
/// without a quote or backslash, and not empty.
pub fn extract_mime_type<'i>(lines: impl IntoIterator<Item = &'i HeaderValue>) -> Option<Mime> {
    match FieldLines::new(lines)? {
        FieldLines::Split(lines) => extract_mime(lines.into_iter().flat_map(split_outside_quotes)),
        FieldLines::Joined(value) => extract_mime(split_outside_quotes(&value)),
    }
}

/// The `type/subtype` of the extracted type, as sent: all a decision on the media type needs.
///
/// Borrowed from the lines, unless a quoted string one line leaves open runs into the next.
pub fn extract_essence<'i>(
    lines: impl IntoIterator<Item = &'i HeaderValue>,
) -> Option<Cow<'i, str>> {
    match FieldLines::new(lines)? {
        FieldLines::Split(lines) => last_valid(lines.into_iter().flat_map(split_outside_quotes))
            .map(|winner| Cow::Borrowed(winner.essence)),
        FieldLines::Joined(value) => last_valid(split_outside_quotes(&value))
            .map(|winner| Cow::Owned(winner.essence.to_owned())),
    }
}

/// The `type/subtype` of the whole value as one media type, as sent: what the CORS safelist
/// judges, so a request is gated on the type its sender was allowed to send.
pub fn parse_essence<'i>(lines: impl IntoIterator<Item = &'i HeaderValue>) -> Option<&'i str> {
    let mut lines = lines.into_iter();
    let first = Candidate::parse(lines.next()?.as_bytes())?;
    // The combined value's subtype runs to its first `;`: without one on the first line, it
    // takes in the `,` that joins the next.
    (lines.next().is_none() || !first.parameters.is_empty()).then_some(first.essence)
}

/// The whole value as one media type with the parameters the `mime` crate can hold, see
/// [`parse_essence`].
pub fn parse_mime_type<'i>(lines: impl IntoIterator<Item = &'i HeaderValue>) -> Option<Mime> {
    let mut lines = lines.into_iter();
    let first = lines.next()?.as_bytes();
    let value = match lines.next() {
        None => Cow::Borrowed(first),
        Some(second) => {
            let lines: SmallVec<[&[u8]; 4]> = [first, second.as_bytes()]
                .into_iter()
                .chain(lines.map(HeaderValue::as_bytes))
                .collect();
            Cow::Owned(join(&lines))
        }
    };
    let parsed = Candidate::parse(&value)?;
    to_mime(parsed.essence, &parsed.parameters())
}

/// The field lines, as the parts of the value they combine to (Fetch's "get") are read.
enum FieldLines<'i> {
    /// Each line split on its own: the same parts, as no line leaves a quoted string open.
    Split(SmallVec<[&'i [u8]; 4]>),
    /// The combined value, for a quoted string that runs from one line into the next.
    Joined(Vec<u8>),
}

impl<'i> FieldLines<'i> {
    fn new(lines: impl IntoIterator<Item = &'i HeaderValue>) -> Option<Self> {
        let lines: SmallVec<[&'i [u8]; 4]> = lines.into_iter().map(HeaderValue::as_bytes).collect();
        let (_, earlier) = lines.split_last()?;
        Some(if earlier.iter().any(|line| ends_quoted(line)) {
            Self::Joined(join(&lines))
        } else {
            Self::Split(lines)
        })
    }
}

/// The lines joined as Fetch combines them.
fn join(lines: &[&[u8]]) -> Vec<u8> {
    let mut value = Vec::with_capacity(lines.iter().map(|line| line.len() + 2).sum());
    for (index, line) in lines.iter().enumerate() {
        if index > 0 {
            value.extend_from_slice(b", ");
        }
        value.extend_from_slice(line);
    }
    value
}

/// Whether `line` ends inside a quoted string.
fn ends_quoted(line: &[u8]) -> bool {
    let (mut quoted, mut escaped) = (false, false);
    for byte in line {
        match (quoted, escaped, byte) {
            (true, true, _) => escaped = false,
            (true, false, b'\\') => escaped = true,
            (_, _, b'"') => quoted = !quoted,
            _ => {}
        }
    }
    quoted
}

fn extract_mime<'a>(parts: impl Iterator<Item = &'a [u8]>) -> Option<Mime> {
    let (winner, inherited_charset) = extract(parts)?;
    let mut parameters = winner.parameters();
    if let Some(charset) = inherited_charset {
        parameters.push(("charset", charset));
    }
    to_mime(winner.essence, &parameters)
}

fn last_valid<'a>(parts: impl Iterator<Item = &'a [u8]>) -> Option<Candidate<'a>> {
    parts
        .filter_map(Candidate::parse)
        .filter(|candidate| candidate.essence != "*/*")
        .last()
}

/// The last valid type and the charset it inherits from an earlier one of the same essence.
fn extract<'a>(
    parts: impl Iterator<Item = &'a [u8]>,
) -> Option<(Candidate<'a>, Option<Cow<'a, [u8]>>)> {
    let mut winner: Option<Candidate<'a>> = None;
    let mut essence_from: Option<Candidate<'a>> = None;
    let mut inherits = false;
    for candidate in parts.filter_map(Candidate::parse) {
        if candidate.essence == "*/*" {
            continue;
        }
        let same_essence =
            winner.is_some_and(|winner| winner.essence.eq_ignore_ascii_case(candidate.essence));
        if same_essence {
            inherits = candidate.charset().is_none();
        } else {
            essence_from = Some(candidate);
            inherits = false;
        }
        winner = Some(candidate);
    }
    let winner = winner?;
    let charset = inherits
        .then(|| essence_from.and_then(Candidate::charset))
        .flatten();
    Some((winner, charset))
}

/// A type MIME Sniffing accepts: a token type and subtype; its parameters never fail it.
#[derive(Clone, Copy)]
struct Candidate<'a> {
    /// `type/subtype` as sent.
    essence: &'a str,
    /// What follows the subtype, from its first `;`.
    parameters: &'a [u8],
}

impl<'a> Candidate<'a> {
    fn parse(value: &'a [u8]) -> Option<Self> {
        let value = trim_http_whitespace(value);
        let slash = value.iter().position(|byte| *byte == b'/')?;
        let (kind, rest) = (&value[..slash], &value[slash + 1..]);
        let semicolon = rest
            .iter()
            .position(|byte| *byte == b';')
            .unwrap_or(rest.len());
        let (subtype, parameters) = rest.split_at(semicolon);
        let subtype = trim_end_http_whitespace(subtype);
        if !is_token(kind) || !is_token(subtype) {
            return None;
        }
        // Tokens are ASCII.
        let essence = std::str::from_utf8(&value[..kind.len() + 1 + subtype.len()]).ok()?;
        Some(Self {
            essence,
            parameters,
        })
    }

    fn charset(self) -> Option<Cow<'a, [u8]>> {
        self.parameters()
            .into_iter()
            .find_map(|(name, value)| name.eq_ignore_ascii_case("charset").then_some(value))
    }

    /// The parameters MIME Sniffing keeps: a token name, a value of quoted-string token code
    /// points, the first of a repeated name.
    fn parameters(self) -> SmallVec<[(&'a str, Cow<'a, [u8]>); 4]> {
        let input = self.parameters;
        let mut parameters: SmallVec<[(&'a str, Cow<'a, [u8]>); 4]> = SmallVec::new();
        let mut position = 0;
        while position < input.len() {
            // At a `;`.
            position += 1;
            while input
                .get(position)
                .is_some_and(|byte| HTTP_WHITESPACE.contains(byte))
            {
                position += 1;
            }
            let name_start = position;
            while input
                .get(position)
                .is_some_and(|byte| *byte != b';' && *byte != b'=')
            {
                position += 1;
            }
            let name = &input[name_start..position];
            match input.get(position) {
                Some(b';') => continue,
                Some(_) => position += 1,
                None => break,
            }
            if position >= input.len() {
                break;
            }
            let value = if input[position] == b'"' {
                let (value, end) = collect_quoted_string(input, position);
                position = end;
                while input.get(position).is_some_and(|byte| *byte != b';') {
                    position += 1;
                }
                value
            } else {
                let value_start = position;
                while input.get(position).is_some_and(|byte| *byte != b';') {
                    position += 1;
                }
                let value = trim_end_http_whitespace(&input[value_start..position]);
                if value.is_empty() {
                    continue;
                }
                Cow::Borrowed(value)
            };
            if is_token(name)
                && value.iter().copied().all(is_quoted_string_token_code_point)
                && let Ok(name) = std::str::from_utf8(name)
                && !parameters
                    .iter()
                    .any(|(known, _)| known.eq_ignore_ascii_case(name))
            {
                parameters.push((name, value));
            }
        }
        parameters
    }
}

/// HTTP whitespace as MIME Sniffing and Fetch use it.
const HTTP_WHITESPACE: [u8; 4] = [b' ', b'\t', b'\n', b'\r'];

fn trim_http_whitespace(value: &[u8]) -> &[u8] {
    let start = value
        .iter()
        .position(|byte| !HTTP_WHITESPACE.contains(byte))
        .unwrap_or(value.len());
    trim_end_http_whitespace(&value[start..])
}

fn trim_end_http_whitespace(value: &[u8]) -> &[u8] {
    let end = value
        .iter()
        .rposition(|byte| !HTTP_WHITESPACE.contains(byte))
        .map_or(0, |last| last + 1);
    &value[..end]
}

/// A field value byte is the code point of the same value (Fetch's isomorphic decoding).
fn is_quoted_string_token_code_point(byte: u8) -> bool {
    matches!(byte, b'\t' | b' '..=b'~' | 0x80..=0xff)
}

/// Fetch's "collect an HTTP quoted string" with the extract-value flag set, from the `"` at
/// `position`: its value and the position after it.
fn collect_quoted_string(input: &[u8], mut position: usize) -> (Cow<'_, [u8]>, usize) {
    position += 1;
    let mut value: Cow<'_, [u8]> = Cow::Borrowed(&[]);
    loop {
        let start = position;
        while input
            .get(position)
            .is_some_and(|byte| *byte != b'"' && *byte != b'\\')
        {
            position += 1;
        }
        append(&mut value, &input[start..position]);
        let Some(&quote_or_backslash) = input.get(position) else {
            break;
        };
        position += 1;
        if quote_or_backslash == b'"' {
            break;
        }
        match input.get(position) {
            Some(&escaped) => {
                value.to_mut().push(escaped);
                position += 1;
            }
            None => {
                value.to_mut().push(b'\\');
                break;
            }
        }
    }
    (value, position)
}

fn append<'a>(value: &mut Cow<'a, [u8]>, part: &'a [u8]) {
    if value.is_empty() {
        *value = Cow::Borrowed(part);
    } else if !part.is_empty() {
        value.to_mut().extend_from_slice(part);
    }
}

/// `essence` with the `parameters` the `mime` crate can hold, quoted where they need it.
fn to_mime(essence: &str, parameters: &[(&str, Cow<'_, [u8]>)]) -> Option<Mime> {
    if parameters.is_empty() {
        return essence.parse().ok();
    }
    let mut serialized = String::with_capacity(
        essence.len()
            + parameters
                .iter()
                .map(|(name, value)| name.len() + value.len() + 5)
                .sum::<usize>(),
    );
    serialized.push_str(essence);
    for (name, value) in parameters {
        let quoted = !is_token(value);
        // `mime` holds a quoted value raw: UTF-8 or a backslash would not re-encode as sent.
        if quoted
            && (value.is_empty()
                || !value
                    .iter()
                    .all(|byte| (b' '..=b'~').contains(byte) && *byte != b'"' && *byte != b'\\'))
        {
            continue;
        }
        // A token or printable ASCII by now.
        let Ok(value) = std::str::from_utf8(value) else {
            continue;
        };
        serialized.push_str("; ");
        serialized.push_str(name);
        serialized.push('=');
        if quoted {
            serialized.push('"');
            serialized.push_str(value);
            serialized.push('"');
        } else {
            serialized.push_str(value);
        }
    }
    serialized.parse().ok().or_else(|| essence.parse().ok())
}

/// Fetch's "split" of a field value: on commas outside quoted strings, trimming HTTP tab or
/// space around each part.
fn split_outside_quotes(value: &[u8]) -> impl Iterator<Item = &[u8]> {
    let mut rest = Some(value);
    std::iter::from_fn(move || {
        let input = rest?;
        let (mut quoted, mut escaped) = (false, false);
        let mut end = input.len();
        for (index, byte) in input.iter().enumerate() {
            match (quoted, escaped, byte) {
                (true, true, _) => escaped = false,
                (true, false, b'\\') => escaped = true,
                (_, _, b'"') => quoted = !quoted,
                (false, _, b',') => {
                    end = index;
                    break;
                }
                _ => {}
            }
        }
        rest = input.get(end + 1..).filter(|_| end < input.len());
        Some(trim_tab_or_space(&input[..end]))
    })
}

fn trim_tab_or_space(value: &[u8]) -> &[u8] {
    let is_tab_or_space = |byte: &u8| *byte == b' ' || *byte == b'\t';
    let start = value
        .iter()
        .position(|byte| !is_tab_or_space(byte))
        .unwrap_or(value.len());
    let end = value
        .iter()
        .rposition(|byte| !is_tab_or_space(byte))
        .map_or(start, |last| last + 1);
    &value[start..end]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mime;

    fn values(lines: &[&str]) -> Vec<HeaderValue> {
        lines
            .iter()
            .map(|line| HeaderValue::from_str(line).unwrap())
            .collect()
    }

    /// The examples of Fetch's "extract a MIME type" (§3.5), one field line per entry.
    #[test]
    fn several_lines_extract_the_mime_type_as_fetch_does() {
        for (lines, essence, charset, x) in [
            (
                &["text/plain;charset=gbk, text/html"][..],
                "text/html",
                None,
                None,
            ),
            (
                &["text/html;charset=gbk;a=b, text/html;x=y"],
                "text/html",
                Some("gbk"),
                Some("y"),
            ),
            (
                &["text/html;charset=gbk;a=b", "text/html;x=y"],
                "text/html",
                Some("gbk"),
                Some("y"),
            ),
            (
                &["text/html;charset=gbk", "x/x", "text/html;x=y"],
                "text/html",
                None,
                Some("y"),
            ),
            (&["text/html", "cannot-parse"], "text/html", None, None),
            (&["text/html", "*/*"], "text/html", None, None),
            (&["text/html", ""], "text/html", None, None),
            (&["text/html", "x/"], "text/html", None, None),
            // A comma inside a quoted parameter value does not split.
            (
                &[r#"text/html;x=",text/plain""#],
                "text/html",
                None,
                Some(",text/plain"),
            ),
            // The inherited charset is set as a parameter, after a trailing `;` too.
            (
                &["text/html;charset=gbk", "text/html;x=y;"],
                "text/html",
                Some("gbk"),
                Some("y"),
            ),
            // A same-essence type with its own charset keeps it and does not pass it on.
            (
                &[
                    "text/html;charset=gbk",
                    "text/html;charset=utf-8",
                    "text/html",
                ],
                "text/html",
                Some("gbk"),
                None,
            ),
        ] {
            let mime = extract_mime_type(&values(lines)).unwrap();
            assert_eq!(mime.essence_str(), essence, "{lines:?}");
            assert_eq!(
                mime.get_param(mime::CHARSET).map(|value| value.as_str()),
                charset,
                "{lines:?}"
            );
            assert_eq!(
                mime.get_param("x").map(|value| value.as_str()),
                x,
                "{lines:?}"
            );
            assert_eq!(
                extract_essence(&values(lines)).as_deref(),
                Some(essence),
                "{lines:?}"
            );
        }
        for lines in [
            &[][..],
            &["cannot-parse"],
            &["*/*"],
            &[""],
            &["x/"],
            &["/x"],
        ] {
            assert!(extract_mime_type(&values(lines)).is_none(), "{lines:?}");
            assert!(extract_essence(&values(lines)).is_none(), "{lines:?}");
        }
    }

    /// MIME Sniffing's "parse a MIME type" (§4.4): only the type and subtype can fail it.
    #[test]
    fn parameters_never_fail_a_type() {
        for (line, essence, parameters) in [
            (
                "application/x-www-form-urlencoded ; charset=UTF-8",
                "application/x-www-form-urlencoded",
                &[("charset", "utf-8")][..],
            ),
            ("text/html;;x=1", "text/html", &[("x", "1")]),
            ("text/html;\tx=1", "text/html", &[("x", "1")]),
            ("text/html;charset", "text/html", &[]),
            ("text/html;charset=", "text/html", &[]),
            ("text/html;x=a@b", "text/html", &[("x", "a@b")]),
            ("text/html;x=\"a b\"", "text/html", &[("x", "a b")]),
            // The `mime` crate holds no escaped quote: left out.
            ("text/html;x=\"a\\\"b\";y=2", "text/html", &[("y", "2")]),
            // Nor a backslash, which a re-encoded value would turn into an escape.
            ("text/html;x=\"a\\\\b\";y=2", "text/html", &[("y", "2")]),
            (
                "text/html;x=\"unterminated",
                "text/html",
                &[("x", "unterminated")],
            ),
            ("TEXT/HTML;X=1;x=2", "text/html", &[("x", "1")]),
            // Nor a tab or an empty quoted value: only that parameter is left out.
            (
                "multipart/form-data; boundary=abc; x=\"\"",
                "multipart/form-data",
                &[("boundary", "abc")],
            ),
            (
                "multipart/form-data; x=\"a\tb\"; boundary=abc",
                "multipart/form-data",
                &[("boundary", "abc")],
            ),
            (
                "multipart/form-data; boundary=AaB03x",
                "multipart/form-data",
                &[("boundary", "AaB03x")],
            ),
        ] {
            let mime = extract_mime_type(&values(&[line])).unwrap();
            assert_eq!(mime.essence_str(), essence, "{line}");
            let kept: Vec<_> = mime
                .params()
                .map(|(name, value)| (name.as_str(), value.as_str()))
                .collect();
            assert_eq!(kept, parameters, "{line}");
        }
    }

    #[test]
    fn essences_borrow_from_the_lines() {
        let one = values(&["Text/HTML; charset=utf-8"]);
        assert!(matches!(
            extract_essence(&one),
            Some(Cow::Borrowed("Text/HTML"))
        ));
        let several = values(&["text/plain", "text/html;x=1"]);
        assert!(matches!(
            extract_essence(&several),
            Some(Cow::Borrowed("text/html"))
        ));
        assert_eq!(parse_essence(&one), Some("Text/HTML"));
    }

    /// A quoted string a line leaves open runs into the next, as in the combined value.
    #[test]
    fn a_quoted_string_spans_lines() {
        let lines = values(&[r#"text/html;x="a"#, r#"b", text/plain"#]);
        assert_eq!(extract_essence(&lines).as_deref(), Some("text/plain"));
        assert_eq!(
            extract_mime_type(&lines).unwrap().essence_str(),
            "text/plain"
        );
        let lines = values(&[r#"text/html;x="a"#, r#"b""#]);
        let mime = extract_mime_type(&lines).unwrap();
        assert_eq!(mime.essence_str(), "text/html");
        assert_eq!(
            mime.get_param("x").map(|value| value.as_str()),
            Some("a, b")
        );
    }

    #[test]
    fn values_are_isomorphic_decoded() {
        let values = [
            HeaderValue::from_static("text/html"),
            HeaderValue::from_bytes(b"text/\xffplain").unwrap(),
        ];
        assert_eq!(
            extract_mime_type(&values).unwrap().essence_str(),
            "text/html"
        );
        // `\xff` is a valid code point, so nothing is inherited; as UTF-8 it would not re-encode.
        let values = [
            HeaderValue::from_static("text/html;charset=gbk"),
            HeaderValue::from_bytes(b"text/html;charset=\xff").unwrap(),
        ];
        let mime = extract_mime_type(&values).unwrap();
        assert_eq!(mime.essence_str(), "text/html");
        assert_eq!(mime.get_param(mime::CHARSET), None);
        let values = [HeaderValue::from_bytes(b"text/plain; name=\"caf\xe9.txt\"; x=1").unwrap()];
        let mime = extract_mime_type(&values).unwrap();
        assert_eq!(mime.get_param("name"), None);
        assert_eq!(mime.get_param("x").map(|value| value.as_str()), Some("1"));
    }

    /// A request is judged as the CORS safelist judges it: the whole value as one type.
    #[test]
    fn parsing_judges_the_whole_value_as_one_type() {
        for (lines, essence) in [
            (&["application/json"][..], Some("application/json")),
            (
                &["Application/JSON ; charset=utf-8"],
                Some("Application/JSON"),
            ),
            // Safelisted as `text/plain`, so never JSON.
            (&["text/plain;,application/json"], Some("text/plain")),
            (&["text/plain;a=b", "application/json"], Some("text/plain")),
            (&["application/json", "application/json"], None),
            (&["text/plain, application/json"], None),
            (&["x/"], None),
            (&[], None),
        ] {
            assert_eq!(
                parse_essence(&values(lines)).as_deref(),
                essence,
                "{lines:?}"
            );
        }
        let mime = parse_mime_type(&values(&["Text/Plain; charset=utf-8;,application/json"]));
        assert_eq!(mime.as_ref().map(Mime::essence_str), Some("text/plain"));
        assert_eq!(
            mime.as_ref()
                .and_then(|mime| mime.get_param(mime::CHARSET))
                .map(|value| value.as_str()),
            Some("utf-8")
        );
        assert_eq!(
            extract_essence(&values(&["text/plain;,application/json"])).as_deref(),
            Some("application/json"),
            "a response is read leniently"
        );
    }
}
