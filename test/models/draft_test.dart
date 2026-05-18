import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/draft.dart';

void main() {
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
