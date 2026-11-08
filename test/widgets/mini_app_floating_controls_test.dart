import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_floating_controls.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_glass_backdrop.dart';

void main() {
  setUpAll(() async {
    if (const String.fromEnvironment('MINI_APP_PREVIEW_DIR').isEmpty) return;
    await (FontLoader(
          'packages/material_symbols_icons/${Symbols.apps_rounded.fontFamily}',
        )..addFont(
          rootBundle.load(
            'packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf',
          ),
        ))
        .load();
  });
  testWidgets('浮动圆弧在明暗和复杂背景的实际预览', (tester) async {
    const directory = String.fromEnvironment('MINI_APP_PREVIEW_DIR');
    if (directory.isEmpty) return;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 110);
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    final backgrounds = [
      Colors.white,
      const Color(0xff101215),
      const Color(0xff6e7783),
      const Color(0xff384f61),
    ];
    final samples = <Color, ui.Image>{};
    await tester.runAsync(() async {
      for (final color in backgrounds) {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(color, BlendMode.src);
        final picture = recorder.endRecording();
        samples[color] = await picture.toImage(32, 32);
        picture.dispose();
      }
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: TranslationProvider(
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Row(
              children: [
                for (final color in backgrounds)
                  Expanded(
                    child: Theme(
                      data: ThemeData(brightness: Brightness.dark),
                      child: Stack(
                        children: [
                          Positioned.fill(child: ColoredBox(color: color)),
                          if (color == const Color(0xff384f61))
                            const Positioned.fill(
                              child: CustomPaint(painter: _PreviewPattern()),
                            ),
                          Positioned.fill(
                            child: MiniAppFullscreenDock(
                              captureBackdrop: (bounds, {maxWidth}) async =>
                                  MiniAppGlassFrame(
                                    samples[color]!.clone(),
                                    bounds,
                                  ),
                              onExit: () {},
                              onMenu: (_) {},
                              landscape: false,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    final paints = tester
        .widgetList<CustomPaint>(
          find.byKey(const ValueKey('mini-app-show-controls')),
        )
        .toList();
    expect((paints[0].foregroundPainter as dynamic).ink, 1.0);
    expect((paints[1].foregroundPainter as dynamic).ink, 0.0);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final shot = await boundary.toImage(pixelRatio: 2);
      final bytes = await shot.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File('$directory/adaptive-contrast.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      shot.dispose();
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    for (final image in samples.values) {
      image.dispose();
    }
  });

  testWidgets('慢截图和吸附动画均不阻挡松手后的页面滚动', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scroll = ScrollController();
    final gate = Completer<MiniAppGlassFrame?>();
    var captures = 0;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Stack(
            children: [
              ListView.builder(
                controller: scroll,
                itemExtent: 80,
                itemCount: 100,
                itemBuilder: (_, i) => Text('$i'),
              ),
              Positioned.fill(
                child: MiniAppFullscreenDock(
                  onExit: () {},
                  onMenu: (_) {},
                  landscape: false,
                  captureBackdrop: (bounds, {maxWidth}) {
                    captures++;
                    return gate.future;
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final dock = find.byKey(const ValueKey('mini-app-fullscreen-dock'));
    final drag = await tester.startGesture(tester.getCenter(dock));
    await drag.moveBy(const Offset(-110, 60));
    await tester.pump();
    await drag.up();
    await tester.pump(const Duration(milliseconds: 16));
    final pageDrag = await tester.startGesture(const Offset(80, 600));
    await pageDrag.moveBy(const Offset(0, -120));
    await tester.pump(const Duration(milliseconds: 16));
    expect(scroll.offset, greaterThan(60), reason: '吸附未结束且截图未完成，也应立即滚动');
    await pageDrag.up();
    expect(captures, 1, reason: '拖动中没有截图积压');
    gate.complete(null);
    await tester.pumpWidget(const SizedBox.shrink());
    scroll.dispose();
  });
  testWidgets('圆弧二维跟手，松手就近靠边；变形菜单不占布局，外侧点击透传', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var taps = 0, rotations = 0;
    final preview = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: preview,
        child: TranslationProvider(
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
            ),
            home: Scaffold(
              body: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      key: const ValueKey('canvas'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => taps++,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFF384F61), Color(0xFF578582)],
                          ),
                        ),
                        child: CustomPaint(painter: _PreviewPattern()),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: MiniAppFullscreenDock(
                      onExit: () {},
                      onMenu: (_) {},
                      landscape: false,
                      onRotate: () => rotations++,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final canvas = find.byKey(const ValueKey('canvas'));
    final ring = find.byKey(const ValueKey('mini-app-fullscreen-dock'));
    final size = tester.getSize(canvas);
    Future<void> capture(String name) async {
      const directory = String.fromEnvironment('MINI_APP_PREVIEW_DIR');
      if (directory.isEmpty) return;
      await tester.runAsync(() async {
        final render =
            preview.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(directory).create(recursive: true);
        await File('$directory/$name.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
        if (name == 'edge-tab-collapsed') {
          // 直接截取真实组件所在的渲染区域，便于查看细节与屏幕边距。
          final layer = render.debugLayer! as OffsetLayer;
          final detail = await layer.toImage(
            Rect.fromLTWH(
              render.size.width - 112,
              tester.getRect(ring).top - 24,
              112,
              96,
            ),
            pixelRatio: 2,
          );
          final bytes = await detail.toByteData(format: ui.ImageByteFormat.png);
          await File('$directory/edge-tab-detail.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          detail.dispose();
        }
      });
    }

    await capture('edge-tab-collapsed');
    if (const String.fromEnvironment('MINI_APP_PREVIEW_DIR').isNotEmpty) {
      const directory = String.fromEnvironment('MINI_APP_PREVIEW_DIR');
      var bounds = Rect.fromLTWH(194, tester.getRect(ring).top - 24, 196, 100);
      var frame = 0;
      var sequence = 'morph';
      Future<void> frames(int count) async {
        for (var i = 0; i < count; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          await tester.runAsync(() async {
            final render =
                preview.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final shot = await (render.debugLayer! as OffsetLayer).toImage(
              bounds,
              pixelRatio: 2,
            );
            final bytes = await shot.toByteData(format: ui.ImageByteFormat.png);
            await File(
              '$directory/$sequence-${(frame++).toString().padLeft(3, '0')}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            shot.dispose();
          });
        }
      }

      await frames(16);
      await tester.tap(ring);
      await tester.pump();
      await frames(40);
      await tester.tapAt(const Offset(100, 600));
      await tester.pump();
      await frames(34);
      sequence = 'drag';
      frame = 0;
      bounds = Rect.fromLTWH(120, tester.getRect(ring).top - 28, 270, 160);
      await frames(14);
      final pulling = await tester.startGesture(tester.getCenter(ring));
      for (var i = 0; i < 18; i++) {
        await pulling.moveBy(const Offset(-5, 1.2));
        await frames(1);
      }
      await frames(12);
      await pulling.up();
      await frames(32);
      taps = 0;
    }
    expect(tester.getSize(ring), const Size(44, 52));
    expect(tester.getRect(ring).right, 384);
    await tester.tapAt(const Offset(180, 600));
    expect(taps, 1);
    final gesture = await tester.startGesture(tester.getCenter(ring));
    final startY = tester.getCenter(ring).dy;
    await gesture.moveBy(const Offset(-170, 90));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.getRect(ring).right, closeTo(214, 1), reason: '横向也必须直接跟手');
    expect(tester.getCenter(ring).dy, closeTo(startY + 90, 1), reason: '纵向跟手');
    Path outline() {
      final clip = tester.widget<ClipPath>(
        find.descendant(of: ring, matching: find.byType(ClipPath)).first,
      );
      return (clip.clipper! as ShapeBorderClipper).shape.getOuterPath(
        Offset.zero & tester.getSize(ring),
      );
    }

    expect(
      outline().contains(const Offset(22, 26)),
      isTrue,
      reason: '拉出的是闭合水滴，不是平移空心圆弧',
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getRect(ring).left, 6, reason: '恢复原来的间距，松手后就近靠左');
    expect(
      outline().contains(const Offset(22, 26)),
      isFalse,
      reason: '停靠后融回空心圆弧',
    );
    await tester.tap(find.byKey(const ValueKey('mini-app-show-controls')));
    await tester.pumpAndSettle();
    expect(tester.getSize(ring).width, 152, reason: '圆弧自身延展为工具条');
    expect(tester.getSize(canvas), size);
    expect(
      find.byKey(const ValueKey('mini-app-fullscreen-exit')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('mini-app-rotate')));
    expect(rotations, 1);
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    expect(tester.getRect(canvas).contains(tester.getCenter(ring)), isTrue);
    expect(tester.getSize(canvas), const Size(844, 390));
    await tester.tap(find.byKey(const ValueKey('mini-app-show-controls')));
    await tester.pumpAndSettle();
    await capture('edge-tab-expanded');
    await tester.tapAt(const Offset(500, 300));
    expect(taps, 2, reason: '展开控制也不能拦截其他游戏区域');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mini-app-fullscreen-exit')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('mini-app-show-controls')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mini-app-fullscreen-exit')),
      findsNothing,
      reason: '未操作时自动贴边收回',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('小幅移动即跟手；吸附途中按下即停，越界返回无空行程，取消后仍可点击', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_fixture());
    final dock = find.byKey(const ValueKey('mini-app-fullscreen-dock'));
    final start = tester.getTopLeft(dock);
    var gesture = await tester.startGesture(tester.getCenter(dock));
    await gesture.moveBy(const Offset(-10, 0));
    await tester.pump();
    expect(tester.getTopLeft(dock).dx, closeTo(start.dx - 10, .1));
    await gesture.moveBy(const Offset(-180, 40));
    await tester.pump();
    final released = tester.getTopLeft(dock);
    await gesture.up();
    await tester.pump();
    expect(tester.getTopLeft(dock), released, reason: '松手不能跳到另一侧');
    await tester.pump(const Duration(milliseconds: 45));
    final settling = tester.getTopLeft(dock);
    expect(settling.dx, lessThan(released.dx));
    gesture = await tester.startGesture(tester.getCenter(dock));
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.getTopLeft(dock), settling, reason: '不必先拉过阈值才能打断吸附');
    await gesture.moveBy(const Offset(12, 11));
    await tester.pump();
    expect(
      (tester.getTopLeft(dock) - settling - const Offset(12, 11)).distance,
      lessThan(.01),
    );
    await gesture.moveBy(const Offset(0, -1000));
    await tester.pump();
    expect(tester.getTopLeft(dock).dy, 8);
    await gesture.moveBy(const Offset(0, 10));
    await tester.pump();
    expect(tester.getTopLeft(dock).dy, 18, reason: '越界后反向立即移动');
    await gesture.cancel();
    await tester.pumpAndSettle();
    await tester.tap(dock);
    await tester.pumpAndSettle();
    expect(tester.getSize(dock).width, 152);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('圆弧原位延展和溶解可反向打断，变形中拖动不丢位置', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_fixture());
    final dock = find.byKey(const ValueKey('mini-app-fullscreen-dock'));
    final element = tester.element(dock);
    await tester.tap(dock);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 130));
    final opening = tester.getRect(dock);
    expect(opening.width, inExclusiveRange(44, 152));
    expect(opening.right, 384);
    await tester.tapAt(const Offset(100, 600));
    await tester.pump();
    expect(tester.getRect(dock), opening, reason: '反向收起从当前形态继续');
    await tester.pump(const Duration(milliseconds: 40));
    final closing = tester.getRect(dock);
    expect(closing.width, lessThan(opening.width));
    await tester.tap(dock);
    await tester.pump();
    expect(tester.getRect(dock), closing, reason: '收起中可重新展开');
    await tester.pump(const Duration(milliseconds: 90));
    final beforeDrag = tester.getRect(dock);
    final gesture = await tester.startGesture(tester.getCenter(dock));
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.getRect(dock), beforeDrag, reason: '按住时变形停在当前帧');
    await gesture.moveBy(const Offset(-25, 30));
    await tester.pump();
    expect(tester.getRect(dock), beforeDrag.shift(const Offset(-25, 30)));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getSize(dock).width, 152);
    expect(tester.element(dock), same(element), reason: '始终是同一个控件');
    await tester.tapAt(const Offset(100, 600));
    await tester.pumpAndSettle();
    expect(tester.getSize(dock).width, 44);
    expect(
      find.byKey(const ValueKey('mini-app-dock-glass')),
      findsNothing,
      reason: '收回后不持续过滤游戏画面',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('菜单遵循公共玻璃档位和开关，切换保留位置；减少动画立即完成变形', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _fixture(settings: const GlassSettings(level: GlassEffectLevel.basic)),
    );
    final dock = find.byKey(const ValueKey('mini-app-fullscreen-dock'));
    await tester.tap(dock);
    await tester.pumpAndSettle();
    final element = tester.element(dock);
    final rect = tester.getRect(dock);
    final glass = tester.widget<GlassSurface>(find.byType(GlassSurface));
    expect(glass.recipe, same(GlassRecipe.toolbar));
    expect(find.byType(BackdropFilter), findsOneWidget);
    await tester.pumpWidget(
      _fixture(settings: const GlassSettings(enabled: false)),
    );
    await tester.pumpAndSettle();
    expect(tester.element(dock), same(element));
    expect(tester.getRect(dock), rect);
    expect(find.byType(BackdropFilter), findsNothing);
    await tester.pumpWidget(_fixture(highContrast: true));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    await tester.pumpWidget(_fixture(reduced: true));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(100, 600));
    await tester.pump();
    expect(tester.getSize(dock).width, 44);
    await tester.tap(dock);
    await tester.pump();
    expect(tester.getSize(dock).width, 152);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Widget _fixture({
  GlassSettings settings = const GlassSettings(),
  bool highContrast = false,
  bool reduced = false,
}) => TranslationProvider(
  child: MaterialApp(
    home: GlassSettingsScope(
      settings: settings,
      child: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(highContrast: highContrast, disableAnimations: reduced),
          child: Scaffold(
            body: MiniAppFullscreenDock(
              onExit: () {},
              onRotate: () {},
              onMenu: (_) {},
              landscape: false,
            ),
          ),
        ),
      ),
    ),
  ),
);

class _PreviewPattern extends CustomPainter {
  const _PreviewPattern();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x887BB8AD)
      ..strokeWidth = 2;
    for (double x = 0; x < size.width; x += 18) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    paint.color = const Color(0x667BB8AD);
    for (double y = 0; y < size.height; y += 18) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_PreviewPattern oldDelegate) => false;
}
