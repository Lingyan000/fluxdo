import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/cf_challenge_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/log/log_policy.dart';
import 'package:fluxdo/services/log/log_writer.dart';
import 'package:fluxdo/services/network/adapters/adapter_log_metadata.dart';
import 'package:fluxdo/services/network/core/net_core_http_adapter.dart';
import 'package:fluxdo/services/network/cookie/app_cookie_manager.dart';
import 'package:fluxdo/services/network/cookie/cookie_logger.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/network/interceptors/cf_challenge_interceptor.dart';
import 'package:fluxdo/services/network/interceptors/network_log_interceptor.dart';
import 'package:fluxdo/services/network/interceptors/request_scheduler_interceptor.dart';
import 'package:fluxdo/services/network/request_scheduler_config.dart';
import 'package:fluxdo/services/network/vpn_auto_toggle_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/cf_test_platform.dart';

class _RecordingAdapter implements HttpClientAdapter {
  final requests = <({String path, String? cookie})>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add((
      path: options.path,
      cookie:
          options.headers['Cookie']?.toString() ??
          options.headers['cookie']?.toString(),
    ));
    setRequestAdapterLogName(options, 'core');
    options.extra['coreRequestId'] = requests.length;
    final challenge = requests.length == 1;
    final response = ResponseBody.fromString(
      challenge ? '<html>challenge</html>' : '{}',
      challenge ? 403 : 200,
      headers: {
        'content-type': [challenge ? 'text/html' : 'application/json'],
        if (challenge) 'cf-mitigated': ['challenge'],
        if (challenge) 'cf-ray': ['test-ray-HKG'],
      },
    );
    response.extra[HttpClientAdapter.extraKeyHttpVersion] = '2.0';
    response.extra[netCoreConnectionExtraKey] = {
      'connectionId': 26,
      'reused': true,
      'echApplied': true,
      'echAccepted': true,
    };
    return response;
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = CfTestPlatform();
  final jar = CookieJarService();
  late io.Directory logDirectory;
  setUpAll(platform.initialize);
  setUp(() async {
    await platform.reset();
    logDirectory = await io.Directory.systemTemp.createTemp('cf-resume-log-');
    await LogWriter.initForTesting(logDirectory);
  });
  tearDown(() async {
    await LogWriter.resetForTesting();
    await logDirectory.delete(recursive: true);
  });

  testWidgets('过盾前后到达的请求等待 Cookie 同步，取消请求立即退出', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: TranslationProvider(
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
      ),
    );
    final cf = CfChallengeService()..resetCooldown();
    cf.autoVerifyEnabled = true;
    await jar.setCookie(
      'cf_clearance',
      'old-clearance',
      domain: '.linux.do',
      trusted: true,
    );
    expect(LogWriter.verboseEnabled, isFalse);
    final vpn = VpnAutoToggleService.instance;
    final previousVpnState = vpn.vpnActive;
    vpn.vpnActiveNotifier.value = true;
    addTearDown(() => vpn.vpnActiveNotifier.value = previousVpnState);
    final adapter = _RecordingAdapter();
    final oldMax = RequestSchedulerConfig.maxPerWindow;
    RequestSchedulerConfig.maxPerWindow = 100;
    final dio = Dio(BaseOptions(baseUrl: 'https://linux.do'))
      ..httpClientAdapter = adapter;
    dio.interceptors.addAll([
      RequestSchedulerInterceptor(),
      AppCookieManager(jar.cookieJar),
      CfChallengeInterceptor(dio: dio, cookieJarService: jar),
      NetworkLogInterceptor(),
    ]);
    addTearDown(() {
      dio.close(force: true);
      RequestSchedulerConfig.maxPerWindow = oldMax;
    });

    final first = dio.get<dynamic>(
      '/first',
      queryParameters: {'token': 'query-secret'},
      options: Options(extra: {'isSilent': true}),
    );
    for (var i = 0; i < 30 && platform.webView == null; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(platform.webView, isNotNull);
    platform.webView!.params.onWebViewCreated!(platform.controller.wrapped);
    await tester.pump();

    final duringVerification = dio.get<dynamic>('/during-verification');
    await tester.pump(const Duration(milliseconds: 10));
    expect(adapter.requests.length, 1);

    final pendingCookie = Completer<Cookie?>();
    platform.cookies.readValue = (_) => pendingCookie.future;
    platform.cookies.values = [cfTestCookie('fresh-clearance')];
    platform.webView!.params.onReceivedHttpError!(
      platform.controller.wrapped,
      WebResourceRequest(
        url: WebUri('https://linux.do/challenge'),
        isForMainFrame: true,
      ),
      WebResourceResponse(
        statusCode: 404,
        headers: {
          'CF-Ray': 'verify-ray-HKG',
          'Set-Cookie': 'cf_clearance=header-secret; HttpOnly',
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1250));
    await tester.pump();
    expect(cf.isVerifying, isFalse);
    final afterClose = dio.get<dynamic>('/after-close');
    final cancelToken = CancelToken();
    final cancelled = dio.get<dynamic>('/cancelled', cancelToken: cancelToken);
    final cancellation = expectLater(
      cancelled,
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 10));
    cancelToken.cancel('取消等待 Cookie 同步的请求');
    await tester.pump(const Duration(milliseconds: 10));
    await cancellation;
    final beforeCookieSync = [...adapter.requests];

    var requestsCompleted = false;
    final requests = Future.wait([first, duringVerification, afterClose])
        .then((_) => requestsCompleted = true);
    pendingCookie.complete(cfTestCookie('fresh-clearance'));
    for (var i = 0; i < 30 && !requestsCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(requestsCompleted, isTrue, reason: 'Cookie 同步完成后应恢复所有等待请求');
    await requests;
    final firstResponse = await first;
    final exported = await tester.runAsync(() async {
      return LogPolicy.export(await LogWriter.readAllContent());
    });
    expect(exported, isNotNull);
    final rows = const LineSplitter()
        .convert(exported!)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();
    final challenge = rows
        .where(
          (row) =>
              row['event'] == 'cf_challenge_detected' &&
              row['type'] == 'request',
        )
        .single;
    expect(challenge['statusCode'], 403);
    expect(challenge['method'], 'GET');
    expect(challenge['isSilent'], isTrue);
    expect(challenge['traceId'], firstResponse.requestOptions.extra['traceId']);
    expect(
      challenge['attemptId'],
      isNot(firstResponse.requestOptions.extra['attemptId']),
    );
    expect(challenge['coreRequestId'], 1);
    expect(challenge['connectionId'], 26);
    expect(challenge['networkAdapter'], 'core');
    expect(challenge['httpVersion'], '2.0');
    expect(challenge['connReused'], isTrue);
    expect(challenge['echAccepted'], isTrue);
    expect(challenge['respCfRay'], 'test-ray-HKG');
    expect(challenge['respCfMitigated'], 'challenge');
    expect(challenge['cfNetworkContext']['vpnDetectionReportedActive'], isTrue);
    expect(challenge['cfNetworkContext']['vpnDetectionMode'], 'automatic');
    expect(
      challenge['cfNetworkContext']['webViewProxyOverrideRegistered'],
      isFalse,
    );
    expect(
      challenge['inputCfClearanceHash'],
      CookieLogger.valueHash('old-clearance'),
    );
    expect(challenge['sentCookies'], contains('cf_clearance(13)'));
    final resumed = rows
        .where((row) => row['url'] == 'https://linux.do/after-close')
        .single;
    final freshHash = CookieLogger.valueHash('fresh-clearance');
    final retry = rows
        .where(
          (row) =>
              row['url'] == 'https://linux.do/first' &&
              row['event'] == 'request_complete',
        )
        .single;
    expect(retry['traceId'], challenge['traceId']);
    expect(retry['attemptId'], firstResponse.requestOptions.extra['attemptId']);
    expect(retry['statusCode'], 200);
    expect(retry['isSilent'], isTrue);
    expect(retry['inputCfClearanceHash'], freshHash);
    expect(resumed['statusCode'], 200);
    expect(resumed['inputCfClearanceHash'], freshHash);
    final sync = rows
        .where((row) => row['event'] == 'cf_completion_cookie_sync')
        .single;
    expect(sync['cookieSyncCompleted'], isTrue);
    expect(sync['verifyStatusCode'], 404);
    expect(sync['verifyCfRay'], 'verify-ray-HKG');
    expect(sync['cfNetworkContext'], challenge['cfNetworkContext']);
    expect(sync['cookieSyncDurationMs'], greaterThanOrEqualTo(0));
    expect(sync['webViewCfClearanceHash'], freshHash);
    expect(sync['jarCfClearanceHash'], freshHash);
    for (final secret in [
      'old-clearance',
      'fresh-clearance',
      'query-secret',
      'header-secret',
    ]) {
      expect(exported, isNot(contains(secret)));
    }
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
    expect(beforeCookieSync.length, 1, reason: '验证完成通知不应让等待请求抢在 Cookie 落库前发送');
    expect(
      adapter.requests.skip(1).map((request) => request.cookie),
      everyElement(contains('cf_clearance=fresh-clearance')),
    );
    expect(
      adapter.requests.map((request) => request.path),
      unorderedEquals([
        '/first',
        '/first',
        '/during-verification',
        '/after-close',
      ]),
    );
  });
}
