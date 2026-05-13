import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/topic.dart';
import '../pages/bookmarks/bookmarks_models.dart';
import '../utils/pagination_helper.dart';
import 'core_providers.dart';

final bookmarksPageLoaderProvider = Provider<BookmarkPageLoader>((ref) {
  final service = ref.read(discourseServiceProvider);
  return (page, limit) => service.getUserBookmarks(page: page, limit: limit);
});

/// 分页助手（所有用户内容列表共用）
final _topicPaginationHelper = PaginationHelpers.forTopics<Topic>(
  keyExtractor: (topic) => topic.id,
);

/// 浏览历史 Notifier (支持分页)
class BrowsingHistoryNotifier extends AsyncNotifier<List<Topic>> {
  int _page = 0;
  bool _hasMore = true;
  bool _isLoadMoreFailed = false;
  bool get hasMore => _hasMore;
  bool get isLoadMoreFailed => _isLoadMoreFailed;

  @override
  Future<List<Topic>> build() async {
    _page = 0;
    _hasMore = true;
    _isLoadMoreFailed = false;
    final service = ref.read(discourseServiceProvider);
    final response = await service.getBrowsingHistory(page: 0);

    final result = _topicPaginationHelper.processRefresh(
      PaginationResult(items: response.topics, moreUrl: response.moreTopicsUrl),
    );
    _hasMore = result.hasMore;
    return result.items;
  }

  Future<void> refresh() async {
    _isLoadMoreFailed = false;
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      _page = 0;
      _hasMore = true;
      final service = ref.read(discourseServiceProvider);
      final response = await service.getBrowsingHistory(page: 0);

      final result = _topicPaginationHelper.processRefresh(
        PaginationResult(
          items: response.topics,
          moreUrl: response.moreTopicsUrl,
        ),
      );
      _hasMore = result.hasMore;
      return result.items;
    });
  }

  Future<void> loadMore() async {
    if (_isLoadMoreFailed) return;
    if (!_hasMore || state.isLoading) return;

    // ignore: invalid_use_of_internal_member
    state = const AsyncLoading<List<Topic>>().copyWithPrevious(state);

    final result = await AsyncValue.guard(() async {
      final currentList = state.requireValue;
      final nextPage = _page + 1;

      final service = ref.read(discourseServiceProvider);
      final response = await service.getBrowsingHistory(page: nextPage);

      final currentState = PaginationState(items: currentList);
      final paginationResult = _topicPaginationHelper.processLoadMore(
        currentState,
        PaginationResult(
          items: response.topics,
          moreUrl: response.moreTopicsUrl,
        ),
      );

      _hasMore = paginationResult.hasMore;
      if (paginationResult.items.length > currentList.length) {
        _page = nextPage;
      }
      return paginationResult.items;
    });
    if (result.hasError) {
      _isLoadMoreFailed = true;
      state = AsyncValue.data(state.requireValue);
    } else {
      state = result;
    }
  }

  void retryLoadMore() {
    _isLoadMoreFailed = false;
    loadMore();
  }
}

final browsingHistoryProvider =
    AsyncNotifierProvider.autoDispose<BrowsingHistoryNotifier, List<Topic>>(() {
      return BrowsingHistoryNotifier();
    });

/// 书签 Notifier（进入页面时拉取全量，确保顶部统计和筛选完整）
class BookmarksNotifier extends AsyncNotifier<List<Topic>> {
  bool _hasMore = false;
  bool _isLoadMoreFailed = false;
  bool _isHydratingAll = false;
  StreamIterator<List<Topic>>? _activeIterator;
  bool get hasMore => _hasMore;
  bool get isLoadMoreFailed => _isLoadMoreFailed;
  bool get isHydratingAll => _isHydratingAll;

  void _refreshCurrentState() {
    if (!state.hasValue) {
      return;
    }
    state = AsyncValue.data(List<Topic>.from(state.requireValue));
  }

  @override
  Future<List<Topic>> build() async {
    _hasMore = false;
    _isLoadMoreFailed = false;
    _isHydratingAll = false;
    return _loadFirstPageThenHydrate(
      loadPage: ref.read(bookmarksPageLoaderProvider),
    );
  }

  Future<void> refresh() async {
    await _activeIterator?.cancel();
    _activeIterator = null;
    _isLoadMoreFailed = false;
    _isHydratingAll = false;
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      return _loadFirstPageThenHydrate(
        loadPage: ref.read(bookmarksPageLoaderProvider),
      );
    });
  }

  Future<void> loadMore() async {
    return;
  }

  void retryLoadMore() {
    if (_isHydratingAll) return;
    _isLoadMoreFailed = false;
    if (!state.hasValue) {
      unawaited(refresh());
      return;
    }
    _hasMore = true;
    _isHydratingAll = true;
    _refreshCurrentState();
    unawaited(
      _restartHydration(loadPage: ref.read(bookmarksPageLoaderProvider)),
    );
  }

  Future<List<Topic>> _loadFirstPageThenHydrate({
    required BookmarkPageLoader loadPage,
  }) async {
    await _activeIterator?.cancel();
    final iterator = StreamIterator(
      progressivelyLoadAllBookmarkTopics(loadPage: loadPage),
    );
    _activeIterator = iterator;
    _bindIteratorCleanup(iterator);

    if (!await iterator.moveNext()) {
      if (identical(_activeIterator, iterator)) {
        _activeIterator = null;
      }
      return const [];
    }

    final firstPageTopics = iterator.current;
    _hasMore = true;
    _isLoadMoreFailed = false;
    _isHydratingAll = true;
    unawaited(_continueHydration(iterator));
    return firstPageTopics;
  }

  Future<void> _restartHydration({required BookmarkPageLoader loadPage}) async {
    await _activeIterator?.cancel();
    final iterator = StreamIterator(
      progressivelyLoadAllBookmarkTopics(loadPage: loadPage),
    );
    _activeIterator = iterator;
    _bindIteratorCleanup(iterator);
    unawaited(_continueHydration(iterator));
  }

  void _bindIteratorCleanup(StreamIterator<List<Topic>> iterator) {
    ref.onDispose(() async {
      if (identical(_activeIterator, iterator)) {
        await iterator.cancel();
      }
    });
  }

  Future<void> _continueHydration(StreamIterator<List<Topic>> iterator) async {
    try {
      while (await iterator.moveNext()) {
        if (!ref.mounted || !identical(_activeIterator, iterator)) {
          return;
        }
        state = AsyncValue.data(iterator.current);
      }
      if (identical(_activeIterator, iterator)) {
        _hasMore = false;
        _isLoadMoreFailed = false;
      }
    } catch (_) {
      if (!ref.mounted || !identical(_activeIterator, iterator)) {
        return;
      }
      _hasMore = true;
      _isLoadMoreFailed = true;
    } finally {
      if (identical(_activeIterator, iterator)) {
        _isHydratingAll = false;
        _activeIterator = null;
        if (ref.mounted) {
          _refreshCurrentState();
        }
      }
    }
  }

  /// 从本地列表中移除指定书签（删除后调用）
  void removeBookmarkById(int bookmarkId) {
    final current = state.value;
    if (current == null) return;
    state = AsyncValue.data(
      current.where((t) => t.bookmarkId != bookmarkId).toList(),
    );
  }

  /// 更新本地列表中指定书签的元数据
  void updateBookmarkMeta(
    int bookmarkId, {
    String? name,
    DateTime? reminderAt,
    bool clearName = false,
    bool clearReminderAt = false,
  }) {
    final current = state.value;
    if (current == null) return;
    state = AsyncValue.data(
      current.map((t) {
        if (t.bookmarkId != bookmarkId) return t;
        return Topic(
          id: t.id,
          title: t.title,
          slug: t.slug,
          postsCount: t.postsCount,
          replyCount: t.replyCount,
          views: t.views,
          likeCount: t.likeCount,
          excerpt: t.excerpt,
          createdAt: t.createdAt,
          lastPostedAt: t.lastPostedAt,
          lastPosterUsername: t.lastPosterUsername,
          categoryId: t.categoryId,
          pinned: t.pinned,
          visible: t.visible,
          closed: t.closed,
          archived: t.archived,
          tags: t.tags,
          posters: t.posters,
          unseen: t.unseen,
          unread: t.unread,
          newPosts: t.newPosts,
          lastReadPostNumber: t.lastReadPostNumber,
          highestPostNumber: t.highestPostNumber,
          bookmarkedPostNumber: t.bookmarkedPostNumber,
          bookmarkId: t.bookmarkId,
          bookmarkName: clearName ? null : (name ?? t.bookmarkName),
          bookmarkReminderAt: clearReminderAt
              ? null
              : (reminderAt ?? t.bookmarkReminderAt),
          bookmarkableType: t.bookmarkableType,
          hasAcceptedAnswer: t.hasAcceptedAnswer,
          canHaveAnswer: t.canHaveAnswer,
        );
      }).toList(),
    );
  }
}

final bookmarksProvider =
    AsyncNotifierProvider.autoDispose<BookmarksNotifier, List<Topic>>(() {
      return BookmarksNotifier();
    });

/// 我的话题 Notifier (支持分页)
class MyTopicsNotifier extends AsyncNotifier<List<Topic>> {
  int _page = 0;
  bool _hasMore = true;
  bool _isLoadMoreFailed = false;
  bool get hasMore => _hasMore;
  bool get isLoadMoreFailed => _isLoadMoreFailed;

  @override
  Future<List<Topic>> build() async {
    _page = 0;
    _hasMore = true;
    _isLoadMoreFailed = false;
    final service = ref.read(discourseServiceProvider);
    final response = await service.getUserCreatedTopics(page: 0);

    final result = _topicPaginationHelper.processRefresh(
      PaginationResult(items: response.topics, moreUrl: response.moreTopicsUrl),
    );
    _hasMore = result.hasMore;
    return result.items;
  }

  Future<void> refresh() async {
    _isLoadMoreFailed = false;
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      _page = 0;
      _hasMore = true;
      final service = ref.read(discourseServiceProvider);
      final response = await service.getUserCreatedTopics(page: 0);

      final result = _topicPaginationHelper.processRefresh(
        PaginationResult(
          items: response.topics,
          moreUrl: response.moreTopicsUrl,
        ),
      );
      _hasMore = result.hasMore;
      return result.items;
    });
  }

  Future<void> loadMore() async {
    if (_isLoadMoreFailed) return;
    if (!_hasMore || state.isLoading) return;

    // ignore: invalid_use_of_internal_member
    state = const AsyncLoading<List<Topic>>().copyWithPrevious(state);

    final result = await AsyncValue.guard(() async {
      final currentList = state.requireValue;
      final nextPage = _page + 1;

      final service = ref.read(discourseServiceProvider);
      final response = await service.getUserCreatedTopics(page: nextPage);

      final currentState = PaginationState(items: currentList);
      final paginationResult = _topicPaginationHelper.processLoadMore(
        currentState,
        PaginationResult(
          items: response.topics,
          moreUrl: response.moreTopicsUrl,
        ),
      );

      _hasMore = paginationResult.hasMore;
      if (paginationResult.items.length > currentList.length) {
        _page = nextPage;
      }
      return paginationResult.items;
    });
    if (result.hasError) {
      _isLoadMoreFailed = true;
      state = AsyncValue.data(state.requireValue);
    } else {
      state = result;
    }
  }

  void retryLoadMore() {
    _isLoadMoreFailed = false;
    loadMore();
  }
}

final myTopicsProvider =
    AsyncNotifierProvider.autoDispose<MyTopicsNotifier, List<Topic>>(() {
      return MyTopicsNotifier();
    });

/// 私信筛选类型
enum PrivateMessageFilter { inbox, sent, archive }

/// 私信列表 Notifier 基类 (支持分页)
abstract class PrivateMessagesNotifier extends AsyncNotifier<List<Topic>> {
  int _page = 0;
  bool _hasMore = true;
  bool _isLoadMoreFailed = false;
  bool get hasMore => _hasMore;
  bool get isLoadMoreFailed => _isLoadMoreFailed;

  Future<TopicListResponse> fetch(int page);

  @override
  Future<List<Topic>> build() async {
    _page = 0;
    _hasMore = true;
    _isLoadMoreFailed = false;
    final response = await fetch(0);

    final result = _topicPaginationHelper.processRefresh(
      PaginationResult(items: response.topics, moreUrl: response.moreTopicsUrl),
    );
    _hasMore = result.hasMore;
    return result.items;
  }

  Future<void> refresh() async {
    _isLoadMoreFailed = false;
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      _page = 0;
      _hasMore = true;
      final response = await fetch(0);

      final result = _topicPaginationHelper.processRefresh(
        PaginationResult(
          items: response.topics,
          moreUrl: response.moreTopicsUrl,
        ),
      );
      _hasMore = result.hasMore;
      return result.items;
    });
  }

  Future<void> loadMore() async {
    if (_isLoadMoreFailed) return;
    if (!_hasMore || state.isLoading) return;

    // ignore: invalid_use_of_internal_member
    state = const AsyncLoading<List<Topic>>().copyWithPrevious(state);

    final result = await AsyncValue.guard(() async {
      final currentList = state.requireValue;
      final nextPage = _page + 1;

      final response = await fetch(nextPage);

      final currentState = PaginationState<Topic>(items: currentList);
      final paginationResult = _topicPaginationHelper.processLoadMore(
        currentState,
        PaginationResult(
          items: response.topics,
          moreUrl: response.moreTopicsUrl,
        ),
      );

      _hasMore = paginationResult.hasMore;
      if (paginationResult.items.length > currentList.length) {
        _page = nextPage;
      }
      return paginationResult.items;
    });
    if (result.hasError) {
      _isLoadMoreFailed = true;
      state = AsyncValue.data(state.requireValue);
    } else {
      state = result;
    }
  }

  void retryLoadMore() {
    _isLoadMoreFailed = false;
    loadMore();
  }
}

class _PmInboxNotifier extends PrivateMessagesNotifier {
  @override
  Future<TopicListResponse> fetch(int page) =>
      ref.read(discourseServiceProvider).getPrivateMessages(page: page);
}

class _PmSentNotifier extends PrivateMessagesNotifier {
  @override
  Future<TopicListResponse> fetch(int page) =>
      ref.read(discourseServiceProvider).getPrivateMessagesSent(page: page);
}

class _PmArchiveNotifier extends PrivateMessagesNotifier {
  @override
  Future<TopicListResponse> fetch(int page) =>
      ref.read(discourseServiceProvider).getPrivateMessagesArchive(page: page);
}

final pmInboxProvider =
    AsyncNotifierProvider.autoDispose<_PmInboxNotifier, List<Topic>>(
      () => _PmInboxNotifier(),
    );
final pmSentProvider =
    AsyncNotifierProvider.autoDispose<_PmSentNotifier, List<Topic>>(
      () => _PmSentNotifier(),
    );
final pmArchiveProvider =
    AsyncNotifierProvider.autoDispose<_PmArchiveNotifier, List<Topic>>(
      () => _PmArchiveNotifier(),
    );
