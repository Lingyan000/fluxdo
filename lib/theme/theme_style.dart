import 'package:flutter/material.dart';

/// 容器（卡片、设置分组、话题卡、楼层）的呈现方式。
enum SurfaceStyle {
  /// 色块填充、层级靠明度区分（Material 默认）
  filled,

  /// 与背景同色、1px 细线描边
  outlined,

  /// 不画容器：平铺在页面上，相邻项之间细线分隔
  flat,
}

/// 实心控件（实心按钮、开关、单选 / 复选、悬浮按钮、选中标签）的颜色。
enum ControlStyle {
  /// 强调色（Material 默认）
  accent,

  /// 墨色：浅色下近黑、深色下近白；强调色只留给链接、选中与焦点
  ink,
}

/// 导航（底栏、侧栏、标签页）的选中标记。
enum NavIndicatorStyle {
  /// 胶囊底（Material 默认）
  pill,

  /// 强调色短横
  bar,

  /// 浅灰底
  tint,
}

/// 输入框外观。
enum InputStyle { filled, outlined, underline }

/// 页面底的质感。
enum TextureStyle { none, paper }

/// 帖子引用块的外观。
enum QuoteStyle {
  /// 浅色底块（默认）
  card,

  /// 细竖条、无底色
  bar,
}

/// 论坛下发的数据色（分类色、标签色）在当前主题里的处理方式。
enum DataColorStyle {
  /// 原样（只做可读性校正）
  vivid,

  /// 色相向主题强调色偏移一小段，保留辨识度又不跳色
  harmonized,

  /// 降饱和，融进素色主题
  muted,

  /// 单色：一律取主题强调色的色相（终端这类单色主题）
  mono,
}

/// 主题的「界面风格」：配色之外，组件长什么样。
///
/// 与配色同样由主题数据（JSON 的 `style` 字段）声明，所有主题共用同一套
/// 组件开关。默认值即 Material 的现有外观。
@immutable
class ThemeStyle extends ThemeExtension<ThemeStyle> {
  const ThemeStyle({
    this.surfaces = SurfaceStyle.filled,
    this.controls = ControlStyle.accent,
    this.navIndicator = NavIndicatorStyle.pill,
    this.inputs = InputStyle.filled,
    this.shadows = true,
    this.titleFont,
    this.bodyLineHeight,
    this.quote = QuoteStyle.card,
    this.texture = TextureStyle.none,
    this.dataColors = DataColorStyle.vivid,
  });

  static const ThemeStyle material = ThemeStyle();

  final SurfaceStyle surfaces;
  final ControlStyle controls;
  final NavIndicatorStyle navIndicator;
  final InputStyle inputs;

  /// 浮层与卡片是否带阴影；关闭时浮层改用细线描边分层。
  final bool shadows;

  /// 标题字体：`serif`（系统宋体 / 衬线）、`mono`（等宽）或字体目录 id；
  /// null 跟随正文字体。
  final String? titleFont;

  /// 帖子正文行高，null 用默认。
  final double? bodyLineHeight;

  final QuoteStyle quote;
  final TextureStyle texture;
  final DataColorStyle dataColors;

  bool get isMaterial => this == material;

  /// 组件外观是否与 Material 一致（数据色只影响取色，不改组件主题）。
  bool get hasMaterialComponents =>
      copyWith(dataColors: DataColorStyle.vivid) == material;

  factory ThemeStyle.fromJson(Map<String, dynamic> json) {
    T pick<T extends Enum>(List<T> values, String key, T fallback) {
      final raw = json[key];
      if (raw == null) return fallback;
      final value = values.asNameMap()[raw];
      if (value == null) throw FormatException('style.$key 无效: $raw');
      return value;
    }

    return ThemeStyle(
      surfaces: pick(SurfaceStyle.values, 'surfaces', SurfaceStyle.filled),
      controls: pick(ControlStyle.values, 'controls', ControlStyle.accent),
      navIndicator: pick(
        NavIndicatorStyle.values,
        'navIndicator',
        NavIndicatorStyle.pill,
      ),
      inputs: pick(InputStyle.values, 'inputs', InputStyle.filled),
      shadows: json['shadows'] as bool? ?? true,
      titleFont: json['titleFont'] as String?,
      bodyLineHeight: (json['bodyLineHeight'] as num?)?.toDouble(),
      quote: pick(QuoteStyle.values, 'quote', QuoteStyle.card),
      texture: pick(TextureStyle.values, 'texture', TextureStyle.none),
      dataColors: pick(
        DataColorStyle.values,
        'dataColors',
        DataColorStyle.vivid,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    if (surfaces != SurfaceStyle.filled) 'surfaces': surfaces.name,
    if (controls != ControlStyle.accent) 'controls': controls.name,
    if (navIndicator != NavIndicatorStyle.pill)
      'navIndicator': navIndicator.name,
    if (inputs != InputStyle.filled) 'inputs': inputs.name,
    if (!shadows) 'shadows': false,
    'titleFont': ?titleFont,
    'bodyLineHeight': ?bodyLineHeight,
    if (quote != QuoteStyle.card) 'quote': quote.name,
    if (texture != TextureStyle.none) 'texture': texture.name,
    if (dataColors != DataColorStyle.vivid) 'dataColors': dataColors.name,
  };

  @override
  ThemeStyle copyWith({
    SurfaceStyle? surfaces,
    ControlStyle? controls,
    NavIndicatorStyle? navIndicator,
    InputStyle? inputs,
    bool? shadows,
    String? titleFont,
    double? bodyLineHeight,
    QuoteStyle? quote,
    TextureStyle? texture,
    DataColorStyle? dataColors,
  }) => ThemeStyle(
    surfaces: surfaces ?? this.surfaces,
    controls: controls ?? this.controls,
    navIndicator: navIndicator ?? this.navIndicator,
    inputs: inputs ?? this.inputs,
    shadows: shadows ?? this.shadows,
    titleFont: titleFont ?? this.titleFont,
    bodyLineHeight: bodyLineHeight ?? this.bodyLineHeight,
    quote: quote ?? this.quote,
    texture: texture ?? this.texture,
    dataColors: dataColors ?? this.dataColors,
  );

  /// 风格是离散选择，主题切换时整体换档。
  @override
  ThemeStyle lerp(covariant ThemeStyle? other, double t) =>
      other == null || t < 0.5 ? this : other;

  @override
  bool operator ==(Object other) =>
      other is ThemeStyle &&
      other.surfaces == surfaces &&
      other.controls == controls &&
      other.navIndicator == navIndicator &&
      other.inputs == inputs &&
      other.shadows == shadows &&
      other.titleFont == titleFont &&
      other.bodyLineHeight == bodyLineHeight &&
      other.quote == quote &&
      other.texture == texture &&
      other.dataColors == dataColors;

  @override
  int get hashCode => Object.hash(
    surfaces,
    controls,
    navIndicator,
    inputs,
    shadows,
    titleFont,
    bodyLineHeight,
    quote,
    texture,
    dataColors,
  );
}

extension ThemeStyleContext on BuildContext {
  /// 当前主题的界面风格；未注入时为 Material 默认。
  ThemeStyle get themeStyle =>
      Theme.of(this).extension<ThemeStyle>() ?? ThemeStyle.material;
}
