import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'color_scheme_roles.dart';

/// 主题配色的生成方式。
enum ThemeColorKind {
  /// 由种子色生成（Material / 简约）：强调色来自调色板、动态色或自定义色。
  generated,

  /// 固定配色（Catppuccin、纸质、终端……）：表面色写死在主题里，
  /// 强调色从主题自带的列表里选。
  fixed,
}

/// 主题在画廊中的分组。
enum ThemeGroup {
  /// 取色（Material / 简约）
  generated,

  /// 经典配色（Catppuccin、Nord……）
  classic,

  /// 阅读（纸质、豆沙绿）
  reading,

  /// 终端
  terminal,

  /// 用户自定义 / 导入
  custom,

  /// 节日（不出现在画廊）
  festival,
}

/// 生成式主题的表面策略。
enum GeneratedSurface {
  /// 表面随种子色染色（完整 fromSeed），即一直以来的默认外观。
  tinted,

  /// 无色相中性灰表面（原"中性"开关）。
  neutral,
}

/// 固定配色主题一侧亮度的关键色。
///
/// 只需给出少数关键色，完整的中性 role 阶梯由 NeutralRamp.derive 推导；
/// 推导结果不满意时可用 [roles] 按 ColorScheme 的 role 名逐个覆盖。
class ThemePalette {
  const ThemePalette({
    required this.bg,
    required this.fg,
    required this.fgMuted,
    required this.border,
    required this.hues,
    this.outline,
    this.error,
    this.roles = const {},
  });

  /// 页面背景（surface）。
  final Color bg;

  /// 正文文字（onSurface）。
  final Color fg;

  /// 次要文字（onSurfaceVariant）。
  final Color fgMuted;

  /// 分割线、弱描边（outlineVariant）。
  final Color border;

  /// 色相表：至少包含 [AppHue.basics]（红橙黄绿青蓝紫），可选
  /// [AppHue.optionals]。语义色、callout、代码高亮都从这里取色。
  final Map<AppHue, Color> hues;

  /// 强描边（outline），缺省由 fgMuted 与 bg 混合推导。
  final Color? outline;

  /// 错误色，缺省用 M3 基线错误色。
  final Color? error;

  /// 按 ColorScheme role 名覆盖推导结果，如 `surfaceContainerHigh`。
  final Map<String, Color> roles;

  factory ThemePalette.fromJson(Map<String, dynamic> json) {
    final rolesJson = json['roles'];
    final roles = rolesJson is Map
        ? {
            for (final e in rolesJson.entries)
              e.key as String: ThemeSpecColor.parse(e.value),
          }
        : const <String, Color>{};
    final unknown = ColorSchemeRoles.unknownKeys(roles);
    if (unknown.isNotEmpty) {
      throw FormatException('未知的 ColorScheme role: ${unknown.join(', ')}');
    }
    final huesJson = json['hues'];
    if (huesJson is! Map) throw const FormatException('缺少色相表 hues');
    const allowed = [...AppHue.basics, ...AppHue.optionals];
    final byName = {for (final h in allowed) h.name: h};
    final hues = <AppHue, Color>{};
    for (final e in huesJson.entries) {
      final hue = byName[e.key];
      if (hue == null) throw FormatException('未知的色相: ${e.key}');
      hues[hue] = ThemeSpecColor.parse(e.value);
    }
    final missing = AppHue.basics.where((h) => !hues.containsKey(h));
    if (missing.isNotEmpty) {
      throw FormatException('色相表缺少: ${missing.map((h) => h.name).join(', ')}');
    }
    return ThemePalette(
      bg: ThemeSpecColor.parse(json['bg']),
      fg: ThemeSpecColor.parse(json['fg']),
      fgMuted: ThemeSpecColor.parse(json['fgMuted']),
      border: ThemeSpecColor.parse(json['border']),
      hues: hues,
      outline: _optionalColor(json['outline']),
      error: _optionalColor(json['error']),
      roles: roles,
    );
  }

  Map<String, dynamic> toJson() => {
    'bg': ThemeSpecColor.format(bg),
    'fg': ThemeSpecColor.format(fg),
    'fgMuted': ThemeSpecColor.format(fgMuted),
    'border': ThemeSpecColor.format(border),
    'hues': {
      for (final e in hues.entries) e.key.name: ThemeSpecColor.format(e.value),
    },
    if (outline != null) 'outline': ThemeSpecColor.format(outline!),
    if (error != null) 'error': ThemeSpecColor.format(error!),
    if (roles.isNotEmpty)
      'roles': {
        for (final e in roles.entries) e.key: ThemeSpecColor.format(e.value),
      },
  };
}

/// 固定配色主题自带的一个强调色（明暗各一）。
class ThemeAccent {
  const ThemeAccent({
    required this.id,
    required this.light,
    required this.dark,
    this.name = const {},
  });

  /// 稳定标识，用于持久化。
  final String id;

  /// 显示名（按语言代码），缺省显示 [id]。
  final Map<String, String> name;

  final Color light;
  final Color dark;

  Color of(Brightness brightness) =>
      brightness == Brightness.light ? light : dark;

  factory ThemeAccent.fromJson(Map<String, dynamic> json) => ThemeAccent(
    id: json['id'] as String,
    name: _parseName(json['name']),
    light: ThemeSpecColor.parse(json['light']),
    dark: ThemeSpecColor.parse(json['dark']),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    if (name.isNotEmpty) 'name': name,
    'light': ThemeSpecColor.format(light),
    'dark': ThemeSpecColor.format(dark),
  };
}

/// 一个主题的完整描述。
///
/// 内置主题与用户导入主题共用这一格式：固定配色主题以 JSON 资产形式
/// 提供，生成式主题（Material / 简约）只有元信息，配色由种子色算出。
class ThemeSpec {
  const ThemeSpec({
    required this.id,
    required this.kind,
    this.name = const {},
    this.group = ThemeGroup.custom,
    this.family,
    this.variantName = const {},
    this.order = 1000,
    this.surface = GeneratedSurface.tinted,
    this.light,
    this.dark,
    this.accents = const [],
    this.allowCustomAccent = false,
    this.supportsPureBlack = true,
  });

  /// 生成式主题。
  const ThemeSpec.generated({
    required this.id,
    required this.surface,
    this.name = const {},
    this.order = 0,
  }) : kind = ThemeColorKind.generated,
       group = ThemeGroup.generated,
       family = null,
       variantName = const {},
       light = null,
       dark = null,
       accents = const [],
       allowCustomAccent = true,
       supportsPureBlack = true;

  /// 稳定标识，用于持久化（不随语言变化）。
  final String id;

  /// 显示名（按语言代码）。生成式内置主题的名字走 l10n，这里可为空。
  final Map<String, String> name;

  final ThemeColorKind kind;

  /// 画廊分组。
  final ThemeGroup group;

  /// 主题族：同族主题在画廊里合并成一张卡，以 [variantName] 区分
  /// （如 Catppuccin 的 Frappé / Macchiato / Mocha）。强调色选择按族
  /// 记忆。缺省自成一族。
  final String? family;

  /// 族内变体名（按语言代码）。
  final Map<String, String> variantName;

  /// 画廊内排序，小的在前。
  final int order;

  /// 强调色记忆与画廊合并用的族标识。
  String get familyId => family ?? id;

  /// 生成式主题的表面策略（固定配色主题忽略）。
  final GeneratedSurface surface;

  /// 固定配色主题的浅色 / 深色关键色（生成式主题为 null）。
  final ThemePalette? light;
  final ThemePalette? dark;

  /// 固定配色主题自带的强调色，第一个为默认。
  final List<ThemeAccent> accents;

  /// 是否允许在自带强调色之外使用自定义强调色。
  final bool allowCustomAccent;

  /// 是否响应纯黑开关。固定配色主题的深色底往往就是主题特色，
  /// 由主题自己声明。
  final bool supportsPureBlack;

  bool get isGenerated => kind == ThemeColorKind.generated;

  ThemePalette paletteOf(Brightness brightness) =>
      (brightness == Brightness.light ? light : dark)!;

  /// 按 id 取强调色，找不到回退第一个。
  ThemeAccent accentOf(String? accentId) {
    for (final accent in accents) {
      if (accent.id == accentId) return accent;
    }
    return accents.first;
  }

  /// 解析并校验主题 JSON，格式不合法时抛 [FormatException]。
  factory ThemeSpec.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('主题缺少 id');
    }
    final kind = ThemeColorKind.values.asNameMap()[json['kind']];
    if (kind == null) {
      throw FormatException('主题 $id 的 kind 无效: ${json['kind']}');
    }
    final name = _parseName(json['name']);

    if (kind == ThemeColorKind.generated) {
      final surface = GeneratedSurface.values.asNameMap()[json['surface']];
      if (surface == null) {
        throw FormatException('主题 $id 的 surface 无效: ${json['surface']}');
      }
      return ThemeSpec.generated(
        id: id,
        surface: surface,
        name: name,
        order: json['order'] as int? ?? 0,
      );
    }

    final lightJson = json['light'];
    final darkJson = json['dark'];
    if (lightJson is! Map<String, dynamic> ||
        darkJson is! Map<String, dynamic>) {
      throw FormatException('主题 $id 必须同时提供 light 与 dark');
    }
    final accentsJson = json['accents'];
    if (accentsJson is! List || accentsJson.isEmpty) {
      throw FormatException('主题 $id 至少需要一个强调色');
    }
    final accents = [
      for (final a in accentsJson)
        ThemeAccent.fromJson(a as Map<String, dynamic>),
    ];
    final ids = accents.map((a) => a.id).toSet();
    if (ids.length != accents.length) {
      throw FormatException('主题 $id 的强调色 id 重复');
    }
    final group = ThemeGroup.values.asNameMap()[json['group']];
    if (json['group'] != null && group == null) {
      throw FormatException('主题 $id 的 group 无效: ${json['group']}');
    }
    return ThemeSpec(
      id: id,
      kind: kind,
      name: name,
      group: group ?? ThemeGroup.custom,
      family: json['family'] as String?,
      variantName: _parseName(json['variantName']),
      order: json['order'] as int? ?? 1000,
      light: ThemePalette.fromJson(lightJson),
      dark: ThemePalette.fromJson(darkJson),
      accents: accents,
      allowCustomAccent: json['allowCustomAccent'] as bool? ?? true,
      supportsPureBlack: json['supportsPureBlack'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    if (name.isNotEmpty) 'name': name,
    'kind': kind.name,
    if (!isGenerated) 'group': group.name,
    if (family != null) 'family': family,
    if (variantName.isNotEmpty) 'variantName': variantName,
    if (order != (isGenerated ? 0 : 1000)) 'order': order,
    if (isGenerated) 'surface': surface.name,
    if (!isGenerated) ...{
      'light': light!.toJson(),
      'dark': dark!.toJson(),
      'accents': [for (final a in accents) a.toJson()],
      'allowCustomAccent': allowCustomAccent,
      'supportsPureBlack': supportsPureBlack,
    },
  };
}

/// 按语言取本地化名字：完整标签（zh_HK）→ 语言（zh）→ en → [fallback]。
String localizedName(Map<String, String> names, Locale locale, String fallback) {
  final tag = [
    locale.languageCode,
    if (locale.countryCode case final c? when c.isNotEmpty) c,
  ].join('_');
  return names[tag] ?? names[locale.languageCode] ?? names['en'] ?? fallback;
}

/// 可选颜色：缺省为 null，给了就必须合法（不静默吞掉拼错的值）。
Color? _optionalColor(Object? value) =>
    value == null ? null : ThemeSpecColor.parse(value);

Map<String, String> _parseName(Object? json) => json is Map
    ? {for (final e in json.entries) e.key as String: e.value as String}
    : const {};

/// 主题 JSON 中的颜色格式：`#RRGGBB` 或 `#AARRGGBB`。
class ThemeSpecColor {
  ThemeSpecColor._();

  static Color parse(Object? value) {
    final color = tryParse(value);
    if (color == null) throw FormatException('颜色格式无效: $value');
    return color;
  }

  static Color? tryParse(Object? value) {
    if (value is! String || !value.startsWith('#')) return null;
    final hex = value.substring(1);
    final parsed = int.tryParse(hex, radix: 16);
    if (parsed == null) return null;
    return switch (hex.length) {
      6 => Color(0xFF000000 | parsed),
      8 => Color(parsed),
      _ => null,
    };
  }

  static String format(Color color) {
    final argb = color.toARGB32();
    final hex = argb.toRadixString(16).padLeft(8, '0').toUpperCase();
    return (argb >>> 24) == 0xFF ? '#${hex.substring(2)}' : '#$hex';
  }
}
