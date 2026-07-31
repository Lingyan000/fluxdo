import 'dart:async';
import 'dart:io' show Directory, File, Platform, pid;
import 'dart:ui' show FramePhase;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../widgets/common/perf_overlay.dart';
import 'frame_scheduler_probe.dart';
import 'jank_profiler.dart';
import 'perf_layer_inventory.dart';

/// 一条掉帧记录(供诊断页展示与导出)
class JankRecord {
  JankRecord({
    required this.time,
    required this.frameNumber,
    required this.total,
    required this.buildDuration,
    required this.rasterDuration,
    required this.vsyncOverhead,
    this.cause,
  });

  final DateTime time;
  final int frameNumber;
  final Duration total;
  final Duration buildDuration;
  final Duration rasterDuration;
  final Duration vsyncOverhead;

  /// 归因标注,如 `nav+320ms push TopicDetailPage`(掉帧发生在导航后
  /// 1.5s 内 = 页面切换首建帧)。null 表示稳态(多为滚动/更新)。
  final String? cause;

  /// 现场解剖结果(JankProfiler 异步回填):该帧时间窗内 timeline
  /// 事件的耗时归并,如 `BUILD 12.1ms | PostItem 5.2ms | ...`。
  String? detail;

  /// 追加一段 detail(换行分隔);同步账单与异步解剖互不覆盖。
  void appendDetail(String more) {
    detail = detail == null ? more : '$detail\n$more';
  }
}

/// 一条诊断事件(NAV / MSGBUS / TYPING / SCROLL-PROBE 等)
class DiagEvent {
  const DiagEvent({required this.time, required this.tag, required this.message});

  final DateTime time;
  final String tag;
  final String message;
}

/// 一帧的 UI 线程相位耗时(µs),由 [PerfPipelineProbe] 实测墙钟填充。
///
/// FrameTiming.buildDuration 是 vsync→scene 提交的整段 UI 线程时间,
/// build/layout/paint 全混在里面(semantics 还在其外);这里把相位拆开,
/// "build 大帧"才能区分是 widget 构建贵还是排版贵——两者修法完全不同。
class PhaseSample {
  int animateUs = 0; // handleBeginFrame:ticker/动画回调
  int drawFrameUs = 0; // WidgetsBinding.drawFrame 整体(build+相位+finalize)
  int layoutUs = 0;
  int compositingBitsUs = 0;
  int paintUs = 0;
  int semanticsUs = 0;

  /// build+finalize ≈ drawFrame 总量减去四个 flush 相位。
  int get buildApproxUs =>
      (drawFrameUs - layoutUs - compositingBitsUs - paintUs - semanticsUs)
          .clamp(0, 1 << 62);

  bool get hasData => drawFrameUs > 0;

  static String _ms(int us) => (us / 1000).toStringAsFixed(1);

  /// 展示行,如 `UI相位: 动画 0.2 | build≈ 3.1 | layout 8.2 | paint 0.9 | sem 1.6`
  /// (cb 与 sem 仅在 ≥0.3ms 时显示,减少噪音)。build≈ 含 finalizeTree。
  String summaryLine() {
    final parts = <String>[
      if (animateUs >= 300) '动画 ${_ms(animateUs)}',
      'build≈ ${_ms(buildApproxUs)}',
      'layout ${_ms(layoutUs)}',
      if (compositingBitsUs >= 300) 'cb ${_ms(compositingBitsUs)}',
      'paint ${_ms(paintUs)}',
      if (semanticsUs >= 300) 'sem ${_ms(semanticsUs)}',
    ];
    return 'UI相位: ${parts.join(' | ')}';
  }
}

/// 帧卡顿监控:app 内自采、自看、自导出的掉帧诊断
///
/// 背景:DevTools 的 Performance 页开着时,timeline 上报与 trace buffer
/// 拉取本身会周期性阻塞 UI 线程(实测单次可达 140ms),体感判断会被
/// 观察者效应污染;且依赖 adb/logcat 的排查链路太长。本监控直接消费
/// engine 的 [FrameTiming] 回调,记录进内存环形缓冲,配合"性能诊断"
/// 页面即可在设备上直接查看与导出,无需连接电脑。
///
/// - debug/profile:main() 里无条件 [start]
/// - release:由设置开关(pref_perf_diagnostics)控制,诊断页可即时启停
/// - 掉帧行带场景归因:导航([JankNavObserver])、message bus、typing、
///   滚动回跳等事件经 [logEvent] 汇入同一时间轴
class FrameJankMonitor {
  FrameJankMonitor._();

  /// release 开关的 SharedPreferences key
  static const prefKey = 'pref_perf_diagnostics';

  /// 帧预算:按当前显示刷新率动态计算(120Hz→8.3ms,60Hz→16.7ms),拿不到
  /// 刷新率时退到 60Hz 预算。判定用 build/raster **各自**对比预算,而非
  /// totalSpan 对固定值——totalSpan 是流水线跨度(build+队列+raster 可以
  /// 各自达标但跨度超阈),旧的"totalSpan>10ms"在 120Hz 下大量假阳性,
  /// 既污染环形缓冲又抢占解剖节流窗口。
  ///
  /// 预算另加 [_budgetSlackUs] 余量过滤贴线噪音(与旧 10ms 阈值在 120Hz
  /// 下的宽容度一致:8.3+1.7≈10)。
  static const _budgetSlackUs = 1700;

  static int _budgetUs() {
    final rate = displayRefreshRate();
    final baseUs = (rate == null || rate < 1) ? 16667 : (1e6 / rate).round();
    return baseUs + _budgetSlackUs;
  }

  /// Logcat 汇总输出间隔
  static const _summaryInterval = Duration(seconds: 10);

  static const _maxJankRecords = 500;
  static const _maxEvents = 300;

  static bool _started = false;
  static bool get isRunning => _started;

  /// 掉帧记录(环形,最新在末尾)
  static final List<JankRecord> jankRecords = [];

  /// 诊断事件(环形,最新在末尾)
  static final List<DiagEvent> events = [];

  /// 记录变化版本号,诊断页用它驱动刷新
  static final ValueNotifier<int> revision = ValueNotifier(0);

  /// 递增 [revision],但避开 build/layout 阶段。
  ///
  /// logEvent 的调用方可能正处于 build(如 TopicPostList 在
  /// _buildRenderSegments 里汇入 MATERIALIZE 事件)—— 同步 notify 会让
  /// 诊断页的 ValueListenableBuilder 在 build 中 markNeedsBuild 直接抛
  /// FlutterError。persistentCallbacks 阶段(build/layout/paint)一律
  /// 推迟到帧后;多次调用合并为一次通知。
  static bool _revisionBumpScheduled = false;
  static void _bumpRevision() {
    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      if (_revisionBumpScheduled) return;
      _revisionBumpScheduled = true;
      binding.addPostFrameCallback((_) {
        _revisionBumpScheduled = false;
        revision.value++;
      });
      return;
    }
    revision.value++;
  }

  // 会话累计(诊断页汇总)
  static DateTime? sessionStart;
  static int sessionFrames = 0;
  static int sessionJanks = 0;
  static Duration sessionWorstBuild = Duration.zero;
  static Duration sessionWorstRaster = Duration.zero;

  // Logcat 10s 窗口
  static int _frames = 0;
  static int _janks = 0;
  static Duration _worstBuild = Duration.zero;
  static Duration _worstRaster = Duration.zero;
  static DateTime _lastSummary = DateTime.now();

  static DateTime? _lastNav;
  static String _lastNavDesc = '';
  static int _lastImageCacheBytes = 0;
  static DateTime _lastLayerInventoryAt =
      DateTime.fromMillisecondsSinceEpoch(0);

  // ---------------------------------------------------------------------------
  // 空转探测(release 可用):回答"静止页面为什么还在持续出帧"。
  //
  // 空转帧 build/raster 都极小,永远不触发 JANK 记录,却持续烧电烧
  // GPU(mermaid shimmer 出图后永动即此类,靠人工审计才揪出)。判定:
  // 连续 _spinFrameThreshold 帧微负载(build+raster < 3ms)且最近
  // _spinPointerQuiet 内无指针输入(滚动/惯性/拖拽的微负载帧不算)。
  // 成立 → 打 SPIN 事件 + 武装 FrameSchedulerProbe 抓一轮调度归因
  // (SPIN-PROF),5 分钟节流,同一空转源一个会话只报一次即够定位。
  // ---------------------------------------------------------------------------

  static int _microLoadStreak = 0;
  static DateTime _lastSpinReport = DateTime.fromMillisecondsSinceEpoch(0);
  static const int _spinFrameThreshold = 120; // 连续 ~1-2s(60/120Hz)
  static const Duration _spinPointerQuiet = Duration(seconds: 2);
  static const Duration _spinThrottle = Duration(minutes: 5);
  static const Duration _microLoad = Duration(milliseconds: 3);

  static void _spinDetect(FrameTiming t) {
    if (t.buildDuration + t.rasterDuration >= _microLoad) {
      _microLoadStreak = 0;
      return;
    }
    _microLoadStreak++;
    if (_microLoadStreak < _spinFrameThreshold) return;
    _microLoadStreak = 0;
    final binding = WidgetsBinding.instance;
    if (binding is! FrameSchedulerProbe) return;
    final FrameSchedulerProbe probe = binding;
    final now = DateTime.now();
    // 指针静默期内才算空转;交互中的微负载连击是正常滚动
    if (now.difference(probe.lastPointerAt) < _spinPointerQuiet) return;
    if (now.difference(_lastSpinReport) < _spinThrottle) return;
    _lastSpinReport = now;
    logEvent(
      'SPIN',
      '静止空转:连续 $_spinFrameThreshold 帧微负载无交互 '
      '(transient=${probe.lastTransientCount}),武装调度归因',
    );
    probe.armSpinCapture();
  }

  static void start() {
    if (_started) return;
    _started = true;
    sessionStart ??= DateTime.now();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _startStallProbes();
    // 版本指纹(异步补齐):诊断导出必须能对上代码版本,否则
    // "旧包跑出的日志被当成新修复无效"——生产排查的头号陷阱
    unawaited(PackageInfo.fromPlatform().then((info) {
      _buildFingerprint = '${info.version}+${info.buildNumber}';
    }).catchError((_) {}));
    // 掉帧现场抓取(debug/profile;release 内部自动跳过)
    unawaited(JankProfiler.ensureInitialized());
    // 悬浮监控面板:开关持久化在 prefs,跟随监控启动恢复
    unawaited(PerfOverlay.restoreIfEnabled());
    debugPrint(
      '[JANK] monitor started, budget ${(_budgetUs() / 1000).toStringAsFixed(1)}ms'
      '@${displayRefreshRate()?.toStringAsFixed(0) ?? '?'}Hz',
    );
  }

  static String? _buildFingerprint;

  static void stop() {
    if (!_started) return;
    _started = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _stopStallProbes();
    debugPrint('[JANK] monitor stopped');
  }

  // ---------------------------------------------------------------------------
  // 线程阻塞探针:归因 vsyncOverhead 型掉帧(build/raster 都小、ov 巨大)
  //
  // 这类帧的成因不在渲染管线里,而是两条线程之一被别的活堵住:
  // - UI isolate 事件循环:isolate 消息回传(compute 结果)、大 Timer 任务
  // - 平台主线程:WebView 创建/销毁/重建、CookieManager IPC、平台通道
  //   同步处理 —— vsync 通知经平台线程分发,它被堵 = ov 直接上天
  // 两个探针只在监控运行时活跃,窗口期波动做了节流,常态零输出。
  // ---------------------------------------------------------------------------

  static Timer? _uiHeartbeat;
  static DateTime? _lastBeat;
  static Timer? _platformProbe;
  static bool _platformProbeInFlight = false;
  static DateTime _lastStallLog = DateTime.fromMillisecondsSinceEpoch(0);
  static const _beatInterval = Duration(milliseconds: 50);

  /// UI 事件循环:单个任务把 timer 压后 ≥30ms 才报(帧 build 最多 20ms
  /// 级,不会误报;isolate 消息回传 40ms+ 正好落网)
  static const _uiStallThreshold = Duration(milliseconds: 30);

  /// 平台线程 RTT:正常 <2ms,>30ms 说明有重活(WebView init/destroy 等)
  static const _platformRttThreshold = Duration(milliseconds: 30);
  static const _stallLogThrottle = Duration(milliseconds: 800);

  static void _startStallProbes() {
    _lastBeat = DateTime.now();
    _uiHeartbeat = Timer.periodic(_beatInterval, (_) {
      final now = DateTime.now();
      final drift = now.difference(_lastBeat!) - _beatInterval;
      _lastBeat = now;
      if (drift >= _uiStallThreshold &&
          now.difference(_lastStallLog) >= _stallLogThrottle) {
        _lastStallLog = now;
        logEvent('STALL', 'UI 事件循环被单任务阻塞 ~${drift.inMilliseconds}ms');
        // 现场解剖:抓刚过去的阻塞窗口,点名单任务(debug/profile 有效;
        // 心跳检测发生在阻塞结束后,往回抓正好覆盖阻塞本体)
        JankProfiler.captureStallWindow(
          drift.inMilliseconds + _beatInterval.inMilliseconds,
        );
      }
    });

    _platformProbe = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_platformProbeInFlight) return;
      _platformProbeInFlight = true;
      final sw = Stopwatch()..start();
      // 故意调不存在的方法:平台侧走一遍消息分发后回 notImplemented,
      // 零副作用;RTT = 平台主线程当下的响应能力
      SystemChannels.platform
          .invokeMethod<void>('__fluxdoJankProbe__')
          .catchError((_) {})
          .whenComplete(() {
        sw.stop();
        _platformProbeInFlight = false;
        final now = DateTime.now();
        if (sw.elapsed >= _platformRttThreshold &&
            now.difference(_lastStallLog) >= _stallLogThrottle) {
          _lastStallLog = now;
          logEvent(
            'STALL',
            '平台主线程阻塞 ~${sw.elapsedMilliseconds}ms '
            '(WebView 操作/平台通道/系统 IPC)',
          );
        }
      });
    });
  }

  static void _stopStallProbes() {
    _uiHeartbeat?.cancel();
    _uiHeartbeat = null;
    _platformProbe?.cancel();
    _platformProbe = null;
  }

  /// 统一事件入口:打印到 Logcat 并汇入诊断时间轴。
  /// NAV 事件同时驱动掉帧行的导航归因。监控未启用时为空操作
  /// (release 关闭态零输出零开销)。
  static void logEvent(
    String tag,
    String message, {
    bool persistWhenStopped = false,
  }) {
    if (!_started && !persistWhenStopped) return;
    if (tag == 'NAV') {
      _lastNav = DateTime.now();
      _lastNavDesc = message;
    }
    debugPrint('[$tag] $message');
    events.add(DiagEvent(time: DateTime.now(), tag: tag, message: message));
    if (events.length > _maxEvents) {
      events.removeRange(0, events.length - _maxEvents);
    }
    _bumpRevision();
  }

  /// 兼容旧调用:导航事件
  static void noteNavigation(String desc) => logEvent('NAV', desc);

  // ---------------------------------------------------------------------------
  // 帧内构建归因(release 可用):回答"这个 build 大帧在建什么"。
  //
  // 稳态滚动的掉帧几乎全是 build 型(6~16ms),但 release 无 VM Service,
  // JANK 行分不清是"物化新帖的一次性成本"、"整页 rebuild 风暴"还是
  // "GC/UI 线程被非帧工作挤占"(三者修法完全不同)。重组件(PostItem /
  // 长帖分段)在 build 时上报自己,按帧号存最近 64 帧;JANK 记录时把
  // 同帧清单写进 detail:
  // - 清单只有 1~2 个新帖 = 单帖首建成本(树/排版瘦身方向)
  // - 清单一大串 = rebuild 风暴(缓存/短路方向)
  // - 清单为空但 build 巨大 = GC 停顿或 UI 线程被挤占(另案)
  // ---------------------------------------------------------------------------

  static final Map<int, List<String>> _buildNotes = {};

  // ---------------------------------------------------------------------------
  // 帧内 span 账单(release 可用):回答"这几毫秒花在谁身上、花了多少"。
  //
  // noteBuild 是"在场名单"(谁 build 了),span 是"账单"(layout/paint/解析
  // 各花了几 µs)。来源:PerfSpanBox 代理盒(lay:/pnt: 前缀,子树粒度)与
  // RenderParseCache(parse: 前缀)。按帧号存最近 64 帧,JANK 记录时把同帧
  // 账单降序 top 若干写进 detail,并给出"未覆盖余量"(相位总量 − span 合计)
  // ——余量大说明大头在埋点之外(框架/第三方),盲区大小自见。
  // ---------------------------------------------------------------------------

  static final Map<int, List<(String, int)>> _spans = {};

  /// 计时埋点上报:label 建议带前缀(lay:/pnt:/parse:),micros 为耗时 µs。
  /// 监控关闭时零开销。
  static void noteSpan(String label, int micros) {
    if (!_started) return;
    final frame =
        WidgetsBinding.instance.platformDispatcher.frameData.frameNumber;
    (_spans[frame] ??= []).add((label, micros));
    if (_spans.length > 64) {
      int? oldest;
      for (final k in _spans.keys) {
        if (oldest == null || k < oldest) oldest = k;
      }
      _spans.remove(oldest);
    }
  }

  /// 本帧 span 账单行:降序 top6 + layout 未覆盖余量。
  /// [phase] 提供 layout 相位总量时,余量 = layout − Σ(lay: span);
  /// 余量 >1ms 才展示——它是"埋点盲区"的量化指标。
  static String? _spanLineFor(int frameNumber, PhaseSample? phase) {
    final spans = _spans[frameNumber];
    if (spans == null || spans.isEmpty) return null;
    final sorted = [...spans]..sort((a, b) => b.$2.compareTo(a.$2));
    final head = sorted
        .take(6)
        .map((s) => '${s.$1} ${(s.$2 / 1000).toStringAsFixed(1)}')
        .join(' | ');
    final more = sorted.length > 6 ? ' +${sorted.length - 6}' : '';
    var line = 'spans[$head$more]';
    if (phase != null && phase.layoutUs > 0) {
      var layCovered = 0;
      for (final s in spans) {
        if (s.$1.startsWith('lay:')) layCovered += s.$2;
      }
      final uncovered = phase.layoutUs - layCovered;
      if (uncovered > 1000) {
        line += ' 未覆盖 layout ≈${(uncovered / 1000).toStringAsFixed(1)}ms';
      }
    }
    return line;
  }

  // ---------------------------------------------------------------------------
  // UI 相位样本(release 可用):PerfPipelineProbe 按帧号写入,JANK 时取用。
  // ---------------------------------------------------------------------------

  static final Map<int, PhaseSample> _phases = {};

  /// 取(或建)指定帧的相位槽,PerfPipelineProbe 在各相位累加耗时。
  /// 监控关闭时返回 null(调用方直通,不计时)。
  static PhaseSample? phaseSlot(int frameNumber) {
    if (!_started) return null;
    final slot = _phases[frameNumber] ??= PhaseSample();
    if (_phases.length > 64) {
      int? oldest;
      for (final k in _phases.keys) {
        if (oldest == null || k < oldest) oldest = k;
      }
      _phases.remove(oldest);
    }
    return slot;
  }

  /// 重组件 build 时上报(监控关闭时零开销)
  static void noteBuild(String key) {
    if (!_started) return;
    final frame =
        WidgetsBinding.instance.platformDispatcher.frameData.frameNumber;
    (_buildNotes[frame] ??= []).add(key);
    if (_buildNotes.length > 64) {
      int? oldest;
      for (final k in _buildNotes.keys) {
        if (oldest == null || k < oldest) oldest = k;
      }
      _buildNotes.remove(oldest);
    }
  }

  static String? _buildNotesFor(int frameNumber) {
    final notes = _buildNotes[frameNumber];
    if (notes == null || notes.isEmpty) return null;
    final head = notes.take(12).join(' ');
    final more = notes.length > 12 ? ' +${notes.length - 12}' : '';
    return 'build[$head$more]';
  }

  /// 最近 [frames] 帧的构建清单摘要。SCROLL-PROBE 类事件的归因线索:
  /// SliverList 的 scrollOffsetCorrection 型回跳,嫌疑对象就是跳变前
  /// 刚物化/重建的 item(重挂载高度与上次记账不符才触发修正)。
  static String recentBuildNotes({int frames = 3}) {
    if (_buildNotes.isEmpty) return '(无)';
    final keys = _buildNotes.keys.toList()..sort();
    final take = keys.length < frames ? keys.length : frames;
    final parts = <String>[];
    for (final k in keys.sublist(keys.length - take)) {
      final notes = _buildNotes[k];
      if (notes == null || notes.isEmpty) continue;
      final head = notes.take(6).join(' ');
      parts.add(notes.length > 6 ? '$head+${notes.length - 6}' : head);
    }
    return parts.isEmpty ? '(无)' : parts.join(' / ');
  }

  static void clear() {
    jankRecords.clear();
    events.clear();
    _spans.clear();
    _phases.clear();
    _buildNotes.clear();
    sessionStart = DateTime.now();
    sessionFrames = 0;
    sessionJanks = 0;
    sessionWorstBuild = Duration.zero;
    sessionWorstRaster = Duration.zero;
    _bumpRevision();
  }

  static String _ms(Duration d) =>
      (d.inMicroseconds / 1000).toStringAsFixed(1);

  static void _onTimings(List<FrameTiming> timings) {
    var changed = false;
    final budgetUs = _budgetUs();
    final budget = Duration(microseconds: budgetUs);
    for (final t in timings) {
      _frames++;
      sessionFrames++;
      _spinDetect(t);
      if (t.buildDuration > _worstBuild) _worstBuild = t.buildDuration;
      if (t.rasterDuration > _worstRaster) _worstRaster = t.rasterDuration;
      if (t.buildDuration > sessionWorstBuild) {
        sessionWorstBuild = t.buildDuration;
      }
      if (t.rasterDuration > sessionWorstRaster) {
        sessionWorstRaster = t.rasterDuration;
      }
      // 判定:build/raster 各自超各自预算才算掉帧。流水线并行下 totalSpan
      // 可以在两端都达标时超阈(build 4 + 队列 2 + raster 5 @120Hz),那不丢帧。
      if (t.buildDuration > budget || t.rasterDuration > budget) {
        _janks++;
        sessionJanks++;
        final nav = _lastNav;
        final sinceNav = nav == null
            ? null
            : DateTime.now().difference(nav).inMilliseconds;
        final cause = sinceNav != null && sinceNav < 1500
            ? 'nav+${sinceNav}ms $_lastNavDesc'
            : null;
        debugPrint(
          '[JANK] #${t.frameNumber} total ${_ms(t.totalSpan)}ms '
          '(build ${_ms(t.buildDuration)} / raster ${_ms(t.rasterDuration)} '
          '/ vsyncOverhead ${_ms(t.vsyncOverhead)})'
          '${cause == null ? '' : ' [$cause]'}',
        );
        final record = JankRecord(
          time: DateTime.now(),
          frameNumber: t.frameNumber,
          total: t.totalSpan,
          buildDuration: t.buildDuration,
          rasterDuration: t.rasterDuration,
          vsyncOverhead: t.vsyncOverhead,
          cause: cause,
        );
        // ---- detail 组装:多行结构 ----
        // 行1: UI 相位拆分(PerfPipelineProbe 实测,有数据才出)
        // 行2: span 账单(PerfSpanBox / parse 埋点,有数据才出)
        // 行3: 队列等待 / build 名单 / imageCache 等短条目(| 分隔)
        // JankProfiler 异步解剖经 appendDetail 追加,不覆盖以上同步账单。
        final lines = <String>[];
        final phase = _phases[t.frameNumber];
        if (phase != null && phase.hasData) {
          lines.add(phase.summaryLine());
        }
        final spanLine = _spanLineFor(t.frameNumber, phase);
        if (spanLine != null) lines.add(spanLine);

        final details = <String>[];
        // 排队拆分:total 远大于三分项之和的帧,缺口在 buildFinish →
        // rasterStart 之间(raster 线程忙别的活/抢不到核,帧在管线里干等)。
        // 显式写出"等待"vs"实干",高负载卡顿的定性不再靠减法心算。
        final queueMs = (t.timestampInMicroseconds(FramePhase.rasterStart) -
                t.timestampInMicroseconds(FramePhase.buildFinish)) /
            1000.0;
        if (queueMs > 3) {
          details.add('队列等待 ${queueMs.toStringAsFixed(1)}ms');
        }
        // build 大帧:附本帧构建清单(为空 = 空转/GC/线程挤占,见 noteBuild)
        if (t.buildDuration > const Duration(milliseconds: 6)) {
          final notes = _buildNotesFor(t.frameNumber);
          if (notes != null) {
            details.add(notes);
          } else {
            details.add('build[无构建记录:疑 rebuild/GC/线程挤占]');
          }
        }
        // raster 大帧(>40ms)十有八九是纹理上传:附 ImageCache 增量快照,
        // 生产日志(无 VM Service)也能指认"这帧前后进了几张/多大的图"
        if (t.rasterDuration > const Duration(milliseconds: 40)) {
          final cache = PaintingBinding.instance.imageCache;
          final sizeMb =
              (cache.currentSizeBytes / (1024 * 1024)).toStringAsFixed(1);
          final deltaMb = ((cache.currentSizeBytes - _lastImageCacheBytes) /
                  (1024 * 1024))
              .toStringAsFixed(1);
          details.add(
              'imageCache ${cache.currentSize}张/${sizeMb}MB (Δ${deltaMb}MB) '
              'pending=${cache.pendingImageCount}');
          // dec 归因:上传发生在解码完成点(与首绘可差多帧),dec 事件
          // 记录在解码那一帧的构建名单里。raster 大帧本身多是 build 极小
          // 的帧(不满足上面 build>6ms 的名单条件),这里按 raster 口径
          // 独立附上 —— 同帧/邻帧见 dec = 上传嫌疑坐实;零 dec = 排除
          // 图片,矛头转 PSO 编译/平台线程挤占等(2026-07-22 首屏簇
          // 291 张图零 dec 记录的归因盲区,即此条件缺失)。
          final notes = _buildNotesFor(t.frameNumber);
          if (notes != null && notes.contains('dec:')) {
            details.add(notes);
          }
          // 图层清单:分类点名本帧(近似)提交了什么(pictures 字节/saveLayer
          // 源/平台视图/纹理)+ 与上次大帧 diff。独立节流,遍历不常发生。
          final now = DateTime.now();
          if (now.difference(_lastLayerInventoryAt) >=
              const Duration(seconds: 2)) {
            _lastLayerInventoryAt = now;
            final inventory = LayerInventory.capture();
            if (inventory != null) details.add(inventory);
          }
        }
        if (details.isNotEmpty) {
          lines.add(details.join(' | '));
        }
        if (lines.isNotEmpty) {
          record.detail = lines.join('\n');
        }
        _lastImageCacheBytes =
            PaintingBinding.instance.imageCache.currentSizeBytes;
        jankRecords.add(record);
        if (jankRecords.length > _maxJankRecords) {
          jankRecords.removeRange(0, jankRecords.length - _maxJankRecords);
        }
        // 异步抓取该帧的 timeline 解剖(节流在 profiler 内部)
        JankProfiler.captureForFrame(t, record);
        // jank 爆发时自动抓一次线程 CPU 分布(卡顿不必现,人工采样永远
        // 慢一步;30s 节流)
        _maybeAutoCpuSample(t);
        changed = true;
      }
    }
    if (changed) _bumpRevision();

    final now = DateTime.now();
    if (now.difference(_lastSummary) >= _summaryInterval && _frames > 0) {
      final semanticsEnabled = SemanticsBinding.instance.semanticsEnabled;
      debugPrint(
        '[JANK] summary: $_janks/$_frames janky, '
        'worst build ${_ms(_worstBuild)}ms, '
        'worst raster ${_ms(_worstRaster)}ms, '
        'budget ${(budgetUs / 1000).toStringAsFixed(1)}ms'
        '@${displayRefreshRate()?.toStringAsFixed(0) ?? '?'}Hz, '
        'semantics: ${semanticsEnabled ? countSemanticsNodes() : 'off'}, '
        'platform views: ${countPlatformViews()}',
      );
      _lastSummary = now;
      _frames = 0;
      _janks = 0;
      _worstBuild = Duration.zero;
      _worstRaster = Duration.zero;
    }
  }

  // ---------------------------------------------------------------------------
  // 线程 CPU 采样(release 可用,Android/Linux):回答"CPU 烧在谁身上"。
  //
  // 读 /proc/self/task/*/stat 两次(间隔 1s)取 utime+stime 差值,按线程
  // 归类排序写入时间轴。USER_HZ=100 → 1s 窗口内的 tick 数值上等于
  // 单核占用百分比,无需换算。触发:jank 爆发(1s 内 ≥8 掉帧或单帧
  // total>40ms)自动一次(30s 节流),悬浮面板可手动。
  // ---------------------------------------------------------------------------

  static bool get cpuSampleSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isLinux);

  static DateTime _lastCpuSampleAt = DateTime.fromMillisecondsSinceEpoch(0);
  static bool _cpuSampling = false;
  static final List<DateTime> _recentJankTimes = [];

  static void _maybeAutoCpuSample(FrameTiming t) {
    if (!cpuSampleSupported || _cpuSampling) return;
    final now = DateTime.now();
    _recentJankTimes.add(now);
    while (_recentJankTimes.isNotEmpty &&
        now.difference(_recentJankTimes.first) > const Duration(seconds: 1)) {
      _recentJankTimes.removeAt(0);
    }
    final burst = _recentJankTimes.length >= 8 ||
        t.totalSpan > const Duration(milliseconds: 40);
    if (!burst) return;
    if (now.difference(_lastCpuSampleAt) < const Duration(seconds: 30)) return;
    _lastCpuSampleAt = now;
    unawaited(sampleThreadCpu(reason: 'jank爆发'));
  }

  /// 采一次线程 CPU 分布(1s 窗口)并写入时间轴。悬浮面板手动触发也走这。
  static Future<void> sampleThreadCpu({String reason = '手动'}) async {
    if (!cpuSampleSupported || _cpuSampling || !_started) return;
    _cpuSampling = true;
    try {
      final first = await _readThreadTicks();
      await Future.delayed(const Duration(seconds: 1));
      final second = await _readThreadTicks();
      if (first.isEmpty || second.isEmpty) return;

      final byGroup = <String, int>{};
      final ungrouped = <String, int>{};
      var total = 0;
      second.forEach((tid, info) {
        final prev = first[tid];
        if (prev == null) return;
        final d = info.$2 - prev.$2;
        if (d <= 0) return;
        total += d;
        final g = _threadGroup(tid, info.$1);
        byGroup[g] = (byGroup[g] ?? 0) + d;
        // "其它"组按原始线程名单独记账:分组表没覆盖到的大户
        // (生产采样出现过"其它 59%")需要能直接看到线程名定位
        if (g == '其它') {
          ungrouped[info.$1] = (ungrouped[info.$1] ?? 0) + d;
        }
      });
      if (total <= 0) {
        logEvent('CPU', '$reason:1s 窗口内进程近乎空闲');
        return;
      }
      final parts =
          (byGroup.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
              .take(6)
              .map((e) => '${e.key} ${e.value}%')
              .join(' | ');
      final otherDetail = ungrouped.isEmpty
          ? ''
          : ' | 其它明细: ${(ungrouped.entries.toList()
                ..sort((a, b) => b.value.compareTo(a.value)))
              .take(3)
              .map((e) => '${e.key} ${e.value}%')
              .join(' / ')}';
      logEvent('CPU', '$reason 采样(单核%): $parts | 进程合计 $total%$otherDetail');
    } catch (e) {
      logEvent('CPU', '采样失败: $e');
    } finally {
      _cpuSampling = false;
    }
  }

  /// tid → (线程名, utime+stime ticks)。
  static Future<Map<int, (String, int)>> _readThreadTicks() async {
    final result = <int, (String, int)>{};
    try {
      await for (final e in Directory('/proc/self/task').list()) {
        final tid = int.tryParse(e.path.split('/').last);
        if (tid == null) continue;
        try {
          final stat = await File('${e.path}/stat').readAsString();
          // comm 在括号内且可能含空格:定位最后一个 ')'
          final close = stat.lastIndexOf(')');
          if (close < 0) continue;
          final name = stat.substring(stat.indexOf('(') + 1, close);
          final fields = stat.substring(close + 2).split(' ');
          // stat 第 14/15 字段是 utime/stime,')' 后偏移 11/12
          if (fields.length < 13) continue;
          final utime = int.tryParse(fields[11]) ?? 0;
          final stime = int.tryParse(fields[12]) ?? 0;
          result[tid] = (name, utime + stime);
        } catch (_) {
          // 线程窗口期退出,跳过
        }
      }
    } catch (_) {}
    return result;
  }

  static String _threadGroup(int tid, String name) {
    if (tid == pid) return 'main平台线程';
    if (name.contains('.ui')) return 'ui(Dart)';
    if (name.contains('.raster')) return 'raster';
    if (name.contains('.io')) return 'io';
    if (name.startsWith('DartWorker') ||
        name.startsWith('Worker') ||
        name.startsWith('io.flutter')) {
      return 'worker(解码等)';
    }
    if (name.startsWith('Chrome') ||
        name.startsWith('Compositor') ||
        name.startsWith('CookieMonster') ||
        name.startsWith('ThreadPool') ||
        name.startsWith('Network') ||
        name.startsWith('VizCompositor')) {
      return 'webview';
    }
    if (name.startsWith('Cronet') || name.contains('OkHttp')) return '网络';
    if (name.startsWith('mali') ||
        name.startsWith('Adreno') ||
        name.contains('GPU')) {
      return 'gpu驱动';
    }
    if (name.contains('GC') || name.contains('Heap') || name.startsWith('Jit')) {
      return 'gc/jit';
    }
    return '其它';
  }

  /// 当前语义树节点总数(未启用语义时为 -1)。
  ///
  /// 滚动时每帧的语义几何更新成本正比于可见节点数;这个数字用来
  /// 判断语义树是否臃肿、以及合并/裁剪优化的效果。
  /// 多视图架构下语义树挂在子 PipelineOwner 上,需整树遍历。
  static int countSemanticsNodes() {
    var count = 0;
    void visitOwner(PipelineOwner owner) {
      final root = owner.semanticsOwner?.rootSemanticsNode;
      if (root != null) {
        void visit(SemanticsNode node) {
          count++;
          node.visitChildren((child) {
            visit(child);
            return true;
          });
        }

        visit(root);
      }
      owner.visitChildren(visitOwner);
    }

    visitOwner(RendererBinding.instance.rootPipelineOwner);
    return count == 0 ? -1 : count;
  }

  /// 当前渲染树中的 platform view 数(RenderObject 类型名匹配)。
  ///
  /// timeline 里出现 AndroidExternalViewEmbedder2::SubmitFlutterView 且
  /// 耗时可观,说明合成走了 external view embedder 路径 —— 树上存在
  /// platform view,哪怕不可见(Overlay 残留、下层缓存页面等)。
  /// headless WebView 不进渲染树,不计入。用这个数字定案"页面无内嵌
  /// WebView 却有合成税"到底是谁挂在树上。
  static int countPlatformViews() {
    var count = 0;
    void visit(RenderObject node) {
      final name = node.runtimeType.toString();
      if (name.contains('PlatformView') ||
          name.contains('AndroidView') ||
          name.contains('UiKitView') ||
          name.contains('AppKitView') ||
          name.contains('DarwinPlatformView')) {
        count++;
      }
      node.visitChildren(visit);
    }

    void visitOwner(PipelineOwner owner) {
      final root = owner.rootNode;
      if (root != null) visit(root);
      owner.visitChildren(visitOwner);
    }

    visitOwner(RendererBinding.instance.rootPipelineOwner);
    return count;
  }

  /// 当前显示刷新率(拿不到时为 null)
  static double? displayRefreshRate() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return null;
    return views.first.display.refreshRate;
  }

  /// 退后台时把当前诊断导出落盘一份(logs/perf_diag_last.txt,整文件覆盖)。
  /// 进程随后被杀时环形缓冲里的现场不再全丢;诊断页提供读取与分享入口。
  /// 静默失败:落盘是尽力而为,不能反过来干扰退后台路径。
  static Future<void> persistSnapshot() async {
    if (!_started || (jankRecords.isEmpty && events.isEmpty)) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/logs/perf_diag_last.txt');
      await file.parent.create(recursive: true);
      await file.writeAsString(exportText());
    } catch (_) {}
  }

  /// 上次会话快照文件(不存在时返回 null)。诊断页展示与分享用。
  static Future<File?> snapshotFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/logs/perf_diag_last.txt');
      return await file.exists() ? file : null;
    } catch (_) {
      return null;
    }
  }

  /// 生成导出文本:头部汇总 + jank/事件合并时间轴(时间正序)
  static String exportText() {
    final buf = StringBuffer();
    final start = sessionStart;
    final elapsed = start == null
        ? null
        : DateTime.now().difference(start);
    final rate = sessionFrames == 0
        ? 0.0
        : sessionJanks / sessionFrames * 100;
    final semanticsEnabled = SemanticsBinding.instance.semanticsEnabled;
    buf.writeln('FluxDO 性能诊断导出');
    buf.writeln('应用版本: ${_buildFingerprint ?? '?'}');
    buf.writeln('导出时间: ${DateTime.now()}');
    if (elapsed != null) {
      buf.writeln('会话时长: ${elapsed.inMinutes}m${elapsed.inSeconds % 60}s');
    }
    buf.writeln(
      '帧数: $sessionFrames, 掉帧: $sessionJanks (${rate.toStringAsFixed(1)}%)',
    );
    buf.writeln(
      'worst build: ${_ms(sessionWorstBuild)}ms, '
      'worst raster: ${_ms(sessionWorstRaster)}ms',
    );
    buf.writeln(
      '刷新率: ${displayRefreshRate()?.toStringAsFixed(0) ?? '?'}Hz, '
      '判定预算: ${(_budgetUs() / 1000).toStringAsFixed(1)}ms(build/raster 各自)',
    );
    buf.writeln(
      '语义树: ${semanticsEnabled ? '${countSemanticsNodes()} 节点' : '未启用'}',
    );
    buf.writeln('platform views: ${countPlatformViews()}');
    buf.writeln('监控状态: ${_started ? '运行中' : '已停止'}');
    buf.writeln('现场抓取: ${JankProfiler.status}');
    buf.writeln('--- 时间轴(旧→新) ---');

    String fmtTime(DateTime t) =>
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}.'
        '${t.millisecond.toString().padLeft(3, '0')}';

    final lines = <(DateTime, String)>[
      for (final e in events) (e.time, '${fmtTime(e.time)}  [${e.tag}] ${e.message}'),
      for (final j in jankRecords)
        (
          j.time,
          '${fmtTime(j.time)}  JANK #${j.frameNumber} total ${_ms(j.total)}ms '
              '(build ${_ms(j.buildDuration)} / raster ${_ms(j.rasterDuration)} '
              '/ ov ${_ms(j.vsyncOverhead)})'
              '${j.cause == null ? '' : ' [${j.cause}]'}'
              '${j.detail == null ? '' : '\n           ↳ ${j.detail!.replaceAll('\n', '\n           ↳ ')}'}'
        ),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    for (final l in lines) {
      buf.writeln(l.$2);
    }
    return buf.toString();
  }
}

/// 导航事件观察者:配合 [FrameJankMonitor] 给掉帧日志做场景归因。
/// 页面切换后 1.5s 内的掉帧会带 [nav+XXXms] 标注 —— 首建/转场帧与
/// 滚动帧一眼区分,不再需要靠回忆"当时在干什么"。
class JankNavObserver extends NavigatorObserver {
  String _desc(Route<dynamic>? route) =>
      route?.settings.name ?? route.runtimeType.toString();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    FrameJankMonitor.noteNavigation('push ${_desc(route)}');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    FrameJankMonitor.noteNavigation('pop → ${_desc(previousRoute)}');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    FrameJankMonitor.noteNavigation('replace ${_desc(newRoute)}');
  }
}
