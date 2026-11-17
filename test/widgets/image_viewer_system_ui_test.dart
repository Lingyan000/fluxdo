import 'dart:convert';

import 'package:app_icons/app_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/pages/image_viewer_page.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/layout/immersive_insets_hold.dart';

void main() {
  final imageBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=',
  );
  late GlobalKey<NavigatorState> navigator;
  late List<MethodCall> systemUiCalls;

  Future<void> openViewer(WidgetTester tester) async {
    PlatformUtils.debugDesktopOverride = false;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 34);
    addTearDown(tester.view.reset);

    systemUiCalls = [];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setEnabledSystemUIMode' ||
            call.method == 'SystemChrome.setEnabledSystemUIOverlays') {
          systemUiCalls.add(call);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    navigator = GlobalKey<NavigatorState>();
    late BuildContext homeContext;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          navigatorKey: navigator,
          builder: (context, child) => ImmersiveInsetsHoldScope(child: child!),
          home: Builder(
            builder: (context) {
              homeContext = context;
              return const Scaffold();
            },
          ),
        ),
      ),
    );
    ImageViewerPage.openBytes(homeContext, imageBytes);
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsOneWidget);
    expect(systemUiCalls, isEmpty);
  }

  Future<void> toggleControls(WidgetTester tester) async {
    await tester.tapAt(const Offset(200, 400));
    // 等待图片手势层区分单击与双击。
    await tester.pumpAndSettle(const Duration(milliseconds: 350));
  }

  void expectSingleRestore() {
    expect(systemUiCalls.map((call) => [call.method, call.arguments]), [
      ['SystemChrome.setEnabledSystemUIMode', 'SystemUiMode.immersiveSticky'],
      [
        'SystemChrome.setEnabledSystemUIOverlays',
        ['SystemUiOverlay.top', 'SystemUiOverlay.bottom'],
      ],
      ['SystemChrome.setEnabledSystemUIMode', 'SystemUiMode.edgeToEdge'],
    ]);
  }

  testWidgets('普通查看后点关闭，不重新切换系统栏模式', (tester) async {
    await openViewer(tester);
    await tester.tap(find.byIcon(Symbols.close_rounded));
    await tester.pumpAndSettle();

    expect(find.byType(ImageViewerPage), findsNothing);
    expect(systemUiCalls, isEmpty, reason: '未隐藏过系统栏，退场不能触发安全区变化');
  });

  testWidgets('普通查看后返回，不重新切换系统栏模式', (tester) async {
    await openViewer(tester);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();

    expect(find.byType(ImageViewerPage), findsNothing);
    expect(systemUiCalls, isEmpty);
  });

  testWidgets('沉浸状态退出在退场起点恢复，销毁时不重复恢复', (tester) async {
    await openViewer(tester);
    await toggleControls(tester);
    expect(systemUiCalls.single.arguments, 'SystemUiMode.immersiveSticky');

    navigator.currentState!.pop();
    await tester.pump();
    expect(find.byType(ImageViewerPage), findsOneWidget);
    expectSingleRestore();

    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);
    expectSingleRestore();
  });

  testWidgets('手动显示系统栏后关闭，不再次恢复', (tester) async {
    await openViewer(tester);
    await toggleControls(tester);
    await toggleControls(tester);
    expectSingleRestore();

    await tester.tap(find.byIcon(Symbols.close_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);
    expectSingleRestore();
  });
}
