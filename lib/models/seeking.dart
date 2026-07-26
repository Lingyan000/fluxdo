import 'user_action.dart';

/// 追觅动态类型
enum SeekingActivityType { post, reply, like, reaction, boost }

/// 追觅（监控用户动态）的统一动态条目。
///
/// 由 /user_actions.json（发帖/回复/点赞）、discourse-reactions、
/// discourse-boosts 三路数据归一化而来，按 createdAt 倒序合并。
class SeekingActivity {
  const SeekingActivity({
    required this.uid,
    required this.username,
    required this.type,
    required this.topicId,
    this.postNumber,
    required this.title,
    this.excerpt,
    this.reactionValue,
    this.createdAt,
  });

  /// 全局唯一 id（新增检测用）：action 用 topicId_postNumber，
  /// reaction/boost 用各自插件的自增 id。
  final String uid;

  /// 被监控用户名（动态的主体）
  final String username;

  final SeekingActivityType type;
  final int topicId;
  final int? postNumber;
  final String title;
  final String? excerpt;

  /// reaction 的表情值（如 heart / tieba_087）
  final String? reactionValue;

  final DateTime? createdAt;

  factory SeekingActivity.fromUserAction(String username, UserAction action) {
    final type = switch (action.actionType) {
      UserActionType.newTopic => SeekingActivityType.post,
      UserActionType.like => SeekingActivityType.like,
      _ => SeekingActivityType.reply,
    };
    return SeekingActivity(
      uid: '${action.topicId}_${action.postNumber ?? 1}_${action.actionType}',
      username: username,
      type: type,
      topicId: action.topicId,
      postNumber: action.postNumber,
      title: action.title,
      excerpt: action.excerpt,
      createdAt: action.actingAt,
    );
  }

  factory SeekingActivity.fromReaction(String username, UserReaction reaction) {
    return SeekingActivity(
      uid: 'reaction_${reaction.id}',
      username: username,
      type: SeekingActivityType.reaction,
      topicId: reaction.topicId,
      postNumber: reaction.postNumber,
      title: reaction.topicTitle ?? '',
      excerpt: reaction.excerpt,
      reactionValue: reaction.reactionValue,
      createdAt: reaction.createdAt,
    );
  }

  factory SeekingActivity.fromBoost(String username, UserBoost boost) {
    return SeekingActivity(
      uid: 'boost_${boost.id}',
      username: username,
      type: SeekingActivityType.boost,
      topicId: boost.topicId,
      // boost 链接可能没有楼层段（只 boost 话题本身），回退首楼
      postNumber: boost.postNumber ?? 1,
      title: boost.topicTitle ?? '',
      excerpt: boost.excerpt ?? boost.cooked,
      createdAt: boost.createdAt,
    );
  }
}

/// 被监控用户的轻量资料（两段式省请求的比较基准）。
class SeekingUserProfile {
  const SeekingUserProfile({this.lastSeenAt, this.avatarTemplate});

  final DateTime? lastSeenAt;
  final String? avatarTemplate;

  String getAvatarUrl({int size = 120}) {
    final template = avatarTemplate;
    if (template == null || template.isEmpty) return '';
    return template.replaceAll('{size}', '$size');
  }

  /// 值相等：provider 靠它判断「资料没变就不重建状态」，
  /// 避免每个轮询节拍都触发整页重建。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SeekingUserProfile &&
          other.lastSeenAt == lastSeenAt &&
          other.avatarTemplate == avatarTemplate;

  @override
  int get hashCode => Object.hash(lastSeenAt, avatarTemplate);
}
