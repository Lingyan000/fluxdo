import 'dart:convert';

// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers/theme_provider.dart';
import '../../services/fonts/font_catalog.dart';

/// 纯净阅读模式的亮色纸张底色方案（深色模式下统一跟随应用深色主题）。
enum ReaderPaperTheme {
  /// 跟随当前应用主题与页面背景
  followTheme,

  /// 暖色纸张质感（叠加程序化纸纹）
  paper,

  /// 柔和护眼绿
  green;

  static ReaderPaperTheme fromString(String? value) {
    return ReaderPaperTheme.values.firstWhere(
      (e) => e.name == value,
      orElse: () => ReaderPaperTheme.followTheme,
    );
  }
}

/// 纯净阅读模式的行距档位。
enum ReaderLineSpacing {
  compact(1.6),
  normal(1.76),
  relaxed(2.0);

  const ReaderLineSpacing(this.height);

  final double height;

  static ReaderLineSpacing fromString(String? value) {
    return ReaderLineSpacing.values.firstWhere(
      (e) => e.name == value,
      orElse: () => ReaderLineSpacing.normal,
    );
  }
}

/// 纯净阅读模式的字重档位。
enum ReaderFontWeight {
  normal(FontWeight.w400),
  medium(FontWeight.w500),
  semiBold(FontWeight.w600);

  const ReaderFontWeight(this.weight);

  final FontWeight weight;

  static ReaderFontWeight fromString(String? value) {
    return ReaderFontWeight.values.firstWhere(
      (e) => e.name == value,
      orElse: () => ReaderFontWeight.normal,
    );
  }
}

/// 亮色纸张配色解析产物。
@immutable
class ReaderPalette {
  const ReaderPalette({
    required this.background,
    required this.surface,
    required this.ink,
    required this.mutedInk,
    required this.outline,
    required this.usePaperTexture,
    required this.isCustomLight,
  });

  final Color background;
  final Color surface;
  final Color ink;
  final Color mutedInk;
  final Color outline;
  final bool usePaperTexture;
  final bool isCustomLight;

  static ReaderPalette resolve(
    ThemeData theme,
    ReaderPaperTheme paperTheme,
  ) {
    final scheme = theme.colorScheme;
    // 深色模式下始终遵循深色主题，避免高亮度底色刺眼。
    if (theme.brightness == Brightness.dark ||
        paperTheme == ReaderPaperTheme.followTheme) {
      return ReaderPalette(
        background: scheme.surface,
        surface: scheme.surfaceContainerLow,
        ink: scheme.onSurface,
        mutedInk: scheme.onSurfaceVariant,
        outline: scheme.outlineVariant,
        usePaperTexture: false,
        isCustomLight: false,
      );
    }

    return switch (paperTheme) {
      ReaderPaperTheme.paper => const ReaderPalette(
        background: Color(0xFFF5EFE4),
        surface: Color(0xFFEBE2D2),
        ink: Color(0xFF2E261C),
        mutedInk: Color(0xFF736759),
        outline: Color(0xFFD6CBB8),
        usePaperTexture: true,
        isCustomLight: true,
      ),
      ReaderPaperTheme.green => const ReaderPalette(
        background: Color(0xFFEBF3EA),
        surface: Color(0xFFDFEBDE),
        ink: Color(0xFF223024),
        mutedInk: Color(0xFF5F7062),
        outline: Color(0xFFC8DAC6),
        usePaperTexture: false,
        isCustomLight: true,
      ),
      ReaderPaperTheme.followTheme => ReaderPalette(
        background: scheme.surface,
        surface: scheme.surfaceContainerLow,
        ink: scheme.onSurface,
        mutedInk: scheme.onSurfaceVariant,
        outline: scheme.outlineVariant,
        usePaperTexture: false,
        isCustomLight: false,
      ),
    };
  }

  /// 纸张色块预览的亮色样例背景。
  static Color previewColorOf(ReaderPaperTheme paperTheme, ColorScheme scheme) {
    return switch (paperTheme) {
      ReaderPaperTheme.followTheme => scheme.surface,
      ReaderPaperTheme.paper => const Color(0xFFF5EFE4),
      ReaderPaperTheme.green => const Color(0xFFEBF3EA),
    };
  }
}

/// 纯净阅读模式排版偏好。
@immutable
class ReaderPreferences {
  const ReaderPreferences({
    this.fontSize = 17.0,
    this.lineSpacing = ReaderLineSpacing.normal,
    this.fontWeight = ReaderFontWeight.normal,
    this.fontChoice = FontChoice.follow,
    this.paperTheme = ReaderPaperTheme.followTheme,
  });

  /// 离散字号档位：界面可见项与实际生效字号严格一一对应。
  static const List<double> fontSizeStops = [15.0, 17.0, 19.0, 21.0];

  final double fontSize;
  final ReaderLineSpacing lineSpacing;
  final ReaderFontWeight fontWeight;

  /// 正文字体选择：复用应用字体体系（[FontChoice.follow] / [FontChoice.system] / [FontCatalog] id）。
  final String fontChoice;
  final ReaderPaperTheme paperTheme;

  static double snapFontSize(double size) {
    var best = fontSizeStops.first;
    var minDiff = (size - best).abs();
    for (final stop in fontSizeStops) {
      final diff = (size - stop).abs();
      if (diff < minDiff) {
        best = stop;
        minDiff = diff;
      }
    }
    return best;
  }

  /// 解析当前应覆盖的字体名。
  ///
  /// - `FontChoice.follow`：返回 null，沿用应用当前主题正文字体；
  /// - `FontChoice.system`：返回平台原生系统字体名，绕过应用自定义正文字体；
  /// - 字体目录 id：已注册到引擎时返回其 `family`，未就绪时暂沿用当前字体。
  String? resolveOverrideFontFamily({
    required Set<String> loadedFonts,
    required TargetPlatform platform,
  }) {
    return switch (fontChoice) {
      FontChoice.follow => null,
      FontChoice.system =>
        Typography.material2021(platform: platform).black.bodyMedium?.fontFamily ??
            '',
      final id => loadedFonts.contains(id) ? FontCatalog.byId(id)?.family : null,
    };
  }

  /// 解析正文排版样式。
  TextStyle resolveBodyStyle(
    TextStyle? base,
    Color inkColor, {
    required Set<String> loadedFonts,
    required TargetPlatform platform,
  }) {
    final overrideFamily = resolveOverrideFontFamily(
      loadedFonts: loadedFonts,
      platform: platform,
    );
    final style = (base ?? const TextStyle()).copyWith(
      fontSize: fontSize,
      height: lineSpacing.height,
      fontWeight: fontWeight.weight,
      color: inkColor,
    );
    if (overrideFamily == null) return style;
    return style.copyWith(fontFamily: overrideFamily);
  }

  /// 同步标题字体样式。
  TextStyle resolveHeadingStyle(
    TextStyle? base,
    Color inkColor, {
    required Set<String> loadedFonts,
    required TargetPlatform platform,
  }) {
    final overrideFamily = resolveOverrideFontFamily(
      loadedFonts: loadedFonts,
      platform: platform,
    );
    final style = (base ?? const TextStyle()).copyWith(color: inkColor);
    if (overrideFamily == null) return style;
    return style.copyWith(fontFamily: overrideFamily);
  }

  ReaderPreferences copyWith({
    double? fontSize,
    ReaderLineSpacing? lineSpacing,
    ReaderFontWeight? fontWeight,
    String? fontChoice,
    ReaderPaperTheme? paperTheme,
  }) {
    return ReaderPreferences(
      fontSize: fontSize ?? this.fontSize,
      lineSpacing: lineSpacing ?? this.lineSpacing,
      fontWeight: fontWeight ?? this.fontWeight,
      fontChoice: fontChoice ?? this.fontChoice,
      paperTheme: paperTheme ?? this.paperTheme,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ReaderPreferences &&
            fontSize == other.fontSize &&
            lineSpacing == other.lineSpacing &&
            fontWeight == other.fontWeight &&
            fontChoice == other.fontChoice &&
            paperTheme == other.paperTheme;
  }

  @override
  int get hashCode => Object.hash(
    fontSize,
    lineSpacing,
    fontWeight,
    fontChoice,
    paperTheme,
  );
}

class ReaderPreferencesNotifier extends StateNotifier<ReaderPreferences> {
  ReaderPreferencesNotifier(this._prefs) : super(_load(_prefs));

  static const _kFontSize = 'reader_font_size';
  static const _kLineSpacing = 'reader_line_spacing';
  static const _kFontWeight = 'reader_font_weight';
  static const _kFontChoice = 'reader_font_choice';
  static const _kPaperTheme = 'reader_paper_theme';

  final SharedPreferences? _prefs;

  static ReaderPreferences _load(SharedPreferences? prefs) {
    if (prefs == null) return const ReaderPreferences();
    final rawFontSize = prefs.getDouble(_kFontSize);
    final fontSize = rawFontSize == null
        ? 17.0
        : ReaderPreferences.snapFontSize(rawFontSize);
    final rawFont = prefs.getString(_kFontChoice);
    final fontChoice =
        (rawFont == null ||
            rawFont.isEmpty ||
            (rawFont != FontChoice.follow &&
                rawFont != FontChoice.system &&
                FontCatalog.byId(rawFont) == null))
        ? FontChoice.follow
        : rawFont;
    return ReaderPreferences(
      fontSize: fontSize,
      lineSpacing: ReaderLineSpacing.fromString(prefs.getString(_kLineSpacing)),
      fontWeight: ReaderFontWeight.fromString(prefs.getString(_kFontWeight)),
      fontChoice: fontChoice,
      paperTheme: ReaderPaperTheme.fromString(prefs.getString(_kPaperTheme)),
    );
  }

  void setFontSize(double size) {
    final snapped = ReaderPreferences.snapFontSize(size);
    if (snapped == state.fontSize) return;
    state = state.copyWith(fontSize: snapped);
    _prefs?.setDouble(_kFontSize, snapped);
  }

  void setLineSpacing(ReaderLineSpacing spacing) {
    if (spacing == state.lineSpacing) return;
    state = state.copyWith(lineSpacing: spacing);
    _prefs?.setString(_kLineSpacing, spacing.name);
  }

  void setFontWeight(ReaderFontWeight weight) {
    if (weight == state.fontWeight) return;
    state = state.copyWith(fontWeight: weight);
    _prefs?.setString(_kFontWeight, weight.name);
  }

  void setFontChoice(String choice) {
    if (choice == state.fontChoice) return;
    state = state.copyWith(fontChoice: choice);
    _prefs?.setString(_kFontChoice, choice);
  }

  void setPaperTheme(ReaderPaperTheme paperTheme) {
    if (paperTheme == state.paperTheme) return;
    state = state.copyWith(paperTheme: paperTheme);
    _prefs?.setString(_kPaperTheme, paperTheme.name);
  }

  void reset() {
    state = const ReaderPreferences();
    _prefs?.remove(_kFontSize);
    _prefs?.remove(_kLineSpacing);
    _prefs?.remove(_kFontWeight);
    _prefs?.remove(_kFontChoice);
    _prefs?.remove(_kPaperTheme);
  }
}

final readerPreferencesProvider =
    StateNotifierProvider<ReaderPreferencesNotifier, ReaderPreferences>((ref) {
      SharedPreferences? prefs;
      try {
        prefs = ref.watch(sharedPreferencesProvider);
      } catch (_) {
        prefs = null;
      }
      return ReaderPreferencesNotifier(prefs);
    });

/// 单篇话题在首贴纯净阅读模式下的阅读位置记录。
@immutable
class ReaderPosition {
  const ReaderPosition({
    required this.itemKey,
    required this.progress,
    required this.updatedAtMs,
  });

  final String itemKey;
  final double progress;
  final int updatedAtMs;

  Map<String, dynamic> toJson() => {
    'k': itemKey,
    'r': double.parse(progress.clamp(0.0, 1.0).toStringAsFixed(4)),
    't': updatedAtMs,
  };

  static ReaderPosition? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final k = raw['k'];
    final r = raw['r'];
    final t = raw['t'];
    if (k is! String || k.isEmpty) return null;
    return ReaderPosition(
      itemKey: k,
      progress: r is num ? r.toDouble().clamp(0.0, 1.0) : 0.0,
      updatedAtMs: t is num ? t.toInt() : 0,
    );
  }
}

/// 按话题维度持久化首贴阅读位置（按最近访问时间保留上限条数）。
class ReaderPositionStore {
  ReaderPositionStore(this._prefs);

  static const _storageKey = 'reader_positions_v1';
  static const _maxEntries = 60;

  final SharedPreferences? _prefs;

  ReaderPosition? read(int topicId) {
    final map = _readAll();
    return map[topicId.toString()];
  }

  Future<void> write(int topicId, ReaderPosition position) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final map = _readAll();
    map[topicId.toString()] = position;
    if (map.length > _maxEntries) {
      final sorted = map.entries.toList()
        ..sort((a, b) => b.value.updatedAtMs.compareTo(a.value.updatedAtMs));
      map
        ..clear()
        ..addEntries(sorted.take(_maxEntries));
    }
    final encoded = jsonEncode({
      for (final entry in map.entries) entry.key: entry.value.toJson(),
    });
    await prefs.setString(_storageKey, encoded);
  }

  Map<String, ReaderPosition> _readAll() {
    final raw = _prefs?.getString(_storageKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, ReaderPosition>{};
      for (final entry in decoded.entries) {
        final pos = ReaderPosition.fromJson(entry.value);
        if (pos != null) {
          result[entry.key.toString()] = pos;
        }
      }
      return result;
    } catch (_) {
      return {};
    }
  }
}
