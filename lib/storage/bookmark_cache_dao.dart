import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

/// 注入式数据库工厂，测试可传入内存库的工厂。
typedef DatabaseFactoryAsync = Future<Database> Function();

/// 书签缓存 DAO：直接面向 sqflite，账号维度隔离。
class BookmarkCacheDao {
  BookmarkCacheDao({DatabaseFactoryAsync? databaseFactory})
    : _databaseFactory = databaseFactory ?? AppDatabase.instance;

  final DatabaseFactoryAsync _databaseFactory;

  static const String _table = 'bookmark_cache';

  /// 读取某账号下全部书签缓存，按 [updatedAt] 倒序（与服务端 bookmarks.json 默认顺序一致）。
  Future<List<BookmarkCacheEntry>> readAll(String accountId) async {
    final db = await _databaseFactory();
    final rows = await db.query(
      _table,
      where: 'account_id = ?',
      whereArgs: [accountId],
      orderBy: 'updated_at DESC',
    );
    return rows.map(_rowToEntry).toList(growable: false);
  }

  /// 拿到 (bookmark_id -> updated_at) 的快照，用于对账判断"本页是否全部已知未变"。
  /// updated_at 用 ISO8601 字符串比较（同源同格式，可逐字符相等判断）。
  Future<Map<int, String>> snapshotById(String accountId) async {
    final db = await _databaseFactory();
    final rows = await db.query(
      _table,
      columns: ['bookmark_id', 'updated_at'],
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
    return {
      for (final row in rows)
        row['bookmark_id'] as int: row['updated_at'] as String,
    };
  }

  /// 拿到某账号下所有 bookmark_id 的集合，用于完整对账时检测远端删除。
  Future<Set<int>> allBookmarkIds(String accountId) async {
    final db = await _databaseFactory();
    final rows = await db.query(
      _table,
      columns: ['bookmark_id'],
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
    return rows.map((row) => row['bookmark_id'] as int).toSet();
  }

  /// 批量 upsert：账号下同 bookmark_id 已存在则覆盖。
  Future<void> upsertAll(
    String accountId,
    List<BookmarkCacheEntry> entries,
  ) async {
    if (entries.isEmpty) return;
    final db = await _databaseFactory();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final entry in entries) {
        batch.insert(
          _table,
          _entryToRow(accountId, entry, fallbackCachedAt: now),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> upsertOne(String accountId, BookmarkCacheEntry entry) async {
    final db = await _databaseFactory();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert(
      _table,
      _entryToRow(accountId, entry, fallbackCachedAt: now),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteByIds(String accountId, Set<int> bookmarkIds) async {
    if (bookmarkIds.isEmpty) return;
    final db = await _databaseFactory();
    // sqflite 不支持参数化数组，手动拼 placeholder。bookmark_id 是 int，无注入风险。
    final placeholders = List.filled(bookmarkIds.length, '?').join(',');
    await db.delete(
      _table,
      where: 'account_id = ? AND bookmark_id IN ($placeholders)',
      whereArgs: [accountId, ...bookmarkIds],
    );
  }

  Future<void> deleteOne(String accountId, int bookmarkId) async {
    final db = await _databaseFactory();
    await db.delete(
      _table,
      where: 'account_id = ? AND bookmark_id = ?',
      whereArgs: [accountId, bookmarkId],
    );
  }

  /// 清空整个账号的缓存（账号注销 / 数据损坏自愈使用）。
  Future<void> clearAccount(String accountId) async {
    final db = await _databaseFactory();
    await db.delete(_table, where: 'account_id = ?', whereArgs: [accountId]);
  }

  BookmarkCacheEntry _rowToEntry(Map<String, Object?> row) {
    return BookmarkCacheEntry(
      bookmarkId: row['bookmark_id'] as int,
      topicId: row['topic_id'] as int,
      nameNormalized: row['name_normalized'] as String?,
      updatedAt: DateTime.parse(row['updated_at'] as String),
      cachedAt: DateTime.parse(row['cached_at'] as String),
      payload: jsonDecode(row['payload'] as String) as Map<String, dynamic>,
    );
  }

  Map<String, Object?> _entryToRow(
    String accountId,
    BookmarkCacheEntry entry, {
    required String fallbackCachedAt,
  }) {
    return {
      'account_id': accountId,
      'bookmark_id': entry.bookmarkId,
      'topic_id': entry.topicId,
      'name_normalized': entry.nameNormalized,
      'updated_at': entry.updatedAt.toUtc().toIso8601String(),
      'cached_at': fallbackCachedAt,
      'payload': jsonEncode(entry.payload),
    };
  }
}
