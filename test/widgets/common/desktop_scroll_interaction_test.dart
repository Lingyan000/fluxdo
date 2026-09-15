import 'dart:async';

import 'package:common_ui/common_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Binding extends AutomatedTestWidgetsFlutterBinding
    with DesktopScrollInteractionBinding {}

void main() {
  _Binding();

  Future<(ScrollController, List<String>)> pumpList(
    WidgetTester tester, {
    Axis axis = Axis.vertical,
    bool wrapped = false,
    ScrollPhysics? physics,
  }) async {
    final scroll = ScrollController();
    final calls = <String>[];
    addTearDown(scroll.dispose);
    Widget list = SingleChildScrollView(
      controller: scroll,
      physics: physics,
      scrollDirection: axis,
      child: Flex(
        direction: axis,
        children: [
          for (var i = 0; i < 30; i++)
            SizedBox(
              width: axis == Axis.horizontal ? 100 : null,
              height: axis == Axis.vertical ? 70 : 120,
              child: GestureDetector(
                onSecondaryTapUp: (_) => calls.add('secondary-$i'),
                child: TextButton(
                  key: ValueKey('item-$i'),
                  onPressed: () => calls.add('primary-$i'),
                  child: Text('Item $i'),
                ),
              ),
            ),
        ],
      ),
    );
    if (wrapped) {
      list = ScrollConfiguration(
        behavior: const DesktopScrollInteractionBehavior().copyWith(
          scrollbars: false,
          overscroll: false,
          physics: const ClampingScrollPhysics(),
        ),
        child: list,
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const DesktopScrollInteractionBehavior(),
        home: Scaffold(body: list),
      ),
    );
    await tester.pump();
    return (scroll, calls);
  }

  for (final axis in Axis.values) {
    for (final secondary in [false, true]) {
      testWidgets('一次鼠标点击中断动画并到达控件 axis=$axis secondary=$secondary', (
        tester,
      ) async {
        final (scroll, calls) = await pumpList(
          tester,
          axis: axis,
          wrapped: true,
        );
        unawaited(
          scroll.animateTo(
            180,
            duration: const Duration(seconds: 1),
            curve: Curves.linear,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(scroll.position.shouldIgnorePointer, isTrue);
        final before = scroll.offset;
        final point = tester.getCenter(find.byKey(const ValueKey('item-3')));
        final mouse = await tester.startGesture(
          point,
          kind: PointerDeviceKind.mouse,
          buttons: secondary ? kSecondaryMouseButton : kPrimaryMouseButton,
        );
        expect(scroll.position.isScrollingNotifier.value, isFalse);
        await mouse.up();
        await tester.pump(const Duration(seconds: 1));
        expect(calls, [secondary ? 'secondary-3' : 'primary-3']);
        expect(scroll.offset, before);
      });
    }
  }

  testWidgets('鼠标悬停不停止惯性，点击才中断惯性', (tester) async {
    final (scroll, calls) = await pumpList(tester);
    scroll.jumpTo(80);
    (scroll.position as ScrollPositionWithSingleContext).goBallistic(600);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('item-5'))));
    expect(scroll.position.isScrollingNotifier.value, isTrue);
    await mouse.down(tester.getCenter(find.byKey(const ValueKey('item-5'))));
    await mouse.up();
    await tester.pump();
    expect(calls, ['primary-5']);
    expect(scroll.position.isScrollingNotifier.value, isFalse);
    await mouse.removePointer();
  });

  testWidgets('触屏仍是首次点击停滚，第二次点击激活', (tester) async {
    final (scroll, calls) = await pumpList(tester);
    unawaited(
      scroll.animateTo(
        180,
        duration: const Duration(seconds: 1),
        curve: Curves.linear,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('item-3'))));
    await tester.pump();
    expect(calls, isEmpty);
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('item-3'))));
    await tester.pump();
    expect(calls, ['primary-3']);
  });

  testWidgets('取消点击不执行操作，滚动可以重新启动', (tester) async {
    final (scroll, calls) = await pumpList(tester);
    unawaited(
      scroll.animateTo(
        180,
        duration: const Duration(seconds: 1),
        curve: Curves.linear,
      ),
    );
    await tester.pump();
    final mouse = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('item-3'))),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.cancel();
    await tester.pump();
    expect(calls, isEmpty);
    unawaited(
      scroll.animateTo(
        180,
        duration: const Duration(milliseconds: 100),
        curve: Curves.linear,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(scroll.offset, 180);
  });

  testWidgets('外层列表与内层轮播同时滚动，一次点击到达嵌套按钮', (tester) async {
    final outer = ScrollController();
    final inner = ScrollController();
    addTearDown(outer.dispose);
    addTearDown(inner.dispose);
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const DesktopScrollInteractionBehavior(),
        home: Scaffold(
          body: SingleChildScrollView(
            controller: outer,
            child: Column(
              children: [
                const SizedBox(height: 100),
                SizedBox(
                  height: 150,
                  child: SingleChildScrollView(
                    controller: inner,
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        const SizedBox(width: 100),
                        TextButton(
                          key: const ValueKey('nested'),
                          onPressed: () => calls++,
                          child: const Text('Nested'),
                        ),
                        const SizedBox(width: 1500),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 1500),
              ],
            ),
          ),
        ),
      ),
    );
    unawaited(
      outer.animateTo(
        80,
        duration: const Duration(seconds: 1),
        curve: Curves.linear,
      ),
    );
    unawaited(
      inner.animateTo(
        80,
        duration: const Duration(seconds: 1),
        curve: Curves.linear,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('nested'))),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(calls, 1);
    expect(outer.position.isScrollingNotifier.value, isFalse);
    expect(inner.position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('共享 controller 的两个列表只停止实际点击的列表', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const DesktopScrollInteractionBehavior().copyWith(
          scrollbars: false,
        ),
        home: Scaffold(
          body: Row(
            children: [
              for (var i = 0; i < 2; i++)
                Expanded(
                  child: SingleChildScrollView(
                    controller: controller,
                    child: Column(
                      children: [
                        const SizedBox(height: 120),
                        TextButton(
                          key: ValueKey('pane-$i'),
                          onPressed: () => calls++,
                          child: Text('Pane $i'),
                        ),
                        const SizedBox(height: 2000),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    final positions = controller.positions.toList();
    for (final position in positions) {
      unawaited(
        position.animateTo(
          80,
          duration: const Duration(seconds: 1),
          curve: Curves.linear,
        ),
      );
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('pane-0'))),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(calls, 1);
    expect(positions[0].isScrollingNotifier.value, isFalse);
    expect(positions[1].isScrollingNotifier.value, isTrue);
    await tester.pumpAndSettle();
  });

  testWidgets('边界回弹期间鼠标点击仍生效，回弹最终回到合法范围', (tester) async {
    final (scroll, calls) = await pumpList(
      tester,
      physics: const BouncingScrollPhysics(),
    );
    scroll.jumpTo(-40);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(scroll.position.outOfRange, isTrue);
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('item-1'))),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(calls, ['primary-1']);
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(0, 1));
  });

  testWidgets('弹层遮住列表时不停止底层滚动', (tester) async {
    final (scroll, calls) = await pumpList(tester);
    final context = tester.element(find.byType(Scaffold));
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('Modal')),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(
      scroll.animateTo(
        180,
        duration: const Duration(seconds: 1),
        curve: Curves.linear,
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Modal'), kind: PointerDeviceKind.mouse);
    expect(scroll.position.isScrollingNotifier.value, isTrue);
    expect(calls, isEmpty);
    await tester.pumpAndSettle();
  });
}
