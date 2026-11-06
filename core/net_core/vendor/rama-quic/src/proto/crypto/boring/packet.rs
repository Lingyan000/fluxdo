use rama_core::{
    bytes::BytesMut,
    error::{BoxError, BoxErrorExt as _},
};
use rama_crypto::dep::boring::{aead, aes::AesEncryptKey, chacha, hash::MessageDigest, hkdf};
use zeroize::Zeroizing;

use crate::proto::crypto::{self, DirectionalKeys, Keys};
use rama_quic_proto::{
    ConnectionId, Side, Version,
    crypto::CryptoError,
    version::{Labels, Wire},
};

#[derive(Clone, Copy)]
pub(super) enum Suite {
    Aes128Gcm,
    Aes256Gcm,
    ChaCha20Poly1305,
}

impl Suite {
    pub(super) fn from_id(id: u16) -> Result<Self, BoxError> {
        match id {
            0x1301 => Ok(Self::Aes128Gcm),
            0x1302 => Ok(Self::Aes256Gcm),
            0x1303 => Ok(Self::ChaCha20Poly1305),
            _ => Err(BoxError::from_static_str("unsupported QUIC cipher suite")),
        }
    }

    fn digest(self) -> MessageDigest {
        match self {
            Self::Aes256Gcm => MessageDigest::sha384(),
            _ => MessageDigest::sha256(),
        }
    }

    fn aead(self) -> aead::Algorithm {
        match self {
            Self::Aes128Gcm => aead::Algorithm::Aes128Gcm,
            Self::Aes256Gcm => aead::Algorithm::Aes256Gcm,
            Self::ChaCha20Poly1305 => aead::Algorithm::ChaCha20Poly1305,
        }
    }
}

pub(super) struct Secret {
    suite: Suite,
    bytes: Zeroizing<Vec<u8>>,
    /// The version's HKDF labels: `quic *` for v1, `quicv2 *` for v2 (RFC 9369 §3.3.2).
    labels: &'static Labels,
}

impl Secret {
    pub(super) fn new(
        suite: Suite,
        bytes: &[u8],
        labels: &'static Labels,
    ) -> Result<Self, BoxError> {
        if bytes.len() != suite.digest().size() {
            return Err(BoxError::from_static_str(
                "invalid QUIC traffic secret length",
            ));
        }
        Ok(Self {
            suite,
            bytes: Zeroizing::new(bytes.to_vec()),
            labels,
        })
    }

    fn expand(&self, label: &[u8], output: &mut [u8]) -> Result<(), BoxError> {
        let info = rama_tls::key_schedule::encode_hkdf_label(label, &[], output.len())?;
        hkdf::expand(self.suite.digest(), &self.bytes, &info, output)?;
        Ok(())
    }

    pub(super) fn updated(&self) -> Result<Self, BoxError> {
        let mut bytes = Zeroizing::new(vec![0; self.bytes.len()]);
        self.expand(self.labels.ku, &mut bytes)?;
        Ok(Self {
            suite: self.suite,
            bytes,
            labels: self.labels,
        })
    }

    pub(super) fn packet_key(&self) -> Result<PacketKey, BoxError> {
        let mut key = Zeroizing::new(vec![0; self.suite.aead().key_len()]);
        let mut iv = Zeroizing::new([0; 12]);
        self.expand(self.labels.key, &mut key)?;
        self.expand(self.labels.iv, &mut *iv)?;
        Ok(PacketKey {
            suite: self.suite,
            key: aead::AeadKey::new(self.suite.aead(), &key)?,
            iv,
        })
    }

    pub(super) fn directional_keys(&self) -> Result<DirectionalKeys, BoxError> {
        let mut key = Zeroizing::new([0; 32]);
        let len = self.suite.aead().key_len();
        self.expand(self.labels.hp, &mut key[..len])?;
        let header = match self.suite {
            Suite::ChaCha20Poly1305 => HeaderKey::ChaCha(key),
            _ => HeaderKey::Aes(AesEncryptKey::new(&key[..len]).map_err(|_error| {
                BoxError::from_static_str("invalid QUIC header protection key")
            })?),
        };
        Ok(DirectionalKeys {
            header: Box::new(header),
            packet: Box::new(self.packet_key()?),
        })
    }
}

pub(super) fn initial_keys(
    wire: &'static Wire,
    cid: &ConnectionId,
    side: Side,
) -> Result<Keys, BoxError> {
    let mut extracted = Zeroizing::new([0; 32]);
    hkdf::extract(
        MessageDigest::sha256(),
        &wire.initial_salt,
        cid,
        &mut *extracted,
    )?;
    let secret = Secret::new(Suite::Aes128Gcm, &*extracted, &wire.labels)?;
    let mut client = Zeroizing::new([0; 32]);
    let mut server = Zeroizing::new([0; 32]);
    secret.expand(b"client in", &mut *client)?;
    secret.expand(b"server in", &mut *server)?;
    let client = Secret::new(Suite::Aes128Gcm, &*client, &wire.labels)?.directional_keys()?;
    let server = Secret::new(Suite::Aes128Gcm, &*server, &wire.labels)?.directional_keys()?;
    let (local, remote) = if side.is_client() {
        (client, server)
    } else {
        (server, client)
    };
    Ok(Keys {
        local,
        remote: Some(remote),
    })
}

pub(super) fn retry_tag(
    wire: &Wire,
    cid: &ConnectionId,
    packet: &[u8],
) -> Result<[u8; 16], BoxError> {
    let mut aad = Vec::with_capacity(1 + cid.len() + packet.len());
    aad.push(cid.len() as u8);
    aad.extend_from_slice(cid);
    aad.extend_from_slice(packet);
    let mut tag = [0; 16];
    aead::AeadKey::new(aead::Algorithm::Aes128Gcm, &wire.retry_key)?.seal_in_place(
        &wire.retry_nonce,
        &aad,
        &mut tag,
    )?;
    Ok(tag)
}

/// The wire constants of a version this provider implements.
pub(super) fn wire(version: Version) -> Option<&'static Wire> {
    version.wire()
}

pub(super) struct PacketKey {
    suite: Suite,
    key: aead::AeadKey,
    iv: Zeroizing<[u8; 12]>,
}

impl PacketKey {
    fn nonce(&self, packet: u64) -> [u8; 12] {
        let mut nonce = *self.iv;
        for (byte, number) in nonce[4..].iter_mut().zip(packet.to_be_bytes()) {
            *byte ^= number;
        }
        nonce
    }
}

impl crypto::PacketKey for PacketKey {
    fn encrypt(
        &self,
        packet: u64,
        buffer: &mut [u8],
        header_len: usize,
    ) -> Result<(), CryptoError> {
        let (header, payload) = buffer.split_at_mut(header_len);
        self.key
            .seal_in_place(&self.nonce(packet), header, payload)
            .map_err(|_error| CryptoError::new())
    }

    fn decrypt(
        &self,
        packet: u64,
        header: &[u8],
        payload: &mut BytesMut,
    ) -> Result<(), CryptoError> {
        let len = self
            .key
            .open_in_place(&self.nonce(packet), header, payload)
            .map_err(|_error| CryptoError::new())?
            .len();
        payload.truncate(len);
        Ok(())
    }

    fn tag_len(&self) -> usize {
        16
    }
    fn confidentiality_limit(&self) -> u64 {
        match self.suite {
            Suite::ChaCha20Poly1305 => 1 << 62,
            _ => 1 << 23,
        }
    }
    fn integrity_limit(&self) -> u64 {
        match self.suite {
            Suite::ChaCha20Poly1305 => 1 << 36,
            _ => 1 << 52,
        }
    }
}

#[expect(
    clippy::large_enum_variant,
    reason = "the complete key is already boxed as a HeaderKey trait object"
)]
enum HeaderKey {
    Aes(AesEncryptKey),
    ChaCha(Zeroizing<[u8; 32]>),
}

impl HeaderKey {
    fn mask(&self, sample: &[u8]) -> [u8; 5] {
        let mut mask = [0; 5];
        match self {
            Self::Aes(key) => {
                let mut block = [0; 16];
                block.copy_from_slice(sample);
                mask.copy_from_slice(&key.encrypt_block(&block)[..5]);
            }
            Self::ChaCha(key) => {
                let counter = u32::from_le_bytes([sample[0], sample[1], sample[2], sample[3]]);
                let mut nonce = [0; 12];
                nonce.copy_from_slice(&sample[4..]);
                chacha::apply(key, &nonce, counter, &mut mask);
            }
        }
        mask
    }

    fn apply(&self, pn_offset: usize, packet: &mut [u8], decrypt: bool) {
        // The packet decoder/builder guarantees a full sample after four PN bytes.
        let mask = self.mask(&packet[pn_offset + 4..pn_offset + 20]);
        let first = packet[0];
        let masked = first ^ (mask[0] & if first & 0x80 == 0 { 0x1f } else { 0x0f });
        let pn_len = usize::from((if decrypt { masked } else { first } & 3) + 1);
        packet[0] = masked;
        for (byte, mask) in packet[pn_offset..pn_offset + pn_len]
            .iter_mut()
            .zip(&mask[1..])
        {
            *byte ^= mask;
        }
    }
}

impl crypto::HeaderKey for HeaderKey {
    fn encrypt(&self, pn_offset: usize, packet: &mut [u8]) {
        self.apply(pn_offset, packet, false);
    }
    fn decrypt(&self, pn_offset: usize, packet: &mut [u8]) {
        self.apply(pn_offset, packet, true);
    }
    fn sample_size(&self) -> usize {
        16
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use rama_quic_proto::{
        crypto::{HeaderKey as _, PacketKey as _},
        version::V1_WIRE,
    };

    /// HMAC (RFC 2104) over one of the TLS 1.3 hashes. Written out here rather than taken
    /// from the crypto backend, so the expectations below come from an implementation
    /// independent of the one under test.
    fn hmac(hash_len: usize, key: &[u8], message: &[u8]) -> Vec<u8> {
        use sha2::{Digest as _, Sha256, Sha384};
        let block_len = if hash_len == 48 { 128 } else { 64 };
        // TLS 1.3 traffic secrets are one hash long, always shorter than the block.
        assert!(key.len() <= block_len);
        let mut padded = vec![0; block_len];
        padded[..key.len()].copy_from_slice(key);
        let round = |pad: u8, tail: &[u8]| {
            let mut input: Vec<u8> = padded.iter().map(|byte| byte ^ pad).collect();
            input.extend_from_slice(tail);
            if hash_len == 48 {
                Sha384::digest(&input).to_vec()
            } else {
                Sha256::digest(&input).to_vec()
            }
        };
        round(0x5c, &round(0x36, message))
    }

    /// HKDF-Expand-Label (RFC 8446, section 7.1) with an empty context, built here so that a
    /// wrong hash, label encoding or output length cannot agree with itself.
    fn expand_label(hash_len: usize, secret: &[u8], label: &[u8], output: &mut [u8]) {
        let mut info = u16::try_from(output.len()).unwrap().to_be_bytes().to_vec();
        info.push(u8::try_from(6 + label.len()).unwrap());
        info.extend_from_slice(b"tls13 ");
        info.extend_from_slice(label);
        info.push(0);
        let mut previous = Vec::new();
        let mut written = 0;
        for counter in 1..=u8::MAX {
            if written == output.len() {
                break;
            }
            let mut message = previous;
            message.extend_from_slice(&info);
            message.push(counter);
            let block = hmac(hash_len, secret, &message);
            let take = block.len().min(output.len() - written);
            output[written..written + take].copy_from_slice(&block[..take]);
            written += take;
            previous = block;
        }
    }

    /// RFC 8446 appendix B.4 names the hash in each cipher suite and RFC 9001 section 5.1
    /// derives the QUIC keys with it. A suite that expanded with the wrong hash would still
    /// agree with itself, so the round-trip tests below cannot observe it; neither can the
    /// handshake tests, which only reach whichever suite BoringSSL's preference picks on the
    /// host CPU. Pin the table and the derived material against the independent expansion.
    #[test]
    fn each_suite_derives_with_the_hash_its_code_point_names() {
        for (id, hash_len, key_len) in [
            (0x1301_u16, 32_usize, 16_usize),
            (0x1302, 48, 32),
            (0x1303, 32, 32),
        ] {
            let suite = Suite::from_id(id).expect("a supported QUIC cipher suite");
            assert_eq!(suite.digest().size(), hash_len);
            assert_eq!(suite.aead().key_len(), key_len);

            let bytes = vec![0x0b; hash_len];
            let secret = Secret::new(suite, &bytes, &V1_WIRE.labels).unwrap();

            let mut updated = vec![0; hash_len];
            expand_label(hash_len, &bytes, b"quic ku", &mut updated);
            assert_eq!(*secret.updated().unwrap().bytes, updated);

            let mut iv = [0; 12];
            expand_label(hash_len, &bytes, b"quic iv", &mut iv);
            let packet_key = secret.packet_key().unwrap();
            assert_eq!(*packet_key.iv, iv);

            // The AEAD and header keys are opaque, so compare what they produce against keys
            // built from independently expanded material.
            let mut key = vec![0; key_len];
            expand_label(hash_len, &bytes, b"quic key", &mut key);
            let expected = PacketKey {
                suite,
                key: aead::AeadKey::new(suite.aead(), &key).unwrap(),
                iv: Zeroizing::new(iv),
            };
            let (mut actual_packet, mut expected_packet) = ([0x33; 24], [0x33; 24]);
            packet_key.encrypt(7, &mut actual_packet, 4).unwrap();
            expected.encrypt(7, &mut expected_packet, 4).unwrap();
            assert_eq!(actual_packet, expected_packet);

            let mut hp = Zeroizing::new([0; 32]);
            expand_label(hash_len, &bytes, b"quic hp", &mut hp[..key_len]);
            let expected = match suite {
                Suite::ChaCha20Poly1305 => HeaderKey::ChaCha(hp),
                _ => HeaderKey::Aes(AesEncryptKey::new(&hp[..key_len]).unwrap()),
            };
            let (mut actual_packet, mut expected_packet) = ([0x33; 24], [0x33; 24]);
            secret
                .directional_keys()
                .unwrap()
                .header
                .encrypt(1, &mut actual_packet);
            expected.encrypt(1, &mut expected_packet);
            assert_eq!(actual_packet, expected_packet);
        }
    }

    /// QUIC uses only the three TLS 1.3 AEAD suites; anything else must be refused rather
    /// than silently treated as one of them.
    #[test]
    fn unsupported_cipher_suites_are_refused() {
        for id in [0x0000, 0x1300, 0x1304, 0x1305, 0x00ff, 0xc02b, 0xffff] {
            assert!(Suite::from_id(id).is_err(), "{id:#06x} is not a QUIC suite");
        }
    }

    fn hex(input: &str) -> Vec<u8> {
        input
            .split_whitespace()
            .collect::<String>()
            .as_bytes()
            .as_chunks::<2>()
            .0
            .iter()
            .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap())
            .collect()
    }

    #[test]
    fn rfc9001_server_initial() {
        let cid = ConnectionId::new(&hex("8394c8f03e515708"));
        let keys = initial_keys(&V1_WIRE, &cid, Side::Server).unwrap();
        let header = hex("c1000000010008f067a5502a4262b50040750001");
        let payload = hex(
            "02000000000600405a020000560303ee fce7f7b37ba1d1632e96677825ddf739
            88cfc79825df566dc5430b9a045a1200 130100002e00330024001d00209d3c94
            0d89690b84d08a60993c144eca684d10 81287c834d5311bcf32bb9da1a002b00 020304",
        );
        let mut packet = header.clone();
        packet.extend_from_slice(&payload);
        packet.resize(packet.len() + 16, 0);
        keys.local
            .packet
            .encrypt(1, &mut packet, header.len())
            .unwrap();
        keys.local.header.encrypt(header.len() - 2, &mut packet);
        assert_eq!(
            packet,
            hex(
                "cf000000010008f067a5502a4262b500 4075c0d95a482cd0991cd25b0aac406a
            5816b6394100f37a1c69797554780bb3 8cc5a99f5ede4cf73c3ec2493a1839b3
            dbcba3f6ea46c5b7684df3548e7ddeb9 c3bf9c73cc3f3bded74b562bfb19fb84
            022f8ef4cdd93795d77d06edbb7aaf2f 58891850abbdca3d20398c276456cbc4 2158407dd074ee"
            )
        );
        let read = initial_keys(&V1_WIRE, &cid, Side::Client)
            .unwrap()
            .remote
            .unwrap();
        read.header.decrypt(header.len() - 2, &mut packet);
        assert_eq!(&packet[..header.len()], header);
        let mut decrypted = BytesMut::from(&packet[header.len()..]);
        read.packet.decrypt(1, &header, &mut decrypted).unwrap();
        assert_eq!(decrypted, payload);
    }

    #[test]
    fn rfc9001_retry() {
        let cid = ConnectionId::new(&hex("8394c8f03e515708"));
        let packet = hex("ff000000010008f067a5502a4262b5746f6b656e");
        assert_eq!(
            retry_tag(&V1_WIRE, &cid, &packet).unwrap().as_slice(),
            hex("04a265ba2eff4d829058fb3f0f2496ba")
        );
    }

    /// RFC 9369 Appendix A.5: the same ChaCha20 secret as RFC 9001, expanded with the
    /// `quicv2` labels.
    #[test]
    fn rfc9369_chacha_short_header_and_key_update() {
        use rama_quic_proto::version::V2_WIRE;
        let secret = Secret::new(
            Suite::ChaCha20Poly1305,
            &hex("9ac312a7f877468ebe69422748ad00a15443f18203a07d6060f688f30f21632b"),
            &V2_WIRE.labels,
        )
        .unwrap();
        assert_eq!(
            *secret.updated().unwrap().bytes,
            hex("c69374c49e3d2a9466fa689e49d476db5d0dfbc87d32ceeaa6343fd0ae4c7d88")
        );
        assert_eq!(
            *secret.packet_key().unwrap().iv,
            hex("a6b5bc6ab7dafce30ffff5dd")[..]
        );
        let keys = secret.directional_keys().unwrap();
        let mut packet = hex("4200bff401");
        packet.resize(21, 0);
        keys.packet.encrypt(654360564, &mut packet, 4).unwrap();
        keys.header.encrypt(1, &mut packet);
        assert_eq!(packet, hex("5558b1c60ae7b6b932bc27d786f4bc2bb20f2162ba"));
    }

    #[test]
    fn rfc9001_chacha_short_header_and_key_update() {
        let secret = Secret::new(
            Suite::ChaCha20Poly1305,
            &hex("9ac312a7f877468ebe69422748ad00a15443f18203a07d6060f688f30f21632b"),
            &V1_WIRE.labels,
        )
        .unwrap();
        assert_eq!(
            *secret.updated().unwrap().bytes,
            hex("1223504755036d556342ee9361d253421a826c9ecdf3c7148684b36b714881f9")
        );
        let keys = secret.directional_keys().unwrap();
        let mut packet = hex("4200bff401");
        packet.resize(21, 0);
        keys.packet.encrypt(654360564, &mut packet, 4).unwrap();
        keys.header.encrypt(1, &mut packet);
        assert_eq!(packet, hex("4cfe4189655e5cd55c41f69080575d7999c25a5bfb"));
        keys.header.decrypt(1, &mut packet);
        assert_eq!(&packet[..4], hex("4200bff4"));
        let mut payload = BytesMut::from(&packet[4..]);
        keys.packet
            .decrypt(654360564, &packet[..4], &mut payload)
            .unwrap();
        assert_eq!(&payload[..], &[1]);
    }

    /// RFC 9001 §6.6 and Appendix B: the AES-GCM suites stop at 2^23 packets per key and
    /// 2^52 forgeries per connection; ChaCha20-Poly1305 at 2^36 forgeries, with a
    /// confidentiality limit beyond the 2^62 packets a connection can number. The Initial keys
    /// are AES-128-GCM keys and answer as such.
    #[test]
    fn packet_keys_report_the_rfc_9001_aead_limits() {
        for (suite, confidentiality, integrity) in [
            (Suite::Aes128Gcm, 1 << 23, 1 << 52),
            (Suite::Aes256Gcm, 1 << 23, 1 << 52),
            (Suite::ChaCha20Poly1305, 1 << 62, 1 << 36),
        ] {
            let secret =
                Secret::new(suite, &vec![7; suite.digest().size()], &V1_WIRE.labels).unwrap();
            for key in [
                secret.packet_key().unwrap(),
                secret.updated().unwrap().packet_key().unwrap(),
            ] {
                assert_eq!(key.confidentiality_limit(), confidentiality);
                assert_eq!(key.integrity_limit(), integrity);
            }
        }
        let keys = initial_keys(
            &V1_WIRE,
            &ConnectionId::new(&[1, 2, 3, 4, 5, 6, 7, 8]),
            Side::Client,
        )
        .unwrap();
        for key in [&keys.local.packet, &keys.remote.unwrap().packet] {
            assert_eq!(key.confidentiality_limit(), 1 << 23);
            assert_eq!(key.integrity_limit(), 1 << 52);
        }
    }

    #[test]
    fn all_suites_authenticate_header_number_and_payload() {
        for suite in [Suite::Aes128Gcm, Suite::Aes256Gcm, Suite::ChaCha20Poly1305] {
            let secret =
                Secret::new(suite, &vec![7; suite.digest().size()], &V1_WIRE.labels).unwrap();
            let key = secret.packet_key().unwrap();
            let mut packet = vec![0; 24];
            packet[..8].copy_from_slice(b"headbody");
            key.encrypt(0x123456789, &mut packet, 4).unwrap();
            let mut wrong_number = BytesMut::from(&packet[4..]);
            assert!(
                key.decrypt(0x123456788, b"head", &mut wrong_number)
                    .is_err()
            );
            let mut wrong_header = BytesMut::from(&packet[4..]);
            assert!(
                key.decrypt(0x123456789, b"HEAD", &mut wrong_header)
                    .is_err()
            );
            let mut corrupt = BytesMut::from(&packet[4..]);
            corrupt[0] ^= 1;
            assert!(key.decrypt(0x123456789, b"head", &mut corrupt).is_err());
            let mut payload = BytesMut::from(&packet[4..]);
            key.decrypt(0x123456789, b"head", &mut payload).unwrap();
            assert_eq!(&payload[..], b"body");
            let mut old = BytesMut::from(&packet[4..]);
            assert!(
                secret
                    .updated()
                    .unwrap()
                    .packet_key()
                    .unwrap()
                    .decrypt(0x123456789, b"head", &mut old)
                    .is_err()
            );
        }
    }

    /// `Secret::new` is the only guard on a traffic secret's length. The suite table and the
    /// derivation it feeds are pinned by `each_suite_derives_with_the_hash_its_code_point_names`;
    /// what is left is that a secret of any other length is refused rather than expanded.
    #[test]
    fn a_traffic_secret_must_match_its_suite_hash_length() {
        for id in [0x1301u16, 0x1302, 0x1303] {
            let suite = Suite::from_id(id).unwrap();
            let len = suite.digest().size();
            Secret::new(suite, &vec![3; len], &V1_WIRE.labels).unwrap();
            for wrong in [0, len - 1, len + 1, 2 * len] {
                assert!(
                    Secret::new(suite, &vec![3; wrong], &V1_WIRE.labels).is_err(),
                    "{id:#06x} accepted a {wrong}-byte secret"
                );
            }
        }
    }

    /// RFC 9001 §5.4.1: header protection masks the low five bits of a short header's first
    /// byte but only the low four of a long header's, so a short header's second reserved bit
    /// is protected too. A sample whose mask byte happens to clear that bit cannot tell the two
    /// policies apart, so this checks several and requires that one of them could.
    #[test]
    fn header_protection_masks_a_fifth_bit_only_for_short_headers() {
        let key = HeaderKey::Aes(AesEncryptKey::new(&[0x2a; 16]).unwrap());
        let mut distinguishing = 0;
        for seed in 0..16u8 {
            let sample = [seed; 16];
            let mask = key.mask(&sample);
            distinguishing += usize::from(mask[0] & 0x10 != 0);
            // A short header sets 0x40 and clears 0x80; a long header sets both.
            for (first, protected) in [(0x42u8, 0x1fu8), (0xc3, 0x0f)] {
                let mut packet = vec![0; 21];
                packet[0] = first;
                packet[5..21].copy_from_slice(&sample);
                key.apply(1, &mut packet, false);
                assert_eq!(
                    packet[0] ^ first,
                    mask[0] & protected,
                    "first byte {first:#04x}"
                );
            }
        }
        assert!(
            distinguishing > 0,
            "no sample set the bit that separates the two masks, so this proved nothing"
        );
    }
}
