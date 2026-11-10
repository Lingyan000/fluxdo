import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:positioned_sliver_list/positioned_sliver_list.dart';
import 'package:fluxdo/widgets/common/positioned_stream_list.dart';

void main() {
  for (final index in [2, 12]) {
    testWidgets('从索引 $index 加载后，折叠块展开和收起逐帧保持标题位置', (tester) async {
      final scroll = ScrollController();
      final list = ListController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PositionedStreamList(
              scrollController: scroll,
              listController: list,
              itemKeys: [for (var i = 0; i < 30; i++) '$i'],
              initialIndex: index,
              positionKey: 'details',
              cacheExtent: 300,
              itemBuilder: (context, i) => i == index
                  ? FluxdoRender(
                      cookedHtml:
                          '<details><summary>标题</summary><p>${'长文内容。' * 200}</p></details>',
                      selectionEnabled: false,
                    )
                  : const SizedBox(height: 100),
            ),
          ),
        ),
      );
      final jump = list.jumpToIndex(index, offset: 100);
      await tester.pumpAndSettle();
      await jump;
      final header = find.text('标题');
      final before = tester.getTopLeft(header);
      for (final expanded in [true, false]) {
        await tester.tap(header);
        for (var frame = 0; frame < 15; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            tester.getTopLeft(header).dy,
            closeTo(before.dy, 1),
            reason: 'expanded=$expanded frame=$frame',
          );
        }
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      list.dispose();
      scroll.dispose();
    });
  }
}
