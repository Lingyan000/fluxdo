// Copyright (c) 2021 The Chromium Authors. All rights reserved.
// 算法改编自 QUICHE；BSD 许可条款见本 crate 的 QUICHE-LICENSE。
//! Initial 包内分片：随机细分 CRYPTO，分配 PING 与填充，再重排帧。
//! 算法依据及验证范围见 docs/diagnostics/h3-initial-layout-20261115.txt。

use rama_core::bytes::Bytes;
use rama_quic_proto::{
    VarInt,
    coding::BufMutExt,
    frame::{self, Frame, FrameType},
};
use rand::{Rng, RngExt};

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
pub(in crate::proto::connection) fn scramble(
    payload: &mut [u8],
    rng: &mut impl Rng,
    interleaved: bool,
) -> bool {
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
    if fragments.is_empty() || (!interleaved && (fragments.len() != 1 || pings != 0)) {
        return false;
    }
    let total = payload.len();

    // 保留输入 CRYPTO 的边界和空洞；每次随机选择一个已有片段，可切到 1 字节。
    let used = fragments.iter().map(Fragment::size).sum::<usize>() + pings;
    if used > total {
        return false;
    }
    let mut budget = total - used;
    let end = fragments
        .iter()
        .map(|f| f.offset + f.data.len() as u64)
        .max()
        .unwrap();
    let start = fragments.iter().map(|f| f.offset).min().unwrap();
    let max_overhead =
        1 + VarInt::from_u64(end).unwrap().size() + VarInt::from_u64(end - start).unwrap().size();
    // 有跨包交错证据时使用该布局对应的新版范围；旧单包布局允许零次细分。
    let attempts = if interleaved {
        2 + rng.random::<u64>() % 9
    } else {
        rng.random::<u64>() % 11
    };
    for _ in 0..attempts {
        if budget < max_overhead {
            break;
        }
        // 原有 PING 同样占据候选位置；选到它时跳过本次细分。
        let index = (rng.random::<u64>() % (fragments.len() + pings) as u64) as usize;
        if index >= fragments.len() || fragments[index].data.len() <= 1 {
            continue;
        }
        let old = &fragments[index];
        let cut = 1 + (rng.random::<u64>() % (old.data.len() - 1) as u64) as usize;
        let head = Fragment {
            offset: old.offset,
            data: old.data.slice(..cut),
        };
        let tail = Fragment {
            offset: old.offset + cut as u64,
            data: old.data.slice(cut..),
        };
        let extra = head.size() + tail.size() - old.size();
        debug_assert!(extra <= budget);
        budget -= extra;
        fragments[index] = head;
        fragments.push(tail);
    }
    let extra_pings = if budget == 0 {
        0
    } else {
        if interleaved {
            (2 + (rng.random::<u64>() % 9) as usize).min(budget)
        } else {
            (rng.random::<u64>() % budget.min(10) as u64) as usize
        }
    };
    budget -= extra_pings;
    let mut items: Vec<Item> = fragments.into_iter().map(Item::Crypto).collect();
    items.extend((0..pings + extra_pings).map(|_| Item::Ping));
    let mut padded = Vec::with_capacity(items.len() * 2 + 1);
    for item in items {
        let run = (rng.random::<u64>() % (budget + 1) as u64) as usize;
        if run > 0 {
            padded.push(Item::Padding(run));
            budget -= run;
        }
        padded.push(item);
    }
    if budget > 0 {
        padded.push(Item::Padding(budget));
    }
    let mut items = padded;
    for index in (1..items.len()).rev() {
        let earlier = (rng.random::<u64>() % (index + 1) as u64) as usize;
        items.swap(index, earlier);
    }

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
            assert!(scramble(&mut scrambled, &mut rng, true));
            assert_eq!(scrambled.len(), original.len());
            // Reassemble the CRYPTO stream from the scrambled frames.
            let mut stream = vec![0u8; data.len()];
            let mut covered = vec![false; data.len()];
            for frame in frame::Iter::new(Bytes::copy_from_slice(&scrambled)).unwrap() {
                if let Frame::Crypto(crypto) = frame.unwrap() {
                    let start = crypto.offset as usize;
                    stream[start..start + crypto.data.len()].copy_from_slice(&crypto.data);
                    for byte in &mut covered[start..start + crypto.data.len()] {
                        assert!(!*byte, "CRYPTO 字节不能重复覆盖");
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
            assert!(scramble(&mut scrambled, &mut rng, true));
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
    fn scramble_reaches_tiny_fragments_and_more_than_three_pings() {
        let mut rng = Pcg32::new(91, 7);
        let mut tiny = false;
        let mut many_pings = false;
        for _ in 0..256 {
            let mut payload = Vec::new();
            frame::Crypto {
                offset: 0,
                data: Bytes::from(vec![1; 900]),
            }
            .encode(&mut payload);
            payload.resize(1216, 0);
            assert!(scramble(&mut payload, &mut rng, true));
            let mut pings = 0;
            for frame in frame::Iter::new(Bytes::from(payload)).unwrap() {
                match frame.unwrap() {
                    Frame::Crypto(c) => tiny |= c.data.len() < 4,
                    Frame::Ping => pings += 1,
                    _ => {}
                }
            }
            assert!((2..=10).contains(&pings));
            many_pings |= pings > 3;
        }
        assert!(tiny && many_pings);
    }

    #[test]
    fn single_packet_range_includes_zero_pings_and_zero_splits() {
        let mut rng = Pcg32::new(97, 19);
        let mut zero_pings = false;
        let mut zero_splits = false;
        for _ in 0..256 {
            let mut payload = Vec::new();
            frame::Crypto {
                offset: 0,
                data: Bytes::from(vec![1; 300]),
            }
            .encode(&mut payload);
            payload.resize(1216, 0);
            assert!(scramble(&mut payload, &mut rng, false));
            let mut pings = 0;
            let mut crypto = 0;
            for frame in frame::Iter::new(Bytes::from(payload)).unwrap() {
                match frame.unwrap() {
                    Frame::Crypto(_) => crypto += 1,
                    Frame::Ping => pings += 1,
                    _ => {}
                }
            }
            assert!(pings < 10 && (1..=11).contains(&crypto));
            zero_pings |= pings == 0;
            zero_splits |= crypto == 1;
        }
        assert!(zero_pings && zero_splits);
    }

    #[test]
    fn scramble_declines_non_initial_payloads() {
        let mut rng = Pcg32::new(1, 2);
        let mut ack_like = vec![0x02, 0x00, 0x00, 0x00];
        assert!(!scramble(&mut ack_like, &mut rng, true));
    }
}
