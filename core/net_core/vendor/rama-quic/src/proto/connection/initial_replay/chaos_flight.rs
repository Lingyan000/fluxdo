// Copyright (c) 2021 The Chromium Authors. All rights reserved.
// 算法改编自 QUICHE；BSD 许可条款见本 crate 的 QUICHE-LICENSE。
//! 使用本次握手的长度规划跨包布局，再交给已有的发送与丢包恢复队列。
use super::*;
use rama_quic_proto::{VarInt, Version, profile::PaddingPlacement};
use rand::RngExt;

impl Connection {
    pub(super) fn prepare_generated_initial(&mut self) -> Option<RecordedInitialFlight> {
        let chaos = matches!(
            self.config.wire.packetization.layout(),
            InitialFlightLayout::Chaos
        ) && self.config.initial_cross_packet_chaos;
        let chunk = self.config.initial_crypto_chunk_size;
        let ordered = matches!(
            self.config.wire.packetization.layout(),
            InitialFlightLayout::Ordered
        ) && chunk.is_some();
        if !self.side.is_client()
            || !(chaos || ordered)
            || self.config.wire.packetization.padding() != PaddingPlacement::Frames
        {
            return None;
        }
        let ConnectionSide::Client { token, .. } = &self.side else {
            return None;
        };
        if !token.is_empty() {
            return None;
        }
        let space = &self.spaces[SpaceId::Initial];
        let tag = space.crypto.as_ref()?.local.packet.tag_len();
        let len = usize::try_from(space.crypto_offset).ok()?;
        if len == 0 || len > 65_536 {
            return None;
        }
        let size = self.path.current_mtu();
        let first = self.config.wire.packetization.first_packet_number();
        let mut geometry = Vec::new();
        for index in 0..16 {
            let width = self
                .config
                .initial_packet_number_lengths
                .get(index)
                .or_else(|| self.config.initial_packet_number_lengths.last())
                .copied()
                .unwrap_or(self.config.wire.packetization.min_packet_number_len());
            let number = PacketNumber::new_at_least(first.checked_add(index as u64)?, 0, width)?;
            let mut header = Vec::new();
            Header::Initial(InitialHeader {
                src_cid: self.handshake_cid,
                dst_cid: self.rem_cids.active(),
                token: Bytes::new(),
                number,
                version: self.wire_version,
            })
            .encode_with_max_packet_len(&mut header, usize::from(size));
            geometry.push((
                number.len() as u8,
                usize::from(size).checked_sub(header.len() + tag)?,
            ));
        }
        let mut packets = Vec::new();
        let (mut shapes, mut offset, middle_end) = if chaos {
            let first_ranges = partition(len, geometry[0].1, &mut self.rng)?;
            let offset = first_ranges[0][0].1;
            let end = first_ranges[0][1].0;
            (first_ranges, offset, end)
        } else {
            (Vec::new(), 0, len)
        };
        // 交错布局写中段，有序布局按实测分片上限写完整握手。
        while offset < middle_end {
            let capacity = geometry.get(shapes.len())?.1;
            let mut count = (middle_end - offset).min(capacity);
            if ordered {
                count = count.min(usize::from(chunk?));
            }
            while count > 0 && crypto_size(offset, count) > capacity {
                count -= 1;
            }
            if count == 0 {
                return None;
            }
            shapes.push(vec![(offset, count)]);
            offset += count;
        }
        for (index, ranges) in shapes.into_iter().enumerate() {
            let (width, capacity) = geometry[index];
            // 此处只生成形状，填充数据不进入 TLS 或发送队列。
            let mut payload = Vec::new();
            for (offset, len) in ranges {
                frame::Crypto {
                    offset: offset as u64,
                    data: Bytes::from(vec![0; len]),
                }
                .encode(&mut payload);
            }
            if payload.len() > capacity {
                return None;
            }
            payload.resize(capacity, 0);
            if chaos
                && !super::super::packet_builder::chaos::scramble(&mut payload, &mut self.rng, true)
            {
                return None;
            }
            let mut frames = Vec::new();
            for frame in frame::Iter::new(Bytes::from(payload)).ok()? {
                match frame.ok()? {
                    frame::Frame::Crypto(c) => frames.push(InitialFrame::Crypto {
                        offset: c.offset,
                        len: c.data.len(),
                    }),
                    frame::Frame::Ping => frames.push(InitialFrame::Ping),
                    frame::Frame::Padding => match frames.last_mut() {
                        Some(InitialFrame::Padding { len }) => *len += 1,
                        _ => frames.push(InitialFrame::Padding { len: 1 }),
                    },
                    _ => return None,
                }
            }
            packets
                .push(InitialPacket::try_new(first + index as u64, width, size, 0, frames).ok()?);
        }
        RecordedInitialFlight::try_new(
            Version::from(self.wire_version),
            self.rem_cids.active().len() as u8,
            self.handshake_cid.len() as u8,
            packets,
        )
        .ok()
    }
}

fn crypto_size(offset: usize, len: usize) -> usize {
    1 + VarInt::from_u32(offset as u32).size() + VarInt::from_u32(len as u32).size() + len
}

/// 上游跨包算法的首包配额；短握手仍由普通的单包路径处理。
fn partition(
    len: usize,
    capacity: usize,
    rng: &mut impl rand::Rng,
) -> Option<Vec<Vec<(usize, usize)>>> {
    let overhead = crypto_size(len.checked_sub(1)?, len) - len;
    let first_capacity = capacity.checked_sub(2 * overhead)?;
    if len <= first_capacity {
        return None;
    }
    let other_capacity = capacity.checked_sub(overhead)?;
    let packets = (len + overhead).div_ceil(other_capacity);
    let first_data = (len + overhead).div_ceil(packets).checked_sub(overhead)?;
    let prefix = 55 + (rng.random::<u64>() % 32) as usize;
    if first_data <= prefix || len <= prefix {
        return None;
    }
    let suffix = first_data - prefix;
    Some(vec![vec![(0, prefix), (len - suffix, suffix)]])
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand_pcg::Pcg32;

    #[test]
    fn partition_adapts_to_current_handshake_and_keeps_middle_out_of_first_packet() {
        let mut rng = Pcg32::new(37, 11);
        for len in [1212, 1945, 1947, 4096, 16384] {
            let ranges = partition(len, 1216, &mut rng).unwrap();
            let [(start, prefix), (tail, suffix)] = ranges[0][..] else {
                panic!()
            };
            assert_eq!(start, 0);
            assert!((55..87).contains(&prefix));
            assert!(tail > prefix);
            assert_eq!(tail + suffix, len);
            assert!(crypto_size(start, prefix) + crypto_size(tail, suffix) <= 1216);
        }
        assert!(partition(900, 1216, &mut rng).is_none());
    }
}
