//! Chromium-style "chaos protection" for a client's Initial packets: the CRYPTO data is split
//! into fragments of random size written in random order, with PING and PADDING frames between
//! them. The payload keeps its length and carries exactly the same CRYPTO bytes, so nothing
//! about loss recovery or reassembly changes; only the arrangement an observer sees does.

use rama_core::bytes::Bytes;
use rama_quic_proto::{
    VarInt,
    coding::BufMutExt,
    frame::{self, Frame, FrameType},
};
use rand::{Rng, RngExt, seq::SliceRandom as _};

/// A CRYPTO fragment as it will be written.
struct Fragment {
    offset: u64,
    data: Bytes,
}

impl Fragment {
    fn size(&self) -> usize {
        1 + VarInt::size(VarInt::from_u64(self.offset).unwrap_or(VarInt::MAX))
            + VarInt::size(VarInt::from_u32(self.data.len() as u32))
            + self.data.len()
    }
}

enum Item {
    Crypto(Fragment),
    Ping,
    Padding(usize),
}

/// Rearrange `payload` in place when it holds only CRYPTO, PING and PADDING frames; anything
/// else leaves it untouched. Returns whether it was rearranged.
pub(super) fn scramble(payload: &mut [u8], rng: &mut impl Rng) -> bool {
    let Ok(frames) = frame::Iter::new(Bytes::copy_from_slice(payload)) else {
        return false;
    };
    let mut fragments: Vec<Fragment> = Vec::new();
    let mut pings = 0usize;
    for frame in frames {
        match frame {
            Ok(Frame::Crypto(crypto)) => fragments.push(Fragment {
                offset: crypto.offset,
                data: crypto.data,
            }),
            Ok(Frame::Ping) => pings += 1,
            Ok(Frame::Padding) => {}
            _ => return false,
        }
    }
    if fragments.is_empty() {
        return false;
    }
    let total = payload.len();

    // Contiguous CRYPTO data first, so fragments can be cut anywhere along it.
    fragments.sort_by_key(|fragment| fragment.offset);
    let mut runs: Vec<Fragment> = Vec::new();
    for fragment in fragments {
        match runs.last_mut() {
            Some(last) if last.offset + last.data.len() as u64 == fragment.offset => {
                let mut joined = Vec::with_capacity(last.data.len() + fragment.data.len());
                joined.extend_from_slice(&last.data);
                joined.extend_from_slice(&fragment.data);
                last.data = Bytes::from(joined);
            }
            _ => runs.push(fragment),
        }
    }

    // Cut each run into pieces while the padding budget pays for the extra frame headers.
    let mut pieces: Vec<Fragment> = Vec::new();
    for run in runs {
        let mut rest = run;
        while rest.data.len() > 64 && rng.random_ratio(3, 4) {
            let cut = rng.random_range(32..rest.data.len() - 32);
            let head = Fragment {
                offset: rest.offset,
                data: rest.data.slice(..cut),
            };
            rest = Fragment {
                offset: rest.offset + cut as u64,
                data: rest.data.slice(cut..),
            };
            pieces.push(head);
        }
        pieces.push(rest);
    }
    // Merge back while it does not fit; the runs, and so the original frames, fit by construction.
    // Only adjacent contiguous pieces may merge: joining across a gap would place the later bytes
    // at the wrong CRYPTO offset and corrupt the stream.
    let mut used = pieces.iter().map(Fragment::size).sum::<usize>() + pings;
    while used > total && pieces.len() > 1 {
        pieces.sort_by_key(|piece| piece.offset);
        let Some(i) = (0..pieces.len() - 1)
            .find(|&i| pieces[i].offset + pieces[i].data.len() as u64 == pieces[i + 1].offset)
        else {
            // Every remaining piece is its own run; nothing contiguous is left to rejoin.
            return false;
        };
        let tail = pieces.remove(i + 1);
        let head = &mut pieces[i];
        let mut joined = Vec::with_capacity(head.data.len() + tail.data.len());
        joined.extend_from_slice(&head.data);
        joined.extend_from_slice(&tail.data);
        head.data = Bytes::from(joined);
        used = pieces.iter().map(Fragment::size).sum::<usize>() + pings;
    }
    if used > total {
        return false;
    }
    let mut budget = total - used;

    // A few PINGs when the padding allows, then the rest of the padding in random runs.
    let extra_pings = rng.random_range(0..=budget.min(3));
    budget -= extra_pings;
    let mut items: Vec<Item> = pieces.into_iter().map(Item::Crypto).collect();
    items.extend((0..pings + extra_pings).map(|_| Item::Ping));
    while budget > 0 {
        let run = if items.len() > 8 || rng.random_ratio(1, 3) {
            budget
        } else {
            rng.random_range(1..=budget)
        };
        items.push(Item::Padding(run));
        budget -= run;
    }
    items.shuffle(rng);

    let mut out = Vec::with_capacity(total);
    for item in items {
        match item {
            Item::Crypto(fragment) => frame::Crypto {
                offset: fragment.offset,
                data: fragment.data,
            }
            .encode(&mut out),
            Item::Ping => out.write(FrameType::PING),
            Item::Padding(run) => out.resize(out.len() + run, 0),
        }
    }
    debug_assert_eq!(out.len(), total);
    if out.len() != total {
        return false;
    }
    payload.copy_from_slice(&out);
    // Every byte is still a frame: decoding the result must succeed. `debug_assert!` still compiles
    // its condition in release, so gate the whole check to match `payload_is_frames`'s own cfg.
    #[cfg(debug_assertions)]
    debug_assert!(
        payload_is_frames(payload),
        "the scrambled payload is not all frames"
    );
    true
}

/// Whether every byte of `payload` decodes as a frame.
#[cfg(debug_assertions)]
fn payload_is_frames(payload: &[u8]) -> bool {
    match frame::Iter::new(Bytes::copy_from_slice(payload)) {
        Ok(frames) => frames.into_iter().all(|frame| frame.is_ok()),
        Err(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand_pcg::Pcg32;

    /// Scrambling keeps exactly the CRYPTO bytes, at the same offsets, so the stream still
    /// reassembles.
    #[test]
    fn scramble_preserves_the_crypto_stream() {
        let mut rng = Pcg32::new(0xdead_beef_dead_beef, 0xcafe_f00d_d15e_a5e5);
        // A payload of one CRYPTO frame (offset 0, 900 bytes) plus PADDING to 1180.
        let data: Vec<u8> = (0..900u32).map(|i| (i % 251) as u8).collect();
        let mut payload = Vec::new();
        frame::Crypto {
            offset: 0,
            data: Bytes::copy_from_slice(&data),
        }
        .encode(&mut payload);
        payload.resize(1180, 0);
        let original = payload.clone();

        for _ in 0..200 {
            let mut scrambled = original.clone();
            assert!(scramble(&mut scrambled, &mut rng));
            assert_eq!(scrambled.len(), original.len());
            // Reassemble the CRYPTO stream from the scrambled frames.
            let mut stream = vec![0u8; data.len()];
            let mut covered = vec![false; data.len()];
            for frame in frame::Iter::new(Bytes::copy_from_slice(&scrambled)).unwrap() {
                if let Frame::Crypto(crypto) = frame.unwrap() {
                    let start = crypto.offset as usize;
                    stream[start..start + crypto.data.len()].copy_from_slice(&crypto.data);
                    for byte in &mut covered[start..start + crypto.data.len()] {
                        *byte = true;
                    }
                }
            }
            assert!(covered.iter().all(|&c| c), "every CRYPTO byte is covered");
            assert_eq!(stream, data, "the CRYPTO bytes are unchanged");
        }
    }

    /// Two CRYPTO frames with a gap between them must keep their bytes at the right offsets even
    /// when a tight budget forces the merge-back path; a merge across the gap would corrupt them.
    #[test]
    fn scramble_preserves_two_non_contiguous_runs() {
        let mut rng = Pcg32::new(0x0123_4567_89ab_cdef, 0xfeed_face_cafe_beef);
        let mut expected = vec![None; 1000];
        let mut payload = Vec::new();
        for &start in &[0usize, 600] {
            let data: Vec<u8> = (start..start + 400).map(|i| (i % 251) as u8).collect();
            for (i, &b) in data.iter().enumerate() {
                expected[start + i] = Some(b);
            }
            frame::Crypto {
                offset: start as u64,
                data: Bytes::copy_from_slice(&data),
            }
            .encode(&mut payload);
        }
        // Barely more room than the two frames occupy, so cutting overflows and forces merge-back.
        payload.resize(payload.len() + 8, 0);
        let original = payload.clone();

        for _ in 0..400 {
            let mut scrambled = original.clone();
            // The two runs on their own fit, so merge-back can always rejoin enough to succeed;
            // a version that instead merges across the gap, or bails, would fail here.
            assert!(scramble(&mut scrambled, &mut rng));
            assert_eq!(scrambled.len(), original.len());
            for frame in frame::Iter::new(Bytes::copy_from_slice(&scrambled)).unwrap() {
                if let Frame::Crypto(crypto) = frame.unwrap() {
                    let start = crypto.offset as usize;
                    for (i, &b) in crypto.data.iter().enumerate() {
                        assert_eq!(
                            expected[start + i],
                            Some(b),
                            "CRYPTO byte at offset {} is wrong",
                            start + i
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn scramble_declines_non_initial_payloads() {
        let mut rng = Pcg32::new(1, 2);
        let mut ack_like = vec![0x02, 0x00, 0x00, 0x00];
        assert!(!scramble(&mut ack_like, &mut rng));
    }
}
