import 'package:common_ui/common_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ProviderContainer> _createContainer({
  Map<String, Object> initialValues = const {},
}) async {
  SharedPreferences.setMockInitialValues(initialValues);
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

void main() {
  test('全局玻璃默认自动开启，不继承旧底栏关闭值', () async {
    final container = await _createContainer(
      initialValues: {
        'pref_bottom_nav_floating_blur': false,
        'pref_dialog_blur': false,
      },
    );
    addTearDown(container.dispose);
    final state = container.read(preferencesProvider);
    expect(state.glassEnabled, isTrue);
    expect(state.glassEffectLevel, GlassEffectLevel.auto);
    expect(state.dialogBlur, isFalse);
  });

  test('全局开关与档位分别持久化，关闭不会清空档位', () async {
    final container = await _createContainer();
    addTearDown(container.dispose);
    final notifier = container.read(preferencesProvider.notifier);
    await notifier.setGlassEffectLevel(GlassEffectLevel.basic);
    await notifier.setGlassEnabled(false);
    final prefs = container.read(sharedPreferencesProvider);
    expect(prefs.getString('pref_glass_effect_level'), 'basic');
    expect(prefs.getBool('pref_glass_enabled'), isFalse);
    final reloaded = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(reloaded.dispose);
    expect(reloaded.read(preferencesProvider).glassEnabled, isFalse);
    expect(
      reloaded.read(preferencesProvider).glassEffectLevel,
      GlassEffectLevel.basic,
    );
    await reloaded.read(preferencesProvider.notifier).setGlassEnabled(true);
    expect(
      reloaded.read(preferencesProvider).glassEffectLevel,
      GlassEffectLevel.basic,
    );
    await reloaded
        .read(preferencesProvider.notifier)
        .setGlassEffectLevel(GlassEffectLevel.full);
    expect(prefs.getString('pref_glass_effect_level'), 'full');
  });

  test('未知玻璃档位回到自动，不影响其他偏好', () async {
    final container = await _createContainer(
      initialValues: {'pref_glass_effect_level': 'future-level'},
    );
    addTearDown(container.dispose);
    expect(
      container.read(preferencesProvider).glassEffectLevel,
      GlassEffectLevel.auto,
    );
    await container.read(preferencesProvider.notifier).setGlassEnabled(false);
    await container
        .read(preferencesProvider.notifier)
        .setBottomNavFloating(true);
    expect(container.read(preferencesProvider).glassEnabled, isFalse);
  });

  test('单次返回退出默认关闭并可以持久化', () async {
    final container = await _createContainer();
    addTearDown(container.dispose);

    expect(container.read(preferencesProvider).exitOnSingleBack, isFalse);

    await container
        .read(preferencesProvider.notifier)
        .setExitOnSingleBack(true);

    final prefs = container.read(sharedPreferencesProvider);
    final reloaded = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(reloaded.dispose);

    expect(reloaded.read(preferencesProvider).exitOnSingleBack, isTrue);
  });

  test('书签默认打开方式默认值为 defaultRoute', () async {
    final container = await _createContainer();
    addTearDown(container.dispose);

    final preferences = container.read(preferencesProvider);

    expect(preferences.bookmarksOpenMode, BookmarksOpenMode.defaultRoute);
  });

  test('切换到标签页模式后重建 provider 仍会恢复', () async {
    final container = await _createContainer();
    addTearDown(container.dispose);

    await container
        .read(preferencesProvider.notifier)
        .setBookmarksOpenMode(BookmarksOpenMode.tabbedWorkspace);

    final prefs = container.read(sharedPreferencesProvider);
    final reloaded = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(reloaded.dispose);

    expect(
      reloaded.read(preferencesProvider).bookmarksOpenMode,
      BookmarksOpenMode.tabbedWorkspace,
    );
  });

  test('非法持久化值会回退到 defaultRoute', () async {
    final container = await _createContainer(
      initialValues: {'pref_bookmarks_open_mode': 'unexpected'},
    );
    addTearDown(container.dispose);

    expect(
      container.read(preferencesProvider).bookmarksOpenMode,
      BookmarksOpenMode.defaultRoute,
    );
  });

  test('过滤提示开关默认开启，关闭后持久化并可恢复', () async {
    final container = await _createContainer();
    addTearDown(container.dispose);

    expect(container.read(preferencesProvider).showFilterHint, isTrue);

    await container.read(preferencesProvider.notifier).setShowFilterHint(false);

    expect(container.read(preferencesProvider).showFilterHint, isFalse);
    final prefs = container.read(sharedPreferencesProvider);
    expect(prefs.getBool('pref_show_filter_hint'), isFalse);

    final reloaded = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(reloaded.dispose);
    expect(reloaded.read(preferencesProvider).showFilterHint, isFalse);
  });

  test('AI 翻译偏好可以持久化并恢复', () async {
    final container = await _createContainer();
    addTearDown(container.dispose);

    final notifier = container.read(preferencesProvider.notifier);
    await notifier.setAiTranslationEnabled(true);
    await notifier.setAiTranslationTargetLanguage('ja');
    await notifier.setAiTranslationModelKey('provider:model');

    final prefs = container.read(sharedPreferencesProvider);
    final reloaded = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(reloaded.dispose);

    final state = reloaded.read(preferencesProvider);
    expect(state.aiTranslationEnabled, isTrue);
    expect(state.aiTranslationTargetLanguage, 'ja');
    expect(state.aiTranslationModelKey, 'provider:model');
  });
}
