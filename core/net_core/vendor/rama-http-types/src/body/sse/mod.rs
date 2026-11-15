//! Server-Sent Events (SSE) support
//!
//! ## Server-Sent Events (SSE)
//!
//! Server-Sent Events (SSE) is a simple and efficient mechanism for servers to push real-time updates to
//! clients over HTTP. Unlike WebSockets, which provide full-duplex communication,
//! SSE establishes a one-way channel from server to client using a long-lived HTTP connection.
//!
//! Rama offers support for `SSE` both as a client and a server.
//! As such you could even MITM proxy it.
//!
//! Server `IntoResponse` support is also supported, including with `Keep-Alive` support.
//! See <https://ramaproxy.org/docs/rama/http/service/web/response/struct.Sse.html> for more info.
//!
//! Learn more about SSE at <https://ramaproxy.org/book/sse.html>.
//!
//! ## Examples
//!
//! You can find ready-to-run examples demonstrating how to expose and consume SSE endpoints using Rama:
//!
//! - [`http_sse.rs`](https://github.com/plabayo/rama/blob/main/examples/src/http_sse.rs)
//!   Simple example showing how to expose an SSE endpoint with string data.
//! - [`http_sse_json.rs`](https://github.com/plabayo/rama/blob/main/examples/src/http_sse_json.rs)
//!   Same as above, but emits **structured JSON data** using typed Rust structs.
//!
//! These examples make use of Rama's typed header support, such as [`LastEventId`](https://github.com/plabayo/rama/blob/main/rama-http-headers/src/common/last_event_id.rs), which allows easy extraction of reconnect state to resume streams reliably.
//!
//! ## Datastar
//!
//! > Datastar helps you build reactive web applications with the simplicity of server-side rendering and the power of a full-stack SPA framework.
//! >
//! > — <https://data-star.dev/>
//!
//! Rama has built-in support for [🚀 Datastar](https://data-star.dev).
//! You can see it in action in [Examples](https://github.com/plabayo/rama/tree/main/examples):
//!
//! - [/examples/src/http_sse_datastar_hello.rs](https://github.com/plabayo/rama/tree/main/examples/src/http_sse_datastar_hello.rs):
//!   SSE Example, showcasing a very simple datastar example,
//!   which is supported by rama both on the client as well as the server side.
//! - [/examples/src/http_sse_datastar_svg.rs](https://github.com/plabayo/rama/tree/main/examples/src/http_sse_datastar_svg.rs):
//!   Minimal example of server-rendered SVG updates.
//!
//! Rama rust docs:
//!
//! - SSE support: [datastar]
//! - Extractor support (`ReadSignals`): <https://ramaproxy.org/docs/rama/http/service/web/extract/datastar/index.html>
//! - Embedded JS Script: <https://ramaproxy.org/docs/rama/http/service/web/response/struct.DatastarScript.html>
//!
//! ## Code Origins
//!
//! Some code in this repo is adapted from third party sources:
//! - Axum (see <https://github.com/plabayo/rama/blob/main/docs/thirdparty/fork/README.md#relative-forks>)
//! - <https://github.com/jpopesculian/eventsource-stream/tree/3d46f1c758f9ee4681e9da0427556d24c53f9c01>:
//!   - Licensed under MIT OR Apache-2.0, owned by Julian Popescu <jpopesculian@gmail.com>

mod decoder;
mod event;
mod event_data;
mod event_stream;
mod parser;

#[doc(inline)]
pub use {
    decoder::{EventDecoder, Events, OnIncompleteLine},
    event::{Event, EventBuildError},
    event_data::{
        EventDataJsonReader, EventDataLineReader, EventDataMultiLineReader, EventDataRead,
        EventDataStringReader, EventDataWrite, JsonEventData,
    },
    event_stream::EventStream,
};

/// Build an [`Event`] for tests, shared by the decoder and stream suites.
#[cfg(test)]
macro_rules! test_event {
    (
        $data:expr,
        $(event = $name:literal,)*
        $(id = $id:literal,)*
        $(comment = $comment:literal,)*
    ) => {
        {
            #[allow(unused_mut)]
            let mut event = $crate::sse::Event {
                data: Some($data),
                ..Default::default()
            };
            $(
                event.try_set_event($name).unwrap();
            )*
            $(
                event.try_set_id($id).unwrap();
            )*
            $(
                event.try_set_comment($comment).unwrap();
            )*
            event
        }
    };
    (
        @,
        $(event = $name:literal,)*
        $(id = $id:literal,)*
        $(comment = $comment:literal,)*
    ) => {
        {
            #[allow(unused_mut)]
            let mut event = <$crate::sse::Event<String>>::default();
            $(
                event.try_set_event($name).unwrap();
            )*
            $(
                event.try_set_id($id).unwrap();
            )*
            $(
                event.try_set_comment($comment).unwrap();
            )*
            event
        }
    };
}

#[cfg(test)]
pub(crate) use test_event;

pub mod server;

pub mod datastar;
