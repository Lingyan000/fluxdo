import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_ui/m3e_ui.dart';

void main() {
  testWidgets('第一行移除与清空时没有残留间隙，再插入只挂载一份', (tester) async {
    final items = ValueNotifier([0, 1, 2]);
    addTearDown(items.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ValueListenableBuilder<List<int>>(
              valueListenable: items,
              builder: (_, values, _) => SegmentedCardGroup(
                children: [
                  for (final value in values)
                    SizedBox(
                      key: ValueKey(value),
                      height: 50,
                      child: Text('row $value'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(SegmentedCardGroup)).height, 156);
    items.value = [1, 2];
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(SegmentedCardGroup)).height, 103);
    items.value = [];
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(SegmentedCardGroup)).height, 0);
    items.value = [1];
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(SegmentedCardGroup)).height, 50);
    expect(find.text('row 1'), findsOneWidget);
  });
  testWidgets('快速显隐保持行 State，减少动态效果时立即完成', (tester) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final controller = TextEditingController(text: 'draft');
    addTearDown(controller.dispose);
    Widget host(bool reduced) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (_, show, _) => SegmentedCardGroup(
              children: [
                const SizedBox(key: ValueKey('first'), height: 48),
                if (show)
                  TextField(
                    key: const ValueKey('input'),
                    controller: controller,
                    focusNode: focus,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(host(false));
    final element = tester.element(find.byType(TextField));
    focus.requestFocus();
    await tester.pump();
    visible.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(focus.hasFocus, isFalse);
    visible.value = true;
    await tester.pumpAndSettle();
    expect(tester.element(find.byType(TextField)), same(element));
    expect(controller.text, 'draft');
    await tester.pumpWidget(host(true));
    visible.value = false;
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
