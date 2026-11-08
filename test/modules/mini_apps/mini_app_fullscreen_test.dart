import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_fullscreen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final locked in [false, true]) {
    test(
      'rotation and fullscreen restore the community preference ($locked)',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final calls = <MethodCall>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          calls.add(call);
          return null;
        });
        addTearDown(() {
          debugDefaultTargetPlatformOverride = null;
          messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        });
        final display = MiniAppFullscreen(
          restoreOrientations: () => locked
              ? [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]
              : [],
        );
        // 不等待进入完成便旋转、关闭，最后的状态仍必须回到社区设置。
        final pending = [
          display.setOrientation(MiniAppOrientation.landscape),
          display.setFullscreen(true),
          display.setOrientation(MiniAppOrientation.portrait),
          display.setOrientation(MiniAppOrientation.system),
          display.restore(),
        ];
        await Future.wait(pending);
        final orientations = calls.where(
          (c) => c.method == 'SystemChrome.setPreferredOrientations',
        );
        expect(orientations.map((c) => c.arguments), [
          [
            'DeviceOrientation.landscapeLeft',
            'DeviceOrientation.landscapeRight',
          ],
          ['DeviceOrientation.portraitUp'],
          <String>[],
          if (locked)
            ['DeviceOrientation.portraitUp', 'DeviceOrientation.portraitDown']
          else
            <String>[],
        ]);
        expect(calls[calls.length - 2].arguments, 'SystemUiMode.edgeToEdge');
        final count = calls.length;
        await display.setFullscreen(true);
        await display.setOrientation(MiniAppOrientation.landscape);
        await display.restore();
        expect(calls.length, count, reason: '已关闭页面不能重新抢占系统方向或全屏');
      },
    );
  }
  test(
    'closing during fullscreen entry restores both system bars in order',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });
      final fullscreen = MiniAppFullscreen();
      final enter = fullscreen.setFullscreen(true);
      final exit = fullscreen.setFullscreen(false);
      await Future.wait([enter, exit]);
      expect(calls.map((e) => e.method), [
        'SystemChrome.setEnabledSystemUIMode',
        'SystemChrome.setEnabledSystemUIOverlays',
        'SystemChrome.setEnabledSystemUIMode',
      ]);
      expect(calls.first.arguments, 'SystemUiMode.immersiveSticky');
      expect(calls[1].arguments, [
        'SystemUiOverlay.top',
        'SystemUiOverlay.bottom',
      ]);
      expect(calls.last.arguments, 'SystemUiMode.edgeToEdge');
    },
  );
}
