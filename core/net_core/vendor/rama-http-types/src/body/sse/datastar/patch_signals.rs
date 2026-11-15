use crate::sse::{
    Event, EventBuildError, EventDataLineReader, EventDataRead, EventDataWrite,
    datastar::EventType, event_data::LinePrefixWriter,
};
use rama_core::error::BoxErrorExt as _;
use rama_core::error::{BoxError, ErrorContext};
use rama_core::telemetry::tracing;

/// [`PatchSignals`] patches signals into the signal store
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PatchSignals<T = String> {
    /// `signals` is a JavaScript object or JSON string that
    /// will be sent to the browser to update signals in the signals.
    ///
    /// The data ***must*** evaluate to a valid JavaScript.
    /// It will be converted to signals by the Datastar client side.
    pub signals: T,
    /// Whether to merge the signal only if it does not already exist.
    ///
    /// If not provided, the Datastar client side will default to false,
    /// which will cause the data to be merged into the signals.
    pub only_if_missing: bool,
}

impl<T> PatchSignals<T> {
    pub const TYPE: EventType = EventType::PatchSignals;

    /// Create a new [`PatchSignals`] data blob.
    pub fn new(signals: T) -> Self {
        Self {
            signals,
            only_if_missing: false,
        }
    }

    /// Consume `self` as an [`Event`].
    pub fn try_into_sse_event(self) -> Result<Event<Self>, EventBuildError> {
        Ok(Event::new()
            .try_with_event(Self::TYPE.as_smol_str())?
            .with_data(self))
    }

    /// Consume `self` as a [`super::DatastarEvent`].
    pub fn try_into_datastar_event(self) -> Result<super::DatastarEvent<T>, EventBuildError> {
        Ok(Event::new()
            .try_with_event(Self::TYPE.as_smol_str())?
            .with_data(super::EventData::PatchSignals(self)))
    }

    rama_utils::macros::generate_set_and_with! {
        /// Sets whether to merge the signal only if it does not already exist.
        pub fn only_if_missing(mut self, only_if_missing: bool) -> Self {
            self.only_if_missing = only_if_missing;
            self
        }
    }
}

impl<T> TryFrom<PatchSignals<T>> for Event<PatchSignals<T>> {
    type Error = EventBuildError;

    #[inline(always)]
    fn try_from(value: PatchSignals<T>) -> Result<Self, Self::Error> {
        value.try_into_sse_event()
    }
}

impl<T> TryFrom<PatchSignals<T>> for super::DatastarEvent<T> {
    type Error = EventBuildError;

    #[inline(always)]
    fn try_from(value: PatchSignals<T>) -> Result<Self, Self::Error> {
        value.try_into_datastar_event()
    }
}

impl<T: EventDataWrite> EventDataWrite for PatchSignals<T> {
    fn write_data(&self, w: &mut impl std::io::Write) -> Result<(), BoxError> {
        if self.only_if_missing {
            w.write_all(b"onlyIfMissing true\n")
                .context("PatchSignals: write onlyIfMissing")?;
        }

        w.write_all(b"signals ")
            .context("PatchSignals: write signals keyword")?;
        let mut prefix_writer = LinePrefixWriter::new(w, b"signals ");
        self.signals
            .write_data(&mut prefix_writer)
            .context("PatchSignals: write signals value")?;
        prefix_writer
            .finish()
            .context("PatchSignals: finish signals value")?;

        Ok(())
    }
}

/// [`EventDataLineReader`] for the [`EventDataRead`] implementation of [`PatchSignals`].
#[derive(Debug)]
pub struct PatchSignalsReader<R> {
    signals: R,
    only_if_missing: bool,
}

impl<T: EventDataRead> EventDataRead for PatchSignals<T> {
    type Reader = PatchSignalsReader<T::Reader>;

    fn line_reader() -> Self::Reader {
        PatchSignalsReader {
            signals: T::line_reader(),
            only_if_missing: false,
        }
    }
}

impl<R: EventDataLineReader> EventDataLineReader for PatchSignalsReader<R> {
    type Data = PatchSignals<R::Data>;

    fn read_line(&mut self, line: &str) -> Result<(), BoxError> {
        let line = line.trim_start();
        if line.is_empty() {
            return Ok(());
        };

        let (keyword, value) = line
            .split_once(' ')
            // in case of empty value
            .unwrap_or((line, ""));

        if keyword.eq_ignore_ascii_case("signals") {
            self.signals.read_line(value)?;
        } else if keyword.eq_ignore_ascii_case("onlyIfMissing") {
            self.only_if_missing = value
                .parse()
                .context("PatchSignalsReader: parse onlyIfMissing")?;
        } else {
            tracing::debug!(
                "PatchSignalsReader: ignore unknown line: keyword = {}; value = {}",
                keyword,
                value,
            );
        }

        Ok(())
    }

    fn data(&mut self, event: Option<&str>) -> Result<Option<Self::Data>, BoxError> {
        let Some(signals) = self.signals.data(None)? else {
            return Ok(None);
        };

        if !event
            .and_then(|e| {
                e.parse::<EventType>()
                    .ok()
                    .map(|t| t == EventType::PatchSignals)
            })
            .unwrap_or_default()
        {
            return Err(BoxError::from_static_str(
                "PatchSignalsReader: unexpected event type: expected: datastar-patch-signals",
            ));
        }

        let only_if_missing = std::mem::take(&mut self.only_if_missing);
        Ok(Some(PatchSignals {
            signals,
            only_if_missing,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read_patch_signals<T: EventDataRead>(input: &str) -> PatchSignals<T> {
        let mut reader = PatchSignals::<T>::line_reader();
        for line in input.lines() {
            reader.read_line(line).unwrap();
        }
        reader
            .data(Some("datastar-patch-signals"))
            .unwrap()
            .unwrap()
    }

    #[test]
    fn test_deserialize_minimal() {
        let data: PatchSignals<String> = read_patch_signals(r##"signals {answer: 42}"##);
        assert_eq!(data.signals, r##"{answer: 42}"##);
        assert!(!data.only_if_missing);
    }

    #[test]
    fn test_serialize_signals_multiline() {
        let mut buf = Vec::default();
        PatchSignals::new(
            r##"{
"foo": 1,
"bar": false,
}"##,
        )
        .write_data(&mut buf)
        .unwrap();
        let output = String::from_utf8(buf).unwrap();
        assert_eq!(
            r##"signals {
signals "foo": 1,
signals "bar": false,
signals }"##,
            output
        );
    }

    #[test]
    fn test_serialize_options_in_protocol_order() {
        let mut buf = Vec::new();
        PatchSignals::new("{count: 1}")
            .with_only_if_missing(true)
            .write_data(&mut buf)
            .unwrap();

        assert_eq!(
            String::from_utf8(buf).unwrap(),
            "onlyIfMissing true\nsignals {count: 1}"
        );
    }

    #[test]
    fn test_serialize_signals_with_crlf() {
        let mut buf = Vec::new();
        PatchSignals::new("{\r\ncount: 1\r\n}")
            .write_data(&mut buf)
            .unwrap();

        assert_eq!(
            String::from_utf8(buf).unwrap(),
            "signals {\r\nsignals count: 1\r\nsignals }"
        );
    }

    #[test]
    fn test_event_conversions() {
        let patch = PatchSignals::new("{count: 1}".to_owned());

        let event: Event<PatchSignals<String>> = patch.clone().try_into().unwrap();
        assert_eq!(event.event(), Some(EventType::PatchSignals.as_str()));

        let event: crate::body::sse::datastar::DatastarEvent = patch.try_into().unwrap();
        assert_eq!(event.event(), Some(EventType::PatchSignals.as_str()));
    }

    #[test]
    fn test_serialize_deserialize_reflect() {
        let expected_data =
            PatchSignals::new(r##"{a:1,b:{"c":2}}"##.to_owned()).with_only_if_missing(true);

        let mut buf = Vec::new();
        expected_data.write_data(&mut buf).unwrap();

        let input = String::from_utf8(buf).unwrap();
        let data = read_patch_signals(&input);

        assert_eq!(expected_data, data);
    }

    #[test]
    fn test_deserialize_ignores_unknown_and_empty_lines() {
        let data: PatchSignals<String> =
            read_patch_signals("\nunknown value\nonlyIfMissing true\nsignals {count: 1}");

        assert_eq!(
            data,
            PatchSignals::new("{count: 1}".to_owned()).with_only_if_missing(true)
        );
    }

    #[test]
    fn test_deserialize_rejects_invalid_input() {
        let mut reader = PatchSignals::<String>::line_reader();
        assert!(reader.read_line("onlyIfMissing perhaps").is_err());

        let mut reader = PatchSignals::<String>::line_reader();
        reader.read_line("signals {}").unwrap();
        reader.data(Some("datastar-patch-elements")).unwrap_err();

        let mut reader = PatchSignals::<String>::line_reader();
        assert!(
            reader
                .data(Some("datastar-patch-signals"))
                .unwrap()
                .is_none()
        );
    }
}
