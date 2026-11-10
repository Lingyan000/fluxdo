import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/theme/app_background.dart';
import 'package:fluxdo/theme/neutral_ramps.dart';
import 'package:fluxdo/widgets/common/app_background_layer.dart';

const _wallpaper = Color(0xff00ff00);
const _previousPage = Color(0xffff0000);

Future<Color> _pixel(WidgetTester tester, GlobalKey key, Offset point) async =>
    (await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final offset = (point.dy.toInt() * image.width + point.dx.toInt()) * 4;
        return Color.fromARGB(
          bytes.getUint8(offset + 3),
          bytes.getUint8(offset),
          bytes.getUint8(offset + 1),
          bytes.getUint8(offset + 2),
        );
      } finally {
        image.dispose();
      }
    }))!;

void main() {
  Future<(GlobalKey<NavigatorState>, GlobalKey)> mount(
    WidgetTester tester,
  ) async {
    final nav = GlobalKey<NavigatorState>();
    final pixels = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: pixels,
        child: MaterialApp(
          navigatorKey: nav,
          theme: ThemeData(
            scaffoldBackgroundColor: Colors.transparent,
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: InterruptiblePageTransitionsBuilder(
                  CupertinoPageTransitionsBuilder(),
                ),
              },
            ),
          ),
          builder: (context, child) => PageBackgroundScope(
            backgroundBuilder: (_) => const ColoredBox(color: _wallpaper),
            child: child!,
          ),
          home: const Scaffold(
            body: ColoredBox(color: _previousPage, child: SizedBox.expand()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (nav, pixels);
  }

  for (final kind in ['application', 'framework', 'custom']) {
    testWidgets('透明页推入和返回只透出本页壁纸，route=$kind', (tester) async {
      final (nav, pixels) = await mount(tester);
      const detail = Scaffold(
        body: Align(alignment: Alignment.topRight, child: Text('detail')),
      );
      nav.currentState!.push(
        kind == 'custom'
            ? InteractionPageRouteBuilder<void>(
                pageBuilder: (_, _, _) => detail,
                transitionDuration: const Duration(milliseconds: 400),
                reverseTransitionDuration: const Duration(milliseconds: 400),
                transitionsBuilder: (_, animation, _, child) => SlideTransition(
                  position: Tween(
                    begin: const Offset(1, 0),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              )
            : kind == 'framework'
            ? MaterialPageRoute<void>(builder: (_) => detail)
            : InteractionPageRoute<void>(builder: (_) => detail),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      expect(await _pixel(tester, pixels, const Offset(780, 400)), _wallpaper);
      // 已露出的上一页仍然可见，背景不能铺在整个转场之外。
      expect(
        (await _pixel(tester, pixels, const Offset(10, 400))).r,
        greaterThan(.5),
      );
      expect(
        find.byType(RoutePageBackground, skipOffstage: false),
        findsNWidgets(2),
      );
      await tester.pumpAndSettle();
      nav.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(await _pixel(tester, pixels, const Offset(780, 400)), _wallpaper);
      await tester.pumpAndSettle();
      expect(
        await _pixel(tester, pixels, const Offset(400, 400)),
        _previousPage,
      );
    });
  }

  testWidgets('透明查看器和弹窗保留底层页面', (tester) async {
    final (nav, pixels) = await mount(tester);
    nav.currentState!.push(
      InteractionPageRouteBuilder<void>(
        opaque: false,
        pageBuilder: (_, _, _) => const SizedBox.expand(),
      ),
    );
    await tester.pumpAndSettle();
    expect(await _pixel(tester, pixels, const Offset(400, 400)), _previousPage);
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    showInteractionDialog<void>(
      context: nav.currentContext!,
      barrierColor: Colors.transparent,
      builder: (_) => const AlertDialog(content: Text('dialog')),
    );
    await tester.pumpAndSettle();
    expect(await _pixel(tester, pixels, const Offset(780, 400)), _previousPage);
  });

  testWidgets('切换透明背景不重新挂载页面状态', (tester) async {
    final enabled = ValueNotifier(true);
    addTearDown(enabled.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => ValueListenableBuilder(
          valueListenable: enabled,
          builder: (_, value, _) => PageBackgroundScope(
            backgroundBuilder: value
                ? (_) => const ColoredBox(color: _wallpaper)
                : null,
            child: child!,
          ),
        ),
        home: const RoutePageBackground(child: Scaffold(body: TextField())),
      ),
    );
    await tester.enterText(find.byType(TextField), 'keep editing');
    final state = tester.state(find.byType(TextField));
    enabled.value = false;
    await tester.pump();
    enabled.value = true;
    await tester.pump();
    expect(identical(state, tester.state(find.byType(TextField))), isTrue);
    expect(find.text('keep editing'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets('壁纸在解码前、透明 PNG 和文件丢失时不透页 $brightness', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 600);
      addTearDown(tester.view.reset);
      final directory = Directory.systemTemp.createTempSync('page-background-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/transparent.png';
      File(path).writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=',
        ),
      );
      final pixels = GlobalKey();
      final base = brightness == Brightness.light
          ? NeutralRamp.light.surface
          : NeutralRamp.dark.surface;
      await tester.pumpWidget(const MaterialApp(home: SizedBox.expand()));
      await tester.runAsync(
        () => precacheImage(
          ResizeImage(FileImage(File(path)), width: 800),
          tester.element(find.byType(SizedBox).first),
        ),
      );
      for (final file in [path, '${directory.path}/missing.png']) {
        await tester.pumpWidget(
          MaterialApp(
            themeAnimationDuration: Duration.zero,
            theme: ThemeData(brightness: brightness),
            home: RepaintBoundary(
              key: pixels,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: _previousPage),
                  AppBackgroundLayer(
                    background: AppBackground(
                      imagePath: file,
                      scrimLight: 0,
                      scrimDark: 0,
                      blurSigma: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        expect(await _pixel(tester, pixels, const Offset(400, 400)), base);
        await tester.pump();
        expect(await _pixel(tester, pixels, const Offset(400, 400)), base);
        expect(await _pixel(tester, pixels, const Offset(1, 1)), base);
        expect(tester.takeException(), isNull);
      }
    });
  }
}
