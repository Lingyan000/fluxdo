import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:fluxdo/config/site_customization.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/webview_page.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/utils/link_launcher.dart';
import 'package:fluxdo/widgets/common/external_link_confirm_dialog.dart';

import '../support/browser_test_platform.dart';
import '../support/url_launcher_test_platform.dart';

const _url = 'https://hb.lafi.sh/tips';

void main() {
  for (final preferInApp in [false, true]) {
    for (final choice in [...ExternalLinkOpenChoice.values, null]) {
      testWidgets('外链本次选择 $choice 优先于内置浏览器偏好 $preferInApp', (tester) async {
        final (prefs, launcher) = await _setUpBrowser(preferInApp: preferInApp);
        await _pumpLauncher(
          tester,
          prefs,
          (context) => launchExternalLink(context, _url),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        expect(find.text('hb.lafi.sh'), findsOneWidget);
        expect(launcher.opened, isEmpty);
        final label = switch (choice) {
          ExternalLinkOpenChoice.systemBrowser =>
            t.externalLink_openInSystemBrowser,
          ExternalLinkOpenChoice.inAppBrowser =>
            t.externalLink_openInAppBrowser,
          null => t.common_cancel,
        };
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        await _expectBrowser(tester, launcher, _url, choice);
      });
    }
  }

  for (final throws in [false, true]) {
    testWidgets('系统浏览器启动失败时回退内置浏览器：throw=$throws', (tester) async {
      final (prefs, launcher) = await _setUpBrowser();
      launcher.succeeds = false;
      launcher.throwsOnLaunch = throws;
      await _pumpLauncher(
        tester,
        prefs,
        (context) => launchExternalLink(context, _url),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.externalLink_openInSystemBrowser));
      await tester.pumpAndSettle();
      expect(launcher.queries, 0, reason: '包可见性查询不能作为启动前提');
      expect(launcher.opened, [_url]);
      expect(find.byType(WebViewPage), findsOneWidget);
      expect(tester.widget<WebViewPage>(find.byType(WebViewPage)).url, _url);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final preferInApp in [false, true]) {
    testWidgets('信任链接无需确认，按偏好打开：inApp=$preferInApp', (tester) async {
      const trustedUrl = 'https://linux.do/about';
      final (prefs, launcher) = await _setUpBrowser(preferInApp: preferInApp);
      await _pumpLauncher(
        tester,
        prefs,
        (context) => launchExternalLink(
          context,
          trustedUrl,
          confirm: (_, _) => throw StateError('信任链接不应弹确认框'),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await _expectBrowser(
        tester,
        launcher,
        trustedUrl,
        preferInApp
            ? ExternalLinkOpenChoice.inAppBrowser
            : ExternalLinkOpenChoice.systemBrowser,
      );
    });
  }

  for (final choice in [...ExternalLinkOpenChoice.values, null]) {
    testWidgets('自定义确认回调传递本次选择：$choice', (tester) async {
      final (prefs, launcher) = await _setUpBrowser(preferInApp: true);
      var confirmations = 0;
      await _pumpLauncher(
        tester,
        prefs,
        (context) => launchExternalLink(
          context,
          _url,
          confirm: (url, risk) async {
            confirmations++;
            expect(url, _url);
            expect(risk, LinkRiskLevel.normal);
            return choice;
          },
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(confirmations, 1);
      expect(find.text(t.externalLink_openInSystemBrowser), findsNothing);
      await _expectBrowser(tester, launcher, _url, choice);
    });
  }

  testWidgets('阻止链接不能进入确认或打开浏览器', (tester) async {
    final (prefs, launcher) = await _setUpBrowser();
    var blocked = 0;
    await _pumpLauncher(
      tester,
      prefs,
      (context) => launchExternalLink(
        context,
        'https://chiddns.com/test',
        confirm: (_, _) => throw StateError('阻止链接不应弹确认框'),
        showBlocked: (_) async {
          blocked++;
        },
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(blocked, 1);
    await _expectBrowser(tester, launcher, _url, null);
  });
}

Future<(SharedPreferences, TestUrlLauncher)> _setUpBrowser({
  bool preferInApp = false,
}) async {
  SharedPreferences.setMockInitialValues({
    'pref_open_external_links_in_app_browser': preferInApp,
    'pref_dialog_blur': false,
  });
  final prefs = await SharedPreferences.getInstance();
  final previous = UrlLauncherPlatform.instance;
  final launcher = TestUrlLauncher();
  final previousWebView = InAppWebViewPlatform.instance;
  InAppWebViewPlatform.instance = BrowserTestPlatform();
  UrlLauncherPlatform.instance = launcher;
  addTearDown(() {
    UrlLauncherPlatform.instance = previous;
    if (previousWebView != null) {
      InAppWebViewPlatform.instance = previousWebView;
    }
  });
  return (prefs, launcher);
}

Future<void> _pumpLauncher(
  WidgetTester tester,
  SharedPreferences prefs,
  Future<void> Function(BuildContext) open,
) => tester.pumpWidget(
  ProviderScope(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    child: TranslationProvider(
      child: MaterialApp(
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
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

Future<void> _expectBrowser(
  WidgetTester tester,
  TestUrlLauncher launcher,
  String url,
  ExternalLinkOpenChoice? choice,
) async {
  expect(launcher.queries, 0, reason: '包可见性查询不能作为启动前提');
  expect(
    launcher.opened,
    choice == ExternalLinkOpenChoice.systemBrowser ? [url] : isEmpty,
  );
  final inApp = choice == ExternalLinkOpenChoice.inAppBrowser;
  expect(find.byType(WebViewPage), inApp ? findsOneWidget : findsNothing);
  if (inApp) {
    expect(tester.widget<WebViewPage>(find.byType(WebViewPage)).url, url);
  }
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
}
