import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// 独立的纹理采样边界，不采集叠在其上方的原生菜单和加载提示。
class TextureCaptureBoundary extends SingleChildRenderObjectWidget {
  const TextureCaptureBoundary({super.key, required super.child});

  @override
  RenderTextureCaptureBoundary createRenderObject(BuildContext context) =>
      RenderTextureCaptureBoundary();
}

class RenderTextureCaptureBoundary extends RenderRepaintBoundary {
  /// 从 Flutter 已合成的纹理取局部画面，不调用网页截图或改变网页视口。
  /// 仅适用于能进入 Flutter 合成树的视图，例如 Windows 的 WebView 纹理。
  Future<SurfaceFrame?> capture(
    Rect globalBounds, {
    required int maxWidth,
    double devicePixelRatio = 1,
  }) async {
    if (maxWidth < 1 || devicePixelRatio <= 0) {
      throw ArgumentError('取样宽度和像素比例必须大于 0');
    }
    if (!attached || !hasSize || debugNeedsPaint) {
      return null;
    }
    final local = (globalToLocal(globalBounds.topLeft) & globalBounds.size)
        .intersect(Offset.zero & size);
    final captureLayer = layer;
    if (local.isEmpty || captureLayer is! OffsetLayer) return null;
    final actualGlobal = localToGlobal(local.topLeft) & local.size;
    final ratio = math.min(devicePixelRatio, maxWidth / local.width);
    // OffsetLayer.toImage 向上取整输出宽高，超薄条带也至少占一个像素。
    final image = await captureLayer.toImage(local, pixelRatio: ratio);
    return SurfaceFrame(image, actualGlobal);
  }
}

/// 原生视图的局部画面；消费者拥有 image，使用完必须释放。
class SurfaceFrame {
  const SurfaceFrame(this.image, this.globalBounds);
  final ui.Image image;
  final Rect globalBounds;

  /// 按实际截图尺寸缩小，宽高均至少为一个像素；不放大小图。
  ///
  /// 仅给 Codec 传 targetWidth 时，超宽条带的隐式高度可能被截断为 0，
  /// Windows Impeller 会因此终止进程，无法用 Dart try/catch 兜底。
  static Future<SurfaceFrame> decode(
    Uint8List bytes,
    Rect globalBounds, {
    required int maxWidth,
  }) async {
    if (maxWidth < 1) {
      throw ArgumentError.value(maxWidth, 'maxWidth', '必须大于 0');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        final width = math.min(maxWidth, descriptor.width);
        final height = math.max(
          1,
          (descriptor.height * width / descriptor.width).round(),
        );
        final codec = await descriptor.instantiateCodec(
          targetWidth: width,
          targetHeight: height,
        );
        try {
          return SurfaceFrame((await codec.getNextFrame()).image, globalBounds);
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }
}

typedef SurfaceCapture =
    Future<SurfaceFrame?> Function(Rect globalBounds, {int? maxWidth});

/// 与 WebView、主题和平台无关的公共取色算法。
///
/// 亮度与对比度采用 sRGB 线性化后的相对亮度，与 Chromium color_utils
/// 的思路一致；不是对 RGB 三个通道直接求平均。
abstract final class AdaptiveSurfaceColors {
  static const lightInk = Color(0xfff5f7fa);
  static const darkInk = Color(0xff20252b);

  static double contrast(Color a, Color b) {
    final x = a.computeLuminance(), y = b.computeLuminance();
    return (math.max(x, y) + .05) / (math.min(x, y) + .05);
  }

  static Color foreground(Color background) =>
      contrast(Colors.white, background) >= contrast(Colors.black, background)
      ? Colors.white
      : Colors.black;

  /// 浏览器可优先传网页声明的 theme-color；嵌套应用应传真实内容取样，
  /// 不把外层宿主的 theme-color 当成应用本身的颜色。
  static Color resolve({
    Color? themeColor,
    Color? sampled,
    required Color fallback,
  }) => Color.alphaBlend(themeColor ?? sampled ?? fallback, fallback);

  static SystemUiOverlayStyle overlay(Color top, Color bottom) {
    final topDark = foreground(top) == Colors.black;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: topDark ? Brightness.dark : Brightness.light,
      statusBarBrightness: topDark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: foreground(bottom) == Colors.black
          ? Brightness.dark
          : Brightness.light,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarContrastEnforced: false,
    );
  }

  static Future<SurfaceColorSample?> fromImage(ui.Image image) async {
    final bytes = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (bytes == null) return null;
    return fromRgba(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      image.width,
      image.height,
    );
  }

  /// 最多读取 16×8 个像素，颜色分桶选主体，排除小面积文字/图标干扰。
  /// 对透明帧返回 null，不以黑色代替尚未渲染的内容。
  static SurfaceColorSample? fromRgba(Uint8List bytes, int width, int height) {
    if (width <= 0 || height <= 0 || bytes.length < width * height * 4) {
      return null;
    }
    final columns = math.min(width, 16), rows = math.min(height, 8);
    final buckets = <int, List<int>>{};
    var luminance = 0.0, count = 0;
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < columns; x++) {
        final offset =
            (((y + .5) * height / rows).floor() * width +
                ((x + .5) * width / columns).floor()) *
            4;
        if (bytes[offset + 3] < 240) continue;
        final r = bytes[offset], g = bytes[offset + 1], b = bytes[offset + 2];
        final bucket = buckets.putIfAbsent(
          ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4),
          () => [0, 0, 0, 0],
        );
        bucket[0]++;
        bucket[1] += r;
        bucket[2] += g;
        bucket[3] += b;
        luminance += Color.fromARGB(255, r, g, b).computeLuminance();
        count++;
      }
    }
    if (count < columns * rows / 2) return null;
    final dominant = buckets.values.reduce((a, b) => a[0] >= b[0] ? a : b);
    return SurfaceColorSample(
      Color.fromARGB(
        255,
        dominant[1] ~/ dominant[0],
        dominant[2] ~/ dominant[0],
        dominant[3] ~/ dominant[0],
      ),
      luminance / count,
      confidence: dominant[0] / count,
    );
  }
}

class SurfaceColorSample {
  const SurfaceColorSample(this.color, this.luminance, {this.confidence = 1});
  final Color color;
  final double luminance;
  final double confidence;
}

/// 双阈值和连续确认防止动态背景在临界亮度附近反复切色。
class SurfaceToneTracker {
  bool? _darkInk;
  bool? _candidate;
  bool update(double luminance) {
    final previous = _darkInk;
    final next = previous == null
        ? luminance > .23
        : previous
        ? luminance >= .16
        : luminance > .30;
    if (previous == null || next == previous) {
      _candidate = null;
      _darkInk = next;
    } else if (_candidate == next || luminance < .06 || luminance > .75) {
      _candidate = null;
      _darkInk = next;
    } else {
      _candidate = next;
    }
    return previous != _darkInk;
  }

  bool get darkInk => _darkInk ?? false;
}
