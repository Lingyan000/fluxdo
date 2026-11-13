import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_ui/m3e_ui.dart';

void main() {
  for (final decorated in [false, true]) {
    testWidgets('普通刷新默认使用 M3E 进度并衔接加载图案 decorated=$decorated', (tester) async {
      final completion = Completer<void>();
      var refreshes = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: const [M3eFlags(enabled: true)]),
          home: UiDecor(
            loadingIndicator: decorated ? _testLoadingDecoration : null,
            child: Scaffold(
              body: M3eRefreshIndicator(
                onRefresh: () {
                  refreshes++;
                  return completion.future;
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: ClampingScrollPhysics(),
                  ),
                  children: const [SizedBox(height: 1200)],
                ),
              ),
            ),
          ),
        ),
      );
      final drag = await tester.startGesture(const Offset(200, 150));
      await drag.moveBy(const Offset(0, 20));
      await tester.pump();
      await drag.moveBy(const Offset(0, 50));
      await tester.pump();
      expect(_pullProgress(tester), inExclusiveRange(0, 1));
      expect(find.byType(LoadingSpinner), findsNothing);
      expect(
        find.byKey(const ValueKey('test-loading-decoration')),
        findsNothing,
      );
      final progress = tester.widget<M3eCircularProgress>(
        find.byType(M3eCircularProgress),
      );
      expect(progress.size, 26);
      await drag.moveBy(const Offset(0, 60));
      await tester.pump();
      expect(_pullProgress(tester), 1);
      expect(
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
        1.12,
      );
      await drag.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(refreshes, 1);
      expect(find.byType(M3eCircularProgress), findsNothing);
      expect(
        decorated
            ? find.byKey(const ValueKey('test-loading-decoration'))
            : find.byType(LoadingSpinner),
        findsOneWidget,
      );
      completion.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final height in [600.0, 1200.0]) {
    for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.trackpad]) {
      testWidgets('固定触发距离不随窗口高度增加 $height $kind', (tester) async {
        tester.view.physicalSize = Size(800, height);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final completion = Completer<void>();
        var refreshes = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.macOS),
            home: Scaffold(
              body: M3eRefreshIndicator(
                triggerDistance: 96,
                onPullExtentChanged: (_) {},
                onRefresh: () {
                  refreshes++;
                  return completion.future;
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: ClampingScrollPhysics(),
                  ),
                  children: const [SizedBox(height: 1800)],
                ),
              ),
            ),
          ),
        );
        final drag = await tester.startGesture(
          const Offset(200, 150),
          kind: kind,
        );
        await drag.moveBy(const Offset(0, 20));
        await tester.pump();
        await drag.moveBy(const Offset(0, 50));
        await tester.pump();
        expect(_pullProgress(tester), inExclusiveRange(0, 1));
        expect(refreshes, 0);
        await drag.moveBy(const Offset(0, 50));
        await tester.pump();
        expect(_pullProgress(tester), 1);
        expect(refreshes, 0);
        await drag.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(refreshes, 1);
        completion.complete();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final expressive in [true, false]) {
    testWidgets('达到提示阈值后松手立即刷新，M3E=$expressive', (tester) async {
      final completion = Completer<void>();
      var refreshes = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: [M3eFlags(enabled: expressive)]),
          home: Scaffold(
            body: M3eRefreshIndicator(
              onPullExtentChanged: (_) {},
              onRefresh: () {
                refreshes++;
                return completion.future;
              },
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: ClampingScrollPhysics(),
                ),
                children: const [SizedBox(height: 1200)],
              ),
            ),
          ),
        ),
      );
      final drag = await tester.startGesture(const Offset(200, 150));
      await drag.moveBy(const Offset(0, 20));
      await tester.pump();
      await drag.moveBy(const Offset(0, 50));
      await tester.pump();
      expect(_pullProgress(tester), inExclusiveRange(0, 1));
      expect(refreshes, 0);
      // 600 高视口的触发距离为 100，覆盖旧逻辑错误取消的 100～150 区间。
      await drag.moveBy(const Offset(0, 60));
      await tester.pump();
      expect(_pullProgress(tester), 1);
      expect(refreshes, 0);
      await drag.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(refreshes, 1);
      expect(find.byType(M3eCircularProgress), findsNothing);
      expect(find.byType(LoadingSpinner), findsOneWidget);
      completion.complete();
      await tester.pump();
      await tester.pump();
      expect(find.byType(LoadingSpinner), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byType(LoadingSpinner), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final mode in RefreshIndicatorTriggerMode.values) {
    for (final variant in [
      (expressive: true, stretch: false),
      (expressive: false, stretch: false),
      (expressive: false, stretch: true),
    ]) {
      testWidgets('连续滚动到顶部后按触发模式刷新 $mode $variant', (tester) async {
        final controller = ScrollController(initialScrollOffset: 100);
        addTearDown(controller.dispose);
        final completion = Completer<void>();
        var refreshes = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              extensions: [M3eFlags(enabled: variant.expressive)],
            ),
            home: Scaffold(
              body: M3eRefreshIndicator(
                triggerMode: mode,
                onPullExtentChanged: variant.stretch ? (_) {} : null,
                onRefresh: () {
                  refreshes++;
                  return completion.future;
                },
                child: ListView(
                  controller: controller,
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: ClampingScrollPhysics(),
                  ),
                  children: const [SizedBox(height: 1800)],
                ),
              ),
            ),
          ),
        );
        final drag = await tester.startGesture(const Offset(200, 200));
        await drag.moveBy(const Offset(0, 20));
        await tester.pump();
        await drag.moveBy(const Offset(0, 120));
        await tester.pump();
        expect(controller.offset, 0);
        expect(refreshes, 0);
        await drag.moveBy(const Offset(0, 250));
        await tester.pump();
        await drag.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        final expected = mode == RefreshIndicatorTriggerMode.anywhere ? 1 : 0;
        expect(refreshes, expected);

        await tester.dragFrom(const Offset(200, 400), const Offset(0, -150));
        await tester.pump(const Duration(milliseconds: 200));
        expect(controller.offset, greaterThan(0));
        expect(refreshes, expected);
        completion.complete();
        await tester.pumpAndSettle();
        controller.jumpTo(0);
        await tester.pumpAndSettle();
        expect(refreshes, expected);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final expressive in [true, false]) {
    testWidgets('拉伸进度覆盖取消、刷新等待和回弹，M3E=$expressive', (tester) async {
      final extents = <double>[];
      final completion = Completer<void>();
      var refreshes = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: [M3eFlags(enabled: expressive)]),
          home: Scaffold(
            body: M3eRefreshIndicator(
              onPullExtentChanged: extents.add,
              onRefresh: () {
                refreshes++;
                return completion.future;
              },
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [SizedBox(height: 1000)],
              ),
            ),
          ),
        ),
      );
      final listElement = tester.element(find.byType(ListView));
      await tester.drag(find.byType(ListView), const Offset(0, 60));
      await tester.pumpAndSettle();
      expect(refreshes, 0);
      expect(extents.any((extent) => extent > 0), isTrue);
      expect(extents.last, 0);
      extents.clear();

      await tester.drag(find.byType(ListView), const Offset(0, 400));
      await tester.pump();
      expect(extents.any((extent) => extent > 60), isTrue);
      await tester.pump(const Duration(milliseconds: 200));
      expect(refreshes, 1);
      expect(extents.last, greaterThan(0));
      completion.complete();
      await tester.pumpAndSettle();
      expect(extents.last, 0);
      expect(tester.element(find.byType(ListView)), same(listElement));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('顶部拖动不重建列表子树(树形状稳定)', (tester) async {
    final controller = ScrollController();
    final listKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: M3eRefreshIndicator(
            onRefresh: () async {},
            child: ListView.builder(
              key: listKey,
              controller: controller,
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: 100,
              itemBuilder: (_, i) => SizedBox(height: 40, child: Text('$i')),
            ),
          ),
        ),
      ),
    );
    final elementBefore = listKey.currentContext!;

    // 在顶部轻拖(触发 drag 状态翻转)再松手取消。
    await tester.drag(find.byType(ListView), const Offset(0, 30));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 树形状稳定:同一个 Element,列表未被拆掉重建。
    expect(listKey.currentContext, same(elementBefore));

    // 先滚下去,再在中途来回拖,位置不能被重置。
    controller.jumpTo(400);
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -50));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(controller.offset, greaterThan(300));
    expect(listKey.currentContext, same(elementBefore));
  });

  testWidgets('完整下拉刷新流程', (tester) async {
    var refreshed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: M3eRefreshIndicator(
            onRefresh: () async => refreshed++,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                for (var i = 0; i < 20; i++)
                  SizedBox(height: 40, child: Text('$i')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200)); // snap
    await tester.pump(const Duration(seconds: 1)); // refresh 完成
    await tester.pumpAndSettle();
    expect(refreshed, 1);
    expect(tester.takeException(), isNull);
  });
}

double _pullProgress(WidgetTester tester) => tester
    .widget<M3eCircularProgress>(
      find.byKey(const ValueKey('refresh-pull-progress')),
    )
    .value!;

Widget _testLoadingDecoration(BuildContext context, double size) =>
    SizedBox.square(
      key: const ValueKey('test-loading-decoration'),
      dimension: size,
    );
