import '../utils/time_utils.dart';
import '../utils/url_helper.dart';

/// 徽章类型
enum BadgeType {
  gold(1, '金牌'),
  silver(2, '银牌'),
  bronze(3, '铜牌');

  final int id;
  final String label;
  const BadgeType(this.id, this.label);

  static BadgeType fromId(int id) {
    return BadgeType.values.firstWhere(
      (type) => type.id == id,
      orElse: () => BadgeType.bronze,
    );
  }
}

/// 徽章模型
class Badge {
  final int id;
  final String name;
  final String description;
  final int badgeTypeId;
  final String? imageUrl;
  final String? icon;
  final int grantCount;
  final bool enabled;
  final bool allowTitle;
  final bool multipleGrant;
  final String? longDescription;
  final String slug;
  final int? badgeGroupingId;

  Badge({
    required this.id,
    required this.name,
    required this.description,
    required this.badgeTypeId,
    this.imageUrl,
    this.icon,
    required this.grantCount,
    required this.enabled,
    required this.allowTitle,
    required this.multipleGrant,
    this.longDescription,
    required this.slug,
    this.badgeGroupingId,
  });

  factory Badge.fromJson(Map<String, dynamic> json) {
    return Badge(
      id: json['id'] as int,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      badgeTypeId: json['badge_type_id'] as int,
      imageUrl: json['image_url'] as String?,
      icon: json['icon'] as String?,
      grantCount: json['grant_count'] as int? ?? 0,
      enabled: json['enabled'] as bool? ?? true,
      allowTitle: json['allow_title'] as bool? ?? false,
      multipleGrant: json['multiple_grant'] as bool? ?? false,
      longDescription: json['long_description'] as String?,
      slug: json['slug'] as String? ?? '',
      badgeGroupingId: json['badge_grouping_id'] as int?,
    );
  }

  BadgeType get badgeType => BadgeType.fromId(badgeTypeId);
}

/// 用户徽章模型
class UserBadge {
  final int id;
  final int badgeId;
  final int userId;
  final DateTime grantedAt;
  final String? grantedByUsername;
  final int? postId;
  final int? postNumber;
  final int? topicId;
  final String? topicTitle;
  final String? username;
  final int count;
  final int? groupingPosition;
  final bool? isFavorite;
  final bool? canFavorite;
  final Badge? badge;

  UserBadge({
    required this.id,
    required this.badgeId,
    this.userId = 0,
    required this.grantedAt,
    this.grantedByUsername,
    this.postId,
    this.postNumber,
    this.topicId,
    this.topicTitle,
    this.username,
    this.count = 1,
    this.groupingPosition,
    this.isFavorite,
    this.canFavorite,
    this.badge,
  });

  factory UserBadge.fromJson(Map<String, dynamic> json) {
    return UserBadge(
      id: json['id'] as int,
      badgeId: json['badge_id'] as int,
      userId: json['user_id'] as int? ?? 0,
      grantedAt: TimeUtils.parseUtcTime(json['granted_at'] as String?) ?? DateTime.now(),
      grantedByUsername: json['granted_by_username'] as String?,
      postId: json['post_id'] as int?,
      postNumber: json['post_number'] as int?,
      topicId: json['topic_id'] as int?,
      topicTitle: json['topic_title'] as String?,
      username: json['username'] as String?,
      count: json['count'] as int? ?? 1,
      groupingPosition: json['grouping_position'] as int?,
      isFavorite: json['is_favorite'] as bool?,
      canFavorite: json['can_favorite'] as bool?,
      badge: json['badge'] != null ? Badge.fromJson(json['badge'] as Map<String, dynamic>) : null,
    );
  }
}

/// 徽章详情响应
class BadgeDetailResponse {
  final Badge badge;
  final List<UserBadge> userBadges;
  final List<BadgeUser> grantedBies;
  final int totalCount;

  BadgeDetailResponse({
    required this.badge,
    required this.userBadges,
    required this.grantedBies,
    required this.totalCount,
  });

  factory BadgeDetailResponse.fromJson(Map<String, dynamic> json) {
    // 解析 badges 数组（在顶层）
    final badgesData = json['badges'] as List<dynamic>? ?? [];
    final badgesMap = <int, Badge>{};
    for (var badgeJson in badgesData) {
      final badge = Badge.fromJson(badgeJson as Map<String, dynamic>);
      badgesMap[badge.id] = badge;
    }

    // 解析 users 数组（在顶层）
    final usersData = json['users'] as List<dynamic>? ?? [];
    final usersMap = <int, BadgeUser>{};
    for (var userJson in usersData) {
      final user = BadgeUser.fromJson(userJson as Map<String, dynamic>);
      usersMap[user.id] = user;
    }

    // 解析 topics 数组（在顶层）
    final topicsData = json['topics'] as List<dynamic>? ?? [];
    final topicsMap = <int, String>{};
    for (var topicJson in topicsData) {
      final topicId = topicJson['id'] as int;
      final topicTitle = topicJson['title'] as String;
      topicsMap[topicId] = topicTitle;
    }

    // 解析 user_badges 数组
    List<dynamic> userBadgesData;
    int? totalCount;
    if (json.containsKey('user_badge_info')) {
      // /user_badges.json 格式
      final info = json['user_badge_info'] as Map<String, dynamic>;
      userBadgesData = info['user_badges'] as List<dynamic>? ?? [];
      totalCount = info['grant_count'] as int?;
    } else {
      // /user-badges/{username}.json 格式
      userBadgesData = json['user_badges'] as List<dynamic>? ?? [];
    }

    final userBadges = userBadgesData.map((e) {
      final userBadge = UserBadge.fromJson(e as Map<String, dynamic>);
      final badge = badgesMap[userBadge.badgeId];
      final topicTitle = userBadge.topicId != null ? topicsMap[userBadge.topicId] : null;

      return UserBadge(
        id: userBadge.id,
        badgeId: userBadge.badgeId,
        userId: userBadge.userId,
        grantedAt: userBadge.grantedAt,
        grantedByUsername: userBadge.grantedByUsername,
        postId: userBadge.postId,
        postNumber: userBadge.postNumber,
        topicId: userBadge.topicId,
        topicTitle: topicTitle ?? userBadge.topicTitle,
        username: userBadge.username,
        count: userBadge.count,
        groupingPosition: userBadge.groupingPosition,
        isFavorite: userBadge.isFavorite,
        canFavorite: userBadge.canFavorite,
        badge: badge ?? userBadge.badge,
      );
    }).toList();

    // 获取主徽章
    Badge badge;
    if (userBadges.isNotEmpty && userBadges.first.badge != null) {
      badge = userBadges.first.badge!;
    } else if (badgesMap.isNotEmpty) {
      badge = badgesMap.values.first;
    } else {
      badge = Badge(
        id: 0,
        name: '徽章',
        description: '',
        badgeTypeId: 3,
        grantCount: 0,
        enabled: true,
        allowTitle: false,
        multipleGrant: false,
        slug: '',
      );
    }

    return BadgeDetailResponse(
      badge: badge,
      userBadges: userBadges,
      grantedBies: usersMap.values.toList(),
      totalCount: totalCount ?? badge.grantCount,
    );
  }
}

/// 徽章用户信息
class BadgeUser {
  final int id;
  final String username;
  final String? name;
  final String avatarTemplate;
  final String? flairName;
  final String? flairUrl;
  final int? flairGroupId;
  final int trustLevel;
  final String? animatedAvatar;
  final bool? admin;
  final bool? moderator;

  BadgeUser({
    required this.id,
    required this.username,
    this.name,
    required this.avatarTemplate,
    this.flairName,
    this.flairUrl,
    this.flairGroupId,
    required this.trustLevel,
    this.animatedAvatar,
    this.admin,
    this.moderator,
  });

  factory BadgeUser.fromJson(Map<String, dynamic> json) {
    return BadgeUser(
      id: json['id'] as int,
      username: json['username'] as String,
      name: json['name'] as String?,
      avatarTemplate: json['avatar_template'] as String,
      flairName: json['flair_name'] as String?,
      flairUrl: json['flair_url'] as String?,
      flairGroupId: json['flair_group_id'] as int?,
      trustLevel: json['trust_level'] as int,
      animatedAvatar: json['animated_avatar'] as String?,
      admin: json['admin'] as bool?,
      moderator: json['moderator'] as bool?,
    );
  }

  String getAvatarUrl({int size = 96}) {
    return UrlHelper.resolveAvatarUrl(
      avatarTemplate: avatarTemplate,
      animatedAvatar: animatedAvatar,
      size: size,
    );
  }
}

/// 徽章话题信息
class BadgeTopic {
  final String fancyTitle;
  final int id;
  final String title;
  final String slug;
  final int postsCount;

  BadgeTopic({
    required this.fancyTitle,
    required this.id,
    required this.title,
    required this.slug,
    required this.postsCount,
  });

  factory BadgeTopic.fromJson(Map<String, dynamic> json) {
    return BadgeTopic(
      fancyTitle: json['fancy_title'] as String,
      id: json['id'] as int,
      title: json['title'] as String,
      slug: json['slug'] as String,
      postsCount: json['posts_count'] as int,
    );
  }
}
