import '../../utils/time_utils.dart';
import 'chat_message.dart';
import 'chat_user.dart';

/// Chat 频道数据模型
class ChatChannel {
  final int id;
  final String? title;
  final String? slug;
  final String? chatableType;
  final int? chatableId;
  final String? chatableUrl;
  final String? description;
  final DateTime? lastMessageSentAt;
  final ChatMessage? lastMessage;
  final int? lastReadMessageId;
  final int? membersCount;
  final bool muted;
  final DateTime? mutedUntil;
  final int unreadCount;
  final int unreadMentions;
  final Map<String, dynamic>? meta;
  final bool starred;
  final bool following;
  final Map<String, dynamic>? userChatChannelMembership;
  final bool? userCanAddMembers;
  final String? emoji;
  final bool threadingEnabled;
  final int? retentionDays;
  final int? retentionHours;
  final String? notificationLevel;
  final List<ChatUser>? dmUsers;
  final bool isGroupDm;

  /// 频道状态：open / closed / read_only / archived（对齐 Discourse Channel#status）
  final String? status;

  const ChatChannel({
    required this.id,
    this.title,
    this.slug,
    this.chatableType,
    this.chatableId,
    this.chatableUrl,
    this.description,
    this.lastMessageSentAt,
    this.lastMessage,
    this.lastReadMessageId,
    this.membersCount,
    this.muted = false,
    this.mutedUntil,
    this.unreadCount = 0,
    this.unreadMentions = 0,
    this.meta,
    this.starred = false,
    this.following = false,
    this.userChatChannelMembership,
    this.userCanAddMembers,
    this.emoji,
    this.threadingEnabled = false,
    this.retentionDays,
    this.retentionHours,
    this.notificationLevel,
    this.dmUsers,
    this.isGroupDm = false,
    this.status,
  });

  /// 是否开放（可正常发言/加入）
  bool get isOpen => (status ?? 'open') == 'open';

  /// 是否已关闭
  bool get isClosed => status == 'closed';

  /// 是否已归档
  bool get isArchived => status == 'archived';

  /// 是否只读
  bool get isReadOnly => status == 'read_only';

  /// 是否可加入（对齐 Discourse chat-channel.js isJoinable）
  /// open 且非 archived；closed / read_only / archived 均不可新加入
  bool get isJoinable => isOpen && !isArchived && !isClosed && !isReadOnly;

  /// 当前用户是否已关注/加入（membership.following == true）
  bool get isJoined => following;

  /// 当前用户是否可在此频道发言
  ///
  /// 对齐 Discourse Guardian#can_create_channel_message?：
  /// - 普通用户仅 open 可发
  /// - staff 在 open/closed 可发
  /// - read_only / archived 均不可发
  /// - 用户被全站禁言时不可发
  bool canSendMessages({required bool isStaff, bool userSilenced = false}) {
    if (userSilenced) return false;
    if (isStaff) return isOpen || isClosed;
    return isOpen;
  }

  /// 不可发言时的提示文案
  String sendDisabledReason({required bool isStaff, bool userSilenced = false}) {
    if (userSilenced) return '你当前被禁言，无法发送消息';
    if (isArchived) return '频道已归档，无法发送消息';
    if (isReadOnly) return '频道为只读，无法发送消息';
    if (isClosed && !isStaff) return '频道已关闭，无法发送消息';
    return '当前无法发送消息';
  }

  /// 是否为直接消息频道（Discourse Direct Message）
  bool get isDirectMessage =>
      chatableType == 'DirectMessage' || chatableType == 'DirectMessageChannel';

  /// 是否为分类/公开频道
  bool get isCategoryChannel =>
      chatableType == 'Category' || chatableType == 'CategoryChannel';

  /// 是否可编辑频道属性（名称/slug/emoji/threading 等）
  ///
  /// 对齐 Discourse Guardian#can_edit_chat_channel?：
  /// - 公开频道：仅 staff
  /// - 直接消息：成员（或 staff）可编辑
  bool canEditChannel({required bool isStaff}) {
    final metaCanEdit = meta?['can_edit'] as bool? ??
        meta?['can_edit_channel'] as bool? ??
        userChatChannelMembership?['can_edit'] as bool?;
    if (metaCanEdit != null) return metaCanEdit;

    if (isDirectMessage) {
      return isStaff || following || userChatChannelMembership != null;
    }
    return isStaff;
  }

  /// 规范化频道 emoji 短码（Discourse 存的是不带冒号的 name，如 speech_balloon）
  static String? normalizeEmojiShortcode(String? raw) {
    if (raw == null) return null;
    var value = raw.trim();
    if (value.isEmpty) return null;
    // 去掉首尾冒号；兼容用户误输入 :name: 或 name:
    while (value.startsWith(':')) {
      value = value.substring(1);
    }
    while (value.endsWith(':')) {
      value = value.substring(0, value.length - 1);
    }
    value = value.trim();
    if (value.isEmpty) return null;
    // 纯 Unicode emoji 保留原样（少数站点可能直接存字符）
    return value;
  }

  /// 用于 EmojiText 渲染的 :name: 形式
  String? get emojiShortcode {
    final name = normalizeEmojiShortcode(emoji);
    if (name == null) return null;
    // 已是 Unicode 字符时直接返回，不包冒号
    if (!looksLikeEmojiShortcodeName(name)) return name;
    return ':$name:';
  }

  /// 是否为 Discourse 风格 emoji 短码名（可包进 :name:）
  static bool looksLikeEmojiShortcodeName(String value) {
    // Discourse emoji 名：字母数字、下划线、连字符，可选 skin tone :t2 等
    return RegExp(r'^[a-zA-Z0-9_+-]+(?::t\d)?$').hasMatch(value);
  }

  /// 把短码名转成 EmojiText 可渲染文本
  static String? toEmojiTextCode(String? raw) {
    final name = normalizeEmojiShortcode(raw);
    if (name == null) return null;
    if (!looksLikeEmojiShortcodeName(name)) return name;
    return ':$name:';
  }

  /// 是否可向频道添加成员
  ///
  /// 对齐 Discourse AddUsersToChannel / channel-info-members：
  /// 仅 DirectMessage，且为群组 DM，或尚无消息（可扩展为群聊）的 1:1 DM。
  bool get canAddMembers {
    final isDm = chatableType == 'DirectMessage' ||
        chatableType == 'DirectMessageChannel';
    if (!isDm) return false;
    if (userCanAddMembers == true) return true;
    // 群组 DM 可继续加人；尚无 lastMessage 的 DM 也可加人并升级为群聊
    if (isGroupDm) return true;
    if (lastMessage == null && lastMessageSentAt == null) return true;
    return false;
  }

  /// 获取 DM 频道的对方用户
  ///
  /// 过滤掉当前用户和系统用户（system）。系统用户在群聊中会被 Discourse
  /// 塞进 members，但官方渲染标题时明确排除它，避免把群聊显示成 "system"。
  ChatUser? getDmTargetUser(int? currentUserId) {
    if (chatableType != 'DirectMessage' && chatableType != 'DirectMessageChannel') {
      return null;
    }
    // 1. 从 dmUsers 中寻找非当前用户且非系统用户
    if (dmUsers != null && dmUsers!.isNotEmpty) {
      for (final u in dmUsers!) {
        if (u.isSystemUser) continue;
        if (currentUserId == null || u.id != currentUserId) {
          return u;
        }
      }
    }
    // 2. 从 lastMessage 中寻找非当前用户且非系统用户
    if (lastMessage?.user != null &&
        !lastMessage!.user!.isSystemUser &&
        (currentUserId == null || lastMessage!.user!.id != currentUserId)) {
      return lastMessage!.user;
    }
    // 3. 兜底：若有 lastMessage 用户且非系统用户，返回它
    if (lastMessage?.user != null && !lastMessage!.user!.isSystemUser) {
      return lastMessage!.user;
    }
    return null;
  }

  /// 格式化显示历史消息保留时长
  ///
  /// Discourse 不在频道 JSON 下发 retention；由站点设置控制：
  /// - 公开频道: chat_channel_retention_days
  /// - 直接消息: chat_dm_retention_days
  /// 0 / null 表示永久保留。
  String retentionDisplay({
    int? channelRetentionDays,
    int? dmRetentionDays,
  }) {
    // 若模型上已有解析值（兼容旧数据），优先使用
    final existingDays = retentionDays;
    if (existingDays != null && existingDays > 0) return '$existingDays 天';
    final existingHours = retentionHours;
    if (existingHours != null && existingHours > 0) return '$existingHours 小时';

    final isDm = chatableType == 'DirectMessage' ||
        chatableType == 'DirectMessageChannel';
    final days = isDm ? dmRetentionDays : channelRetentionDays;
    if (days != null && days > 0) return '$days 天';
    return '永久保留';
  }

  /// 内部工具：解析保留时长
  static (int? days, int? hours) _parseRetentionValues(Map<String, dynamic> json) {
    int? parsedDays;
    int? parsedHours;

    void parseValue(dynamic val, {bool defaultIsHours = false}) {
      if (val == null || parsedDays != null || parsedHours != null) return;
      if (val is num) {
        final n = val.toInt();
        if (n > 0) {
          if (defaultIsHours) {
            parsedHours = n;
          } else {
            parsedDays = n;
          }
        }
      } else if (val is String) {
        final str = val.trim().toLowerCase();
        if (str == 'never' || str == 'none' || str == '0' || str.isEmpty) return;
        final match = RegExp(r'^(\d+)_?(day|days|hour|hours|year|years)?$').firstMatch(str);
        if (match != null) {
          final numVal = int.tryParse(match.group(1) ?? '');
          final unit = match.group(2);
          if (numVal != null && numVal > 0) {
            if (unit == 'hour' || unit == 'hours' || defaultIsHours) {
              parsedHours = numVal;
            } else if (unit == 'year' || unit == 'years') {
              parsedDays = numVal * 365;
            } else {
              parsedDays = numVal;
            }
          }
        } else {
          final n = int.tryParse(str);
          if (n != null && n > 0) {
            if (defaultIsHours) {
              parsedHours = n;
            } else {
              parsedDays = n;
            }
          }
        }
      }
    }

    final metaObj = json['meta'] is Map ? Map<String, dynamic>.from(json['meta'] as Map) : null;
    final chatableObj = json['chatable'] is Map ? Map<String, dynamic>.from(json['chatable'] as Map) : null;

    // 天数解析
    parseValue(json['retention_days']);
    parseValue(metaObj?['retention_days']);
    parseValue(chatableObj?['retention_days']);
    parseValue(json['auto_delete_days']);
    parseValue(metaObj?['auto_delete_days']);
    parseValue(json['auto_archive_duration_days']);
    parseValue(metaObj?['auto_archive_duration_days']);

    // 字符串偏好设置解析 (e.g. "90_days", "24_hours")
    parseValue(json['auto_delete_preference']);
    parseValue(metaObj?['auto_delete_preference']);
    parseValue(chatableObj?['auto_delete_preference']);

    // 小时数解析
    parseValue(json['retention_hours'], defaultIsHours: true);
    parseValue(metaObj?['retention_hours'], defaultIsHours: true);
    parseValue(chatableObj?['retention_hours'], defaultIsHours: true);
    parseValue(json['auto_delete_hours'], defaultIsHours: true);
    parseValue(metaObj?['auto_delete_hours'], defaultIsHours: true);
    parseValue(json['auto_archive_duration_hours'], defaultIsHours: true);
    return (parsedDays, parsedHours);
  }

  factory ChatChannel.fromJson(Map<String, dynamic> json) {
    final membership = json['user_chat_channel_membership'] is Map
        ? Map<String, dynamic>.from(json['user_chat_channel_membership'] as Map)
        : (json['current_user_membership'] is Map
            ? Map<String, dynamic>.from(json['current_user_membership'] as Map)
            : null);

    final isStarred = (json['starred'] as bool?) ??
        (membership?['starred'] as bool?) ??
        false;
    // 仅当 membership.following == true 才算已加入；有 membership 但 following=false 表示曾加入后取消关注
    final isFollowing = (json['following'] as bool?) ??
        (membership?['following'] as bool?) ??
        false;
    final statusVal = json['status']?.toString();

    final canAdd = (json['allow_user_add'] as bool?) ??
        (json['user_can_add_members'] as bool?) ??
        (json['can_modify_members'] as bool?);

    final emojiVal = normalizeEmojiShortcode(
      json['emoji']?.toString() ??
          json['icon']?.toString() ??
          (json['meta'] is Map ? (json['meta']['emoji']?.toString()) : null),
    );

    final threading = (json['threading_enabled'] as bool?) ??
        (json['allow_threading'] as bool?) ??
        (json['meta'] is Map ? (json['meta']['threading_enabled'] as bool?) : null) ??
        false;

    // 通知级别可能是字符串 never/mention/always，或枚举整数 0/1/2
    String? notifLevel;
    final rawNotif =
        membership?['notification_level'] ?? json['notification_level'];
    if (rawNotif is String) {
      notifLevel = rawNotif;
    } else if (rawNotif is num) {
      notifLevel = switch (rawNotif.toInt()) {
        0 => 'never',
        1 => 'mention',
        2 => 'always',
        _ => rawNotif.toString(),
      };
    }

    final (rDays, rHours) = _parseRetentionValues(json);

    List<ChatUser>? parsedDmUsers;
    final chatableObj = json['chatable'] is Map ? json['chatable'] as Map : null;
    final usersList = json['users'] ??
        json['target_users'] ??
        json['members'] ??
        (chatableObj?['users'] ?? chatableObj?['members'] ?? chatableObj?['target_users']);
    // 群聊 DM 标记：Discourse DirectMessageSerializer 输出 group 字段
    // (direct_message_serializer.rb: attributes :group, :users)，并在
    // users.count > 1 时从 users 中移除当前用户（即返回的是"其他成员"）。
    // 因此 3 人直接消息的 dmUsers 长度为 2（两位其他用户），2 人直接消息长度为 1。
    // 用 > 1 判定群聊（≥2 位其他成员 = 3 人及以上直接消息）。
    final groupDmFlag = (chatableObj?['group'] as bool?) ??
        (json['group'] as bool?) ??
        (json['is_group'] as bool?) ??
        false;
    final isDmType = json['chatable_type']?.toString() == 'DirectMessage' ||
        json['chatable_type']?.toString() == 'DirectMessageChannel';
    if (usersList is List) {
      parsedDmUsers = usersList
          .whereType<Map>()
          .map((u) => ChatUser.fromJson(Map<String, dynamic>.from(u)))
          .toList();
    }
    // 在 parsedDmUsers 实际解析后计算 isGroupDm（用真实成员数）。
    // Discourse 在 users.count > 1 时从 users 中移除当前用户，因此：
    // - 2 人直接消息：dmUsers 长度 1（仅对方）
    // - 3 人及以上直接消息：dmUsers 长度 ≥ 2（其他成员，已不含当前用户）
    // 群聊判据 = group 标记为 true，或 dmUsers 长度 > 1（即 ≥2 位其他成员）。
    final resolvedGroupDm = groupDmFlag ||
        (isDmType && (parsedDmUsers?.length ?? 0) > 1);

    final parsedLastMessage = json['last_message'] is Map
        ? ChatMessage.fromJson(
            Map<String, dynamic>.from(json['last_message'] as Map),
          )
        : null;
    // Discourse 已删除 last_message_sent_at 列，时间来自 last_message.created_at
    final parsedLastMessageSentAt =
        TimeUtils.parseUtcTime(json['last_message_sent_at']?.toString()) ??
            parsedLastMessage?.createdAt;

    return ChatChannel(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: json['title']?.toString(),
      slug: json['slug']?.toString(),
      chatableType: json['chatable_type']?.toString(),
      chatableId: (json['chatable_id'] as num?)?.toInt(),
      chatableUrl: json['chatable_url']?.toString(),
      description: json['description']?.toString(),
      lastMessage: parsedLastMessage,
      lastMessageSentAt: parsedLastMessageSentAt,
      lastReadMessageId: (json['last_read_message_id'] as num?)?.toInt() ??
          (membership?['last_read_message_id'] as num?)?.toInt(),
      // 官方字段 memberships_count
      membersCount: (json['memberships_count'] as num?)?.toInt() ??
          (json['members_count'] as num?)?.toInt() ??
          (json['user_count'] as num?)?.toInt(),
      muted: (json['muted'] as bool?) ?? (membership?['muted'] as bool?) ?? false,
      mutedUntil: json['muted_until'] != null
          ? TimeUtils.parseUtcTime(json['muted_until']?.toString())
          : null,
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
      // 官方 tracking 字段是 mention_count
      unreadMentions: (json['unread_mentions'] as num?)?.toInt() ??
          (json['mention_count'] as num?)?.toInt() ??
          0,
      meta: json['meta'] is Map
          ? Map<String, dynamic>.from(json['meta'] as Map)
          : null,
      starred: isStarred,
      following: isFollowing,
      userChatChannelMembership: membership,
      userCanAddMembers: canAdd,
      emoji: emojiVal,
      threadingEnabled: threading,
      retentionDays: rDays,
      retentionHours: rHours,
      notificationLevel: notifLevel,
      dmUsers: parsedDmUsers,
      isGroupDm: resolvedGroupDm,
      status: statusVal,
    );
  }

  ChatChannel copyWith({
    int? id,
    String? title,
    String? slug,
    String? chatableType,
    int? chatableId,
    String? chatableUrl,
    String? description,
    DateTime? lastMessageSentAt,
    ChatMessage? lastMessage,
    int? lastReadMessageId,
    int? membersCount,
    bool? muted,
    DateTime? mutedUntil,
    int? unreadCount,
    int? unreadMentions,
    Map<String, dynamic>? meta,
    bool? starred,
    bool? following,
    Map<String, dynamic>? userChatChannelMembership,
    bool? userCanAddMembers,
    String? emoji,
    bool? threadingEnabled,
    int? retentionDays,
    int? retentionHours,
    String? notificationLevel,
    List<ChatUser>? dmUsers,
    bool? isGroupDm,
    String? status,
  }) {
    return ChatChannel(
      id: id ?? this.id,
      title: title ?? this.title,
      slug: slug ?? this.slug,
      chatableType: chatableType ?? this.chatableType,
      chatableId: chatableId ?? this.chatableId,
      chatableUrl: chatableUrl ?? this.chatableUrl,
      description: description ?? this.description,
      lastMessageSentAt: lastMessageSentAt ?? this.lastMessageSentAt,
      lastMessage: lastMessage ?? this.lastMessage,
      lastReadMessageId: lastReadMessageId ?? this.lastReadMessageId,
      membersCount: membersCount ?? this.membersCount,
      muted: muted ?? this.muted,
      mutedUntil: mutedUntil ?? this.mutedUntil,
      unreadCount: unreadCount ?? this.unreadCount,
      unreadMentions: unreadMentions ?? this.unreadMentions,
      meta: meta ?? this.meta,
      starred: starred ?? this.starred,
      following: following ?? this.following,
      userChatChannelMembership:
          userChatChannelMembership ?? this.userChatChannelMembership,
      userCanAddMembers: userCanAddMembers ?? this.userCanAddMembers,
      emoji: emoji ?? this.emoji,
      threadingEnabled: threadingEnabled ?? this.threadingEnabled,
      retentionDays: retentionDays ?? this.retentionDays,
      retentionHours: retentionHours ?? this.retentionHours,
      notificationLevel: notificationLevel ?? this.notificationLevel,
      dmUsers: dmUsers ?? this.dmUsers,
      isGroupDm: isGroupDm ?? this.isGroupDm,
      status: status ?? this.status,
    );
  }
}