import '../../utils/time_utils.dart';
import 'chat_user.dart';

/// 消息串预览（对齐 Discourse Chat::ThreadPreviewSerializer）
class ChatThreadPreview {
  final int replyCount;
  final int? lastReplyId;
  final String? lastReplyExcerpt;
  final DateTime? lastReplyCreatedAt;
  final ChatUser? lastReplyUser;
  final int? participantCount;
  final List<ChatUser> participantUsers;

  const ChatThreadPreview({
    this.replyCount = 0,
    this.lastReplyId,
    this.lastReplyExcerpt,
    this.lastReplyCreatedAt,
    this.lastReplyUser,
    this.participantCount,
    this.participantUsers = const [],
  });

  factory ChatThreadPreview.fromJson(Map<String, dynamic> json) {
    return ChatThreadPreview(
      replyCount: (json['reply_count'] as num?)?.toInt() ?? 0,
      lastReplyId: (json['last_reply_id'] as num?)?.toInt(),
      lastReplyExcerpt: json['last_reply_excerpt']?.toString(),
      lastReplyCreatedAt:
          TimeUtils.parseUtcTime(json['last_reply_created_at']?.toString()),
      lastReplyUser: json['last_reply_user'] is Map
          ? ChatUser.fromJson(
              Map<String, dynamic>.from(json['last_reply_user'] as Map),
            )
          : null,
      participantCount: (json['participant_count'] as num?)?.toInt(),
      participantUsers: (json['participant_users'] as List?)
              ?.whereType<Map>()
              .map((e) => ChatUser.fromJson(Map<String, dynamic>.from(e)))
              .toList() ??
          const [],
    );
  }
}

/// 消息串原消息摘要（列表接口 ThreadOriginalMessageSerializer）
///
/// 不复用完整 ChatMessage，避免与 chat_message 循环依赖。
class ChatThreadOriginalMessage {
  final int id;
  final String message;
  final String? cooked;
  final String? excerpt;
  final DateTime? createdAt;
  final int? chatChannelId;
  final ChatUser? user;

  const ChatThreadOriginalMessage({
    required this.id,
    required this.message,
    this.cooked,
    this.excerpt,
    this.createdAt,
    this.chatChannelId,
    this.user,
  });

  factory ChatThreadOriginalMessage.fromJson(Map<String, dynamic> json) {
    return ChatThreadOriginalMessage(
      id: (json['id'] as num?)?.toInt() ?? 0,
      message: json['message']?.toString() ?? '',
      cooked: json['cooked']?.toString(),
      excerpt: json['excerpt']?.toString(),
      createdAt: TimeUtils.parseUtcTime(json['created_at']?.toString()),
      chatChannelId: (json['chat_channel_id'] as num?)?.toInt(),
      user: json['user'] is Map
          ? ChatUser.fromJson(Map<String, dynamic>.from(json['user'] as Map))
          : null,
    );
  }

  /// 转成 ChatMessage 需要的最小字段 map，供气泡复用
  Map<String, dynamic> toMessageJson() => {
        'id': id,
        'message': message,
        if (cooked != null) 'cooked': cooked,
        if (createdAt != null) 'created_at': createdAt!.toUtc().toIso8601String(),
        if (chatChannelId != null) 'chat_channel_id': chatChannelId,
        if (user != null) 'user': user!.toJson(),
      };
}

/// 消息串（对齐 Discourse Chat::ThreadSerializer）
class ChatThread {
  final int id;
  final String? title;
  final String? status;
  final int channelId;
  final int replyCount;
  final int? lastMessageId;
  final bool force;
  final ChatThreadPreview? preview;
  final ChatThreadOriginalMessage? originalMessage;

  const ChatThread({
    required this.id,
    this.title,
    this.status,
    required this.channelId,
    this.replyCount = 0,
    this.lastMessageId,
    this.force = false,
    this.preview,
    this.originalMessage,
  });

  factory ChatThread.fromJson(Map<String, dynamic> json) {
    final previewJson = json['preview'];
    ChatThreadOriginalMessage? original;
    if (json['original_message'] is Map) {
      try {
        original = ChatThreadOriginalMessage.fromJson(
          Map<String, dynamic>.from(json['original_message'] as Map),
        );
      } catch (_) {}
    }
    return ChatThread(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: json['title']?.toString(),
      status: json['status']?.toString(),
      channelId: (json['channel_id'] as num?)?.toInt() ??
          (json['channel'] is Map
              ? ((json['channel'] as Map)['id'] as num?)?.toInt()
              : null) ??
          0,
      replyCount: (json['reply_count'] as num?)?.toInt() ??
          (previewJson is Map
              ? (previewJson['reply_count'] as num?)?.toInt()
              : null) ??
          0,
      lastMessageId: (json['last_message_id'] as num?)?.toInt(),
      force: json['force'] as bool? ?? false,
      preview: previewJson is Map
          ? ChatThreadPreview.fromJson(
              Map<String, dynamic>.from(previewJson),
            )
          : null,
      originalMessage: original,
    );
  }

  /// 列表标题：优先自定义 title，否则用原消息摘要/正文
  String get displayTitle {
    if (title != null && title!.trim().isNotEmpty) return title!.trim();
    final om = originalMessage;
    if (om == null) return '消息串';
    final text = (om.excerpt ?? om.message).trim();
    if (text.isEmpty) return '消息串 #$id';
    return text.length > 48 ? '${text.substring(0, 48)}…' : text;
  }

  /// 指示器是否应显示（对齐 Discourse showThreadIndicator）
  bool get hasVisibleReplies {
    final count = preview?.replyCount ?? replyCount;
    return count > 0;
  }

  ChatThread copyWith({
    int? id,
    String? title,
    String? status,
    int? channelId,
    int? replyCount,
    int? lastMessageId,
    bool? force,
    ChatThreadPreview? preview,
    ChatThreadOriginalMessage? originalMessage,
  }) {
    return ChatThread(
      id: id ?? this.id,
      title: title ?? this.title,
      status: status ?? this.status,
      channelId: channelId ?? this.channelId,
      replyCount: replyCount ?? this.replyCount,
      lastMessageId: lastMessageId ?? this.lastMessageId,
      force: force ?? this.force,
      preview: preview ?? this.preview,
      originalMessage: originalMessage ?? this.originalMessage,
    );
  }
}
