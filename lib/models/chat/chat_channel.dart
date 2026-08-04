import '../../utils/time_utils.dart';
import 'chat_message.dart';
import 'chat_user.dart';

/// 我在某频道的成员关系(current_user_membership)——未读红点的数据源
class ChatChannelMembership {
  final bool following;
  final bool muted;

  /// 收藏(列表置顶区)
  final bool starred;

  /// 通知级别:'muted' | 'normal' | 'mention' | 'always'(实测为字符串)
  final String? notificationLevel;
  final int? lastReadMessageId;
  final DateTime? lastViewedAt;

  const ChatChannelMembership({
    this.following = false,
    this.muted = false,
    this.starred = false,
    this.notificationLevel,
    this.lastReadMessageId,
    this.lastViewedAt,
  });

  factory ChatChannelMembership.fromJson(Map<String, dynamic> json) {
    return ChatChannelMembership(
      following: json['following'] as bool? ?? false,
      muted: json['muted'] as bool? ?? false,
      starred: json['starred'] as bool? ?? false,
      notificationLevel: json['notification_level']?.toString(),
      lastReadMessageId: json['last_read_message_id'] as int?,
      lastViewedAt: TimeUtils.parseUtcTime(json['last_viewed_at'] as String?),
    );
  }
}

/// 频道的 MessageBus 订阅起始位点(meta.message_bus_last_ids)
/// 订阅时必须带上,否则漏消息
class ChatChannelBusLastIds {
  final int? channelMessageBusLastId;
  final int? newMessages;
  final int? newMentions;
  final int? kick;

  const ChatChannelBusLastIds({
    this.channelMessageBusLastId,
    this.newMessages,
    this.newMentions,
    this.kick,
  });

  factory ChatChannelBusLastIds.fromJson(Map<String, dynamic> json) {
    return ChatChannelBusLastIds(
      channelMessageBusLastId: json['channel_message_bus_last_id'] as int?,
      newMessages: json['new_messages'] as int?,
      newMentions: json['new_mentions'] as int?,
      kick: json['kick'] as int?,
    );
  }
}

/// Chat 频道(DM 频道 chatable_type == 'DirectMessage')
class ChatChannel {
  final int id;
  final String? title;

  /// title 的无表情版本(DM 频道 title 形如 "@user1, @user2")
  final String? unicodeTitle;
  final String? slug;
  final String? description;
  final String chatableType;
  final String? status;
  final bool threadingEnabled;
  final int? membershipsCount;

  /// 是否群聊(chatable.group);非 DM 频道恒 false
  final bool isGroupDm;

  /// DM 对端用户(1:1 时服务端已剔除自己;群聊为全部其他成员)
  final List<ChatUser> dmUsers;

  /// 公共频道(chatable_type=Category)的分类色(hex,无 #)与分类名
  final String? categoryColor;
  final String? categoryName;

  /// 频道 emoji(站点配置的频道图标)
  final String? emoji;
  final ChatChannelMembership? currentUserMembership;
  final ChatMessage? lastMessage;
  final ChatChannelBusLastIds busLastIds;

  /// 服务端能力位(meta.can_*),动态判定,不硬编码权限
  final bool canModerate;
  final bool canManagePins;
  final bool canDeleteSelf;
  final bool canDeleteOthers;
  final bool canRemoveMembers;
  final bool canFlag;

  const ChatChannel({
    required this.id,
    this.title,
    this.unicodeTitle,
    this.slug,
    this.description,
    required this.chatableType,
    this.status,
    this.threadingEnabled = false,
    this.membershipsCount,
    this.isGroupDm = false,
    this.dmUsers = const [],
    this.categoryColor,
    this.categoryName,
    this.emoji,
    this.currentUserMembership,
    this.lastMessage,
    this.busLastIds = const ChatChannelBusLastIds(),
    this.canModerate = false,
    this.canManagePins = false,
    this.canDeleteSelf = false,
    this.canDeleteOthers = false,
    this.canRemoveMembers = false,
    this.canFlag = false,
  });

  bool get isDirectMessage => chatableType == 'DirectMessage';
  bool get isPublicChannel => chatableType == 'Category';

  ChatChannel copyWith({
    ChatMessage? lastMessage,
    String? title,
    String? description,
    String? slug,
    bool? threadingEnabled,
  }) {
    return ChatChannel(
      id: id,
      title: title ?? this.title,
      unicodeTitle: unicodeTitle,
      slug: slug ?? this.slug,
      description: description ?? this.description,
      chatableType: chatableType,
      status: status,
      threadingEnabled: threadingEnabled ?? this.threadingEnabled,
      membershipsCount: membershipsCount,
      isGroupDm: isGroupDm,
      dmUsers: dmUsers,
      categoryColor: categoryColor,
      categoryName: categoryName,
      emoji: emoji,
      currentUserMembership: currentUserMembership,
      lastMessage: lastMessage ?? this.lastMessage,
      busLastIds: busLastIds,
      canModerate: canModerate,
      canManagePins: canManagePins,
      canDeleteSelf: canDeleteSelf,
      canDeleteOthers: canDeleteOthers,
      canRemoveMembers: canRemoveMembers,
      canFlag: canFlag,
    );
  }

  factory ChatChannel.fromJson(Map<String, dynamic> json) {
    final chatable = json['chatable'] as Map<String, dynamic>? ?? const {};
    final membership = json['current_user_membership'];
    final lastMessage = json['last_message'];
    final meta = json['meta'] as Map<String, dynamic>? ?? const {};
    final busLastIds = meta['message_bus_last_ids'];
    final channelId = json['id'] as int? ?? 0;
    // last_message 可能是 {id: null, ...} 的空壳,按无消息处理
    final hasLastMessage =
        lastMessage is Map<String, dynamic> && lastMessage['id'] != null;
    return ChatChannel(
      id: channelId,
      title: json['title'] as String?,
      unicodeTitle: json['unicode_title'] as String?,
      slug: json['slug'] as String?,
      description: json['description'] as String?,
      chatableType: json['chatable_type'] as String? ?? '',
      status: json['status'] as String?,
      threadingEnabled: json['threading_enabled'] as bool? ?? false,
      membershipsCount: json['memberships_count'] as int?,
      isGroupDm: chatable['group'] as bool? ?? false,
      dmUsers: (chatable['users'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ChatUser.fromJson)
          .toList(),
      categoryColor: chatable['color'] as String?,
      categoryName: chatable['name'] as String?,
      emoji: json['emoji'] as String?,
      currentUserMembership: membership is Map<String, dynamic>
          ? ChatChannelMembership.fromJson(membership)
          : null,
      lastMessage: hasLastMessage
          ? ChatMessage.fromJson(lastMessage, fallbackChannelId: channelId)
          : null,
      busLastIds: busLastIds is Map<String, dynamic>
          ? ChatChannelBusLastIds.fromJson(busLastIds)
          : const ChatChannelBusLastIds(),
      canModerate: meta['can_moderate'] as bool? ?? false,
      canManagePins: meta['can_manage_pins'] as bool? ?? false,
      canDeleteSelf: meta['can_delete_self'] as bool? ?? false,
      canDeleteOthers: meta['can_delete_others'] as bool? ?? false,
      canRemoveMembers: meta['can_remove_members'] as bool? ?? false,
      canFlag: meta['can_flag'] as bool? ?? false,
    );
  }
}

/// 频道成员(memberships 列表元素:membership 字段 + 内嵌 user)
class ChatChannelMember {
  final ChatUser user;
  final bool following;
  final bool muted;

  const ChatChannelMember({
    required this.user,
    this.following = true,
    this.muted = false,
  });

  factory ChatChannelMember.fromJson(Map<String, dynamic> json) {
    final user = json['user'] as Map<String, dynamic>? ?? const {};
    return ChatChannelMember(
      user: ChatUser.fromJson(user),
      following: json['following'] as bool? ?? true,
      muted: json['muted'] as bool? ?? false,
    );
  }
}

/// 单频道未读状态(tracking 映射的值)
class ChatChannelTracking {
  final int unreadCount;
  final int mentionCount;

  const ChatChannelTracking({this.unreadCount = 0, this.mentionCount = 0});

  factory ChatChannelTracking.fromJson(Map<String, dynamic> json) {
    return ChatChannelTracking(
      unreadCount: json['unread_count'] as int? ?? 0,
      mentionCount: json['mention_count'] as int? ?? 0,
    );
  }
}

/// GET /chat/api/me/channels 响应(StructuredChannelSerializer)
class MyChatChannelsResponse {
  final List<ChatChannel> publicChannels;
  final List<ChatChannel> directMessageChannels;

  /// channel_id -> 未读状态(tracking.channel_tracking)
  final Map<int, ChatChannelTracking> channelTracking;

  /// 全局 MessageBus 通道起始位点(meta.message_bus_last_ids):
  /// user_tracking_state / new_channel / channel_metadata 等
  final Map<String, int> globalBusLastIds;

  const MyChatChannelsResponse({
    required this.publicChannels,
    required this.directMessageChannels,
    required this.channelTracking,
    required this.globalBusLastIds,
  });

  factory MyChatChannelsResponse.fromJson(Map<String, dynamic> json) {
    final tracking = json['tracking'] as Map<String, dynamic>? ?? const {};
    final channelTrackingRaw =
        tracking['channel_tracking'] as Map<String, dynamic>? ?? const {};
    final meta = json['meta'] as Map<String, dynamic>? ?? const {};
    final busLastIdsRaw =
        meta['message_bus_last_ids'] as Map<String, dynamic>? ?? const {};
    return MyChatChannelsResponse(
      publicChannels: (json['public_channels'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ChatChannel.fromJson)
          .toList(),
      directMessageChannels:
          (json['direct_message_channels'] as List<dynamic>? ?? [])
              .whereType<Map<String, dynamic>>()
              .map(ChatChannel.fromJson)
              .toList(),
      channelTracking: {
        for (final entry in channelTrackingRaw.entries)
          if (int.tryParse(entry.key) != null &&
              entry.value is Map<String, dynamic>)
            int.parse(entry.key): ChatChannelTracking.fromJson(
              entry.value as Map<String, dynamic>,
            ),
      },
      globalBusLastIds: {
        for (final entry in busLastIdsRaw.entries)
          if (entry.value is int) entry.key: entry.value as int,
      },
    );
  }
}
