import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/s.dart';
import '../migration_service.dart';
import '../storage/resilient_secure_storage.dart';

/// 数据备份导出/导入服务
///
/// ## v2:反白名单(排除清单)
///
/// v1 是前缀白名单(pref_/ai_/theme_/…),问题是**持续腐烂**:每加一个
/// 不在白名单前缀下的配置就静默漏备(实际审计发现主题字体/自定义配色、
/// 网页收藏、贴纸订阅、代理另一半 upstream_proxy_* 等十余项全漏,主题
/// 恢复"一半对一半错")。
///
/// v2 反转:**默认全备,只排除稳定类别**——缓存/派生、会话/凭证、
/// 设备绑定/运行态、一次性 UI 标记、迁移标记。新配置项自动纳入,
/// 失败模式从"用户丢配置"变成"备份文件多几个无害 key"。
/// 排除规则在导出与导入两侧都生效(防旧备份/手改文件把会话态灌回来)。
class DataBackupService {
  static final ResilientSecureStorage _secureStorage = ResilientSecureStorage();
  static const _apiKeyPrefix = 'ai_provider_key_';

  /// 排除前缀:命中即不备份。按类别分组,新增排除项时对号入座。
  static const _excludeKeyPrefixes = [
    // ── 缓存 / 派生数据(可重建,体积大或随会话变)──
    'ai_chat_session_messages_',
    'ai_chat_topic_sessions_',
    'ai_chat_all_sessions_index',
    'ai_post_review_guidelines_cache',
    'current_user_cache',
    'user_summary_cache',
    'cdk_user_info',
    'ldc_user_info',
    'update_', // update_cache / update_cache_time / update_etag
    'sticker_market_', // 贴纸市场缓存(真配置 base_url 在下面精确回捞)
    'bookmark_last_full_sync_',
    'blob_image_cache_last_sweep',
    // ── 会话 / 凭证(跨设备无效或有害)──
    'linux_do_', // csrf_token / username
    'cookie_',
    'auth_passive_logout_history',
    'bg_shared_session_key',
    'one_time_password',
    // ── 设备绑定 / 运行态 ──
    'cronet_', // 降级状态
    'vpn_suppressed_',
    'per_device_cert_installed',
    'cert_use_per_device',
    'window_', // 桌面端窗口几何(legacy keys)
    // ── 一次性 UI 标记(新设备应重新引导)──
    'onboarding_completed',
    'crashlytics_notice_shown',
    'cursor_swipe_hint_',
  ];

  /// 排除后缀:一次性引导标记的通用形态(xxx_guide_shown)。
  static const _excludeKeySuffixes = ['_guide_shown'];

  /// 被排除前缀误伤的真配置,精确回捞。
  static const _includeExactKeys = ['sticker_market_base_url'];

  /// 判断 key 是否应该被备份(导出与导入同一套规则)。
  static bool _shouldBackup(String key) {
    if (_includeExactKeys.contains(key)) return true;
    // 迁移完成标记:动态从 MigrationService 派生,不抄常量
    if (MigrationService.migrationKeys.contains(key)) return false;
    for (final prefix in _excludeKeyPrefixes) {
      if (key.startsWith(prefix)) return false;
    }
    for (final suffix in _excludeKeySuffixes) {
      if (key.endsWith(suffix)) return false;
    }
    return true;
  }

  /// 导出数据为 Map
  static Future<Map<String, dynamic>> exportData(
    SharedPreferences prefs,
  ) async {
    final pkg = await PackageInfo.fromPlatform();
    final data = <String, Map<String, dynamic>>{};

    for (final key in prefs.getKeys()) {
      if (!_shouldBackup(key)) continue;

      final value = prefs.get(key);
      if (value == null) continue;

      String type;
      dynamic serializedValue;

      if (value is bool) {
        type = 'bool';
        serializedValue = value;
      } else if (value is int) {
        type = 'int';
        serializedValue = value;
      } else if (value is double) {
        type = 'double';
        serializedValue = value;
      } else if (value is String) {
        type = 'String';
        serializedValue = value;
      } else if (value is List<String>) {
        type = 'StringList';
        serializedValue = value;
      } else {
        continue;
      }

      data[key] = {'type': type, 'value': serializedValue};
    }

    // 导出 AI 供应商 API Key（存储在 FlutterSecureStorage 中）。
    // 其余 SecureStorage 项(登录账密 / User-Api-Key 凭证)是设备绑定,
    // 刻意不导出。
    final apiKeys = await _exportApiKeys(prefs);

    return {
      'version': 2,
      'appVersion': pkg.version,
      'exportTime': DateTime.now().toIso8601String(),
      'data': data,
      if (apiKeys.isNotEmpty) 'apiKeys': apiKeys,
    };
  }

  /// 从 SecureStorage 中导出所有 AI 供应商的 API Key
  static Future<Map<String, String>> _exportApiKeys(
    SharedPreferences prefs,
  ) async {
    final apiKeys = <String, String>{};
    final providersJson = prefs.getString('ai_providers');
    if (providersJson == null) return apiKeys;

    try {
      final list = jsonDecode(providersJson) as List<dynamic>;
      for (final item in list) {
        final id = (item as Map<String, dynamic>)['id'] as String?;
        if (id == null) continue;
        final key = await _secureStorage.read(key: '$_apiKeyPrefix$id');
        if (key != null && key.isNotEmpty) {
          apiKeys[id] = key;
        }
      }
    } catch (_) {
      // 解析失败时跳过
    }
    return apiKeys;
  }

  /// 将导出数据写入临时文件，返回文件路径
  static Future<String> exportToFile(SharedPreferences prefs) async {
    final exportData = await DataBackupService.exportData(prefs);
    final jsonStr = const JsonEncoder.withIndent('  ').convert(exportData);

    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('${tempDir.path}/fluxdo_backup_$timestamp.json');
    await file.writeAsString(jsonStr);

    return file.path;
  }

  /// 从 Map 导入数据。
  ///
  /// 导入侧同样过 [_shouldBackup]:v1 旧备份(白名单时代)与手改文件
  /// 里可能混着会话态/缓存 key,一律过滤。
  static Future<void> importData(
    SharedPreferences prefs,
    Map<String, dynamic> backup,
  ) async {
    final data = backup['data'] as Map<String, dynamic>?;
    if (data == null) throw FormatException(S.current.backup_missingDataField);

    for (final entry in data.entries) {
      final key = entry.key;
      if (!_shouldBackup(key)) continue;
      final item = entry.value as Map<String, dynamic>;
      final type = item['type'] as String;
      final value = item['value'];

      switch (type) {
        case 'bool':
          await prefs.setBool(key, value as bool);
        case 'int':
          await prefs.setInt(key, value as int);
        case 'double':
          await prefs.setDouble(key, (value as num).toDouble());
        case 'String':
          await prefs.setString(key, value as String);
        case 'StringList':
          await prefs.setStringList(
            key,
            (value as List<dynamic>).cast<String>(),
          );
      }
    }

    // 导入 API Key 到 SecureStorage
    final apiKeys = backup['apiKeys'] as Map<String, dynamic>?;
    if (apiKeys != null) {
      for (final entry in apiKeys.entries) {
        await _secureStorage.write(
          key: '$_apiKeyPrefix${entry.key}',
          value: entry.value as String,
        );
      }
    }
  }

  /// 从文件路径读取并解析备份数据
  static Future<Map<String, dynamic>> parseBackupFile(String filePath) async {
    final file = File(filePath);
    final content = await file.readAsString();
    final json = jsonDecode(content) as Map<String, dynamic>;

    // 基本校验(v1 / v2 结构相同,均可导入)
    if (json['version'] == null || json['data'] == null) {
      throw FormatException(S.current.backup_invalidFormat);
    }

    return json;
  }

  /// 测试钩子:暴露备份判定(仅测试用)。
  static bool debugShouldBackup(String key) => _shouldBackup(key);
}
