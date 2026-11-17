import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/markdown_block_format.dart';

void main() {
  test('纯文字、表情与行内格式不算块级格式', () {
    for (final text in [
      '',
      '我觉得可以 :smile:',
      '**加粗** 和 [链接](https://linux.do) 以及 `行内代码`',
      '比较 a > b 的情况',
      '- 列表项\n- 另一项',
    ]) {
      expect(markdownHasBlockFormatting(text), isFalse, reason: text);
    }
  });

  test('识别各类块级格式', () {
    for (final text in [
      '[quote="a, post:2, topic:1"]\nhi\n[/quote]',
      '[details="展开"]\n内容\n[/details]',
      '```dart\nvoid main() {}\n```',
      '![image|690x388](upload://abc.png)',
      '| a | b |\n| --- | --- |\n| 1 | 2 |',
      '> 引用一段话',
      '## 标题',
      '<div>html</div>',
    ]) {
      expect(markdownHasBlockFormatting(text), isTrue, reason: text);
    }
  });
}
