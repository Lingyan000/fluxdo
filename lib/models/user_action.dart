// 用户操作记录
import '../utils/time_utils.dart';
import '../utils/url_helper.dart';

/// 用户操作类型
class UserActionType {
  static const int like = 1;        // 点赞
  static const int wasLiked = 2;    // 被点赞
  static const int newTopic = 4;    // 创建话题
  static const int reply = 5;       // 回复
}

class UserAction {
  final int? actionType;
  final int topicId;
  final String title;
  final String? slug;
  final int? postNumber;
  final String? username;
  final String? avatarTemplate;
  final DateTime? actingAt;
  final int? categoryId;
  final String? excerpt;

  const UserAction({
    this.actionType,
    required this.topicId,
    required this.title,
    this.slug,
    this.postNumber,
    this.username,
    this.avatarTemplate,
    this.actingAt,
    this.categoryId,
    this.excerpt,
  });

  factory UserAction.fromJson(Map<String, dynamic> json) {
    return UserAction(
      actionType: json['action_type'] as int?,
      topicId: json['topic_id'] as int,
      title: json['title'] as String? ?? '',
      slug: json['slug'] as String?,
      postNumber: json['post_number'] as int?,
      username: json['acting_username'] as String? ?? json['username'] as String?,
      avatarTemplate: json['acting_avatar_template'] as String? ?? json['avatar_template'] as String?,
      actingAt: TimeUtils.parseUtcTime(json['acting_at'] as String? ?? json['created_at'] as String?),
      categoryId: json['category_id'] as int?,
      excerpt: json['excerpt'] as String?,
    );
  }

  String getAvatarUrl({int size = 120}) {
    return UrlHelper.resolveAvatarUrl(avatarTemplate: avatarTemplate, size: size);
  }
}

class UserActionResponse {
  final List<UserAction> actions;

  const UserActionResponse({required this.actions});

  factory UserActionResponse.fromJson(Map<String, dynamic> json) {
    final actionsJson = json['user_actions'] as List<dynamic>? ?? [];
    return UserActionResponse(
      actions: actionsJson.map((e) => UserAction.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }
}

/// 用户回应记录（discourse-reactions 插件）
class UserReaction {
  final int id;
  final int postId;
  final int topicId;
  final int? postNumber;
  final String? topicTitle;
  final String? excerpt;
  final String? reactionValue;
  final DateTime? createdAt;

  const UserReaction({
    required this.id,
    required this.postId,
    required this.topicId,
    this.postNumber,
    this.topicTitle,
    this.excerpt,
    this.reactionValue,
    this.createdAt,
  });

  factory UserReaction.fromJson(Map<String, dynamic> json) {
    final post = json['post'] as Map<String, dynamic>?;
    final reaction = json['reaction'] as Map<String, dynamic>?;

    return UserReaction(
      id: json['id'] as int,
      postId: json['post_id'] as int,
      topicId: post?['topic_id'] as int? ?? 0,
      postNumber: post?['post_number'] as int?,
      topicTitle: post?['topic_title'] as String?,
      excerpt: post?['excerpt'] as String?,
      reactionValue: reaction?['reaction_value'] as String?,
      createdAt: TimeUtils.parseUtcTime(json['created_at'] as String?),
    );
  }
}

class UserReactionsResponse {
  final List<UserReaction> reactions;

  const UserReactionsResponse({required this.reactions});

  factory UserReactionsResponse.fromJson(dynamic json) {
    // API 直接返回数组
    if (json is List) {
      return UserReactionsResponse(
        reactions: json.map((e) => UserReaction.fromJson(e as Map<String, dynamic>)).toList(),
      );
    }
    // 如果是对象包装的数组
    if (json is Map<String, dynamic>) {
      final list = json['reactions'] as List<dynamic>? ?? json['posts'] as List<dynamic>? ?? [];
      return UserReactionsResponse(
        reactions: list.map((e) => UserReaction.fromJson(e as Map<String, dynamic>)).toList(),
      );
    }
    return const UserReactionsResponse(reactions: []);
  }
}
