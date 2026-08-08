/// Chat 数据模型
///
/// 集中导出所有 Chat 相关模型，外部只需导入此文件。
library;

import 'chat_channel.dart';

export 'chat_channel.dart';
export 'chat_message.dart';
export 'chat_thread.dart';
export 'chat_user.dart';

/// Chat 频道列表状态
class ChatChannelsState {
  /// 公开频道
  final List<ChatChannel> publicChannels;

  /// 私信频道
  final List<ChatChannel> directMessageChannels;

  /// 频道追踪数据（unread_count, unread_mentions 等）
  final Map<String, Map<String, dynamic>> tracking;

  /// MessageBus 最新 ID 映射
  final Map<String, int>? messageBusLastIds;

  /// 聊天全局在线用户 ID 集合（来自 /chat/online presence channel）
  final Set<int> onlineUserIds;

  const ChatChannelsState({
    required this.publicChannels,
    required this.directMessageChannels,
    required this.tracking,
    this.messageBusLastIds,
    this.onlineUserIds = const {},
  });

  factory ChatChannelsState.fromJson(Map<String, dynamic> json) {
    final membershipsMap = <int, Map<String, dynamic>>{};
    final membershipsRaw = json['user_chat_channel_memberships'] ?? json['memberships'];
    if (membershipsRaw is List) {
      for (final m in membershipsRaw) {
        if (m is Map) {
          final map = Map<String, dynamic>.from(m);
          final chId = (map['chat_channel_id'] as num?)?.toInt() ??
              (map['channel_id'] as num?)?.toInt();
          if (chId != null) {
            membershipsMap[chId] = map;
          }
        }
      }
    }

    // Discourse tracking 形状:
    // { channel_tracking: { "<id>": { unread_count, mention_count, ... } }, thread_tracking: {...} }
    final tracking = _parseTracking(json['tracking']);

    return ChatChannelsState(
      publicChannels:
          _parseChannels(json['public_channels'], membershipsMap, tracking),
      directMessageChannels: _parseChannels(
        json['direct_message_channels'],
        membershipsMap,
        tracking,
      ),
      tracking: tracking,
      messageBusLastIds: _parseMessageBusIds(json['message_bus_last_ids']),
    );
  }

  /// 复制并更新在线用户列表 / 频道字段
  ChatChannelsState copyWith({
    Set<int>? onlineUserIds,
    List<ChatChannel>? publicChannels,
    List<ChatChannel>? directMessageChannels,
  }) {
    return ChatChannelsState(
      publicChannels: publicChannels ?? this.publicChannels,
      directMessageChannels:
          directMessageChannels ?? this.directMessageChannels,
      tracking: tracking,
      messageBusLastIds: messageBusLastIds,
      onlineUserIds: onlineUserIds ?? this.onlineUserIds,
    );
  }

  /// 按 id 更新某个频道（乐观更新 threading 等字段）
  ChatChannelsState mapChannel(
    int channelId,
    ChatChannel Function(ChatChannel) transform,
  ) {
    List<ChatChannel> mapList(List<ChatChannel> list) => [
          for (final c in list) c.id == channelId ? transform(c) : c,
        ];
    return copyWith(
      publicChannels: mapList(publicChannels),
      directMessageChannels: mapList(directMessageChannels),
    );
  }

  static List<ChatChannel> _parseChannels(
    dynamic channels, [
    Map<int, Map<String, dynamic>>? membershipsMap,
    Map<String, Map<String, dynamic>>? tracking,
  ]) {
    if (channels is! List) return [];
    return channels.map((e) {
      final map = Map<String, dynamic>.from(e as Map);
      final chId = (map['id'] as num?)?.toInt();
      if (chId != null &&
          !map.containsKey('user_chat_channel_membership') &&
          membershipsMap != null &&
          membershipsMap.containsKey(chId)) {
        map['user_chat_channel_membership'] = membershipsMap[chId];
      }
      // ChannelSerializer 不输出 unread_*，从 channel_tracking 合并
      if (chId != null && tracking != null) {
        final t = tracking[chId.toString()];
        if (t != null) {
          map['unread_count'] ??= t['unread_count'];
          // 官方字段是 mention_count
          map['unread_mentions'] ??= t['mention_count'] ?? t['unread_mentions'];
        }
      }
      return ChatChannel.fromJson(map);
    }).toList();
  }

  /// 解析 tracking，优先取 channel_tracking 子表
  static Map<String, Map<String, dynamic>> _parseTracking(dynamic tracking) {
    if (tracking is! Map) return {};
    final root = Map<String, dynamic>.from(tracking);
    final channelTracking = root['channel_tracking'];
    if (channelTracking is Map) {
      return channelTracking.map(
        (k, v) => MapEntry(
          k.toString(),
          v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{},
        ),
      );
    }
    // 兼容旧扁平结构（直接 channelId -> stats）
    final result = <String, Map<String, dynamic>>{};
    for (final entry in root.entries) {
      if (entry.key == 'thread_tracking') continue;
      if (entry.value is Map) {
        final value = Map<String, dynamic>.from(entry.value as Map);
        // 跳过仍然嵌套的 tracking 容器
        if (value.containsKey('unread_count') ||
            value.containsKey('mention_count') ||
            value.containsKey('unread_mentions')) {
          result[entry.key.toString()] = value;
        }
      }
    }
    return result;
  }

  static Map<String, int>? _parseMessageBusIds(dynamic ids) {
    if (ids is! Map) return null;
    return (ids as Map).map(
      (k, v) => MapEntry(k.toString(), (v as num).toInt()),
    );
  }
}

/// Chat 可搜索用户/群组
class Chatable {
  final int id;
  final String username;
  final String? name;
  final String? avatarTemplate;

  const Chatable({
    required this.id,
    required this.username,
    this.name,
    this.avatarTemplate,
  });

  factory Chatable.fromJson(Map<String, dynamic> json) {
    return Chatable(
      id: (json['id'] as num?)?.toInt() ?? 0,
      username: json['username']?.toString() ?? '',
      name: json['name']?.toString(),
      avatarTemplate: json['avatar_template']?.toString(),
    );
  }
}