import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/following_feed.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/following_feed_provider.dart';

FollowingPost post(int id) => FollowingPost(
  id: id,
  topicId: 7,
  postNumber: id,
  createdAtRaw: '2026-11-17T00:00:0$id.123456Z',
  title: '话题',
  author: TopicUser(id: 1, username: 'alice', avatarTemplate: ''),
);
FollowingFeedResponse page(List<int> ids, {bool more = true}) =>
    FollowingFeedResponse(posts: ids.map(post).toList(), hasMore: more);

void main() {
  test('游标使用原始时间，重复帖子去重，失败后从同一游标重试', () async {
    final cursors = <String?>[];
    var fail = true;
    final notifier = FollowingFeedNotifier((cursor) async {
      cursors.add(cursor);
      if (cursor == null) return page([3, 2]);
      if (fail) {
        fail = false;
        throw StateError('offline');
      }
      return page([2, 1], more: false);
    });
    addTearDown(notifier.dispose);
    await notifier.refresh();
    await notifier.loadMore();
    expect(notifier.state.posts.map((p) => p.id), [3, 2]);
    expect(notifier.state.moreError, isNotNull);
    await notifier.loadMore();
    expect(cursors, [null, post(2).createdAtRaw, post(2).createdAtRaw]);
    expect(notifier.state.posts.map((p) => p.id), [3, 2, 1]);
    expect(notifier.state.hasMore, false);
  });

  test('刷新覆盖正在进行的旧分页，旧响应不能污染新结果', () async {
    final pending = Completer<FollowingFeedResponse>();
    var first = true;
    final notifier = FollowingFeedNotifier((cursor) async {
      if (cursor != null) return pending.future;
      if (first) {
        first = false;
        return page([2]);
      }
      return page([4, 3]);
    });
    addTearDown(notifier.dispose);
    await notifier.refresh();
    final loading = notifier.loadMore();
    await notifier.refresh();
    pending.complete(page([1]));
    await loading;
    expect(notifier.state.posts.map((p) => p.id), [4, 3]);
  });

  test('重复游标停止分页，空响应不继续请求', () async {
    var calls = 0;
    final notifier = FollowingFeedNotifier((_) async {
      calls++;
      return page([1]);
    });
    addTearDown(notifier.dispose);
    await notifier.refresh();
    await notifier.loadMore();
    await notifier.loadMore();
    expect(calls, 2);
    expect(notifier.state.hasMore, false);
  });

  test('页面销毁后忽略返回结果', () async {
    final pending = Completer<FollowingFeedResponse>();
    final notifier = FollowingFeedNotifier((_) => pending.future);
    final loading = notifier.refresh();
    notifier.dispose();
    pending.complete(page([1]));
    await loading;
  });

  test('解析服务端嵌套用户、话题、分类及微秒时间', () {
    final response = FollowingFeedResponse.fromJson({
      'posts': [
        {
          'id': 10,
          'topic_id': 7,
          'post_number': 3,
          'created_at': '2026-11-17T00:00:00.123456Z',
          'user': {'id': 2, 'username': 'alice', 'avatar_template': '/avatar'},
          'topic': {'id': 7, 'title': '讨论', 'category_id': 12},
          'excerpt': '<p>回复</p>',
        },
      ],
      '__rest_serializer': '1',
      'extras': {'has_more': true},
    });
    expect(response.hasMore, true);
    expect(response.posts.single.author.username, 'alice');
    expect(response.posts.single.title, '讨论');
    expect(response.posts.single.categoryId, 12);
    expect(
      response.posts.single.createdAt!.microsecondsSinceEpoch,
      DateTime.utc(2026, 11, 17, 0, 0, 0, 123, 456).microsecondsSinceEpoch,
    );
    expect(response.posts.single.createdAtRaw, '2026-11-17T00:00:00.123456Z');
  });
}
