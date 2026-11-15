//! Streaming bodies for Requests and Responses.
//!
//! For both [Clients](crate::client) and [Servers](crate::server), requests and
//! responses use streaming bodies, instead of complete buffering. This
//! allows applications to not use memory they don't need, and allows exerting
//! back-pressure on connections by only reading when asked.
//!
//! There are two pieces to this in rama_http_core:
//!
//! - **The [`StreamingBody`] trait** describes all possible bodies.
//!   rama_http_core allows any body type that implements `StreamingBody`, allowing
//!   applications to have fine-grained control over their streaming.
//! - **The [`Incoming`] concrete type**, which is an implementation
//!   of `StreamingBody`, and returned by rama_http_core as a "receive stream" (so, for server
//!   requests and client responses).
//!
//! There are additional implementations available in [`rama_http_types::body::util`],
//! such as a `Full` or `Empty` body
//!
//! ## Reading a body
//!
//! The [`BodyExt`][] extension trait provides an asynchronous way to read the
//! frames of a body. A frame can contain either data or trailers:
//!
//! ```
//! use rama_http_core::{Error, body::Incoming};
//! use rama_http_types::body::util::BodyExt as _;
//!
//! async fn read_body(mut body: Incoming) -> Result<(), Error> {
//!     while let Some(frame) = body.frame().await {
//!         let frame = frame?;
//!
//!         if let Some(data) = frame.data_ref() {
//!             println!("received {} bytes", data.len());
//!         }
//!
//!         if let Some(trailers) = frame.trailers_ref() {
//!             println!("received trailers: {trailers:?}");
//!         }
//!     }
//!
//!     Ok(())
//! }
//! ```
//!
//! A body only advances when it is polled. Processing each frame before
//! polling for the next one preserves back-pressure on the connection.
//!
//! If a body is known to be small, it can be collected into memory instead:
//!
//! ```
//! use rama_http_core::body::{Bytes, Incoming};
//! use rama_http_types::body::{CollectError, util::BodyExt as _};
//!
//! /// Consider using `Limited` if the body is untrusted.
//! async fn read_entire_body(body: Incoming) -> Result<Bytes, CollectError> {
//!     Ok(body.collect().await?.to_bytes())
//! }
//! ```
//!
//! Collecting buffers the whole body, so it should be avoided for large or
//! untrusted bodies unless their size is limited.
//!
//! [`BodyExt`]: rama_http_types::body::util::BodyExt
//! [`StreamingBody`]: rama_http_types::body::StreamingBody

pub use rama_core::bytes::{Buf, Bytes};
pub use rama_http_types::body::{Body, Frame, SizeHint};

pub use self::incoming::Incoming;

pub(crate) use self::chan::Sender;
pub(crate) use self::length::DecodedLength;

mod chan;
mod incoming;
mod length;

fn _assert_send_sync() {
    fn _assert_send<T: Send>() {}
    fn _assert_sync<T: Sync>() {}

    _assert_send::<Incoming>();
    _assert_sync::<Incoming>();
}
