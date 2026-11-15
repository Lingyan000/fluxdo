//! HTTP Client.
//!
//! rama_http_core provides HTTP over a single connection. See the [`conn`] module.

#[cfg(test)]
mod tests;

pub mod conn;
pub(super) mod dispatch;
