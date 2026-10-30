import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/animation.dart';
import 'package:flutter/services.dart';

import 'composer_keyboard_dismiss.dart';

/// 工具与键盘共用一块底部空间。保留输入连接，几何只取实际键盘高度；
/// 上拉额外向正文借用的距离由工作台单独限制。
class ComposerInputHandoff extends ChangeNotifier {
  ComposerInputHandoff(this.keyboard, {required TickerProvider vsync})
    : _release = AnimationController(vsync: vsync, value: 1) {
    keyboard.addListener(_keyboardChanged);
    _release.addListener(_released);
  }

  final ComposerKeyboardDismissController keyboard;
  final AnimationController _release;
  VoidCallback? onResumeKeyboard;
  bool _disposed = false;
  bool active = false;
  double inputHeight = 0;
  double _inset = 0;
  double _safeBottom = 0;
  double _progress = 0;
  double _sentDistance = 0;
  double _dismissDistance = 0;
  bool _fromKeyboard = false;
  bool _controlling = false;
  bool _ending = false;
  bool _restoreInput = true;
  bool _returnRequested = false;
  bool _customPanel = false;
  bool _disableAnimations = false;
  bool? _target;
  int _generation = 0;
  Timer? _returnTimeout;
  Timer? _controlTimeout;
  bool get dismissing => _target == false && !_restoreInput && !_customPanel;
  double get progress => _progress;
  bool get readyToFinish =>
      replacementHeight <= .5 && (!dismissing || !keyboard.active);

  double extraLift(double available, double baseHeight) => math.min(
    96,
    math.max(0, available - replacementHeight - baseHeight - 160),
  );

  double get visibleHeight {
    if (active && _customPanel) {
      return math.max(_safeBottom, inputHeight * (1 - _progress));
    }
    if (keyboard.active) return keyboard.visibleHeight;
    // 表情也让出同一块空间，但不需要驱动系统 IME。
    if (active && !_fromKeyboard && !_returnRequested && _restoreInput) {
      return math.max(_safeBottom, inputHeight * (1 - _progress));
    }
    return math.max(_safeBottom, _inset);
  }

  double get reservedHeight => math.max(
    visibleHeight,
    _safeBottom +
        (inputHeight - _safeBottom) * (_customPanel ? 1 : _release.value),
  );

  double get replacementHeight =>
      active ? math.max(0, reservedHeight - visibleHeight) : 0;

  void updateMetrics(
    double inset,
    double safeBottom, {
    bool customPanel = false,
    bool disableAnimations = false,
  }) {
    _inset = inset;
    _safeBottom = safeBottom;
    _customPanel = customPanel;
    _disableAnimations = disableAnimations;
  }

  void begin(ui.FlutterView view, double panelHeight) {
    if (active) return;
    _generation++;
    active = true;
    inputHeight = math.max(panelHeight, math.max(_inset, _safeBottom));
    _fromKeyboard = _inset > 0;
    _progress = 0;
    _sentDistance = 0;
    _restoreInput = true;
    _returnRequested = false;
    _customPanel = false;
    _release.value = 1;
    _target = null;
    _ending = false;
    _controlling = _fromKeyboard && keyboard.begin(view);
    notifyListeners();
  }

  void update(double progress, {bool dragging = false}) {
    // 手势开始就确定输入意图，不能等松手才决定是否让键盘让位。
    // 反向时也立即更新，待定回调不能继续执行上一方向。
    if (dragging && progress != _progress) {
      final open = progress > _progress;
      if (_target != open) settle(open);
    }
    _progress = progress;
    _moveKeyboard();
    notifyListeners();
  }

  void _moveKeyboard() {
    if (_controlling && !_ending) {
      final distance = _customPanel
          ? inputHeight
          : dismissing
          ? _dismissDistance +
                (inputHeight - _dismissDistance) * (1 - _release.value)
          : inputHeight * _progress;
      keyboard.update(distance - _sentDistance);
      _sentDistance = distance;
    }
  }

  void _released() {
    _moveKeyboard();
    notifyListeners();
  }

  /// 点按和松手共用目标；取消正在上拉的手势仍由原生控制器回到键盘。
  void settle(bool open, {bool restoreInput = true}) {
    final wasDismissing = dismissing;
    _target = open;
    _restoreInput = restoreInput;
    if (open) {
      _returnTimeout?.cancel();
      _returnRequested = false;
      if (_release.value == 1) {
        _release.stop();
      } else {
        _animateRelease(1);
      }
      if (_fromKeyboard && !_controlling) {
        unawaited(
          SystemChannels.textInput.invokeMethod<void>('TextInput.hide'),
        );
      }
      if (keyboard.awaitingAndroidControl && _controlTimeout == null) {
        _controlTimeout = Timer(const Duration(milliseconds: 160), () {
          _controlTimeout = null;
          if (_disposed ||
              !active ||
              _target != true ||
              !keyboard.awaitingAndroidControl) {
            return;
          }
          _controlling = false;
          keyboard.dismissPendingWithSystemAnimation();
          notifyListeners();
        });
      }
    } else if (restoreInput && !_controlling && !_customPanel) {
      _requestKeyboard();
    }
    if (!open) {
      _controlTimeout?.cancel();
      _controlTimeout = null;
    }
    if (dismissing && !wasDismissing) {
      _returnTimeout?.cancel();
      _dismissDistance = _sentDistance;
      _animateRelease(0);
    }
    notifyListeners();
  }

  void _requestKeyboard() {
    if (_returnRequested) return;
    _returnRequested = true;
    onResumeKeyboard?.call();
    // 外接键盘、系统拒绝唤起或新键盘变矮时，退去剩余占位；
    // 当前 IME 的逐帧高度始终优先，不会把实际键盘空间一并清空。
    _returnTimeout = Timer(const Duration(milliseconds: 900), () {
      if (_disposed || !active || _target != false) return;
      _animateRelease(0);
    });
  }

  void _animateRelease(double target) {
    if (_disableAnimations) {
      _release.value = target;
    } else {
      _release.animateTo(
        target,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void reachedTarget(bool open) {
    if (!_controlling || _ending) return;
    _ending = true;
    final generation = _generation;
    unawaited(() async {
      final dismiss = open || _customPanel || !_restoreInput;
      await keyboard.end(dismiss ? 1000 : 0, cancel: !dismiss);
      if (_disposed || generation != _generation) return;
      _controlling = false;
      _ending = false;
      // 原生收尾期间允许用户反向。收尾后以最新意图重新交接，不能
      // 让旧的异步完成事件把键盘/面板切回上一种状态。
      if (active && _target == false && _restoreInput && !_customPanel) {
        _requestKeyboard();
      }
      if (active && _target == true && _inset > _safeBottom) {
        unawaited(
          SystemChannels.textInput.invokeMethod<void>('TextInput.hide'),
        );
      }
      notifyListeners();
    }());
  }

  void _keyboardChanged() {
    if (!keyboard.awaitingAndroidControl) {
      _controlTimeout?.cancel();
      _controlTimeout = null;
    }
    if (active && _controlling && !_ending && !keyboard.active) {
      // 系统撤销控制权或旧系统不支持时，结束原生会话并回到普通
      // IME 帧交接；拖拽尚未松手则继续保留取消的选择。
      _controlling = false;
      unawaited(keyboard.end(0, cancel: true));
      if (_target == true) {
        unawaited(
          SystemChannels.textInput.invokeMethod<void>('TextInput.hide'),
        );
      }
    }
    if (!_disposed) notifyListeners();
  }

  void finish() {
    _generation++;
    active = false;
    if (_controlling && !_ending) unawaited(keyboard.end(0, cancel: true));
    _controlling = false;
    _returnTimeout?.cancel();
    _controlTimeout?.cancel();
    _controlTimeout = null;
    _release.stop();
    _target = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _returnTimeout?.cancel();
    _controlTimeout?.cancel();
    keyboard.removeListener(_keyboardChanged);
    _release.dispose();
    super.dispose();
  }
}
