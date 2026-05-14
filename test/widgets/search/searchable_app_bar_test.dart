import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/slang/strings.g.dart';
import 'package:fluxdo/widgets/search/searchable_app_bar.dart';

void main() {
  testWidgets('搜索模式输入后会立即显示清空按钮', (tester) async {
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
            appBar: SearchableAppBar(
              title: '书签',
              isSearchMode: true,
              onSearchPressed: () {},
              onCloseSearch: () {},
              onSearch: (_) {},
            ),
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'codex');
    await tester.pump();
    expect(find.byIcon(Icons.close), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.byIcon(Icons.close), findsNothing);
  });
}
