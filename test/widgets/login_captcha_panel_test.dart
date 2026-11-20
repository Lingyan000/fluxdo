import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/widgets/auth/webview_login_dialog.dart';
import 'package:fluxdo/widgets/common/captcha_panel.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/cf_test_platform.dart';

class _LoginPlatform extends CfTestPlatform {
  late final _login = _LoginController(cookies);
  @override
  _LoginController get controller => _login;
}

class _LoginController extends CfTestController {
  _LoginController(super.cookies);
  int submissions = 0;

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    if (source.startsWith('window.__fluxdoLogin(')) submissions++;
    return super.evaluateJavascript(source: source, contentWorld: contentWorld);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = _LoginPlatform();
  late SharedPreferences prefs;
  late Directory directory;
  final navigator = navigatorKey;
  WebViewLoginDialogResult? result;
  late AppLocalizations l;

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zh);
    SharedPreferences.setMockInitialValues({'pref_dialog_blur': false});
    FlutterSecureStorage.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    directory = await Directory.systemTemp.createTemp('login-captcha-test-');
    await platform.initialize(cookieDirectory: directory.path);
  });
  tearDownAll(() => directory.delete(recursive: true));
  setUp(() async {
    await platform.reset();
    result = null;
    platform.controller.submissions = 0;
  });

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(360, 720),
    double scale = 1,
    Future<String?> Function(WebViewLoginNeed2FA)? secondFactor,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigator,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    result = await showWebViewLoginDialog(
                      context,
                      siteKey: 'fixture',
                      identifier: 'test-user',
                      password: 'fixture',
                      onNeedSecondFactor: secondFactor ?? (_) async => null,
                    );
                  },
                  child: const Text('登录'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    l = navigator.currentContext!.l10n;
    platform.webView!.params.onWebViewCreated!(platform.controller.wrapped);
  }

  void send(String name, [Object? value]) =>
      platform.controller.handlers[name]!([value]);

  testWidgets('同一验证视图从勾选展开到做题，关闭题目返回勾选', (tester) async {
    await open(tester, size: const Size(320, 660), scale: 1.6);
    expect(find.text(l.captcha_loading), findsOneWidget);
    final firstView = platform.webView;
    send('hcaptcha_ready');
    await tester.pump();
    final checkboxHeight = tester.getSize(find.byType(CaptchaPanel)).height;
    expect(find.text(l.login_captchaCheckbox), findsOneWidget);
    send('hcaptcha_open');
    await tester.pump();
    expect(
      tester.getSize(find.byType(CaptchaPanel)).height,
      greaterThan(checkboxHeight),
    );
    await tester.pump(const Duration(minutes: 1));
    expect(find.text(l.captcha_challengeHint), findsOneWidget);
    send('hcaptcha_close');
    await tester.pump();
    expect(find.text(l.login_captchaCheckbox), findsOneWidget);
    expect(platform.webView, same(firstView));
    expect(platform.controller.submissions, 0);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(result?.status, WebViewLoginStatus.canceled);
    expect(tester.takeException(), isNull);
  });

  testWidgets('超时或过期可在原处重试，旧视图回调与退出时的回调作废', (tester) async {
    await open(tester, size: const Size(900, 400));
    final oldReady = platform.controller.handlers['hcaptcha_ready']!;
    final oldPass = platform.controller.handlers['hcaptcha_pass']!;
    await tester.pump(const Duration(seconds: 46));
    expect(find.text(l.captcha_unavailable), findsOneWidget);
    await tester.tap(find.text(l.common_retry));
    await tester.pump();
    platform.webView!.params.onWebViewCreated!(platform.controller.wrapped);
    oldReady([]);
    oldPass(['stale']);
    await tester.pump();
    expect(find.text(l.captcha_loading), findsOneWidget);
    send('hcaptcha_ready');
    send('hcaptcha_expired');
    await tester.pumpAndSettle();
    expect(find.text(l.captcha_expired), findsOneWidget);
    navigator.currentState!.pop();
    send('hcaptcha_pass', 'late');
    await tester.pumpAndSettle();
    expect(platform.controller.submissions, 0);
    expect(result?.status, WebViewLoginStatus.canceled);
    expect(find.text('登录'), findsOneWidget);
  });

  testWidgets('提交和二步验证保留同一会话，重复的验证码回调不重发登录', (tester) async {
    final factor = Completer<String?>();
    var prompts = 0;
    await open(
      tester,
      secondFactor: (need) {
        expect(need.totpEnabled, isTrue);
        prompts++;
        return factor.future;
      },
    );
    final firstView = platform.webView;
    send('hcaptcha_ready');
    send('hcaptcha_pass', 'sample');
    send('hcaptcha_pass', 'duplicate');
    send('hcaptcha_expired');
    await tester.pump();
    expect(find.text(l.login_captchaSubmitting), findsOneWidget);
    expect(platform.controller.submissions, 1);
    send(
      'login_result',
      jsonEncode({
        'phase': 'session',
        'status': 200,
        'body': jsonEncode({'reason': 'second_factor', 'totp_enabled': true}),
      }),
    );
    await tester.pump();
    expect(prompts, 1);
    factor.complete('000000');
    await tester.pump();
    expect(platform.controller.submissions, 2);
    expect(platform.webView, same(firstView));
    send(
      'login_result',
      jsonEncode({
        'phase': 'session',
        'status': 200,
        'body': jsonEncode({'reason': 'invalid_credentials'}),
      }),
    );
    await tester.pumpAndSettle();
    expect(result?.status, WebViewLoginStatus.failure);
    expect(find.text('登录'), findsOneWidget);
  });
}
