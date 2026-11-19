import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/webview_surface_capture.dart';

void main() {
  Future<Uint8List> image(int width, int height) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(Colors.red, BlendMode.src);
    canvas.drawRect(
      Rect.fromLTWH(0, height / 2, width.toDouble(), height / 2),
      Paint()..color = Colors.blue,
    );
    final picture = recorder.endRecording();
    final result = await picture.toImage(width, height);
    picture.dispose();
    try {
      final data = (await result.toByteData(format: ui.ImageByteFormat.png))!;
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      result.dispose();
    }
  }

  testWidgets('Android 完整视口截图后裁边，横竖屏和局部玻璃均不传原生 rect', (tester) async {
    await tester.runAsync(() async {
      for (final size in [const Size(400, 800), const Size(800, 400)]) {
        final viewport = const Offset(24, 56) & size;
        for (final (region, expected) in [
          (Rect.fromLTWH(24, 56, size.width, 24), Colors.red),
          (
            Rect.fromLTWH(24, viewport.bottom - 24, size.width, 24),
            Colors.blue,
          ),
          (Rect.fromLTWH(8, viewport.bottom - 60, 100, 80), Colors.blue),
        ]) {
          final calls = <ScreenshotConfiguration>[];
          final bounds = viewport.intersect(region);
          final frame = (await WebViewSurfaceCapture.capture(
            takeScreenshot: (configuration) async {
              calls.add(configuration);
              // 模拟 Android 插件 snapshotWidth 乘 DPR；若代码错误地把
              // 全屏图直接当局部图，底边取色会混入红色，此断言会失败。
              final width = (configuration.snapshotWidth! * 3).round();
              return image(width, (width * size.height / size.width).round());
            },
            platform: TargetPlatform.android,
            viewport: viewport,
            region: region,
            devicePixelRatio: 3,
            maxWidth: 48,
          ))!;
          try {
            expect(calls, hasLength(1));
            expect(
              calls.single.rect,
              isNull,
              reason: '局部 Canvas 截图会触发 Android 嵌套 frame 停滚',
            );
            expect(frame.globalBounds, bounds);
            expect(frame.image.width, lessThanOrEqualTo(48));
            expect(frame.image.height, greaterThanOrEqualTo(1));
            final sample = (await AdaptiveSurfaceColors.fromImage(
              frame.image,
            ))!;
            expect(sample.color.toARGB32(), expected.toARGB32());
          } finally {
            frame.image.dispose();
          }
        }
      }
    });
  });

  testWidgets('完整图限制最长边，不返回原生区域外的画面', (tester) async {
    await tester.runAsync(() async {
      ScreenshotConfiguration? requested;
      final frame = (await WebViewSurfaceCapture.capture(
        takeScreenshot: (configuration) async {
          requested = configuration;
          return image(256, 512);
        },
        platform: TargetPlatform.android,
        viewport: const Rect.fromLTWH(0, 48, 400, 800),
        region: const Rect.fromLTWH(380, 700, 80, 80),
        devicePixelRatio: 3,
        maxWidth: 220,
      ))!;
      try {
        expect(requested!.snapshotWidth! * 3, 256);
        expect(frame.globalBounds, const Rect.fromLTWH(380, 700, 20, 80));
        expect(frame.image.width, 13);
        expect(frame.image.height, 52);
      } finally {
        frame.image.dispose();
      }
    });
  });

  testWidgets('WKWebView 保留局部截图，空交集和截图失败不制造画面', (tester) async {
    await tester.runAsync(() async {
      var calls = 0;
      final bytes = await image(48, 3);
      final frame = (await WebViewSurfaceCapture.capture(
        takeScreenshot: (config) async {
          calls++;
          expect(config.rect!.x, 0);
          expect(config.rect!.y, 776);
          expect(config.rect!.width, 400);
          expect(config.rect!.height, 24);
          return bytes;
        },
        platform: TargetPlatform.iOS,
        viewport: const Rect.fromLTWH(0, 56, 400, 800),
        region: const Rect.fromLTWH(0, 832, 400, 24),
        devicePixelRatio: 3,
        maxWidth: 48,
      ))!;
      frame.image.dispose();
      for (final outside in [true, false]) {
        expect(
          await WebViewSurfaceCapture.capture(
            takeScreenshot: (_) async {
              calls++;
              return null;
            },
            platform: TargetPlatform.android,
            viewport: const Rect.fromLTWH(0, 56, 400, 800),
            region: Rect.fromLTWH(outside ? 500 : 0, 60, 400, 24),
            devicePixelRatio: 3,
            maxWidth: 48,
          ),
          isNull,
        );
      }
      expect(calls, 2);
    });
  });

  testWidgets('Android 保活实例走原生缩小绘制，不调用插件截图；拿不到时退回插件', (tester) async {
    const channel = MethodChannel('com.fluxdo/webview_surface');
    final requests = <Map<Object?, Object?>>[];
    var available = true;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      final args = call.arguments as Map<Object?, Object?>;
      requests.add(args);
      if (!available) return null;
      // 原生按请求宽度绘制完整视口：上半红、下半蓝
      final width = args['width']! as int;
      final height = width * 2;
      final pixels = Uint8List(width * height * 4);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final p = (y * width + x) * 4;
          final top = y < height / 2;
          pixels
            ..[p] = top ? 255 : 0
            ..[p + 2] = top ? 0 : 255
            ..[p + 3] = 255;
        }
      }
      return {'width': width, 'height': height, 'pixels': pixels};
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.runAsync(() async {
      var pluginCalls = 0;
      Future<SurfaceFrame?> sample() => WebViewSurfaceCapture.capture(
        takeScreenshot: (configuration) async {
          pluginCalls++;
          final width = (configuration.snapshotWidth! * 3).round();
          return image(width, width * 2);
        },
        platform: TargetPlatform.android,
        viewport: const Rect.fromLTWH(0, 56, 400, 800),
        region: const Rect.fromLTWH(0, 832, 400, 24),
        devicePixelRatio: 3,
        maxWidth: 48,
        viewId: 'keep-alive',
      );

      final fast = (await sample())!;
      try {
        expect(pluginCalls, 0);
        expect(requests.single['keepAliveId'], 'keep-alive');
        // 完整视口按取样比例缩小：400 宽、48/400 的比例下约 48 像素宽
        expect(requests.single['width'], 48);
        final data = (await fast.image.toByteData())!;
        expect(data.getUint8(2), greaterThan(200), reason: '底边应取到蓝色');
        expect(data.getUint8(0), lessThan(60));
      } finally {
        fast.image.dispose();
      }

      available = false;
      final fallback = (await sample())!;
      fallback.image.dispose();
      expect(pluginCalls, 1);
    });
  });
}
