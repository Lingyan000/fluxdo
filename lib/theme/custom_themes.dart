import 'dart:convert';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import 'app_colors.dart';
import 'theme_resolver.dart';
import 'theme_spec.dart';

/// 用户自定义主题的存取、底稿生成与导入导出。
///
/// 自定义主题与内置主题同一格式（[ThemeSpec] JSON），存在偏好设置里，
/// 随应用数据一起备份；导出的「主题代码」就是这份 JSON。
class CustomThemes {
  CustomThemes._();

  static const String prefsKey = 'custom_themes';

  /// 解码已保存的主题；单个条目损坏只跳过它。
  static List<ThemeSpec> decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      final specs = <ThemeSpec>[];
      for (final item in list) {
        try {
          specs.add(ThemeSpec.fromJson(item as Map<String, dynamic>));
        } catch (e) {
          debugPrint('[CustomThemes] 跳过损坏的自定义主题: $e');
        }
      }
      return specs;
    } catch (e) {
      debugPrint('[CustomThemes] 自定义主题数据损坏: $e');
      return const [];
    }
  }

  static String encode(List<ThemeSpec> specs) =>
      jsonEncode([for (final s in specs) s.toJson()]);

  static String newId() => 'custom-${DateTime.now().microsecondsSinceEpoch}';

  /// 以 [base] 为底稿生成一份自定义主题（未保存）。
  ///
  /// 固定配色主题直接复制配色；生成式主题（Material / 简约）没有关键色，
  /// 从当前解析结果 [resolved] 里取：表面 / 文字 / 分割线、语义色相，
  /// 以及主色、第三色作为强调色。圆角与界面风格都沿用底稿。
  static ThemeSpec draftFrom(
    ThemeSpec base, {
    required String name,
    required ResolvedTheme resolved,
  }) {
    if (!base.isGenerated) {
      return base.copyWith(
        id: newId(),
        name: {'zh': name, 'en': name},
        group: ThemeGroup.custom,
        clearFamily: true,
      );
    }
    ThemePalette palette(Brightness b) {
      final scheme = b == Brightness.light ? resolved.light : resolved.dark;
      final colors = b == Brightness.light
          ? resolved.lightColors
          : resolved.darkColors;
      return ThemePalette(
        bg: scheme.surface,
        fg: scheme.onSurface,
        fgMuted: scheme.onSurfaceVariant,
        border: scheme.outlineVariant,
        hues: {
          for (final hue in AppHue.basics) hue: colors.hues[hue]!.shade500,
        },
      );
    }

    return ThemeSpec(
      id: newId(),
      kind: ThemeColorKind.fixed,
      name: {'zh': name, 'en': name},
      group: ThemeGroup.custom,
      shape: base.shape,
      style: base.style,
      light: palette(Brightness.light),
      dark: palette(Brightness.dark),
      accents: [
        ThemeAccent(
          id: 'primary',
          light: resolved.light.primary,
          dark: resolved.dark.primary,
        ),
        ThemeAccent(
          id: 'tertiary',
          light: resolved.light.tertiary,
          dark: resolved.dark.tertiary,
        ),
      ],
      allowCustomAccent: true,
      supportsPureBlack: true,
    );
  }

  /// 从主题代码导入：补全省略的部分（见 [_complete]）后完整校验，强制
  /// 归入「我的主题」，id 与已有主题冲突时换新。格式不合法抛
  /// [FormatException]。
  static ThemeSpec importFrom(String raw, {required Set<String> existingIds}) {
    final Object? json;
    try {
      json = jsonDecode(raw.trim());
    } catch (_) {
      throw const FormatException('不是有效的主题代码');
    }
    if (json is! Map<String, dynamic>) {
      throw const FormatException('不是有效的主题代码');
    }
    final spec = ThemeSpec.fromJson(_complete(json));
    if (spec.isGenerated) {
      throw const FormatException('只能导入固定配色主题');
    }
    return spec.copyWith(
      id: existingIds.contains(spec.id) || !spec.id.startsWith('custom-')
          ? newId()
          : spec.id,
      group: ThemeGroup.custom,
      clearFamily: true,
    );
  }

  /// 补全主题代码里省略的部分，方便手写或从别处的配色换算：
  /// - `id`、`kind` 可省略；
  /// - 每一侧只有 `bg`、`fg` 必填：`fgMuted`、`border` 缺省由两者混合得出，
  ///   `hues` 里缺省的色相取默认语义色；
  /// - 强调色可以只写一个颜色，或只给一侧（两侧共用，显示时按各自背景
  ///   补足对比度）。
  ///
  /// `group` 直接丢弃：导入后一律归入「我的主题」，旧版本导出的分组名
  /// 改过也不影响导入。写了的其他字段原样交给 [ThemeSpec.fromJson] 严格
  /// 校验，不替用户纠错。
  static Map<String, dynamic> _complete(Map<String, dynamic> json) {
    Object? palette(Object? raw, Brightness brightness) {
      if (raw is! Map<String, dynamic>) return raw;
      final bg = ThemeSpecColor.tryParse(raw['bg']);
      final fg = ThemeSpecColor.tryParse(raw['fg']);
      final hues = raw['hues'];
      if (bg == null || fg == null || (hues != null && hues is! Map)) {
        return raw;
      }
      final defaults = AppColors.material(brightness).hues;
      return {
        ...raw,
        if (raw['fgMuted'] == null)
          'fgMuted': ThemeSpecColor.format(Color.lerp(fg, bg, 0.35)!),
        if (raw['border'] == null)
          'border': ThemeSpecColor.format(Color.lerp(bg, fg, 0.12)!),
        'hues': {
          for (final hue in AppHue.basics)
            hue.name: ThemeSpecColor.format(defaults[hue]!.shade500),
          ...?(hues as Map?),
        },
      };
    }

    Object? accents(Object? raw) {
      if (raw is! List) return raw;
      return [
        for (final (i, accent) in raw.indexed)
          if (accent is String)
            {'id': 'a$i', 'light': accent, 'dark': accent}
          else if (accent is Map<String, dynamic>)
            {
              'id': 'a$i',
              ...accent,
              'light': accent['light'] ?? accent['dark'],
              'dark': accent['dark'] ?? accent['light'],
            }
          else
            accent,
      ];
    }

    return {
      'id': newId(),
      'kind': ThemeColorKind.fixed.name,
      ...json,
      'light': palette(json['light'], Brightness.light),
      'dark': palette(json['dark'], Brightness.dark),
      'accents': accents(json['accents']),
    }..remove('group');
  }

  /// 导出为主题代码（格式化 JSON，便于分享与手改）。
  static String export(ThemeSpec spec) =>
      const JsonEncoder.withIndent('  ').convert(spec.toJson());
}
