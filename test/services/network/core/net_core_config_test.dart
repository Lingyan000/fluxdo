import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/core/net_core_service.dart';

void main() {
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
  });
}
