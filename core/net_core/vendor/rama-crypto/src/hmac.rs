//! HMAC-SHA-256 and HMAC-SHA-512 signing and verification.

use rama_core::error::{BoxError, ErrorContext as _};

// Cargo cannot disable fallback dependencies when another backend is enabled.
// Keep them acknowledged for its unused-dependency lint in those builds.
#[cfg(any(feature = "aws-lc", feature = "ring"))]
use ::hmac as _;
#[cfg(any(feature = "aws-lc", feature = "ring"))]
use rand as _;

cfg_select! {
    all(feature = "aws-lc", not(feature = "ring")) => {
        use crate::dep::aws_lc_rs::{hmac::{self, Key}, rand::SystemRandom};
    }
    feature = "ring" => {
        use crate::dep::ring::{hmac::{self, Key}, rand::SystemRandom};
    }
    _ => {
        use ::hmac::{KeyInit as _, Mac as _};
        use rand::TryRng as _;

        // Store the prepared hash state. Each operation clones it because
        // finalization consumes it; cloning is allocation-free and reuses the key setup.
        #[derive(Clone)]
        enum Key {
            Sha256(::hmac::Hmac<::sha2::Sha256>),
            Sha512(::hmac::Hmac<::sha2::Sha512>),
        }

        impl core::fmt::Debug for Key {
            fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
                let mut ds = f.debug_struct("Key");
                match self {
                    Self::Sha256(_) => ds.field("algorithm", &"sha256"),
                    Self::Sha512(_) => ds.field("algorithm", &"sha512"),
                }.finish()
            }
        }
    }
}

/// A reusable SHA-256 or SHA-512 HMAC key for signing and verifying messages.
///
/// Uses `ring` when enabled, otherwise `aws-lc` when enabled, and RustCrypto
/// when neither backend is enabled.
#[derive(Debug, Clone)]
pub struct HmacSha2(Key);

impl HmacSha2 {
    /// Create an HMAC-SHA-256 key from a 32-byte secret.
    pub fn new_256(seed: &[u8; 32]) -> Self {
        cfg_select! {
            any(feature = "aws-lc", feature = "ring") => {
                Self(Key::new(hmac::HMAC_SHA256, seed))
            }
            _ => {
                // HMAC pads short keys to the hash block size.
                let mut key = [0; 64];
                key[..seed.len()].copy_from_slice(seed);
                Self(Key::Sha256(::hmac::Hmac::new((&key).into())))
            }
        }
    }

    /// Generate an HMAC-SHA-256 key using the operating system's randomness.
    ///
    /// # Errors
    ///
    /// Returns an error if random key generation fails.
    pub fn try_rand_256() -> Result<Self, BoxError> {
        cfg_select! {
            any(feature = "aws-lc", feature = "ring") => {
                Key::generate(hmac::HMAC_SHA256, &SystemRandom::new())
                    .map(Self)
                    .context("generate HMAC-SHA-256 key")
            }
            _ => {
                let mut key = [0; 32];
                rand::rngs::SysRng.try_fill_bytes(&mut key)
                    .context("generate HMAC-SHA-256 key")?;
                Ok(Self::new_256(&key))
            }
        }
    }

    /// Create an HMAC-SHA-512 key from a 64-byte secret.
    pub fn new_512(seed: &[u8; 64]) -> Self {
        cfg_select! {
            any(feature = "aws-lc", feature = "ring") => {
                Self(Key::new(hmac::HMAC_SHA512, seed))
            }
            _ => {
                // HMAC pads short keys to the hash block size.
                let mut key = [0; 128];
                key[..seed.len()].copy_from_slice(seed);
                Self(Key::Sha512(::hmac::Hmac::new((&key).into())))
            }
        }
    }

    /// Generate an HMAC-SHA-512 key using the operating system's randomness.
    ///
    /// # Errors
    ///
    /// Returns an error if random key generation fails.
    pub fn try_rand_512() -> Result<Self, BoxError> {
        cfg_select! {
            any(feature = "aws-lc", feature = "ring") => {
                Key::generate(hmac::HMAC_SHA512, &SystemRandom::new())
                    .map(Self)
                    .context("generate HMAC-SHA-512 key")
            }
            _ => {
                let mut key = [0; 64];
                rand::rngs::SysRng.try_fill_bytes(&mut key)
                    .context("generate HMAC-SHA-512 key")?;
                Ok(Self::new_512(&key))
            }
        }
    }

    /// Sign `data`, writing the full authentication tag into `out`.
    ///
    /// # Panics
    ///
    /// Panics if `out.len()` does not equal [`Self::signature_len`].
    pub fn sign(&self, data: &[u8], out: &mut [u8]) {
        cfg_select! {
            any(feature = "aws-lc", feature = "ring") => {
                out.copy_from_slice(hmac::sign(&self.0, data).as_ref());
            }
            _ => {
                match &self.0 {
                    Key::Sha256(mac) => out.copy_from_slice(
                        &mac.clone().chain_update(data).finalize().into_bytes()),
                    Key::Sha512(mac) => out.copy_from_slice(
                        &mac.clone().chain_update(data).finalize().into_bytes()),
                }
            }
        }
    }

    /// Return the signature length in bytes: 32 for SHA-256 or 64 for SHA-512.
    pub fn signature_len(&self) -> usize {
        cfg_select! {
            feature = "ring" => {
                self.0.algorithm().digest_algorithm().output_len()
            }
            feature = "aws-lc" => {
                self.0.algorithm().digest_algorithm().output_len
            }
            _ => {
                match &self.0 {
                    Key::Sha256(_) => 32,
                    Key::Sha512(_) => 64,
                }
            }
        }
    }

    /// Verify the full signature of `data` using a constant-time comparison.
    ///
    /// # Errors
    ///
    /// Returns an error if the signature does not match or has an incorrect length.
    pub fn verify(&self, data: &[u8], signature: &[u8]) -> Result<(), BoxError> {
        cfg_select! {
            any(feature = "aws-lc", feature = "ring") => {
                hmac::verify(&self.0, data, signature)
                    .context("HMAC verification failed")
            }
            _ => {
                match &self.0 {
                    Key::Sha256(mac) => mac.clone().chain_update(data).verify_slice(signature),
                    Key::Sha512(mac) => mac.clone().chain_update(data).verify_slice(signature),
                }.context("HMAC verification failed")
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::HmacSha2;

    fn sign(key: &HmacSha2, data: &[u8]) -> Vec<u8> {
        let mut signature = vec![0; key.signature_len()];
        key.sign(data, &mut signature);
        signature
    }

    #[test]
    fn rfc_4231_vectors() {
        // https://www.rfc-editor.org/rfc/rfc4231.html#section-4
        // Zero-padding these short keys to our fixed key lengths preserves the HMAC.
        let cases: &[(&[u8], &[u8], &str, &str)] = &[
            (
                &[0x0b; 20],
                b"Hi There",
                "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
                concat!(
                    "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cde",
                    "daa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854"
                ),
            ),
            (
                b"Jefe",
                b"what do ya want for nothing?",
                "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
                concat!(
                    "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea250554",
                    "9758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737"
                ),
            ),
            (
                &[0xaa; 20],
                &[0xdd; 50],
                "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe",
                concat!(
                    "fa73b0089d56a284efb0f0756c890be9b1b5dbdd8ee81a3655f83e33b2279d39",
                    "bf3e848279a722c806b485a47e67c807b946a337bee8942674278859e13292fb"
                ),
            ),
        ];
        for &(raw_key, data, expected_256, expected_512) in cases {
            let mut key_256 = [0; 32];
            key_256[..raw_key.len()].copy_from_slice(raw_key);
            let mut key_512 = [0; 64];
            key_512[..raw_key.len()].copy_from_slice(raw_key);
            for (key, expected, len) in [
                (HmacSha2::new_256(&key_256), expected_256, 32),
                (HmacSha2::new_512(&key_512), expected_512, 64),
            ] {
                assert_eq!(key.signature_len(), len);
                let expected: Vec<u8> = (0..expected.len())
                    .step_by(2)
                    .map(|i| u8::from_str_radix(&expected[i..i + 2], 16).unwrap())
                    .collect();
                assert_eq!(sign(&key, data), expected);
                key.verify(data, &expected).unwrap();
            }
        }
    }

    #[test]
    fn rejects_tampering_and_incorrect_lengths() {
        for (key, wrong_key) in [
            (HmacSha2::new_256(&[1; 32]), HmacSha2::new_256(&[2; 32])),
            (HmacSha2::new_512(&[1; 64]), HmacSha2::new_512(&[2; 64])),
        ] {
            let data = b"authenticated message";
            let signature = sign(&key, data);
            assert!(key.verify(b"modified message", &signature).is_err());
            assert!(wrong_key.verify(data, &signature).is_err());
            for i in 0..signature.len() {
                let mut modified = signature.clone();
                modified[i] ^= 1;
                assert!(key.verify(data, &modified).is_err());
            }
            for len in 0..signature.len() {
                assert!(key.verify(data, &signature[..len]).is_err());
            }
            let mut extended = signature.clone();
            extended.push(0);
            assert!(key.verify(data, &extended).is_err());
            key.verify(data, &signature).unwrap();
        }
    }

    #[test]
    fn verification_errors_preserve_the_backend_cause() {
        for key in [HmacSha2::new_256(&[1; 32]), HmacSha2::new_512(&[1; 64])] {
            let error = key.verify(b"message", &[]).unwrap_err();
            assert!(error.to_string().contains("HMAC verification failed"));
            let source = error.source().expect("backend error is preserved");
            cfg_select! {
                feature = "ring" => {
                    assert!(source.is::<crate::dep::ring::error::Unspecified>());
                }
                feature = "aws-lc" => {
                    assert!(source.is::<crate::dep::aws_lc_rs::error::Unspecified>());
                }
                _ => {
                    assert!(source.is::<::hmac::digest::MacError>());
                }
            }
        }
    }

    #[test]
    fn reusable_and_cloned_keys() {
        for key in [
            HmacSha2::new_256(&[0xff; 32]),
            HmacSha2::new_512(&[0xff; 64]),
        ] {
            let cloned = key.clone();
            let original = sign(&key, b"first message");
            for data in [b"".as_slice(), b"second message", &[0xa5; 1024]] {
                let signature = sign(&key, data);
                assert_eq!(signature, sign(&cloned, data));
                key.verify(data, &signature).unwrap();
                cloned.verify(data, &signature).unwrap();
            }
            assert_eq!(original, sign(&key, b"first message"));
            assert_eq!(original, sign(&cloned, b"first message"));
        }
    }

    #[test]
    fn random_keys() {
        for (key, other, len) in [
            (
                HmacSha2::try_rand_256().unwrap(),
                HmacSha2::try_rand_256().unwrap(),
                32,
            ),
            (
                HmacSha2::try_rand_512().unwrap(),
                HmacSha2::try_rand_512().unwrap(),
                64,
            ),
        ] {
            assert_eq!(key.signature_len(), len);
            let signature = sign(&key, b"message");
            key.verify(b"message", &signature).unwrap();
            key.verify(b"message", &signature).unwrap();
            assert_ne!(signature, sign(&other, b"message"));
            assert!(other.verify(b"message", &signature).is_err());
        }
    }

    #[test]
    fn sign_rejects_incorrect_output_lengths() {
        for key in [HmacSha2::new_256(&[0; 32]), HmacSha2::new_512(&[0; 64])] {
            for len in [0, key.signature_len() - 1, key.signature_len() + 1] {
                assert!(
                    std::panic::catch_unwind(|| {
                        key.sign(b"message", &mut vec![0; len]);
                    })
                    .is_err()
                );
            }
        }
    }
}
