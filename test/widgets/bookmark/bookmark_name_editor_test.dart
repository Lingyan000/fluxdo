import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/app_localizations.dart';
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
}
