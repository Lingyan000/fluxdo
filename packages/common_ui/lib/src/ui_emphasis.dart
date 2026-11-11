import 'package:flutter/material.dart';

/// 强调色的两种用途 token：调用方声明意图，取值由主题决定。
///
/// 直接写 `colorScheme.primary` 时，素色主题（控件用墨色）里这些图标会
/// 残留成唯一的彩色点；按意图取 token 后各主题统一换档。链接仍直接用
/// `colorScheme.primary`——强调色本来就留给链接。
///
/// 未注入时两者都是 `colorScheme.primary`，与引入本类之前一致。
@immutable
class UiEmphasis extends ThemeExtension<UiEmphasis> {
  const UiEmphasis({required this.accent, required this.selected});

  /// 装饰性强调：入口按钮（☰、添加）、区块 / 分组图标、空态大图标，
  /// 以及与之配套的入口文字。
  final Color accent;

  /// 状态强调：已选中的勾、已置顶、已开启、当前排序方向。
  final Color selected;

  factory UiEmphasis.fallback(ColorScheme scheme) =>
      UiEmphasis(accent: scheme.primary, selected: scheme.primary);

  /// 从 [theme] 取 token（只有 ThemeData、没有 context 的地方用）。
  static UiEmphasis of(ThemeData theme) =>
      theme.extension<UiEmphasis>() ?? UiEmphasis.fallback(theme.colorScheme);

  @override
  UiEmphasis copyWith({Color? accent, Color? selected}) => UiEmphasis(
    accent: accent ?? this.accent,
    selected: selected ?? this.selected,
  );

  @override
  UiEmphasis lerp(covariant UiEmphasis? other, double t) {
    if (other == null) return this;
    return UiEmphasis(
      accent: Color.lerp(accent, other.accent, t)!,
      selected: Color.lerp(selected, other.selected, t)!,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UiEmphasis &&
      other.accent == accent &&
      other.selected == selected;

  @override
  int get hashCode => Object.hash(accent, selected);
}

extension UiEmphasisContext on BuildContext {
  /// 当前主题的强调 token；未注入时取 `colorScheme.primary`。
  UiEmphasis get emphasis => UiEmphasis.of(Theme.of(this));
}

/// 顶栏区域：区域内的图标按钮与 AppBar 的操作图标同色（装饰强调）。
/// 只作用于图标按钮，标题等区域内的普通图标不受影响。
///
/// 给不是 AppBar、但承担顶栏职责的自绘工具条用（如首页标题栏），
/// 区域内的按钮不必逐个写颜色；同一个按钮放到侧栏等其他区域时自动
/// 回到普通操作图标的次要色。
class TopBarIconScope extends StatelessWidget {
  const TopBarIconScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final emphasis = context.emphasis;
    final disabled = theme.colorScheme.onSurface.withValues(alpha: 0.38);
    final foreground = WidgetStateProperty.resolveWith<Color?>((states) {
      if (states.contains(WidgetState.disabled)) return disabled;
      if (states.contains(WidgetState.selected)) return emphasis.selected;
      return emphasis.accent;
    });
    final base = theme.iconButtonTheme.style ?? const ButtonStyle();
    return IconButtonTheme(
      data: IconButtonThemeData(
        style: base.copyWith(foregroundColor: foreground),
      ),
      child: child,
    );
  }
}
