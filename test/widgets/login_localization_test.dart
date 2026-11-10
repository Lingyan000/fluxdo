import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/login_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // Deferred translations must load outside the widget test's fake async zone.
  setUpAll(() async {
    for (final locale in AppLocale.values) {
      await LocaleSettings.setLocale(locale);
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() => LocaleSettings.setLocaleSync(AppLocale.zh));

  testWidgets('login page follows locale changes without losing form input', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    LocaleSettings.setLocaleSync(AppLocale.en);
    await tester.pumpWidget(
      TranslationProvider(
        child: Builder(
          builder: (context) => MaterialApp(
            locale: TranslationProvider.of(context).flutterLocale,
            supportedLocales: AppLocaleUtils.supportedLocales,
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: const LoginPage(),
          ),
        ),
      ),
    );
    // The page has a repeating background animation, so do not pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Username / email'), findsOneWidget);
    expect(find.text('Remember password'), findsOneWidget);
    expect(find.text('Forgot password?'), findsOneWidget);
    expect(find.text('Sign in with browser authorization'), findsOneWidget);
    expect(
      find.text('Other sign-in options (OAuth / Passkey / Sign up)'),
      findsOneWidget,
    );
    expect(find.text('Scan QR to sign in'), findsOneWidget);
    expect(find.text('用户名 / 邮箱'), findsNothing);
    expect(find.byTooltip('Show password'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'demo@example.test');
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(find.byTooltip('Hide password'), findsOneWidget);

    LocaleSettings.setLocaleSync(AppLocale.zh);
    await tester.pump();
    await tester.pump();
    expect(find.text('用户名 / 邮箱'), findsOneWidget);
    expect(find.text('记住密码'), findsOneWidget);
    expect(find.text('忘记密码？'), findsOneWidget);
    expect(find.text('浏览器授权登录'), findsOneWidget);
    expect(find.text('其他方式登录 (OAuth / Passkey / 注册)'), findsOneWidget);
    expect(find.text('扫码登录'), findsOneWidget);
    expect(find.text('真诚、友善、团结、专业'), findsOneWidget);
    expect(find.text('将在浏览器中打开登录页面'), findsOneWidget);
    expect(find.text('Username / email'), findsNothing);
    expect(find.byTooltip('隐藏密码'), findsOneWidget);
    expect(find.text('demo@example.test'), findsOneWidget);
    for (final locale in [AppLocale.zhTw, AppLocale.zhHk]) {
      LocaleSettings.setLocaleSync(locale);
      await tester.pump();
      await tester.pump();
      expect(find.text('記住密碼'), findsOneWidget);
      expect(find.text('瀏覽器授權登入'), findsOneWidget);
      expect(find.text('其他方式登入 (OAuth / Passkey / 註冊)'), findsOneWidget);
      expect(find.text('demo@example.test'), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
