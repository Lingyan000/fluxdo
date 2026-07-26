import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/layout/draggable_divider.dart';
import 'package:fluxdo/widgets/layout/master_detail_layout.dart';

void main() {
  Future<void> pumpLayout(WidgetTester tester, {required double width}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MasterDetailLayout(
            master: ColoredBox(
              key: ValueKey('master-content'),
              color: Colors.blue,
            ),
            detail: ColoredBox(
              key: ValueKey('detail-content'),
              color: Colors.green,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('desktop layout uses the default 20% master ratio', (
    tester,
  ) async {
    await pumpLayout(tester, width: 1600);

    final masterSize = tester.getSize(
      find.byKey(const ValueKey('master-pane')),
    );
    final detailSize = tester.getSize(
      find.byKey(const ValueKey('detail-content')),
    );

    expect(masterSize.width, closeTo(320, 0.1));
    expect(detailSize.width, greaterThanOrEqualTo(400));
  });

  testWidgets(
    'desktop layout keeps the absolute minimum width near tablet size',
    (tester) async {
      await pumpLayout(tester, width: 1000);

      final masterSize = tester.getSize(
        find.byKey(const ValueKey('master-pane')),
      );
      final detailSize = tester.getSize(
        find.byKey(const ValueKey('detail-content')),
      );

      expect(masterSize.width, closeTo(240, 0.1));
      expect(detailSize.width, greaterThanOrEqualTo(400));
    },
  );

  testWidgets('narrow windows stay single pane', (tester) async {
    await pumpLayout(tester, width: 760);

    final masterSize = tester.getSize(
      find.byKey(const ValueKey('master-pane')),
    );
    expect(masterSize.width, closeTo(760, 0.1));
    expect(find.byKey(const ValueKey('detail-content')), findsNothing);
  });

  testWidgets('user resize sticks across window width changes', (tester) async {
    await pumpLayout(tester, width: 1600);

    // 初始：1600 * 0.2 = 320
    var masterSize = tester.getSize(find.byKey(const ValueKey('master-pane')));
    expect(masterSize.width, closeTo(320, 0.1));

    // 用户向右拖动 24 像素，master 调整到 344
    await tester.timedDrag(
      find.byType(DraggableDivider),
      const Offset(24, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pump();

    masterSize = tester.getSize(find.byKey(const ValueKey('master-pane')));
    expect(masterSize.width, closeTo(344, 1));

    // 缩小窗口到 1200，用户设定的 344 仍在合法范围内，应当保持
    tester.view.physicalSize = const Size(1200, 800);
    await tester.pump();

    masterSize = tester.getSize(find.byKey(const ValueKey('master-pane')));
    expect(masterSize.width, closeTo(344, 1));
  });
}
