import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/browser_tabs.dart';
import 'package:fluxdo/services/navigation/browser_dock_observer.dart';
import 'package:fluxdo/widgets/browser/browser_dock_host.dart';
import 'package:fluxdo/widgets/browser/browser_tab_overview.dart';
import 'package:fluxdo/widgets/browser/browser_page_route.dart';
import 'package:fluxdo/widgets/browser/browser_dock_motion.dart';

import '../helpers/preview_fonts.dart';

class _ExternalTab extends BrowserTabSession {
  _ExternalTab() : super(url: 'about:blank', title: '外部会话');
}

void main() {
  late BrowserTabsController tabs;
  late BrowserDockObserver observer;
  late GlobalKey<NavigatorState> navigator;
  final restored = <BrowserTabSession>[];
  const contentKey = ValueKey('content');

  setUp(() {
    tabs = BrowserTabsController();
    observer = BrowserDockObserver();
    navigator = GlobalKey<NavigatorState>();
    restored.clear();
  });
  tearDown(() => tabs.dispose());

  BrowserTabSession addTab(String title) {
    final tab = BrowserTabSession(
      url: 'https://example.com/$title',
      title: title,
    );
    tabs.minimize(tab);
    return tab;
  }

  Widget app({
    double keyboard = 0,
    double safeBottom = 0,
    bool enabled = true,
    bool reduceMotion = false,
  }) => TranslationProvider(
    child: MaterialApp(
      navigatorKey: navigator,
      navigatorObservers: [observer],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduceMotion,
          viewInsets: EdgeInsets.only(bottom: keyboard),
          padding: EdgeInsets.only(bottom: safeBottom),
          viewPadding: EdgeInsets.only(bottom: safeBottom),
        ),
        child: BrowserDockHost(
          enabled: enabled,
          controller: tabs,
          observer: observer,
          onRestore: restored.add,
          child: child!,
        ),
      ),
      home: const Scaffold(body: SizedBox.expand(key: contentKey)),
    ),
  );

  testWidgets('底栏占据布局空间且安全区只算一次，恢复后归还空间', (tester) async {
    await tester.pumpWidget(app(safeBottom: 20));
    final full = tester.getSize(find.byKey(contentKey)).height;
    final tab = addTab('页面一');
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(contentKey)).height, full - 84);
    final media = MediaQuery.of(tester.element(find.byKey(contentKey)));
    expect(media.padding.bottom, 0);
    expect(media.viewPadding.bottom, 0);
    await tester.tap(find.text('页面一'));
    await tester.pumpAndSettle();
    expect(restored, [tab]);
    expect(tester.getSize(find.byKey(contentKey)).height, full);
    expect(tester.takeException(), isNull);
  });

  for (final reduceMotion in [false, true]) {
    testWidgets('打开浏览器首帧即清除底栏占位，减少动画 $reduceMotion', (tester) async {
      await tester.pumpWidget(app(safeBottom: 24, reduceMotion: reduceMotion));
      final full = tester.getSize(find.byType(Navigator)).height;
      addTab('保留在底栏的网页');
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(Navigator)).height, full - 88);
      navigator.currentState!.push(
        BrowserPageRoute<void>(
          motion: BrowserDockViewport.motionOf(navigator.currentContext!),
          builder: (_) => const Scaffold(),
        ),
      );
      await tester.pump();
      for (var frame = 0; frame < 36; frame++) {
        expect(
          tester.getSize(find.byType(Navigator)).height,
          full,
          reason: '进入浏览器的第 $frame 帧不应保留底栏占位',
        );
        expect(
          find.byKey(const ValueKey('browser-dock-card')).hitTestable(),
          findsNothing,
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tabs.tabs, hasLength(1));
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(Navigator)).height, full - 88);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('从多页恢复浏览器，展开结束后底栏不重新闪现', (tester) async {
    await tester.pumpWidget(app(safeBottom: 24));
    final full = tester.getSize(find.byType(Navigator)).height;
    final tab = addTab('恢复的网页');
    addTab('仍然收起的网页');
    await tester.pumpAndSettle();
    final session = (await tabs.take(tab))!;
    navigator.currentState!.push(
      BrowserPageRoute<void>(
        fromDock: true,
        session: session,
        motion: BrowserDockViewport.motionOf(navigator.currentContext!),
        builder: (_) => const Scaffold(),
      ),
    );
    await tester.pump();
    for (var frame = 0; frame < 50; frame++) {
      expect(
        tester.getSize(find.byType(Navigator)).height,
        full,
        reason: '恢复第 $frame 帧不应出现底部占位',
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      find.byKey(const ValueKey('browser-dock-card')).hitTestable(),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('browser-moving-dock-card')),
      findsNothing,
    );
    expect(tabs.tabs, hasLength(1));
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await session.close();
    expect(tester.takeException(), isNull);
  });

  testWidgets('多页概览从底栏跟手展开，顶部下拉可收回', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());
    addTab('页面一');
    addTab('页面二');
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('browser-overview-panel'));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('browser-restore-drag-area'))),
    );
    await gesture.moveBy(const Offset(0, -24));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    final top = tester.getTopLeft(panel).dy;
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getTopLeft(panel).dy, closeTo(top, .01));
    await gesture.moveBy(const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getTopLeft(panel).dy, closeTo(top - 300, 1));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(panel).dy, lessThan(40));
    final close = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey('browser-overview-drag-area')),
      ),
    );
    await close.moveBy(const Offset(0, 24));
    await tester.pump();
    await close.moveBy(const Offset(0, 450));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getTopLeft(panel).dy, greaterThan(450));
    await close.up();
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(tabs.tabs, hasLength(2));
    expect(restored, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭最后一页时保留底栏画面直到占位退完，不露黑底', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(key: boundaryKey, child: app(safeBottom: 20)),
    );
    final full = tester.getSize(find.byKey(contentKey)).height;
    addTab('正在关闭的网页');
    await tester.pumpAndSettle();
    final surface = Theme.of(tester.element(find.byType(BrowserDockHost)))
        .colorScheme
        .surface;
    await tester.tap(find.byTooltip('关闭'));
    await tester.pump();
    expect(tabs.tabs, isEmpty);
    var previousHeight = full - 84;
    for (var frame = 0; frame < 4; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('正在关闭的网页'), findsOneWidget);
      final height = tester.getSize(find.byKey(contentKey)).height;
      expect(height, greaterThan(previousHeight));
      expect(height, lessThan(full));
      previousHeight = height;
      // 底部安全区必须持续绘制主题背景，不能先清空成透明/黑色。
      final boundary =
          boundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        if (const bool.fromEnvironment('BROWSER_PREVIEW')) {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '.artifacts/browser-motion/previews/dock-close-$frame.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(png!.buffer.asUint8List());
        }
        final pixels = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final offset = ((image.height - 2) * image.width + 2) * 4;
        expect(pixels!.getUint8(offset), (surface.r * 255).round());
        expect(pixels.getUint8(offset + 1), (surface.g * 255).round());
        expect(pixels.getUint8(offset + 2), (surface.b * 255).round());
        expect(pixels.getUint8(offset + 3), 255);
        image.dispose();
      });
    }
    await tester.pumpAndSettle();
    expect(find.text('正在关闭的网页'), findsNothing);
    expect(tester.getSize(find.byKey(contentKey)).height, full);
    expect(tester.takeException(), isNull);
  });

  testWidgets('网页和小程序混合会话也支持上滑展开概览', (tester) async {
    await tester.pumpWidget(app());
    addTab('普通网页');
    tabs.minimize(_ExternalTab());
    await tester.pumpAndSettle();
    await tester.fling(
      find.byKey(const ValueKey('browser-restore-drag-area')),
      const Offset(0, -240),
      1200,
    );
    await tester.pumpAndSettle();
    final overview = tester.widget<BrowserTabOverview>(
      find.byType(BrowserTabOverview),
    );
    expect(overview.visible, isTrue);
    expect(overview.animation, isNotNull);
    expect(overview.onDragStart, isNotNull);
    expect(overview.onDragUpdate, isNotNull);
    expect(overview.onDragEnd, isNotNull);
    expect(overview.onDragCancel, isNotNull);
    expect(restored, isEmpty);
  });

  testWidgets('多页概览支持系统返回、Esc、横滑关闭和全部关闭', (tester) async {
    addTab('页面一');
    addTab('页面二');
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('2').first);
    await tester.pumpAndSettle();
    expect(find.byType(Dismissible), findsNWidgets(2));
    await navigator.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(Dismissible), findsNothing);
    expect(tabs.tabs.length, 2);
    await tester.tap(find.textContaining('2').first);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Dismissible), findsNothing);
    await tester.tap(find.textContaining('2').first);
    await tester.pumpAndSettle();
    await tester.fling(
      find.byType(Dismissible).first,
      const Offset(700, 0),
      1500,
    );
    await tester.pumpAndSettle();
    expect(tabs.tabs.length, 1);
    final closeAll = find.byType(TextButton);
    await tester.tap(closeAll);
    await tester.pumpAndSettle();
    expect(tabs.tabs, isEmpty);
    expect(navigator.currentState!.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('浏览器和全屏路由隐藏底栏，返回后恢复，键盘与禁用宿主也让位', (tester) async {
    addTab('页面一');
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final docked = tester.getSize(find.byKey(contentKey)).height;
    for (final name in [browserPageRouteName, fullscreenVideoRouteName]) {
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          settings: RouteSettings(name: name),
          builder: (_) => const Scaffold(body: Text('全屏')),
        ),
      );
      await tester.pumpAndSettle();
      expect(observer.hidden.value, isTrue);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(observer.hidden.value, isFalse);
      expect(tester.getSize(find.byKey(contentKey)).height, docked);
    }
    await tester.pumpWidget(app(keyboard: 200));
    await tester.pumpAndSettle();
    // Scaffold 自身避让键盘，宿主不再另外扣除底栏高度。
    expect(tester.getSize(find.byKey(contentKey)).height, docked + 64 - 200);
    await tester.pumpWidget(app(enabled: false));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(contentKey)).height, docked + 64);
    expect(tabs.tabs.length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('概览卡片统一尺寸与间距，保留自定义图标和副标题', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final first = addTab('普通网页');
    final second = addTab('自定义应用');
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: BrowserTabOverview(
            visible: true,
            tabs: [first, second],
            blurEnabled: false,
            iconBuilder: (_, tab, size) =>
                Icon(tab == second ? Icons.apps : Icons.language, size: size),
            subtitleBuilder: (_, tab) => tab == second ? '保留应用身份' : tab.url,
            onDismiss: () {},
            onRestore: restored.add,
            onCloseTab: tabs.close,
            onCloseAll: tabs.closeAll,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final firstRect = tester.getRect(find.byType(Dismissible).first);
    final secondRect = tester.getRect(find.byType(Dismissible).last);
    expect(firstRect.size, secondRect.size);
    expect(secondRect.left - firstRect.right, closeTo(12, .1));
    expect(firstRect.left, 32);
    expect(find.text('保留应用身份'), findsOneWidget);
    expect(find.byIcon(Icons.apps), findsOneWidget);
    await tester.tap(find.text('自定义应用'));
    expect(restored, [second]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('多页概览明暗主题与窄屏预览', (tester) async {
    if (!const bool.fromEnvironment('BROWSER_PREVIEW')) return;
    await loadPreviewCjkFont();
    final fontManifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final entry in fontManifest) {
      if (!(entry['family'] as String).contains('Material')) continue;
      final loader = FontLoader(entry['family'] as String);
      for (final font in entry['fonts'] as List) {
        loader.addFont(rootBundle.load(font['asset'] as String));
      }
      await loader.load();
    }
    // 预览只使用本地示例页面，不加载用户网页。
    final fixtures = <BrowserTabSession>[];
    for (var index = 0; index < 5; index++) {
      final tab = BrowserTabSession(
        url: [
          'https://flutter.dev',
          'https://dart.dev',
          'https://example.com/design',
          'https://example.org/read',
          'https://example.net',
        ][index],
        title: [
          'Flutter 开发文档',
          'Dart 语言指南',
          '设计中的留白',
          '稍后继续阅读',
          '尚未生成预览',
        ][index],
      );
      if (index < 4) {
        await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawColor(
            index.isEven ? const Color(0xfff3f6f2) : const Color(0xfff4f2ed),
            BlendMode.src,
          );
          final paragraph =
              (ui.ParagraphBuilder(
                      ui.ParagraphStyle(fontFamily: 'MiSans', fontSize: 28),
                    )
                    ..pushStyle(ui.TextStyle(color: const Color(0xff25372c)))
                    ..addText(tab.title))
                  .build()
                ..layout(const ui.ParagraphConstraints(width: 312));
          canvas.drawParagraph(paragraph, const Offset(24, 30));
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTWH(24, 100, 312, 180),
              const Radius.circular(20),
            ),
            Paint()
              ..color = [
                const Color(0xffc8dfd1),
                const Color(0xffd2dded),
                const Color(0xffe6d9c5),
                const Color(0xffdfd1e8),
              ][index],
          );
          for (var line = 0; line < 6; line++) {
            canvas.drawRRect(
              RRect.fromRectAndRadius(
                Rect.fromLTWH(
                  24,
                  312 + line * 24,
                  line % 3 == 2 ? 200 : 310,
                  10,
                ),
                const Radius.circular(5),
              ),
              Paint()..color = const Color(0xffc4cdc7),
            );
          }
          final picture = recorder.endRecording();
          final image = await picture.toImage(360, 500);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          tab.preview = bytes!.buffer.asUint8List();
          image.dispose();
          picture.dispose();
        });
      }
      fixtures.add(tab);
    }
    final boundary = GlobalKey();
    for (final variant in [
      (
        name: 'phone',
        size: const Size(390, 844),
        scale: 1.0,
        brightness: Brightness.light,
      ),
      (
        name: 'dark',
        size: const Size(390, 844),
        scale: 1.0,
        brightness: Brightness.dark,
      ),
      (
        name: 'narrow',
        size: const Size(320, 640),
        scale: 1.6,
        brightness: Brightness.light,
      ),
      (
        name: 'desktop',
        size: const Size(1200, 900),
        scale: 1.0,
        brightness: Brightness.light,
      ),
    ]) {
      tester.view.physicalSize = variant.size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: TranslationProvider(
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                fontFamily: 'MiSans',
                colorScheme: ColorScheme.fromSeed(
                  seedColor: const Color(0xff326b52),
                  brightness: variant.brightness,
                ),
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(variant.scale)),
                child: child!,
              ),
              home: Scaffold(
                body: BrowserTabOverview(
                  visible: true,
                  tabs: fixtures,
                  blurEnabled: false,
                  onDismiss: () {},
                  onRestore: (_) {},
                  onCloseTab: (_) {},
                  onCloseAll: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        for (final tab in fixtures) {
          if (tab.preview != null) {
            await precacheImage(
              MemoryImage(tab.preview!),
              boundary.currentContext!,
            );
          }
        }
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory('.artifacts/browser-motion/previews')
          ..createSync(recursive: true);
        await File('${directory.path}/overview-${variant.name}.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
    }
    tester.view.reset();
  });
}
