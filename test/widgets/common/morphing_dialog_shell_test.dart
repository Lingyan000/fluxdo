import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/morphing_dialog_anchor.dart';
import 'package:fluxdo/widgets/common/morphing_dialog_shell.dart';

const _anchor = Rect.fromLTWH(20, 400, 360, 78);
final _shell = find.byKey(const ValueKey('morphing-shell'));

Widget _app(
  Animation<double> animation, {
  double height = 160,
  MediaQueryData? media,
  VoidCallback? onTap,
}) => MaterialApp(
  home: MediaQuery(
    data: media ?? const MediaQueryData(size: Size(800, 600)),
    child: Scaffold(
      body: MorphingDialogShell(
        animation: animation,
        anchorRect: _anchor,
        child: GestureDetector(
          onTap: onTap,
          child: SizedBox(
            key: const ValueKey('body'),
            height: height,
            child: const ColoredBox(color: Colors.blue),
          ),
        ),
      ),
    ),
  ),
);

AnimationController _controller(WidgetTester tester, {double value = 0}) {
  final controller = AnimationController(
    vsync: tester,
    value: value,
    duration: MorphingDialogShell.enterDuration,
    reverseDuration: MorphingDialogShell.exitDuration,
  );
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  testWidgets('首帧贴合来源，展开没有过冲，正文落位后可交互', (tester) async {
    final controller = _controller(tester);
    var taps = 0;
    await tester.pumpWidget(_app(controller, onTap: () => taps++));
    expect(tester.getRect(_shell), _anchor);

    controller.forward();
    await tester.pump();
    for (var frame = 0; frame < 28; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final rect = tester.getRect(_shell);
      expect(rect.width, inInclusiveRange(_anchor.width, 500));
      expect(rect.height, inInclusiveRange(_anchor.height, 160));
      if (frame == 5) {
        await tester.tapAt(rect.center);
        expect(taps, 0);
      }
    }
    expect(tester.getRect(_shell), const Rect.fromLTWH(150, 220, 500, 160));
    expect(
      tester.getRect(find.byKey(const ValueKey('body'))),
      tester.getRect(_shell),
    );
    await tester.tapAt(tester.getCenter(_shell));
    expect(taps, 1);
  });

  testWidgets('异步正文改变高度时连续伸展，不跳高也不留下空白', (tester) async {
    final controller = _controller(tester, value: 1);
    await tester.pumpWidget(_app(controller, height: 120));
    final before = tester.getRect(_shell);
    await tester.pumpWidget(_app(controller, height: 360));
    expect(tester.getRect(_shell), before);
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getSize(_shell).height, inExclusiveRange(120, 360));
    await tester.pumpAndSettle();
    expect(tester.getSize(_shell).height, 360);
    expect(
      tester.getRect(find.byKey(const ValueKey('body'))),
      tester.getRect(_shell),
    );
  });

  testWidgets('展开中关闭从当前画面收回，返回途中正文变化不改变轨迹', (tester) async {
    final controller = _controller(tester);
    await tester.pumpWidget(_app(controller));
    controller.forward();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    final beforeClose = tester.getRect(_shell);
    controller.reverse();
    await tester.pumpWidget(_app(controller, height: 400));
    expect(tester.getRect(_shell), beforeClose);
    var previousDistance = (beforeClose.center - _anchor.center).distance;
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final current = tester.getRect(_shell);
      final distance = (current.center - _anchor.center).distance;
      expect(distance, lessThanOrEqualTo(previousDistance + 0.01));
      expect(current.height, lessThanOrEqualTo(beforeClose.height));
      previousDistance = distance;
    }
    expect(tester.getRect(_shell), _anchor);
  });

  testWidgets('窄窗口和键盘出现后，内容仍在安全区域内', (tester) async {
    tester.view.physicalSize = const Size(280, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _controller(tester, value: 1);
    const media = MediaQueryData(
      size: Size(280, 700),
      padding: EdgeInsets.only(top: 28, bottom: 20),
      viewPadding: EdgeInsets.only(top: 28, bottom: 20),
    );
    await tester.pumpWidget(_app(controller, height: 700, media: media));
    expect(tester.getSize(_shell).width, 248);
    await tester.pumpWidget(
      _app(
        controller,
        height: 700,
        media: media.copyWith(viewInsets: const EdgeInsets.only(bottom: 320)),
      ),
    );
    await tester.pumpAndSettle();
    final rect = tester.getRect(_shell);
    expect(rect.left, greaterThanOrEqualTo(16));
    expect(rect.right, lessThanOrEqualTo(264));
    expect(rect.top, greaterThanOrEqualTo(44));
    expect(rect.bottom, lessThanOrEqualTo(364));
    expect(tester.takeException(), isNull);
  });

  testWidgets('减少动态效果时直接显示最终布局', (tester) async {
    final controller = _controller(tester);
    await tester.pumpWidget(
      _app(
        controller,
        media: const MediaQueryData(
          size: Size(800, 600),
          disableAnimations: true,
        ),
      ),
    );
    expect(tester.getRect(_shell), const Rect.fromLTWH(150, 220, 500, 160));
    await tester.pumpWidget(
      _app(
        controller,
        height: 300,
        media: const MediaQueryData(
          size: Size(800, 600),
          disableAnimations: true,
        ),
      ),
    );
    await tester.pump();
    expect(tester.getSize(_shell).height, 300);
  });

  testWidgets('快照只截取卡身，隐藏来源时保持原有列表布局', (tester) async {
    late BuildContext cardContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              child: MorphingDialogAnchor(
                builder: (context) {
                  cardContext = context;
                  return const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: SizedBox(
                      key: ValueKey('card'),
                      height: 78,
                      child: ColoredBox(color: Colors.green),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    final card = find.byKey(const ValueKey('card'));
    final original = tester.getRect(card);
    final snapshot = MorphingDialogAnchor.capture(cardContext);
    expect(snapshot, isNotNull);
    addTearDown(snapshot!.dispose);
    expect(snapshot.rect, original);
    expect(
      snapshot.image.height / snapshot.image.width,
      closeTo(78 / 360, 0.01),
    );
    await tester.pump();
    expect(tester.getRect(card), original);
    expect(
      tester
          .widget<Opacity>(
            find.ancestor(of: card, matching: find.byType(Opacity)).first,
          )
          .opacity,
      0,
    );
    snapshot.restore();
    await tester.pump();
    expect(
      tester
          .widget<Opacity>(
            find.ancestor(of: card, matching: find.byType(Opacity)).first,
          )
          .opacity,
      1,
    );
  });

  testWidgets('被滚动窗口裁掉的卡片部分不进入起始快照', (tester) async {
    late BuildContext cardContext;
    final scroll = ScrollController(initialScrollOffset: 40);
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              key: const ValueKey('viewport'),
              width: 360,
              height: 200,
              child: ListView(
                controller: scroll,
                children: [
                  MorphingDialogAnchor(
                    builder: (context) {
                      cardContext = context;
                      return const SizedBox(
                        height: 108,
                        child: ColoredBox(color: Colors.green),
                      );
                    },
                  ),
                  const SizedBox(height: 600),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final snapshot = MorphingDialogAnchor.capture(cardContext);
    expect(snapshot, isNotNull);
    expect(
      snapshot!.rect.top,
      tester.getTopLeft(find.byKey(const ValueKey('viewport'))).dy,
    );
    expect(snapshot.rect.height, 60);
    snapshot.dispose();
    await tester.pump();
  });
}
