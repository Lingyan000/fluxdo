import '../../utils/time_utils.dart';
import 'chat_thread.dart';
import 'chat_user.dart';

/// Chat 消息的回应（Reaction）数据模型
class ChatMessageReaction {
  final String emoji;
  final int count;
  final bool reacted;
  final List<ChatUser>? users;

  const ChatMessageReaction({
    required this.emoji,
    required this.count,
    this.reacted = false,
    this.users,
  });

  factory ChatMessageReaction.fromJson(Map<String, dynamic> json) {
    return ChatMessageReaction(
      emoji: json['emoji']?.toString() ?? json['id']?.toString() ?? '',
      count: (json['count'] as num?)?.toInt() ?? 1,
      reacted:
          json['reacted'] as bool? ?? json['user_reacted'] as bool? ?? false,
      users: (json['users'] as List?)
          ?.map((e) => ChatUser.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'emoji': emoji,
    'count': count,
    'reacted': reacted,
    if (users != null) 'users': users!.map((u) => u.toJson()).toList(),
  };
}

/// Chat 消息数据模型
class ChatMessage {
  final int id;
  final String message;
  final String? cooked;
  final DateTime createdAt;
  final int chatChannelId;
  final ChatUser? user;
  final int? inReplyToId;

  /// 消息摘要（Discourse excerpt，用于 in_reply_to 预览）
  final String? excerpt;

  /// Discourse 嵌套的被回复消息摘要（可能不在当前消息窗口内）。
  /// 仅作预览；完整消息以列表内查找结果为准。
  final ChatMessage? inReplyTo;
  final int? threadId;

  /// 消息串元数据（仅原消息/OM 会带完整 thread 对象）
  final ChatThread? thread;

  /// 非原消息时服务端可能只下发 thread_title
  final String? threadTitle;
  final List<Map<String, dynamic>>? uploads;
  final List<ChatMessageReaction>? reactions;
  final bool edited;
  final bool deleted;
  final DateTime? deletedAt;
  final int? deletedById;
  final bool bookmarked;

  /// Discourse 书签 ID（删除书签时需要）
  final int? bookmarkId;

  /// 是否置顶（需站点开启 chat_pinned_messages）
  final bool pinned;

  /// 服务端下发的可用举报类型符号列表（如 off_topic / spam）
  final List<String>? availableFlags;

  const ChatMessage({
    required this.id,
    required this.message,
    this.cooked,
    required this.createdAt,
    required this.chatChannelId,
    this.user,
    this.inReplyToId,
    this.inReplyTo,
    this.threadId,
    this.thread,
    this.threadTitle,
    this.uploads,
    this.reactions,
    this.edited = false,
    this.deleted = false,
    this.deletedAt,
    this.deletedById,
    this.bookmarked = false,
    this.bookmarkId,
    this.pinned = false,
    this.availableFlags,
    this.excerpt,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    // Discourse message serializer 在有书签时返回 bookmark 对象（含 id）
    final bookmarkObj = json['bookmark'] is Map
        ? Map<String, dynamic>.from(json['bookmark'] as Map)
        : null;
    final parsedBookmarkId =
        (bookmarkObj?['id'] as num?)?.toInt() ??
        (json['bookmark_id'] as num?)?.toInt();

    // 嵌套 in_reply_to 只解析一层，避免循环引用
    ChatMessage? nestedReply;
    if (json['in_reply_to'] is Map) {
      final replyJson = Map<String, dynamic>.from(json['in_reply_to'] as Map);
      // 去掉更深一层的 in_reply_to，防止无限递归
      replyJson.remove('in_reply_to');
      nestedReply = ChatMessage.fromJson(replyJson);
    }

    ChatThread? thread;
    if (json['thread'] is Map) {
      thread = ChatThread.fromJson(
        Map<String, dynamic>.from(json['thread'] as Map),
      );
    }

    return ChatMessage(
      id: (json['id'] as num?)?.toInt() ?? 0,
      message: json['message']?.toString() ?? '',
      cooked: json['cooked']?.toString(),
      createdAt:
          TimeUtils.parseUtcTime(json['created_at']?.toString()) ??
          DateTime.now(),
      chatChannelId: (json['chat_channel_id'] as num?)?.toInt() ?? 0,
      user: json['user'] is Map
          ? ChatUser.fromJson(Map<String, dynamic>.from(json['user'] as Map))
          : null,
      // Discourse 序列化的是嵌套 in_reply_to 对象，不一定带顶层 in_reply_to_id
      inReplyToId: (json['in_reply_to_id'] as num?)?.toInt() ?? nestedReply?.id,
      inReplyTo: nestedReply,
      threadId: (json['thread_id'] as num?)?.toInt() ?? thread?.id,
      thread: thread,
      threadTitle: json['thread_title']?.toString() ?? thread?.title,
      uploads: (json['uploads'] as List?)
          ?.map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      reactions: (json['reactions'] as List?)
          ?.map(
            (e) => ChatMessageReaction.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList(),
      edited: json['edited'] as bool? ?? false,
      // Discourse 用 deleted_at 表示删除，没有单独的 deleted 布尔字段
      deleted: json['deleted'] as bool? ?? json['deleted_at'] != null,
      deletedAt: json['deleted_at'] != null
          ? TimeUtils.parseUtcTime(json['deleted_at']?.toString())
          : null,
      deletedById: (json['deleted_by_id'] as num?)?.toInt(),
      bookmarked:
          (json['bookmarked'] as bool?) ??
          (bookmarkObj != null || parsedBookmarkId != null),
      bookmarkId: parsedBookmarkId,
      pinned: json['pinned'] as bool? ?? false,
      availableFlags: (json['available_flags'] as List?)
          ?.map((e) => e.toString())
          .toList(),
      excerpt: json['excerpt']?.toString(),
    );
  }

  ChatMessage copyWith({
    int? id,
    String? message,
    String? cooked,
    DateTime? createdAt,
    int? chatChannelId,
    ChatUser? user,
    int? inReplyToId,
    ChatMessage? inReplyTo,
    int? threadId,
    ChatThread? thread,
    String? threadTitle,
    List<Map<String, dynamic>>? uploads,
    List<ChatMessageReaction>? reactions,
    bool? edited,
    bool? deleted,
    DateTime? deletedAt,
    int? deletedById,
    bool? bookmarked,
    int? bookmarkId,
    bool clearBookmarkId = false,
    bool? pinned,
    List<String>? availableFlags,
    String? excerpt,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      message: message ?? this.message,
      cooked: cooked ?? this.cooked,
      createdAt: createdAt ?? this.createdAt,
      chatChannelId: chatChannelId ?? this.chatChannelId,
      user: user ?? this.user,
      inReplyToId: inReplyToId ?? this.inReplyToId,
      inReplyTo: inReplyTo ?? this.inReplyTo,
      threadId: threadId ?? this.threadId,
      thread: thread ?? this.thread,
      threadTitle: threadTitle ?? this.threadTitle,
      uploads: uploads ?? this.uploads,
      reactions: reactions ?? this.reactions,
      edited: edited ?? this.edited,
      deleted: deleted ?? this.deleted,
      deletedAt: deletedAt ?? this.deletedAt,
      deletedById: deletedById ?? this.deletedById,
      bookmarked: bookmarked ?? this.bookmarked,
      bookmarkId: clearBookmarkId ? null : (bookmarkId ?? this.bookmarkId),
      pinned: pinned ?? this.pinned,
      availableFlags: availableFlags ?? this.availableFlags,
      excerpt: excerpt ?? this.excerpt,
    );
  }
}
