part of '../topic_detail_provider.dart';

// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

@visibleForTesting
bool isRealtimeBoostFromCurrentUser(Boost boost, User? currentUser) {
  if (currentUser == null) return false;
  if (boost.user.id != 0 && boost.user.id == currentUser.id) {
    return true;
  }
  return boost.user.username.isNotEmpty &&
      boost.user.username == currentUser.username;
}

@visibleForTesting
bool resolveCanBoostAfterRealtimeBoost({
  required bool currentCanBoost,
  required Boost newBoost,
  required User? currentUser,
}) {
  return isRealtimeBoostFromCurrentUser(newBoost, currentUser)
      ? false
      : currentCanBoost;
}

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

    // refreshPost 网络响应落地(msgbus acted/revised/deleted 的真正
    // 高度变化时刻,与发起请求隔了一次网络往返):在这里武装锚定哨兵
    // 才能覆盖到落地帧;在消息分发处武装会因异步而错帧失效。
    AnchorGuardSliver.arm();

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
  ///
  /// 单解决方案模式(`solved_allow_multiple_solutions=false`):接受新答案时清空其他;
  /// 多解决方案模式:仅切换当前 post,其他保留。
  void updatePostSolution(int postId, bool accepted) {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    final allowMultiple = PreloadedDataService()
            .siteSettingsSync?['solved_allow_multiple_solutions'] ==
        true;

    final currentPosts = currentDetail.postStream.posts;
    final newPosts = currentPosts.map((post) {
      if (post.id == postId) {
        return post.copyWith(
          acceptedAnswer: accepted,
          canUnacceptAnswer: accepted,
        );
      } else if (accepted && !allowMultiple && post.acceptedAnswer) {
        return post.copyWith(
          acceptedAnswer: false,
          canUnacceptAnswer: false,
        );
      }
      return post;
    }).toList();

    // 从 newPosts 中按 acceptedAnswer 反查构造 AcceptedAnswer 列表
    // (post 自身已包含 username/name/avatarTemplate/cooked/createdAt,
    //  足以本地渲染 banner,无需等待后端二次拉取)
    final newAcceptedAnswers = newPosts
        .where((p) => p.acceptedAnswer)
        .map((p) => AcceptedAnswer.fromPost(p))
        .toList()
      ..sort((a, b) => a.postNumber.compareTo(b.postNumber));

    state = AsyncValue.data(currentDetail.copyWith(
      postStream: PostStream(
        posts: newPosts,
        stream: currentDetail.postStream.stream,
        gaps: currentDetail.postStream.gaps,
      ),
      acceptedAnswers: newAcceptedAnswers,
    ));
  }

  /// 添加新创建的帖子到列表（用于回复后直接更新）
  ///
  /// [wasAtBottom] 调用方在打开回复面板前捕获的快照，用于解决 MessageBus
  /// created 事件先于 API 响应到达、将 _hasMoreAfter 改为 true 的竞态问题。
  bool addPost(Post post, {bool wasAtBottom = false}) {
    final currentDetail = state.value;
    if (currentDetail == null) return false;

    final currentPosts = currentDetail.postStream.posts;

    if (currentPosts.any((p) => p.id == post.id)) return true;

    final currentStream = currentDetail.postStream.stream;
    final alreadyInStream = currentStream.contains(post.id);

    final newStream = [...currentStream];
    if (!alreadyInStream) {
      newStream.add(post.id);
    }

    if (!_hasMoreAfter || wasAtBottom) {
      final newPosts = [...currentPosts, post];
      newPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));

      // onNewPostCreated 可能已递增过 postsCount，避免双重递增
      final newPostsCount = alreadyInStream
          ? currentDetail.postsCount
          : currentDetail.postsCount + 1;

      state = AsyncValue.data(currentDetail.copyWith(
        postsCount: newPostsCount,
        postStream: PostStream(posts: newPosts, stream: newStream, gaps: currentDetail.postStream.gaps),
      ));

      // MessageBus 可能已将 _hasMoreAfter 设为 true，插入帖子后修正
      _updateBoundaryState(newPosts, newStream);

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

  /// 挂入一条当前用户的待审核回复(发帖 enqueued 后即时展示在底部待审块)
  void addPendingPost(PendingPost pending) {
    final currentDetail = state.value;
    if (currentDetail == null) return;
    if (currentDetail.pendingPosts.any((p) => p.id == pending.id)) return;

    state = AsyncValue.data(currentDetail.copyWith(
      pendingPosts: [...currentDetail.pendingPosts, pending],
    ));
  }

  /// 移除待审核回复(撤回成功后)
  void removePendingPost(int reviewableId) {
    final currentDetail = state.value;
    if (currentDetail == null) return;
    if (!currentDetail.pendingPosts.any((p) => p.id == reviewableId)) return;

    state = AsyncValue.data(currentDetail.copyWith(
      pendingPosts: currentDetail.pendingPosts
          .where((p) => p.id != reviewableId)
          .toList(),
    ));
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

  /// 更新 "俺也一样" (shared_issue) 状态
  void updateSharedIssue(int newCount, bool userCreated) {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    state = AsyncValue.data(currentDetail.copyWith(
      sharedIssueCount: newCount,
      userCreatedSharedIssue: userCreated,
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
      // boost_added 会广播给所有浏览者；消息本身不携带当前用户的
      // can_boost 重新计算结果，只有自己的 boost 才应消耗本地权限。
      final currentUser = ref.read(currentUserProvider).value;
      final canBoost = resolveCanBoostAfterRealtimeBoost(
        currentCanBoost: post.canBoost,
        newBoost: newBoost,
        currentUser: currentUser,
      );
      return post.copyWith(boosts: currentBoosts, canBoost: canBoost);
    });
  }

  /// 从帖子移除 Boost（用于 MessageBus boost_removed 消息）
  void removeBoostFromPost(int postId, int boostId) {
    _updatePostById(postId, (post) {
      final currentBoosts = List<Boost>.from(post.boosts ?? []);
      currentBoosts.removeWhere((b) => b.id == boostId);
      // 删除后可能恢复 canBoost，但这取决于是否是自己的 boost
      // 由于 MessageBus 不携带这个信息，保守处理不改变 canBoost
      return post.copyWith(boosts: currentBoosts);
    });
  }

  /// 本地创建 Boost 落地(自己在帖脚发的,与 msgbus 回声幂等去重)。
  ///
  /// boost 是弹幕层/列表/action bar 共用的 provider 数据 —— 此前只写
  /// footer 本地 state,弹幕模式读不到,自己刚发的 boost 直接消失。
  void applyLocalBoostCreated(int postId, Boost boost) {
    _updatePostById(postId, (post) {
      final currentBoosts = List<Boost>.from(post.boosts ?? []);
      if (currentBoosts.any((b) => b.id == boost.id)) return post;
      currentBoosts.add(boost);
      // 自己发的必然消耗本地 boost 权限
      return post.copyWith(boosts: currentBoosts, canBoost: false);
    });
  }

  /// 本地删除 Boost 落地;删自己的才恢复 canBoost(调用方判定)。
  void applyLocalBoostDeleted(
    int postId,
    int boostId, {
    required bool restoreCanBoost,
  }) {
    _updatePostById(postId, (post) {
      final currentBoosts = List<Boost>.from(post.boosts ?? []);
      currentBoosts.removeWhere((b) => b.id == boostId);
      return post.copyWith(
        boosts: currentBoosts,
        canBoost: restoreCanBoost ? true : post.canBoost,
      );
    });
  }

  /// 本地更新单条 Boost(举报后补拉详情等);不存在则忽略。
  void applyLocalBoostChanged(int postId, Boost boost) {
    _updatePostById(postId, (post) {
      final currentBoosts = List<Boost>.from(post.boosts ?? []);
      final index = currentBoosts.indexWhere((b) => b.id == boost.id);
      if (index == -1) return post;
      currentBoosts[index] = boost;
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
        acceptedAnswers: newDetail.acceptedAnswers,
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
