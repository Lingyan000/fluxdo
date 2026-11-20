import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/avif_sequence_still.dart';

/// 按 ISOBMFF 拼一个结构上合法的 AVIF(内容不可解码,只测解析与改写)。
class AvifFixture {
  AvifFixture({
    this.majorBrand = 'avis',
    this.compatibleBrands = const ['avif', 'mif1', 'msf1', 'miaf'],
    this.withMoov = true,
    this.moovAfterMdat = false,
    this.dataReferenceIndex = 0,
    this.items = const [(100, 200), (8, 50)],
    this.mdatPayload = 1000,
  });

  final String majorBrand;
  final List<String> compatibleBrands;
  final bool withMoov;
  final bool moovAfterMdat;
  final int dataReferenceIndex;

  /// 主图与辅助项在 mdat 负载内的 (偏移, 长度)。
  final List<(int, int)> items;
  final int mdatPayload;

  late int mdatOffset;

  Uint8List build() {
    final ftyp = _box('ftyp', [
      ...ascii.encode(majorBrand),
      ..._u32(0),
      for (final b in compatibleBrands) ...ascii.encode(b),
    ]);
    final moov = _box('moov', List.filled(20, 0));
    // iloc 里的绝对偏移依赖 mdat 位置,先用占位算出 meta 长度
    final metaLength = _meta(0).length;
    mdatOffset =
        ftyp.length +
        metaLength +
        (withMoov && !moovAfterMdat ? moov.length : 0);
    final meta = _meta(mdatOffset + 8);
    final mdat = _box('mdat', List.generate(mdatPayload, (i) => i & 0xFF));
    return Uint8List.fromList([
      ...ftyp,
      ...meta,
      if (withMoov && !moovAfterMdat) ...moov,
      ...mdat,
      if (withMoov && moovAfterMdat) ...moov,
    ]);
  }

  List<int> _meta(int mdatDataStart) {
    final iloc = <int>[
      0, 0, 0, 0, // version 0 + flags
      0x44, 0x00, // offset_size 4, length_size 4, base_offset_size 0
      ..._u16(items.length),
      for (var i = 0; i < items.length; i++) ...[
        ..._u16(i + 1),
        ..._u16(dataReferenceIndex),
        ..._u16(1), // extent_count
        ..._u32(mdatDataStart + items[i].$1),
        ..._u32(items[i].$2),
      ],
    ];
    return _box('meta', [
      0, 0, 0, 0, // FullBox
      ..._box('hdlr', List.filled(25, 0)),
      ..._box('pitm', [0, 0, 0, 0, ..._u16(1)]),
      ..._box('iloc', iloc),
    ]);
  }

  static List<int> _box(String type, List<int> payload) => [
    ..._u32(payload.length + 8),
    ...ascii.encode(type),
    ...payload,
  ];

  static List<int> _u16(int v) => [(v >> 8) & 0xFF, v & 0xFF];
  static List<int> _u32(int v) => [
    (v >> 24) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 8) & 0xFF,
    v & 0xFF,
  ];
}

String _ascii(Uint8List bytes, int offset) =>
    ascii.decode(bytes.sublist(offset, offset + 4));

int _boxOffset(Uint8List bytes, String type) {
  final data = ByteData.sublistView(bytes);
  var off = 0;
  while (off + 8 <= bytes.length) {
    if (_ascii(bytes, off + 4) == type) return off;
    off += data.getUint32(off);
  }
  return -1;
}

void main() {
  test('动画 AVIF 只需下载到主图项结束', () {
    final fixture = AvifFixture();
    final bytes = fixture.build();

    // 两个项的最远结束位置 = mdat 负载起点 + 100 + 200
    expect(
      AvifSequenceStill.requiredLength(bytes),
      fixture.mdatOffset + 8 + 300,
    );
  });

  test('改写为静态 AVIF:品牌、moov、mdat 尺寸', () {
    final fixture = AvifFixture();
    final bytes = fixture.build();
    final end = AvifSequenceStill.requiredLength(bytes)!;

    final still = AvifSequenceStill.toStill(bytes.sublist(0, end))!;

    expect(still.length, end);
    expect(_ascii(still, 8), 'avif');
    expect(
      [for (var o = 16; o < 32; o += 4) _ascii(still, o)],
      ['avif', 'mif1', 'mif1', 'miaf'],
    );
    expect(_boxOffset(still, 'moov'), -1);
    expect(_boxOffset(still, 'free'), isNot(-1));
    final mdat = _boxOffset(still, 'mdat');
    expect(ByteData.sublistView(still).getUint32(mdat), end - mdat);
    // 项数据原样保留,iloc 偏移无需改动
    expect(still.sublist(mdat + 8), bytes.sublist(mdat + 8, end));
  });

  test('前缀不足所需长度时不改写', () {
    final bytes = AvifFixture().build();
    final end = AvifSequenceStill.requiredLength(bytes)!;

    expect(AvifSequenceStill.toStill(bytes.sublist(0, end - 1)), isNull);
  });

  test('静态 AVIF 不当作动画处理', () {
    final bytes = AvifFixture(
      majorBrand: 'avif',
      compatibleBrands: ['avif', 'mif1', 'miaf'],
      withMoov: false,
    ).build();

    expect(AvifSequenceStill.requiredLength(bytes), isNull);
  });

  test('moov 在 mdat 之后时放弃(首帧索引不在前缀里)', () {
    final bytes = AvifFixture(moovAfterMdat: true).build();

    expect(AvifSequenceStill.requiredLength(bytes), isNull);
  });

  test('项引用外部数据时放弃', () {
    final bytes = AvifFixture(dataReferenceIndex: 1).build();

    expect(AvifSequenceStill.requiredLength(bytes), isNull);
  });

  test('前缀没覆盖完整 meta 时放弃', () {
    final bytes = AvifFixture().build();

    expect(AvifSequenceStill.requiredLength(bytes.sublist(0, 60)), isNull);
  });

  test('非 ISOBMFF 数据返回 null', () {
    expect(
      AvifSequenceStill.requiredLength(Uint8List.fromList(List.filled(64, 7))),
      isNull,
    );
  });
}
