import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_ui/m3e_ui.dart';

void main() {
  testWidgets('顶部拖动不重建列表子树(树形状稳定)', (tester) async {
    final controller = ScrollController();
    final listKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: M3eRefreshIndicator(
            onRefresh: () async {},
            child: ListView.builder(
              key: listKey,
              controller: controller,
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: 100,
              itemBuilder: (_, i) => SizedBox(height: 40, child: Text('$i')),
            ),
          ),
        ),
      ),
    );
    final elementBefore = listKey.currentContext!;

    // 在顶部轻拖(触发 drag 状态翻转)再松手取消。
    await tester.drag(find.byType(ListView), const Offset(0, 30));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 树形状稳定:同一个 Element,列表未被拆掉重建。
    expect(listKey.currentContext, same(elementBefore));

    // 先滚下去,再在中途来回拖,位置不能被重置。
    controller.jumpTo(400);
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -50));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(controller.offset, greaterThan(300));
    expect(listKey.currentContext, same(elementBefore));
  });

  testWidgets('完整下拉刷新流程', (tester) async {
    var refreshed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: M3eRefreshIndicator(
            onRefresh: () async => refreshed++,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [for (var i = 0; i < 20; i++) SizedBox(height: 40, child: Text('$i'))],
            ),
          ),
        ),
      ),
    );
    await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200)); // snap
    await tester.pump(const Duration(seconds: 1)); // refresh 完成
    await tester.pumpAndSettle();
    expect(refreshed, 1);
    expect(tester.takeException(), isNull);
  });
}
