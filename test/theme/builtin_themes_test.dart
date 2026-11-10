import 'dart:convert';
import 'dart:io';

import 'package:fluxdo/services/fonts/font_catalog.dart';
import 'package:fluxdo/theme/color_contrast.dart';
import 'package:fluxdo/theme/theme_registry.dart';
import 'package:fluxdo/theme/theme_resolver.dart';
import 'package:fluxdo/theme/theme_spec.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 直接读仓库里的主题资产，与 ThemeRegistry.loadBuiltins 的解析同源。
List<ThemeSpec> _loadAssets() {
  final files =
      Directory('assets/themes')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final f in files)
      ThemeSpec.fromJson(
        jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
      ),
  ];
}

void main() {
  final specs = _loadAssets();

  test('全部主题资产可解析且 id 唯一', () {
    expect(specs, isNotEmpty);
    final ids = specs.map((s) => s.id).toList();
    expect(ids.toSet().length, ids.length);
    for (final spec in specs) {
      expect(spec.isGenerated, isFalse, reason: spec.id);
      expect(spec.name['zh'], isNotNull, reason: '${spec.id} 缺中文名');
      expect(spec.name['en'], isNotNull, reason: '${spec.id} 缺英文名');
      expect(spec.group, isNot(ThemeGroup.custom), reason: spec.id);
    }
  });

  test('主题推荐的字体都在字体目录里', () {
    final fonts = FontCatalog.parse(
      File(FontCatalog.assetPath).readAsStringSync(),
    );
    final ids = {for (final f in fonts) f.id: f.slot};
    for (final spec in specs) {
      if (spec.fontBody case final id?) {
        expect(ids[id], FontSlot.body, reason: '${spec.id} 正文字体 $id');
      }
      if (spec.fontMono case final id?) {
        expect(ids[id], FontSlot.mono, reason: '${spec.id} 等宽字体 $id');
      }
    }
  });

  test('同族主题的强调色 id 一致（切换口味保留强调色）', () {
    final byFamily = <String, List<ThemeSpec>>{};
    for (final spec in specs) {
      byFamily.putIfAbsent(spec.familyId, () => []).add(spec);
    }
    for (final family in byFamily.values.where((f) => f.length > 1)) {
      final first = family.first.accents.map((a) => a.id).toList();
      for (final spec in family.skip(1)) {
        expect(spec.accents.map((a) => a.id).toList(), first, reason: spec.id);
        expect(spec.variantName, isNotEmpty, reason: '${spec.id} 缺变体名');
      }
    }
  });

  test('所有主题、强调色、明暗、纯黑组合的文字都可读', () {
    void check(ColorScheme s, String where) {
      void pair(Color fg, Color bg, double min, String name) => expect(
        ColorContrast.ratio(fg, bg),
        greaterThanOrEqualTo(min - 0.01),
        reason: '$where $name',
      );
      const t = ColorContrast.text;
      pair(s.onSurface, s.surfaceContainerHighest, t, 'onSurface');
      pair(s.onSurfaceVariant, s.surfaceContainerHighest, t, 'onSurfaceVar');
      pair(s.onPrimary, s.primary, t, 'onPrimary');
      pair(s.onPrimaryContainer, s.primaryContainer, t, 'onPrimaryCont');
      pair(s.onSecondaryContainer, s.secondaryContainer, t, 'onSecCont');
      pair(s.onTertiaryContainer, s.tertiaryContainer, t, 'onTertCont');
      pair(s.onErrorContainer, s.errorContainer, t, 'onErrorCont');
      pair(s.primary, s.surface, ColorContrast.graphic, 'primary');
      pair(s.outline, s.surface, ColorContrast.graphic, 'outline');
    }

    for (final spec in specs) {
      for (final accent in spec.accents) {
        for (final black in [false, true]) {
          final themes = ThemeResolver.resolve(
            spec: spec,
            mode: ThemeMode.system,
            black: black,
            transparent: false,
            seed: Colors.blue,
            variant: DynamicSchemeVariant.tonalSpot,
            accentId: accent.id,
          );
          check(themes.light, '${spec.id}/${accent.id} light');
          check(themes.dark, '${spec.id}/${accent.id} dark black=$black');
          for (final (colors, side) in [
            (themes.lightColors, 'light'),
            (themes.darkColors, 'dark'),
          ]) {
            for (final e in colors.syntax.entries) {
              expect(
                ColorContrast.ratio(e.value.color!, colors.codeBackground),
                greaterThanOrEqualTo(ColorContrast.text - 0.01),
                reason: '${spec.id} $side syntax ${e.key}',
              );
            }
          }
        }
      }
    }
  });

  test('自定义强调色只在主题允许时生效', () {
    final spec = specs.firstWhere((s) => s.allowCustomAccent);
    final themes = ThemeResolver.resolve(
      spec: spec,
      mode: ThemeMode.system,
      black: false,
      transparent: false,
      seed: Colors.blue,
      variant: DynamicSchemeVariant.tonalSpot,
      accentId: '#E91E63',
    );
    expect(themes.dark.primary, isNot(spec.accents.first.dark));
  });

  test('注册表按分组与顺序排列，同族可查', () {
    ThemeRegistry.setFixed(specs);
    addTearDown(() => ThemeRegistry.setFixed(const []));
    final groups = ThemeRegistry.fixed.map((s) => s.group.index).toList();
    expect(groups, [...groups]..sort());
    final mocha = ThemeRegistry.byId('catppuccin-mocha');
    expect(mocha.id, 'catppuccin-mocha');
    expect(
      ThemeRegistry.familyOf(mocha).map((s) => s.id),
      containsAll(['catppuccin-frappe', 'catppuccin-macchiato']),
    );
  });

  test('本地化名字回退链', () {
    const names = {'zh': '纸质', 'zh_TW': '紙質', 'en': 'Paper'};
    expect(localizedName(names, const Locale('zh', 'TW'), 'x'), '紙質');
    expect(localizedName(names, const Locale('zh', 'CN'), 'x'), '纸质');
    expect(localizedName(names, const Locale('ja'), 'x'), 'Paper');
    expect(localizedName(const {}, const Locale('ja'), 'x'), 'x');
  });
}
