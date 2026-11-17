import 'package:flutter/widgets.dart';

import 'nav_action_bus.dart';

/// 常驻页面的可见性；路由可见不代表 IndexedStack 中的标签可见。
class NavigationActivityScope extends InheritedWidget {
  const NavigationActivityScope({
    super.key,
    required this.active,
    this.action,
    required super.child,
  });
  final bool active;
  final NavActionEvent? action;
  static NavActionEvent? actionOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<NavigationActivityScope>()
      ?.action;
  static bool isActive(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<NavigationActivityScope>()
          ?.active ??
      true;
  @override
  bool updateShouldNotify(NavigationActivityScope oldWidget) =>
      active != oldWidget.active || action != oldWidget.action;
}

/// 首次选中才构建，之后保留状态。避免配置底栏就启动插件、请求服务。
class LazyNavigationPage extends StatefulWidget {
  const LazyNavigationPage({
    super.key,
    required this.active,
    required this.builder,
  });
  final bool active;
  final WidgetBuilder builder;
  @override
  State<LazyNavigationPage> createState() => _LazyNavigationPageState();
}

class _LazyNavigationPageState extends State<LazyNavigationPage> {
  bool _visited = false;
  @override
  Widget build(BuildContext context) {
    _visited |= widget.active;
    return _visited ? widget.builder(context) : const SizedBox.shrink();
  }
}
