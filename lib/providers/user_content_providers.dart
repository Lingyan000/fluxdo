import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/topic.dart';
import '../pages/bookmarks/bookmarks_models.dart';
import '../utils/pagination_helper.dart';
import 'bookmarks_reconciler.dart';
import 'bookmarks_repository.dart';
import 'core_providers.dart';

final bookmarksPageLoaderProvider = Provider<BookmarkPageLoader>((ref) {
  final service = ref.read(discourseServiceProvider);
  return (page, limit) => service.getUserBookmarks(page: page, limit: limit);
});

/// 当前账号 username，作为本地书签缓存的隔离键；抽出来便于测试注入。
final currentUsernameProvider = FutureProvider<String?>((ref) async {
  return ref.read(discourseServiceProvider).getUsername();
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

/// 书签 Notifier：本地缓存 + 远端对账 + 本地分页。
///
/// 数据来源是 [BookmarksRepository]（Hive 本地缓存），通过 watch 订阅变更。
/// 网络对账委托给 [BookmarksReconciler]。
///
/// **本地分页**：build 时先拿 [BookmarksRepository.idsOrderedByUpdated]（仅 id
/// 顺序，不反序列化 payload），首屏 hydrate [_pageSize] 条；UI 滚到底调
/// [loadMore] 反序列化下一批。reconcile / 编辑触发的刷新只重新 hydrate 当前
/// 已展示的窗口大小，避免一次性 jsonDecode 全量。
class BookmarksNotifier extends AsyncNotifier<List<Topic>> {
  late BookmarksRepository _repo;
  String? _accountId;
  bool _isReconciling = false;
  bool _isLastReconcileFailed = false;
  bool _isLoadingMore = false;
  bool _isLoadMoreFailed = false;
  ReconcileMode? _ongoingMode;
  StreamSubscription<void>? _repoSubscription;

  /// 当前账号下所有 bookmark_id 的完整顺序（按 updated_at DESC）。
  List<int> _orderedIds = const <int>[];

  /// 已 hydrate（反序列化）的条目数，等同于 state 列表长度。
  int _loadedCount = 0;

  /// 单次 hydrate 的批量大小。
  static const int _pageSize = 30;

  bool get isReconciling => _isReconciling;
  bool get isLastReconcileFailed => _isLastReconcileFailed;
  ReconcileMode? get ongoingReconcileMode => _ongoingMode;

  /// 本地缓存里是否还有未 hydrate 的条目。
  bool get hasMore => _loadedCount < _orderedIds.length;

  /// 上一次 [loadMore] 是否失败。
  bool get isLoadMoreFailed => _isLoadMoreFailed;

  /// 兼容旧 UI：映射到"对账进行中"。
  bool get isHydratingAll => _isReconciling;

  @override
  Future<List<Topic>> build() async {
    _repo = ref.read(bookmarksRepositoryProvider);
    final username = await ref.read(currentUsernameProvider.future);
    if (username == null) {
      // 未登录或测试环境读不到 username：直接返回空表，不阻塞 UI。
      return const <Topic>[];
    }
    _accountId = username;

    _repoSubscription = _repo.watch().listen((_) {
      if (!ref.mounted) return;
      unawaited(_refreshFromRepository());
    });
    ref.onDispose(() {
      _repoSubscription?.cancel();
    });

    _orderedIds = await _repo.idsOrderedByUpdated(username);
    final reconciler = await ref.read(bookmarksReconcilerProvider.future);

    if (_orderedIds.isEmpty) {
      // 首次进入（本地空）：阻塞做完整对账。仅此一次。
      _isReconciling = true;
      try {
        final report = await reconciler.fullReconcile(username);
        _isLastReconcileFailed =
            report.stopReason == ReconcileStopReason.errored;
      } catch (_) {
        _isLastReconcileFailed = true;
      } finally {
        _isReconciling = false;
      }
      _orderedIds = await _repo.idsOrderedByUpdated(username);
      return _hydrateFirstPage(username);
    }

    // 非首次：先吐第一页，后台跑增量或定期完整对账。
    unawaited(_runBackgroundReconcile(reconciler, username));
    return _hydrateFirstPage(username);
  }

  Future<List<Topic>> _hydrateFirstPage(String accountId) async {
    final take = _orderedIds.length < _pageSize
        ? _orderedIds.length
        : _pageSize;
    final ids = _orderedIds.sublist(0, take);
    final records = await _repo.readByIds(accountId, ids);
    _loadedCount = records.length;
    return records.map((r) => r.topic).toList(growable: false);
  }

  Future<void> _runBackgroundReconcile(
    BookmarksReconciler reconciler,
    String accountId,
  ) async {
    if (_isReconciling) return;
    final mode = reconciler.isFullReconcileDue(accountId)
        ? ReconcileMode.full
        : ReconcileMode.incremental;
    // autoDispose provider：用户在对账期间切走页面时如果不 keepAlive，notifier
    // 会被销毁，导致 finally 里的 _emit 写不进 state（sync 按钮卡在 loading）。
    final keepAliveLink = ref.keepAlive();
    _isReconciling = true;
    _ongoingMode = mode;
    _isLastReconcileFailed = false;
    _emit();
    try {
      final report = mode == ReconcileMode.full
          ? await reconciler.fullReconcile(accountId)
          : await reconciler.incrementalReconcile(accountId);
      _isLastReconcileFailed = report.stopReason == ReconcileStopReason.errored;
    } catch (_) {
      _isLastReconcileFailed = true;
    } finally {
      _isReconciling = false;
      _ongoingMode = null;
      _emit();
      keepAliveLink.close();
    }
  }

  Future<void> _refreshFromRepository() async {
    final accountId = _accountId;
    if (accountId == null) return;
    final newIds = await _repo.idsOrderedByUpdated(accountId);
    if (!ref.mounted) return;
    _orderedIds = newIds;
    // 保持用户已展示的窗口大小（_loadedCount）重新 hydrate；剩余条目走 loadMore。
    final windowSize = _loadedCount == 0 ? _pageSize : _loadedCount;
    final take = _orderedIds.length < windowSize
        ? _orderedIds.length
        : windowSize;
    final ids = _orderedIds.sublist(0, take);
    final records = await _repo.readByIds(accountId, ids);
    if (!ref.mounted) return;
    _loadedCount = records.length;
    state = AsyncValue.data(
      records.map((r) => r.topic).toList(growable: false),
    );
  }

  /// 下拉刷新：拉第一页 upsert，不翻多页、不删除（spec 中明确不是"对账"）。
  Future<void> refresh() async {
    final accountId = _accountId;
    if (accountId == null) return;
    final reconciler = await ref.read(bookmarksReconcilerProvider.future);
    await reconciler.pullToRefresh(accountId);
    // 写入会经由 repository.watch 通知 _refreshFromRepository。
  }

  /// 手动对账：触发完整对账，UI 通常会在调用前后展示加载条与结果 toast。
  Future<ReconcileReport?> manualFullReconcile() async {
    final accountId = _accountId;
    if (accountId == null) return null;
    if (_isReconciling) return null;
    final reconciler = await ref.read(bookmarksReconcilerProvider.future);
    // autoDispose provider：用户点同步后页面被切走（或 widget 被回收）会让
    // notifier 被销毁，finally 里 _emit 写不进 state → sync 按钮卡 loading。
    // 用 keepAlive 在对账期间保住 notifier，结束后释放即可正常 autoDispose。
    final keepAliveLink = ref.keepAlive();
    _isReconciling = true;
    _ongoingMode = ReconcileMode.full;
    _isLastReconcileFailed = false;
    _emit();
    try {
      final report = await reconciler.fullReconcile(accountId);
      _isLastReconcileFailed = report.stopReason == ReconcileStopReason.errored;
      return report;
    } catch (_) {
      _isLastReconcileFailed = true;
      return null;
    } finally {
      _isReconciling = false;
      _ongoingMode = null;
      _emit();
      keepAliveLink.close();
    }
  }

  /// 加载下一批本地缓存中的书签条目。
  Future<void> loadMore() async {
    final accountId = _accountId;
    if (accountId == null) return;
    if (_isLoadingMore) return;
    if (!hasMore) return;
    _isLoadingMore = true;
    _isLoadMoreFailed = false;
    try {
      final end = (_loadedCount + _pageSize) > _orderedIds.length
          ? _orderedIds.length
          : _loadedCount + _pageSize;
      final ids = _orderedIds.sublist(_loadedCount, end);
      final records = await _repo.readByIds(accountId, ids);
      if (!ref.mounted) return;
      final current = state.value ?? const <Topic>[];
      final merged = <Topic>[
        ...current,
        ...records.map((r) => r.topic),
      ];
      _loadedCount = merged.length;
      state = AsyncValue.data(List<Topic>.unmodifiable(merged));
    } catch (_) {
      _isLoadMoreFailed = true;
      _emit();
    } finally {
      _isLoadingMore = false;
    }
  }

  /// 上一次 [loadMore] 失败时让用户点击"重试"。
  void retryLoadMore() {
    if (_isLoadingMore) return;
    if (!_isLoadMoreFailed) return;
    unawaited(loadMore());
  }

  /// 本地写穿透：编辑书签元数据（name / reminderAt）后调用，写入 repository。
  /// 实际 UI 刷新由 repository.watch 推送。
  Future<void> applyLocalEditResult(
    int bookmarkId, {
    required String? name,
    required DateTime? reminderAt,
  }) async {
    final accountId = _accountId;
    if (accountId == null) return;
    await _repo.applyMetadataChange(
      accountId,
      bookmarkId,
      name: name,
      reminderAt: reminderAt,
      bookmarkUpdatedAt: DateTime.now().toUtc(),
    );
  }

  /// 本地写穿透：删除书签后调用。
  Future<void> removeBookmarkLocally(int bookmarkId) async {
    final accountId = _accountId;
    if (accountId == null) return;
    await _repo.deleteOne(accountId, bookmarkId);
  }

  /// 兼容旧 API：同步移除本地某条书签（实际异步写入 repository）。
  void removeBookmarkById(int bookmarkId) {
    unawaited(removeBookmarkLocally(bookmarkId));
  }

  /// 兼容旧 API：更新本地某条书签的元数据。
  void updateBookmarkMeta(
    int bookmarkId, {
    String? name,
    DateTime? reminderAt,
    bool clearName = false,
    bool clearReminderAt = false,
  }) {
    unawaited(
      applyLocalEditResult(
        bookmarkId,
        name: clearName ? null : name,
        reminderAt: clearReminderAt ? null : reminderAt,
      ),
    );
  }

  void _emit() {
    if (!ref.mounted) return;
    final current = state.value;
    if (current == null) return;
    // 重新打包同一个 list 让监听 notifier 状态的 widget 感知到状态字段变化。
    state = AsyncValue.data(List<Topic>.unmodifiable(current));
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
