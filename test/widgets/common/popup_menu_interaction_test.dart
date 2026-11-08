import 'package:common_ui/common_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(Widget child, {bool reduced = false}) => MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: child!,
    ),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topCenter,
        child: Padding(padding: const EdgeInsets.only(top: 60), child: child),
      ),
    ),
  );

  Widget menu({
    ValueChanged<int>? onSelected,
    VoidCallback? onTap,
    bool feedback = true,
    List<PopupMenuEntry<int>>? items,
  }) => SwipeDismissiblePopupMenuButton<int>(
    enableFeedback: feedback,
    position: PopupMenuPosition.under,
    itemBuilder: (_) =>
        items ??
        [
          PopupMenuItem(value: 1, onTap: onTap, child: const Text('One')),
          const PopupMenuItem(
            value: 2,
            enabled: false,
            child: Text('Disabled'),
          ),
          PopupMenuItem(value: 3, onTap: onTap, child: const Text('Three')),
        ],
    onSelected: onSelected,
    child: const Padding(padding: EdgeInsets.all(12), child: Text('Open')),
  );

  testWidgets('触摸与鼠标从入口连续划选，回调只执行一次，触觉反馈可关闭', (tester) async {
    var haptics = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') haptics++;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
      final values = <int>[];
      var taps = 0;
      await tester.pumpWidget(
        host(
          menu(
            onSelected: values.add,
            onTap: () => taps++,
            feedback: kind == PointerDeviceKind.touch,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final beforeHaptics = haptics;
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Open')),
        kind: kind,
      );
      await tester.pumpAndSettle();
      expect(find.text('One'), findsOneWidget);
      await gesture.moveTo(tester.getCenter(find.text('One')));
      await tester.pumpAndSettle();
      final pressed = tester.getRect(find.text('One'));
      await gesture.moveTo(tester.getCenter(find.text('Three')));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.text('One')).top,
        isNot(closeTo(pressed.top, .1)),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(values, [3]);
      expect(taps, 1);
      expect(find.text('Three'), findsNothing);
      expect(
        haptics - beforeHaptics,
        kind == PointerDeviceKind.touch ? greaterThan(0) : 0,
      );
      await gesture.removePointer();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('菜单内跨行划选只激活落点，禁用项、分隔线和滑出不会误选', (tester) async {
    final values = <int>[];
    await tester.pumpWidget(host(menu(onSelected: values.add)));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    var gesture = await tester.startGesture(tester.getCenter(find.text('One')));
    await gesture.moveTo(tester.getCenter(find.text('Disabled')));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(values, isEmpty);
    expect(find.text('Three'), findsOneWidget);
    gesture = await tester.startGesture(tester.getCenter(find.text('One')));
    await gesture.moveTo(const Offset(20, 550));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(values, isEmpty);
    gesture = await tester.startGesture(tester.getCenter(find.text('One')));
    await gesture.moveTo(tester.getCenter(find.text('Three')));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(values, [3]);
  });

  testWidgets('按住入口停留展开子菜单，再划入子项，整条菜单链只选择一次', (tester) async {
    final values = <int>[];
    await tester.pumpWidget(
      host(
        menu(
          onSelected: values.add,
          items: const [
            PopupMenuItem(value: 1, child: Text('One')),
            ExpandablePopupMenuEntry<int>(
              icon: Icons.settings,
              label: 'More',
              children: [
                ExpandableMenuChild(
                  value: 8,
                  icon: Icons.check,
                  label: 'Child A',
                ),
                ExpandableMenuChild(
                  value: 9,
                  icon: Icons.star,
                  label: 'Child B',
                ),
              ],
            ),
          ],
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Open')),
    );
    await tester.pumpAndSettle();
    await gesture.moveTo(tester.getCenter(find.text('More')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    expect(find.text('Child B'), findsOneWidget);
    expect(values, isEmpty);
    await gesture.moveTo(tester.getCenter(find.text('Child B')));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(values, [9]);
    expect(find.text('Child B'), findsNothing);
    expect(find.text('More'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('菜单内部长列表仍能滚动，不触发划选；入口上的快速滚动不打开菜单', (tester) async {
    var calls = 0;
    final pageScroll = ScrollController();
    addTearDown(pageScroll.dispose);
    await tester.pumpWidget(
      host(
        SizedBox(
          width: 300,
          child: ListView(
            controller: pageScroll,
            children: [
              menu(onSelected: (_) => calls++),
              const SizedBox(height: 1500),
            ],
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Open')),
    );
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(0, -100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(pageScroll.offset, greaterThan(40));
    expect(find.text('One'), findsNothing);
    await tester.pumpWidget(
      host(
        menu(
          onSelected: (_) => calls++,
          items: [
            for (var i = 0; i < 30; i++)
              PopupMenuItem(value: i, child: Text('Item $i')),
          ],
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final scroller = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(SingleChildScrollView),
            matching: find.byType(Scrollable),
          )
          .last,
    );
    await tester.drag(find.text('Item 4'), const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(scroller.position.pixels, greaterThan(60));
    expect(calls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消按压不执行选项，关闭减少动画与移除入口后可安全收起', (tester) async {
    var calls = 0;
    final showSource = ValueNotifier(true);
    addTearDown(showSource.dispose);
    for (final reduced in [false, true]) {
      showSource.value = true;
      await tester.pumpWidget(
        host(
          ValueListenableBuilder<bool>(
            valueListenable: showSource,
            builder: (_, shown, _) =>
                shown ? menu(onSelected: (_) => calls++) : const SizedBox(),
          ),
          reduced: reduced,
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Open')),
      );
      await tester.pumpAndSettle();
      await gesture.moveTo(tester.getCenter(find.text('Three')));
      await tester.pumpAndSettle();
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(calls, 0);
      final route =
          ModalRoute.of(tester.element(find.text('One'))) as TransitionRoute;
      if (reduced) expect(route.transitionDuration, Duration.zero);
      showSource.value = false;
      await tester.pump();
      Navigator.of(tester.element(find.text('One'))).pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('入口保留键盘激活，收回期间不重复打开，完成后可以再次打开', (tester) async {
    await tester.pumpWidget(host(menu()));
    await tester.pumpAndSettle();
    final focus = Focus.of(tester.element(find.text('Open')));
    focus.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('One'), findsOneWidget);
    Navigator.of(tester.element(find.text('One'))).pop();
    await tester.pump();
    final sourceInk = tester.widget<InkWell>(
      find.descendant(
        of: find.byType(SwipeDismissiblePopupMenuButton<int>),
        matching: find.byType(InkWell),
      ),
    );
    sourceInk.onTap!();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('One'), findsNothing);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('One'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已打开菜单里按住子菜单入口也能连续选择，原行不重复打开子菜单', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        menu(
          onSelected: (_) => calls++,
          items: const [
            ExpandablePopupMenuEntry<int>(
              icon: Icons.settings,
              label: 'More',
              children: [
                ExpandableMenuChild(
                  value: 7,
                  icon: Icons.check,
                  label: 'Child',
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('More')),
    );
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    expect(find.text('Child'), findsOneWidget);
    await gesture.moveTo(tester.getCenter(find.text('Child')));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('Child'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('划选期间第二根手指不会触发另一项，原指针取消后恢复', (tester) async {
    final values = <int>[];
    await tester.pumpWidget(host(menu(onSelected: values.add)));
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Open')),
      pointer: 11,
    );
    await tester.pumpAndSettle();
    await gesture.moveTo(tester.getCenter(find.text('One')));
    await tester.pumpAndSettle();
    final second = await tester.startGesture(
      tester.getCenter(find.text('Three')),
      pointer: 12,
    );
    await second.up();
    await tester.pumpAndSettle();
    expect(values, isEmpty);
    await gesture.cancel();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Three'));
    await tester.pumpAndSettle();
    expect(values, [3]);
  });
}
