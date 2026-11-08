import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_glass_backdrop.dart';

void main() {
  testWidgets('收拢仅低频读取 32px 色样，释放图片，后台没有取样', (tester) async {
    final widths = <int?>[];
    final gate = Completer<MiniAppGlassFrame?>();
    SurfaceColorSample? color;
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 44,
          height: 52,
          child: MiniAppGlassBackdrop(
            showBackdrop: false,
            onSample: (value) => color = value,
            capture: (rect, {maxWidth}) {
              widths.add(maxWidth);
              return gate.future;
            },
          ),
        ),
      ),
    );
    final frame = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.white, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(32, 32);
      picture.dispose();
      gate.complete(
        MiniAppGlassFrame(image, const Rect.fromLTWH(0, 0, 44, 52)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return image;
    });
    for (var i = 0; i < 20 && color == null; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(widths, [32]);
    expect(color!.luminance, 1);
    expect(frame!.debugDisposed, isTrue, reason: '只保留颜色，不缓存静止圆弧的背景图');
    await tester.pump(const Duration(milliseconds: 1100));
    expect(widths, hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 10));
    expect(widths, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('局部取样串行限频，移动后更新区域，关闭释放画面并丢弃迟到帧', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final regions = <Rect>[];
    var gate = Completer<MiniAppGlassFrame?>();
    Future<MiniAppGlassFrame?> capture(Rect region, {int? maxWidth}) {
      regions.add(region);
      return gate.future;
    }

    Future<ui.Image> makeImage() async {
      return (await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.green, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(40, 20);
        picture.dispose();
        return image;
      }))!;
    }

    Widget scene(double left) => MaterialApp(
      home: Stack(
        children: [
          Positioned(
            left: left,
            top: 200,
            width: 152,
            height: 52,
            child: MiniAppGlassBackdrop(capture: capture),
          ),
        ],
      ),
    );
    await tester.pumpWidget(scene(180));
    expect(regions.single, const Rect.fromLTWH(164, 184, 184, 84));
    await tester.pump(const Duration(seconds: 2));
    expect(regions, hasLength(1), reason: '慢截图不积压，不靠超时并发新截图');
    final first = await makeImage();
    gate.complete(MiniAppGlassFrame(first, regions.single));
    await tester.pump();
    await tester.pumpWidget(scene(100));
    gate = Completer<MiniAppGlassFrame?>();
    await tester.pump(const Duration(milliseconds: 160));
    expect(regions.last.left, 84);
    final second = await makeImage();
    gate.complete(MiniAppGlassFrame(second, regions.last));
    await tester.pump();
    await tester.pump();
    expect(first.debugDisposed, isTrue);
    gate = Completer<MiniAppGlassFrame?>();
    await tester.pump(const Duration(milliseconds: 160));
    final beforeClose = regions.length;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(second.debugDisposed, isTrue);
    final late = await makeImage();
    gate.complete(MiniAppGlassFrame(late, regions.last));
    await tester.pump();
    expect(late.debugDisposed, isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(regions, hasLength(beforeClose));
    expect(tester.takeException(), isNull);
  });
}
