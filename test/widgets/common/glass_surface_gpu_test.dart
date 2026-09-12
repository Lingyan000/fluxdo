import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

// 运行：flutter test --enable-impeller test/widgets/common/glass_surface_gpu_test.dart
// 普通 Skia 测试跳过；必须确认启用 Impeller 后所有像素断言实际执行。
void main() {
  const size = Size(200, 48);
  const surfaceKey = ValueKey('被测玻璃');
  final captureKey = GlobalKey();

  Future<Uint8List> capture(
    WidgetTester tester, {
    required Offset position,
    required double dpr,
    bool nested = false,
    bool optical = true,
    double scale = 1,
    GlassRecipe recipe = GlassRecipe.navigation,
  }) async {
    tester.view.devicePixelRatio = dpr;
    tester.view.physicalSize = const Size(700, 600) * dpr;
    final glass = optical
        ? GlassSurfaceFrame(
            key: surfaceKey,
            radius: 24,
            recipe: recipe,
            child: const SizedBox(width: 200, height: 48),
          )
        : ClipRRect(
            key: surfaceKey,
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(
                sigmaX: GlassRecipe.navigation.blurSigmaPx / dpr,
                sigmaY: GlassRecipe.navigation.blurSigmaPx / dpr,
                tileMode: ui.TileMode.clamp,
              ),
              child: ColoredBox(
                color: const Color(
                  0xFFFCFCFC,
                ).withValues(alpha: GlassRecipe.navigation.tintAlpha),
                child: const SizedBox(width: 200, height: 48),
              ),
            ),
          );
    Widget scene = SizedBox(
      width: 500,
      height: 400,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _BackdropPattern(position: position, scale: scale),
            ),
          ),
          Positioned(
            left: position.dx,
            top: position.dy,
            child: Transform.scale(
              alignment: Alignment.topLeft,
              scale: scale,
              child: glass,
            ),
          ),
        ],
      ),
    );
    if (nested) {
      scene = Opacity(opacity: .9, child: scene);
    }
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: captureKey,
          child: Stack(
            children: [
              const Positioned.fill(child: ColoredBox(color: Colors.white)),
              Positioned(
                left: nested ? 31 : 0,
                top: nested ? 43 : 0,
                child: scene,
              ),
            ],
          ),
        ),
      ),
    );
    // 有限轮询实际路径，避免固定睡眠掩盖资源未就绪或静默降级。
    for (var attempt = 0; attempt < 50; attempt++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      if (!optical || find.byType(BackdropFilter).evaluate().length == 2) break;
    }
    await tester.pumpAndSettle();
    if (optical) {
      expect(
        find.byType(BackdropFilter),
        findsNWidgets(2),
        reason: '必须实际执行局部背景层与折射层，不能降级冒充通过',
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is GlassEdgePainter,
        ),
        findsNothing,
      );
    }
    late Uint8List result;
    await tester.runAsync(() async {
      final image =
          await (captureKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: dpr);
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
      final rect = tester.getRect(find.byKey(surfaceKey));
      final left = (rect.left * dpr).round();
      final top = (rect.top * dpr).round();
      final width = (size.width * dpr * scale).round();
      final height = (size.height * dpr * scale).round();
      result = Uint8List(width * height * 4);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          if (left + x < 0 ||
              top + y < 0 ||
              left + x >= image.width ||
              top + y >= image.height) {
            continue;
          }
          final start = ((top + y) * image.width + left + x) * 4;
          result.setRange(
            (y * width + x) * 4,
            (y * width + x + 1) * 4,
            pixels,
            start,
          );
        }
      }
      if (const bool.fromEnvironment('GLASS_SAVE_PROBES')) {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          '/tmp/fluxdo-glass-${optical ? "optical" : "blur"}-$dpr-${position.dx}-${position.dy}-$nested-$scale.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
      }
      image.dispose();
    });
    expect(tester.takeException(), isNull);
    return result;
  }

  double difference(Uint8List a, Uint8List b) {
    expect(a.length, b.length);
    var total = 0;
    for (var i = 0; i < a.length; i++) {
      total += (a[i] - b[i]).abs();
    }
    return total / a.length;
  }

  testWidgets('shader 加载前后及模糊开关不重新挂载前景状态', (tester) async {
    addTearDown(tester.view.reset);
    var mounts = 0;
    Future<void> pumpSurface(bool enabled) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 200,
              child: GlassSurfaceFrame(
                radius: 24,
                enabled: enabled,
                child: _StateProbe(onMount: () => mounts++),
              ),
            ),
          ),
        ),
      );
    }

    await pumpSurface(true);
    for (
      var i = 0;
      i < 50 && find.byType(BackdropFilter).evaluate().length != 2;
      i++
    ) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
    }
    expect(find.byType(BackdropFilter), findsNWidgets(2));
    expect(mounts, 1);
    expect(
      tester.getSize(find.byType(GlassSurface)).height,
      48,
      reason: '松约束不能让玻璃高度膨胀到整页',
    );
    await pumpSurface(false);
    expect(find.byType(BackdropFilter), findsNothing);
    await pumpSurface(true);
    expect(find.byType(BackdropFilter), findsNWidgets(2));
    expect(mounts, 1);
  }, skip: !ui.ImageFilter.isShaderFilterSupported);

  testWidgets(
    '折射开启时不同位置与 DPR 的像素结果一致，右半边不复制成条带',
    (tester) async {
      addTearDown(tester.view.reset);
      for (final dpr in [1.0, 2.0, 3.0]) {
        final original = await capture(
          tester,
          position: const Offset(30, 40),
          dpr: dpr,
        );
        final moved = await capture(
          tester,
          position: const Offset(240, 300),
          dpr: dpr,
        );
        expect(
          difference(original, moved),
          lessThan(1.5),
          reason: '玻璃与背景一起平移不应改变材质',
        );
        final width = (size.width * dpr).round();
        final y = (size.height / 2 * dpr).round();
        final colors = <int>{};
        for (var x = (110 * dpr).round(); x < (185 * dpr).round(); x++) {
          final index = (y * width + x) * 4;
          colors.add(
            (moved[index] << 16) | (moved[index + 1] << 8) | moved[index + 2],
          );
        }
        expect(colors.length, greaterThan(10), reason: '右半边必须保留背景变化，不能反复读取同一列');
      }
    },
    skip: !ui.ImageFilter.isShaderFilterSupported,
  );

  GlassRecipe refractionOnly(double amount) {
    const base = GlassRecipe.navigation;
    return GlassRecipe(
      // 固定诊断配方，使几何回归不随产品视觉配方调校而改变基线。
      blurSigmaPx: 9.2,
      tintAlpha: 0,
      tintLightGray: base.tintLightGray,
      tintDarkGray: base.tintDarkGray,
      saturation: 1,
      brightness: 0,
      contrast: 1,
      refractionHeight: 18,
      refractionAmount: amount,
      depthEffect: base.depthEffect,
      chromaticAberration: 0,
      highlightAlpha: 0,
      darkHighlightMultiplier: base.darkHighlightMultiplier,
      noise: 0,
      postBlurSigma: 0.5,
      fallbackEdgeWidth: base.fallbackEdgeWidth,
      fallbackLightAlpha: base.fallbackLightAlpha,
      fallbackDarkAlpha: base.fallbackDarkAlpha,
    );
  }

  testWidgets('只改变折射量就产生边缘位移，中间区域保持不变', (tester) async {
    addTearDown(tester.view.reset);
    final optical = await capture(
      tester,
      position: const Offset(200, 300),
      dpr: 2,
      recipe: refractionOnly(18),
    );
    final identity = await capture(
      tester,
      position: const Offset(200, 300),
      dpr: 2,
      recipe: refractionOnly(0),
    );
    var edgeDifference = 0.0;
    var centerDifference = 0.0;
    var edgeCount = 0;
    var centerCount = 0;
    const width = 400;
    for (var y = 0; y < 96; y++) {
      for (var x = 0; x < width; x++) {
        final i = (y * width + x) * 4;
        final delta =
            (optical[i] - identity[i]).abs() +
            (optical[i + 1] - identity[i + 1]).abs() +
            (optical[i + 2] - identity[i + 2]).abs();
        if (x > 60 && x < 340 && y > 4 && y < 24) {
          edgeDifference += delta;
          edgeCount += 3;
        }
        if (x > 100 && x < 300 && y > 43 && y < 53) {
          centerDifference += delta;
          centerCount += 3;
        }
      }
    }
    expect(
      edgeDifference / edgeCount,
      greaterThan(2),
      reason: '关闭高光、噪点、色散和色罩后，仍必须有真实折射位移',
    );
    expect(
      centerDifference / centerCount,
      lessThan(1),
      reason: '折射应局限在边缘带，不拉伸整个背景',
    );
  }, skip: !ui.ImageFilter.isShaderFilterSupported);

  testWidgets('左上边缘被父裁切时仍与完整玻璃对应区域一致', (tester) async {
    addTearDown(tester.view.reset);
    final original = await capture(
      tester,
      position: const Offset(30, 40),
      dpr: 1,
      recipe: refractionOnly(18),
    );
    final clipped = await capture(
      tester,
      position: const Offset(-10, -10),
      dpr: 1,
      recipe: refractionOnly(18),
    );
    var delta = 0.0;
    var count = 0;
    for (var y = 15; y < 43; y++) {
      for (var x = 25; x < 175; x++) {
        final i = (y * 200 + x) * 4;
        for (var c = 0; c < 3; c++) {
          delta += (original[i + c] - clipped[i + c]).abs();
          count++;
        }
      }
    }
    expect(delta / count, lessThan(2));
  }, skip: !ui.ImageFilter.isShaderFilterSupported);

  testWidgets('额外缩放后的折射几何与未缩放结果一致', (tester) async {
    addTearDown(tester.view.reset);
    final original = await capture(
      tester,
      position: const Offset(40, 40),
      dpr: 2,
      recipe: refractionOnly(18),
    );
    final scaled = await capture(
      tester,
      position: const Offset(40, 40),
      dpr: 2,
      scale: 1.25,
      recipe: refractionOnly(18),
    );
    var total = 0.0;
    var count = 0;
    for (var y = 5; y < 90; y++) {
      for (var x = 50; x < 350; x++) {
        final a = (y * 400 + x) * 4;
        final b = ((y * 1.25).round() * 500 + (x * 1.25).round()) * 4;
        for (var c = 0; c < 3; c++) {
          total += (original[a + c] - scaled[b + c]).abs();
          count++;
        }
      }
    }
    debugPrint('缩放平均像素差: ${total / count}');
    expect(total / count, lessThan(8));
  }, skip: !ui.ImageFilter.isShaderFilterSupported);

  testWidgets('嵌套离屏层、分数位置与缩放仍保留折射', (tester) async {
    addTearDown(tester.view.reset);
    for (final scale in [1.0, 1.25]) {
      final a = await capture(
        tester,
        position: const Offset(30.25, 40.25),
        dpr: 2,
        nested: true,
        scale: scale,
      );
      final b = await capture(
        tester,
        position: const Offset(230.25, 280.25),
        dpr: 2,
        nested: true,
        scale: scale,
      );
      expect(difference(a, b), lessThan(2), reason: '父离屏层和位置不能改变玻璃的局部坐标');
    }
  }, skip: !ui.ImageFilter.isShaderFilterSupported);
}

class _BackdropPattern extends CustomPainter {
  const _BackdropPattern({required this.position, required this.scale});
  final Offset position;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xFFFFF5E8), BlendMode.src);
    canvas.save();
    canvas.translate(position.dx, position.dy);
    canvas.scale(scale);
    for (var x = -100; x < 500; x += 5) {
      final channel = ((x + 100) / 600 * 255).round().clamp(0, 255);
      canvas.drawRect(
        Rect.fromLTWH(x.toDouble(), -100, 5, 600),
        Paint()..color = Color.fromARGB(255, channel, 80, 220 - channel ~/ 2),
      );
    }
    for (var y = -100; y < 500; y += 12) {
      canvas.drawRect(
        Rect.fromLTWH(-100, y.toDouble(), 600, 3),
        Paint()..color = const Color(0xFF202020),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BackdropPattern oldDelegate) =>
      oldDelegate.position != position || oldDelegate.scale != scale;
}

class _StateProbe extends StatefulWidget {
  const _StateProbe({required this.onMount});
  final VoidCallback onMount;
  @override
  State<_StateProbe> createState() => _StateProbeState();
}

class _StateProbeState extends State<_StateProbe> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 48);
}
