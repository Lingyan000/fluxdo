import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/windows_webview_environment_service.dart';

void main() {
  group('WindowsWebViewEnvironmentService', () {
    test('只解析本机 HTTP 代理端口', () {
      expect(
        WindowsWebViewEnvironmentService.parseLocalProxyPort(
          'http://127.0.0.1:7890',
        ),
        7890,
      );
      expect(
        WindowsWebViewEnvironmentService.parseLocalProxyPort(
          'http://localhost:7891',
        ),
        7891,
      );
      expect(
        WindowsWebViewEnvironmentService.parseLocalProxyPort(
          'http://[::1]:7892',
        ),
        7892,
      );
      expect(
        WindowsWebViewEnvironmentService.parseLocalProxyPort(
          'http://proxy.example:7890',
        ),
        isNull,
      );
      expect(
        WindowsWebViewEnvironmentService.parseLocalProxyPort(
          'socks5://127.0.0.1:7890',
        ),
        isNull,
      );
    });

    test('代理清理延后且端口仍匹配时保留本地代理', () {
      expect(
        WindowsWebViewEnvironmentService.shouldRetainLocalProxy(
          clearApplied: false,
          activeEnvironmentPort: 7890,
          runningProxyPort: 7890,
        ),
        isTrue,
      );
      expect(
        WindowsWebViewEnvironmentService.shouldRetainLocalProxy(
          clearApplied: true,
          activeEnvironmentPort: 7890,
          runningProxyPort: 7890,
        ),
        isFalse,
      );
      expect(
        WindowsWebViewEnvironmentService.shouldRetainLocalProxy(
          clearApplied: false,
          activeEnvironmentPort: 7890,
          runningProxyPort: 7891,
        ),
        isFalse,
      );
    });
  });
}
