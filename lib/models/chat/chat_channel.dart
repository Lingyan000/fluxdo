import '../mention_user.dart';
import '../../utils/time_utils.dart';

/// 频道内当前用户的成员关系（未读数/免打扰状态等）
class ChatMembership {
  final bool following;
  final bool muted;
  final bool starred;
  final int unreadCount;
  final int unreadMentions;
  final int? lastReadMessageId;

  /// 通知级别,对应 `Chat::UserChatChannelMembership::NOTIFICATION_LEVELS`
  /// (never=0, mention=1, always=2)。
  final int notificationLevel;

  const ChatMembership({
    this.following = false,
    this.muted = false,
    this.starred = false,
    this.unreadCount = 0,
    this.unreadMentions = 0,
    this.lastReadMessageId,
    this.notificationLevel = 2,
  });

  /// `starred` 字段核对过 Discourse 源码
  /// `Chat::BaseChannelMembershipSerializer`,任意频道(含 DM)都能收藏,
  /// 通过 `PUT /chat/api/channels/:id/memberships/me` 切换
  /// (`Chat::UpdateUserChannelMembership`)。
  factory ChatMembership.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ChatMembership();
    return ChatMembership(
      following: json['following'] as bool? ?? false,
      muted: json['muted'] as bool? ?? false,
      starred: json['starred'] as bool? ?? false,
      unreadCount: json['unread_count'] as int? ?? 0,
      unreadMentions: json['unread_mentions'] as int? ?? 0,
      lastReadMessageId: json['last_read_message_id'] as int?,
      notificationLevel: _parseNotificationLevel(json['notification_level']),
    );
  }

  /// 序列化端给的是枚举名字符串("never"/"mention"/"always"),
  /// 但也兼容数字形态。
  static int _parseNotificationLevel(dynamic value) {
    if (value is int) return value;
    switch (value) {
      case 'never':
        return 0;
      case 'mention':
        return 1;
      case 'always':
        return 2;
    }
    return 2;
  }

  ChatMembership copyWith({
    bool? following,
    bool? muted,
    bool? starred,
    int? unreadCount,
    int? unreadMentions,
    int? lastReadMessageId,
    int? notificationLevel,
  }) {
    return ChatMembership(
      following: following ?? this.following,
      muted: muted ?? this.muted,
      starred: starred ?? this.starred,
      unreadCount: unreadCount ?? this.unreadCount,
      unreadMentions: unreadMentions ?? this.unreadMentions,
      lastReadMessageId: lastReadMessageId ?? this.lastReadMessageId,
      notificationLevel: notificationLevel ?? this.notificationLevel,
    );
  }
}

/// 频道最后一条消息的摘要，用于列表页预览
class ChatLastMessage {
  final int? id;
  final String? message;
  final DateTime? createdAt;

  const ChatLastMessage({this.id, this.message, this.createdAt});

  /// 实测线上接口里,刚创建、还没人发过消息的频道会给一个
  /// `{id: null, message: null, ...}` 的空壳 last_message,不是完全省略
  /// 这个字段——所以字段本身用 `as int?`,不能假设非空。
  factory ChatLastMessage.fromJson(Map<String, dynamic> json) {
    return ChatLastMessage(
      id: json['id'] as int?,
      message: json['message'] as String?,
      createdAt: TimeUtils.parseUtcTime(json['created_at'] as String?),
    );
  }
}

/// Chat 插件的频道(DM 或公共频道,按 [chatableType] 区分)
class ChatChannel {
  final int id;
  final String? title;
  final String? slug;
  /// 群聊自定义图标(表情短代码,不带冒号),没设置过为 null
  final String? emoji;
  final String chatableType;
  final int? chatableId;
  final String? description;
  final bool threadingEnabled;
  final bool isGroup;

  /// 公共频道挂靠的类别名(chatable_type == Category 时)
  final String? categoryName;

  /// 频道成员数(memberships_count)
  final int? membershipsCount;

  /// 能力位,来自序列化 meta(scope 按当前用户算好):没权限的设置项
  /// UI 直接不显示,而不是点了 403。
  final bool canModerate;
  final bool canManagePins;
  final List<MentionUser> participants;
  final ChatLastMessage? lastMessage;
  final ChatMembership membership;
  final int? messageBusLastId;

  const ChatChannel({
    required this.id,
    this.title,
    this.slug,
    this.emoji,
    required this.chatableType,
    this.chatableId,
    this.description,
    this.threadingEnabled = false,
    this.isGroup = false,
    this.categoryName,
    this.membershipsCount,
    this.canModerate = false,
    this.canManagePins = false,
    this.participants = const [],
    this.lastMessage,
    this.membership = const ChatMembership(),
    this.messageBusLastId,
  });

  /// 是否是私聊(DM)频道;否则是分类挂靠的公共频道(chatable_type: Category)。
  bool get isDirectMessage => chatableType == 'DirectMessage';

  factory ChatChannel.fromJson(Map<String, dynamic> json) {
    final chatable = json['chatable'] as Map<String, dynamic>?;
    final usersJson = chatable?['users'] as List<dynamic>? ?? const [];
    final meta = json['meta'] as Map<String, dynamic>?;
    final messageBusLastIds = meta?['message_bus_last_ids'] as Map<String, dynamic>?;

    return ChatChannel(
      id: json['id'] as int,
      title: json['title'] as String?,
      slug: json['slug'] as String?,
      emoji: json['emoji'] as String?,
      chatableType: json['chatable_type'] as String? ?? 'DirectMessage',
      chatableId: json['chatable_id'] as int?,
      description: json['description'] as String?,
      threadingEnabled: json['threading_enabled'] as bool? ?? false,
      categoryName: json['chatable_type'] == 'Category'
          ? (chatable?['name'] as String?)
          : null,
      membershipsCount: json['memberships_count'] as int?,
      canModerate: meta?['can_moderate'] as bool? ?? false,
      canManagePins: meta?['can_manage_pins'] as bool? ?? false,
      isGroup: chatable?['group'] as bool? ?? usersJson.length > 1,
      participants: usersJson
          .map((e) => MentionUser.fromJson(e as Map<String, dynamic>))
          .toList(),
      lastMessage: json['last_message'] != null
          ? ChatLastMessage.fromJson(json['last_message'] as Map<String, dynamic>)
          : null,
      membership: ChatMembership.fromJson(json['current_user_membership'] as Map<String, dynamic>?),
      // 频道内新消息推送(`/chat/{id}/new-messages`)对应的是 meta 里的
      // `new_messages` 这个子键,不是 `channel_message_bus_last_id`(那个是
      // 频道根 MessageBus 频道的 last id,语义不同,订阅新消息用错键会导致
      // 服务端从错误的位置起播积压消息)。
      messageBusLastId: messageBusLastIds?['new_messages'] as int?,
    );
  }

  ChatChannel copyWith({
    ChatLastMessage? lastMessage,
    ChatMembership? membership,
    bool? threadingEnabled,
    String? title,
    String? slug,
    String? emoji,
  }) {
    return ChatChannel(
      id: id,
      title: title ?? this.title,
      slug: slug ?? this.slug,
      emoji: emoji ?? this.emoji,
      chatableType: chatableType,
      chatableId: chatableId,
      description: description,
      threadingEnabled: threadingEnabled ?? this.threadingEnabled,
      isGroup: isGroup,
      categoryName: categoryName,
      membershipsCount: membershipsCount,
      canModerate: canModerate,
      canManagePins: canManagePins,
      participants: participants,
      lastMessage: lastMessage ?? this.lastMessage,
      membership: membership ?? this.membership,
      messageBusLastId: messageBusLastId,
    );
  }

  /// 除当前用户外的对方（单聊场景），拿不到时兜底取第一个
  MentionUser? otherParticipant(String currentUsername) {
    if (participants.isEmpty) return null;
    for (final p in participants) {
      if (p.username != currentUsername) return p;
    }
    return participants.first;
  }
}
