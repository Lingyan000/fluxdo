import 'package:flutter/services.dart' show PredictiveBackEvent;
import 'package:flutter/widgets.dart';

/// 让非路由的嵌入式浮层(分类抽屉/侧栏通知面板)消费 Android 预测
/// 返回手势:浮层自己把手势进度映射到收起动画,commit 时关闭。
///
/// 框架侧机制:WidgetsBinding 在 startBackGesture 时按注册顺序询问
/// 所有 observer,[handleStartBackGesture] 返回 true 即认领,后续
/// update/commit/cancel 只派发给认领者。同一时刻可能有多个浮层
/// 都处于可关闭状态,各自的 [isEnabled] 必须互斥(只允许 z 序最
/// 上层的浮层认领),否则一次手势会同时关掉多层。
class PredictiveBackOverlayHandler with WidgetsBindingObserver {
  PredictiveBackOverlayHandler({
    required this.isEnabled,
    required this.onStart,
    required this.onUpdate,
    required this.onCancel,
    required this.onCommit,
  });

  final bool Function() isEnabled;
  final VoidCallback onStart;
  final ValueChanged<double> onUpdate;
  final VoidCallback onCancel;
  final VoidCallback onCommit;

  bool _gestureActive = false;

  void attach() => WidgetsBinding.instance.addObserver(this);

  void dispose() => WidgetsBinding.instance.removeObserver(this);

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (backEvent.isButtonEvent || !isEnabled()) return false;
    _gestureActive = true;
    onStart();
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (!_gestureActive) return;
    onUpdate(backEvent.progress.clamp(0.0, 1.0));
  }

  @override
  void handleCancelBackGesture() {
    if (!_gestureActive) return;
    _gestureActive = false;
    onCancel();
  }

  @override
  void handleCommitBackGesture() {
    if (!_gestureActive) return;
    _gestureActive = false;
    onCommit();
  }

  // 手势中途 Activity 进后台(挂后台/锁屏):系统不补发 commit/cancel,
  // 不收尾的话浮层卡在半开进度。代打 cancel 弹回原位。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused) {
      return;
    }
    if (!_gestureActive) return;
    _gestureActive = false;
    onCancel();
  }
}
