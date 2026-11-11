import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/fonts/font_catalog.dart';
import '../services/fonts/font_download_service.dart';
import '../services/launch_splash_handoff.dart';
import '../theme/accent_colors.dart';
import '../theme/app_background.dart';
import 'package:common_ui/common_ui.dart' show UiShapes;

import '../theme/app_palettes.dart';
import '../theme/custom_themes.dart';
import '../theme/festival_calendar.dart';
import '../theme/shape_presets.dart';
import '../theme/theme_registry.dart';
import '../theme/theme_spec.dart';
import '../theme/theme_style.dart';

/// 字体选择的特殊取值；其余取值为字体目录 id（见 [FontCatalog]）。
abstract final class FontChoice {
  /// 跟随主题推荐（主题未推荐时用系统字体）
  static const String follow = 'follow';

  /// 系统字体
  static const String system = 'system';
}

/// 强调色来源。
///
/// 只对生成式主题（Material / 简约）生效，只提供彩色 role；表面是否
/// 被种子色染色由主题决定（见 [ThemeState.themeId]）。
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

  /// 当前主题 id（见 [ThemeRegistry]），与模式正交
  final String themeId;

  /// 用户指定的圆角风格，null 表示跟随主题推荐
  final ShapePreset? shapeOverride;

  /// 固定配色主题按族记忆的强调色：主题自带强调色 id，或 `#RRGGBB`
  /// 自定义色（主题允许时）。生成式主题的强调色见 [accentSource]。
  final Map<String, String> themeAccents;

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

  /// 正文字体选择（[FontChoice] 或字体目录 id）
  final String bodyFont;

  /// 等宽字体选择（[FontChoice] 或字体目录 id）
  final String monoFont;

  /// 已注册给引擎、可以直接使用的字体 id
  final Set<String> loadedFonts;

  /// 节日主题开关：传统节日期间自动换上节日配色
  final bool festivalEnabled;

  /// 节日期间首次打开时的问候提示
  final bool festivalGreetingEnabled;

  /// 已跳过（「本次关闭」或节日期间手动换了主题）的节日窗口键
  final Set<String> festivalSkipped;

  /// 今天所处的节日窗口（与开关、跳过无关）
  final FestivalOccurrence? festival;

  /// 用户自定义主题（与 [ThemeRegistry.custom] 同步，变化时触发重建）
  final List<ThemeSpec> customThemes;

  /// M3E 组件风格总开关（加载动画/进度条/滑块/按钮形变/下拉刷新）
  final bool m3eEnabled;

  /// 透明模式的背景配置
  final AppBackground background;

  const ThemeState({
    required this.mode,
    this.themeId = ThemeRegistry.materialId,
    this.themeAccents = const {},
    this.shapeOverride,
    this.blackEnabled = false,
    this.transparentEnabled = false,
    this.accentSource = AccentSource.palette,
    this.paletteId = AppPalettes.defaultId,
    required this.seedColor,
    this.schemeVariant = DynamicSchemeVariant.tonalSpot,
    this.customColors = const [],
    this.dynamicPrimary,
    this.bodyFont = FontChoice.follow,
    this.monoFont = FontChoice.follow,
    this.loadedFonts = const {},
    this.festivalEnabled = true,
    this.festivalGreetingEnabled = true,
    this.festivalSkipped = const {},
    this.festival,
    this.customThemes = const [],
    this.m3eEnabled = true,
    this.background = const AppBackground(),
  });

  /// 透明模式当前是否真正生效（开了开关且有背景图才生效；
  /// 无图时回退普通表面，避免裸透明造成的可读性事故）
  bool get isTransparentActive => transparentEnabled && background.hasImage;

  /// 当前主题
  ThemeSpec get themeSpec => ThemeRegistry.byId(themeId);

  /// 当前生效的节日（开关打开、处于窗口内且本次未跳过）
  FestivalOccurrence? get activeFestival {
    final f = festival;
    if (!festivalEnabled || f == null || festivalSkipped.contains(f.key)) {
      return null;
    }
    // 节日配色主题缺失（资产损坏）时不生效
    return ThemeRegistry.byId(f.festival.themeId).id == f.festival.themeId
        ? f
        : null;
  }

  /// 实际用于配色的主题：节日生效时为节日配色，否则为用户选择的主题。
  /// 圆角与字体始终跟随用户选择的主题（[themeSpec]）。
  ThemeSpec get effectiveColorSpec {
    final f = activeFestival;
    return f == null ? themeSpec : ThemeRegistry.byId(f.festival.themeId);
  }

  /// 主题、强调色、配色风格与圆角是否都是默认值（外观页据此显示「重置」）
  bool get isThemeLookDefault =>
      themeId == ThemeRegistry.materialId &&
      accentSource == AccentSource.palette &&
      paletteId == AppPalettes.defaultId &&
      schemeVariant == DynamicSchemeVariant.tonalSpot &&
      shapeOverride == null &&
      themeAccents.isEmpty;

  /// 当前生效的界面风格：跟随用户选择的主题（节日只换配色）
  ThemeStyle get effectiveStyle => themeSpec.style;

  /// 纸张纹理是否生效：与用户背景图共用页面背景层，背景图优先
  bool get isPaperTextureActive =>
      !isTransparentActive && effectiveStyle.texture == TextureStyle.paper;

  /// 页面是否铺独立背景（用户背景图或纸张纹理），表面类颜色需要透出
  bool get hasPageBackground => isTransparentActive || isPaperTextureActive;

  /// 当前生效的圆角风格：用户指定优先，否则取主题推荐
  ShapePreset get effectiveShapePreset => shapeOverride ?? themeSpec.shape;

  /// 当前生效的形状 token
  UiShapes get effectiveShapes => effectiveShapePreset.shapes;

  /// [spec] 所在主题族记忆的强调色选择（null = 主题默认）
  String? accentFor(ThemeSpec spec) => themeAccents[spec.familyId];

  /// 当前生效的种子色（色卡预览、主题合成、预热等场景使用）
  Color get effectiveSeedColor => switch (accentSource) {
    AccentSource.dynamic => dynamicPrimary ?? seedColor,
    AccentSource.palette => AppPalettes.byId(paletteId).seedColor,
    AccentSource.custom => seedColor,
  };

  static String? _resolveFont(String choice, String? suggestion) =>
      switch (choice) {
        FontChoice.follow => suggestion,
        FontChoice.system => null,
        _ => choice,
      };

  /// 当前生效的正文字体 id（null = 系统字体）
  String? get effectiveBodyFontId =>
      _resolveFont(bodyFont, themeSpec.fontBody);

  /// 当前生效的等宽字体 id（null = 系统等宽）
  String? get effectiveMonoFontId =>
      _resolveFont(monoFont, themeSpec.fontMono);

  /// 实际用于 ThemeData 的 fontFamily：选中的字体已下载并注册时才生效，
  /// 否则回退系统字体
  String? get fontFamilyName {
    final id = effectiveBodyFontId;
    if (id == null || !loadedFonts.contains(id)) return null;
    return FontCatalog.byId(id)?.family;
  }

  ThemeState copyWith({
    ThemeMode? mode,
    String? themeId,
    Map<String, String>? themeAccents,
    ShapePreset? Function()? shapeOverride,
    bool? blackEnabled,
    bool? transparentEnabled,
    AccentSource? accentSource,
    String? paletteId,
    Color? seedColor,
    DynamicSchemeVariant? schemeVariant,
    List<Color>? customColors,
    Color? dynamicPrimary,
    String? bodyFont,
    String? monoFont,
    Set<String>? loadedFonts,
    bool? festivalEnabled,
    bool? festivalGreetingEnabled,
    Set<String>? festivalSkipped,
    FestivalOccurrence? Function()? festival,
    List<ThemeSpec>? customThemes,
    bool? m3eEnabled,
    AppBackground? background,
  }) {
    return ThemeState(
      mode: mode ?? this.mode,
      themeId: themeId ?? this.themeId,
      themeAccents: themeAccents ?? this.themeAccents,
      shapeOverride: shapeOverride != null
          ? shapeOverride()
          : this.shapeOverride,
      blackEnabled: blackEnabled ?? this.blackEnabled,
      transparentEnabled: transparentEnabled ?? this.transparentEnabled,
      accentSource: accentSource ?? this.accentSource,
      paletteId: paletteId ?? this.paletteId,
      seedColor: seedColor ?? this.seedColor,
      schemeVariant: schemeVariant ?? this.schemeVariant,
      customColors: customColors ?? this.customColors,
      dynamicPrimary: dynamicPrimary ?? this.dynamicPrimary,
      bodyFont: bodyFont ?? this.bodyFont,
      monoFont: monoFont ?? this.monoFont,
      loadedFonts: loadedFonts ?? this.loadedFonts,
      festivalEnabled: festivalEnabled ?? this.festivalEnabled,
      festivalGreetingEnabled:
          festivalGreetingEnabled ?? this.festivalGreetingEnabled,
      festivalSkipped: festivalSkipped ?? this.festivalSkipped,
      festival: festival != null ? festival() : this.festival,
      customThemes: customThemes ?? this.customThemes,
      m3eEnabled: m3eEnabled ?? this.m3eEnabled,
      background: background ?? this.background,
    );
  }
}

/// App Theme Notifier
class ThemeNotifier extends StateNotifier<ThemeState> {
  static const String _themeModeKey = 'theme_mode';
  static const String _themeIdKey = 'theme_id';
  static const String _themeAccentsKey = 'theme_accents';
  static const String _shapePresetKey = 'shape_preset';
  static const String _blackKey = 'theme_black';
  static const String _transparentKey = 'theme_transparent';
  static const String _accentSourceKey = 'accent_source';
  static const String _paletteIdKey = 'palette_id';
  static const String _seedColorKey = 'seed_color';
  static const String _schemeVariantKey = 'scheme_variant';
  static const String _customColorsKey = 'custom_colors';
  static const String _fontBodyKey = 'font_body';
  static const String _festivalEnabledKey = 'festival_enabled';
  static const String _festivalGreetingKey = 'festival_greeting';
  static const String _festivalSkippedKey = 'festival_skipped';
  static const String _fontMonoKey = 'font_mono';
  static const String _m3eEnabledKey = 'm3e_enabled';
  static const String _bgImagePathKey = 'bg_image_path';
  static const String _bgScrimLightKey = 'bg_scrim_light';
  static const String _bgScrimDarkKey = 'bg_scrim_dark';
  static const String _bgBlurKey = 'bg_blur';

  // 旧版键：只读迁移，不再写入
  static const String _legacyDynamicColorKey = 'use_dynamic_color';
  static const String _legacyNeutralKey = 'theme_neutral';

  /// 旧版字体键：只有「system / miSans」二选一（MiSans 曾随安装包内置）
  static const String legacyFontFamilyKey = 'font_family';

  final SharedPreferences _prefs;

  ThemeNotifier(this._prefs) : super(_loadTheme(_prefs)) {
    // 启动时对齐一次：覆盖升级等未经设置页切换的情况
    LaunchSplashHandoff.syncNightMode(state.mode);
    _fontInstalledSub = FontDownloadService.instance.onInstalled.listen(
      (_) => syncFonts(),
    );
    unawaited(syncFonts());
  }

  StreamSubscription<FontEntry>? _fontInstalledSub;
  AppLifecycleListener? _lifecycle;
  Timer? _midnightTimer;

  /// 启动节日窗口的自动判定：回到前台与跨过零点时重新判定。由应用启动
  /// 流程调用（不放在构造里：测试里的通知器不应常驻计时器）。
  void startFestivalClock() {
    if (_lifecycle != null) return;
    _lifecycle = AppLifecycleListener(onResume: refreshFestival);
    refreshFestival();
    _scheduleMidnight();
  }

  void _scheduleMidnight() {
    _midnightTimer?.cancel();
    final now = FestivalCalendar.clock();
    _midnightTimer = Timer(
      FestivalCalendar.nextMidnight(now).difference(now) +
          const Duration(seconds: 1),
      () {
        refreshFestival();
        _scheduleMidnight();
      },
    );
  }

  /// 按当前日期重新判定节日窗口。
  void refreshFestival() {
    if (!mounted) return;
    final festival = FestivalCalendar.activeOn(FestivalCalendar.clock());
    if (festival != state.festival) {
      state = state.copyWith(festival: () => festival);
    }
  }

  Future<void> setFestivalEnabled(bool value) async {
    state = state.copyWith(festivalEnabled: value);
    await _prefs.setBool(_festivalEnabledKey, value);
  }

  Future<void> setFestivalGreetingEnabled(bool value) async {
    state = state.copyWith(festivalGreetingEnabled: value);
    await _prefs.setBool(_festivalGreetingKey, value);
  }

  /// 保存（新增或按 id 覆盖）自定义主题。
  Future<void> saveCustomTheme(ThemeSpec spec) async {
    final list = [...state.customThemes];
    final index = list.indexWhere((s) => s.id == spec.id);
    if (index >= 0) {
      list[index] = spec;
    } else {
      list.add(spec);
    }
    await _setCustomThemes(list);
  }

  /// 删除自定义主题；正在使用时回退 Material。
  Future<void> deleteCustomTheme(String id) async {
    final list = state.customThemes.where((s) => s.id != id).toList();
    await _setCustomThemes(list);
    if (state.themeId == id) await setThemeId(ThemeRegistry.materialId);
    if (state.themeAccents.containsKey(id)) {
      final accents = {...state.themeAccents}..remove(id);
      state = state.copyWith(themeAccents: accents);
      await _prefs.setString(_themeAccentsKey, jsonEncode(accents));
    }
  }

  /// 从主题代码导入并保存，返回导入的主题。格式不合法抛 FormatException。
  Future<ThemeSpec> importCustomTheme(String code) async {
    final spec = CustomThemes.importFrom(
      code,
      existingIds: {for (final s in ThemeRegistry.all) s.id},
    );
    await saveCustomTheme(spec);
    return spec;
  }

  Future<void> _setCustomThemes(List<ThemeSpec> list) async {
    ThemeRegistry.setCustom(list);
    state = state.copyWith(customThemes: List.unmodifiable(list));
    await _prefs.setString(CustomThemes.prefsKey, CustomThemes.encode(list));
  }

  /// 本次节日不再使用节日配色（窗口结束后自然失效）。
  Future<void> skipCurrentFestival() async {
    final f = state.festival;
    if (f == null) return;
    // 只保留最近若干条，避免无限增长
    final skipped = [...state.festivalSkipped, f.key];
    final kept = skipped.length > 20
        ? skipped.sublist(skipped.length - 20)
        : skipped;
    state = state.copyWith(festivalSkipped: kept.toSet());
    await _prefs.setStringList(_festivalSkippedKey, kept);
  }

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

    // ── 自定义主题：先注册，主题 id 才能解析到它们 ──
    final customThemes = CustomThemes.decode(
      prefs.getString(CustomThemes.prefsKey),
    );
    ThemeRegistry.setCustom(customThemes);

    // ── 主题：新键优先，缺省时从旧的中性开关迁移（开 = 简约） ──
    final themeId =
        prefs.getString(_themeIdKey) ??
        ((prefs.getBool(_legacyNeutralKey) ?? false)
            ? ThemeRegistry.minimalId
            : ThemeRegistry.materialId);

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

    // ── 字体：新键优先，缺省时从旧版二选一迁移 ──
    final bodyFont =
        prefs.getString(_fontBodyKey) ??
        switch (prefs.getString(legacyFontFamilyKey)) {
          'miSans' => 'misans',
          'system' => FontChoice.system,
          _ => FontChoice.follow,
        };
    final monoFont = prefs.getString(_fontMonoKey) ?? FontChoice.follow;

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
      themeId: themeId,
      themeAccents: _decodeAccents(prefs.getString(_themeAccentsKey)),
      shapeOverride: ShapePreset.values.asNameMap()[prefs.getString(
        _shapePresetKey,
      )],
      blackEnabled: prefs.getBool(_blackKey) ?? false,
      transparentEnabled: prefs.getBool(_transparentKey) ?? false,
      accentSource: accentSource,
      paletteId: paletteId,
      seedColor: seedColor,
      schemeVariant: schemeVariant,
      customColors: customColors,
      bodyFont: bodyFont,
      monoFont: monoFont,
      loadedFonts: {
        for (final font in FontCatalog.all)
          if (FontDownloadService.instance.isRegistered(font)) font.id,
      },
      festivalEnabled: prefs.getBool(_festivalEnabledKey) ?? true,
      festivalGreetingEnabled: prefs.getBool(_festivalGreetingKey) ?? true,
      festivalSkipped: {...?prefs.getStringList(_festivalSkippedKey)},
      festival: FestivalCalendar.activeOn(FestivalCalendar.clock()),
      customThemes: customThemes,
      m3eEnabled: prefs.getBool(_m3eEnabledKey) ?? true,
      background: background,
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(mode: mode);
    LaunchSplashHandoff.syncNightMode(mode);
    String value = 'system';
    if (mode == ThemeMode.light) {
      value = 'light';
    } else if (mode == ThemeMode.dark) {
      value = 'dark';
    }
    await _prefs.setString(_themeModeKey, value);
  }

  static Map<String, String> _decodeAccents(String? raw) {
    if (raw == null) return const {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return {for (final e in map.entries) e.key: e.value as String};
    } catch (_) {
      return const {};
    }
  }

  /// 为主题族 [familyId] 选择强调色（主题自带 id 或 `#RRGGBB`）。
  Future<void> setThemeAccent(String familyId, String selection) async {
    final accents = {...state.themeAccents, familyId: selection};
    state = state.copyWith(themeAccents: accents);
    await _prefs.setString(_themeAccentsKey, jsonEncode(accents));
  }

  /// 指定圆角风格，null 表示跟随主题推荐。
  Future<void> setShapeOverride(ShapePreset? preset) async {
    state = state.copyWith(shapeOverride: () => preset);
    if (preset == null) {
      await _prefs.remove(_shapePresetKey);
    } else {
      await _prefs.setString(_shapePresetKey, preset.name);
    }
  }

  Future<void> setThemeId(String themeId) async {
    // 节日期间手动换主题：本次节日不再抢用户的设置
    if (state.activeFestival != null) await skipCurrentFestival();
    state = state.copyWith(themeId: themeId);
    await _prefs.setString(_themeIdKey, themeId);
    // 「跟随主题」的字体随主题变化
    await syncFonts();
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

  /// 把自定义色 [from] 改成 [to]（保持位置）；正在使用 [from] 时一起切换。
  Future<void> replaceCustomColor(Color from, Color to) async {
    final newColors = [
      for (final c in state.customColors)
        c.toARGB32() == from.toARGB32() ? to : c,
    ];
    state = state.copyWith(customColors: newColors);
    await _saveCustomColors(newColors);
    if (state.accentSource == AccentSource.custom &&
        state.seedColor.toARGB32() == from.toARGB32()) {
      await selectCustomColor(to);
    }
  }

  /// 主题、强调色、配色风格与圆角恢复默认。自定义色与自定义主题是用户
  /// 创建的内容，保留不删。
  Future<void> resetThemeLook() async {
    state = state.copyWith(
      themeId: ThemeRegistry.materialId,
      accentSource: AccentSource.palette,
      paletteId: AppPalettes.defaultId,
      schemeVariant: DynamicSchemeVariant.tonalSpot,
      shapeOverride: () => null,
      themeAccents: const {},
    );
    for (final key in [
      _themeIdKey,
      _accentSourceKey,
      _paletteIdKey,
      _schemeVariantKey,
      _shapePresetKey,
      _themeAccentsKey,
    ]) {
      await _prefs.remove(key);
    }
    await syncFonts();
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

  Future<void> setBodyFont(String choice) async {
    state = state.copyWith(bodyFont: choice);
    await _prefs.setString(_fontBodyKey, choice);
    await syncFonts();
  }

  Future<void> setMonoFont(String choice) async {
    state = state.copyWith(monoFont: choice);
    await _prefs.setString(_fontMonoKey, choice);
    await syncFonts();
  }

  /// 把当前生效、已下载的字体注册给引擎并刷新主题（下载完成、切换主题
  /// 或字体选择时调用）。
  Future<void> syncFonts() async {
    final loaded = {...state.loadedFonts};
    final wanted = {state.effectiveBodyFontId, state.effectiveMonoFontId};
    for (final id in wanted.nonNulls) {
      final entry = FontCatalog.byId(id);
      if (entry == null || loaded.contains(id)) continue;
      if (await FontDownloadService.instance.register(entry)) loaded.add(id);
    }
    if (mounted && loaded.length != state.loadedFonts.length) {
      state = state.copyWith(loadedFonts: loaded);
    }
  }

  /// 冷启动在 runApp 前注册已选字体，避免首帧先用系统字体再切换。
  static Future<void> preloadFonts(SharedPreferences prefs) async {
    final state = _loadTheme(prefs);
    final watch = Stopwatch()..start();
    for (final id in {
      state.effectiveBodyFontId,
      state.effectiveMonoFontId,
    }.nonNulls) {
      final entry = FontCatalog.byId(id);
      if (entry != null) await FontDownloadService.instance.register(entry);
    }
    if (watch.elapsedMilliseconds > 0) {
      debugPrint('[Fonts] 启动注册字体耗时 ${watch.elapsedMilliseconds}ms');
    }
  }

  @override
  void dispose() {
    _fontInstalledSub?.cancel();
    _lifecycle?.dispose();
    _midnightTimer?.cancel();
    super.dispose();
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
