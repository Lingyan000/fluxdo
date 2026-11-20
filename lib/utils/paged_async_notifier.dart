import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pagination_helper.dart';

class PagedPage<T> {
  const PagedPage({
    required this.items,
    required this.hasMore,
    this.advancePage = true,
  });

  factory PagedPage.fromPagination(
    PaginationState<T> state, {
    bool advancePage = true,
  }) {
    return PagedPage<T>(
      items: state.items,
      hasMore: state.hasMore,
      advancePage: advancePage,
    );
  }

  final List<T> items;
  final bool hasMore;

  /// Whether a successful load-more response should move the page cursor.
  ///
  /// Empty responses should usually keep this false so a stale or repeated
  /// server cursor cannot make the notifier skip through page numbers.
  final bool advancePage;
}

typedef PagedRefreshLoader<T> = Future<PagedPage<T>> Function();
typedef PagedLoadMoreLoader<T> =
    Future<PagedPage<T>> Function(List<T> currentItems, int nextPage);

/// Shared paging state for `AsyncNotifier<List<T>>` providers.
///
/// UI coordination still lives in `LoadMoreCoordinator`; this mixin keeps the
/// provider-side contract consistent: has-more, load-more failure, previous
/// data retention while loading, and retry semantics.
mixin PagedAsyncNotifierMixin<T> on AsyncNotifier<List<T>> {
  int _page = 0;
  bool _hasMore = true;
  bool _isLoadMoreFailed = false;

  int get currentPage => _page;
  bool get hasMore => _hasMore;
  bool get isLoadMoreFailed => _isLoadMoreFailed;
  bool get isLoadingMore => state.isLoading && state.hasValue;

  void resetPagingState({int page = 0, bool hasMore = true}) {
    _page = page;
    _hasMore = hasMore;
    _isLoadMoreFailed = false;
  }

  List<T> completePagedRefresh(PagedPage<T> page, {int pageNumber = 0}) {
    _page = pageNumber;
    _hasMore = page.hasMore;
    _isLoadMoreFailed = false;
    return page.items;
  }

  Future<void> runPagedRefresh(
    PagedRefreshLoader<T> loadPage, {
    int pageNumber = 0,
  }) async {
    final requestRef = ref;
    resetPagingState(page: pageNumber);
    state = AsyncLoading<List<T>>();
    final result = await AsyncValue.guard(loadPage);
    if (!requestRef.mounted) return;
    state = result.whenData(
      (page) => completePagedRefresh(page, pageNumber: pageNumber),
    );
  }

  Future<void> runPagedLoadMore(PagedLoadMoreLoader<T> loadPage) async {
    if (_isLoadMoreFailed || !_hasMore || state.isLoading) return;
    final currentItems = state.value;
    if (currentItems == null) return;

    _isLoadMoreFailed = false;
    final requestRef = ref;
    final nextPage = _page + 1;

    // ignore: invalid_use_of_internal_member
    state = AsyncLoading<List<T>>().copyWithPrevious(state);

    try {
      final page = await loadPage(currentItems, nextPage);
      if (!requestRef.mounted) return;
      _hasMore = page.hasMore;
      if (page.advancePage) {
        _page = nextPage;
      }
      state = AsyncValue.data(page.items);
    } catch (_) {
      if (!requestRef.mounted) return;
      _isLoadMoreFailed = true;
      state = AsyncValue.data(currentItems);
    }
  }

  Future<void> retryPagedLoadMore(Future<void> Function() loadMore) async {
    if (!_isLoadMoreFailed) return;
    _isLoadMoreFailed = false;
    await loadMore();
  }
}
