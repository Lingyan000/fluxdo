//! QUIC v1 packet protection using GnuTLS's HKDF and AES primitives.
use crate::native;
use rama::{
    bytes::BytesMut,
    quic::{
        proto::{
            ConnectionId, Side,
            crypto::{self, CryptoError},
        },
        tls::provider::{self, DirectionalKeys, Keys},
    },
};
use zeroize::Zeroizing;

pub struct Secret(Zeroizing<[u8; 32]>);

impl Secret {
    pub fn new(bytes: &[u8]) -> Self {
        Self(Zeroizing::new(
            bytes.try_into().expect("AES128/SHA256 secret"),
        ))
    }

    fn expand<const N: usize>(&self, label: &[u8]) -> native::Result<Zeroizing<[u8; N]>> {
        let info = rama::tls::key_schedule::encode_hkdf_label(label, &[], N)
            .expect("fixed QUIC label and length");
        let mut out = Zeroizing::new([0; N]);
        native::expand(&self.0, &info, &mut *out)?;
        Ok(out)
    }

    pub fn updated(&self) -> native::Result<Self> {
        Ok(Self(self.expand(b"quic ku")?))
    }

    pub fn packet(&self) -> native::Result<PacketKey> {
        Ok(PacketKey {
            key: self.expand(b"quic key")?,
            iv: self.expand(b"quic iv")?,
        })
    }

    pub fn keys(&self) -> native::Result<DirectionalKeys> {
        Ok(DirectionalKeys {
            header: Box::new(HeaderKey(self.expand(b"quic hp")?)),
            packet: Box::new(self.packet()?),
        })
    }
}

pub fn initial(cid: &ConnectionId, side: Side) -> native::Result<Keys> {
    // RFC 9001 section 5.2 (QUIC v1 only).
    let salt = [
        0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c,
        0xad, 0xcc, 0xbb, 0x7f, 0x0a,
    ];
    let extracted = Secret(native::extract(&salt, cid)?);
    let client = Secret(extracted.expand(b"client in")?).keys()?;
    let server = Secret(extracted.expand(b"server in")?).keys()?;
    Ok(if side == Side::Client {
        Keys {
            local: client,
            remote: Some(server),
        }
    } else {
        Keys {
            local: server,
            remote: Some(client),
        }
    })
}

const RETRY_KEY: [u8; 16] = [
    0xbe, 0x0c, 0x69, 0x0b, 0x9f, 0x66, 0x57, 0x5a, 0x1d, 0x76, 0x6b, 0x54, 0xe3, 0x68, 0xc8, 0x4e,
];

const RETRY_NONCE: [u8; 12] = [
    0x46, 0x15, 0x99, 0xd3, 0x5d, 0x63, 0x2b, 0xf2, 0x23, 0x98, 0x25, 0xbb,
];

fn retry_aad(cid: &ConnectionId, packet: &[u8]) -> Vec<u8> {
    let mut aad = vec![u8::try_from(cid.len()).expect("QUIC CID length")];
    aad.extend_from_slice(cid);
    aad.extend_from_slice(packet);
    aad
}

pub fn retry_tag(cid: &ConnectionId, packet: &[u8]) -> native::Result<[u8; 16]> {
    native::init()?;
    Ok(native::aead(
        false,
        &RETRY_KEY,
        &RETRY_NONCE,
        &retry_aad(cid, packet),
        &[],
    )?
    .try_into()
    .expect("empty AES-GCM plaintext produces one tag"))
}

pub fn valid_retry(cid: &ConnectionId, header: &[u8], payload: &[u8]) -> bool {
    let Some(end) = payload.len().checked_sub(16) else {
        return false;
    };
    let mut packet = header.to_vec();
    packet.extend_from_slice(&payload[..end]);
    native::aead(
        true,
        &RETRY_KEY,
        &RETRY_NONCE,
        &retry_aad(cid, &packet),
        &payload[end..],
    )
    .is_ok()
}

pub struct PacketKey {
    key: Zeroizing<[u8; 16]>,
    iv: Zeroizing<[u8; 12]>,
}

impl PacketKey {
    fn nonce(&self, number: u64) -> [u8; 12] {
        let mut nonce = *self.iv;
        for (byte, number) in nonce[4..].iter_mut().zip(number.to_be_bytes()) {
            *byte ^= number;
        }
        nonce
    }
}

impl crypto::PacketKey for PacketKey {
    fn encrypt(
        &self,
        number: u64,
        buffer: &mut [u8],
        header_len: usize,
    ) -> Result<(), CryptoError> {
        let (header, payload) = buffer.split_at_mut(header_len);
        let end = payload.len().checked_sub(16).ok_or_else(CryptoError::new)?;
        let encrypted = native::aead(
            false,
            &self.key,
            &self.nonce(number),
            header,
            &payload[..end],
        )
        .map_err(|_| CryptoError::new())?;
        payload.copy_from_slice(&encrypted);
        Ok(())
    }

    fn decrypt(
        &self,
        number: u64,
        header: &[u8],
        payload: &mut BytesMut,
    ) -> Result<(), CryptoError> {
        let plain = native::aead(true, &self.key, &self.nonce(number), header, payload)
            .map_err(|_| CryptoError::new())?;
        payload.clear();
        payload.extend_from_slice(&plain);
        Ok(())
    }

    fn tag_len(&self) -> usize {
        16
    }

    fn confidentiality_limit(&self) -> u64 {
        1 << 23
    }

    fn integrity_limit(&self) -> u64 {
        1 << 52
    }
}

struct HeaderKey(Zeroizing<[u8; 16]>);

impl HeaderKey {
    fn apply(&self, offset: usize, packet: &mut [u8], decrypt: bool) {
        let sample = packet[offset + 4..offset + 20]
            .try_into()
            .expect("transport provides a full header sample");
        let mask = native::mask(&self.0, sample).expect("GnuTLS AES block operation");
        let first = packet[0];
        let changed = first ^ (mask[0] & if first & 0x80 == 0 { 0x1f } else { 0x0f });
        let len = usize::from(((if decrypt { changed } else { first }) & 3) + 1);
        packet[0] = changed;
        for (byte, mask) in packet[offset..offset + len].iter_mut().zip(&mask[1..]) {
            *byte ^= mask;
        }
    }
}

impl crypto::HeaderKey for HeaderKey {
    fn encrypt(&self, offset: usize, packet: &mut [u8]) {
        self.apply(offset, packet, false);
    }

    fn decrypt(&self, offset: usize, packet: &mut [u8]) {
        self.apply(offset, packet, true);
    }

    fn sample_size(&self) -> usize {
        16
    }
}

pub struct TokenKey(Zeroizing<[u8; 32]>);

impl TokenKey {
    pub fn new() -> native::Result<Self> {
        let mut key = Zeroizing::new([0; 32]);
        native::random(&mut *key)?;
        Ok(Self(key))
    }
}

struct TokenAead(Zeroizing<[u8; 16]>);

impl provider::HandshakeTokenKey for TokenKey {
    fn aead_from_hkdf(&self, random: &[u8]) -> Result<Box<dyn provider::AeadKey>, CryptoError> {
        let mut key = Zeroizing::new([0; 16]);
        native::expand(&self.0, random, &mut *key).map_err(|_| CryptoError::new())?;
        Ok(Box::new(TokenAead(key)))
    }
}

impl provider::AeadKey for TokenAead {
    fn seal(&self, data: &mut Vec<u8>, aad: &[u8]) -> Result<(), CryptoError> {
        *data =
            native::aead(false, &self.0, &[0; 12], aad, data).map_err(|_| CryptoError::new())?;
        Ok(())
    }

    fn open<'a>(&self, data: &'a mut [u8], aad: &[u8]) -> Result<&'a mut [u8], CryptoError> {
        let plain =
            native::aead(true, &self.0, &[0; 12], aad, data).map_err(|_| CryptoError::new())?;
        data[..plain.len()].copy_from_slice(&plain);
        Ok(&mut data[..plain.len()])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let cid = ConnectionId::try_from_bytes(&hex("8394c8f03e515708")).unwrap();
        let keys = initial(&cid, Side::Server).unwrap();
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
        let read = initial(&cid, Side::Client).unwrap().remote.unwrap();
        read.header.decrypt(header.len() - 2, &mut packet);
        assert_eq!(&packet[..header.len()], header);
        let mut decrypted = BytesMut::from(&packet[header.len()..]);
        read.packet.decrypt(1, &header, &mut decrypted).unwrap();
        assert_eq!(decrypted, payload);
    }

    #[test]
    fn rfc9001_retry() {
        let cid = ConnectionId::try_from_bytes(&hex("8394c8f03e515708")).unwrap();
        let packet = hex("ff000000010008f067a5502a4262b5746f6b656e");
        assert_eq!(
            retry_tag(&cid, &packet).unwrap().as_slice(),
            hex("04a265ba2eff4d829058fb3f0f2496ba")
        );
    }
}
