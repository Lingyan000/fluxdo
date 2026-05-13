import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/app_localizations.dart';
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
}
