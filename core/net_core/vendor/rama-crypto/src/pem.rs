//! PEM encoding of DER objects (RFC 7468), the writing counterpart of the
//! [`PemObject`](crate::pki_types::pem::PemObject) readers.
//!
//! [`PemEncode::pem`] gives a [`PemBlock`] view of a DER object; the view writes itself into a
//! `String`, a `Vec<u8>`, any [`fmt::Write`] or, through [`fmt::Display`], any `io::Write`,
//! without an intermediate allocation.

use base64::Engine as _;
use std::fmt;

use crate::pki_types::{
    CertificateDer, CertificateRevocationListDer, CertificateSigningRequestDer, PrivateKeyDer,
    PrivatePkcs1KeyDer, PrivatePkcs8KeyDer, PrivateSec1KeyDer,
};

/// Base64 columns per body line, as RFC 7468 §2 requires of generators.
const LINE_WIDTH: usize = 64;

/// DER bytes that fill one body line exactly, so lines can be encoded one at a time.
const LINE_INPUT: usize = LINE_WIDTH / 4 * 3;

const BEGIN: &str = "-----BEGIN ";
const END: &str = "-----END ";
const DASHES: &str = "-----\n";

/// One PEM block: a label and the DER bytes it wraps, encoded on demand.
///
/// Every output ends in a newline, so blocks written one after another form a valid file.
#[derive(Debug, Clone, Copy)]
pub struct PemBlock<'a> {
    label: &'a str,
    der: &'a [u8],
}

impl<'a> PemBlock<'a> {
    /// A block labelled `label` around `der`.
    #[must_use]
    pub const fn new(label: &'a str, der: &'a [u8]) -> Self {
        Self { label, der }
    }

    /// The label between `-----BEGIN` and `-----`.
    #[must_use]
    pub const fn label(&self) -> &'a str {
        self.label
    }

    /// The DER bytes the block encodes.
    #[must_use]
    pub const fn der(&self) -> &'a [u8] {
        self.der
    }

    /// The exact number of bytes the encoded block takes.
    #[must_use]
    #[expect(
        clippy::expect_used,
        reason = "no DER object approaches usize::MAX encoded"
    )]
    pub fn encoded_len(&self) -> usize {
        let body = self.der.len().div_ceil(3) * 4;
        let lines = body.div_ceil(LINE_WIDTH);
        // Header and footer: dashes, keyword, label, dashes and newline each.
        (BEGIN.len() + END.len() + 2 * (self.label.len() + DASHES.len()))
            .checked_add(body)
            .and_then(|n| n.checked_add(lines))
            .expect("pem output length overflow")
    }

    /// Encode into a new `String`.
    #[must_use]
    pub fn to_pem(&self) -> String {
        let mut output = String::new();
        self.append_to_string(&mut output);
        output
    }

    /// Encode into a new vector of UTF-8 bytes.
    #[must_use]
    pub fn to_vec(&self) -> Vec<u8> {
        let mut output = Vec::new();
        self.append_to_vec(&mut output);
        output
    }

    /// Append the block, reserving space without clearing existing text.
    #[expect(clippy::expect_used, reason = "writing into a String is infallible")]
    pub fn append_to_string(&self, output: &mut String) {
        output.reserve(self.encoded_len());
        self.write_to(output)
            .expect("writing PEM to a String cannot fail");
    }

    /// Append the block's UTF-8 bytes, reserving space without clearing existing data.
    pub fn append_to_vec(&self, output: &mut Vec<u8>) {
        output.reserve(self.encoded_len());
        let mut line = [0u8; LINE_WIDTH];
        output.extend_from_slice(BEGIN.as_bytes());
        output.extend_from_slice(self.label.as_bytes());
        output.extend_from_slice(DASHES.as_bytes());
        for chunk in self.der.chunks(LINE_INPUT) {
            output.extend_from_slice(encode_line(chunk, &mut line));
            output.push(b'\n');
        }
        output.extend_from_slice(END.as_bytes());
        output.extend_from_slice(self.label.as_bytes());
        output.extend_from_slice(DASHES.as_bytes());
    }

    /// Write the block without allocating an intermediate string.
    ///
    /// Writer errors are propagated; on failure the destination may hold a partial block. For a
    /// `std::io::Write` destination, use `write!(writer, "{block}")` with the I/O trait in scope.
    #[expect(clippy::expect_used, reason = "base64 output is always ASCII")]
    pub fn write_to<W: fmt::Write + ?Sized>(&self, writer: &mut W) -> fmt::Result {
        writer.write_str(BEGIN)?;
        writer.write_str(self.label)?;
        writer.write_str(DASHES)?;
        let mut line = [0u8; LINE_WIDTH];
        for chunk in self.der.chunks(LINE_INPUT) {
            let encoded = encode_line(chunk, &mut line);
            writer.write_str(std::str::from_utf8(encoded).expect("base64 is ASCII"))?;
            writer.write_char('\n')?;
        }
        writer.write_str(END)?;
        writer.write_str(self.label)?;
        writer.write_str(DASHES)
    }
}

impl fmt::Display for PemBlock<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.write_to(f)
    }
}

/// One body line: at most `LINE_INPUT` DER bytes as base64, into `line`.
#[expect(clippy::expect_used, reason = "the buffer holds a full line of base64")]
fn encode_line<'l>(chunk: &[u8], line: &'l mut [u8; LINE_WIDTH]) -> &'l [u8] {
    let written = base64::engine::general_purpose::STANDARD
        .encode_slice(chunk, line)
        .expect("a line of DER fits its base64 line");
    &line[..written]
}

/// One PEM block labelled `label` around `der`, as a new `String`.
#[must_use]
pub fn encode(label: &str, der: &[u8]) -> String {
    PemBlock::new(label, der).to_pem()
}

/// DER objects that carry the PEM label RFC 7468 assigns them.
pub trait PemEncode {
    /// The label between `-----BEGIN` and `-----`.
    fn pem_label(&self) -> &'static str;

    /// The DER bytes the block encodes.
    fn pem_der(&self) -> &[u8];

    /// This object as a block to write wherever it is needed.
    fn pem(&self) -> PemBlock<'_> {
        PemBlock::new(self.pem_label(), self.pem_der())
    }

    /// This object as one PEM block in a new `String`.
    #[must_use]
    fn to_pem(&self) -> String {
        self.pem().to_pem()
    }
}

impl PemEncode for CertificateDer<'_> {
    fn pem_label(&self) -> &'static str {
        "CERTIFICATE"
    }

    fn pem_der(&self) -> &[u8] {
        self.as_ref()
    }
}

impl PemEncode for CertificateRevocationListDer<'_> {
    fn pem_label(&self) -> &'static str {
        "X509 CRL"
    }

    fn pem_der(&self) -> &[u8] {
        self.as_ref()
    }
}

impl PemEncode for CertificateSigningRequestDer<'_> {
    fn pem_label(&self) -> &'static str {
        "CERTIFICATE REQUEST"
    }

    fn pem_der(&self) -> &[u8] {
        self.as_ref()
    }
}

impl PemEncode for PrivatePkcs1KeyDer<'_> {
    fn pem_label(&self) -> &'static str {
        "RSA PRIVATE KEY"
    }

    fn pem_der(&self) -> &[u8] {
        self.secret_pkcs1_der()
    }
}

impl PemEncode for PrivateSec1KeyDer<'_> {
    fn pem_label(&self) -> &'static str {
        "EC PRIVATE KEY"
    }

    fn pem_der(&self) -> &[u8] {
        self.secret_sec1_der()
    }
}

impl PemEncode for PrivatePkcs8KeyDer<'_> {
    fn pem_label(&self) -> &'static str {
        "PRIVATE KEY"
    }

    fn pem_der(&self) -> &[u8] {
        self.secret_pkcs8_der()
    }
}

impl PemEncode for PrivateKeyDer<'_> {
    fn pem_label(&self) -> &'static str {
        match self {
            Self::Pkcs1(key) => key.pem_label(),
            Self::Sec1(key) => key.pem_label(),
            // PKCS#8, and any kind added later: PKCS#8 wraps every key algorithm.
            _ => PrivatePkcs8KeyDer::from(Vec::new()).pem_label(),
        }
    }

    fn pem_der(&self) -> &[u8] {
        self.secret_der()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pki_types::pem::PemObject as _;
    use std::io::Write as _;

    fn reference(label: &str, der: &[u8]) -> String {
        let body = base64::engine::general_purpose::STANDARD.encode(der);
        let mut pem = format!("-----BEGIN {label}-----\n");
        for line in body.as_bytes().chunks(LINE_WIDTH) {
            pem.push_str(std::str::from_utf8(line).unwrap());
            pem.push('\n');
        }
        pem.push_str(&format!("-----END {label}-----\n"));
        pem
    }

    #[test]
    fn every_output_path_matches_the_reference_encoding_and_length() {
        for len in [0, 1, 2, 3, 4, 47, 48, 49, 95, 96, 97, 100, 1000] {
            let der: Vec<u8> = (0..len).map(|i| (i * 7 % 256) as u8).collect();
            let block = PemBlock::new("THING", &der);
            let expected = reference("THING", &der);
            assert_eq!(block.to_pem(), expected, "to_pem, {len} bytes");
            assert_eq!(block.to_vec(), expected.as_bytes(), "to_vec, {len} bytes");
            assert_eq!(block.to_string(), expected, "Display, {len} bytes");
            assert_eq!(encode("THING", &der), expected, "encode, {len} bytes");
            assert_eq!(
                block.encoded_len(),
                expected.len(),
                "encoded_len, {len} bytes"
            );
            assert_eq!(block.label(), "THING");
            assert_eq!(block.der(), der.as_slice());

            let mut text = String::from("before\n");
            block.append_to_string(&mut text);
            assert_eq!(text, format!("before\n{expected}"));
            let mut bytes = b"before\n".to_vec();
            block.append_to_vec(&mut bytes);
            assert_eq!(bytes, format!("before\n{expected}").into_bytes());

            let mut io = Vec::new();
            write!(io, "{block}").unwrap();
            assert_eq!(io, expected.as_bytes(), "io::Write through Display");
        }
    }

    #[test]
    fn lines_are_wrapped_at_64_columns() {
        let pem = encode("THING", &[0xab; 100]);
        let lines: Vec<&str> = pem.lines().collect();
        assert_eq!(lines[0], "-----BEGIN THING-----");
        assert_eq!(lines[lines.len() - 1], "-----END THING-----");
        assert!(pem.ends_with('\n'));
        let body = &lines[1..lines.len() - 1];
        assert_eq!(body.len(), 3, "136 base64 characters take three lines");
        assert!(body[..2].iter().all(|line| line.len() == LINE_WIDTH));
        assert_eq!(body[2].len(), 8);
        assert_eq!(
            encode("EMPTY", &[]),
            "-----BEGIN EMPTY-----\n-----END EMPTY-----\n"
        );
    }

    #[test]
    fn a_failing_writer_stops_the_block() {
        struct Refuse;
        impl fmt::Write for Refuse {
            fn write_str(&mut self, _: &str) -> fmt::Result {
                Err(fmt::Error)
            }
        }
        assert!(PemBlock::new("X", &[1]).write_to(&mut Refuse).is_err());
    }

    #[test]
    fn objects_read_back_as_what_they_were() {
        let certificate = CertificateDer::from(vec![0x30, 0x03, 0x02, 0x01, 0x07]);
        let read = CertificateDer::from_pem_slice(certificate.to_pem().as_bytes()).unwrap();
        assert_eq!(read, certificate);
        assert_eq!(certificate.pem().label(), "CERTIFICATE");

        let keys = [
            PrivateKeyDer::Pkcs1(PrivatePkcs1KeyDer::from(vec![1, 2, 3])),
            PrivateKeyDer::Sec1(PrivateSec1KeyDer::from(vec![4, 5, 6])),
            PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(vec![7, 8, 9])),
        ];
        for key in keys {
            let read = PrivateKeyDer::from_pem_slice(key.to_pem().as_bytes()).unwrap();
            assert_eq!(read.secret_der(), key.secret_der());
            assert_eq!(
                std::mem::discriminant(&read),
                std::mem::discriminant(&key),
                "the label names the encoding"
            );
        }
        let der = vec![0x30, 0x02, 0x05, 0x00];
        let pkcs1 = PrivatePkcs1KeyDer::from(der.clone());
        assert_eq!(pkcs1.pem_label(), "RSA PRIVATE KEY");
        assert_eq!(pkcs1.pem_der(), der);
        assert_eq!(
            PrivatePkcs1KeyDer::from_pem_slice(pkcs1.to_pem().as_bytes())
                .unwrap()
                .secret_pkcs1_der(),
            der
        );
        let sec1 = PrivateSec1KeyDer::from(der.clone());
        assert_eq!(sec1.pem_label(), "EC PRIVATE KEY");
        assert_eq!(sec1.pem_der(), der);
        assert_eq!(
            PrivateSec1KeyDer::from_pem_slice(sec1.to_pem().as_bytes())
                .unwrap()
                .secret_sec1_der(),
            der
        );
        let pkcs8 = PrivatePkcs8KeyDer::from(der.clone());
        assert_eq!(pkcs8.pem_label(), "PRIVATE KEY");
        assert_eq!(pkcs8.pem_der(), der);
        assert_eq!(
            PrivatePkcs8KeyDer::from_pem_slice(pkcs8.to_pem().as_bytes())
                .unwrap()
                .secret_pkcs8_der(),
            der
        );
        let crl = CertificateRevocationListDer::from(der.clone());
        assert_eq!(crl.pem_label(), "X509 CRL");
        assert_eq!(crl.pem_der(), der);
        assert_eq!(
            CertificateRevocationListDer::from_pem_slice(crl.to_pem().as_bytes()).unwrap(),
            crl
        );
        let csr = CertificateSigningRequestDer::from(der.clone());
        assert_eq!(csr.pem_label(), "CERTIFICATE REQUEST");
        assert_eq!(csr.pem_der(), der);
        assert_eq!(
            CertificateSigningRequestDer::from_pem_slice(csr.to_pem().as_bytes()).unwrap(),
            csr
        );

        let chain: String = [certificate.clone(), certificate.clone()]
            .iter()
            .map(PemEncode::to_pem)
            .collect();
        let read: Vec<CertificateDer<'_>> = CertificateDer::pem_slice_iter(chain.as_bytes())
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(read.len(), 2, "blocks concatenate into one file");
    }
}
