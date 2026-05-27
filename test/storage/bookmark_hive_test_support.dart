import 'dart:io';

import 'package:hive_ce/hive.dart';

/// 书签缓存测试用的 Hive box 工厂——每个实例一个临时目录，自动隔离。
///
/// 用法：
/// ```dart
/// late BookmarkHiveTestSupport storage;
/// setUp(() async {
///   storage = await BookmarkHiveTestSupport.create();
/// });
/// tearDown(() async {
///   await storage.dispose();
/// });
/// final dao = BookmarkCacheDao(boxFactory: storage.openBox);
/// ```
class BookmarkHiveTestSupport {
  BookmarkHiveTestSupport._(this._dir);

  static int _instanceSeq = 0;

  final Directory _dir;
  final Map<String, Box<Map>> _open = {};
  late final int _id = ++_instanceSeq;

  static Future<BookmarkHiveTestSupport> create() async {
    final dir = await Directory.systemTemp.createTemp('bookmark_hive_test_');
    return BookmarkHiveTestSupport._(dir);
  }

  Future<Box<Map>> openBox(String accountId) async {
    final name = 'bm_${_id}_$accountId';
    final cached = _open[name];
    if (cached != null) return cached;
    final box = await Hive.openBox<Map>(name, path: _dir.path);
    _open[name] = box;
    return box;
  }

  Future<void> dispose() async {
    for (final box in _open.values) {
      if (box.isOpen) await box.close();
    }
    _open.clear();
    if (await _dir.exists()) {
      try {
        await _dir.delete(recursive: true);
      } catch (_) {
        // 临时目录清理失败不影响测试断言。
      }
    }
  }
}
