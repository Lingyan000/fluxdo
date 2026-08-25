import 'package:flutter/material.dart';

import '../utils/seed_color_scheme.dart';
import 'accent_colors.dart';
import 'neutral_ramps.dart';

/// 一次主题解析的产出：明暗两套 ColorScheme + MaterialApp 的 themeMode。
class ResolvedTheme {
  const ResolvedTheme({
    required this.light,
    required this.dark,
    required this.mode,
    required this.transparent,
  });

  final ColorScheme light;
  final ColorScheme dark;
  final ThemeMode mode;

  /// 透明模式是否生效（供根背景层/脚手架背景判断）。
  final bool transparent;
}

/// 主题合成器。
///
/// 默认路径（未开任何开关）走 [SeedColorScheme.from] 的完整 fromSeed
/// 方案：中性表面带种子色相，这是一直以来的默认外观。
///
/// 中性/纯黑/透明三个开关走合成路径：彩色 role 来自 [AccentColors]，
/// 中性 role 来自 [NeutralRamp]（无色相中性灰，不被种子色染色）。
/// 所有 role 显式给出，不依赖 ColorScheme 的缺省回退。
class ThemeResolver {
  ThemeResolver._();

  /// 合成单个 ColorScheme：彩色 role 来自 [accent]，中性 role 来自 [neutral]。
  static ColorScheme resolveColorScheme({
    required AccentColors accent,
    required NeutralRamp neutral,
    required Brightness brightness,
  }) {
    return ColorScheme(
      brightness: brightness,
      // ── 彩色 role：来自强调色组 ──
      primary: accent.primary,
      onPrimary: accent.onPrimary,
      primaryContainer: accent.primaryContainer,
      onPrimaryContainer: accent.onPrimaryContainer,
      primaryFixed: accent.primaryFixed,
      primaryFixedDim: accent.primaryFixedDim,
      onPrimaryFixed: accent.onPrimaryFixed,
      onPrimaryFixedVariant: accent.onPrimaryFixedVariant,
      secondary: accent.secondary,
      onSecondary: accent.onSecondary,
      secondaryContainer: accent.secondaryContainer,
      onSecondaryContainer: accent.onSecondaryContainer,
      secondaryFixed: accent.secondaryFixed,
      secondaryFixedDim: accent.secondaryFixedDim,
      onSecondaryFixed: accent.onSecondaryFixed,
      onSecondaryFixedVariant: accent.onSecondaryFixedVariant,
      tertiary: accent.tertiary,
      onTertiary: accent.onTertiary,
      tertiaryContainer: accent.tertiaryContainer,
      onTertiaryContainer: accent.onTertiaryContainer,
      tertiaryFixed: accent.tertiaryFixed,
      tertiaryFixedDim: accent.tertiaryFixedDim,
      onTertiaryFixed: accent.onTertiaryFixed,
      onTertiaryFixedVariant: accent.onTertiaryFixedVariant,
      error: accent.error,
      onError: accent.onError,
      errorContainer: accent.errorContainer,
      onErrorContainer: accent.onErrorContainer,
      inversePrimary: accent.inversePrimary,
      surfaceTint: accent.primary,
      // ── 中性 role：来自中性层 ──
      surface: neutral.surface,
      onSurface: neutral.onSurface,
      onSurfaceVariant: neutral.onSurfaceVariant,
      surfaceDim: neutral.surfaceDim,
      surfaceBright: neutral.surfaceBright,
      surfaceContainerLowest: neutral.surfaceContainerLowest,
      surfaceContainerLow: neutral.surfaceContainerLow,
      surfaceContainer: neutral.surfaceContainer,
      surfaceContainerHigh: neutral.surfaceContainerHigh,
      surfaceContainerHighest: neutral.surfaceContainerHighest,
      outline: neutral.outline,
      outlineVariant: neutral.outlineVariant,
      inverseSurface: neutral.inverseSurface,
      onInverseSurface: neutral.onInverseSurface,
      shadow: neutral.shadow,
      scrim: neutral.scrim,
    );
  }

  /// 解析整套主题。
  ///
  /// - [black] 只作用于深色一侧：深色用纯黑中性层，浅色不受影响，
  ///   主题模式选择不变；
  /// - [transparent] 在对应亮度的中性层上叠加透明版本，让用户背景图
  ///   透出来（带色相的 fromSeed 表面加透明度会浑浊，故透明路径一律
  ///   基于中性层）；
  /// - [neutral] 只决定非纯黑路径的表面：纯黑/透明的表面本来就是
  ///   中性层，无需再"去染色"。
  static ResolvedTheme resolve({
    required ThemeMode mode,
    required bool neutral,
    required bool black,
    required bool transparent,
    required Color seed,
    required DynamicSchemeVariant variant,
  }) {
    ColorScheme schemeFor(Brightness brightness) {
      // 纯黑只替换深色一侧的中性层
      final useBlackRamp = black && brightness == Brightness.dark;
      if (neutral || useBlackRamp || transparent) {
        // 合成路径：彩色 role 来自种子，中性 role 来自中性层
        final base = useBlackRamp
            ? NeutralRamp.black
            : brightness == Brightness.light
            ? NeutralRamp.light
            : NeutralRamp.dark;
        return resolveColorScheme(
          accent: AccentColors.fromSeed(
            seedColor: seed,
            brightness: brightness,
            variant: variant,
          ),
          neutral: transparent ? NeutralRamp.transparent(base) : base,
          brightness: brightness,
        );
      }
      // 原始路径：完整 fromSeed，表面带种子色相
      return SeedColorScheme.from(
        seedColor: seed,
        brightness: brightness,
        variant: variant,
      );
    }

    return ResolvedTheme(
      light: schemeFor(Brightness.light),
      dark: schemeFor(Brightness.dark),
      mode: mode,
      transparent: transparent,
    );
  }
}

/// 透明模式的浮层取色约定。
extension ColorSchemeOverlayX on ColorScheme {
  /// 当前主题是否处于透明模式（透明模式的表面类 role 带透明度，
  /// 见 NeutralRamp.transparent；普通模式的表面恒为不透明）。
  bool get isTransparentMode => surface.a < 0.99;

  /// 浮层根背景色：透明模式下用接近不透明的 [surfaceContainerHigh]，
  /// 避免透出底下未压暗的内容；普通模式保持 [surface]，观感与
  /// 透明功能引入前完全一致。
  Color get overlaySurface =>
      isTransparentMode ? surfaceContainerHigh : surface;
}
