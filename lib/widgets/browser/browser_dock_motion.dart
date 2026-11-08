import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/browser_tabs.dart';

const browserDockHeight = 64.0;
const browserDockInset = 12.0;
const browserDockCardHeight = 52.0;
const browserDockMaxWidth = 736.0;
const browserDockExpandDuration = Duration(milliseconds: 460);
const browserDockMinimizeDuration = Duration(milliseconds: 420);

// 临界阻尼响应：较快启动、连续减速，归一化端点以免末帧跳动。
double _settle(double value, double response) {
  double position(double t) => 1 - (1 + response * t) * math.exp(-response * t);
  return position(value) / position(1);
}

double browserDockOpenProgress(double value, {bool closing = false}) {
  final t = value.clamp(0.0, 1.0);
  return closing ? 1 - _settle(1 - t, 8) : _settle(t, 8.5);
}

/// 网页在靠近底栏时连续交接给同一张卡片，避免先消失再出现底栏。
double browserDockPageOpacity(double progress) =>
    Curves.easeInOut.transform((progress / .24).clamp(0.0, 1.0));

Rect browserDockRect(Size size, double safeBottom) {
  final width = (size.width - browserDockInset * 2).clamp(
    0.0,
    browserDockMaxWidth,
  );
  return Rect.fromLTWH(
    (size.width - width) / 2,
    size.height - safeBottom - browserDockHeight + 8,
    width,
    browserDockCardHeight,
  );
}

/// 只由浏览器路由驱动；小程序沿用已有路由和底栏避让规则。
class BrowserDockMotion extends ChangeNotifier {
  final stateChanges = ValueNotifier(0);
  Animation<double>? _animation;
  BrowserTabSession? _tab;
  bool _disposed = false;
  bool _linear = false;
  BrowserTabSession? _restoreDragTab;
  double _restoreDragProgress = 0;
  double? _restoreDragVelocity;
  ValueChanged<double>? _updateRestore;
  ValueChanged<double>? _endRestore;
  bool get active => _animation != null;
  BrowserTabSession? get tab => _tab;
  double get openProgress => _linear
      ? (_animation?.value ?? 1)
      : browserDockOpenProgress(
          _animation?.value ?? 1,
          closing: _animation?.status == AnimationStatus.reverse,
        );
  double get reservedFraction => 1 - openProgress;

  void start(
    Animation<double> animation,
    BrowserTabSession tab, {
    bool linear = false,
  }) {
    _animation?.removeListener(_tick);
    _animation = animation;
    _tab = tab;
    _linear = linear;
    animation.addListener(_tick);
    stateChanges.value++;
    notifyListeners();
  }

  bool restoringByDrag(BrowserTabSession? tab) =>
      tab != null && identical(tab, _restoreDragTab);

  void beginRestoreDrag(BrowserTabSession tab) {
    _restoreDragTab = tab;
    _restoreDragProgress = 0;
    _restoreDragVelocity = null;
  }

  void updateRestoreDrag(double progress) {
    _restoreDragProgress = progress.clamp(0.0, 1.0);
    _updateRestore?.call(_restoreDragProgress);
  }

  void endRestoreDrag(double velocity) {
    _restoreDragVelocity = velocity;
    _endRestore?.call(velocity);
  }

  void bindRestoreDrag(ValueChanged<double> update, ValueChanged<double> end) {
    _updateRestore = update;
    _endRestore = end;
    update(_restoreDragProgress);
    if (_restoreDragVelocity case final velocity?) end(velocity);
  }

  void clearRestoreDrag() {
    _restoreDragTab = null;
    _updateRestore = null;
    _endRestore = null;
  }

  void _tick() => notifyListeners();

  void finish(Animation<double> animation) {
    if (_disposed || _animation != animation) return;
    animation.removeListener(_tick);
    _animation = null;
    _tab = null;
    clearRestoreDrag();
    stateChanges.value++;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _animation?.removeListener(_tick);
    stateChanges.dispose();
    super.dispose();
  }
}

/// 保存外层完整视口，底栏占位变化时不改变转场中原生网页的尺寸。
class BrowserDockViewport extends InheritedWidget {
  const BrowserDockViewport({
    super.key,
    required this.media,
    required this.motion,
    required super.child,
  });

  final MediaQueryData media;
  final BrowserDockMotion motion;

  static BrowserDockViewport? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BrowserDockViewport>();

  static BrowserDockMotion? motionOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<BrowserDockViewport>()?.motion;

  @override
  bool updateShouldNotify(BrowserDockViewport oldWidget) =>
      media != oldWidget.media || motion != oldWidget.motion;
}
