import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/webview_page.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/utils/link_launcher.dart';

import '../support/browser_test_platform.dart';
import '../support/url_launcher_test_platform.dart';

void main() {
  for (final scenario in ['confirm', 'cancel', 'false', 'throw', 'inApp']) {
    testWidgets('外链离站确认到启动浏览器：$scenario', (tester) async {
      final confirm = scenario != 'cancel';
      SharedPreferences.setMockInitialValues({
        'pref_open_external_links_in_app_browser': scenario == 'inApp',
        'pref_dialog_blur': false,
      });
      final prefs = await SharedPreferences.getInstance();
      final previous = UrlLauncherPlatform.instance;
      final launcher = TestUrlLauncher()
        ..succeeds = scenario != 'false'
        ..throwsOnLaunch = scenario == 'throw';
      final previousWebView = InAppWebViewPlatform.instance;
      InAppWebViewPlatform.instance = BrowserTestPlatform();
      UrlLauncherPlatform.instance = launcher;
      addTearDown(() {
        UrlLauncherPlatform.instance = previous;
        if (previousWebView != null) {
          InAppWebViewPlatform.instance = previousWebView;
        }
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
          child: TranslationProvider(
            child: MaterialApp(
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () =>
                        launchExternalLink(context, 'https://hb.lafi.sh/tips'),
                    child: const Text('打开'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('hb.lafi.sh'), findsOneWidget);
      expect(launcher.opened, isEmpty);
      await tester.tap(
        find.text(confirm ? t.common_continueVisit : t.common_cancel),
      );
      await tester.pumpAndSettle();
      expect(launcher.queries, 0, reason: '包可见性查询不能作为启动前提');
      expect(
        launcher.opened,
        confirm && scenario != 'inApp' ? ['https://hb.lafi.sh/tips'] : isEmpty,
      );
      final inApp = ['false', 'throw', 'inApp'].contains(scenario);
      expect(find.byType(WebViewPage), inApp ? findsOneWidget : findsNothing);
      if (inApp) {
        expect(
          tester.widget<WebViewPage>(find.byType(WebViewPage)).url,
          'https://hb.lafi.sh/tips',
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
