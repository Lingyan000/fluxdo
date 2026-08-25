import 'package:flutter/material.dart';

import '../utils/seed_color_scheme.dart';

/// 强调色组：一套配色来源提供的全部彩色 role。
///
/// 这里不含任何中性表面色。来源可以是内置默认色、调色板预设、系统
/// 动态色或用户自定义种子色。中性 role 的来源见 theme_resolver.dart：
/// 默认路径由种子色 fromSeed 生成（带色相），中性/纯黑/透明开关路径
/// 则由 [NeutralRamp] 提供（无色相）。
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

  /// 内置默认色：默认调色板的种子色。
  ///
  /// 沿用应用一直以来的蓝色种子，保证老用户升级后强调色不变。
  static const defaultSeed = Colors.blue;
}
