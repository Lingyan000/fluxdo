import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_ui/m3e_ui.dart';

Widget _host(
  Widget child, {
  bool enabled = true,
  TextDirection direction = TextDirection.ltr,
  double textScale = 1,
}) => MaterialApp(
  theme: ThemeData(extensions: [M3eFlags(enabled: enabled)]),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: TextScaler.linear(textScale)),
    child: Directionality(textDirection: direction, child: child!),
  ),
  home: Scaffold(body: Center(child: child)),
);

List<M3eButtonGroupItem<int>> _items(int count) => [
  for (var i = 0; i < count; i++)
    M3eButtonGroupItem(value: i, label: Text('Variant $i')),
];

Finder get _group => find.byType(M3eButtonGroup<int>);
Finder get _scroll =>
    find.descendant(of: _group, matching: find.byType(Scrollable));

class _SelectionNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void select(int value) => state = value;
}

final _selectionProvider = NotifierProvider<_SelectionNotifier, int>(
  _SelectionNotifier.new,
);

void _expectVisible(WidgetTester tester, int value) {
  final viewport = tester.getRect(_group);
  final label = tester.getRect(find.text('Variant $value'));
  expect(label.left, greaterThanOrEqualTo(viewport.left));
  expect(label.right, lessThanOrEqualTo(viewport.right));
}

void main() {
  testWidgets('Provider 驱动的按钮组在新选中项生效后震动一次', (tester) async {
    final feedback = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        feedback.add(call.arguments as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    for (final enabled in [true, false]) {
      for (final scrollable in [false, true]) {
        feedback.clear();
        await tester.pumpWidget(
          ProviderScope(
            key: ValueKey('$enabled-$scrollable'),
            child: _host(
              Consumer(
                builder: (context, ref, child) => SizedBox(
                  width: 360,
                  child: M3eButtonGroup<int>(
                    scrollable: scrollable,
                    items: _items(2),
                    selected: ref.watch(_selectionProvider),
                    onSelected: ref.read(_selectionProvider.notifier).select,
                  ),
                ),
              ),
              enabled: enabled,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Variant 1'));
        await tester.pumpAndSettle();
        expect(tester.widget<M3eButtonGroup<int>>(_group).selected, 1);
        expect(feedback, ['HapticFeedbackType.selectionClick']);
        await tester.tap(find.text('Variant 1'));
        await tester.pumpAndSettle();
        expect(feedback, hasLength(1));
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('只在点击后的新选中状态生效时震动，按下、取消、重复和拒绝不震动', (tester) async {
    final feedback = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        feedback.add(call.arguments as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    for (final enabled in [true, false]) {
      var selected = 0;
      var accept = true;
      Completer<void>? pending;
      late StateSetter update;
      feedback.clear();
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            key: ValueKey(enabled),
            builder: (context, setState) {
              update = setState;
              return SizedBox(
                width: 360,
                child: M3eButtonGroup<int>(
                  scrollable: true,
                  items: _items(2),
                  selected: selected,
                  onSelected: (value) async {
                    await pending?.future;
                    if (accept) setState(() => selected = value);
                  },
                ),
              );
            },
          ),
          enabled: enabled,
        ),
      );
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Variant 1')),
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(feedback, isEmpty);
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(feedback, isEmpty);

      pending = Completer<void>();
      await tester.tap(find.text('Variant 1'));
      await tester.pumpAndSettle();
      expect(feedback, isEmpty);
      pending.complete();
      await tester.pumpAndSettle();
      expect(selected, 1);
      expect(feedback, ['HapticFeedbackType.selectionClick']);

      await tester.tap(find.text('Variant 1'));
      await tester.pumpAndSettle();
      expect(feedback, hasLength(1));
      accept = false;
      await tester.tap(find.text('Variant 0'));
      await tester.pumpAndSettle();
      expect(selected, 1);
      expect(feedback, hasLength(1));
      update(() => selected = 0);
      await tester.pumpAndSettle();
      expect(feedback, hasLength(1));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('空间足够时等宽铺满，按压回弹且不挤动邻项', (tester) async {
    var selected = 0;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, update) => SizedBox(
            width: 480,
            child: M3eButtonGroup<int>(
              scrollable: true,
              items: _items(3),
              selected: selected,
              onSelected: (value) => update(() => selected = value),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.state<ScrollableState>(_scroll).position.maxScrollExtent, 0);
    final buttons = find.descendant(
      of: _group,
      matching: find.byType(Material),
    );
    final rest = tester.getRect(buttons.first);
    final neighbor = tester.getRect(buttons.at(1));
    expect(rest.width, neighbor.width);
    final groupSize = tester.getSize(_group);
    final gesture = await tester.startGesture(rest.center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.getRect(buttons.first).width, greaterThan(rest.width));
    expect(tester.getRect(buttons.at(1)), neighbor);
    expect(tester.getSize(_group), groupSize);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(tester.getRect(buttons.first), rest);
    await tester.tap(find.text('Variant 1'));
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('横滑可滚动且不误选，外部切换后选中项自动可见', (tester) async {
    var selected = 0;
    var calls = 0;
    late StateSetter update;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return SizedBox(
              width: 220,
              child: M3eButtonGroup<int>(
                scrollable: true,
                items: _items(5),
                selected: selected,
                onSelected: (value) => setState(() {
                  selected = value;
                  calls++;
                }),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    _expectVisible(tester, 0);
    await tester.drag(find.text('Variant 0'), const Offset(-140, 0));
    await tester.pumpAndSettle();
    expect(
      tester.state<ScrollableState>(_scroll).position.pixels,
      greaterThan(30),
    );
    expect(calls, 0);
    expect(selected, 0);
    update(() => selected = 4);
    await tester.pumpAndSettle();
    _expectVisible(tester, 4);
    update(() => selected = 0);
    await tester.pumpAndSettle();
    _expectVisible(tester, 0);
    expect(calls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('从口味按钮竖向拖动仍可滚动页面', (tester) async {
    final page = ScrollController();
    addTearDown(page.dispose);
    var calls = 0;
    await tester.pumpWidget(
      _host(
        ListView(
          controller: page,
          children: [
            const SizedBox(height: 180),
            Align(
              child: SizedBox(
                width: 220,
                child: M3eButtonGroup<int>(
                  scrollable: true,
                  items: _items(5),
                  selected: 0,
                  onSelected: (_) => calls++,
                ),
              ),
            ),
            const SizedBox(height: 1000),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.text('Variant 0'), const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(page.offset, greaterThan(30));
    expect(tester.state<ScrollableState>(_scroll).position.pixels, 0);
    expect(calls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('大字体、RTL 和经典样式下初始选中项可见，宽度变化后仍可用', (tester) async {
    for (final enabled in [true, false]) {
      for (final direction in TextDirection.values) {
        var width = 360.0;
        late StateSetter update;
        await tester.pumpWidget(
          _host(
            StatefulBuilder(
              key: ValueKey('$enabled-$direction'),
              builder: (context, setState) {
                update = setState;
                return SizedBox(
                  width: width,
                  child: M3eButtonGroup<int>(
                    scrollable: true,
                    items: _items(5),
                    selected: 4,
                    onSelected: (_) {},
                  ),
                );
              },
            ),
            enabled: enabled,
            direction: direction,
            textScale: 1.6,
          ),
        );
        await tester.pumpAndSettle();
        _expectVisible(tester, 4);
        update(() => width = 260);
        await tester.pumpAndSettle();
        _expectVisible(tester, 4);
        expect(tester.takeException(), isNull);
      }
    }
  });
}
