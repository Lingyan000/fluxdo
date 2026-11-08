import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// 给不经过 Navigator 的 pane 转场提供相同的视觉更新暂停信号。
/// 只在开始/结束时通知后代，不把逐帧动画广播给列表。
class PageMotionScope extends StatelessWidget {
  const PageMotionScope({super.key, required this.moving, required this.child});

  final bool moving;
  final Widget child;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PageMotion>()?.moving ??
      false;

  @override
  Widget build(BuildContext context) =>
      _PageMotion(moving: moving || PageMotionScope.of(context), child: child);
}

class _PageMotion extends InheritedWidget {
  const _PageMotion({required this.moving, required super.child});
  final bool moving;

  @override
  bool updateShouldNotify(_PageMotion oldWidget) => moving != oldWidget.moving;
}

/// 仅暂存一份用于展示的值；业务订阅、请求和最新状态不受影响。
///
/// build 中调用 [holdDuringRouteMotion]。转场结束只触发一次重建，读取
/// 最新值。账号/查询等 [identity] 改变时立即作废旧画面，即使正在转场。
mixin RouteMotionHoldMixin<W extends StatefulWidget, V> on State<W> {
  final _animations = <Animation<double>>{};
  final _gestures = <ValueListenable<bool>>{};
  bool _paneMoving = false;
  bool _pending = false;
  bool _releaseScheduled = false;
  bool _hasValue = false;
  Object? _identity;
  V? _shown;

  bool get _moving =>
      _paneMoving ||
      _animations.any((animation) => animation.isAnimating) ||
      _gestures.any((gesture) => gesture.value);

  V holdDuringRouteMotion(V value, {required Object identity}) {
    if (!_hasValue || identity != _identity || !_moving) {
      _hasValue = true;
      _identity = identity;
      _shown = value;
      _pending = false;
    } else if (value != _shown) {
      _pending = true;
    }
    return _shown as V;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _detach();
    _paneMoving = PageMotionScope.of(context);
    // 嵌套 Navigator 内的页面也可能随外层路由一起移动。
    var route = ModalRoute.of(context);
    final seen = <ModalRoute<dynamic>>{};
    while (route != null && seen.add(route)) {
      if (route.animation case final animation?) _animations.add(animation);
      if (route.secondaryAnimation case final animation?) {
        _animations.add(animation);
      }
      final navigator = route.navigator;
      if (navigator == null) break;
      _gestures.add(navigator.userGestureInProgressNotifier);
      route = ModalRoute.of(navigator.context);
    }
    for (final animation in _animations) {
      animation.addStatusListener(_onStatus);
    }
    for (final gesture in _gestures) {
      gesture.addListener(_release);
    }
    _release();
  }

  void _onStatus(AnimationStatus _) => _release();

  void _release() {
    if (!_pending || _moving || _releaseScheduled) return;
    _releaseScheduled = true;
    // 路由/pane 的结束回调可能发生在 build/layout 中；下一帧再更新。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _releaseScheduled = false;
      if (mounted && _pending && !_moving) setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _detach() {
    for (final animation in _animations) {
      animation.removeStatusListener(_onStatus);
    }
    for (final gesture in _gestures) {
      gesture.removeListener(_release);
    }
    _animations.clear();
    _gestures.clear();
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }
}
