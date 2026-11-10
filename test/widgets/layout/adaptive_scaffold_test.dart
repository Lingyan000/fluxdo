import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxdo/pages/topics_page.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/widgets/layout/adaptive_navigation.dart';
import 'package:fluxdo/widgets/layout/adaptive_scaffold.dart';
import 'package:fluxdo/modules/mini_apps/home_mini_apps_layer.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/widgets/layout/master_detail_layout.dart';
import 'package:fluxdo/widgets/topics/topics_fab.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => PlatformUtils.debugDesktopOverride = false);
  tearDown(() => PlatformUtils.debugDesktopOverride = null);

  for (final floating in [false, true]) {
    testWidgets('手机底栏将内容和 FAB 的避让高度传入主面板 floating=$floating', (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 815));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({
        'pref_bottom_nav_floating': floating,
        'pref_bottom_nav_labelless': true,
        'pref_hide_bar_on_scroll': true,
      });
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      MediaQueryData? contentMedia;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: TranslationProvider(
            child: MaterialApp(
              home: MediaQuery(
                data: const MediaQueryData(
                  size: Size(375, 815),
                  padding: EdgeInsets.only(bottom: 24),
                  viewPadding: EdgeInsets.only(bottom: 24),
                ),
                child: AdaptiveScaffold(
                  selectedIndex: 0,
                  onDestinationSelected: (_) {},
                  destinations: const [
                    AdaptiveDestination(
                      id: 'home',
                      icon: Icon(Icons.home),
                      selectedIcon: Icon(Icons.home),
                      label: '首页',
                    ),
                    AdaptiveDestination(
                      id: 'chat',
                      icon: Icon(Icons.chat),
                      selectedIcon: Icon(Icons.chat),
                      label: '聊天',
                    ),
                  ],
                  body: MasterDetailLayout(
                    master: Builder(
                      builder: (context) {
                        contentMedia = MediaQuery.of(context);
                        return const SizedBox.expand();
                      },
                    ),
                    masterFloatingActionButton: TopicsFab(
                      canCreate: true,
                      isActive: true,
                      onRefresh: () {},
                      onCreateTopic: () {},
                      onOpenDrafts: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bar = tester.getRect(find.byType(AdaptiveBottomNavigation));
      final fab = find.byKey(const ValueKey('topics-create-menu'));
      final fabBottom = tester.getBottomRight(fab).dy;
      final fabCenter = tester.getCenter(fab).dy;
      expect(contentMedia!.padding.bottom, closeTo(bar.height, 1));
      expect(fabBottom, lessThanOrEqualTo(bar.top - 16));
      final bodyHeight = tester
          .getSize(find.byKey(const ValueKey('master-pane')))
          .height;
      container.read(barVisibilityProvider.notifier).state = 0;
      await tester.pumpAndSettle();
      expect(tester.getCenter(fab).dy - fabCenter, closeTo(bar.height - 24, 1));
      expect(
        tester.getSize(find.byKey(const ValueKey('master-pane'))).height,
        bodyHeight,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('桌面窄窗口保留侧栏和广场入口，不挂移动端下拉层或底栏', (tester) async {
    PlatformUtils.debugDesktopOverride = true;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({
      'pref_mini_app_pull_enabled': true,
    });
    final prefs = await SharedPreferences.getInstance();
    var selected = -1;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          categoriesProvider.overrideWith((_) async => []),
        ],
        child: MaterialApp(
          home: AdaptiveScaffold(
            selectedIndex: 0,
            onDestinationSelected: (index) => selected = index,
            destinations: const [
              AdaptiveDestination(
                id: 'home',
                icon: Icon(Icons.home),
                selectedIcon: Icon(Icons.home),
                label: '首页',
              ),
              AdaptiveDestination(
                id: 'mini_apps',
                icon: Icon(Icons.apps),
                selectedIcon: Icon(Icons.apps),
                label: '应用广场',
              ),
              AdaptiveDestination(
                id: 'profile',
                icon: Icon(Icons.person),
                selectedIcon: Icon(Icons.person),
                label: '我的',
              ),
            ],
            body: const Text('主内容区'),
          ),
        ),
      ),
    );
    expect(find.byType(HomeMiniAppsLayer), findsNothing);
    expect(find.byType(AdaptiveBottomNavigation), findsNothing);
    expect(find.byType(AdaptiveNavigationRail), findsOneWidget);
    await tester.tap(find.byTooltip('应用广场'));
    expect(selected, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机端 barVisibility 为 0 时将底部导航栏平移出屏', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));

    SharedPreferences.setMockInitialValues({'pref_hide_bar_on_scroll': true});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    container.read(barVisibilityProvider.notifier).state = 0;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(390, 844)),
            child: AdaptiveScaffold(
              selectedIndex: 1,
              onDestinationSelected: (_) {},
              destinations: const [
                AdaptiveDestination(
                  id: 'home',
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: '首页',
                ),
                AdaptiveDestination(
                  id: 'bookmarks',
                  icon: Icon(Icons.bookmark_outline_rounded),
                  selectedIcon: Icon(Icons.bookmark_rounded),
                  label: '书签',
                ),
              ],
              body: const SizedBox.expand(child: Text('body')),
            ),
          ),
        ),
      ),
    );

    // 滚动平移层的 child 是投影开合层(AnimatedSlide),再往里才是底栏
    // 本体;AnimatedSlide 自身也由 FractionalTranslation 实现,不能只按
    // 类型找。
    final bottomNavTranslation = find.byWidgetPredicate(
      (widget) =>
          widget is FractionalTranslation && widget.child is AnimatedSlide,
    );

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(bottomNavTranslation, findsOneWidget);
    expect(
      tester.widget<FractionalTranslation>(bottomNavTranslation).translation,
      const Offset(0, 1),
    );

    container.read(barVisibilityProvider.notifier).state = 1;
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(
      tester.widget<FractionalTranslation>(bottomNavTranslation).translation,
      Offset.zero,
    );
  });

  testWidgets('横屏二级平行视界隐藏全局侧栏', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1400, 900));

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(1400, 900)),
            child: AdaptiveScaffold(
              selectedIndex: 0,
              onDestinationSelected: (_) {},
              hideNavigationRail: true,
              destinations: const [
                AdaptiveDestination(
                  id: 'home',
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: '首页',
                ),
                AdaptiveDestination(
                  id: 'messages',
                  icon: Icon(Icons.mail_outline),
                  selectedIcon: Icon(Icons.mail),
                  label: '私信',
                ),
              ],
              body: const SizedBox.expand(child: Text('平行视界内容')),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(AdaptiveNavigationRail), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('平行视界内容'), findsOneWidget);
  });
}
