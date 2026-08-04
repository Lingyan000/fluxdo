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

  void attach() => WidgetsBinding.instance.addObserver(this);

  void dispose() => WidgetsBinding.instance.removeObserver(this);

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (backEvent.isButtonEvent || !isEnabled()) return false;
    onStart();
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    onUpdate(backEvent.progress.clamp(0.0, 1.0));
  }

  @override
  void handleCancelBackGesture() => onCancel();

  @override
  void handleCommitBackGesture() => onCommit();
}
