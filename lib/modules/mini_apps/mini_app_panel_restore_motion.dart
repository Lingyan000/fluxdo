import 'package:flutter/material.dart';

import '../../services/browser_tabs.dart';
import '../../widgets/browser/browser_dock_motion.dart';

/// 将底栏手势交给公共底部弹窗的真实路由进度，保持弹窗呈现和原生实例。
/// 控制器由打开入口持有，等路由彻底卸载后才释放。
class MiniAppPanelRestoreMotion {
  MiniAppPanelRestoreMotion(this.navigator, this.motion, this.session)
    : controller = AnimationController(
        vsync: navigator,
        duration: browserDockExpandDuration,
        reverseDuration: browserDockMinimizeDuration,
      );

  final NavigatorState navigator;
  final BrowserDockMotion motion;
  final BrowserTabSession session;
  final AnimationController controller;
  VoidCallback? onReturnToDock;
  bool _dragging = true, _userGesture = false, _disposed = false;

  void start() {
    controller.stop();
    controller.value = .000001;
    controller.addStatusListener(_finish);
    motion.start(controller.view, session, linear: true);
    _userGesture = true;
    navigator.didStartUserGesture();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      motion.bindRestoreDrag(_update, _end);
    });
  }

  void _update(double progress) {
    if (_disposed || !_dragging) return;
    controller.value = progress.clamp(.000001, .999999);
  }

  void _end(double velocity) {
    if (_disposed || !_dragging) return;
    _dragging = false;
    motion.clearRestoreDrag();
    if (velocity > 650 || (velocity >= -650 && controller.value >= .28)) {
      controller.animateTo(
        1,
        duration: Duration(
          milliseconds: (120 + 220 * (1 - controller.value)).round(),
        ),
        curve: Curves.easeOutCubic,
      );
    } else {
      // 松手取消不等待截图、媒体或网络，不销毁已主动收起的实例。
      onReturnToDock?.call();
      if (!_disposed && !controller.isDismissed) {
        controller.animateBack(
          0,
          duration: Duration(
            milliseconds: (120 + 220 * controller.value).round(),
          ),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  void _finish(AnimationStatus status) {
    if (_dragging ||
        (status != AnimationStatus.completed &&
            status != AnimationStatus.dismissed)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      motion.finish(controller.view);
      _stopGesture();
    });
  }

  void _stopGesture() {
    if (!_userGesture) return;
    _userGesture = false;
    if (navigator.mounted) navigator.didStopUserGesture();
  }

  void dispose() {
    _disposed = true;
    _stopGesture();
    motion.finish(controller.view);
    controller.removeStatusListener(_finish);
    controller.dispose();
  }
}
