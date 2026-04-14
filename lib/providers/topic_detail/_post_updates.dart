part of '../topic_detail_provider.dart';

// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// 帖子和话题更新相关方法
extension PostUpdateMethods on TopicDetailNotifier {
  /// 正在请求中的 postId 集合，防止同一 postId 并发请求。
  /// 对齐 Discourse 官方 triggerChangedPost：同一 postId 同时只有一个在途请求，
  /// 如果在途期间又收到新消息，标记需要「尾部重试」一次以获取最新状态。
  static final _pendingRefresh = <int>{};
  static final _needsRetry = <int>{};

  /// 刷新单个帖子（用于 MessageBus revised/acted 等消息）
  /// 与 Discourse 官方一致，使用 /posts/{id}.json 单帖接口获取完整数据
  Future<void> refreshPost(int postId, {bool preserveCooked = false, DateTime? updatedAt}) async {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    final currentPosts = currentDetail.postStream.posts;
    final index = currentPosts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    // 对齐 Discourse 官方：只在 updated_at 更新时才请求
    if (updatedAt != null && !currentPosts[index].updatedAt.isBefore(updatedAt)) {
      return;
    }

    // 同一 postId 已有在途请求 → 标记尾部重试，不发新请求
    if (!_pendingRefresh.add(postId)) {
      _needsRetry.add(postId);
      return;
    }

    try {
      final service = ref.read(discourseServiceProvider);
      final updatedPost = await service.getPost(postId);
      if (!ref.mounted) return;

      _applyPostUpdate(postId, updatedPost, preserveCooked: preserveCooked);
    } catch (e) {
      debugPrint('[TopicDetail] 刷新帖子 $postId 失败: $e');
    } finally {
      _pendingRefresh.remove(postId);
      // 在途期间有新消息到达 → 自动重试一次获取最新状态
      if (_needsRetry.remove(postId) && ref.mounted) {
        refreshPost(postId);
      }
    }
  }

  /// 将获取到的帖子数据应用到 state
  void _applyPostUpdate(int postId, Post updatedPost, {bool preserveCooked = false}) {
    final currentDetail = state.value;
    if (currentDetail == null) return;
    final currentPosts = currentDetail.postStream.posts;
    final index = currentPosts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    final oldPost = currentPosts[index];

    // /posts/{id}.json 单帖接口不会预加载 boosts 关联，
    // 导致返回的 JSON 中不包含 boosts/can_boost 字段。
    // 此时 Post.fromJson 会将 boosts 设为 null、canBoost 设为 false。
    // 为避免丢失已有的 boost 数据，当新数据不含 boosts 时保留旧值。
    final mergedPost = updatedPost.boosts == null
        ? updatedPost.copyWith(
            boosts: oldPost.boosts,
            canBoost: oldPost.canBoost,
          )
        : updatedPost;

    final finalPost = preserveCooked
        ? mergedPost.copyWith(
            cooked: oldPost.cooked,
            read: oldPost.read,
          )
        : mergedPost;

    final newPosts = [...currentPosts];
    newPosts[index] = finalPost;

    state = AsyncValue.data(currentDetail.copyWith(
      postStream: PostStream(posts: newPosts, stream: currentDetail.postStream.stream, gaps: currentDetail.postStream.gaps),
    ));
  }

  /// 从列表中移除帖子（用于 MessageBus destroyed 消息）
  void removePost(int postId) {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    final currentPosts = currentDetail.postStream.posts;
    final newPosts = currentPosts.where((p) => p.id != postId).toList();

    if (newPosts.length == currentPosts.length) return;

    final newStream = currentDetail.postStream.stream.where((id) => id != postId).toList();

    state = AsyncValue.data(currentDetail.copyWith(
      postsCount: currentDetail.postsCount - 1,
      postStream: PostStream(posts: newPosts, stream: newStream, gaps: currentDetail.postStream.gaps),
    ));
  }

  /// 标记帖子被删除（用于 MessageBus deleted 消息）
  void markPostDeleted(int postId) {
    refreshPost(postId);
  }

  /// 标记帖子已恢复（用于 MessageBus recovered 消息）
  void markPostRecovered(int postId) {
    refreshPost(postId);
  }

  /// 更新帖子点赞数（用于 MessageBus liked/unliked 消息）
  void updatePostLikes(int postId, {int? likesCount}) {
    if (likesCount == null) {
      refreshPost(postId, preserveCooked: true);
      return;
    }
    _updatePostById(postId, (post) => post.copyWith(likeCount: likesCount));
  }

  /// 更新单个帖子的点赞/回应状态
  void updatePostReaction(int postId, List<PostReaction> reactions, PostReaction? currentUserReaction) {
    _updatePostById(postId, (post) => post.copyWith(
      reactions: reactions,
      currentUserReaction: currentUserReaction,
    ));
  }

  /// 更新帖子的解决方案状态
  void updatePostSolution(int postId, bool accepted) {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    final currentPosts = currentDetail.postStream.posts;
    final newPosts = currentPosts.map((post) {
      if (post.id == postId) {
        return post.copyWith(
          acceptedAnswer: accepted,
          canUnacceptAnswer: accepted,
        );
      } else if (accepted && post.acceptedAnswer) {
        return post.copyWith(
          acceptedAnswer: false,
          canUnacceptAnswer: false,
        );
      }
      return post;
    }).toList();

    int? acceptedPostNumber;
    if (accepted) {
      final acceptedPost = newPosts.firstWhere((p) => p.id == postId);
      acceptedPostNumber = acceptedPost.postNumber;
    }

    state = AsyncValue.data(currentDetail.copyWith(
      postStream: PostStream(posts: newPosts, stream: currentDetail.postStream.stream, gaps: currentDetail.postStream.gaps),
      hasAcceptedAnswer: accepted,
      acceptedAnswerPostNumber: acceptedPostNumber,
    ));
  }

  /// 添加新创建的帖子到列表（用于回复后直接更新）
  bool addPost(Post post) {
    final currentDetail = state.value;
    if (currentDetail == null) return false;

    final currentPosts = currentDetail.postStream.posts;

    if (currentPosts.any((p) => p.id == post.id)) return true;

    final newStream = [...currentDetail.postStream.stream];
    if (!newStream.contains(post.id)) {
      newStream.add(post.id);
    }

    if (!_hasMoreAfter) {
      final newPosts = [...currentPosts, post];
      newPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));

      final newPostsCount = currentDetail.postsCount + 1;

      state = AsyncValue.data(currentDetail.copyWith(
        postsCount: newPostsCount,
        postStream: PostStream(posts: newPosts, stream: newStream, gaps: currentDetail.postStream.gaps),
      ));

      // 从 API 刷新被回复帖子以获取正确的 replyCount（避免与 MessageBus 路径重复递增）
      if (post.replyToPostNumber > 0) {
        _refreshReplyTarget(post.replyToPostNumber);
      }

      return true;
    } else {
      state = AsyncValue.data(currentDetail.copyWith(
        postsCount: currentDetail.postsCount + 1,
        postStream: PostStream(posts: currentPosts, stream: newStream, gaps: currentDetail.postStream.gaps),
      ));
      return false;
    }
  }

  /// 从 API 刷新被回复帖子，获取正确的 replyCount
  void _refreshReplyTarget(int replyToPostNumber) {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    final posts = currentDetail.postStream.posts;
    final index = posts.indexWhere((p) => p.postNumber == replyToPostNumber);
    if (index == -1) return;
    final targetPost = posts[index];

    refreshPost(targetPost.id);
  }

  /// 更新已存在的帖子（用于编辑后直接更新）
  void updatePost(Post post) {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    final currentPosts = currentDetail.postStream.posts;
    final index = currentPosts.indexWhere((p) => p.id == post.id);
    if (index == -1) return;

    final newPosts = [...currentPosts];
    newPosts[index] = post;

    state = AsyncValue.data(currentDetail.copyWith(
      postStream: PostStream(posts: newPosts, stream: currentDetail.postStream.stream, gaps: currentDetail.postStream.gaps),
    ));
  }

  /// 更新话题信息（用于编辑话题后直接更新）
  void updateTopicInfo({
    String? title,
    int? categoryId,
    List<String>? tags,
    Post? firstPost,
  }) {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    PostStream? updatedPostStream;
    if (firstPost != null) {
      final currentPosts = currentDetail.postStream.posts;
      final index = currentPosts.indexWhere((p) => p.id == firstPost.id);
      if (index != -1) {
        final newPosts = [...currentPosts];
        newPosts[index] = firstPost;
        updatedPostStream = PostStream(posts: newPosts, stream: currentDetail.postStream.stream, gaps: currentDetail.postStream.gaps);
      }
    }

    state = AsyncValue.data(currentDetail.copyWith(
      title: title ?? currentDetail.title,
      categoryId: categoryId ?? currentDetail.categoryId,
      tags: tags != null ? tags.map((name) => Tag(name: name)).toList() : currentDetail.tags,
      postStream: updatedPostStream ?? currentDetail.postStream,
    ));
  }

  /// 更新话题投票状态
  void updateTopicVote(int newVoteCount, bool userVoted) {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    state = AsyncValue.data(currentDetail.copyWith(
      voteCount: newVoteCount,
      userVoted: userVoted,
    ));
  }

  /// 更新话题订阅级别
  Future<void> updateNotificationLevel(TopicNotificationLevel level) async {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    try {
      await ref.read(discourseServiceProvider).setTopicNotificationLevel(
        currentDetail.id,
        level,
      );
      if (!ref.mounted) return;

      state = AsyncValue.data(currentDetail.copyWith(notificationLevel: level));
    } catch (e) {
      debugPrint('[TopicDetail] 更新订阅级别失败: $e');
      rethrow;
    }
  }

  /// 本地更新话题订阅级别（不发起网络请求，用于 MessageBus 同步）
  void updateNotificationLevelLocally(TopicNotificationLevel level) {
    final currentDetail = state.value;
    if (currentDetail == null) return;
    state = AsyncValue.data(currentDetail.copyWith(notificationLevel: level));
  }

  /// 应用话题统计更新（用于 MessageBus stats 消息）
  void applyStatsUpdate(TopicStatsUpdate stats) {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    state = AsyncValue.data(currentDetail.copyWith(
      postsCount: stats.postsCount ?? currentDetail.postsCount,
      likeCount: stats.likeCount ?? currentDetail.likeCount,
    ));
  }

  /// 添加话题书签
  Future<int> addTopicBookmark() async {
    final currentDetail = state.value;
    if (currentDetail == null) throw Exception(S.current.error_topicDetailEmpty);

    final service = ref.read(discourseServiceProvider);
    final newBookmarkId = await service.bookmarkTopic(currentDetail.id);
    if (!ref.mounted) throw Exception(S.current.error_providerDisposed);

    state = AsyncValue.data(currentDetail.copyWith(
      bookmarked: true,
      bookmarkId: newBookmarkId,
    ));
    return newBookmarkId;
  }

  /// 删除话题书签
  Future<void> removeTopicBookmark() async {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    final bookmarkId = currentDetail.bookmarkId;
    if (bookmarkId == null) return;

    final service = ref.read(discourseServiceProvider);
    await service.deleteBookmark(bookmarkId);
    if (!ref.mounted) return;

    state = AsyncValue.data(currentDetail.copyWith(
      bookmarked: false,
      clearBookmarkId: true,
      clearBookmarkName: true,
      clearBookmarkReminderAt: true,
    ));
  }

  /// 更新话题书签元数据（本地状态）
  void updateTopicBookmarkMeta({String? name, DateTime? reminderAt, bool clearName = false, bool clearReminderAt = false}) {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    state = AsyncValue.data(currentDetail.copyWith(
      bookmarkName: name,
      bookmarkReminderAt: reminderAt,
      clearBookmarkName: clearName,
      clearBookmarkReminderAt: clearReminderAt,
    ));
  }

  /// 添加 Boost 到帖子（用于 MessageBus boost_added 消息）
  void addBoostToPost(int postId, Map<String, dynamic> boostData) {
    _updatePostById(postId, (post) {
      final newBoost = Boost.fromJson(boostData);
      final currentBoosts = List<Boost>.from(post.boosts ?? []);
      // 避免重复添加
      if (currentBoosts.any((b) => b.id == newBoost.id)) return post;
      currentBoosts.add(newBoost);
      return post.copyWith(boosts: currentBoosts, canBoost: false);
    });
  }

  /// 从帖子移除 Boost（用于 MessageBus boost_removed 消息）
  void removeBoostFromPost(int postId, int boostId) {
    _updatePostById(postId, (post) {
      final currentBoosts = List<Boost>.from(post.boosts ?? []);
      final removed = currentBoosts.removeWhere((b) => b.id == boostId);
      // 删除后可能恢复 canBoost，但这取决于是否是自己的 boost
      // 由于 MessageBus 不携带这个信息，保守处理不改变 canBoost
      return post.copyWith(boosts: currentBoosts);
    });
  }

  /// 重新加载话题元数据（只更新元数据，不刷新帖子流）
  Future<void> reloadTopicMetadata() async {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    try {
      final service = ref.read(discourseServiceProvider);
      final newDetail = await service.getTopicDetail(arg.topicId, postNumber: 1);
      if (!ref.mounted) return;
      // 只更新元数据，保留当前帖子列表
      state = AsyncValue.data(currentDetail.copyWith(
        title: newDetail.title,
        slug: newDetail.slug,
        closed: newDetail.closed,
        archived: newDetail.archived,
        tags: newDetail.tags,
        categoryId: newDetail.categoryId,
        notificationLevel: newDetail.notificationLevel,
        hasAcceptedAnswer: newDetail.hasAcceptedAnswer,
        acceptedAnswerPostNumber: newDetail.acceptedAnswerPostNumber,
        canEdit: newDetail.canEdit,
        bookmarked: newDetail.bookmarked,
        bookmarkId: newDetail.bookmarkId,
        clearBookmarkId: !newDetail.bookmarked,
      ));
    } catch (e) {
      debugPrint('[TopicDetail] reloadTopicMetadata 失败: $e');
    }
  }
}
