import 'package:fluxdo/services/network/webview/webview_adapter_settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('WebViewAdapterSettingsService 会话兼容模式', () {
    late SharedPreferences prefs;
    late WebViewAdapterSettingsService service;

    setUp(() async {
      service = WebViewAdapterSettingsService.instance;
      service.resetForTest();
      SharedPreferences.setMockInitialValues({
        'webview_adapter_enabled': false,
      });
      prefs = await SharedPreferences.getInstance();
      await service.initialize(prefs);
    });

    tearDown(() {
      service.resetForTest();
    });

    test('临时启用只改变会话状态，不修改持久化设置', () {
      service.enableSessionFallback();

      expect(service.enabled, false);
      expect(service.persistentEnabled, false);
      expect(service.sessionFallbackEnabled, true);
      expect(service.effectiveEnabled, true);
      expect(prefs.getBool('webview_adapter_enabled'), false);
    });

    test('退出临时兼容后恢复持久化设置决定的有效状态', () async {
      await service.setEnabled(true);
      service.enableSessionFallback();
      service.disableSessionFallback();

      expect(service.enabled, true);
      expect(service.sessionFallbackEnabled, false);
      expect(service.effectiveEnabled, true);
      expect(prefs.getBool('webview_adapter_enabled'), true);
    });

    test('重置会话状态不会关闭用户持久化兼容模式', () async {
      await service.setEnabled(true);
      service.enableSessionFallback();
      service.resetSessionFallback();

      expect(service.persistentEnabled, true);
      expect(service.sessionFallbackEnabled, false);
      expect(service.effectiveEnabled, true);
    });

    test('effectiveNotifier 仅跟随实际分流状态', () async {
      var notifications = 0;
      void listener() => notifications++;
      service.effectiveNotifier.addListener(listener);
      addTearDown(() => service.effectiveNotifier.removeListener(listener));

      service.enableSessionFallback();
      await service.setEnabled(true);
      service.disableSessionFallback();
      await service.setEnabled(false);

      expect(notifications, 2);
      expect(service.effectiveEnabled, false);
    });

    test('临时兼容仍排除 MessageBus 与非主站请求', () {
      service.enableSessionFallback();

      expect(
        service.shouldUseWebView(Uri.parse('https://linux.do/latest.json')),
        true,
      );
      expect(
        service.shouldUseWebView(
          Uri.parse('https://linux.do/message-bus/abc/poll'),
        ),
        false,
      );
      expect(
        service.shouldUseWebView(Uri.parse('https://cdn.linux.do/image.png')),
        false,
      );
    });
  });
}
