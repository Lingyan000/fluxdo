#[cfg(all(feature = "aws-lc", not(feature = "ring")))]
use rama_crypto::dep::aws_lc_rs::{aead, error, hkdf};
#[cfg(feature = "ring")]
use rama_crypto::dep::ring::{aead, error, hkdf};

use crate::proto::crypto::{self};
use rama_quic_proto::crypto::CryptoError;

// The backend's own error carries no detail this crate keeps, so every failure maps to the
// opaque `CryptoError`. (`CryptoError` lives in `rama-quic-proto`, so a `From` impl here would
// violate the orphan rule.)
fn crypto_error(_: error::Unspecified) -> CryptoError {
    CryptoError::new()
}

impl crypto::HandshakeTokenKey for hkdf::Prk {
    fn aead_from_hkdf(&self, random_bytes: &[u8]) -> Result<Box<dyn crypto::AeadKey>, CryptoError> {
        let mut key_buffer = [0u8; 32];
        let info = [random_bytes];
        let okm = self
            .expand(&info, hkdf::HKDF_SHA256)
            .map_err(crypto_error)?;
        okm.fill(&mut key_buffer).map_err(crypto_error)?;
        let key = aead::UnboundKey::new(&aead::AES_256_GCM, &key_buffer).map_err(crypto_error)?;
        Ok(Box::new(aead::LessSafeKey::new(key)))
    }
}

impl crypto::AeadKey for aead::LessSafeKey {
    fn seal(&self, data: &mut Vec<u8>, additional_data: &[u8]) -> Result<(), CryptoError> {
        let aad = aead::Aad::from(additional_data);
        let zero_nonce = aead::Nonce::assume_unique_for_key([0u8; 12]);
        self.seal_in_place_append_tag(zero_nonce, aad, data)
            .map_err(crypto_error)
    }

    fn open<'a>(
        &self,
        data: &'a mut [u8],
        additional_data: &[u8],
    ) -> Result<&'a mut [u8], CryptoError> {
        let aad = aead::Aad::from(additional_data);
        let zero_nonce = aead::Nonce::assume_unique_for_key([0u8; 12]);
        self.open_in_place(zero_nonce, aad, data)
            .map_err(crypto_error)
    }
}
