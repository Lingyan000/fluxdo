import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/bookmarks/bookmarks_models.dart';
import 'package:fluxdo/providers/bookmark_name_suggestions_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

Future<ProviderContainer> _createContainer({
  Map<String, Object> initialValues = const {},
  BookmarkPageLoader? pageLoader,
}) async {
  SharedPreferences.setMockInitialValues(initialValues);
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      if (pageLoader != null)
        bookmarkNameSuggestionPageLoaderProvider.overrideWithValue(pageLoader),
    ],
  );
}

void main() {
  test('会缓存已知书签名称并复用首次全量加载结果', () async {
    final requestedPages = <String>[];
    final container = await _createContainer(
      pageLoader: (page, limit) async {
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
                  topicId: 2,
                  bookmarkId: 102,
                  bookmarkName: 'beta',
                ),
              ],
              moreTopicsUrl: '/u/test/bookmarks.json?page=1',
            );
          default:
            return TopicListResponse(topics: const []);
        }
      },
    );
    addTearDown(container.dispose);

    final notifier = container.read(bookmarkNameSuggestionsProvider.notifier);
    notifier.seedFromTopics([
      _bookmarkTopic(topicId: 9, bookmarkId: 999, bookmarkName: 'seeded'),
    ]);

    expect(container.read(bookmarkNameSuggestionsProvider), ['seeded']);

    final loaded = await notifier.ensureLoaded();
    expect(loaded, ['beta', 'image']);
    expect(container.read(bookmarkNameSuggestionsProvider), ['beta', 'image']);

    await notifier.ensureLoaded();
    expect(requestedPages, [
      '0:$bookmarkRequestLimit',
      '1:$bookmarkRequestLimit',
    ]);
  });

  test('完整书签快照会直接标记候选已全量并跳过后续远端加载', () async {
    final requestedPages = <String>[];
    final container = await _createContainer(
      pageLoader: (page, limit) async {
        requestedPages.add('$page:$limit');
        return TopicListResponse(topics: const []);
      },
    );
    addTearDown(container.dispose);

    final notifier = container.read(bookmarkNameSuggestionsProvider.notifier);
    notifier.seedFromTopics([
      _bookmarkTopic(topicId: 1, bookmarkId: 101, bookmarkName: 'image'),
      _bookmarkTopic(topicId: 2, bookmarkId: 102, bookmarkName: 'beta'),
    ], isCompleteSnapshot: true);

    final loaded = await notifier.ensureLoaded();

    expect(loaded, ['beta', 'image']);
    expect(container.read(bookmarkNameSuggestionsProvider), ['beta', 'image']);
    expect(requestedPages, isEmpty);
  });

  test('标记脏状态后会保留新名称并在下次重新拉取', () async {
    final requestedPages = <String>[];
    var useUpdatedRemote = false;
    final container = await _createContainer(
      pageLoader: (page, limit) async {
        requestedPages.add('$page:$limit');
        if (page > 0) {
          return TopicListResponse(topics: const []);
        }
        return TopicListResponse(
          topics: useUpdatedRemote
              ? [
                  _bookmarkTopic(
                    topicId: 2,
                    bookmarkId: 202,
                    bookmarkName: 'codex',
                  ),
                ]
              : [
                  _bookmarkTopic(
                    topicId: 1,
                    bookmarkId: 101,
                    bookmarkName: 'image',
                  ),
                ],
        );
      },
    );
    addTearDown(container.dispose);

    final notifier = container.read(bookmarkNameSuggestionsProvider.notifier);

    await notifier.ensureLoaded();
    expect(container.read(bookmarkNameSuggestionsProvider), ['image']);

    notifier.markDirty(optimisticName: 'codex');
    expect(container.read(bookmarkNameSuggestionsProvider), ['image', 'codex']);

    useUpdatedRemote = true;
    final reloaded = await notifier.ensureLoaded();
    expect(reloaded, ['codex']);
    expect(requestedPages, [
      '0:$bookmarkRequestLimit',
      '1:$bookmarkRequestLimit',
      '0:$bookmarkRequestLimit',
      '1:$bookmarkRequestLimit',
    ]);
  });

  test('重建 provider 后会立即恢复上次缓存的书签名称', () async {
    final requestedPages = <String>[];
    final container = await _createContainer(
      pageLoader: (page, limit) async {
        requestedPages.add('$page:$limit');
        if (page > 0) {
          return TopicListResponse(topics: const []);
        }
        return TopicListResponse(
          topics: [
            _bookmarkTopic(topicId: 1, bookmarkId: 101, bookmarkName: 'image'),
            _bookmarkTopic(topicId: 2, bookmarkId: 102, bookmarkName: 'beta'),
          ],
        );
      },
    );
    addTearDown(container.dispose);

    await container
        .read(bookmarkNameSuggestionsProvider.notifier)
        .ensureLoaded();
    expect(container.read(bookmarkNameSuggestionsProvider), ['beta', 'image']);

    final prefs = container.read(sharedPreferencesProvider);
    final reloaded = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        bookmarkNameSuggestionPageLoaderProvider.overrideWithValue((
          page,
          limit,
        ) async {
          requestedPages.add('reload:$page:$limit');
          return TopicListResponse(topics: const []);
        }),
      ],
    );
    addTearDown(reloaded.dispose);

    expect(reloaded.read(bookmarkNameSuggestionsProvider), ['beta', 'image']);
  });

  test('空缓存时会后台预热书签名称候选', () async {
    final requestedPages = <String>[];
    final container = await _createContainer(
      pageLoader: (page, limit) async {
        requestedPages.add('$page:$limit');
        if (page > 0) {
          return TopicListResponse(topics: const []);
        }
        return TopicListResponse(
          topics: [
            _bookmarkTopic(topicId: 1, bookmarkId: 101, bookmarkName: 'image'),
          ],
          moreTopicsUrl: '/u/test/bookmarks.json?page=1',
        );
      },
    );
    addTearDown(container.dispose);

    final notifier = container.read(bookmarkNameSuggestionsProvider.notifier);
    notifier.prefetchIfEmpty();

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(requestedPages, [
      '0:$bookmarkRequestLimit',
      '1:$bookmarkRequestLimit',
    ]);
    expect(container.read(bookmarkNameSuggestionsProvider), ['image']);
  });
}
