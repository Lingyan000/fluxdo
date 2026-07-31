/// QuoteBuilder 引用头构建行为验证:显示名 fallback、`username:` 参数
/// 附加条件、引号字符剥离(对齐官方 buildQuote / stripQuotationMarks)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/quote_builder.dart';

void main() {
  test('无显示名:首字段为 username,不带 username: 参数', () {
    final quote = QuoteBuilder.build(
      markdown: '内容',
      displayName: null,
      username: 'sam',
      postNumber: 3,
      topicId: 42,
    );
    expect(quote, startsWith('[quote="sam, post:3, topic:42"]\n'));
    expect(quote, isNot(contains('username:')));
  });

  test('空串显示名等同无显示名', () {
    final quote = QuoteBuilder.build(
      markdown: '内容',
      displayName: '',
      username: 'sam',
      postNumber: 3,
      topicId: 42,
    );
    expect(quote, startsWith('[quote="sam, post:3, topic:42"]\n'));
  });

  test('有显示名:首字段为显示名,真实用户名放 username: 参数', () {
    final quote = QuoteBuilder.build(
      markdown: '内容',
      displayName: '张三',
      username: 'sam',
      postNumber: 3,
      topicId: 42,
    );
    expect(
      quote,
      startsWith('[quote="张三, post:3, topic:42, username:sam"]\n'),
    );
  });

  test('显示名里的引号字符被剥离,不产出非法 bbcode', () {
    final quote = QuoteBuilder.build(
      markdown: '内容',
      displayName: 'He said "hi" 和 “中文引号”',
      username: 'sam',
      postNumber: 3,
      topicId: 42,
    );
    expect(
      quote,
      startsWith('[quote="He said hi 和 中文引号, post:3, topic:42, username:sam"]\n'),
    );
  });

  test('显示名剥引号后为空:退回 username', () {
    final quote = QuoteBuilder.build(
      markdown: '内容',
      displayName: '"”',
      username: 'sam',
      postNumber: 3,
      topicId: 42,
    );
    expect(quote, startsWith('[quote="sam, post:3, topic:42"]\n'));
  });

  test('整体结构:内容 trim,尾部双换行', () {
    final quote = QuoteBuilder.build(
      markdown: '  内容  \n',
      displayName: null,
      username: 'sam',
      postNumber: 1,
      topicId: 2,
    );
    expect(quote, '[quote="sam, post:1, topic:2"]\n内容\n[/quote]\n\n');
  });
}
