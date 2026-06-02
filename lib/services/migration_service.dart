import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
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
  ];

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
