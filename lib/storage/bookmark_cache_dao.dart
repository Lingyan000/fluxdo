import 'dart:convert';

import 'package:hive_ce/hive.dart';

import 'app_database.dart';

/// 单条书签缓存数据。
///
/// [updatedAt] 是 Discourse 书签自身的 `updated_at`（书签 name / reminder 被改时
/// 会变），用于对账提前停止判断。[payload] 是 `bookmarks.json` 接口里
/// normalize 后的 topic-like JSON Map，反序列化时直接调 `Topic.fromJson`。
class BookmarkCacheEntry {
  const BookmarkCacheEntry({
    required this.bookmarkId,
    required this.topicId,
    required this.nameNormalized,
    required this.updatedAt,
    required this.cachedAt,
    required this.payload,
  });

  final int bookmarkId;
  final int topicId;
  final String? nameNormalized;
  final DateTime updatedAt;
  final DateTime cachedAt;
  final Map<String, dynamic> payload;
}

/// 注入式 box 工厂，测试可传入内存 box 的工厂。
typedef BookmarkBoxFactory = Future<Box<Map>> Function(String accountId);

/// 书签缓存 DAO：直接面向 Hive box，账号维度隔离（每账号一个 box）。
///
/// box value 拆字段存储：`topic_id` / `name_normalized` / `updated_at` /
/// `cached_at` / `payload`（payload 是 jsonEncode 的 topic-like map）。
/// 拆字段是为了让聚合 / 对账等不需要 payload 的接口跳过 jsonDecode。
class BookmarkCacheDao {
  BookmarkCacheDao({BookmarkBoxFactory? boxFactory})
    : _boxFactory = boxFactory ?? AppDatabase.bookmarkBox;

  final BookmarkBoxFactory _boxFactory;

  static const String _kTopicId = 'topic_id';
  static const String _kName = 'name_normalized';
  static const String _kUpdatedAt = 'updated_at';
  static const String _kCachedAt = 'cached_at';
  static const String _kPayload = 'payload';

  /// 读取某账号下全部书签缓存，按 [updatedAt] 倒序。
  Future<List<BookmarkCacheEntry>> readAll(String accountId) async {
    final box = await _boxFactory(accountId);
    final entries = <BookmarkCacheEntry>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw == null) continue;
      final id = (key as num).toInt();
      entries.add(_entryFromBox(id, raw));
    }
    entries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(entries);
  }

  /// 拿到按 [updatedAt] 倒序的 bookmark_id 列表，不反序列化 payload。
  /// 上层（Notifier）用它做本地分页：先拿全量顺序，再按需 [readByIds] 反序列化。
  Future<List<int>> idsOrderedByUpdated(String accountId) async {
    final box = await _boxFactory(accountId);
    final pairs = <_IdUpdatedAtPair>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw == null) continue;
      final updatedAt = raw[_kUpdatedAt] as String?;
      if (updatedAt == null) continue;
      pairs.add(_IdUpdatedAtPair((key as num).toInt(), updatedAt));
    }
    // updated_at 是同源 ISO8601 字符串，逐字符比较即可保持 DESC 顺序。
    pairs.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(pairs.map((p) => p.id));
  }

  /// 按 id 列表批量反序列化。返回顺序与 [ids] 一致；缺失的 id 会被跳过。
  /// 用于本地分页 hydrate：上层拿 [idsOrderedByUpdated] 切片后调它。
  Future<List<BookmarkCacheEntry>> readByIds(
    String accountId,
    List<int> ids,
  ) async {
    if (ids.isEmpty) return const [];
    final box = await _boxFactory(accountId);
    final entries = <BookmarkCacheEntry>[];
    for (final id in ids) {
      final raw = box.get(id);
      if (raw == null) continue;
      entries.add(_entryFromBox(id, raw));
    }
    return List.unmodifiable(entries);
  }

  /// 单点读取：用于本地编辑、增量对账中按 id 取出旧值。避免上层做 readAll 再 firstWhere。
  Future<BookmarkCacheEntry?> findOne(String accountId, int bookmarkId) async {
    final box = await _boxFactory(accountId);
    final raw = box.get(bookmarkId);
    if (raw == null) return null;
    return _entryFromBox(bookmarkId, raw);
  }

  /// 拿到 (bookmark_id -> updated_at) 的快照，用于对账判断「本页是否全部已知未变」。
  /// updated_at 用 ISO8601 字符串比较（同源同格式，可逐字符相等判断）。
  /// 不会 jsonDecode payload。
  Future<Map<int, String>> snapshotById(String accountId) async {
    final box = await _boxFactory(accountId);
    final result = <int, String>{};
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw == null) continue;
      final updatedAt = raw[_kUpdatedAt] as String?;
      if (updatedAt == null) continue;
      result[(key as num).toInt()] = updatedAt;
    }
    return result;
  }

  /// 拿到某账号下所有 bookmark_id 的集合，用于完整对账时检测远端删除。
  Future<Set<int>> allBookmarkIds(String accountId) async {
    final box = await _boxFactory(accountId);
    return {for (final key in box.keys) (key as num).toInt()};
  }

  /// 聚合 (name_normalized -> count)，用于书签名候选 / 顶部筛选条。
  /// 只读 name 字段，不 jsonDecode payload。
  Future<Map<String, int>> nameCounts(String accountId) async {
    final box = await _boxFactory(accountId);
    final counts = <String, int>{};
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw == null) continue;
      final name = raw[_kName] as String?;
      if (name == null || name.isEmpty) continue;
      counts.update(name, (v) => v + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  /// 批量 upsert：账号下同 bookmark_id 已存在则覆盖。
  Future<void> upsertAll(
    String accountId,
    List<BookmarkCacheEntry> entries,
  ) async {
    if (entries.isEmpty) return;
    final box = await _boxFactory(accountId);
    final now = DateTime.now().toUtc().toIso8601String();
    await box.putAll({
      for (final entry in entries)
        entry.bookmarkId: _entryToBox(entry, fallbackCachedAt: now),
    });
  }

  Future<void> upsertOne(String accountId, BookmarkCacheEntry entry) async {
    final box = await _boxFactory(accountId);
    final now = DateTime.now().toUtc().toIso8601String();
    await box.put(
      entry.bookmarkId,
      _entryToBox(entry, fallbackCachedAt: now),
    );
  }

  Future<void> deleteByIds(String accountId, Set<int> bookmarkIds) async {
    if (bookmarkIds.isEmpty) return;
    final box = await _boxFactory(accountId);
    await box.deleteAll(bookmarkIds);
  }

  Future<void> deleteOne(String accountId, int bookmarkId) async {
    final box = await _boxFactory(accountId);
    await box.delete(bookmarkId);
  }

  /// 清空整个账号的缓存（账号注销 / 数据损坏自愈使用）。
  Future<void> clearAccount(String accountId) async {
    final box = await _boxFactory(accountId);
    await box.clear();
  }

  BookmarkCacheEntry _entryFromBox(int bookmarkId, Map raw) {
    final payloadStr = raw[_kPayload] as String;
    return BookmarkCacheEntry(
      bookmarkId: bookmarkId,
      topicId: (raw[_kTopicId] as num).toInt(),
      nameNormalized: raw[_kName] as String?,
      updatedAt: DateTime.parse(raw[_kUpdatedAt] as String),
      cachedAt: DateTime.parse(raw[_kCachedAt] as String),
      payload: jsonDecode(payloadStr) as Map<String, dynamic>,
    );
  }

  Map<String, dynamic> _entryToBox(
    BookmarkCacheEntry entry, {
    required String fallbackCachedAt,
  }) {
    return {
      _kTopicId: entry.topicId,
      _kName: entry.nameNormalized,
      _kUpdatedAt: entry.updatedAt.toUtc().toIso8601String(),
      _kCachedAt: fallbackCachedAt,
      _kPayload: jsonEncode(entry.payload),
    };
  }
}

class _IdUpdatedAtPair {
  const _IdUpdatedAtPair(this.id, this.updatedAt);
  final int id;
  final String updatedAt;
}
