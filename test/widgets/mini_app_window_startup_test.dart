import 'dart:async';

import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/main.dart' show MainApp, androidMiniAppWindowMain;
import 'package:fluxdo/modules/mini_apps/mini_app_window_startup.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:m3e_ui/m3e_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('独立窗口向系统提交小程序名称，主题切换后保持身份', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    final titles = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setApplicationSwitcherDescription') {
          titles.add((call.arguments as Map)['label'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MainApp(
          windowTitle: '软块合成',
          windowHome: Scaffold(body: Text('运行内容')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(titles, isNotEmpty);
    expect(titles.toSet(), {'软块合成'});
    container.read(themeProvider.notifier).setThemeMode(ThemeMode.dark);
    await tester.pumpAndSettle();
    expect(titles.toSet(), {'软块合成'});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('启动未完成也绘制加载和关闭入口，完成后交给运行页', (tester) async {
    final initialize = Completer<Widget>();
    var closes = 0;
    await tester.pumpWidget(
      MiniAppWindowStartup(
        initialize: () => initialize.future,
        onClose: () => closes++,
      ),
    );
    expect(find.byType(LoadingSpinner), findsOneWidget);
    expect(find.byType(CloseButton), findsOneWidget);
    await tester.tap(find.byType(CloseButton));
    expect(closes, 1);
    await tester.binding.handlePopRoute();
    expect(closes, 2);
    initialize.complete(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('完整运行页')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('完整运行页'), findsOneWidget);
    expect(find.byType(LoadingSpinner), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首帧前初始化失败可见可重试，重试成功替换错误页', (tester) async {
    var attempts = 0;
    final retry = Completer<Widget>();
    await tester.pumpWidget(
      MiniAppWindowStartup(
        initialize: () {
          attempts++;
          return attempts == 1
              ? Future.error(PlatformException(code: 'BOOTSTRAP_FAILED'))
              : retry.future;
        },
        onClose: () {},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AppEmptyState), findsOneWidget);
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    expect(attempts, 2);
    expect(find.byType(LoadingSpinner), findsOneWidget);
    retry.complete(const MaterialApp(home: Text('已恢复')));
    await tester.pumpAndSettle();
    expect(find.text('已恢复'), findsOneWidget);
    expect(find.byType(AppEmptyState), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android 根入口不等待宿主首个请求；无响应在超时后显示错误', (tester) async {
    const bridge = MethodChannel('com.fluxdo/mini_app_windows');
    final launch = Completer<String?>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(bridge, (
      call,
    ) {
      expect(call.method, 'getLaunch');
      return launch.future;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        bridge,
        null,
      );
    });
    await androidMiniAppWindowMain();
    // 直接运行入口时显式重置测试帧时钟，避免沿用上一测试的动画时间。
    tester.binding.resetEpoch();
    await tester.pump();
    expect(find.byType(LoadingSpinner), findsOneWidget);
    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    expect(find.byType(AppEmptyState), findsOneWidget);
    launch.complete('late-session');
    await tester.pumpAndSettle();
    expect(
      find.byType(AppEmptyState),
      findsOneWidget,
      reason: '迟到的启动响应不能覆盖失败状态',
    );
    expect(tester.takeException(), isNull);
  });
}
