import 'package:material_ui/material_ui.dart';

/// 分段卡片组的呈现模式。
enum SegmentedCardMode {
  /// 每个条目独立成块、块间细缝（M3 Expressive 默认）
  segmented,

  /// 整组一个细线框，组内细线分隔
  outlined,

  /// 不画容器，条目之间细线分隔
  flat,
}

/// 分段卡片组的主题扩展；未注入时为 [SegmentedCardMode.segmented]。
@immutable
class SegmentedCardStyle extends ThemeExtension<SegmentedCardStyle> {
  const SegmentedCardStyle({
    this.mode = SegmentedCardMode.segmented,
    this.dividerColor,
    this.borderColor,
    this.background,
  });

  final SegmentedCardMode mode;

  /// 组内分隔线颜色，缺省为 outlineVariant
  final Color? dividerColor;

  /// 描边模式的外框颜色，缺省为 outlineVariant
  final Color? borderColor;

  /// 描边模式的底色，缺省为 surface；平铺模式恒为透明
  final Color? background;

  static SegmentedCardStyle of(BuildContext context) =>
      SegmentedCardStyleScope.maybeOf(context) ??
      Theme.of(context).extension<SegmentedCardStyle>() ??
      const SegmentedCardStyle();

  @override
  SegmentedCardStyle copyWith({
    SegmentedCardMode? mode,
    Color? dividerColor,
    Color? borderColor,
    Color? background,
  }) => SegmentedCardStyle(
    mode: mode ?? this.mode,
    dividerColor: dividerColor ?? this.dividerColor,
    borderColor: borderColor ?? this.borderColor,
    background: background ?? this.background,
  );

  @override
  SegmentedCardStyle lerp(covariant SegmentedCardStyle? other, double t) {
    if (other == null) return this;
    return SegmentedCardStyle(
      mode: t < 0.5 ? mode : other.mode,
      dividerColor: Color.lerp(dividerColor, other.dividerColor, t),
      borderColor: Color.lerp(borderColor, other.borderColor, t),
      background: Color.lerp(background, other.background, t),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SegmentedCardStyle &&
      other.mode == mode &&
      other.dividerColor == dividerColor &&
      other.borderColor == borderColor &&
      other.background == background;

  @override
  int get hashCode => Object.hash(mode, dividerColor, borderColor, background);
}

/// 局部覆写 [SegmentedCardStyle] 的轻量作用域，避免为了改模式而复制整份
/// [ThemeData] 导致 Flutter 全局主题本地化缓存被频繁逐出。
class SegmentedCardStyleScope extends InheritedWidget {
  const SegmentedCardStyleScope({
    super.key,
    required this.style,
    required super.child,
  });

  final SegmentedCardStyle style;

  static SegmentedCardStyle? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<SegmentedCardStyleScope>()
      ?.style;

  @override
  bool updateShouldNotify(SegmentedCardStyleScope oldWidget) =>
      style != oldWidget.style;
}
