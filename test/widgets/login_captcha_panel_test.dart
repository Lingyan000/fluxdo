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
import 'package:fluxdo/widgets/auth/login_form.dart';
import 'package:fluxdo/widgets/auth/webview_login_dialog.dart';
import 'package:fluxdo/widgets/common/captcha_panel.dart';
import 'package:fluxdo/widgets/common/skeleton.dart';
import 'package:m3e_ui/m3e_ui.dart';
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
  String document = '';

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    if (source.startsWith('window.__fluxdoLogin(')) submissions++;
    if (source.contains('origin: window.location.origin')) {
      return {'origin': 'https://linux.do'};
    }
    final write = RegExp(r'document\.write\(([^\n]+)\);').firstMatch(source);
    if (write != null) document = jsonDecode(write.group(1)!) as String;
    return super.evaluateJavascript(source: source, contentWorld: contentWorld);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = _LoginPlatform();
  late SharedPreferences prefs;
  late Directory directory;
  final navigator = navigatorKey;
  final host = GlobalKey<WebViewLoginHostState>();
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
    bool reduceMotion = false,
    Future<String?> Function(WebViewLoginNeed2FA)? secondFactor,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    final phase = ValueNotifier<LoginSubmissionPhase?>(null);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigator,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: reduceMotion,
              ),
              child: child!,
            ),
            home: Scaffold(
              body: Stack(
                children: [
                  WebViewLoginHost(key: host),
                  Center(
                    child: SingleChildScrollView(
                      child: ValueListenableBuilder(
                        valueListenable: phase,
                        builder: (context, value, _) => LoginForm(
                          savedUsername: 'test-user',
                          savedPassword: 'fixture',
                          progressLabel: switch (value) {
                            LoginSubmissionPhase.verifying =>
                              context.l10n.login_confirmingVerification,
                            LoginSubmissionPhase.signingIn =>
                              context.l10n.login_captchaSubmitting,
                            null => null,
                          },
                          onSubmit:
                              ({
                                required identifier,
                                required password,
                                required rememberCredentials,
                              }) async {
                                result = await host.currentState!.show(
                                  siteKey: 'fixture',
                                  identifier: identifier,
                                  password: password,
                                  onProgress: (value) => phase.value = value,
                                  onNeedSecondFactor:
                                      secondFactor ?? (_) async => null,
                                );
                                phase.value = null;
                                return result?.status ==
                                    WebViewLoginStatus.success;
                              },
                        ),
                      ),
                    ),
                  ),
                ],
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
    final view = platform.webView!.params;
    view.onWebViewCreated!(platform.controller.wrapped);
    if (Platform.isWindows) {
      view.onLoadStop!(
        platform.controller.wrapped,
        WebUri('https://linux.do/robots.txt'),
      );
      await tester.pump();
    } else {
      platform.controller.document = view.initialData!.data;
    }
  }

  void send(String name, [Object? value]) =>
      platform.controller.handlers[name]!([value]);

  testWidgets('同一验证视图从勾选展开到做题，关闭题目返回勾选', (tester) async {
    await open(tester, size: const Size(320, 660), scale: 1.6);
    expect(find.bySemanticsLabel(l.captcha_loading), findsOneWidget);
    expect(find.byType(Skeleton), findsOneWidget);
    final initial = tester.getRect(find.byType(CaptchaPanel));
    final firstView = platform.webView;
    expect(platform.controller.document, contains("size: 'normal'"));
    send('hcaptcha_ready', 78);
    await tester.pump();
    final checkboxHeight = tester.getSize(find.byType(CaptchaPanel)).height;
    expect(tester.getRect(find.byType(CaptchaPanel)), initial);
    expect(checkboxHeight, lessThan(130));
    expect(find.bySemanticsLabel(l.login_captchaCheckbox), findsOneWidget);
    expect(find.text(l.login_captchaCheckbox), findsNothing);
    send('hcaptcha_open');
    await tester.pump();
    expect(
      tester.getSize(find.byType(CaptchaPanel)).height,
      greaterThan(checkboxHeight),
    );
    send('hcaptcha_height', 360);
    await tester.pump();
    final measured = tester.getSize(find.byType(CaptchaPanel)).height;
    send('hcaptcha_height', 405);
    await tester.pump();
    expect(tester.getSize(find.byType(CaptchaPanel)).height, measured + 45);
    await tester.pump(const Duration(minutes: 1));
    expect(find.bySemanticsLabel(l.captcha_challengeHint), findsOneWidget);
    send('hcaptcha_close');
    await tester.pump();
    send('hcaptcha_height', 600);
    await tester.pump();
    expect(tester.getSize(find.byType(CaptchaPanel)).height, checkboxHeight);
    expect(platform.webView, same(firstView));
    expect(platform.controller.submissions, 0);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(result?.status, WebViewLoginStatus.canceled);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄于横版勾选框时使用紧凑版，并按实际控件高度留位', (tester) async {
    await open(tester, size: const Size(290, 600));
    final initial = tester.getRect(find.byType(CaptchaPanel));
    expect(platform.controller.document, contains("size: 'compact'"));
    send('hcaptcha_ready', 144);
    await tester.pump();
    expect(tester.getRect(find.byType(CaptchaPanel)), initial);
    expect(
      tester.getSize(find.byType(InAppWebView)).height,
      greaterThanOrEqualTo(144),
    );
    expect(tester.takeException(), isNull);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
  });

  testWidgets('横屏的大题目可以滚到操作区，收起时仍沿用原验证视图', (tester) async {
    await open(tester, size: const Size(700, 320));
    final firstView = platform.webView;
    send('hcaptcha_ready', 78);
    send('hcaptcha_open');
    send('hcaptcha_height', 500);
    await tester.pump();
    final scrollable = find.descendant(
      of: find.byType(CaptchaPanel),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(
      tester.getSize(find.byType(InAppWebView)).height,
      greaterThanOrEqualTo(500),
    );
    expect(position.maxScrollExtent, greaterThan(0));
    await tester.drag(scrollable, const Offset(0, -650));
    await tester.pumpAndSettle();
    expect(position.pixels, position.maxScrollExtent);
    send('hcaptcha_close');
    await tester.pumpAndSettle();
    expect(position.pixels, 0);
    expect(platform.webView, same(firstView));
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
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
    expect(find.bySemanticsLabel(l.captcha_loading), findsOneWidget);
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
    final button = find.descendant(
      of: find.byType(LoginForm),
      matching: find.byType(FilledButton),
    );
    final spinner = find.descendant(
      of: button,
      matching: find.byType(LoadingSpinner),
    );
    final bounds = tester.getRect(button);
    expect(tester.getSize(spinner), const Size.square(24));
    expect(tester.getCenter(spinner), bounds.center);
    send('hcaptcha_ready');
    final element = tester.element(find.byType(InAppWebView));
    send('hcaptcha_pass', 'sample');
    send('hcaptcha_pass', 'duplicate');
    send('hcaptcha_expired');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text(l.login_captchaTitle), findsNothing);
    expect(find.byType(CaptchaPanel), findsNothing);
    final hint = find.text(l.login_confirmingVerification);
    expect(
      find.bySemanticsLabel(l.login_confirmingVerification),
      findsOneWidget,
    );
    expect(tester.getRect(button), bounds);
    expect(tester.getCenter(spinner).dy, tester.getCenter(hint).dy);
    expect(
      tester.getRect(spinner).expandToInclude(tester.getRect(hint)).center,
      bounds.center,
    );
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    expect(platform.controller.submissions, 1);
    final spinnerBeforeSignIn = tester.element(spinner);
    send('login_submitting');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(find.text(l.login_captchaSubmitting), findsOneWidget);
    expect(tester.element(spinner), same(spinnerBeforeSignIn));
    expect(tester.getRect(button), bounds);
    expect(find.byType(LinearProgressIndicator), findsNothing);
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
    expect(
      tester.element(find.byType(InAppWebView, skipOffstage: false)),
      same(element),
    );
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

  testWidgets('桌面勾选前后等高，只有做题时加宽弹框', (tester) async {
    await open(tester, size: const Size(1080, 720));
    final initial = tester.getRect(find.byType(CaptchaPanel));
    expect(initial.width, 368);
    send('hcaptcha_ready', 78);
    await tester.pump();
    expect(tester.getRect(find.byType(CaptchaPanel)), initial);
    send('hcaptcha_open');
    await tester.pump();
    expect(tester.getSize(find.byType(CaptchaPanel)).width, 560);
    send('hcaptcha_close');
    await tester.pump();
    expect(tester.getRect(find.byType(CaptchaPanel)), initial);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
  });

  testWidgets('快速返回跳过等待文案，失败保留账号和密码', (tester) async {
    await open(tester);
    send('hcaptcha_pass', 'fixture');
    await tester.pump(const Duration(milliseconds: 50));
    send('login_submitting');
    send(
      'login_result',
      jsonEncode({'phase': 'session', 'status': 403, 'body': '{}'}),
    );
    await tester.pumpAndSettle();
    expect(result?.status, WebViewLoginStatus.failure);
    expect(find.text(l.login_confirmingVerification), findsNothing);
    expect(find.text(l.login_captchaSubmitting), findsNothing);
    expect(find.byType(LoadingSpinner), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    expect(find.text('test-user'), findsOneWidget);
    expect(
      tester
          .widgetList<TextField>(find.byType(TextField))
          .last
          .controller!
          .text,
      'fixture',
    );
  });

  testWidgets('离开登录页会结束已收起的验证会话并忽略迟到结果', (tester) async {
    await open(tester);
    send('hcaptcha_pass', 'fixture');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final lateResult = platform.controller.handlers['login_result']!;
    await tester.pumpWidget(const SizedBox.shrink());
    lateResult([
      jsonEncode({'phase': 'session', 'status': 200, 'body': '{}'}),
    ]);
    await tester.pump();
    expect(result?.status, WebViewLoginStatus.canceled);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭承载验证弹层的导航器会取消尚未提交的登录', (tester) async {
    await open(tester);
    final latePass = platform.controller.handlers['hcaptcha_pass']!;
    await tester.pumpWidget(const SizedBox.shrink());
    latePass(['fixture']);
    await tester.pump();
    expect(result?.status, WebViewLoginStatus.canceled);
    expect(platform.controller.submissions, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('减少动态效果时使用静态骨架和按钮状态，并可取消二步验证', (tester) async {
    final factor = Completer<String?>();
    await open(
      tester,
      size: const Size(320, 580),
      scale: 1.8,
      reduceMotion: true,
      secondFactor: (_) => factor.future,
    );
    expect(find.byType(Skeleton), findsNothing);
    expect(find.byType(SkeletonBox), findsWidgets);
    send('hcaptcha_ready', 78);
    send('hcaptcha_pass', 'fixture');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(l.login_confirmingVerification), findsOneWidget);
    expect(find.byType(LoadingSpinner), findsNothing);
    send(
      'login_result',
      jsonEncode({
        'phase': 'session',
        'status': 200,
        'body': jsonEncode({'reason': 'second_factor', 'totp_enabled': true}),
      }),
    );
    await tester.pump();
    factor.complete(null);
    await tester.pumpAndSettle();
    expect(result?.status, WebViewLoginStatus.canceled);
    expect(platform.controller.submissions, 1);
    expect(find.byType(InAppWebView, skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('登录成功等待原会话同步，快速响应不展示中间文案', (tester) async {
    await open(tester);
    send('hcaptcha_pass', 'fixture');
    await tester.pump();
    send('login_submitting');
    send(
      'login_result',
      jsonEncode({
        'phase': 'session',
        'status': 200,
        'body': jsonEncode({
          'user': {'id': 1},
        }),
      }),
    );
    await tester.pump();
    expect(result, isNull);
    final bootstrap = platform.controller.handlers.keys.singleWhere(
      (name) => name.startsWith('fluxdo_session_bootstrap_'),
    );
    send(bootstrap, jsonEncode({'ok': true}));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(result?.status, WebViewLoginStatus.success);
    expect(find.text(l.login_confirmingVerification), findsNothing);
    expect(find.text(l.login_captchaSubmitting), findsNothing);
    expect(find.byType(InAppWebView, skipOffstage: false), findsNothing);
  });
}
