part of '../topic_detail_page.dart';

// ignore_for_file: invalid_use_of_protected_member

/// 过滤模式相关方法
extension _FilterActions on _TopicDetailPageState {
  bool _detailHasTargetPost(
    TopicDetail detail, {
    int? postNumber,
    int? postId,
  }) {
    if (postId != null) {
      if (detail.postStream.stream.contains(postId)) return true;
      if (detail.postStream.posts.any((p) => p.id == postId)) return true;
    }
    if (postNumber != null) {
      if (detail.postStream.posts.any((p) => p.postNumber == postNumber))
        return true;
    }
    return false;
  }

  Future<void> _reloadWithFilterFallback({
    required int postNumber,
    int? postId,
  }) async {
    final params = _params;
    final notifier = ref.read(topicDetailProvider(params).notifier);
    final wasSummaryMode = notifier.isSummaryMode;
    final wasUsernameFilter = notifier.usernameFilter;
    final wasTopLevelMode = notifier.isTopLevelMode;

    setState(() => _isSwitchingMode = true);
    _controller.resetVisibility();

    try {
      await notifier.reloadWithPostNumber(postNumber);
      if (!mounted) return;

      final detail = ref.read(topicDetailProvider(params)).value;
      final hasTarget =
          detail != null &&
          _detailHasTargetPost(detail, postNumber: postNumber, postId: postId);
      final shouldFallback =
          detail != null &&
          _shouldFallbackFilter(
            detail,
            wasSummaryMode,
            wasUsernameFilter,
            wasTopLevelMode,
          );
      if (!hasTarget || shouldFallback) {
        _controller.resetVisibility();
        _controller.prepareJumpToPost(postNumber);
        await notifier.cancelFilterAndReloadWithPostNumber(postNumber);
      }
    } finally {
      if (mounted) {
        setState(() => _isSwitchingMode = false);
        _scheduleCheckTitleVisibility();
      }
    }
  }

  bool _shouldFallbackFilter(
    TopicDetail detail,
    bool wasSummaryMode,
    String? wasUsernameFilter,
    bool wasTopLevelMode,
  ) {
    if (wasSummaryMode) {
      if (!detail.hasSummary) return true;
      if (detail.postsCount > 0 &&
          detail.postStream.stream.length >= detail.postsCount) {
        return true;
      }
    }

    if (wasUsernameFilter != null && wasUsernameFilter.isNotEmpty) {
      // 服务端 username_filters 恒保留 1 楼(主帖作者未必是被过滤用户),
      // 判定"过滤是否真的生效"时要把主帖排除在外。
      final hasOtherUsers = detail.postStream.posts.any(
        (p) => p.postNumber != 1 && p.username != wasUsernameFilter,
      );
      if (hasOtherUsers) return true;
    }

    // 只看顶层模式下跳转到楼中楼帖子时需要取消过滤
    if (wasTopLevelMode) return true;

    return false;
  }

  Future<void> _handleShowTopReplies() async {
    final params = _params;
    final notifier = ref.read(topicDetailProvider(params).notifier);

    // 四项互斥单选：激活内容筛选时退出树形视图
    setState(() {
      _isSwitchingMode = true;
      _isNestedView = false;
    });

    _controller.prepareJumpToPost(1);
    _controller.skipNextJumpHighlight = true;
    _controller.resetVisibility();

    await notifier.showTopReplies();

    if (mounted) {
      setState(() => _isSwitchingMode = false);
      _scheduleCheckTitleVisibility();
    }
  }

  /// 问答话题:切到按活动排序(默认视图为按票,activity 走时间流)
  Future<void> _handleShowByActivity() async {
    final params = _params;
    final notifier = ref.read(topicDetailProvider(params).notifier);

    setState(() {
      _isSwitchingMode = true;
      _isNestedView = false;
    });

    _controller.prepareJumpToPost(1);
    _controller.skipNextJumpHighlight = true;
    _controller.resetVisibility();

    await notifier.showByActivity();

    if (mounted) {
      setState(() => _isSwitchingMode = false);
      _scheduleCheckTitleVisibility();
    }
  }

  Future<void> _handleCancelFilter() async {
    // 嵌套模式：直接退出，不需要重新加载
    if (_isNestedView) {
      setState(() => _isNestedView = false);
      _scheduleCheckTitleVisibility();
      return;
    }

    final params = _params;
    final notifier = ref.read(topicDetailProvider(params).notifier);

    setState(() => _isSwitchingMode = true);

    _controller.prepareJumpToPost(1);
    _controller.skipNextJumpHighlight = true;
    _controller.resetVisibility();

    await notifier.cancelFilter();

    if (mounted) {
      setState(() => _isSwitchingMode = false);
      _scheduleCheckTitleVisibility();
    }
  }

  Future<void> _handleShowTopLevelReplies() async {
    final params = _params;
    final notifier = ref.read(topicDetailProvider(params).notifier);

    // 四项互斥单选：激活内容筛选时退出树形视图
    setState(() {
      _isSwitchingMode = true;
      _isNestedView = false;
    });

    _controller.prepareJumpToPost(1);
    _controller.skipNextJumpHighlight = true;
    _controller.resetVisibility();

    try {
      await notifier.showTopLevelReplies();
    } finally {
      if (mounted) {
        setState(() => _isSwitchingMode = false);
        _scheduleCheckTitleVisibility();
      }
    }
  }

  Future<void> _handleShowAuthorOnly() async {
    final params = _params;
    final detail = ref.read(topicDetailProvider(params)).value;

    final authorUsername = detail?.createdBy?.username;
    if (authorUsername == null || authorUsername.isEmpty) return;

    await _handleShowUserOnly(authorUsername);
  }

  /// 只看指定用户的帖子(username_filters,对齐官方 filterParticipant)。
  /// 「只看作者」是它的特例;用户卡片/头像菜单的「只看 TA」传任意参与者。
  Future<void> _handleShowUserOnly(String username) async {
    if (username.isEmpty) return;
    final params = _params;
    final notifier = ref.read(topicDetailProvider(params).notifier);
    if (notifier.usernameFilter == username) return;

    // 四项互斥单选：激活内容筛选时退出树形视图
    setState(() {
      _isSwitchingMode = true;
      _isNestedView = false;
    });

    _controller.prepareJumpToPost(1);
    _controller.skipNextJumpHighlight = true;
    _controller.resetVisibility();

    await notifier.showAuthorOnly(username);

    if (mounted) {
      setState(() => _isSwitchingMode = false);
      _scheduleCheckTitleVisibility();
    }
  }

  /// 从菜单打开筛选面板
  void _showFilterSheet() {
    final params = _params;
    final notifier = ref.read(topicDetailProvider(params).notifier);
    final detail = ref.read(topicDetailProvider(params)).value;
    final hasActiveFilter =
        notifier.isSummaryMode ||
        notifier.isActivityMode ||
        notifier.isAuthorOnlyMode ||
        notifier.isTopLevelMode ||
        _isNestedView;
    // 用户过滤分两种:过滤对象=楼主 → 命中「只看作者」项;过滤对象=
    // 其他参与者(用户卡片发起) → 单列一项显示具体用户名
    final userFilter = notifier.usernameFilter;
    final isAuthorFilter =
        userFilter != null && userFilter == detail?.createdBy?.username;
    final isOtherUserFilter = userFilter != null && !isAuthorFilter;

    AppBottomSheet.show(
      context: context,
      contentPadding: EdgeInsets.zero,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 问答话题:默认按票排序,可切按活动(时间流)
            if (detail?.isPostVoting ?? false)
              ListTile(
                leading: const Icon(Symbols.history_rounded),
                title: Text(context.l10n.topicDetail_sortByActivity),
                trailing: notifier.isActivityMode
                    ? Icon(Symbols.check_rounded, color: theme.colorScheme.primary)
                    : null,
                onTap: () {
                  Navigator.pop(ctx);
                  if (notifier.isActivityMode) {
                    _handleCancelFilter();
                  } else {
                    _handleShowByActivity();
                  }
                },
              ),
            if (detail?.hasSummary ?? false)
              ListTile(
                leading: Icon(
                  notifier.isSummaryMode
                      ? Symbols.local_fire_department_rounded
                      : Symbols.local_fire_department_rounded,
                ),
                title: Text(context.l10n.topicDetail_hotOnly),
                trailing: notifier.isSummaryMode
                    ? Icon(Symbols.check_rounded, color: theme.colorScheme.primary)
                    : null,
                onTap: () {
                  Navigator.pop(ctx);
                  if (notifier.isSummaryMode) {
                    _handleCancelFilter();
                  } else {
                    _handleShowTopReplies();
                  }
                },
              ),
            ListTile(
              leading: Icon(
                Symbols.person_rounded,
                fill: isAuthorFilter ? 1 : 0,
              ),
              title: Text(context.l10n.topicDetail_authorOnly),
              trailing: isAuthorFilter
                  ? Icon(Symbols.check_rounded, color: theme.colorScheme.primary)
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                if (isAuthorFilter) {
                  _handleCancelFilter();
                } else {
                  _handleShowAuthorOnly();
                }
              },
            ),
            if (isOtherUserFilter)
              ListTile(
                leading: const Icon(Symbols.person_search_rounded, fill: 1),
                title: Text(context.l10n.topicDetail_userOnly(userFilter)),
                trailing: Icon(
                  Symbols.check_rounded,
                  color: theme.colorScheme.primary,
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _handleCancelFilter();
                },
              ),
            ListTile(
              leading: Icon(
                notifier.isTopLevelMode
                    ? Symbols.account_tree_rounded
                    : Symbols.account_tree_rounded,
              ),
              title: Text(context.l10n.topicDetail_topLevelOnly),
              trailing: notifier.isTopLevelMode
                  ? Icon(Symbols.check_rounded, color: theme.colorScheme.primary)
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                if (notifier.isTopLevelMode) {
                  _handleCancelFilter();
                } else {
                  _handleShowTopLevelReplies();
                }
              },
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              leading: Icon(Symbols.forum_rounded, fill: _isNestedView ? 1 : 0),
              title: Text(context.l10n.nested_title),
              trailing: _isNestedView
                  ? Icon(Symbols.check_rounded, color: theme.colorScheme.primary)
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                _toggleNestedView();
              },
            ),
            if (hasActiveFilter) ...[
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: Icon(
                  Symbols.filter_list_off_rounded,
                  color: theme.colorScheme.error,
                ),
                title: Text(
                  context.l10n.common_cancel,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _handleCancelFilter();
                },
              ),
            ],
          ],
        );
      },
    );
  }
}
