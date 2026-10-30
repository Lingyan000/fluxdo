import 'dart:ui' as ui;

import 'package:common_ui/src/glass_optical_border.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('光照按轮廓法线计算，迎光与背光具有明显差异', () {
    final lit = GlassOpticalBorder.illumination(const Offset(-.6, -.8));
    final away = GlassOpticalBorder.illumination(const Offset(.8, -.6));
    expect(lit, greaterThan(away * 4));
    expect(
      GlassOpticalBorder.illumination(const Offset(0, -1)),
      greaterThan(GlassOpticalBorder.illumination(const Offset(0, 1))),
    );
  });

  testWidgets('连续光学轮廓绘制在内部且包含真实像素', (tester) async {
    for (final size in [
      const Size(360, 132),
      const Size(200, 48),
      const Size(1, 1),
    ]) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      const painter = GlassOpticalBorder(
        radius: 20,
        isDark: false,
        strength: 1,
      );
      painter.paint(canvas, size);
      final picture = recorder.endRecording();
      await tester.runAsync(() async {
        final image = await picture.toImage(
          size.width.toInt(),
          size.height.toInt(),
        );
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        if (size.width > 1) {
          final width = size.width.toInt();
          final center = ((size.height ~/ 2) * width + width ~/ 2) * 4;
          expect(data[center + 3], 0, reason: '光学边缘不能覆盖面内');
          var maxAlpha = 0;
          for (var i = 3; i < data.length; i += 4) {
            if (data[i] > maxAlpha) maxAlpha = data[i];
          }
          expect(maxAlpha, greaterThan(30), reason: '轮廓必须实际可见');
        }
        image.dispose();
      });
      picture.dispose();
    }
    expect(tester.takeException(), isNull);
  });
}
