import 'package:flutter/material.dart';

final appRouteObserver = AppRouteObserver();

/// 同时向内层 Navigator 中的页面报告根栈顶变化，包括移除和替换路由。
class AppRouteObserver extends RouteObserver<ModalRoute<dynamic>> {
  final topRouteRevision = ValueNotifier<int>(0);

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    super.didChangeTop(topRoute, previousTopRoute);
    topRouteRevision.value++;
  }
}
