import 'dart:async';

import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Binding extends AutomatedTestWidgetsFlutterBinding
    with DesktopScrollInteractionBinding {}

void main() {
  _Binding();

  for (final outerAxis in Axis.values) {
    for (final ballistic in [false, true]) {
      testWidgets('外层 $outerAxis 滚动时立即接管内层交叉拖动 ballistic=$ballistic', (
        tester,
      ) async {
        final outer = ScrollController();
        final inner = ScrollController();
        addTearDown(outer.dispose);
        addTearDown(inner.dispose);
        final horizontal = outerAxis == Axis.horizontal;
        var taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            scrollBehavior: const DesktopScrollInteractionBehavior(),
            home: Scaffold(
              body: SingleChildScrollView(
                controller: outer,
                scrollDirection: outerAxis,
                child: SizedBox(
                  width: horizontal ? 1600 : 800,
                  height: horizontal ? 600 : 1600,
                  child: SingleChildScrollView(
                    controller: inner,
                    scrollDirection: horizontal
                        ? Axis.vertical
                        : Axis.horizontal,
                    child: SizedBox(
                      width: horizontal ? 1600 : 2400,
                      height: horizontal ? 2400 : 1600,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => taps++,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        if (ballistic) {
          await tester.flingFrom(
            const Offset(400, 300),
            horizontal ? const Offset(-180, 0) : const Offset(0, -180),
            900,
          );
        } else {
          unawaited(
            outer.animateTo(
              300,
              duration: const Duration(seconds: 1),
              curve: Curves.linear,
            ),
          );
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 30));
        expect(outer.position.isScrollingNotifier.value, isTrue);
        expect(outer.position.shouldIgnorePointer, isTrue);
        final stoppedAt = outer.offset;
        final gesture = await tester.startGesture(const Offset(400, 300));
        await gesture.moveBy(
          horizontal ? const Offset(0, -40) : const Offset(-40, 0),
        );
        await tester.pump();
        await gesture.moveBy(
          horizontal ? const Offset(0, -90) : const Offset(-90, 0),
        );
        await tester.pump();
        expect(inner.offset, greaterThan(60));
        expect(outer.offset, closeTo(stoppedAt, 0.01));
        expect(taps, 0);
        await gesture.cancel();
        await tester.pumpAndSettle();
      });
    }
  }

  testWidgets('分页吸附未完成时纵向列表可拖动，分页最终仍吸附到整页', (tester) async {
    final pages = PageController();
    final list = ScrollController();
    addTearDown(pages.dispose);
    addTearDown(list.dispose);
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const DesktopScrollInteractionBehavior(),
        home: Scaffold(
          body: PageView(
            controller: pages,
            children: [
              ListView.builder(
                controller: list,
                itemExtent: 60,
                itemCount: 60,
                itemBuilder: (_, i) => Text('row $i'),
              ),
              const ColoredBox(color: Colors.blue),
            ],
          ),
        ),
      ),
    );
    unawaited(
      pages.animateToPage(
        1,
        duration: const Duration(seconds: 1),
        curve: Curves.linear,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final gesture = await tester.startGesture(const Offset(300, 300));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    expect(list.offset, greaterThan(70));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(pages.page, closeTo(0, 0.001));
  });

  Future<(ScrollController, List<int>)> pumpList(
    WidgetTester tester, {
    bool ignoreContent = false,
  }) async {
    final scroll = ScrollController(initialScrollOffset: 200);
    final taps = <int>[];
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const DesktopScrollInteractionBehavior(),
        home: Scaffold(
          body: SingleChildScrollView(
            controller: scroll,
            child: IgnorePointer(
              ignoring: ignoreContent,
              child: Column(
                children: [
                  for (var i = 0; i < 30; i++)
                    SizedBox(
                      height: 80,
                      width: double.infinity,
                      child: TextButton(
                        onPressed: () => taps.add(i),
                        child: Text('item $i'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return (scroll, taps);
  }

  Future<void> animate(WidgetTester tester, ScrollController scroll) async {
    unawaited(
      scroll.animateTo(
        500,
        duration: const Duration(seconds: 1),
        curve: Curves.linear,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('停止动画的触屏按压取消后，下一次点击和反向拖动均正常', (tester) async {
    final (scroll, taps) = await pumpList(tester);
    await animate(tester, scroll);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('item 5')),
    );
    await gesture.cancel();
    await tester.pump();
    expect(taps, isEmpty);
    await tester.tap(find.text('item 5'));
    expect(taps, [5]);
    await animate(tester, scroll);
    final before = scroll.offset;
    final reverse = await tester.startGesture(const Offset(400, 300));
    await reverse.moveBy(const Offset(0, 40));
    await reverse.moveBy(const Offset(0, 90));
    await tester.pump();
    expect(scroll.offset, lessThan(before - 60));
    await reverse.cancel();
    await tester.pumpAndSettle();
  });

  testWidgets('不会打开业务层主动设置的 IgnorePointer', (tester) async {
    final (scroll, taps) = await pumpList(tester, ignoreContent: true);
    await animate(tester, scroll);
    await tester.tapAt(tester.getCenter(find.text('item 5')));
    await tester.pump();
    await tester.tapAt(tester.getCenter(find.text('item 5')));
    await tester.pump();
    expect(taps, isEmpty);
  });

  testWidgets('第二根手指按下不会打断第一根手指正在进行的拖动', (tester) async {
    final (scroll, taps) = await pumpList(tester);
    final first = await tester.startGesture(const Offset(400, 300), pointer: 1);
    await first.moveBy(const Offset(0, -40));
    await first.moveBy(const Offset(0, -80));
    await tester.pump();
    final before = scroll.offset;
    final second = await tester.startGesture(
      const Offset(450, 300),
      pointer: 2,
    );
    await second.up();
    await first.moveBy(const Offset(0, -70));
    await tester.pump();
    expect(scroll.offset, greaterThan(before + 40));
    expect(taps, isEmpty);
    await first.cancel();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('触屏点击弹层不会停掉背后的滚动', (tester) async {
    final (scroll, taps) = await pumpList(tester);
    unawaited(
      showDialog<void>(
        context: tester.element(find.byType(Scaffold)),
        builder: (_) => const AlertDialog(content: Text('dialog')),
      ),
    );
    await tester.pumpAndSettle();
    await animate(tester, scroll);
    await tester.tap(find.text('dialog'));
    expect(scroll.position.isScrollingNotifier.value, isTrue);
    expect(taps, isEmpty);
    await tester.pumpAndSettle();
  });
}
