// details 折叠块在 center 双向列表 reverse 半场展开时的位置回归测试。
//
// 背景:before-center 区(reverse 增长)子项向远离 center 方向生长,
// details 展开会把 header 顶出视口上方(视觉 = 点击后跳到内容底部)。
// 修复链路:_DetailsWidget 动画每帧 FoldShiftHook.notify → 宿主注入
// AnchorGuardSliver.arm → 哨兵同帧 scrollOffsetCorrection 钉住 header。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

import 'package:fluxdo/widgets/common/anchor_guard_sliver.dart';

final _detailsHtml =
    '<details><summary>标题</summary>'
    '<p>${'长文内容。' * 200}</p>'
    '</details>';

void main() {
  Widget buildList({required bool inBeforeRegion, required Key centerKey}) {
    Widget filler(Color color) => Container(height: 100, color: color);
    final details = FluxdoRender(
      cookedHtml: _detailsHtml,
      selectionEnabled: false,
    );
    return MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          center: centerKey,
          slivers: [
            const AnchorGuardSliver(),
            SliverList.builder(
              itemCount: 10,
              itemBuilder: (context, i) =>
                  i == 2 && inBeforeRegion ? details : filler(Colors.green),
            ),
            SliverList.builder(
              key: centerKey,
              itemCount: 10,
              itemBuilder: (context, i) =>
                  i == 2 && !inBeforeRegion ? details : filler(Colors.amber),
            ),
            const AnchorGuardSliver(),
          ],
        ),
      ),
    );
  }

  Future<void> run(WidgetTester tester, {required bool inBeforeRegion}) async {
    FoldShiftHook.onFrame = AnchorGuardSliver.arm;
    addTearDown(() => FoldShiftHook.onFrame = null);

    final centerKey = UniqueKey();
    await tester.pumpWidget(
      buildList(inBeforeRegion: inBeforeRegion, centerKey: centerKey),
    );
    if (inBeforeRegion) {
      // 让 before 区的 details 进入视口(且不贴顶,避开哨兵顶部抑制)
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      position.jumpTo(-450);
      await tester.pump();
    }

    // 追踪 summary 文本而非 chevron 图标:图标展开时自身旋转 0→90°,
    // 旋转中途包围盒胀缩(45° 时顶边上移约 5px),会把逐帧断言污染成
    // 假漂移;文本不动,量到的才是纯锚定误差。
    final header = find.text('标题');
    expect(header, findsOneWidget);
    final before = tester.getTopLeft(header);

    await tester.tap(header);
    // 逐帧推进 200ms 展开动画,每帧校验 header 不漂移(不是只测终帧:
    // 中途跳走再回来的对称性 bug 会被终帧断言漏掉)
    for (int i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final now = tester.getTopLeft(header);
      expect(
        (now.dy - before.dy).abs(),
        lessThan(1.0),
        reason: 'inBeforeRegion=$inBeforeRegion 第 $i 帧 header 漂移 '
            '${(now.dy - before.dy).toStringAsFixed(1)}px',
      );
    }
  }

  testWidgets('details 在 after-center 区展开,header 原地不动', (tester) async {
    await run(tester, inBeforeRegion: false);
  });

  testWidgets('details 在 before-center(reverse)区展开,header 原地不动',
      (tester) async {
    await run(tester, inBeforeRegion: true);
  });

  testWidgets('未注入 hook 时 reverse 区展开会顶出 header(现状基线)',
      (tester) async {
    FoldShiftHook.onFrame = null;
    final centerKey = UniqueKey();
    await tester.pumpWidget(
      buildList(inBeforeRegion: true, centerKey: centerKey),
    );
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    position.jumpTo(-450);
    await tester.pump();
    final header = find.text('标题');
    final before = tester.getTopLeft(header);
    await tester.tap(header);
    await tester.pumpAndSettle();
    final after = tester.getTopLeft(header);
    // 无补偿时 header 必然上移(被展开的 body 顶出原位)
    expect(after.dy, lessThan(before.dy - 8));
  });
}
