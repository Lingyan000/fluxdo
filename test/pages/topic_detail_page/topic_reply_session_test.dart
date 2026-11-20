import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/pages/topic_detail_page/controllers/topic_reply_session.dart';

void main() {
  TextEditingValue at(String text, [int? offset]) => TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: offset ?? text.length),
  );

  const quote = '[quote="a, post:2, topic:1"]\nhi\n[/quote]';

  test('空编辑器直接插入引用，后留空行，光标在其后', () {
    final v = TopicReplySession.withQuoteInserted(at(''), quote);
    expect(v.text, '$quote\n\n');
    expect(v.selection.baseOffset, v.text.length);
  });

  test('正文末尾插入时与正文隔一个空行', () {
    final v = TopicReplySession.withQuoteInserted(at('我觉得'), quote);
    expect(v.text, '我觉得\n\n$quote\n\n');
  });

  test('已有换行只补足到一个空行', () {
    expect(
      TopicReplySession.withQuoteInserted(at('我觉得\n'), quote).text,
      '我觉得\n\n$quote\n\n',
    );
    expect(
      TopicReplySession.withQuoteInserted(at('我觉得\n\n'), quote).text,
      '我觉得\n\n$quote\n\n',
    );
  });

  test('光标在中间时插在光标处，后文保留', () {
    final v = TopicReplySession.withQuoteInserted(at('前文后文', 2), quote);
    expect(v.text, '前文\n\n$quote\n\n后文');
    expect(v.selection.baseOffset, '前文\n\n$quote\n\n'.length);
  });

  test('引用自身多余的尾部空白被收掉', () {
    final v = TopicReplySession.withQuoteInserted(at(''), '$quote\n\n\n');
    expect(v.text, '$quote\n\n');
  });
}
