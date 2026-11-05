// Independent Serde wire-format reference for encoder parity tests.

use super::{QlogEventView, TraceInfo};
use serde::Serialize;
use std::io::{self, Write};

#[derive(Debug, Default)]
pub(crate) struct ReferenceJsonEncoder;

impl ReferenceJsonEncoder {
    pub(crate) fn begin(info: &TraceInfo, output: &mut dyn Write) -> io::Result<()> {
        let title = info.title.as_deref();
        let description = info.description.as_deref();
        write_record(
            output,
            &Header {
                file_schema: "urn:ietf:params:qlog:file:sequential",
                serialization_format: "application/qlog+json-seq",
                title,
                description,
                trace: Trace {
                    title,
                    description,
                    vantage_point: VantagePoint { r#type: "unknown" },
                    event_schemas: ["urn:ietf:params:qlog:events:quic-13"],
                    common_fields: CommonFields {
                        time_format: "relative_to_epoch",
                        reference_time: ReferenceTime {
                            clock_type: "monotonic",
                            epoch: "unknown",
                        },
                    },
                },
            },
        )
    }

    pub(crate) fn event(
        info: &TraceInfo,
        event: &QlogEventView<'_>,
        output: &mut dyn Write,
    ) -> io::Result<()> {
        write_record(
            output,
            &Record {
                time: event
                    .time
                    .saturating_duration_since(info.start_time)
                    .as_secs_f64()
                    * 1000.0,
                group_id: &event.group_id,
                event: &event.fields,
            },
        )
    }
}

fn write_record(output: &mut dyn Write, record: &impl Serialize) -> io::Result<()> {
    output.write_all(b"\x1e")?;
    serde_json::to_writer(&mut *output, record).map_err(io::Error::from)?;
    output.write_all(b"\n")
}

#[derive(Serialize)]
struct Header<'a> {
    file_schema: &'static str,
    serialization_format: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<&'a str>,
    trace: Trace<'a>,
}

#[derive(Serialize)]
struct Trace<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<&'a str>,
    vantage_point: VantagePoint,
    event_schemas: [&'static str; 1],
    common_fields: CommonFields,
}

#[derive(Serialize)]
struct VantagePoint {
    r#type: &'static str,
}

#[derive(Serialize)]
struct CommonFields {
    time_format: &'static str,
    reference_time: ReferenceTime,
}

#[derive(Serialize)]
struct ReferenceTime {
    clock_type: &'static str,
    epoch: &'static str,
}

#[derive(Serialize)]
struct Record<'a, E> {
    time: f64,
    #[serde(serialize_with = "rama_utils::bytes::serde_hex::serialize")]
    group_id: &'a [u8],
    #[serde(flatten)]
    event: E,
}
