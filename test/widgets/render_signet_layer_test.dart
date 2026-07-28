import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/render_signet/render_signet_codec.dart';
import 'package:fluxdo/widgets/render_signet/render_signet_layer.dart';

/// 混合语义像素回读:在纯色底上跑一遍真实 painter(modulate+plus
/// 两笔),读回像素逐通道断言——只允许动 B 通道,且幅度不超过
/// kSignetModulateDrop。任何 R/G 变动或超幅都意味着"完全不可见"
/// 契约被破坏。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const size = 168; // 2 个块周期
  const id = 998244353;

  Future<ByteData> paintOnColor(Color bg) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      Paint()..color = bg,
    );
    final (mod, plus) = buildSignetTiles(id, 1.0);
    RenderSignetPainter(modTile: mod, plusTile: plus)
        .paint(canvas, Size(size.toDouble(), size.toDouble()));
    final picture = recorder.endRecording();
    final image = picture.toImageSync(size, size);
    picture.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    mod.dispose();
    plus.dispose();
    return data!;
  }

  for (final (label, bg, expectedDelta) in [
    // 白底:modulate 满效 -drop,plus 饱和熄火(255+δ clamp 回 255,
    // 但 modulate 先走,255*(255-2)/255=253,再 +1 → -1)
    ('白底', const Color(0xFFFFFFFF), -kSignetPlusDelta),
    // 黑底:modulate 无效,plus 满效 +δ
    ('黑底', const Color(0xFF000000), kSignetPlusDelta),
  ]) {
    test('$label:只动 B 通道且幅度=±$kSignetPlusDelta', () async {
      final px = await paintOnColor(bg);
      var dotCount = 0;
      var maxAbsDb = 0;
      for (var i = 0; i < size * size; i++) {
        final r = px.getUint8(i * 4);
        final g = px.getUint8(i * 4 + 1);
        final b = px.getUint8(i * 4 + 2);
        expect(r, (bg.r * 255).round(), reason: 'R 通道被污染 @$i');
        expect(g, (bg.g * 255).round(), reason: 'G 通道被污染 @$i');
        final db = b - (bg.b * 255).round();
        if (db != 0) {
          dotCount++;
          expect(db.sign, expectedDelta.sign, reason: '极性错误 @$i');
          if (db.abs() > maxAbsDb) maxAbsDb = db.abs();
        }
      }
      // 4 个块 x 49 格 x 5x6 点 = 5880 个点像素
      expect(dotCount, 4 * kSignetGridRows * kSignetGridCols * 30);
      expect(maxAbsDb, lessThanOrEqualTo(kSignetModulateDrop),
          reason: '扰动超幅,不可见性契约破坏');
    });
  }

  test('中灰底:扰动幅度不超过 drop 的一半', () async {
    final px = await paintOnColor(const Color(0xFF808080));
    for (var i = 0; i < size * size; i++) {
      expect((px.getUint8(i * 4 + 2) - 0x80).abs(),
          lessThanOrEqualTo(kSignetModulateDrop ~/ 2),
          reason: '中灰死区应近零扰动 @$i');
    }
  });
}
