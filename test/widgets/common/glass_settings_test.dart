import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('自动按后端能力选择，基础不折射，关闭和高对比度优先', () {
    for (final level in GlassEffectLevel.values) {
      for (final enabled in [false, true]) {
        for (final supported in [false, true]) {
          for (final highContrast in [false, true]) {
            final settings = GlassSettings(enabled: enabled, level: level);
            expect(
              settings.allowsBlur(highContrast: highContrast),
              enabled && !highContrast,
            );
            expect(
              settings.allowsOptics(
                shaderSupported: supported,
                highContrast: highContrast,
              ),
              enabled &&
                  !highContrast &&
                  supported &&
                  level != GlassEffectLevel.basic,
            );
            expect(
              settings.allowsBlur(
                highContrast: highContrast,
                locallyEnabled: false,
              ),
              isFalse,
            );
          }
        }
      }
    }
  });

  testWidgets('高对比度下半透明色罩覆盖也强制实色', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(highContrast: true),
          child: Center(
            child: GlassSurface(
              recipe: GlassRecipe.navigation,
              shape: StadiumBorder(),
              tintColor: Color(0x40123456),
              child: SizedBox(width: 200, height: 48),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    final box = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(GlassSurface),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    expect((box.decoration as ShapeDecoration).color!.a, 1);
  });

  testWidgets('切换全局档位保留子状态，基础到完整可启动shader', (tester) async {
    var mounts = 0;
    Future<void> pump(
      GlassSettings settings, {
      bool highContrast = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: GlassSettingsScope(
            settings: settings,
            child: MediaQuery(
              data: MediaQueryData(highContrast: highContrast),
              child: Center(
                child: GlassSurfaceFrame(
                  radius: 20,
                  child: _Probe(onMount: () => mounts++),
                ),
              ),
            ),
          ),
        ),
      );
      // 完整档异步加载需要让真实事件循环运行；不把加载中当作最终降级。
      for (var i = 0; i < 50; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        await tester.pump();
        final optics = settings.allowsOptics(
          shaderSupported: ui.ImageFilter.isShaderFilterSupported,
          highContrast: highContrast,
        );
        if (!optics || find.byType(BackdropFilter).evaluate().length == 2) {
          break;
        }
      }
      await tester.pumpAndSettle();
    }

    await pump(const GlassSettings(level: GlassEffectLevel.basic));
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(mounts, 1);
    await pump(const GlassSettings(level: GlassEffectLevel.full));
    expect(
      find.byType(BackdropFilter),
      ui.ImageFilter.isShaderFilterSupported
          ? findsNWidgets(2)
          : findsOneWidget,
    );
    await pump(
      const GlassSettings(enabled: false, level: GlassEffectLevel.full),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    await pump(const GlassSettings(), highContrast: true);
    expect(find.byType(BackdropFilter), findsNothing);
    await pump(const GlassSettings());
    expect(
      find.byType(BackdropFilter),
      ui.ImageFilter.isShaderFilterSupported
          ? findsNWidgets(2)
          : findsOneWidget,
    );
    expect(mounts, 1);
    expect(tester.takeException(), isNull);
  });
}

class _Probe extends StatefulWidget {
  const _Probe({required this.onMount});
  final VoidCallback onMount;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 240, height: 100);
}
