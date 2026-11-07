// ignore_for_file: invalid_use_of_protected_member

part of '../post_footer_section.dart';

extension _PostFooterReactionActions on _PostFooterSectionState {
  void _syncReactionToProvider(List<PostReaction> reactions, PostReaction? currentUserReaction) {
    // 经活跃实例注册表找回页面 provider:页面 params 带 UUID instanceId,
    // 这里凭 topicId 直接 new 一个空 instanceId 的 params 只会命中(并
    // 凭空创建+全量拉取)一个孤儿实例,更新落不到在显示的数据上。
    final params = TopicDetailNotifier.activeParamsFor(widget.topicId);
    if (params == null) return;

    try {
      ref
          .read(topicDetailProvider(params).notifier)
          .updatePostReaction(widget.post.id, reactions, currentUserReaction);
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  Future<void> _toggleLike() async {
    if (_isLiking) return;

    HapticFeedback.lightImpact();
    setState(() => _isLiking = true);
    try {
      await _submitReaction(_currentUserReaction?.id ?? 'heart');
    } finally {
      if (mounted) {
        setState(() => _isLiking = false);
      }
    }
  }

  Future<void> _toggleReaction(String reactionId) =>
      _submitReaction(reactionId);

  /// 乐观切换回应(同官方 discourse-reactions 的 toggleReaction):
  /// 先在本地改好计数与「我的回应」立即显示,再提交;失败回滚。
  ///
  /// 乐观状态**同时写进页面 provider**,并在请求在途期间挡住帖子对象
  /// 替换回写(见 [_PostFooterSectionState._pendingReactions])。服务端
  /// 切换回应时会先后推送 liked(只带点赞数)、acted —— 页面收到 liked
  /// 就用 provider 里的帖子换掉本楼的 post,此前 provider 还是旧回应,
  /// footer 被同步回旧状态,接口返回后又切回来:选中 → 空 → 选中。
  ///
  /// 连续快速切换时只认最后一次提交的结果:早发出的请求晚回来,
  /// 不能拿它的(已过期)状态覆盖当前显示。
  Future<void> _submitReaction(String reactionId) async {
    final saved = (_reactions, _currentUserReaction);
    final seq = ++_reactionSeq;
    _pendingReactions++;
    setState(() {
      final next = applyReactionToggle(
        _reactions,
        _currentUserReaction,
        reactionId,
      );
      _reactions = next.$1;
      _currentUserReaction = next.$2;
    });
    _syncReactionToProvider(_reactions, _currentUserReaction);

    try {
      final result = await _service.toggleReaction(widget.post.id, reactionId);
      if (!mounted || seq != _reactionSeq) return;

      setState(() {
        _reactions = result['reactions'] as List<PostReaction>;
        _currentUserReaction = result['currentUserReaction'] as PostReaction?;
      });

      _syncReactionToProvider(_reactions, _currentUserReaction);
    } catch (e, s) {
      if (mounted && seq == _reactionSeq) {
        setState(() {
          _reactions = saved.$1;
          _currentUserReaction = saved.$2;
        });
        _syncReactionToProvider(_reactions, _currentUserReaction);
      }
      // 网络错误已由 ErrorInterceptor 处理
      if (e is! DioException) AppErrorHandler.handleUnexpected(e, s);
    } finally {
      _pendingReactions--;
    }
  }

  void _showReactionUsers(BuildContext context, {String? reactionId}) {
    showAppBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => PostReactionUsersSheet(
        postId: widget.post.id,
        initialReactionId: reactionId,
      ),
    );
  }
}
