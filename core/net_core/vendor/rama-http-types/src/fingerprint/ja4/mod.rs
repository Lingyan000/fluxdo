mod http;
#[doc(inline)]
pub use http::{Ja4H, Ja4HComputeError};

use std::fmt;

use sha2::{Digest as _, Sha256};

#[derive(Default)]
struct HashWriter {
    hasher: Sha256,
    wrote_bytes: bool,
}

impl fmt::Write for HashWriter {
    fn write_str(&mut self, value: &str) -> fmt::Result {
        self.wrote_bytes |= !value.is_empty();
        self.hasher.update(value.as_bytes());
        Ok(())
    }
}

/// Hash formatted bytes into the 12-hex-char truncated SHA-256 digest used by
/// the JA4 family without first allocating the unhashed string. Empty output
/// maps to the all-zero sentinel per the spec.
fn write_hash12(
    output: &mut impl fmt::Write,
    write_value: impl FnOnce(&mut dyn fmt::Write) -> fmt::Result,
) -> fmt::Result {
    let mut writer = HashWriter::default();
    write_value(&mut writer)?;

    if !writer.wrote_bytes {
        output.write_str("000000000000")
    } else {
        let digest = writer.hasher.finalize();
        rama_utils::fmt::hex(&digest[..6]).write_to(output)
    }
}
