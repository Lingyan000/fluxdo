import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_interaction.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_engine.dart';
import 'package:fluxdo/navigation/nav_action_bus.dart';
import 'package:fluxdo/navigation/nav_entry_registry.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  tearDown(() => PlatformUtils.debugDesktopOverride = null);

  test('默认使用轻量宿主，保留明确选择的网页引擎，未知值使用默认引擎', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    ProviderContainer open() {
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      return container;
    }

    final first = open();
    expect(
      first.read(preferencesProvider).miniAppEngine,
      MiniAppEngine.lightweight,
    );
    await first
        .read(preferencesProvider.notifier)
        .setMiniAppEngine(MiniAppEngine.web);
    expect(open().read(preferencesProvider).miniAppEngine, MiniAppEngine.web);
    await prefs.setString('pref_mini_app_engine', 'unsupported');
    expect(
      open().read(preferencesProvider).miniAppEngine,
      MiniAppEngine.lightweight,
    );
  });

  test('移动端下拉默认开启，关闭持久化且不影响其他入口', () async {
    PlatformUtils.debugDesktopOverride = false;
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    ProviderContainer makeContainer() {
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      return container;
    }

    final container = makeContainer();
    expect(container.read(miniAppPullEnabledProvider), isTrue);
    await container
        .read(preferencesProvider.notifier)
        .setMiniAppPullEnabled(false);
    expect(container.read(miniAppPullEnabledProvider), isFalse);
    expect(prefs.getBool('pref_mini_app_pull_enabled'), isFalse);
    final restored = makeContainer();
    expect(restored.read(miniAppPullEnabledProvider), isFalse);
    expect(
      restored
          .read(preferencesProvider)
          .copyWith(anonymousShare: true)
          .miniAppPullEnabled,
      isFalse,
    );
    final entry = NavEntryRegistry.byId(NavEntryIds.miniApps)!;
    expect(entry.requiresLogin, isFalse);
    expect(entry.pageBuilder, isNotNull);
    expect(
      NavEntryRegistry.defaultBottomNavIds(),
      isNot(contains(NavEntryIds.miniApps)),
    );
    await restored
        .read(preferencesProvider.notifier)
        .setMiniAppPullEnabled(true);
    expect(restored.read(miniAppPullEnabledProvider), isTrue);
  });

  test('桌面无论保存的手势开关如何均禁用下拉，导航固定且不重复', () async {
    PlatformUtils.debugDesktopOverride = true;
    for (final enabled in [true, false]) {
      SharedPreferences.setMockInitialValues({
        'pref_mini_app_pull_enabled': enabled,
      });
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      expect(container.read(miniAppPullEnabledProvider), isFalse);
      container.dispose();
    }
    final selected = [
      NavEntryRegistry.byId(NavEntryIds.profile)!,
      NavEntryRegistry.byId(NavEntryIds.miniApps)!,
      NavEntryRegistry.byId(NavEntryIds.home)!,
    ];
    final desktop = NavEntryRegistry.desktopEntries(selected);
    expect(desktop.map((e) => e.id), [
      NavEntryIds.home,
      NavEntryIds.miniApps,
      NavEntryIds.profile,
    ]);
    expect(selected.first.id, NavEntryIds.profile, reason: '不改写用户的移动端排列');
    expect(desktop[1].requiresLogin, isFalse);
  });
}
