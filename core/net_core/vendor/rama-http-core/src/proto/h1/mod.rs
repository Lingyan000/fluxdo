use httparse::ParserConfig;
use rama_core::bytes::BytesMut;
use rama_core::extensions::Extensions;
use rama_http::proto::h1::ext::informational::OnInformational;
use rama_http_types::{HeaderMap, Method, Version};

use crate::body::DecodedLength;
use crate::proto::{BodyLength, MessageHead};

pub(crate) use self::conn::Conn;
pub(crate) use self::decode::Decoder;
pub(crate) use self::dispatch::Dispatcher;
pub(crate) use self::encode::{EncodedBuf, Encoder};
//TODO: move out of h1::io
pub(crate) use self::io::MINIMUM_MAX_BUFFER_SIZE;

mod conn;
mod decode;
pub(crate) mod dispatch;
mod encode;
mod io;
mod role;

pub(crate) type ClientTransaction = role::Client;
pub(crate) type ServerTransaction = role::Server;

pub(crate) trait Http1Transaction {
    type Incoming;
    type Outgoing: Default;
    const LOG: &'static str;
    fn parse(bytes: &mut BytesMut, ctx: ParseContext<'_>) -> ParseResult<Self::Incoming>;
    fn encode(enc: Encode<'_, Self::Outgoing>, dst: &mut Vec<u8>) -> crate::Result<Encoder>;

    fn on_error(err: &crate::Error) -> Option<MessageHead<Self::Outgoing>>;

    fn is_client() -> bool {
        !Self::is_server()
    }

    fn is_server() -> bool {
        !Self::is_client()
    }

    fn should_error_on_parse_eof() -> bool {
        Self::is_client()
    }

    fn should_read_first() -> bool {
        Self::is_server()
    }

    /// Whether this outgoing message accepts an HTTP upgrade.
    fn accepts_upgrade(_subject: &Self::Outgoing, _method: Option<&Method>) -> bool {
        false
    }

    fn update_date() {}
}

/// Result newtype for `Http1Transaction::parse`.
pub(crate) type ParseResult<T> = Result<Option<ParsedMessage<T>>, crate::error::Parse>;

#[derive(Debug)]
pub(crate) struct ParsedMessage<T> {
    head: MessageHead<T>,
    decode: DecodedLength,
    expect_continue: bool,
    keep_alive: bool,
    wants_upgrade: bool,
}

pub(crate) struct ParseContext<'a> {
    req_method: &'a mut Option<Method>,
    h1_parser_config: ParserConfig,
    h1_max_headers: Option<usize>,
    h1_max_header_size: Option<usize>,
    h09_responses: bool,
    on_informational: &'a mut Option<OnInformational>,
    /// This can be consumed but we pass this as mut ref to prevent cloning in parse loops.
    /// These extensions have been prepared with the correct scope and they should be consumed
    /// and used as it without any extra wrapping
    prepared_extensions: &'a mut Option<Extensions>,
}

struct EncodeHead<'a, S> {
    /// HTTP version of the message.
    pub(crate) version: Version,
    /// Subject (request line or status line) of Incoming message.
    pub(crate) subject: S,
    /// Headers of the Incoming message.
    pub(crate) headers: HeaderMap,
    /// Extensions.
    extensions: &'a mut Extensions,
}

/// Passed to `Http1Transaction::encode`.
pub(crate) struct Encode<'a, T> {
    head: EncodeHead<'a, T>,
    body: Option<BodyLength>,
    keep_alive: bool,
    req_method: &'a mut Option<Method>,
    title_case_headers: bool,
    date_header: bool,
    /// Refuse, rather than drop, framing fields on a 2xx to CONNECT.
    strict_connect_framing: bool,
}

/// Extra flags that a request "wants", like expect-continue or upgrades.
#[derive(Clone, Copy, Debug)]
struct Wants(u8);

impl Wants {
    const EMPTY: Self = Self(0b00);
    const EXPECT: Self = Self(0b01);
    const UPGRADE: Self = Self(0b10);

    #[must_use]
    fn add(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    fn contains(self, other: Self) -> bool {
        (self.0 & other.0) == other.0
    }
}

#[cfg(test)]
pub(crate) mod test_util {
    use super::{Http1Transaction, ParseContext, ParseResult, ServerTransaction};
    use crate::proto::RequestLine;
    use rama_core::{bytes::BytesMut, extensions::Extensions};
    use rama_http_types::HeaderMap;
    use rama_net::uri::Uri;
    #[cfg(feature = "quic")]
    use {
        super::{ClientTransaction, Encode, EncodeHead},
        rama_http_types::{Method, Version},
    };

    fn parse(raw: &str) -> ParseResult<RequestLine> {
        ServerTransaction::parse(
            &mut BytesMut::from(raw),
            ParseContext {
                req_method: &mut None,
                h1_parser_config: Default::default(),
                h1_max_headers: None,
                h1_max_header_size: None,
                h09_responses: false,
                on_informational: &mut None,
                prepared_extensions: &mut Some(Extensions::default()),
            },
        )
    }

    /// The target and headers an HTTP/1 server receives for `raw`.
    pub(crate) fn receive(raw: &str) -> (Uri, HeaderMap) {
        let head = parse(raw).unwrap().unwrap().head;
        (head.subject.1, head.headers)
    }

    /// Whether an HTTP/1 server refuses `raw` as malformed.
    #[cfg(feature = "quic")]
    pub(crate) fn refuses(raw: &str) -> bool {
        parse(raw).is_err()
    }

    /// The request head an HTTP/1 client writes, or `None` when it refuses to.
    #[cfg(feature = "quic")]
    pub(crate) fn send(method: Method, uri: Uri) -> Option<String> {
        send_with(method, uri, HeaderMap::new())
    }

    /// [`send`] with the request's own header fields.
    #[cfg(feature = "quic")]
    pub(crate) fn send_with(method: Method, uri: Uri, headers: HeaderMap) -> Option<String> {
        let mut extensions = Extensions::default();
        let mut dst = Vec::new();
        ClientTransaction::encode(
            Encode {
                head: EncodeHead {
                    version: Version::HTTP_11,
                    subject: RequestLine(method, uri),
                    headers,
                    extensions: &mut extensions,
                },
                body: None,
                keep_alive: true,
                req_method: &mut None,
                title_case_headers: false,
                date_header: false,
                strict_connect_framing: false,
            },
            &mut dst,
        )
        .ok()?;
        String::from_utf8(dst).ok()
    }
}
