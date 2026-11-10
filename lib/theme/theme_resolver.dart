import 'package:flutter/material.dart';

import '../utils/seed_color_scheme.dart';
import 'accent_colors.dart';
import 'color_scheme_roles.dart';
import 'neutral_ramps.dart';
import 'theme_spec.dart';

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

/// 主题合成器：把 [ThemeSpec] 与用户选择（强调色、纯黑、透明）解析成
/// 明暗两套 ColorScheme。
///
/// - Material 主题（未开纯黑/透明）走 [SeedColorScheme.from] 的完整
///   fromSeed 方案：中性表面带种子色相，这是一直以来的默认外观；
/// - 简约主题、纯黑/透明修饰走合成路径：彩色 role 来自 [AccentColors]，
///   中性 role 来自 [NeutralRamp]（无色相中性灰，不被种子色染色）；
/// - 固定配色主题：两类 role 都由主题关键色推导，最后应用主题的逐 role
///   覆盖。
///
/// 合成路径的所有 role 显式给出，不依赖 ColorScheme 的缺省回退。
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
  /// - [seed] 是生成式主题的种子色；固定配色主题用 [accentId] 选中的
  ///   自带强调色，找不到时取第一个；
  /// - [black] 只作用于深色一侧，且只对声明了
  ///   [ThemeSpec.supportsPureBlack] 的主题生效，主题模式选择不变；
  /// - [transparent] 在对应亮度的中性层上叠加透明版本，让用户背景图
  ///   透出来（带色相的 fromSeed 表面加透明度会浑浊，故 Material 的
  ///   透明路径一律基于中性层）。
  static ResolvedTheme resolve({
    required ThemeSpec spec,
    required ThemeMode mode,
    required bool black,
    required bool transparent,
    required Color seed,
    required DynamicSchemeVariant variant,
    String? accentId,
  }) {
    ColorScheme schemeFor(Brightness brightness) {
      final useBlack =
          black && spec.supportsPureBlack && brightness == Brightness.dark;
      if (!spec.isGenerated) {
        return _fixedScheme(
          spec: spec,
          brightness: brightness,
          accentId: accentId,
          pureBlack: useBlack,
          transparent: transparent,
        );
      }
      final neutral = spec.surface == GeneratedSurface.neutral;
      if (neutral || useBlack || transparent) {
        // 合成路径：彩色 role 来自种子，中性 role 来自中性层
        final base = useBlack
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

  static ColorScheme _fixedScheme({
    required ThemeSpec spec,
    required Brightness brightness,
    required String? accentId,
    required bool pureBlack,
    required bool transparent,
  }) {
    final palette = spec.paletteOf(brightness);
    final ramp = NeutralRamp.derive(
      brightness: brightness,
      surface: palette.bg,
      onSurface: palette.fg,
      onSurfaceVariant: palette.fgMuted,
      outlineVariant: palette.border,
      outline: palette.outline,
      pureBlack: pureBlack,
    );
    // tertiary 取强调色列表里的下一个，让三色都来自主题自己的色板
    final accents = spec.accents;
    final accent = spec.accentOf(accentId);
    final next = accents.length > 1
        ? accents[(accents.indexOf(accent) + 1) % accents.length]
        : null;
    final scheme = resolveColorScheme(
      accent: AccentColors.fromFixed(
        accent: accent.of(brightness),
        brightness: brightness,
        bg: ramp.surface,
        fg: ramp.onSurface,
        fgMuted: ramp.onSurfaceVariant,
        tertiary: next?.of(brightness),
        error: palette.error,
      ),
      neutral: transparent ? NeutralRamp.transparent(ramp) : ramp,
      brightness: brightness,
    );
    // 表面类覆盖是按主题原底色调的：纯黑/透明已经替换了表面，再应用
    // 会把修饰冲掉，此时只保留强调色类覆盖
    final overrides = pureBlack || transparent
        ? {
            for (final e in palette.roles.entries)
              if (!NeutralRamp.roleNames.contains(e.key)) e.key: e.value,
          }
        : palette.roles;
    return ColorSchemeRoles.apply(scheme, overrides);
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
