import '../../utils/time_utils.dart';
import '../../utils/url_helper.dart';
import 'chat_user.dart';

/// Chat 消息附件(uploads 数组元素,来自核心 UploadSerializer)
class ChatUpload {
  final int id;
  final String? url;
  final String? shortUrl;
  final String? originalFilename;
  final String? extension;
  final int? width;
  final int? height;
  final int? thumbnailWidth;
  final int? thumbnailHeight;
  final String? dominantColor;

  const ChatUpload({
    required this.id,
    this.url,
    this.shortUrl,
    this.originalFilename,
    this.extension,
    this.width,
    this.height,
    this.thumbnailWidth,
    this.thumbnailHeight,
    this.dominantColor,
  });

  factory ChatUpload.fromJson(Map<String, dynamic> json) {
    return ChatUpload(
      id: json['id'] as int? ?? 0,
      url: json['url'] as String?,
      shortUrl: json['short_url'] as String?,
      originalFilename: json['original_filename'] as String?,
      extension: json['extension'] as String?,
      width: json['width'] as int?,
      height: json['height'] as int?,
      thumbnailWidth: json['thumbnail_width'] as int?,
      thumbnailHeight: json['thumbnail_height'] as int?,
      dominantColor: json['dominant_color'] as String?,
    );
  }

  String? get resolvedUrl =>
      url == null ? null : UrlHelper.resolveUrlWithCdn(url!);
}

/// Chat 消息上的表情回应聚合
class ChatMessageReaction {
  final String emoji;
  final int count;
  final bool reacted;
  final List<ChatUser> users;

  const ChatMessageReaction({
    required this.emoji,
    required this.count,
    required this.reacted,
    this.users = const [],
  });

  factory ChatMessageReaction.fromJson(Map<String, dynamic> json) {
    return ChatMessageReaction(
      emoji: json['emoji'] as String? ?? '',
      count: json['count'] as int? ?? 0,
      reacted: json['reacted'] as bool? ?? false,
      users: (json['users'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ChatUser.fromJson)
          .toList(),
    );
  }
}

/// 被回复消息的摘要(in_reply_to 字段,服务端只给精简形状)
class ChatMessageReplyRef {
  final int id;
  final String? excerpt;
  final ChatUser? user;

  const ChatMessageReplyRef({required this.id, this.excerpt, this.user});

  factory ChatMessageReplyRef.fromJson(Map<String, dynamic> json) {
    final user = json['user'];
    return ChatMessageReplyRef(
      id: json['id'] as int? ?? 0,
      excerpt: json['excerpt'] as String?,
      user: user is Map<String, dynamic> ? ChatUser.fromJson(user) : null,
    );
  }
}

/// 消息上的 thread 摘要(thread 字段;开启消息串的消息带回复数)
class ChatThreadRef {
  final int id;
  final String? title;
  final int replyCount;
  final DateTime? lastReplyCreatedAt;

  /// 最后回复摘要与作者(官方入口卡样式用)
  final String? lastReplyExcerpt;
  final ChatUser? lastReplyUser;

  /// 参与者头像(preview.participant_users,最多几个)
  final List<ChatUser> participants;

  const ChatThreadRef({
    required this.id,
    this.title,
    this.replyCount = 0,
    this.lastReplyCreatedAt,
    this.lastReplyExcerpt,
    this.lastReplyUser,
    this.participants = const [],
  });

  factory ChatThreadRef.fromJson(Map<String, dynamic> json) {
    final preview = json['preview'] as Map<String, dynamic>?;
    final lastReplyUser = preview?['last_reply_user'];
    return ChatThreadRef(
      id: json['id'] as int? ?? 0,
      title: json['title'] as String?,
      replyCount:
          json['reply_count'] as int? ??
          preview?['reply_count'] as int? ??
          0,
      lastReplyCreatedAt: TimeUtils.parseUtcTime(
        preview?['last_reply_created_at'] as String?,
      ),
      lastReplyExcerpt: preview?['last_reply_excerpt'] as String?,
      lastReplyUser: lastReplyUser is Map<String, dynamic>
          ? ChatUser.fromJson(lastReplyUser)
          : null,
      participants: (preview?['participant_users'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ChatUser.fromJson)
          .toList(),
    );
  }
}

/// 消息发送状态(仅客户端使用,服务端消息恒为 sent)
enum ChatMessageSendState { sent, staged, failed }

/// 我对某条消息的收藏(bookmark 字段,仅收藏过时下发)
class ChatMessageBookmark {
  final int id;
  final String? name;
  final DateTime? reminderAt;

  const ChatMessageBookmark({required this.id, this.name, this.reminderAt});

  factory ChatMessageBookmark.fromJson(Map<String, dynamic> json) {
    return ChatMessageBookmark(
      id: json['id'] as int? ?? 0,
      name: json['name'] as String?,
      reminderAt: TimeUtils.parseUtcTime(json['reminder_at'] as String?),
    );
  }
}

/// Chat 消息
class ChatMessage {
  final int id;
  final int channelId;

  /// 原始 markdown
  final String message;

  /// 服务端 cook 出的 HTML;staged 消息为本地 cook 产物
  final String cooked;
  final String? excerpt;
  final DateTime? createdAt;
  final DateTime? deletedAt;
  final int? deletedById;
  final bool edited;
  final int? threadId;

  /// thread 摘要(仅串首消息带;回复数驱动"N 条回复"入口)
  final ChatThreadRef? thread;
  final ChatUser? user;
  final List<ChatUser> mentionedUsers;
  final List<ChatMessageReaction> reactions;
  final List<ChatUpload> uploads;
  final ChatMessageReplyRef? inReplyTo;
  final bool streaming;

  /// 乐观发送:客户端生成的 staged_id(uuid);服务端 sent 广播原样带回,
  /// 用于把本地临时消息原地替换为真实消息
  final String? stagedId;
  final ChatMessageSendState sendState;

  /// 可用举报类型的 nameKey(如 off_topic/inappropriate/spam);
  /// 空 = 不可举报(自己的消息/已举报过/无权限,服务端已算好)
  final List<String> availableFlags;

  /// 我对这条消息的举报状态(ReviewableScore.statuses 数值,pending=0)
  final int? userFlagStatus;

  /// 我的收藏(null=未收藏)
  final ChatMessageBookmark? bookmark;

  /// 是否被置顶(站点开 chat_pinned_messages 时下发)
  final bool pinned;

  const ChatMessage({
    required this.id,
    required this.channelId,
    required this.message,
    required this.cooked,
    this.excerpt,
    this.createdAt,
    this.deletedAt,
    this.deletedById,
    this.edited = false,
    this.threadId,
    this.thread,
    this.user,
    this.mentionedUsers = const [],
    this.reactions = const [],
    this.uploads = const [],
    this.inReplyTo,
    this.streaming = false,
    this.stagedId,
    this.sendState = ChatMessageSendState.sent,
    this.availableFlags = const [],
    this.userFlagStatus,
    this.bookmark,
    this.pinned = false,
  });

  bool get isDeleted => deletedAt != null;
  bool get isStaged => sendState == ChatMessageSendState.staged;

  factory ChatMessage.fromJson(
    Map<String, dynamic> json, {
    int? fallbackChannelId,
  }) {
    final user = json['user'];
    final inReplyTo = json['in_reply_to'];
    final thread = json['thread'];
    return ChatMessage(
      id: json['id'] as int? ?? 0,
      channelId:
          json['chat_channel_id'] as int? ??
          json['channel_id'] as int? ??
          fallbackChannelId ??
          0,
      message: json['message'] as String? ?? '',
      cooked: json['cooked'] as String? ?? '',
      excerpt: json['excerpt'] as String?,
      createdAt: TimeUtils.parseUtcTime(json['created_at'] as String?),
      deletedAt: TimeUtils.parseUtcTime(json['deleted_at'] as String?),
      deletedById: json['deleted_by_id'] as int?,
      edited: json['edited'] as bool? ?? false,
      threadId: json['thread_id'] as int?,
      thread: thread is Map<String, dynamic>
          ? ChatThreadRef.fromJson(thread)
          : null,
      user: user is Map<String, dynamic> ? ChatUser.fromJson(user) : null,
      mentionedUsers: (json['mentioned_users'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ChatUser.fromJson)
          .toList(),
      reactions: (json['reactions'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ChatMessageReaction.fromJson)
          .toList(),
      uploads: (json['uploads'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ChatUpload.fromJson)
          .toList(),
      inReplyTo: inReplyTo is Map<String, dynamic>
          ? ChatMessageReplyRef.fromJson(inReplyTo)
          : null,
      streaming: json['streaming'] as bool? ?? false,
      availableFlags: (json['available_flags'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      userFlagStatus: json['user_flag_status'] as int?,
      bookmark: json['bookmark'] is Map<String, dynamic>
          ? ChatMessageBookmark.fromJson(json['bookmark'] as Map<String, dynamic>)
          : null,
      pinned: json['pinned'] as bool? ?? false,
    );
  }

  static const _unset = Object();

  ChatMessage copyWith({
    int? id,
    String? message,
    String? cooked,
    DateTime? createdAt,
    DateTime? deletedAt,
    bool? edited,
    List<ChatMessageReaction>? reactions,
    List<ChatUpload>? uploads,
    String? stagedId,
    ChatMessageSendState? sendState,
    Object? bookmark = _unset,
    bool? pinned,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      channelId: channelId,
      message: message ?? this.message,
      cooked: cooked ?? this.cooked,
      excerpt: excerpt,
      createdAt: createdAt ?? this.createdAt,
      deletedAt: deletedAt ?? this.deletedAt,
      deletedById: deletedById,
      edited: edited ?? this.edited,
      threadId: threadId,
      thread: thread,
      user: user,
      mentionedUsers: mentionedUsers,
      reactions: reactions ?? this.reactions,
      uploads: uploads ?? this.uploads,
      inReplyTo: inReplyTo,
      streaming: streaming,
      stagedId: stagedId ?? this.stagedId,
      sendState: sendState ?? this.sendState,
      availableFlags: availableFlags,
      userFlagStatus: userFlagStatus,
      bookmark: identical(bookmark, _unset)
          ? this.bookmark
          : bookmark as ChatMessageBookmark?,
      pinned: pinned ?? this.pinned,
    );
  }
}

/// 消息列表响应(GET /chat/api/channels/:id/messages)
class ChatMessagesResponse {
  final List<ChatMessage> messages;
  final bool canLoadMorePast;
  final bool canLoadMoreFuture;
  final int? targetMessageId;

  const ChatMessagesResponse({
    required this.messages,
    required this.canLoadMorePast,
    required this.canLoadMoreFuture,
    this.targetMessageId,
  });

  factory ChatMessagesResponse.fromJson(
    Map<String, dynamic> json, {
    required int channelId,
  }) {
    final meta = json['meta'] as Map<String, dynamic>? ?? const {};
    return ChatMessagesResponse(
      messages: (json['messages'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((m) => ChatMessage.fromJson(m, fallbackChannelId: channelId))
          .toList(),
      canLoadMorePast: meta['can_load_more_past'] as bool? ?? false,
      canLoadMoreFuture: meta['can_load_more_future'] as bool? ?? false,
      targetMessageId: meta['target_message_id'] as int?,
    );
  }
}
