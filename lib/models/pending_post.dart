import '../utils/time_utils.dart';

/// 待审核内容(NewPostManager 拦截进审核队列的帖子/主题)
///
/// 单模型覆盖三种序列化形态:
/// 1. topic.json 的 `pending_posts`(TopicPendingPostSerializer):
///    `{id, raw?, created_at}` —— 仅发帖人自己可见
/// 2. GET /posts/{username}/pending.json(PendingPostSerializer):
///    `{id, raw_text, title, topic_id, category_id, created_at, ...}`
/// 3. 发帖 enqueued 响应的 `pending_post`(同 1 的序列化器)
///
/// [id] 是服务端 Reviewable(ReviewableQueuedPost)的 id,
/// 撤回走 DELETE /review/{id}。
class PendingPost {
  final int id;

  /// 原始 Markdown。形态 1/3 在 `raw`,形态 2 在 `raw_text`
  final String raw;

  /// 仅形态 2 返回:新主题 = payload.title,回复 = 所在主题标题
  final String? title;

  /// null = 待审的新主题(主题尚未创建);非 null = 某主题下的待审回复
  final int? topicId;

  final int? categoryId;
  final DateTime? createdAt;

  const PendingPost({
    required this.id,
    required this.raw,
    this.title,
    this.topicId,
    this.categoryId,
    this.createdAt,
  });

  /// 是否为待审的新主题(而非回复)
  bool get isNewTopic => topicId == null;

  factory PendingPost.fromJson(Map<String, dynamic> json) {
    return PendingPost(
      id: json['id'] as int,
      raw: (json['raw'] ?? json['raw_text']) as String? ?? '',
      title: json['title'] as String?,
      topicId: json['topic_id'] as int?,
      categoryId: json['category_id'] as int?,
      createdAt: TimeUtils.parseUtcTime(json['created_at'] as String?),
    );
  }
}
