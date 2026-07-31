import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/render_signet/render_signet_codec.dart';
import 'package:fluxdo/widgets/render_signet/render_signet_layer.dart';

/// 混合语义像素回读:在纯色底上跑一遍真实 painter(消饱和 srcATop +
/// 信号 plus 两笔),读回像素逐通道断言不可见性契约:
/// - R/G 只允许全局均匀缩放((255-δ)/255,无空间对比即不可见),
///   禁止出现任何空间图案;
/// - B 通道点位相对底色的差分恒为 +δ,且非点位无扰动;
/// - 消饱和笔的失败形态(退化 srcOver)在不透明底上与正常输出
///   逐字节相同——结构安全性的直接证明。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const size = 168; // 2 个块周期
  const id = 998244353;
  // 4 个块 x 49 格 x 5x6 点 = 5880 个点像素
  const expectedDots = 4 * kSignetGridRows * kSignetGridCols * 30;

  Future<ByteData> paintOnColor(Color bg) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      Paint()..color = bg,
    );
    final tile = buildSignetSignalTile(id, 1.0);
    RenderSignetPainter(tile: tile)
        .paint(canvas, Size(size.toDouble(), size.toDouble()));
    final picture = recorder.endRecording();
    final image = picture.toImageSync(size, size);
    picture.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    tile.dispose();
    return data!;
  }

  ({Set<int> r, Set<int> g, Map<int, int> b}) channelStats(ByteData px) {
    final r = <int>{};
    final g = <int>{};
    final b = <int, int>{};
    for (var i = 0; i < size * size; i++) {
      r.add(px.getUint8(i * 4));
      g.add(px.getUint8(i * 4 + 1));
      final bv = px.getUint8(i * 4 + 2);
      b[bv] = (b[bv] ?? 0) + 1;
    }
    return (r: r, g: g, b: b);
  }

  for (final (label, bg) in [
    ('白底', const Color(0xFFFFFFFF)),
    ('黑底', const Color(0xFF000000)),
    ('中灰底(旧方案死区)', const Color(0xFF808080)),
  ]) {
    test('$label:R/G 无空间图案,B 点位差分恒 +$kSignetPlusDelta', () async {
      final px = await paintOnColor(bg);
      final stats = channelStats(px);
      // R/G:全屏单一取值(均匀缩放),任何第二取值都意味着空间图案
      expect(stats.r.length, 1, reason: 'R 通道出现空间图案: ${stats.r}');
      expect(stats.g.length, 1, reason: 'G 通道出现空间图案: ${stats.g}');
      // 消饱和幅度契约:恰为 (255-δ)/255 缩放(四舍五入)
      final bgC = (bg.r * 255).round();
      final expectScaled = (bgC * (255 - kSignetPlusDelta) / 255).round();
      expect(stats.r.single, expectScaled, reason: 'R 消饱和幅度不符');
      // B:恰好两档,高档 = 低档+δ 且计数 = 点像素数
      expect(stats.b.length, 2, reason: 'B 通道取值异常: ${stats.b.keys}');
      final values = stats.b.keys.toList()..sort();
      expect(values[1] - values[0], kSignetPlusDelta, reason: 'B 差分幅度不符');
      expect(stats.b[values[1]], expectedDots, reason: '点像素数不符');
    });
  }

  test('消饱和笔失败形态(srcOver 退化)与正常输出逐字节相同', () async {
    // 不透明底上 srcATop 与 srcOver 数学同式:
    //   srcATop: 0·da + d(1-α), da=1;srcOver: 0 + d(1-α)
    //   α 通道:srcATop 保持 da=1;srcOver δ/255+254/255=1,同为 1
    // 该测试即"白屏类坏帧在本方案中不存在"的可执行证明。
    Future<ByteData> paintDesat(BlendMode mode) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      for (var x = 0; x < 256; x++) {
        canvas.drawRect(
          Rect.fromLTWH(x.toDouble(), 0, 1, 32),
          Paint()..color = Color.fromARGB(255, x, 255 - x, (x * 7) % 256),
        );
      }
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 256, 32),
        Paint()
          ..color = const Color.fromARGB(kSignetPlusDelta, 0, 0, 0)
          ..blendMode = mode,
      );
      final picture = recorder.endRecording();
      final image = picture.toImageSync(256, 32);
      picture.dispose();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!;
    }

    final normal = await paintDesat(BlendMode.srcATop);
    final degraded = await paintDesat(BlendMode.srcOver);
    for (var i = 0; i < 256 * 32 * 4; i++) {
      expect(normal.getUint8(i), degraded.getUint8(i),
          reason: '字节 $i 不一致——失败形态不再等价,结构安全性破坏');
    }
  });
}
