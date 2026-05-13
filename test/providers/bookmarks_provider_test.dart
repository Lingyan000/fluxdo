import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/bookmarks/bookmarks_models.dart';
import 'package:fluxdo/providers/user_content_providers.dart';

Topic _bookmarkTopic({
  required int topicId,
  required int bookmarkId,
  String? bookmarkName,
}) {
  return Topic(
    id: topicId,
    title: 'Topic $topicId',
    slug: 'topic-$topicId',
    postsCount: 1,
    replyCount: 0,
    views: 0,
    likeCount: 0,
    categoryId: '1',
    bookmarkId: bookmarkId,
    bookmarkName: bookmarkName,
  );
}

Future<void> _flushAsync() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('本地更新书签元数据时允许清空书签名', () async {
    final container = ProviderContainer(
      overrides: [
        bookmarksPageLoaderProvider.overrideWithValue((page, limit) async {
          if (page > 0) {
            return TopicListResponse(topics: const []);
          }
          return TopicListResponse(
            topics: [
              _bookmarkTopic(
                topicId: 1,
                bookmarkId: 101,
                bookmarkName: 'image',
              ),
            ],
          );
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(bookmarksProvider.future);

    container.read(bookmarksProvider.notifier).updateBookmarkMeta(
      101,
      clearName: true,
    );

    expect(
      container.read(bookmarksProvider).requireValue.single.bookmarkName,
      isNull,
    );
  });

  test('全量补水失败时保留首页数据并暴露可重试状态', () async {
    var failSecondPage = true;
    final container = ProviderContainer(
      overrides: [
        bookmarksPageLoaderProvider.overrideWithValue((page, limit) async {
          switch (page) {
            case 0:
              return TopicListResponse(
                topics: [
                  _bookmarkTopic(
                    topicId: 1,
                    bookmarkId: 101,
                    bookmarkName: 'image',
                  ),
                ],
                moreTopicsUrl: '/u/test/bookmarks.json?page=1',
              );
            case 1:
              if (failSecondPage) {
                throw Exception('hydrate failed');
              }
              return TopicListResponse(
                topics: [
                  _bookmarkTopic(
                    topicId: 2,
                    bookmarkId: 102,
                    bookmarkName: 'beta',
                  ),
                ],
              );
            default:
              return TopicListResponse(topics: const []);
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(bookmarksProvider, (_, _) {});
    addTearDown(subscription.close);

    final firstPage = await container.read(bookmarksProvider.future);
    expect(firstPage.map((topic) => topic.id), [1]);

    await _flushAsync();

    final notifier = container.read(bookmarksProvider.notifier);
    expect(subscription.read().requireValue.map((topic) => topic.id), [1]);
    expect(notifier.isHydratingAll, isFalse);
    expect(notifier.isLoadMoreFailed, isTrue);
    expect(notifier.hasMore, isTrue);

    failSecondPage = false;
    notifier.retryLoadMore();

    await _flushAsync();

    expect(subscription.read().requireValue.map((topic) => topic.id), [1, 2]);
    expect(notifier.isHydratingAll, isFalse);
    expect(notifier.isLoadMoreFailed, isFalse);
    expect(notifier.hasMore, isFalse);
  });
}
