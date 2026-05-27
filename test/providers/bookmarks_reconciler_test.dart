import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/bookmarks_reconciler.dart';
import 'package:fluxdo/providers/bookmarks_repository.dart';
import 'package:fluxdo/storage/bookmark_cache_dao.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/bookmark_hive_test_support.dart';

BookmarkCacheEntry _entry({
  required int bookmarkId,
  int topicId = 1,
  String? name,
  required DateTime updatedAt,
}) {
  return BookmarkCacheEntry(
    bookmarkId: bookmarkId,
    topicId: topicId,
    nameNormalized: name,
    updatedAt: updatedAt,
    cachedAt: updatedAt,
    payload: {
      'id': topicId,
      '_bookmark_id': bookmarkId,
      '_bookmark_updated_at': updatedAt.toUtc().toIso8601String(),
      '_bookmark_name': ?name,
      'title': 'Topic $topicId',
    },
  );
}

void main() {
  late BookmarkHiveTestSupport storage;
  late BookmarksRepository repo;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    storage = await BookmarkHiveTestSupport.create();
    repo = BookmarksRepository(BookmarkCacheDao(boxFactory: storage.openBox));
  });

  tearDown(() async {
    await repo.dispose();
    await storage.dispose();
  });

  BookmarksReconciler buildReconciler(BookmarkRawPageLoader fetchPage) {
    return BookmarksReconciler(
      repository: repo,
      fetchPage: fetchPage,
      preferences: prefs,
    );
  }

  test('incrementalReconcile 在整页已知未变时立即停止', () async {
    // 本地预置 (1, 2026-01-01) 与 (2, 2026-02-01)
    await repo.upsertEntries('acct', [
      _entry(bookmarkId: 1, updatedAt: DateTime.utc(2026, 1, 1)),
      _entry(bookmarkId: 2, updatedAt: DateTime.utc(2026, 2, 1)),
    ]);

    var pagesFetched = 0;
    final reconciler = buildReconciler((page) async {
      pagesFetched++;
      if (page > 0) {
        return BookmarkPageParseResult(
          topics: const [],
          entries: const [],
          moreUrl: null,
        );
      }
      // 返回完全匹配本地的第一页
      return BookmarkPageParseResult(
        topics: const [],
        entries: [
          _entry(bookmarkId: 1, updatedAt: DateTime.utc(2026, 1, 1)),
          _entry(bookmarkId: 2, updatedAt: DateTime.utc(2026, 2, 1)),
        ],
        moreUrl: null,
      );
    });

    final report = await reconciler.incrementalReconcile('acct');
    expect(report.upserted, 0);
    expect(report.deleted, 0);
    expect(pagesFetched, 1);
    expect(report.stopReason, ReconcileStopReason.allKnownAndUnchanged);
  });

  test('incrementalReconcile 发现新条目时继续翻页直到稳定', () async {
    await repo.upsertEntries('acct', [
      _entry(bookmarkId: 1, updatedAt: DateTime.utc(2026, 1, 1)),
    ]);

    final reconciler = buildReconciler((page) async {
      if (page == 0) {
        return BookmarkPageParseResult(
          topics: const [],
          entries: [
            _entry(bookmarkId: 9, updatedAt: DateTime.utc(2026, 5, 1)),
          ],
          moreUrl: 'p1',
        );
      }
      if (page == 1) {
        // 已知且未变 → 提前停止
        return BookmarkPageParseResult(
          topics: const [],
          entries: [
            _entry(bookmarkId: 1, updatedAt: DateTime.utc(2026, 1, 1)),
          ],
          moreUrl: null,
        );
      }
      return BookmarkPageParseResult(
        topics: const [],
        entries: const [],
        moreUrl: null,
      );
    });

    final report = await reconciler.incrementalReconcile('acct');
    expect(report.upserted, 1);
    expect(report.deleted, 0);
    expect(report.pagesFetched, 2);
    expect(report.stopReason, ReconcileStopReason.allKnownAndUnchanged);
    expect((await repo.allBookmarkIds('acct')), {1, 9});
  });

  test('fullReconcile 翻完所有页后检测删除', () async {
    await repo.upsertEntries('acct', [
      _entry(bookmarkId: 1, updatedAt: DateTime.utc(2026, 1, 1)),
      _entry(bookmarkId: 2, updatedAt: DateTime.utc(2026, 2, 1)),
      _entry(bookmarkId: 3, updatedAt: DateTime.utc(2026, 3, 1)),
    ]);

    final reconciler = buildReconciler((page) async {
      if (page == 0) {
        // 远端只剩 2、4（1 和 3 被删，4 是新）
        return BookmarkPageParseResult(
          topics: const [],
          entries: [
            _entry(bookmarkId: 4, updatedAt: DateTime.utc(2026, 5, 1)),
            _entry(bookmarkId: 2, updatedAt: DateTime.utc(2026, 2, 1)),
          ],
          moreUrl: null,
        );
      }
      return BookmarkPageParseResult(
        topics: const [],
        entries: const [],
        moreUrl: null,
      );
    });

    final report = await reconciler.fullReconcile('acct');
    expect(report.upserted, 2);
    expect(report.deleted, 2); // 1 与 3 被清理
    expect((await repo.allBookmarkIds('acct')), {2, 4});
    expect(reconciler.lastFullSyncAt('acct'), isNotNull);
  });

  test('fullReconcile 中途失败时保留已写入数据但不清理', () async {
    await repo.upsertEntries('acct', [
      _entry(bookmarkId: 1, updatedAt: DateTime.utc(2026, 1, 1)),
    ]);

    final reconciler = buildReconciler((page) async {
      if (page == 0) {
        return BookmarkPageParseResult(
          topics: const [],
          entries: [
            _entry(bookmarkId: 2, updatedAt: DateTime.utc(2026, 5, 1)),
          ],
          moreUrl: 'p1',
        );
      }
      throw Exception('network down');
    });

    final report = await reconciler.fullReconcile('acct');
    expect(report.stopReason, ReconcileStopReason.errored);
    expect(report.upserted, 1);
    expect(report.deleted, 0);
    // 原 (1) 未被清理（remoteIds 不完整时不清理）。
    expect((await repo.allBookmarkIds('acct')), {1, 2});
    expect(reconciler.lastFullSyncAt('acct'), isNull); // 未标记完成
  });

  test('pullToRefresh 只拉第一页 upsert，不删除', () async {
    await repo.upsertEntries('acct', [
      _entry(bookmarkId: 1, updatedAt: DateTime.utc(2026, 1, 1)),
      _entry(bookmarkId: 99, updatedAt: DateTime.utc(2026, 2, 1)),
    ]);

    var pageRequests = 0;
    final reconciler = buildReconciler((page) async {
      pageRequests++;
      return BookmarkPageParseResult(
        topics: const [],
        entries: [
          _entry(bookmarkId: 5, updatedAt: DateTime.utc(2026, 5, 1)),
        ],
        moreUrl: 'p1',
      );
    });

    final report = await reconciler.pullToRefresh('acct');
    expect(pageRequests, 1);
    expect(report.upserted, 1);
    expect(report.deleted, 0);
    // 99 没被清理，5 已插入
    expect((await repo.allBookmarkIds('acct')), {1, 5, 99});
  });

  test('isFullReconcileDue：从未做过 / 间隔过期时返回 true', () async {
    final reconciler = buildReconciler(
      (_) async => BookmarkPageParseResult(
        topics: const [],
        entries: const [],
        moreUrl: null,
      ),
    );
    expect(reconciler.isFullReconcileDue('acct'), isTrue);

    // 标记一次完整完成（用 fullReconcile 触发 _markFullSyncCompleted）
    await reconciler.fullReconcile('acct');
    expect(reconciler.isFullReconcileDue('acct'), isFalse);
  });
}
