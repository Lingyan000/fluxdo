import 'dart:async';

import 'package:flutter/scheduler.dart';

import '../utils/scroll_busy_signal.dart';

/// 小尾巴动画共享自适应帧调度器。
///
/// 调度器只决定“多久采样一次动画”，时间轴仍按真实经过时间推进，因此降帧
/// 不会让动画变慢。全部签名共用一个单次 Timer；当前实现虽然只允许一个
/// SVG 同时播放，但共享设计可以避免以后放宽并发时产生多个独立定时器。
///
/// 每次派发会推进**所有**订阅者一帧（而非轮转），这样放宽并发后每个 SVG
/// 拿到的仍然是 [effectiveFps]，不会被订阅数摊薄；总成本随订阅数线性上升，
/// 由负载学习降档兜底。
class SignatureFrameScheduler {
  SignatureFrameScheduler._();

  static final instance = SignatureFrameScheduler._();

  /// 帧率档位。顶档必须 ≤ AnimatedSvgView 关闭自适应时的固定帧率
  /// (`_playbackFps = 15`)，否则打开这个以「降低帧率减少卡顿」为名、
  /// 且默认开启的开关，反而会比关掉它更费 —— 每 tick 是两趟 SVG 全树
  /// 遍历加一次重绘，帧率上浮的成本相当可观。
  static const _fpsTiers = <int>[15, 8, 4];
  static const _pressureThreshold = 2;
  static const _healthyThreshold = 120;

  final Map<Object, void Function(int nowMicros)> _subscribers = {};
  final Stopwatch _clock = Stopwatch()..start();

  Timer? _timer;
  bool _dispatching = false;
  bool _timingsAttached = false;
  int _tierIndex = 0;
  int _pressureStreak = 0;
  int _wakeLagStreak = 0;
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
      // 复制一份再遍历:回调里可能触发 unsubscribe(如订阅者已 unmount)。
      for (final onFrame in _subscribers.values.toList(growable: false)) {
        onFrame(wakeMicros);
      }
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
      );
    }
  }

  /// [wakeLagMicros] 只有调度器自身的派发样本才携带(UI 帧样本传 null)。
  void _recordLoad({required int workMicros, int? wakeLagMicros}) {
    // 唤醒延迟走独立 streak:派发样本最高 15Hz,UI 帧样本 60-120Hz,
    // 若共用一条 streak,两个派发样本之间必然夹着几十个 UI 帧样本,
    // 任何一个健康帧都会清零连击,唤醒延迟信号永远凑不齐阈值(死通路)。
    if (wakeLagMicros != null) {
      if (wakeLagMicros >= 8000) {
        _healthyStreak = 0;
        _wakeLagStreak++;
        if (_wakeLagStreak >= _pressureThreshold &&
            _tierIndex < _fpsTiers.length - 1) {
          _wakeLagStreak = 0;
          _tierIndex++;
          _reschedule();
          return;
        }
      } else {
        _wakeLagStreak = 0;
      }
    }

    final expensive = workMicros >= 12000;
    if (expensive) {
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
    if (workMicros <= 6000 &&
        (wakeLagMicros == null || wakeLagMicros < 3000) &&
        _tierIndex > 0) {
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
  /// [wakeLagMicros] 非 null 表示派发样本,null 表示 UI 帧样本。
  void debugRecordLoad({required int workMicros, int? wakeLagMicros}) {
    _recordLoad(workMicros: workMicros, wakeLagMicros: wakeLagMicros);
  }

  /// 单元测试使用：清理单例状态。
  void debugReset() {
    _timer?.cancel();
    _timer = null;
    _subscribers.clear();
    _dispatching = false;
    _detachTimings();
    _tierIndex = 0;
    _pressureStreak = 0;
    _wakeLagStreak = 0;
    _healthyStreak = 0;
    _scheduledAtMicros = 0;
    _scheduledDelayMicros = 0;
  }
}
