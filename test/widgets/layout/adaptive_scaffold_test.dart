import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxdo/pages/topics_page.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/widgets/layout/adaptive_navigation.dart';
import 'package:fluxdo/widgets/layout/adaptive_scaffold.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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
