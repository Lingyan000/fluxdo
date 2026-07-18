import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/webview_mitm_policy.dart';

void main() {
  group('WebViewMitmPolicy', () {
    test('CONNECT 始终 MITM 解密(与上游一致,SNI 阻断防护依赖出口改写)', () {
      expect(
        WebViewMitmPolicy.useMitmConnect(
          isWindows: true,
          webViewAdapterEnabled: false,
        ),
        isTrue,
      );
      expect(
        WebViewMitmPolicy.useMitmConnect(
          isWindows: false,
          webViewAdapterEnabled: false,
        ),
        isTrue,
      );
    });

    test('Windows 启用 DoH 即要求 CA,与网络引擎选择无关', () {
      expect(
        WebViewMitmPolicy.requiresTrustedCa(
          isWindows: true,
          dohEnabled: true,
          webViewAdapterEnabled: false,
        ),
        isTrue,
      );
      expect(
        WebViewMitmPolicy.requiresTrustedCa(
          isWindows: true,
          dohEnabled: true,
          webViewAdapterEnabled: true,
        ),
        isTrue,
      );
    });

    test('Windows 未开启 DoH 时不要求 CA', () {
      expect(
        WebViewMitmPolicy.requiresTrustedCa(
          isWindows: true,
          dohEnabled: false,
          webViewAdapterEnabled: true,
        ),
        isFalse,
      );
    });

    test('网关模式只由 DoH 与网关开关决定', () {
      expect(
        WebViewMitmPolicy.useGatewayMode(
          isWindows: true,
          dohEnabled: true,
          gatewayEnabled: false,
          webViewAdapterEnabled: false,
        ),
        isFalse,
      );
      expect(
        WebViewMitmPolicy.useGatewayMode(
          isWindows: true,
          dohEnabled: true,
          gatewayEnabled: true,
          webViewAdapterEnabled: false,
        ),
        isTrue,
      );
      expect(
        WebViewMitmPolicy.useGatewayMode(
          isWindows: true,
          dohEnabled: false,
          gatewayEnabled: true,
          webViewAdapterEnabled: true,
        ),
        isFalse,
      );
    });
  });
}
