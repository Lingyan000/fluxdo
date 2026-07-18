import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../utils/frame_jank_monitor.dart';

/// 子树计时盒:测量所包子树的 layout / paint 耗时,上报
/// [FrameJankMonitor.noteSpan](lay:/pnt: 前缀)。
///
/// noteBuild 是"在场名单"(谁在本帧 build 了),这里是"账单"(该子树的
/// 排版/绘制各花了几 µs)。layout 同步递归,performLayout 包住 super
/// 测到的就是整棵子树的排版成本;帖子正文的文本排版(长帖大表格)
/// 正是 build 型大帧里最常见却从未被单独计量的大头。
///
/// 纯代理盒,无任何视觉/布局影响。子树不脏时框架跳过 layout/paint,
/// 天然零调用;监控关闭时仅一次 bool 判断。
class PerfSpanBox extends SingleChildRenderObjectWidget {
  const PerfSpanBox({super.key, required this.label, super.child});

  /// 账单条目名,如 `post#42`、`card#3021`(上报时自动加 lay:/pnt: 前缀)
  final String label;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderPerfSpanBox(label: label);

  @override
  void updateRenderObject(
      BuildContext context, RenderPerfSpanBox renderObject) {
    renderObject.label = label;
  }
}

class RenderPerfSpanBox extends RenderProxyBox {
  RenderPerfSpanBox({required this.label});

  String label;

  // 实例字段而非静态:span 盒会嵌套(长帖整体 span 内含分段 span),
  // layout 递归时共享秒表会被内层 reset 踩掉外层计时。
  final Stopwatch _watch = Stopwatch();

  @override
  void performLayout() {
    if (!FrameJankMonitor.isRunning) {
      super.performLayout();
      return;
    }
    _watch
      ..reset()
      ..start();
    try {
      super.performLayout();
    } finally {
      _watch.stop();
      FrameJankMonitor.noteSpan('lay:$label', _watch.elapsedMicroseconds);
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!FrameJankMonitor.isRunning) {
      super.paint(context, offset);
      return;
    }
    // 注意:paint 里子树若有 RepaintBoundary,其内容不在本次调用内重绘,
    // pnt: 数值是"本边界内"的绘制成本,读数时留意。
    _watch
      ..reset()
      ..start();
    try {
      super.paint(context, offset);
    } finally {
      _watch.stop();
      FrameJankMonitor.noteSpan('pnt:$label', _watch.elapsedMicroseconds);
    }
  }
}
