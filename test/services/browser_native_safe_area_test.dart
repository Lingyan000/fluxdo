import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/browser_native_safe_area.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.fluxdo/browser_safe_area');
  final calls = <MethodCall>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('按保活实例安装观察器，不传工具栏状态或固定 Insets', () async {
    expect(await BrowserNativeSafeArea.attach(keepAliveId: 'tab-a'), isTrue);
    expect(calls.single.method, 'attach');
    expect(calls.single.arguments, {'keepAliveId': 'tab-a'});
  });

  test('恢复或全屏切换可刷新同一个原生实例', () async {
    await BrowserNativeSafeArea.attach(keepAliveId: 'tab-b');
    await BrowserNativeSafeArea.attach(keepAliveId: 'tab-b');
    expect(calls.length, 2);
    expect(calls.first.arguments, calls.last.arguments);
  });

  test('其他四个平台不调用 Android 通道', () async {
    for (final platform in [
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(await BrowserNativeSafeArea.attach(keepAliveId: 'tab'), isTrue);
    }
    expect(calls, isEmpty);
  });

  test('实例已销毁时报告同步失败，不中断网页加载流程', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(code: 'WEBVIEW_NOT_FOUND');
        });
    expect(
      await BrowserNativeSafeArea.attach(keepAliveId: 'closed-tab'),
      isFalse,
    );
  });
}
