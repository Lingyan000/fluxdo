import 'dart:convert';

import 'package:hive_ce/hive.dart';

import 'app_database.dart';

/// 会话列表冷启缓存 DAO:整份 me/channels 的 DM 频道快照单 key 存,
/// 账号维度隔离。启动先出缓存再网络刷新,不做逐条对账(会话列表
/// 数据量小,全量覆盖成本可忽略)。
class ChatCacheDao {
  ChatCacheDao({Future<Box<Map>> Function(String accountId)? boxFactory})
    : _boxFactory = boxFactory ?? _defaultBox;

  final Future<Box<Map>> Function(String accountId) _boxFactory;

  static const String _kSnapshotKey = 'dm_channels_snapshot';
  static const String _kChannels = 'channels';
  static const String _kPublicChannels = 'public_channels';
  static const String _kTracking = 'tracking';
  static const String _kCachedAt = 'cached_at';

  static Future<Box<Map>> _defaultBox(String accountId) {
    return AppDatabase.namedBox('chat_cache_$accountId');
  }

  /// 读快照:(DM 频道 + 公共频道 + tracking 原始 JSON),无缓存返回 null
  Future<
    ({
      List<Map<String, dynamic>> channels,
      List<Map<String, dynamic>> publicChannels,
      Map<String, dynamic> tracking,
    })?
  >
  readSnapshot(String accountId) async {
    final box = await _boxFactory(accountId);
    final raw = box.get(_kSnapshotKey);
    if (raw == null) return null;
    try {
      final channels = (jsonDecode(raw[_kChannels] as String) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .toList();
      final publicChannels =
          (jsonDecode(raw[_kPublicChannels] as String? ?? '[]')
                  as List<dynamic>)
              .whereType<Map<String, dynamic>>()
              .toList();
      final tracking =
          jsonDecode(raw[_kTracking] as String? ?? '{}')
              as Map<String, dynamic>;
      return (
        channels: channels,
        publicChannels: publicChannels,
        tracking: tracking,
      );
    } catch (_) {
      // 结构损坏当无缓存,下一次写入覆盖
      return null;
    }
  }

  Future<void> writeSnapshot(
    String accountId, {
    required List<Map<String, dynamic>> channels,
    List<Map<String, dynamic>> publicChannels = const [],
    required Map<String, dynamic> tracking,
  }) async {
    final box = await _boxFactory(accountId);
    await box.put(_kSnapshotKey, {
      _kChannels: jsonEncode(channels),
      _kPublicChannels: jsonEncode(publicChannels),
      _kTracking: jsonEncode(tracking),
      _kCachedAt: DateTime.now().toIso8601String(),
    });
  }

  Future<void> clear(String accountId) async {
    final box = await _boxFactory(accountId);
    await box.delete(_kSnapshotKey);
  }
}
