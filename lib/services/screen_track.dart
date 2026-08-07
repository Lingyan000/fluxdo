import 'dart:async';

import 'package:flutter/foundation.dart';

import 'cf_challenge_service.dart';
import 'discourse/discourse_service.dart';

/// 阅读时间上报成功后的回调
/// [topicId] 话题 ID
/// [postNumbers] 已上报的帖子编号集合
/// [highestSeen] 最高已读帖子编号
typedef OnTimingsSent =
    void Function(int topicId, Set<int> postNumbers, int highestSeen);

/// 帖子浏览时间追踪服务
class ScreenTrack {
  static const _flushInterval = Duration(seconds: 60);
  static const _tickInterval = Duration(seconds: 1);
  static const _pauseUnlessScrolled = Duration(minutes: 3);
  static const _maxTrackingTime = Duration(minutes: 6);
  static const _ajaxFailureDelays = [
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 40),
  ];
  static const _allowedAjaxFailures = {405, 429, 500, 501, 502, 503, 504};

  final DiscourseService _service;
  final OnTimingsSent? onTimingsSent;
  final String? debugSourceId;
  final CfChallengeService _cfService;

  int? _topicId;
  Timer? _tickTimer;
  DateTime? _lastTick;
  DateTime? _lastScrolled;
  Duration _lastFlush = Duration.zero;
  int _topicTime = 0;

  final Map<int, int> _timings = {};
  final Map<int, int> _totalTimings = {};
  final List<_ConsolidatedTiming> _consolidatedTimings = [];
  final Set<int> _readPosts = {};
  int _ajaxFailures = 0;
  DateTime? _blockSendingUntil;
  Set<int> _onscreen = {};
  Set<int> _readOnscreen = {};
  bool _inProgress = false;
  bool _hasFocus = true;

  /// abandon() 后置位:在途的 timings 请求完成也不再触发 onTimingsSent。
  /// start() 重新开始追踪时清零。
  bool _suppressCallbacks = false;

  /// CF 验证进行中标记。订阅自 [CfChallengeService.inProgressNotifier]。
  /// 为 true 时:
  /// - _tick 不再累积 _topicTime 和 _timings（避免一次性堆积几十秒的阅读时间
  ///   被服务端判定为非人类行为）
  /// - _flush / _sendNextConsolidatedTiming / _consolidateTimings 全部跳过
  /// CF 触发的瞬间还会清空已累积但未上报的数据，模拟"用户离开 topic"语义。
  bool _cfFrozen = false;

  ScreenTrack(
    this._service, {
    this.onTimingsSent,
    this.debugSourceId,
    CfChallengeService? cfService,
  }) : _cfService = cfService ?? CfChallengeService();

  void start(int topicId) {
    if (_topicId != null && _topicId != topicId) {
      _tick();
      _flush();
    }
    _reset();
    _topicId = topicId;
    _suppressCallbacks = false;
    // 监听 CF 验证状态：CF 触发时立即清空累积数据并冻结后续 tick；
    // CF 完成后从下一个 tick 起从 0 重新累积。
    _cfFrozen = _cfService.isVerifying;
    _cfService.inProgressNotifier.addListener(_onCfChange);
    _tickTimer ??= Timer.periodic(_tickInterval, (_) => _tick());
  }

  void stop() {
    if (_topicId == null) return;
    _cfService.inProgressNotifier.removeListener(_onCfChange);
    _tick();
    _flush();
    _reset();
    _topicId = null;
    _tickTimer?.cancel();
    _tickTimer = null;
  }

  /// 放弃追踪：丢弃全部已累积但未上报的数据并停止（不做最终 flush）。
  /// 「标记为未读」用——服务端刚把 last_read 回退,此刻再把本地积攒的
  /// 阅读时间发出去会立刻重新标回已读。同时抑制在途请求完成后的
  /// [onTimingsSent] 回调,避免其把本地已读游标推回去。
  void abandon() {
    if (_topicId == null) return;
    _cfService.inProgressNotifier.removeListener(_onCfChange);
    _suppressCallbacks = true;
    _reset();
    _topicId = null;
    _tickTimer?.cancel();
    _tickTimer = null;
  }

  void _onCfChange() {
    final inProgress = _cfService.inProgressNotifier.value;
    if (inProgress) {
      // 进入 CF 验证：丢弃已累积但未上报的 timings/topicTime/退避状态。
      // _totalTimings 不清——它是"上次发到哪了"的基准，CF 后继续作为去重依据。
      _timings.clear();
      _consolidatedTimings.clear();
      _topicTime = 0;
      _inProgress = false;
      _blockSendingUntil = null;
      _ajaxFailures = 0;
      _cfFrozen = true;
      debugPrint('[ScreenTrack] CF 验证开始，冻结采集并丢弃未上报数据 sourceId=$debugSourceId');
    } else {
      // CF 完成：重置 _lastTick，下次 tick 用新的时间戳算 diff，
      // 避免把 CF 期间的真实流逝时间也算进 _topicTime。
      _lastTick = DateTime.now();
      _lastScrolled = DateTime.now();
      _lastFlush = Duration.zero;
      _cfFrozen = false;
      debugPrint('[ScreenTrack] CF 验证完成，恢复采集 sourceId=$debugSourceId');
    }
  }

  void setOnscreen(Set<int> postNumbers, {Set<int>? readOnscreen}) {
    _onscreen = postNumbers;
    _readOnscreen = readOnscreen ?? {};
  }

  void scrolled() {
    _lastScrolled = DateTime.now();
  }

  void setHasFocus(bool hasFocus) {
    if (_hasFocus == hasFocus) return;
    _hasFocus = hasFocus;
    _lastTick = DateTime.now();
    _lastFlush = Duration.zero;
  }

  void _reset() {
    final now = DateTime.now();
    _lastTick = now;
    _lastScrolled = now;
    _lastFlush = Duration.zero;
    _timings.clear();
    _totalTimings.clear();
    _consolidatedTimings.clear();
    _topicTime = 0;
    _onscreen = {};
    _readOnscreen = {};
    _readPosts.clear();
    _inProgress = false;
    _ajaxFailures = 0;
    _blockSendingUntil = null;
  }

  void _tick() {
    if (_cfFrozen) return;
    final now = DateTime.now();

    // 长时间未滚动则暂停追踪
    final sinceScrolled = now.difference(_lastScrolled ?? now);
    if (sinceScrolled > _pauseUnlessScrolled) return;

    final diffDuration = now.difference(_lastTick ?? now);
    _lastTick = now;

    final diff = diffDuration.inMilliseconds;
    _lastFlush += diffDuration;

    // 检查是否需要立即上报（有新的未上报帖子）
    final rush = _timings.entries.any(
      (e) =>
          e.value > 0 &&
          !_totalTimings.containsKey(e.key) &&
          !_readPosts.contains(e.key),
    );

    if (!_inProgress && (_lastFlush > _flushInterval || rush)) {
      _flush();
    }

    if (!_inProgress) {
      _sendNextConsolidatedTiming();
    }

    if (!_hasFocus) return;

    _topicTime += diff;
    for (final postNumber in _onscreen) {
      _timings[postNumber] = (_timings[postNumber] ?? 0) + diff;
    }

    for (final postNumber in _readOnscreen) {
      _readPosts.add(postNumber);
    }
  }

  void _flush() {
    if (_cfFrozen) return;
    final topicId = _topicId;
    if (topicId == null) return;

    final newTimings = <int, int>{};
    for (final entry in _timings.entries) {
      final postNumber = entry.key;
      final time = entry.value;
      final totalTime = _totalTimings[postNumber] ?? 0;

      if (time > 0 && totalTime < _maxTrackingTime.inMilliseconds) {
        _totalTimings[postNumber] = totalTime + time;
        newTimings[postNumber] = time;
      }
      _timings[postNumber] = 0;
    }

    final highestSeen = newTimings.keys.fold<int>(
      0,
      (max, v) => v > max ? v : max,
    );

    if (highestSeen > 0) {
      if (_service.isAuthenticated) {
        _consolidateTimings(newTimings, _topicTime, topicId);
        _sendNextConsolidatedTiming();
      }
      _topicTime = 0;
    }

    _lastFlush = Duration.zero;
  }

  void _consolidateTimings(Map<int, int> timings, int topicTime, int topicId) {
    if (_cfFrozen) return;
    final existingIndex = _consolidatedTimings.indexWhere(
      (t) => t.topicId == topicId,
    );
    if (existingIndex != -1) {
      final existing = _consolidatedTimings[existingIndex];
      existing.topicTime += topicTime;
      timings.forEach((postNumber, time) {
        existing.timings[postNumber] =
            (existing.timings[postNumber] ?? 0) + time;
      });
    } else {
      _consolidatedTimings.add(
        _ConsolidatedTiming(
          topicId: topicId,
          topicTime: topicTime,
          timings: Map<int, int>.from(timings),
        ),
      );
    }
  }

  Future<void> _sendNextConsolidatedTiming() async {
    if (_cfFrozen) return;
    if (_consolidatedTimings.isEmpty) return;
    if (_inProgress) return;
    if (!_service.isAuthenticated) return;
    if (_blockSendingUntil != null &&
        _blockSendingUntil!.isAfter(DateTime.now())) {
      return;
    }

    _inProgress = true;
    final next = _consolidatedTimings.removeLast();
    try {
      final statusCode = await _service.topicsTimings(
        topicId: next.topicId,
        topicTime: next.topicTime,
        timings: next.timings,
        logContext: {
          if (debugSourceId != null) 'screenTrackSourceId': debugSourceId,
          'visiblePostCount': _onscreen.length,
          'readOnscreenCount': _readOnscreen.length,
        },
      );

      // 上报成功后调用回调，同步本地状态
      if (statusCode != null && statusCode < 400) {
        _ajaxFailures = 0;
        if (next.timings.isNotEmpty &&
            onTimingsSent != null &&
            !_suppressCallbacks) {
          final highestSeen = next.timings.keys.reduce((a, b) => a > b ? a : b);
          onTimingsSent!(next.topicId, next.timings.keys.toSet(), highestSeen);
        }
      } else {
        if (statusCode != null && _allowedAjaxFailures.contains(statusCode)) {
          final delayIndex = _ajaxFailures.clamp(
            0,
            _ajaxFailureDelays.length - 1,
          );
          _ajaxFailures += 1;
          _blockSendingUntil = DateTime.now().add(
            _ajaxFailureDelays[delayIndex],
          );
          _consolidateTimings(next.timings, next.topicTime, next.topicId);
        }
      }
    } catch (e) {
      debugPrint('[ScreenTrack] topicsTimings failed without status: $e');
    } finally {
      _inProgress = false;
      _lastFlush = Duration.zero;
    }
  }
}

class _ConsolidatedTiming {
  _ConsolidatedTiming({
    required this.topicId,
    required this.topicTime,
    required this.timings,
  });

  final int topicId;
  int topicTime;
  final Map<int, int> timings;
}
