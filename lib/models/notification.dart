import '../utils/time_utils.dart';
import '../utils/url_helper.dart';

/// Discourse 通知类型枚举
enum NotificationType {
  mentioned(1, '提及'),
  replied(2, '回复'),
  quoted(3, '引用'),
  edited(4, '编辑'),
  liked(5, '点赞'),
  privateMessage(6, '私信'),
  invitedToPrivateMessage(7, '私信邀请'),
  inviteeAccepted(8, '邀请已接受'),
  posted(9, '发帖'),
  movedPost(10, '帖子移动'),
  linked(11, '链接'),
  grantedBadge(12, '获得徽章'),
  invitedToTopic(13, '话题邀请'),
  custom(14, '自定义'),
  groupMentioned(15, '群组提及'),
  groupMessageSummary(16, '群组消息摘要'),
  watchingFirstPost(17, '关注首帖'),
  topicReminder(18, '话题提醒'),
  likedConsolidated(19, '点赞汇总'),
  postApproved(20, '帖子已批准'),
  codeReviewCommitApproved(21, '代码审核通过'),
  membershipRequestAccepted(22, '成员申请已接受'),
  membershipRequestConsolidated(23, '成员申请汇总'),
  bookmarkReminder(24, '书签提醒'),
  reaction(25, '反应'),
  votesReleased(26, '投票发布'),
  eventReminder(27, '活动提醒'),
  eventInvitation(28, '活动邀请'),
  chatMention(29, '聊天提及'),
  chatMessage(30, '聊天消息'),
  chatInvitation(31, '聊天邀请'),
  chatGroupMention(32, '群聊提及'),
  chatQuotedPost(33, '聊天引用'),
  assignedTopic(34, '话题指派'),
  questionAnswerUserCommented(35, '问答评论'),
  watchingCategoryOrTag(36, '关注分类或标签'),
  newFeatures(37, '新功能'),
  adminProblems(38, '管理员问题'),
  linkedConsolidated(39, '链接汇总'),
  chatWatchedThread(40, '聊天关注话题'),
  following(800, '关注'),
  followingCreatedTopic(801, '关注的用户创建了话题'),
  followingReplied(802, '关注的用户回复了'),
  circlesActivity(900, '圈子活动'),
  unknown(0, '未知');

  final int id;
  final String label;
  const NotificationType(this.id, this.label);

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
  final int? originalPostId;
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
  });

  factory NotificationData.fromJson(Map<String, dynamic> json) {
    return NotificationData(
      displayUsername: json['display_username'] as String?,
      originalPostId: json['original_post_id'] as int?,
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

  DiscourseNotification copyWith({
    bool? read,
    bool? highPriority,
  }) {
    return DiscourseNotification(
      id: id,
      userId: userId,
      notificationType: notificationType,
      read: read ?? this.read,
      highPriority: highPriority ?? this.highPriority,
      createdAt: createdAt,
      postNumber: postNumber,
      topicId: topicId,
      slug: slug,
      data: data,
      fancyTitle: fancyTitle,
      actingUserAvatarTemplate: actingUserAvatarTemplate,
    );
  }

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
      data: NotificationData.fromJson(json['data'] as Map<String, dynamic>? ?? {}),
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
    return UrlHelper.resolveAvatarUrl(
      avatarTemplate: actingUserAvatarTemplate ?? data.avatarTemplate,
      size: size,
    );
  }

  /// 获取通知标题
  String get title {
    // 优先使用 data.topicTitle（纯文本格式，避免 HTML 实体问题）
    if (data.topicTitle != null && data.topicTitle!.isNotEmpty) return data.topicTitle!;
    // 其次使用 fancy_title
    if (fancyTitle != null && fancyTitle!.isNotEmpty) return fancyTitle!;
    // 兜底使用通知类型
    return notificationType.label;
  }

  /// 获取通知描述
  String get description {
    final username = data.displayUsername ?? data.originalUsername ?? '';
    switch (notificationType) {
      case NotificationType.mentioned:
        return '$username 在帖子中提及了你';
      case NotificationType.replied:
        return '$username 回复了你的帖子';
      case NotificationType.quoted:
        return '$username 引用了你的帖子';
      case NotificationType.liked:
        return '$username 赞了你的帖子';
      case NotificationType.likedConsolidated:
        final count = data.count ?? 1;
        return '$count 人赞了你的帖子';
      case NotificationType.privateMessage:
        return '$username 发送了私信';
      case NotificationType.posted:
        return '$username 发布了新帖子';
      case NotificationType.grantedBadge:
        return '获得徽章: ${data.badgeName ?? ""}';
      case NotificationType.linked:
        return '$username 链接了你的帖子';
      case NotificationType.watchingFirstPost:
        return '$username 发布了你关注话题的首帖';
      case NotificationType.bookmarkReminder:
        return '书签提醒';
      case NotificationType.groupMentioned:
        return '群组 ${data.groupName ?? ""} 被提及';
      case NotificationType.following:
        return '$username 开始关注你';
      case NotificationType.followingCreatedTopic:
        return '$username 创建了新话题';
      case NotificationType.followingReplied:
        return '$username 回复了话题';
      case NotificationType.invitedToTopic:
        return '$username 邀请你参与话题';
      case NotificationType.invitedToPrivateMessage:
        return '$username 邀请你参与私信';
      case NotificationType.inviteeAccepted:
        return '$username 接受了你的邀请';
      case NotificationType.movedPost:
        return '帖子已被移动';
      case NotificationType.linkedConsolidated:
        return '$username 链接了你的帖子';
      case NotificationType.topicReminder:
        return '话题提醒';
      case NotificationType.reaction:
        return '$username 对你的帖子做出了反应';
      case NotificationType.votesReleased:
        return '投票已发布';
      case NotificationType.eventReminder:
        return '活动提醒';
      case NotificationType.eventInvitation:
        return '$username 邀请你参加活动';
      case NotificationType.chatMention:
        return '$username 在聊天中提及了你';
      case NotificationType.chatMessage:
        return '$username 发送了聊天消息';
      case NotificationType.chatInvitation:
        return '$username 邀请你参与聊天';
      case NotificationType.chatGroupMention:
        return '群组在聊天中被提及';
      case NotificationType.chatQuotedPost:
        return '$username 在聊天中引用了你';
      case NotificationType.chatWatchedThread:
        return '你关注的聊天话题有新消息';
      case NotificationType.assignedTopic:
        return '话题已分配给你';
      case NotificationType.questionAnswerUserCommented:
        return '$username 评论了问答';
      case NotificationType.watchingCategoryOrTag:
        return '你关注的分类或标签有新内容';
      case NotificationType.newFeatures:
        return '新功能发布';
      case NotificationType.adminProblems:
        return '管理员问题提醒';
      case NotificationType.circlesActivity:
        return '圈子有新动态';
      case NotificationType.edited:
        return '$username 编辑了帖子';
      case NotificationType.custom:
        return '自定义通知';
      case NotificationType.groupMessageSummary:
        return '群组消息摘要';
      case NotificationType.postApproved:
        return '你的帖子已被批准';
      case NotificationType.codeReviewCommitApproved:
        return '代码审核已通过';
      case NotificationType.membershipRequestAccepted:
        return '你的成员申请已被接受';
      case NotificationType.membershipRequestConsolidated:
        return '成员申请汇总';
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
