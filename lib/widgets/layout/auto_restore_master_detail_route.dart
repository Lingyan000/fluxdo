import 'package:flutter/material.dart';

import 'master_detail_layout.dart';

/// 窄屏下临时顶替平行视界的全屏页面。
///
/// 窗口重新变宽后，精确移除当前临时路由，露出下方仍保留完整导航栈的
/// Master-Detail 页面。使用 [NavigatorState.removeRoute] 而不是简单 pop，
/// 避免临时路由上方还有用户主动打开的页面时误关掉错误的路由。
class AutoRestoreMasterDetailRoute extends StatefulWidget {
  const AutoRestoreMasterDetailRoute({
    super.key,
    required this.child,
    this.onRestore,
    this.masterWidth = MasterDetailLayout.defaultMasterWidth,
    this.minDetailWidth = MasterDetailLayout.defaultMinDetailWidth,
  });

  final Widget child;
  final VoidCallback? onRestore;
  final double masterWidth;
  final double minDetailWidth;

  @override
  State<AutoRestoreMasterDetailRoute> createState() =>
      _AutoRestoreMasterDetailRouteState();
}

class _AutoRestoreMasterDetailRouteState
    extends State<AutoRestoreMasterDetailRoute> {
  bool _removeScheduled = false;

  @override
  Widget build(BuildContext context) {
    final canShowBothPanes = MasterDetailLayout.canShowBothPanesFor(
      context,
      masterWidth: widget.masterWidth,
      minDetailWidth: widget.minDetailWidth,
    );
    if (!canShowBothPanes) {
      _removeScheduled = false;
      return widget.child;
    }

    if (!_removeScheduled) {
      _removeScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final route = ModalRoute.of(context);
        if (route == null || !route.isCurrent) {
          _removeScheduled = false;
          return;
        }
        final navigator = Navigator.of(context);
        // 先移除再 onRestore:反过来的话 onRestore 里 setState/push 的
        // 内容会与还在栈顶的本全屏路由同一帧重叠渲染(闪一下)。移除后
        // 本 State 已 unmount,回调闭包不依赖本 context,安全。
        if (route.isActive) navigator.removeRoute(route);
        widget.onRestore?.call();
      });
    }

    return widget.child;
  }
}
