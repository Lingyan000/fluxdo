import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/cf_challenge_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/network/deadline_dio.dart';
import 'package:fluxdo/services/network/exceptions/api_exception.dart';
import 'package:fluxdo/services/network/flux_request_spec.dart';
import 'package:fluxdo/services/network/interceptors/cf_challenge_interceptor.dart';
import 'package:fluxdo/services/network/interceptors/error_interceptor.dart';
import 'package:fluxdo/services/network/interceptors/request_scheduler_interceptor.dart';
import 'package:fluxdo/services/network/system_proxy_service.dart';
import 'package:fluxdo/services/network/webview/webview_adapter_settings_service.dart';
import 'package:fluxdo/widgets/common/error_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/cf_test_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = CfTestPlatform();
  final jar = CookieJarService();
  final cfService = CfChallengeService();
  late SharedPreferences prefs;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    await platform.initialize();
  });
  setUp(() async {
    await platform.reset();
    cfService.resetCooldown();
    cfService.autoVerifyEnabled = true;
    cfService.clearanceResolvedAt.value = null;
  });
  tearDown(() async {
    cfService.resetCooldown();
    WebViewAdapterSettingsService.instance.resetSessionFallback();
    SystemProxyService.instance.resetForTest();
    await platform.reset();
  });

  Future<void> mount(
    WidgetTester tester, {
    Object? error,
    VoidCallback? onRetry,
  }) => tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: Scaffold(
            body: error == null
                ? null
                : ErrorView(error: error, onRetry: onRetry ?? () {}),
          ),
        ),
      ),
    ),
  );

  Dio client(_ChallengeAdapter adapter) {
    final dio = DeadlineDio(
      BaseOptions(baseUrl: 'https://linux.do'),
      const Duration(seconds: 30),
    )..httpClientAdapter = adapter;
    dio.interceptors.addAll([
      ErrorInterceptor(),
      CfChallengeInterceptor(dio: dio, cookieJarService: jar),
    ]);
    addTearDown(() => dio.close(force: true));
    return dio;
  }

  Future<void> openVerification(WidgetTester tester) async {
    for (var i = 0; i < 20 && platform.webView == null; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(platform.webView, isNotNull);
    platform.webView!.params.onWebViewCreated!(platform.controller.wrapped);
    await tester.pump();
  }

  void finishVerification() {
    platform.webView!.params.onReceivedHttpError!(
      platform.controller.wrapped,
      WebResourceRequest(
        url: WebUri('https://linux.do/challenge'),
        isForMainFrame: true,
      ),
      WebResourceResponse(statusCode: 404),
    );
  }

  void requireInteraction() {
    platform.controller.documentHtml =
        '<html><div class="cf-turnstile"></div></html>';
    platform.webView!.params.onPageCommitVisible!(
      platform.controller.wrapped,
      WebUri('https://linux.do/challenge'),
    );
    unawaited(platform.controller.widgetEvent('interactiveBegin'));
  }

  testWidgets('错误页手动验证直达源站时说明没有出现挑战，并重试原页面', (tester) async {
    var retries = 0;
    await mount(
      tester,
      error: CfChallengeException(),
      onRetry: () => retries++,
    );
    await tester.tap(find.text(S.current.cf_manualVerifyAction));
    await openVerification(tester);
    final snapshot = Completer<List<Cookie>>();
    platform.cookies.readSnapshot = () => snapshot.future;
    finishVerification();
    await tester.pump(const Duration(milliseconds: 200));
    expect(retries, 0);
    expect(find.text(S.current.cf_noChallengeTitle), findsOneWidget);
    expect(find.text(S.current.cfVerify_success), findsNothing);
    snapshot.complete([]);
    await tester.pump();
    expect(retries, 1);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  const ok = (200, false);
  const challenged = (403, true);
  const challenged429 = (429, true);
  const forbidden = (403, false);
  const rateLimited = (429, false);
  for (final (retries, delayedSnapshot) in [
    ([ok], false),
    ([challenged], false),
    ([challenged429], false),
    ([forbidden], false),
    ([rateLimited], false),
    ([challenged, challenged429], false),
    ([challenged, forbidden], false),
    ([ok], true),
  ]) {
    testWidgets('验证后按最后一次重试 $retries 判断恢复（快照延迟=$delayedSnapshot）', (
      tester,
    ) async {
      await mount(tester);
      final adapter = _ChallengeAdapter(retries);
      final dio = client(adapter);
      final useCompat = retries.length > 1;
      if (useCompat) {
        WebViewAdapterSettingsService.instance.enableSessionFallback();
      }

      Response<dynamic>? result;
      Object? failure;
      var completed = false;
      final request = dio
          .get<dynamic>(
            useCompat ? '/latest.json' : '/',
            options: Options(
              headers: {'Accept': useCompat ? 'application/json' : 'text/html'},
            ),
          )
          .then<void>(
            (response) {
              result = response;
              completed = true;
            },
            onError: (Object error) {
              failure = error;
              completed = true;
            },
          );

      await openVerification(tester);
      // 同时等待本轮页面的调用方应拿到与原请求对应的结果。
      final pageResult = cfService.verifyPage(
        presentation: CfVerifyPresentation.blocking,
      );
      Completer<List<Cookie>>? pendingSnapshot;
      if (delayedSnapshot) {
        requireInteraction();
        await tester.pump(const Duration(seconds: 31));
        expect(completed, isFalse, reason: '前台请求应等待人工操作');
        // 验证期间另一路先写回了副本，验证页的 Cookie 快照此刻尚在读取。
        await jar.cookieJar.saveFromResponse(Uri.parse('https://linux.do'), [
          io.Cookie('cf_clearance', 'bootstrap-copy')
            ..domain = '.linux.do'
            ..path = '/',
        ]);
        pendingSnapshot = Completer<List<Cookie>>();
        platform.cookies.readSnapshot = () => pendingSnapshot!.future;
        platform.cookies.values = [cfTestCookie('current-webview-value')];
      }
      finishVerification();
      if (pendingSnapshot != null) {
        await tester.pump(const Duration(seconds: 31));
        expect(
          cfService.clearanceResolvedAt.value,
          isNotNull,
          reason: '入口无盾即可结束页面，不被当前快照读取阻塞',
        );
        expect(adapter.requests, 1, reason: '原生重试需复用当前快照，不能抢发旧 jar');
        expect(completed, isFalse, reason: '同步仍在本轮验证预算内');
        pendingSnapshot.complete(platform.cookies.values);
      }
      for (var i = 0; i < 20 && !completed; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }

      expect(completed, isTrue, reason: '不能再等待 1.5 秒或轮询新 Cookie 才重试');
      await request;
      final page = (await pageResult)!;
      expect(page.round, cfService.verifyRound);
      expect(
        page.stage,
        delayedSnapshot
            ? CfVerificationStage.challengeCleared
            : CfVerificationStage.noChallengeObserved,
      );
      expect(page.interactionRequested, delayedSnapshot);
      expect(adapter.requests, 1 + retries.length);
      expect(
        await jar.getCfClearance(),
        delayedSnapshot ? 'current-webview-value' : isNull,
      );
      if (delayedSnapshot) {
        expect(
          adapter.lastCookieHeader,
          contains('cf_clearance=current-webview-value'),
        );
      }
      final (retryStatus, isChallenge) = retries.last;
      if (retryStatus == 200) {
        expect(result?.statusCode, 200);
        expect(failure, isNull);
        expect(cfService.consecutiveFailures, 0);
        expect(cfService.isInCooldown, isFalse);
      } else {
        expect(result, isNull);
        expect(failure, isA<DioException>());
        final err = failure as DioException;
        expect(err.response?.statusCode, retryStatus);
        expect(err.error is CfChallengeException, isChallenge);
        if (isChallenge) {
          expect((err.error as CfChallengeException).verification, same(page));
        }
        if (retries.last == rateLimited) {
          expect(err.error, isA<RateLimitException>());
        }
        expect(
          err.response?.headers.value('cf-mitigated'),
          isChallenge ? 'challenge' : isNull,
        );
        if (!useCompat) expect(cfService.isInCooldown, isChallenge);
        await mount(tester, error: err);
        expect(
          find.text(S.current.cf_manualVerifyAction),
          isChallenge ? findsOneWidget : findsNothing,
        );
        final message = switch (retries.last) {
          (_, true) => S.current.cf_challengeNotEffective,
          (429, false) => S.current.error_rateLimitedRetryLater,
          _ => S.current.error_forbiddenAccess,
        };
        expect(find.text(message), findsOneWidget);
      }

      // 清理验证页面的原生析构冷却和续期服务启动定时器。
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('并发前台请求独立计算验证时限，等待面板和快照共用两分钟', (tester) async {
    await mount(tester);
    final adapter = _ChallengeAdapter([ok, ok]);
    final dio = client(adapter)
      ..interceptors.insert(0, RequestSchedulerInterceptor());
    final timeout = throwsA(
      isA<DioException>().having(
        (e) => e.error,
        'deadline',
        isA<CallDeadlineExceeded>().having(
          (e) => e.limit,
          'limit',
          const Duration(minutes: 2),
        ),
      ),
    );
    var expired = 0;
    final first = expectLater(
      dio.get<dynamic>('/'),
      timeout,
    ).then((_) => expired++);
    await openVerification(tester);
    requireInteraction();
    final early = expectLater(
      dio.get<dynamic>('/early'),
      timeout,
    ).then((_) => expired++);
    await tester.pump(const Duration(seconds: 60));
    expect(expired, 0);
    expect(adapter.requests, 1);

    final late = dio.get<dynamic>('/late');
    await tester.pump(const Duration(seconds: 5));
    final snapshot = Completer<List<Cookie>>();
    platform.cookies.readSnapshot = () => snapshot.future;
    finishVerification();
    await tester.pump(const Duration(seconds: 2));
    expect(cfService.isVerifying, isFalse);
    final afterClose = dio.get<dynamic>('/after-close');
    await tester.pump(const Duration(seconds: 55));
    expect(expired, 2);
    await Future.wait([first, early]);
    expect(adapter.requests, 1);

    snapshot.complete([]);
    await tester.pump(const Duration(milliseconds: 10));
    expect(adapter.requests, 3);
    expect((await late).statusCode, 200);
    expect((await afterClose).statusCode, 200);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (description, explicitLimit, isSilent) in [
    ('显式总时限到期', const Duration(seconds: 5), false),
    ('静默请求的显式总时限到期', const Duration(seconds: 5), true),
    ('调用方取消', null, false),
  ]) {
    testWidgets('$description，已结束的请求不会重发', (tester) async {
      await mount(tester);
      final adapter = _ChallengeAdapter([ok]);
      final dio = client(adapter);
      final token = CancelToken();
      final request = dio.get<dynamic>(
        '/',
        cancelToken: token,
        options: Options(
          extra: {
            if (isSilent) FluxRequestKeys.isSilent: true,
            if (explicitLimit != null)
              FluxRequestKeys.callTimeoutMillis: explicitLimit.inMilliseconds,
          },
        ),
      );
      final expected = expectLater(
        request,
        throwsA(
          explicitLimit == null
              ? isA<DioException>().having(
                  (e) => e.type,
                  'type',
                  DioExceptionType.cancel,
                )
              : isA<DioException>().having(
                  (e) => e.error,
                  'deadline',
                  isA<CallDeadlineExceeded>().having(
                    (e) => e.limit,
                    'limit',
                    explicitLimit,
                  ),
                ),
        ),
      );
      await openVerification(tester);
      final snapshot = Completer<List<Cookie>>();
      platform.cookies.readSnapshot = () => snapshot.future;
      finishVerification();
      await tester.pump(explicitLimit ?? const Duration(seconds: 1));
      if (explicitLimit == null) token.cancel();
      await tester.pump();
      await expected;
      snapshot.complete([]);
      await tester.pump(const Duration(seconds: 2));
      expect(adapter.requests, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

class _ChallengeAdapter implements HttpClientAdapter {
  _ChallengeAdapter(this.retries);

  final List<(int, bool)> retries;
  int requests = 0;
  String? lastCookieHeader;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastCookieHeader = options.headers['Cookie']?.toString();
    final (status, challenge) = ++requests == 1
        ? (403, true)
        : retries[requests - 2];
    return ResponseBody.fromString(
      challenge ? '<html>challenge</html>' : '{}',
      status,
      headers: {
        Headers.contentTypeHeader: [
          challenge ? 'text/html' : 'application/json',
        ],
        if (challenge) 'cf-mitigated': ['challenge'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
