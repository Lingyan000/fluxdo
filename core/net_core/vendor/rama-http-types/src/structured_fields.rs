//! Allocation-free dictionary projection for [RFC 9651](https://www.rfc-editor.org/rfc/rfc9651.html).
//!
//! This deliberately exposes only the values needed by dictionary consumers such as
//! HTTP Priority. Parameters and inner-list contents are fully validated and skipped.
//! Borrowed textual variants retain their wire encoding (including escapes), not a
//! decoded value. Parsing takes linear time and constant auxiliary space; inner lists
//! cannot nest. This is not a general structured-field serializer or object model.

/// A validated bare item. Textual values borrow their wire representation, without delimiters.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BareItem<'a> {
    /// Integer in the RFC's inclusive ±999,999,999,999,999 range.
    Integer(i64),
    /// Decimal wire representation, with at most three fractional digits.
    Decimal(&'a str),
    /// String contents, retaining backslash escapes.
    String(&'a str),
    /// ASCII token.
    Token(&'a str),
    /// Base64 contents, retaining padding if supplied.
    ByteSequence(&'a str),
    /// Boolean value.
    Boolean(bool),
    /// Unix timestamp in whole seconds.
    Date(i64),
    /// UTF-8 display string contents, retaining percent escapes.
    DisplayString(&'a str),
}

/// A dictionary member, with parameters validated but omitted.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DictionaryValue<'a> {
    /// A bare item.
    Item(BareItem<'a>),
    /// An inner list whose items and parameters have been validated.
    InnerList,
}

/// A list member (RFC 9651 §3.1), with inner-list contents validated but omitted.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ListMember<'a> {
    /// A bare item.
    Item(BareItem<'a>),
    /// An inner list whose items and parameters have been validated.
    InnerList,
}

/// What [`parse_list`] reports, in wire order: each member, then its parameters.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ListEvent<'a> {
    /// The next list member.
    Member(ListMember<'a>),
    /// A parameter of the preceding member; a bare key has the value `?1`.
    Parameter {
        /// The parameter key.
        key: &'a str,
        /// The parameter value.
        value: BareItem<'a>,
    },
}

/// Malformed structured-field syntax.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ParseError;

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("invalid structured field")
    }
}

impl std::error::Error for ParseError {}

/// Validate a complete dictionary, projecting each member into `visit` in wire order.
///
/// Duplicate keys are visited repeatedly; consumers must replace earlier values.
/// Callbacks can occur before a later syntax error: discard their results on error.
/// Combine multiple HTTP field lines with commas before calling this function.
pub fn parse_dictionary<'a>(
    input: &'a [u8],
    mut visit: impl FnMut(&'a str, DictionaryValue<'a>),
) -> Result<(), ParseError> {
    let input = std::str::from_utf8(input).map_err(|_error| ParseError)?;
    if !input.is_ascii() {
        return Err(ParseError);
    }
    let mut parser = Parser { input, pos: 0 };
    parser.spaces();
    while parser.peek().is_some() {
        let key = parser.key()?;
        let value = if parser.take(b'=') {
            if parser.take(b'(') {
                parser.inner_list()?;
                DictionaryValue::InnerList
            } else {
                DictionaryValue::Item(parser.bare_item()?)
            }
        } else {
            DictionaryValue::Item(BareItem::Boolean(true))
        };
        parser.parameters()?;
        visit(key, value);
        parser.ows();
        if parser.peek().is_none() {
            break;
        }
        parser.expect(b',')?;
        parser.ows();
        if parser.peek().is_none() {
            return Err(ParseError);
        }
    }
    Ok(())
}

/// Validate a complete List (RFC 9651 §4.2.1), projecting each member and its parameters
/// into `visit` in wire order.
///
/// Callbacks can occur before a later syntax error: discard their results on error. Combine
/// multiple HTTP field lines with commas before calling this function.
pub fn parse_list<'a>(
    input: &'a [u8],
    mut visit: impl FnMut(ListEvent<'a>),
) -> Result<(), ParseError> {
    let input = std::str::from_utf8(input).map_err(|_error| ParseError)?;
    if !input.is_ascii() {
        return Err(ParseError);
    }
    let mut parser = Parser { input, pos: 0 };
    parser.spaces();
    while parser.peek().is_some() {
        let member = if parser.take(b'(') {
            parser.inner_list()?;
            ListMember::InnerList
        } else {
            ListMember::Item(parser.bare_item()?)
        };
        visit(ListEvent::Member(member));
        parser.parameters_visit(&mut visit)?;
        parser.ows();
        if parser.peek().is_none() {
            break;
        }
        parser.expect(b',')?;
        parser.ows();
        if parser.peek().is_none() {
            return Err(ParseError);
        }
    }
    Ok(())
}

/// Parse a complete Item field (RFC 9651 §4.2.3), validating and ignoring its parameters.
///
/// Combine multiple HTTP field lines with commas first: that produces a List, which is not an
/// Item and is rejected, as RFC 9297 §3.4 expects for a repeated `Capsule-Protocol`.
pub fn parse_item(input: &[u8]) -> Result<BareItem<'_>, ParseError> {
    let input = std::str::from_utf8(input).map_err(|_error| ParseError)?;
    if !input.is_ascii() {
        return Err(ParseError);
    }
    let mut parser = Parser { input, pos: 0 };
    parser.spaces();
    let item = parser.bare_item()?;
    parser.parameters()?;
    parser.spaces();
    if parser.peek().is_some() {
        return Err(ParseError);
    }
    Ok(item)
}

struct Parser<'a> {
    input: &'a str,
    pos: usize,
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<u8> {
        self.input.as_bytes().get(self.pos).copied()
    }

    fn next(&mut self) -> Result<u8, ParseError> {
        let byte = self.peek().ok_or(ParseError)?;
        self.pos += 1;
        Ok(byte)
    }

    fn take(&mut self, byte: u8) -> bool {
        if self.peek() == Some(byte) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn expect(&mut self, byte: u8) -> Result<(), ParseError> {
        self.take(byte).then_some(()).ok_or(ParseError)
    }

    fn spaces(&mut self) {
        while self.take(b' ') {}
    }

    fn ows(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t')) {
            self.pos += 1;
        }
    }

    fn key(&mut self) -> Result<&'a str, ParseError> {
        let start = self.pos;
        if !matches!(self.next()?, b'a'..=b'z' | b'*') {
            return Err(ParseError);
        }
        while matches!(
            self.peek(),
            Some(b'a'..=b'z' | b'0'..=b'9' | b'_' | b'-' | b'.' | b'*')
        ) {
            self.pos += 1;
        }
        Ok(&self.input[start..self.pos])
    }

    fn parameters(&mut self) -> Result<(), ParseError> {
        while self.take(b';') {
            self.spaces();
            self.key()?;
            if self.take(b'=') {
                self.bare_item()?;
            }
        }
        Ok(())
    }

    fn parameters_visit(
        &mut self,
        visit: &mut impl FnMut(ListEvent<'a>),
    ) -> Result<(), ParseError> {
        while self.take(b';') {
            self.spaces();
            let key = self.key()?;
            let value = if self.take(b'=') {
                self.bare_item()?
            } else {
                BareItem::Boolean(true)
            };
            visit(ListEvent::Parameter { key, value });
        }
        Ok(())
    }

    fn inner_list(&mut self) -> Result<(), ParseError> {
        loop {
            self.spaces();
            if self.take(b')') {
                return Ok(());
            }
            self.bare_item()?;
            self.parameters()?;
            if !matches!(self.peek(), Some(b' ' | b')')) {
                return Err(ParseError);
            }
        }
    }

    fn bare_item(&mut self) -> Result<BareItem<'a>, ParseError> {
        match self.peek().ok_or(ParseError)? {
            b'-' | b'0'..=b'9' => self.number(),
            b'?' => {
                self.pos += 1;
                match self.next()? {
                    b'0' => Ok(BareItem::Boolean(false)),
                    b'1' => Ok(BareItem::Boolean(true)),
                    _ => Err(ParseError),
                }
            }
            b'@' => {
                self.pos += 1;
                match self.number()? {
                    BareItem::Integer(value) => Ok(BareItem::Date(value)),
                    _ => Err(ParseError),
                }
            }
            b'"' => self.string().map(BareItem::String),
            b'%' => self.display_string().map(BareItem::DisplayString),
            b':' => self.byte_sequence().map(BareItem::ByteSequence),
            b'a'..=b'z' | b'A'..=b'Z' | b'*' => {
                let start = self.pos;
                while matches!(
                    self.peek(),
                    Some(
                        b'a'..=b'z'
                        | b'A'..=b'Z'
                        | b'0'..=b'9'
                        | b'!'
                        | b'#'
                        | b'$'
                        | b'%'
                        | b'&'
                        | b'\''
                        | b'*'
                        | b'+'
                        | b'-'
                        | b'.'
                        | b'^'
                        | b'_'
                        | b'`'
                        | b'|'
                        | b'~'
                        | b':'
                        | b'/',
                    )
                ) {
                    self.pos += 1;
                }
                Ok(BareItem::Token(&self.input[start..self.pos]))
            }
            _ => Err(ParseError),
        }
    }

    fn number(&mut self) -> Result<BareItem<'a>, ParseError> {
        let start = self.pos;
        let negative = self.take(b'-');
        let digits = self.pos;
        let mut value = 0_i64;
        while let Some(byte @ b'0'..=b'9') = self.peek() {
            if self.pos - digits == 15 {
                return Err(ParseError);
            }
            value = value * 10 + i64::from(byte - b'0');
            self.pos += 1;
        }
        let count = self.pos - digits;
        if count == 0 {
            return Err(ParseError);
        }
        if self.take(b'.') {
            if count > 12 {
                return Err(ParseError);
            }
            let fraction = self.pos;
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.pos += 1;
                if self.pos - fraction > 3 {
                    return Err(ParseError);
                }
            }
            if self.pos == fraction {
                return Err(ParseError);
            }
            Ok(BareItem::Decimal(&self.input[start..self.pos]))
        } else {
            Ok(BareItem::Integer(if negative { -value } else { value }))
        }
    }

    fn string(&mut self) -> Result<&'a str, ParseError> {
        self.expect(b'"')?;
        let start = self.pos;
        loop {
            match self.next()? {
                b'"' => return Ok(&self.input[start..self.pos - 1]),
                b'\\' => {
                    if !matches!(self.next()?, b'"' | b'\\') {
                        return Err(ParseError);
                    }
                }
                b' '..=b'~' => (),
                _ => return Err(ParseError),
            }
        }
    }

    fn byte_sequence(&mut self) -> Result<&'a str, ParseError> {
        self.expect(b':')?;
        let start = self.pos;
        while matches!(
            self.peek(),
            Some(b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'+' | b'/')
        ) {
            self.pos += 1;
        }
        let symbols = self.pos - start;
        let padding_start = self.pos;
        while self.take(b'=') {}
        let padding = self.pos - padding_start;
        // Missing padding and nonzero pad bits are accepted per RFC 9651 §4.2.7.
        let allowed_padding = match symbols % 4 {
            0 => 0,
            2 => 2,
            3 => 1,
            _ => return Err(ParseError),
        };
        if padding > allowed_padding {
            return Err(ParseError);
        }
        let end = self.pos;
        self.expect(b':')?;
        Ok(&self.input[start..end])
    }

    fn display_string(&mut self) -> Result<&'a str, ParseError> {
        self.expect(b'%')?;
        self.expect(b'"')?;
        let start = self.pos;
        // At most one UTF-8 scalar is buffered, even for arbitrarily long strings.
        let mut scalar = [0_u8; 4];
        let mut len = 0;
        loop {
            let byte = match self.next()? {
                b'"' if len == 0 => return Ok(&self.input[start..self.pos - 1]),
                b'"' => return Err(ParseError),
                b'%' => hex(self.next()?)? * 16 + hex(self.next()?)?,
                byte @ b' '..=b'~' => byte,
                _ => return Err(ParseError),
            };
            scalar[len] = byte;
            len += 1;
            match std::str::from_utf8(&scalar[..len]) {
                Ok(_) => len = 0,
                Err(error) if error.error_len().is_none() && len < scalar.len() => (),
                Err(_) => return Err(ParseError),
            }
        }
    }
}

fn hex(byte: u8) -> Result<u8, ParseError> {
    match byte {
        b'0'..=b'9' => Ok(byte - b'0'),
        b'a'..=b'f' => Ok(byte - b'a' + 10),
        _ => Err(ParseError),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dictionary_values_and_extensions() {
        let mut members = Vec::new();
        parse_dictionary(
            b"u=1, i, u=7;x=token, x=(1;a \"b,c\");q, d=@-42, s=%\"%c3%bc\"",
            |key, value| members.push((key, value)),
        )
        .unwrap();
        assert_eq!(
            members[0],
            ("u", DictionaryValue::Item(BareItem::Integer(1)))
        );
        assert_eq!(
            members[1],
            ("i", DictionaryValue::Item(BareItem::Boolean(true)))
        );
        assert_eq!(
            members[2],
            ("u", DictionaryValue::Item(BareItem::Integer(7)))
        );
        assert_eq!(members[3], ("x", DictionaryValue::InnerList));
        assert_eq!(
            members[4],
            ("d", DictionaryValue::Item(BareItem::Date(-42)))
        );
        assert_eq!(
            members[5],
            (
                "s",
                DictionaryValue::Item(BareItem::DisplayString("%c3%bc"))
            )
        );
    }

    #[test]
    fn valid_boundaries() {
        for value in [
            "",
            "   ",
            "x\t",
            "x,\ty",
            "x=999999999999999",
            "x=-999999999999999",
            "x=999999999999.999",
            "x=-0.001",
            "x=()",
            "x=(  )",
            "x=:aQ:",
            "x=:aQ=:",
            "x=:aQ==:",
            "x=:aR==:",
            "x=::",
            "x=%\"%00%f4%8f%bf%bf\"",
            "x=\"a\\\"b\\\\c\"",
            "x=A:/!#$%&'*+-.^_`|~",
            "x;p=1;p=2",
        ] {
            assert!(
                parse_dictionary(value.as_bytes(), |_, _| {}).is_ok(),
                "{value:?}"
            );
        }
    }

    #[test]
    fn malformed_ignored_values_fail_entire_dictionary() {
        for value in [
            "\tx",
            "x,",
            "x,,y",
            "X",
            "x =1",
            "x= 1",
            "x;\tp",
            "x;p=()",
            "x=(())",
            "x=(1\t2)",
            "x=(1,2)",
            "x=(1",
            "x=1000000000000000",
            "x=0000000000000000",
            "x=1000000000000.0",
            "x=1.0000",
            "x=1.",
            "x=-",
            "x=?2",
            "x=@1.0",
            "x=\"a\\q\"",
            "x=\"a\t\"",
            "x=:a:",
            "x=:a===:",
            "x=:abcd=:",
            "x=:aQ===:",
            "x=:a Q:",
            "x=%\"%FF\"",
            "x=%\"%ff\"",
            "x=%\"%c0%80\"",
            "x=%\"%ed%a0%80\"",
            "x=%\"%f4%90%80%80\"",
            "x=%\"%c3\"",
            "x=%\"%c3x\"",
            "x=\"ü\"",
        ] {
            assert!(
                parse_dictionary(value.as_bytes(), |_, _| {}).is_err(),
                "{value:?}"
            );
        }
    }

    #[test]
    fn items_ignore_parameters_and_reject_lists_or_trailing_input() {
        for (value, expected) in [
            ("?1", BareItem::Boolean(true)),
            ("  ?0 ", BareItem::Boolean(false)),
            ("?1;a=1;b", BareItem::Boolean(true)),
            ("token", BareItem::Token("token")),
            ("42", BareItem::Integer(42)),
            // RFC 9651 erratum 8869: a Display String is also an Item.
            ("%\"caf%c3%a9\"", BareItem::DisplayString("caf%c3%a9")),
        ] {
            assert_eq!(parse_item(value.as_bytes()), Ok(expected), "{value:?}");
        }
        for value in [
            "", " ", "?1, ?1", "?1 ?0", "?1;", "?2", "(?1)", "\t?1", "?1\t",
        ] {
            assert!(parse_item(value.as_bytes()).is_err(), "{value:?}");
        }
    }

    #[test]
    fn lists_report_members_then_their_parameters() {
        let mut events = Vec::new();
        parse_list(b"a;x=1;y, \"b\" , (c d);z=?0, 7", |event| {
            events.push(event)
        })
        .unwrap();
        assert_eq!(
            events,
            [
                ListEvent::Member(ListMember::Item(BareItem::Token("a"))),
                ListEvent::Parameter {
                    key: "x",
                    value: BareItem::Integer(1)
                },
                ListEvent::Parameter {
                    key: "y",
                    value: BareItem::Boolean(true)
                },
                ListEvent::Member(ListMember::Item(BareItem::String("b"))),
                ListEvent::Member(ListMember::InnerList),
                ListEvent::Parameter {
                    key: "z",
                    value: BareItem::Boolean(false)
                },
                ListEvent::Member(ListMember::Item(BareItem::Integer(7))),
            ]
        );
    }

    #[test]
    fn malformed_lists_are_rejected() {
        for input in [&b"a,"[..], b",a", b"a;", b"a;X=1", b"a b", b"(a", b"\xff"] {
            assert_eq!(parse_list(input, |_| {}), Err(ParseError), "{input:?}");
        }
        let mut count = 0;
        parse_list(b"", |_| count += 1).unwrap();
        assert_eq!(count, 0);
    }
}
