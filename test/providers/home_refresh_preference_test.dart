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
  return _containerWithPreferences(prefs);
}

ProviderContainer _containerWithPreferences(SharedPreferences prefs) {
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('首页悬浮刷新按钮默认关闭，不受其他悬浮设置影响', () async {
    final container = await _createContainer(
      initialValues: {
        'pref_bottom_nav_floating': true,
        'pref_hide_bar_on_scroll': true,
      },
    );

    expect(container.read(preferencesProvider).homeRefreshButton, isFalse);
    expect(
      container
          .read(sharedPreferencesProvider)
          .containsKey('pref_home_refresh_button'),
      isFalse,
    );
  });

  test('copyWith 可开启和关闭首页刷新按钮，未指定时保留原值', () async {
    final container = await _createContainer();
    final original = container.read(preferencesProvider);
    final enabled = original.copyWith(homeRefreshButton: true);

    expect(original.homeRefreshButton, isFalse);
    expect(enabled.homeRefreshButton, isTrue);
    expect(enabled.copyWith().homeRefreshButton, isTrue);
    expect(enabled.copyWith(anonymousShare: true).homeRefreshButton, isTrue);
    expect(
      enabled.copyWith(homeRefreshButton: false).homeRefreshButton,
      isFalse,
    );
    expect(original.copyWith().homeRefreshButton, isFalse);
  });

  test('首页刷新按钮开关即时更新，开启与关闭均持久化并可恢复', () async {
    final container = await _createContainer();
    final notifier = container.read(preferencesProvider.notifier);
    final prefs = container.read(sharedPreferencesProvider);

    final enabling = notifier.setHomeRefreshButton(true);
    expect(container.read(preferencesProvider).homeRefreshButton, isTrue);
    await enabling;
    expect(prefs.getBool('pref_home_refresh_button'), isTrue);

    await prefs.reload();
    final enabledContainer = _containerWithPreferences(prefs);
    expect(
      enabledContainer.read(preferencesProvider).homeRefreshButton,
      isTrue,
    );

    await enabledContainer
        .read(preferencesProvider.notifier)
        .setAnonymousShare(true);
    expect(
      enabledContainer.read(preferencesProvider).homeRefreshButton,
      isTrue,
    );

    final disabling = enabledContainer
        .read(preferencesProvider.notifier)
        .setHomeRefreshButton(false);
    expect(
      enabledContainer.read(preferencesProvider).homeRefreshButton,
      isFalse,
    );
    await disabling;
    expect(prefs.getBool('pref_home_refresh_button'), isFalse);

    await prefs.reload();
    final disabledContainer = _containerWithPreferences(prefs);
    expect(
      disabledContainer.read(preferencesProvider).homeRefreshButton,
      isFalse,
    );
    expect(disabledContainer.read(preferencesProvider).anonymousShare, isTrue);
  });

  for (final enabled in [true, false]) {
    test('初始化恢复已保存的首页刷新按钮值：$enabled', () async {
      final container = await _createContainer(
        initialValues: {'pref_home_refresh_button': enabled},
      );

      expect(container.read(preferencesProvider).homeRefreshButton, enabled);
    });
  }
}
