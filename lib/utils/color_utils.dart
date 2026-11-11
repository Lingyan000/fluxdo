import 'package:flutter/material.dart';

import '../theme/theme_style.dart';

/// 品牌色(Discourse 分类色/标签色)可读性工具。
class ColorUtils {
  ColorUtils._();

  /// 把为亮色网页设计的品牌色调整到当前主题下可读的亮度区间:
  /// 暗色主题提亮过暗的颜色,亮色主题压暗过亮的颜色,色相/饱和度不变。
  static Color readableOn(Color color, Brightness brightness) {
    final hsl = HSLColor.fromColor(color);
    if (brightness == Brightness.dark) {
      if (hsl.lightness < 0.6) {
        return hsl.withLightness(0.6 + hsl.lightness * 0.2).toColor();
      }
    } else {
      if (hsl.lightness > 0.55) {
        return hsl.withLightness(0.42).toColor();
      }
    }
    return color;
  }

  /// 解析 Discourse 下发的 6 位十六进制色（可带 `#`），无效返回 null。
  static Color? parseHex(String? hex) {
    if (hex == null) return null;
    final clean = hex.startsWith('#') ? hex.substring(1) : hex;
    if (clean.length != 6) return null;
    final value = int.tryParse(clean, radix: 16);
    return value == null ? null : Color(0xFF000000 | value);
  }

  /// 分类色 / 标签色在当前主题下的显示色：解析 [hex]（无效取 [fallback]，
  /// 缺省灰色），再按主题的数据色风格处理。
  static Color category(String? hex, ThemeData theme, {Color? fallback}) =>
      themed(parseHex(hex) ?? fallback ?? Colors.grey, theme);

  /// 按主题的数据色风格（[ThemeStyle.dataColors]）处理一个数据色。
  static Color themed(Color color, ThemeData theme) {
    final style = theme.extension<ThemeStyle>()?.dataColors;
    switch (style) {
      case null || DataColorStyle.vivid:
        return color;
      case DataColorStyle.harmonized:
        return _harmonize(color, theme.colorScheme.primary);
      case DataColorStyle.muted:
        return _mute(color, theme.brightness);
      case DataColorStyle.mono:
        return _mono(theme.colorScheme.primary, theme.brightness);
    }
  }

  /// 色相向 [anchor] 偏移差值的一半，最多 15°：保留分类之间的区分，
  /// 同时让整体落在主题的色调里。
  static Color _harmonize(Color color, Color anchor) {
    final c = HSVColor.fromColor(color);
    final a = HSVColor.fromColor(anchor);
    if (c.saturation < 0.08 || a.saturation < 0.08) return color;
    var diff = a.hue - c.hue;
    if (diff > 180) diff -= 360;
    if (diff < -180) diff += 360;
    final shift = (diff * 0.5).clamp(-15.0, 15.0);
    return c.withHue((c.hue + shift) % 360).toColor();
  }

  /// 单色主题：分类色统一成强调色的色相，明度收进与次要文字相近的中段。
  static Color _mono(Color anchor, Brightness brightness) {
    final hsl = HSLColor.fromColor(anchor);
    final dark = brightness == Brightness.dark;
    return hsl
        .withSaturation(hsl.saturation * 0.6)
        .withLightness(dark ? 0.62 : 0.4)
        .toColor();
  }

  /// 降饱和并把明度收进中段：素色主题里分类色只是一点色相提示。
  static Color _mute(Color color, Brightness brightness) {
    final hsl = HSLColor.fromColor(color);
    final dark = brightness == Brightness.dark;
    return hsl
        .withSaturation(hsl.saturation * 0.42)
        .withLightness(
          dark
              ? hsl.lightness.clamp(0.62, 0.74)
              : hsl.lightness.clamp(0.34, 0.48),
        )
        .toColor();
  }
}
