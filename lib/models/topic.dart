// 帖子数据模型
import 'package:flutter/foundation.dart' show listEquals;
import '../l10n/s.dart';
import '../utils/time_utils.dart';
import '../utils/url_helper.dart';
import 'user.dart';

/// 标签模型
class Tag {
  final int? id;
  final String name;
  final String? slug;

  const Tag({
    this.id,
    required this.name,
    this.slug,
  });

  factory Tag.fromJson(dynamic json) {
    // 兼容新旧格式
    if (json is String) {
      // 旧格式：直接是字符串
      return Tag(name: json);
    } else if (json is Map<String, dynamic>) {
      // 新格式：对象格式
      return Tag(
        id: json['id'] as int?,
        name: json['name'] as String? ?? '',
        slug: json['slug'] as String?,
      );
    } else {
      // 降级处理
      return Tag(name: json.toString());
    }
  }

  @override
  String toString() => name;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Tag && other.name == name;
  }

  @override
  int get hashCode => name.hashCode;
}

/// 话题订阅级别
enum TopicNotificationLevel {
  muted(0),
  regular(1),
  tracking(2),
  watching(3);

  const TopicNotificationLevel(this.value);
  final int value;

  String get label {
    switch (this) {
      case TopicNotificationLevel.muted: return S.current.topic_levelMuted;
      case TopicNotificationLevel.regular: return S.current.topic_levelRegular;
      case TopicNotificationLevel.tracking: return S.current.topic_levelTracking;
      case TopicNotificationLevel.watching: return S.current.topic_levelWatching;
    }
  }

  String get description {
    switch (this) {
      case TopicNotificationLevel.muted: return S.current.topic_levelMutedDesc;
      case TopicNotificationLevel.regular: return S.current.topic_levelRegularDesc;
      case TopicNotificationLevel.tracking: return S.current.topic_levelTrackingDesc;
      case TopicNotificationLevel.watching: return S.current.topic_levelWatchingDesc;
    }
  }

  static TopicNotificationLevel fromValue(int? value) {
    return TopicNotificationLevel.values.firstWhere(
      (e) => e.value == value,
      orElse: () => TopicNotificationLevel.regular,
    );
  }
}

/// 投票选项
class PollOption {
  final String id;
  final String html;
  final int votes;

  PollOption({required this.id, required this.html, required this.votes});

  factory PollOption.fromJson(Map<String, dynamic> json) {
    return PollOption(
      id: json['id'] as String? ?? '',
      html: json['html'] as String? ?? '',
      votes: json['votes'] as int? ?? 0,
    );
  }
}

/// 投票
class Poll {
  final int id;
  final String name;
  final String type;
  final String status;
  final String results;
  final List<PollOption> options;
  final int voters;

  Poll({
    required this.id,
    required this.name,
    required this.type,
    required this.status,
    required this.results,
    required this.options,
    required this.voters,
  });

  factory Poll.fromJson(Map<String, dynamic> json) {
    return Poll(
      id: json['id'] as int? ?? 0,
      name: json['name'] as String? ?? '',
      type: json['type'] as String? ?? 'regular',
      status: json['status'] as String? ?? 'open',
      results: json['results'] as String? ?? 'always',
      options: (json['options'] as List<dynamic>?)
          ?.map((e) => PollOption.fromJson(e as Map<String, dynamic>))
          .toList() ?? [],
      voters: json['voters'] as int? ?? 0,
    );
  }
}

/// 话题相关的用户信息
class TopicUser {
  final int id;
  final String username;
  final String avatarTemplate;

  TopicUser({
    required this.id,
    required this.username,
    required this.avatarTemplate,
  });

  factory TopicUser.fromJson(Map<String, dynamic> json) {
    return TopicUser(
      id: json['id'] as int,
      username: json['username'] as String? ?? '',
      avatarTemplate: json['avatar_template'] as String? ?? '',
    );
  }

  String getAvatarUrl({int size = 40}) {
    final template = avatarTemplate.replaceAll('{size}', '$size');
    return UrlHelper.resolveUrlWithCdn(template);
  }
}

/// 话题海报（参与者）信息
class TopicPoster {
  final int userId;
  final String description;
  final String extras;
  final TopicUser? user;

  TopicPoster({
    required this.userId,
    required this.description,
    required this.extras,
    this.user,
  });

  factory TopicPoster.fromJson(Map<String, dynamic> json, Map<int, TopicUser> userMap) {
    final userId = json['user_id'] as int;
    return TopicPoster(
      userId: userId,
      description: json['description'] as String? ?? '',
      extras: json['extras'] as String? ?? '',
      user: userMap[userId],
    );
  }
}

class Topic {
  final int id;
  final String title;
  final String slug;
  final int postsCount;
  final int replyCount;
  final int views;
  final int likeCount;
  final String? excerpt;
  final DateTime? createdAt;
  final DateTime? lastPostedAt;
  final String? lastPosterUsername;
  final String categoryId;
  final bool pinned;
  final bool visible;
  final bool closed;
  final bool archived;
  final List<Tag> tags;
  final List<TopicPoster> posters;

  // 已读状态相关
  final bool unseen;           // 新话题（从未见过）
  final int unread;            // 未读帖子数
  final int newPosts;          // 新帖子数
  final int? lastReadPostNumber;   // 最后阅读的帖子编号
  final int highestPostNumber;     // 最高帖子编号

  // 书签相关（从书签列表 API 获取）
  final int? bookmarkedPostNumber;  // 帖子书签对应的帖子编号（bookmarkable_type 为 Post 时有值）
  final int? bookmarkId;            // 书签 ID（用于编辑/删除）
  final String? bookmarkName;       // 书签备注名称
  final DateTime? bookmarkReminderAt; // 书签提醒时间
  final String? bookmarkableType;   // 书签类型（Post/Topic）

  // 已解决问题相关
  final bool hasAcceptedAnswer;    // 话题是否有被接受的答案
  final bool canHaveAnswer;        // 话题是否可以有解决方案（用于显示未解决状态）

  Topic({
    required this.id,
    required this.title,
    required this.slug,
    required this.postsCount,
    required this.replyCount,
    required this.views,
    required this.likeCount,
    this.excerpt,
    this.createdAt,
    this.lastPostedAt,
    this.lastPosterUsername,
    required this.categoryId,
    this.pinned = false,
    this.visible = true,
    this.closed = false,
    this.archived = false,
    this.tags = const <Tag>[],
    this.posters = const [],
    this.unseen = false,
    this.unread = 0,
    this.newPosts = 0,
    this.lastReadPostNumber,
    this.highestPostNumber = 0,
    this.bookmarkedPostNumber,
    this.bookmarkId,
    this.bookmarkName,
    this.bookmarkReminderAt,
    this.bookmarkableType,
    this.hasAcceptedAnswer = false,
    this.canHaveAnswer = false,
  });

  factory Topic.fromJson(Map<String, dynamic> json, {Map<int, TopicUser>? userMap}) {
    return Topic(
      id: json['id'] as int,
      title: json['title'] as String? ?? '',
      slug: json['slug'] as String? ?? '',
      postsCount: json['posts_count'] as int? ?? 0,
      replyCount: json['reply_count'] as int? ?? 0,
      views: json['views'] as int? ?? 0,
      likeCount: json['like_count'] as int? ?? 0,
      excerpt: json['excerpt'] as String?,
      createdAt: TimeUtils.parseUtcTime(json['created_at'] as String?),
      lastPostedAt: TimeUtils.parseUtcTime(json['last_posted_at'] as String?),
      lastPosterUsername: json['last_poster_username'] as String?,
      categoryId: (json['category_id'] ?? 0).toString(),
      pinned: json['pinned'] as bool? ?? false,
      visible: json['visible'] as bool? ?? true,
      closed: json['closed'] as bool? ?? false,
      archived: json['archived'] as bool? ?? false,
      tags: (json['tags'] as List<dynamic>?)?.map((e) => Tag.fromJson(e)).toList() ?? const <Tag>[],
      posters: (json['posters'] as List<dynamic>?)
          ?.map((e) => TopicPoster.fromJson(e as Map<String, dynamic>, userMap ?? {}))
          .toList() ?? const [],
      unseen: json['unseen'] as bool? ?? false,
      unread: json['unread_posts'] as int? ?? 0,
      newPosts: json['new_posts'] as int? ?? 0,
      lastReadPostNumber: json['last_read_post_number'] as int?,
      highestPostNumber: json['highest_post_number'] as int? ?? 0,
      bookmarkedPostNumber: json['_bookmarked_post_number'] as int?,
      bookmarkId: json['_bookmark_id'] as int?,
      bookmarkName: json['_bookmark_name'] as String?,
      bookmarkReminderAt: TimeUtils.parseUtcTime(json['_bookmark_reminder_at'] as String?),
      bookmarkableType: json['_bookmarkable_type'] as String?,
      hasAcceptedAnswer: json['has_accepted_answer'] as bool? ?? false,
      canHaveAnswer: json['can_have_answer'] as bool? ?? false,
    );
  }
}

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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PostReaction && id == other.id && type == other.type && count == other.count;

  @override
  int get hashCode => Object.hash(id, type, count);
}

/// 回应人信息
class ReactionUser {
  final String username;
  final String? name;
  final String avatarTemplate;

  const ReactionUser({
    required this.username,
    this.name,
    required this.avatarTemplate,
  });

  factory ReactionUser.fromJson(Map<String, dynamic> json) {
    return ReactionUser(
      username: json['username'] as String? ?? '',
      name: json['name'] as String?,
      avatarTemplate: json['avatar_template'] as String? ?? '',
    );
  }

  String getAvatarUrl({int size = 96}) {
    final template = avatarTemplate.replaceAll('{size}', '$size');
    return UrlHelper.resolveUrlWithCdn(template);
  }
}

/// 按回应类型分组的用户列表
class ReactionUsersGroup {
  final String id; // emoji 名称
  final int count;
  final List<ReactionUser> users;

  const ReactionUsersGroup({
    required this.id,
    required this.count,
    required this.users,
  });

  factory ReactionUsersGroup.fromJson(Map<String, dynamic> json) {
    return ReactionUsersGroup(
      id: json['id'] as String? ?? '',
      count: json['count'] as int? ?? 0,
      users: (json['users'] as List<dynamic>?)
              ?.map((e) => ReactionUser.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

/// 帖子（回复）数据模型
/// 帖子提示信息（新用户首发帖、回归用户、自定义通知）
class PostNotice {
  final String type; // "new_user" | "returning_user" | "custom"
  final String? lastPostedAt; // returning_user 类型的上次发帖时间
  final String? cooked; // custom 类型的 HTML 内容

  const PostNotice({required this.type, this.lastPostedAt, this.cooked});

  factory PostNotice.fromJson(Map<String, dynamic> json) {
    return PostNotice(
      type: json['type'] as String,
      lastPostedAt: json['last_posted_at'] as String?,
      cooked: json['cooked'] as String?,
    );
  }
}

class Post {
  final int id;
  final String? name;
  final String username;
  final String avatarTemplate;
  final String? animatedAvatar;
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
  final String? bookmarkName; // 书签名称
  final DateTime? bookmarkReminderAt; // 书签提醒时间
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

  // 用户 ID（用于打赏等功能）
  final int? userId;

  // 用户身份标识
  final bool moderator;          // 用户是否为版主
  final bool admin;              // 用户是否为管理员
  final bool groupModerator;     // 用户是否为分类群组版主

  // 隐藏状态（举报隐藏）
  final bool hidden;             // 帖子是否被隐藏
  final bool cookedHidden;       // cooked 内容是否被替换为隐藏提示
  final bool canSeeHiddenPost;   // 当前用户是否可以查看隐藏内容

  // 帖子提示信息
  final PostNotice? notice;

  // Boost（微反应气泡）
  final List<Boost>? boosts;
  final bool canBoost;

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
    this.bookmarkName,
    this.bookmarkReminderAt,
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
    this.userId,
    this.moderator = false,
    this.admin = false,
    this.groupModerator = false,
    this.hidden = false,
    this.cookedHidden = false,
    this.canSeeHiddenPost = false,
    this.notice,
    this.boosts,
    this.canBoost = false,
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
      updatedAt: TimeUtils.parseUtcTime(json['updated_at'] as String) ?? DateTime.now(),
      createdAt: TimeUtils.parseUtcTime(json['created_at'] as String) ?? DateTime.now(),
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
      bookmarkName: json['_bookmark_name'] as String?,
      bookmarkReminderAt: json['_bookmark_reminder_at'] != null
          ? TimeUtils.parseUtcTime(json['_bookmark_reminder_at'] as String?)
          : null,
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
      userId: json['user_id'] as int?,
      moderator: json['moderator'] as bool? ?? false,
      admin: json['admin'] as bool? ?? false,
      groupModerator: json['group_moderator'] as bool? ?? false,
      hidden: json['hidden'] as bool? ?? false,
      cookedHidden: json['cooked_hidden'] as bool? ?? false,
      canSeeHiddenPost: json['can_see_hidden_post'] as bool? ?? false,
      notice: json['notice'] != null
          ? PostNotice.fromJson(json['notice'] as Map<String, dynamic>)
          : null,
      boosts: (json['boosts'] as List<dynamic>?)
          ?.whereType<Map<String, dynamic>>()
          .map((e) => Boost.fromJson(e))
          .toList(),
      canBoost: json['can_boost'] as bool? ?? false,
    );
  }

  /// 获取头像 URL，优先使用动画头像（GIF）
  String getAvatarUrl({int size = 120}) {
    if (animatedAvatar != null && animatedAvatar!.isNotEmpty) {
      return UrlHelper.resolveUrlWithCdn(animatedAvatar!);
    }
    final template = avatarTemplate.replaceAll('{size}', '$size');
    return UrlHelper.resolveUrlWithCdn(template);
  }

  /// 帖子是否已被删除
  bool get isDeleted => deletedAt != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Post &&
          id == other.id &&
          cooked == other.cooked &&
          likeCount == other.likeCount &&
          replyCount == other.replyCount &&
          bookmarked == other.bookmarked &&
          bookmarkId == other.bookmarkId &&
          bookmarkName == other.bookmarkName &&
          bookmarkReminderAt == other.bookmarkReminderAt &&
          acceptedAnswer == other.acceptedAnswer &&
          canAcceptAnswer == other.canAcceptAnswer &&
          canUnacceptAnswer == other.canUnacceptAnswer &&
          deletedAt == other.deletedAt &&
          canEdit == other.canEdit &&
          canDelete == other.canDelete &&
          canRecover == other.canRecover &&
          read == other.read &&
          hidden == other.hidden &&
          cookedHidden == other.cookedHidden &&
          listEquals(reactions, other.reactions) &&
          currentUserReaction == other.currentUserReaction &&
          listEquals(boosts, other.boosts) &&
          canBoost == other.canBoost;

  @override
  int get hashCode => Object.hash(id, cooked, likeCount, bookmarked, acceptedAnswer, hidden, canBoost);

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
    String? bookmarkName,
    DateTime? bookmarkReminderAt,
    bool clearBookmarkName = false,
    bool clearBookmarkReminderAt = false,
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
    int? userId,
    bool? moderator,
    bool? admin,
    bool? groupModerator,
    bool? hidden,
    bool? cookedHidden,
    bool? canSeeHiddenPost,
    PostNotice? notice,
    List<Boost>? boosts,
    bool? canBoost,
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
      bookmarkName: clearBookmarkName ? null : (bookmarkName ?? this.bookmarkName),
      bookmarkReminderAt: clearBookmarkReminderAt ? null : (bookmarkReminderAt ?? this.bookmarkReminderAt),
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
      userId: userId ?? this.userId,
      moderator: moderator ?? this.moderator,
      admin: admin ?? this.admin,
      groupModerator: groupModerator ?? this.groupModerator,
      hidden: hidden ?? this.hidden,
      cookedHidden: cookedHidden ?? this.cookedHidden,
      canSeeHiddenPost: canSeeHiddenPost ?? this.canSeeHiddenPost,
      notice: notice ?? this.notice,
      boosts: boosts ?? this.boosts,
      canBoost: canBoost ?? this.canBoost,
    );
  }
}

/// Boost（微反应气泡）
class Boost {
  final int id;
  final String cooked; // 渲染后的 HTML
  final BoostUser user;
  final bool canDelete;
  final bool canFlag;
  final int? userFlagStatus;
  final List<String>? availableFlags;

  const Boost({
    required this.id,
    required this.cooked,
    required this.user,
    this.canDelete = false,
    this.canFlag = false,
    this.userFlagStatus,
    this.availableFlags,
  });

  factory Boost.fromJson(Map<String, dynamic> json) {
    return Boost(
      id: json['id'] as int,
      cooked: json['cooked'] as String? ?? '',
      user: json['user'] != null
          ? BoostUser.fromJson(json['user'] as Map<String, dynamic>)
          : const BoostUser(id: 0, username: '', avatarTemplate: ''),
      canDelete: json['can_delete'] as bool? ?? false,
      canFlag: json['can_flag'] as bool? ?? false,
      userFlagStatus: json['user_flag_status'] as int?,
      availableFlags: (json['available_flags'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList(),
    );
  }

  Boost copyWith({
    bool? canDelete,
    bool? canFlag,
    int? userFlagStatus,
    List<String>? availableFlags,
  }) {
    return Boost(
      id: id,
      cooked: cooked,
      user: user,
      canDelete: canDelete ?? this.canDelete,
      canFlag: canFlag ?? this.canFlag,
      userFlagStatus: userFlagStatus ?? this.userFlagStatus,
      availableFlags: availableFlags ?? this.availableFlags,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Boost && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Boost 用户信息
class BoostUser {
  final int id;
  final String username;
  final String? name;
  final String avatarTemplate;

  const BoostUser({
    required this.id,
    required this.username,
    this.name,
    required this.avatarTemplate,
  });

  factory BoostUser.fromJson(Map<String, dynamic> json) {
    return BoostUser(
      id: json['id'] as int,
      username: json['username'] as String? ?? '',
      name: json['name'] as String?,
      avatarTemplate: json['avatar_template'] as String? ?? '',
    );
  }

  /// 获取头像 URL
  String getAvatarUrl({int size = 48}) {
    final template = avatarTemplate.replaceAll('{size}', '$size');
    return UrlHelper.resolveUrlWithCdn(template);
  }
}

/// 帖子流中的 gaps 数据（拉黑用户的帖子位置）
class PostStreamGaps {
  final Map<int, List<int>> before; // {postId: [gapPostIds]}
  final Map<int, List<int>> after;  // {postId: [gapPostIds]}

  const PostStreamGaps({this.before = const {}, this.after = const {}});

  factory PostStreamGaps.fromJson(Map<String, dynamic> json) {
    Map<int, List<int>> parseGapMap(Map<String, dynamic>? raw) {
      if (raw == null) return const {};
      final result = <int, List<int>>{};
      for (final entry in raw.entries) {
        final postId = int.tryParse(entry.key);
        if (postId != null && entry.value is List) {
          result[postId] = (entry.value as List).cast<int>();
        }
      }
      return result;
    }
    return PostStreamGaps(
      before: parseGapMap(json['before'] as Map<String, dynamic>?),
      after: parseGapMap(json['after'] as Map<String, dynamic>?),
    );
  }

  bool get isEmpty => before.isEmpty && after.isEmpty;
}

/// 帖子流信息
class PostStream {
  final List<Post> posts;
  final List<int> stream; // 所有 post_id 的列表
  final PostStreamGaps? gaps; // 拉黑用户帖子的 gaps 数据

  PostStream({required this.posts, required this.stream, this.gaps});

  factory PostStream.fromJson(Map<String, dynamic> json) {
    final gapsJson = json['gaps'] as Map<String, dynamic>?;
    return PostStream(
      posts: (json['posts'] as List<dynamic>? ?? [])
          .map((e) => Post.fromJson(e as Map<String, dynamic>))
          .toList(),
      stream: (json['stream'] as List<dynamic>? ?? [])
          .map((e) => e as int)
          .toList(),
      gaps: gapsJson != null ? PostStreamGaps.fromJson(gapsJson) : null,
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

/// 话题详情模型
class TopicDetail {
  final int id;
  final String title;
  final String slug;
  final int postsCount;
  final PostStream postStream;
  final int categoryId;
  final bool closed;
  final bool archived;
  final List<Tag>? tags;
  final int views;
  final int likeCount;
  final DateTime? createdAt;
  final bool visible;
  final int? lastReadPostNumber; // 最后阅读的帖子编号（从 API 获取）

  // 投票相关字段
  final bool canVote;        // 是否可以投票
  final int voteCount;       // 投票数
  final bool userVoted;      // 当前用户是否已投票

  // 创建者信息
  final TopicUser? createdBy;

  // AI 摘要相关字段
  final bool summarizable;        // 话题是否可摘要（后端控制）
  final bool hasCachedSummary;    // 是否有缓存的摘要

  // 热门回复相关字段
  final bool hasSummary;          // 是否有足够的帖子/点赞来支持热门回复功能

  // 订阅级别
  final TopicNotificationLevel notificationLevel;

  // 话题类型
  final String archetype;  // 'regular' 或 'private_message'

  // 话题权限（来自 details）
  final bool canEdit;  // 是否可以编辑话题元数据（标题、分类、标签）

  // 话题书签相关
  final bool bookmarked;                // 话题是否已被书签（Topic 级别）
  final int? bookmarkId;                // 话题书签 ID（用于删除书签）
  final String? bookmarkName;           // 书签名称
  final DateTime? bookmarkReminderAt;   // 书签提醒时间

  // 已解决问题相关
  final bool hasAcceptedAnswer;         // 话题是否有被接受的答案
  final int? acceptedAnswerPostNumber;  // 被接受答案的帖子编号

  /// 是否为私信
  bool get isPrivateMessage => archetype == 'private_message';

  TopicDetail({
    required this.id,
    required this.title,
    required this.slug,
    required this.postsCount,
    required this.postStream,
    required this.categoryId,
    required this.closed,
    required this.archived,
    this.tags,
    this.views = 0,
    this.likeCount = 0,
    this.createdAt,
    this.visible = true,
    this.lastReadPostNumber,
    this.canVote = false,
    this.voteCount = 0,
    this.userVoted = false,
    this.createdBy,
    this.summarizable = false,
    this.hasCachedSummary = false,
    this.hasSummary = false,
    this.notificationLevel = TopicNotificationLevel.regular,
    this.archetype = 'regular',
    this.canEdit = false,
    this.bookmarked = false,
    this.bookmarkId,
    this.bookmarkName,
    this.bookmarkReminderAt,
    this.hasAcceptedAnswer = false,
    this.acceptedAnswerPostNumber,
  });

  factory TopicDetail.fromJson(Map<String, dynamic> json) {
    var postStream = PostStream.fromJson(json['post_stream'] as Map<String, dynamic>);

    // 注入 topic 级别的 badges 数据到每个 post
    final rawPosts = (json['post_stream'] as Map<String, dynamic>)['posts'] as List<dynamic>?;
    PostStream.injectBadges(postStream.posts, json, rawPosts);

    // 解析 accepted_answer：topic 级别返回的是一个对象 {post_number, username, ...}
    final acceptedAnswerData = json['accepted_answer'];
    int? acceptedAnswerPostNumber;
    bool hasAcceptedAnswer = false;

    if (acceptedAnswerData is Map<String, dynamic>) {
      // topic 级别的 accepted_answer 是一个对象
      acceptedAnswerPostNumber = acceptedAnswerData['post_number'] as int?;
      hasAcceptedAnswer = true;
    }

    // 备用方案：如果 topic 级别没有，从帖子的 topic_accepted_answer 或 accepted_answer 字段推断
    if (!hasAcceptedAnswer) {
      hasAcceptedAnswer = json['has_accepted_answer'] as bool? ?? false;
    }
    if (hasAcceptedAnswer && acceptedAnswerPostNumber == null) {
      final acceptedPost = postStream.posts.where((p) => p.acceptedAnswer).firstOrNull;
      acceptedAnswerPostNumber = acceptedPost?.postNumber;
    }

    // 解析书签数组：分别提取话题书签和帖子书签
    bool topicBookmarked = false;
    int? topicBookmarkId;
    String? topicBookmarkName;
    DateTime? topicBookmarkReminderAt;
    // 帖子书签映射：bookmarkable_id -> bookmark data
    final postBookmarks = <int, Map<String, dynamic>>{};
    final bookmarksList = json['bookmarks'] as List<dynamic>?;
    if (bookmarksList != null) {
      for (final b in bookmarksList) {
        if (b is Map<String, dynamic>) {
          if (b['bookmarkable_type'] == 'Topic') {
            topicBookmarked = true;
            topicBookmarkId = b['id'] as int?;
            final name = b['name'] as String?;
            topicBookmarkName = (name != null && name.isNotEmpty) ? name : null;
            topicBookmarkReminderAt = TimeUtils.parseUtcTime(b['reminder_at'] as String?);
          } else if (b['bookmarkable_type'] == 'Post') {
            final bookmarkableId = b['bookmarkable_id'] as int?;
            if (bookmarkableId != null) {
              postBookmarks[bookmarkableId] = b;
            }
          }
        }
      }
    }

    // 注入帖子书签数据到对应的 Post
    if (postBookmarks.isNotEmpty) {
      final updatedPosts = postStream.posts.map((post) {
        final bm = postBookmarks[post.id];
        if (bm != null) {
          final bmName = bm['name'] as String?;
          return post.copyWith(
            bookmarked: true,
            bookmarkId: bm['id'] as int?,
            bookmarkName: (bmName != null && bmName.isNotEmpty) ? bmName : null,
            bookmarkReminderAt: TimeUtils.parseUtcTime(bm['reminder_at'] as String?),
          );
        }
        return post;
      }).toList();
      postStream = PostStream(posts: updatedPosts, stream: postStream.stream, gaps: postStream.gaps);
    }

    return TopicDetail(
      id: json['id'] as int,
      title: json['title'] as String? ?? '',
      slug: json['slug'] as String? ?? '',
      postsCount: json['posts_count'] as int? ?? 0,
      postStream: postStream,
      categoryId: json['category_id'] as int? ?? 0,
      closed: json['closed'] as bool? ?? false,
      archived: json['archived'] as bool? ?? false,
      tags: (json['tags'] as List<dynamic>?)?.map((e) => Tag.fromJson(e)).toList(),
      views: json['views'] as int? ?? 0,
      likeCount: json['like_count'] as int? ?? 0,
      createdAt: TimeUtils.parseUtcTime(json['created_at'] as String?),
      visible: json['visible'] as bool? ?? true,
      lastReadPostNumber: json['last_read_post_number'] as int?,
      canVote: json['can_vote'] as bool? ?? false,
      voteCount: json['vote_count'] as int? ?? 0,
      userVoted: json['user_voted'] as bool? ?? false,
      createdBy: (json['details'] as Map<String, dynamic>?)?['created_by'] != null
          ? TopicUser.fromJson((json['details']!['created_by'] as Map<String, dynamic>))
          : null,
      summarizable: json['summarizable'] as bool? ?? false,
      hasCachedSummary: json['has_cached_summary'] as bool? ?? false,
      hasSummary: json['has_summary'] as bool? ?? false,
      archetype: json['archetype'] as String? ?? 'regular',
      notificationLevel: TopicNotificationLevel.fromValue(
        (json['details'] as Map<String, dynamic>?)?['notification_level'] as int?,
      ),
      canEdit: (json['details'] as Map<String, dynamic>?)?['can_edit'] as bool? ?? false,
      bookmarked: topicBookmarked,
      bookmarkId: topicBookmarkId,
      bookmarkName: topicBookmarkName,
      bookmarkReminderAt: topicBookmarkReminderAt,
      hasAcceptedAnswer: hasAcceptedAnswer,
      acceptedAnswerPostNumber: acceptedAnswerPostNumber,
    );
  }

  /// 创建修改后的副本
  TopicDetail copyWith({
    int? id,
    String? title,
    String? slug,
    int? postsCount,
    PostStream? postStream,
    int? categoryId,
    bool? closed,
    bool? archived,
    List<Tag>? tags,
    int? views,
    int? likeCount,
    DateTime? createdAt,
    bool? visible,
    int? lastReadPostNumber,
    bool? canVote,
    int? voteCount,
    bool? userVoted,
    TopicUser? createdBy,
    bool? summarizable,
    bool? hasCachedSummary,
    bool? hasSummary,
    TopicNotificationLevel? notificationLevel,
    String? archetype,
    bool? canEdit,
    bool? bookmarked,
    int? bookmarkId,
    bool clearBookmarkId = false,
    String? bookmarkName,
    DateTime? bookmarkReminderAt,
    bool clearBookmarkName = false,
    bool clearBookmarkReminderAt = false,
    bool? hasAcceptedAnswer,
    int? acceptedAnswerPostNumber,
  }) {
    return TopicDetail(
      id: id ?? this.id,
      title: title ?? this.title,
      slug: slug ?? this.slug,
      postsCount: postsCount ?? this.postsCount,
      postStream: postStream ?? this.postStream,
      categoryId: categoryId ?? this.categoryId,
      closed: closed ?? this.closed,
      archived: archived ?? this.archived,
      tags: tags ?? this.tags,
      views: views ?? this.views,
      likeCount: likeCount ?? this.likeCount,
      createdAt: createdAt ?? this.createdAt,
      visible: visible ?? this.visible,
      lastReadPostNumber: lastReadPostNumber ?? this.lastReadPostNumber,
      canVote: canVote ?? this.canVote,
      voteCount: voteCount ?? this.voteCount,
      userVoted: userVoted ?? this.userVoted,
      createdBy: createdBy ?? this.createdBy,
      summarizable: summarizable ?? this.summarizable,
      hasCachedSummary: hasCachedSummary ?? this.hasCachedSummary,
      hasSummary: hasSummary ?? this.hasSummary,
      notificationLevel: notificationLevel ?? this.notificationLevel,
      archetype: archetype ?? this.archetype,
      canEdit: canEdit ?? this.canEdit,
      bookmarked: bookmarked ?? this.bookmarked,
      bookmarkId: clearBookmarkId ? null : (bookmarkId ?? this.bookmarkId),
      bookmarkName: clearBookmarkName ? null : (bookmarkName ?? this.bookmarkName),
      bookmarkReminderAt: clearBookmarkReminderAt ? null : (bookmarkReminderAt ?? this.bookmarkReminderAt),
      hasAcceptedAnswer: hasAcceptedAnswer ?? this.hasAcceptedAnswer,
      acceptedAnswerPostNumber: acceptedAnswerPostNumber ?? this.acceptedAnswerPostNumber,
    );
  }
}

/// 话题 AI 摘要
class TopicSummary {
  final String summarizedText;
  final String? algorithm;
  final bool outdated;
  final bool canRegenerate;
  final int newPostsSinceSummary;
  final DateTime? updatedAt;

  TopicSummary({
    required this.summarizedText,
    this.algorithm,
    required this.outdated,
    required this.canRegenerate,
    required this.newPostsSinceSummary,
    this.updatedAt,
  });

  factory TopicSummary.fromJson(Map<String, dynamic> json) {
    return TopicSummary(
      summarizedText: json['summarized_text'] as String? ?? '',
      algorithm: json['algorithm'] as String?,
      outdated: json['outdated'] as bool? ?? false,
      canRegenerate: json['can_regenerate'] as bool? ?? false,
      newPostsSinceSummary: json['new_posts_since_summary'] as int? ?? 0,
      updatedAt: TimeUtils.parseUtcTime(json['updated_at'] as String?),
    );
  }
}

/// 帖子列表响应
class TopicListResponse {
  final List<Topic> topics;
  final String? moreTopicsUrl;

  TopicListResponse({
    required this.topics,
    this.moreTopicsUrl,
  });

  factory TopicListResponse.fromJson(Map<String, dynamic> json) {
    // Parse users map
    final usersJson = json['users'] as List<dynamic>? ?? [];
    final userMap = {
      for (var u in usersJson)
        (u['id'] as int): TopicUser.fromJson(u as Map<String, dynamic>)
    };

    final topicList = json['topic_list'] as Map<String, dynamic>?;
    List<dynamic> topicsJson = [];
    String? moreTopicsUrl;

    if (topicList != null) {
      topicsJson = topicList['topics'] as List<dynamic>? ?? [];
      moreTopicsUrl = topicList['more_topics_url'] as String?;
    } else if (json.containsKey('user_bookmark_list')) {
      // 处理 /u/{username}/bookmarks.json 格式
      final userBookmarkList = json['user_bookmark_list'] as Map<String, dynamic>?;
      if (userBookmarkList != null) {
        final bookmarks = userBookmarkList['bookmarks'] as List<dynamic>? ?? [];
        moreTopicsUrl = userBookmarkList['more_bookmarks_url'] as String?;
        topicsJson = bookmarks.map((b) {
          final map = Map<String, dynamic>.from(b as Map);

          // 提取书签元数据（必须在 id 被覆盖前取原始书签 ID）
          map['_bookmark_id'] = map['id'];

          // 书签对象中的 id 是书签 ID，topic_id 才是主题 ID
          if (map.containsKey('topic_id')) {
            map['id'] = map['topic_id'];
          }
          final bmName = map['name'] as String?;
          if (bmName != null && bmName.isNotEmpty) {
            map['_bookmark_name'] = bmName;
          }
          if (map['reminder_at'] != null) {
            map['_bookmark_reminder_at'] = map['reminder_at'];
          }
          if (map['bookmarkable_type'] != null) {
            map['_bookmarkable_type'] = map['bookmarkable_type'];
          }

          // 帖子书签：保留 linked_post_number 供跳转使用
          if (map['bookmarkable_type'] == 'Post') {
            final linkedPostNumber = map['linked_post_number'] as int?;
            if (linkedPostNumber != null) {
              map['_bookmarked_post_number'] = linkedPostNumber;
            }
          }

          // 映射关键字段以适配 TopicCard 显示
          // 1. 使用 highest_post_number 作为 posts_count
          if (map.containsKey('highest_post_number')) {
            map['posts_count'] = map['highest_post_number'];
            map['reply_count'] = (map['highest_post_number'] as int) - 1;
          }

          // 2. 使用 bumped_at 作为 last_posted_at
          if (map.containsKey('bumped_at') && !map.containsKey('last_posted_at')) {
            map['last_posted_at'] = map['bumped_at'];
          }

          // 3. 将 user 转换为 posters 数组格式（用于头像叠放）
          if (map.containsKey('user') && map['user'] != null) {
            final user = map['user'] as Map<String, dynamic>;
            final userId = user['id'] as int;

            // 添加 user 到 userMap（如果不存在）
            if (!userMap.containsKey(userId)) {
              userMap[userId] = TopicUser.fromJson(user);
            }

            // 创建 posters 数组
            map['posters'] = [
              {
                'user_id': userId,
                'description': 'Original Poster',
                'extras': 'latest',
              }
            ];

            // 设置 last_poster_username
            if (user.containsKey('username')) {
              map['last_poster_username'] = user['username'];
            }
          }

          // 4. 如果没有 like_count，设置为 0（书签数据中可能没有这个字段）
          if (!map.containsKey('like_count')) {
            map['like_count'] = 0;
          }

          // 5. 如果没有 views，设置为 0
          if (!map.containsKey('views')) {
            map['views'] = 0;
          }

          return map;
        }).toList();
      }
    } else if (json.containsKey('bookmarks')) {
      // 处理 /bookmarks.json 格式
      final bookmarks = json['bookmarks'] as List<dynamic>? ?? [];
      topicsJson = bookmarks.map((b) {
        final map = Map<String, dynamic>.from(b as Map);
        // 书签对象中的 id 是书签 ID，topic_id 才是主题 ID
        // 为了兼容 Topic.fromJson，我们将 topic_id 赋给 id
        if (map.containsKey('topic_id')) {
          map['id'] = map['topic_id'];
        }
        return map;
      }).toList();
    }

    return TopicListResponse(
      topics: topicsJson.map((t) => Topic.fromJson(t as Map<String, dynamic>, userMap: userMap)).toList(),
      moreTopicsUrl: moreTopicsUrl,
    );
  }
}

/// 举报类型
class FlagType {
  final int id;
  final String nameKey;
  final String name;
  final String description;
  final String? shortDescription;
  final bool isFlag;
  final bool requireMessage;
  final bool enabled;
  final int position;
  final List<String> appliesTo;

  const FlagType({
    required this.id,
    required this.nameKey,
    required this.name,
    required this.description,
    this.shortDescription,
    required this.isFlag,
    this.requireMessage = false,
    this.enabled = true,
    this.position = 0,
    this.appliesTo = const ['Post', 'Chat::Message'],
  });

  factory FlagType.fromJson(Map<String, dynamic> json) {
    return FlagType(
      id: json['id'] as int,
      nameKey: json['name_key'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      shortDescription: json['short_description'] as String?,
      isFlag: json['is_flag'] as bool? ?? false,
      requireMessage: json['require_message'] as bool? ?? false,
      enabled: json['enabled'] as bool? ?? true,
      position: json['position'] as int? ?? 0,
      appliesTo: (json['applies_to'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList() ?? const ['Post', 'Chat::Message'],
    );
  }

  /// 是否适用于帖子
  bool get appliesToPost => appliesTo.contains('Post');

  /// 默认的举报类型列表（作为后备）
  static List<FlagType> get defaultTypes => [
    FlagType(
      id: 3,
      nameKey: 'off_topic',
      name: S.current.topic_flagOffTopic,
      description: S.current.topic_flagOffTopicDesc,
      isFlag: true,
      position: 1,
    ),
    FlagType(
      id: 4,
      nameKey: 'inappropriate',
      name: S.current.topic_flagInappropriate,
      description: S.current.topic_flagInappropriateDesc,
      isFlag: true,
      position: 2,
    ),
    FlagType(
      id: 8,
      nameKey: 'spam',
      name: S.current.topic_flagSpam,
      description: S.current.topic_flagSpamDesc,
      isFlag: true,
      position: 3,
    ),
    FlagType(
      id: 7,
      nameKey: 'notify_moderators',
      name: S.current.topic_flagOther,
      description: S.current.topic_flagOtherDesc,
      isFlag: true,
      requireMessage: true,
      position: 4,
    ),
  ];
}
