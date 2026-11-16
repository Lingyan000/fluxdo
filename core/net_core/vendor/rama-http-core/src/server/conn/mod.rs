//!  Server connection API.
//!
//! The types in this module are to provide a lower-level API based around a
//! single connection. Accepting a connection and binding it with a service
//! are not handled at this level. This module provides the building blocks to
//! customize those things externally.
//!
//! This module is split by HTTP version, providing a connection builder for
//! each. They work similarly, but they each have specific options.
//!
//! If your server needs to support both versions, an auto-connection builder is
//! provided in the `auto` module of this crate.
//!
//! This builder wraps the HTTP/1 and HTTP/2 connection builders from this
//! module, allowing you to set configuration for both. The builder will then check
//! the version of the incoming connection and serve it accordingly.

pub mod http1;
pub mod http2;

pub mod auto;

pub(crate) mod timeout;
pub use self::timeout::{HeaderReadTimeout, IdleTimeout};

#[cfg(feature = "fuzz-utils")]
use std::time::Duration;

/// Evaluate a request-head budget for bounded fuzz harnesses.
#[cfg(feature = "fuzz-utils")]
#[doc(hidden)]
pub fn fuzz_head_allowance(
    config: &HeaderReadTimeout,
    rtt: Option<Duration>,
    bytes: u64,
) -> Duration {
    timeout::HeadBudget::new(config, rtt).allowance(bytes)
}

/// Drive connection deadlines through `steps` of (delay in ms, kind, value) and
/// report whether every observation matches the history-based reference.
#[cfg(feature = "fuzz-utils")]
#[doc(hidden)]
#[must_use]
pub fn fuzz_conn_deadlines(
    idle: Option<IdleTimeout>,
    head: Option<HeaderReadTimeout>,
    steps: &[(u16, u8, u16)],
) -> bool {
    timeout::model::conforms(idle, head, steps)
}
