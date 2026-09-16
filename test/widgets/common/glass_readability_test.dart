import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_island.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_object_surface.dart';

const recipes = [
  GlassRecipe.navigation,
  GlassRecipe.toolbar,
  GlassRecipe.menu,
  GlassRecipe.sheet,
  GlassRecipe.dialog,
];
const names = ['Navigation', 'Toolbar', 'Menu', 'Panel', 'Dialog'];

void main() {
  testWidgets('工具岛展开切换材质，保留输入和焦点', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    Future<void> pump(bool expanded) async {
      await tester.pumpWidget(
        MaterialApp(
          home: GlassSettingsScope(
            settings: const GlassSettings(level: GlassEffectLevel.basic),
            child: Column(
              children: [
                ComposerIsland(
                  expanded: expanded,
                  child: TextField(focusNode: focus),
                ),
                const ComposerObjectSurface(
                  compact: true,
                  child: SizedBox(width: 100, height: 48),
                ),
                const ComposerObjectSurface(
                  child: SizedBox(width: 100, height: 100),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await pump(false);
    expect(
      tester
          .widgetList<GlassSurface>(find.byType(GlassSurface))
          .map((w) => w.recipe),
      [GlassRecipe.toolbar, GlassRecipe.toolbar, GlassRecipe.menu],
    );
    focus.requestFocus();
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'keep editing');
    await pump(true);
    expect(
      tester.widgetList<GlassSurface>(find.byType(GlassSurface)).first.recipe,
      GlassRecipe.sheet,
    );
    expect(focus.hasFocus, isTrue);
    expect(find.text('keep editing'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final level in [GlassEffectLevel.basic, GlassEffectLevel.full]) {
    for (final dark in [false, true]) {
      for (final dpr in [1.0, 3.0]) {
        testWidgets(
          '背景隔离逐级增强 $level dark=$dark dpr=$dpr',
          (tester) async {
            final capture = GlobalKey();
            tester.view.devicePixelRatio = dpr;
            tester.view.physicalSize = const Size(340, 740) * dpr;
            addTearDown(tester.view.reset);
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(
                  brightness: dark ? Brightness.dark : Brightness.light,
                ),
                home: GlassSettingsScope(
                  settings: GlassSettings(level: level),
                  child: RepaintBoundary(
                    key: capture,
                    child: Scaffold(
                      body: Stack(
                        children: [
                          const Positioned.fill(
                            child: CustomPaint(painter: _BusyBackground()),
                          ),
                          for (var i = 0; i < recipes.length; i++)
                            Positioned(
                              left: 20,
                              top: 12 + i * 145,
                              width: 300,
                              height: 124,
                              child: GlassSurfaceFrame(
                                radius: 20,
                                recipe: recipes[i],
                                child: Align(
                                  alignment: Alignment.bottomLeft,
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Text(
                                      names[i],
                                      style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
            for (var attempt = 0; attempt < 50; attempt++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)),
              );
              await tester.pump();
              if (level == GlassEffectLevel.basic ||
                  find.byType(BackdropFilter).evaluate().length == 10) {
                break;
              }
            }
            await tester.pumpAndSettle();
            expect(
              find.byType(BackdropFilter),
              findsNWidgets(level == GlassEffectLevel.full ? 10 : 5),
            );
            final deviations = <double>[];
            final contrasts = <double>[];
            final foreground = Theme.of(capture.currentContext!)
                .colorScheme
                .onSurface
                .computeLuminance();
            await tester.runAsync(() async {
              final image =
                  await (capture.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage(pixelRatio: dpr);
              final data = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              for (var i = 0; i < recipes.length; i++) {
                var sum = 0.0, squares = 0.0;
                var count = 0;
                var minimumContrast = double.infinity;
                // Exclude labels, rounded edges and optical border. Wide contrast
                // bands avoid reducing the strongest levels to quantization noise.
                for (
                  var y = ((32 + i * 145) * dpr).round();
                  y < ((78 + i * 145) * dpr).round();
                  y++
                ) {
                  for (
                    var x = (50 * dpr).round();
                    x < (290 * dpr).round();
                    x++
                  ) {
                    final p = (y * image.width + x) * 4;
                    final l =
                        data.getUint8(p) * .2126 +
                        data.getUint8(p + 1) * .7152 +
                        data.getUint8(p + 2) * .0722;
                    final background = Color.fromARGB(
                      255,
                      data.getUint8(p),
                      data.getUint8(p + 1),
                      data.getUint8(p + 2),
                    ).computeLuminance();
                    final contrast =
                        (math.max(foreground, background) + .05) /
                        (math.min(foreground, background) + .05);
                    minimumContrast = math.min(minimumContrast, contrast);
                    sum += l;
                    squares += l * l;
                    count++;
                  }
                }
                contrasts.add(minimumContrast);
                deviations.add(
                  math.sqrt(
                    math.max(0, squares / count - math.pow(sum / count, 2)),
                  ),
                );
              }
              if (const bool.fromEnvironment('GLASS_SAVE_PROBES')) {
                final png = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await File(
                  '/tmp/fluxdo-glass-tiers-${level.name}-${dark ? 'dark' : 'light'}-$dpr.png',
                ).writeAsBytes(png!.buffer.asUint8List());
              }
              image.dispose();
            });
            for (var i = 1; i < deviations.length; i++) {
              expect(
                deviations[i],
                lessThan(deviations[i - 1]),
                reason: '${names[i]} 应比 ${names[i - 1]} 更隔离背景: $deviations',
              );
            }
            for (var i = 1; i < contrasts.length; i++) {
              expect(
                contrasts[i],
                greaterThanOrEqualTo(4.5),
                reason: '${names[i]} 的普通文字需保持对比度: $contrasts',
              );
            }
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
          skip:
              level == GlassEffectLevel.full &&
              !ui.ImageFilter.isShaderFilterSupported,
        );
      }
    }
  }
}

class _BusyBackground extends CustomPainter {
  const _BusyBackground();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final paint = Paint()..color = const Color(0xff182335);
    for (var x = 0.0; x < size.width; x += 240) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 120, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_BusyBackground oldDelegate) => false;
}
