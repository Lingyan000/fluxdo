/// 手势光标:grapheme 移动纯函数 + 滑钮手势步进/选择开关。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/cursor_swipe_control.dart';

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

    // 开选择开关后左滑 → extend=true 且方向 -1
    calls.clear();
    await tester.tap(find.byKey(const ValueKey('cursor-select-toggle')));
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
}
