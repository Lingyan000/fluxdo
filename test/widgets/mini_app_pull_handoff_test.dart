import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/modules/mini_apps/home_mini_apps_layer.dart';
import 'package:m3e_ui/m3e_ui.dart';

void main() {
  for (final expressive in [true, false]) {
    for (final bouncing in [true, false]) {
      testWidgets('关闭途中接回刷新、取消、再深拉 ($expressive/$bouncing)', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        tester.view.padding = const FakeViewPadding(top: 52, bottom: 24);
        tester.view.viewPadding = const FakeViewPadding(top: 52, bottom: 24);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        final layer = GlobalKey<HomeMiniAppsLayerState>();
        final refresh = GlobalKey<M3eRefreshIndicatorState>();
        final home = GlobalKey();
        final gallery = GlobalKey();
        final refreshed = Completer<void>();
        var refreshes = 0;
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              theme: ThemeData(extensions: [M3eFlags(enabled: expressive)]),
              home: HomeMiniAppsLayer(
                key: layer,
                gallery: ColoredBox(key: gallery, color: Colors.blue),
                child: Scaffold(
                  body: M3eRefreshIndicator(
                    key: refresh,
                    externalReveal: true,
                    revealOffset: () => layer.currentState!.offset,
                    onSecondaryAction: () => layer.currentState!.open(),
                    onRefresh: () async {
                      refreshes++;
                      await refreshed.future;
                    },
                    child: ListView(
                      key: home,
                      physics: RefreshRevealScrollPhysics(
                        holdLeadingEdge: () =>
                            refresh.currentState?.isRevealing ?? false,
                        parent: bouncing
                            ? const BouncingScrollPhysics(
                                parent: AlwaysScrollableScrollPhysics(),
                              )
                            : const ClampingScrollPhysics(
                                parent: AlwaysScrollableScrollPhysics(),
                              ),
                      ),
                      children: const [SizedBox(height: 1400)],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        double offset() => layer.currentState!.offset;
        Future<void> openByPull() async {
          await tester.dragFrom(const Offset(180, 180), const Offset(0, 320));
          await tester.pumpAndSettle();
          expect(layer.currentState!.isOpen, isTrue);
        }

        Future<TestGesture> catchClosing() async {
          layer.currentState!.close();
          await tester.pump();
          for (var frame = 0; frame < 90 && offset() > 95; frame++) {
            await tester.pump(const Duration(milliseconds: 8));
          }
          expect(offset(), inExclusiveRange(0, 95));
          final held = offset();
          final gesture = await tester.startGesture(const Offset(180, 500));
          await tester.pump(const Duration(milliseconds: 48));
          expect(offset(), closeTo(held, .01), reason: '按下即接住回程');
          await gesture.moveBy(const Offset(0, 25));
          await tester.pump();
          expect(offset(), closeTo(held + 25 * .9, 1), reason: '刷新从当前位移继续');
          return gesture;
        }

        final originalHome = home.currentContext;
        await openByPull();
        final originalGallery = gallery.currentContext;
        final resume = await catchClosing();
        await resume.moveBy(Offset(0, (178 - offset()) / .9));
        await tester.pump();
        expect(offset(), closeTo(178, 1));
        await resume.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 220));
        expect(refreshes, 1, reason: '回程接管后松手仍能刷新，不会强制重新打开广场');
        final surface = find.byKey(const ValueKey('mini-app-gallery-surface'));
        final opacity = tester.widget<Opacity>(
          find.ancestor(of: surface, matching: find.byType(Opacity)).first,
        );
        expect(opacity.opacity, 0, reason: '刷新时即使访问过广场也不能透出内容');
        refreshed.complete();
        await tester.pumpAndSettle();
        expect(offset(), 0);
        expect(layer.currentState!.isOpen, isFalse);
        expect(refresh.currentState!.isRevealing, isFalse);
        expect(
          ModalRoute.of(home.currentContext!)!.willHandlePopInternally,
          isFalse,
        );

        await openByPull();
        final cancel = await catchClosing();
        await cancel.cancel();
        await tester.pumpAndSettle();
        expect(offset(), 0);
        expect(refreshes, 1);

        await openByPull();
        final reopen = await catchClosing();
        await reopen.moveBy(const Offset(0, 250));
        await tester.pump();
        final beforeRelease = offset();
        await reopen.up();
        await tester.pump();
        expect(offset(), closeTo(beforeRelease, 1));
        await tester.pumpAndSettle();
        expect(layer.currentState!.isOpen, isTrue);
        expect(offset(), 756);
        expect(refreshes, 1);
        expect(home.currentContext, same(originalHome));
        expect(gallery.currentContext, same(originalGallery));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
