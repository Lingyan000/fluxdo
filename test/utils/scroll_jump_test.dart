import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import 'package:fluxdo/utils/scroll_jump.dart';

/// 跳转落点贴底后内容收缩，位置不得越界（越界 ⇒ BouncingScrollSimulation 回弹）
///
/// 复现话题详情页的时序：跳到底部附近的已渲染帖子后，列表在同一时间
/// 重新布局并变短（落点附近 segment 由估算高度换成真实高度、末页
/// loadMore 收尾移除底部 loading sliver），maxScrollExtent 随之收缩。
void main() {
  const itemHeight = 50.0;
  const viewportHeight = 600.0;

  /// [itemCount] 个 AutoScrollTag 项的列表，视口固定 600 高
  Widget buildList(AutoScrollController controller, int itemCount) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            height: viewportHeight,
            child: ListView.builder(
              controller: controller,
              // 与话题详情页一致：iOS 式回弹物理
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              itemCount: itemCount,
              itemBuilder: (context, index) => AutoScrollTag(
                key: ValueKey(index),
                controller: controller,
                index: index,
                child: SizedBox(height: itemHeight, child: Text('item $index')),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('jumpToRenderedScrollIndex：贴底落点遇内容收缩不越界', (tester) async {
    final controller = AutoScrollController();
    addTearDown(controller.dispose);

    // 20 项 = 1000px 内容，视口 600 ⇒ maxScrollExtent 400。
    // 先停在 200（不贴底），让跳转有真实位移
    await tester.pumpWidget(buildList(controller, 20));
    controller.jumpTo(200.0);
    await tester.pumpAndSettle();

    final position = controller.position;
    expect(position.maxScrollExtent, 400.0);
    // 目标须已渲染，否则走的是回退分支（scrollToIndex 爬行定位），
    // 测的就不是本用例关心的路径了
    expect(controller.topAlignOffsetForScrollIndex(18), 900.0);

    // 跳到倒数第二项：顶对齐需要 900px，远超 maxScrollExtent，只能
    // clamp 贴底 —— 正是回弹的高发落点
    await controller.jumpToRenderedScrollIndex(18);
    await tester.pump();

    // 时间未推进就已到位：animateTo 此刻还停在半路，那段动画窗口
    // （velocity≠0）正是回弹得以发生的前提
    expect(position.pixels, 400.0, reason: '跳转应是瞬时的，不留动画窗口');

    // 落点正贴在 maxScrollExtent 上，此刻内容收缩 150px
    // （末页 loadMore 收尾移除 loading sliver、估算高度换成真实高度）
    await tester.pumpWidget(buildList(controller, 17));
    await tester.pump();

    expect(position.maxScrollExtent, 250.0, reason: '收缩后的可滚上限');
    expect(
      position.pixels,
      lessThanOrEqualTo(250.0),
      reason: '位置越界会被 BouncingScrollSimulation 弹回，表现为触底回弹',
    );
    // 越界时这几帧能看到弹回过程；不越界则位置自始至终钉住
    await tester.pump(const Duration(milliseconds: 300));
    expect(position.pixels, 250.0);
  });

  testWidgets('jumpToRenderedScrollIndex：目标下方足够时精确顶对齐', (tester) async {
    final controller = AutoScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(buildList(controller, 20));
    await tester.pumpAndSettle();

    // 第 4 项顶对齐 = 200px，小于 maxScrollExtent(400)，无需 clamp
    await controller.jumpToRenderedScrollIndex(4);
    await tester.pump();

    expect(controller.position.pixels, 200.0);
  });

  testWidgets('topAlignOffsetForScrollIndex：未渲染的项返回 null', (tester) async {
    final controller = AutoScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(buildList(controller, 200));
    await tester.pumpAndSettle();

    // 列表尾部远在缓存区之外，没有 tag 挂载 ⇒ 测不到几何，
    // 由调用方回退 scrollToIndex 的爬行定位
    expect(controller.topAlignOffsetForScrollIndex(199), isNull);
  });
}
