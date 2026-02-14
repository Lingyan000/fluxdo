// 搜索结果数据模型
import '../utils/time_utils.dart';
import '../utils/url_helper.dart';
import 'topic.dart';

/// 搜索结果响应
class SearchResult {
  final List<SearchPost> posts;
  final List<SearchUser> users;
  final GroupedSearchResult groupedResult;

  SearchResult({
    required this.posts,
    required this.users,
    required this.groupedResult,
  });

  factory SearchResult.fromJson(Map<String, dynamic> json) {
    // 解析 posts - 搜索结果的主要内容
    final postsJson = json['posts'] as List<dynamic>? ?? [];
    // 解析 topics 用于关联
    final topicsJson = json['topics'] as List<dynamic>? ?? [];
    final topicsMap = <int, Map<String, dynamic>>{};
    for (final t in topicsJson) {
      final topic = t as Map<String, dynamic>;
      topicsMap[topic['id'] as int] = topic;
    }

    final posts = postsJson.map((p) {
      final post = p as Map<String, dynamic>;
      final topicId = post['topic_id'] as int?;
      final topicData = topicId != null ? topicsMap[topicId] : null;
      return SearchPost.fromJson(post, topicData);
    }).toList();

    // 解析 users
    final usersJson = json['users'] as List<dynamic>? ?? [];
    final users = usersJson
        .map((u) => SearchUser.fromJson(u as Map<String, dynamic>))
        .toList();

    // 解析分组结果
    final groupedJson =
        json['grouped_search_result'] as Map<String, dynamic>? ?? {};

    return SearchResult(
      posts: posts,
      users: users,
      groupedResult: GroupedSearchResult.fromJson(groupedJson),
    );
  }

  bool get isEmpty => posts.isEmpty && users.isEmpty;
  /// AI 搜索摘要
  String? get aiAnswer => groupedResult.aiAnswer;
  /// 是否有更多帖子结果
  /// 全页面搜索使用 more_full_page_results，头部搜索使用 more_posts
  bool get hasMorePosts => groupedResult.moreFullPageResults || groupedResult.morePosts;
  bool get hasMoreUsers => groupedResult.moreUsers;
}

/// 搜索结果中的帖子
class SearchPost {
  final int id;
  final String username;
  final String avatarTemplate;
  final DateTime createdAt;
  final int likeCount;
  final String blurb;
  final int postNumber;
  final String? topicTitleHeadline;
  final SearchTopic? topic;

  SearchPost({
    required this.id,
    required this.username,
    required this.avatarTemplate,
    required this.createdAt,
    required this.likeCount,
    required this.blurb,
    required this.postNumber,
    this.topicTitleHeadline,
    this.topic,
  });

  factory SearchPost.fromJson(
      Map<String, dynamic> json, Map<String, dynamic>? topicJson) {
    return SearchPost(
      id: json['id'] as int,
      username: json['username'] as String? ?? '',
      avatarTemplate: json['avatar_template'] as String? ?? '',
      createdAt: TimeUtils.parseUtcTime(json['created_at'] as String?) ??
          DateTime.now(),
      likeCount: json['like_count'] as int? ?? 0,
      blurb: json['blurb'] as String? ?? '',
      postNumber: json['post_number'] as int? ?? 1,
      topicTitleHeadline: json['topic_title_headline'] as String?,
      topic: topicJson != null ? SearchTopic.fromJson(topicJson) : null,
    );
  }

  String getAvatarUrl({int size = 120}) {
    return UrlHelper.resolveAvatarUrl(avatarTemplate: avatarTemplate, size: size);
  }
}

/// 搜索结果中的话题信息
class SearchTopic {
  final int id;
  final String title;
  final String slug;
  final int? categoryId;
  final List<Tag> tags;
  final int postsCount;
  final int views;
  final bool closed;
  final bool archived;

  SearchTopic({
    required this.id,
    required this.title,
    required this.slug,
    this.categoryId,
    required this.tags,
    required this.postsCount,
    required this.views,
    required this.closed,
    required this.archived,
  });

  factory SearchTopic.fromJson(Map<String, dynamic> json) {
    final tagsJson = json['tags'] as List<dynamic>? ?? [];
    return SearchTopic(
      id: json['id'] as int,
      title: json['title'] as String? ?? '',
      slug: json['slug'] as String? ?? '',
      categoryId: json['category_id'] as int?,
      tags: tagsJson.map((t) => Tag.fromJson(t)).toList(),
      postsCount: json['posts_count'] as int? ?? 0,
      views: json['views'] as int? ?? 0,
      closed: json['closed'] as bool? ?? false,
      archived: json['archived'] as bool? ?? false,
    );
  }
}

/// 搜索到的用户
class SearchUser {
  final int id;
  final String username;
  final String? name;
  final String avatarTemplate;

  SearchUser({
    required this.id,
    required this.username,
    this.name,
    required this.avatarTemplate,
  });

  factory SearchUser.fromJson(Map<String, dynamic> json) {
    return SearchUser(
      id: json['id'] as int,
      username: json['username'] as String? ?? '',
      name: json['name'] as String?,
      avatarTemplate: json['avatar_template'] as String? ?? '',
    );
  }

  String getAvatarUrl({int size = 120}) {
    return UrlHelper.resolveAvatarUrl(avatarTemplate: avatarTemplate, size: size);
  }
}

/// 分组结果元信息
class GroupedSearchResult {
  final String term;
  final bool morePosts;
  final bool moreUsers;
  final bool moreCategories;
  final bool moreFullPageResults;
  final int? searchLogId;

  /// AI 搜索摘要（discourse-ai 插件提供，HTML 格式）
  final String? aiAnswer;

  GroupedSearchResult({
    required this.term,
    required this.morePosts,
    required this.moreUsers,
    required this.moreCategories,
    required this.moreFullPageResults,
    this.searchLogId,
    this.aiAnswer,
  });

  factory GroupedSearchResult.fromJson(Map<String, dynamic> json) {
    return GroupedSearchResult(
      term: json['term'] as String? ?? '',
      morePosts: json['more_posts'] as bool? ?? false,
      moreUsers: json['more_users'] as bool? ?? false,
      moreCategories: json['more_categories'] as bool? ?? false,
      moreFullPageResults: json['more_full_page_results'] as bool? ?? false,
      searchLogId: json['search_log_id'] as int?,
      aiAnswer: json['ai_answer'] as String?,
    );
  }
}
