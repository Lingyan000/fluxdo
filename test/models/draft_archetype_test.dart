/// 草稿的私信判据。
///
/// 用的是 `/drafts.json` 的**真实**返回（回复一个已有私信的草稿）。
/// 关键陷阱：`data.archetypeId` 是 `"regular"`，只有顶层 `archetype`
/// 才是 `"private_message"` —— 拿 data 里那个判私信必然失效。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/draft.dart';

void main() {
  // linux.do/drafts.json?offset=0&limit=30 实际返回的一行
  const rawPmReply = '''
{
  "excerpt": "aaaaaaaaaaaaa",
  "created_at": "2026-07-20T11:35:47.259Z",
  "draft_key": "topic_2612595",
  "sequence": 577,
  "avatar_template": "/user_avatar/linux.do/is_hp/{size}/836735_2.png",
  "data": "{\\"reply\\":\\"aaaaaaaaaaaaa\\",\\"action\\":\\"reply\\",\\"categoryId\\":null,\\"tags\\":[],\\"archetypeId\\":\\"regular\\",\\"composerTime\\":2911,\\"typingTime\\":400}",
  "topic_id": 2612595,
  "username": "is_hp",
  "title": "Let's chat!ver5.0",
  "archetype": "private_message"
}
''';

  test('回复已有私信:顶层 archetype 认私信,data.archetypeId 是 regular', () {
    final d = Draft.fromJson(jsonDecode(rawPmReply) as Map<String, dynamic>);

    expect(d.archetype, 'private_message');
    expect(d.isPrivateMessage, isTrue);
    expect(d.topicId, 2612595);

    // 这一条是**反例护栏**:说明为什么不能用 data.archetypeId
    expect(d.data.archetypeId, 'regular',
        reason: 'composer 原型对私信回复也是 regular —— 拿它判私信会漏判');
  });

  test('普通话题回复:不是私信', () {
    final d = Draft.fromJson({
      'draft_key': 'topic_123',
      'topic_id': 123,
      'data': '{"reply":"x","archetypeId":"regular"}',
      'archetype': 'regular',
    });
    expect(d.isPrivateMessage, isFalse);
  });

  test('顶层 archetype 缺失:不误判成私信', () {
    final d = Draft.fromJson({
      'draft_key': 'topic_123',
      'topic_id': 123,
      'data': '{"reply":"x"}',
    });
    expect(d.archetype, isNull);
    expect(d.isPrivateMessage, isFalse);
  });

  test('新建私信草稿:按 key 前缀也认', () {
    final d = Draft.fromJson({
      'draft_key': 'new_private_message_1737000000000',
      'data': '{"reply":"x","recipients":["a"]}',
    });
    expect(d.isPrivateMessage, isTrue);
  });
}
