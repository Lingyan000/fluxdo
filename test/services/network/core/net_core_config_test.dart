import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/core/net_core_service.dart';
import 'package:fluxdo/services/network/proxy/proxy_settings_service.dart';

void main() {
  test('日志摘要不暴露 DoH 与代理配置，实际网络配置仍完整', () {
    const config = NetCoreConfig(
      enableDoh: true,
      dohServer: 'https://resolver.example/path-secret',
      upstreamProxy: ProxySettings(enabled: true, host: 'private-proxy.example', port: 7890),
      systemProxy: NetCoreProxy(host: 'private-system.example', port: 8080),
    );
    final description = config.describe();
    expect(description, contains('DoH 开'));
    expect(description, contains('应用代理 http'));
    expect(description, contains('系统代理 开'));
    expect(description, isNot(contains('.example')));
    expect(description, isNot(contains('path-secret')));
    expect(config.toJson()['doh_server'], config.dohServer);
    expect((config.toJson()['upstream_proxy'] as Map)['host'], 'private-proxy.example');
  });

  test('配置复制保留实际 UA 并传递平台身份', () {
    const config = NetCoreConfig(
      fingerprintUserAgent: 'actual WebView UA',
      fingerprintPreset: 'android-chrome149',
      http3CachePath: '/app/cache/http3_services.json',
    );
    final copied = config.copyWith(
      systemProxy: const NetCoreProxy(host: 'localhost', port: 7890),
    );
    expect(copied.toJson()['fingerprint_user_agent'], 'actual WebView UA');
    expect(copied.toJson()['fingerprint_platform'], Platform.operatingSystem);
    expect(
      jsonDecode(copied.toJson()['fingerprint_runtime_identity'] as String),
      [Platform.operatingSystem, Platform.operatingSystemVersion],
    );
    expect(copied.toJson()['fingerprint_preset'], 'android-chrome149');
    expect(
      copied.toJson()['http3_cache_path'],
      '/app/cache/http3_services.json',
    );
    expect(
      const NetCoreConfig().toJson().containsKey('fingerprint_preset'),
      false,
    );
  });
  test('预置可用与真实采样就绪分别表达，旧核心状态仍能读取', () {
    final preset = NetCoreStatus.fromJson({
      'running': true,
      'template_ready': false,
      'template_source': 'builtin',
      'template_preset': 'android-webview133',
    });
    expect(preset.templateReady, false);
    expect(preset.templateSource, 'builtin');
    expect(preset.templatePreset, 'android-webview133');
    expect(NetCoreStatus.fromJson({'running': true}).templateSource, isNull);
    expect(NetCoreStatus.fromJson({'running': true}).templateDiagnostics, isEmpty);
    final status = NetCoreStatus.fromJson({
      'running': true,
      'template_diagnostics': {
        'cache_state': 'runtime_changed',
        'h3': {'enabled_for_template': false},
        'tls_capabilities': {'status': 'backend_mismatch'},
      },
    });
    expect(status.templateDiagnostics['cache_state'], 'runtime_changed');
    expect(() => status.templateDiagnostics['extra'] = true, throwsUnsupportedError);
  });
}
