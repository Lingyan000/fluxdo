import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_widget_library.dart';
import 'package:rfw/formats.dart';
import 'package:rfw/rfw.dart';

void main() {
  for (final component in ['PageLayout', 'ListPage', 'GridPage']) {
    for (final count in [2, 20]) {
      testWidgets('$component 上滑分页、去重、错误与末页 count=$count', (tester) async {
        tester.view.physicalSize = const Size(360, 500);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final data = DynamicContent()
          ..updateAll({'more': true, 'loading': false, 'error': ''});
        final rows = List.generate(count, (i) => 'row $i');
        data.update('rows', rows);
        const children = '...for row in data.rows: SizedBox(height: 100.0, child: Label(text: row))';
        final errorName = component == 'PageLayout' ? 'loadMoreError' : 'error';
        final slot = component == 'PageLayout' ? 'children' : 'items';
        final runtime = Runtime()
          ..update(
            metaverseWidgetLibraryName,
            createMetaverseWidgetLibrary(loadImage: (_) async => Uint8List(0)),
          )
          ..update(
            metaversePluginLibraryName,
            parseLibraryFile(
              'import fluxdo; widget Main = $component(hasMore: data.more, loadingMore: data.loading, $errorName: data.error, onLoadMore: event "more" {}, $slot: [$children]);',
            ),
          );
        addTearDown(runtime.dispose);
        var requests = 0;
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: RemoteWidget(
                  runtime: runtime,
                  widget: const FullyQualifiedWidgetName(
                    metaversePluginLibraryName,
                    'Main',
                  ),
                  data: data,
                  onEvent: (_, _) => requests++,
                ),
              ),
            ),
          ),
        );
        expect(requests, 0);
        final scroll = find.byType(Scrollable).first;
        await tester.drag(scroll, const Offset(0, -2400));
        await tester.pumpAndSettle();
        expect(requests, 1);
        await tester.drag(scroll, const Offset(0, -150));
        await tester.pumpAndSettle();
        expect(requests, 1);
        // 本地缓存直接追加一页；下一次上滑仍应能请求后面的内容。
        data.update('rows', [...rows, 'extra']);
        await tester.pump();
        await tester.drag(scroll, const Offset(0, -300));
        await tester.pumpAndSettle();
        expect(requests, 2);
        data.update('loading', true);
        await tester.pump();
        await tester.drag(scroll, const Offset(0, -150));
        await tester.pump();
        expect(requests, 2);
        data.updateAll({'loading': false, 'error': 'offline'});
        await tester.pump();
        await tester.drag(scroll, const Offset(0, -150));
        await tester.pumpAndSettle();
        expect(requests, 2);
        data.update('error', '');
        await tester.pump();
        await tester.drag(scroll, const Offset(0, -150));
        await tester.pumpAndSettle();
        expect(requests, 3);
        data.update('more', false);
        await tester.pump();
        await tester.drag(scroll, const Offset(0, -150));
        await tester.pumpAndSettle();
        expect(requests, 3);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
