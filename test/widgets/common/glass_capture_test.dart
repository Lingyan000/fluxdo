import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final boundary = GlobalKey();

  /// 红底上放一块玻璃；[opacity] 小于 1 时玻璃在淡入淡出中
  Future<void> pumpScene(
    WidgetTester tester, {
    GlassEffectLevel level = GlassEffectLevel.full,
    double opacity = 1,
    Color background = const Color(0xFFE53935),
    bool host = true,
  }) async {
    Widget scene = Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: background)),
        Positioned(
          left: 40,
          top: 100,
          width: 200,
          height: 48,
          child: Opacity(
            opacity: opacity,
            child: const GlassSurfaceFrame(
              radius: 24,
              child: SizedBox.expand(),
            ),
          ),
        ),
      ],
    );
    if (host) scene = GlassCaptureHost(enabled: true, child: scene);
    await tester.pumpWidget(
      MaterialApp(
        home: GlassSettingsScope(
          settings: GlassSettings(level: level),
          child: RepaintBoundary(key: boundary, child: scene),
        ),
      ),
    );
    // 折射 shader 是真实异步加载，等它就绪再看最终路径
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      final optical = find.byWidgetPredicate(
        (widget) => widget is GlassBackdrop && widget.program != null,
      );
      if (level == GlassEffectLevel.basic || optical.evaluate().isNotEmpty) {
        break;
      }
    }
  }

  Future<Color> glassCenter(WidgetTester tester) async {
    late Color color;
    await tester.runAsync(() async {
      final image =
          await (boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      // 玻璃中心（避开圆角与边缘光）
      final p = (124 * image.width + 140) * 4;
      color = Color.fromARGB(
        data.getUint8(p + 3),
        data.getUint8(p),
        data.getUint8(p + 1),
        data.getUint8(p + 2),
      );
      image.dispose();
    });
    return color;
  }

  for (final level in [GlassEffectLevel.basic, GlassEffectLevel.full]) {
    testWidgets('${level.name} 档：玻璃从宿主的截取里取到背后的内容', (tester) async {
      await pumpScene(tester, level: level);
      final color = await glassCenter(tester);
      // 浅色色罩叠在红色背景上：仍明显偏红，而不是取到空白
      expect(color.r, greaterThan(color.g + 0.1));
      expect(color.r, greaterThan(color.b + 0.1));
      expect(GlassCaptureHost.debugLastCapture?.panes, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('画面不变时沿用上一张截取，背景变化才重新截取', (tester) async {
    await pumpScene(tester);
    await tester.pump();
    expect(GlassCaptureHost.debugLastCapture?.snapshots, 0);

    await pumpScene(tester, background: const Color(0xFF1E88E5));
    expect(GlassCaptureHost.debugLastCapture?.snapshots, 1);
    final color = await glassCenter(tester);
    expect(color.b, greaterThan(color.r + 0.1));
  });

  testWidgets('淡入淡出中的玻璃仍读页面，随透明度一起淡化', (tester) async {
    await pumpScene(tester, opacity: 0.5);
    final color = await glassCenter(tester);
    expect(color.r, greaterThan(color.g + 0.1));
    expect(GlassCaptureHost.debugLastCapture?.panes, 1);
  });

  testWidgets('宿主之外的玻璃退回背景模糊，不报错', (tester) async {
    await pumpScene(tester, host: false);
    final color = await glassCenter(tester);
    expect(color.r, greaterThan(color.g + 0.1));
    expect(tester.takeException(), isNull);
  });
}
