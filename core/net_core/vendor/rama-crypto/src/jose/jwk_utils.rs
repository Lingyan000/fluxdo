use crate::jose::constants::{
    BIT_STRING_NO_UNUSED_BITS, DER_LENGTH_SHORT_FORM_MAX, DER_TAG_BIT_STRING, DER_TAG_INTEGER,
    DER_TAG_SEQUENCE, INTEGER_SIGN_BIT_MASK, RSA_ALGORITHM_IDENTIFIER,
};

/// In section 4.1 of [RFC 5280](https://datatracker.ietf.org/doc/rfc5280/) the standard DER
/// encoded public key format is defined as
///```rust,ignore
/// SubjectPublicKeyInfo = SEQUENCE {
///     algorithm AlgorithmIdentifier,
///     subjectPublicKey BIT STRING
/// }
///```
/// The subject public key type `BIT STRING`, a DER encoded representation of a bit string
/// defined in section 8.6 of [X.690](https://www.itu.int/ITU-T/studygroups/com17/languages/X.690-0207.pdf) spec,
/// contains a DER encoded RSA public key sequence in the format
///```rust,ignore
/// RSAPublicKey = SEQUENCE {
///     modulus INTEGER,
///     exponent INTEGER,
/// }
/// ```
/// defined in section 2.3.1 of [RFC 3279](https://datatracker.ietf.org/doc/rfc3279/)
///
/// `SEQUENCE` here is a DER encoded representation of a byte sequence defined in section 8.9 of
/// [X.690](https://www.itu.int/ITU-T/studygroups/com17/languages/X.690-0207.pdf).
///
/// `INTEGER` here is a DER encoded representation of an integer defined in section 8.3 of
/// [X.690](https://www.itu.int/ITU-T/studygroups/com17/languages/X.690-0207.pdf).
pub(crate) fn create_subject_public_key_info(n_bytes: Vec<u8>, e_bytes: Vec<u8>) -> Vec<u8> {
    // Encode the integers - these are small allocations we can't avoid
    let n_der_encoded = encode_integer(n_bytes);
    let e_der_encoded = encode_integer(e_bytes);

    // Calculate sizes for RSAPublicKey SEQUENCE
    let rsa_seq_content_len = n_der_encoded.len() + e_der_encoded.len();
    let rsa_seq_len_encoding = encode_der_length(rsa_seq_content_len);
    let rsa_seq_total_len = 1 + rsa_seq_len_encoding.len() + rsa_seq_content_len;

    // Calculate sizes for BIT STRING
    let bit_string_content_len = 1 + rsa_seq_total_len; // 1 for unused bits byte
    let bit_string_len_encoding = encode_der_length(bit_string_content_len);
    let bit_string_total_len = 1 + bit_string_len_encoding.len() + bit_string_content_len;

    // Calculate final SEQUENCE size
    let final_content_len = RSA_ALGORITHM_IDENTIFIER.len() + bit_string_total_len;
    let final_len_encoding = encode_der_length(final_content_len);
    let total_len = 1 + final_len_encoding.len() + final_content_len;

    // Single allocation for the entire result
    let result = Vec::with_capacity(total_len);
    create_final_sequence(
        result,
        &final_len_encoding,
        &bit_string_len_encoding,
        &rsa_seq_len_encoding,
        &n_der_encoded,
        &e_der_encoded,
    )
}

/// See section 4.1.1 of [RFC 5280](https://datatracker.ietf.org/doc/rfc5280/)
fn create_final_sequence(
    mut result: Vec<u8>,
    final_len_encoding: &[u8],
    bit_string_len_encoding: &[u8],
    rsa_seq_len_encoding: &[u8],
    n_der_encoded: &[u8],
    e_der_encoded: &[u8],
) -> Vec<u8> {
    // Build final SEQUENCE
    result.push(DER_TAG_SEQUENCE);
    result.extend_from_slice(final_len_encoding);
    result.extend_from_slice(&RSA_ALGORITHM_IDENTIFIER);
    create_bit_string(
        result,
        bit_string_len_encoding,
        rsa_seq_len_encoding,
        n_der_encoded,
        e_der_encoded,
    )
}

/// Create the content bytes for the construction of a BIT STRING type
/// defined in section 8.6 of [ITU X.690](https://www.itu.int/ITU-T/studygroups/com17/languages/X.690-0207.pdf).
fn create_bit_string(
    mut result: Vec<u8>,
    bit_string_len_encoding: &[u8],
    rsa_seq_len_encoding: &[u8],
    n_der_encoded: &[u8],
    e_der_encoded: &[u8],
) -> Vec<u8> {
    // Build BIT STRING
    result.push(DER_TAG_BIT_STRING);
    result.extend_from_slice(bit_string_len_encoding);
    result.push(BIT_STRING_NO_UNUSED_BITS);
    create_der_encoded_rsa_key_sequence(result, rsa_seq_len_encoding, n_der_encoded, e_der_encoded)
}

/// Creates a DER encoded sequence of an RSA public key defined in section 2.3.1 of
/// [RFC 3279](https://datatracker.ietf.org/doc/rfc3279/))
fn create_der_encoded_rsa_key_sequence(
    mut result: Vec<u8>,
    rsa_seq_len_encoding: &[u8],
    n_der_encoded: &[u8],
    e_der_encoded: &[u8],
) -> Vec<u8> {
    // Build RSAPublicKey SEQUENCE
    result.push(DER_TAG_SEQUENCE);
    result.extend_from_slice(rsa_seq_len_encoding);
    combine_der_encoded_modulus_and_exponent(result, n_der_encoded, e_der_encoded)
}

/// Combines the der encoded modulus and exponent into a single sequence for constructing the
/// RSA public key sequence.
fn combine_der_encoded_modulus_and_exponent(
    mut result: Vec<u8>,
    n_der_encoded: &[u8],
    e_der_encoded: &[u8],
) -> Vec<u8> {
    result.extend_from_slice(n_der_encoded);
    result.extend_from_slice(e_der_encoded);
    result
}

/// This function is an implementation of length encoding as defined in section 8.1.3
/// [ITU X.690](https://www.itu.int/ITU-T/studygroups/com17/languages/X.690-0207.pdf) specification.
fn encode_der_length(len: usize) -> Vec<u8> {
    if len <= DER_LENGTH_SHORT_FORM_MAX {
        vec![len as u8]
    } else {
        let mut len_bytes = len.to_be_bytes().to_vec();
        while len_bytes[0] == 0 {
            len_bytes.remove(0);
        }
        let first_byte = INTEGER_SIGN_BIT_MASK | len_bytes.len() as u8;
        let mut result = vec![first_byte];
        result.extend_from_slice(&len_bytes);
        result
    }
}

/// This function is a minimal implementation of DER encoded integers as defined in the
/// [ITU X.690](https://www.itu.int/ITU-T/studygroups/com17/languages/X.690-0207.pdf) specification.
///
/// Hence, it should only be used for parsing JWK encoded RSA values.
/// The function should ***NOT*** be used for general ASN.1 encoded values.
/// The function assumes the input is in minimal form, not empty, and is a
/// positive integer.
pub(super) fn encode_integer(value: Vec<u8>) -> Vec<u8> {
    let needs_leading_zero = value[0] & INTEGER_SIGN_BIT_MASK != 0;
    let value_len = value.len() + needs_leading_zero as usize;
    let len_bytes = encode_der_length(value_len);
    let mut result = Vec::with_capacity(1 + len_bytes.len() + value_len);
    result.push(DER_TAG_INTEGER);
    result.extend_from_slice(&len_bytes);
    if needs_leading_zero {
        result.push(0);
    }
    result.extend(value);
    result
}
