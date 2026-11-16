use rama_core::extensions::Extension;

/// Marks an HTTP/1 message after which the connection cannot be reused.
///
/// HTTP/1 codecs derive this from the HTTP version and all `Connection`
/// fields. A client request's close intent is carried onto its corresponding
/// response so pools and relays can retire the connection synchronously,
/// without racing the connection driver shutdown.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Extension)]
#[extension(tags(http))]
pub struct ConnectionClose;
