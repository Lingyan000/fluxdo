/// Callout 属性对话框:headerMarkdown 组装 + 对话框交互返回 spec。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/callout_edit_dialog.dart';

Future<ProviderScope> _scoped(Widget child) async {
  SharedPreferences.setMockInitialValues(const {});
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    child: child,
  );
}

void main() {
  test('headerMarkdown:折叠三态与标题组装', () {
    expect(
      const CalloutSpec(type: 'note', title: '', foldable: null)
          .headerMarkdown,
      '[!note]',
    );
    expect(
      const CalloutSpec(type: 'warning', title: '当心', foldable: true)
          .headerMarkdown,
      '[!warning]+ 当心',
    );
    expect(
      const CalloutSpec(type: 'tip', title: ' 空白裁剪 ', foldable: false)
          .headerMarkdown,
      '[!tip]- 空白裁剪',
    );
  });

  testWidgets('对话框:改类型/标题/折叠态后确定返回 spec', (tester) async {
    CalloutSpec? result;
    await tester.pumpWidget(await _scoped(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showCalloutEditDialog(ctx);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, 'warning'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '注意事项');
    await tester.tap(find.text('可折叠'));
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.type, 'warning');
    expect(result!.title, '注意事项');
    expect(result!.foldable, isTrue);
    expect(result!.headerMarkdown, '[!warning]+ 注意事项');
  });

  testWidgets('清单外自定义类型保留为候选且默认选中', (tester) async {
    CalloutSpec? result;
    await tester.pumpWidget(await _scoped(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showCalloutEditDialog(ctx,
                    type: 'mycustom', title: 'T', foldable: false);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final chip = tester
        .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'mycustom'));
    expect(chip.selected, isTrue);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result!.type, 'mycustom');
    expect(result!.foldable, isFalse);
  });
}
