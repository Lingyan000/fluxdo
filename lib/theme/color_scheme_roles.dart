import 'package:flutter/material.dart';

/// 按 role 名覆盖 ColorScheme（主题 JSON 里的 `roles` 字段）。
class ColorSchemeRoles {
  ColorSchemeRoles._();

  /// 用 [overrides] 覆盖 [scheme] 的同名 role。
  ///
  /// role 名清单只在这一处 copyWith 里出现一次：取值时顺带记录被消费的
  /// 键，[unknownKeys] 借此判定拼写错误，不用再维护第二份名单。
  static ColorScheme apply(ColorScheme scheme, Map<String, Color> overrides) =>
      _apply(scheme, overrides, <String>{});

  /// [overrides] 中不是 ColorScheme role 名的键。
  static Set<String> unknownKeys(Map<String, Color> overrides) {
    final used = <String>{};
    _apply(const ColorScheme.light(), overrides, used);
    return overrides.keys.toSet().difference(used);
  }

  static ColorScheme _apply(
    ColorScheme s,
    Map<String, Color> o,
    Set<String> used,
  ) {
    if (o.isEmpty) return s;
    Color? r(String key) {
      used.add(key);
      return o[key];
    }

    return s.copyWith(
      primary: r('primary'),
      onPrimary: r('onPrimary'),
      primaryContainer: r('primaryContainer'),
      onPrimaryContainer: r('onPrimaryContainer'),
      primaryFixed: r('primaryFixed'),
      primaryFixedDim: r('primaryFixedDim'),
      onPrimaryFixed: r('onPrimaryFixed'),
      onPrimaryFixedVariant: r('onPrimaryFixedVariant'),
      secondary: r('secondary'),
      onSecondary: r('onSecondary'),
      secondaryContainer: r('secondaryContainer'),
      onSecondaryContainer: r('onSecondaryContainer'),
      secondaryFixed: r('secondaryFixed'),
      secondaryFixedDim: r('secondaryFixedDim'),
      onSecondaryFixed: r('onSecondaryFixed'),
      onSecondaryFixedVariant: r('onSecondaryFixedVariant'),
      tertiary: r('tertiary'),
      onTertiary: r('onTertiary'),
      tertiaryContainer: r('tertiaryContainer'),
      onTertiaryContainer: r('onTertiaryContainer'),
      tertiaryFixed: r('tertiaryFixed'),
      tertiaryFixedDim: r('tertiaryFixedDim'),
      onTertiaryFixed: r('onTertiaryFixed'),
      onTertiaryFixedVariant: r('onTertiaryFixedVariant'),
      error: r('error'),
      onError: r('onError'),
      errorContainer: r('errorContainer'),
      onErrorContainer: r('onErrorContainer'),
      surface: r('surface'),
      onSurface: r('onSurface'),
      surfaceDim: r('surfaceDim'),
      surfaceBright: r('surfaceBright'),
      surfaceContainerLowest: r('surfaceContainerLowest'),
      surfaceContainerLow: r('surfaceContainerLow'),
      surfaceContainer: r('surfaceContainer'),
      surfaceContainerHigh: r('surfaceContainerHigh'),
      surfaceContainerHighest: r('surfaceContainerHighest'),
      onSurfaceVariant: r('onSurfaceVariant'),
      outline: r('outline'),
      outlineVariant: r('outlineVariant'),
      shadow: r('shadow'),
      scrim: r('scrim'),
      inverseSurface: r('inverseSurface'),
      onInverseSurface: r('onInverseSurface'),
      inversePrimary: r('inversePrimary'),
      surfaceTint: r('surfaceTint'),
    );
  }
}
