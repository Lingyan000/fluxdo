// 草稿数据模型
import 'dart:convert';
import '../l10n/s.dart';
import '../utils/time_utils.dart';

/// 草稿操作类型
enum DraftAction {
  createTopic('create_topic'),
  reply('reply'),
  privateMessage('private_message');

  const DraftAction(this.value);
  final String value;

  static DraftAction fromString(String? value) {
    return DraftAction.values.firstWhere(
      (e) => e.value == value,
      orElse: () => DraftAction.reply,
    );
  }
}

/// 草稿内容数据
class DraftData {
  final String? reply; // 内容
  final String? title; // 标题（创建话题/私信时）
  final int? categoryId; // 分类 ID（创建话题时）
  final List<String>? tags; // 标签（创建话题时）
  final int? replyToPostNumber; // 回复的帖子编号
  final String? action; // 操作类型
  final List<String>? recipients; // 私信接收人（私信时）
  final String? archetypeId; // 'regular' 或 'private_message'
  final int? composerTime; // 编辑器打开时长（毫秒）
  final int? typingTime; // 输入时长（毫秒）

  const DraftData({
    this.reply,
    this.title,
    this.categoryId,
    this.tags,
    this.replyToPostNumber,
    this.action,
    this.recipients,
    this.archetypeId,
    this.composerTime,
    this.typingTime,
  });

  /// 从 JSON 解析
  factory DraftData.fromJson(Map<String, dynamic> json) {
    return DraftData(
      reply: json['reply'] as String?,
      title: json['title'] as String?,
      categoryId: json['categoryId'] as int?,
      tags: (json['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList(),
      replyToPostNumber: json['replyToPostNumber'] as int?,
      action: json['action'] as String?,
      recipients: (json['recipients'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList(),
      archetypeId: json['archetypeId'] as String?,
      composerTime: json['composerTime'] as int?,
      typingTime: json['typingTime'] as int?,
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (reply != null) json['reply'] = reply;
    if (title != null) json['title'] = title;
    if (categoryId != null) json['categoryId'] = categoryId;
    if (tags != null && tags!.isNotEmpty) json['tags'] = tags;
    if (replyToPostNumber != null) {
      json['replyToPostNumber'] = replyToPostNumber;
    }
    if (action != null) json['action'] = action;
    if (recipients != null && recipients!.isNotEmpty) {
      json['recipients'] = recipients;
    }
    if (archetypeId != null) json['archetypeId'] = archetypeId;
    if (composerTime != null) json['composerTime'] = composerTime;
    if (typingTime != null) json['typingTime'] = typingTime;
    return json;
  }

  /// 转换为 JSON 字符串
  String toJsonString() => jsonEncode(toJson());

  /// 是否有有效内容
  bool get hasContent {
    return (reply != null && reply!.trim().isNotEmpty) ||
        (title != null && title!.trim().isNotEmpty);
  }

  /// 复制并修改部分字段
  DraftData copyWith({
    String? reply,
    String? title,
    int? categoryId,
    List<String>? tags,
    int? replyToPostNumber,
    String? action,
    List<String>? recipients,
    String? archetypeId,
    int? composerTime,
    int? typingTime,
  }) {
    return DraftData(
      reply: reply ?? this.reply,
      title: title ?? this.title,
      categoryId: categoryId ?? this.categoryId,
      tags: tags ?? this.tags,
      replyToPostNumber: replyToPostNumber ?? this.replyToPostNumber,
      action: action ?? this.action,
      recipients: recipients ?? this.recipients,
      archetypeId: archetypeId ?? this.archetypeId,
      composerTime: composerTime ?? this.composerTime,
      typingTime: typingTime ?? this.typingTime,
    );
  }
}

/// 完整的草稿对象
class Draft {
  final String draftKey;
  final DraftData data;
  final int sequence; // 序列号（用于乐观锁）

  // 草稿列表 API 返回的额外信息
  final String? title; // 话题标题（回复草稿时）
  final String? excerpt; // 内容摘要
  final DateTime? updatedAt; // 更新时间
  final String? username; // 用户名
  final String? avatarTemplate; // 头像模板
  final int? topicId; // 话题 ID

  const Draft({
    required this.draftKey,
    required this.data,
    this.sequence = 0,
    this.title,
    this.excerpt,
    this.updatedAt,
    this.username,
    this.avatarTemplate,
    this.topicId,
  });

  /// 从 API 响应解析
  factory Draft.fromJson(Map<String, dynamic> json) {
    // 解析 data 字段，可能是 String（需要 JSON 解码）或 Map
    DraftData data;
    final rawData = json['data'];
    if (rawData is String) {
      try {
        data = DraftData.fromJson(jsonDecode(rawData) as Map<String, dynamic>);
      } catch (_) {
        data = const DraftData();
      }
    } else if (rawData is Map<String, dynamic>) {
      data = DraftData.fromJson(rawData);
    } else {
      data = const DraftData();
    }

    // 解析 topic_id：可能来自 draft_key 或直接字段
    int? topicId = json['topic_id'] as int?;
    final draftKey = json['draft_key'] as String? ?? '';
    if (topicId == null && draftKey.startsWith('topic_')) {
      topicId = int.tryParse(draftKey.replaceFirst('topic_', ''));
    }

    return Draft(
      draftKey: draftKey,
      data: data,
      sequence: json['draft_sequence'] as int? ?? json['sequence'] as int? ?? 0,
      title: json['title'] as String?,
      excerpt: json['excerpt'] as String?,
      updatedAt:
          TimeUtils.parseUtcTime(json['updated_at'] as String?) ??
          TimeUtils.parseUtcTime(json['created_at'] as String?),
      username: json['username'] as String?,
      avatarTemplate: json['avatar_template'] as String?,
      topicId: topicId,
    );
  }

  /// 是否有有效内容
  bool get hasContent => data.hasContent;

  /// 获取显示标题
  String get displayTitle {
    // 优先使用草稿列表返回的话题标题
    if (title != null && title!.isNotEmpty) return title!;
    // 其次使用草稿数据中的标题（新话题/私信）
    if (data.title != null && data.title!.isNotEmpty) return data.title!;
    // 回复草稿没有标题时显示话题 ID
    if (draftKey.startsWith('topic_')) {
      return S.current.draft_topicTitle(draftKey.replaceFirst('topic_', ''));
    }
    return S.current.draft_untitled;
  }

  /// 复制并修改部分字段
  Draft copyWith({
    String? draftKey,
    DraftData? data,
    int? sequence,
    String? title,
    String? excerpt,
    DateTime? updatedAt,
    String? username,
    String? avatarTemplate,
    int? topicId,
  }) {
    return Draft(
      draftKey: draftKey ?? this.draftKey,
      data: data ?? this.data,
      sequence: sequence ?? this.sequence,
      title: title ?? this.title,
      excerpt: excerpt ?? this.excerpt,
      updatedAt: updatedAt ?? this.updatedAt,
      username: username ?? this.username,
      avatarTemplate: avatarTemplate ?? this.avatarTemplate,
      topicId: topicId ?? this.topicId,
    );
  }

  // === 草稿 Key 生成方法 ===

  /// 新话题草稿 Key
  static const String newTopicKey = 'new_topic';

  /// 新私信草稿 Key
  static const String newPrivateMessageKey = 'new_private_message';

  /// 判断是否是新话题草稿 Key。
  ///
  /// Discourse 网页端可能为新话题草稿生成带后缀的 key，例如
  /// `new_topic_xxxxx`，不能只按固定的 `new_topic` 判断。
  static bool isNewTopicKey(String draftKey) {
    return draftKey == newTopicKey || draftKey.startsWith('${newTopicKey}_');
  }

  /// 是否是新话题草稿。
  bool get isNewTopicDraft {
    if (isNewTopicKey(draftKey)) return true;

    final action = data.action;
    return draftKey.isNotEmpty &&
        draftKey != newPrivateMessageKey &&
        !draftKey.startsWith('topic_') &&
        (action == 'createTopic' || action == DraftAction.createTopic.value);
  }

  /// 话题回复草稿 Key（回复话题本身）
  static String topicReplyKey(int topicId) => 'topic_$topicId';

  /// 帖子回复草稿 Key（回复某个帖子）
  static String postReplyKey(int topicId, int postNumber) =>
      'topic_${topicId}_post_$postNumber';

  /// 根据参数生成回复草稿 Key
  static String replyKey(int topicId, {int? replyToPostNumber}) {
    if (replyToPostNumber != null && replyToPostNumber > 0) {
      return postReplyKey(topicId, replyToPostNumber);
    }
    return topicReplyKey(topicId);
  }

  /// 判断是否是帖子回复草稿
  bool get isPostReply => draftKey.contains('_post_');

  /// 从草稿 key 解析帖子编号（仅帖子回复草稿有效）
  int? get replyToPostNumberFromKey {
    if (!isPostReply) return null;
    final match = RegExp(r'_post_(\d+)$').firstMatch(draftKey);
    return match != null ? int.tryParse(match.group(1)!) : null;
  }
}

/// 草稿列表响应
class DraftListResponse {
  final List<Draft> drafts;
  final bool hasMore;

  const DraftListResponse({required this.drafts, this.hasMore = false});

  factory DraftListResponse.fromJson(Map<String, dynamic> json) {
    final draftsJson = json['drafts'] as List<dynamic>? ?? [];
    return DraftListResponse(
      drafts: draftsJson
          .map((e) => Draft.fromJson(e as Map<String, dynamic>))
          .toList(),
      hasMore: json['has_more'] as bool? ?? false,
    );
  }
}
