import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/image_format.dart';

List<int> _u32(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

/// ftyp(主品牌 + 兼容品牌)+ 一个带 ispe 的 meta 片段。
List<int> _avif({
  String major = 'avif',
  List<String> compatible = const ['mif1', 'miaf'],
  (int, int)? size = (500, 300),
}) {
  final ftypPayload = [
    ...ascii.encode(major),
    ..._u32(0),
    for (final b in compatible) ...ascii.encode(b),
  ];
  return [
    ..._u32(ftypPayload.length + 8),
    ...ascii.encode('ftyp'),
    ...ftypPayload,
    ..._u32(64),
    ...ascii.encode('meta'),
    0, 0, 0, 0, //
    if (size != null) ...[
      ..._u32(20),
      ...ascii.encode('ispe'),
      0, 0, 0, 0, //
      ..._u32(size.$1),
      ..._u32(size.$2),
    ],
  ];
}

void main() {
  test('按文件头识别 AVIF,与后缀无关', () {
    expect(bytesLookLikeAvif(_avif()), isTrue);
    expect(bytesLookLikeAvif(_avif(major: 'avis')), isTrue);
    expect(
      bytesLookLikeAvif([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0, 0, 0, 0, 0]),
      isFalse,
    );
    expect(bytesLookLikeAvif(_avif(major: 'heic')), isFalse);
    expect(bytesLookLikeAvif([1, 2, 3]), isFalse);
  });

  test('动画品牌在主品牌或兼容品牌里都算', () {
    expect(avifLooksAnimated(_avif()), isFalse);
    expect(avifLooksAnimated(_avif(major: 'avis')), isTrue);
    expect(avifLooksAnimated(_avif(compatible: ['mif1', 'msf1'])), isTrue);
  });

  test('从 ispe 读出尺寸,没有 ispe 时返回 null', () {
    expect(avifIntrinsicSize(_avif(size: (2048, 1536))), (2048, 1536));
    expect(avifIntrinsicSize(_avif(size: null)), isNull);
    expect(avifIntrinsicSize([0x89, 0x50, 0x4E, 0x47]), isNull);
  });
}
