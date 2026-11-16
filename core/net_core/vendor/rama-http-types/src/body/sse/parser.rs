//! SSE Parser (for clients)
//!
//! Originally adapted from
//! <https://github.com/jpopesculian/eventsource-stream/blob/3d46f1c758f9ee4681e9da0427556d24c53f9c01/src/parser.rs>:
//! - by Julian Popescu (hi@julian.dev); License: MIT or Apache 2.0
//!
//! Rewritten as a hand-rolled single-pass line parser: the caller hands us
//! one complete line (terminator already stripped) and we classify it.

/// ; ABNF definition from HTML spec
///
/// stream        = [ bom ] *event
/// event         = *( comment / field ) end-of-line
/// comment       = colon *any-char end-of-line
/// field         = 1*name-char [ colon [ space ] *any-char ] end-of-line
/// end-of-line   = ( cr lf / cr / lf )
///
/// ; characters
/// lf            = %x000A ; U+000A LINE FEED (LF)
/// cr            = %x000D ; U+000D CARRIAGE RETURN (CR)
/// space         = %x0020 ; U+0020 SPACE
/// colon         = %x003A ; U+003A COLON (:)
/// bom           = %xFEFF ; U+FEFF BYTE ORDER MARK
/// name-char     = %x0000-0009 / %x000B-000C / %x000E-0039 / %x003B-10FFFF
///                 ; a scalar value other than U+000A LINE FEED (LF), U+000D CARRIAGE RETURN (CR), or U+003A COLON (:)
/// any-char      = %x0000-0009 / %x000B-000C / %x000E-10FFFF
///                 ; a scalar value other than U+000A LINE FEED (LF) or U+000D CARRIAGE RETURN (CR)
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) enum RawEventLine<'a> {
    Comment(&'a str),
    Field(&'a str, Option<&'a str>),
    Empty,
}

#[inline]
pub(super) fn is_lf(c: char) -> bool {
    c == '\u{000A}'
}

/// Classify a single complete SSE line (without its terminator).
///
/// Since a line by construction contains no CR/LF, every input maps to
/// one of the three [`RawEventLine`] variants; this can never fail.
#[inline]
pub(super) fn parse_line(line: &str) -> RawEventLine<'_> {
    if line.is_empty() {
        return RawEventLine::Empty;
    }
    let bytes = line.as_bytes();
    if bytes[0] == b':' {
        let comment = &line[1..];
        return RawEventLine::Comment(comment.strip_prefix(' ').unwrap_or(comment));
    }
    // `:` is ASCII, so the byte offset is always a valid char boundary
    match memchr::memchr(b':', bytes) {
        Some(colon) => {
            let value = &line[colon + 1..];
            let value = value.strip_prefix(' ').unwrap_or(value);
            RawEventLine::Field(&line[..colon], Some(value))
        }
        None => RawEventLine::Field(line, None),
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_parse_line_empty() {
        assert_eq!(RawEventLine::Empty, parse_line(""));
    }

    #[test]
    fn test_parse_line_comment() {
        assert_eq!(RawEventLine::Comment(""), parse_line(":"));
        assert_eq!(RawEventLine::Comment(""), parse_line(": "));
        assert_eq!(RawEventLine::Comment(" "), parse_line(":  "));
        assert_eq!(RawEventLine::Comment("hello"), parse_line(": hello"));
        assert_eq!(RawEventLine::Comment("hello"), parse_line(":hello"));
        assert_eq!(RawEventLine::Comment("a: b"), parse_line(": a: b"));
    }

    #[test]
    fn test_parse_line_field() {
        assert_eq!(RawEventLine::Field("data", None), parse_line("data"));
        assert_eq!(RawEventLine::Field("data", Some("")), parse_line("data:"));
        assert_eq!(RawEventLine::Field("data", Some("")), parse_line("data: "));
        assert_eq!(
            RawEventLine::Field("data", Some(" ")),
            parse_line("data:  ")
        );
        assert_eq!(
            RawEventLine::Field("data", Some("hello")),
            parse_line("data: hello")
        );
        assert_eq!(
            RawEventLine::Field("data", Some("hello")),
            parse_line("data:hello")
        );
        assert_eq!(
            RawEventLine::Field("data", Some("a: b")),
            parse_line("data: a: b")
        );
        assert_eq!(RawEventLine::Field("id", Some("42")), parse_line("id: 42"));
        assert_eq!(
            RawEventLine::Field("weird🚀name", Some("v")),
            parse_line("weird🚀name: v")
        );
    }
}
