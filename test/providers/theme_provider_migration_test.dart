import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/theme/theme_spec.dart';
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

  group('字体选择迁移', () {
    test('旧版选了 MiSans 迁移为下载版 MiSans', () async {
      final notifier = await load({'font_family': 'miSans'});
      expect(notifier.state.bodyFont, 'misans');
      expect(notifier.state.effectiveBodyFontId, 'misans');
      // 未下载未注册时回退系统字体
      expect(notifier.state.fontFamilyName, isNull);
    });

    test('旧版明确选了系统字体保持系统字体', () async {
      final notifier = await load({'font_family': 'system'});
      expect(notifier.state.bodyFont, FontChoice.system);
    });

    test('未设置过默认跟随主题，取主题推荐', () async {
      ThemeRegistry.setFixed([
        ThemeSpec.fromJson({
          'id': 'p',
          'kind': 'fixed',
          'font': {'body': 'lxgw-wenkai', 'mono': 'firacode'},
          'light': _side,
          'dark': _side,
          'accents': [
            {'id': 'a', 'light': '#1E66F5', 'dark': '#89B4FA'},
          ],
        }),
      ]);
      addTearDown(() => ThemeRegistry.setFixed(const []));
      final notifier = await load({'theme_id': 'p'});
      expect(notifier.state.bodyFont, FontChoice.follow);
      expect(notifier.state.effectiveBodyFontId, 'lxgw-wenkai');
      expect(notifier.state.effectiveMonoFontId, 'firacode');

      await notifier.setBodyFont(FontChoice.system);
      expect(notifier.state.effectiveBodyFontId, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('font_body'), FontChoice.system);
    });
  });
}

const _side = {
  'bg': '#FFFFFF',
  'fg': '#000000',
  'fgMuted': '#444444',
  'border': '#DDDDDD',
  'hues': {
    'red': '#D20F39',
    'orange': '#FE640B',
    'yellow': '#DF8E1D',
    'green': '#40A02B',
    'cyan': '#04A5E5',
    'blue': '#1E66F5',
    'purple': '#8839EF',
  },
};
