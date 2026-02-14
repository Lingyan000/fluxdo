part of '../topic.dart';

/// 话题详情模型
class TopicDetail {
  final int id;
  final String title;
  final String slug;
  final int postsCount;
  final PostStream postStream;
  final int categoryId;
  final bool closed;
  final bool archived;
  final List<Tag>? tags;
  final int views;
  final int likeCount;
  final DateTime? createdAt;
  final bool visible;
  final int? lastReadPostNumber; // 最后阅读的帖子编号（从 API 获取）

  // 投票相关字段
  final bool canVote;        // 是否可以投票
  final int voteCount;       // 投票数
  final bool userVoted;      // 当前用户是否已投票

  // 创建者信息
  final TopicUser? createdBy;

  // AI 摘要相关字段
  final bool summarizable;        // 话题是否可摘要（后端控制）
  final bool hasCachedSummary;    // 是否有缓存的摘要

  // 热门回复相关字段
  final bool hasSummary;          // 是否有足够的帖子/点赞来支持热门回复功能

  // 订阅级别
  final TopicNotificationLevel notificationLevel;

  // 话题类型
  final String archetype;  // 'regular' 或 'private_message'

  // 话题权限（来自 details）
  final bool canEdit;  // 是否可以编辑话题元数据（标题、分类、标签）

  // 已解决问题相关
  final bool hasAcceptedAnswer;         // 话题是否有被接受的答案
  final int? acceptedAnswerPostNumber;  // 被接受答案的帖子编号

  /// 是否为私信
  bool get isPrivateMessage => archetype == 'private_message';

  TopicDetail({
    required this.id,
    required this.title,
    required this.slug,
    required this.postsCount,
    required this.postStream,
    required this.categoryId,
    required this.closed,
    required this.archived,
    this.tags,
    this.views = 0,
    this.likeCount = 0,
    this.createdAt,
    this.visible = true,
    this.lastReadPostNumber,
    this.canVote = false,
    this.voteCount = 0,
    this.userVoted = false,
    this.createdBy,
    this.summarizable = false,
    this.hasCachedSummary = false,
    this.hasSummary = false,
    this.notificationLevel = TopicNotificationLevel.regular,
    this.archetype = 'regular',
    this.canEdit = false,
    this.hasAcceptedAnswer = false,
    this.acceptedAnswerPostNumber,
  });

  factory TopicDetail.fromJson(Map<String, dynamic> json) {
    final postStream = PostStream.fromJson(json['post_stream'] as Map<String, dynamic>);

    // 注入 topic 级别的 badges 数据到每个 post
    final rawPosts = (json['post_stream'] as Map<String, dynamic>)['posts'] as List<dynamic>?;
    PostStream.injectBadges(postStream.posts, json, rawPosts);

    // 解析 accepted_answer：topic 级别返回的是一个对象 {post_number, username, ...}
    final acceptedAnswerData = json['accepted_answer'];
    int? acceptedAnswerPostNumber;
    bool hasAcceptedAnswer = false;

    if (acceptedAnswerData is Map<String, dynamic>) {
      // topic 级别的 accepted_answer 是一个对象
      acceptedAnswerPostNumber = acceptedAnswerData['post_number'] as int?;
      hasAcceptedAnswer = true;
    }

    // 备用方案：如果 topic 级别没有，从帖子的 topic_accepted_answer 或 accepted_answer 字段推断
    if (!hasAcceptedAnswer) {
      hasAcceptedAnswer = json['has_accepted_answer'] as bool? ?? false;
    }
    if (hasAcceptedAnswer && acceptedAnswerPostNumber == null) {
      final acceptedPost = postStream.posts.where((p) => p.acceptedAnswer).firstOrNull;
      acceptedAnswerPostNumber = acceptedPost?.postNumber;
    }

    return TopicDetail(
      id: json['id'] as int,
      title: json['title'] as String? ?? '',
      slug: json['slug'] as String? ?? '',
      postsCount: json['posts_count'] as int? ?? 0,
      postStream: postStream,
      categoryId: json['category_id'] as int? ?? 0,
      closed: json['closed'] as bool? ?? false,
      archived: json['archived'] as bool? ?? false,
      tags: (json['tags'] as List<dynamic>?)?.map((e) => Tag.fromJson(e)).toList(),
      views: json['views'] as int? ?? 0,
      likeCount: json['like_count'] as int? ?? 0,
      createdAt: TimeUtils.parseUtcTime(json['created_at'] as String?),
      visible: json['visible'] as bool? ?? true,
      lastReadPostNumber: json['last_read_post_number'] as int?,
      canVote: json['can_vote'] as bool? ?? false,
      voteCount: json['vote_count'] as int? ?? 0,
      userVoted: json['user_voted'] as bool? ?? false,
      createdBy: (json['details'] as Map<String, dynamic>?)?['created_by'] != null
          ? TopicUser.fromJson((json['details']!['created_by'] as Map<String, dynamic>))
          : null,
      summarizable: json['summarizable'] as bool? ?? false,
      hasCachedSummary: json['has_cached_summary'] as bool? ?? false,
      hasSummary: json['has_summary'] as bool? ?? false,
      archetype: json['archetype'] as String? ?? 'regular',
      notificationLevel: TopicNotificationLevel.fromValue(
        (json['details'] as Map<String, dynamic>?)?['notification_level'] as int?,
      ),
      canEdit: (json['details'] as Map<String, dynamic>?)?['can_edit'] as bool? ?? false,
      hasAcceptedAnswer: hasAcceptedAnswer,
      acceptedAnswerPostNumber: acceptedAnswerPostNumber,
    );
  }

  /// 创建修改后的副本
  TopicDetail copyWith({
    int? id,
    String? title,
    String? slug,
    int? postsCount,
    PostStream? postStream,
    int? categoryId,
    bool? closed,
    bool? archived,
    List<Tag>? tags,
    int? views,
    int? likeCount,
    DateTime? createdAt,
    bool? visible,
    int? lastReadPostNumber,
    bool? canVote,
    int? voteCount,
    bool? userVoted,
    TopicUser? createdBy,
    bool? summarizable,
    bool? hasCachedSummary,
    bool? hasSummary,
    TopicNotificationLevel? notificationLevel,
    String? archetype,
    bool? canEdit,
    bool? hasAcceptedAnswer,
    int? acceptedAnswerPostNumber,
  }) {
    return TopicDetail(
      id: id ?? this.id,
      title: title ?? this.title,
      slug: slug ?? this.slug,
      postsCount: postsCount ?? this.postsCount,
      postStream: postStream ?? this.postStream,
      categoryId: categoryId ?? this.categoryId,
      closed: closed ?? this.closed,
      archived: archived ?? this.archived,
      tags: tags ?? this.tags,
      views: views ?? this.views,
      likeCount: likeCount ?? this.likeCount,
      createdAt: createdAt ?? this.createdAt,
      visible: visible ?? this.visible,
      lastReadPostNumber: lastReadPostNumber ?? this.lastReadPostNumber,
      canVote: canVote ?? this.canVote,
      voteCount: voteCount ?? this.voteCount,
      userVoted: userVoted ?? this.userVoted,
      createdBy: createdBy ?? this.createdBy,
      summarizable: summarizable ?? this.summarizable,
      hasCachedSummary: hasCachedSummary ?? this.hasCachedSummary,
      hasSummary: hasSummary ?? this.hasSummary,
      notificationLevel: notificationLevel ?? this.notificationLevel,
      archetype: archetype ?? this.archetype,
      canEdit: canEdit ?? this.canEdit,
      hasAcceptedAnswer: hasAcceptedAnswer ?? this.hasAcceptedAnswer,
      acceptedAnswerPostNumber: acceptedAnswerPostNumber ?? this.acceptedAnswerPostNumber,
    );
  }
}

/// 话题 AI 摘要
class TopicSummary {
  final String summarizedText;
  final String? algorithm;
  final bool outdated;
  final bool canRegenerate;
  final int newPostsSinceSummary;
  final DateTime? updatedAt;

  TopicSummary({
    required this.summarizedText,
    this.algorithm,
    required this.outdated,
    required this.canRegenerate,
    required this.newPostsSinceSummary,
    this.updatedAt,
  });

  factory TopicSummary.fromJson(Map<String, dynamic> json) {
    return TopicSummary(
      summarizedText: json['summarized_text'] as String? ?? '',
      algorithm: json['algorithm'] as String?,
      outdated: json['outdated'] as bool? ?? false,
      canRegenerate: json['can_regenerate'] as bool? ?? false,
      newPostsSinceSummary: json['new_posts_since_summary'] as int? ?? 0,
      updatedAt: TimeUtils.parseUtcTime(json['updated_at'] as String?),
    );
  }
}

/// 帖子列表响应
class TopicListResponse {
  final List<Topic> topics;
  final String? moreTopicsUrl;

  TopicListResponse({
    required this.topics,
    this.moreTopicsUrl,
  });

  factory TopicListResponse.fromJson(Map<String, dynamic> json) {
    // Parse users map
    final usersJson = json['users'] as List<dynamic>? ?? [];
    final userMap = {
      for (var u in usersJson)
        (u['id'] as int): TopicUser.fromJson(u as Map<String, dynamic>)
    };

    final topicList = json['topic_list'] as Map<String, dynamic>?;
    List<dynamic> topicsJson = [];
    String? moreTopicsUrl;

    if (topicList != null) {
      topicsJson = topicList['topics'] as List<dynamic>? ?? [];
      moreTopicsUrl = topicList['more_topics_url'] as String?;
    } else if (json.containsKey('user_bookmark_list')) {
      // 处理 /u/{username}/bookmarks.json 格式
      final userBookmarkList = json['user_bookmark_list'] as Map<String, dynamic>?;
      if (userBookmarkList != null) {
        final bookmarks = userBookmarkList['bookmarks'] as List<dynamic>? ?? [];
        moreTopicsUrl = userBookmarkList['more_bookmarks_url'] as String?;
        topicsJson = bookmarks.map((b) {
          final map = Map<String, dynamic>.from(b as Map);
          // 书签对象中的 id 是书签 ID，topic_id 才是主题 ID
          if (map.containsKey('topic_id')) {
            map['id'] = map['topic_id'];
          }

          // 映射关键字段以适配 TopicCard 显示
          // 1. 使用 highest_post_number 作为 posts_count
          if (map.containsKey('highest_post_number')) {
            map['posts_count'] = map['highest_post_number'];
            map['reply_count'] = (map['highest_post_number'] as int) - 1;
          }

          // 2. 使用 bumped_at 作为 last_posted_at
          if (map.containsKey('bumped_at') && !map.containsKey('last_posted_at')) {
            map['last_posted_at'] = map['bumped_at'];
          }

          // 3. 将 user 转换为 posters 数组格式（用于头像叠放）
          if (map.containsKey('user') && map['user'] != null) {
            final user = map['user'] as Map<String, dynamic>;
            final userId = user['id'] as int;

            // 添加 user 到 userMap（如果不存在）
            if (!userMap.containsKey(userId)) {
              userMap[userId] = TopicUser.fromJson(user);
            }

            // 创建 posters 数组
            map['posters'] = [
              {
                'user_id': userId,
                'description': 'Original Poster',
                'extras': 'latest',
              }
            ];

            // 设置 last_poster_username
            if (user.containsKey('username')) {
              map['last_poster_username'] = user['username'];
            }
          }

          // 4. 如果没有 like_count，设置为 0（书签数据中可能没有这个字段）
          if (!map.containsKey('like_count')) {
            map['like_count'] = 0;
          }

          // 5. 如果没有 views，设置为 0
          if (!map.containsKey('views')) {
            map['views'] = 0;
          }

          return map;
        }).toList();
      }
    } else if (json.containsKey('bookmarks')) {
      // 处理 /bookmarks.json 格式
      final bookmarks = json['bookmarks'] as List<dynamic>? ?? [];
      topicsJson = bookmarks.map((b) {
        final map = Map<String, dynamic>.from(b as Map);
        // 书签对象中的 id 是书签 ID，topic_id 才是主题 ID
        // 为了兼容 Topic.fromJson，我们将 topic_id 赋给 id
        if (map.containsKey('topic_id')) {
          map['id'] = map['topic_id'];
        }
        return map;
      }).toList();
    }

    return TopicListResponse(
      topics: topicsJson.map((t) => Topic.fromJson(t as Map<String, dynamic>, userMap: userMap)).toList(),
      moreTopicsUrl: moreTopicsUrl,
    );
  }
}

/// 举报类型
class FlagType {
  final int id;
  final String nameKey;
  final String name;
  final String description;
  final String? shortDescription;
  final bool isFlag;
  final bool requireMessage;
  final bool enabled;
  final int position;
  final List<String> appliesTo;

  const FlagType({
    required this.id,
    required this.nameKey,
    required this.name,
    required this.description,
    this.shortDescription,
    required this.isFlag,
    this.requireMessage = false,
    this.enabled = true,
    this.position = 0,
    this.appliesTo = const ['Post', 'Chat::Message'],
  });

  factory FlagType.fromJson(Map<String, dynamic> json) {
    return FlagType(
      id: json['id'] as int,
      nameKey: json['name_key'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      shortDescription: json['short_description'] as String?,
      isFlag: json['is_flag'] as bool? ?? false,
      requireMessage: json['require_message'] as bool? ?? false,
      enabled: json['enabled'] as bool? ?? true,
      position: json['position'] as int? ?? 0,
      appliesTo: (json['applies_to'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList() ?? const ['Post', 'Chat::Message'],
    );
  }

  /// 是否适用于帖子
  bool get appliesToPost => appliesTo.contains('Post');

  /// 默认的举报类型列表（作为后备）
  static const List<FlagType> defaultTypes = [
    FlagType(
      id: 3,
      nameKey: 'off_topic',
      name: '离题',
      description: '此帖子与当前讨论无关，应该移动到其他话题',
      isFlag: true,
      position: 1,
    ),
    FlagType(
      id: 4,
      nameKey: 'inappropriate',
      name: '不当内容',
      description: '此帖子包含不适当的内容',
      isFlag: true,
      position: 2,
    ),
    FlagType(
      id: 8,
      nameKey: 'spam',
      name: '垃圾信息',
      description: '此帖子是广告或垃圾信息',
      isFlag: true,
      position: 3,
    ),
    FlagType(
      id: 7,
      nameKey: 'notify_moderators',
      name: '其他问题',
      description: '需要版主关注的其他问题',
      isFlag: true,
      requireMessage: true,
      position: 4,
    ),
  ];
}
