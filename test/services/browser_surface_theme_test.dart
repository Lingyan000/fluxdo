import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/browser_surface_theme.dart';

void main() {
  testWidgets('纹理取样按全局坐标裁切，忽略上层菜单，销毁后不再取图', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned(
              left: 24,
              top: 56,
              width: 400,
              height: 160,
              child: TextureCaptureBoundary(
                key: key,
                child: const Column(
                  children: [
                    Expanded(
                      child: ColoredBox(
                        color: Color(0xff12372a),
                        child: SizedBox.expand(),
                      ),
                    ),
                    Expanded(
                      child: ColoredBox(
                        color: Color(0xff264653),
                        child: SizedBox.expand(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Positioned(
              left: 24,
              top: 56,
              width: 400,
              height: 160,
              child: ColoredBox(color: Colors.red),
            ),
          ],
        ),
      ),
    );
    final boundary =
        key.currentContext!.findRenderObject() as RenderTextureCaptureBoundary;
    await tester.runAsync(() async {
      for (final (region, actual, color) in [
        (
          const Rect.fromLTWH(24, 56, 400, 24),
          const Rect.fromLTWH(24, 56, 400, 24),
          const Color(0xff12372a),
        ),
        (
          const Rect.fromLTWH(4, 208, 500, 24),
          const Rect.fromLTWH(24, 208, 400, 8),
          const Color(0xff264653),
        ),
        (
          const Rect.fromLTWH(24, 180, 400, 1),
          const Rect.fromLTWH(24, 180, 400, 1),
          const Color(0xff264653),
        ),
      ]) {
        final frame = (await boundary.capture(region, maxWidth: 48))!;
        try {
          expect(frame.globalBounds, actual);
          expect(frame.image.width, 48);
          expect(frame.image.height, greaterThanOrEqualTo(1));
          final sampled = (await AdaptiveSurfaceColors.fromImage(frame.image))!
              .color;
          // GPU 缩小与颜色空间转换可产生一个量化级误差。
          expect(sampled.r, closeTo(color.r, 2 / 255));
          expect(sampled.g, closeTo(color.g, 2 / 255));
          expect(sampled.b, closeTo(color.b, 2 / 255));
        } finally {
          frame.image.dispose();
        }
      }
      expect(
        await boundary.capture(
          const Rect.fromLTWH(500, 0, 10, 10),
          maxWidth: 48,
        ),
        isNull,
      );
    });
    await tester.pumpWidget(const SizedBox.shrink());
    expect(
      await boundary.capture(
        const Rect.fromLTWH(24, 56, 400, 24),
        maxWidth: 48,
      ),
      isNull,
    );
  });

  testWidgets('截图缩放覆盖手机、超宽横屏和单像素条带，取色不生成零高图片', (tester) async {
    await tester.runAsync(() async {
      const bounds = Rect.fromLTWH(24, 56, 1280, 24);
      for (final (width, height, decodedWidth, decodedHeight) in [
        (390, 24, 48, 3),
        (1265, 24, 48, 1),
        (3840, 24, 48, 1),
        (7680, 1, 48, 1),
        (1, 24, 1, 24),
        (16, 8, 16, 8),
      ]) {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(const Color(0xffe2d8c4), BlendMode.src);
        final picture = recorder.endRecording();
        final original = await picture.toImage(width, height);
        picture.dispose();
        late Uint8List bytes;
        try {
          final encoded = (await original.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          bytes = encoded.buffer.asUint8List(
            encoded.offsetInBytes,
            encoded.lengthInBytes,
          );
        } finally {
          original.dispose();
        }
        final frame = await SurfaceFrame.decode(bytes, bounds, maxWidth: 48);
        try {
          expect(frame.image.width, decodedWidth, reason: '$width×$height');
          expect(frame.image.height, decodedHeight, reason: '$width×$height');
          expect(frame.globalBounds, bounds);
          final sample = await AdaptiveSurfaceColors.fromImage(frame.image);
          expect(sample?.color, const Color(0xffe2d8c4));
        } finally {
          frame.image.dispose();
        }
      }
      await expectLater(
        SurfaceFrame.decode(Uint8List(0), bounds, maxWidth: 0),
        throwsArgumentError,
      );
    });
  });

  test('取色忽略小面积字形和透明帧，前景/系统栏保持对比度', () {
    final rgba = Uint8List(16 * 8 * 4);
    for (var i = 0; i < 128; i++) {
      rgba.setRange(
        i * 4,
        i * 4 + 4,
        i < 22 ? [0, 0, 0, 255] : [226, 216, 196, 255],
      );
    }
    final sample = AdaptiveSurfaceColors.fromRgba(rgba, 16, 8)!;
    expect(sample.color, const Color(0xffe2d8c4));
    expect(sample.confidence, greaterThan(.8));
    expect(AdaptiveSurfaceColors.fromRgba(Uint8List(512), 16, 8), isNull);
    for (final background in [
      Colors.white,
      Colors.black,
      const Color(0xfff44336),
      Colors.blue,
      Colors.grey,
    ]) {
      expect(
        AdaptiveSurfaceColors.contrast(
          AdaptiveSurfaceColors.foreground(background),
          background,
        ),
        greaterThanOrEqualTo(4.5),
      );
    }
    final style = AdaptiveSurfaceColors.overlay(Colors.white, Colors.black);
    expect(style.statusBarIconBrightness, Brightness.dark);
    expect(style.statusBarBrightness, Brightness.light);
    expect(style.systemNavigationBarIconBrightness, Brightness.light);
    expect(
      AdaptiveSurfaceColors.resolve(
        themeColor: Colors.red,
        sampled: Colors.green,
        fallback: Colors.white,
      ),
      const Color(0xfff44336),
    );
  });

  test('圆弧亮度滞回避开临界闪烁，持续改变和极亮背景可切换', () {
    final tone = SurfaceToneTracker();
    tone.update(.1);
    expect(tone.darkInk, isFalse);
    for (final value in [.2, .27, .24, .29]) {
      expect(tone.update(value), isFalse);
    }
    tone.update(.4);
    expect(tone.darkInk, isFalse);
    tone.update(.4);
    expect(tone.darkInk, isTrue);
    tone.update(.03);
    expect(tone.darkInk, isFalse);
    tone.update(.95);
    expect(tone.darkInk, isTrue);
  });

  testWidgets('边缘取色串行、旋转重新定位，后台停止，迟到帧释放', (tester) async {
    final theme = BrowserSurfaceTheme();
    final regions = <Rect>[];
    final widths = <int?>[];
    var gate = Completer<SurfaceFrame?>();
    var enabled = true;
    var bounds = const Rect.fromLTWH(0, 56, 390, 788);
    Future<SurfaceFrame?> capture(Rect rect, {int? maxWidth}) {
      regions.add(rect);
      widths.add(maxWidth);
      return gate.future;
    }

    void configure() => theme.configure(
      enabled: enabled,
      document: 1,
      bounds: bounds,
      capture: capture,
    );
    Future<ui.Image> image(Color color) async =>
        (await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawColor(color, BlendMode.src);
          final picture = recorder.endRecording();
          final result = await picture.toImage(48, 4);
          picture.dispose();
          return result;
        }))!;
    configure();
    await tester.pump(const Duration(milliseconds: 180));
    expect(regions.single, const Rect.fromLTWH(0, 56, 390, 24));
    await tester.pump(const Duration(seconds: 8));
    expect(regions, hasLength(1));
    final oldGate = gate;
    gate = Completer<SurfaceFrame?>();
    final top = await image(Colors.white);
    await tester.runAsync(() async {
      oldGate.complete(SurfaceFrame(top, regions.first));
      await Future<void>.delayed(const Duration(milliseconds: 15));
    });
    expect(theme.top, Colors.white);
    expect(top.debugDisposed, isTrue);
    expect(regions.last, const Rect.fromLTWH(0, 820, 390, 24));
    final bottom = await image(Colors.black);
    await tester.runAsync(() async {
      gate.complete(SurfaceFrame(bottom, regions.last));
      await Future<void>.delayed(const Duration(milliseconds: 15));
    });
    expect(theme.bottom, Colors.black);
    bounds = const Rect.fromLTWH(30, 48, 784, 320);
    gate = Completer<SurfaceFrame?>();
    configure();
    await tester.pump(const Duration(milliseconds: 180));
    expect(regions.last, const Rect.fromLTWH(30, 48, 784, 24));
    enabled = false;
    configure();
    final late = await image(Colors.green);
    gate.complete(SurfaceFrame(late, regions.last));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    expect(late.debugDisposed, isTrue);
    expect(theme.top, Colors.white);
    final count = regions.length;
    await tester.pump(const Duration(seconds: 12));
    expect(regions, hasLength(count));
    expect(widths.every((width) => width == 48), isTrue);
    theme.dispose();
  });
}
