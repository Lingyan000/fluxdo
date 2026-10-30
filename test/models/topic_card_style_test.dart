import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic_card_style.dart';
import 'package:fluxdo/models/topic.dart';

void main() {
  test('新用户、旧配置和恢复默认均不会自动展示或请求正文', () {
    for (final style in [
      TopicCardStyle.defaults,
      TopicCardStyle.fromJsonString(null),
      TopicCardStyle.fromJsonString('{"showAuthor":false}'),
      TopicCardStyle.fromJsonString('invalid'),
    ]) {
      expect(style.showExcerpt, isFalse);
      expect(style.showImages, isFalse);
      expect(style.allowExcerptFetch, isFalse);
    }
    final existing = TopicCardStyle.fromJsonString('{"showExcerpt":true}');
    expect(existing.showExcerpt, isTrue);
    expect(existing.allowExcerptFetch, isFalse);
  });

  test('旧配置的元信息、头像、字号设置原样保留', () {
    const legacy =
        '{"showAuthor":false,"showTags":false,"showReplies":false,"showLikes":false,"showViews":false,"avatarLayout":"column","titleFontSize":17,"animatedAvatar":false}';
    final migrated = TopicCardStyle.fromJsonString(legacy);
    expect(
      migrated,
      const TopicCardStyle(
        showAuthor: false,
        showTags: false,
        showReplies: false,
        showLikes: false,
        showViews: false,
        avatarLayout: TopicCardAvatarLayout.column,
        titleFontSize: 17,
        animatedAvatar: false,
      ),
    );
  });

  test('三个开关的所有组合独立持久化', () {
    for (var mask = 0; mask < 8; mask++) {
      final style = TopicCardStyle(
        showExcerpt: mask & 1 != 0,
        showImages: mask & 2 != 0,
        allowExcerptFetch: mask & 4 != 0,
      );
      expect(TopicCardStyle.fromJsonString(style.toJsonString()), style);
      expect(style.copyWith(showImages: !style.showImages), isNot(style));
    }

    final displayOnly = TopicCardStyle.defaults.copyWith(showExcerpt: true);
    final fetch = displayOnly.copyWith(allowExcerptFetch: true);
    expect(displayOnly.allowExcerptFetch, isFalse);
    expect(fetch, isNot(displayOnly));
    expect(TopicCardStyle.fromJsonString(fetch.toJsonString()), fetch);
    expect(fetch.copyWith(showExcerpt: false).showExcerpt, isFalse);
  });

  test('话题列表 image_url 解析后在已读状态更新中保留', () {
    final list = TopicListResponse.fromJson({
      'topic_list': {
        'topics': [
          {'id': 1, 'image_url': '/uploads/cover.jpg'},
        ],
      },
    });
    final topic = list.topics.single;
    expect(topic.imageUrl, '/uploads/cover.jpg');
    expect(topic.copyWith(unseen: false, unread: 0).imageUrl, topic.imageUrl);
    expect(Topic.fromJson({'id': 2}).imageUrl, isNull);
  });

  test('旧的八行配置收紧为三行', () {
    expect(TopicCardStyle.defaults.maxCollapsedLines, 3);
    expect(
      TopicCardStyle.fromJsonString('{"maxCollapsedLines":8}')
          .maxCollapsedLines,
      3,
    );
  });
}
