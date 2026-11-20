import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/sticker.dart';
import 'package:fluxdo/widgets/markdown_editor/sticker_preview.dart';
import 'package:material_ui/material_ui.dart';

StickerItem _sticker(String id) => StickerItem(
  id: id,
  name: 'name-$id',
  url: 'https://sticker-preview.invalid/$id.png',
  width: 100,
  height: 100,
  groupId: 'g',
);

void main() {
  late List<String> selected;
  late List<StickerPreviewTarget> menuTargets;

  StickerPreviewController controllerWithMenu() => StickerPreviewController(
    actionsBuilder: (target) {
      menuTargets.add(target);
      return [
        StickerPreviewAction(
          icon: Icons.star,
          label: '操作-${target.sticker.id}',
          onSelected: () => selected.add(target.sticker.id),
        ),
      ];
    },
  );

  Future<void> pumpCells(
    WidgetTester tester,
    StickerPreviewController controller, {
    VoidCallback? onTap,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final id in ['a', 'b'])
                  SizedBox.square(
                    key: ValueKey('cell-$id'),
                    dimension: 80,
                    child: StickerGridCell(
                      sticker: _sticker(id),
                      preview: controller,
                      origin: #recent,
                      onTap: onTap,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  setUp(() {
    selected = [];
    menuTargets = [];
  });

  testWidgets('长按停留后弹出菜单,松手后菜单保留,点选执行并关闭', (tester) async {
    final controller = controllerWithMenu();
    addTearDown(controller.dispose);
    await pumpCells(tester, controller, onTap: () {});

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('cell-a'))),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect(find.text('name-a'), findsOneWidget, reason: '长按出现预览');
    expect(find.text('操作-a'), findsNothing);

    await tester.pump(StickerPreviewController.menuDelay);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('操作-a'), findsOneWidget);
    expect(menuTargets.single.origin, #recent);

    await gesture.up();
    await tester.pump();
    expect(find.text('操作-a'), findsOneWidget, reason: '菜单出现后松手不收起');

    await tester.tap(find.text('操作-a'));
    await tester.pump();
    expect(selected, ['a']);
    expect(controller.isShowing, isFalse);
  });

  testWidgets('停留不足就松手:预览收起,不弹菜单', (tester) async {
    final controller = controllerWithMenu();
    addTearDown(controller.dispose);
    await pumpCells(tester, controller, onTap: () {});

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('cell-a'))),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pump(StickerPreviewController.menuDelay);

    expect(controller.isShowing, isFalse);
    expect(menuTargets, isEmpty);
  });

  testWidgets('滑到另一张表情重新计时,菜单针对新表情', (tester) async {
    final controller = controllerWithMenu();
    addTearDown(controller.dispose);
    await pumpCells(tester, controller, onTap: () {});

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('cell-a'))),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 1000));
    await gesture.moveTo(tester.getCenter(find.byKey(const ValueKey('cell-b'))));
    await tester.pump(const Duration(milliseconds: 1000));
    expect(menuTargets, isEmpty, reason: '切换后重新计时,还没到点');

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('操作-b'), findsOneWidget);
    await gesture.up();
  });

  testWidgets('右键直接弹出菜单,点空白处关闭', (tester) async {
    final controller = controllerWithMenu();
    addTearDown(controller.dispose);
    await pumpCells(tester, controller, onTap: () {});

    await tester.tap(
      find.byKey(const ValueKey('cell-a')),
      buttons: kSecondaryButton,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('操作-a'), findsOneWidget);

    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(controller.isShowing, isFalse);
    expect(selected, isEmpty);
  });

  testWidgets('没有点按回调时点按显示固定预览,点任意处关闭', (tester) async {
    final controller = StickerPreviewController();
    addTearDown(controller.dispose);
    await pumpCells(tester, controller);

    await tester.tap(find.byKey(const ValueKey('cell-a')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('name-a'), findsOneWidget);

    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(controller.isShowing, isFalse);
  });
}
