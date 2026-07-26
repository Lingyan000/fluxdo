import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/proxy/gateway_upstream.dart';
import 'package:fluxdo/services/network/proxy/proxy_settings_service.dart';

void main() {
  group('GatewayUpstream.resolve', () {
    test('应用代理优先于系统代理', () {
      const applicationProxy = ProxySettings(
        enabled: true,
        protocol: UpstreamProxyProtocol.socks5,
        host: 'app.proxy',
        port: 1080,
        username: 'user',
        password: 'pass',
      );

      final upstream = GatewayUpstream.resolve(
        applicationProxy: applicationProxy,
        systemProxyUrl: 'http://system.proxy:7890',
      );

      expect(upstream?.protocol, 'socks5');
      expect(upstream?.host, 'app.proxy');
      expect(upstream?.port, 1080);
      expect(upstream?.username, 'user');
      expect(upstream?.password, 'pass');
    });

    test('应用代理未启用时回退 HTTP 系统代理', () {
      final upstream = GatewayUpstream.resolve(
        applicationProxy: const ProxySettings(),
        systemProxyUrl: 'http://127.0.0.1:7890',
      );

      expect(upstream?.protocol, 'http');
      expect(upstream?.host, '127.0.0.1');
      expect(upstream?.port, 7890);
    });

    test('应用代理未启用时回退 SOCKS5 系统代理', () {
      final upstream = GatewayUpstream.resolve(
        applicationProxy: const ProxySettings(),
        systemProxyUrl: 'socks5://127.0.0.1:7891',
      );

      expect(upstream?.protocol, 'socks5');
      expect(upstream?.host, '127.0.0.1');
      expect(upstream?.port, 7891);
    });

    test('不支持或缺少系统代理时使用直连', () {
      expect(
        GatewayUpstream.resolve(
          applicationProxy: const ProxySettings(),
          systemProxyUrl: null,
        ),
        isNull,
      );
      expect(
        GatewayUpstream.resolve(
          applicationProxy: const ProxySettings(),
          systemProxyUrl: 'ftp://127.0.0.1:21',
        ),
        isNull,
      );
    });
  });
}
