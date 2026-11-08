import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/modules/mini_apps/home_mini_apps_layer.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_refresh_logo.dart';
import 'package:m3e_ui/m3e_ui.dart';

void main() {
  testWidgets('关闭下拉开关结束旧会话，恢复普通刷新且可再次开启', (tester) async {
    final enabled = ValueNotifier(true);
    final layer = GlobalKey<HomeMiniAppsLayerState>();
    final refresh = GlobalKey<M3eRefreshIndicatorState>();
    final list = GlobalKey();
    var refreshes = 0;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (context, active, _) => HomeMiniAppsLayer(
              key: layer,
              enabled: active,
              gallery: const Text('真实广场'),
              child: Scaffold(
                body: M3eRefreshIndicator(
                  key: refresh,
                  externalReveal: active,
                  revealOffset: active
                      ? () => layer.currentState!.offset
                      : null,
                  onSecondaryAction: active
                      ? () => layer.currentState!.open()
                      : null,
                  onRefresh: () async => refreshes++,
                  child: ListView(
                    key: list,
                    physics: active
                        ? RefreshRevealScrollPhysics(
                            holdLeadingEdge: () =>
                                refresh.currentState?.isRevealing ?? false,
                            parent: const AlwaysScrollableScrollPhysics(),
                          )
                        : const AlwaysScrollableScrollPhysics(),
                    children: const [SizedBox(height: 1200)],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final original = list.currentContext;
    await tester.dragFrom(const Offset(200, 100), const Offset(0, 300));
    await tester.pump(const Duration(milliseconds: 32));
    expect(layer.currentState!.isOpen, isTrue);
    enabled.value = false;
    await tester.pumpAndSettle();
    expect(layer.currentState!.offset, 0);
    expect(layer.currentState!.isOpen, isFalse);
    expect(list.currentContext, same(original));
    expect(find.byType(MiniAppRefreshLogo), findsNothing);
    expect(
      ModalRoute.of(list.currentContext!)!.willHandlePopInternally,
      isFalse,
    );
    await tester.dragFrom(const Offset(200, 100), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(refreshes, 1);
    expect(layer.currentState!.offset, 0);
    enabled.value = true;
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(200, 100), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(layer.currentState!.isOpen, isTrue);
    expect(refreshes, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    enabled.dispose();
  });

  for (final expressive in [true, false]) {
    testWidgets('真实广场连续显露、即时操作；前景能反向接管 ($expressive)', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.padding = const FakeViewPadding(top: 52, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 52, bottom: 24);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      final layer = GlobalKey<HomeMiniAppsLayerState>();
      final gallery = GlobalKey();
      final refresh = GlobalKey<M3eRefreshIndicatorState>();
      final galleryScroll = ScrollController();
      final search = TextEditingController(text: '保留搜索');
      var refreshes = 0, taps = 0;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(extensions: [M3eFlags(enabled: expressive)]),
            home: HomeMiniAppsLayer(
              key: layer,
              gallery: Scaffold(
                key: gallery,
                body: SafeArea(
                  child: Column(
                    children: [
                      TextField(controller: search),
                      TextButton(
                        onPressed: () => taps++,
                        child: const Text('广场操作'),
                      ),
                      Expanded(
                        child: ListView(
                          controller: galleryScroll,
                          children: const [
                            SizedBox(height: 1600, child: Text('真实应用目录')),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              child: Scaffold(
                body: M3eRefreshIndicator(
                  key: refresh,
                  externalReveal: true,
                  revealOffset: () => layer.currentState!.offset,
                  onSecondaryAction: () => layer.currentState!.open(),
                  onRefresh: () async => refreshes++,
                  child: ListView(
                    physics: RefreshRevealScrollPhysics(
                      holdLeadingEdge: () =>
                          refresh.currentState?.isRevealing ?? false,
                      parent: const AlwaysScrollableScrollPhysics(),
                    ),
                    children: const [SizedBox(height: 1200, child: Text('社区'))],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      double offset() => layer.currentState!.offset;
      final pull = await tester.startGesture(const Offset(180, 160));
      await pull.moveBy(const Offset(0, 25));
      await tester.pump();
      await pull.moveBy(const Offset(0, 220));
      await tester.pump();
      expect(layer.currentState!.isOpen, isFalse);
      expect(find.byKey(gallery), findsOneWidget);
      final originalGallery = gallery.currentContext;
      final opacity = tester
          .widget<Opacity>(
            find
                .ancestor(
                  of: find.byKey(const ValueKey('mini-app-gallery-surface')),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity;
      expect(opacity, inExclusiveRange(0, 1), reason: '深拉时真实广场渐入，不突然全亮');
      double galleryScale() => tester
          .widget<Transform>(
            find.byKey(const ValueKey('mini-app-gallery-scale')),
          )
          .transform
          .storage[0];
      double galleryTint() =>
          (tester
                      .widget<DecoratedBox>(
                        find.byKey(const ValueKey('mini-app-gallery-tint')),
                      )
                      .decoration
                  as BoxDecoration)
              .color!
              .a;
      expect(galleryScale(), inExclusiveRange(.94, 1));
      expect(galleryTint(), greaterThan(0));
      expect(
        find.byType(MiniAppRefreshLogo),
        findsOneWidget,
        reason: '后页显露时，刷新提示仍叠在前景上方',
      );
      final firstLabelY = tester
          .getTopLeft(find.byKey(const ValueKey('mini-app-pull-label')))
          .dy;
      await pull.moveBy(const Offset(0, 25));
      await tester.pump();
      final releaseOffset = offset();
      final galleryPosition = tester.getTopLeft(find.byKey(gallery));
      final scaleBeforeRelease = galleryScale();
      final tintBeforeRelease = galleryTint();
      final labelY = tester
          .getTopLeft(find.byKey(const ValueKey('mini-app-pull-label')))
          .dy;
      expect(labelY, greaterThan(firstLabelY), reason: '提示沿前景上缘随手指下移');
      await pull.up();
      await tester.pump();
      expect(layer.currentState!.isOpen, isTrue);
      expect(offset(), closeTo(releaseOffset, 1));
      expect(gallery.currentContext, same(originalGallery));
      expect(tester.getTopLeft(find.byKey(gallery)), galleryPosition);
      expect(galleryScale(), scaleBeforeRelease);
      expect(galleryTint(), tintBeforeRelease, reason: '松手只开始吸附，不切换视觉状态');
      expect(
        find.byKey(const ValueKey('mini-app-return-home')).hitTestable(),
        findsNothing,
        reason: '未显露的返回条不能留下隐形点击区域',
      );
      // 吸附仍在进行，已显露的内容必须直接响应，不能等整屏透明层退场。
      await tester.tap(find.text('广场操作'));
      expect(taps, 1, reason: '打开动画期间可立即点击可见应用');
      final scrollingAt = offset();
      await tester.dragFrom(
        Offset(180, scrollingAt - 12),
        const Offset(0, -45),
      );
      await tester.pump();
      expect(galleryScroll.offset, greaterThan(0), reason: '动画期间列表也能直接滚动');
      expect(offset(), closeTo(scrollingAt, 1), reason: '列表滑动不抢成前景开关');

      // 前景随时可接住；背后的列表和按钮始终属于广场。
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 32));
        final caught = offset();
        final gesture = await tester.startGesture(
          Offset(180, (caught + 120).clamp(0, 800)),
        );
        await tester.pump(const Duration(milliseconds: 48));
        expect(offset(), closeTo(caught, .01), reason: '按下即停住');
        final delta = i.isEven ? -55.0 : 55.0;
        await gesture.moveBy(Offset(0, delta));
        await tester.pump();
        const geometry = RefreshRevealGeometry(
          viewportExtent: 844,
          topInset: 52,
        );
        final expected = delta > 0 && caught <= geometry.secondaryExtent
            ? geometry.offsetFor(geometry.distanceFor(caught) + delta)
            : caught + delta;
        expect(offset(), closeTo(expected, 1), reason: '回到刷新区沿用刷新阻尼，其余直接跟手');
        await gesture.moveBy(Offset(0, delta));
        await tester.pump();
        await gesture.up();
        await tester.pump();
        expect(gallery.currentContext, same(originalGallery));
      }
      await tester.tap(find.text('广场操作'));
      expect(taps, 2, reason: '连续反向接管后，动画未结束也能点击广场');
      final interruptedAt = offset();
      await tester.dragFrom(
        Offset(180, interruptedAt - 12),
        const Offset(0, -45),
      );
      await tester.pump();
      expect(galleryScroll.offset, greaterThan(45), reason: '打断后立即可滚动');
      expect(offset(), closeTo(interruptedAt, 1));
      await tester.pumpAndSettle();
      expect(offset(), 756);
      expect(galleryScale(), 1);
      expect(galleryTint(), 0);
      expect(find.byType(MiniAppRefreshLogo), findsNothing);
      expect(refreshes, 0);
      await tester.tap(find.text('广场操作'));
      expect(taps, 3, reason: '停止后广场仍可直接点击');
      await tester.dragFrom(const Offset(180, 400), const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(galleryScroll.offset, greaterThan(0));
      expect(offset(), 756, reason: '广场列表正常滚动不关闭页面');
      final scrollPosition = galleryScroll.offset;
      layer.currentState!.close();
      await tester.pumpAndSettle();
      expect(refresh.currentState!.isRevealing, isFalse);
      layer.currentState!.open();
      await tester.pumpAndSettle();
      expect(gallery.currentContext, same(originalGallery));
      expect(search.text, '保留搜索');
      expect(galleryScroll.offset, scrollPosition);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      galleryScroll.dispose();
      search.dispose();
    });
  }

  for (final bouncing in [false, true]) {
    testWidgets(
      'pull continues into the same layer; upward dismissal preserves home and route ($bouncing)',
      (tester) async {
        final layer = GlobalKey<HomeMiniAppsLayerState>();
        final home = GlobalKey();
        final refreshKey = GlobalKey<M3eRefreshIndicatorState>();
        var refreshes = 0;
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: HomeMiniAppsLayer(
                key: layer,
                gallery: const ColoredBox(
                  color: Colors.green,
                  child: Text('gallery'),
                ),
                child: Scaffold(
                  floatingActionButton: FloatingActionButton(
                    onPressed: () {},
                    child: const Text('FAB'),
                  ),
                  bottomNavigationBar: const SizedBox(
                    height: 64,
                    child: Center(child: Text('bottom navigation')),
                  ),
                  body: Builder(
                    builder: (context) => M3eRefreshIndicator(
                      key: refreshKey,
                      externalReveal: true,
                      revealOffset: () => HomeMiniAppsLayer.of(context).offset,
                      onSecondaryAction: () =>
                          HomeMiniAppsLayer.of(context).open(),
                      onRefresh: () async {
                        refreshes++;
                      },
                      child: ListView(
                        key: home,
                        physics: RefreshRevealScrollPhysics(
                          holdLeadingEdge: () =>
                              refreshKey.currentState?.isRevealing ?? false,
                          parent: bouncing
                              ? const BouncingScrollPhysics(
                                  parent: AlwaysScrollableScrollPhysics(),
                                )
                              : const ClampingScrollPhysics(
                                  parent: AlwaysScrollableScrollPhysics(),
                                ),
                        ),
                        children: List.generate(
                          40,
                          (i) => SizedBox(height: 40, child: Text('topic $i')),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final original = home.currentContext;
        final gesture = await tester.startGesture(const Offset(200, 100));
        await gesture.moveBy(const Offset(0, 25));
        await tester.pump();
        for (var i = 0; i < 10; i++) {
          await gesture.moveBy(const Offset(0, 40));
          await tester.pump(const Duration(milliseconds: 16));
        }
        double sheetOffset() => tester
            .widget<Transform>(
              find.byKey(const ValueKey('mini-app-community-sheet')),
            )
            .transform
            .storage[13];
        final beforeRelease = sheetOffset();
        expect(beforeRelease, greaterThan(100));
        expect(
          tester.getTopLeft(find.text('topic 0')).dy,
          closeTo(beforeRelease, 1),
          reason: 'native overscroll must not move the list twice',
        );
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 16));
        expect(sheetOffset(), greaterThanOrEqualTo(beforeRelease - .01));
        await tester.pumpAndSettle();
        expect(layer.currentState!.isOpen, isTrue);
        expect(refreshes, 0);
        expect(ModalRoute.of(home.currentContext!)!.isFirst, isTrue);
        expect(
          ModalRoute.of(home.currentContext!)!.willHandlePopInternally,
          isTrue,
        );
        expect(home.currentContext, same(original));
        expect(find.text('FAB').hitTestable(), findsNothing);
        expect(find.text('bottom navigation').hitTestable(), findsNothing);
        expect(
          sheetOffset(),
          tester.view.physicalSize.height / tester.view.devicePixelRatio - 64,
        );
        expect(
          find.byKey(const ValueKey('mini-app-return-home')).hitTestable(),
          findsOneWidget,
        );
        final close = await tester.startGesture(const Offset(200, 100));
        await close.moveBy(const Offset(0, -25));
        await tester.pump();
        await close.moveBy(const Offset(0, -250));
        await tester.pump();
        await close.up();
        var previousOffset = sheetOffset();
        for (var frame = 0; frame < 90; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            find.byType(MiniAppRefreshLogo),
            findsNothing,
            reason: '关闭广场不重播刷新提示',
          );
          expect(
            sheetOffset(),
            lessThanOrEqualTo(previousOffset + .01),
            reason: 'closing must never replay the recognizer\'s old deep pull',
          );
          previousOffset = sheetOffset();
        }
        await tester.pumpAndSettle();
        expect(layer.currentState!.isOpen, isFalse);
        expect(tester.getTopLeft(find.byKey(home)).dy, 0);
        expect(home.currentContext, same(original));
        expect(find.text('FAB').hitTestable(), findsOneWidget);
        // Reversing a deep pull must keep the list at its leading edge while
        // the foreground follows the finger back into the refresh range.
        final reverse = await tester.startGesture(const Offset(200, 100));
        await reverse.moveBy(const Offset(0, 25));
        await tester.pump();
        await reverse.moveBy(const Offset(0, 400));
        await tester.pump();
        final deepOffset = sheetOffset();
        await reverse.moveBy(const Offset(0, -40));
        await tester.pump();
        expect(sheetOffset(), lessThan(deepOffset));
        expect(
          tester.getTopLeft(find.text('topic 0')).dy,
          closeTo(sheetOffset(), 1),
          reason:
              'reverse motion must retract the sheet before scrolling topics',
        );
        await reverse.moveBy(const Offset(0, -220));
        await tester.pump();
        await reverse.up();
        await tester.pumpAndSettle();
        expect(refreshes, 1);
        expect(layer.currentState!.isOpen, isFalse);
        // Refresh uses the same moving surface and returns fully to rest.
        final shallow = await tester.startGesture(const Offset(200, 100));
        await shallow.moveBy(const Offset(0, 25));
        await tester.pump();
        await shallow.moveBy(const Offset(0, 150));
        await tester.pump();
        await shallow.up();
        await tester.pumpAndSettle();
        expect(refreshes, 2);
        expect(tester.getTopLeft(find.byKey(home)).dy, 0);

        // A new gesture can catch a returning surface without resetting it
        // to zero. Continue pulling from the visible position.
        final interrupted = await tester.startGesture(const Offset(200, 100));
        await interrupted.moveBy(const Offset(0, 25));
        await tester.pump();
        await interrupted.moveBy(const Offset(0, 60));
        await tester.pump();
        await interrupted.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 32));
        final returning = sheetOffset();
        expect(returning, greaterThan(0));
        final resume = await tester.startGesture(const Offset(200, 160));
        await resume.moveBy(const Offset(0, 25));
        await tester.pump();
        expect(sheetOffset(), greaterThanOrEqualTo(returning - 1));
        await resume.moveBy(const Offset(0, 400));
        await tester.pump();
        await resume.up();
        await tester.pumpAndSettle();
        expect(layer.currentState!.isOpen, isTrue);
        expect(refreshes, 2);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final textScale in [1.0, 1.8]) {
    testWidgets(
      'refresh feedback clears the status bar safe area ($textScale)',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(800, 600);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        tester.view.padding = const FakeViewPadding(top: 52);
        tester.view.viewPadding = const FakeViewPadding(top: 52);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        final layer = GlobalKey<HomeMiniAppsLayerState>();
        final refreshKey = GlobalKey<M3eRefreshIndicatorState>();
        var refreshes = 0;
        final refreshed = Completer<void>();
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
              home: HomeMiniAppsLayer(
                key: layer,
                gallery: const SizedBox.expand(),
                child: Scaffold(
                  body: M3eRefreshIndicator(
                    key: refreshKey,
                    externalReveal: true,
                    revealOffset: () => layer.currentState!.offset,
                    onSecondaryAction: () => layer.currentState!.open(),
                    onRefresh: () async {
                      refreshes++;
                      await refreshed.future;
                    },
                    child: ListView(
                      physics: RefreshRevealScrollPhysics(
                        holdLeadingEdge: () =>
                            refreshKey.currentState?.isRevealing ?? false,
                        parent: const AlwaysScrollableScrollPhysics(),
                      ),
                      children: const [SizedBox(height: 1200)],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final gesture = await tester.startGesture(const Offset(200, 100));
        await gesture.moveBy(const Offset(0, 25));
        await tester.pump();
        await gesture.moveBy(Offset(0, (52 + 80 + 36 * textScale) / .9 - 20));
        await tester.pump();
        final label = find.byKey(const ValueKey('mini-app-pull-label'));
        expect(
          find.text('app preview'),
          findsNothing,
          reason: 'pulling in the refresh range must not reveal apps',
        );
        expect(
          find.byKey(const ValueKey('mini-app-gallery-surface')),
          findsNothing,
        );
        expect(tester.getTopLeft(label).dy, greaterThanOrEqualTo(52));
        final logo = find.byType(MiniAppRefreshLogo);
        expect(tester.getTopLeft(logo).dy, greaterThanOrEqualTo(52));
        expect(
          tester.getBottomLeft(logo).dy,
          lessThan(tester.getTopLeft(label).dy),
        );
        await gesture.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.widget<MiniAppRefreshLogo>(logo).refreshing, isTrue);
        expect(find.text('app preview'), findsNothing);
        final painting = find.byKey(
          const ValueKey('mini-app-refresh-logo-paint'),
        );
        final first = tester.widget<CustomPaint>(painting).painter!;
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          tester.widget<CustomPaint>(painting).painter!.shouldRepaint(first),
          isTrue,
        );
        refreshed.complete();
        await tester.pumpAndSettle();
        expect(refreshes, 1);
        expect(layer.currentState!.isOpen, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('refresh logo respects reduced motion', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: const Center(
            child: MiniAppRefreshLogo(progress: 1, refreshing: true),
          ),
        ),
      ),
    );
    final painting = find.byKey(const ValueKey('mini-app-refresh-logo-paint'));
    final first = tester.widget<CustomPaint>(painting).painter!;
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.widget<CustomPaint>(painting).painter!.shouldRepaint(first),
      isFalse,
    );
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  for (final reducedMotion in [false, true]) {
    testWidgets(
      'gallery back is consumed before root exit guard ($reducedMotion)',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(800, 600);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        tester.view.padding = const FakeViewPadding(bottom: 24);
        tester.view.viewPadding = const FakeViewPadding(bottom: 24);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        final layer = GlobalKey<HomeMiniAppsLayerState>();
        final navigator = GlobalKey<NavigatorState>();
        var exitAttempts = 0;
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              navigatorKey: navigator,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(disableAnimations: reducedMotion),
                child: child!,
              ),
              home: Builder(
                builder: (context) => PopScope(
                  canPop: ModalRoute.canPopOf(context) ?? false,
                  onPopInvokedWithResult: (didPop, _) {
                    if (!didPop) exitAttempts++;
                  },
                  child: HomeMiniAppsLayer(
                    key: layer,
                    gallery: const SizedBox.expand(),
                    child: const Scaffold(body: Text('home')),
                  ),
                ),
              ),
            ),
          ),
        );
        layer.currentState!.open();
        await tester.pumpAndSettle();
        final footer = find.byKey(const ValueKey('mini-app-return-home'));
        expect(tester.getSize(footer).height, 88);
        expect(tester.getBottomLeft(footer).dy, 600);
        expect(
          tester
              .getBottomLeft(
                find.byKey(const ValueKey('mini-app-gallery-surface')),
              )
              .dy,
          600,
          reason: 'gallery background must extend behind the footer corners',
        );
        await navigator.currentState!.maybePop();
        await tester.pump();
        expect(exitAttempts, 0);
        if (!reducedMotion) {
          // Back again during the closing animation still belongs to the layer.
          await navigator.currentState!.maybePop();
          await tester.pump();
          expect(exitAttempts, 0);
        }
        await tester.pumpAndSettle();
        expect(layer.currentState!.isOpen, isFalse);
        expect(navigator.currentState!.canPop(), isFalse);
        await navigator.currentState!.maybePop();
        expect(exitAttempts, 1);

        layer.currentState!.open();
        await tester.pumpAndSettle();
        await tester.tap(footer);
        await tester.pumpAndSettle();
        expect(layer.currentState!.isOpen, isFalse);
        expect(exitAttempts, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
