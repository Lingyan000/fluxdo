import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:vm_service/vm_service.dart' as vms;
import 'package:vm_service/vm_service_io.dart' as vms_io;

import 'frame_jank_monitor.dart';

/// 掉帧现场自动抓取:app 内连接自身 VM Service,掉帧后拉取该帧时间窗
/// 的 timeline 事件,归并出耗时构成(阶段 + widget 级,依赖
/// debugProfileBuildsEnabled),写回 [FrameJankMonitor] 的记录。
///
/// 这替代了"连 DevTools 录 timeline → 导出 → 电脑上解析"的链路:
/// 掉帧现场自动带解剖结果,诊断页/导出报告直接可读。
///
/// 仅 debug/profile 有效(release 无 VM Service);抓取在掉帧之后异步
/// 进行且有节流(默认 2s 一次),不在渲染关键路径上。
class JankProfiler {
  JankProfiler._();

  static vms.VmService? _service;
  static bool _initTried = false;
  static DateTime _lastCapture = DateTime.fromMillisecondsSinceEpoch(0);

  /// STALL 抓取的独立节流:与帧抓取共享节流时,STALL 前总有 jank 帧
  /// 先占掉窗口,STALL-PROF 实际从未触发(生产验证)——分开计
  static DateTime _lastStallCapture = DateTime.fromMillisecondsSinceEpoch(0);

  /// 当前状态(诊断页/导出报告展示):ready / 各种失败原因
  static String status = '未初始化';

  /// 抓取节流间隔:掉帧常成串出现,一个窗口抓一次代表帧即可
  static const _throttle = Duration(seconds: 2);

  /// 单次抓取的时间窗上限(µs):防止把整段转场全拉下来
  static const _maxWindowUs = 200 * 1000;

  static Future<void> ensureInitialized() async {
    if (_initTried) return;
    _initTried = true;
    if (kReleaseMode) {
      status = 'release 构建无 VM Service';
      return;
    }
    try {
      final info = await developer.Service.getInfo();
      final httpUri = info.serverUri;
      if (httpUri == null) {
        status = 'VM Service 未开启';
        FrameJankMonitor.logEvent('PROF', status);
        return;
      }
      final wsUri = httpUri.replace(
        scheme: 'ws',
        path: '${httpUri.path}${httpUri.path.endsWith('/') ? '' : '/'}ws',
      );
      final service = await vms_io.vmServiceConnectUri(wsUri.toString());
      final vm = await service.getVM();
      if (vm.isolates?.isEmpty ?? true) {
        status = '未找到 isolate';
        FrameJankMonitor.logEvent('PROF', status);
        return;
      }
      // Dart stream:framework 的 BUILD/LAYOUT 与 debugProfileBuilds 的
      // widget 事件;Embedder stream:engine/raster 侧事件(纹理上传、
      // Rasterizer::Draw 等),raster 型大帧靠它解剖
      await service.setVMTimelineFlags(['Dart', 'Embedder']);
      _service = service;
      status = 'ready';
      FrameJankMonitor.logEvent('PROF', 'ready ($wsUri)');
    } catch (e) {
      // flutter run / IDE 附加时,getInfo 返回的是电脑侧 DDS 地址,
      // 设备上直连必然被拒 —— 这种场景下用 DevTools 即可;现场抓取
      // 面向"独立启动 profile 包日常使用"(此时可直连设备本机 VM Service)
      if ('$e'.contains('Connection refused')) {
        status = 'IDE 附加运行时不可用(独立启动应用后可用)';
      } else {
        status = '初始化失败: $e';
      }
      FrameJankMonitor.logEvent('PROF', status);
    }
  }

  /// [FrameJankMonitor] 在掉帧时调用:异步抓取该帧时间窗的 timeline
  /// 并把归并结果写回 [record]。
  ///
  /// 节流不再"一窗只抓第一帧":转场/爆发是一串掉帧,首帧往往只是
  /// 前菜。被节流抑制的帧里记住最差的一帧(totalSpan 最大),窗口结束
  /// 时补抓它——VM timeline ring buffer 保留近期事件,延迟 ≤2s 可抓。
  static void captureForFrame(FrameTiming timing, JankRecord record) {
    final service = _service;
    if (service == null) {
      // 断线后由此触发重连,当前帧放弃、后续掉帧恢复抓取
      unawaited(ensureInitialized());
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastCapture) < _throttle) {
      // 窗口内被抑制:竞选"最差帧",窗口尾统一补抓一次
      if (_pendingWorst == null ||
          timing.totalSpan > _pendingWorst!.$1.totalSpan) {
        _pendingWorst = (timing, record);
      }
      _pendingTimer ??= Timer(
        _throttle - now.difference(_lastCapture),
        _capturePendingWorst,
      );
      return;
    }
    _lastCapture = now;
    _captureInto(timing, record);
  }

  static (FrameTiming, JankRecord)? _pendingWorst;
  static Timer? _pendingTimer;

  static void _capturePendingWorst() {
    _pendingTimer = null;
    final pending = _pendingWorst;
    _pendingWorst = null;
    if (pending == null) return;
    _lastCapture = DateTime.now();
    _captureInto(pending.$1, pending.$2);
  }

  static void _captureInto(FrameTiming timing, JankRecord record) {
    final service = _service;
    if (service == null) return;

    final startUs =
        timing.timestampInMicroseconds(FramePhase.vsyncStart);
    final endUs =
        timing.timestampInMicroseconds(FramePhase.rasterFinishWallTime);
    final extent = (endUs - startUs).clamp(1000, _maxWindowUs);

    unawaited(() async {
      try {
        final timeline = await service.getVMTimeline(
          timeOriginMicros: startUs,
          timeExtentMicros: extent,
        );
        final summary = _summarize(timeline.traceEvents ?? []);
        if (summary.isNotEmpty) {
          // 追加而非覆盖:record.detail 里已有同步账单(相位/span/imageCache)
          record.appendDetail('解剖: $summary');
          FrameJankMonitor.revision.value++;
          debugPrint('[JANK-PROF] #${record.frameNumber} $summary');
        } else {
          record.appendDetail('解剖: (时间窗内无 timeline 事件)');
          FrameJankMonitor.revision.value++;
        }
      } catch (e) {
        status = '抓取失败: $e';
        FrameJankMonitor.logEvent('PROF', status);
        // 连接断开(后台挂起 / hot restart 等):重置,下次掉帧自动重连
        if ('$e'.contains('disposed') || '$e'.contains('closed')) {
          _service = null;
          _initTried = false;
        }
      }
    }());
  }

  /// STALL(UI 事件循环单任务阻塞)现场抓取:jank 抓取按帧时间窗,
  /// STALL 常发生在帧间隙、或伴随帧被 2s 节流吃掉,这里按"刚过去的
  /// [windowMs]"独立抓一窗,汇总写回诊断时间轴 —— 回答"那 ~100ms
  /// 的单任务是谁"(配合业务侧的 Timeline 标记:ParseShortPost /
  /// ParseLongChunk / MsgBusDecode 等)。与帧抓取共享节流。
  static void captureStallWindow(int windowMs) {
    final service = _service;
    if (service == null) {
      unawaited(ensureInitialized());
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastStallCapture) < _throttle) return;
    _lastStallCapture = now;

    final nowUs = developer.Timeline.now;
    final extent = (windowMs * 1000).clamp(1000, _maxWindowUs);
    unawaited(() async {
      try {
        final timeline = await service.getVMTimeline(
          timeOriginMicros: nowUs - extent,
          timeExtentMicros: extent,
        );
        final summary = _summarize(timeline.traceEvents ?? []);
        if (summary.isNotEmpty) {
          FrameJankMonitor.logEvent('STALL-PROF', summary);
        }
      } catch (_) {
        // 抓取失败不影响 STALL 事件本身;下次掉帧路径会自动重连
      }
    }());
  }

  /// 把 Chrome trace 格式事件归并为"名称 → 自击耗时(self-time)"top 列表。
  ///
  /// 旧版按名称累计 total(嵌套父子重复计数),再靠 ~90 行硬编码包装层
  /// 黑名单降噪——名单永远追不上代码演化,也违背"由数据派生"。改算
  /// self = total − 直接子事件耗时:纯包装层(Semantics/Builder/各种壳)
  /// 自击 ≈0 自然沉底,黑名单整个删除;榜上的名字就是真正花时间的代码。
  ///
  /// B/E 与 X 各自按 tid 独立配对(B/E 栈式;X 按 ts 排序 + 区间包含栈);
  /// 两族之间不互相扣减(同线程同族嵌套是常态,跨族嵌套罕见,重复计入
  /// 量级可忽略)。
  static String _summarize(List<vms.TimelineEvent> events) {
    final totals = <String, int>{};

    void addSelf(String name, int self) {
      if (self > 0) totals[name] = (totals[name] ?? 0) + self;
    }

    // ---- B/E 配对:per tid 栈式,pop 时 self = total − childUs ----
    final beStacks = <int, List<_OpenSpan>>{};
    // ---- X 事件:per tid 收集,稍后按 ts 排序做区间包含 ----
    final xByTid = <int, List<(String, int, int)>>{}; // (name, ts, dur)

    for (final e in events) {
      final json = e.json;
      if (json == null) continue;
      final ph = json['ph'] as String?;
      final name = json['name'] as String?;
      final tid = json['tid'] as int? ?? 0;
      final ts = json['ts'] as int? ?? 0;
      if (name == null) continue;
      switch (ph) {
        case 'X':
          final dur = json['dur'] as int? ?? 0;
          if (dur > 0) (xByTid[tid] ??= []).add((name, ts, dur));
        case 'B':
          (beStacks[tid] ??= []).add(_OpenSpan(name, ts));
        case 'E':
          final stack = beStacks[tid];
          if (stack != null && stack.isNotEmpty) {
            final span = stack.removeLast();
            final total = ts - span.startTs;
            if (total > 0) {
              addSelf(span.name, total - span.childUs);
              // 父的 childUs 记子的 total(孙辈已含在内,不重复上溯)
              if (stack.isNotEmpty) stack.last.childUs += total;
            }
          }
      }
    }
    // 窗口截断的未闭合 B:按窗口内已知子耗时估 self 意义不大,与旧版
    // 一致直接丢弃(截断事件由相邻窗口的完整事件代表)。

    for (final list in xByTid.values) {
      list.sort((a, b) => a.$2.compareTo(b.$2));
      final open = <_OpenX>[];
      void closeTop() {
        final x = open.removeLast();
        addSelf(x.name, x.dur - x.childUs);
      }

      for (final (name, ts, dur) in list) {
        while (open.isNotEmpty && open.last.endTs <= ts) {
          closeTop();
        }
        // 收进最内层仍然打开的包含区间(只记直接父,孙辈不重复)
        if (open.isNotEmpty && ts + dur <= open.last.endTs) {
          open.last.childUs += dur;
        }
        open.add(_OpenX(name, ts + dur, dur));
      }
      while (open.isNotEmpty) {
        closeTop();
      }
    }

    final entries = totals.entries.where((e) => e.value >= 300).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries
        .take(10)
        .map((e) => '${e.key} ${(e.value / 1000).toStringAsFixed(1)}ms')
        .join(' | ');
  }
}

/// B/E 配对栈上的未闭合事件
class _OpenSpan {
  _OpenSpan(this.name, this.startTs);
  final String name;
  final int startTs;
  int childUs = 0;
}

/// X 区间包含栈上的事件
class _OpenX {
  _OpenX(this.name, this.endTs, this.dur);
  final String name;
  final int endTs;
  final int dur;
  int childUs = 0;
}
