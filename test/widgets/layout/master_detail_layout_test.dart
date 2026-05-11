import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  testWidgets('desktop layout widens the master pane on wide windows', (
    tester,
  ) async {
    await pumpLayout(tester, width: 1600);

    final masterSize = tester.getSize(
      find.byKey(const ValueKey('master-pane')),
    );
    final detailSize = tester.getSize(
      find.byKey(const ValueKey('detail-content')),
    );

    expect(masterSize.width, closeTo(448, 0.1));
    expect(detailSize.width, greaterThanOrEqualTo(400));
  });

  testWidgets(
    'desktop layout keeps the existing compact width near tablet size',
    (tester) async {
      await pumpLayout(tester, width: 1000);

      final masterSize = tester.getSize(
        find.byKey(const ValueKey('master-pane')),
      );
      final detailSize = tester.getSize(
        find.byKey(const ValueKey('detail-content')),
      );

      expect(masterSize.width, closeTo(380, 0.1));
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
}
