import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/browser_tabs.dart';
import 'package:fluxdo/services/navigation/browser_dock_observer.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/browser/browser_dock_host.dart';
import 'package:fluxdo/widgets/browser/browser_dock_motion.dart';
import 'package:fluxdo/widgets/browser/browser_page_route.dart';
import 'package:fluxdo/widgets/layout/adaptive_navigation.dart';
import 'package:fluxdo/widgets/layout/adaptive_scaffold.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final config in [
    (width: 900.0, desktop: false, extended: false),
    (width: 390.0, desktop: true, extended: false),
    (width: 1400.0, desktop: true, extended: true),
  ]) {
    testWidgets('底栏只占主内容空间，侧栏保持全高 $config', (tester) async {
      PlatformUtils.debugDesktopOverride = config.desktop;
      addTearDown(() => PlatformUtils.debugDesktopOverride = null);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(config.width, 844);
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        'pref_mini_app_pull_enabled': false,
      });
      final prefs = await SharedPreferences.getInstance();
      final tabs = BrowserTabsController();
      final observer = BrowserDockObserver();
      final navigator = GlobalKey<NavigatorState>();
      final scroll = ScrollController(initialScrollOffset: 120);
      const contentKey = ValueKey('sidebar-test-content');
      const fabKey = ValueKey('sidebar-test-fab');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            categoriesProvider.overrideWith((_) async => []),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: navigator,
              navigatorObservers: [observer],
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  padding: const EdgeInsets.only(left: 16, bottom: 24),
                  viewPadding: const EdgeInsets.only(left: 16, bottom: 24),
                ),
                child: BrowserDockHost(
                  controller: tabs,
                  observer: observer,
                  onRestore: (_) {},
                  child: child!,
                ),
              ),
              home: AdaptiveScaffold(
                selectedIndex: 0,
                extendedRail: config.extended,
                onDestinationSelected: (_) {},
                destinations: const [
                  AdaptiveDestination(
                    id: 'home',
                    icon: Icon(Icons.home),
                    selectedIcon: Icon(Icons.home),
                    label: '首页',
                  ),
                  AdaptiveDestination(
                    id: 'profile',
                    icon: Icon(Icons.person),
                    selectedIcon: Icon(Icons.person),
                    label: '我的',
                  ),
                ],
                floatingActionButton: FloatingActionButton(
                  key: fabKey,
                  onPressed: () {},
                  child: const Icon(Icons.add),
                ),
                body: SizedBox.expand(
                  key: contentKey,
                  child: ListView.builder(
                    controller: scroll,
                    itemExtent: 60,
                    itemCount: 100,
                    itemBuilder: (_, index) => Text('内容 $index'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rail = find.byType(AdaptiveNavigationRail);
      final originalRail = tester.getRect(rail);
      final profile = config.extended ? find.text('我的') : find.byTooltip('我的');
      final originalProfile = tester.getRect(profile);
      final originalBody = tester.getRect(find.byKey(contentKey));
      expect(originalRail.height, 844);
      final tab = BrowserTabSession(url: 'https://example.com', title: '测试网页');
      tabs.minimize(tab);
      await tester.pump();
      for (var frame = 0; frame < 22; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getRect(rail), originalRail);
        expect(tester.getRect(profile), originalProfile);
        expect(scroll.offset, 120);
      }
      final card = find.byKey(const ValueKey('browser-dock-card'));
      final dockRect = tester.getRect(card);
      expect(dockRect.left, greaterThanOrEqualTo(originalRail.right + 12));
      expect(
        dockRect.center.dx,
        closeTo((originalRail.right + config.width) / 2, 1),
      );
      expect(
        tester.getRect(find.byKey(contentKey)).bottom,
        originalBody.bottom - 88,
      );
      expect(
        MediaQuery.paddingOf(tester.element(find.byKey(contentKey))).bottom,
        0,
      );
      expect(tester.getRect(find.byKey(fabKey)).bottom, lessThan(dockRect.top));

      // 旋转/缩放跨越导航栏断点时继续使用同一页面和滚动状态。
      if (!config.desktop) {
        tester.view.physicalSize = const Size(390, 844);
        await tester.pumpAndSettle();
        expect(rail, findsNothing);
        expect(tester.getSize(find.byType(Navigator)).height, 844 - 88);
        expect(scroll.offset, 120);
        tester.view.physicalSize = Size(config.width, 844);
        await tester.pumpAndSettle();
        expect(tester.getRect(rail), originalRail);
        expect(tester.getRect(card), dockRect);
      }

      // 普通详情页没有常驻侧栏，仍使用原有全宽底栏和内容避让。
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold()),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(card).center.dx,
        closeTo((config.width + 16) / 2, .1),
      );
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(tester.getRect(rail), originalRail);
      expect(tester.getRect(card), dockRect);

      // 上下转场与静态底栏共享右侧内容区落点，不能突然跳回整屏中心。
      final session = (await tabs.take(tab))!;
      final route = BrowserPageRoute<void>(
        fromDock: true,
        session: session,
        motion: BrowserDockViewport.motionOf(navigator.currentContext!),
        builder: (_) => const Scaffold(),
      );
      navigator.currentState!.push(route);
      await tester.pump();
      final moving = find.byKey(const ValueKey('browser-moving-dock-card'));
      expect(tester.getRect(moving), dockRect);
      await tester.pumpAndSettle();
      route.beginMinimize(session, hasSnapshot: false);
      tabs.minimize(session);
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(
        browserDockMinimizeDuration - const Duration(milliseconds: 4),
      );
      final landing = tester.getRect(moving);
      await tester.pumpAndSettle();
      expect(landing.left, closeTo(tester.getRect(card).left, 1));
      expect(landing.width, closeTo(tester.getRect(card).width, 1));
      expect(tester.getRect(profile), originalProfile);

      tabs.closeAll();
      await tester.pump();
      for (var frame = 0; frame < 22; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getRect(rail), originalRail);
        expect(tester.getRect(profile), originalProfile);
      }
      expect(tester.getRect(find.byKey(contentKey)), originalBody);
      expect(scroll.offset, 120);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      tabs.dispose();
      scroll.dispose();
    });
  }
}
