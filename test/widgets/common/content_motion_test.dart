import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(
    Widget child, {
    bool reduced = false,
    bool reduceMotion = false,
  }) => MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(disableAnimations: reduced, reduceMotion: reduceMotion),
      child: child!,
    ),
    home: Scaffold(body: child),
  );
  const empty = AppEmptyState(
    icon: Icon(Icons.inbox_outlined),
    title: 'empty',
    message: 'message',
  );
  double opacity(WidgetTester tester, String text) => tester
      .widget<Opacity>(
        find
            .ancestor(of: find.text(text), matching: find.byType(Opacity))
            .first,
      )
      .opacity;

  testWidgets('空态错峰淡入，完成后 rebuild 不重播', (tester) async {
    await tester.pumpWidget(host(empty));
    final before = tester.getSize(find.byType(AppEmptyState));
    expect(opacity(tester, 'empty'), 0);
    await tester.pump(const Duration(milliseconds: 180));
    expect(opacity(tester, 'empty'), greaterThan(opacity(tester, 'message')));
    expect(opacity(tester, 'empty'), lessThan(1));
    expect(tester.getSize(find.byType(AppEmptyState)), before);
    await tester.pumpAndSettle();
    expect(opacity(tester, 'empty'), 1);
    await tester.pumpWidget(
      host(
        const AppEmptyState(
          icon: Icon(Icons.inbox_outlined),
          title: 'empty',
          message: 'updated',
        ),
      ),
    );
    expect(opacity(tester, 'empty'), 1);
    expect(opacity(tester, 'updated'), 1);
  });

  testWidgets('减少动态效果或页面转场时直接呈现空态', (tester) async {
    await tester.pumpWidget(host(empty, reduced: true));
    expect(opacity(tester, 'empty'), 1);
    await tester.pumpWidget(
      host(const PageMotionScope(moving: true, child: empty)),
    );
    expect(opacity(tester, 'empty'), 1);
    await tester.pumpAndSettle();
  });

  testWidgets('iOS reduceMotion 独立启用时空态直接呈现，运行时切换也生效', (tester) async {
    await tester.pumpWidget(host(empty));
    expect(opacity(tester, 'empty'), 0);
    await tester.pumpWidget(host(empty, reduceMotion: true));
    expect(opacity(tester, 'empty'), 1);
    expect(opacity(tester, 'message'), 1);
    await tester.pumpAndSettle();
  });

  testWidgets('面板渐隐不改变高度，不抢点击和拖拽，滚动后标题固定', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    var taps = 0;
    var notifications = 0;
    final sheet = AppSheetScaffold(
      title: 'sheet title',
      expandToFill: true,
      contentPadding: EdgeInsets.zero,
      footer: const Text('footer'),
      child: ListView.builder(
        controller: scroll,
        itemExtent: 48,
        itemCount: 30,
        itemBuilder: (_, i) =>
            TextButton(onPressed: () => taps++, child: Text('row $i')),
      ),
    );
    await tester.pumpWidget(
      host(
        NotificationListener<ScrollNotification>(
          onNotification: (_) {
            notifications++;
            return false;
          },
          child: sheet,
        ),
      ),
    );
    final title = tester.getRect(find.text('sheet title'));
    final footer = tester.getRect(find.text('footer'));
    final size = tester.getSize(find.byType(ListView));
    await tester.tap(find.text('row 0'));
    expect(taps, 1);
    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    expect(notifications, greaterThan(0));
    expect(tester.getRect(find.text('sheet title')), title);
    expect(tester.getRect(find.text('footer')), footer);
    expect(tester.getSize(find.byType(ListView)), size);
    expect(tester.takeException(), isNull);
  });

  testWidgets('固定工具栏下的滚动内容只在自己的顶部渐隐，回顶后恢复', (tester) async {
    final capture = GlobalKey();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    const toolbar = ColoredBox(
      color: Colors.black,
      child: SizedBox(width: double.infinity, height: 40),
    );
    await tester.pumpWidget(
      host(
        RepaintBoundary(
          key: capture,
          child: AppSheetScaffold(
            title: '翻译',
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                toolbar,
                Flexible(
                  child: SingleChildScrollView(
                    controller: scroll,
                    child: const ColoredBox(
                      color: Colors.black,
                      child: SizedBox(width: double.infinity, height: 1500),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byKey(capture));
    final headerY = (tester.getTopLeft(find.byWidget(toolbar)) - origin).dy;
    final viewport = tester
        .getRect(find.byType(SingleChildScrollView))
        .shift(-origin);
    // 在同一条竖线上取样：固定工具栏、正文渐变的起点和中间、渐变下方。
    Future<List<int>> sample() async => (await tester.runAsync(() async {
      final box =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await box.toImage();
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        return [
          for (final y in [
            headerY + 1,
            viewport.top + 1,
            viewport.top + 8,
            viewport.top + 20,
          ])
            bytes.getUint8(
              (y.floor() * image.width + viewport.center.dx.floor()) * 4,
            ),
        ];
      } finally {
        image.dispose();
      }
    }))!;

    expect(await sample(), [0, 0, 0, 0]);
    scroll.jumpTo(60);
    await tester.pumpAndSettle();
    final [header, top, middle, below] = await sample();
    expect(header, 0);
    expect(top, greaterThan(middle));
    expect(middle, greaterThan(0));
    expect(below, 0);
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(await sample(), [0, 0, 0, 0]);
  });

  testWidgets('普通面板保持内容高度，窄屏大字体/键盘下无溢出', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    await tester.pumpWidget(
      host(
        const Align(
          alignment: Alignment.bottomCenter,
          child: AppSheetScaffold(
            title: '标题',
            style: AppSheetStyle.card,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [Text('完整显示的内容说明'), TextField()],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final paragraph = tester.renderObject<RenderParagraph>(
      find.text('完整显示的内容说明'),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
  });
}
