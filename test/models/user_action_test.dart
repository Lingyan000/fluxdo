import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/user_action.dart';

void main() {
  final post = {
    'id': 99,
    'post_id': 99,
    'topic_id': 8,
    'topic_title': '一个话题',
    'post_number': 12,
    'url': '/t/example/8/12',
    'user_id': 2,
    'username': 'author',
    'name': '原帖作者',
    'avatar_template': '/author/{size}.png',
    'category_id': 42,
    'excerpt': '<p>正文 &amp; 表情</p>',
    'created_at': '2026-11-11T08:00:00Z',
  };

  test('点赞与被赞保留原帖作者，不以操作人覆盖作者', () {
    for (final type in [UserActionType.like, UserActionType.wasLiked]) {
      final action = UserAction.fromJson({
        ...post,
        'title': '一个话题',
        'action_type': type,
        'acting_user_id': 3,
        'acting_username': 'liker',
        'acting_avatar_template': '/liker/{size}.png',
      });
      expect(action.username, 'liker');
      expect(action.author?.username, 'author');
      expect(action.author?.id, 2);
      expect(action.author?.name, '原帖作者');
      expect(action.author?.avatarTemplate, '/author/{size}.png');
      expect(
        action.actingAt?.isAtSameMomentAs(DateTime.utc(2026, 11, 11, 8)),
        isTrue,
      );
    }
  });

  test('回应使用嵌套帖子的作者和分类，保留表情与楼层', () {
    final reaction = UserReaction.fromJson({
      'id': 1,
      'post_id': 99,
      'user': {'id': 3, 'username': 'reactor'},
      'post': {
        ...post,
        'user': {
          'id': 2,
          'username': 'author',
          'name': '原帖作者',
          'avatar_template': '/author/{size}.png',
        },
      },
      'reaction': {'reaction_value': 'heart'},
    });
    expect(reaction.author?.username, 'author');
    expect(reaction.author?.id, 2);
    expect(reaction.categoryId, 42);
    expect(reaction.postNumber, 12);
    expect(reaction.reactionValue, 'heart');
  });

  test('Boost 原帖与留言分别保留，已解决记录保留回答作者', () {
    final boost = UserBoost.fromJson({
      'id': 1,
      'post': post,
      'cooked': '<p>我赞同这段内容</p>',
    });
    expect(boost.author?.username, 'author');
    expect(boost.categoryId, 42);
    expect(boost.postNumber, 12);
    expect(boost.excerpt, post['excerpt']);
    expect(boost.cooked, '<p>我赞同这段内容</p>');
    final solved = SolvedPost.fromJson(post);
    expect(solved.author?.username, 'author');
    expect(solved.categoryId, 42);
    expect(
      solved.createdAt?.isAtSameMomentAs(DateTime.utc(2026, 11, 11, 8)),
      isTrue,
    );
  });

  test('未提供作者的旧响应不把当前用户冒充原帖作者', () {
    expect(UserBoost.fromJson({'id': 1}).author, isNull);
    expect(UserReaction.fromJson({'id': 1, 'post_id': 99}).author, isNull);
    expect(SolvedPost.fromJson({}).author, isNull);
    expect(
      UserAction.fromJson({'topic_id': 8, 'acting_username': 'liker'}).author,
      isNull,
    );
  });
}
