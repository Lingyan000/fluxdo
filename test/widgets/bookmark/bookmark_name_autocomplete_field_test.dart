import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/bookmark/bookmark_name_autocomplete_field.dart';

void main() {
  testWidgets('输入前缀后会出现已有书签名称候选并可选中', (tester) async {
    final controller = TextEditingController();

    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookmarkNameAutocompleteField(
            controller: controller,
            suggestions: const ['image', 'beta', 'icon'],
            labelText: '书签名称',
            hintText: '输入书签名称',
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextFormField), 'i');
    await tester.pumpAndSettle();

    expect(find.text('image'), findsOneWidget);
    expect(find.text('icon'), findsOneWidget);

    await tester.tap(find.text('image').last);
    await tester.pumpAndSettle();

    expect(controller.text, 'image');
  });

  testWidgets('按 Tab 会自动选中当前第一条候选', (tester) async {
    final controller = TextEditingController();

    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookmarkNameAutocompleteField(
            controller: controller,
            suggestions: const ['image', 'icon', 'beta'],
            labelText: '书签名称',
            hintText: '输入书签名称',
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextFormField), 'i');
    await tester.pumpAndSettle();

    expect(find.text('image'), findsOneWidget);
    expect(find.text('icon'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();

    expect(controller.text, 'image');
  });

  testWidgets('候选异步到达后会基于当前输入立即显示补全', (tester) async {
    final controller = TextEditingController();

    addTearDown(controller.dispose);

    Widget buildField(Iterable<String> suggestions) {
      return MaterialApp(
        home: Scaffold(
          body: BookmarkNameAutocompleteField(
            controller: controller,
            suggestions: suggestions,
            labelText: '书签名称',
            hintText: '输入书签名称',
          ),
        ),
      );
    }

    await tester.pumpWidget(buildField(const <String>[]));

    await tester.enterText(find.byType(TextFormField), 'i');
    await tester.pumpAndSettle();

    expect(find.text('image'), findsNothing);
    expect(find.text('icon'), findsNothing);

    await tester.pumpWidget(buildField(const ['image', 'icon', 'beta']));
    await tester.pumpAndSettle();

    expect(find.text('image'), findsOneWidget);
    expect(find.text('icon'), findsOneWidget);
  });
}
