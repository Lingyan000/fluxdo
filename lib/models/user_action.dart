// 用户操作记录
import 'package:fluxdo/utils/avatar_url.dart';

import '../utils/time_utils.dart';
import 'topic.dart';

/// 活动中的帖子作者与发起点赞、回应的用户是两个身份。
TopicUser? _readPostAuthor(Map<String, dynamic>? post) {
  if (post == null) return null;
  final embeddedUser = post['user'] as Map<String, dynamic>?;
  final user = embeddedUser ?? post;
  final username = user['username'] as String?;
  if (username == null || username.isEmpty) return null;
  return TopicUser(
    id: (embeddedUser?['id'] ?? post['user_id']) as int? ?? 0,
    username: username,
    name: user['name'] as String?,
    avatarTemplate: user['avatar_template'] as String? ?? '',
  );
}

TopicUser? _readUser(Map<String, dynamic>? user) {
  final username = user?['username'] as String?;
  if (username == null || username.isEmpty) return null;
  return TopicUser(
    id: user!['id'] as int? ?? 0,
    username: username,
    name: user['name'] as String?,
    avatarTemplate: user['avatar_template'] as String? ?? '',
  );
}

/// 用户操作类型
class UserActionType {
  static const int like = 1; // 点赞
  static const int wasLiked = 2; // 被点赞
  static const int newTopic = 4; // 创建话题
  static const int reply = 5; // 回复
  static const int response = 6; // 被回复
  static const int mention = 7; // 被提及
  static const int quote = 9; // 被引用
  static const int edit = 11; // 帖子被编辑
  static const int linked = 17; // 帖子被链接
}

class UserAction {
  final int? actionType;
  final int topicId;
  final String title;
  final String? slug;
  final int? postNumber;
  final String? username;
  final String? actingName;
  final String? avatarTemplate;
  final DateTime? actingAt;
  final int? categoryId;
  final String? excerpt;
  final TopicUser? author;

  const UserAction({
    this.actionType,
    required this.topicId,
    required this.title,
    this.slug,
    this.postNumber,
    this.username,
    this.actingName,
    this.avatarTemplate,
    this.actingAt,
    this.categoryId,
    this.excerpt,
    this.author,
  });

  factory UserAction.fromJson(Map<String, dynamic> json) {
    return UserAction(
      actionType: json['action_type'] as int?,
      topicId: json['topic_id'] as int,
      title: json['title'] as String? ?? '',
      slug: json['slug'] as String?,
      postNumber: json['post_number'] as int?,
      username:
          json['acting_username'] as String? ?? json['username'] as String?,
      actingName: json['acting_name'] as String? ?? json['name'] as String?,
      avatarTemplate:
          json['acting_avatar_template'] as String? ??
          json['avatar_template'] as String?,
      actingAt: TimeUtils.parseUtcTime(
        json['acting_at'] as String? ?? json['created_at'] as String?,
      ),
      categoryId: json['category_id'] as int?,
      excerpt: json['excerpt'] as String?,
      author: _readPostAuthor(json),
    );
  }

  /// 列表去重键。同一帖子可能有多人动作（如多人点赞），需带上动作者。
  String get dedupeKey => '${topicId}_${postNumber}_${actionType}_$username';

  /// 发起这条动作的用户（点赞人、回复人等），缺字段时为 null。
  TopicUser? get actor {
    final name = username;
    if (name == null || name.isEmpty) return null;
    return TopicUser(
      id: 0,
      username: name,
      name: actingName,
      avatarTemplate: avatarTemplate ?? '',
    );
  }

  String getAvatarUrl({int size = 120}) {
    if (avatarTemplate == null) return '';
    return AvatarUrl.resolve(avatarTemplate!, size: size);
  }
}

class UserActionResponse {
  final List<UserAction> actions;

  const UserActionResponse({required this.actions});

  factory UserActionResponse.fromJson(Map<String, dynamic> json) {
    final actionsJson = json['user_actions'] as List<dynamic>? ?? [];
    return UserActionResponse(
      actions: actionsJson
          .map((e) => UserAction.fromJson(e as Map<String, dynamic>))
          .toList(),
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
  final TopicUser? author;

  /// 做出回应的用户；收到的回应里是对方，发出的回应里是本人。
  final TopicUser? actor;
  final int? categoryId;

  const UserReaction({
    required this.id,
    required this.postId,
    required this.topicId,
    this.postNumber,
    this.topicTitle,
    this.excerpt,
    this.reactionValue,
    this.createdAt,
    this.author,
    this.actor,
    this.categoryId,
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
      author: _readPostAuthor(post),
      actor: _readUser(json['user'] as Map<String, dynamic>?),
      categoryId: post?['category_id'] as int?,
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
        reactions: json
            .map((e) => UserReaction.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
    }
    // 如果是对象包装的数组
    if (json is Map<String, dynamic>) {
      final list =
          json['reactions'] as List<dynamic>? ??
          json['posts'] as List<dynamic>? ??
          [];
      return UserReactionsResponse(
        reactions: list
            .map((e) => UserReaction.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
    }
    return const UserReactionsResponse(reactions: []);
  }
}

/// 用户发出的 Boost 记录（discourse-boosts 插件）
class UserBoost {
  final int id;
  final int postId;
  final int topicId;
  final int? postNumber;
  final String? topicTitle;
  final String? excerpt;
  final String cooked;
  final DateTime? createdAt;
  final TopicUser? author;

  /// Boost 的人；收到的 Boost 里是对方，发出的 Boost 里是本人。
  final TopicUser? booster;
  final int? categoryId;

  const UserBoost({
    required this.id,
    required this.postId,
    required this.topicId,
    this.postNumber,
    this.topicTitle,
    this.excerpt,
    required this.cooked,
    this.createdAt,
    this.author,
    this.booster,
    this.categoryId,
  });

  factory UserBoost.fromJson(Map<String, dynamic> json) {
    final post = json['post'] as Map<String, dynamic>?;

    // 序列化器不含 post_number，从 post.url（/t/slug/{topic_id}/{post_number}）尾段解析
    int? postNumber;
    final url = post?['url'] as String?;
    if (url != null) {
      final segments = Uri.parse(url).pathSegments
          .where((s) => s.isNotEmpty)
          .toList();
      if (segments.length >= 4) {
        postNumber = int.tryParse(segments.last);
      }
    }

    return UserBoost(
      id: json['id'] as int,
      postId: json['post_id'] as int? ?? post?['id'] as int? ?? 0,
      topicId: post?['topic_id'] as int? ?? 0,
      postNumber: postNumber,
      topicTitle: post?['topic_title'] as String?,
      excerpt: post?['excerpt'] as String?,
      cooked: json['cooked'] as String? ?? '',
      createdAt: TimeUtils.parseUtcTime(json['created_at'] as String?),
      author: _readPostAuthor(post),
      booster: _readUser(json['user'] as Map<String, dynamic>?),
      categoryId: post?['category_id'] as int?,
    );
  }
}

class UserBoostsResponse {
  final List<UserBoost> boosts;

  const UserBoostsResponse({required this.boosts});

  factory UserBoostsResponse.fromJson(Map<String, dynamic> json) {
    final list = json['boosts'] as List<dynamic>? ?? [];
    return UserBoostsResponse(
      boosts: list
          .map((e) => UserBoost.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// 用户已解决（被采纳为答案）的帖子记录（discourse-solved 插件）
class SolvedPost {
  final int postId;
  final int topicId;
  final int? postNumber;
  final String? topicTitle;
  final String? excerpt;
  final DateTime? createdAt;
  final TopicUser? author;
  final int? categoryId;

  const SolvedPost({
    required this.postId,
    required this.topicId,
    this.postNumber,
    this.topicTitle,
    this.excerpt,
    this.createdAt,
    this.author,
    this.categoryId,
  });

  factory SolvedPost.fromJson(Map<String, dynamic> json) {
    return SolvedPost(
      postId: json['post_id'] as int? ?? 0,
      topicId: json['topic_id'] as int? ?? 0,
      postNumber: json['post_number'] as int?,
      topicTitle: json['topic_title'] as String?,
      excerpt: json['excerpt'] as String?,
      createdAt: TimeUtils.parseUtcTime(json['created_at'] as String?),
      author: _readPostAuthor(json),
      categoryId: json['category_id'] as int?,
    );
  }
}

class SolvedPostsResponse {
  final List<SolvedPost> posts;

  const SolvedPostsResponse({required this.posts});

  factory SolvedPostsResponse.fromJson(Map<String, dynamic> json) {
    final list = json['user_solved_posts'] as List<dynamic>? ?? [];
    return SolvedPostsResponse(
      posts: list
          .map((e) => SolvedPost.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
