import 'package:flutter/painting.dart';

/// WCAG 对比度工具：固定配色主题推导 `on*` role 时保证可读性。
class ColorContrast {
  ColorContrast._();

  /// 正文文字的最低对比度（WCAG AA）。
  static const double text = 4.5;

  /// 大字、图标、描边的最低对比度（WCAG AA 非文本）。
  static const double graphic = 3.0;

  /// [a] 与 [b] 的对比度（1~21）。带透明度的前景先叠到背景上再算。
  static double ratio(Color a, Color b) {
    final fg = a.a < 1 ? Color.alphaBlend(a, b) : a;
    final la = fg.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// 在 [bg] 上至少达到 [min] 对比度的 [fg]。
  ///
  /// 已达标原样返回；否则保持色相与饱和度，只沿明度向更有利的一端
  /// （黑或白）移动，取满足要求的最小改动，尽量保留原色观感。
  /// 两端都达不到时返回对比度更高的那一端。
  static Color ensure(Color fg, Color bg, double min) {
    if (ratio(fg, bg) >= min) return fg;
    const black = Color(0xFF000000);
    const white = Color(0xFFFFFFFF);
    final towardWhite = ratio(white, bg) >= ratio(black, bg);
    final extreme = towardWhite ? white : black;
    if (ratio(extreme, bg) < min) return extreme;

    final hsl = HSLColor.fromColor(fg.withValues(alpha: 1));
    final target = towardWhite ? 1.0 : 0.0;
    var lo = hsl.lightness;
    var hi = target;
    // 二分 16 次，明度精度约 1e-5，远小于 8bit 量化步长
    for (var i = 0; i < 16; i++) {
      final mid = (lo + hi) / 2;
      if (ratio(hsl.withLightness(mid).toColor(), bg) >= min) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
    return hsl.withLightness(hi).toColor().withValues(alpha: fg.a);
  }

  /// [bg] 或 [fg] 中与 [color] 对比度更高的一个，再补足到 [min]。
  /// 用于实心色块上的文字（onPrimary 等）：优先用主题自己的前景/背景色。
  static Color onFilled(Color color, {required Color bg, required Color fg}) {
    final pick = ratio(bg, color) >= ratio(fg, color) ? bg : fg;
    return ensure(pick, color, text);
  }
}
