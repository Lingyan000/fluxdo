import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/topic.dart';
import '../pages/bookmarks/bookmarks_models.dart';
import 'bookmarks_repository.dart';
import 'core_providers.dart';

/// 兼容 stub：方案 E 重构后此 provider 不再驱动候选加载（候选已从
/// [BookmarksRepository] 派生）。仅保留以兼容旧 test override，调用者
/// 不应依赖其行为。
@Deprecated(
  'Bookmark name suggestions now derive from BookmarksRepository directly; '
  'this provider is retained as a stub for legacy tests only.',
)
final bookmarkNameSuggestionPageLoaderProvider =
    Provider<BookmarkPageLoader>((ref) {
      final service = ref.read(discourseServiceProvider);
      return (page, limit) => service.getUserBookmarks(page: page, limit: limit);
    });

/// 书签名候选 Notifier。
///
/// 方案 E 下：数据源从 [BookmarksRepository]（Hive 本地缓存）派生，不再单独
/// 持久化候选名集合，也不再独立发起网络请求拉全量——这些职责归给 repository
/// 与 [BookmarksReconciler]。候选聚合通过 `repository.nameCounts` 直接在
/// DAO 层完成，不需要 jsonDecode payload。
///
/// 仍保留旧 API（[seedFromTopics] / [rememberName] / [markDirty] /
/// [ensureLoaded] / [prefetchIfEmpty] / [clearCache]）以最小代价兼容现有
/// 调用方；语义已退化为"从 repository 重新派生 / 乐观插入"。
class BookmarkNameSuggestionsNotifier extends Notifier<List<String>> {
  String? _accountId;
  StreamSubscription<void>? _repoSubscription;
  Future<void>? _initFuture;

  @override
  List<String> build() {
    final repo = ref.read(bookmarksRepositoryProvider);
    _repoSubscription = repo.watch().listen((_) {
      unawaited(_refreshFromRepo(repo));
    });
    ref.onDispose(() {
      _repoSubscription?.cancel();
    });
    _initFuture = _initialize(repo);
    return const <String>[];
  }

  Future<void> _initialize(BookmarksRepository repo) async {
    final service = ref.read(discourseServiceProvider);
    final username = await service.getUsername();
    if (username == null) return;
    _accountId = username;
    await _refreshFromRepo(repo);
  }

  Future<void> _refreshFromRepo(BookmarksRepository repo) async {
    final accountId = _accountId;
    if (accountId == null) return;
    final counts = await repo.nameCounts(accountId);
    if (!ref.mounted) return;
    final sorted = counts.keys.toList()
      ..sort((a, b) {
        final cmp = counts[b]!.compareTo(counts[a]!);
        if (cmp != 0) return cmp;
        return a.compareTo(b);
      });
    state = List<String>.unmodifiable(sorted);
  }

  /// 兼容旧 API：seed 的语义在新方案下由 repository 自动覆盖，noop。
  /// 参数保留是为了避免大面积改 caller，[topics] / [isCompleteSnapshot] 暂未使用。
  // ignore: avoid_unused_constructor_parameters
  void seedFromTopics(List<Topic> topics, {bool isCompleteSnapshot = false}) {}

  /// 乐观插入一个名字到候选中：用户刚编辑/新建一个书签时，repository 写穿
  /// 通常会触发 [_refreshFromRepo] 覆盖；这里只是为了 UI 立即响应。
  void rememberName(String? name) {
    final normalized = normalizeBookmarkName(name);
    if (normalized == null || state.contains(normalized)) return;
    state = List<String>.unmodifiable([...state, normalized]);
  }

  /// 兼容旧 API：触发一次乐观插入；repository.watch 会自动覆盖。
  void markDirty({String? optimisticName}) {
    rememberName(optimisticName);
  }

  /// 兼容旧 API：让 caller 强制等一次"加载完成"。新方案下我们只是从
  /// repository 重新派生——如果 repository 还在对账中，结果可能不完整，
  /// 但不会阻塞编辑面板打开。
  Future<List<String>> ensureLoaded() async {
    final init = _initFuture;
    if (init != null) {
      try {
        await init;
      } catch (_) {
        // 初始化失败不应该卡住编辑面板，保留当前 state 返回。
      }
    }
    final accountId = _accountId;
    if (accountId == null) return state;
    final repo = ref.read(bookmarksRepositoryProvider);
    await _refreshFromRepo(repo);
    return state;
  }

  /// 兼容旧 API：state 为空时后台触发一次 [ensureLoaded]。
  void prefetchIfEmpty() {
    if (state.isNotEmpty) return;
    unawaited(ensureLoaded().then((_) => null, onError: (_) => null));
  }

  void clearCache() {
    state = const <String>[];
  }
}

final bookmarkNameSuggestionsProvider =
    NotifierProvider<BookmarkNameSuggestionsNotifier, List<String>>(
      BookmarkNameSuggestionsNotifier.new,
    );
