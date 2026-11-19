import 'package:extended_image_lite/extended_image_lite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('翻页间距只出现在两张图之间，旋转后当前图仍居中', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    final controller = ExtendedPageController(pageSpacing: 50);
    addTearDown(controller.dispose);
    final pages = List.generate(
      3,
      (index) => SizedBox.expand(key: ValueKey(index)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ExtendedImageGesturePageView(
          controller: controller,
          children: pages,
        ),
      ),
    );
    expect(controller.position.maxScrollExtent, 900);
    expect(
      tester.getRect(find.byKey(const ValueKey(0))),
      const Rect.fromLTWH(0, 0, 400, 800),
    );

    controller.jumpTo(225);
    await tester.pump();
    final first = tester.getRect(find.byKey(const ValueKey(0)));
    final second = tester.getRect(find.byKey(const ValueKey(1)));
    expect(second.left - first.right, 50);
    controller.jumpToPage(1);
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(const ValueKey(1))).dx, 0);

    tester.view.physicalSize = const Size(800, 400);
    await tester.pump();
    expect(controller.page, 1, reason: '旋转的第一帧也应对齐当前图片');
    await tester.pumpAndSettle();
    expect(controller.page, 1);
    expect(tester.getTopLeft(find.byKey(const ValueKey(1))).dx, 0);
    expect(controller.position.maxScrollExtent, 1700);
    controller.jumpToPage(2);
    await tester.pump();
    expect(controller.position.pixels, controller.position.maxScrollExtent);
    expect(tester.getBottomRight(find.byKey(const ValueKey(2))).dx, 800);
  });
}
