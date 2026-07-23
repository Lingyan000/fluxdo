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

/// 待审回复的「回复目标楼层」会话级补记(reviewableId → replyToPostNumber)。
///
/// 服务端 payload 里存着 reply_to_post_number(new_post_manager.rb enqueue),
/// 审核通过时回复关系不丢;但发帖人本人可见的所有序列化形态
/// (TopicPendingPostSerializer / PendingPostSerializer)都不吐这个字段,
/// 唯一会吐的 ReviewableQueuedPostSerializer 走 GET /review/:id,
/// Reviewable.viewable_by 只放行 staff/分类版主 —— 本人无权访问。
///
/// 所以「撤回并重新编辑」要恢复回复关系,只能趁送审当下 composer 还知道
/// 上下文时记一笔。注册表按 reviewable id 直寻址,横跨话题详情整刷存活;
/// 杀进程后丢失(冷场景),此时回复目标未知,UI 需提示用户会退化为直接回复话题。
class PendingReplyTargetRegistry {
  PendingReplyTargetRegistry._();

  /// value 为 null = 送审时就是直接回复话题(与「未记录」语义不同)
  static final Map<int, int?> _targets = {};

  /// 送审当下记录回复目标(null 也要记,表示"确认是直接回复话题")
  static void record(int reviewableId, int? replyToPostNumber) {
    _targets[reviewableId] = replyToPostNumber;
  }

  /// 是否记录过该待审项的送审上下文;false = 冷场景,回复目标未知
  static bool contains(int reviewableId) => _targets.containsKey(reviewableId);

  static int? lookup(int reviewableId) => _targets[reviewableId];

  /// 撤回成功后清理(重新提交送审会以新 reviewable id 重新记录)
  static void remove(int reviewableId) => _targets.remove(reviewableId);
}
