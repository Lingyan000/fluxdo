use rama_crypto::{
    dep::boring::{aead, hash::MessageDigest, hkdf},
    hmac::HmacSha2,
};
use zeroize::Zeroizing;

use crate::proto::crypto::{AeadKey, HandshakeTokenKey};
use rama_quic_proto::crypto::CryptoError;

pub(crate) struct TokenKey(Zeroizing<[u8; 32]>);

impl TokenKey {
    pub(crate) fn from_material(material: &[u8]) -> Self {
        let mut secret = Zeroizing::new([0; 32]);
        // HKDF-Extract with an empty salt uses a hash-length zero HMAC key.
        HmacSha2::new_256(&[0; 32]).sign(material, &mut *secret);
        Self(secret)
    }
}

impl HandshakeTokenKey for TokenKey {
    fn aead_from_hkdf(&self, random_bytes: &[u8]) -> Result<Box<dyn AeadKey>, CryptoError> {
        let mut key = Zeroizing::new([0; 32]);
        hkdf::expand(MessageDigest::sha256(), &*self.0, random_bytes, &mut *key)
            .map_err(|_error| CryptoError::new())?;
        Ok(Box::new(TokenAead(
            aead::AeadKey::new(aead::Algorithm::Aes256Gcm, &*key)
                .map_err(|_error| CryptoError::new())?,
        )))
    }
}

struct TokenAead(aead::AeadKey);

impl AeadKey for TokenAead {
    fn seal(&self, data: &mut Vec<u8>, additional_data: &[u8]) -> Result<(), CryptoError> {
        data.resize(data.len() + 16, 0);
        self.0
            .seal_in_place(&[0; 12], additional_data, data)
            .map_err(|_error| CryptoError::new())
    }

    fn open<'a>(
        &self,
        data: &'a mut [u8],
        additional_data: &[u8],
    ) -> Result<&'a mut [u8], CryptoError> {
        self.0
            .open_in_place(&[0; 12], additional_data, data)
            .map_err(|_error| CryptoError::new())
    }
}

#[cfg(all(test, any(feature = "ring", feature = "aws-lc")))]
mod tests {
    use super::*;
    #[cfg(all(feature = "aws-lc", not(feature = "ring")))]
    use rama_crypto::dep::aws_lc_rs::hkdf as reference;
    #[cfg(feature = "ring")]
    use rama_crypto::dep::ring::hkdf as reference;

    #[test]
    fn tokens_are_interchangeable_between_providers() {
        let material = [0x5a; 48];
        let salt = b"per-token randomness";
        let aad = b"token address";
        let boring = TokenKey::from_material(&material)
            .aead_from_hkdf(salt)
            .unwrap();
        let other = reference::Salt::new(reference::HKDF_SHA256, &[])
            .extract(&material)
            .aead_from_hkdf(salt)
            .unwrap();
        let mut native = b"token body".to_vec();
        let mut expected = native.clone();
        boring.seal(&mut native, aad).unwrap();
        other.seal(&mut expected, aad).unwrap();
        assert_eq!(native, expected);
        assert_eq!(other.open(&mut native, aad).unwrap(), b"token body");
        assert_eq!(boring.open(&mut expected, aad).unwrap(), b"token body");
    }
}
