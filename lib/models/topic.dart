// 帖子数据模型
import '../utils/time_utils.dart';
import '../utils/url_helper.dart';
import 'user.dart';

part 'topic/_post.dart';
part 'topic/_topic_detail.dart';

/// 标签模型
class Tag {
  final int? id;
  final String name;
  final String? slug;

  const Tag({
    this.id,
    required this.name,
    this.slug,
  });

  factory Tag.fromJson(dynamic json) {
    // 兼容新旧格式
    if (json is String) {
      // 旧格式：直接是字符串
      return Tag(name: json);
    } else if (json is Map<String, dynamic>) {
      // 新格式：对象格式
      return Tag(
        id: json['id'] as int?,
        name: json['name'] as String? ?? '',
        slug: json['slug'] as String?,
      );
    } else {
      // 降级处理
      return Tag(name: json.toString());
    }
  }

  @override
  String toString() => name;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Tag && other.name == name;
  }

  @override
  int get hashCode => name.hashCode;
}

/// 话题订阅级别
enum TopicNotificationLevel {
  muted(0, '静音', '不接收任何通知'),
  regular(1, '常规', '只在被 @ 提及或回复时通知'),
  tracking(2, '跟踪', '显示未读计数'),
  watching(3, '关注', '每个新回复都通知');

  const TopicNotificationLevel(this.value, this.label, this.description);
  final int value;
  final String label;
  final String description;

  static TopicNotificationLevel fromValue(int? value) {
    return TopicNotificationLevel.values.firstWhere(
      (e) => e.value == value,
      orElse: () => TopicNotificationLevel.regular,
    );
  }
}

/// 投票选项
class PollOption {
  final String id;
  final String html;
  final int votes;

  PollOption({required this.id, required this.html, required this.votes});

  factory PollOption.fromJson(Map<String, dynamic> json) {
    return PollOption(
      id: json['id'] as String? ?? '',
      html: json['html'] as String? ?? '',
      votes: json['votes'] as int? ?? 0,
    );
  }
}

/// 投票
class Poll {
  final int id;
  final String name;
  final String type;
  final String status;
  final String results;
  final List<PollOption> options;
  final int voters;

  Poll({
    required this.id,
    required this.name,
    required this.type,
    required this.status,
    required this.results,
    required this.options,
    required this.voters,
  });

  factory Poll.fromJson(Map<String, dynamic> json) {
    return Poll(
      id: json['id'] as int? ?? 0,
      name: json['name'] as String? ?? '',
      type: json['type'] as String? ?? 'regular',
      status: json['status'] as String? ?? 'open',
      results: json['results'] as String? ?? 'always',
      options: (json['options'] as List<dynamic>?)
          ?.map((e) => PollOption.fromJson(e as Map<String, dynamic>))
          .toList() ?? [],
      voters: json['voters'] as int? ?? 0,
    );
  }
}

/// 话题相关的用户信息
class TopicUser {
  final int id;
  final String username;
  final String avatarTemplate;

  TopicUser({
    required this.id,
    required this.username,
    required this.avatarTemplate,
  });

  factory TopicUser.fromJson(Map<String, dynamic> json) {
    return TopicUser(
      id: json['id'] as int,
      username: json['username'] as String? ?? '',
      avatarTemplate: json['avatar_template'] as String? ?? '',
    );
  }

  String getAvatarUrl({int size = 40}) {
    return UrlHelper.resolveAvatarUrl(avatarTemplate: avatarTemplate, size: size);
  }
}

/// 话题海报（参与者）信息
class TopicPoster {
  final int userId;
  final String description;
  final String extras;
  final TopicUser? user;

  TopicPoster({
    required this.userId,
    required this.description,
    required this.extras,
    this.user,
  });

  factory TopicPoster.fromJson(Map<String, dynamic> json, Map<int, TopicUser> userMap) {
    final userId = json['user_id'] as int;
    return TopicPoster(
      userId: userId,
      description: json['description'] as String? ?? '',
      extras: json['extras'] as String? ?? '',
      user: userMap[userId],
    );
  }
}

class Topic {
  final int id;
  final String title;
  final String slug;
  final int postsCount;
  final int replyCount;
  final int views;
  final int likeCount;
  final String? excerpt;
  final DateTime? createdAt;
  final DateTime? lastPostedAt;
  final String? lastPosterUsername;
  final int categoryId;
  final bool pinned;
  final bool visible;
  final bool closed;
  final bool archived;
  final List<Tag> tags;
  final List<TopicPoster> posters;

  // 已读状态相关
  final bool unseen;           // 新话题（从未见过）
  final int unread;            // 未读帖子数
  final int newPosts;          // 新帖子数
  final int? lastReadPostNumber;   // 最后阅读的帖子编号
  final int highestPostNumber;     // 最高帖子编号

  // 已解决问题相关
  final bool hasAcceptedAnswer;    // 话题是否有被接受的答案
  final bool canHaveAnswer;        // 话题是否可以有解决方案（用于显示未解决状态）

  Topic({
    required this.id,
    required this.title,
    required this.slug,
    required this.postsCount,
    required this.replyCount,
    required this.views,
    required this.likeCount,
    this.excerpt,
    this.createdAt,
    this.lastPostedAt,
    this.lastPosterUsername,
    required this.categoryId,
    this.pinned = false,
    this.visible = true,
    this.closed = false,
    this.archived = false,
    this.tags = const <Tag>[],
    this.posters = const [],
    this.unseen = false,
    this.unread = 0,
    this.newPosts = 0,
    this.lastReadPostNumber,
    this.highestPostNumber = 0,
    this.hasAcceptedAnswer = false,
    this.canHaveAnswer = false,
  });

  Topic copyWith({
    int? id,
    String? title,
    String? slug,
    int? postsCount,
    int? replyCount,
    int? views,
    int? likeCount,
    String? excerpt,
    DateTime? createdAt,
    DateTime? lastPostedAt,
    String? lastPosterUsername,
    int? categoryId,
    bool? pinned,
    bool? visible,
    bool? closed,
    bool? archived,
    List<Tag>? tags,
    List<TopicPoster>? posters,
    bool? unseen,
    int? unread,
    int? newPosts,
    int? lastReadPostNumber,
    int? highestPostNumber,
    bool? hasAcceptedAnswer,
    bool? canHaveAnswer,
  }) {
    return Topic(
      id: id ?? this.id,
      title: title ?? this.title,
      slug: slug ?? this.slug,
      postsCount: postsCount ?? this.postsCount,
      replyCount: replyCount ?? this.replyCount,
      views: views ?? this.views,
      likeCount: likeCount ?? this.likeCount,
      excerpt: excerpt ?? this.excerpt,
      createdAt: createdAt ?? this.createdAt,
      lastPostedAt: lastPostedAt ?? this.lastPostedAt,
      lastPosterUsername: lastPosterUsername ?? this.lastPosterUsername,
      categoryId: categoryId ?? this.categoryId,
      pinned: pinned ?? this.pinned,
      visible: visible ?? this.visible,
      closed: closed ?? this.closed,
      archived: archived ?? this.archived,
      tags: tags ?? this.tags,
      posters: posters ?? this.posters,
      unseen: unseen ?? this.unseen,
      unread: unread ?? this.unread,
      newPosts: newPosts ?? this.newPosts,
      lastReadPostNumber: lastReadPostNumber ?? this.lastReadPostNumber,
      highestPostNumber: highestPostNumber ?? this.highestPostNumber,
      hasAcceptedAnswer: hasAcceptedAnswer ?? this.hasAcceptedAnswer,
      canHaveAnswer: canHaveAnswer ?? this.canHaveAnswer,
    );
  }

  factory Topic.fromJson(Map<String, dynamic> json, {Map<int, TopicUser>? userMap}) {
    return Topic(
      id: json['id'] as int,
      title: json['title'] as String? ?? '',
      slug: json['slug'] as String? ?? '',
      postsCount: json['posts_count'] as int? ?? 0,
      replyCount: json['reply_count'] as int? ?? 0,
      views: json['views'] as int? ?? 0,
      likeCount: json['like_count'] as int? ?? 0,
      excerpt: json['excerpt'] as String?,
      createdAt: TimeUtils.parseUtcTime(json['created_at'] as String?),
      lastPostedAt: TimeUtils.parseUtcTime(json['last_posted_at'] as String?),
      lastPosterUsername: json['last_poster_username'] as String?,
      categoryId: json['category_id'] as int? ?? 0,
      pinned: json['pinned'] as bool? ?? false,
      visible: json['visible'] as bool? ?? true,
      closed: json['closed'] as bool? ?? false,
      archived: json['archived'] as bool? ?? false,
      tags: (json['tags'] as List<dynamic>?)?.map((e) => Tag.fromJson(e)).toList() ?? const <Tag>[],
      posters: (json['posters'] as List<dynamic>?)
          ?.map((e) => TopicPoster.fromJson(e as Map<String, dynamic>, userMap ?? {}))
          .toList() ?? const [],
      unseen: json['unseen'] as bool? ?? false,
      unread: json['unread_posts'] as int? ?? 0,
      newPosts: json['new_posts'] as int? ?? 0,
      lastReadPostNumber: json['last_read_post_number'] as int?,
      highestPostNumber: json['highest_post_number'] as int? ?? 0,
      hasAcceptedAnswer: json['has_accepted_answer'] as bool? ?? false,
      canHaveAnswer: json['can_have_answer'] as bool? ?? false,
    );
  }
}
