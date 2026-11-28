import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_widget_library.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rfw/formats.dart';
import 'package:rfw/rfw.dart';

import '../../helpers/preview_fonts.dart';

void main() {
  const screenshots = bool.fromEnvironment('PLUGIN_SNAPSHOTS');
  setUpAll(() async {
    if (!screenshots) return;
    await loadPreviewCjkFont();
    await (FontLoader('packages/material_symbols_icons/MaterialSymbolsRounded')
          ..addFont(
            rootBundle.load(
              'packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf',
            ),
          ))
        .load();
  });
  final capture = GlobalKey();
  late Runtime runtime;
  late DynamicContent data;
  setUp(() {
    data = DynamicContent();
    runtime = Runtime()
      ..update(
        metaverseWidgetLibraryName,
        createMetaverseWidgetLibrary(loadImage: (_) async => Uint8List(0)),
      );
  });
  tearDown(() => runtime.dispose());
  Future<void> show(
    WidgetTester tester,
    String source, {
    double scale = 1,
    bool dark = false,
    TextDirection direction = TextDirection.ltr,
    String imports = '',
    Color? background,
  }) async {
    runtime.update(
      metaversePluginLibraryName,
      parseLibraryFile('import fluxdo; $imports widget Test = $source;'),
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            fontFamily: screenshots ? 'MiSans' : null,
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.indigo,
              brightness: dark ? Brightness.dark : Brightness.light,
            ),
            extensions: const [UiShapes.standard],
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: Directionality(
              textDirection: direction,
              child: PageBackgroundScope(
                backgroundBuilder: background == null
                    ? null
                    : (_) => ColoredBox(color: background),
                child: child!,
              ),
            ),
          ),
          home: RepaintBoundary(
            key: capture,
            child: RoutePageBackground(
              child: Scaffold(
                backgroundColor: background == null ? null : Colors.transparent,
                body: RemoteWidget(
                  runtime: runtime,
                  widget: const FullyQualifiedWidgetName(
                    metaversePluginLibraryName,
                    'Test',
                  ),
                  data: data,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> snapshot(WidgetTester tester, String name) async {
    if (!screenshots) return;
    await tester.runAsync(() async {
      final picture = await tester
          .renderObject<RenderRepaintBoundary>(find.byKey(capture))
          .toImage();
      final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
      picture.dispose();
      final file = File('build/plugin-inner-ui/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  testWidgets('水平渐隐只作用于尚有内容的物理边缘，支持 RTL、反向、内容与宽度变化', (tester) async {
    data.updateAll({'width': 200.0, 'reverse': false});
    const source =
        'Align(alignment:{x:-1.0,y:-1.0}, child:SizedBox(width:100.0,height:40.0,child:HorizontalScroll(reverse:data.reverse,child:ColoredBox(color:0xFF000000,child:SizedBox(width:data.width,height:40.0)))))';
    Future<(int, int)> edges() async {
      return (await tester.runAsync(() async {
        final picture = await tester
            .renderObject<RenderRepaintBoundary>(find.byKey(capture))
            .toImage();
        final bytes = await picture.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final width = picture.width;
        picture.dispose();
        return (
          bytes!.getUint8((20 * width + 1) * 4),
          bytes.getUint8((20 * width + 98) * 4),
        );
      }))!;
    }

    for (final direction in TextDirection.values) {
      for (final reverse in [false, true]) {
        data.updateAll({'width': 200.0, 'reverse': reverse});
        await tester.pumpWidget(const SizedBox());
        await show(tester, source, direction: direction);
        final flipped = (direction == TextDirection.rtl) != reverse;
        var colors = await edges();
        expect(flipped ? colors.$1 : colors.$2, greaterThan(0));
        expect(flipped ? colors.$2 : colors.$1, 0);
        final position = tester
            .state<ScrollableState>(find.byType(Scrollable))
            .position;
        position.jumpTo(position.maxScrollExtent);
        await tester.pumpAndSettle();
        colors = await edges();
        expect(flipped ? colors.$2 : colors.$1, greaterThan(0));
        data.update('width', 100.0);
        await tester.pumpAndSettle();
        colors = await edges();
        expect(colors, (0, 0));
      }
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets('固定底栏透出页面背景，隐藏时不留分隔线和高度', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 720);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    data.update('visible', true);
    await show(
      tester,
      '''PageLayout(children:[Label(text:"正文")],footer:switch data.visible {
      true:Button(label:"确认"),default:SizedBoxShrink()})''',
      background: Colors.teal,
    );
    final pixels = await tester.runAsync(() async {
      final image = await tester
          .renderObject<RenderRepaintBoundary>(find.byKey(capture))
          .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return bytes!;
    });
    final index = (710 * 320 + 1) * 4;
    expect(pixels!.getUint8(index + 1), 150);
    expect(pixels.getUint8(index + 2), 136);
    data.update('visible', false);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(SingleChildScrollView)).bottom, 720);
    expect(tester.takeException(), isNull);
  });
  testWidgets('内容行大字长元信息与任意详情插槽不溢出，强调语义由显式状态驱动', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 720);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final semantics = tester.ensureSemantics();
    data.update('highlight', true);
    await show(
      tester,
      '''ContentRow(title:"社区近况", summary:"这里是较长的摘要，标题与内容分开呈现。",
      meta:"很长的来源信息 · 更新记录", emphasized:data.highlight,
      leading:Avatar(label:"林"),detail:Label(text:"2026-11-28 18:30 · 刚刚更新",style:"labelSmall"))''',
      scale: 1.8,
      dark: true,
    );
    expect(
      find.bySemanticsLabel(RegExp(S.current.metaverse_contentEmphasized)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await snapshot(tester, 'content-row-large-dark');
    data.update('highlight', false);
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel(RegExp(S.current.metaverse_contentEmphasized)),
      findsNothing,
    );
    semantics.dispose();
  });
  for (final dark in [false, true]) {
    testWidgets('随手记首发包草稿、错误重试与清空操作小屏可见 dark=$dark', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 720);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final bundle = jsonDecode(
        File('test/fixtures/metaverse/release/quick-notes-1.0.0.fluxplugin')
            .readAsStringSync(),
      );
      runtime.update(
        const LibraryName(['notes']),
        parseLibraryFile(bundle['files']['ui.rfwtxt']),
      );
      final locales = jsonDecode(
        File('test/fixtures/metaverse/quick-notes-locales.json')
            .readAsStringSync(),
      );
      data.updateAll({
        'note': '周末整理开发文档\n检查插件首发包',
        'count': '19 字',
        'status': '保存未完成',
        'failed': true,
        'hasNote': true,
        'confirming': false,
        'i18n': locales['zh'],
      });
      await show(
        tester,
        'Padding(padding:[16.0],child:SingleChildScrollView(child:Surface(child:Card())))',
        imports: 'import notes;',
        scale: 1.4,
        dark: dark,
      );
      expect(find.text('保存未完成'), findsOneWidget);
      expect(find.text('重试').hitTestable(), findsOneWidget);
      expect(find.text('清空').hitTestable(), findsOneWidget);
      expect(find.byType(InputFieldShell), findsOneWidget);
      expect(tester.takeException(), isNull);
      await snapshot(tester, 'notes-error-${dark ? 'dark' : 'light'}');
      data.updateAll({'status': '已自动保存', 'failed': false});
      await tester.pumpAndSettle();
      expect(find.text('重试'), findsNothing);
      await snapshot(tester, 'notes-${dark ? 'dark' : 'light'}');
    });
  }
}
