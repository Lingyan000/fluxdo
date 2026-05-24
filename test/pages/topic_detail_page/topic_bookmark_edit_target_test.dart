import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/topic_detail_page/topic_bookmark_edit_target.dart';

Post _post({
  required int id,
  required int postNumber,
  int? bookmarkId,
  String? bookmarkName,
}) {
  return Post(
    id: id,
    postNumber: postNumber,
    username: 'tester',
    avatarTemplate: '',
    createdAt: DateTime(2026, 5, 15),
    updatedAt: DateTime(2026, 5, 15),
    cooked: '<p>test</p>',
    postType: 1,
    replyCount: 0,
    likeCount: 0,
    replyToPostNumber: 0,
    canEdit: false,
    canDelete: false,
    canRecover: false,
    canWiki: false,
    linkCounts: const [],
    bookmarked: bookmarkId != null,
    bookmarkId: bookmarkId,
    bookmarkName: bookmarkName,
  );
}

TopicDetail _detail({
  bool bookmarked = true,
  int? bookmarkId,
  String? bookmarkName,
  List<Post> posts = const [],
  List<int> stream = const [],
}) {
  return TopicDetail(
    id: 1,
    title: 'Topic',
    slug: 'topic',
    postsCount: posts.length,
    postStream: PostStream(posts: posts, stream: stream),
    categoryId: 1,
    closed: false,
    archived: false,
    bookmarked: bookmarked,
    bookmarkId: bookmarkId,
    bookmarkName: bookmarkName,
  );
}

void main() {
  test('优先使用话题级书签作为编辑目标', () {
    final target = resolveTopicBookmarkEditTarget(
      detail: _detail(bookmarkId: 42, bookmarkName: 'topic-mark'),
    );

    expect(target, isNotNull);
    expect(target!.bookmarkId, 42);
    expect(target.source, TopicBookmarkTargetSource.topic);
    expect(target.initialName, 'topic-mark');
  });

  test('话题级 bookmarkId 缺失时会回退到书签页传入的书签上下文', () {
    final target = resolveTopicBookmarkEditTarget(
      detail: _detail(
        bookmarked: true,
        posts: [
          _post(id: 100, postNumber: 1),
        ],
        stream: const [100],
      ),
      fallbackBookmarkId: 222,
      fallbackBookmarkName: 'from-bookmarks',
      fallbackBookmarkableType: 'Post',
      scrollToPostNumber: 1,
    );

    expect(target, isNotNull);
    expect(target!.bookmarkId, 222);
    expect(target.source, TopicBookmarkTargetSource.routeFallback);
    expect(target.initialName, 'from-bookmarks');
    expect(target.bookmarkableType, 'Post');
  });

  test('指定 scrollToPostNumber 命中带书签的帖子时返回 loadedPost', () {
    final target = resolveTopicBookmarkEditTarget(
      detail: _detail(
        bookmarked: false,
        posts: [
          _post(id: 100, postNumber: 1),
          _post(id: 101, postNumber: 2, bookmarkId: 555, bookmarkName: 'p2'),
        ],
        stream: const [100, 101],
      ),
      scrollToPostNumber: 2,
    );

    expect(target, isNotNull);
    expect(target!.bookmarkId, 555);
    expect(target.source, TopicBookmarkTargetSource.loadedPost);
    expect(target.postId, 101);
    expect(target.bookmarkableType, 'Post');
  });

  test('话题已书签但 bookmarkId 缺失且无 scrollToPostNumber 时不会兜底到 post 书签', () {
    // M3 修复：避免把唯一已加载的 post 书签当成话题书签编辑目标，
    // 详见 lib/pages/topic_detail_page/topic_bookmark_edit_target.dart。
    final target = resolveTopicBookmarkEditTarget(
      detail: _detail(
        bookmarked: true,
        posts: [
          _post(id: 100, postNumber: 1),
          _post(id: 101, postNumber: 2, bookmarkId: 555, bookmarkName: 'p2'),
        ],
        stream: const [100, 101],
      ),
    );

    expect(target, isNull);
  });

  test('话题未书签且仅有唯一已加载的 post 书签时允许兜底', () {
    final target = resolveTopicBookmarkEditTarget(
      detail: _detail(
        bookmarked: false,
        posts: [
          _post(id: 100, postNumber: 1),
          _post(id: 101, postNumber: 2, bookmarkId: 555, bookmarkName: 'p2'),
        ],
        stream: const [100, 101],
      ),
    );

    expect(target, isNotNull);
    expect(target!.bookmarkId, 555);
    expect(target.source, TopicBookmarkTargetSource.loadedPost);
  });

  test('多个已加载 post 书签时返回 null，避免猜测', () {
    final target = resolveTopicBookmarkEditTarget(
      detail: _detail(
        bookmarked: false,
        posts: [
          _post(id: 100, postNumber: 1, bookmarkId: 333),
          _post(id: 101, postNumber: 2, bookmarkId: 555),
        ],
        stream: const [100, 101],
      ),
    );

    expect(target, isNull);
  });
}
