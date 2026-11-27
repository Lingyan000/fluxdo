import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/network_settings_service.dart';

void main() {
  group('NetworkSettingsService.buildSiteTunnelProxySettings', () {
    test('Android 生成反选代理白名单且移除隐式 localhost 规则', () {
      final settings = NetworkSettingsService.buildSiteTunnelProxySettings(
        port: 43210,
        baseHost: 'Linux.DO',
        isAndroid: true,
      );

      expect(settings.reverseBypassEnabled, isTrue);
      expect(settings.removeImplicitRules, isTrue);
      expect(settings.bypassRules, equals(['linux.do', '*.linux.do']));
      expect(settings.proxyRules, hasLength(1));
      expect(settings.proxyRules.single.url, 'http://127.0.0.1:43210');
      expect(
        settings.proxyRules.single.schemeFilter,
        ProxySchemeFilter.MATCH_HTTPS,
      );
    });

    test('iOS/macOS 仅对主站域名启用 matchDomains 代理规则', () {
      final settings = NetworkSettingsService.buildSiteTunnelProxySettings(
        port: 43210,
        baseHost: 'Linux.DO',
        isAndroid: false,
      );

      expect(settings.reverseBypassEnabled, isFalse);
      expect(settings.removeImplicitRules, isNull);
      expect(settings.bypassRules, isEmpty);
      expect(settings.proxyRules, hasLength(1));
      expect(settings.proxyRules.single.url, 'http://127.0.0.1:43210');
      expect(settings.proxyRules.single.matchDomains, equals(['linux.do']));
    });
  });

  group('NetworkSettingsService.resolveMutualExclusiveProtocol', () {
    test('开启主站协议对齐时自动关闭无模板强制 HTTP/3', () {
      final resolved = NetworkSettingsService.resolveMutualExclusiveProtocol(
        currentSiteTunnel: false,
        currentAllowUncalibratedHttp3: true,
        nextSiteTunnel: true,
      );
      expect(resolved.siteTunnel, isTrue);
      expect(resolved.allowUncalibratedHttp3, isFalse);
    });

    test('开启无模板强制 HTTP/3 时自动关闭主站协议对齐', () {
      final resolved = NetworkSettingsService.resolveMutualExclusiveProtocol(
        currentSiteTunnel: true,
        currentAllowUncalibratedHttp3: false,
        nextAllowUncalibratedHttp3: true,
      );
      expect(resolved.siteTunnel, isFalse);
      expect(resolved.allowUncalibratedHttp3, isTrue);
    });

    test('历史异常同时开启时防御性归一为主站协议对齐优先', () {
      final resolved = NetworkSettingsService.resolveMutualExclusiveProtocol(
        currentSiteTunnel: true,
        currentAllowUncalibratedHttp3: true,
      );
      expect(resolved.siteTunnel, isTrue);
      expect(resolved.allowUncalibratedHttp3, isFalse);
    });
  });
}
