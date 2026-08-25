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

  /// reverse 列表（聊天气泡流）的 alignment 语义
  ///
  /// getOffsetToReveal 的 alignment 相对**滚动**前缘、而非屏幕上方。
  /// reverse:true 时滚动前缘在视觉下方，所以 0=贴视觉底、1=贴视觉顶——
  /// 聊天页要贴视觉顶就必须传 1，传 0（默认）会把目标压到屏幕最底下。
  group('reverse 列表', () {
    Widget buildReverseList(AutoScrollController controller, int itemCount) {
      return MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: ListView.builder(
                controller: controller,
                reverse: true,
                itemCount: itemCount,
                itemBuilder: (context, index) => AutoScrollTag(
                  key: ValueKey(index),
                  controller: controller,
                  index: index,
                  child: SizedBox(
                    height: itemHeight,
                    child: Text('item $index'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('alignment:1 落点使目标贴视口顶', (tester) async {
      final controller = AutoScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(buildReverseList(controller, 20));
      await tester.pumpAndSettle();

      // 目标要选得够"深"：reverse 列表里 index 越小越靠视觉底部，太靠底
      // 的项根本无法顶对齐（所需 offset 为负会被 clamp 成 0）。
      // index 15 占滚动区间 [750,800]，顶对齐需 800-600=200，在可滚范围内。
      await controller.jumpToRenderedScrollIndex(15, alignment: 1.0);
      await tester.pump();

      expect(controller.position.pixels, 200.0);

      // 目标顶边与视口顶边重合（±0.5 容差）
      final box = tester.renderObject<RenderBox>(find.text('item 15'));
      final viewportTop = tester.getRect(find.byType(ListView)).top;
      expect(
        box.localToGlobal(Offset.zero).dy,
        closeTo(viewportTop, 0.5),
        reason: 'reverse 列表下 alignment:1 才是视觉顶对齐',
      );
    });

    testWidgets('默认 alignment:0 在 reverse 下是贴视口底', (tester) async {
      final controller = AutoScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(buildReverseList(controller, 20));
      await tester.pumpAndSettle();

      await controller.jumpToRenderedScrollIndex(4);
      await tester.pump();

      final box = tester.renderObject<RenderBox>(find.text('item 4'));
      final viewportBottom = tester.getRect(find.byType(ListView)).bottom;
      expect(
        box.localToGlobal(Offset.zero).dy + box.size.height,
        closeTo(viewportBottom, 0.5),
        reason: '默认值在 reverse 下贴底，正是聊天页不能用默认值的原因',
      );
    });

    testWidgets('顶对齐落点加 avoid 后目标下移 avoid(浮层避让方向)', (tester) async {
      final controller = AutoScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(buildReverseList(controller, 20));
      await tester.pumpAndSettle();

      // 聊天页的置顶横幅浮在列表之上,顶对齐会让目标顶死在横幅下沿。
      // 这里钉住"往哪个方向退"的符号:reverse 列表沿 AxisDirection.up 滚动,
      // pixels 增大 = 视口移向更旧的消息 = 目标相对视口向下移。
      // 所以避让是 offset + avoid,不是减。
      const avoid = 60.0;
      final base = controller.topAlignOffsetForScrollIndex(15, alignment: 1.0)!;

      controller.jumpTo(base + avoid);
      await tester.pump();

      final box = tester.renderObject<RenderBox>(find.text('item 15'));
      final viewportTop = tester.getRect(find.byType(ListView)).top;
      expect(
        box.localToGlobal(Offset.zero).dy,
        closeTo(viewportTop + avoid, 0.5),
        reason: 'offset + avoid 才是把目标从顶部浮层底下推出来',
      );
    });
  });

  /// 护住三处既有调用方（话题详情页）：默认参数行为不得变化
  testWidgets('正序列表默认 alignment 仍是顶对齐', (tester) async {
    final controller = AutoScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(buildList(controller, 20));
    await tester.pumpAndSettle();

    expect(controller.topAlignOffsetForScrollIndex(4), 200.0);
    expect(
      controller.topAlignOffsetForScrollIndex(4, alignment: 0.0),
      200.0,
      reason: '显式传默认值与不传须等价',
    );
  });
}
