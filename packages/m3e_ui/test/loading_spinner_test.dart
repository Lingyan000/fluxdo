import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_ui/m3e_ui.dart';

void main() {
  testWidgets('标准分页加载完整周期保留留白且图形大于紧凑尺寸', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Center(child: LoadingSpinner.standard())),
    );
    expect(tester.getSize(find.byType(LoadingSpinner)), const Size(48, 48));
    final paintFinder = find.descendant(
      of: find.byType(LoadingSpinner),
      matching: find.byType(CustomPaint),
    );
    // 在更大的透明画布上绘制，检查旋转和弹簧过冲时是否越出容器。
    var largestWidth = 0;
    for (var frame = 0; frame < 50; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
      final painter = tester.widget<CustomPaint>(paintFinder).painter!;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..translate(24, 24);
      painter.paint(canvas, const Size(48, 48));
      final picture = recorder.endRecording();
      final image = picture.toImageSync(96, 96);
      final bytes = await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      var minX = 96;
      var maxX = -1;
      for (var y = 0; y < 96; y++) {
        for (var x = 0; x < 96; x++) {
          if (bytes!.getUint8((y * 96 + x) * 4 + 3) < 16) continue;
          expect(x, inInclusiveRange(25, 70));
          expect(y, inInclusiveRange(25, 70));
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
        }
      }
      final width = maxX - minX + 1;
      expect(width, greaterThan(0));
      if (width > largestWidth) largestWidth = width;
      image.dispose();
      picture.dispose();
    }
    expect(largestWidth, greaterThan(24));
    expect(tester.takeException(), isNull);
  });

  testWidgets('LoadingSpinner 完整 morph 周期内正常绘制', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: LoadingSpinner())),
      ),
    );

    // 覆盖多个 650ms morph 周期(含形状指针步进与闭环回绕),
    // 验证 7 段 Morph 的构造与路径生成都不抛错。
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);

    // 自定义尺寸与颜色。
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: LoadingSpinner(size: 16, color: Colors.white)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('确定态随进度绘制且不驱动帧，可与不定态互相切换', (tester) async {
    Future<void> pumpSpinner(double? progress, {bool expressive = true}) =>
        tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(extensions: [M3eFlags(enabled: expressive)]),
            home: Scaffold(
              body: Center(child: LoadingSpinner(progress: progress)),
            ),
          ),
        );

    for (final progress in [0.0, 0.3, 0.5, 1.0, 1.6]) {
      await pumpSpinner(progress);
      expect(tester.hasRunningAnimations, isFalse);
    }
    await pumpSpinner(null);
    expect(tester.hasRunningAnimations, isTrue);
    await pumpSpinner(0.4);
    expect(tester.hasRunningAnimations, isFalse);

    // M3E 关闭时回退为经典确定态进度环。
    await pumpSpinner(0.4, expressive: false);
    // 主题切换有插值动画，等开关生效。
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator),
          )
          .value,
      0.4,
    );
    expect(tester.takeException(), isNull);
  });
}
