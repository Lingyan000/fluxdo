part of '../topic.dart';

/// 链接点击统计
class LinkCount {
  final String url;
  final bool internal;
  final bool reflection;
  final String? title;
  final int clicks;

  const LinkCount({
    required this.url,
    required this.internal,
    required this.reflection,
    this.title,
    required this.clicks,
  });

  factory LinkCount.fromJson(Map<String, dynamic> json) {
    return LinkCount(
      url: json['url'] as String? ?? '',
      internal: json['internal'] as bool? ?? false,
      reflection: json['reflection'] as bool? ?? false,
      title: json['title'] as String?,
      clicks: json['clicks'] as int? ?? 0,
    );
  }
}

/// 回复目标用户
class ReplyToUser {
  final String username;
  final String? name;
  final String avatarTemplate;

  const ReplyToUser({
    required this.username,
    this.name,
    required this.avatarTemplate,
  });

  factory ReplyToUser.fromJson(Map<String, dynamic> json) {
    return ReplyToUser(
      username: json['username'] as String? ?? '',
      name: json['name'] as String?,
      avatarTemplate: json['avatar_template'] as String? ?? '',
    );
  }

  String getAvatarUrl({int size = 40}) {
    return UrlHelper.resolveAvatarUrl(avatarTemplate: avatarTemplate, size: size);
  }
}

/// 被提及用户（含状态信息）
class MentionedUser {
  final int id;
  final String username;
  final String? name;
  final String? avatarTemplate;
  final String? statusEmoji;
  final String? statusDescription;

  const MentionedUser({
    required this.id,
    required this.username,
    this.name,
    this.avatarTemplate,
    this.statusEmoji,
    this.statusDescription,
  });

  factory MentionedUser.fromJson(Map<String, dynamic> json) {
    final status = json['status'] as Map<String, dynamic>?;
    return MentionedUser(
      id: json['id'] as int? ?? 0,
      username: json['username'] as String? ?? '',
      name: json['name'] as String?,
      avatarTemplate: json['avatar_template'] as String?,
      statusEmoji: status?['emoji'] as String?,
      statusDescription: status?['description'] as String?,
    );
  }
}

/// 帖子头部显示的徽章
class GrantedBadge {
  final int id;
  final String name;
  final String? icon;      // FontAwesome 图标名，如 "seedling"
  final String? imageUrl;  // 图片 URL（与 icon 二选一）
  final String slug;
  final int badgeTypeId;   // 1=Gold, 2=Silver, 3=Bronze

  const GrantedBadge({
    required this.id,
    required this.name,
    this.icon,
    this.imageUrl,
    required this.slug,
    this.badgeTypeId = 0,
  });

  factory GrantedBadge.fromJson(Map<String, dynamic> json) {
    final badge = json['badge'] as Map<String, dynamic>? ?? json;
    return GrantedBadge(
      id: badge['id'] as int? ?? 0,
      name: badge['name'] as String? ?? '',
      icon: badge['icon'] as String?,
      imageUrl: badge['image_url'] as String?,
      slug: badge['slug'] as String? ?? '',
      badgeTypeId: badge['badge_type_id'] as int? ?? 0,
    );
  }
}

/// 帖子回应（Reaction）
class PostReaction {
  final String id;  // emoji 名称，如 "heart", "distorted_face"
  final String type;
  final int count;

  const PostReaction({required this.id, required this.type, required this.count});

  factory PostReaction.fromJson(Map<String, dynamic> json) {
    return PostReaction(
      id: json['id'] as String? ?? '',
      type: json['type'] as String? ?? 'emoji',
      count: json['count'] as int? ?? 0,
    );
  }
}

/// 帖子（回复）数据模型
class Post {
  final int id;
  final String? name;
  final String username;
  final String avatarTemplate;
  final String? animatedAvatar; // 动画头像（GIF）
  final String cooked; // HTML 内容
  final int postNumber;
  final int postType;
  final DateTime updatedAt;
  final DateTime createdAt;
  final int likeCount;
  final int replyCount;
  final int replyToPostNumber;
  final ReplyToUser? replyToUser;
  final bool scoreHidden;
  final bool canEdit;
  final bool canDelete;
  final bool canRecover;
  final bool canWiki;
  final bool bookmarked;
  final int? bookmarkId; // 书签 ID（用于删除书签）
  final bool read; // 是否已读
  final List<dynamic>? actionsSummary;
  final List<LinkCount>? linkCounts; // 链接点击统计
  final List<PostReaction>? reactions; // 回应/表情
  final PostReaction? currentUserReaction; // 当前用户的回应
  final List<Poll>? polls; // 投票列表
  final Map<String, List<String>>? pollsVotes; // 用户投票记录 {pollName: [optionId]}

  // small_action 相关字段
  final String? actionCode;       // 操作代码，如 "pinned.enabled", "closed.enabled"
  final String? actionCodeWho;    // 操作执行者用户名
  final String? actionCodePath;   // 操作关联的路径

  // Flair 徽章
  final String? flairUrl;
  final String? flairName;
  final String? flairBgColor;
  final String? flairColor;
  final int? flairGroupId;

  // 用户主要群组
  final String? primaryGroupName;

  // 被提及用户（含状态信息）
  final List<MentionedUser>? mentionedUsers;

  // 已解决问题相关
  final bool acceptedAnswer;       // 此帖子是否是被接受的答案
  final bool canAcceptAnswer;      // 当前用户是否可以接受此帖子为答案
  final bool canUnacceptAnswer;    // 当前用户是否可以取消接受

  // 删除状态
  final DateTime? deletedAt;       // 删除时间（不为空表示已删除）
  final bool userDeleted;          // 是否是用户自己删除的

  // 用户头衔和状态
  final String? userTitle;         // 用户头衔
  final UserStatus? userStatus;    // 用户状态（emoji + 描述）

  // 帖子头部徽章
  final List<GrantedBadge>? badgesGranted; // 帖子头部显示的徽章

  Post({
    required this.id,
    this.name,
    required this.username,
    required this.avatarTemplate,
    this.animatedAvatar,
    required this.cooked,
    required this.postNumber,
    required this.postType,
    required this.updatedAt,
    required this.createdAt,
    required this.likeCount,
    required this.replyCount,
    this.replyToPostNumber = 0,
    this.replyToUser,
    this.scoreHidden = false,
    this.canEdit = false,
    this.canDelete = false,
    this.canRecover = false,
    this.canWiki = false,
    this.bookmarked = false,
    this.bookmarkId,
    this.read = false,
    this.actionsSummary,
    this.linkCounts,
    this.reactions,
    this.currentUserReaction,
    this.polls,
    this.pollsVotes,
    this.actionCode,
    this.actionCodeWho,
    this.actionCodePath,
    this.flairUrl,
    this.flairName,
    this.flairBgColor,
    this.flairColor,
    this.flairGroupId,
    this.primaryGroupName,
    this.mentionedUsers,
    this.acceptedAnswer = false,
    this.canAcceptAnswer = false,
    this.canUnacceptAnswer = false,
    this.deletedAt,
    this.userDeleted = false,
    this.userTitle,
    this.userStatus,
    this.badgesGranted,
  });

  factory Post.fromJson(Map<String, dynamic> json) {
    return Post(
      id: json['id'] as int,
      name: json['name'] as String?,
      username: json['username'] as String? ?? 'Unknown',
      avatarTemplate: json['avatar_template'] as String? ?? '',
      animatedAvatar: json['animated_avatar'] as String?,
      cooked: json['cooked'] as String? ?? '',
      postNumber: json['post_number'] as int? ?? 0,
      postType: json['post_type'] as int? ?? 1,
      updatedAt: TimeUtils.parseUtcTime(json['updated_at'] as String?) ?? DateTime.now(),
      createdAt: TimeUtils.parseUtcTime(json['created_at'] as String?) ?? DateTime.now(),
      likeCount: json['like_count'] as int? ?? 0,
      replyCount: json['reply_count'] as int? ?? 0,
      replyToPostNumber: json['reply_to_post_number'] as int? ?? 0,
      replyToUser: json['reply_to_user'] != null
          ? ReplyToUser.fromJson(json['reply_to_user'] as Map<String, dynamic>)
          : null,
      scoreHidden: json['score_hidden'] as bool? ?? false,
      canEdit: json['can_edit'] as bool? ?? false,
      canDelete: json['can_delete'] as bool? ?? false,
      canRecover: json['can_recover'] as bool? ?? false,
      canWiki: json['can_wiki'] as bool? ?? false,
      bookmarked: json['bookmarked'] as bool? ?? false,
      bookmarkId: json['bookmark_id'] as int?,
      read: json['read'] as bool? ?? false,
      actionsSummary: json['actions_summary'] as List<dynamic>?,
      linkCounts: (json['link_counts'] as List<dynamic>?)
          ?.map((e) => LinkCount.fromJson(e as Map<String, dynamic>))
          .toList(),
      reactions: (json['reactions'] as List<dynamic>?)
          ?.map((e) => PostReaction.fromJson(e as Map<String, dynamic>))
          .toList(),
      currentUserReaction: json['current_user_reaction'] != null
          ? PostReaction.fromJson(json['current_user_reaction'] as Map<String, dynamic>)
          : null,
      polls: (json['polls'] as List<dynamic>?)
          ?.map((e) => Poll.fromJson(e as Map<String, dynamic>))
          .toList(),
      pollsVotes: (json['polls_votes'] as Map<String, dynamic>?)?.map(
        (key, value) => MapEntry(key, (value as List<dynamic>).map((e) => e.toString()).toList()),
      ),
      actionCode: json['action_code'] as String?,
      actionCodeWho: json['action_code_who'] as String?,
      actionCodePath: json['action_code_path'] as String?,
      flairUrl: json['flair_url'] as String?,
      flairName: json['flair_name'] as String?,
      flairBgColor: json['flair_bg_color'] as String?,
      flairColor: json['flair_color'] as String?,
      flairGroupId: json['flair_group_id'] as int?,
      primaryGroupName: json['primary_group_name'] as String?,
      mentionedUsers: (json['mentioned_users'] as List<dynamic>?)
          ?.map((e) => MentionedUser.fromJson(e as Map<String, dynamic>))
          .toList(),
      acceptedAnswer: json['accepted_answer'] as bool? ?? false,
      canAcceptAnswer: json['can_accept_answer'] as bool? ?? false,
      canUnacceptAnswer: json['can_unaccept_answer'] as bool? ?? false,
      deletedAt: json['deleted_at'] != null
          ? TimeUtils.parseUtcTime(json['deleted_at'] as String)
          : null,
      userDeleted: json['user_deleted'] as bool? ?? false,
      userTitle: (json['user_title'] as String?)?.isNotEmpty == true
          ? json['user_title'] as String
          : null,
      userStatus: json['user_status'] != null
          ? UserStatus.fromJson(json['user_status'] as Map<String, dynamic>)
          : null,
      badgesGranted: (json['badges_granted'] as List<dynamic>?)
          ?.map((e) => GrantedBadge.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// 获取头像 URL，优先使用动画头像（GIF）
  String getAvatarUrl({int size = 120}) {
    return UrlHelper.resolveAvatarUrl(
      avatarTemplate: avatarTemplate,
      animatedAvatar: animatedAvatar,
      size: size,
    );
  }

  /// 帖子是否已被删除
  bool get isDeleted => deletedAt != null;

  /// 复制并修改部分字段
  Post copyWith({
    int? id,
    String? name,
    String? username,
    String? avatarTemplate,
    String? animatedAvatar,
    String? cooked,
    int? postNumber,
    int? postType,
    DateTime? updatedAt,
    DateTime? createdAt,
    int? likeCount,
    int? replyCount,
    int? replyToPostNumber,
    ReplyToUser? replyToUser,
    bool? scoreHidden,
    bool? canEdit,
    bool? canDelete,
    bool? canRecover,
    bool? canWiki,
    bool? bookmarked,
    int? bookmarkId,
    bool? read,
    List<dynamic>? actionsSummary,
    List<LinkCount>? linkCounts,
    List<PostReaction>? reactions,
    PostReaction? currentUserReaction,
    List<Poll>? polls,
    Map<String, List<String>>? pollsVotes,
    String? actionCode,
    String? actionCodeWho,
    String? actionCodePath,
    String? flairUrl,
    String? flairName,
    String? flairBgColor,
    String? flairColor,
    int? flairGroupId,
    String? primaryGroupName,
    List<MentionedUser>? mentionedUsers,
    bool? acceptedAnswer,
    bool? canAcceptAnswer,
    bool? canUnacceptAnswer,
    DateTime? deletedAt,
    bool? userDeleted,
    String? userTitle,
    UserStatus? userStatus,
    List<GrantedBadge>? badgesGranted,
    bool clearCurrentUserReaction = false,
  }) {
    return Post(
      id: id ?? this.id,
      name: name ?? this.name,
      username: username ?? this.username,
      avatarTemplate: avatarTemplate ?? this.avatarTemplate,
      animatedAvatar: animatedAvatar ?? this.animatedAvatar,
      cooked: cooked ?? this.cooked,
      postNumber: postNumber ?? this.postNumber,
      postType: postType ?? this.postType,
      updatedAt: updatedAt ?? this.updatedAt,
      createdAt: createdAt ?? this.createdAt,
      likeCount: likeCount ?? this.likeCount,
      replyCount: replyCount ?? this.replyCount,
      replyToPostNumber: replyToPostNumber ?? this.replyToPostNumber,
      replyToUser: replyToUser ?? this.replyToUser,
      scoreHidden: scoreHidden ?? this.scoreHidden,
      canEdit: canEdit ?? this.canEdit,
      canDelete: canDelete ?? this.canDelete,
      canRecover: canRecover ?? this.canRecover,
      canWiki: canWiki ?? this.canWiki,
      bookmarked: bookmarked ?? this.bookmarked,
      bookmarkId: bookmarkId ?? this.bookmarkId,
      read: read ?? this.read,
      actionsSummary: actionsSummary ?? this.actionsSummary,
      linkCounts: linkCounts ?? this.linkCounts,
      reactions: reactions ?? this.reactions,
      currentUserReaction: clearCurrentUserReaction ? null : (currentUserReaction ?? this.currentUserReaction),
      polls: polls ?? this.polls,
      pollsVotes: pollsVotes ?? this.pollsVotes,
      actionCode: actionCode ?? this.actionCode,
      actionCodeWho: actionCodeWho ?? this.actionCodeWho,
      actionCodePath: actionCodePath ?? this.actionCodePath,
      flairUrl: flairUrl ?? this.flairUrl,
      flairName: flairName ?? this.flairName,
      flairBgColor: flairBgColor ?? this.flairBgColor,
      flairColor: flairColor ?? this.flairColor,
      flairGroupId: flairGroupId ?? this.flairGroupId,
      primaryGroupName: primaryGroupName ?? this.primaryGroupName,
      mentionedUsers: mentionedUsers ?? this.mentionedUsers,
      acceptedAnswer: acceptedAnswer ?? this.acceptedAnswer,
      canAcceptAnswer: canAcceptAnswer ?? this.canAcceptAnswer,
      canUnacceptAnswer: canUnacceptAnswer ?? this.canUnacceptAnswer,
      deletedAt: deletedAt ?? this.deletedAt,
      userDeleted: userDeleted ?? this.userDeleted,
      userTitle: userTitle ?? this.userTitle,
      userStatus: userStatus ?? this.userStatus,
      badgesGranted: badgesGranted ?? this.badgesGranted,
    );
  }
}

/// 帖子流信息
class PostStream {
  final List<Post> posts;
  final List<int> stream; // 所有 post_id 的列表

  PostStream({required this.posts, required this.stream});

  factory PostStream.fromJson(Map<String, dynamic> json) {
    return PostStream(
      posts: (json['posts'] as List<dynamic>? ?? [])
          .map((e) => Post.fromJson(e as Map<String, dynamic>))
          .toList(),
      stream: (json['stream'] as List<dynamic>? ?? [])
          .map((e) => e as int)
          .toList(),
    );
  }

  /// 从顶层 JSON 解析 users/badges 数据，注入到 posts 中
  /// [topLevelJson] 是包含 users、badges 字段的顶层响应 JSON
  static void injectBadges(List<Post> posts, Map<String, dynamic> topLevelJson, List<dynamic>? rawPosts) {
    // badge 数据在 topLevelJson['user_badges'] 下，包含 users 和 badges 两个子字典
    final userBadgesContainer = topLevelJson['user_badges'] as Map<String, dynamic>?;
    if (userBadgesContainer == null) return;

    final badgesMap = <int, GrantedBadge>{};
    final userBadgeIdsMap = <int, List<int>>{};

    // 解析 badges（支持 Map 和 List 两种格式）
    final badgesRaw = userBadgesContainer['badges'];
    if (badgesRaw is Map<String, dynamic>) {
      for (final entry in badgesRaw.entries) {
        final badgeId = int.tryParse(entry.key);
        if (badgeId != null && entry.value is Map<String, dynamic>) {
          badgesMap[badgeId] = GrantedBadge.fromJson(entry.value as Map<String, dynamic>);
        }
      }
    } else if (badgesRaw is List) {
      for (final item in badgesRaw) {
        if (item is Map<String, dynamic>) {
          final badgeId = item['id'] as int?;
          if (badgeId != null) {
            badgesMap[badgeId] = GrantedBadge.fromJson(item);
          }
        }
      }
    }

    // 解析 users（支持 Map 和 List 两种格式）
    final usersRaw = userBadgesContainer['users'];
    if (usersRaw is Map<String, dynamic>) {
      for (final entry in usersRaw.entries) {
        final userId = int.tryParse(entry.key);
        if (userId != null && entry.value is Map<String, dynamic>) {
          final badgeIds = (entry.value['badge_ids'] as List<dynamic>?)
              ?.map((e) => e as int)
              .toList();
          if (badgeIds != null && badgeIds.isNotEmpty) {
            userBadgeIdsMap[userId] = badgeIds;
          }
        }
      }
    } else if (usersRaw is List) {
      for (final item in usersRaw) {
        if (item is Map<String, dynamic>) {
          final userId = item['id'] as int?;
          final badgeIds = (item['badge_ids'] as List<dynamic>?)
              ?.map((e) => e as int)
              .toList();
          if (userId != null && badgeIds != null && badgeIds.isNotEmpty) {
            userBadgeIdsMap[userId] = badgeIds;
          }
        }
      }
    }

    if (badgesMap.isEmpty || userBadgeIdsMap.isEmpty) return;

    // 从原始 post JSON 中获取 user_id 映射
    final postUserIdMap = <int, int>{};
    if (rawPosts != null) {
      for (final rawPost in rawPosts) {
        if (rawPost is Map<String, dynamic>) {
          final postId = rawPost['id'] as int?;
          final userId = rawPost['user_id'] as int?;
          if (postId != null && userId != null) {
            postUserIdMap[postId] = userId;
          }
        }
      }
    }

    for (int i = 0; i < posts.length; i++) {
      final post = posts[i];
      final userId = postUserIdMap[post.id];
      if (userId != null) {
        final badgeIds = userBadgeIdsMap[userId];
        if (badgeIds != null) {
          final badges = badgeIds
              .map((id) => badgesMap[id])
              .whereType<GrantedBadge>()
              .toList();
          if (badges.isNotEmpty) {
            posts[i] = post.copyWith(badgesGranted: badges);
          }
        }
      }
    }
  }
}
