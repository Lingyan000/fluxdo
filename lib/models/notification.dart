import 'dart:convert';

import '../l10n/s.dart';
import '../utils/time_utils.dart';
import '../utils/url_helper.dart';

/// 解析通知 data 字段：可能是 Map、JSON string 或 null
Map<String, dynamic> _parseDataField(dynamic data) {
  if (data is Map<String, dynamic>) return data;
  if (data is String) {
    try {
      final parsed = jsonDecode(data);
      if (parsed is Map<String, dynamic>) return parsed;
    } catch (_) {}
  }
  return {};
}

/// Discourse 通知类型枚举
enum NotificationType {
  mentioned(1),
  replied(2),
  quoted(3),
  edited(4),
  liked(5),
  privateMessage(6),
  invitedToPrivateMessage(7),
  inviteeAccepted(8),
  posted(9),
  movedPost(10),
  linked(11),
  grantedBadge(12),
  invitedToTopic(13),
  custom(14),
  groupMentioned(15),
  groupMessageSummary(16),
  watchingFirstPost(17),
  topicReminder(18),
  likedConsolidated(19),
  postApproved(20),
  codeReviewCommitApproved(21),
  membershipRequestAccepted(22),
  membershipRequestConsolidated(23),
  bookmarkReminder(24),
  reaction(25),
  votesReleased(26),
  eventReminder(27),
  eventInvitation(28),
  chatMention(29),
  chatMessage(30),
  chatInvitation(31),
  chatGroupMention(32),
  chatQuotedPost(33),
  assignedTopic(34),
  questionAnswerUserCommented(35),
  watchingCategoryOrTag(36),
  newFeatures(37),
  adminProblems(38),
  linkedConsolidated(39),
  chatWatchedThread(40),
  boost(43),
  following(800),
  followingCreatedTopic(801),
  followingReplied(802),
  circlesActivity(900),
  unknown(0);

  final int id;
  const NotificationType(this.id);

  String get label {
    switch (this) {
      case NotificationType.mentioned: return S.current.notification_typeMentioned;
      case NotificationType.replied: return S.current.notification_typeReplied;
      case NotificationType.quoted: return S.current.notification_typeQuoted;
      case NotificationType.edited: return S.current.notification_typeEdited;
      case NotificationType.liked: return S.current.notification_typeLiked;
      case NotificationType.privateMessage: return S.current.notification_typePrivateMessage;
      case NotificationType.invitedToPrivateMessage: return S.current.notification_typeInvitedToPM;
      case NotificationType.inviteeAccepted: return S.current.notification_typeInviteeAccepted;
      case NotificationType.posted: return S.current.notification_typePosted;
      case NotificationType.movedPost: return S.current.notification_typeMovedPost;
      case NotificationType.linked: return S.current.notification_typeLinked;
      case NotificationType.grantedBadge: return S.current.notification_typeGrantedBadge;
      case NotificationType.invitedToTopic: return S.current.notification_typeInvitedToTopic;
      case NotificationType.custom: return S.current.notification_typeCustom;
      case NotificationType.groupMentioned: return S.current.notification_typeGroupMentioned;
      case NotificationType.groupMessageSummary: return S.current.notification_typeGroupMessageSummary;
      case NotificationType.watchingFirstPost: return S.current.notification_typeWatchingFirstPost;
      case NotificationType.topicReminder: return S.current.notification_typeTopicReminder;
      case NotificationType.likedConsolidated: return S.current.notification_typeLikedConsolidated;
      case NotificationType.postApproved: return S.current.notification_typePostApproved;
      case NotificationType.codeReviewCommitApproved: return S.current.notification_typeCodeReviewApproved;
      case NotificationType.membershipRequestAccepted: return S.current.notification_typeMembershipAccepted;
      case NotificationType.membershipRequestConsolidated: return S.current.notification_typeMembershipConsolidated;
      case NotificationType.bookmarkReminder: return S.current.notification_typeBookmarkReminder;
      case NotificationType.reaction: return S.current.notification_typeReaction;
      case NotificationType.votesReleased: return S.current.notification_typeVotesReleased;
      case NotificationType.eventReminder: return S.current.notification_typeEventReminder;
      case NotificationType.eventInvitation: return S.current.notification_typeEventInvitation;
      case NotificationType.chatMention: return S.current.notification_typeChatMention;
      case NotificationType.chatMessage: return S.current.notification_typeChatMessage;
      case NotificationType.chatInvitation: return S.current.notification_typeChatInvitation;
      case NotificationType.chatGroupMention: return S.current.notification_typeChatGroupMention;
      case NotificationType.chatQuotedPost: return S.current.notification_typeChatQuotedPost;
      case NotificationType.assignedTopic: return S.current.notification_typeAssignedTopic;
      case NotificationType.questionAnswerUserCommented: return S.current.notification_typeQACommented;
      case NotificationType.watchingCategoryOrTag: return S.current.notification_typeWatchingCategoryOrTag;
      case NotificationType.newFeatures: return S.current.notification_typeNewFeatures;
      case NotificationType.adminProblems: return S.current.notification_typeAdminProblems;
      case NotificationType.linkedConsolidated: return S.current.notification_typeLinkedConsolidated;
      case NotificationType.chatWatchedThread: return S.current.notification_typeChatWatchedThread;
      case NotificationType.boost: return S.current.notification_typeBoost;
      case NotificationType.following: return S.current.notification_typeFollowing;
      case NotificationType.followingCreatedTopic: return S.current.notification_typeFollowingCreatedTopic;
      case NotificationType.followingReplied: return S.current.notification_typeFollowingReplied;
      case NotificationType.circlesActivity: return S.current.notification_typeCirclesActivity;
      case NotificationType.unknown: return S.current.notification_typeUnknown;
    }
  }

  static NotificationType fromId(int id) {
    return NotificationType.values.firstWhere(
      (type) => type.id == id,
      orElse: () => NotificationType.unknown,
    );
  }
}

/// 通知详细数据
class NotificationData {
  final String? displayUsername;
  final String? originalPostId;
  final int? originalPostType;
  final String? originalUsername;
  final int? revisionNumber;
  final String? topicTitle;
  final String? badgeName;
  final int? badgeId;
  final String? badgeSlug;
  final String? groupName;
  final String? inboxCount;
  final int? count;
  final String? username;
  final String? username2;
  final String? avatarTemplate;
  final String? boostRaw;

  NotificationData({
    this.displayUsername,
    this.originalPostId,
    this.originalPostType,
    this.originalUsername,
    this.revisionNumber,
    this.topicTitle,
    this.badgeName,
    this.badgeId,
    this.badgeSlug,
    this.groupName,
    this.inboxCount,
    this.count,
    this.username,
    this.username2,
    this.avatarTemplate,
    this.boostRaw,
  });

  factory NotificationData.fromJson(Map<String, dynamic> json) {
    return NotificationData(
      displayUsername: json['display_username'] as String?,
      originalPostId: json['original_post_id']?.toString(),
      originalPostType: json['original_post_type'] as int?,
      originalUsername: json['original_username'] as String?,
      revisionNumber: json['revision_number'] as int?,
      topicTitle: json['topic_title'] as String?,
      badgeName: json['badge_name'] as String?,
      badgeId: json['badge_id'] as int?,
      badgeSlug: json['badge_slug'] as String?,
      groupName: json['group_name'] as String?,
      inboxCount: json['inbox_count']?.toString(),
      count: json['count'] as int?,
      username: json['username'] as String?,
      username2: json['username2'] as String?,
      avatarTemplate: json['acting_user_avatar_template'] as String? ?? json['avatar_template'] as String?,
      boostRaw: json['boost_raw'] as String?,
    );
  }
}

/// Discourse 通知模型
class DiscourseNotification {
  final int id;
  final int userId;
  final NotificationType notificationType;
  final bool read;
  final bool highPriority;
  final DateTime createdAt;
  final int? postNumber;
  final int? topicId;
  final String? slug;
  final NotificationData data;
  final String? fancyTitle;
  final String? actingUserAvatarTemplate;

  DiscourseNotification({
    required this.id,
    required this.userId,
    required this.notificationType,
    required this.read,
    required this.highPriority,
    required this.createdAt,
    this.postNumber,
    this.topicId,
    this.slug,
    required this.data,
    this.fancyTitle,
    this.actingUserAvatarTemplate,
  });

  factory DiscourseNotification.fromJson(Map<String, dynamic> json) {
    return DiscourseNotification(
      id: json['id'] as int,
      userId: json['user_id'] as int,
      notificationType: NotificationType.fromId(json['notification_type'] as int),
      read: json['read'] as bool? ?? false,
      highPriority: json['high_priority'] as bool? ?? false,
      createdAt: TimeUtils.parseUtcTime(json['created_at'] as String?) ?? DateTime.now(),
      postNumber: json['post_number'] as int?,
      topicId: json['topic_id'] as int?,
      slug: json['slug'] as String?,
      data: NotificationData.fromJson(_parseDataField(json['data'])),
      fancyTitle: json['fancy_title'] as String?,
      actingUserAvatarTemplate: json['acting_user_avatar_template'] as String?,
    );
  }

  /// 获取显示用户名
  String? get username {
    return data.displayUsername ?? data.username ?? data.originalUsername;
  }

  /// 获取头像 URL
  String getAvatarUrl({int size = 96}) {
    // 优先使用顶层的 acting_user_avatar_template
    String? template = actingUserAvatarTemplate ?? data.avatarTemplate;
    if (template == null || template.isEmpty) {
      return '';
    }
    // 替换 {size} 占位符并解析 URL
    final url = template.replaceAll('{size}', size.toString());
    return UrlHelper.resolveUrlWithCdn(url);
  }

  DiscourseNotification copyWith({
    int? id,
    int? userId,
    NotificationType? notificationType,
    bool? read,
    bool? highPriority,
    DateTime? createdAt,
    int? postNumber,
    int? topicId,
    String? slug,
    NotificationData? data,
    String? fancyTitle,
    String? actingUserAvatarTemplate,
  }) {
    return DiscourseNotification(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      notificationType: notificationType ?? this.notificationType,
      read: read ?? this.read,
      highPriority: highPriority ?? this.highPriority,
      createdAt: createdAt ?? this.createdAt,
      postNumber: postNumber ?? this.postNumber,
      topicId: topicId ?? this.topicId,
      slug: slug ?? this.slug,
      data: data ?? this.data,
      fancyTitle: fancyTitle ?? this.fancyTitle,
      actingUserAvatarTemplate: actingUserAvatarTemplate ?? this.actingUserAvatarTemplate,
    );
  }

  /// 获取通知标题
  String get title {
    final displayName = data.displayUsername ?? data.originalUsername ?? '';

    // 某些类型有专门的标题逻辑，不应使用话题标题
    switch (notificationType) {
      case NotificationType.grantedBadge:
        return data.badgeName != null
            ? S.current.notification_grantedBadge(data.badgeName!)
            : notificationType.label;
      case NotificationType.inviteeAccepted:
        return displayName.isNotEmpty ? S.current.notification_inviteeAccepted(displayName) : notificationType.label;
      case NotificationType.following:
        return displayName.isNotEmpty ? S.current.notification_followingYou(displayName) : notificationType.label;
      case NotificationType.likedConsolidated:
        final count = data.count ?? 0;
        return displayName.isNotEmpty
            ? S.current.notification_likedMultiplePosts(displayName, count)
            : S.current.notification_peopleLikedPost(count);
      case NotificationType.linkedConsolidated:
        final count = data.count ?? 0;
        return displayName.isNotEmpty
            ? S.current.notification_linkedMultiplePosts(displayName, count)
            : S.current.notification_peopleLinkedPost(count);
      case NotificationType.groupMessageSummary:
        final count = int.tryParse(data.inboxCount ?? '0') ?? 0;
        return S.current.notification_groupMessageSummary(data.groupName ?? "", count);
      case NotificationType.membershipRequestAccepted:
        return S.current.notification_membershipAccepted(data.groupName ?? "");
      case NotificationType.membershipRequestConsolidated:
        final count = data.count ?? 0;
        return S.current.notification_membershipPending(count, data.groupName ?? "");
      case NotificationType.newFeatures:
        return S.current.notification_newFeaturesAvailable;
      case NotificationType.adminProblems:
        return S.current.notification_adminNewSuggestions;
      default:
        break;
    }

    // 话题类通知：使用话题标题
    if (data.topicTitle != null && data.topicTitle!.isNotEmpty) return data.topicTitle!;
    if (fancyTitle != null && fancyTitle!.isNotEmpty) return fancyTitle!;

    // 兜底使用通知类型
    return notificationType.label;
  }

  /// 获取通知描述
  String get description {
    final username = data.displayUsername ?? data.originalUsername ?? '';
    switch (notificationType) {
      // === 话题类通知：描述为 "用户 + 操作" ===
      case NotificationType.mentioned:
        return S.current.notification_mentioned(username);
      case NotificationType.replied:
        return S.current.notification_replied(username);
      case NotificationType.quoted:
        return S.current.notification_quoted(username);
      case NotificationType.liked:
        // 处理多人点赞
        final count = data.count ?? 1;
        if (count <= 1) {
          return S.current.notification_liked(username);
        } else if (count == 2) {
          final username2 = data.username2 ?? '';
          return S.current.notification_likedByTwo(username, username2);
        } else {
          return S.current.notification_likedByMany(username, count - 1);
        }
      case NotificationType.privateMessage:
        return S.current.notification_privateMsgSent(username);
      case NotificationType.posted:
        return S.current.notification_newPostPublished(username);
      case NotificationType.linked:
        return S.current.notification_linkedPost(username);
      case NotificationType.edited:
        return S.current.notification_editedPost(username);
      case NotificationType.movedPost:
        return S.current.notification_movedPost(username);
      case NotificationType.groupMentioned:
        return '$username @${data.groupName ?? ""}';
      case NotificationType.watchingFirstPost:
        return S.current.notification_newTopic;
      case NotificationType.followingCreatedTopic:
        return S.current.notification_createdNewTopic(username);
      case NotificationType.followingReplied:
        return S.current.notification_repliedTopic(username);
      case NotificationType.invitedToTopic:
        return S.current.notification_invitedToTopic(username);
      case NotificationType.invitedToPrivateMessage:
        return S.current.notification_invitedToPM(username);
      case NotificationType.bookmarkReminder:
        return S.current.notification_bookmarkReminder;
      case NotificationType.topicReminder:
        return S.current.notification_topicReminder;
      case NotificationType.reaction:
        return S.current.notification_reaction(username);
      case NotificationType.votesReleased:
        return S.current.notification_votesReleased;
      case NotificationType.eventReminder:
        return S.current.notification_eventReminder;
      case NotificationType.eventInvitation:
        return S.current.notification_eventInvitation(username);
      case NotificationType.chatMention:
        return S.current.notification_chatMention(username);
      case NotificationType.chatMessage:
        return S.current.notification_chatMessage(username);
      case NotificationType.chatInvitation:
        return S.current.notification_chatInvitation(username);
      case NotificationType.chatGroupMention:
        return S.current.notification_chatGroupMention;
      case NotificationType.chatQuotedPost:
        return S.current.notification_chatQuotedPost(username);
      case NotificationType.chatWatchedThread:
        return S.current.notification_chatWatchedThread;
      case NotificationType.boost:
        final count = data.count ?? 1;
        if (count > 1) {
          return S.current.notification_boostByMany(username, count - 1);
        }
        final boostRaw = data.boostRaw;
        if (boostRaw != null && boostRaw.isNotEmpty) {
          return S.current.notification_boostWithContent(username, boostRaw);
        }
        return S.current.notification_boost(username);
      case NotificationType.assignedTopic:
        return S.current.notification_assignedTopic;
      case NotificationType.questionAnswerUserCommented:
        return S.current.notification_qaCommented(username);
      case NotificationType.watchingCategoryOrTag:
        return S.current.notification_watchingCategoryNewPost(username);
      case NotificationType.postApproved:
        return S.current.notification_postApproved;
      case NotificationType.codeReviewCommitApproved:
        return S.current.notification_codeReviewApproved;
      case NotificationType.custom:
        return S.current.notification_custom;
      case NotificationType.circlesActivity:
        return S.current.notification_circlesActivity;

      // === 非话题类通知：标题已包含完整信息，描述使用类型标签 ===
      case NotificationType.grantedBadge:
      case NotificationType.inviteeAccepted:
      case NotificationType.following:
      case NotificationType.likedConsolidated:
      case NotificationType.linkedConsolidated:
      case NotificationType.groupMessageSummary:
      case NotificationType.membershipRequestAccepted:
      case NotificationType.membershipRequestConsolidated:
      case NotificationType.newFeatures:
      case NotificationType.adminProblems:
        return notificationType.label;

      default:
        if (username.isNotEmpty) return username;
        return notificationType.label;
    }
  }
}

/// 通知列表响应
class NotificationListResponse {
  final List<DiscourseNotification> notifications;
  final int totalRowsNotifications;
  final int seenNotificationId;
  final String? loadMoreNotifications;

  NotificationListResponse({
    required this.notifications,
    required this.totalRowsNotifications,
    required this.seenNotificationId,
    this.loadMoreNotifications,
  });

  factory NotificationListResponse.fromJson(Map<String, dynamic> json) {
    final notificationsList = json['notifications'] as List<dynamic>? ?? [];
    return NotificationListResponse(
      notifications: notificationsList
          .map((e) => DiscourseNotification.fromJson(e as Map<String, dynamic>))
          .toList(),
      totalRowsNotifications: json['total_rows_notifications'] as int? ?? 0,
      seenNotificationId: json['seen_notification_id'] as int? ?? 0,
      loadMoreNotifications: json['load_more_notifications'] as String?,
    );
  }
}
