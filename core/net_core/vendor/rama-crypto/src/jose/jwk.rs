use aws_lc_rs::{
    digest::{Digest, SHA256, digest},
    encoding::{AsDer, Pkcs8V1Der},
    pkcs8::Document,
    rand::SystemRandom,
    rsa::KeySize,
    signature::{
        self, ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, EcdsaSigningAlgorithm,
        EcdsaVerificationAlgorithm, KeyPair, RsaKeyPair, Signature,
    },
};
use base64::{Engine as _, prelude::BASE64_URL_SAFE_NO_PAD};
use rama_core::error::BoxErrorExt as _;
use rama_core::error::{BoxError, ErrorContext};
use serde::{Deserialize, Serialize, Serializer, ser::SerializeStruct};

use crate::jose::{JWA, Signer, jwk_utils::create_subject_public_key_info};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
/// [`JWK`] or JSON Web Key as defined in [`rfc7517`]
///
/// [`rfc7517`]: https://datatracker.ietf.org/doc/html/rfc7517
pub struct JWK {
    /// Algorithm intended for use with this key
    pub alg: JWA,
    #[serde(flatten)]
    /// Key type (e.g., RSA, EC, oct)
    pub key_type: JWKType,
    #[serde(skip_serializing_if = "Option::is_none")]
    /// Intended use (e.g., "sig" for signature, "enc" for encryption)
    pub r#use: Option<JWKUse>,
    #[serde(skip_serializing_if = "Option::is_none")]
    /// Operations this key supports (e.g., ["sign", "verify"])
    pub key_ops: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    /// X.509 certificate chain
    pub x5c: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    /// X.509 certificate SHA-1 thumbprint (base64url-encoded)
    pub x5t: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "x5t#S256")]
    /// X.509 certificate SHA-256 thumbprint (base64url-encoded)
    pub x5t_sha256: Option<String>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(tag = "kty")]
/// The "kty" (key type) parameter identifies the cryptographic algorithm family used with the key, such as "RSA", "EC", or "OCT"
pub enum JWKType {
    RSA {
        n: String,
        e: String,
    },
    /// Elleptic curve
    EC {
        crv: JWKEllipticCurves,
        x: String,
        y: String,
    },
    /// an octet sequence key, which represents a symmetric key
    OCT {
        k: String,
    },
}

impl Serialize for JWKType {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        // Order here is important as this output will be used to generate jwk thumb
        match &self {
            Self::EC { crv, x, y } => {
                let mut state = serializer.serialize_struct("JWKType", 4)?;
                state.serialize_field("crv", crv)?;
                state.serialize_field("kty", "EC")?;
                state.serialize_field("x", x)?;
                state.serialize_field("y", y)?;
                state.end()
            }
            Self::RSA { n, e } => {
                let mut state = serializer.serialize_struct("JWKType", 3)?;
                state.serialize_field("e", e)?;
                state.serialize_field("kty", "RSA")?;
                state.serialize_field("n", n)?;
                state.end()
            }
            Self::OCT { k } => {
                let mut state = serializer.serialize_struct("JWKType", 2)?;
                state.serialize_field("k", k)?;
                state.serialize_field("kty", "OCT")?;
                state.end()
            }
        }
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum JWKEllipticCurves {
    #[serde(rename = "P-256")]
    P256,
    #[serde(rename = "P-384")]
    P384,
    #[serde(rename = "P-521")]
    P521,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
/// [`JWKUse`] identifies the intended use of the public key
pub enum JWKUse {
    #[serde(rename = "sig")]
    Signature,
    #[serde(rename = "enc")]
    Encryption,
}

impl JWK {
    /// Create a [`JWK`] for the given [`EcdsaKeyPair`]
    ///
    /// Warning: make sure to specify the correct algorithm.
    /// If `https://github.com/aws/aws-lc-rs/pull/834` gets merged this won't be needed anymore
    fn try_new_from_escdsa_keypair(key: &EcdsaKeyPair) -> Result<Self, BoxError> {
        let alg = JWA::try_from(key.algorithm())?;
        let curve = alg.try_into()?;
        // 0x04 prefix + x + y
        let pub_key = key.public_key().as_ref();
        let middle = (pub_key.len() - 1) / 2;
        let (x, y) = key.public_key().as_ref()[1..].split_at(middle);

        Ok(Self {
            alg,
            key_type: JWKType::EC {
                crv: curve,
                x: BASE64_URL_SAFE_NO_PAD.encode(x),
                y: BASE64_URL_SAFE_NO_PAD.encode(y),
            },
            r#use: Some(JWKUse::Signature),
            key_ops: None,
            x5c: None,
            x5t: None,
            x5t_sha256: None,
        })
    }

    /// JSON Web Key (JWK) Thumbprint as defined
    /// in [`rfc7638`] is url safe identifier for a [`JWK`]
    ///
    /// [`rfc7638`]: https://datatracker.ietf.org/doc/html/rfc7638
    pub fn thumb_sha256(&self) -> Result<Digest, BoxError> {
        Ok(digest(
            &SHA256,
            &serde_json::to_vec(&self.key_type).context("failed to serialise JWK")?,
        ))
    }

    /// Convert this [`JWK`] to an unparsed public key which can be used to verify signatures
    ///
    /// Warning no verification is done on this key until `.verify()` is called
    pub fn unparsed_public_key(&self) -> Result<signature::UnparsedPublicKey<Vec<u8>>, BoxError> {
        match &self.key_type {
            JWKType::RSA { n, e } => {
                let n_bytes = BASE64_URL_SAFE_NO_PAD
                    .decode(n)
                    .context("decode RSA modulus (n)")?;
                let e_bytes = BASE64_URL_SAFE_NO_PAD
                    .decode(e)
                    .context("decode RSA exponent (e)")?;

                let rsa_public_key_sequence = create_subject_public_key_info(n_bytes, e_bytes);

                Ok(signature::UnparsedPublicKey::new(
                    self.alg.try_into()?,
                    rsa_public_key_sequence,
                ))
            }
            JWKType::OCT { .. } => Err(BoxError::from_static_str(
                "Symmetric key cannot be converted to public key",
            )),
            JWKType::EC { crv, x, y } => {
                let alg: &'static EcdsaVerificationAlgorithm =
                    JWA::from(crv.to_owned()).try_into()?;

                let x_bytes = BASE64_URL_SAFE_NO_PAD
                    .decode(x)
                    .context("decode ec curve x point")?;
                let y_bytes = BASE64_URL_SAFE_NO_PAD
                    .decode(y)
                    .context("decode ec curve y point")?;

                let mut point_bytes = Vec::with_capacity(1 + x_bytes.len() + y_bytes.len());
                point_bytes.push(0x04);
                point_bytes.extend_from_slice(&x_bytes);
                point_bytes.extend_from_slice(&y_bytes);

                Ok(signature::UnparsedPublicKey::new(alg, point_bytes))
            }
        }
    }

    /// Creates a new [`JWK`] from a given [`RsaKeyPair`]
    #[must_use]
    pub fn new_from_rsa_key_pair(rsa_key_pair: &RsaKeyPair, alg: JWA) -> Self {
        let n = rsa_key_pair.public_key().modulus();
        let e = rsa_key_pair.public_key().exponent();
        Self {
            alg,
            key_type: JWKType::RSA {
                n: BASE64_URL_SAFE_NO_PAD.encode(n.big_endian_without_leading_zero()),
                e: BASE64_URL_SAFE_NO_PAD.encode(e.big_endian_without_leading_zero()),
            },
            r#use: Some(JWKUse::Signature),
            key_ops: None,
            x5c: None,
            x5t: None,
            x5t_sha256: None,
        }
    }
}

#[derive(Debug)]
/// [`EcdsaKey`] which is used to identify and authenticate our requests
///
/// This contains the private and public key we will be using for JWS
pub struct EcdsaKey {
    rng: SystemRandom,
    alg: JWA,
    inner: EcdsaKeyPair,
}

impl EcdsaKey {
    /// Create a new [`EcdsaKey`] from the given [`EcdsaKeyPair`]
    pub fn try_new(key_pair: EcdsaKeyPair, alg: JWA, rng: SystemRandom) -> Result<Self, BoxError> {
        // Check if passed algorithm is a correct elliptic curve one
        let _curve = JWKEllipticCurves::try_from(alg)?;
        Ok(Self {
            rng,
            alg,
            inner: key_pair,
        })
    }

    /// Generate a new [`EcdsaKey`] from a newly generated [`EcdsaKeyPair`] using P-256 EC
    pub fn generate() -> Result<Self, BoxError> {
        let key_pair = EcdsaKeyPair::generate(&ECDSA_P256_SHA256_FIXED_SIGNING)
            .context("generate EcdsaKeyPair")?;

        Self::try_new(key_pair, JWA::ES256, SystemRandom::new())
    }

    /// Generate a new [`EcdsaKey`] from the given pkcs8 der
    pub fn from_pkcs8_der(alg: JWA, pkcs8_der: &[u8], rng: SystemRandom) -> Result<Self, BoxError> {
        let ec_alg: &'static EcdsaSigningAlgorithm = alg.try_into()?;
        let key_pair = EcdsaKeyPair::from_pkcs8(ec_alg, pkcs8_der)
            .context("create EcdsaKeyPair from pkcs8")?;

        Self::try_new(key_pair, alg, rng)
    }

    /// Create pkcs8 der for the current [`EcdsaKeyPair`]
    pub fn pkcs8_der(&self) -> Result<Document, BoxError> {
        let doc = self
            .inner
            .to_pkcs8v1()
            .context("create pkcs8 der from keypair")?;
        Ok(doc)
    }

    /// Create a [`JWK`] for this [`EcdsaKey`]
    #[must_use]
    pub fn create_jwk(&self) -> JWK {
        #[expect(
            clippy::expect_used,
            reason = "`new_for_escdsa_keypair` can only fail if curve is not elliptic but we already check that in `new`"
        )]
        JWK::try_new_from_escdsa_keypair(&self.inner).expect("create JWK from escdsa keypair")
    }

    #[must_use]
    pub fn rng(&self) -> &SystemRandom {
        &self.rng
    }

    #[must_use]
    pub fn alg(&self) -> JWA {
        self.alg
    }
}

#[derive(Serialize)]
struct SigningHeaders<'a> {
    alg: JWA,
    jwk: &'a JWK,
}

impl Signer for EcdsaKey {
    type Signature = Signature;
    type Error = BoxError;

    fn set_headers(
        &self,
        protected_headers: &mut super::jws::Headers,
        _unprotected_headers: &mut super::jws::Headers,
    ) -> Result<(), Self::Error> {
        let jwk = self.create_jwk();
        protected_headers.try_set_headers(SigningHeaders {
            alg: jwk.alg,
            jwk: &jwk,
        })?;
        Ok(())
    }

    fn sign(&self, data: &str) -> Result<Self::Signature, Self::Error> {
        let sig = self
            .inner
            .sign(self.rng(), data.as_bytes())
            .context("sign protected data")?;

        Ok(sig)
    }
}

#[derive(Debug)]
pub struct RsaKey {
    rng: SystemRandom,
    alg: JWA,
    inner: RsaKeyPair,
}

impl RsaKey {
    /// Create a new [`RsaKey`] from the given [`RsaKeyPair`]
    pub fn try_new(key_pair: RsaKeyPair, alg: JWA, rng: SystemRandom) -> Result<Self, BoxError> {
        Ok(Self {
            rng,
            alg,
            inner: key_pair,
        })
    }

    /// Generate a new [`RsaKey`] from a newly generated [`RsaKeyPair`]
    pub fn generate(key_size: KeySize) -> Result<Self, BoxError> {
        let key_pair = RsaKeyPair::generate(key_size).context("error generating rsa key pair")?;

        Self::try_new(key_pair, JWA::RS256, SystemRandom::new())
    }

    /// Generate a new [`RsaKey`] from the given pkcs8 der
    pub fn from_pkcs8_der(pkcs8_der: &[u8], alg: JWA, rng: SystemRandom) -> Result<Self, BoxError> {
        let key_pair = RsaKeyPair::from_pkcs8(pkcs8_der).context("create RSAKeyPair from pkcs8")?;

        Self::try_new(key_pair, alg, rng)
    }

    /// Create pkcs8 der for the current [`RsaKeyPair`]
    pub fn pkcs8_der(&self) -> Result<(JWA, Pkcs8V1Der<'static>), BoxError> {
        let doc = self
            .inner
            .as_der()
            .context("error creating pkcs8 der from rsa keypair")?;
        Ok((self.alg, doc))
    }

    /// Create a [`JWK`] for this [`RsaKey`]
    #[must_use]
    pub fn create_jwk(&self) -> JWK {
        JWK::new_from_rsa_key_pair(&self.inner, self.alg)
    }

    #[must_use]
    pub fn rng(&self) -> &SystemRandom {
        &self.rng
    }
}

impl Signer for RsaKey {
    type Signature = Vec<u8>;
    type Error = BoxError;

    fn set_headers(
        &self,
        protected_headers: &mut super::jws::Headers,
        _unprotected_headers: &mut super::jws::Headers,
    ) -> Result<(), Self::Error> {
        let jwk = self.create_jwk();
        protected_headers.try_set_headers(SigningHeaders {
            alg: jwk.alg,
            jwk: &jwk,
        })?;
        Ok(())
    }

    fn sign(&self, data: &str) -> Result<Self::Signature, Self::Error> {
        let mut sig = vec![0; self.inner.public_modulus_len()];
        self.inner
            .sign(self.alg.try_into()?, self.rng(), data.as_bytes(), &mut sig)
            .context("sign protected data")?;
        Ok(sig)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::jose::JWKType::RSA;

    #[test]
    fn jwk_thumb_order_is_correct() {
        let jwk_type = JWKType::EC {
            crv: JWKEllipticCurves::P256,
            x: "x".into(),
            y: "y".into(),
        };
        let output = serde_json::to_string(&jwk_type).unwrap();
        let expected_output = r##"{"crv":"P-256","kty":"EC","x":"x","y":"y"}"##;
        assert_eq!(&output, expected_output);

        let jwk_type = JWKType::RSA {
            n: "n".into(),
            e: "e".into(),
        };
        let output = serde_json::to_string(&jwk_type).unwrap();
        let expected_output = r##"{"e":"e","kty":"RSA","n":"n"}"##;
        assert_eq!(&output, expected_output);

        let jwk_type = JWKType::OCT { k: "k".into() };
        let output = serde_json::to_string(&jwk_type).unwrap();
        let expected_output = r##"{"k":"k","kty":"OCT"}"##;
        assert_eq!(&output, expected_output);
    }

    #[test]
    fn can_generate_and_reuse_keys() {
        let key = EcdsaKey::generate().unwrap();
        let alg = key.alg();
        let der = key.pkcs8_der().unwrap();
        let recreated_key =
            EcdsaKey::from_pkcs8_der(alg, der.as_ref(), SystemRandom::new()).unwrap();

        assert_eq!(key.create_jwk(), recreated_key.create_jwk())
    }

    #[test]
    fn test_n_and_e_are_base64_encoded() {
        let rsa_key_pair = RsaKey::generate(KeySize::Rsa4096).unwrap();
        let jwk = JWK::new_from_rsa_key_pair(&rsa_key_pair.inner, JWA::PS512);
        let JWKType::RSA { n, e } = jwk.key_type else {
            panic!("JWK type not RSA")
        };
        BASE64_URL_SAFE_NO_PAD.decode(n).unwrap();
        BASE64_URL_SAFE_NO_PAD.decode(e).unwrap();
    }

    /// This example is taken from the [RFC 7517](https://datatracker.ietf.org/doc/html/rfc7517#appendix-A.1)
    /// Appendix A.1.
    #[test]
    fn test_unparsed_public_key() {
        let jwk_rsa = JWK {
            alg: JWA::RS256,
            key_type: RSA {
                n: "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK\
                7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl9\
                3lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHz\
                u6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksIN\
                HaQ-G_xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw"
                    .to_owned(),
                e: "AQAB".to_owned(),
            },
            r#use: None,
            key_ops: None,
            x5c: None,
            x5t: None,
            x5t_sha256: None,
        };
        // This is the known byte sequence of the unparsed public key generated from the above JWK
        // using the python `cryptography` library.
        let expected_unparsed_bytes = [
            48, 130, 1, 34, 48, 13, 6, 9, 42, 134, 72, 134, 247, 13, 1, 1, 1, 5, 0, 3, 130, 1, 15,
            0, 48, 130, 1, 10, 2, 130, 1, 1, 0, 210, 252, 123, 106, 10, 30, 108, 103, 16, 74, 235,
            143, 136, 178, 87, 102, 155, 77, 246, 121, 221, 173, 9, 155, 92, 74, 108, 217, 168,
            128, 21, 181, 161, 51, 191, 11, 133, 108, 120, 113, 182, 223, 0, 11, 85, 79, 206, 179,
            194, 237, 81, 43, 182, 143, 20, 92, 110, 132, 52, 117, 47, 171, 82, 161, 207, 193, 36,
            64, 143, 121, 181, 138, 69, 120, 193, 100, 40, 133, 87, 137, 247, 162, 73, 227, 132,
            203, 45, 159, 174, 45, 103, 253, 150, 251, 146, 108, 25, 142, 7, 115, 153, 253, 200,
            21, 192, 175, 9, 125, 222, 90, 173, 239, 244, 77, 231, 14, 130, 127, 72, 120, 67, 36,
            57, 191, 238, 185, 96, 104, 208, 71, 79, 197, 13, 109, 144, 191, 58, 152, 223, 175, 16,
            64, 200, 156, 2, 214, 146, 171, 59, 60, 40, 150, 96, 157, 134, 253, 115, 183, 116, 206,
            7, 64, 100, 124, 238, 234, 163, 16, 189, 18, 249, 133, 168, 235, 159, 89, 253, 212, 38,
            206, 165, 178, 18, 15, 79, 42, 52, 188, 171, 118, 75, 126, 108, 84, 214, 132, 2, 56,
            188, 196, 5, 135, 165, 158, 102, 237, 31, 51, 137, 69, 119, 99, 92, 71, 10, 247, 92,
            249, 44, 32, 209, 218, 67, 225, 191, 196, 25, 226, 34, 166, 240, 208, 187, 53, 140, 94,
            56, 249, 203, 5, 10, 234, 254, 144, 72, 20, 241, 172, 26, 164, 156, 202, 158, 160, 202,
            131, 2, 3, 1, 0, 1,
        ];
        let unparsed_key = jwk_rsa.unparsed_public_key().unwrap();
        assert_eq!(expected_unparsed_bytes, unparsed_key.as_ref());
    }
}
