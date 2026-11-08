import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// 直接验证 Windows 纹理控件的输入/布局链路，不以模拟 WebView 代替。
// 根项目通过 dependency_overrides 引用这份 Windows 实现。
// ignore: depend_on_referenced_packages
import 'package:flutter_inappwebview_windows/src/in_app_webview/custom_platform_view.dart';

void main() {
  testWidgets('点击和重建不重复重设纹理尺寸，布局与 DPI 改变仍更新', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    const manager = MethodChannel(
      'com.pichillilorenzo/flutter_inappwebview_manager',
    );
    const surface = MethodChannel(
      'com.pichillilorenzo/custom_platform_view_42',
    );
    const events = MethodChannel(
      'com.pichillilorenzo/custom_platform_view_42_events',
    );
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(
      manager,
      (call) async => call.method == 'createInAppWebView' ? 42 : null,
    );
    messenger.setMockMethodCallHandler(surface, (call) async {
      calls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(manager, null);
      messenger.setMockMethodCallHandler(surface, null);
      messenger.setMockMethodCallHandler(events, null);
    });
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<void> scene({double width = 320, double? scale}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: 240,
              child: CustomPlatformView(scaleFactor: scale),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    List<MethodCall> sizes() =>
        calls.where((c) => c.method == 'setSize').toList();
    await scene();
    expect(sizes(), hasLength(1));
    expect(sizes().single.arguments, [320.0, 240.0, 1.0]);
    for (var i = 0; i < 4; i++) {
      await tester.tapAt(const Offset(60, 100), kind: PointerDeviceKind.mouse);
      await scene();
    }
    expect(
      calls.where((c) => c.method == 'setPointerButton').length,
      greaterThan(0),
    );
    expect(sizes(), hasLength(1), reason: '点击不能重建原生帧池');
    await scene(width: 420);
    expect(sizes(), hasLength(2));
    expect(sizes().last.arguments, [420.0, 240.0, 1.0]);
    tester.view.devicePixelRatio = 1.5;
    await tester.pump();
    await tester.pump();
    expect(sizes(), hasLength(3));
    expect(sizes().last.arguments, [420.0, 240.0, 1.5]);
    await scene(width: 420, scale: 2);
    expect(sizes(), hasLength(4));
    expect(sizes().last.arguments, [420.0, 240.0, 2.0]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
