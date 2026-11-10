import 'package:flutter/material.dart';

import '../utils/seed_color_scheme.dart';
import 'color_contrast.dart';

/// 强调色组：一套配色来源提供的全部彩色 role。
///
/// 这里不含任何中性表面色。生成式主题的来源可以是调色板预设、系统
/// 动态色或用户自定义种子色（[AccentColors.fromSeed]）；固定配色主题
/// 由主题自带强调色推导（[AccentColors.fromFixed]）。中性 role 的来源
/// 见 theme_resolver.dart。
class AccentColors {
  const AccentColors({
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.primaryFixed,
    required this.primaryFixedDim,
    required this.onPrimaryFixed,
    required this.onPrimaryFixedVariant,
    required this.secondary,
    required this.onSecondary,
    required this.secondaryContainer,
    required this.onSecondaryContainer,
    required this.secondaryFixed,
    required this.secondaryFixedDim,
    required this.onSecondaryFixed,
    required this.onSecondaryFixedVariant,
    required this.tertiary,
    required this.onTertiary,
    required this.tertiaryContainer,
    required this.onTertiaryContainer,
    required this.tertiaryFixed,
    required this.tertiaryFixedDim,
    required this.onTertiaryFixed,
    required this.onTertiaryFixedVariant,
    required this.error,
    required this.onError,
    required this.errorContainer,
    required this.onErrorContainer,
    required this.inversePrimary,
  });

  final Color primary;
  final Color onPrimary;
  final Color primaryContainer;
  final Color onPrimaryContainer;
  final Color primaryFixed;
  final Color primaryFixedDim;
  final Color onPrimaryFixed;
  final Color onPrimaryFixedVariant;

  final Color secondary;
  final Color onSecondary;
  final Color secondaryContainer;
  final Color onSecondaryContainer;
  final Color secondaryFixed;
  final Color secondaryFixedDim;
  final Color onSecondaryFixed;
  final Color onSecondaryFixedVariant;

  final Color tertiary;
  final Color onTertiary;
  final Color tertiaryContainer;
  final Color onTertiaryContainer;
  final Color tertiaryFixed;
  final Color tertiaryFixedDim;
  final Color onTertiaryFixed;
  final Color onTertiaryFixedVariant;

  final Color error;
  final Color onError;
  final Color errorContainer;
  final Color onErrorContainer;

  final Color inversePrimary;

  // surfaceTint 恒等于 primary（M3 惯例），不单独存储。

  /// 从完整 [ColorScheme] 抽取彩色 role，中性 role 全部丢弃。
  factory AccentColors.fromScheme(ColorScheme s) => AccentColors(
    primary: s.primary,
    onPrimary: s.onPrimary,
    primaryContainer: s.primaryContainer,
    onPrimaryContainer: s.onPrimaryContainer,
    primaryFixed: s.primaryFixed,
    primaryFixedDim: s.primaryFixedDim,
    onPrimaryFixed: s.onPrimaryFixed,
    onPrimaryFixedVariant: s.onPrimaryFixedVariant,
    secondary: s.secondary,
    onSecondary: s.onSecondary,
    secondaryContainer: s.secondaryContainer,
    onSecondaryContainer: s.onSecondaryContainer,
    secondaryFixed: s.secondaryFixed,
    secondaryFixedDim: s.secondaryFixedDim,
    onSecondaryFixed: s.onSecondaryFixed,
    onSecondaryFixedVariant: s.onSecondaryFixedVariant,
    tertiary: s.tertiary,
    onTertiary: s.onTertiary,
    tertiaryContainer: s.tertiaryContainer,
    onTertiaryContainer: s.onTertiaryContainer,
    tertiaryFixed: s.tertiaryFixed,
    tertiaryFixedDim: s.tertiaryFixedDim,
    onTertiaryFixed: s.onTertiaryFixed,
    onTertiaryFixedVariant: s.onTertiaryFixedVariant,
    error: s.error,
    onError: s.onError,
    errorContainer: s.errorContainer,
    onErrorContainer: s.onErrorContainer,
    inversePrimary: s.inversePrimary,
  );

  /// 由种子色生成（走 [SeedColorScheme] 缓存，同一组合只算一次）。
  factory AccentColors.fromSeed({
    required Color seedColor,
    required Brightness brightness,
    DynamicSchemeVariant variant = DynamicSchemeVariant.tonalSpot,
  }) => AccentColors.fromScheme(
    SeedColorScheme.from(
      seedColor: seedColor,
      brightness: brightness,
      variant: variant,
    ),
  );

  /// 固定配色主题的强调色组：由选中的强调色和主题关键色推导。
  ///
  /// 不走 fromSeed——它会把容器色拉成 M3 的高饱和色调，和固定配色主题
  /// （常见低饱和、马卡龙色系）打架。这里的容器色是强调色以低透明度
  /// 叠在主题背景上，文字色统一补足对比度：
  /// - secondary：强调色向次要文字色收敛，得到同色系的低饱和版本；
  /// - tertiary：优先用主题提供的 [tertiary]（如强调色列表里的相邻色），
  ///   缺省把色相旋转 60°。
  factory AccentColors.fromFixed({
    required Color accent,
    required Brightness brightness,
    required Color bg,
    required Color fg,
    required Color fgMuted,
    Color? tertiary,
    Color? error,
  }) {
    final isLight = brightness == Brightness.light;
    Color container(Color c) =>
        Color.alphaBlend(c.withValues(alpha: isLight ? 0.16 : 0.24), bg);
    Color dim(Color c) =>
        Color.alphaBlend(c.withValues(alpha: isLight ? 0.32 : 0.40), bg);
    Color onContainer(Color c, Color background) => ColorContrast.ensure(
      Color.lerp(c, fg, 0.35)!,
      background,
      ColorContrast.text,
    );
    // 强调色本身常被当作文字/图标色直接画在背景上，至少保证非文本对比度
    Color strong(Color c) => ColorContrast.ensure(c, bg, ColorContrast.graphic);

    final primary = strong(accent);
    final secondary = strong(Color.lerp(accent, fgMuted, 0.45)!);
    final tertiaryColor = strong(
      tertiary ??
          HSLColor.fromColor(
            accent,
          ).withHue((HSLColor.fromColor(accent).hue + 60) % 360).toColor(),
    );
    final errorColor = strong(
      error ?? (isLight ? const Color(0xFFBA1A1A) : const Color(0xFFFFB4AB)),
    );

    final primaryContainer = container(primary);
    final secondaryContainer = container(secondary);
    final tertiaryContainer = container(tertiaryColor);
    final errorContainer = container(errorColor);
    final primaryDim = dim(primary);
    final secondaryDim = dim(secondary);
    final tertiaryDim = dim(tertiaryColor);

    return AccentColors(
      primary: primary,
      onPrimary: ColorContrast.onFilled(primary, bg: bg, fg: fg),
      primaryContainer: primaryContainer,
      onPrimaryContainer: onContainer(primary, primaryContainer),
      primaryFixed: primaryContainer,
      primaryFixedDim: primaryDim,
      onPrimaryFixed: onContainer(primary, primaryDim),
      onPrimaryFixedVariant: ColorContrast.ensure(
        primary,
        primaryContainer,
        ColorContrast.graphic,
      ),
      secondary: secondary,
      onSecondary: ColorContrast.onFilled(secondary, bg: bg, fg: fg),
      secondaryContainer: secondaryContainer,
      onSecondaryContainer: onContainer(secondary, secondaryContainer),
      secondaryFixed: secondaryContainer,
      secondaryFixedDim: secondaryDim,
      onSecondaryFixed: onContainer(secondary, secondaryDim),
      onSecondaryFixedVariant: ColorContrast.ensure(
        secondary,
        secondaryContainer,
        ColorContrast.graphic,
      ),
      tertiary: tertiaryColor,
      onTertiary: ColorContrast.onFilled(tertiaryColor, bg: bg, fg: fg),
      tertiaryContainer: tertiaryContainer,
      onTertiaryContainer: onContainer(tertiaryColor, tertiaryContainer),
      tertiaryFixed: tertiaryContainer,
      tertiaryFixedDim: tertiaryDim,
      onTertiaryFixed: onContainer(tertiaryColor, tertiaryDim),
      onTertiaryFixedVariant: ColorContrast.ensure(
        tertiaryColor,
        tertiaryContainer,
        ColorContrast.graphic,
      ),
      error: errorColor,
      onError: ColorContrast.onFilled(errorColor, bg: bg, fg: fg),
      errorContainer: errorContainer,
      onErrorContainer: onContainer(errorColor, errorContainer),
      // inversePrimary 画在 inverseSurface（≈ 前景色）上
      inversePrimary: ColorContrast.ensure(accent, fg, ColorContrast.graphic),
    );
  }

  /// 内置默认色：默认调色板的种子色。
  ///
  /// 沿用应用一直以来的蓝色种子，保证老用户升级后强调色不变。
  static const defaultSeed = Colors.blue;
}
