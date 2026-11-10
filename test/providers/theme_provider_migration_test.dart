import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/theme/theme_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ThemeNotifier> load(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return ThemeNotifier(await SharedPreferences.getInstance());
  }

  test('全新安装默认 Material', () async {
    final notifier = await load({});
    expect(notifier.state.themeId, ThemeRegistry.materialId);
  });

  test('旧中性开关打开迁移为简约', () async {
    final notifier = await load({'theme_neutral': true});
    expect(notifier.state.themeId, ThemeRegistry.minimalId);
    expect(notifier.state.themeSpec, ThemeRegistry.minimal);
  });

  test('旧中性开关关闭迁移为 Material', () async {
    final notifier = await load({'theme_neutral': false});
    expect(notifier.state.themeId, ThemeRegistry.materialId);
  });

  test('新键优先于旧键', () async {
    final notifier = await load({
      'theme_neutral': true,
      'theme_id': ThemeRegistry.materialId,
    });
    expect(notifier.state.themeId, ThemeRegistry.materialId);
  });

  test('未知主题 id 回退 Material 但保留原值', () async {
    final notifier = await load({'theme_id': 'removed-theme'});
    expect(notifier.state.themeId, 'removed-theme');
    expect(notifier.state.themeSpec, ThemeRegistry.material);
  });

  test('强调色按主题族记忆并持久化', () async {
    final notifier = await load({});
    await notifier.setThemeAccent('catppuccin', 'peach');
    await notifier.setThemeAccent('nord', '#E91E63');
    final reloaded = await load({
      'theme_accents': (await SharedPreferences.getInstance()).getString(
        'theme_accents',
      )!,
    });
    expect(reloaded.state.themeAccents, {
      'catppuccin': 'peach',
      'nord': '#E91E63',
    });
  });

  test('强调色存储损坏时回退为空', () async {
    final notifier = await load({'theme_accents': 'not json'});
    expect(notifier.state.themeAccents, isEmpty);
  });

  test('setThemeId 持久化到新键', () async {
    final notifier = await load({'theme_neutral': true});
    await notifier.setThemeId(ThemeRegistry.materialId);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_id'), ThemeRegistry.materialId);
    expect(notifier.state.themeId, ThemeRegistry.materialId);
  });
}
