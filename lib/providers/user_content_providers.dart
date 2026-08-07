import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/topic.dart';
import '../pages/bookmarks/bookmarks_models.dart';
import '../storage/bookmark_cache_dao.dart';
import '../utils/paged_async_notifier.dart';
import '../utils/pagination_helper.dart';
import 'bookmark_sync_controller.dart';
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

/// 删除书签后的本地缓存写穿透(全入口统一收口):
/// 服务端 DELETE 成功后调用,把 Hive 里对应条目立刻删掉——否则要等
/// 下次对账才消失,期间书签列表仍展示已删条目(用户实测漏报)。
/// container 版签名:帖子脚等非 Consumer 场景用
/// ProviderScope.containerOf(context) 也能调。
Future<void> purgeBookmarkFromLocalCache(
  ProviderContainer container,
  int bookmarkId,
) {
  return container
      .read(bookmarkSyncControllerProvider.notifier)
      .purgeLocal(bookmarkId);
}

/// 添加/编辑书签成功后的静默保鲜(全入口统一收口):服务端按
/// updated_at DESC 返回,刚增改的条目必在第一页——拉一页 upsert 即可
/// 让书签列表立刻反映变化,不需要客户端拼 payload 写穿(列表 entry 的
/// payload 只有列表接口给得全,帖子页现场构造不现实)。
///
/// 委托给 [BookmarkSyncController.pullFirstPage],失败静默:下次对账会补上。
Future<void> refreshBookmarkListCacheSilently(ProviderContainer container) {
  return container
      .read(bookmarkSyncControllerProvider.notifier)
      .pullFirstPage();
}

/// 分页助手（所有用户内容列表共用）
final _topicPaginationHelper = PaginationHelpers.forTopics<Topic>(
  keyExtractor: (topic) => topic.id,
);

/// 浏览历史 Notifier (支持分页)
class BrowsingHistoryNotifier extends AsyncNotifier<List<Topic>>
    with PagedAsyncNotifierMixin<Topic> {
  @override
  Future<List<Topic>> build() async {
    resetPagingState();
    final service = ref.read(discourseServiceProvider);
    final response = await service.getBrowsingHistory(page: 0);

    final result = _topicPaginationHelper.processRefresh(
      PaginationResult(items: response.topics, moreUrl: response.moreTopicsUrl),
    );
    return completePagedRefresh(PagedPage.fromPagination(result));
  }

  Future<void> refresh() async {
    await runPagedRefresh(() async {
      final service = ref.read(discourseServiceProvider);
      final response = await service.getBrowsingHistory(page: 0);

      final result = _topicPaginationHelper.processRefresh(
        PaginationResult(
          items: response.topics,
          moreUrl: response.moreTopicsUrl,
        ),
      );
      return PagedPage.fromPagination(result);
    });
  }

  Future<void> loadMore() async {
    await runPagedLoadMore((currentList, nextPage) async {
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

      return PagedPage.fromPagination(
        paginationResult,
        advancePage: response.topics.isNotEmpty,
      );
    });
  }

  Future<void> retryLoadMore() {
    return retryPagedLoadMore(loadMore);
  }
}

final browsingHistoryProvider =
    AsyncNotifierProvider.autoDispose<BrowsingHistoryNotifier, List<Topic>>(() {
      return BrowsingHistoryNotifier();
    });

/// 书签 Notifier:本地缓存 + 本地分页,**不再管对账**。
///
/// 数据来源是 [BookmarksRepository](Hive 本地缓存),通过 watch 订阅变更。
/// 网络对账/节流/失败态收口在全局 [BookmarkSyncController]——对账状态
/// 曾寄生在本 autoDispose notifier 里,逼出 keepAlive 补丁、同步转圈
/// 串到列表 footer、每次进页面重复开跑对账,已整体迁出。
///
/// **本地分页**:build 时先拿 [BookmarksRepository.idsOrderedByUpdated](仅 id
/// 顺序,不反序列化 payload),首屏 hydrate [_pageSize] 条;UI 滚到底调
/// [loadMore] 反序列化下一批。reconcile / 编辑触发的刷新只重新 hydrate 当前
/// 已展示的窗口大小,避免一次性 jsonDecode 全量。
///
/// 本地为空(首次)也**不阻塞**:直接返回空表并交给 controller 后台全量
/// 对账,每页 upsert 经 repository.watch 推回来,列表第一页落地即可见,
/// 空态期间的「正在同步」提示由页面读 sync 状态展示。
class BookmarksNotifier extends AsyncNotifier<List<Topic>> {
  late BookmarksRepository _repo;
  String? _accountId;
  bool _isLoadingMore = false;
  bool _isLoadMoreFailed = false;
  StreamSubscription<void>? _repoSubscription;

  /// 当前账号下所有 bookmark_id 的完整顺序(按 updated_at DESC)。
  List<int> _orderedIds = const <int>[];

  /// 已 hydrate(反序列化)的条目数,等同于 state 列表长度。
  int _loadedCount = 0;

  /// 单次 hydrate 的批量大小。
  static const int _pageSize = 30;

  /// 本地缓存里是否还有未 hydrate 的条目。
  bool get hasMore => _loadedCount < _orderedIds.length;

  /// 本地分页 hydrate 是否进行中(列表 footer 的转圈只看它)。
  bool get isLoadingMore => _isLoadingMore;

  /// 上一次 [loadMore] 是否失败。
  bool get isLoadMoreFailed => _isLoadMoreFailed;

  @override
  Future<List<Topic>> build() async {
    _repo = ref.read(bookmarksRepositoryProvider);
    final username = await ref.read(currentUsernameProvider.future);
    if (username == null) {
      // 未登录或测试环境读不到 username:直接返回空表,不阻塞 UI。
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

    // 数据保鲜交给全局同步控制器:节流/全量判定/失败态都在它那边,
    // 这里只是"提示可以考虑同步",不 await、不影响本地首屏。
    unawaited(
      ref.read(bookmarkSyncControllerProvider.notifier).ensureFreshness(),
    );

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

  Future<void> _refreshFromRepository() async {
    final accountId = _accountId;
    if (accountId == null) return;
    final newIds = await _repo.idsOrderedByUpdated(accountId);
    if (!ref.mounted) return;
    _orderedIds = newIds;
    // 保持用户已展示的窗口大小(_loadedCount)重新 hydrate;剩余条目走 loadMore。
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

  /// 下拉刷新:拉第一页 upsert,不翻多页、不删除(spec 中明确不是"对账")。
  Future<void> refresh() {
    // 写入会经由 repository.watch 通知 _refreshFromRepository。
    return ref.read(bookmarkSyncControllerProvider.notifier).pullFirstPage();
  }

  /// 加载下一批本地缓存中的书签条目。
  Future<void> loadMore() async {
    final accountId = _accountId;
    if (accountId == null) return;
    if (_isLoadingMore) return;
    if (!hasMore) return;
    _isLoadingMore = true;
    _isLoadMoreFailed = false;
    _emit();
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
      _emit();
    }
  }

  /// 上一次 [loadMore] 失败时让用户点击"重试"。
  void retryLoadMore() {
    if (_isLoadingMore) return;
    if (!_isLoadMoreFailed) return;
    unawaited(loadMore());
  }

  /// 本地写穿透:编辑书签元数据(name / reminderAt)后调用,写入 repository。
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

  /// 本地写穿透:删除书签后调用。
  Future<void> removeBookmarkLocally(int bookmarkId) async {
    final accountId = _accountId;
    if (accountId == null) return;
    await _repo.deleteOne(accountId, bookmarkId);
  }

  /// 乐观删除:先删本地(列表立即响应),返回备份 entry 供失败回滚。
  Future<BookmarkCacheEntry?> removeBookmarkOptimistically(
    int bookmarkId,
  ) async {
    final accountId = _accountId;
    if (accountId == null) return null;
    final backup = await _repo.findOne(accountId, bookmarkId);
    await _repo.deleteOne(accountId, bookmarkId);
    return backup;
  }

  /// 乐观删除失败后的回滚:把备份 entry 写回本地缓存。
  Future<void> restoreBookmark(BookmarkCacheEntry? backup) async {
    if (backup == null) return;
    final accountId = _accountId;
    if (accountId == null) return;
    await _repo.upsertOne(accountId, backup);
  }

  /// 兼容旧 API:同步移除本地某条书签(实际异步写入 repository)。
  void removeBookmarkById(int bookmarkId) {
    unawaited(removeBookmarkLocally(bookmarkId));
  }

  /// 兼容旧 API:更新本地某条书签的元数据。
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
class MyTopicsNotifier extends AsyncNotifier<List<Topic>>
    with PagedAsyncNotifierMixin<Topic> {
  @override
  Future<List<Topic>> build() async {
    resetPagingState();
    final service = ref.read(discourseServiceProvider);
    final response = await service.getUserCreatedTopics(page: 0);

    final result = _topicPaginationHelper.processRefresh(
      PaginationResult(items: response.topics, moreUrl: response.moreTopicsUrl),
    );
    return completePagedRefresh(PagedPage.fromPagination(result));
  }

  Future<void> refresh() async {
    await runPagedRefresh(() async {
      final service = ref.read(discourseServiceProvider);
      final response = await service.getUserCreatedTopics(page: 0);

      final result = _topicPaginationHelper.processRefresh(
        PaginationResult(
          items: response.topics,
          moreUrl: response.moreTopicsUrl,
        ),
      );
      return PagedPage.fromPagination(result);
    });
  }

  Future<void> loadMore() async {
    await runPagedLoadMore((currentList, nextPage) async {
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

      return PagedPage.fromPagination(
        paginationResult,
        advancePage: response.topics.isNotEmpty,
      );
    });
  }

  Future<void> retryLoadMore() {
    return retryPagedLoadMore(loadMore);
  }
}

final myTopicsProvider =
    AsyncNotifierProvider.autoDispose<MyTopicsNotifier, List<Topic>>(() {
      return MyTopicsNotifier();
    });

/// 私信筛选类型
enum PrivateMessageFilter { inbox, sent, archive }

/// 私信列表 Notifier 基类 (支持分页)
abstract class PrivateMessagesNotifier extends AsyncNotifier<List<Topic>>
    with PagedAsyncNotifierMixin<Topic> {
  Future<TopicListResponse> fetch(int page);

  @override
  Future<List<Topic>> build() async {
    resetPagingState();
    final response = await fetch(0);

    final result = _topicPaginationHelper.processRefresh(
      PaginationResult(items: response.topics, moreUrl: response.moreTopicsUrl),
    );
    return completePagedRefresh(PagedPage.fromPagination(result));
  }

  Future<void> refresh() async {
    await runPagedRefresh(() async {
      final response = await fetch(0);

      final result = _topicPaginationHelper.processRefresh(
        PaginationResult(
          items: response.topics,
          moreUrl: response.moreTopicsUrl,
        ),
      );
      return PagedPage.fromPagination(result);
    });
  }

  Future<void> loadMore() async {
    await runPagedLoadMore((currentList, nextPage) async {
      final response = await fetch(nextPage);

      final currentState = PaginationState<Topic>(items: currentList);
      final paginationResult = _topicPaginationHelper.processLoadMore(
        currentState,
        PaginationResult(
          items: response.topics,
          moreUrl: response.moreTopicsUrl,
        ),
      );

      return PagedPage.fromPagination(
        paginationResult,
        advancePage: response.topics.isNotEmpty,
      );
    });
  }

  Future<void> retryLoadMore() {
    return retryPagedLoadMore(loadMore);
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
