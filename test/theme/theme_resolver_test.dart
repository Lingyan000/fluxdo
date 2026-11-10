import 'package:fluxdo/theme/accent_colors.dart';
import 'package:fluxdo/theme/app_palettes.dart';
import 'package:fluxdo/theme/color_contrast.dart';
import 'package:fluxdo/theme/neutral_ramps.dart';
import 'package:fluxdo/theme/theme_registry.dart';
import 'package:fluxdo/theme/theme_resolver.dart';
import 'package:fluxdo/theme/theme_spec.dart';
import 'package:fluxdo/utils/seed_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 重构前的 ThemeResolver.resolve 原样拷贝，作为零视觉变化的参照。
ResolvedTheme _legacyResolve({
  required ThemeMode mode,
  required bool neutral,
  required bool black,
  required bool transparent,
  required Color seed,
  required DynamicSchemeVariant variant,
}) {
  ColorScheme schemeFor(Brightness brightness) {
    final useBlackRamp = black && brightness == Brightness.dark;
    if (neutral || useBlackRamp || transparent) {
      final base = useBlackRamp
          ? NeutralRamp.black
          : brightness == Brightness.light
          ? NeutralRamp.light
          : NeutralRamp.dark;
      return ThemeResolver.resolveColorScheme(
        accent: AccentColors.fromSeed(
          seedColor: seed,
          brightness: brightness,
          variant: variant,
        ),
        neutral: transparent ? NeutralRamp.transparent(base) : base,
        brightness: brightness,
      );
    }
    return SeedColorScheme.from(
      seedColor: seed,
      brightness: brightness,
      variant: variant,
    );
  }

  return ResolvedTheme(
    light: schemeFor(Brightness.light),
    dark: schemeFor(Brightness.dark),
    mode: mode,
    transparent: transparent,
  );
}

/// 一个 Catppuccin 风格的固定配色主题样例（Latte / Mocha 取值）。
Map<String, dynamic> _fixedJson() => {
  'id': 'sample',
  'name': {'zh': '样例', 'en': 'Sample'},
  'kind': 'fixed',
  'supportsPureBlack': true,
  'light': <String, dynamic>{
    'bg': '#EFF1F5',
    'fg': '#4C4F69',
    'fgMuted': '#6C6F85',
    'border': '#CCD0DA',
    'error': '#D20F39',
  },
  'dark': <String, dynamic>{
    'bg': '#1E1E2E',
    'fg': '#CDD6F4',
    'fgMuted': '#A6ADC8',
    'border': '#45475A',
    'roles': {'surfaceContainerHigh': '#313244', 'primary': '#F5C2E7'},
  },
  'accents': [
    {'id': 'mauve', 'light': '#8839EF', 'dark': '#CBA6F7'},
    {'id': 'peach', 'light': '#FE640B', 'dark': '#FAB387'},
    // 故意给一个在浅色底上对比度不足的强调色，验证补足逻辑
    {'id': 'yellow', 'light': '#F9E2AF', 'dark': '#F9E2AF'},
  ],
};

void main() {
  group('生成式主题与旧路径逐 role 一致', () {
    final seeds = {
      for (final p in AppPalettes.builtins) p.seedColor,
      const Color(0xFF6750A4), // 模拟系统动态色
    };
    for (final (spec, neutral) in [
      (ThemeRegistry.material, false),
      (ThemeRegistry.minimal, true),
    ]) {
      test(spec.id, () {
        for (final seed in seeds) {
          for (final variant in DynamicSchemeVariant.values) {
            for (final black in [false, true]) {
              for (final transparent in [false, true]) {
                final actual = ThemeResolver.resolve(
                  spec: spec,
                  mode: ThemeMode.system,
                  black: black,
                  transparent: transparent,
                  seed: seed,
                  variant: variant,
                );
                final expected = _legacyResolve(
                  mode: ThemeMode.system,
                  neutral: neutral,
                  black: black,
                  transparent: transparent,
                  seed: seed,
                  variant: variant,
                );
                final where =
                    '${spec.id} seed=$seed $variant black=$black '
                    'transparent=$transparent';
                expect(actual.light, expected.light, reason: '$where light');
                expect(actual.dark, expected.dark, reason: '$where dark');
                expect(actual.transparent, expected.transparent);
              }
            }
          }
        }
      });
    }
  });

  group('ThemeSpec JSON', () {
    test('往返一致', () {
      final spec = ThemeSpec.fromJson(_fixedJson());
      final again = ThemeSpec.fromJson(spec.toJson());
      expect(again.toJson(), spec.toJson());
      expect(spec.accents.map((a) => a.id), ['mauve', 'peach', 'yellow']);
      expect(spec.dark!.roles.keys, ['surfaceContainerHigh', 'primary']);
    });

    test('生成式主题往返一致', () {
      for (final spec in ThemeRegistry.builtins) {
        final again = ThemeSpec.fromJson(spec.toJson());
        expect(again.id, spec.id);
        expect(again.surface, spec.surface);
        expect(again.isGenerated, isTrue);
      }
    });

    test('缺少一侧亮度时拒绝', () {
      final json = _fixedJson()..remove('dark');
      expect(() => ThemeSpec.fromJson(json), throwsFormatException);
    });

    test('没有强调色时拒绝', () {
      final json = _fixedJson()..['accents'] = [];
      expect(() => ThemeSpec.fromJson(json), throwsFormatException);
    });

    test('未知 role 名与非法颜色拒绝', () {
      final badRole = _fixedJson();
      (badRole['light'] as Map)['roles'] = {'surfaceContainerHigest': '#000'};
      expect(() => ThemeSpec.fromJson(badRole), throwsFormatException);

      final badColor = _fixedJson();
      (badColor['light'] as Map)['outline'] = 'red';
      expect(() => ThemeSpec.fromJson(badColor), throwsFormatException);
    });

    test('颜色格式', () {
      expect(ThemeSpecColor.parse('#112233'), const Color(0xFF112233));
      expect(ThemeSpecColor.parse('#80112233'), const Color(0x80112233));
      expect(ThemeSpecColor.format(const Color(0xFF112233)), '#112233');
      expect(ThemeSpecColor.format(const Color(0x80112233)), '#80112233');
      expect(ThemeSpecColor.tryParse('#12345'), isNull);
    });
  });

  group('固定配色主题', () {
    final spec = ThemeSpec.fromJson(_fixedJson());

    ResolvedTheme resolve({
      String? accentId,
      bool black = false,
      bool transparent = false,
    }) => ThemeResolver.resolve(
      spec: spec,
      mode: ThemeMode.system,
      black: black,
      transparent: transparent,
      seed: Colors.blue,
      variant: DynamicSchemeVariant.tonalSpot,
      accentId: accentId,
    );

    void expectReadable(ColorScheme s, String where) {
      void check(Color fg, Color bg, double min, String pair) => expect(
        ColorContrast.ratio(fg, bg),
        greaterThanOrEqualTo(min - 0.01),
        reason: '$where $pair',
      );
      const t = ColorContrast.text;
      check(s.onSurface, s.surfaceContainerHighest, t, 'onSurface');
      check(s.onSurfaceVariant, s.surfaceContainerHighest, t, 'onSurfaceVar');
      check(s.onPrimary, s.primary, t, 'onPrimary');
      check(s.onPrimaryContainer, s.primaryContainer, t, 'onPrimaryCont');
      check(s.onSecondary, s.secondary, t, 'onSecondary');
      check(s.onSecondaryContainer, s.secondaryContainer, t, 'onSecCont');
      check(s.onTertiary, s.tertiary, t, 'onTertiary');
      check(s.onTertiaryContainer, s.tertiaryContainer, t, 'onTertCont');
      check(s.onError, s.error, t, 'onError');
      check(s.onErrorContainer, s.errorContainer, t, 'onErrorCont');
      check(s.primary, s.surface, ColorContrast.graphic, 'primary/surface');
      check(s.outline, s.surface, ColorContrast.graphic, 'outline');
    }

    test('表面色来自主题，不被种子色影响', () {
      final themes = resolve();
      expect(themes.light.surface, const Color(0xFFEFF1F5));
      expect(themes.dark.surface, const Color(0xFF1E1E2E));
      expect(themes.light.primary, const Color(0xFF8839EF));
    });

    test('所有强调色、明暗、修饰组合都满足对比度', () {
      for (final accent in spec.accents) {
        for (final black in [false, true]) {
          final themes = resolve(accentId: accent.id, black: black);
          expectReadable(themes.light, '${accent.id} light');
          expectReadable(themes.dark, '${accent.id} dark black=$black');
        }
      }
    });

    test('对比度不足的强调色被补足', () {
      final light = resolve(accentId: 'yellow').light;
      expect(light.primary, isNot(const Color(0xFFF9E2AF)));
      expect(
        ColorContrast.ratio(light.primary, light.surface),
        greaterThanOrEqualTo(ColorContrast.graphic - 0.01),
      );
    });

    test('tertiary 取强调色列表的下一个', () {
      final themes = resolve(accentId: 'mauve');
      expect(themes.dark.tertiary, const Color(0xFFFAB387));
      // 最后一个回绕到第一个
      expect(resolve(accentId: 'yellow').dark.tertiary, const Color(0xFFCBA6F7));
    });

    test('未知强调色回退第一个', () {
      expect(resolve(accentId: 'nope').light.primary, const Color(0xFF8839EF));
    });

    test('role 覆盖生效', () {
      final dark = resolve().dark;
      expect(dark.surfaceContainerHigh, const Color(0xFF313244));
      expect(dark.primary, const Color(0xFFF5C2E7));
    });

    test('纯黑：只作用于深色，表面覆盖让位，强调色覆盖保留', () {
      final themes = resolve(black: true);
      expect(themes.dark.surface, const Color(0xFF000000));
      expect(themes.dark.surfaceContainerHigh, isNot(const Color(0xFF313244)));
      expect(themes.dark.primary, const Color(0xFFF5C2E7));
      expect(themes.light.surface, const Color(0xFFEFF1F5));
    });

    test('不支持纯黑的主题忽略纯黑开关', () {
      final json = _fixedJson()..['supportsPureBlack'] = false;
      final noBlack = ThemeSpec.fromJson(json);
      final themes = ThemeResolver.resolve(
        spec: noBlack,
        mode: ThemeMode.dark,
        black: true,
        transparent: false,
        seed: Colors.blue,
        variant: DynamicSchemeVariant.tonalSpot,
      );
      expect(themes.dark.surface, const Color(0xFF1E1E2E));
    });

    test('透明：表面带透明度，表面覆盖让位', () {
      final themes = resolve(transparent: true);
      expect(themes.transparent, isTrue);
      expect(themes.light.isTransparentMode, isTrue);
      expect(themes.dark.isTransparentMode, isTrue);
      expect(themes.dark.surfaceContainerHigh.a, lessThan(1));
    });

    test('容器阶梯单调', () {
      final themes = resolve();
      double l(Color c) => c.computeLuminance();
      final light = themes.light;
      expect(l(light.surfaceContainerLow), lessThan(l(light.surface)));
      expect(
        l(light.surfaceContainerHighest),
        lessThan(l(light.surfaceContainerHigh)),
      );
      // 深色侧 surfaceContainerHigh 被覆盖，取未覆盖的相邻两级比较
      final dark = themes.dark;
      expect(l(dark.surfaceContainerLow), greaterThan(l(dark.surface)));
      expect(
        l(dark.surfaceContainerHighest),
        greaterThan(l(dark.surfaceContainer)),
      );
    });
  });

  group('ColorContrast', () {
    test('黑白对比度为 21', () {
      expect(
        ColorContrast.ratio(const Color(0xFF000000), const Color(0xFFFFFFFF)),
        closeTo(21, 0.01),
      );
    });

    test('已达标的颜色原样返回', () {
      const fg = Color(0xFF1E1E20);
      expect(
        ColorContrast.ensure(fg, const Color(0xFFFFFFFF), ColorContrast.text),
        fg,
      );
    });

    test('补足时保持色相', () {
      const fg = Color(0xFFF9E2AF);
      final fixed = ColorContrast.ensure(
        fg,
        const Color(0xFFEFF1F5),
        ColorContrast.text,
      );
      expect(
        HSLColor.fromColor(fixed).hue,
        closeTo(HSLColor.fromColor(fg).hue, 1),
      );
      expect(
        ColorContrast.ratio(fixed, const Color(0xFFEFF1F5)),
        greaterThanOrEqualTo(ColorContrast.text - 0.01),
      );
    });
  });
}
