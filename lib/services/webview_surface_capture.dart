import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 读取原生 WebView 的可视画面，消费者负责释放返回的图片。
/// Windows 应直接使用 TextureCaptureBoundary，避免 CDP 截图改变视口。
abstract final class WebViewSurfaceCapture {
  static const _android = MethodChannel('com.fluxdo/webview_surface');

  /// Android：由原生侧按 [width]（物理像素）缩小画布后绘制保活 WebView
  /// 的完整可视区域，返回原始像素（WebViewSurfaceChannel.kt）。插件的
  /// takeScreenshot 会先在主线程上按全分辨率软件绘制整页、再缩小、再 PNG
  /// 压缩，高频取样时占满主线程。拿不到原生实例时返回 null，由调用方退回
  /// 插件截图。[keepAliveId] 是保活实例的 `controller.getViewId()`。
  static Future<ui.Image?> androidSnapshot(
    String keepAliveId, {
    required int width,
  }) async {
    final Map<Object?, Object?>? result;
    try {
      result = await _android.invokeMapMethod<Object?, Object?>('capture', {
        'keepAliveId': keepAliveId,
        'width': width,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
    final pixels = result?['pixels'];
    final imageWidth = result?['width'];
    final imageHeight = result?['height'];
    if (pixels is! Uint8List || imageWidth is! int || imageHeight is! int) {
      return null;
    }
    final image = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      imageWidth,
      imageHeight,
      ui.PixelFormat.rgba8888,
      image.complete,
    );
    return image.future;
  }

  /// Android 保活实例的 id（插件对保活实例的 `getViewId()` 返回字符串）；
  /// 其他平台或拿不到时为 null，取样退回插件截图
  static String? keepAliveIdOf(InAppWebViewController controller) {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final id = controller.getViewId();
      return id is String ? id : null;
    } catch (_) {
      return null;
    }
  }

  static Future<SurfaceFrame?> capture({
    required Future<Uint8List?> Function(ScreenshotConfiguration configuration)
    takeScreenshot,
    required TargetPlatform platform,
    required ui.Rect viewport,
    required ui.Rect region,
    required double devicePixelRatio,
    required int maxWidth,
    Object? viewId,
  }) async {
    if (maxWidth < 1 || !devicePixelRatio.isFinite || devicePixelRatio <= 0) {
      throw ArgumentError('取样宽度和像素比例必须大于 0');
    }
    if (!viewport.isFinite || !region.isFinite || viewport.isEmpty) return null;
    final bounds = viewport.intersect(region);
    if (bounds.isEmpty) return null;
    final local = bounds.shift(-viewport.topLeft);
    final android = platform == TargetPlatform.android;
    // Android 插件通过 WebView.draw(Canvas) 截图。将 Canvas 裁成边缘条带
    // 会使嵌套 frame 停止响应滚动：touchmove 仍到达，页面却
    // 不再滚动。必须绘制完整可视区域，再在 Flutter 图片上裁切；不能给
    // 原生传局部 rect，也不能靠 invalidate/重新布局强迫网页恢复。
    final captureBounds = android ? viewport : bounds;
    // 返回的完整图仅用于一次取样，最长边不超过 512 物理像素，不缓存页面
    // 或图片。插件内部仍须以真实视口绘制，因此继续由调用者串行、低频取样。
    final scale = android
        ? math.min(
            devicePixelRatio,
            math.min(
              maxWidth / local.width,
              512 / math.max(viewport.width, viewport.height),
            ),
          )
        : math.min(devicePixelRatio, maxWidth / local.width);
    final captureWidth = math.max(1, (captureBounds.width * scale).round());
    final fast = android && viewId is String
        ? await androidSnapshot(viewId, width: captureWidth)
        : null;
    final SurfaceFrame full;
    if (fast != null) {
      full = SurfaceFrame(fast, captureBounds);
    } else {
      final screenshot = await _pluginScreenshot(
        takeScreenshot,
        android: android,
        local: local,
        captureWidth: captureWidth,
        devicePixelRatio: devicePixelRatio,
        captureBounds: captureBounds,
      );
      if (screenshot == null) return null;
      full = screenshot;
    }
    if (!android) return full;
    return _crop(
      full,
      viewport: viewport,
      local: local,
      bounds: bounds,
      maxWidth: maxWidth,
    );
  }

  static Future<SurfaceFrame?> _pluginScreenshot(
    Future<Uint8List?> Function(ScreenshotConfiguration configuration)
    takeScreenshot, {
    required bool android,
    required ui.Rect local,
    required int captureWidth,
    required double devicePixelRatio,
    required ui.Rect captureBounds,
  }) async {
    final bytes = await takeScreenshot(
      ScreenshotConfiguration(
        rect: android
            ? null
            : InAppWebViewRect(
                x: local.left,
                y: local.top,
                width: local.width,
                height: local.height,
              ),
        snapshotWidth: captureWidth / devicePixelRatio,
        compressFormat: CompressFormat.PNG,
      ),
    );
    if (bytes == null) return null;
    return SurfaceFrame.decode(bytes, captureBounds, maxWidth: captureWidth);
  }

  /// Android 截的是完整可视区域，在 Flutter 图片上裁出需要的部分
  static Future<SurfaceFrame> _crop(
    SurfaceFrame full, {
    required ui.Rect viewport,
    required ui.Rect local,
    required ui.Rect bounds,
    required int maxWidth,
  }) async {
    try {
      final xScale = full.image.width / viewport.width;
      final yScale = full.image.height / viewport.height;
      final source = ui.Rect.fromLTRB(
        local.left * xScale,
        local.top * yScale,
        local.right * xScale,
        local.bottom * yScale,
      );
      final width = math.max(1, math.min(maxWidth, source.width.ceil()));
      final height = math.max(1, source.height.ceil());
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawImageRect(
        full.image,
        source,
        ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.low,
      );
      final picture = recorder.endRecording();
      try {
        return SurfaceFrame(await picture.toImage(width, height), bounds);
      } finally {
        picture.dispose();
      }
    } finally {
      full.image.dispose();
    }
  }
}
