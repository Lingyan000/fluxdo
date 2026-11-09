import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/config/site_customization.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/widgets/common/external_link_confirm_dialog.dart';

void main() {
  for (final size in [const Size(844, 390), const Size(320, 568)]) {
    for (final locale in [AppLocale.zh, AppLocale.en]) {
      for (final choice in ExternalLinkOpenChoice.values) {
        testWidgets('离站确认按钮可滚动点击：$size ${locale.name} $choice', (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          LocaleSettings.setLocale(locale);
          addTearDown(() => LocaleSettings.setLocale(AppLocale.zh));
          final scale = size.width < 400 ? 2.0 : 1.0;
          final risk = size.width < 400
              ? LinkRiskLevel.dangerous
              : LinkRiskLevel.normal;
          late Future<ExternalLinkOpenChoice?> result;
          await _pumpDialog(tester, scale, (context) {
            result = showExternalLinkConfirmDialog(
              context,
              'https://example.com/a-long-post-link?source=topic',
              risk,
            );
          });
          await tester.tap(find.text('打开'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final label = choice == ExternalLinkOpenChoice.inAppBrowser
              ? t.externalLink_openInAppBrowser
              : t.externalLink_openInSystemBrowser;
          await tester.scrollUntilVisible(
            find.text(label),
            120,
            scrollable: find.byType(Scrollable),
          );
          await tester.pumpAndSettle();
          expect(find.text(label).hitTestable(), findsOneWidget);
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          expect(await result, choice);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  for (final url in ['mailto:hello@example.com', 'tel:123456789']) {
    testWidgets('非网页链接不显示内置浏览器选项：$url', (tester) async {
      late Future<ExternalLinkOpenChoice?> result;
      await _pumpDialog(tester, 1, (context) {
        result = showExternalLinkConfirmDialog(
          context,
          url,
          LinkRiskLevel.normal,
        );
      });
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text(t.externalLink_openInAppBrowser), findsNothing);
      await tester.tap(find.text(t.externalLink_openInSystemBrowser));
      await tester.pumpAndSettle();
      expect(await result, ExternalLinkOpenChoice.systemBrowser);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('返回关闭离站确认时返回 null', (tester) async {
    late Future<ExternalLinkOpenChoice?> result;
    await _pumpDialog(tester, 1, (context) {
      result = showExternalLinkConfirmDialog(
        context,
        'https://example.com',
        LinkRiskLevel.normal,
      );
    });
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(await result, isNull);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpDialog(
  WidgetTester tester,
  double scale,
  void Function(BuildContext) open,
) async {
  SharedPreferences.setMockInitialValues({'pref_dialog_blur': false});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: TranslationProvider(
        child: MaterialApp(
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => open(context),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
