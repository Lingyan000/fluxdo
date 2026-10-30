import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/draft.dart';

void main() {
  group('DraftData 标签兼容', () {
    test('兼容旧版字符串、新版对象及混合标签，不把对象转成显示文本', () {
      final data = DraftData.fromJson({
        'tags': [
          'linux',
          {'name': '纯水'},
          {'id': 42, 'name': '快问快答', 'slug': 'questions'},
        ],
      });

      expect(data.tags, ['linux', '纯水', '快问快答']);
      expect(jsonDecode(data.toJsonString())['tags'], ['linux', '纯水', '快问快答']);
      expect(DraftData.fromJson(data.toJson()).tags, data.tags);
    });

    test('忽略无效标签，保留草稿正文及有效标签', () {
      final data = DraftData.fromJson({
        'reply': '正文不能因为标签异常而丢失',
        'tags': [
          null,
          42,
          false,
          {},
          {'id': 1},
          {'name': null},
          {'name': 2},
          '',
          {'name': ''},
          {'name': '纯水'},
        ],
      });

      expect(data.reply, '正文不能因为标签异常而丢失');
      expect(data.tags, ['纯水']);
      expect(DraftData.fromJson({}).tags, isNull);
      expect(DraftData.fromJson({'tags': []}).tags, isEmpty);
    });

    for (final encoded in [false, true]) {
      test('草稿 API 的对象和 JSON 字符串入口均能恢复网页标签 encoded=$encoded', () {
        final payload = {
          'title': '网页草稿',
          'reply': '草稿正文',
          'tags': [
            {'name': '纯水'},
            {'id': 42, 'name': '快问快答'},
          ],
        };
        final draft = Draft.fromJson({
          'draft_key': 'new_topic',
          'data': encoded ? jsonEncode(payload) : payload,
        });

        expect(draft.data.tags, ['纯水', '快问快答']);
        expect(draft.data.reply, '草稿正文');
      });
    }

    test('网页对象标签与客户端字符串标签具有相同内容指纹', () {
      final web = DraftData.fromJson({
        'reply': '正文',
        'tags': [
          {'name': '纯水'},
          {'id': 42, 'name': '快问快答'},
        ],
      });
      const app = DraftData(reply: '正文', tags: ['快问快答', '纯水']);

      expect(web.contentFingerprint, app.contentFingerprint);
    });
  });

  group('Draft', () {
    test('识别网页端带后缀的新话题草稿 key', () {
      expect(Draft.isNewTopicKey('new_topic'), isTrue);
      expect(Draft.isNewTopicKey('new_topic_9c3f4f'), isTrue);
      expect(Draft.isNewTopicKey('new_private_message'), isFalse);
      expect(Draft.isNewTopicKey('topic_123'), isFalse);
    });

    test('带后缀的新话题草稿会被解析为新话题草稿', () {
      final draft = Draft.fromJson({
        'draft_key': 'new_topic_9c3f4f',
        'draft_sequence': 3,
        'data': {
          'action': 'createTopic',
          'title': '测试网页端草稿',
          'reply': '这是从网页端保存的新话题草稿',
          'categoryId': 1,
          'tags': ['linux'],
          'archetypeId': 'regular',
        },
      });

      expect(draft.isNewTopicDraft, isTrue);
      expect(draft.sequence, 3);
      expect(draft.data.title, '测试网页端草稿');
      expect(draft.data.reply, '这是从网页端保存的新话题草稿');
      expect(draft.data.categoryId, 1);
      expect(draft.data.tags, ['linux']);
    });

    test('非 topic key 但 action 为 createTopic 时兜底识别为新话题草稿', () {
      final draft = Draft.fromJson({
        'draft_key': 'composer_draft_abc',
        'data': {'action': 'createTopic', 'title': '新话题'},
      });

      expect(draft.isNewTopicDraft, isTrue);
    });

    test('私信和回复草稿不会被误判为新话题草稿', () {
      final privateMessageDraft = Draft.fromJson({
        'draft_key': 'new_private_message',
        'data': {'action': 'privateMessage', 'title': '私信'},
      });
      final topicReplyDraft = Draft.fromJson({
        'draft_key': 'topic_123',
        'data': {'action': 'reply', 'reply': '回复内容'},
      });
      final postReplyDraft = Draft.fromJson({
        'draft_key': 'topic_123_post_4',
        'data': {'action': 'reply', 'replyToPostNumber': 4},
      });

      expect(privateMessageDraft.isNewTopicDraft, isFalse);
      expect(topicReplyDraft.isNewTopicDraft, isFalse);
      expect(postReplyDraft.isNewTopicDraft, isFalse);
    });
  });
}
