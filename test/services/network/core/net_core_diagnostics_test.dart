import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/core/net_core_diagnostics.dart';

void main() {
  test('每次导出读取新状态，不复用先前 H3 结果', () {
    var sampled = false;
    var reads = 0;
    String read() {
      reads++;
      return jsonEncode({
        'running': true,
        'system_proxy': false,
        'template_mode': 'auto',
        'template_diagnostics': {
          'h3': {'enabled_for_template': sampled},
        },
      });
    }

    final before = NetCoreDiagnosticSnapshot.capture(read);
    sampled = true;
    final after = NetCoreDiagnosticSnapshot.capture(read);
    expect(reads, 2);
    expect(
      before.toLogFields(appProxyEnabled: false)['h3CalibrationState'],
      'notReady',
    );
    final fields = after.toLogFields(appProxyEnabled: false);
    expect(fields['coreStatusRead'], 'live');
    expect(fields['h3CalibrationState'], 'sampled');
    expect(fields['proxySource'], 'direct');
    expect(fields['effectiveProxyEnabled'], false);
    expect(fields['templateMode'], 'auto');
  });

  final failures = <String, String? Function()>{
    'status_unavailable': () => null,
    'status_read_failed': () => throw StateError('FFI unavailable'),
    'status_invalid': () => '{broken',
  };
  for (final entry in failures.entries) {
    test('${entry.key} 不伪造未就绪、直连或已停止', () {
      final snapshot = NetCoreDiagnosticSnapshot.capture(entry.value);
      final fields = snapshot.toLogFields(appProxyEnabled: false);
      expect(fields['coreStatusRead'], entry.key);
      expect(fields['coreRunning'], isNull);
      expect(fields['templateDiagnostics'], isNull);
      expect(fields['templateMode'], isNull);
      expect(fields['h3CalibrationState'], 'unknown');
      expect(fields['h3CalibrationReason'], 'status_unavailable');
      expect(fields['systemProxyEnabled'], isNull);
      expect(fields['effectiveProxyEnabled'], isNull);
      expect(fields['proxySource'], 'unknown');
      final appProxy = snapshot.toLogFields(appProxyEnabled: true);
      expect(appProxy['effectiveProxyEnabled'], true);
      expect(appProxy['proxySource'], 'app');
    });
  }

  test('非法根状态和旧核心缺失字段保持未知', () {
    for (final raw in ['[]', 'null', '{}', '{"running":"true"}']) {
      expect(
        NetCoreDiagnosticSnapshot.capture(() => raw).readStatus,
        'status_invalid',
      );
    }
    final old = NetCoreDiagnosticSnapshot.capture(() => '{"running":true}')
        .toLogFields(appProxyEnabled: false);
    expect(old['coreStatusRead'], 'live');
    expect(old['coreRunning'], true);
    expect(old['templateMode'], isNull);
    expect(old['h3CalibrationState'], 'unknown');
    expect(old['proxySource'], 'unknown');
  });

  test('真实系统代理与停止状态按原生结果导出', () {
    final fields = NetCoreDiagnosticSnapshot.capture(
      () => '{"running":false,"system_proxy":true}',
    ).toLogFields(appProxyEnabled: false);
    expect(fields['coreRunning'], false);
    expect(fields['proxySource'], 'system');
    expect(fields['effectiveProxyEnabled'], true);
  });
}
