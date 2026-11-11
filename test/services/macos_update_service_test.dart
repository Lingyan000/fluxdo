import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/macos_update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.fluxdo/macos_update');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('passes configured GitHub proxy to Sparkle', () async {
    SharedPreferences.setMockInitialValues({
      'github_proxy_url': 'https://proxy.example/',
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'checkForUpdates');
      expect(call.arguments, {'githubProxy': 'https://proxy.example/'});
      return true;
    });
    expect(await MacOSUpdateService.checkForUpdates(), isTrue);
  });

  test('missing native bridge allows browser fallback', () async {
    expect(await MacOSUpdateService.checkForUpdates(), isFalse);
  });

  test('native startup failure allows browser fallback', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'updater_unavailable');
    });
    expect(await MacOSUpdateService.checkForUpdates(), isFalse);
  });

  test('debug builds can decline an in-place update', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    expect(await MacOSUpdateService.checkForUpdates(), isFalse);
  });

  test('startup reminders respect the version skipped in Sparkle', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'isVersionSkipped');
      return call.arguments == '2.0.0';
    });
    expect(await MacOSUpdateService.isVersionSkipped('2.0.0'), isTrue);
    expect(await MacOSUpdateService.isVersionSkipped('2.0.1'), isFalse);
  });

  test('missing native bridge keeps startup reminders available', () async {
    expect(await MacOSUpdateService.isVersionSkipped('2.0.0'), isFalse);
  });
}
