import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/nested_topic.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/utils/blocked_user_filter.dart';

void main() {
  group('BlockedUserFilter', () {
    test('用户名去重和匹配均不区分大小写', () {
      expect(
        BlockedUserFilter.sanitizeUsernames([' Alice ', '@alice', '', '@BOB']),
        ['Alice', 'BOB'],
      );

      final blocked = BlockedUserFilter.normalizedUsernames(['@Alice']);
      expect(BlockedUserFilter.isBlockedUsername('ALICE', blocked), isTrue);
      expect(BlockedUserFilter.isBlockedUsername('alice_2', blocked), isFalse);
    });

    test('只过滤楼主在名单中的话题', () {
      final blocked = BlockedUserFilter.normalizedUsernames(['alice']);
      final visible = BlockedUserFilter.visibleTopics([
        _topic(1, 'alice'),
        _topic(2, 'bob'),
      ], blocked);

      expect(visible.map((topic) => topic.id), [2]);
    });

    test('回复和 Boost 按发布者过滤', () {
      final blocked = BlockedUserFilter.normalizedUsernames(['alice']);
      final posts = [_post(1, 'alice'), _post(2, 'bob')];
      final boosts = [_boost(1, 'alice'), _boost(2, 'bob')];

      expect(
        BlockedUserFilter.visiblePosts(posts, blocked).map((post) => post.id),
        [2],
      );
      expect(
        BlockedUserFilter.visibleBoosts(
          boosts,
          blocked,
        ).map((boost) => boost.id),
        [2],
      );
    });

    test('树状回复会提升被屏蔽节点的可见子回复', () {
      final blocked = BlockedUserFilter.normalizedUsernames(['alice']);
      final child = NestedNode(post: _post(3, 'bob'));
      final hiddenParent = NestedNode(
        post: _post(2, 'alice'),
        children: [child],
      );
      final visible = BlockedUserFilter.visibleNestedNodes([
        hiddenParent,
      ], blocked);

      expect(visible, hasLength(1));
      expect(visible.single.post.username, 'bob');
    });
  });
}

Topic _topic(int id, String username) {
  final user = TopicUser(id: id, username: username, avatarTemplate: '');
  return Topic(
    id: id,
    title: 'topic $id',
    slug: 'topic-$id',
    postsCount: 1,
    replyCount: 0,
    views: 0,
    likeCount: 0,
    categoryId: '0',
    posters: [
      TopicPoster(
        userId: id,
        description: 'Original Poster',
        extras: '',
        user: user,
      ),
    ],
  );
}

Post _post(int id, String username) {
  final now = DateTime(2026, 1, 1);
  return Post(
    id: id,
    username: username,
    avatarTemplate: '',
    cooked: '',
    postNumber: id,
    postType: 1,
    updatedAt: now,
    createdAt: now,
    likeCount: 0,
    replyCount: 0,
  );
}

Boost _boost(int id, String username) {
  return Boost(
    id: id,
    cooked: '',
    user: BoostUser(id: id, username: username, avatarTemplate: ''),
  );
}
