use rama_core::extensions::Extension;

/// Prefer close-delimited framing when encoding an HTTP/1 response.
///
/// Insert this extension on the response or its inherited context.
/// The encoder emits neither
/// `Content-Length` nor `Transfer-Encoding`, adds `Connection: close`, streams
/// the body unchanged, and closes the connection when the body ends. An exact
/// body size hint does not override this choice. Like other context extensions,
/// the preference remains effective when middleware derives a response from it.
///
/// Explicit `Content-Length`, `Transfer-Encoding`, or `Trailer` headers take
/// precedence, using the encoder's normal framing and validation rules. Without
/// these headers, the body must not produce trailers. This extension has no effect
/// on responses that cannot carry a body (including HEAD and successful CONNECT)
/// or on HTTP/2 connections.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Extension)]
#[extension(tags(http))]
pub struct CloseDelimitedResponse;

/// Original HTTP/1 response framing, recorded by the client decoder before
/// middleware can remove or change the framing headers.
///
/// Each parsed response receives its own value, overriding inherited metadata.
/// This is informational; inserting it does not change outgoing framing.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Extension)]
#[extension(tags(http))]
#[non_exhaustive]
pub enum OriginalResponseBodyFraming {
    /// No HTTP message body, for example a HEAD response or protocol upgrade.
    Empty,
    /// The response body has an explicit Content-Length.
    ContentLength,
    /// Transfer-Encoding was present, whether or not its final coding is chunked.
    TransferEncoded,
    /// A body delimited by EOF, with neither Content-Length nor Transfer-Encoding.
    CloseDelimited,
}
