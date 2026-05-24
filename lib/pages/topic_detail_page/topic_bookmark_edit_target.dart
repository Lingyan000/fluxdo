import '../../models/topic.dart';

enum TopicBookmarkTargetSource { topic, routeFallback, loadedPost }

class TopicBookmarkEditTarget {
  const TopicBookmarkEditTarget({
    required this.bookmarkId,
    required this.source,
    required this.bookmarkableType,
    this.initialName,
    this.initialReminderAt,
    this.postId,
    this.postNumber,
  });

  final int bookmarkId;
  final TopicBookmarkTargetSource source;
  final String bookmarkableType;
  final String? initialName;
  final DateTime? initialReminderAt;
  final int? postId;
  final int? postNumber;

  bool get isTopicBookmark => bookmarkableType == 'Topic';

  bool get isPostBookmark => bookmarkableType == 'Post';
}

TopicBookmarkEditTarget? resolveTopicBookmarkEditTarget({
  required TopicDetail detail,
  int? fallbackBookmarkId,
  String? fallbackBookmarkName,
  DateTime? fallbackBookmarkReminderAt,
  String? fallbackBookmarkableType,
  int? scrollToPostNumber,
}) {
  if (detail.bookmarkId != null) {
    return TopicBookmarkEditTarget(
      bookmarkId: detail.bookmarkId!,
      source: TopicBookmarkTargetSource.topic,
      bookmarkableType: 'Topic',
      initialName: detail.bookmarkName,
      initialReminderAt: detail.bookmarkReminderAt,
    );
  }

  if (fallbackBookmarkId != null) {
    return TopicBookmarkEditTarget(
      bookmarkId: fallbackBookmarkId,
      source: TopicBookmarkTargetSource.routeFallback,
      bookmarkableType: fallbackBookmarkableType ?? 'Topic',
      initialName: fallbackBookmarkName,
      initialReminderAt: fallbackBookmarkReminderAt,
      postId: _findPostByNumber(detail, scrollToPostNumber)?.id,
      postNumber: scrollToPostNumber,
    );
  }

  final targetPost = _findPostByNumber(detail, scrollToPostNumber);
  if (targetPost?.bookmarkId != null) {
    return TopicBookmarkEditTarget(
      bookmarkId: targetPost!.bookmarkId!,
      source: TopicBookmarkTargetSource.loadedPost,
      bookmarkableType: 'Post',
      initialName: targetPost.bookmarkName,
      initialReminderAt: targetPost.bookmarkReminderAt,
      postId: targetPost.id,
      postNumber: targetPost.postNumber,
    );
  }

  // 兜底分支：尝试用"已加载列表里唯一的 post 书签"作为编辑目标。
  //
  // 仅在以下两种场景启用，避免误把某个 post 书签当成话题级书签编辑：
  // 1. 调用方传入了 scrollToPostNumber，意味着用户来自帖子级入口；
  // 2. 话题本身未书签（!detail.bookmarked），此时唯一的 post 书签就是
  //    用户在该话题内可编辑的唯一对象。
  //
  // 当 detail.bookmarked == true 但 bookmarkId 异常缺失时，主动返回 null，
  // 让调用方走 "bookmark_id_missing" 错误分支，不去猜测目标。
  if (scrollToPostNumber != null || !detail.bookmarked) {
    final bookmarkedPosts = detail.postStream.posts
        .where((post) => post.bookmarkId != null)
        .toList(growable: false);
    if (bookmarkedPosts.length == 1) {
      final post = bookmarkedPosts.single;
      return TopicBookmarkEditTarget(
        bookmarkId: post.bookmarkId!,
        source: TopicBookmarkTargetSource.loadedPost,
        bookmarkableType: 'Post',
        initialName: post.bookmarkName,
        initialReminderAt: post.bookmarkReminderAt,
        postId: post.id,
        postNumber: post.postNumber,
      );
    }
  }

  return null;
}

Post? _findPostByNumber(TopicDetail detail, int? postNumber) {
  if (postNumber == null) {
    return null;
  }
  for (final post in detail.postStream.posts) {
    if (post.postNumber == postNumber) {
      return post;
    }
  }
  return null;
}
