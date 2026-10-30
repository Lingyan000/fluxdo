import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/widgets/common/app_glass_settings.dart';
import 'package:fluxdo/widgets/layout/adaptive_navigation.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_island.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('一个偏好同时控制真实底栏和编辑工具岛，不改变尺寸', (tester) async {
    SharedPreferences.setMockInitialValues({
      'pref_bottom_nav_floating': true,
      'pref_bottom_nav_labelless': true,
      'pref_bottom_nav_floating_blur': false,
      'pref_glass_effect_level': 'basic',
      'pref_dialog_blur': false,
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (_, child) => AppGlassSettings(child: child!),
          home: Scaffold(
            body: const Center(
              child: SizedBox(
                width: 300,
                child: ComposerIsland(child: SizedBox(height: 132)),
              ),
            ),
            bottomNavigationBar: AdaptiveBottomNavigation(
              selectedIndex: 0,
              onDestinationSelected: (_) {},
              destinations: const [
                AdaptiveDestination(
                  id: 'home',
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: '首页',
                ),
                AdaptiveDestination(
                  id: 'profile',
                  icon: Icon(Icons.person_outline),
                  selectedIcon: Icon(Icons.person),
                  label: '我的',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(GlassSurface), findsNWidgets(2));
    expect(
      find.byType(BackdropFilter),
      findsNWidgets(2),
      reason: '基础档两处各一层模糊，旧底栏关闭值不再生效',
    );
    final before = tester
        .renderObjectList(find.byType(GlassSurface))
        .map((box) => (box as RenderBox).size)
        .toList();
    final notifier = container.read(preferencesProvider.notifier);
    await notifier.setGlassEnabled(false);
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(
      tester
          .renderObjectList(find.byType(GlassSurface))
          .map((box) => (box as RenderBox).size)
          .toList(),
      before,
    );
    await notifier.setGlassEffectLevel(GlassEffectLevel.full);
    await notifier.setGlassEnabled(true);
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
      if (!ui.ImageFilter.isShaderFilterSupported ||
          find.byType(BackdropFilter).evaluate().length == 4) {
        break;
      }
    }
    await tester.pumpAndSettle();
    expect(
      find.byType(BackdropFilter),
      findsNWidgets(ui.ImageFilter.isShaderFilterSupported ? 4 : 2),
    );
    expect(
      container.read(preferencesProvider).dialogBlur,
      isFalse,
      reason: '全局玻璃设置不控制弹窗背景模糊',
    );
    expect(tester.takeException(), isNull);
  });
}
