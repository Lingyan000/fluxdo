/// 手势光标:grapheme 移动纯函数 + 滑钮手势步进/选择开关。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/cursor_swipe_control.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('moveTextSelectionByGrapheme', () {
    TextEditingValue v(String text, int offset, [int? extent]) =>
        TextEditingValue(
          text: text,
          selection: extent == null
              ? TextSelection.collapsed(offset: offset)
              : TextSelection(baseOffset: offset, extentOffset: extent),
        );

    test('ASCII 左右各一步;边界钳住', () {
      expect(moveTextSelectionByGrapheme(v('abc', 1), 1, extend: false),
          const TextSelection.collapsed(offset: 2));
      expect(moveTextSelectionByGrapheme(v('abc', 1), -1, extend: false),
          const TextSelection.collapsed(offset: 0));
      expect(moveTextSelectionByGrapheme(v('abc', 0), -1, extend: false),
          isNull);
      expect(moveTextSelectionByGrapheme(v('abc', 3), 1, extend: false),
          isNull);
    });

    test('emoji 代理对/ZWJ 家庭簇一步跨整簇', () {
      const emoji = '😀'; // 2 code units
      expect(
        moveTextSelectionByGrapheme(v('a${emoji}b', 1), 1, extend: false),
        const TextSelection.collapsed(offset: 3),
      );
      expect(
        moveTextSelectionByGrapheme(v('a${emoji}b', 3), -1, extend: false),
        const TextSelection.collapsed(offset: 1),
      );
      const family = '👨‍👩‍👧‍👦'; // ZWJ 簇
      expect(
        moveTextSelectionByGrapheme(v('x${family}y', 1), 1, extend: false),
        TextSelection.collapsed(offset: 1 + family.length),
      );
    });

    test('扩选:只动 extent;非扩选有选区先折叠到方向侧', () {
      expect(
        moveTextSelectionByGrapheme(v('abcd', 1, 2), 1, extend: true),
        const TextSelection(baseOffset: 1, extentOffset: 3),
      );
      expect(
        moveTextSelectionByGrapheme(v('abcd', 1, 3), 1, extend: false),
        const TextSelection.collapsed(offset: 3),
      );
      expect(
        moveTextSelectionByGrapheme(v('abcd', 1, 3), -1, extend: false),
        const TextSelection.collapsed(offset: 1),
      );
    });
  });

  testWidgets('滑钮:拖动按步进回调;选择开关切 extend', (tester) async {
    final calls = <(int, bool)>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: CursorSwipeControl(
            onMove: (dir, {required extend}) => calls.add((dir, extend)),
          ),
        ),
      ),
    ));

    // 定位滑钮图标中心起手势;分段滑越过 touch slop 后按步进回调
    final knob =
        tester.getCenter(find.byKey(const ValueKey('cursor-swipe-knob')));
    final g = await tester.startGesture(knob);
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(12, 0));
      await tester.pump();
    }
    await g.up();
    await tester.pump();
    expect(calls.length, greaterThanOrEqualTo(3), reason: '72px越slop后≥3步');
    expect(calls.every((c) => c.$1 == 1 && c.$2 == false), isTrue);

    // 单击滑钮切换选择模式后左滑 → extend=true 且方向 -1
    calls.clear();
    await tester.tap(find.byKey(const ValueKey('cursor-swipe-knob')));
    await tester.pump();
    final g2 = await tester.startGesture(knob);
    for (var i = 0; i < 5; i++) {
      await g2.moveBy(const Offset(-12, 0));
      await tester.pump();
    }
    await g2.up();
    await tester.pump();
    expect(calls.length, greaterThanOrEqualTo(2));
    expect(calls.every((c) => c.$1 == -1 && c.$2 == true), isTrue);
  });

  testWidgets('指针模式:start 成功透传二维 delta;start 拒绝则忽略拖动',
      (tester) async {
    var startCalls = 0;
    var allowStart = true;
    final moves = <Offset>[];
    var ends = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: CursorSwipeControl(
            onPointerStart: ({required extend}) {
              startCalls++;
              return allowStart;
            },
            onPointerMove: moves.add,
            onPointerEnd: () => ends++,
          ),
        ),
      ),
    ));
    final knob =
        tester.getCenter(find.byKey(const ValueKey('cursor-swipe-knob')));

    final g = await tester.startGesture(knob);
    await g.moveBy(const Offset(30, 20));
    await tester.pump();
    await g.moveBy(const Offset(-10, 15));
    await tester.pump();
    await g.up();
    await tester.pump();
    expect(startCalls, 1);
    expect(moves, isNotEmpty, reason: '二维 delta 透传');
    expect(moves.any((d) => d.dy != 0), isTrue, reason: '垂直分量保留');
    expect(ends, 1);

    // start 拒绝(编辑器无光标):move/end 不再回调
    allowStart = false;
    moves.clear();
    ends = 0;
    final g2 = await tester.startGesture(knob);
    await g2.moveBy(const Offset(30, 0));
    await tester.pump();
    await g2.up();
    await tester.pump();
    expect(moves, isEmpty);
    expect(ends, 0);
  });

  testWidgets('按下即独占:外层水平拖动(左滑预览类)抢不走滑钮手势',
      (tester) async {
    var outerDrags = 0;
    final calls = <(int, bool)>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (_) => outerDrags++,
          child: Center(
            child: CursorSwipeControl(
              onMove: (dir, {required extend}) => calls.add((dir, extend)),
            ),
          ),
        ),
      ),
    ));
    final knob =
        tester.getCenter(find.byKey(const ValueKey('cursor-swipe-knob')));
    final g = await tester.startGesture(knob);
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(-12, 0));
      await tester.pump();
    }
    await g.up();
    await tester.pump();
    expect(outerDrags, 0, reason: '外层水平手势颗粒无收');
    expect(calls, isNotEmpty, reason: '滑钮步进正常');
    expect(calls.every((c) => c.$1 == -1), isTrue);
  });

  testWidgets('首次按下出内联提示,拖动即收,额度耗尽不再出', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final calls = <(int, bool)>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: CursorSwipeControl(
            onMove: (dir, {required extend}) => calls.add((dir, extend)),
          ),
        ),
      ),
    ));
    await tester.pump(); // prefs 异步加载
    final knob =
        tester.getCenter(find.byKey(const ValueKey('cursor-swipe-knob')));
    const moveHint = '滑动移动光标 · 单击切换选择';

    // 第 1 次按下:提示出现;越过阈值拖动即收
    final g = await tester.startGesture(knob);
    await tester.pump();
    expect(find.text(moveHint), findsOneWidget);
    await g.moveBy(const Offset(20, 0));
    await tester.pump();
    expect(find.text(moveHint), findsNothing, reason: '开始拖动教学即收');
    await g.up();
    await tester.pump();

    // 第 2、3 次按放(耗尽额度 3 次)
    for (var i = 0; i < 2; i++) {
      final gi = await tester.startGesture(knob);
      await tester.pump();
      expect(find.text(moveHint), findsOneWidget);
      await gi.up();
      await tester.pump();
      // 单击切换了选择模式:切回,顺带收选择提示
      await tester.pump(const Duration(seconds: 2));
    }

    // 第 4 次:额度耗尽,不再出
    final g4 = await tester.startGesture(knob);
    await tester.pump();
    expect(find.text(moveHint), findsNothing, reason: '3 次后永久收声');
    await g4.up();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('单击切入选择模式时出选择提示并自动淡出', (tester) async {
    SharedPreferences.setMockInitialValues(const {
      'cursor_swipe_hint_move_left': 0, // 移动提示已耗尽,只验选择提示
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: CursorSwipeControl(
            onMove: (dir, {required extend}) {},
          ),
        ),
      ),
    ));
    await tester.pump();
    const selectHint = '选择模式:滑动即选择文本';

    await tester.tap(find.byKey(const ValueKey('cursor-swipe-knob')));
    await tester.pump();
    expect(find.text(selectHint), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text(selectHint), findsNothing, reason: '1.8s 自动淡出');
  });
}
