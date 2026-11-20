import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/log/log_policy.dart';
import 'package:fluxdo/services/log/log_writer.dart';
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
}
