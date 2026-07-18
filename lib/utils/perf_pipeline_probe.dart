import 'dart:ui' as ui show SemanticsUpdate;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'frame_jank_monitor.dart';

/// UI 线程相位探针:把一帧 UI 线程时间拆成 动画/build/layout/
/// compositingBits/paint/semantics,实测墙钟写入 [FrameJankMonitor]。
///
/// 背景:FrameTiming.buildDuration 是 vsync→scene 提交的整段 UI 线程
/// 时间,build 与 layout 混在一起(semantics 还在其外),"build 大帧"到底
/// 是 widget 构建贵还是文本排版贵分不出来,而两者修法完全不同(缓存/
/// 短路 vs 排版瘦身/分段)。相位一拆,JANK 行直接给出答案,release 同权
/// (不依赖 VM Service)。
///
/// 实现依据(SDK 3.44 源码验证):
/// - RendererBinding.createRootPipelineOwner 官方注明可覆写;
/// - 根 PipelineOwner 的四个 flush* 均 public 且尾部递归子 owner,
///   包根即包全树(多 view/子 owner 都计入);
/// - WidgetsBinding.drawFrame = buildScope → super.drawFrame(四个
///   flush + compositeFrame)→ finalizeTree,动画/ticker 在
///   handleBeginFrame。build≈ = drawFrame 总量 − 四相位(含 finalize
///   与 compositeFrame 的 scene 组装,量级通常可忽略)。
///
/// 成本:监控关闭时每相位仅一次 bool 判断;开启时每帧 6 次
/// Stopwatch 起停 + 一次 map 写入,微秒级。
mixin PerfPipelineProbe on WidgetsFlutterBinding {
  final Stopwatch _phaseWatch = Stopwatch();

  /// handleBeginFrame 的动画耗时暂存:引擎 hook `_beginFrame` 是先派发
  /// onBeginFrame、后更新 frameData.frameNumber(sky_engine hooks.dart),
  /// 在 handleBeginFrame 里读帧号拿到的是上一帧旧值。先存这里,到
  /// drawFrame(帧号已更新,与 FrameTiming.frameNumber 对齐)再入槽。
  int _pendingAnimateUs = 0;

  int get _frameNumber => platformDispatcher.frameData.frameNumber;

  @override
  PipelineOwner createRootPipelineOwner() {
    return _PerfRootPipelineOwner();
  }

  @override
  void handleBeginFrame(Duration? rawTimeStamp) {
    if (!FrameJankMonitor.isRunning) {
      super.handleBeginFrame(rawTimeStamp);
      return;
    }
    _phaseWatch
      ..reset()
      ..start();
    try {
      super.handleBeginFrame(rawTimeStamp);
    } finally {
      _phaseWatch.stop();
      _pendingAnimateUs += _phaseWatch.elapsedMicroseconds;
    }
  }

  @override
  void drawFrame() {
    final slot = FrameJankMonitor.phaseSlot(_frameNumber);
    if (slot == null) {
      _pendingAnimateUs = 0;
      super.drawFrame();
      return;
    }
    slot.animateUs += _pendingAnimateUs;
    _pendingAnimateUs = 0;
    final watch = Stopwatch()..start();
    try {
      super.drawFrame();
    } finally {
      watch.stop();
      slot.drawFrameUs += watch.elapsedMicroseconds;
    }
  }
}

/// 根 pipeline owner:flush* 计时后转发。默认根 owner 不管理渲染树
/// (rootNode 不赋值),仅作为子 owner 的树根,行为与
/// _DefaultRootPipelineOwner 一致(onSemanticsUpdate 不应被调到)。
base class _PerfRootPipelineOwner extends PipelineOwner {
  _PerfRootPipelineOwner() : super(onSemanticsUpdate: _onSemanticsUpdate);

  static void _onSemanticsUpdate(ui.SemanticsUpdate _) {
    // 根 owner 不挂 rootNode,永远不该收到 semantics update
    // (与 SDK _DefaultRootPipelineOwner 的 assert 语义一致)。
    assert(false, 'Root pipeline owner does not manage a render tree.');
  }

  static final Stopwatch _watch = Stopwatch();

  void _timed(int frameNumber, void Function() flush,
      void Function(PhaseSample slot, int us) add) {
    final slot = FrameJankMonitor.phaseSlot(frameNumber);
    if (slot == null) {
      flush();
      return;
    }
    _watch
      ..reset()
      ..start();
    try {
      flush();
    } finally {
      _watch.stop();
      add(slot, _watch.elapsedMicroseconds);
    }
  }

  int get _frameNumber => WidgetsBinding
      .instance.platformDispatcher.frameData.frameNumber;

  @override
  void flushLayout() =>
      _timed(_frameNumber, super.flushLayout, (s, us) => s.layoutUs += us);

  @override
  void flushCompositingBits() => _timed(_frameNumber,
      super.flushCompositingBits, (s, us) => s.compositingBitsUs += us);

  @override
  void flushPaint() =>
      _timed(_frameNumber, super.flushPaint, (s, us) => s.paintUs += us);

  @override
  void flushSemantics() => _timed(
      _frameNumber, super.flushSemantics, (s, us) => s.semanticsUs += us);
}
