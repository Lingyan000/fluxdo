import 'package:common_ui/common_ui.dart' show UiShapes;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/theme/shape_presets.dart';
import 'package:fluxdo/theme/theme_registry.dart';
import 'package:fluxdo/theme/theme_spec.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show FluxdoRenderShapes;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UiShapes 换算', () {
    test('标准档恒等，外观与迁移前一致', () {
      const s = UiShapes.standard;
      for (final v in [0.0, 2, 4, 8, 12, 16, 20, 28, 99, 9999]) {
        expect(s.resolve(v.toDouble()), v.toDouble());
      }
      expect(s.borderRadius(12), BorderRadius.circular(12));
      expect(s.radius(8), const Radius.circular(8));
      expect(s.isStandard, isTrue);
    });

    test('适中按比例缩小，胶囊保持', () {
      final s = ShapePreset.compact.shapes;
      expect(s.resolve(20), closeTo(12, 1e-9));
      expect(s.resolve(9999), 9999);
    });

    test('方正封顶，胶囊也收成上限', () {
      final s = ShapePreset.sharp.shapes;
      expect(s.resolve(4), closeTo(0.8, 1e-9));
      expect(s.resolve(28), 3);
      expect(s.resolve(9999), 3);
    });

    test('渲染引擎换算与宿主同源', () {
      for (final preset in ShapePreset.values) {
        final ui = preset.shapes;
        final render = ui.render;
        for (final v in [4.0, 12, 20, 9999]) {
          expect(render.resolve(v.toDouble()), ui.resolve(v.toDouble()));
        }
      }
      expect(const FluxdoRenderShapes().resolve(12), 12);
    });

    test('插值在两档之间连续', () {
      final a = ShapePreset.standard.shapes;
      final b = ShapePreset.compact.shapes;
      expect(a.lerp(b, 0.5).scale, closeTo(0.8, 1e-9));
      expect(a.lerp(ShapePreset.sharp.shapes, 0.75).max, 3);
    });
  });

  group('主题推荐与用户指定', () {
    test('主题 JSON 的 shape 字段', () {
      final spec = ThemeSpec.fromJson({
        'id': 't',
        'kind': 'fixed',
        'shape': 'sharp',
        'light': _palette('#FFFFFF', '#000000'),
        'dark': _palette('#000000', '#FFFFFF'),
        'accents': [
          {'id': 'a', 'light': '#1E66F5', 'dark': '#89B4FA'},
        ],
      });
      expect(spec.shape, ShapePreset.sharp);
      expect(ThemeSpec.fromJson(spec.toJson()).shape, ShapePreset.sharp);
      expect(
        () => ThemeSpec.fromJson({...spec.toJson(), 'shape': 'round'}),
        throwsFormatException,
      );
      expect(ThemeRegistry.material.shape, ShapePreset.standard);
    });

    test('跟随主题与用户指定，指定值持久化', () async {
      SharedPreferences.setMockInitialValues({});
      final notifier = ThemeNotifier(await SharedPreferences.getInstance());
      expect(notifier.state.shapeOverride, isNull);
      expect(notifier.state.effectiveShapes, UiShapes.standard);

      await notifier.setShapeOverride(ShapePreset.sharp);
      expect(notifier.state.effectiveShapePreset, ShapePreset.sharp);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('shape_preset'), 'sharp');
      final reloaded = ThemeNotifier(prefs);
      expect(reloaded.state.shapeOverride, ShapePreset.sharp);

      await notifier.setShapeOverride(null);
      expect(notifier.state.shapeOverride, isNull);
      expect(prefs.getString('shape_preset'), isNull);
    });
  });
}

Map<String, dynamic> _palette(String bg, String fg) => {
  'bg': bg,
  'fg': fg,
  'fgMuted': fg,
  'border': fg,
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
