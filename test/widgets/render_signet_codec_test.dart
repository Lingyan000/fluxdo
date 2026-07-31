import 'package:fluxdo/widgets/render_signet/render_signet_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('标识印记编解码', () {
    test('编码长度与同步行', () {
      final bits = encodeSignetBits(12345);
      expect(bits.length, kSignetGridRows * kSignetGridCols);
      expect(bits.sublist(0, kSignetSyncRow.length), kSignetSyncRow);
    });

    test('往返:典型/边界标识值', () {
      for (final id in [0, 1, 12345, 998244353, 0xFFFFFFFF]) {
        expect(decodeSignetBits(encodeSignetBits(id)), id);
      }
    });

    test('单比特翻转被 CRC 拒绝', () {
      final bits = encodeSignetBits(67890);
      // 翻转 payload 区每一位,解码都必须失败(同步行翻转由同步校验拒绝)
      for (var i = 0; i < bits.length; i++) {
        final corrupted = [...bits];
        corrupted[i] = !corrupted[i];
        final decoded = decodeSignetBits(corrupted);
        // 备用位不参与校验,翻转它们仍解出原标识值
        final isSpare =
            i >= kSignetGridRows * kSignetGridCols - kSignetSpareBits.length;
        expect(decoded, isSpare ? 67890 : null, reason: 'bit $i');
      }
    });

    test('长度不符返回 null', () {
      expect(decodeSignetBits([true, false]), null);
    });
  });
}
