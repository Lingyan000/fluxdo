import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/log/log_policy.dart';
import 'package:fluxdo/services/log/log_writer.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/services/webview_session_cookie_refresh_service.dart';

import '../support/browser_test_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late BrowserTestPlatform platform;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('session-diagnostics-');
    await LogWriter.initForTesting(directory);
    platform = BrowserTestPlatform();
    InAppWebViewPlatform.instance = platform;
  });
  tearDown(() async {
    WebViewSessionCookieRefreshService.instance.resetPluginCacheForTest();
    await LogWriter.resetForTesting();
    await directory.delete(recursive: true);
  });

  for (final controllerError in [false, true]) {
    test('普通日志导出保留 ${controllerError ? '控制器错误' : '超时'} 阶段', () async {
      if (controllerError) {
        platform.controller.evaluate = (_) =>
            throw StateError('private-page-content');
      }
      final result = await WebViewSessionCookieRefreshService.instance
          .runOnController(
            platform.controller.wrapped,
            reason: 'diagnostics_test',
            timeout: const Duration(milliseconds: 10),
          );
      final phase = controllerError ? 'controller_error' : 'timeout';
      expect(result.ok, isFalse);
      expect(result.phase, phase);
      final exported = LogPolicy.export(await LogWriter.readAllContent());
      expect(exported, isNot(contains('private-page-content')));
      final events = const LineSplitter()
          .convert(exported)
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .where((row) => row['event'] == 'webview_session_bootstrap_result');
      final event = events.single;
      expect(event['phase'], phase);
      expect(event['level'], 'warning');
      expect(event['elapsedMs'], isNonNegative);
      if (!controllerError) expect(event['timeoutMs'], 10);
      if (controllerError) expect(event['errorType'], 'StateError');
    });
  }

  test('脚本返回 not_logged_in 403 且 cfBlocked=false 时不误判为 CF 拦截', () async {
    platform.controller.evaluate = (source) async {
      final match = RegExp(
        r'const handlerName = "([^"]+)";',
      ).firstMatch(source);
      if (match != null) {
        final name = match.group(1)!;
        platform.controller.handlers[name]?.call([
          jsonEncode({
            'ok': false,
            'phase': 'exception',
            'status': 403,
            'cfBlocked': false,
            'contentType': 'application/json; charset=utf-8',
            'error':
                'POST /rky1u -> 403: {"errors":["您需要登录才能执行此操作。"],"error_type":"not_logged_in"}',
          }),
        ]);
      }
      return null;
    };

    final result = await WebViewSessionCookieRefreshService.instance
        .runOnController(
          platform.controller.wrapped,
          reason: 'not_logged_in_test',
        );
    expect(result.ok, isFalse);
    expect(result.cfBlocked, isFalse);
    expect(result.status, 403);

    final exported = LogPolicy.export(await LogWriter.readAllContent());
    final event = const LineSplitter()
        .convert(exported)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .singleWhere((row) => row['event'] == 'webview_session_bootstrap_result');
    expect(event['cfBlocked'], isNull);
    expect(event['status'], 403);
    expect(event['contentType'], 'application/json; charset=utf-8');
  });

  test('插件候选提取优先 data-official=false 非 chunk 主包，再兜底官方与分包', () {
    const html = '''
      <script src="https://cdn3.ldstatic.com/assets/br/plugins/chat_main.aaa.digested.js" data-official="true"></script>
      <script src="https://cdn3.ldstatic.com/assets/br/plugins/discourse-ai_chunk.bbb.digested.js" data-official="false"></script>
      <script src="https://cdn3.ldstatic.com/assets/br/plugins/discourse-qdiyowzg_main.ccc.digested.js" data-official="false"></script>
      <script src="/assets/br/plugins/custom-plain_main.ddd.digested.js"></script>
      <link rel="modulepreload" href="https://cdn3.ldstatic.com/assets/br/plugins/extra_chunk.eee.digested.js">
      <script src="https://cdn3.ldstatic.com/assets/br/plugins/discourse-qdiyowzg_main.ccc.digested.js" data-official="false"></script>
    ''';

    final ordered = extractPluginCandidatesFromHtml(html, 'https://linux.do');
    expect(ordered, [
      'https://cdn3.ldstatic.com/assets/br/plugins/discourse-qdiyowzg_main.ccc.digested.js',
      'https://cdn3.ldstatic.com/assets/br/plugins/chat_main.aaa.digested.js',
      'https://linux.do/assets/br/plugins/custom-plain_main.ddd.digested.js',
      'https://cdn3.ldstatic.com/assets/br/plugins/discourse-ai_chunk.bbb.digested.js',
      'https://cdn3.ldstatic.com/assets/br/plugins/extra_chunk.eee.digested.js',
    ]);
  });

  test('bootstrap 记住上次命中插件 URL、记录分阶段耗时，并在 404 时失效缓存', () async {
    const pluginUrl =
        'https://cdn3.ldstatic.com/assets/br/plugins/discourse-qdiyowzg_main.ccc.digested.js';
    var nextStatus = 200;
    var nextOk = true;
    platform.controller.evaluate = (source) async {
      final match = RegExp(
        r'const handlerName = "([^"]+)";',
      ).firstMatch(source);
      if (match != null) {
        final name = match.group(1)!;
        platform.controller.handlers[name]?.call([
          jsonEncode({
            'ok': nextOk,
            'phase': 'post',
            'plugin': pluginUrl,
            'endpoint': '/rky1u/x6efzro/z22z0kmrovas',
            'status': nextStatus,
            'scannedCount': 1,
            'discoverMs': 12,
            'collectMs': 85,
            'postMs': 44,
          }),
        ]);
      }
      return null;
    };

    final first = await WebViewSessionCookieRefreshService.instance
        .runOnController(
          platform.controller.wrapped,
          reason: 'cache_hit_first',
          pluginCandidates: const [pluginUrl],
        );
    expect(first.ok, isTrue);
    expect(
      WebViewSessionCookieRefreshService.instance.lastMatchedPluginUrlForTest,
      pluginUrl,
    );

    final exported = LogPolicy.export(await LogWriter.readAllContent());
    final firstEvent = const LineSplitter()
        .convert(exported)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .singleWhere((row) => row['event'] == 'webview_session_bootstrap_result');
    expect(firstEvent['scannedCount'], 1);
    expect(firstEvent['discoverMs'], 12);
    expect(firstEvent['collectMs'], 85);
    expect(firstEvent['postMs'], 44);

    // 第二次调用应把上次命中的 URL 注入脚本；若本次 404，应清掉缓存。
    platform.controller.evaluated.clear();
    nextOk = false;
    nextStatus = 404;
    final second = await WebViewSessionCookieRefreshService.instance
        .runOnController(
          platform.controller.wrapped,
          reason: 'cache_404_invalidate',
          pluginCandidates: const [pluginUrl],
        );
    expect(second.ok, isFalse);
    expect(
      platform.controller.evaluated.any(
        (s) => s.contains('window.__fluxdoLastPluginUrl = "$pluginUrl";'),
      ),
      isTrue,
    );
    expect(
      WebViewSessionCookieRefreshService.instance.lastMatchedPluginUrlForTest,
      isNull,
    );
  });
}
