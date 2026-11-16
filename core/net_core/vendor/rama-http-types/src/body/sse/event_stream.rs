use super::{Event, EventDataRead, EventDecoder, OnIncompleteLine};

use pin_project_lite::pin_project;
use rama_core::error::BoxError;
use rama_core::error_sink::ErrorSink;
use rama_core::futures::stream::Stream;
use rama_core::futures::task::{Context, Poll};
use rama_utils::macros::generate_set_and_with;
use rama_utils::str::smol_str::SmolStr;
use std::fmt;
use std::pin::Pin;
use std::sync::Arc;

/// Cooperative budget for input bytes pushed into the decoder by one
/// `poll_next` call.
const POLL_BYTES_SOFT_CAP: usize = rama_utils::octets::mib(1);

/// Byte accounting alone cannot bound a stream of ready empty/tiny chunks.
const POLL_UPSTREAM_ITEMS_SOFT_CAP: usize = 64;

pin_project! {
    /// Decode a stream of byte chunks into SSE events.
    ///
    /// Wraps [`EventDecoder`], which can also inspect borrowed chunks directly.
    ///
    /// Input is unlimited by default. Set [`max_line_len`](Self::with_max_line_len)
    /// and [`max_event_len`](Self::with_max_event_len) for limits per line and event.
    /// [`BodyLimit`] or [`Body::limited`] instead caps the entire body, terminating
    /// even a long-lived stream once that budget is exhausted.
    ///
    /// [`BodyLimit`]: crate::BodyLimit
    /// [`Body::limited`]: crate::Body::limited
    pub struct EventStream<S, T: EventDataRead = String> {
        #[pin]
        stream: S,
        decoder: EventDecoder<T>,
        // tail of an upstream chunk left over from this poll's byte budget,
        // pushed into the decoder before the upstream stream is polled again
        overflow: Vec<u8>,
        overflow_offset: usize,
        stream_done: bool,
        terminated: bool,
    }
}

impl<S, T> fmt::Debug for EventStream<S, T>
where
    S: fmt::Debug,
    T: EventDataRead + fmt::Debug,
    T::Reader: fmt::Debug,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("EventStream")
            .field("stream", &self.stream)
            .field("decoder", &self.decoder)
            .field("overflow", &self.overflow.len())
            .field("overflow_offset", &self.overflow_offset)
            .field("stream_done", &self.stream_done)
            .field("terminated", &self.terminated)
            .finish()
    }
}

impl<S, T: EventDataRead> EventStream<S, T> {
    /// Initialize the EventStream with a Stream
    pub fn new(stream: S) -> Self {
        Self {
            stream,
            decoder: EventDecoder::new(),
            overflow: Vec::new(),
            overflow_offset: 0,
            stream_done: false,
            terminated: false,
        }
    }

    generate_set_and_with! {
        /// Fail decoding once a single line grows past `max` bytes,
        /// terminator excluded.
        ///
        /// See [`EventDecoder::with_max_line_len`].
        pub fn max_line_len(mut self, max: Option<usize>) -> Self {
            self.decoder.maybe_set_max_line_len(max);
            self
        }
    }

    generate_set_and_with! {
        /// Fail decoding once the lines accumulated into one event grow
        /// past `max` bytes.
        ///
        /// See [`EventDecoder::with_max_event_len`].
        pub fn max_event_len(mut self, max: Option<usize>) -> Self {
            self.decoder.maybe_set_max_event_len(max);
            self
        }
    }

    generate_set_and_with! {
        /// Pass a nonempty buffered partial line to `cb` at most once,
        /// when the body ends or the stream is dropped.
        ///
        /// See [`EventDecoder::with_on_incomplete`].
        pub fn on_incomplete(mut self, cb: Option<OnIncompleteLine>) -> Self {
            self.decoder.maybe_set_on_incomplete(cb);
            self
        }
    }

    generate_set_and_with! {
        /// Recover from a decode fault instead of ending the stream, skipping
        /// to the next event boundary.
        ///
        /// See [`EventDecoder::with_lenient`].
        pub fn lenient(mut self, lenient: bool) -> Self {
            self.decoder.set_lenient(lenient);
            self
        }
    }

    generate_set_and_with! {
        /// Route each resync in [`lenient`](Self::with_lenient) mode to an
        /// [`ErrorSink`].
        ///
        /// See [`EventDecoder::with_on_resync`].
        pub fn on_resync(mut self, sink: Option<Arc<dyn ErrorSink>>) -> Self {
            self.decoder.maybe_set_on_resync(sink);
            self
        }
    }

    /// Set the last event ID of the stream. Useful for initializing the stream with a previous
    /// last event ID
    pub fn try_set_last_event_id(&mut self, id: impl Into<SmolStr>) -> Result<(), BoxError> {
        self.decoder.try_set_last_event_id(id)
    }

    /// Get the last event ID of the stream
    pub fn last_event_id(&self) -> Option<&str> {
        self.decoder.last_event_id()
    }

    /// How many resyncs have happened in [`lenient`](Self::with_lenient) mode.
    ///
    /// See [`EventDecoder::resync_count`].
    #[must_use]
    pub fn resync_count(&self) -> usize {
        self.decoder.resync_count()
    }
}

impl<S, B, E, T> Stream for EventStream<S, T>
where
    S: Stream<Item = Result<B, E>>,
    E: Into<BoxError>,
    B: AsRef<[u8]>,
    T: EventDataRead,
{
    type Item = Result<Event<T>, BoxError>;

    fn poll_next(self: Pin<&mut Self>, cx: &mut Context) -> Poll<Option<Self::Item>> {
        let mut this = self.project();
        let mut pushed_bytes = 0;
        let mut upstream_items = 0;

        loop {
            match this.decoder.next_event() {
                Ok(Some(event)) => return Poll::Ready(Some(Ok(event))),
                Ok(None) => (),
                Err(err) => {
                    // a decode error is fatal: the byte stream can no longer
                    // be interpreted reliably beyond this point
                    *this.terminated = true;
                    return Poll::Ready(Some(Err(err)));
                }
            }
            if *this.terminated {
                return Poll::Ready(None);
            }

            if pushed_bytes >= POLL_BYTES_SOFT_CAP || upstream_items >= POLL_UPSTREAM_ITEMS_SOFT_CAP
            {
                cx.waker().wake_by_ref();
                return Poll::Pending;
            }

            // push a set-aside chunk tail before polling upstream again
            if *this.overflow_offset < this.overflow.len() {
                let start = *this.overflow_offset;
                let end = (start + POLL_BYTES_SOFT_CAP - pushed_bytes).min(this.overflow.len());
                let result = this.decoder.push(&this.overflow[start..end]);
                pushed_bytes += end - start;
                *this.overflow_offset = end;
                if end >= this.overflow.len() {
                    this.overflow.clear();
                    *this.overflow_offset = 0;
                }
                if let Err(err) = result {
                    *this.terminated = true;
                    return Poll::Ready(Some(Err(err)));
                }
                continue;
            }

            if *this.stream_done {
                *this.terminated = true;
                if let Err(err) = this.decoder.finish() {
                    return Poll::Ready(Some(Err(err)));
                }
                continue;
            }

            match this.stream.as_mut().poll_next(cx) {
                Poll::Ready(Some(Ok(chunk))) => {
                    upstream_items += 1;
                    let bytes = chunk.as_ref();
                    let budget = POLL_BYTES_SOFT_CAP - pushed_bytes;
                    let (offered, rest) = bytes.split_at(bytes.len().min(budget));
                    pushed_bytes += offered.len();
                    this.overflow.extend_from_slice(rest);
                    if let Err(err) = this.decoder.push(offered) {
                        *this.terminated = true;
                        return Poll::Ready(Some(Err(err)));
                    }
                }
                Poll::Ready(Some(Err(err))) => {
                    // transport errors pass through without terminating the
                    // decoder: the caller decides whether to keep polling
                    return Poll::Ready(Some(Err(err.into())));
                }
                Poll::Ready(None) => {
                    *this.stream_done = true;
                }
                Poll::Pending => return Poll::Pending,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::allow_attributes,
        reason = "test macros use `#[allow(unused_mut)]` because the binding is mutated only by some variadic arms — `#[expect]` would warn unfulfilled when no arm fires"
    )]

    use crate::sse::{JsonEventData, test_event as event};
    use std::assert_matches;

    use super::*;
    use rama_core::futures::prelude::*;
    use serde_json::json;
    use std::convert::Infallible;
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    use std::task::{Wake, Waker};

    #[derive(Default)]
    struct WakeCounter(AtomicUsize);

    impl Wake for WakeCounter {
        fn wake(self: Arc<Self>) {
            self.0.fetch_add(1, Ordering::Relaxed);
        }

        fn wake_by_ref(self: &Arc<Self>) {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }

    struct AlwaysReadyEmpty {
        polls: Arc<AtomicUsize>,
    }

    impl Stream for AlwaysReadyEmpty {
        type Item = Result<Vec<u8>, Infallible>;

        fn poll_next(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
            self.polls.fetch_add(1, Ordering::Relaxed);
            Poll::Ready(Some(Ok(Vec::new())))
        }
    }

    #[test]
    fn one_poll_has_a_cumulative_byte_budget() {
        let upstream = stream::iter([Ok::<_, Infallible>(vec![b'x'; POLL_BYTES_SOFT_CAP * 2])]);
        let mut stream = std::pin::pin!(EventStream::<_, String>::new(upstream));
        let wake_count = Arc::new(WakeCounter::default());
        let waker = Waker::from(Arc::clone(&wake_count));
        let mut cx = Context::from_waker(&waker);

        assert_matches!(stream.as_mut().poll_next(&mut cx), Poll::Pending);
        assert_eq!(1, wake_count.0.load(Ordering::Relaxed));
        assert_eq!(POLL_BYTES_SOFT_CAP, stream.overflow.len());

        assert_matches!(stream.as_mut().poll_next(&mut cx), Poll::Pending);
        assert_eq!(2, wake_count.0.load(Ordering::Relaxed));
        assert!(stream.overflow.is_empty());

        assert_matches!(stream.as_mut().poll_next(&mut cx), Poll::Ready(None));
    }

    #[test]
    fn empty_ready_chunks_have_a_poll_attempt_budget() {
        let upstream_polls = Arc::new(AtomicUsize::new(0));
        let upstream = AlwaysReadyEmpty {
            polls: Arc::clone(&upstream_polls),
        };
        let mut stream = std::pin::pin!(EventStream::<_, String>::new(upstream));
        let wake_count = Arc::new(WakeCounter::default());
        let waker = Waker::from(Arc::clone(&wake_count));
        let mut cx = Context::from_waker(&waker);

        assert_matches!(stream.as_mut().poll_next(&mut cx), Poll::Pending);
        assert_eq!(
            POLL_UPSTREAM_ITEMS_SOFT_CAP,
            upstream_polls.load(Ordering::Relaxed)
        );
        assert_eq!(1, wake_count.0.load(Ordering::Relaxed));
    }

    #[tokio::test]
    async fn valid_data_fields() {
        for (input, expected) in [
            (
                vec!["data: Hello, world!\n\n"],
                vec![event!("Hello, world!".to_owned(),)],
            ),
            (
                vec!["data: Hello,", " world!\n\n"],
                vec![event!("Hello, world!".to_owned(),)],
            ),
            (
                vec!["data: Hello,", "", " world!\n\n"],
                vec![event!("Hello, world!".to_owned(),)],
            ),
            (
                vec!["data: Hello,\ndata: world!\n\n"],
                vec![event!("Hello,\nworld!".to_owned(),)],
            ),
            (
                vec!["data: Hello,\n\ndata: world!\n\n"],
                vec![event!("Hello,".to_owned(),), event!("world!".to_owned(),)],
            ),
        ] {
            let stream = EventStream::new(stream::iter(input.iter().map(Ok::<_, Infallible>)));
            let output = stream.try_collect::<Vec<_>>().await.unwrap();
            assert_eq!(expected, output, "input: '{input:?}'; output: '{output:?}'");
        }
    }

    #[tokio::test]
    async fn spec_examples() {
        for (input, expected) in [
            (
                vec![
                    "data: This is the first message.

data: This is the second message, it
data: has two lines.

data: This is the third message.

",
                ],
                vec![
                    event!("This is the first message.".to_owned(),),
                    event!("This is the second message, it\nhas two lines.".to_owned(),),
                    event!("This is the third message.".to_owned(),),
                ],
            ),
            (
                vec![
                    "event: add
data: 73857293

event: remove
data: 2153

event: add
data: 113411

    ",
                ],
                vec![
                    event!("73857293".to_owned(), event = "add",),
                    event!("2153".to_owned(), event = "remove",),
                    event!("113411".to_owned(), event = "add",),
                ],
            ),
            (
                vec![
                    "data: YHOO
data: +2
data: 10

    ",
                ],
                vec![event!("YHOO\n+2\n10".to_owned(),)],
            ),
            (
                vec![
                    ": test stream

data: first event
id: 1

data:second event
id

data:  third event

    ",
                ],
                vec![
                    event!(@, comment = "test stream",),
                    event!("first event".to_owned(), id = "1",),
                    // WHATWG: bare `id` (no value) sets the last-event-ID buffer
                    // to the empty string, so the dispatched event carries
                    // `id = ""` rather than `id = None`.
                    event!("second event".to_owned(), id = "",),
                    event!(" third event".to_owned(),),
                ],
            ),
            (
                vec![
                    "data

data
data

data:
",
                ],
                vec![event!("".to_owned(),), event!("\n".to_owned(),)],
            ),
            (
                vec![
                    "data:test

data: test

",
                ],
                vec![event!("test".to_owned(),), event!("test".to_owned(),)],
            ),
        ] {
            let stream = EventStream::new(stream::iter(input.iter().map(Ok::<_, Infallible>)));
            let expect = format!("input: '{input:?}'");
            let output = stream.try_collect::<Vec<_>>().await.expect(&expect);
            assert_eq!(expected, output, "input: '{input:?}'; output: '{output:?}'");
        }
    }

    /// WHATWG: a bare `event` field (no value) sets the event-type buffer
    /// to the empty string, which dispatches as the default `message` event
    /// — _and_ overrides any earlier `event:` line within the same event.
    #[tokio::test]
    async fn empty_event_field_clears_event_name() {
        let input = "event: ping\nevent\ndata: 42\n\n";
        let stream = EventStream::new(stream::iter([Ok::<_, Infallible>(input)]));
        let output = stream.try_collect::<Vec<_>>().await.unwrap();
        assert_eq!(output, vec![event!("42".to_owned(),)]);
    }

    /// WHATWG: a bare `id` field (no value) sets the last-event-ID buffer
    /// to the empty string; the dispatched event carries `id = ""`.
    #[tokio::test]
    async fn empty_id_field_sets_empty_last_event_id() {
        let input = "id: prior\ndata: a\n\nid\ndata: b\n\n";
        let mut stream = EventStream::new(stream::iter([Ok::<_, Infallible>(input)]));
        let events: Vec<_> = (&mut stream).try_collect::<Vec<_>>().await.unwrap();
        assert_eq!(
            events,
            vec![
                event!("a".to_owned(), id = "prior",),
                event!("b".to_owned(), id = "",),
            ],
        );
        assert_eq!(stream.last_event_id(), Some(""));
    }

    /// WHATWG: an `id` containing U+0000 makes the entire field ignored.
    #[tokio::test]
    async fn id_with_nul_is_ignored() {
        let input = "id: ok\ndata: a\n\nid: bad\u{0000}id\ndata: b\n\n";
        let mut stream = EventStream::new(stream::iter([Ok::<_, Infallible>(input)]));
        let events: Vec<_> = (&mut stream).try_collect::<Vec<_>>().await.unwrap();
        assert_eq!(
            events,
            vec![
                event!("a".to_owned(), id = "ok",),
                // `id` line is ignored: the event has no id, but the
                // last-event-ID buffer keeps the previous value.
                event!("b".to_owned(),),
            ],
        );
        assert_eq!(stream.last_event_id(), Some("ok"));
    }

    /// WHATWG: the last-event-ID buffer persists across events that don't
    /// carry an explicit `id` field.
    #[tokio::test]
    async fn last_event_id_persists_across_events_without_id() {
        let input = "id: seven\ndata: a\n\ndata: b\n\ndata: c\n\n";
        let mut stream = EventStream::new(stream::iter([Ok::<_, Infallible>(input)]));
        let events: Vec<_> = (&mut stream).try_collect::<Vec<_>>().await.unwrap();
        assert_eq!(
            events,
            vec![
                event!("a".to_owned(), id = "seven",),
                event!("b".to_owned(),),
                event!("c".to_owned(),),
            ],
        );
        assert_eq!(stream.last_event_id(), Some("seven"));
    }

    /// WHATWG: the `retry` value MUST consist of only ASCII digits.
    /// Rust's `u64::parse` accepts a leading `+`, which the spec disallows.
    #[tokio::test]
    async fn retry_only_accepts_ascii_digits() {
        for (input, want_retry_ms) in [
            ("retry: 1500\ndata: a\n\n", Some(1500_u64)),
            ("retry: +5\ndata: a\n\n", None),
            ("retry: -1\ndata: a\n\n", None),
            ("retry: 5ms\ndata: a\n\n", None),
            ("retry: abc\ndata: a\n\n", None),
            ("retry:\ndata: a\n\n", None),
        ] {
            let stream = EventStream::<_, String>::new(stream::iter([Ok::<_, Infallible>(input)]));
            let events: Vec<_> = stream.try_collect::<Vec<_>>().await.unwrap();
            assert_eq!(events.len(), 1, "input: {input:?}");
            assert_eq!(
                events[0].retry().map(|d| d.as_millis() as u64),
                want_retry_ms,
                "input: {input:?}",
            );
        }
    }

    /// JSON reader on an event without any `data:` line should surface
    /// `Ok(None)` rather than erroring on `serde_json::from_str("")`.
    #[tokio::test]
    async fn json_reader_surfaces_none_when_no_data() {
        // Two events: the first carries no data field at all.
        let input = ": preamble\nid: 1\n\ndata: {\"v\":2}\nid: 2\n\n";
        let stream = EventStream::<_, JsonEventData<serde_json::Value>>::new(stream::iter([Ok::<
            _,
            Infallible,
        >(
            input,
        )]));
        let events: Vec<_> = stream.try_collect::<Vec<_>>().await.unwrap();
        assert_eq!(events.len(), 2);
        assert!(events[0].data().is_none());
        assert_eq!(events[1].data().map(|d| d.0.clone()), Some(json!({"v": 2})),);
    }

    /// The stream passes the trailing-line handler through to the decoder,
    /// which fires it when the body ends.
    #[tokio::test]
    async fn the_incomplete_trailing_line_is_handed_over() {
        let seen = Arc::new(std::sync::OnceLock::new());
        let sink = Arc::clone(&seen);

        let input = "data: a\n\ndata: cut";
        let stream = EventStream::<_, String>::new(stream::iter([Ok::<_, Infallible>(input)]))
            .with_on_incomplete(Box::new(move |line| drop(sink.set(line))));

        let events = stream.try_collect::<Vec<_>>().await.unwrap();
        assert_eq!(events, vec![event!("a".to_owned(),)]);
        assert_eq!(seen.get().map(Vec::as_slice), Some(&b"data: cut"[..]));
    }

    /// A stream abandoned mid-body — a client that stops reading — still
    /// hands over the partial line it was holding, on drop.
    #[tokio::test]
    async fn an_abandoned_stream_hands_over_its_partial_line() {
        let seen = Arc::new(std::sync::OnceLock::new());
        let sink = Arc::clone(&seen);

        let mut stream = EventStream::<_, String>::new(stream::iter([
            Ok::<_, Infallible>("data: a\n\ndata: par"),
            Ok::<_, Infallible>("tial"),
        ]))
        .with_on_incomplete(Box::new(move |line| drop(sink.set(line))));

        // read the one complete event, then walk away mid-body
        let event = stream.next().await.unwrap().unwrap();
        assert_eq!(event, event!("a".to_owned(),));
        assert!(seen.get().is_none());

        drop(stream);
        assert_eq!(seen.get().map(Vec::as_slice), Some(&b"data: par"[..]));
    }

    /// The per-line and per-event limits are decoder settings; the stream
    /// only has to pass them through.
    #[tokio::test]
    async fn limits_are_passed_through_to_the_decoder() {
        let input = "data: 0123456789\n\n";

        let stream = EventStream::<_, String>::new(stream::iter([Ok::<_, Infallible>(input)]))
            .with_max_line_len(8);
        stream.try_collect::<Vec<_>>().await.unwrap_err();

        let stream = EventStream::<_, String>::new(stream::iter([Ok::<_, Infallible>(input)]))
            .with_max_event_len(8);
        stream.try_collect::<Vec<_>>().await.unwrap_err();

        let stream = EventStream::<_, String>::new(stream::iter([Ok::<_, Infallible>(input)]))
            .with_max_line_len(64)
            .with_max_event_len(64);
        let events = stream.try_collect::<Vec<_>>().await.unwrap();
        assert_eq!(events, vec![event!("0123456789".to_owned(),)]);
    }

    #[tokio::test]
    async fn lenient_mode_and_its_resync_sink_pass_through_to_the_decoder() {
        let input = "data: one\n\ndata: 0123456789\n\ndata: three\n\n";

        // strict (the default): the over-long line ends the stream with an error
        // (the cap fits `data: one`/`data: three` but not the long middle line)
        let strict = EventStream::<_, String>::new(stream::iter([Ok::<_, Infallible>(input)]))
            .with_max_line_len(12);
        strict.try_collect::<Vec<_>>().await.unwrap_err();

        // lenient: the bad event is skipped, the rest arrive, and the sink fires
        let resyncs = Arc::new(AtomicUsize::new(0));
        let sink = Arc::clone(&resyncs);
        let lenient = EventStream::<_, String>::new(stream::iter([Ok::<_, Infallible>(input)]))
            .with_max_line_len(12)
            .with_lenient(true)
            .with_on_resync(Arc::new(move |_err: BoxError| {
                sink.fetch_add(1, Ordering::Relaxed);
            }));
        let events = lenient.try_collect::<Vec<_>>().await.unwrap();
        assert_eq!(
            events,
            vec![event!("one".to_owned(),), event!("three".to_owned(),)]
        );
        assert_eq!(1, resyncs.load(Ordering::Relaxed));
    }
}
