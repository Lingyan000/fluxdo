import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/discourse/discourse_service.dart';
import 'bookmarks_repository.dart';
import 'core_providers.dart';

/// 对账模式。
enum ReconcileMode {
  /// 增量：拉到"整页 (bookmark_id, updated_at) 都已在本地且未变"为止，
  /// 仅 upsert，不做删除。
  incremental,

  /// 完整：翻完所有页，upsert + 检测远端删除。
  full,

  /// 下拉刷新：仅拉第一页 upsert，不翻多页、不删除。
  pullToRefresh,
}

class ReconcileReport {
  ReconcileReport({
    required this.mode,
    required this.upserted,
    required this.deleted,
    required this.pagesFetched,
    required this.stopReason,
  });

  /// 本次对账模式。
  final ReconcileMode mode;

  /// 写入（含新增与更新）的条目数。
  final int upserted;

  /// 仅完整对账可能 > 0：远端已删、本地清理的条目数。
  final int deleted;

  /// 实际请求的页数。
  final int pagesFetched;

  /// 终止原因（调试用）。
  final ReconcileStopReason stopReason;

  bool get hasChange => upserted > 0 || deleted > 0;
}

enum ReconcileStopReason {
  /// 服务端返回空页（翻到尾）。
  emptyPage,

  /// 本页全部 (id, updated_at) 已在本地且未变。
  allKnownAndUnchanged,

  /// 拉满预定页数（pullToRefresh 模式）。
  pageLimitReached,

  /// 网络或解析失败。
  errored,
}

/// 拉单页接口。reconciler 不直接依赖 dio / 服务层。
typedef BookmarkRawPageLoader =
    Future<BookmarkPageParseResult> Function(int page);

/// 书签对账器：协调三种触发时机（首次 / 进页面静默 / 手动 / 下拉刷新）的
/// 数据同步，最终结果统一写回 [BookmarksRepository]。
class BookmarksReconciler {
  BookmarksReconciler({
    required BookmarksRepository repository,
    required BookmarkRawPageLoader fetchPage,
    required SharedPreferences preferences,
  }) : _repository = repository,
       _fetchPage = fetchPage,
       _preferences = preferences;

  static const String _lastFullSyncKeyPrefix = 'bookmark_last_full_sync_';
  static const int _bookmarksPageLimit = 20;

  /// 完整对账的最小间隔——超过这个时间再进页面会自动触发后台 full 对账。
  static const Duration kFullReconcileInterval = Duration(hours: 24);

  final BookmarksRepository _repository;
  final BookmarkRawPageLoader _fetchPage;
  final SharedPreferences _preferences;

  /// 上次完整对账的时间戳。空表示从未做过（=本地首次）。
  DateTime? lastFullSyncAt(String accountId) {
    final iso = _preferences.getString('$_lastFullSyncKeyPrefix$accountId');
    if (iso == null) return null;
    return DateTime.tryParse(iso);
  }

  /// 是否需要在进页面时跑一次完整对账。
  bool isFullReconcileDue(String accountId) {
    final last = lastFullSyncAt(accountId);
    if (last == null) return true;
    return DateTime.now().difference(last) > kFullReconcileInterval;
  }

  Future<void> _markFullSyncCompleted(String accountId) async {
    await _preferences.setString(
      '$_lastFullSyncKeyPrefix$accountId',
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  /// 增量对账：用于进页面静默后台同步。
  ///
  /// 服务端按 `updated_at DESC` 返回；遇到整页"已知且未变"即可停止——后续
  /// 页也不会有新变化（因为它们的 updated_at 比本页还旧）。
  Future<ReconcileReport> incrementalReconcile(String accountId) async {
    var page = 0;
    var upserted = 0;
    final snapshot = await _repository.snapshotById(accountId);

    while (true) {
      late final BookmarkPageParseResult result;
      try {
        result = await _fetchPage(page);
      } catch (_) {
        return ReconcileReport(
          mode: ReconcileMode.incremental,
          upserted: upserted,
          deleted: 0,
          pagesFetched: page,
          stopReason: ReconcileStopReason.errored,
        );
      }
      if (result.entries.isEmpty) {
        return ReconcileReport(
          mode: ReconcileMode.incremental,
          upserted: upserted,
          deleted: 0,
          pagesFetched: page + 1,
          stopReason: ReconcileStopReason.emptyPage,
        );
      }

      final changed = result.entries.where((entry) {
        final local = snapshot[entry.bookmarkId];
        return local == null ||
            local != entry.updatedAt.toUtc().toIso8601String();
      }).toList(growable: false);

      if (changed.isNotEmpty) {
        await _repository.upsertEntries(accountId, changed);
        upserted += changed.length;
      }

      final allKnownAndUnchanged = changed.isEmpty;
      if (allKnownAndUnchanged) {
        return ReconcileReport(
          mode: ReconcileMode.incremental,
          upserted: upserted,
          deleted: 0,
          pagesFetched: page + 1,
          stopReason: ReconcileStopReason.allKnownAndUnchanged,
        );
      }
      page++;
    }
  }

  /// 完整对账：翻完所有页 + 检测远端删除。
  ///
  /// 适用于首次（本地空）、定期、手动同步三种触发时机。
  Future<ReconcileReport> fullReconcile(String accountId) async {
    var page = 0;
    var upserted = 0;
    final remoteIds = <int>{};

    while (true) {
      late final BookmarkPageParseResult result;
      try {
        result = await _fetchPage(page);
      } catch (_) {
        // 任何一页失败都终止：保留已 upsert 的数据，但不做删除清理。
        return ReconcileReport(
          mode: ReconcileMode.full,
          upserted: upserted,
          deleted: 0,
          pagesFetched: page,
          stopReason: ReconcileStopReason.errored,
        );
      }
      if (result.entries.isEmpty) {
        break;
      }

      remoteIds.addAll(result.entries.map((e) => e.bookmarkId));
      await _repository.upsertEntries(accountId, result.entries);
      upserted += result.entries.length;
      page++;
    }

    // 远端没拿到的本地 id = 远端已删除。
    final localIds = await _repository.allBookmarkIds(accountId);
    final deleted = localIds.difference(remoteIds);
    if (deleted.isNotEmpty) {
      await _repository.deleteByIds(accountId, deleted);
    }
    await _markFullSyncCompleted(accountId);
    return ReconcileReport(
      mode: ReconcileMode.full,
      upserted: upserted,
      deleted: deleted.length,
      pagesFetched: page,
      stopReason: ReconcileStopReason.emptyPage,
    );
  }

  /// 下拉刷新：仅拉第一页 upsert，不翻多页、不删除。
  /// 与"对账"在 spec 中明确解耦。
  Future<ReconcileReport> pullToRefresh(String accountId) async {
    try {
      final result = await _fetchPage(0);
      if (result.entries.isNotEmpty) {
        await _repository.upsertEntries(accountId, result.entries);
      }
      return ReconcileReport(
        mode: ReconcileMode.pullToRefresh,
        upserted: result.entries.length,
        deleted: 0,
        pagesFetched: 1,
        stopReason: result.entries.isEmpty
            ? ReconcileStopReason.emptyPage
            : ReconcileStopReason.pageLimitReached,
      );
    } catch (_) {
      return ReconcileReport(
        mode: ReconcileMode.pullToRefresh,
        upserted: 0,
        deleted: 0,
        pagesFetched: 0,
        stopReason: ReconcileStopReason.errored,
      );
    }
  }

  static int get pageLimit => _bookmarksPageLimit;
}

/// 全局 raw page loader Provider：用 [DiscourseService.getUserBookmarksRaw]
/// + [parseBookmarkPage] 组合得到 [BookmarkPageParseResult]。
final bookmarkRawPageLoaderProvider = Provider<BookmarkRawPageLoader>((ref) {
  final service = ref.read(discourseServiceProvider);
  return (page) async {
    final raw = await service.getUserBookmarksRaw(
      page: page,
      limit: BookmarksReconciler.pageLimit,
    );
    return parseBookmarkPage(raw);
  };
});

/// 全局对账器 Provider。
final bookmarksReconcilerProvider = FutureProvider<BookmarksReconciler>((
  ref,
) async {
  final repo = ref.read(bookmarksRepositoryProvider);
  final loader = ref.read(bookmarkRawPageLoaderProvider);
  final prefs = await SharedPreferences.getInstance();
  return BookmarksReconciler(
    repository: repo,
    fetchPage: loader,
    preferences: prefs,
  );
});
