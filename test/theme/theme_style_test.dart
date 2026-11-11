import 'package:common_ui/common_ui.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/theme/app_colors.dart';
import 'package:fluxdo/theme/app_theme.dart';
import 'package:fluxdo/theme/theme_registry.dart';
import 'package:fluxdo/theme/theme_style.dart';
import 'package:fluxdo/utils/color_utils.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show FluxdoRenderStyle;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ThemeData _build(ThemeStyle style, {Brightness brightness = Brightness.light}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF3366CC),
    brightness: brightness,
  );
  return buildAppTheme(
    scheme,
    AppColors.material(brightness),
    UiShapes.standard,
    const ThemeState(mode: ThemeMode.light, seedColor: Color(0xFF3366CC)),
    fullscreenSwipeBack: false,
    pageBackground: false,
    style: style,
  );
}

void main() {
  group('ThemeStyle JSON', () {
    test('默认值不写出，往返一致', () {
      expect(ThemeStyle.material.toJson(), isEmpty);
      const style = ThemeStyle(
        surfaces: SurfaceStyle.flat,
        controls: ControlStyle.ink,
        navIndicator: NavIndicatorStyle.bar,
        inputs: InputStyle.underline,
        shadows: false,
        titleFont: 'serif',
        bodyLineHeight: 1.7,
        quote: QuoteStyle.bar,
        texture: TextureStyle.paper,
        dataColors: DataColorStyle.muted,
      );
      expect(ThemeStyle.fromJson(style.toJson()), style);
    });

    test('无效取值拒绝', () {
      expect(
        () => ThemeStyle.fromJson({'surfaces': 'glass'}),
        throwsFormatException,
      );
    });

    test('只改数据色时组件仍按 Material', () {
      const style = ThemeStyle(dataColors: DataColorStyle.harmonized);
      expect(style.isMaterial, isFalse);
      expect(style.hasMaterialComponents, isTrue);
    });
  });

  group('强调 token', () {
    test('Material 下入口图标与选中都是强调色', () {
      final theme = _build(ThemeStyle.material);
      final emphasis = UiEmphasis.of(theme);
      expect(emphasis.accent, theme.colorScheme.primary);
      expect(emphasis.selected, theme.colorScheme.primary);
      expect(theme.appBarTheme.iconTheme?.color, theme.colorScheme.primary);
    });

    test('墨色控件的主题里换成墨色，链接色不变', () {
      final theme = _build(ThemeRegistry.minimal.style);
      final emphasis = UiEmphasis.of(theme);
      expect(emphasis.accent, theme.colorScheme.onSurface);
      expect(emphasis.selected, theme.colorScheme.onSurface);
      expect(theme.appBarTheme.iconTheme?.color, theme.colorScheme.onSurface);
      expect(theme.colorScheme.primary, isNot(theme.colorScheme.onSurface));
    });
  });

  group('同一区域图标同色', () {
    Future<Map<String, Color>> colors(
      WidgetTester tester,
      ThemeStyle style,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: _build(style),
          home: Scaffold(
            appBar: AppBar(
              actions: [
                IconButton(
                  key: const Key('appbar'),
                  onPressed: () {},
                  icon: const Icon(Icons.search),
                ),
              ],
            ),
            body: Column(
              children: [
                IconButton(
                  key: const Key('plain'),
                  onPressed: () {},
                  icon: const Icon(Icons.share),
                ),
                IconButton(
                  key: const Key('selected'),
                  isSelected: true,
                  onPressed: () {},
                  icon: const Icon(Icons.star),
                ),
                TopBarIconScope(
                  child: IconButton(
                    key: const Key('topbar'),
                    onPressed: () {},
                    icon: const Icon(Icons.menu),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      Color of(String key) => tester
          .widget<RichText>(
            find.descendant(
              of: find.byKey(Key(key)),
              matching: find.byType(RichText),
            ),
          )
          .text
          .style!
          .color!;
      return {
        for (final k in ['appbar', 'plain', 'selected', 'topbar']) k: of(k),
      };
    }

    for (final (name, style) in [
      ('material', ThemeStyle.material),
      ('minimal', ThemeRegistry.minimal.style),
    ]) {
      testWidgets(name, (tester) async {
        final theme = _build(style);
        final emphasis = UiEmphasis.of(theme);
        final c = await colors(tester, style);
        // 顶栏与顶栏区域：装饰强调；普通操作图标：次要色；选中：选中 token
        expect(c['appbar'], emphasis.accent);
        expect(c['topbar'], emphasis.accent);
        expect(c['plain'], theme.colorScheme.onSurfaceVariant);
        expect(c['selected'], emphasis.selected);
      });
    }
  });

  group('正文排版风格', () {
    test('Material 不改正文', () {
      final style = _build(ThemeStyle.material).extension<FluxdoRenderStyle>();
      expect(style, FluxdoRenderStyle.standard);
    });

    test('宋体标题与细竖条引用', () {
      final style = _build(
        const ThemeStyle(titleFont: 'serif', quote: QuoteStyle.bar),
      ).extension<FluxdoRenderStyle>()!;
      expect(style.headingFontFamily, isNotNull);
      expect(style.headingFontFamilyFallback!.last, 'serif');
      expect(style.quoteBackground, isFalse);
      expect(style.quoteBarWidth, lessThan(4));
    });
  });

  group('数据色', () {
    const red = Color(0xFFE53935);

    test('解析十六进制色', () {
      expect(ColorUtils.parseHex('E53935'), red);
      expect(ColorUtils.parseHex('#E53935'), red);
      expect(ColorUtils.parseHex('E539'), isNull);
      expect(ColorUtils.parseHex('zzzzzz'), isNull);
      expect(ColorUtils.parseHex(null), isNull);
    });

    test('vivid 原样，muted 降饱和，harmonized 只偏移色相', () {
      final vivid = _build(ThemeStyle.material);
      expect(ColorUtils.category('E53935', vivid), red);
      expect(
        ColorUtils.category('bad', vivid, fallback: Colors.teal),
        Colors.teal,
      );

      final muted = _build(const ThemeStyle(dataColors: DataColorStyle.muted));
      final m = HSLColor.fromColor(ColorUtils.category('E53935', muted));
      expect(m.saturation, lessThan(HSLColor.fromColor(red).saturation * 0.5));

      final harmonized = _build(
        const ThemeStyle(dataColors: DataColorStyle.harmonized),
      );
      final h = HSVColor.fromColor(ColorUtils.category('E53935', harmonized));
      final r = HSVColor.fromColor(red);
      expect(h.saturation, closeTo(r.saturation, 0.01));
      final shift = ((h.hue - r.hue + 540) % 360) - 180;
      expect(shift.abs(), inInclusiveRange(0.1, 15));
    });
  });
}
