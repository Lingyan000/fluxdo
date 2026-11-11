import 'package:flutter/widgets.dart';

/// 宿主注入的点缀（例如节日期间）：组件库只预留位置，内容由应用决定。
///
/// 构建器需保持同一实例（例如顶层函数），否则每次重建都会通知依赖方。
class UiDecor extends InheritedWidget {
  const UiDecor({
    super.key,
    this.cornerBadge,
    this.loadingIndicator,
    required super.child,
  });

  /// 空状态图标右上角的小点缀
  final WidgetBuilder? cornerBadge;

  /// 替换下拉刷新圆片里的加载动画；`size` 为可用边长
  final Widget Function(BuildContext context, double size)? loadingIndicator;

  static UiDecor? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UiDecor>();

  @override
  bool updateShouldNotify(UiDecor oldWidget) =>
      cornerBadge != oldWidget.cornerBadge ||
      loadingIndicator != oldWidget.loadingIndicator;
}
