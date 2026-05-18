import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/slang/strings.g.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/bookmark/bookmark_edit_sheet.dart';

void main() {
  testWidgets('未显式传入候选时也会异步加载书签名称自动补全', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          navigatorKey: navigatorKey,
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: Scaffold(
            body: BookmarkEditSheet(
              bookmarkId: 1,
              nameSuggestionsLoader: () async => ['image', 'icon'],
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'i');
    await tester.pumpAndSettle();

    expect(find.text('image'), findsOneWidget);
    expect(find.text('icon'), findsOneWidget);
  });

  testWidgets('编辑面板中的书签名称候选列表可滚动查看更多选项', (tester) async {
    final suggestions = List<String>.generate(12, (index) => 'tag-${index + 1}');

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          navigatorKey: navigatorKey,
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: Scaffold(
            body: BookmarkEditSheet(
              bookmarkId: 1,
              nameSuggestions: suggestions,
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextFormField));
    await tester.pumpAndSettle();

    expect(find.text('tag-12'), findsNothing);

    await tester.drag(find.byType(ListView).last, const Offset(0, -400));
    await tester.pumpAndSettle();

    expect(find.text('tag-12'), findsOneWidget);
  });

  testWidgets('传入缓存候选后仍会后台刷新完整补全列表', (tester) async {
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
          navigatorKey: navigatorKey,
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: Scaffold(
            body: BookmarkEditSheet(
              bookmarkId: 1,
              nameSuggestions: const ['cached'],
              nameSuggestionsLoader: () async {
                loaderCalls++;
                return ['cached', 'icon'];
              },
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

  testWidgets('窄屏且键盘弹起时编辑面板仍可滚动显示', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          navigatorKey: navigatorKey,
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 480),
              viewInsets: EdgeInsets.only(bottom: 180),
            ),
            child: Scaffold(
              body: BookmarkEditSheet(
                bookmarkId: 1,
                initialReminderAt: DateTime(2026, 5, 13, 12, 34),
                nameSuggestions: const ['cached'],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('初始书签名为问号时输入框会视为空值', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          navigatorKey: navigatorKey,
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: Scaffold(
            body: BookmarkEditSheet(
              bookmarkId: 1,
              initialName: '?',
              nameSuggestions: const ['image'],
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final field = tester.widget<TextFormField>(find.byType(TextFormField));
    expect(field.controller?.text, isEmpty);
  });
}
