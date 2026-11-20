//! Opentelemetry utilities

use crate::Version;

/// Return the [`Version`] as the OTEL `network.protocol.version`.
///
/// Reference: <https://opentelemetry.io/docs/specs/semconv/registry/attributes/network/>
#[must_use]
pub fn version_as_protocol_version(version: Version) -> &'static str {
    match version {
        Version::HTTP_09 => "0.9",
        Version::HTTP_10 => "1.0",
        Version::HTTP_11 => "1.1",
        Version::HTTP_2 => "2",
        Version::HTTP_3 => "3",
    }
}
