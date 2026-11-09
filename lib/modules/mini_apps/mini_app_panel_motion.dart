import 'package:flutter/material.dart';

import '../../services/browser_tabs.dart';
import '../../widgets/browser/browser_dock_motion.dart';

/// 弹窗与底栏共用真实路由进度；手指直接驱动位移，松手后才归位。
/// 控制器由打开入口持有，通过公共弹层的卸载回调同步释放。
class MiniAppPanelMotion {
  MiniAppPanelMotion(
    this.navigator,
    this.motion,
    this.session, {
    this.reduceMotion = false,
  }) : controller = AnimationController(
         vsync: navigator,
         duration: reduceMotion ? Duration.zero : browserDockExpandDuration,
         reverseDuration: reduceMotion
             ? Duration.zero
             : browserDockMinimizeDuration,
       );

  final NavigatorState navigator;
  final BrowserDockMotion? motion;
  final BrowserTabSession session;
  final bool reduceMotion;
  final AnimationController controller;
  final moving = ValueNotifier(false);
  VoidCallback? onReturnToDock;
  bool Function()? canDrag;
  double extent = 1;
  bool _dragging = false, _userGesture = false, _disposed = false;
  bool _committed = false;
  int _revision = 0;

  void start({required bool fromDock}) {
    controller.addStatusListener(_finish);
    moving.value = true;
    if (fromDock && motion?.restoringByDrag(session) == true) {
      _dragging = true;
      controller.stop();
      controller.value = .000001;
      _startGesture();
      motion?.start(controller.view, session, linear: true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) motion?.bindRestoreDrag(_updateRestore, _endRestore);
      });
    } else {
      if (fromDock) motion?.start(controller.view, session, linear: true);
      controller.animateTo(1, curve: const _OpenCurve());
      // 禁用动画时，push 可能在注册监听前已同步到端点。
      if (controller.isCompleted) _finish(AnimationStatus.completed);
    }
  }

  void updateExtent(double height) {
    extent = height > 0 ? height : 1;
    if (motion?.restoringByDrag(session) == true) {
      motion?.restoreDragExtent = extent;
    }
  }

  /// 从当前画面接手回弹，不重置到展开端点，也不等待截图。
  void hold() {
    if (_disposed || _committed || canDrag?.call() != true) return;
    _revision++;
    _dragging = true;
    controller.stop();
    moving.value = true;
    _startGesture();
    motion?.start(controller.view, session, linear: true);
  }

  void drag(double dy) {
    if (!_dragging || _disposed) return;
    controller.value = (controller.value - dy / extent).clamp(.000001, .999999);
  }

  void release(double velocity) {
    if (!_dragging || _disposed) return;
    _dragging = false;
    if (velocity > 650 || (velocity >= -650 && controller.value < .72)) {
      onReturnToDock?.call();
    } else {
      _expand();
    }
  }

  void cancel() {
    if (!_dragging || _disposed) return;
    _dragging = false;
    _expand();
  }

  void _expand() {
    // 顶栏按钮获胜时取消的是零位移拖动；已在端点不会再发状态通知。
    // 也要结束 Navigator 的用户手势，否则菜单关闭后网页仍被拦截。
    if (controller.isCompleted) {
      _finish(AnimationStatus.completed);
      return;
    }
    controller.animateTo(
      1,
      duration: _settleDuration(1 - controller.value),
      curve: Curves.easeOutCubic,
    );
  }

  void _updateRestore(double progress) {
    if (!_disposed && _dragging) {
      controller.value = progress.clamp(.000001, .999999);
    }
  }

  void _endRestore(double velocity) {
    if (_disposed || !_dragging) return;
    _dragging = false;
    motion?.clearRestoreDrag();
    if (velocity > 650 || (velocity >= -650 && controller.value >= .28)) {
      _expand();
    } else {
      onReturnToDock?.call();
    }
  }

  /// 收起按钮和拖动确认共用交接；普通关闭不保留会话。
  void minimize() {
    if (_disposed) return;
    _revision++;
    _committed = true;
    _dragging = false;
    moving.value = true;
    motion?.start(controller.view, session, linear: true);
  }

  /// pop 会先触发默认 reverse，紧接着接管剩余路程，避免松手后变速。
  void didPop() {
    if (_disposed) return;
    _revision++;
    _committed = true;
    _dragging = false;
    moving.value = true;
    controller.animateBack(
      0,
      duration: _settleDuration(controller.value),
      curve: Curves.easeOutCubic,
    );
  }

  Duration _settleDuration(double distance) => reduceMotion
      ? Duration.zero
      : Duration(milliseconds: (120 + 220 * distance).round());

  void _startGesture() {
    if (_userGesture) return;
    _userGesture = true;
    navigator.didStartUserGesture();
  }

  void _finish(AnimationStatus status) {
    if (_dragging ||
        (status != AnimationStatus.completed &&
            status != AnimationStatus.dismissed)) {
      return;
    }
    final revision = _revision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || revision != _revision || _dragging) return;
      motion?.finish(controller.view);
      moving.value = false;
      _stopGesture();
    });
  }

  void _stopGesture() {
    if (!_userGesture) return;
    _userGesture = false;
    if (navigator.mounted) navigator.didStopUserGesture();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stopGesture();
    final animation = controller.view;
    // 卸载可能发生在 Navigator.dispose 中，不在锁定的构建树上通知底栏。
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => motion?.finish(animation),
    );
    controller.removeStatusListener(_finish);
    controller.dispose();
    moving.dispose();
  }
}

class _OpenCurve extends Curve {
  const _OpenCurve();
  @override
  double transformInternal(double t) => browserDockOpenProgress(t);
}
