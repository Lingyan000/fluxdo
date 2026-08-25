import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/accent_colors.dart';
import '../theme/app_background.dart';
import '../theme/app_palettes.dart';

/// 内置字体选项
enum AppFontFamily {
  /// 跟随系统默认字体
  system,

  /// 内置 MiSans 字体
  miSans,
}

/// 强调色来源。
///
/// 只提供彩色 role；表面是否被种子色染色由"中性"开关决定
/// （见 [ThemeState.neutralEnabled]）。
enum AccentSource {
  /// 系统动态色（Android 12+ 壁纸取色；不支持时不展示入口）
  dynamic,

  /// 内置调色板（含"默认"这一简单配色）
  palette,

  /// 用户自定义种子色
  custom,
}

/// App Theme State
class ThemeState {
  /// 主题模式：浅色 / 深色 / 跟随系统
  final ThemeMode mode;

  /// 中性开关：表面不随主题色彩染色（无色相中性灰），与模式正交
  final bool neutralEnabled;

  /// 纯黑开关（AMOLED）：深色模式下的纯黑表面质感，只作用于
  /// 深色一侧，不改变主题模式选择
  final bool blackEnabled;

  /// 透明模式开关：半透明表面 + 用户背景图，独立功能
  final bool transparentEnabled;

  /// 强调色来源
  final AccentSource accentSource;

  /// 选中的调色板 id（accentSource == palette 时生效）
  final String paletteId;

  /// 自定义种子色（accentSource == custom 时生效）
  final Color seedColor;

  /// 配色风格（9 种生成风格，对任意来源的种子色生效）
  final DynamicSchemeVariant schemeVariant;

  /// 用户自定义颜色列表
  final List<Color> customColors;

  /// 系统动态色原始 primary（由 DynamicColorBuilder 提供）
  final Color? dynamicPrimary;

  final AppFontFamily fontFamily;

  /// M3E 组件风格总开关（加载动画/进度条/滑块/按钮形变/下拉刷新）
  final bool m3eEnabled;

  /// 透明模式的背景配置
  final AppBackground background;

  const ThemeState({
    required this.mode,
    this.neutralEnabled = false,
    this.blackEnabled = false,
    this.transparentEnabled = false,
    this.accentSource = AccentSource.palette,
    this.paletteId = AppPalettes.defaultId,
    required this.seedColor,
    this.schemeVariant = DynamicSchemeVariant.tonalSpot,
    this.customColors = const [],
    this.dynamicPrimary,
    this.fontFamily = AppFontFamily.system,
    this.m3eEnabled = true,
    this.background = const AppBackground(),
  });

  /// 透明模式当前是否真正生效（开了开关且有背景图才生效；
  /// 无图时回退普通表面，避免裸透明造成的可读性事故）
  bool get isTransparentActive => transparentEnabled && background.hasImage;

  /// 当前生效的种子色（色卡预览、主题合成、预热等场景使用）
  Color get effectiveSeedColor => switch (accentSource) {
    AccentSource.dynamic => dynamicPrimary ?? seedColor,
    AccentSource.palette => AppPalettes.byId(paletteId).seedColor,
    AccentSource.custom => seedColor,
  };

  /// 获取实际用于 ThemeData 的 fontFamily 字符串
  String? get fontFamilyName {
    switch (fontFamily) {
      case AppFontFamily.miSans:
        return 'MiSans';
      case AppFontFamily.system:
        return null;
    }
  }

  ThemeState copyWith({
    ThemeMode? mode,
    bool? neutralEnabled,
    bool? blackEnabled,
    bool? transparentEnabled,
    AccentSource? accentSource,
    String? paletteId,
    Color? seedColor,
    DynamicSchemeVariant? schemeVariant,
    List<Color>? customColors,
    Color? dynamicPrimary,
    AppFontFamily? fontFamily,
    bool? m3eEnabled,
    AppBackground? background,
  }) {
    return ThemeState(
      mode: mode ?? this.mode,
      neutralEnabled: neutralEnabled ?? this.neutralEnabled,
      blackEnabled: blackEnabled ?? this.blackEnabled,
      transparentEnabled: transparentEnabled ?? this.transparentEnabled,
      accentSource: accentSource ?? this.accentSource,
      paletteId: paletteId ?? this.paletteId,
      seedColor: seedColor ?? this.seedColor,
      schemeVariant: schemeVariant ?? this.schemeVariant,
      customColors: customColors ?? this.customColors,
      dynamicPrimary: dynamicPrimary ?? this.dynamicPrimary,
      fontFamily: fontFamily ?? this.fontFamily,
      m3eEnabled: m3eEnabled ?? this.m3eEnabled,
      background: background ?? this.background,
    );
  }
}

/// App Theme Notifier
class ThemeNotifier extends StateNotifier<ThemeState> {
  static const String _themeModeKey = 'theme_mode';
  static const String _neutralKey = 'theme_neutral';
  static const String _blackKey = 'theme_black';
  static const String _transparentKey = 'theme_transparent';
  static const String _accentSourceKey = 'accent_source';
  static const String _paletteIdKey = 'palette_id';
  static const String _seedColorKey = 'seed_color';
  static const String _schemeVariantKey = 'scheme_variant';
  static const String _customColorsKey = 'custom_colors';
  static const String _fontFamilyKey = 'font_family';
  static const String _m3eEnabledKey = 'm3e_enabled';
  static const String _bgImagePathKey = 'bg_image_path';
  static const String _bgScrimLightKey = 'bg_scrim_light';
  static const String _bgScrimDarkKey = 'bg_scrim_dark';
  static const String _bgBlurKey = 'bg_blur';

  // 旧版键：只读迁移，不再写入
  static const String _legacyDynamicColorKey = 'use_dynamic_color';

  final SharedPreferences _prefs;

  ThemeNotifier(this._prefs) : super(_loadTheme(_prefs));

  static ThemeState _loadTheme(SharedPreferences prefs) {
    // ── 主题模式 ──
    final savedMode = prefs.getString(_themeModeKey);
    ThemeMode mode = ThemeMode.system;
    if (savedMode == 'light') {
      mode = ThemeMode.light;
    } else if (savedMode == 'dark') {
      mode = ThemeMode.dark;
    }

    // ── 自定义种子色（自定义路径的唯一颜色状态） ──
    final savedColorValue = prefs.getInt(_seedColorKey);
    final seedColor = savedColorValue != null
        ? Color(savedColorValue)
        : AccentColors.defaultSeed;

    // ── 强调色来源：新键优先，缺省时从 use_dynamic_color + seed_color 迁移 ──
    final AccentSource accentSource;
    final String paletteId;
    final savedSource = prefs.getString(_accentSourceKey);
    if (savedSource != null) {
      accentSource =
          AccentSource.values.asNameMap()[savedSource] ?? AccentSource.palette;
      paletteId = prefs.getString(_paletteIdKey) ?? AppPalettes.defaultId;
    } else if (prefs.getBool(_legacyDynamicColorKey) ?? false) {
      accentSource = AccentSource.dynamic;
      paletteId = AppPalettes.defaultId;
    } else {
      final matched = AppPalettes.bySeed(seedColor);
      if (matched != null) {
        accentSource = AccentSource.palette;
        paletteId = matched.id;
      } else {
        accentSource = AccentSource.custom;
        paletteId = AppPalettes.defaultId;
      }
    }

    // Load Scheme Variant
    final savedVariant = prefs.getString(_schemeVariantKey);
    DynamicSchemeVariant schemeVariant = DynamicSchemeVariant.tonalSpot;
    for (final v in DynamicSchemeVariant.values) {
      if (v.name == savedVariant) {
        schemeVariant = v;
        break;
      }
    }

    // Load Custom Colors
    final savedCustomColors = prefs.getStringList(_customColorsKey) ?? [];
    final customColors = savedCustomColors
        .map((s) => int.tryParse(s))
        .where((v) => v != null)
        .map((v) => Color(v!))
        .toList();

    // Load Font Family
    final savedFontFamily = prefs.getString(_fontFamilyKey);
    AppFontFamily fontFamily = AppFontFamily.system;
    if (savedFontFamily == 'miSans') {
      fontFamily = AppFontFamily.miSans;
    }

    // ── 透明模式与背景配置 ──
    final background = AppBackground(
      imagePath: prefs.getString(_bgImagePathKey),
      scrimLight:
          prefs.getDouble(_bgScrimLightKey) ?? AppBackground.defaultScrimLight,
      scrimDark:
          prefs.getDouble(_bgScrimDarkKey) ?? AppBackground.defaultScrimDark,
      blurSigma: prefs.getDouble(_bgBlurKey) ?? 0,
    );

    return ThemeState(
      mode: mode,
      neutralEnabled: prefs.getBool(_neutralKey) ?? false,
      blackEnabled: prefs.getBool(_blackKey) ?? false,
      transparentEnabled: prefs.getBool(_transparentKey) ?? false,
      accentSource: accentSource,
      paletteId: paletteId,
      seedColor: seedColor,
      schemeVariant: schemeVariant,
      customColors: customColors,
      fontFamily: fontFamily,
      m3eEnabled: prefs.getBool(_m3eEnabledKey) ?? true,
      background: background,
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(mode: mode);
    String value = 'system';
    if (mode == ThemeMode.light) {
      value = 'light';
    } else if (mode == ThemeMode.dark) {
      value = 'dark';
    }
    await _prefs.setString(_themeModeKey, value);
  }

  Future<void> setNeutralEnabled(bool value) async {
    state = state.copyWith(neutralEnabled: value);
    await _prefs.setBool(_neutralKey, value);
  }

  Future<void> setBlackEnabled(bool value) async {
    state = state.copyWith(blackEnabled: value);
    await _prefs.setBool(_blackKey, value);
  }

  Future<void> setTransparentEnabled(bool value) async {
    state = state.copyWith(transparentEnabled: value);
    await _prefs.setBool(_transparentKey, value);
  }

  Future<void> selectPalette(String paletteId) async {
    state = state.copyWith(
      accentSource: AccentSource.palette,
      paletteId: paletteId,
    );
    await _prefs.setString(_accentSourceKey, AccentSource.palette.name);
    await _prefs.setString(_paletteIdKey, paletteId);
  }

  Future<void> selectDynamicColor() async {
    state = state.copyWith(accentSource: AccentSource.dynamic);
    await _prefs.setString(_accentSourceKey, AccentSource.dynamic.name);
  }

  Future<void> selectCustomColor(Color color) async {
    state = state.copyWith(accentSource: AccentSource.custom, seedColor: color);
    await _prefs.setString(_accentSourceKey, AccentSource.custom.name);
    await _prefs.setInt(_seedColorKey, color.toARGB32());
  }

  void setDynamicPrimary(Color? color) {
    if (state.dynamicPrimary != color) {
      state = state.copyWith(dynamicPrimary: color);
    }
  }

  Future<void> setSchemeVariant(DynamicSchemeVariant variant) async {
    state = state.copyWith(schemeVariant: variant);
    await _prefs.setString(_schemeVariantKey, variant.name);
  }

  Future<void> setM3eEnabled(bool value) async {
    state = state.copyWith(m3eEnabled: value);
    await _prefs.setBool(_m3eEnabledKey, value);
  }

  Future<void> setBackgroundImage(String path) async {
    state = state.copyWith(
      background: state.background.copyWith(imagePath: path),
    );
    await _prefs.setString(_bgImagePathKey, path);
  }

  Future<void> setBackgroundScrim(double value, Brightness brightness) async {
    final background = brightness == Brightness.light
        ? state.background.copyWith(scrimLight: value)
        : state.background.copyWith(scrimDark: value);
    state = state.copyWith(background: background);
    if (brightness == Brightness.light) {
      await _prefs.setDouble(_bgScrimLightKey, value);
    } else {
      await _prefs.setDouble(_bgScrimDarkKey, value);
    }
  }

  Future<void> setBackgroundBlur(double sigma) async {
    state = state.copyWith(
      background: state.background.copyWith(blurSigma: sigma),
    );
    await _prefs.setDouble(_bgBlurKey, sigma);
  }

  Future<void> addCustomColor(Color color) async {
    final newColors = [...state.customColors, color];
    state = state.copyWith(customColors: newColors);
    await _saveCustomColors(newColors);
  }

  Future<void> removeCustomColor(Color color) async {
    final newColors = state.customColors
        .where((c) => c.toARGB32() != color.toARGB32())
        .toList();
    state = state.copyWith(customColors: newColors);
    // 如果删除的正好是当前选中的自定义色，回退到默认调色板
    if (state.accentSource == AccentSource.custom &&
        state.seedColor.toARGB32() == color.toARGB32()) {
      await selectPalette(AppPalettes.defaultId);
    }
    await _saveCustomColors(newColors);
  }

  Future<void> _saveCustomColors(List<Color> colors) async {
    await _prefs.setStringList(
      _customColorsKey,
      colors.map((c) => c.toARGB32().toString()).toList(),
    );
  }

  Future<void> setFontFamily(AppFontFamily fontFamily) async {
    state = state.copyWith(fontFamily: fontFamily);
    switch (fontFamily) {
      case AppFontFamily.miSans:
        await _prefs.setString(_fontFamilyKey, 'miSans');
      case AppFontFamily.system:
        await _prefs.setString(_fontFamilyKey, 'system');
    }
  }
}

/// SharedPreferences Provider
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError();
});

/// Theme Provider
final themeProvider = StateNotifierProvider<ThemeNotifier, ThemeState>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return ThemeNotifier(prefs);
});
