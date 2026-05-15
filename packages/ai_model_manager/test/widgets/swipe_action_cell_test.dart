import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpCell(
    WidgetTester tester, {
    required bool enableLongPressMenu,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SwipeActionCell(
            enableLongPressMenu: enableLongPressMenu,
            trailingActions: [
              SwipeAction(
                icon: Icons.delete_outline,
                color: Colors.red,
                label: '删除',
                onPressed: () {},
              ),
            ],
            child: const ListTile(
              title: Text('供应商'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('long press menu is shown when enabled', (tester) async {
    await pumpCell(tester, enableLongPressMenu: true);

    await tester.longPress(find.text('供应商'));
    await tester.pumpAndSettle();

    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('long press menu is not shown when disabled', (tester) async {
    await pumpCell(tester, enableLongPressMenu: false);

    await tester.longPress(find.text('供应商'));
    await tester.pumpAndSettle();

    expect(find.text('删除'), findsNothing);
  });
}
