part of '../topic_detail_page.dart';

/// AppBar 相关的构建方法
extension _TopicDetailAppBar on _TopicDetailPageState {
  /// 构建带动画的 AppBar
  PreferredSizeWidget _buildAppBar({
    required ThemeData theme,
    required TopicDetail? detail,
    required TopicDetailNotifier notifier,
  }) {
    final searchState = ref.watch(topicSearchProvider(widget.topicId));

    // 搜索模式下的 AppBar
    if (searchState.isSearchMode) {
      return AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: theme.colorScheme.surface,
        title: TextField(
          controller: _searchController,
          focusNode: _searchFocusNode,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '在本话题中搜索...',
            border: InputBorder.none,
            hintStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          style: theme.textTheme.bodyLarge,
          textInputAction: TextInputAction.search,
          onSubmitted: (query) {
            ref.read(topicSearchProvider(widget.topicId).notifier).search(query);
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () {
              _searchController.clear();
              ref.read(topicSearchProvider(widget.topicId).notifier).exitSearchMode();
            },
          ),
        ],
      );
    }

    // 正常模式下的 AppBar
    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight),
      child: ValueListenableBuilder<bool>(
        valueListenable: _showTitleNotifier,
        builder: (context, showTitle, _) => ValueListenableBuilder<bool>(
          valueListenable: _isScrolledUnderNotifier,
          builder: (context, isScrolledUnder, _) => AnimatedBuilder(
            animation: _expandController,
            builder: (context, child) {
              final targetElevation = isScrolledUnder ? 3.0 : 0.0;
              final currentElevation = targetElevation * (1.0 - _expandController.value);
              final expandProgress = _expandController.value;
              final shouldShowTitle = showTitle || !_hasFirstPost;

              return AppBar(
                automaticallyImplyLeading: !widget.embeddedMode,
                elevation: currentElevation,
                scrolledUnderElevation: currentElevation,
                shadowColor: Colors.transparent,
                surfaceTintColor: theme.colorScheme.surfaceTint.withValues(alpha:(1.0 - expandProgress).clamp(0.0, 1.0)),
                backgroundColor: theme.colorScheme.surface,
                title: _buildAppBarTitle(
                  theme: theme,
                  detail: detail,
                  shouldShowTitle: shouldShowTitle,
                  expandProgress: expandProgress,
                ),
                centerTitle: false,
                actions: _buildAppBarActions(
                  detail: detail,
                  notifier: notifier,
                  shouldShowTitle: shouldShowTitle,
                  expandProgress: expandProgress,
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 构建 AppBar 标题
  Widget _buildAppBarTitle({
    required ThemeData theme,
    required TopicDetail? detail,
    required bool shouldShowTitle,
    required double expandProgress,
  }) {
    return Opacity(
      opacity: shouldShowTitle ? (1.0 - expandProgress).clamp(0.0, 1.0) : 0.0,
      child: GestureDetector(
        onTap: () {
          if (shouldShowTitle && detail != null) {
            _toggleExpandedHeader();
          }
        },
        child: Text.rich(
          TextSpan(
            style: theme.textTheme.titleMedium,
            children: [
              if (detail?.closed ?? false)
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      Icons.lock_outline,
                      size: 18,
                      color: theme.textTheme.titleMedium?.color ?? theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              if (detail?.hasAcceptedAnswer ?? false)
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      Icons.check_box,
                      size: 18,
                      color: Colors.green,
                    ),
                  ),
                ),
              ...EmojiText.buildEmojiSpans(context, detail?.title ?? widget.initialTitle ?? '', theme.textTheme.titleMedium),
            ],
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// 构建 AppBar Actions
  List<Widget> _buildAppBarActions({
    required TopicDetail? detail,
    required TopicDetailNotifier notifier,
    required bool shouldShowTitle,
    required double expandProgress,
  }) {
    if (detail == null) {
      return [];
    }

    // 编辑话题入口：可以编辑话题元数据 或 可以编辑首贴内容
    final firstPost = detail.postStream.posts.where((p) => p.postNumber == 1).firstOrNull;
    final canEditTopic = detail.canEdit || (firstPost?.canEdit ?? false);

    return [
      // 搜索按钮
      IconButton(
        icon: const Icon(Icons.search),
        tooltip: '搜索本话题',
        onPressed: () {
          ref.read(topicSearchProvider(widget.topicId).notifier).enterSearchMode();
        },
      ),
      // 更多选项
      PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert),
        tooltip: '更多选项',
        onSelected: (value) {
          if (value == 'subscribe') {
            showNotificationLevelSheet(
              context,
              detail.notificationLevel,
              (level) => _handleNotificationLevelChanged(notifier, level),
            );
          } else if (value == 'edit_topic') {
            _handleEditTopic();
          }
        },
        itemBuilder: (context) => [
          if (canEditTopic)
            PopupMenuItem(
              value: 'edit_topic',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.edit_outlined,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  const SizedBox(width: 12),
                  const Text('编辑话题'),
                ],
              ),
            ),
          PopupMenuItem(
            value: 'subscribe',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  TopicNotificationButton.getIcon(detail.notificationLevel),
                  size: 20,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                const SizedBox(width: 12),
                const Text('订阅设置'),
              ],
            ),
          ),
        ],
      ),
    ];
  }
}
