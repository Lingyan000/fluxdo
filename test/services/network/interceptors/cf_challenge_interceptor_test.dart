import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/cf_challenge_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/network/interceptors/cf_challenge_interceptor.dart';
import 'package:fluxdo/services/network/system_proxy_service.dart';

import '../../../support/cf_test_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = CfTestPlatform();
  final jar = CookieJarService();
  final cfService = CfChallengeService();

  setUpAll(platform.initialize);
  setUp(() async {
    await platform.reset();
    cfService.resetCooldown();
    cfService.autoVerifyEnabled = true;
    cfService.clearanceResolvedAt.value = null;
  });
  tearDown(() async {
    cfService.resetCooldown();
    SystemProxyService.instance.resetForTest();
    await platform.reset();
  });

  for (final (retryStatus, delayedSnapshot) in [
    (200, false),
    (403, false),
    (200, true),
  ]) {
    testWidgets('入口无盾后以 API $retryStatus 判断恢复（快照延迟=$delayedSnapshot）', (
      tester,
    ) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: const Scaffold(body: SizedBox.shrink()),
          ),
        ),
      );

      final adapter = _ChallengeAdapter(retryStatus);
      final dio = Dio(BaseOptions(baseUrl: 'https://linux.do'))
        ..httpClientAdapter = adapter;
      dio.interceptors.add(
        CfChallengeInterceptor(dio: dio, cookieJarService: jar),
      );
      addTearDown(() => dio.close(force: true));

      Response<dynamic>? result;
      Object? failure;
      var completed = false;
      final request = dio
          .get<dynamic>(
            '/latest.json',
            options: Options(extra: {'isSilent': true}),
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

      for (var i = 0; i < 20 && platform.webView == null; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(platform.webView, isNotNull);
      platform.webView!.params.onWebViewCreated!(platform.controller.wrapped);
      Completer<Cookie?>? pendingValue;
      if (delayedSnapshot) {
        // 验证期间另一路先写回了副本，验证页的 Cookie 快照此刻尚在读取。
        await jar.cookieJar.saveFromResponse(Uri.parse('https://linux.do'), [
          io.Cookie('cf_clearance', 'bootstrap-copy')
            ..domain = '.linux.do'
            ..path = '/',
        ]);
        pendingValue = Completer<Cookie?>();
        platform.cookies.readValue = (_) => pendingValue!.future;
        platform.cookies.values = [cfTestCookie('current-webview-value')];
      }
      platform.webView!.params.onReceivedHttpError!(
        platform.controller.wrapped,
        WebResourceRequest(
          url: WebUri('https://linux.do/challenge'),
          isForMainFrame: true,
        ),
        WebResourceResponse(statusCode: 404),
      );
      if (pendingValue != null) {
        await tester.pump(const Duration(milliseconds: 10));
        expect(
          cfService.clearanceResolvedAt.value,
          isNotNull,
          reason: '入口无盾即可结束页面，不被当前快照读取阻塞',
        );
        expect(adapter.requests, 1, reason: '原生重试需复用当前快照，不能抢发旧 jar');
        pendingValue.complete(cfTestCookie('current-webview-value'));
      }
      for (var i = 0; i < 20 && !completed; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }

      expect(completed, isTrue, reason: '不能再等待 1.5 秒或轮询新 Cookie 才重试');
      await request;
      expect(adapter.requests, 2);
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
      if (retryStatus == 200) {
        expect(result?.statusCode, 200);
        expect(failure, isNull);
        expect(cfService.consecutiveFailures, 0);
        expect(cfService.isInCooldown, isFalse);
      } else {
        expect(result, isNull);
        expect(failure, isA<DioException>());
        expect((failure as DioException).response?.statusCode, 403);
        expect(cfService.isInCooldown, isTrue);
      }

      // 清理验证页面的原生析构冷却和续期服务启动定时器。
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

class _ChallengeAdapter implements HttpClientAdapter {
  _ChallengeAdapter(this.retryStatus);

  final int retryStatus;
  int requests = 0;
  String? lastCookieHeader;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastCookieHeader = options.headers['Cookie']?.toString();
    final status = ++requests == 1 ? 403 : retryStatus;
    return ResponseBody.fromString(
      status == 403 ? '<html>challenge</html>' : '{}',
      status,
      headers: {
        Headers.contentTypeHeader: [
          status == 403 ? 'text/html' : 'application/json',
        ],
        if (status == 403) 'cf-mitigated': ['challenge'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
