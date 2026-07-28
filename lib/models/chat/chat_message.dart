import '../mention_user.dart';
import '../../utils/time_utils.dart';

/// Chat 插件消息里的发送者，字段和 MentionUser 一致，直接复用其解析逻辑
typedef ChatMessageUser = MentionUser;

/// 消息上的一个表情回应聚合(同一 emoji 的所有人合并成一条)。核对过
/// Discourse 源码 `Chat::MessageSerializer#reactions`:按 emoji 分组,
/// `reacted` 是当前用户是否在其中。
class ChatReaction {
  final String emoji;
  final int count;
  final bool reacted;

  const ChatReaction({
    required this.emoji,
    required this.count,
    required this.reacted,
  });

  factory ChatReaction.fromJson(Map<String, dynamic> json) {
    return ChatReaction(
      emoji: json['emoji'] as String,
      count: json['count'] as int? ?? 0,
      reacted: json['reacted'] as bool? ?? false,
    );
  }
}

/// 被回复消息的摘要(`Chat::InReplyToSerializer`:id/cooked/excerpt/user)。
class ChatInReplyTo {
  final int id;
  final String? excerpt;
  final String? username;

  const ChatInReplyTo({required this.id, this.excerpt, this.username});

  factory ChatInReplyTo.fromJson(Map<String, dynamic> json) {
    final user = json['user'] as Map<String, dynamic>?;
    return ChatInReplyTo(
      id: json['id'] as int,
      excerpt: json['excerpt'] as String?,
      username: user?['username'] as String?,
    );
  }
}

/// 消息附带的上传文件(标准 `UploadSerializer`)。图片/附件**不在 cooked
/// 里**——官方 `Chat::MessageSerializer` 把 uploads 单独序列化,网页端也是
/// 在正文下方单独渲染的,不解析这个字段就永远"收不到图片"。
class ChatUpload {
  final int? id;
  final String url;
  final String? originalFilename;
  final String? extension;
  final int? width;
  final int? height;

  const ChatUpload({
    this.id,
    required this.url,
    this.originalFilename,
    this.extension,
    this.width,
    this.height,
  });

  factory ChatUpload.fromJson(Map<String, dynamic> json) {
    return ChatUpload(
      id: json['id'] as int?,
      url: json['url'] as String? ?? '',
      originalFilename: json['original_filename'] as String?,
      extension: json['extension'] as String?,
      width: json['width'] as int?,
      height: json['height'] as int?,
    );
  }

  bool get isImage => const {
        'png', 'jpg', 'jpeg', 'gif', 'webp', 'avif', 'bmp',
      }.contains(extension?.toLowerCase());
}

/// 消息串信息(线程原始消息上的 `thread` 字段,`Chat::ThreadSerializer`:
/// id/title/reply_count + preview.reply_count)。
class ChatThreadInfo {
  final int id;
  final String? title;
  final int replyCount;

  const ChatThreadInfo({required this.id, this.title, this.replyCount = 0});

  factory ChatThreadInfo.fromJson(Map<String, dynamic> json) {
    final preview = json['preview'] as Map<String, dynamic>?;
    return ChatThreadInfo(
      id: json['id'] as int,
      title: json['title'] as String?,
      replyCount: (preview?['reply_count'] ?? json['reply_count']) as int? ?? 0,
    );
  }
}

/// 消息上的书签(`Chat::MessageSerializer` 的 `bookmark` 字段,当前用户
/// 给这条消息加过书签才有)。
class ChatBookmark {
  final int id;
  final String? name;
  final DateTime? reminderAt;

  const ChatBookmark({required this.id, this.name, this.reminderAt});

  factory ChatBookmark.fromJson(Map<String, dynamic> json) {
    return ChatBookmark(
      id: json['id'] as int,
      name: json['name'] as String?,
      reminderAt: TimeUtils.parseUtcTime(json['reminder_at'] as String?),
    );
  }
}

/// Chat 插件的单条消息
class ChatMessage {
  final int id;
  final int channelId;
  final String? message;
  final String? cooked;
  final String? excerpt;
  final DateTime? createdAt;
  final DateTime? deletedAt;
  final int? threadId;
  final bool edited;
  final ChatMessageUser? user;
  final int? inReplyToId;
  final ChatInReplyTo? inReplyTo;
  final bool pinned;
  final List<ChatReaction> reactions;
  final List<ChatUpload> uploads;

  /// 搜索接口(include_channel)会附带所属频道的标题,普通消息流没有
  final String? channelTitle;

  /// 消息串:线程"原始消息"上带完整 thread 对象;线程内回复只带
  /// thread_id(+ thread_title)。
  final ChatThreadInfo? thread;
  final String? threadTitle;

  /// 当前用户给这条消息加的书签(没加过为 null)
  final ChatBookmark? bookmark;

  const ChatMessage({
    required this.id,
    required this.channelId,
    this.message,
    this.cooked,
    this.excerpt,
    this.createdAt,
    this.deletedAt,
    this.threadId,
    this.edited = false,
    this.user,
    this.inReplyToId,
    this.inReplyTo,
    this.pinned = false,
    this.reactions = const [],
    this.uploads = const [],
    this.channelTitle,
    this.thread,
    this.threadTitle,
    this.bookmark,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final inReplyTo = json['in_reply_to'] as Map<String, dynamic>?;
    final reactionsJson = json['reactions'] as List<dynamic>? ?? const [];
    return ChatMessage(
      id: json['id'] as int,
      channelId: json['chat_channel_id'] as int,
      message: json['message'] as String?,
      cooked: json['cooked'] as String?,
      excerpt: json['excerpt'] as String?,
      createdAt: TimeUtils.parseUtcTime(json['created_at'] as String?),
      deletedAt: TimeUtils.parseUtcTime(json['deleted_at'] as String?),
      threadId: json['thread_id'] as int?,
      edited: json['edited'] as bool? ?? false,
      user: json['user'] != null
          ? ChatMessageUser.fromJson(json['user'] as Map<String, dynamic>)
          : null,
      inReplyToId: inReplyTo?['id'] as int?,
      inReplyTo: inReplyTo != null ? ChatInReplyTo.fromJson(inReplyTo) : null,
      pinned: json['pinned'] as bool? ?? false,
      reactions: reactionsJson
          .map((e) => ChatReaction.fromJson(e as Map<String, dynamic>))
          .toList(),
      uploads: (json['uploads'] as List<dynamic>? ?? const [])
          .map((e) => ChatUpload.fromJson(e as Map<String, dynamic>))
          .toList(),
      channelTitle:
          (json['channel'] as Map<String, dynamic>?)?['title'] as String?,
      thread: json['thread'] is Map<String, dynamic>
          ? ChatThreadInfo.fromJson(json['thread'] as Map<String, dynamic>)
          : null,
      threadTitle: json['thread_title'] as String?,
      bookmark: json['bookmark'] is Map<String, dynamic>
          ? ChatBookmark.fromJson(json['bookmark'] as Map<String, dynamic>)
          : null,
    );
  }

  bool get isDeleted => deletedAt != null;

  ChatMessage copyWith({
    List<ChatReaction>? reactions,
    bool? pinned,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    ChatBookmark? bookmark,
    bool clearBookmark = false,
  }) {
    return ChatMessage(
      id: id,
      channelId: channelId,
      message: message,
      cooked: cooked,
      excerpt: excerpt,
      createdAt: createdAt,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
      threadId: threadId,
      edited: edited,
      user: user,
      inReplyToId: inReplyToId,
      inReplyTo: inReplyTo,
      pinned: pinned ?? this.pinned,
      reactions: reactions ?? this.reactions,
      uploads: uploads,
      channelTitle: channelTitle,
      thread: thread,
      threadTitle: threadTitle,
      bookmark: clearBookmark ? null : (bookmark ?? this.bookmark),
    );
  }

  ChatMessage copyWithReactions(List<ChatReaction> newReactions) =>
      copyWith(reactions: newReactions);
}
