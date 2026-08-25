part of '../topic_detail_provider.dart';

// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// 过滤模式相关方法
extension FilterMethods on TopicDetailNotifier {
  /// 切换到热门回复模式
  Future<void> showTopReplies() async {
    if (_filter == 'summary') return;
    _filter = 'summary';
    _usernameFilter = null;
    _filterTopLevelReplies = false;
    await _reloadWithFilter();
  }

  /// 切换到按活动排序(post-voting 问答话题:默认视图是按票排序,
  /// filter=activity 走时间流并恢复显示对答案的回复)
  Future<void> showByActivity() async {
    if (_filter == 'activity') return;
    _filter = 'activity';
    _usernameFilter = null;
    _filterTopLevelReplies = false;
    await _reloadWithFilter();
  }

  /// 切换到只看题主模式
  Future<void> showAuthorOnly(String username) async {
    if (_usernameFilter == username) return;
    _usernameFilter = username;
    _filter = null;
    _filterTopLevelReplies = false;
    await _reloadWithFilter();
  }

  /// 切换到只看顶层回复模式
  Future<void> showTopLevelReplies() async {
    if (_filterTopLevelReplies) return;

    // 保存主贴（filter_top_level_replies 不返回主贴）
    Post? savedFirstPost;
    if (state.hasValue) {
      final posts = state.requireValue.postStream.posts;
      final idx = posts.indexWhere((p) => p.postNumber == 1);
      if (idx != -1) savedFirstPost = posts[idx];
    }

    _filterTopLevelReplies = true;
    _filter = null;
    _usernameFilter = null;
    await _reloadWithFilter();

    // 主贴不在当前数据中，单独请求
    if (savedFirstPost == null && ref.mounted) {
      try {
        final service = ref.read(discourseServiceProvider);
        savedFirstPost = await service.getPostByNumber(arg.topicId, 1);
      } catch (_) {
        // 加载失败不影响主流程
      }
    }

    // 补回主贴
    if (ref.mounted) _prependFirstPost(savedFirstPost);
  }

  /// 补回主贴到 posts 和 stream 开头
  void _prependFirstPost(Post? firstPost) {
    if (firstPost == null || !state.hasValue) return;
    final detail = state.requireValue;
    final posts = detail.postStream.posts;
    if (posts.any((p) => p.postNumber == 1)) return; // 已有主贴

    final updatedPosts = [firstPost, ...posts];
    final stream = detail.postStream.stream;
    final updatedStream = stream.contains(firstPost.id)
        ? stream
        : [firstPost.id, ...stream];

    state = AsyncValue.data(
      detail.copyWith(
        postStream: PostStream(
          posts: updatedPosts,
          stream: updatedStream,
          gaps: detail.postStream.gaps,
        ),
      ),
    );
  }

  /// 取消过滤，显示全部回复
  Future<void> cancelFilter() async {
    if (_filter == null && _usernameFilter == null && !_filterTopLevelReplies) {
      return;
    }
    _filter = null;
    _usernameFilter = null;
    _filterTopLevelReplies = false;
    await _reloadWithFilter();
  }

  /// 取消过滤并跳转到指定帖子
  Future<void> cancelFilterAndReloadWithPostNumber(int postNumber) async {
    _filter = null;
    _usernameFilter = null;
    _filterTopLevelReplies = false;
    state = const AsyncValue.loading();
    _hasMoreAfter = true;
    _hasMoreBefore = true;
    _isLoadMoreFailed = false;
    _isLoadPreviousFailed = false;

    await Future.delayed(Duration.zero);

    final result = await AsyncValue.guard(() async {
      final service = ref.read(discourseServiceProvider);
      final detail = await service.getTopicDetail(
        arg.topicId,
        postNumber: postNumber,
        filter: _filter,
        usernameFilters: _usernameFilter,
      );

      _updateBoundaryState(detail.postStream.posts, detail.postStream.stream);

      return _withSuggestedCache(detail);
    });
    if (!ref.mounted) return;
    state = result;
  }

  /// 使用当前 filter 重新加载数据
  Future<void> _reloadWithFilter() async {
    state = const AsyncValue.loading();
    _hasMoreAfter = true;
    _hasMoreBefore = true;
    _isLoadMoreFailed = false;
    _isLoadPreviousFailed = false;

    final result = await AsyncValue.guard(() async {
      final service = ref.read(discourseServiceProvider);
      final detail = await service.getTopicDetail(
        arg.topicId,
        filter: _filter,
        usernameFilters: _usernameFilter,
        filterTopLevelReplies: _filterTopLevelReplies,
      );

      _updateBoundaryState(detail.postStream.posts, detail.postStream.stream);

      return _withSuggestedCache(detail);
    });
    if (!ref.mounted) return;
    state = result;
  }

  /// 过滤模式下根据 stream ID 加载更多帖子
  Future<void> _loadMoreByStreamIds() async {
    if (_isLoadMoreFailed) return; // 失败后需手动重试
    _isLoadingMore = true;

    try {
      // 分页 spinner 由 loadingMoreListenable 驱动,不发射 AsyncLoading
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

        final nextIds = stream.sublist(
          lastIndex + 1,
          (lastIndex + 21).clamp(0, stream.length),
        );

        if (nextIds.isEmpty) {
          _hasMoreAfter = false;
          return currentDetail;
        }

        final service = ref.read(discourseServiceProvider);
        final newPostStream = await service.getPosts(
          arg.topicId,
          nextIds,
          // 过滤模式下服务端同样不下发推荐话题,靠这一次翻页补
          includeSuggested: currentDetail.suggestedTopics.isEmpty,
        );

        final existingIds = currentPosts.map((p) => p.id).toSet();
        final newPosts = newPostStream.posts
            .where((p) => !existingIds.contains(p.id))
            .toList();
        final mergedPosts = [...currentPosts, ...newPosts];
        final streamPosition = <int, int>{
          for (var i = 0; i < stream.length; i++) stream[i]: i,
        };
        mergedPosts.sort(
          (a, b) => (streamPosition[a.id] ?? stream.length).compareTo(
            streamPosition[b.id] ?? stream.length,
          ),
        );

        final newLastId = mergedPosts.last.id;
        final newLastIndex = stream.indexOf(newLastId);
        _hasMoreAfter = newLastIndex < stream.length - 1;

        return _withSuggestedCache(currentDetail.copyWith(
          postStream: PostStream(posts: mergedPosts, stream: stream, gaps: currentDetail.postStream.gaps),
          suggestedTopics: newPostStream.suggestedTopics.isNotEmpty
              ? newPostStream.suggestedTopics
              : null,
          relatedTopics: newPostStream.relatedTopics.isNotEmpty
              ? newPostStream.relatedTopics
              : null,
        ));
      });
      if (!ref.mounted) return;
      if (result.hasError) {
        // 未发射过 AsyncLoading,state 仍是原 AsyncData,无需恢复
        _isLoadMoreFailed = true;
      } else {
        state = result;
      }
    } finally {
      _isLoadingMore = false;
    }
  }

  /// 过滤模式下根据 stream ID 加载更早的帖子
  Future<void> _loadPreviousByStreamIds() async {
    if (_isLoadPreviousFailed) return; // 失败后需手动重试
    _isLoadingPrevious = true;

    try {
      // 分页 spinner 由 loadingPreviousListenable 驱动,不发射 AsyncLoading
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

        final start = (firstIndex - 20).clamp(0, firstIndex);
        final prevIds = stream.sublist(start, firstIndex);

        if (prevIds.isEmpty) {
          _hasMoreBefore = false;
          return currentDetail;
        }

        final service = ref.read(discourseServiceProvider);
        final newPostStream = await service.getPosts(arg.topicId, prevIds);

        final existingIds = currentPosts.map((p) => p.id).toSet();
        final newPosts = newPostStream.posts
            .where((p) => !existingIds.contains(p.id))
            .toList();
        final mergedPosts = [...currentPosts, ...newPosts];
        final streamPosition = <int, int>{
          for (var i = 0; i < stream.length; i++) stream[i]: i,
        };
        mergedPosts.sort(
          (a, b) => (streamPosition[a.id] ?? stream.length).compareTo(
            streamPosition[b.id] ?? stream.length,
          ),
        );

        final newFirstId = mergedPosts.first.id;
        final newFirstIndex = stream.indexOf(newFirstId);
        _hasMoreBefore = newFirstIndex > 0;

        return currentDetail.copyWith(
          postStream: PostStream(
            posts: mergedPosts,
            stream: stream,
            gaps: currentDetail.postStream.gaps,
          ),
        );
      });
      if (!ref.mounted) return;
      if (result.hasError) {
        // 未发射过 AsyncLoading,state 仍是原 AsyncData,无需恢复
        _isLoadPreviousFailed = true;
      } else {
        state = result;
      }
    } finally {
      _isLoadingPrevious = false;
    }
  }
}
