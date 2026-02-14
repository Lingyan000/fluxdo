import '../utils/time_utils.dart';
import '../utils/url_helper.dart';
import 'badge.dart';

/// 用户数据模型
class User {
  final int id;
  final String username;
  final String? name;
  final String? avatarTemplate;
  final String? animatedAvatar; // 动画头像（GIF）
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

  // 用户状态
  final UserStatus? status;

  // 时间信息
  final DateTime? lastPostedAt;
  final DateTime? lastSeenAt;
  final DateTime? createdAt;
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

  // 积分相关
  final int? gamificationScore;

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
    this.status,
    this.lastPostedAt,
    this.lastSeenAt,
    this.createdAt,
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
    this.gamificationScore,
  });

  User copyWith({
    int? id,
    String? username,
    String? name,
    String? avatarTemplate,
    String? animatedAvatar,
    int? trustLevel,
    String? bio,
    String? bioCooked,
    String? bioRaw,
    String? cardBackgroundUploadUrl,
    String? profileBackgroundUploadUrl,
    int? unreadNotifications,
    int? unreadHighPriorityNotifications,
    int? allUnreadNotificationsCount,
    int? seenNotificationId,
    int? notificationChannelPosition,
    UserStatus? status,
    DateTime? lastPostedAt,
    DateTime? lastSeenAt,
    DateTime? createdAt,
    String? location,
    String? website,
    String? websiteName,
    String? flairUrl,
    String? flairName,
    String? flairBgColor,
    String? flairColor,
    int? flairGroupId,
    bool? canFollow,
    bool? isFollowed,
    int? totalFollowers,
    int? totalFollowing,
    bool? canSendPrivateMessages,
    bool? canSendPrivateMessageToUser,
    int? gamificationScore,
  }) {
    return User(
      id: id ?? this.id,
      username: username ?? this.username,
      name: name ?? this.name,
      avatarTemplate: avatarTemplate ?? this.avatarTemplate,
      animatedAvatar: animatedAvatar ?? this.animatedAvatar,
      trustLevel: trustLevel ?? this.trustLevel,
      bio: bio ?? this.bio,
      bioCooked: bioCooked ?? this.bioCooked,
      bioRaw: bioRaw ?? this.bioRaw,
      cardBackgroundUploadUrl: cardBackgroundUploadUrl ?? this.cardBackgroundUploadUrl,
      profileBackgroundUploadUrl: profileBackgroundUploadUrl ?? this.profileBackgroundUploadUrl,
      unreadNotifications: unreadNotifications ?? this.unreadNotifications,
      unreadHighPriorityNotifications:
          unreadHighPriorityNotifications ?? this.unreadHighPriorityNotifications,
      allUnreadNotificationsCount:
          allUnreadNotificationsCount ?? this.allUnreadNotificationsCount,
      seenNotificationId: seenNotificationId ?? this.seenNotificationId,
      notificationChannelPosition:
          notificationChannelPosition ?? this.notificationChannelPosition,
      status: status ?? this.status,
      lastPostedAt: lastPostedAt ?? this.lastPostedAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      createdAt: createdAt ?? this.createdAt,
      location: location ?? this.location,
      website: website ?? this.website,
      websiteName: websiteName ?? this.websiteName,
      flairUrl: flairUrl ?? this.flairUrl,
      flairName: flairName ?? this.flairName,
      flairBgColor: flairBgColor ?? this.flairBgColor,
      flairColor: flairColor ?? this.flairColor,
      flairGroupId: flairGroupId ?? this.flairGroupId,
      canFollow: canFollow ?? this.canFollow,
      isFollowed: isFollowed ?? this.isFollowed,
      totalFollowers: totalFollowers ?? this.totalFollowers,
      totalFollowing: totalFollowing ?? this.totalFollowing,
      canSendPrivateMessages: canSendPrivateMessages ?? this.canSendPrivateMessages,
      canSendPrivateMessageToUser: canSendPrivateMessageToUser ?? this.canSendPrivateMessageToUser,
      gamificationScore: gamificationScore ?? this.gamificationScore,
    );
  }

  factory User.fromJson(Map<String, dynamic> json) {
    String? resolve(String? url) => url != null ? UrlHelper.resolveUrl(url) : null;
    
    // 简单的 HTML 图片路径修复
    String? fixHtml(String? html) {
      if (html == null) return null;
      // 替换 src="/... 为 src="https://linux.do/...
      return html.replaceAllMapped(
        RegExp(r'''src=["'](/[^"']+)["']'''), 
        (match) => 'src="${UrlHelper.resolveUrl(match.group(1)!)}"'
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
      status: json['status'] != null ? UserStatus.fromJson(json['status']) : null,
      lastPostedAt: TimeUtils.parseUtcTime(json['last_posted_at'] as String?),
      lastSeenAt: TimeUtils.parseUtcTime(json['last_seen_at'] as String?),
      createdAt: TimeUtils.parseUtcTime(json['created_at'] as String?),
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
      gamificationScore: json['gamification_score'] as int?,
    );
  }

  /// 获取背景图 URL（优先 profile，其次 card）
  String? get backgroundUrl => profileBackgroundUploadUrl ?? cardBackgroundUploadUrl;

  /// 获取信任等级描述
  String get trustLevelString {
    switch (trustLevel) {
      case 0:
        return 'L0 新用户';
      case 1:
        return 'L1 基本用户';
      case 2:
        return 'L2 成员';
      case 3:
        return 'L3 活跃用户';
      case 4:
        return 'L4 领袖';
      default:
        return '等级 $trustLevel';
    }
  }
  
  /// 获取头像 URL，优先使用动画头像（GIF）
  String getAvatarUrl({int size = 120}) {
    return UrlHelper.resolveAvatarUrl(
      avatarTemplate: avatarTemplate,
      animatedAvatar: animatedAvatar,
      size: size,
    );
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
    return UrlHelper.resolveAvatarUrl(avatarTemplate: avatarTemplate, size: size);
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
    return UrlHelper.resolveAvatarUrl(avatarTemplate: avatarTemplate, size: size);
  }
}
