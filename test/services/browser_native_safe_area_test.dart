import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
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

  test('上下工具栏承担安全区时，指定实例的四边均归零', () async {
    expect(
      await BrowserNativeSafeArea.apply(
        keepAliveId: 'tab-a',
        unsafe: EdgeInsets.zero,
        edgeToEdge: true,
      ),
      isTrue,
    );
    expect(calls.single.method, 'setHandledEdges');
    expect(calls.single.arguments, {
      'keepAliveId': 'tab-a',
      'left': true,
      'top': true,
      'right': true,
      'bottom': true,
    });
  });

  test('横屏 cover 保留网页需承担的侧边安全区，回退留边后全部归零', () async {
    const unsafe = EdgeInsets.fromLTRB(47, 0, 47, 0);
    await BrowserNativeSafeArea.apply(
      keepAliveId: 'tab-b',
      unsafe: unsafe,
      edgeToEdge: true,
    );
    expect(calls.last.arguments, {
      'keepAliveId': 'tab-b',
      'left': false,
      'top': true,
      'right': false,
      'bottom': true,
    });
    await BrowserNativeSafeArea.apply(
      keepAliveId: 'tab-b',
      unsafe: unsafe,
      edgeToEdge: false,
    );
    expect((calls.last.arguments as Map)['left'], isTrue);
    expect((calls.last.arguments as Map)['right'], isTrue);
  });

  test('网页延伸到底部时保留底部安全区', () async {
    await BrowserNativeSafeArea.apply(
      keepAliveId: 'tab-c',
      unsafe: const EdgeInsets.only(bottom: 24),
      edgeToEdge: true,
    );
    expect((calls.single.arguments as Map)['bottom'], isFalse);
  });

  test('其他四个平台不调用 Android 通道', () async {
    for (final platform in [
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(
        await BrowserNativeSafeArea.apply(
          keepAliveId: 'tab',
          unsafe: EdgeInsets.zero,
          edgeToEdge: true,
        ),
        isTrue,
      );
    }
    expect(calls, isEmpty);
  });

  test('实例已销毁时报告同步失败，不中断网页加载流程', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(code: 'WEBVIEW_NOT_FOUND');
        });
    expect(
      await BrowserNativeSafeArea.apply(
        keepAliveId: 'closed-tab',
        unsafe: EdgeInsets.zero,
        edgeToEdge: true,
      ),
      isFalse,
    );
  });
}
