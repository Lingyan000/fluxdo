import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

const browserPageRouteName = '/browser';
const miniAppPageRouteName = '/mini-app';
const fullscreenVideoRouteName = '/fullscreen-video';

/// 底栏给浏览器、沉浸式查看器和模态弹层让位。
class BrowserDockObserver extends NavigatorObserver {
  final hidden = ValueNotifier(false);
  final List<Route<dynamic>> _routes = [];
  bool _scheduled = false;
  Route<dynamic>? get currentRoute => _routes.lastOrNull;

  void _update() {
    // 普通 push 浏览器时首帧就给全屏页面让位；若正在 build，仍遵守
    // 帧末通知规则。其他路由（包括小程序）保持原有通知时序。
    if (currentRoute?.settings.name == browserPageRouteName &&
        SchedulerBinding.instance.schedulerPhase !=
            SchedulerPhase.persistentCallbacks) {
      hidden.value = true;
      return;
    }
    // Navigator 的初始路由可能在 build 期间安装，合并到帧末通知宿主。
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      final route = _routes.lastOrNull;
      hidden.value =
          route != null &&
          (route is PopupRoute ||
              (route is PageRoute && !route.opaque) ||
              (route is PageRoute && route.fullscreenDialog) ||
              route.settings.name == browserPageRouteName ||
              route.settings.name == miniAppPageRouteName ||
              route.settings.name == fullscreenVideoRouteName);
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _update();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _update();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _update();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        _routes.removeAt(index);
      } else {
        _routes[index] = newRoute;
      }
    } else if (newRoute != null) {
      _routes.add(newRoute);
    }
    _update();
  }
}

final browserDockObserver = BrowserDockObserver();
