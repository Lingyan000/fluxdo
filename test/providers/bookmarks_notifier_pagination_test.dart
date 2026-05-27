import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/bookmarks_reconciler.dart';
import 'package:fluxdo/providers/bookmarks_repository.dart';
import 'package:fluxdo/providers/user_content_providers.dart';
import 'package:fluxdo/storage/bookmark_cache_dao.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/bookmark_hive_test_support.dart';

// 验证 BookmarksNotifier 的本地分页行为：
// - build 首屏 hydrate 前 _pageSize=30 条
// - hasMore / loadMore / retryLoadMore 真实生效
// - repository.watch 触发的刷新只 hydrate 当前 _loadedCount 范围
//
// 不验证对账网络路径（见 bookmarks_reconciler_test.dart）；测试中把 fetchPage
// loader 替换为永远返回空页的 stub，避免 build 里的 fullReconcile 拉真实 HTTP。

BookmarkCacheEntry _entry({
  required int bookmarkId,
  required DateTime updatedAt,
  String? name,
}) {
  return BookmarkCacheEntry(
    bookmarkId: bookmarkId,
    topicId: bookmarkId,
    nameNormalized: name,
    updatedAt: updatedAt,
    cachedAt: updatedAt,
    payload: {
      'id': bookmarkId,
      '_bookmark_id': bookmarkId,
      '_bookmark_updated_at': updatedAt.toUtc().toIso8601String(),
      '_bookmark_name': ?name,
      'title': 'Topic $bookmarkId',
    },
  );
}

ProviderContainer _container({
  required BookmarksRepository repo,
  required String username,
}) {
  final container = ProviderContainer(
    overrides: [
      bookmarksRepositoryProvider.overrideWithValue(repo),
      currentUsernameProvider.overrideWith((ref) async => username),
      // 让 reconciler 看到 empty page 立即停止，不发 HTTP。
      bookmarkRawPageLoaderProvider.overrideWithValue(
        (_) async => BookmarkPageParseResult(
          topics: const [],
          entries: const [],
          moreUrl: null,
        ),
      ),
    ],
  );
  // 模拟 UI 一直在 watch（否则 autoDispose 在 await 间隙触发，
  // notifier 被销毁 → 下次 read 是新实例处于 AsyncLoading）。
  final sub = container.listen<AsyncValue<List<Topic>>>(
    bookmarksProvider,
    (_, _) {},
  );
  addTearDown(sub.close);
  addTearDown(container.dispose);
  return container;
}

Future<List<BookmarkCacheEntry>> _preset(int count) async {
  // updated_at 递减：bookmark_id=count 最新，=1 最旧。
  return [
    for (var i = count; i >= 1; i--)
      _entry(
        bookmarkId: i,
        updatedAt: DateTime.utc(2026, 1, i),
        name: 'name_$i',
      ),
  ];
}

void main() {
  late BookmarkHiveTestSupport storage;
  late BookmarksRepository repo;
  const username = 'acct';

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // 预设 last_full_sync 为最近时间 → isFullReconcileDue=false → 后台跑
    // incremental reconcile，stub loader 返回 empty 时会立即停止且不删除本地。
    // 否则 full reconcile 会把 remoteIds 视作空 → 误删全部本地缓存。
    SharedPreferences.setMockInitialValues({
      'bookmark_last_full_sync_$username': DateTime.now()
          .toUtc()
          .toIso8601String(),
    });
    storage = await BookmarkHiveTestSupport.create();
    repo = BookmarksRepository(BookmarkCacheDao(boxFactory: storage.openBox));
  });

  tearDown(() async {
    await repo.dispose();
    await storage.dispose();
  });

  test('首屏只 hydrate 前 30 条（_pageSize），hasMore=true', () async {
    await repo.upsertEntries(username, await _preset(70));

    final container = _container(repo: repo, username: username);
    final topics = await container.read(bookmarksProvider.future);

    expect(topics, hasLength(30));
    // bookmark_id=70 是最新的 → 应排第一。
    expect(topics.first.bookmarkId, 70);
    expect(topics.last.bookmarkId, 70 - 29);
    expect(container.read(bookmarksProvider.notifier).hasMore, isTrue);
    expect(container.read(bookmarksProvider.notifier).isLoadMoreFailed, isFalse);
  });

  test('本地总数 ≤ pageSize 时首屏全量 + hasMore=false', () async {
    await repo.upsertEntries(username, await _preset(12));

    final container = _container(repo: repo, username: username);
    final topics = await container.read(bookmarksProvider.future);

    expect(topics, hasLength(12));
    expect(container.read(bookmarksProvider.notifier).hasMore, isFalse);
  });

  test('loadMore 按批追加，最后一批正确收尾', () async {
    await repo.upsertEntries(username, await _preset(70));

    final container = _container(repo: repo, username: username);
    await container.read(bookmarksProvider.future);
    final notifier = container.read(bookmarksProvider.notifier);

    expect(container.read(bookmarksProvider).value, hasLength(30));

    await notifier.loadMore();
    expect(container.read(bookmarksProvider).value, hasLength(60));
    expect(notifier.hasMore, isTrue);

    await notifier.loadMore();
    expect(container.read(bookmarksProvider).value, hasLength(70));
    expect(notifier.hasMore, isFalse);

    // 已到底再 loadMore 是 noop。
    await notifier.loadMore();
    expect(container.read(bookmarksProvider).value, hasLength(70));
  });

  test('loadMore 接续顺序与全量 readAll 一致', () async {
    await repo.upsertEntries(username, await _preset(70));

    final container = _container(repo: repo, username: username);
    await container.read(bookmarksProvider.future);
    final notifier = container.read(bookmarksProvider.notifier);

    await notifier.loadMore();
    await notifier.loadMore();

    final actualIds = container
        .read(bookmarksProvider)
        .value!
        .map((t) => t.bookmarkId)
        .toList();
    // updated_at DESC：70, 69, ..., 1。
    expect(actualIds, [for (var i = 70; i >= 1; i--) i]);
  });

  test('编辑书签（applyMetadataChange）后 listener 只 hydrate 当前窗口', () async {
    await repo.upsertEntries(username, await _preset(70));

    final container = _container(repo: repo, username: username);
    await container.read(bookmarksProvider.future);
    final notifier = container.read(bookmarksProvider.notifier);

    // 加载到 60 条
    await notifier.loadMore();
    expect(container.read(bookmarksProvider).value, hasLength(60));

    // 编辑某条已加载书签的 name → repository.watch 触发刷新
    await repo.applyMetadataChange(
      username,
      50,
      name: 'renamed',
      reminderAt: null,
      bookmarkUpdatedAt: DateTime.utc(2026, 6, 1),
    );
    // 让事件循环跑一下 broadcast + async readByIds（_refreshFromRepository
    // 有多个 await，单个 microtask 不够）
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // 列表大小保持在已展示窗口（60），不会一次性 hydrate 全部 70 条
    expect(container.read(bookmarksProvider).value, hasLength(60));
    // 被改的那条因 updated_at 变成 2026-06-01 应排到最前
    expect(container.read(bookmarksProvider).value!.first.bookmarkId, 50);
    expect(notifier.hasMore, isTrue); // 70 - 60 = 10 条未 hydrate
  });
}
