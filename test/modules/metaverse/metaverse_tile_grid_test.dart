import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_widget_library.dart';
import 'package:rfw/formats.dart';
import 'package:rfw/rfw.dart';

void main() {
  Future<DynamicContent> pumpGrid(
    WidgetTester tester, {
    String layout = 'natural',
    TextDirection direction = TextDirection.ltr,
    int columns = 2,
    double width = 360,
  }) async {
    final data = DynamicContent({
      'layout': layout,
      'columns': columns,
      'width': width,
      'minTileWidth': 0.0,
      'spacing': 12.0,
      'runSpacing': 12.0,
      'items': [
        {'label': 'a', 'height': 60.0},
        {'label': 'b', 'height': 100.0},
        {'label': 'c', 'height': 40.0},
      ],
    });
    final runtime = Runtime()
      ..update(
        metaverseWidgetLibraryName,
        createMetaverseWidgetLibrary(loadImage: (_) async => Uint8List(0)),
      )
      ..update(
        metaversePluginLibraryName,
        parseLibraryFile('''
        import fluxdo;
        widget Main = SizedBox(width: data.width, child: TileGrid(
          layout: data.layout, columns: data.columns,
          minTileWidth: data.minTileWidth, spacing: data.spacing,
          runSpacing: data.runSpacing,
          children: [...for item in data.items:
            Surface(padding: [0.0], onTap: event "tap" {label: item.label},
              child: SizedBox(height: item.height, child: Label(text: item.label)))
          ]
        ));
      '''),
      );
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: direction,
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: RemoteWidget(
                runtime: runtime,
                widget: const FullyQualifiedWidgetName(
                  metaversePluginLibraryName,
                  'Main',
                ),
                data: data,
              ),
            ),
          ),
        ),
      ),
    );
    return data;
  }

  Rect tile(WidgetTester tester, String label) => tester.getRect(
    find.ancestor(of: find.text(label), matching: find.byType(Material)).first,
  );

  for (final mode in MetaverseTileGridLayout.values) {
    testWidgets('网格 ${mode.name} 按实际尺寸布局并响应内容变化', (tester) async {
      final data = await pumpGrid(tester, layout: mode.name);
      final first = tile(tester, 'a');
      final second = tile(tester, 'b');
      final third = tile(tester, 'c');
      expect(first.width, 174);
      expect(second.left - first.right, 12);
      expect(
        first.height,
        mode == MetaverseTileGridLayout.equalHeight ? 100 : 60,
      );
      expect(third.top, mode == MetaverseTileGridLayout.masonry ? 72 : 112);
      data.update('items', [
        {'label': 'a', 'height': 140.0},
        {'label': 'b', 'height': 100.0},
        {'label': 'c', 'height': 40.0},
        {'label': 'd', 'height': 70.0},
      ]);
      await tester.pump();
      expect(
        tile(tester, 'b').height,
        mode == MetaverseTileGridLayout.equalHeight ? 140 : 100,
      );
      expect(
        tile(tester, 'c').top,
        mode == MetaverseTileGridLayout.masonry ? 112 : 152,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('网格模式切换、方向与末排列宽保持一致', (tester) async {
    final data = await pumpGrid(tester, direction: TextDirection.rtl);
    expect(tile(tester, 'a').left, 186);
    expect(tile(tester, 'b').left, 0);
    data.update('layout', 'equalHeight');
    await tester.pump();
    expect(tile(tester, 'a').height, tile(tester, 'b').height);
    data.update('items', [
      {'label': 'a', 'height': 60.0},
    ]);
    await tester.pump();
    expect(tile(tester, 'a').width, 174);
    expect(tile(tester, 'a').left, 186);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自动列数随窗口宽度改变并兼容空列表', (tester) async {
    final data = await pumpGrid(tester, columns: 0);
    expect(tile(tester, 'a').width, 174);
    data.update('width', 300.0);
    await tester.pump();
    expect(tile(tester, 'a').width, 300);
    expect(tile(tester, 'b').top, 72);
    data.update('items', <Object>[]);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('最小项宽度、显式列数与间距配置生效', (tester) async {
    final data = await pumpGrid(tester, columns: 0);
    data.update('minTileWidth', 200.0);
    data.update('runSpacing', 20.0);
    await tester.pump();
    expect(tile(tester, 'a').width, 360);
    expect(tile(tester, 'b').top, 80);
    data.update('columns', 3);
    data.update('spacing', 6.0);
    await tester.pump();
    expect(tile(tester, 'a').width, 116);
    expect(tile(tester, 'c').left, 244);
    expect(tile(tester, 'c').top, 0);
    expect(tester.takeException(), isNull);
  });
}
