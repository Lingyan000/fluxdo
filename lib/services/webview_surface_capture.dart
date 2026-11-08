import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 读取原生 WebView 的可视画面，消费者负责释放返回的图片。
/// Windows 应直接使用 TextureCaptureBoundary，避免 CDP 截图改变视口。
abstract final class WebViewSurfaceCapture {
  static Future<SurfaceFrame?> capture({
    required Future<Uint8List?> Function(ScreenshotConfiguration configuration)
    takeScreenshot,
    required TargetPlatform platform,
    required ui.Rect viewport,
    required ui.Rect region,
    required double devicePixelRatio,
    required int maxWidth,
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
    final full = await SurfaceFrame.decode(
      bytes,
      captureBounds,
      maxWidth: captureWidth,
    );
    if (!android) return full;
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
