import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 内置字体选项
enum AppFontFamily {
  /// 跟随系统默认字体
  system,
  /// 内置 MiSans 字体
  miSans,
}

/// App Theme State
class ThemeState {
  final ThemeMode mode;
  final Color seedColor;
  final bool useDynamicColor;
  final AppFontFamily fontFamily;
  final DynamicSchemeVariant schemeVariant;

  /// 用户自定义颜色列表
  final List<Color> customColors;

  /// 系统动态色原始 primary（由 DynamicColorBuilder 提供）
  final Color? dynamicPrimary;

  /// M3E 组件风格总开关（加载动画/进度条/滑块/按钮形变/下拉刷新）
  final bool m3eEnabled;

  const ThemeState({
    required this.mode,
    required this.seedColor,
    this.useDynamicColor = false,
    this.fontFamily = AppFontFamily.system,
    this.schemeVariant = DynamicSchemeVariant.tonalSpot,
    this.customColors = const [],
    this.dynamicPrimary,
    this.m3eEnabled = true,
  });

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
    Color? seedColor,
    bool? useDynamicColor,
    AppFontFamily? fontFamily,
    DynamicSchemeVariant? schemeVariant,
    List<Color>? customColors,
    Color? dynamicPrimary,
    bool? m3eEnabled,
  }) {
    return ThemeState(
      mode: mode ?? this.mode,
      seedColor: seedColor ?? this.seedColor,
      useDynamicColor: useDynamicColor ?? this.useDynamicColor,
      fontFamily: fontFamily ?? this.fontFamily,
      schemeVariant: schemeVariant ?? this.schemeVariant,
      customColors: customColors ?? this.customColors,
      dynamicPrimary: dynamicPrimary ?? this.dynamicPrimary,
      m3eEnabled: m3eEnabled ?? this.m3eEnabled,
    );
  }
}

/// App Theme Notifier
class ThemeNotifier extends StateNotifier<ThemeState> {
  static const String _themeModeKey = 'theme_mode';
  static const String _seedColorKey = 'seed_color';
  static const String _dynamicColorKey = 'use_dynamic_color';
  static const String _fontFamilyKey = 'font_family';
  static const String _schemeVariantKey = 'scheme_variant';
  static const String _customColorsKey = 'custom_colors';
  static const String _m3eEnabledKey = 'm3e_enabled';
  final SharedPreferences _prefs;

  // Preset Colors
  //
  // 前四个为内置精选种子(海洋/樱花/春/秋):Material Theme Builder 按
  // tonalSpot 从种子导出的经典配色,fromSeed(默认 tonalSpot)可 1:1
  // 复现全套 token(已实测 primary/container/surface/scl 一致)。
  static const List<Color> presetColors = [
    Color(0xFF116682), // 海洋
    Color(0xFF8E4955), // 樱花
    Color(0xFF4C662B), // 春
    Color(0xFF735C0C), // 秋
    Colors.blue,
    Colors.purple,
    Colors.green,
    Colors.orange,
    Colors.pink,
    Colors.teal,
    Colors.red,
    Colors.indigo,
    Colors.amber,
    Colors.cyan,
  ];

  ThemeNotifier(this._prefs) : super(_loadTheme(_prefs));

  static ThemeState _loadTheme(SharedPreferences prefs) {
    // Load Mode
    final savedMode = prefs.getString(_themeModeKey);
    ThemeMode mode = ThemeMode.system;
    if (savedMode == 'light') {
      mode = ThemeMode.light;
    } else if (savedMode == 'dark') {
      mode = ThemeMode.dark;
    }

    // Load Color
    final savedColorValue = prefs.getInt(_seedColorKey);
    Color seedColor = Colors.blue;
    if (savedColorValue != null) {
      seedColor = Color(savedColorValue);
    }

    // Load Dynamic Color
    final useDynamicColor = prefs.getBool(_dynamicColorKey) ?? false;

    // Load Font Family
    final savedFontFamily = prefs.getString(_fontFamilyKey);
    AppFontFamily fontFamily = AppFontFamily.system;
    if (savedFontFamily == 'miSans') {
      fontFamily = AppFontFamily.miSans;
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

    return ThemeState(
      mode: mode,
      seedColor: seedColor,
      useDynamicColor: useDynamicColor,
      fontFamily: fontFamily,
      schemeVariant: schemeVariant,
      customColors: customColors,
      m3eEnabled: prefs.getBool(_m3eEnabledKey) ?? true,
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

  Future<void> setSeedColor(Color color) async {
    state = state.copyWith(seedColor: color, useDynamicColor: false);
    await _prefs.setInt(_seedColorKey, color.toARGB32());
    await _prefs.setBool(_dynamicColorKey, false);
  }

  Future<void> setUseDynamicColor(bool value) async {
    state = state.copyWith(useDynamicColor: value);
    await _prefs.setBool(_dynamicColorKey, value);
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
    // 如果删除的正好是当前选中色，回退到默认蓝色
    if (state.seedColor.toARGB32() == color.toARGB32() &&
        !state.useDynamicColor) {
      await setSeedColor(Colors.blue);
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
      case AppFontFamily.system:
        await _prefs.setString(_fontFamilyKey, 'system');
      case AppFontFamily.miSans:
        await _prefs.setString(_fontFamilyKey, 'miSans');
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
