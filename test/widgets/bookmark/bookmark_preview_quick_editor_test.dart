import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/slang/strings.g.dart';
import 'package:fluxdo/widgets/bookmark/bookmark_preview_quick_editor.dart';

void main() {
  testWidgets('快速编辑会复用缓存候选并后台刷新完整补全列表', (tester) async {
    var loaderCalls = 0;

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
            body: BookmarkPreviewQuickEditor(
              initialName: 'cached',
              suggestions: const ['cached'],
              suggestionsLoader: () async {
                loaderCalls++;
                return ['cached', 'icon'];
              },
              onSave: (_) async => true,
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(loaderCalls, 1);

    await tester.enterText(find.byType(TextFormField), 'i');
    await tester.pumpAndSettle();

    expect(find.text('icon'), findsOneWidget);
  });

  testWidgets('保存成功后会自动关闭所在弹窗', (tester) async {
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
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () {
                    showDialog<void>(
                      context: context,
                      builder: (_) => Dialog(
                        child: BookmarkPreviewQuickEditor(
                          suggestions: const ['cached'],
                          onSave: (_) async => true,
                        ),
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('保存失败时会保留弹窗和输入内容', (tester) async {
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
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () {
                    showDialog<void>(
                      context: context,
                      builder: (_) => Dialog(
                        child: BookmarkPreviewQuickEditor(
                          suggestions: const ['cached'],
                          onSave: (_) async => false,
                        ),
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField), 'draft-name');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('draft-name'), findsOneWidget);
  });

  testWidgets('快速编辑输入框默认不自动聚焦', (tester) async {
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
            body: BookmarkPreviewQuickEditor(
              suggestions: const ['cached'],
              onSave: (_) async => true,
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.autofocus, isFalse);
  });
}
