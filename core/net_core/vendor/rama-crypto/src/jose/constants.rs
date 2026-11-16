pub(crate) use der_encoding_tags::*;
pub(crate) use rsa_algorithm_identifier::RSA_ALGORITHM_IDENTIFIER;
mod der_encoding_tags {
    /// Identifier tag for a DER encoded integer.
    /// Defined in [ITU X.680](https://www.itu.int/ITU-T/studygroups/com17/languages/X.680-0207.pdf).
    pub(crate) const DER_TAG_INTEGER: u8 = 0x02;
    /// Identifier tag for a DER encoded bit string.
    /// Defined in [ITU X.680](https://www.itu.int/ITU-T/studygroups/com17/languages/X.680-0207.pdf).
    pub(crate) const DER_TAG_BIT_STRING: u8 = 0x03;
    /// Identifier tag for a DER encoded sequence.
    /// Defined in [ITU X.680](https://www.itu.int/ITU-T/studygroups/com17/languages/X.680-0207.pdf).
    pub(crate) const DER_TAG_SEQUENCE: u8 = 0x30;
    /// Maximum length of a DER encoded length in short form.
    /// Defined in [ITU X.690](https://www.itu.int/ITU-T/studygroups/com17/languages/X.690-0207.pdf).
    pub(crate) const DER_LENGTH_SHORT_FORM_MAX: usize = 127;
    /// Octet that indicates that no unused bits are present in a bit string.
    /// Defined in section 8.6 of [ITU X.690](https://www.itu.int/ITU-T/studygroups/com17/languages/X.690-0207.pdf).
    pub(crate) const BIT_STRING_NO_UNUSED_BITS: u8 = 0x00;
}

/// DER encoded byte representation of RSA encryption algorithm identifier.
///
/// The identifier oid: `1.2.840.113549.1.1.1` defined in appendix C of
/// [RFC 8017](https://datatracker.ietf.org/doc/rfc8017/)
///
/// Section 2.2.1 of the [RFC 3279](https://www.rfc-editor.org/rfc/rfc3279.html) specifies the tag needs to be
/// NULL. The general structure is IDENTIFIER, PARAMETER, but for rsa here we don't
/// have PARAMETER, so we use NULL instead.
///
mod rsa_algorithm_identifier {
    const SEQUENCE_TAG: u8 = 0x30;
    const LENGTH: u8 = 0x0d;
    const OBJECT_IDENTIFIER_TAG: u8 = 0x06;
    const LENGTH_OID: u8 = 0x09;
    const NULL_TAG: u8 = 0x05;
    const LENGTH_NULL: u8 = 0x00;

    /// This entire thing has 3 layers, and the final goal is to
    /// get the der algorithm identifier for rsa encoding
    ///
    /// 1. The identifier oid: 1.2.840.113549.1.1.1 defined in RFC 8017
    /// 2. RFC 3279 (Algorithms and Identifiers for the Internet X.509 PKI)
    ///    specifies tag is needs to be NULL. The general structure is
    ///    IDENTIFIER, PARAMETER, but for rsa here we don't have PARAMETER
    ///    so NULL instead
    /// 3. We need to combine everything in DER encode
    ///   - 3.1 (IDENTIFIER, PARAMETER) is a sequence, so SEQUENCE_TAG, LENGTH of what follows
    ///   - 3.2 OBJECT_IDENTIFIER_TAG to specify OID, LENGTH of OID,and actual oid
    ///   - 3.3 NULL_TAG and LENGTH_NULL to encode null value
    pub(crate) const RSA_ALGORITHM_IDENTIFIER: [u8; 15] = [
        SEQUENCE_TAG,
        LENGTH,
        OBJECT_IDENTIFIER_TAG,
        LENGTH_OID,
        // OID: 1.2.840.113549.1.1.1
        0x2a,
        0x86,
        0x48,
        0x86,
        0xf7,
        0x0d,
        0x01,
        0x01,
        0x01,
        NULL_TAG,
        LENGTH_NULL,
    ];
}

// Integer encoding constants
pub(crate) const INTEGER_SIGN_BIT_MASK: u8 = 0x80;
