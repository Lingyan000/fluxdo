import 'topic.dart';
import '../utils/time_utils.dart';

/// Follow 插件返回的帖子流，保留服务端原始时间作为分页游标。
class FollowingPost {
  const FollowingPost({
    required this.id,
    required this.topicId,
    required this.postNumber,
    required this.createdAtRaw,
    required this.title,
    required this.author,
    this.excerpt,
    this.categoryId,
  });
  final int id;
  final int topicId;
  final int postNumber;
  final String createdAtRaw;
  final String title;
  final TopicUser author;
  final String? excerpt;
  final int? categoryId;
  DateTime? get createdAt => TimeUtils.parseUtcTime(createdAtRaw);

  factory FollowingPost.fromJson(Map<String, dynamic> json) {
    final topic = json['topic'] as Map<String, dynamic>;
    final user = json['user'] as Map<String, dynamic>;
    return FollowingPost(
      id: json['id'] as int,
      topicId: json['topic_id'] as int,
      postNumber: json['post_number'] as int,
      createdAtRaw: json['created_at'] as String,
      title: topic['title'] as String? ?? '',
      author: TopicUser(
        id: user['id'] as int,
        username: user['username'] as String,
        name: user['name'] as String?,
        avatarTemplate: user['avatar_template'] as String? ?? '',
      ),
      excerpt: json['excerpt'] as String?,
      categoryId: json['category_id'] as int? ?? topic['category_id'] as int?,
    );
  }
}

class FollowingFeedResponse {
  const FollowingFeedResponse({required this.posts, required this.hasMore});
  final List<FollowingPost> posts;
  final bool hasMore;
  factory FollowingFeedResponse.fromJson(Map<String, dynamic> json) =>
      FollowingFeedResponse(
        posts: (json['posts'] as List)
            .map((p) => FollowingPost.fromJson(p as Map<String, dynamic>))
            .toList(),
        hasMore:
            (json['extras'] as Map<String, dynamic>?)?['has_more'] as bool? ??
            false,
      );
}
