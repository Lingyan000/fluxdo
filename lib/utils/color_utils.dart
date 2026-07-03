import 'package:flutter/material.dart';

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
}
