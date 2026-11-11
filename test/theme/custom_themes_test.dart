import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/theme/custom_themes.dart';
import 'package:fluxdo/theme/theme_registry.dart';
import 'package:fluxdo/theme/theme_resolver.dart';
import 'package:fluxdo/theme/theme_spec.dart';
import 'package:shared_preferences/shared_preferences.dart';

ThemeSpec _asset(String id) => ThemeSpec.fromJson(
  jsonDecode(File('assets/themes/$id.json').readAsStringSync())
      as Map<String, dynamic>,
);

ResolvedTheme _resolve(ThemeSpec spec) => ThemeResolver.resolve(
  spec: spec,
  mode: ThemeMode.system,
  black: false,
  seed: Colors.blue,
  variant: DynamicSchemeVariant.tonalSpot,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('底稿与导入导出', () {
    test('生成式主题的底稿取自当前解析结果', () {
      final resolved = _resolve(ThemeRegistry.material);
      final draft = CustomThemes.draftFrom(
        ThemeRegistry.material,
        name: '我的蓝',
        resolved: resolved,
      );
      expect(draft.isGenerated, isFalse);
      expect(draft.group, ThemeGroup.custom);
      expect(draft.id, startsWith('custom-'));
      expect(draft.light!.bg, resolved.light.surface);
      expect(draft.dark!.fg, resolved.dark.onSurface);
      expect(draft.accents.first.light, resolved.light.primary);
      // 底稿本身可解析回同样的配色
      expect(_resolve(draft).light.surface, resolved.light.surface);
    });

    test('固定配色主题的底稿复制配色并脱离原主题族', () {
      final mocha = _asset('catppuccin-mocha');
      final draft = CustomThemes.draftFrom(
        mocha,
        name: 'Mocha 副本',
        resolved: _resolve(mocha),
      );
      expect(draft.family, isNull);
      expect(draft.familyId, draft.id);
      expect(draft.group, ThemeGroup.custom);
      expect(draft.dark!.bg, mocha.dark!.bg);
      expect(draft.accents.length, mocha.accents.length);
      expect(draft.name['zh'], 'Mocha 副本');
    });

    test('导出再导入内容一致，id 冲突时换新', () {
      final draft = CustomThemes.draftFrom(
        _asset('paper'),
        name: '纸',
        resolved: _resolve(_asset('paper')),
      );
      final code = CustomThemes.export(draft);
      final same = CustomThemes.importFrom(code, existingIds: const {});
      expect(same.id, draft.id);
      expect(same.toJson(), draft.toJson());

      final renamed = CustomThemes.importFrom(code, existingIds: {draft.id});
      expect(renamed.id, isNot(draft.id));
      expect(renamed.light!.bg, draft.light!.bg);
    });

    test('导入内置主题代码会归入我的主题并换 id', () {
      final code = File('assets/themes/nord.json').readAsStringSync();
      final spec = CustomThemes.importFrom(code, existingIds: {'nord'});
      expect(spec.id, startsWith('custom-'));
      expect(spec.group, ThemeGroup.custom);
    });

    test('非法代码与生成式主题拒绝导入', () {
      expect(
        () => CustomThemes.importFrom('hello', existingIds: const {}),
        throwsFormatException,
      );
      expect(
        () => CustomThemes.importFrom('[1,2]', existingIds: const {}),
        throwsFormatException,
      );
      expect(
        () => CustomThemes.importFrom(
          jsonEncode(ThemeRegistry.minimal.toJson()),
          existingIds: const {},
        ),
        throwsFormatException,
      );
    });

    test('解码时跳过损坏条目', () {
      final good = CustomThemes.draftFrom(
        _asset('paper'),
        name: 'ok',
        resolved: _resolve(_asset('paper')),
      );
      final raw = jsonEncode([
        good.toJson(),
        {'id': 'broken'},
      ]);
      expect(CustomThemes.decode(raw).map((s) => s.id), [good.id]);
      expect(CustomThemes.decode('not json'), isEmpty);
      expect(CustomThemes.decode(null), isEmpty);
    });
  });

  group('状态', () {
    tearDown(() => ThemeRegistry.setCustom(const []));

    Future<ThemeNotifier> load([Map<String, Object> values = const {}]) async {
      SharedPreferences.setMockInitialValues(values);
      return ThemeNotifier(await SharedPreferences.getInstance());
    }

    test('保存后可选中，重启后仍在', () async {
      final notifier = await load();
      final draft = CustomThemes.draftFrom(
        _asset('paper'),
        name: '纸',
        resolved: _resolve(_asset('paper')),
      );
      await notifier.saveCustomTheme(draft);
      await notifier.setThemeId(draft.id);
      expect(notifier.state.themeSpec.id, draft.id);
      expect(ThemeRegistry.custom.single.id, draft.id);

      final prefs = await SharedPreferences.getInstance();
      ThemeRegistry.setCustom(const []);
      final reloaded = ThemeNotifier(prefs);
      expect(reloaded.state.themeSpec.id, draft.id);
      expect(reloaded.state.customThemes.single.name['zh'], '纸');
    });

    test('编辑保存按 id 覆盖', () async {
      final notifier = await load();
      final draft = CustomThemes.draftFrom(
        _asset('paper'),
        name: 'a',
        resolved: _resolve(_asset('paper')),
      );
      await notifier.saveCustomTheme(draft);
      await notifier.saveCustomTheme(draft.copyWith(name: {'zh': 'b'}));
      expect(notifier.state.customThemes.single.name['zh'], 'b');
    });

    test('删除正在使用的主题回退 Material，并清理强调色记忆', () async {
      final notifier = await load();
      final draft = CustomThemes.draftFrom(
        _asset('paper'),
        name: 'x',
        resolved: _resolve(_asset('paper')),
      );
      await notifier.saveCustomTheme(draft);
      await notifier.setThemeId(draft.id);
      await notifier.setThemeAccent(draft.id, draft.accents.last.id);
      await notifier.deleteCustomTheme(draft.id);
      expect(notifier.state.themeId, ThemeRegistry.materialId);
      expect(notifier.state.customThemes, isEmpty);
      expect(notifier.state.themeAccents.containsKey(draft.id), isFalse);
    });

    test('导入主题代码', () async {
      final notifier = await load();
      final spec = await notifier.importCustomTheme(
        File('assets/themes/nord.json').readAsStringSync(),
      );
      expect(notifier.state.customThemes.single.id, spec.id);
      expect(
        () => notifier.importCustomTheme('{}'),
        throwsFormatException,
      );
    });
  });
}
