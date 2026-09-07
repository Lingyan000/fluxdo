/// MessageBus 相关数据模型
library;

import '../../utils/url_helper.dart';

/// 正在输入的用户信息
class TypingUser {
  final int id;
  final String username;
  final String avatarTemplate;

  const TypingUser({
    required this.id,
    required this.username,
    required this.avatarTemplate,
  });

  String getAvatarUrl({int size = 40}) {
    final template = avatarTemplate.replaceAll('{size}', '$size');
    return UrlHelper.resolveUrlWithCdn(template);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TypingUser &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// presence/get API 响应
class PresenceResponse {
  final List<TypingUser> users;
  final int messageId;

  const PresenceResponse({required this.users, required this.messageId});

  factory PresenceResponse.fromJson(Map<String, dynamic> json, int topicId) {
    final channelKey = '/discourse-presence/reply/$topicId';
    final channelData = json[channelKey] as Map<String, dynamic>?;
    
    if (channelData == null) {
      return const PresenceResponse(users: [], messageId: -1);
    }
    
    final usersList = channelData['users'] as List<dynamic>? ?? [];
    final users = usersList.map((u) {
      final userMap = u as Map<String, dynamic>;
      return TypingUser(
        id: userMap['id'] as int? ?? 0,
        username: userMap['username'] as String? ?? '',
        avatarTemplate: userMap['avatar_template'] as String? ?? '',
      );
    }).where((u) => u.username.isNotEmpty && u.id > 0).toList();
    
    final messageId = channelData['message_id'] as int? ?? -1;
    
    return PresenceResponse(users: users, messageId: messageId);
  }
}

/// 话题频道消息类型
enum TopicMessageType {
  created,    // 新帖子创建
  revised,    // 帖子被修改
  rebaked,    // 帖子被重新渲染
  deleted,    // 帖子被删除（软删除）
  destroyed,  // 帖子被永久删除
  recovered,  // 帖子被恢复
  acted,      // 有人对帖子执行了操作
  liked,      // 有人点赞
  unliked,    // 有人取消点赞
  read,       // 有人阅读了帖子
  stats,      // 话题统计更新
  boostAdded,    // 有人发送了 Boost
  boostRemoved,  // Boost 被删除
  moveToInbox,    // 私信移入收件箱
  archived,       // 私信被归档
  removeAllowedUser, // 用户被移出私信
  policyChanged, // Policy 接受/撤销状态变更（discourse-policy）
}

/// 帖子更新信息
class PostUpdate {
  final int postId;
  final TopicMessageType type;
  final DateTime updatedAt;
  final int? likesCount;  // 用于 liked/unliked
  final int? readersCount; // 用于 read
  final int? userId;       // 操作用户
  final Map<String, dynamic>? boostData; // 用于 boostAdded
  final int? boostId;     // 用于 boostRemoved

  const PostUpdate({
    required this.postId,
    required this.type,
    required this.updatedAt,
    this.likesCount,
    this.readersCount,
    this.userId,
    this.boostData,
    this.boostId,
  });
}

/// 话题统计更新
class TopicStatsUpdate {
  final int? postsCount;
  final int? likeCount;
  final DateTime? lastPostedAt;

  const TopicStatsUpdate({
    this.postsCount,
    this.likeCount,
    this.lastPostedAt,
  });
}

/// "俺也一样" (shared_issue) 推送：MessageBus payload `{type: shared_issue, count, user_created_shared_issue}`
class SharedIssueUpdate {
  final int count;
  final bool userCreated;

  const SharedIssueUpdate({required this.count, required this.userCreated});
}

/// 话题频道状态
class TopicChannelState {
  final bool hasNewReplies;
  final List<TypingUser> typingUsers;

  /// 最近一批帖子更新(微任务边界攒批后整体替换,配合
  /// [postUpdatesGeneration] 消费 —— 不是累积列表)
  final List<PostUpdate> postUpdates;

  /// 批次号:每 flush 一批 +1。监听方比较它判断"有新一批",
  /// 一次拿到整批做去重/坍缩,替代逐条通知。
  final int postUpdatesGeneration;
  final TopicStatsUpdate? statsUpdate;
  final SharedIssueUpdate? sharedIssueUpdate;
  final bool messageArchived;
  final bool removedFromPrivateMessage;
  final bool reloadRequested;        // 需要重新加载话题（reload_topic 消息）
  final bool refreshStreamRequested; // 需要刷新帖子流（reload_topic + refresh_stream）
  final int? notificationLevelChange; // 通知级别变更

  const TopicChannelState({
    this.hasNewReplies = false,
    this.typingUsers = const [],
    this.postUpdates = const [],
    this.postUpdatesGeneration = 0,
    this.statsUpdate,
    this.sharedIssueUpdate,
    this.messageArchived = false,
    this.removedFromPrivateMessage = false,
    this.reloadRequested = false,
    this.refreshStreamRequested = false,
    this.notificationLevelChange,
  });

  TopicChannelState copyWith({
    bool? hasNewReplies,
    List<TypingUser>? typingUsers,
    List<PostUpdate>? postUpdates,
    int? postUpdatesGeneration,
    TopicStatsUpdate? statsUpdate,
    bool? clearStatsUpdate,
    SharedIssueUpdate? sharedIssueUpdate,
    bool clearSharedIssueUpdate = false,
    bool? messageArchived,
    bool? removedFromPrivateMessage,
    bool? reloadRequested,
    bool? refreshStreamRequested,
    int? notificationLevelChange,
    bool clearNotificationLevelChange = false,
  }) {
    return TopicChannelState(
      hasNewReplies: hasNewReplies ?? this.hasNewReplies,
      typingUsers: typingUsers ?? this.typingUsers,
      postUpdates: postUpdates ?? this.postUpdates,
      postUpdatesGeneration:
          postUpdatesGeneration ?? this.postUpdatesGeneration,
      statsUpdate: clearStatsUpdate == true ? null : (statsUpdate ?? this.statsUpdate),
      sharedIssueUpdate: clearSharedIssueUpdate
          ? null
          : (sharedIssueUpdate ?? this.sharedIssueUpdate),
      messageArchived: messageArchived ?? this.messageArchived,
      removedFromPrivateMessage:
          removedFromPrivateMessage ?? this.removedFromPrivateMessage,
      reloadRequested: reloadRequested ?? this.reloadRequested,
      refreshStreamRequested: refreshStreamRequested ?? this.refreshStreamRequested,
      notificationLevelChange: clearNotificationLevelChange ? null : (notificationLevelChange ?? this.notificationLevelChange),
    );
  }
}

/// 通知计数状态
class NotificationCountState {
  final int allUnread;
  final int unread;
  final int highPriority;

  const NotificationCountState({
    this.allUnread = 0,
    this.unread = 0,
    this.highPriority = 0,
  });
  
  NotificationCountState copyWith({
    int? allUnread,
    int? unread,
    int? highPriority,
  }) {
    return NotificationCountState(
      allUnread: allUnread ?? this.allUnread,
      unread: unread ?? this.unread,
      highPriority: highPriority ?? this.highPriority,
    );
  }
}
