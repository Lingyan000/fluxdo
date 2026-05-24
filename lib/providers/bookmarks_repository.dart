import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/topic.dart';
import '../storage/bookmark_cache_dao.dart';
import '../utils/bookmark_name_utils.dart';

/// 单条书签的展示态：从 [BookmarkCacheEntry] 反序列化出 [Topic]，并保留
/// 对账所需的书签自身 `updated_at`。
class BookmarkRecord {
  BookmarkRecord({
    required this.topic,
    required this.bookmarkUpdatedAt,
    required this.cachedAt,
  });

  factory BookmarkRecord.fromEntry(BookmarkCacheEntry entry) {
    return BookmarkRecord(
      topic: Topic.fromJson(entry.payload),
      bookmarkUpdatedAt: entry.updatedAt,
      cachedAt: entry.cachedAt,
    );
  }

  final Topic topic;
  final DateTime bookmarkUpdatedAt;
  final DateTime cachedAt;
}

/// 由远端 bookmarks.json 拉到的单页解析产物。
class BookmarkPageParseResult {
  BookmarkPageParseResult({
    required this.topics,
    required this.entries,
    required this.moreUrl,
  });

  final List<Topic> topics;
  final List<BookmarkCacheEntry> entries;
  final String? moreUrl;
}

/// 把一页 bookmarks.json 原始响应解析成 (Topic 列表, 缓存 entry 列表)。
///
/// 与 [TopicListResponse.fromJson] 共享 [normalizeBookmarkListEntry]，避免两份
/// normalize 实现漂移。
BookmarkPageParseResult parseBookmarkPage(Map<String, dynamic> rawResponse) {
  final usersJson = rawResponse['users'] as List<dynamic>? ?? [];
  final userMap = <int, TopicUser>{
    for (final u in usersJson)
      (u['id'] as int): TopicUser.fromJson(u as Map<String, dynamic>),
  };

  final userBookmarkList =
      rawResponse['user_bookmark_list'] as Map<String, dynamic>?;
  if (userBookmarkList == null) {
    return BookmarkPageParseResult(
      topics: const [],
      entries: const [],
      moreUrl: null,
    );
  }

  final rawBookmarks =
      userBookmarkList['bookmarks'] as List<dynamic>? ?? const [];
  final moreUrl = userBookmarkList['more_bookmarks_url'] as String?;

  final topics = <Topic>[];
  final entries = <BookmarkCacheEntry>[];
  final cachedAt = DateTime.now().toUtc();

  for (final raw in rawBookmarks) {
    final rawMap = Map<String, dynamic>.from(raw as Map);
    final normalized = normalizeBookmarkListEntry(rawMap, userMap: userMap);
    final topic = Topic.fromJson(normalized, userMap: userMap);
    final bookmarkId = normalized['_bookmark_id'] as int?;
    final topicId = normalized['id'] as int?;
    final updatedAtRaw = normalized['_bookmark_updated_at'] as String?;
    if (bookmarkId == null || topicId == null || updatedAtRaw == null) {
      // 容错：缺关键字段就只显示，不写缓存（避免存进去后续对账无法识别）。
      topics.add(topic);
      continue;
    }
    final updatedAt = DateTime.parse(updatedAtRaw);
    topics.add(topic);
    entries.add(
      BookmarkCacheEntry(
        bookmarkId: bookmarkId,
        topicId: topicId,
        nameNormalized: normalizeBookmarkName(
          normalized['_bookmark_name'] as String?,
        ),
        updatedAt: updatedAt,
        cachedAt: cachedAt,
        payload: normalized,
      ),
    );
  }

  return BookmarkPageParseResult(
    topics: topics,
    entries: entries,
    moreUrl: moreUrl,
  );
}

/// 书签本地缓存 + 远端对账的统一入口。
///
/// 上层（[BookmarksNotifier]、`bookmarkNameSuggestionsProvider`）通过它读取
/// 本地数据并订阅变更；编辑/新建/删除书签后调它写穿本地缓存。
///
/// 不在此处发起对账请求——那是 `BookmarksReconciler` 的职责，但都通过本类
/// 改写本地缓存。
class BookmarksRepository {
  BookmarksRepository(this._dao);

  final BookmarkCacheDao _dao;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// 任何写入完成后会广播一次（不带数据，订阅方收到后自行 readAll）。
  Stream<void> watch() => _changes.stream;

  Future<List<BookmarkRecord>> readAll(String accountId) async {
    final entries = await _dao.readAll(accountId);
    return entries.map(BookmarkRecord.fromEntry).toList(growable: false);
  }

  Future<Map<int, String>> snapshotById(String accountId) {
    return _dao.snapshotById(accountId);
  }

  Future<Set<int>> allBookmarkIds(String accountId) {
    return _dao.allBookmarkIds(accountId);
  }

  Future<void> upsertEntries(
    String accountId,
    List<BookmarkCacheEntry> entries,
  ) async {
    if (entries.isEmpty) return;
    await _dao.upsertAll(accountId, entries);
    _notify();
  }

  Future<void> upsertOne(String accountId, BookmarkCacheEntry entry) async {
    await _dao.upsertOne(accountId, entry);
    _notify();
  }

  Future<void> deleteByIds(String accountId, Set<int> bookmarkIds) async {
    if (bookmarkIds.isEmpty) return;
    await _dao.deleteByIds(accountId, bookmarkIds);
    _notify();
  }

  Future<void> deleteOne(String accountId, int bookmarkId) async {
    await _dao.deleteOne(accountId, bookmarkId);
    _notify();
  }

  Future<void> clearAccount(String accountId) async {
    await _dao.clearAccount(accountId);
    _notify();
  }

  /// 本地修改书签元数据后调用：读出旧 entry → 改 payload 的 _bookmark_name /
  /// _bookmark_reminder_at / _bookmark_updated_at → 写回。
  ///
  /// [bookmarkUpdatedAt] 由调用方传入：服务端写入成功后客户端用当前时间作
  /// 占位，下次对账拉到真实服务端值会覆盖。
  Future<void> applyMetadataChange(
    String accountId,
    int bookmarkId, {
    required String? name,
    required DateTime? reminderAt,
    required DateTime bookmarkUpdatedAt,
  }) async {
    final snapshot = await _dao.snapshotById(accountId);
    if (!snapshot.containsKey(bookmarkId)) return;
    final all = await _dao.readAll(accountId);
    final existing = all.firstWhere(
      (e) => e.bookmarkId == bookmarkId,
      orElse: () => throw StateError('bookmark $bookmarkId snapshot 与 readAll 不一致'),
    );
    final payload = Map<String, dynamic>.from(existing.payload);
    final normalizedName = normalizeBookmarkName(name);
    if (normalizedName == null) {
      payload.remove('_bookmark_name');
    } else {
      payload['_bookmark_name'] = normalizedName;
    }
    if (reminderAt == null) {
      payload.remove('_bookmark_reminder_at');
    } else {
      payload['_bookmark_reminder_at'] = reminderAt.toUtc().toIso8601String();
    }
    payload['_bookmark_updated_at'] = bookmarkUpdatedAt.toUtc().toIso8601String();

    await _dao.upsertOne(
      accountId,
      BookmarkCacheEntry(
        bookmarkId: existing.bookmarkId,
        topicId: existing.topicId,
        nameNormalized: normalizedName,
        updatedAt: bookmarkUpdatedAt,
        cachedAt: DateTime.now().toUtc(),
        payload: payload,
      ),
    );
    _notify();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() async {
    await _changes.close();
  }
}

/// 全局 [BookmarksRepository] Provider。
final bookmarksRepositoryProvider = Provider<BookmarksRepository>((ref) {
  final repo = BookmarksRepository(BookmarkCacheDao());
  ref.onDispose(() {
    unawaited(repo.dispose());
  });
  return repo;
});
