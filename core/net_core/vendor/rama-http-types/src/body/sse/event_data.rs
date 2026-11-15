use rama_core::error::{BoxError, ErrorContext};
use rama_utils::{macros::impl_deref, str::arcstr::ArcStr};
use std::{fmt, marker::PhantomData};

use crate::sse::parser::is_lf;

pub(super) struct LinePrefixWriter<'a, W> {
    inner: &'a mut W,
    prefix: &'static [u8],
    pending_cr: bool,
}

impl<'a, W: std::io::Write> LinePrefixWriter<'a, W> {
    pub(super) fn new(inner: &'a mut W, prefix: &'static [u8]) -> Self {
        Self {
            inner,
            prefix,
            pending_cr: false,
        }
    }

    pub(super) fn finish(mut self) -> std::io::Result<()> {
        if self.pending_cr {
            self.inner.write_all(self.prefix)?;
            self.pending_cr = false;
        }
        Ok(())
    }
}

impl<W: std::io::Write> std::io::Write for LinePrefixWriter<'_, W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let mut start = 0;

        if self.pending_cr && !buf.is_empty() {
            self.pending_cr = false;
            if buf[0] == b'\n' {
                self.inner.write_all(&buf[..1])?;
                self.inner.write_all(self.prefix)?;
                start = 1;
            } else {
                self.inner.write_all(self.prefix)?;
            }
        }

        // jump from terminator to terminator: everything in between is
        // bulk-written, single-line data in exactly one write
        let mut index = start;
        while let Some(pos) = memchr::memchr2(b'\r', b'\n', &buf[index..]).map(|p| index + p) {
            if buf[pos] == b'\r' {
                let mut end = pos + 1;
                if end == buf.len() {
                    // an LF may still follow in the next write call
                    self.inner.write_all(&buf[start..end])?;
                    self.pending_cr = true;
                    return Ok(buf.len());
                }
                if buf[end] == b'\n' {
                    end += 1;
                }
                self.inner.write_all(&buf[start..end])?;
                self.inner.write_all(self.prefix)?;
                index = end;
            } else {
                self.inner.write_all(&buf[start..=pos])?;
                self.inner.write_all(self.prefix)?;
                index = pos + 1;
            }
            start = index;
        }

        self.inner.write_all(&buf[start..])?;
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

/// Trait that can be implemented for a custom data type that is to be written (by a server).
pub trait EventDataWrite {
    fn write_data(&self, w: &mut impl std::io::Write) -> Result<(), BoxError>;

    /// Best-effort size in bytes of the data [`write_data`] will produce
    /// (excluding any `data: ` line prefixes inserted around it), used to
    /// pre-reserve serialization buffers. `None` when unknown up front.
    ///
    /// [`write_data`]: EventDataWrite::write_data
    fn size_hint(&self) -> Option<usize> {
        None
    }
}

/// Trait that can be implemented for a custom data type that is to be read (by a client).
pub trait EventDataRead: Sized {
    type Reader: EventDataLineReader<Data = Self>;

    fn line_reader() -> Self::Reader;
}

pub trait EventDataLineReader {
    type Data: EventDataRead;

    fn read_line(&mut self, line: &str) -> Result<(), BoxError>;

    fn data(&mut self, event: Option<&str>) -> Result<Option<Self::Data>, BoxError>;
}

macro_rules! write_str_data {
    () => {
        fn write_data(&self, w: &mut impl std::io::Write) -> Result<(), BoxError> {
            w.write_all(self.as_bytes())
                .context("write string event data")
        }

        fn size_hint(&self) -> Option<usize> {
            Some(self.len())
        }
    };
}

impl EventDataWrite for &str {
    write_str_data!();
}

impl EventDataWrite for ArcStr {
    write_str_data!();
}

impl EventDataWrite for String {
    write_str_data!();
}

/// Upper bound on the previous-payload capacity hint: one huge event must
/// not make every following (possibly tiny) payload pre-reserve that much.
const PAYLOAD_SIZE_HINT_CAP: usize = rama_utils::octets::mib(1);

#[derive(Debug)]
/// [`EventDataLineReader`] for the [`EventDataRead`] implementation of [`String`].
pub struct EventDataStringReader {
    buf: Option<String>,
    // size of the previously produced payload (capped): streams tend to
    // carry similarly-sized events, so pre-reserving it avoids the realloc
    // ladder (and its copies) while appending line by line
    size_hint: usize,
}

impl EventDataLineReader for EventDataStringReader {
    type Data = String;

    #[inline]
    fn read_line(&mut self, line: &str) -> Result<(), BoxError> {
        let buf = match &mut self.buf {
            Some(buf) => buf,
            None => self
                .buf
                .insert(String::with_capacity(self.size_hint.max(line.len() + 1))),
        };
        buf.push_str(line);
        buf.push('\u{000A}');
        Ok(())
    }

    fn data(&mut self, _event: Option<&str>) -> Result<Option<Self::Data>, BoxError> {
        let Some(mut data) = self.buf.take() else {
            return Ok(None);
        };

        if data.chars().next_back().map(is_lf).unwrap_or_default() {
            data.pop();
        }
        self.size_hint = (data.len() + 1).min(PAYLOAD_SIZE_HINT_CAP);
        // don't hand out a payload retaining a way larger reservation
        // than it uses (the hint can overshoot on heterogeneous streams)
        if data.capacity() / 4 > data.len() {
            data.shrink_to_fit();
        }
        Ok(Some(data))
    }
}

impl EventDataRead for String {
    type Reader = EventDataStringReader;

    fn line_reader() -> Self::Reader {
        EventDataStringReader {
            buf: Default::default(),
            size_hint: 0,
        }
    }
}

macro_rules! write_multiline_data {
    () => {
        fn write_data(&self, w: &mut impl std::io::Write) -> Result<(), BoxError> {
            let mut iter = self.iter();
            if let Some(mut next) = iter.next() {
                for element in iter {
                    next.write_data(w)?;
                    next = element;
                    write!(w, "\n").context("write newline")?;
                }
                next.write_data(w)?;
            }
            Ok(())
        }

        fn size_hint(&self) -> Option<usize> {
            // element hints are advisory: saturate rather than overflow
            let mut total = 0usize;
            let mut lines = 0usize;
            for element in self.iter() {
                total = total.saturating_add(element.size_hint()?);
                lines += 1;
            }
            Some(total.saturating_add(lines.saturating_sub(1)))
        }
    };
}

impl<const N: usize, T: EventDataWrite> EventDataWrite for [T; N] {
    write_multiline_data!();
}

impl<T: EventDataWrite> EventDataWrite for [T] {
    write_multiline_data!();
}

impl<T: EventDataWrite> EventDataWrite for Vec<T> {
    write_multiline_data!();
}

/// [`EventDataLineReader`] for the [`EventDataRead`] implementation of [`Vec`].
pub struct EventDataMultiLineReader<T> {
    lines: Vec<T>,
}

impl<T: fmt::Debug> fmt::Debug for EventDataMultiLineReader<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("EventDataMultiLineReader")
            .field("lines", &self.lines)
            .finish()
    }
}

impl<T: EventDataRead> EventDataLineReader for EventDataMultiLineReader<T> {
    type Data = Vec<T>;

    fn read_line(&mut self, line: &str) -> Result<(), BoxError> {
        let mut reader = T::line_reader();
        reader.read_line(line)?;
        if let Some(data) = reader.data(None)? {
            self.lines.push(data);
        }
        Ok(())
    }

    fn data(&mut self, _event: Option<&str>) -> Result<Option<Self::Data>, BoxError> {
        if self.lines.is_empty() {
            return Ok(None);
        }

        let lines = std::mem::take(&mut self.lines);
        Ok(Some(lines))
    }
}

impl<T: EventDataRead> EventDataRead for Vec<T> {
    type Reader = EventDataMultiLineReader<T>;

    fn line_reader() -> Self::Reader {
        EventDataMultiLineReader {
            lines: Default::default(),
        }
    }
}

/// Wrapper used to create Json event data.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JsonEventData<T>(pub T);

impl_deref!(JsonEventData);

impl<T> From<T> for JsonEventData<T> {
    fn from(inner: T) -> Self {
        Self(inner)
    }
}

impl<T: serde::Serialize> EventDataWrite for JsonEventData<T> {
    fn write_data(&self, w: &mut impl std::io::Write) -> Result<(), BoxError> {
        serde_json::to_writer(w, &self.0).context("serialize json data")?;
        Ok(())
    }
}

/// [`EventDataLineReader`] for the [`EventDataRead`] implementation of any
/// json-compatible [`DeserializeOwned`].
///
/// [`DeserializeOwned`]: serde::de::DeserializeOwned
pub struct EventDataJsonReader<T> {
    buf: String,
    _phantom: PhantomData<fn() -> T>,
}

impl<T> fmt::Debug for EventDataJsonReader<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("EventDataJsonReader")
            .field("buf", &self.buf)
            .field(
                "_phantom",
                &format_args!("{}", std::any::type_name::<fn() -> T>()),
            )
            .finish()
    }
}

impl<T: serde::de::DeserializeOwned> EventDataLineReader for EventDataJsonReader<T> {
    type Data = JsonEventData<T>;

    fn read_line(&mut self, line: &str) -> Result<(), BoxError> {
        self.buf.push_str(line);
        self.buf.push('\u{000A}');
        Ok(())
    }

    fn data(&mut self, _event: Option<&str>) -> Result<Option<Self::Data>, BoxError> {
        // An event with no `data:` line leaves the buffer empty; in that case
        // there is no JSON to decode and we surface `Ok(None)` rather than
        // erroring on `from_str("")`.
        if self.buf.is_empty() {
            return Ok(None);
        }
        let data: T = serde_json::from_str(&self.buf).context("read json event data")?;
        self.buf.clear();
        Ok(Some(JsonEventData(data)))
    }
}

impl<T: serde::de::DeserializeOwned> EventDataRead for JsonEventData<T> {
    type Reader = EventDataJsonReader<T>;

    fn line_reader() -> Self::Reader {
        EventDataJsonReader {
            buf: Default::default(),
            _phantom: PhantomData,
        }
    }
}

macro_rules! impl_either_event_data_write {
    ($id:ident, $($param:ident),+ $(,)?) => {
        impl<$($param),+> EventDataWrite for rama_core::combinators::$id<$($param),+>
        where
            $(
                $param: EventDataWrite,
            )+
    {
        fn write_data(&self, w: &mut impl std::io::Write) -> Result<(), BoxError> {
            match self {
                $(
                    rama_core::combinators::$id::$param(d) => d.write_data(w),
                )+
            }
        }

        fn size_hint(&self) -> Option<usize> {
            match self {
                $(
                    rama_core::combinators::$id::$param(d) => d.size_hint(),
                )+
            }
        }
        }
    };
}

rama_core::combinators::impl_either!(impl_either_event_data_write);

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as _;

    fn run(segments: &[&[u8]]) -> String {
        let mut out = Vec::new();
        let mut writer = LinePrefixWriter::new(&mut out, b"data: ");
        for segment in segments {
            writer.write_all(segment).unwrap();
        }
        writer.finish().unwrap();
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn line_prefix_writer_handles_all_terminators_and_split_writes() {
        for (segments, expected) in [
            (vec![b"hello".as_slice()], "hello"),
            (vec![b"".as_slice()], ""),
            (vec![b"a\nb".as_slice()], "a\ndata: b"),
            (vec![b"a\r\nb".as_slice()], "a\r\ndata: b"),
            (vec![b"a\rb".as_slice()], "a\rdata: b"),
            // a trailing CR leaves the prefix decision to finish()
            (vec![b"a\r".as_slice()], "a\rdata: "),
            // ... or to the next write call: LF joins the CR terminator
            (vec![b"a\r".as_slice(), b"\nb".as_slice()], "a\r\ndata: b"),
            (vec![b"a\r".as_slice(), b"b".as_slice()], "a\rdata: b"),
            (
                vec![b"a\r".as_slice(), b"\rb".as_slice()],
                "a\rdata: \rdata: b",
            ),
            (vec![b"\n\n".as_slice()], "\ndata: \ndata: "),
            (
                vec![b"a\r\n".as_slice(), b"\nb".as_slice()],
                "a\r\ndata: \ndata: b",
            ),
            (
                vec![
                    b"multi".as_slice(),
                    b"ple\nwri".as_slice(),
                    b"tes".as_slice(),
                ],
                "multiple\ndata: writes",
            ),
        ] {
            assert_eq!(run(&segments), expected, "segments: {segments:?}");
        }
    }
}
