import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用级 Hive 存储初始化与按账号 box 工厂。
///
/// 书签缓存采用「每账号一个 box」的方式做隔离，box 名形如
/// `bookmark_cache_<sanitized_account_id>`。box 中：
/// - key   = `bookmark_id` (int)
/// - value = `Map`，含 `topic_id` / `name_normalized` / `updated_at` /
///   `cached_at` / `payload`（payload 为 normalize 后的 topic-like JSON 字符串）
///
/// 把 `name_normalized`、`updated_at` 拆成顶层字段是为了让聚合 /
/// 增量对账等操作不必再 jsonDecode 整个 payload，发挥 Hive box 的随机访问优势。
///
/// 纯 Dart，无 native 依赖；移动端 / 桌面端 / Web 都可用。
class AppDatabase {
  AppDatabase._();

  static const String _bookmarkBoxPrefix = 'bookmark_cache_';

  static bool _initialized = false;
  static Future<void>? _initializing;
  static final Map<String, Box<Map>> _openBoxes = <String, Box<Map>>{};
  static final Map<String, Future<Box<Map>>> _openingBoxes =
      <String, Future<Box<Map>>>{};

  /// 测试可注入：替换 box 工厂（内存 box / 自定义临时目录等）。
  @visibleForTesting
  static Future<Box<Map>> Function(String accountId)? debugBoxFactory;

  /// 测试可注入：跳过默认初始化路径，直接走 [debugBoxFactory]。
  @visibleForTesting
  static void debugMarkInitialized() {
    _initialized = true;
  }

  /// 测试用：复位状态。
  @visibleForTesting
  static Future<void> debugReset() async {
    _initialized = false;
    _initializing = null;
    debugBoxFactory = null;
    _openBoxes.clear();
    _openingBoxes.clear();
  }

  /// 获取某账号对应的书签缓存 box，按需初始化 Hive 并打开。
  /// 一旦打开后会缓存 box 实例，后续调用直接命中缓存（同步路径，仅一次 await）。
  static Future<Box<Map>> bookmarkBox(String accountId) async {
    final factory = debugBoxFactory;
    if (factory != null) {
      return factory(accountId);
    }
    await _ensureInitialized();
    final name = _bookmarkBoxName(accountId);
    final cached = _openBoxes[name];
    if (cached != null && cached.isOpen) return cached;
    final pending = _openingBoxes[name];
    if (pending != null) return pending;
    final opening = Hive.openBox<Map>(name);
    _openingBoxes[name] = opening;
    try {
      final box = await opening;
      _openBoxes[name] = box;
      return box;
    } finally {
      _openingBoxes.remove(name);
    }
  }

  static Future<void> _ensureInitialized() {
    if (_initialized) return Future.value();
    return _initializing ??= _initialize().whenComplete(
      () => _initializing = null,
    );
  }

  static Future<void> _initialize() async {
    if (kIsWeb) {
      // Web 暂时不走本地缓存——上层 BookmarksNotifier 在 username 为空时
      // 直接返回空表，这里抛错是为了在被错误地引入到 Web 构建时尽早暴露。
      throw UnsupportedError(
        'AppDatabase 暂不支持 Web 平台：书签本地缓存仅在移动端与桌面端启用。',
      );
    }
    final directory = await getApplicationDocumentsDirectory();
    Hive.init(p.join(directory.path, 'hive'));
    _initialized = true;
  }

  static String _bookmarkBoxName(String accountId) {
    // Hive box 名只允许字母/数字/下划线/连字符；把其它字符（如 @、空格、中文）
    // 替换为 `_`，避免某些平台底层文件系统不接受。
    final sanitized = accountId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return '$_bookmarkBoxPrefix$sanitized';
  }

  /// 仅供 [BookmarkCacheDao.clearAccount] 在删除账号后顺手释放句柄。
  static Future<void> closeBookmarkBox(String accountId) async {
    if (debugBoxFactory != null) return; // 测试自行管理生命周期
    final name = _bookmarkBoxName(accountId);
    _openBoxes.remove(name);
    if (Hive.isBoxOpen(name)) {
      await Hive.box<Map>(name).close();
    }
  }
}
