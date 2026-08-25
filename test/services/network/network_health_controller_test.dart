import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/log/log_writer.dart';
import 'package:fluxdo/services/network/adapters/cronet_fallback_service.dart';
import 'package:fluxdo/services/network/health/network_health_controller.dart';
import 'package:fluxdo/services/network/request_scheduler_config.dart';
import 'package:fluxdo/services/network/webview/webview_adapter_settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// NetworkHealthController 是通道健康的只读投影。
///
/// 它必须满足两条:① 忠实反映各状态源的当前值(不引入第二个真相源);
/// ② 能一条日志导出全貌 —— 用户反馈网络问题时,日志里以前只有"某请求
/// 失败"的结果,没有引擎/降级/盾态/凭证状态,归因只能靠猜。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    WebViewAdapterSettingsService.instance.resetForTest();
    await WebViewAdapterSettingsService.instance.initialize(
      await SharedPreferences.getInstance(),
    );
  });

  group('快照忠实反映状态源', () {
    test('默认状态:未降级、盾通行', () {
      final snapshot = NetworkHealthController.instance.snapshot();

      expect(snapshot.shield, ShieldState.ok);
      expect(snapshot.webViewCompatSession, isFalse);
      expect(snapshot.webViewCompatPersistent, isFalse);
      expect(snapshot.isDegraded, isFalse);
    });

    test('会话级兼容通道开启后，快照与 isDegraded 同步变化', () {
      final webView = WebViewAdapterSettingsService.instance;
      addTearDown(webView.disableSessionFallback);

      webView.enableSessionFallback();
      final snapshot = NetworkHealthController.instance.snapshot();

      expect(snapshot.webViewCompatSession, isTrue);
      expect(snapshot.isDegraded, isTrue);
      expect(snapshot.summary(), contains('compat=session'));
    });

    test('Cronet 强制降级后，快照带出降级标记', () async {
      final cronet = CronetFallbackService.instance;
      await cronet.setForceFallback(true);
      addTearDown(() => cronet.setForceFallback(false));

      final snapshot = NetworkHealthController.instance.snapshot();

      expect(snapshot.cronetFallenBack, isTrue);
      expect(snapshot.cronetForceFallback, isTrue);
      expect(snapshot.isDegraded, isTrue);
      expect(snapshot.summary(), contains('cronet=forced'));
    });

    test('调度器配置变化即时反映（无缓存）', () {
      final before = RequestSchedulerConfig.maxConcurrent;
      addTearDown(() => RequestSchedulerConfig.maxConcurrent = before);

      RequestSchedulerConfig.maxConcurrent = 9;
      expect(NetworkHealthController.instance.snapshot().maxConcurrent, 9);
    });

    test('测试环境无 navigator context → 判定为 headless', () {
      // CF 验证需要前台 UI;后台 isolate/启动早期没有 context,
      // 此时撞盾不该去等一个永不到来的 context。
      final snapshot = NetworkHealthController.instance.snapshot();
      expect(snapshot.hasForegroundUi, isFalse);
      expect(snapshot.summary(), contains('ui=headless'));
    });
  });

  group('dumpToLog', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('net_health_dump');
      await LogWriter.resetForTesting();
      await LogWriter.initForTesting(tempDir);
    });

    tearDown(() async {
      await LogWriter.resetForTesting();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('写出一条带 reason 与结构化字段的 network_health 日志', () async {
      NetworkHealthController.instance.dumpToLog('cf_challenge_detected');
      await LogWriter.instance.flushNow();

      final entries = (await LogWriter.getLogFile())
          .readAsLinesSync()
          .where((line) => line.trim().isNotEmpty)
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .where((e) => e['type'] == 'network_health')
          .toList();

      expect(entries, hasLength(1));
      final entry = entries.single;
      expect(entry['event'], 'network_health_snapshot');
      expect(entry['reason'], 'cf_challenge_detected');
      // 关键诊断字段必须在,否则日志分享出来仍然无法归因
      for (final key in [
        'engine',
        'engineReason',
        'shield',
        'cronetFallenBack',
        'webViewCompatSession',
        'hasCsrfToken',
        'csrfInFailureCooldown',
        'hasForegroundUi',
        'maxConcurrent',
        'isDegraded',
      ]) {
        expect(entry.containsKey(key), isTrue, reason: '缺字段 $key');
      }
      // message 是一行人类可读摘要
      expect(entry['message'], contains('engine='));
      expect(entry['message'], contains('shield='));
    });
  });
}
