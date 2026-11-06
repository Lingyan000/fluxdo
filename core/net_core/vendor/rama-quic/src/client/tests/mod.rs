//! Tests for client QUIC connections.

mod classify;

#[cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
mod connector;
#[cfg(any(
    feature = "boring",
    all(feature = "rustls", any(feature = "aws-lc", feature = "ring"))
))]
mod endpoint;
