import 'dart:io';

import 'package:common_ui/common_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_widget_library.dart';
import 'package:rfw/formats.dart';
import 'package:rfw/rfw.dart';

// 固定 Flutter 测试字体、尺寸和时刻；不依赖系统字体、网络或动画完成时间。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader('PluginBaseline')..addFont(
          File('test/fixtures/fonts/Roboto-Regular.ttf')
              .readAsBytes()
              .then(ByteData.sublistView),
        ))
        .load();
    await (FontLoader('packages/material_symbols_icons/MaterialSymbolsRounded')
          ..addFont(
            rootBundle.load(
              'packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf',
            ),
          ))
        .load();
  });
  for (final brightness in Brightness.values) {
    for (final width in [320.0, 800.0]) {
      testWidgets('时间线输入基线 ${brightness.name} $width', (tester) async {
        tester.view.physicalSize = Size(width, 720);
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = const FakeViewPadding(bottom: 240);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        final runtime = Runtime()
          ..update(metaverseWidgetLibraryName, createMetaverseWidgetLibrary(loadImage: (_) async => Uint8List(0)))
          ..update(metaversePluginLibraryName, parseLibraryFile('''
            import fluxdo;
            widget Main = TimelinePage(identity: "example", itemKeys: ["2", "1"],
              header: Label(text: "Conversation", style: "titleMedium"),
              footer: Row(crossAxisAlignment: "end", children: [
                Expanded(child: TextInput(value: "A longer message\\nReady to send", variant: "filled", minLines: 1, maxLines: 4, maxLength: 500, showCounter: false)), Gap(size: 8),
                Button(label: "Send", onPressed: event "send" {})]),
              items: [
                Padding(padding: [0.0, 6.0], child: Align(alignment: {x: 1.0, y: 0.0}, child: Surface(color: "secondaryContainer", child: Label(text: "Thanks!")))),
                Padding(padding: [0.0, 6.0], child: Align(alignment: {x: -1.0, y: 0.0}, child: Surface(child: Label(text: "You can use it on two devices."))))
              ]);
          '''));
        addTearDown(runtime.dispose);
        final key = GlobalKey();
        await tester.pumpWidget(TranslationProvider(child: MaterialApp(
          theme: ThemeData(fontFamily: 'PluginBaseline', colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: brightness), extensions: const [UiShapes.standard]),
          builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(width == 320 ? 1.4 : 1)), child: child!),
          home: RepaintBoundary(key: key, child: Scaffold(body: RemoteWidget(runtime: runtime,
            widget: const FullyQualifiedWidgetName(metaversePluginLibraryName, 'Main'), data: DynamicContent()))),
        )));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getRect(find.byType(TextField)).bottom, lessThanOrEqualTo(480));
        if (Platform.environment['PLUGIN_GOLDENS'] == '1') {
          await expectLater(find.byKey(key), matchesGoldenFile('goldens/timeline-${brightness.name}-${width.toInt()}.png'));
        }
      });
    }
    for (final width in [390.0, 800.0]) {
      for (final loading in [true, false]) {
        testWidgets('插件布局基线 ${brightness.name} $width loading=$loading', (
          tester,
        ) async {
          tester.view.physicalSize = Size(width, 720);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final runtime = Runtime()
            ..update(
              metaverseWidgetLibraryName,
              createMetaverseWidgetLibrary(
                loadImage: (_) async => Uint8List(0),
              ),
            )
            ..update(
              metaversePluginLibraryName,
              parseLibraryFile('''
              import fluxdo;
              widget Main = GridPage(layout: "equalHeight", minTileWidth: 160,
                loading: data.loading, error: "", hasMore: false,
                toolbar: SearchInput(hint: "Search plugins", value: ""),
                header: Statistics(items: [{label: "Following", value: "24"}, {label: "Unread", value: "8"}]),
                loadingPlaceholder: Skeleton(child: TileGrid(columns: 2, children: [SkeletonBox(height: 160), SkeletonBox(height: 160)])),
                items: [...for item in data.items: Surface(child: Column(crossAxisAlignment: "stretch", children: [
                  Label(text: item.title, maxLines: 3, style: "titleMedium"), Gap(size: 16), Amount(value: "12.50", unit: "LDC"), Gap(size: 12), Label(text: "Available", style: "bodySmall")
                ]))]);
            '''),
            );
          addTearDown(runtime.dispose);
          final key = GlobalKey();
          await tester.pumpWidget(
            TranslationProvider(
              child: MaterialApp(
                theme: ThemeData(
                  fontFamily: 'PluginBaseline',
                  colorScheme: ColorScheme.fromSeed(
                    seedColor: Colors.indigo,
                    brightness: brightness,
                  ),
                  extensions: const [UiShapes.standard],
                ),
                home: RepaintBoundary(
                  key: key,
                  child: Scaffold(
                    body: RemoteWidget(
                      runtime: runtime,
                      widget: const FullyQualifiedWidgetName(
                        metaversePluginLibraryName,
                        'Main',
                      ),
                      data: DynamicContent({
                        'loading': loading,
                        'items': loading
                            ? <Object>[]
                            : [
                                {'title': 'Development tools'},
                                {
                                  'title': 'A longer product name with several lines',
                                },
                                {'title': 'Community subscription'},
                              ],
                      }),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 200));
          expect(tester.takeException(), isNull);
          if (Platform.environment['PLUGIN_GOLDENS'] == '1') {
            await expectLater(
              find.byKey(key),
              matchesGoldenFile(
                'goldens/plugin-${brightness.name}-${width.toInt()}-$loading.png',
              ),
            );
          }
          expect(
            tester.renderObject<RenderBox>(find.byKey(key)).size,
            Size(width, 720),
          );
        });
      }
    }
  }
}
