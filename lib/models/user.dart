import '../l10n/s.dart';
import '../utils/time_utils.dart';
import '../utils/url_helper.dart';
import 'badge.dart';

/// 用户数据模型
class User {
  final int id;
  final String username;
  final String? name;
  final String? avatarTemplate;
  final String? animatedAvatar;
  final int trustLevel;
  final String? bio;
  final String? bioCooked;
  final String? bioRaw;

  // 背景图
  final String? cardBackgroundUploadUrl;
  final String? profileBackgroundUploadUrl;

  // 通知计数字段（从 session/current.json 或 MessageBus 获取）
  final int unreadNotifications;
  final int unreadHighPriorityNotifications;
  final int allUnreadNotificationsCount;
  final int seenNotificationId;
  final int notificationChannelPosition;

  // 待审核内容数(仅本人可见,UserSerializer include_pending_posts_count?)
  final int pendingPostsCount;

  // 用户状态
  final UserStatus? status;

  // 时间信息
  final DateTime? lastPostedAt;
  final DateTime? lastSeenAt;
  final DateTime? createdAt;
  final int? timeRead;        // 总阅读时长（秒）
  final int? recentTimeRead;  // 近 60 天阅读时长（秒）
  final String? location;
  final String? website;
  final String? websiteName;

  // Flair 徽章
  final String? flairUrl;
  final String? flairName;
  final String? flairBgColor;
  final String? flairColor;
  final int? flairGroupId;

  // 关注相关 (discourse-follow 插件)
  final bool? canFollow;           // 是否可以关注该用户
  final bool? isFollowed;          // 当前用户是否已关注该用户
  final int? totalFollowers;       // 粉丝数
  final int? totalFollowing;       // 关注数

  // 私信相关
  final bool? canSendPrivateMessages;        // 当前用户是否可以发送私信
  final bool? canSendPrivateMessageToUser;   // 是否可以给该用户发私信
  final bool? canChatUser;                   // 是否可与该用户聊天(chat 插件 user_card 注入)

  /// 该用户在某话题内的发帖数(card.json 带 include_post_count_for=topicId
  /// 时 serializer 注入,形如 {topic_id: count};官方用它决定用户卡片
  /// 是否显示「过滤到该用户的 N 帖」按钮)
  final Map<int, int> topicPostCount;

  // 积分相关
  final int? gamificationScore;

  // 订阅级别相关
  final bool? muted;           // 当前用户是否已静音该用户
  final bool? ignored;         // 当前用户是否已忽略该用户
  final bool? canMuteUser;     // 是否可以静音
  final bool? canIgnoreUser;   // 是否可以忽略

  // 封禁/禁言相关
  final String? suspendReason;    // 封禁原因
  final DateTime? suspendedTill;  // 封禁截止时间
  final String? silenceReason;    // 禁言原因
  final DateTime? silencedTill;   // 禁言截止时间

  // 角色（来自 /session/current.json 的 current_user）
  final bool admin;
  final bool moderator;

  /// discourse-assign 插件加的字段(add_to_serializer(:current_user, :can_assign))
  /// 只在 CurrentUserSerializer 里有,/u/username.json 这种公开资料接口没有——
  /// 见 core_providers.dart _mergeUser 里用预加载数据兜底。
  final bool canAssign;

  /// 隐私:隐藏公开资料与在线状态(user_option.hide_presence)。
  /// true 时客户端不得上报 presence(正在输入/在线)——对齐网页版
  /// chat.js 的前置判断。
  final bool hidePresence;

  /// 聊天草稿(current_user.chat_drafts,最近 20 条原始 JSON:
  /// {channel_id, data, thread_id});chat 层自行解析,登录会话期有效
  final List<Map<String, dynamic>> chatDrafts;


  User({
    required this.id,
    required this.username,
    this.name,
    this.avatarTemplate,
    this.animatedAvatar,
    required this.trustLevel,
    this.bio,
    this.bioCooked,
    this.bioRaw,
    this.cardBackgroundUploadUrl,
    this.profileBackgroundUploadUrl,
    this.unreadNotifications = 0,
    this.unreadHighPriorityNotifications = 0,
    this.allUnreadNotificationsCount = 0,
    this.seenNotificationId = 0,
    this.notificationChannelPosition = -1,
    this.pendingPostsCount = 0,
    this.status,
    this.lastPostedAt,
    this.lastSeenAt,
    this.createdAt,
    this.timeRead,
    this.recentTimeRead,
    this.location,
    this.website,
    this.websiteName,
    this.flairUrl,
    this.flairName,
    this.flairBgColor,
    this.flairColor,
    this.flairGroupId,
    this.canFollow,
    this.isFollowed,
    this.totalFollowers,
    this.totalFollowing,
    this.canSendPrivateMessages,
    this.canSendPrivateMessageToUser,
    this.canChatUser,
    this.topicPostCount = const {},
    this.gamificationScore,
    this.muted,
    this.ignored,
    this.canMuteUser,
    this.canIgnoreUser,
    this.suspendReason,
    this.suspendedTill,
    this.silenceReason,
    this.silencedTill,
    this.admin = false,
    this.moderator = false,
    this.canAssign = false,
    this.hidePresence = false,
    this.chatDrafts = const [],
  });

  User copyWith({
    int? unreadNotifications,
    int? unreadHighPriorityNotifications,
    int? allUnreadNotificationsCount,
    int? seenNotificationId,
    int? notificationChannelPosition,
    bool? muted,
    bool? ignored,
    bool? canAssign,
  }) {
    return User(
      id: id,
      username: username,
      name: name,
      avatarTemplate: avatarTemplate,
      animatedAvatar: animatedAvatar,
      trustLevel: trustLevel,
      bio: bio,
      bioCooked: bioCooked,
      bioRaw: bioRaw,
      cardBackgroundUploadUrl: cardBackgroundUploadUrl,
      profileBackgroundUploadUrl: profileBackgroundUploadUrl,
      unreadNotifications: unreadNotifications ?? this.unreadNotifications,
      unreadHighPriorityNotifications:
          unreadHighPriorityNotifications ?? this.unreadHighPriorityNotifications,
      allUnreadNotificationsCount:
          allUnreadNotificationsCount ?? this.allUnreadNotificationsCount,
      seenNotificationId: seenNotificationId ?? this.seenNotificationId,
      notificationChannelPosition:
          notificationChannelPosition ?? this.notificationChannelPosition,
      pendingPostsCount: pendingPostsCount,
      status: status,
      lastPostedAt: lastPostedAt,
      lastSeenAt: lastSeenAt,
      createdAt: createdAt,
      timeRead: timeRead,
      recentTimeRead: recentTimeRead,
      location: location,
      website: website,
      websiteName: websiteName,
      flairUrl: flairUrl,
      flairName: flairName,
      flairBgColor: flairBgColor,
      flairColor: flairColor,
      flairGroupId: flairGroupId,
      canFollow: canFollow,
      isFollowed: isFollowed,
      totalFollowers: totalFollowers,
      totalFollowing: totalFollowing,
      canSendPrivateMessages: canSendPrivateMessages,
      canSendPrivateMessageToUser: canSendPrivateMessageToUser,
      canChatUser: canChatUser,
      topicPostCount: topicPostCount,
      gamificationScore: gamificationScore,
      muted: muted ?? this.muted,
      ignored: ignored ?? this.ignored,
      canMuteUser: canMuteUser,
      canIgnoreUser: canIgnoreUser,
      suspendReason: suspendReason,
      suspendedTill: suspendedTill,
      silenceReason: silenceReason,
      silencedTill: silencedTill,
      admin: admin,
      moderator: moderator,
      canAssign: canAssign ?? this.canAssign,
      hidePresence: hidePresence,
      chatDrafts: chatDrafts,
    );
  }

  factory User.fromJson(Map<String, dynamic> json) {
    String? resolve(String? url) => url != null ? UrlHelper.resolveUrlWithCdn(url) : null;
    
    // 简单的 HTML 图片路径修复
    String? fixHtml(String? html) {
      if (html == null) return null;
      // 替换 src="/... 为 src="https://linux.do/...
      return html.replaceAllMapped(
        RegExp(r'''src=["'](/[^"']+)["']'''), 
        (match) => 'src="${UrlHelper.resolveUrlWithCdn(match.group(1)!)}"'
      );
    }

    return User(
      id: json['id'] as int? ?? 0,
      username: json['username'] as String? ?? '',
      name: json['name'] as String?,
      avatarTemplate: resolve(json['avatar_template'] as String?),
      animatedAvatar: resolve(json['animated_avatar'] as String?),
      trustLevel: json['trust_level'] as int? ?? 0,
      bio: fixHtml(json['bio_cooked'] as String?) ?? json['bio_excerpt'] as String? ?? json['bio_raw'] as String?,
      bioCooked: fixHtml(json['bio_cooked'] as String?),
      bioRaw: json['bio_raw'] as String?,
      cardBackgroundUploadUrl: resolve(json['card_background_upload_url'] as String?),
      profileBackgroundUploadUrl: resolve(json['profile_background_upload_url'] as String?),
      unreadNotifications: json['unread_notifications'] as int? ?? 0,
      unreadHighPriorityNotifications: json['unread_high_priority_notifications'] as int? ?? 0,
      allUnreadNotificationsCount: json['all_unread_notifications_count'] as int? ?? 0,
      seenNotificationId: json['seen_notification_id'] as int? ?? 0,
      notificationChannelPosition: json['notification_channel_position'] as int? ?? -1,
      pendingPostsCount: json['pending_posts_count'] as int? ?? 0,
      status: json['status'] != null ? UserStatus.fromJson(json['status']) : null,
      lastPostedAt: TimeUtils.parseUtcTime(json['last_posted_at'] as String?),
      lastSeenAt: TimeUtils.parseUtcTime(json['last_seen_at'] as String?),
      createdAt: TimeUtils.parseUtcTime(json['created_at'] as String?),
      timeRead: json['time_read'] as int?,
      recentTimeRead: json['recent_time_read'] as int?,
      location: json['location'] as String?,
      website: json['website'] as String?,
      websiteName: json['website_name'] as String?,
      flairUrl: resolve(json['flair_url'] as String?),
      flairName: json['flair_name'] as String?,
      flairBgColor: json['flair_bg_color'] as String?,
      flairColor: json['flair_color'] as String?,
      flairGroupId: json['flair_group_id'] as int?,
      canFollow: json['can_follow'] as bool?,
      isFollowed: json['is_followed'] as bool?,
      totalFollowers: json['total_followers'] as int?,
      totalFollowing: json['total_following'] as int?,
      canSendPrivateMessages: json['can_send_private_messages'] as bool?,
      canSendPrivateMessageToUser: json['can_send_private_message_to_user'] as bool?,
      canChatUser: json['can_chat_user'] as bool?,
      topicPostCount: {
        for (final e
            in (json['topic_post_count'] as Map<String, dynamic>? ?? const {})
                .entries)
          if (int.tryParse(e.key) != null && e.value is int)
            int.parse(e.key): e.value as int,
      },
      gamificationScore: json['gamification_score'] as int?,
      muted: json['muted'] as bool?,
      ignored: json['ignored'] as bool?,
      canMuteUser: json['can_mute_user'] as bool?,
      canIgnoreUser: json['can_ignore_user'] as bool?,
      suspendReason: json['suspend_reason'] as String?,
      suspendedTill: TimeUtils.parseUtcTime(json['suspended_till'] as String?),
      silenceReason: json['silence_reason'] as String?,
      silencedTill: TimeUtils.parseUtcTime(json['silenced_till'] as String?),
      admin: json['admin'] as bool? ?? false,
      moderator: json['moderator'] as bool? ?? false,
      canAssign: json['can_assign'] as bool? ?? false,
      hidePresence:
          (json['user_option'] as Map<String, dynamic>?)?['hide_presence']
                  as bool? ??
              false,
      chatDrafts: (json['chat_drafts'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList(),
    );
  }

  /// 序列化为缓存 JSON（字段已处理过，直接存储）
  Map<String, dynamic> toCacheJson() => {
    'id': id,
    'username': username,
    'name': name,
    'avatar_template': avatarTemplate,
    'animated_avatar': animatedAvatar,
    'trust_level': trustLevel,
    'status': status != null ? {'description': status!.description, 'emoji': status!.emoji} : null,
    'flair_url': flairUrl,
    'flair_name': flairName,
    'flair_bg_color': flairBgColor,
    'flair_color': flairColor,
    'gamification_score': gamificationScore,
    'admin': admin,
    'moderator': moderator,
    'can_assign': canAssign,
  };

  /// 从缓存 JSON 恢复（不再调用 resolveUrl/fixHtml，直接读取）
  factory User.fromCacheJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as int? ?? 0,
      username: json['username'] as String? ?? '',
      name: json['name'] as String?,
      avatarTemplate: json['avatar_template'] as String?,
      animatedAvatar: json['animated_avatar'] as String?,
      trustLevel: json['trust_level'] as int? ?? 0,
      status: json['status'] != null ? UserStatus.fromJson(json['status'] as Map<String, dynamic>) : null,
      flairUrl: json['flair_url'] as String?,
      flairName: json['flair_name'] as String?,
      flairBgColor: json['flair_bg_color'] as String?,
      flairColor: json['flair_color'] as String?,
      gamificationScore: json['gamification_score'] as int?,
      admin: json['admin'] as bool? ?? false,
      moderator: json['moderator'] as bool? ?? false,
      canAssign: json['can_assign'] as bool? ?? false,
    );
  }

  /// 是否被封禁（suspended_till 在当前时间之后）
  bool get isSuspended => suspendedTill != null && suspendedTill!.isAfter(DateTime.now());

  /// 是否被永久封禁（超过 100 年）
  bool get isSuspendedForever => suspendedTill != null &&
      suspendedTill!.difference(DateTime.now()).inDays > 36500;

  /// 是否被禁言（silenced_till 在当前时间之后）
  bool get isSilenced => silencedTill != null && silencedTill!.isAfter(DateTime.now());

  /// 是否被永久禁言（超过 100 年）
  bool get isSilencedForever => silencedTill != null &&
      silencedTill!.difference(DateTime.now()).inDays > 36500;

  /// 是否为站点 staff（admin 或 moderator）。
  /// 对齐 discourse `Guardian#is_staff?`，用于编辑历史 staff 操作权限判断。
  bool get isStaff => admin || moderator;

  /// 获取背景图 URL（优先 profile，其次 card）
  String? get backgroundUrl => profileBackgroundUploadUrl ?? cardBackgroundUploadUrl;

  /// 获取信任等级描述
  String get trustLevelString {
    switch (trustLevel) {
      case 0:
        return S.current.user_trustLevel0;
      case 1:
        return S.current.user_trustLevel1;
      case 2:
        return S.current.user_trustLevel2;
      case 3:
        return S.current.user_trustLevel3;
      case 4:
        return S.current.user_trustLevel4;
      default:
        return S.current.user_trustLevelUnknown(trustLevel);
    }
  }
  
  /// 获取头像 URL，优先使用动画头像（GIF）
  String getAvatarUrl({int size = 120}) {
    if (animatedAvatar != null && animatedAvatar!.isNotEmpty) {
      return UrlHelper.resolveUrlWithCdn(animatedAvatar!);
    }
    if (avatarTemplate == null) return '';
    final template = avatarTemplate!.replaceAll('{size}', size.toString());
    return UrlHelper.resolveUrlWithCdn(template);
  }
}

/// 用户状态
class UserStatus {
  final String? description;
  final String? emoji;
  
  UserStatus({this.description, this.emoji});
  
  factory UserStatus.fromJson(Map<String, dynamic> json) {
    return UserStatus(
      description: json['description'] as String?,
      emoji: json['emoji'] as String?,
    );
  }
}

/// 用户统计数据
class UserSummary {
  final int daysVisited;
  final int postsReadCount;
  final int likesReceived;
  final int likesGiven;
  final int topicCount;
  final int postCount;
  final int timeRead; // 秒
  final int bookmarkCount;
  final int topicsEntered; // 浏览主题数
  final int recentTimeRead; // 近60天阅读时间（秒）

  // 详细统计
  final List<SummaryTopic> topics;
  final List<SummaryReply> replies;
  final List<SummaryLink> links;
  final List<SummaryUserWithCount> mostRepliedToUsers;
  final List<SummaryUserWithCount> mostLikedByUsers;
  final List<SummaryUserWithCount> mostLikedUsers;
  final List<SummaryCategory> topCategories;
  final List<Badge> badges;

  UserSummary({
    required this.daysVisited,
    required this.postsReadCount,
    required this.likesReceived,
    required this.likesGiven,
    required this.topicCount,
    required this.postCount,
    required this.timeRead,
    required this.bookmarkCount,
    this.topicsEntered = 0,
    this.recentTimeRead = 0,
    this.topics = const [],
    this.replies = const [],
    this.links = const [],
    this.mostRepliedToUsers = const [],
    this.mostLikedByUsers = const [],
    this.mostLikedUsers = const [],
    this.topCategories = const [],
    this.badges = const [],
  });

  factory UserSummary.fromJson(Map<String, dynamic> json) {
    final summary = json['user_summary'] as Map<String, dynamic>? ?? {};

    // 热门话题：完整数据在顶层 json['topics'] 中 sideload
    final sideloadedTopics = json['topics'] as List<dynamic>? ?? [];
    final topics = sideloadedTopics
        .map((e) => SummaryTopic.fromJson(e as Map<String, dynamic>))
        .toList();
    final topicMap = {for (final t in topics) t.id: t};

    // 解析回复列表
    final repliesJson = summary['replies'] as List<dynamic>? ?? [];
    // 解析链接列表
    final linksJson = summary['links'] as List<dynamic>? ?? [];
    // 解析用户列表
    final mostRepliedTo = summary['most_replied_to_users'] as List<dynamic>? ?? [];
    final mostLikedBy = summary['most_liked_by_users'] as List<dynamic>? ?? [];
    final mostLiked = summary['most_liked_users'] as List<dynamic>? ?? [];
    // 解析分类列表
    final topCats = summary['top_categories'] as List<dynamic>? ?? [];
    // 热门徽章：完整数据在顶层 json['badges'] 中 sideload
    final badgesJson = json['badges'] as List<dynamic>? ?? [];

    return UserSummary(
      daysVisited: summary['days_visited'] as int? ?? 0,
      postsReadCount: summary['posts_read_count'] as int? ?? 0,
      likesReceived: summary['likes_received'] as int? ?? 0,
      likesGiven: summary['likes_given'] as int? ?? 0,
      topicCount: summary['topic_count'] as int? ?? 0,
      postCount: summary['post_count'] as int? ?? 0,
      timeRead: summary['time_read'] as int? ?? 0,
      bookmarkCount: summary['bookmark_count'] as int? ?? 0,
      topicsEntered: summary['topics_entered'] as int? ?? 0,
      recentTimeRead: summary['recent_time_read'] as int? ?? 0,
      topics: topics,
      replies: repliesJson.map((e) => SummaryReply.fromJson(e as Map<String, dynamic>, topicMap)).toList(),
      links: linksJson.map((e) => SummaryLink.fromJson(e as Map<String, dynamic>, topicMap)).toList(),
      mostRepliedToUsers: mostRepliedTo.map((e) => SummaryUserWithCount.fromJson(e as Map<String, dynamic>)).toList(),
      mostLikedByUsers: mostLikedBy.map((e) => SummaryUserWithCount.fromJson(e as Map<String, dynamic>)).toList(),
      mostLikedUsers: mostLiked.map((e) => SummaryUserWithCount.fromJson(e as Map<String, dynamic>)).toList(),
      topCategories: topCats.map((e) => SummaryCategory.fromJson(e as Map<String, dynamic>)).toList(),
      badges: badgesJson.map((e) => Badge.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }

  /// 序列化为缓存 JSON
  Map<String, dynamic> toCacheJson() => {
    'days_visited': daysVisited,
    'posts_read_count': postsReadCount,
    'likes_received': likesReceived,
    'post_count': postCount,
    'likes_given': likesGiven,
    'topic_count': topicCount,
    'time_read': timeRead,
    'bookmark_count': bookmarkCount,
    'topics_entered': topicsEntered,
    'recent_time_read': recentTimeRead,
  };

  /// 从缓存 JSON 恢复
  factory UserSummary.fromCacheJson(Map<String, dynamic> json) {
    return UserSummary(
      daysVisited: json['days_visited'] as int? ?? 0,
      postsReadCount: json['posts_read_count'] as int? ?? 0,
      likesReceived: json['likes_received'] as int? ?? 0,
      likesGiven: json['likes_given'] as int? ?? 0,
      topicCount: json['topic_count'] as int? ?? 0,
      postCount: json['post_count'] as int? ?? 0,
      timeRead: json['time_read'] as int? ?? 0,
      bookmarkCount: json['bookmark_count'] as int? ?? 0,
      topicsEntered: json['topics_entered'] as int? ?? 0,
      recentTimeRead: json['recent_time_read'] as int? ?? 0,
    );
  }

  /// 格式化阅读时间
  String get formattedTimeRead {
    final hours = timeRead ~/ 3600;
    if (hours > 0) return '${hours}h';
    final minutes = timeRead ~/ 60;
    return '${minutes}m';
  }
}

/// 总结页 - 话题
class SummaryTopic {
  final int id;
  final String title;
  final String? slug;
  final int likeCount;
  final int? categoryId;
  final DateTime? createdAt;

  const SummaryTopic({
    required this.id,
    required this.title,
    this.slug,
    this.likeCount = 0,
    this.categoryId,
    this.createdAt,
  });

  factory SummaryTopic.fromJson(Map<String, dynamic> json) {
    return SummaryTopic(
      id: json['id'] as int? ?? 0,
      title: json['title'] as String? ?? '',
      slug: json['slug'] as String?,
      likeCount: json['like_count'] as int? ?? 0,
      categoryId: json['category_id'] as int?,
      createdAt: TimeUtils.parseUtcTime(json['created_at'] as String?),
    );
  }
}

/// 总结页 - 回复
class SummaryReply {
  final int? topicId;
  final int postNumber;
  final int likeCount;
  final DateTime? createdAt;
  final SummaryTopic? topic;

  const SummaryReply({
    this.topicId,
    required this.postNumber,
    this.likeCount = 0,
    this.createdAt,
    this.topic,
  });

  factory SummaryReply.fromJson(Map<String, dynamic> json, Map<int, SummaryTopic> topicMap) {
    final topicId = json['topic_id'] as int?;
    // 优先从嵌套的 topic 对象解析，其次从 sideload 映射中查找
    final topicJson = json['topic'] as Map<String, dynamic>?;
    final topic = topicJson != null
        ? SummaryTopic.fromJson(topicJson)
        : (topicId != null ? topicMap[topicId] : null);
    return SummaryReply(
      topicId: topicId ?? topic?.id,
      postNumber: json['post_number'] as int? ?? 0,
      likeCount: json['like_count'] as int? ?? 0,
      createdAt: TimeUtils.parseUtcTime(json['created_at'] as String?),
      topic: topic,
    );
  }
}

/// 总结页 - 链接
class SummaryLink {
  final String url;
  final String? title;
  final int clicks;
  final int? postNumber;
  final int? topicId;
  final SummaryTopic? topic;

  const SummaryLink({
    required this.url,
    this.title,
    this.clicks = 0,
    this.postNumber,
    this.topicId,
    this.topic,
  });

  factory SummaryLink.fromJson(Map<String, dynamic> json, Map<int, SummaryTopic> topicMap) {
    final topicId = json['topic_id'] as int?;
    final topicJson = json['topic'] as Map<String, dynamic>?;
    final topic = topicJson != null
        ? SummaryTopic.fromJson(topicJson)
        : (topicId != null ? topicMap[topicId] : null);
    return SummaryLink(
      url: json['url'] as String? ?? '',
      title: json['title'] as String?,
      clicks: json['clicks'] as int? ?? 0,
      postNumber: json['post_number'] as int?,
      topicId: topicId ?? topic?.id,
      topic: topic,
    );
  }
}

/// 总结页 - 用户统计（用于最多回复/点赞等）
class SummaryUserWithCount {
  final int id;
  final String username;
  final String? name;
  final String? avatarTemplate;
  final int count;

  const SummaryUserWithCount({
    required this.id,
    required this.username,
    this.name,
    this.avatarTemplate,
    this.count = 0,
  });

  factory SummaryUserWithCount.fromJson(Map<String, dynamic> json) {
    return SummaryUserWithCount(
      id: json['id'] as int? ?? 0,
      username: json['username'] as String? ?? '',
      name: json['name'] as String?,
      avatarTemplate: json['avatar_template'] as String?,
      count: json['count'] as int? ?? 0,
    );
  }

  String getAvatarUrl({int size = 120}) {
    if (avatarTemplate == null) return '';
    final template = avatarTemplate!.replaceAll('{size}', '$size');
    return UrlHelper.resolveUrlWithCdn(template);
  }
}

/// 总结页 - 热门类别
class SummaryCategory {
  final int id;
  final String name;
  final String? color;
  final String? slug;
  final int topicCount;
  final int postCount;

  const SummaryCategory({
    required this.id,
    required this.name,
    this.color,
    this.slug,
    this.topicCount = 0,
    this.postCount = 0,
  });

  factory SummaryCategory.fromJson(Map<String, dynamic> json) {
    return SummaryCategory(
      id: json['id'] as int? ?? 0,
      name: json['name'] as String? ?? '',
      color: json['color'] as String?,
      slug: json['slug'] as String?,
      topicCount: json['topic_count'] as int? ?? 0,
      postCount: json['post_count'] as int? ?? 0,
    );
  }
}

/// 当前用户信息（从 /session/current.json 获取）
class CurrentUser {
  final User user;
  final bool isLoggedIn;
  
  CurrentUser({required this.user, required this.isLoggedIn});
  
  factory CurrentUser.fromJson(Map<String, dynamic> json) {
    final currentUser = json['current_user'] as Map<String, dynamic>?;
    if (currentUser == null) {
      throw Exception('Not logged in');
    }
    return CurrentUser(
      user: User.fromJson(currentUser),
      isLoggedIn: true,
    );
  }
}

/// 关注/粉丝用户简化模型
class FollowUser {
  final int id;
  final String username;
  final String? name;
  final String? avatarTemplate;

  FollowUser({
    required this.id,
    required this.username,
    this.name,
    this.avatarTemplate,
  });

  factory FollowUser.fromJson(Map<String, dynamic> json) {
    return FollowUser(
      id: json['id'] as int,
      username: json['username'] as String,
      name: json['name'] as String?,
      avatarTemplate: json['avatar_template'] as String?,
    );
  }

  String getAvatarUrl({int size = 96}) {
    if (avatarTemplate == null) return '';
    final template = avatarTemplate!.replaceAll('{size}', size.toString());
    return UrlHelper.resolveUrlWithCdn(template);
  }
}
