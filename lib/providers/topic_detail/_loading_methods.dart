part of '../topic_detail_provider.dart';

// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// 加载相关方法
extension LoadingMethods on TopicDetailNotifier {
  /// 加载更早的帖子（向上滚动）
  Future<void> loadPrevious() async {
    if (_isLoadPreviousFailed) return; // 失败后需手动重试
    if (_isFilteredMode) {
      if (!_hasMoreBefore || state.isLoading || _isLoadingPrevious) return;
      await _loadPreviousByStreamIds();
      return;
    }
    if (!_hasMoreBefore || state.isLoading || _isLoadingPrevious) return;
    _isLoadingPrevious = true;

    try {
      // ignore: invalid_use_of_internal_member
      state = const AsyncLoading<TopicDetail>().copyWithPrevious(state);

      final result = await AsyncValue.guard(() async {
        final currentDetail = state.requireValue;
        final currentPosts = currentDetail.postStream.posts;
        final stream = currentDetail.postStream.stream;

        if (currentPosts.isEmpty) {
          _hasMoreBefore = false;
          return currentDetail;
        }

        final firstPostId = currentPosts.first.id;
        final firstIndex = stream.indexOf(firstPostId);
        if (firstIndex <= 0) {
          _hasMoreBefore = false;
          return currentDetail;
        }

        final firstPostNumber = currentPosts.first.postNumber;
        final service = ref.read(discourseServiceProvider);
        final newPostStream = await service.getPostsByNumber(
          arg.topicId,
          postNumber: firstPostNumber,
          asc: false,
        );

        final existingIds = currentPosts.map((p) => p.id).toSet();
        final newPosts = newPostStream.posts.where((p) => !existingIds.contains(p.id)).toList();
        final mergedPosts = [...newPosts, ...currentPosts];
        mergedPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));

        final currentStream = currentDetail.postStream.stream;
        final existingStreamIds = currentStream.toSet();
        final newPostIds = newPosts.map((p) => p.id).where((id) => !existingStreamIds.contains(id)).toList();
        final mergedStream = [...newPostIds, ...currentStream];

        final newFirstId = mergedPosts.first.id;
        final newFirstIndex = mergedStream.indexOf(newFirstId);
        _hasMoreBefore = newFirstIndex > 0;

        return currentDetail.copyWith(
          postStream: PostStream(posts: mergedPosts, stream: mergedStream, gaps: currentDetail.postStream.gaps),
        );
      });
      if (!ref.mounted) return;
      if (result.hasError) {
        _isLoadPreviousFailed = true;
        // 恢复之前的数据状态，不让 UI 显示全局错误
        state = AsyncValue.data(state.requireValue);
      } else {
        state = result;
      }
    } finally {
      _isLoadingPrevious = false;
    }
  }

  /// 手动重试加载更早的帖子
  Future<void> retryLoadPrevious() async {
    _isLoadPreviousFailed = false;
    await loadPrevious();
  }

  /// 加载更多回复（向下滚动）
  Future<void> loadMore() async {
    if (_isLoadMoreFailed) return; // 失败后需手动重试
    if (!_hasMoreAfter || state.isLoading || _isLoadingMore || _isLoadingNewPosts) return;

    if (_isFilteredMode) {
      await _loadMoreByStreamIds();
      return;
    }
    _isLoadingMore = true;

    try {
      // ignore: invalid_use_of_internal_member
      state = const AsyncLoading<TopicDetail>().copyWithPrevious(state);

      final result = await AsyncValue.guard(() async {
        final currentDetail = state.requireValue;
        final currentPosts = currentDetail.postStream.posts;
        final stream = currentDetail.postStream.stream;

        if (currentPosts.isEmpty) {
          _hasMoreAfter = false;
          return currentDetail;
        }

        final lastPostId = currentPosts.last.id;
        final lastIndex = stream.indexOf(lastPostId);
        if (lastIndex == -1 || lastIndex >= stream.length - 1) {
          _hasMoreAfter = false;
          return currentDetail;
        }

        final lastPostNumber = currentPosts.last.postNumber;
        final service = ref.read(discourseServiceProvider);
        final newPostStream = await service.getPostsByNumber(
          arg.topicId,
          postNumber: lastPostNumber,
          asc: true,
        );

        final existingIds = currentPosts.map((p) => p.id).toSet();
        final newPosts = newPostStream.posts.where((p) => !existingIds.contains(p.id)).toList();
        final mergedPosts = [...currentPosts, ...newPosts];
        mergedPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));

        final currentStream = currentDetail.postStream.stream;
        final existingStreamIds = currentStream.toSet();
        final newPostIds = newPosts.map((p) => p.id).where((id) => !existingStreamIds.contains(id)).toList();
        final mergedStream = [...currentStream, ...newPostIds];

        final newLastId = mergedPosts.last.id;
        final newLastIndex = mergedStream.indexOf(newLastId);
        _hasMoreAfter = newLastIndex < mergedStream.length - 1;

        return currentDetail.copyWith(
          postStream: PostStream(posts: mergedPosts, stream: mergedStream, gaps: currentDetail.postStream.gaps),
        );
      });
      if (!ref.mounted) return;
      if (result.hasError) {
        _isLoadMoreFailed = true;
        state = AsyncValue.data(state.requireValue);
      } else {
        state = result;
      }
    } finally {
      _isLoadingMore = false;
    }
  }

  /// 手动重试加载更多
  Future<void> retryLoadMore() async {
    _isLoadMoreFailed = false;
    await loadMore();
  }

  /// 收到新回复通知（MessageBus created 消息）
  /// 对齐 Discourse：不在底部时只更新 stream，在底部时批量加载帖子内容
  void onNewPostCreated(int postId) {
    if (state.isLoading) return;
    if (_isFilteredMode) return;

    final currentDetail = state.value;
    if (currentDetail == null) return;

    final currentStream = currentDetail.postStream.stream;
    if (currentStream.contains(postId)) return; // 已在 stream 中

    // 对齐 Discourse triggerNewPostsInStream：先基于旧边界判断是否已加载到底部，
    // 再更新 stream。否则新 postId 先进入 stream 后，_hasMoreAfter 会立即变成 true，
    // 导致“本来在底部却不自动加载新帖内容”。
    final wasLoadedAllPosts = !_hasMoreAfter;

    // 将 post ID 加入 stream 并更新 postsCount（本地即时更新，无需请求）
    final newStream = [...currentStream, postId];
    state = AsyncValue.data(currentDetail.copyWith(
      postsCount: currentDetail.postsCount + 1,
      postStream: PostStream(
        posts: currentDetail.postStream.posts,
        stream: newStream,
        gaps: currentDetail.postStream.gaps,
      ),
    ));
    _updateBoundaryState(currentDetail.postStream.posts, newStream);

    // 对齐 Discourse loadedAllPosts：收到新帖前已加载到底部时才批量拉取新帖子内容，
    // 否则只更新 stream（用户滚到底部时通过 loadMore 自然加载）。
    if (wasLoadedAllPosts) {
      _pendingNewPostIds.add(postId);
      _loadPendingNewPosts();
    }
  }

  /// 批量加载待处理的新帖子（对齐 Discourse triggerNewPostsInStream）
  Future<void> _loadPendingNewPosts() async {
    if (_isLoadingNewPosts) return;
    if (_pendingNewPostIds.isEmpty) return;

    _isLoadingNewPosts = true;
    final postIds = List<int>.from(_pendingNewPostIds);
    _pendingNewPostIds.clear();

    try {
      final service = ref.read(discourseServiceProvider);
      final postStream = await service.getPosts(arg.topicId, postIds);
      final fetchedPosts = postStream.posts;

      if (fetchedPosts.isEmpty || !ref.mounted) return;

      final currentDetail = state.value;
      if (currentDetail == null) return;

      final currentPosts = currentDetail.postStream.posts;
      final existingIds = currentPosts.map((p) => p.id).toSet();
      final newPosts = fetchedPosts.where((p) => !existingIds.contains(p.id)).toList();
      if (newPosts.isEmpty) return;

      // 本地递增被回复帖子的 replyCount（与 Discourse 官方做法一致）
      final replyToNumbers = <int>{};
      for (final p in newPosts) {
        if (p.replyToPostNumber > 0) {
          replyToNumbers.add(p.replyToPostNumber);
        }
      }
      final updatedCurrentPosts = replyToNumbers.isEmpty
          ? currentPosts
          : currentPosts.map((p) {
              if (replyToNumbers.contains(p.postNumber)) {
                return p.copyWith(replyCount: p.replyCount + 1);
              }
              return p;
            }).toList();

      final mergedPosts = [...updatedCurrentPosts, ...newPosts];
      mergedPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));

      _updateBoundaryState(mergedPosts, currentDetail.postStream.stream);

      state = AsyncValue.data(currentDetail.copyWith(
        postStream: PostStream(
          posts: mergedPosts,
          stream: currentDetail.postStream.stream,
          gaps: currentDetail.postStream.gaps,
        ),
      ));
    } catch (e) {
      // 失败时将 post IDs 放回队列
      _pendingNewPostIds.insertAll(0, postIds);
      debugPrint('[TopicDetail] 加载新回复失败: $e');
    } finally {
      _isLoadingNewPosts = false;
      // 如果在加载期间又有新帖子进入队列，继续加载
      if (_pendingNewPostIds.isNotEmpty) {
        _loadPendingNewPosts();
      }
    }
  }

  /// 使用新的起始帖子号重新加载数据
  ///
  /// 使用 copyWithPrevious 保留旧 detail，避免 loading 期间 detail==null
  /// 把整页（含底栏 Overlay）换成纯骨架。
  Future<void> reloadWithPostNumber(int postNumber) async {
    _hasMoreAfter = true;
    _hasMoreBefore = true;
    _isLoadMoreFailed = false;
    _isLoadPreviousFailed = false;

    // ignore: invalid_use_of_internal_member
    state = const AsyncLoading<TopicDetail>().copyWithPrevious(state);

    await Future.delayed(Duration.zero);

    final result = await AsyncValue.guard(() async {
      final service = ref.read(discourseServiceProvider);
      final detail = await service.getTopicDetail(
        arg.topicId,
        postNumber: postNumber,
        filter: _filter,
        usernameFilters: _usernameFilter,
        filterTopLevelReplies: _filterTopLevelReplies,
      );

      _updateBoundaryState(detail.postStream.posts, detail.postStream.stream);

      return detail;
    });
    if (!ref.mounted) return;
    state = result;
  }

  /// 刷新当前话题详情（保持列表可见）
  Future<void> refreshWithPostNumber(int postNumber) async {
    if (state.isLoading) return;
    _isLoadMoreFailed = false;
    _isLoadPreviousFailed = false;

    // ignore: invalid_use_of_internal_member
    state = const AsyncLoading<TopicDetail>().copyWithPrevious(state);

    final result = await AsyncValue.guard(() async {
      final service = ref.read(discourseServiceProvider);
      final detail = await service.getTopicDetail(
        arg.topicId,
        postNumber: _isFilteredMode ? null : postNumber,
        filter: _filter,
        usernameFilters: _usernameFilter,
      );

      _updateBoundaryState(detail.postStream.posts, detail.postStream.stream);

      return detail;
    });
    if (!ref.mounted) return;
    state = result;
  }

  /// 加载指定楼层的帖子（用于跳转）
  Future<int> loadPostNumber(int postNumber) async {
    final currentDetail = state.value;
    if (currentDetail == null) return -1;

    final currentPosts = currentDetail.postStream.posts;

    final existingIndex = currentPosts.indexWhere((p) => p.postNumber == postNumber);
    if (existingIndex != -1) return existingIndex;

    try {
      final service = ref.read(discourseServiceProvider);
      final newDetail = await service.getTopicDetail(arg.topicId, postNumber: postNumber);

      final existingIds = currentPosts.map((p) => p.id).toSet();
      final newPosts = newDetail.postStream.posts.where((p) => !existingIds.contains(p.id)).toList();
      final mergedPosts = [...currentPosts, ...newPosts];
      mergedPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));

      final currentStream = currentDetail.postStream.stream;
      final newStream = newDetail.postStream.stream;
      final existingStreamIds = currentStream.toSet();
      final newStreamIds = newStream.where((id) => !existingStreamIds.contains(id)).toList();
      final mergedStream = [...currentStream, ...newStreamIds];

      _updateBoundaryState(mergedPosts, mergedStream);

      if (!ref.mounted) return -1;
      state = AsyncValue.data(currentDetail.copyWith(
        postStream: PostStream(posts: mergedPosts, stream: mergedStream, gaps: currentDetail.postStream.gaps),
      ));

      return mergedPosts.indexWhere((p) => p.postNumber == postNumber);
    } catch (e) {
      debugPrint('[TopicDetail] 加载帖子 #$postNumber 失败: $e');
      return -1;
    }
  }
}
