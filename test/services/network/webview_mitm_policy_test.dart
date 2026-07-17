import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/webview_mitm_policy.dart';

void main() {
  group('WebViewMitmPolicy', () {
    test('Windows 高性能模式使用端到端 TLS', () {
      expect(
        WebViewMitmPolicy.useMitmConnect(
          isWindows: true,
          webViewAdapterEnabled: false,
        ),
        isFalse,
      );
      expect(
        WebViewMitmPolicy.requiresTrustedCa(
          isWindows: true,
          dohEnabled: true,
          webViewAdapterEnabled: false,
        ),
        isFalse,
      );
    });

    test('Windows WebView 加 DoH 时使用 MITM 并要求 CA', () {
      expect(
        WebViewMitmPolicy.useMitmConnect(
          isWindows: true,
          webViewAdapterEnabled: true,
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

    test('其他平台保持上游 MITM 策略', () {
      expect(
        WebViewMitmPolicy.useMitmConnect(
          isWindows: false,
          webViewAdapterEnabled: false,
        ),
        isTrue,
      );
      expect(
        WebViewMitmPolicy.requiresTrustedCa(
          isWindows: false,
          dohEnabled: true,
          webViewAdapterEnabled: true,
        ),
        isFalse,
      );
    });
  });
}
