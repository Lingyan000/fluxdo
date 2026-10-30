import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_object_toolbar.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_action_menu.dart';

void main() {
  const labels = [
    '在前面输入',
    '在后面输入',
    '查看',
    '图片尺寸',
    '替代文本',
    '加入网格',
    '复制',
    '剪切',
    '删除图片',
  ];

  for (final x in [400.0, 600.0, 1000.0]) {
    testWidgets('PC 窄菜单以更多按钮 x=$x 为锚点，不按预估宽度漂移', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final buttonKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (root) => Stack(
                children: [
                  Positioned(
                    left: x,
                    top: 280,
                    width: 40,
                    height: 40,
                    child: Builder(
                      key: buttonKey,
                      builder: (button) => IconButton(
                        icon: const Icon(Icons.more_horiz),
                        onPressed: () {
                          final box = button.findRenderObject()! as RenderBox;
                          showComposerActionMenu<int>(
                            context: root,
                            globalAnchorRect:
                                box.localToGlobal(Offset.zero) & box.size,
                            stayNearTrigger: true,
                            avoidRects: const [
                              Rect.fromLTWH(180, 300, 800, 700),
                              Rect.fromLTWH(180, 60, 450, 200),
                            ],
                            keepVisibleRect: const Rect.fromLTWH(
                              180,
                              300,
                              800,
                              700,
                            ),
                            items: [
                              for (var i = 0; i < 10; i++)
                                PopupMenuItem(
                                  value: i,
                                  height: 48,
                                  child: Text('操作 $i'),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final button = tester.getRect(find.byKey(buttonKey));
      await tester.tap(find.byKey(buttonKey));
      await tester.pumpAndSettle();
      final menu = tester.getRect(
        find.ancestor(
          of: find.text('操作 0'),
          matching: find.byType(SingleChildScrollView),
        ),
      );
      expect(menu.width, lessThan(280), reason: '覆盖实际菜单比预估宽度窄的情况');
      final expectedEdge = x + 20 > 600 ? button.right : button.left;
      expect(x + 20 > 600 ? menu.right : menu.left, closeTo(expectedEdge, 1));
      expect(menu.inflate(8).contains(button.center), isTrue);
      expect(find.text('操作 9').hitTestable(), findsOneWidget);
    });
  }

  Future<Rect> openMenu(
    WidgetTester tester, {
    required double top,
    double height = 800,
    double keyboard = 0,
    double textScale = 1,
    required ValueChanged<String> onAction,
  }) async {
    tester.view.physicalSize = Size(800, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            viewInsets: EdgeInsets.only(bottom: keyboard),
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: Scaffold(
          resizeToAvoidBottomInset: false,
          body: Stack(
            children: [
              Positioned(
                top: top,
                left: 40,
                width: 360,
                height: 48,
                child: ComposerObjectToolbar(
                  selection: ComposerObjectSelection(
                    label: '图片',
                    rect: const Rect.fromLTWH(40, 100, 300, 500),
                    dismiss: () {},
                    after: () {},
                    actions: [
                      for (final label in labels)
                        ComposerObjectAction(
                          label,
                          Icons.image_outlined,
                          () => onAction(label),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final anchor = tester.getRect(
      find.byKey(const ValueKey('composer-object-more')),
    );
    await tester.tap(find.byKey(const ValueKey('composer-object-more')));
    await tester.pumpAndSettle();
    return anchor;
  }

  for (final top in [96.0, 620.0, 360.0]) {
    testWidgets('悬浮操作条 top=$top：菜单完整展示，最后一项可直接点击', (tester) async {
      String? chosen;
      final anchor = await openMenu(
        tester,
        top: top,
        onAction: (value) => chosen = value,
      );
      final first = find.text(labels.first).hitTestable();
      final last = find.text(labels.last).hitTestable();
      expect(first, findsOneWidget);
      expect(last, findsOneWidget, reason: '下方还有空间时，不能把菜单挤成上方的一行半');
      expect(tester.getRect(first).top, greaterThanOrEqualTo(8));
      expect(tester.getRect(last).bottom, lessThanOrEqualTo(792));
      if (top == 96) {
        expect(tester.getRect(first).top, greaterThan(anchor.bottom));
      }
      if (top == 620) {
        expect(tester.getRect(last).bottom, lessThan(anchor.top));
      }
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(chosen, labels.last);
    });
  }

  testWidgets('键盘压缩可视区域：使用可视区域滚动，末项仍可操作', (tester) async {
    String? chosen;
    await openMenu(
      tester,
      top: 260,
      height: 700,
      keyboard: 320,
      textScale: 1.4,
      onAction: (value) => chosen = value,
    );
    final menuScroll = find.ancestor(
      of: find.text(labels.first),
      matching: find.byType(SingleChildScrollView),
    );
    expect(tester.getRect(menuScroll).top, greaterThanOrEqualTo(8));
    expect(tester.getRect(menuScroll).bottom, lessThanOrEqualTo(372));
    await tester.drag(menuScroll, const Offset(0, -400));
    await tester.pumpAndSettle();
    final last = find.text(labels.last).hitTestable();
    expect(last, findsOneWidget);
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(chosen, labels.last);
  });
}
