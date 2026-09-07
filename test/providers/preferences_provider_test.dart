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
