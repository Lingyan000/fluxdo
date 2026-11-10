import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_refresh_logo.dart';
import 'package:fluxdo/theme/theme_registry.dart';
import 'package:fluxdo/theme/theme_resolver.dart';

void main() {
  testWidgets(
    'release preserves the pull frame and completion freezes the flow',
    (tester) async {
      Future<void> show(double progress, bool refreshing) => tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: MiniAppRefreshLogo(
              progress: progress,
              refreshing: refreshing,
            ),
          ),
        ),
      );
      CustomPainter painter() => tester
          .widget<CustomPaint>(
            find.byKey(const ValueKey('mini-app-refresh-logo-paint')),
          )
          .painter!;

      await show(1.2, false);
      final pulled = painter();
      await show(1, true);
      expect(painter().shouldRepaint(pulled), isFalse);
      await tester.pump(const Duration(milliseconds: 300));
      final running = painter();
      expect(running.shouldRepaint(pulled), isTrue);
      await show(.9, false);
      expect(painter().shouldRepaint(running), isFalse);
      await show(.4, false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(painter().shouldRepaint(running), isFalse);
      expect(tester.binding.hasScheduledFrame, isFalse);

      // A fresh pull can take over a settled logo without a leftover ticker.
      await show(.8, false);
      expect(painter().shouldRepaint(running), isTrue);
      final nextPull = painter();
      await show(1, true);
      expect(painter().shouldRepaint(nextPull), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('flow loops without flashing or moving the logo', (tester) async {
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: Theme(
          data: ThemeData.dark(),
          child: Center(
            child: RepaintBoundary(
              key: boundary,
              child: const MiniAppRefreshLogo(progress: 1, refreshing: true),
            ),
          ),
        ),
      ),
    );
    Future<Uint8List> pixels() async => (await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return bytes!.buffer.asUint8List();
    }))!;

    final start = await pixels();
    await tester.pump(const Duration(milliseconds: 400));
    final moving = await pixels();
    expect(moving, isNot(orderedEquals(start)));
    // The middle tone remains steady while light follows the other bands
    // and the right rim. A full-image shimmer would brighten this pixel too.
    const center = (40 * 80 + 40) * 4;
    expect(
      moving.sublist(center, center + 4),
      orderedEquals(start.sublist(center, center + 4)),
    );
    await tester.pump(const Duration(milliseconds: 1600));
    expect(await pixels(), orderedEquals(start));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final brightness in Brightness.values) {
    testWidgets('rim light stays smooth without corner spurs ($brightness)', (
      tester,
    ) async {
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Center(
            child: RepaintBoundary(
              key: boundary,
              child: const MiniAppRefreshLogo(progress: 1, refreshing: true),
            ),
          ),
        ),
      );
      Future<Uint8List> pixels() async => (await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 10);
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        image.dispose();
        return bytes!.buffer.asUint8List();
      }))!;
      // A 40dp mark at 10x gives four pixels per normalized logo unit.
      // This region contains the left rim between the two horizontal bands,
      // including the corner the wide light ribbon used to spill into.
      List<int> leftRim(Uint8List image) => [
        for (var y = 33 * 4; y < 67 * 4; y++)
          for (var x = 6 * 4; x < 15 * 4; x++)
            ...image.sublist((y * 400 + x) * 4, (y * 400 + x) * 4 + 4),
      ];
      final initial = await pixels();
      final baseline = leftRim(initial);
      // Sample inside the rim rather than its antialiased outer edge. Its
      // illumination must be continuous around the whole circle, including
      // twelve and six o'clock, where a half-circle clip left a visible step.
      List<int> rimLight(Uint8List image) => [
        for (var degrees = 0; degrees < 360; degrees += 2)
          image[((((50 + 42.43 * math.sin(degrees * math.pi / 180)) * 4)
                              .floor() *
                          400 +
                      ((50 + 42.43 * math.cos(degrees * math.pi / 180)) * 4)
                          .floor()) *
                  4) +
              3],
      ];
      final initialRim = rimLight(initial);
      for (var frame = 1; frame <= 20; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
        final image = await pixels();
        expect(
          leftRim(image),
          orderedEquals(baseline),
          reason: 'left contour changed at ${frame * 100}ms',
        );
        final rim = rimLight(image);
        for (var i = 0; i < rim.length; i++) {
          final next = (i + 1) % rim.length;
          final jump =
              (rim[next] - initialRim[next]) - (rim[i] - initialRim[i]);
          expect(
            jump.abs(),
            lessThanOrEqualTo(16),
            reason:
                'rim has a hard edge at ${i * 2} degrees / ${frame * 100}ms',
          );
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  const output = String.fromEnvironment('MINI_APP_MOTION_DIR');
  testWidgets(
    'export actual Flutter refresh motion in both themes',
    skip: output.isEmpty,
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(640, 440);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final fonts = FontLoader('MiSans')
        ..addFont(rootBundle.load('assets/fonts/MiSansVF.ttf'));
      await fonts.load();
      final themes = ThemeResolver.resolve(
        spec: ThemeRegistry.material,
        mode: ThemeMode.system,
        black: false,
        transparent: false,
        seed: Colors.blue,
        variant: DynamicSchemeVariant.tonalSpot,
      );
      Widget sample(ColorScheme scheme) => Expanded(
        child: Theme(
          data: ThemeData(colorScheme: scheme, fontFamily: 'MiSans'),
          child: ColoredBox(
            color: scheme.surfaceContainerLow,
            child: DefaultTextStyle(
              style: TextStyle(color: scheme.onSurface, fontFamily: 'MiSans'),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(scheme.brightness == Brightness.light ? '浅色' : '深色'),
                  const SizedBox(height: 24),
                  const MiniAppRefreshLogo(progress: 1, refreshing: true),
                  const SizedBox(height: 8),
                  const Text('正在刷新'),
                  const SizedBox(height: 40),
                  const SizedBox.square(
                    dimension: 120,
                    child: FittedBox(
                      child: MiniAppRefreshLogo(progress: 1, refreshing: true),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('3 倍细节'),
                ],
              ),
            ),
          ),
        ),
      );
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: RepaintBoundary(
              key: boundary,
              child: Row(children: [sample(themes.light), sample(themes.dark)]),
            ),
          ),
        ),
      );
      for (var frame = 0; frame < 120; frame++) {
        if (frame > 0) {
          // Integer microsecond timestamps cover exactly one 2000 ms cycle.
          final micros =
              (frame * 2000000 ~/ 120) - ((frame - 1) * 2000000 ~/ 120);
          await tester.pump(Duration(microseconds: micros));
        }
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(output).create(recursive: true);
          await File('$output/frame-${frame.toString().padLeft(3, '0')}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
