import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/browser_trust_coordinator.dart';
import 'package:fluxdo/services/cf_challenge_service.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/network/exceptions/api_exception.dart';
import 'package:fluxdo/services/network/system_proxy_service.dart';
import 'package:fluxdo/services/network/webview/site_webview_runtime.dart';
import 'package:fluxdo/services/network/webview/webview_adapter_settings_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/cf_test_platform.dart';

const _home =
    '<script id="data-preloaded" type="application/json">'
    '{"siteSettings":{"title":"FluxDO"}}</script>';

class _HomeAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int status = 200;
  String body = _home;
  final headers = <String, List<String>>{
    Headers.contentTypeHeader: ['text/html; charset=utf-8'],
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(body, status, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = CfTestPlatform();
  final settings = WebViewAdapterSettingsService.instance;
  late final BrowserTrustCoordinator startup;
  late final PreloadedDataService preload;
  late final HttpClientAdapter originalAdapter;
  late _HomeAdapter http;
  final stages = <BrowserTrustPreloadStage?>[];
  void record() => stages.add(startup.preloadStage.value);

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await settings.initialize(await SharedPreferences.getInstance());
    await platform.initialize();
    preload = PreloadedDataService();
    startup = BrowserTrustCoordinator.instance;
    originalAdapter = preload.dioForTesting.httpClientAdapter;
    startup.preloadStage.addListener(record);
    // 让兼容模式下的浏览器租约立即失败，测试可检查回退路径。
    await SiteWebViewRuntime.instance.suspendAndDrain();
  });
  setUp(() async {
    await platform.reset();
    preload.reset();
    http = _HomeAdapter();
    preload.dioForTesting.httpClientAdapter = http;
    stages.clear();
  });
  tearDownAll(() async {
    startup.preloadStage.removeListener(record);
    preload.dioForTesting.httpClientAdapter = originalAdapter;
    preload.reset();
    SiteWebViewRuntime.instance.resume();
    settings.resetForTest();
    await platform.reset();
  });

  for (final ttl in [null, const Duration(minutes: 9)]) {
    test('首页${ttl == null ? '缺少' : '仅剩 9 分钟的'}通行 Cookie 时优先原生请求', () async {
      if (ttl != null) {
        await CookieJarService().setCookie(
          'cf_clearance',
          'test-clearance',
          expires: DateTime.now().toUtc().add(ttl),
        );
      }

      final first = startup.ensurePreloaded(reason: 'startup');
      expect(startup.ensurePreloaded(reason: 'preheat_gate'), same(first));
      await first;

      expect(stages, [BrowserTrustPreloadStage.native, null]);
      final request = http.requests.single;
      expect(request.method, 'GET');
      expect(request.extra['requestTag'], 'preload-home');
      expect(preload.siteSettingsSync?['title'], 'FluxDO');
    });
  }

  test('首页权限 403 保留响应并可由用户重新加载', () async {
    http.status = 403;
    await expectLater(
      startup.ensurePreloaded(),
      throwsA(
        isA<DioException>().having((e) => e.response?.statusCode, 'HTTP', 403),
      ),
    );
    expect(http.requests, hasLength(1));
    expect(stages, [BrowserTrustPreloadStage.native, null]);

    http.status = 200;
    await startup.ensurePreloaded();
    expect(preload.isLoaded, isTrue);
    expect(http.requests, hasLength(2));
  });

  test('首页返回 HTML 但缺少预加载数据时保留解析错误', () async {
    http.body = '<html><title>站点维护</title></html>';
    await expectLater(startup.ensurePreloaded(), throwsFormatException);
    expect(preload.isLoaded, isFalse);
    expect(http.requests, hasLength(1));
    expect(stages, [BrowserTrustPreloadStage.native, null]);
  });

  test('首帧前遇到挑战且自动验证关闭时保留验证错误', () async {
    final cf = CfChallengeService();
    final autoVerify = cf.autoVerifyEnabled;
    cf.autoVerifyEnabled = false;
    addTearDown(() {
      cf.autoVerifyEnabled = autoVerify;
      SystemProxyService.instance.resetForTest();
    });
    http.status = 403;
    http.headers['cf-mitigated'] = ['challenge'];
    await expectLater(
      startup.ensurePreloaded(),
      throwsA(
        isA<DioException>().having(
          (e) => e.error,
          '验证错误',
          isA<CfChallengeException>().having(
            (e) => e.autoVerifyDisabled,
            '自动验证已关闭',
            isTrue,
          ),
        ),
      ),
    );
    expect(http.requests, hasLength(1));
    expect(stages, [BrowserTrustPreloadStage.native, null]);
  });

  for (final persistent in [true, false]) {
    test('${persistent ? '设置开启' : '本次会话启用'}兼容模式时先走浏览器，不可用时回退', () async {
      if (persistent) {
        await settings.setEnabled(true);
        addTearDown(() => settings.setEnabled(false));
      } else {
        settings.enableSessionFallback();
        addTearDown(settings.disableSessionFallback);
      }
      await startup.ensurePreloaded();
      expect(stages, [
        BrowserTrustPreloadStage.webView,
        BrowserTrustPreloadStage.fallback,
        null,
      ]);
      expect(http.requests, hasLength(1));
      expect(preload.isLoaded, isTrue);
    });
  }
}
