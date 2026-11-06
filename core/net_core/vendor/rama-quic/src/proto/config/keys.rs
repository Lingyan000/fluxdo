use std::fmt;
#[cfg(any(feature = "aws-lc", feature = "ring", feature = "boring"))]
use std::sync::Arc;

#[cfg(all(feature = "aws-lc", not(feature = "ring")))]
use rama_crypto::dep::aws_lc_rs::hkdf;
#[cfg(feature = "ring")]
use rama_crypto::dep::ring::hkdf;
use rama_crypto::hmac::HmacSha2;

#[cfg(any(feature = "aws-lc", feature = "ring", feature = "boring"))]
use crate::proto::{config::ConfigError, crypto::HandshakeTokenKey};

/// Bytes of secret material accepted by the fixed-size key constructors.
pub const KEY_MATERIAL_SIZE: usize = 32;

/// The key an endpoint derives the stateless reset tokens it issues from (RFC 9000 §10.3).
///
/// An endpoint gives a peer a token per connection ID, and the peer recognises a stateless
/// reset by that token. Endpoints holding the same key derive the same token for the same
/// connection ID, so a peer of one of them recognises a reset from another: that is how a
/// restarted process, or another endpoint of the same service, can reset a connection whose
/// state it does not have. An endpoint given no key generates one, which no other endpoint
/// holds. Whatever keeps the material between restarts has to keep it secret.
///
/// The material is derived with HMAC-SHA256 whichever provider is compiled in, so the same
/// bytes give the same tokens on all of them, including builds without a native provider.
#[derive(Clone)]
pub struct StatelessResetKey(HmacSha2);

impl StatelessResetKey {
    /// Construct a key from a seed of [`KEY_MATERIAL_SIZE`] bytes.
    #[must_use]
    pub fn from_seed(seed: &[u8; KEY_MATERIAL_SIZE]) -> Self {
        Self(HmacSha2::new_256(seed))
    }

    pub(crate) fn into_key(self) -> HmacSha2 {
        self.0
    }
}

impl fmt::Debug for StatelessResetKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("StatelessResetKey")
    }
}

/// The key a server seals address-validation tokens with (RFC 9000 §8.1).
///
/// Retry tokens and the tokens sent in NEW_TOKEN frames are sealed with it, so servers holding
/// the same key can read one another's, as can a server that keeps its key across a restart.
/// Reading a token is not accepting it: the address it was issued for, its lifetime and, for a
/// NEW_TOKEN token, whether it has been seen before all still decide. A server given no key
/// generates one. The same secrecy applies as for [`StatelessResetKey`].
///
/// The material is derived with HKDF-SHA256 whichever provider is compiled in.
#[cfg(any(feature = "aws-lc", feature = "ring", feature = "boring"))]
#[derive(Clone)]
pub struct AddressTokenKey(Arc<dyn HandshakeTokenKey>);

#[cfg(any(feature = "aws-lc", feature = "ring", feature = "boring"))]
impl AddressTokenKey {
    /// Construct a key from a seed of [`KEY_MATERIAL_SIZE`] bytes.
    #[must_use]
    pub fn from_seed(seed: &[u8; KEY_MATERIAL_SIZE]) -> Self {
        Self::from_material(seed)
    }

    /// Construct a key from at least [`KEY_MATERIAL_SIZE`] bytes of secret material.
    ///
    /// Fails when the material is shorter than that.
    pub fn try_from_bytes(material: &[u8]) -> Result<Self, ConfigError> {
        if material.len() < KEY_MATERIAL_SIZE {
            return Err(ConfigError::KeyMaterialTooShort);
        }
        Ok(Self::from_material(material))
    }

    pub(super) fn from_material(material: &[u8]) -> Self {
        #[cfg(any(feature = "aws-lc", feature = "ring"))]
        let key = hkdf::Salt::new(hkdf::HKDF_SHA256, &[]).extract(material);
        #[cfg(not(any(feature = "aws-lc", feature = "ring")))]
        let key = crate::proto::crypto::boring::token::TokenKey::from_material(material);
        Self(Arc::new(key))
    }

    pub(crate) fn into_key(self) -> Arc<dyn HandshakeTokenKey> {
        self.0
    }
}

#[cfg(any(feature = "aws-lc", feature = "ring", feature = "boring"))]
impl fmt::Debug for AddressTokenKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("AddressTokenKey")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proto::token::reset_token;
    use rama_quic_proto::{ConnectionId, RESET_TOKEN_SIZE};

    #[test]
    fn reset_key_debug_hides_secret_material() {
        let key = StatelessResetKey::from_seed(&[0x4b; KEY_MATERIAL_SIZE]);
        assert_eq!(format!("{key:?}"), "StatelessResetKey");
    }

    #[test]
    fn reset_tokens_are_the_same_on_every_provider() {
        let reset = StatelessResetKey::from_seed(&[0x4b; KEY_MATERIAL_SIZE]).into_key();
        let token = reset_token(&reset, ConnectionId::new(&[0x01, 0x02, 0x03, 0x04]));
        assert_eq!(
            &token[..],
            &[
                0x5b, 0xbf, 0xb4, 0xfe, 0x26, 0xc5, 0x00, 0xc7, 0xf7, 0x7c, 0x44, 0x14, 0xe6, 0xda,
                0x51, 0xfd
            ],
            "HMAC-SHA256 over the connection ID, truncated to {RESET_TOKEN_SIZE} bytes"
        );
    }

    #[cfg(any(feature = "aws-lc", feature = "ring", feature = "boring"))]
    #[test]
    fn address_token_key_validates_material_and_hides_it() {
        let short = [0x5a; KEY_MATERIAL_SIZE - 1];
        assert_eq!(
            AddressTokenKey::try_from_bytes(&short).unwrap_err(),
            ConfigError::KeyMaterialTooShort
        );
        AddressTokenKey::try_from_bytes(&[0x5a; KEY_MATERIAL_SIZE]).unwrap();
        AddressTokenKey::try_from_bytes(&[0x5a; KEY_MATERIAL_SIZE * 2]).unwrap();
        let key = AddressTokenKey::from_seed(&[0x4b; KEY_MATERIAL_SIZE]);
        assert_eq!(format!("{key:?}"), "AddressTokenKey");
    }

    #[cfg(any(feature = "aws-lc", feature = "ring", feature = "boring"))]
    #[test]
    fn address_tokens_are_the_same_on_every_provider() {
        let sealing = AddressTokenKey::from_seed(&[0x4b; KEY_MATERIAL_SIZE]).into_key();
        let aead = sealing.aead_from_hkdf(&[0x11; 16]).unwrap();
        let mut sealed = b"a token payload".to_vec();
        aead.seal(&mut sealed, b"the associated data").unwrap();
        assert_eq!(
            sealed,
            vec![
                0x8c, 0x99, 0x11, 0x9b, 0xa2, 0xbe, 0x77, 0x88, 0x57, 0x90, 0xc9, 0xec, 0x36, 0xeb,
                0x0e, 0x91, 0x30, 0x69, 0x85, 0x01, 0xe0, 0x68, 0x2f, 0xe5, 0xc4, 0x64, 0x74, 0x8a,
                0x9b, 0x6b, 0xe2
            ]
        );
    }
}
