import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';

import 'mini_app_artwork_image.dart';

/// 装饰配色按图标地址和明暗主题复用；滚动回收后不重新取色。
/// 下载继续走公共图片缓存，取色只读取 32×32 首帧，不随动图逐帧变化。
abstract final class MiniAppArtworkPalette {
  static final _cache = <(String, Brightness), Future<Color?>>{};

  static Future<Color?> resolve(String url, Brightness brightness) {
    if (url.isEmpty) return SynchronousFuture(null);
    final key = (url, brightness);
    final cached = _cache.remove(key);
    late final Future<Color?> value;
    value =
        cached ??
        _load(url, brightness).then((color) {
          // 回收后重挂载直接使用已取到的颜色，避免默认色闪回和重复渐变。
          // 已淘汰的请求完成时不重新占用缓存。
          if (identical(_cache[key], value)) {
            _cache[key] = SynchronousFuture(color);
          }
          return color;
        });
    _cache[key] = value;
    while (_cache.length > 128) {
      _cache.remove(_cache.keys.first);
    }
    return value;
  }

  static Future<Color?> _load(String url, Brightness brightness) async {
    try {
      final thumbnail = await MiniAppArtworkImage.load(
        url,
        brightness: brightness,
      );
      try {
        final data = await thumbnail.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        return data == null ? null : fromPixels(data.buffer.asUint8List());
      } finally {
        thumbnail.dispose();
      }
    } catch (_) {
      // 配色失败不影响原图标、卡片内容和启动操作。
      return null;
    }
  }

  /// 忽略透明边缘和纯黑白底，选择面积占优的色簇，避免单个亮点主导底色。
  @visibleForTesting
  static Color? fromPixels(Uint8List rgba) {
    final bins = <int, ({double weight, double r, double g, double b})>{};
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      if (rgba[i + 3] < 128) continue;
      final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
      final color = Color.fromARGB(255, r, g, b);
      final hsl = HSLColor.fromColor(color);
      if (hsl.lightness < .08 || hsl.lightness > .94 || hsl.saturation < .12) {
        continue;
      }
      final key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4);
      final weight = (.4 + hsl.saturation * .6) * rgba[i + 3] / 255;
      final old = bins[key] ?? (weight: 0.0, r: 0.0, g: 0.0, b: 0.0);
      bins[key] = (
        weight: old.weight + weight,
        r: old.r + r * weight,
        g: old.g + g * weight,
        b: old.b + b * weight,
      );
    }
    if (bins.isEmpty) return null;
    final best = bins.values.reduce((a, b) => a.weight > b.weight ? a : b);
    return Color.fromARGB(
      255,
      (best.r / best.weight).round(),
      (best.g / best.weight).round(),
      (best.b / best.weight).round(),
    );
  }
}
