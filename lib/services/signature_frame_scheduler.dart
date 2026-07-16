import 'dart:async';

import 'package:flutter/scheduler.dart';

import '../utils/scroll_busy_signal.dart';

/// 小尾巴动画共享自适应帧调度器。
///
/// 调度器只决定“多久采样一次动画”，时间轴仍按真实经过时间推进，因此降帧
/// 不会让动画变慢。全部签名共用一个单次 Timer；当前实现虽然只允许一个
/// SVG 同时播放，但共享设计可以避免以后放宽并发时产生多个独立定时器。
class SignatureFrameScheduler {
  SignatureFrameScheduler._();

  static final instance = SignatureFrameScheduler._();

  static const _fpsTiers = <int>[24, 12, 6];
  static const _pressureThreshold = 2;
  static const _healthyThreshold = 120;

  final Map<Object, void Function(int nowMicros)> _subscribers = {};
  final Stopwatch _clock = Stopwatch()..start();

  Timer? _timer;
  Object? _lastOwner;
  bool _dispatching = false;
  bool _timingsAttached = false;
  int _tierIndex = 0;
  int _pressureStreak = 0;
  int _healthyStreak = 0;
  int _scheduledAtMicros = 0;
  int _scheduledDelayMicros = 0;

  int get targetFps => _fpsTiers[_tierIndex];

  /// 滚动时固定使用最低档；滚动结束后恢复到负载学习得到的档位。
  int get effectiveFps => ScrollBusySignal.isBusy ? _fpsTiers.last : targetFps;

  int get debugSubscriberCount => _subscribers.length;

  void subscribe({
    required Object owner,
    required void Function(int nowMicros) onFrame,
  }) {
    _subscribers[owner] = onFrame;
    _attachTimings();
    _scheduleNext();
  }

  void unsubscribe(Object owner) {
    if (_subscribers.remove(owner) == null) return;
    if (identical(_lastOwner, owner)) _lastOwner = null;
    if (_subscribers.isEmpty) {
      _timer?.cancel();
      _timer = null;
      _detachTimings();
    } else if (!_dispatching) {
      _scheduleNext();
    }
  }

  void _attachTimings() {
    if (_timingsAttached) return;
    _timingsAttached = true;
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
  }

  void _detachTimings() {
    if (!_timingsAttached) return;
    _timingsAttached = false;
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
  }

  Duration get _interval => Duration(
    microseconds: (Duration.microsecondsPerSecond / effectiveFps).ceil(),
  );

  void _scheduleNext() {
    if (_dispatching || _subscribers.isEmpty) return;
    _timer?.cancel();
    final delay = _interval;
    _scheduledAtMicros = _clock.elapsedMicroseconds;
    _scheduledDelayMicros = delay.inMicroseconds;
    _timer = Timer(delay, _dispatch);
  }

  void _dispatch() {
    _timer = null;
    if (_subscribers.isEmpty) return;

    final wakeMicros = _clock.elapsedMicroseconds;
    final wakeLagMicros =
        wakeMicros - _scheduledAtMicros - _scheduledDelayMicros;
    final dispatchWatch = Stopwatch()..start();
    _dispatching = true;
    try {
      final owners = _subscribers.keys.toList(growable: false);
      var index = 0;
      final lastOwner = _lastOwner;
      if (lastOwner != null) {
        final lastIndex = owners.indexOf(lastOwner);
        if (lastIndex >= 0) index = (lastIndex + 1) % owners.length;
      }
      final owner = owners[index];
      _lastOwner = owner;
      _subscribers[owner]?.call(wakeMicros);
    } finally {
      dispatchWatch.stop();
      _dispatching = false;
      _recordLoad(
        workMicros: dispatchWatch.elapsedMicroseconds,
        wakeLagMicros: wakeLagMicros,
      );
      _scheduleNext();
    }
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      _recordLoad(
        workMicros:
            timing.buildDuration.inMicroseconds +
            timing.rasterDuration.inMicroseconds,
        wakeLagMicros: 0,
      );
    }
  }

  void _recordLoad({required int workMicros, required int wakeLagMicros}) {
    final expensive = workMicros >= 12000;
    final pumpDelayed = wakeLagMicros >= 8000;
    if (expensive || pumpDelayed) {
      _healthyStreak = 0;
      _pressureStreak++;
      if (_pressureStreak >= _pressureThreshold &&
          _tierIndex < _fpsTiers.length - 1) {
        _pressureStreak = 0;
        _tierIndex++;
        _reschedule();
      }
      return;
    }

    _pressureStreak = 0;
    if (workMicros <= 6000 && wakeLagMicros < 3000 && _tierIndex > 0) {
      _healthyStreak++;
      if (_healthyStreak >= _healthyThreshold) {
        _healthyStreak = 0;
        _tierIndex--;
        _reschedule();
      }
    } else {
      _healthyStreak = 0;
    }
  }

  void _reschedule() {
    if (_dispatching || _subscribers.isEmpty) return;
    _scheduleNext();
  }

  /// 单元测试使用：喂入确定性负载样本。
  void debugRecordLoad({required int workMicros, int wakeLagMicros = 0}) {
    _recordLoad(workMicros: workMicros, wakeLagMicros: wakeLagMicros);
  }

  /// 单元测试使用：清理单例状态。
  void debugReset() {
    _timer?.cancel();
    _timer = null;
    _subscribers.clear();
    _lastOwner = null;
    _dispatching = false;
    _detachTimings();
    _tierIndex = 0;
    _pressureStreak = 0;
    _healthyStreak = 0;
    _scheduledAtMicros = 0;
    _scheduledDelayMicros = 0;
  }
}
