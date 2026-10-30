import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/draft.dart';

void main() {
  test('网页端省略字段和客户端空值、默认原型表达相同内容', () {
    const web = DraftData(reply: '正文', action: 'reply');
    const app = DraftData(
      reply: '正文',
      title: '',
      action: 'reply',
      archetypeId: 'regular',
      tags: [],
      recipients: [],
      replyToPostNumber: 0,
    );
    expect(web.contentFingerprint, app.contentFingerprint);
  });
  test('标签和收件人顺序、时长不影响内容指纹，真实修改仍然不同', () {
    const data = DraftData(
      reply: '正文',
      title: '私信',
      action: 'privateMessage',
      tags: ['one', 'two'],
      recipients: ['alice', 'bob'],
    );
    final reordered = data.copyWith(
      tags: ['two', 'one'],
      recipients: ['bob', 'alice'],
      composerTime: 100,
      typingTime: 200,
    );
    expect(data.contentFingerprint, reordered.contentFingerprint);
    expect(
      data.contentFingerprint,
      isNot(data.copyWith(reply: '新正文').contentFingerprint),
    );
    expect(
      data.contentFingerprint,
      isNot(data.copyWith(recipients: ['alice']).contentFingerprint),
    );
  });
}
