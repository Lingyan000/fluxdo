import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/slang/strings.g.dart';
import 'package:fluxdo/widgets/bookmark/bookmark_name_editor.dart';

void main() {
  testWidgets('带保存按钮模式下可以直接修改标签名并保存', (tester) async {
    final controller = TextEditingController(text: 'image');
    String? savedValue;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: Scaffold(
            body: BookmarkNameEditor(
              controller: controller,
              suggestions: const ['image', 'icon', 'beta'],
              onSave: (value) async {
                savedValue = value;
              },
            ),
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextFormField), 'icon');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(savedValue, 'icon');
  });

  testWidgets('窄屏下保存按钮会移到输入框下方', (tester) async {
    final controller = TextEditingController(text: 'image');
    addTearDown(controller.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(320, 640));

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: Scaffold(
            body: BookmarkNameEditor(
              controller: controller,
              suggestions: const ['image', 'icon', 'beta'],
              onSave: (_) async {},
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final fieldTop = tester.getTopLeft(find.byType(TextFormField)).dy;
    final saveTop = tester
        .getTopLeft(find.widgetWithText(FilledButton, '保存'))
        .dy;

    expect(saveTop, greaterThan(fieldTop + 40));
    expect(tester.takeException(), isNull);
  });
}
