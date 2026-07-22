import 'dart:collection';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'frame_jank_monitor.dart';

/// 帧调度归因探针:回答"这一帧是谁要求画的"。
///
/// 背景:相位拆分/span 账单回答"帧里的时间花在哪",但对"静止页面为
/// 什么还在持续出帧"(空转)无能为力——那类帧 build/raster 都很小,
/// 不触发 JANK 记录,却持续烧电烧 GPU(mermaid shimmer 出图后永动就
/// 是此类,靠人工审计才揪出)。本探针补上调度维度。
///
/// ## 归因原理
///
/// 循环 ticker 每帧的**续期注册**(rescheduling=true)发生在帧循环
/// 内部,栈全是框架帧,无归因价值;含业务栈的是**首次注册**
/// (rescheduling=false,即 start/forward/repeat 的调用点)。因此:
///
/// - 首次注册时抓一条栈,提取首个非框架帧,按 callback(实例方法
///   tearoff,同实例同方法相等)存入有界映射;
/// - 空转判定(由 [FrameJankMonitor] 的 FrameTiming 流驱动:连续
///   N 帧微负载 + 无近期指针输入)成立时 [armSpinCapture] 武装;
/// - 武装期间(一个完整帧周期)把每个续期注册的 callback 查表归因,
///   连同武装期的 scheduleFrame 直呼栈一起,归并成 `SPIN-PROF`
///   事件落进诊断时间轴,随后自动解除武装。
///
/// 成本:监控关闭时每次调度一个 bool 判断;开启时首次注册(动画
/// 启动,非每帧)各抓一条栈,常态帧路径只有查 bool;栈解析仅在
/// 注册点与武装帧发生。
mixin FrameSchedulerProbe on WidgetsFlutterBinding {
  /// callback(tearoff)→ 首次注册时的业务来源。有界,LRU 淘汰。
  final LinkedHashMap<Function, String> _callbackOrigins = LinkedHashMap();
  static const int _maxOrigins = 128;

  bool _armed = false;
  int _armedFrames = 0;
  final List<String> _captured = [];
  static const int _maxCaptured = 24;

  /// 最近一帧帧首的活跃 transient 回调数(≈活跃 ticker 数)。
  /// transient 回调在帧中被消费清空,事后读不到,只能帧首采样。
  int lastTransientCount = 0;

  /// 最近一次指针事件时刻,空转判定用(滚动/拖拽驱动的连续微负载
  /// 帧不是空转)。
  DateTime _lastPointerAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime get lastPointerAt => _lastPointerAt;

  @override
  void handlePointerEvent(PointerEvent event) {
    if (FrameJankMonitor.isRunning) {
      _lastPointerAt = DateTime.now();
    }
    super.handlePointerEvent(event);
  }

  @override
  int scheduleFrameCallback(FrameCallback callback,
      {bool rescheduling = false, bool scheduleNewFrame = true}) {
    if (FrameJankMonitor.isRunning) {
      if (!rescheduling) {
        // 首次注册 = 动画/ticker 启动点,栈里有业务帧。记名。
        _callbackOrigins.remove(callback);
        _callbackOrigins[callback] = _originOf(StackTrace.current);
        if (_callbackOrigins.length > _maxOrigins) {
          _callbackOrigins.remove(_callbackOrigins.keys.first);
        }
      } else if (_armed && _captured.length < _maxCaptured) {
        // 武装期:每个仍在续期的 ticker 查表归因
        _captured.add(_callbackOrigins[callback] ?? '(启动早于监控)');
      }
    }
    return super.scheduleFrameCallback(callback,
        rescheduling: rescheduling, scheduleNewFrame: scheduleNewFrame);
  }

  @override
  void scheduleFrame() {
    // 武装期间连 scheduleFrame 直呼也抓(setState 驱动的空转、
    // image_paint_gate 兜底续帧等不走 transient 回调的帧请求)
    if (_armed &&
        !hasScheduledFrame &&
        _captured.length < _maxCaptured &&
        FrameJankMonitor.isRunning) {
      _captured.add('frame:${_originOf(StackTrace.current)}');
    }
    super.scheduleFrame();
  }

  @override
  void handleBeginFrame(Duration? rawTimeStamp) {
    if (FrameJankMonitor.isRunning) {
      lastTransientCount = transientCallbackCount;
      if (_armed) {
        // 武装于帧间(timings 回调);第 1 个帧首只计数,让本帧的
        // 续期注册被收集;第 2 个帧首收网上报。
        _armedFrames++;
        if (_armedFrames >= 2) {
          _armed = false;
          _reportCaptured();
        }
      }
    }
    super.handleBeginFrame(rawTimeStamp);
  }

  /// 空转判定成立时由 [FrameJankMonitor] 调用:武装一个帧周期的抓取。
  void armSpinCapture() {
    if (_armed) return;
    _captured.clear();
    _armedFrames = 0;
    _armed = true;
    // 能判空转说明在持续出帧;兜底请求一帧保证武装必有结算
    // (放在置位后:此调用自身若入栈会被 hasScheduledFrame 挡掉)。
    scheduleFrame();
  }

  void _reportCaptured() {
    if (_captured.isEmpty) {
      FrameJankMonitor.logEvent(
        'SPIN-PROF',
        'transient=$lastTransientCount 武装帧无调度注册'
        '(帧源可能是引擎侧/warm-up,或空转恰好停止)',
      );
      return;
    }
    // 归并同源(同一 ticker 每帧一条),按出现次数降序,最多 6 个来源
    final counts = <String, int>{};
    for (final origin in _captured) {
      counts[origin] = (counts[origin] ?? 0) + 1;
    }
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final summary = sorted
        .take(6)
        .map((e) => e.value > 1 ? '${e.key} ×${e.value}' : e.key)
        .join(' | ');
    final more = sorted.length > 6 ? ' +${sorted.length - 6}种' : '';
    _captured.clear();
    FrameJankMonitor.logEvent(
      'SPIN-PROF',
      'transient=$lastTransientCount 来源[$summary$more]',
    );
  }

  /// 提取栈里第一个非框架帧(跳过全部 package:flutter / dart: 帧)。
  /// 通常落在 AnimationController 宿主 State 或自定义 ticker 创建者;
  /// 第三方包驱动的动画则落在该包,同样是有效归因。
  static String _originOf(StackTrace trace) {
    final lines = trace.toString().split('\n');
    for (final line in lines) {
      if (line.isEmpty ||
          line.contains('package:flutter/') ||
          line.contains('FrameSchedulerProbe') ||
          line.contains('(dart:')) {
        continue;
      }
      // "#4  _FooState._tick (package:fluxdo/....dart:42:7)"
      // → "_FooState._tick(lib/....dart:42:7)"
      final match = RegExp(r'#\d+\s+(\S+)\s+\((.+?)\)').firstMatch(line);
      if (match != null) {
        final method = match.group(1)!;
        var location = match.group(2)!;
        location = location.replaceFirst(RegExp(r'^package:[^/]+/'), '');
        return '$method($location)';
      }
      return line.trim();
    }
    return '(纯框架栈)';
  }
}
