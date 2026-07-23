import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import 'discourse_cache_manager.dart';
import 'network/cookie/cookie_jar_service.dart';

/// 迁移项定义
class Migration {
  const Migration({
    required this.key,
    required this.name,
    required this.shouldRun,
    required this.run,
  });

  /// SharedPreferences 标记键
  final String key;

  /// 迁移名称（日志用）
  final String name;

  /// 前置检查：返回 true 才真正执行
  /// 全新安装时应返回 false（没有旧数据需要迁移）
  final Future<bool> Function(SharedPreferences prefs) shouldRun;

  /// 执行迁移
  final Future<void> Function() run;
}

/// 统一迁移服务
/// 新增迁移只需在 [_migrations] 列表末尾追加一条即可。
class MigrationService {
  MigrationService._();

  /// 本次启动是否需要重新登录（供 UI 弹 Dialog 用）
  static bool requiresRelogin = false;

  /// 按顺序执行的迁移列表
  static final _migrations = <Migration>[
    // v2: enhanced_cookie_jar 切换 — 清空旧 cookie 存储，要求重新登录
    Migration(
      key: 'cookie_clean_slate_v2',
      name: 'Cookie clean slate',
      shouldRun: (prefs) async {
        // 旧迁移标记存在 → 老用户
        if (prefs.getBool('cookie_domain_migration_v2') == true) return true;
        // 兜底：CookieJar 中有登录 token
        try {
          final jar = CookieJarService();
          if (!jar.isInitialized) await jar.initialize();
          final token = await jar.getTToken();
          return token != null && token.isNotEmpty;
        } catch (_) {
          return false;
        }
      },
      run: () async {
        final jar = CookieJarService();
        if (!jar.isInitialized) await jar.initialize();
        await jar.clearAll();
        requiresRelogin = true;
      },
    ),
    // v3: 浏览器优先双通道切换 — 对存量用户执行一次全量 Cookie 清理，避免旧污染状态残留
    Migration(
      key: 'cookie_clean_slate_v3',
      name: 'Cookie clean slate v3',
      shouldRun: (prefs) async {
        if (_hasLegacyCookieMigrationMarker(prefs)) return true;
        try {
          final jar = CookieJarService();
          if (!jar.isInitialized) await jar.initialize();
          final token = await jar.getTToken();
          final cfClearance = await jar.getCfClearance();
          return (token != null && token.isNotEmpty) ||
              (cfClearance != null && cfClearance.isNotEmpty) ||
              prefs.getString('linux_do_username')?.isNotEmpty == true;
        } catch (_) {
          return prefs.getString('linux_do_username')?.isNotEmpty == true;
        }
      },
      run: () async {
        final jar = CookieJarService();
        if (!jar.isInitialized) await jar.initialize();
        await jar.clearAll();
        requiresRelogin = true;
      },
    ),
    // v4: storageKey 放宽（去掉 hostOnly）— 清理旧 cookie 防止多副本残留
    // 只要不是全新安装就清除（游客也可能有残留重复 cookie）
    Migration(
      key: 'cookie_relaxed_key_v4',
      name: 'Relaxed storageKey migration',
      shouldRun: (prefs) async {
        // 有任何旧迁移标记 = 非全新安装
        if (_hasLegacyCookieMigrationMarker(prefs)) return true;
        // jar 中有 cookie = 非全新安装
        try {
          final jar = CookieJarService();
          if (!jar.isInitialized) await jar.initialize();
          final cookies = await jar.cookieJar.loadForRequest(
            Uri.parse(AppConstants.baseUrl),
          );
          return cookies.isNotEmpty;
        } catch (_) {
          return false;
        }
      },
      run: () async {
        final jar = CookieJarService();
        if (!jar.isInitialized) await jar.initialize();
        await jar.clearAll();
        requiresRelogin = true;
      },
    ),
    // v5 (cookie 引擎 v0.4.0): RawSetCookieQueue 移除
    // 把 .cookies/pending_set_cookies.json 队列文件中残留的 cookie 回灌到 jar
    // 然后删除文件。不强制重登。
    // 设计依据: docs/cookie-sync-design-v0.4.0.md §8.5
    Migration(
      key: 'cookie_queue_removed_v5',
      name: 'RawSetCookieQueue removal migration',
      shouldRun: (prefs) async {
        try {
          final dir = await getApplicationDocumentsDirectory();
          final queueFile = io.File(
            p.join(dir.path, '.cookies', 'pending_set_cookies.json'),
          );
          return await queueFile.exists();
        } catch (_) {
          return false;
        }
      },
      run: () async {
        try {
          final dir = await getApplicationDocumentsDirectory();
          final queueFile = io.File(
            p.join(dir.path, '.cookies', 'pending_set_cookies.json'),
          );
          if (!await queueFile.exists()) return;

          final content = await queueFile.readAsString();
          if (content.trim().isNotEmpty) {
            final jar = CookieJarService();
            if (!jar.isInitialized) await jar.initialize();
            try {
              final entries = jsonDecode(content) as List;
              for (final raw in entries) {
                if (raw is! Map) continue;
                final url = raw['url']?.toString();
                final header = raw['raw']?.toString();
                if (url == null || header == null) continue;
                final uri = Uri.tryParse(url);
                if (uri == null) continue;
                try {
                  await jar.cookieJar.saveFromResponse(uri, [
                    io.Cookie.fromSetCookieValue(header),
                  ]);
                } catch (e) {
                  debugPrint(
                    '[Migration v5] 单条 cookie 回灌失败 url=$url: $e',
                  );
                }
              }
            } catch (e) {
              debugPrint('[Migration v5] 解析队列文件失败: $e');
            }
          }
          await queueFile.delete();
          debugPrint('[Migration v5] 已清理 RawSetCookieQueue 持久化文件');
        } catch (e) {
          debugPrint('[Migration v5] 失败 (忽略): $e');
        }
      },
    ),
    // v6: 图片缓存索引从自研 Hive repo 迁回 flutter_cache_manager 默认后端
    // (移动端 / macOS = sqlite 事务安全; Windows / Linux = Json 纯 Dart)。
    // 旧的 image_cache_meta_* Hive box 不再使用,其中损坏的 box 正是
    // "unknown typeId" 崩溃源,一次性删除。图片文件本身仍在,索引重建 =
    // 首次访问按需重新下载,无数据损失。
    Migration(
      key: 'image_cache_meta_hive_purge_v6',
      name: 'Purge legacy Hive image cache index',
      shouldRun: (prefs) async {
        try {
          final dir = await getApplicationDocumentsDirectory();
          final hiveDir = io.Directory(p.join(dir.path, 'hive'));
          if (!await hiveDir.exists()) return false;
          await for (final e in hiveDir.list()) {
            if (e is io.File &&
                p.basename(e.path).startsWith('image_cache_meta_')) {
              return true;
            }
          }
          return false;
        } catch (_) {
          return false;
        }
      },
      run: () async {
        final dir = await getApplicationDocumentsDirectory();
        final hiveDir = io.Directory(p.join(dir.path, 'hive'));
        if (!await hiveDir.exists()) return;
        await for (final e in hiveDir.list()) {
          if (e is! io.File ||
              !p.basename(e.path).startsWith('image_cache_meta_')) {
            continue;
          }
          try {
            await e.delete();
            debugPrint('[Migration v6] 删除旧 Hive 图片索引: ${p.basename(e.path)}');
          } catch (err) {
            debugPrint('[Migration v6] 删除失败 ${p.basename(e.path)}: $err');
          }
        }
      },
    ),
    // v7: 清空图片缓存目录。
    // v6 删除旧 Hive 索引后,已下载的图片文件仍留在 Temporary/{cacheKey}/ 下,
    // 但新索引不再引用它们 —— emptyCache / LRU 清理都只认索引内条目,这批
    // 文件会永久占据磁盘(可达数百 MB)。目录里绝大多数文件都是这种孤儿,
    // 不值得为少数已重新入索引的文件做逐文件比对 —— 整目录删除,连同刚起步
    // 的 sqlite 索引 db 一起删,全部从零重建(纯缓存,按需重新下载)。
    //
    // **防卡顿契约**(有升级卡顿的用户反馈,疑似此处):迁移跑在 runApp
    // 之前,绝不能同步递归删数百 MB(几千次文件系统调用)。改为
    // rename 成 .trash(原子,毫秒级),真正的递归删除由 [purgeTrash]
    // 在启动后台完成;被杀断也无害,下次启动重新清扫。
    Migration(
      key: 'image_cache_orphan_purge_v7',
      name: 'Purge image cache directories',
      shouldRun: (prefs) async {
        try {
          final tempDir = await getTemporaryDirectory();
          for (final key in kLegacyImageCacheKeys) {
            if (await io.Directory(p.join(tempDir.path, key)).exists()) {
              return true;
            }
          }
          return false;
        } catch (_) {
          return false;
        }
      },
      run: () async {
        final tempDir = await getTemporaryDirectory();
        final supportDir = await getApplicationSupportDirectory();
        for (final key in kLegacyImageCacheKeys) {
          await _trashCacheDir(tempDir, key);
          await _deleteCacheDb(supportDir, key);
        }
      },
    ),
    // v8: emoji 缓存迁往 BlobImageCache(零 sqlite 寻址),旧
    // emojiImageCache 整体废弃 —— 直接删不迁移(纯缓存,按需重下)。
    // 同 v7 的防卡顿契约:rename → 后台删。
    Migration(
      key: 'emoji_blob_cache_v8',
      name: 'Retire legacy emoji image cache',
      shouldRun: (prefs) async {
        try {
          final tempDir = await getTemporaryDirectory();
          if (await io.Directory(
            p.join(tempDir.path, kLegacyEmojiCacheKey),
          ).exists()) {
            return true;
          }
          final supportDir = await getApplicationSupportDirectory();
          return await io.File(
            p.join(supportDir.path, '$kLegacyEmojiCacheKey.db'),
          ).exists();
        } catch (_) {
          return false;
        }
      },
      run: () async {
        final tempDir = await getTemporaryDirectory();
        final supportDir = await getApplicationSupportDirectory();
        await _trashCacheDir(tempDir, kLegacyEmojiCacheKey);
        await _deleteCacheDb(supportDir, kLegacyEmojiCacheKey);
      },
    ),
    // v9: 图片缓存全量迁入 BlobImageCache(零 sqlite 寻址),
    // flutter_cache_manager 退役 —— 三个旧缓存(正文/贴纸/外部)目录 +
    // db 三件套废弃。直接删不迁移(纯缓存按需重下);同 v7 防卡顿契约。
    Migration(
      key: 'image_cache_blob_unification_v9',
      name: 'Retire flutter_cache_manager image caches',
      shouldRun: (prefs) async {
        try {
          final tempDir = await getTemporaryDirectory();
          final supportDir = await getApplicationSupportDirectory();
          for (final key in kLegacyImageCacheKeys) {
            if (await io.Directory(p.join(tempDir.path, key)).exists()) {
              return true;
            }
            if (await io.File(p.join(supportDir.path, '$key.db')).exists()) {
              return true;
            }
          }
          return false;
        } catch (_) {
          return false;
        }
      },
      run: () async {
        final tempDir = await getTemporaryDirectory();
        final supportDir = await getApplicationSupportDirectory();
        for (final key in kLegacyImageCacheKeys) {
          await _trashCacheDir(tempDir, key);
          await _deleteCacheDb(supportDir, key);
        }
      },
    ),
  ];

  /// 把缓存目录原子 rename 成 `<key>.<millis>.trash`,加入待删清单。
  /// rename 同卷内是纯目录项操作,与目录大小无关(毫秒级)。
  static Future<void> _trashCacheDir(io.Directory tempDir, String key) async {
    try {
      final dir = io.Directory(p.join(tempDir.path, key));
      if (!await dir.exists()) return;
      final trashPath = p.join(
        tempDir.path,
        '$key.${DateTime.now().millisecondsSinceEpoch}$_trashSuffix',
      );
      await dir.rename(trashPath);
      debugPrint('[Migration] 已移入待删区: $key');
    } catch (e) {
      debugPrint('[Migration] trash $key 失败 (忽略): $e');
    }
  }

  /// 删除 sqlite 索引三件套(小文件,同步删无压力)。
  static Future<void> _deleteCacheDb(
    io.Directory supportDir,
    String key,
  ) async {
    for (final suffix in const ['.db', '.db-wal', '.db-shm']) {
      try {
        final f = io.File(p.join(supportDir.path, '$key$suffix'));
        if (await f.exists()) await f.delete();
      } catch (e) {
        debugPrint('[Migration] 删除 $key$suffix 失败 (忽略): $e');
      }
    }
  }

  static const String _trashSuffix = '.trash';

  /// 后台清扫 Temporary 下的 `*.trash` 目录(v7/v8 rename 出来的,以及
  /// 上次启动被杀断残留的)。递归删除跑在 [Isolate.run],主 isolate 与
  /// 启动路径零负担;调用方应在首帧后空闲时机 unawaited 触发。
  static Future<void> purgeTrash() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final tempPath = tempDir.path;
      final deleted = await Isolate.run(() {
        var count = 0;
        for (final e in io.Directory(tempPath).listSync()) {
          if (e is! io.Directory || !e.path.endsWith(_trashSuffix)) continue;
          try {
            e.deleteSync(recursive: true);
            count++;
          } catch (_) {}
        }
        return count;
      });
      if (deleted > 0) {
        debugPrint('[Migration] 后台清扫 $deleted 个 .trash 目录');
      }
    } catch (e) {
      debugPrint('[Migration] purgeTrash 失败 (忽略): $e');
    }
  }

  /// 全部迁移完成标记 key(供备份服务排除,数据驱动不抄常量)。
  static List<String> get migrationKeys =>
      [for (final m in _migrations) m.key, 'cookie_domain_migration_v2'];

  /// 判断是否为 v0.1.x 以前的老用户。
  ///
  /// **不要**把 `cookie_clean_slate_v2` 当作老用户标记 —— 它是 v2 迁移的
  /// 完成标记 (runAll 会对全新用户也 setBool true 表示"跳过"),把它作为
  /// 老用户依据会让 v3 / v4 对全新用户误触发。
  ///
  /// 真正能区分"老用户"的只有 v0.1.x 时代的 `cookie_domain_migration_v2`,
  /// 全新用户的 prefs 中不存在此 key。
  static bool _hasLegacyCookieMigrationMarker(SharedPreferences prefs) {
    return prefs.getBool('cookie_domain_migration_v2') == true;
  }

  /// 在 main() 中调用，在所有网络服务启动之前执行
  static Future<void> runAll(SharedPreferences prefs) async {
    requiresRelogin = false;

    for (final m in _migrations) {
      if (prefs.getBool(m.key) == true) continue;

      if (!await m.shouldRun(prefs)) {
        await prefs.setBool(m.key, true);
        debugPrint('[Migration] 跳过（无需迁移）: ${m.name}');
        continue;
      }

      debugPrint('[Migration] 开始: ${m.name}');
      try {
        await m.run();
        await prefs.setBool(m.key, true);
        debugPrint('[Migration] 完成: ${m.name}');
      } catch (e) {
        debugPrint('[Migration] 失败: ${m.name}, $e');
      }
    }
  }
}
