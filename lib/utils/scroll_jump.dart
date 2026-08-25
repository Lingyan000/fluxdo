import 'package:flutter/rendering.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

/// 已渲染目标的瞬时定位（替代 scroll_to_index 的 1ms animateTo）
extension AutoScrollJump on AutoScrollController {
  /// 跳到已渲染的 [scrollIndex]（几何测不到时回退 scrollToIndex）
  ///
  /// [alignment] 语义见 [topAlignOffsetForScrollIndex]：正序列表顶对齐传
  /// 0（默认），reverse 列表要视觉顶对齐则传 1。
  ///
  /// 不走 scrollToIndex：它内部固定用 animateTo，而调用方只给 1ms，
  /// 本意就是瞬移。animateTo 期间 velocity≠0，此时若列表重新布局导致
  /// maxScrollExtent 收缩（落点附近 segment 由估算高度换成真实高度、
  /// 末页 loadMore 收尾移除底部 loading sliver 等），
  /// RangeMaintainingScrollPhysics 会因 velocity≠0 主动放弃把位置约束回
  /// 新范围（framework scroll_physics.dart: adjustPositionForNewDimensions
  /// 里 velocity≠0 ⇒ enforceBoundary=false，注释「不要调整正在动画的位置」），
  /// pixels 就留在 max 之外；动画结束 goBallistic 时 BouncingScrollPhysics
  /// 一见 outOfRange 便交给 BouncingScrollSimulation 弹回 —— 这就是跳转
  /// 落到底部时看到的回弹。
  ///
  /// jumpTo 没有动画窗口，velocity 恒为 0，维度收缩时边界约束照常生效，
  /// 落点直接钉死；且落点已 clamp 在范围内，其 goBallistic(0) 不会产生
  /// 任何 simulation。
  Future<void> jumpToRenderedScrollIndex(
    int scrollIndex, {
    double alignment = 0.0,
  }) async {
    final offset = topAlignOffsetForScrollIndex(
      scrollIndex,
      alignment: alignment,
    );
    if (offset == null) {
      // 几何测不到（tag 未挂载 / element 已失活）：保留原兜底路径
      await scrollToIndex(
        scrollIndex,
        preferPosition: alignment == 0.0
            ? AutoScrollPosition.begin
            : (alignment == 1.0
                  ? AutoScrollPosition.end
                  : AutoScrollPosition.middle),
        duration: const Duration(milliseconds: 1),
      );
      return;
    }

    // 与 scroll_to_index 同款防越界 clamp：目标下方不足一屏时顶对齐
    // 本就不可达，只能贴底
    jumpTo(offset.clamp(position.minScrollExtent, position.maxScrollExtent));
  }

  /// [scrollIndex] 对齐到视口所需的滚动位置；无法测量时返回 null
  ///
  /// [alignment] 沿用 `RenderAbstractViewport.getOffsetToReveal` 的语义：
  /// 相对**滚动**前缘而非屏幕上方。正序列表 0=顶对齐；reverse 列表滚动
  /// 前缘在视觉下方，故 0=贴视觉底、1=贴视觉顶。
  double? topAlignOffsetForScrollIndex(
    int scrollIndex, {
    double alignment = 0.0,
  }) {
    if (!hasClients) return null;

    final ctx = tagMap[scrollIndex]?.context;
    if (ctx == null || !ctx.mounted) return null;

    // ctx.mounted=true 不代表 element 仍 active，
    // inactive 状态下 findRenderObject 会抛
    final RenderObject? box;
    try {
      box = ctx.findRenderObject();
    } catch (_) {
      return null;
    }
    if (box == null || !box.attached) return null;
    if (box is RenderBox && !box.hasSize) return null;

    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return null;

    // viewportBoundaryGetter 默认 Rect.zero，无额外偏移
    return viewport.getOffsetToReveal(box, alignment).offset;
  }
}
