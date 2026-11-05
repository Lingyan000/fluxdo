//! What keeping part of a received packet costs.

use rama_core::bytes::Bytes;

/// Bytes taken from a received packet to keep past its processing.
pub(super) struct Retained {
    pub(super) bytes: Bytes,
    /// The memory `bytes` keeps allocated, which is what a budget holding them must count.
    pub(super) charge: usize,
}

/// Prepare `bytes`, a slice of a received packet that keeps `allocated` bytes alive, to be kept.
///
/// A slice keeps all of that alive, so one under half of it is copied out and charged its own
/// length; a larger one stays shared and is charged the allocation.
pub(super) fn retain(bytes: Bytes, allocated: usize) -> Retained {
    if bytes.len().saturating_mul(2) < allocated {
        let charge = bytes.len();
        Retained {
            bytes: Bytes::copy_from_slice(&bytes),
            charge,
        }
    } else {
        let charge = allocated.max(bytes.len());
        Retained { bytes, charge }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn small_parts_are_detached_and_large_ones_charged_their_packet() {
        let packet = Bytes::from(vec![7u8; 1200]);
        for (len, copied) in [
            (0, true),
            (1, true),
            (599, true),
            (600, false),
            (1200, false),
        ] {
            let retained = retain(packet.slice(..len), packet.len());
            assert_eq!(retained.bytes.as_ref(), &packet[..len]);
            if copied {
                assert_eq!(retained.charge, len);
            } else {
                assert_eq!(retained.charge, packet.len());
            }
            drop(retained);
            assert!(
                packet.is_unique(),
                "nothing kept the packet after a {len}-byte part"
            );
        }
        let retained = retain(packet.slice(..1), packet.len());
        assert!(
            packet.is_unique(),
            "a one-byte part keeps no hold on its packet"
        );
        let retained_large = retain(packet.slice(..900), packet.len());
        assert!(!packet.is_unique(), "a large part shares its packet");
        drop((retained, retained_large));
    }
}
