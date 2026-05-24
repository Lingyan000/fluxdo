import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 应用级 sqflite 数据库单例。
///
/// 移动端（iOS / Android）走默认 [databaseFactory]；桌面端（Windows / Linux /
/// macOS）显式切到 [databaseFactoryFfi]。Web 不在支持范围内——若被错误地引入
/// 到 Web 构建，[ensureInitialized] 会抛错以暴露问题。
class AppDatabase {
  AppDatabase._();

  static const String _fileName = 'fluxdo.db';
  static const int _schemaVersion = 1;

  static Database? _instance;
  static Future<Database>? _opening;

  /// 获取数据库实例，按需打开。
  static Future<Database> instance() {
    if (_instance != null) return Future.value(_instance);
    return _opening ??= _open().whenComplete(() => _opening = null);
  }

  /// 测试用：替换底层 [Database] 实例。
  @visibleForTesting
  static void debugOverrideInstance(Database? database) {
    _instance = database;
  }

  /// 测试用：复位状态，下次调用 [instance] 会重新打开。
  @visibleForTesting
  static Future<void> debugReset() async {
    final current = _instance;
    _instance = null;
    _opening = null;
    if (current != null && current.isOpen) {
      await current.close();
    }
  }

  static Future<Database> _open() async {
    if (kIsWeb) {
      throw UnsupportedError(
        'AppDatabase 不支持 Web 平台：书签本地缓存仅在移动端与桌面端可用。',
      );
    }
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final directory = await getApplicationDocumentsDirectory();
    final dbPath = p.join(directory.path, _fileName);
    final db = await openDatabase(
      dbPath,
      version: _schemaVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onConfigure: _onConfigure,
    );
    _instance = db;
    return db;
  }

  static Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON;');
  }

  static Future<void> _onCreate(Database db, int version) async {
    await _createBookmarkCacheTable(db);
  }

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    // 后续 schema 升级在此分支处理。当前只有 v1。
  }

  static Future<void> _createBookmarkCacheTable(Database db) async {
    // 缓存书签元数据。account_id + bookmark_id 复合主键支持多账号隔离。
    // payload 保存的是 bookmarks.json 接口里 normalize 后的 topic-like JSON，
    // 反序列化时直接调 Topic.fromJson(payload)。
    await db.execute('''
      CREATE TABLE bookmark_cache (
        account_id        TEXT    NOT NULL,
        bookmark_id       INTEGER NOT NULL,
        topic_id          INTEGER NOT NULL,
        name_normalized   TEXT,
        updated_at        TEXT    NOT NULL,
        cached_at         TEXT    NOT NULL,
        payload           TEXT    NOT NULL,
        PRIMARY KEY (account_id, bookmark_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_bm_cache_acct_updated '
      'ON bookmark_cache(account_id, updated_at DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_bm_cache_acct_name '
      'ON bookmark_cache(account_id, name_normalized)',
    );
  }
}
