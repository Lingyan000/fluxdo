import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpGlass(
    WidgetTester tester, {
    double dpr = 1,
    Offset position = const Offset(100, 600),
    bool enabled = true,
    bool framed = true,
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: MediaQuery(
          // 刻意不修改 tester.view 的 DPR，防止误用进程首个视图。
          data: MediaQueryData(devicePixelRatio: dpr),
          child: Stack(
            children: [
              const Positioned.fill(child: ColoredBox(color: Colors.orange)),
              Positioned(
                left: position.dx,
                top: position.dy,
                width: 200,
                height: 48,
                child: framed
                    ? GlassSurfaceFrame(
                        radius: 24,
                        enabled: enabled,
                        child: const SizedBox.expand(),
                      )
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: GlassSurface(
                          recipe: GlassRecipe.navigation,
                          shape: const StadiumBorder(),
                          enabled: enabled,
                          child: const SizedBox.expand(),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  ShapeDecoration surfaceDecoration(WidgetTester tester) {
    final decoration = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(GlassSurface),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    return decoration.decoration as ShapeDecoration;
  }

  test('支持 Impeller 时保留光学材质能力', () {
    expect(
      GlassSurface.opticalEdgeAvailable,
      ui.ImageFilter.isShaderFilterSupported,
    );
  });

  testWidgets('不同位置与 DPR 均使用当前视图的稳定背景模糊', (tester) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final dpr in [1.0, 2.0, 3.0]) {
      for (final position in [
        Offset.zero,
        const Offset(100, 600),
        const Offset(500, 700),
      ]) {
        await pumpGlass(tester, dpr: dpr, position: position);
        expect(find.byType(BackdropFilter), findsOneWidget);
        final backdrop = tester.widget<BackdropFilter>(
          find.byType(BackdropFilter),
        );
        expect(
          backdrop.filter,
          ui.ImageFilter.blur(
            sigmaX: GlassRecipe.navigation.blurSigmaPx / dpr,
            sigmaY: GlassRecipe.navigation.blurSigmaPx / dpr,
            tileMode: ui.TileMode.clamp,
          ),
        );
        // 确认滤镜仍被胶囊的局部裁切包住，而不是作用于整页。
        final clip = find.ancestor(
          of: find.byType(BackdropFilter),
          matching: find.byType(ClipRRect),
        );
        expect(clip, findsOneWidget);
        expect(tester.getRect(clip), position & const Size(200, 48));
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('共用外壳只画一层方向性边缘光，色罩保持中性', (tester) async {
    for (final brightness in Brightness.values) {
      await pumpGlass(tester, brightness: brightness);
      final surface = tester.widget<GlassSurface>(find.byType(GlassSurface));
      expect(surface.drawFallbackBorder, isFalse);
      final decoration = surfaceDecoration(tester);
      expect((decoration.shape as OutlinedBorder).side, BorderSide.none);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint &&
              widget.painter is GlassEdgePainter,
        ),
        findsOneWidget,
      );
      final color = decoration.color!;
      final gray = GlassRecipe.navigation.tintGrayFor(
        brightness == Brightness.dark,
      );
      expect(color.r, closeTo(gray, 0.001));
      expect(color.g, closeTo(gray, 0.001));
      expect(color.b, closeTo(gray, 0.001));
      expect(color.a, closeTo(GlassRecipe.navigation.tintAlpha + 0.08, 0.001));
    }
  });

  testWidgets('独立玻璃保留默认细描边', (tester) async {
    await pumpGlass(tester, framed: false);
    expect(
      (surfaceDecoration(tester).shape as OutlinedBorder).side.width,
      GlassRecipe.navigation.fallbackEdgeWidth,
    );
  });

  testWidgets('关闭再开启模糊时仍走稳定路径', (tester) async {
    await pumpGlass(tester);
    expect(find.byType(BackdropFilter), findsOneWidget);

    await pumpGlass(tester, enabled: false);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(surfaceDecoration(tester).color!.a, 1);

    await pumpGlass(tester);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
