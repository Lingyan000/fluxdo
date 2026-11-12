import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_ui/m3e_ui.dart';

void main() {
  for (final expressive in [true, false]) {
    testWidgets('拉伸进度覆盖取消、刷新等待和回弹，M3E=$expressive', (tester) async {
      final extents = <double>[];
      final completion = Completer<void>();
      var refreshes = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: [M3eFlags(enabled: expressive)]),
          home: Scaffold(
            body: M3eRefreshIndicator(
              onPullExtentChanged: extents.add,
              onRefresh: () {
                refreshes++;
                return completion.future;
              },
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [SizedBox(height: 1000)],
              ),
            ),
          ),
        ),
      );
      final listElement = tester.element(find.byType(ListView));
      await tester.drag(find.byType(ListView), const Offset(0, 60));
      await tester.pumpAndSettle();
      expect(refreshes, 0);
      expect(extents.any((extent) => extent > 0), isTrue);
      expect(extents.last, 0);
      extents.clear();

      await tester.drag(find.byType(ListView), const Offset(0, 400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(refreshes, 1);
      expect(extents.last, greaterThan(0));
      completion.complete();
      await tester.pumpAndSettle();
      expect(extents.last, 0);
      expect(tester.element(find.byType(ListView)), same(listElement));
      expect(tester.takeException(), isNull);
    });
  }

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
