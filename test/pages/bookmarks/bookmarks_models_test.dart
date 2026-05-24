import 'package:flutter_test/flutter_test.dart';
import 'dart:async';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/bookmarks/bookmarks_models.dart';

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

void main() {
  test('?, ？ 与空白书签名一律归一为 null', () {
    expect(normalizeBookmarkName(null), isNull);
    expect(normalizeBookmarkName(''), isNull);
    expect(normalizeBookmarkName('   '), isNull);
    expect(normalizeBookmarkName('?'), isNull);
    expect(normalizeBookmarkName('？'), isNull);
    expect(normalizeBookmarkName('  ?  '), isNull);
    expect(normalizeBookmarkName('  ？  '), isNull);
    expect(normalizeBookmarkName(' image '), 'image');
  });

  test('Topic.fromJson 会将 ? / ？ 书签名清洗为 null', () {
    final dirtyNames = ['?', '？', '  ?  ', '   '];
    for (final name in dirtyNames) {
      final topic = Topic.fromJson({
        'id': 1,
        'title': 'Topic 1',
        'slug': 'topic-1',
        'posts_count': 1,
        'reply_count': 0,
        'views': 0,
        'like_count': 0,
        'category_id': 1,
        'bookmarked': true,
        'bookmarks': [
          {'id': 100, 'name': name},
        ],
      });
      expect(topic.bookmarkName, isNull, reason: '"$name" 应归一为 null');
    }
  });

  test('会按页拉取全部书签直到空页，并保留同主题的多个书签', () async {
    final requestedPages = <String>[];

    final topics = await loadAllBookmarkTopics(
      loadPage: (page, limit) async {
        requestedPages.add('$page:$limit');
        switch (page) {
          case 0:
            return TopicListResponse(
              topics: [
                _bookmarkTopic(
                  topicId: 1,
                  bookmarkId: 101,
                  bookmarkName: 'image',
                ),
                _bookmarkTopic(
                  topicId: 1,
                  bookmarkId: 102,
                  bookmarkName: 'image',
                ),
              ],
              moreTopicsUrl: '/u/test/bookmarks.json?page=1',
            );
          case 1:
            return TopicListResponse(
              topics: [
                _bookmarkTopic(
                  topicId: 2,
                  bookmarkId: 103,
                  bookmarkName: 'beta',
                ),
              ],
              moreTopicsUrl: '/u/test/bookmarks.json?page=2',
            );
          default:
            return TopicListResponse(topics: const [], moreTopicsUrl: null);
        }
      },
    );

    expect(requestedPages, [
      '0:$bookmarkRequestLimit',
      '1:$bookmarkRequestLimit',
      '2:$bookmarkRequestLimit',
    ]);
    expect(topics.map((topic) => topic.bookmarkId), [101, 102, 103]);
  });

  test('书签名称候选会去重并按数量降序输出', () {
    final suggestions = buildBookmarkNameSuggestions([
      _bookmarkTopic(topicId: 1, bookmarkId: 101, bookmarkName: 'image'),
      _bookmarkTopic(topicId: 2, bookmarkId: 102, bookmarkName: 'beta'),
      _bookmarkTopic(topicId: 3, bookmarkId: 103, bookmarkName: 'image'),
      _bookmarkTopic(topicId: 4, bookmarkId: 104, bookmarkName: '   '),
    ]);

    expect(suggestions, ['image', 'beta']);
  });

  test('未设置汇总固定排在全部之后的第一个筛选项', () {
    final summaries = buildBookmarkNameSummaries([
      _bookmarkTopic(topicId: 1, bookmarkId: 101, bookmarkName: 'image'),
      _bookmarkTopic(topicId: 2, bookmarkId: 102, bookmarkName: 'beta'),
      _bookmarkTopic(topicId: 3, bookmarkId: 103, bookmarkName: '   '),
    ]);

    expect(
      summaries.map((summary) => summary.filterKey),
      [unsetBookmarkNameFilterKey, 'beta', 'image'],
    );
  });

  test('重复页不再产生新书签时会停止继续拉取', () async {
    final requestedPages = <String>[];

    final topics = await loadAllBookmarkTopics(
      loadPage: (page, limit) async {
        requestedPages.add('$page:$limit');
        if (page == 0) {
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
        }
        return TopicListResponse(
          topics: [
            _bookmarkTopic(topicId: 1, bookmarkId: 101, bookmarkName: 'image'),
          ],
          moreTopicsUrl: '/u/test/bookmarks.json?page=2',
        );
      },
    );

    expect(requestedPages, [
      '0:$bookmarkRequestLimit',
      '1:$bookmarkRequestLimit',
    ]);
    expect(topics.map((topic) => topic.bookmarkId), [101]);
  });

  test('请求单页上限超过接口限制时会自动收敛到 20', () async {
    final requestedPages = <String>[];

    await loadAllBookmarkTopics(
      requestLimit: 100,
      loadPage: (page, limit) async {
        requestedPages.add('$page:$limit');
        if (page == 0) {
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
        }
        return TopicListResponse(topics: const []);
      },
    );

    expect(requestedPages, [
      '0:$bookmarkRequestLimit',
      '1:$bookmarkRequestLimit',
    ]);
  });

  test('渐进式加载会先产出第一页，再补后续分页', () async {
    final stream = progressivelyLoadAllBookmarkTopics(
      loadPage: (page, limit) async {
        if (page == 0) {
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
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (page == 1) {
          return TopicListResponse(
            topics: [
              _bookmarkTopic(topicId: 2, bookmarkId: 102, bookmarkName: 'beta'),
            ],
            moreTopicsUrl: '/u/test/bookmarks.json?page=2',
          );
        }
        return TopicListResponse(topics: const [], moreTopicsUrl: null);
      },
    );

    final iterator = StreamIterator(stream);
    addTearDown(iterator.cancel);

    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current.map((topic) => topic.bookmarkId), [101]);

    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current.map((topic) => topic.bookmarkId), [101, 102]);
  });
}
