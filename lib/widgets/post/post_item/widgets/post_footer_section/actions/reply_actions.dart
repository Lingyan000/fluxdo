part of '../post_footer_section.dart';

extension _PostFooterReplyActions on _PostFooterSectionState {
  void _saveRepliesSnapshot({bool? expanded}) {
    _inlineStore?.save(
      InlinePostsKind.replies,
      _postId,
      posts: _replies,
      expanded: expanded ?? _showRepliesNotifier.value,
    );
  }

  Future<void> _loadReplies() async {
    if (_isLoadingRepliesNotifier.value) return;

    _isLoadingRepliesNotifier.value = true;
    try {
      final after = _replies.isNotEmpty ? _replies.last.postNumber : 1;
      final replies = await _service.getPostReplies(
        widget.post.id,
        after: after,
      );
      // 加载期间滑出屏幕也落快照,回来时直接是完整列表
      _replies.addAll(replies);
      _saveRepliesSnapshot(expanded: true);
      if (mounted) {
        _isLoadingRepliesNotifier.value = false;
      }
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
      if (mounted) {
        _isLoadingRepliesNotifier.value = false;
      }
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
      if (mounted) {
        _isLoadingRepliesNotifier.value = false;
      }
    }
  }

  Future<void> _toggleReplies() async {
    // 过滤模式：打开弹框展示递归回复
    if (widget.useReplyDialog) {
      showPostRepliesSheet(
        context: context,
        post: widget.post,
        topicId: widget.topicId,
        topicTitle: widget.topicTitle,
        isPrivateMessageTopic: widget.isPrivateMessageTopic,
        isPmWithNonHumanUser: widget.isPmWithNonHumanUser,
        onJumpToPost: widget.onJumpToPost,
      );
      return;
    }

    // 普通模式：内联展开直接回复
    if (_showRepliesNotifier.value) {
      _showRepliesNotifier.value = false;
      return;
    }

    if (_replies.isNotEmpty) {
      _showRepliesNotifier.value = true;
      return;
    }

    if (_isLoadingRepliesNotifier.value) return;

    _isLoadingRepliesNotifier.value = true;
    try {
      final replies = await _service.getPostReplies(widget.post.id, after: 1);
      if (mounted) {
        _replies.addAll(replies);
        _isLoadingRepliesNotifier.value = false;
        _showRepliesNotifier.value = true;
      } else {
        // 加载期间滑出屏幕:按用户意图记为已展开,回来时直接恢复
        _replies.addAll(replies);
        _saveRepliesSnapshot(expanded: replies.isNotEmpty);
      }
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
      if (mounted) {
        _isLoadingRepliesNotifier.value = false;
      }
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
      if (mounted) {
        _isLoadingRepliesNotifier.value = false;
      }
    }
  }
}
