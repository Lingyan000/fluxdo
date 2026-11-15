use rama_core::extensions::Extension;

/// Wire form used for an HTTP/1 request target.
///
/// A parsed standalone head carries this extension so protocols such as ICAP
/// can encode the same target form again without inferring it from outbound
/// connector metadata.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Extension)]
#[extension(tags(http))]
#[non_exhaustive]
pub enum RequestTargetForm {
    /// `GET /path?query HTTP/1.1`
    Origin,
    /// `GET http://example.test/path HTTP/1.1`
    Absolute,
    /// `CONNECT example.test:443 HTTP/1.1`
    Authority,
    /// `OPTIONS * HTTP/1.1`
    Asterisk,
}
