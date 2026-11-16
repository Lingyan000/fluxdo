use rama_core::bytes::{BufMut as _, Bytes, BytesMut};
use rama_core::error::{BoxError, ErrorContext as _};
use rama_utils::macros::generate_set_and_with;
use rama_utils::str::smol_str::SmolStr;
use std::{fmt, time::Duration};

use super::{EventDataWrite, JsonEventData, event_data::LinePrefixWriter};

/// Server-sent event
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Event<T = String> {
    pub(super) event: Option<SmolStr>,
    pub(super) id: Option<SmolStr>,
    pub(super) data: Option<T>,
    pub(super) retry: Option<Duration>,
    pub(super) comments: Option<Vec<SmolStr>>,
}

impl<T> Default for Event<T> {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug)]
pub struct EventBuildError {
    kind: EventBuildErrorKind,
}

impl EventBuildError {
    pub(super) fn invalid_characters(chars: SmolStr) -> Self {
        Self {
            kind: EventBuildErrorKind::InvalidCharacter(chars),
        }
    }
}

#[derive(Debug)]
enum EventBuildErrorKind {
    InvalidCharacter(SmolStr),
}

impl fmt::Display for EventBuildError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.kind {
            EventBuildErrorKind::InvalidCharacter(s) => {
                write!(f, "event build error: invalid character(s): {s}")
            }
        }
    }
}

impl std::error::Error for EventBuildError {}

impl<T> Event<T> {
    /// Create a new [`Event`].
    #[must_use]
    pub fn new() -> Self {
        Self {
            event: None,
            id: None,
            data: None,
            retry: None,
            comments: None,
        }
    }
}

/// Pre-reservation cap for the advisory data size hint; larger payloads
/// simply grow the buffer from here on.
const DATA_SIZE_HINT_CAP: usize = rama_utils::octets::mib(1);

impl<T: EventDataWrite> Event<T> {
    pub(super) fn serialize(&self) -> Result<Bytes, BoxError> {
        // pre-reserve using the exactly-known field sizes; the data hint
        // gets 1/8 slack for the `data: ` prefixes inserted at inner
        // newlines (unknown up front), enough for lines of 48+ bytes
        let mut capacity = 4;
        for comment in self.comments.iter().flatten() {
            capacity += comment.len() + 4;
        }
        if let Some(ref id) = self.id {
            capacity += id.len() + 6;
        }
        if let Some(ref event) = self.event {
            capacity += event.len() + 9;
        }
        if self.retry.is_some() {
            capacity += 28;
        }
        if let Some(hint) = self.data.as_ref().and_then(|data| data.size_hint()) {
            // the hint is advisory (a custom impl can get it wrong): clamp
            // so it can neither overflow nor drive an absurd reservation
            let hint = hint.min(DATA_SIZE_HINT_CAP);
            capacity += hint + hint / 8 + 8;
        }
        let mut buffer = BytesMut::with_capacity(capacity);

        let mut serialize = |name, value| {
            buffer.extend_from_slice(name);
            buffer.put_u8(b':');
            buffer.put_u8(b' ');
            buffer.extend_from_slice(value);
            buffer.put_u8(b'\n');
        };

        for comment in self.comments.iter().flatten() {
            serialize(b"", comment.as_bytes());
        }
        if let Some(ref id) = self.id {
            serialize(b"id", id.as_bytes());
        }

        if let Some(ref event) = self.event {
            serialize(b"event", event.as_bytes());
        }

        if let Some(retry) = self.retry {
            let mut buf = itoa::Buffer::new();
            serialize(b"retry", buf.format(retry.as_millis()).as_bytes());
        }

        let mut buffer = match &self.data {
            Some(data) => {
                buffer.extend_from_slice(b"data");
                buffer.put_u8(b':');
                buffer.put_u8(b' ');

                let mut buf_write = buffer.writer();
                let mut prefix_writer = LinePrefixWriter::new(&mut buf_write, b"data: ");
                data.write_data(&mut prefix_writer)?;
                prefix_writer.finish()?;
                let mut buffer = buf_write.into_inner();
                buffer.put_u8(b'\n');
                buffer
            }
            None => buffer,
        };

        if !buffer.is_empty() {
            buffer.put_u8(b'\n');
        }

        Ok(buffer.freeze())
    }
}

impl<T> Event<T> {
    /// Return the event's identifier field (`id:<identifier>`).
    ///
    /// This corresponds to [`MessageEvent`'s `lastEventId` field]. If no ID is in the event itself,
    /// the browser will set that field to the last known message ID, starting with the empty
    /// string.
    ///
    /// [`MessageEvent`'s `lastEventId` field]: https://developer.mozilla.org/en-US/docs/Web/API/MessageEvent/lastEventId
    pub fn id(&self) -> Option<&str> {
        self.id.as_deref()
    }

    generate_set_and_with! {
        /// Set the event's identifier field (`id:<identifier>`).
        ///
        /// This corresponds to [`MessageEvent`'s `lastEventId` field]. If no ID is in the event itself,
        /// the browser will set that field to the last known message ID, starting with the empty
        /// string.
        ///
        /// Previously set value will be overwritten.
        ///
        /// [`MessageEvent`'s `lastEventId` field]: https://developer.mozilla.org/en-US/docs/Web/API/MessageEvent/lastEventId
        pub fn id(mut self, id: impl Into<SmolStr>) -> Result<Self, EventBuildError> {
            let id = id.into();
            if id.contains(['\n', '\r', '\0']) {
                return Err(EventBuildError::invalid_characters(id));
            }
            self.id = Some(id);
            Ok(self)
        }
    }

    /// Return the event's data field(s) (`data: <content>`)
    ///
    /// This corresponds to [`MessageEvent`'s data field].
    ///
    /// [`MessageEvent`'s data field]: https://developer.mozilla.org/en-US/docs/Web/API/MessageEvent/data
    pub fn data(&self) -> Option<&T> {
        self.data.as_ref()
    }

    /// Consume `self` and return the event's data field(s) (`data: <content>`)
    ///
    /// This corresponds to [`MessageEvent`'s data field].
    ///
    /// [`MessageEvent`'s data field]: https://developer.mozilla.org/en-US/docs/Web/API/MessageEvent/data
    pub fn into_data(self) -> Option<T> {
        self.data
    }

    generate_set_and_with! {
        /// Set the event's data field(s) (`data: <content>`)
        ///
        /// The serialized data will automatically break newlines across `data: ` fields.
        ///
        /// This corresponds to [`MessageEvent`'s data field].
        ///
        /// Note that events with an empty data field will be ignored by the browser.
        /// Previously set value will be overwritten.
        ///
        /// [`MessageEvent`'s data field]: https://developer.mozilla.org/en-US/docs/Web/API/MessageEvent/data
        pub fn data(mut self, data: T) -> Self {
            self.data = Some(data);
            self
        }
    }

    /// Return the event's name field (`event:<event-name>`).
    ///
    /// This corresponds to the `type` parameter given when calling `addEventListener` on an
    /// [`EventSource`]. For example, `.event("update")` should correspond to
    /// `.addEventListener("update", ...)`. If no event type is given, browsers will fire a
    /// [`message` event] instead.
    ///
    /// [`EventSource`]: https://developer.mozilla.org/en-US/docs/Web/API/EventSource
    /// [`message` event]: https://developer.mozilla.org/en-US/docs/Web/API/EventSource/message_event
    pub fn event(&self) -> Option<&str> {
        self.event.as_deref()
    }

    generate_set_and_with! {
        /// Set the event's name field (`event:<event-name>`).
        ///
        /// Previously set event will be overwritten.
        ///
        /// This corresponds to the `type` parameter given when calling `addEventListener` on an
        /// [`EventSource`]. For example, `.event("update")` should correspond to
        /// `.addEventListener("update", ...)`. If no event type is given, browsers will fire a
        /// [`message` event] instead.
        ///
        /// [`EventSource`]: https://developer.mozilla.org/en-US/docs/Web/API/EventSource
        /// [`message` event]: https://developer.mozilla.org/en-US/docs/Web/API/EventSource/message_event
        pub fn event(mut self, event: impl Into<SmolStr>) -> Result<Self, EventBuildError> {
            let event = event.into();
            if event.contains(['\n', '\r']) {
                return Err(EventBuildError::invalid_characters(event));
            }
            self.event = Some(event);
            Ok(self)
        }
    }

    /// Return the event's retry timeout field (`retry:<timeout>`).
    ///
    /// This sets how long clients will wait before reconnecting if they are disconnected from the
    /// SSE endpoint. Note that this is just a hint: clients are free to wait for longer if they
    /// wish, such as if they implement exponential backoff.
    pub fn retry(&self) -> Option<Duration> {
        self.retry
    }

    generate_set_and_with! {
        /// Set the event's retry timeout field (`retry:<timeout>`).
        ///
        /// Previously set retry will be overwritten.
        ///
        /// This sets how long clients will wait before reconnecting if they are disconnected from the
        /// SSE endpoint. Note that this is just a hint: clients are free to wait for longer if they
        /// wish, such as if they implement exponential backoff.
        pub const fn static_retry(mut self, millis: u64) -> Self {
            self.retry = Some(Duration::from_millis(millis));
            self
        }
    }

    generate_set_and_with! {
        /// Set the event's retry timeout field (`retry:<timeout>`).
        ///
        /// Previously set retry will be overwritten.
        ///
        /// This sets how long clients will wait before reconnecting if they are disconnected from the
        /// SSE endpoint. Note that this is just a hint: clients are free to wait for longer if they
        /// wish, such as if they implement exponential backoff.
        pub fn retry(mut self, millis: u64) -> Self {
            self.retry = Some(Duration::from_millis(millis));
            self
        }
    }

    /// Return the event's comment fields (`:<comment-text>`).
    pub fn comment(&self) -> impl Iterator<Item = &str> {
        self.comments.iter().flatten().map(|s| s.as_str())
    }

    generate_set_and_with! {
        /// Set the event's comment field (`:<comment-text>`).
        ///
        /// This field will be ignored by most SSE clients.
        ///
        /// You can add as many comments as you want by calling this function as many as you wish,
        /// unlike other setters this one does not overwrite.
        pub fn comment(mut self, comment: impl Into<SmolStr>) -> Result<Self, EventBuildError> {
            let comment = comment.into();
            if comment.contains(['\n', '\r']) {
                return Err(EventBuildError::invalid_characters(comment));
            }
            self.comments.get_or_insert_default().push(comment);
            Ok(self)
        }
    }
}

impl Event {
    generate_set_and_with! {
        /// Use [`JsonEventData`] as a shortcut to serialize it directly
        /// into a [`String`] using [`Self::data`].
        pub fn json_data(mut self, data: impl serde::Serialize) -> Result<Self, BoxError> {
            let mut v = Vec::new();
            JsonEventData(data).write_data(&mut v)?;
            self.data = Some(String::from_utf8(v).context("utf8 error")?);
            Ok(self)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct ChunkedData<'a>(&'a [&'a [u8]]);

    impl EventDataWrite for ChunkedData<'_> {
        fn write_data(&self, w: &mut impl std::io::Write) -> Result<(), BoxError> {
            for chunk in self.0 {
                w.write_all(chunk)?;
            }
            Ok(())
        }
    }

    #[test]
    fn serializes_all_line_endings_without_extra_data_lines() {
        for (chunks, expected) in [
            (
                &[b"first\nsecond".as_slice()][..],
                b"data: first\ndata: second\n\n".as_slice(),
            ),
            (
                &[b"first\rsecond".as_slice()][..],
                b"data: first\rdata: second\n\n".as_slice(),
            ),
            (
                &[b"first\r\nsecond".as_slice()][..],
                b"data: first\r\ndata: second\n\n".as_slice(),
            ),
            (
                &[b"first\r".as_slice(), b"\nsecond".as_slice()][..],
                b"data: first\r\ndata: second\n\n".as_slice(),
            ),
            (
                &[b"first\r".as_slice()][..],
                b"data: first\rdata: \n\n".as_slice(),
            ),
        ] {
            let bytes = Event::new()
                .with_data(ChunkedData(chunks))
                .serialize()
                .unwrap();
            assert_eq!(&bytes[..], expected);
        }
    }

    /// A wildly wrong custom size hint must stay advisory: serialization
    /// neither overflows nor pre-reserves anywhere near the claimed size.
    #[test]
    fn absurd_data_size_hint_stays_advisory() {
        struct LyingHint;

        impl EventDataWrite for LyingHint {
            fn write_data(&self, w: &mut impl std::io::Write) -> Result<(), BoxError> {
                w.write_all(b"x").map_err(Into::into)
            }

            fn size_hint(&self) -> Option<usize> {
                Some(usize::MAX)
            }
        }

        let bytes = Event::new().with_data(LyingHint).serialize().unwrap();
        assert_eq!(&bytes[..], b"data: x\n\n".as_slice());

        // multiline hint aggregation saturates instead of overflowing
        assert_eq!(Some(usize::MAX), [LyingHint, LyingHint].size_hint());
    }

    #[test]
    fn builders_validate_and_expose_event_fields() {
        let event = Event::new()
            .try_with_event("update")
            .unwrap()
            .try_with_id("42")
            .unwrap()
            .with_retry(2_000)
            .try_with_comment("ready")
            .unwrap()
            .with_data("payload".to_owned());

        assert_eq!(event.event(), Some("update"));
        assert_eq!(event.id(), Some("42"));
        assert_eq!(event.retry(), Some(Duration::from_millis(2_000)));
        assert_eq!(event.comment().collect::<Vec<_>>(), ["ready"]);
        assert_eq!(event.data().map(String::as_str), Some("payload"));
        assert_eq!(event.into_data().as_deref(), Some("payload"));

        Event::<String>::new()
            .try_with_event("bad\nevent")
            .unwrap_err();
        Event::<String>::new().try_with_id("bad\0id").unwrap_err();
        Event::<String>::new()
            .try_with_comment("bad\rcomment")
            .unwrap_err();
    }

    #[test]
    fn json_data_serializes_values() {
        let event = Event::new()
            .try_with_json_data(serde_json::json!({"answer": 42}))
            .unwrap();

        assert_eq!(event.data().map(String::as_str), Some(r#"{"answer":42}"#));
    }
}
