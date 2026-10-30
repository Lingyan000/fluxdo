import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('展开工具岛保持20dp圆角，外层合成不替换抗锯齿覆盖率', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(800, 600);
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: boundaryKey,
          child: const ColoredBox(
            color: Color(0xFFFFF8EF),
            child: Center(
              child: GlassSurfaceFrame(
                radius: 20,
                child: SizedBox(width: 360, height: 132),
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      if (find.byType(BackdropFilter).evaluate().length == 2) break;
    }
    await tester.pumpAndSettle();
    final filters = tester
        .widgetList<BackdropFilter>(find.byType(BackdropFilter))
        .toList();
    expect(filters, hasLength(2), reason: '必须实际启用折射，不能用降级路径冒充');
    expect(
      filters.first.blendMode,
      BlendMode.srcOver,
      reason: '页面边界保留圆角抗锯齿覆盖率，避免四角衔接细线',
    );
    expect(
      filters.last.blendMode,
      BlendMode.src,
      reason: '局部纹理内仍替换主模糊结果，避免重复混合',
    );
    final clip = tester.widget<ClipRRect>(find.byType(ClipRRect).first);
    expect(clip.borderRadius, BorderRadius.circular(20));
    expect(
      clip.clipBehavior,
      Clip.antiAlias,
      reason: '不能改为antiAliasWithSaveLayer，否则会隔断背景输入',
    );

    await tester.runAsync(() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
      final rect = tester.getRect(find.byType(GlassSurfaceFrame));
      final x = (rect.left * 2).round();
      final y = (rect.top * 2).round();
      // 四角矩形顶点位于圆角之外，必须保持页面颜色，不能泄露矩形背景层。
      for (final offset in [
        const Offset(1, 1),
        const Offset(718, 1),
        const Offset(1, 262),
        const Offset(718, 262),
      ]) {
        final index =
            ((y + offset.dy.toInt()) * image.width + x + offset.dx.toInt()) * 4;
        expect(data[index], greaterThan(240));
        expect(data[index + 1], greaterThan(230));
        expect(data[index + 3], 255);
      }
      image.dispose();
    });
    expect(tester.takeException(), isNull);
  }, skip: !ui.ImageFilter.isShaderFilterSupported);
}
