import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/emoji_text.dart';
import 'package:fluxdo/widgets/common/emoji_text_editing_controller.dart';

void main() {
  test('文本值保持原始短代码', () {
    final c = EmojiTextEditingController(text: '你好 :smile: 世界');
    expect(c.text, '你好 :smile: 世界');
  });

  test('光标落进短代码中间时挪到短代码之后', () {
    final c = EmojiTextEditingController(text: 'a:smile:b');
    c.selection = const TextSelection.collapsed(offset: 4);
    expect(c.selection, const TextSelection.collapsed(offset: 8));
  });

  test('光标在短代码边界或普通文本中保持不动', () {
    final c = EmojiTextEditingController(text: 'a:smile:b');
    c.selection = const TextSelection.collapsed(offset: 1);
    expect(c.selection.baseOffset, 1);
    c.selection = const TextSelection.collapsed(offset: 8);
    expect(c.selection.baseOffset, 8);
    c.selection = const TextSelection.collapsed(offset: 9);
    expect(c.selection.baseOffset, 9);
  });

  testWidgets('输入法组字时组字区以外的表情仍显示成图片（不闪回短代码）', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      Builder(
        builder: (c) {
          context = c;
          return const SizedBox.shrink();
        },
      ),
    );
    final c = EmojiTextEditingController();
    // 正在组字的是末尾的 "ni"
    c.value = const TextEditingValue(
      text: ':smile: ni',
      selection: TextSelection.collapsed(offset: 10),
      composing: TextRange(start: 8, end: 10),
    );
    final span = c.buildTextSpan(
      context: context,
      style: const TextStyle(fontSize: 16),
      withComposing: true,
    );
    final children = span.children!;
    expect(children.whereType<WidgetSpan>(), hasLength(1));
    final composing = children.whereType<TextSpan>().last;
    expect(composing.text, 'ni');
    expect(composing.style?.decoration, TextDecoration.underline);
    // 渲染层长度与原文一致：光标与删除不错位
    expect(span.toPlainText(includePlaceholders: true).length, c.text.length);
  });

  test('表情补位字符不占宽度（否则表情之间会空出一大截）', () {
    const base = TextStyle(fontSize: 16, letterSpacing: 0.5);
    final painter = TextPainter(
      text: TextSpan(
        text: '\u2060' * 7,
        style: EmojiText.sourceLengthFillerStyle(base),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    expect(painter.width, lessThan(0.5));
    painter.dispose();
  });
}
