//! 对回环浏览器的原始头块逐字段解码，再使用生产 HPACK 编码器按原顺序回放。
//! 只比较编码层，不把此实验等价为完整应用请求头生成。
use rama::{
    bytes::BytesMut,
    http::proto::h2::hpack::{Decoder, Encoder, Header},
};
use serde_json::{Value, json};
use std::{collections::HashMap, io::Cursor, ops::ControlFlow};
fn integer(bytes: &[u8], offset: &mut usize, bits: u32) -> Result<usize, &'static str> {
    let mask = (1u8 << bits) - 1;
    let mut value = usize::from(*bytes.get(*offset).ok_or("missing integer")? & mask);
    *offset += 1;
    if value < usize::from(mask) {
        return Ok(value);
    }
    let mut shift = 0;
    loop {
        let byte = *bytes.get(*offset).ok_or("truncated integer")?;
        *offset += 1;
        if shift > 28 {
            return Err("oversized integer");
        }
        value += usize::from(byte & 127) << shift;
        if byte & 128 == 0 {
            return Ok(value);
        }
        shift += 7;
    }
}
fn string(bytes: &[u8], offset: &mut usize) -> Result<(), &'static str> {
    let length = integer(bytes, offset, 7)?;
    *offset += length;
    if *offset > bytes.len() {
        return Err("truncated string");
    }
    Ok(())
}
fn decode(
    bytes: &[u8],
    decoder: &mut Decoder,
) -> Result<(Vec<Header>, Vec<Value>), Box<dyn std::error::Error>> {
    let mut fields = Vec::new();
    let mut records = Vec::new();
    let mut offset = 0;
    while offset < bytes.len() {
        let start = offset;
        let first = bytes[start];
        let kind = if first & 128 != 0 {
            integer(bytes, &mut offset, 7)?;
            "indexed"
        } else if first & 224 == 32 {
            integer(bytes, &mut offset, 5)?;
            "table_size"
        } else {
            let incremental = first & 64 != 0;
            if integer(bytes, &mut offset, if incremental { 6 } else { 4 })? == 0 {
                string(bytes, &mut offset)?;
            }
            string(bytes, &mut offset)?;
            if incremental {
                "incremental"
            } else if first & 16 != 0 {
                "never_indexed"
            } else {
                "without_indexing"
            }
        };
        let mut wire = BytesMut::from(&bytes[start..offset]);
        decoder.decode(&mut Cursor::new(&mut wire), |field| {
            records.push(json!({"name":format!("{:?}",field.name()),"value":String::from_utf8_lossy(field.value_slice()),"kind":kind,"sensitive":field.is_sensitive()}));
            fields.push(field); ControlFlow::Continue(())
        })?;
    }
    Ok((fields, records))
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::args().nth(1).ok_or("capture JSON required")?;
    let capture: Value = serde_json::from_slice(&std::fs::read(path)?)?;
    let mut states = HashMap::new();
    let mut results = Vec::new();
    for row in capture["headers"].as_array().ok_or("headers required")? {
        let hex = row["header_block_hex"].as_str().ok_or("hex required")?;
        let wire = (0..hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16))
            .collect::<Result<Vec<_>, _>>()?;
        let (browser, core, encoder) = states
            .entry(row["connection"].as_u64().unwrap_or(0))
            .or_insert_with(|| (Decoder::default(), Decoder::default(), Encoder::default()));
        let (fields, expected) = decode(&wire, browser)?;
        let mut replay = BytesMut::new();
        encoder.encode(fields.into_iter().map(Into::into), &mut replay);
        let (_, actual) = decode(&replay, core)?;
        results.push(json!({"connection":row["connection"],"stream":row["stream"],"wire_equal":wire==replay.as_ref(),"field_representation_equal":expected==actual,"browser":expected,"core":actual}));
    }
    println!(
        "{}",
        serde_json::to_string_pretty(
            &json!({"scope":"same_headers_order_and_observed_indexing_hpack_replay","all_wire_equal":results.iter().all(|r|r["wire_equal"]==true),"all_field_representations_equal":results.iter().all(|r|r["field_representation_equal"]==true),"requests":results})
        )?
    );
    Ok(())
}
