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
