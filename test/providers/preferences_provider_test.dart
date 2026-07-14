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

  group('ccswitch import enabled', () {
    test('defaults to true', () async {
      final container = await _createContainer();
      addTearDown(container.dispose);

      expect(
        container.read(preferencesProvider).ccswitchImportEnabled,
        isTrue,
      );
    });

    test('setter persists and reloads', () async {
      final container = await _createContainer();
      addTearDown(container.dispose);

      await container
          .read(preferencesProvider.notifier)
          .setCcswitchImportEnabled(false);

      final prefs = container.read(sharedPreferencesProvider);
      final reloaded = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(reloaded.dispose);

      expect(
        reloaded.read(preferencesProvider).ccswitchImportEnabled,
        isFalse,
      );
      expect(prefs.getBool('pref_ccswitch_import_enabled'), isFalse);
    });
  });

  group('ccswitch import app', () {
    test('defaults to codex', () async {
      final container = await _createContainer();
      addTearDown(container.dispose);

      expect(
        container.read(preferencesProvider).ccswitchImportApp,
        CcswitchImportApp.codex,
      );
    });

    test('setter persists and reloads', () async {
      final container = await _createContainer();
      addTearDown(container.dispose);

      await container
          .read(preferencesProvider.notifier)
          .setCcswitchImportApp(CcswitchImportApp.claude);

      final prefs = container.read(sharedPreferencesProvider);
      final reloaded = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(reloaded.dispose);

      expect(
        reloaded.read(preferencesProvider).ccswitchImportApp,
        CcswitchImportApp.claude,
      );
      expect(prefs.getString('pref_ccswitch_import_app'), 'claude');
    });

    test('invalid value falls back to codex', () async {
      final container = await _createContainer(
        initialValues: {'pref_ccswitch_import_app': 'nope'},
      );
      addTearDown(container.dispose);

      expect(
        container.read(preferencesProvider).ccswitchImportApp,
        CcswitchImportApp.codex,
      );
    });
  });
}
