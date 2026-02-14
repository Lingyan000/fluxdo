part of '../topics_page.dart';

// ─── TopicList ───

/// 话题列表（每个 tab 一个实例，根据 categoryId + topicSortProvider 获取数据）
class _TopicList extends ConsumerStatefulWidget {
  final VoidCallback onLoginRequired;
  final int? categoryId;

  const _TopicList({
    super.key,
    required this.onLoginRequired,
    this.categoryId,
  });

  @override
  ConsumerState<_TopicList> createState() => _TopicListState();
}

class _TopicListState extends ConsumerState<_TopicList>
    with AutomaticKeepAliveClientMixin {
  bool _isLoadingNewTopics = false;

  @override
  bool get wantKeepAlive => true;

  /// 列表区域顶部圆角
  static const _topBorderRadius = BorderRadius.only(
    topLeft: Radius.circular(12),
    topRight: Radius.circular(12),
  );

  void scrollToTop() {
    final controller = PrimaryScrollController.maybeOf(context);
    controller?.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _openTopic(Topic topic) {
    final canShowDetailPane = MasterDetailLayout.canShowBothPanesFor(context);

    if (canShowDetailPane) {
      ref.read(selectedTopicProvider.notifier).select(
        topicId: topic.id,
        initialTitle: topic.title,
        scrollToPostNumber: topic.lastReadPostNumber,
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topic.id,
          initialTitle: topic.title,
          scrollToPostNumber: topic.lastReadPostNumber,
          autoSwitchToMasterDetail: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 需要
    final currentSort = ref.watch(topicSortProvider);
    final selectedTopicId = ref.watch(selectedTopicProvider).topicId;
    final providerKey = (currentSort, widget.categoryId);
    final topicsAsync = ref.watch(topicListProvider(providerKey));

    return topicsAsync.when(
      data: (topics) {
        if (topics.isEmpty) {
          return RefreshIndicator(
            onRefresh: () async {
              try {
                // ignore: unused_result
                await ref.refresh(topicListProvider(providerKey).future);
              } catch (e) {
                debugPrint('[TopicList] Refresh failed (empty): $e');
              }
            },
            child: ClipRRect(
              borderRadius: _topBorderRadius,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                children: const [
                  SizedBox(height: 100),
                  Center(child: Text('没有相关话题')),
                ],
              ),
            ),
          );
        }

        final incomingState = ref.watch(latestChannelProvider);
        final hasNewTopics = currentSort == TopicListFilter.latest
            && incomingState.hasIncomingForCategory(widget.categoryId);
        final newTopicCount = incomingState.incomingCountForCategory(widget.categoryId);
        final newTopicOffset = hasNewTopics ? 1 : 0;

        return RefreshIndicator(
          onRefresh: () async {
            try {
              // ignore: unused_result
              await ref.refresh(topicListProvider(providerKey).future);
            } catch (e) {
              debugPrint('[TopicList] Refresh failed: $e');
            }
            if (currentSort == TopicListFilter.latest) {
              ref.read(latestChannelProvider.notifier).clearNewTopicsForCategory(widget.categoryId);
            }
          },
          child: ClipRRect(
            borderRadius: _topBorderRadius,
            child: NotificationListener<ScrollUpdateNotification>(
              onNotification: (notification) {
                if (notification.depth == 0 &&
                    notification.metrics.pixels >= notification.metrics.maxScrollExtent - 200) {
                  ref.read(topicListProvider(providerKey).notifier).loadMore();
                }
                return false;
              },
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(top: 8, bottom: 12),
                cacheExtent: 1000,
                itemCount: topics.length + newTopicOffset + 1,
                itemBuilder: (context, index) {
                  if (hasNewTopics && index == 0) {
                    return _buildNewTopicIndicator(context, newTopicCount, providerKey);
                  }

                  final topicIndex = index - newTopicOffset;
                  if (topicIndex >= topics.length) {
                    return Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Center(
                        child: ref.watch(topicListProvider(providerKey).notifier).hasMore
                            ? const CircularProgressIndicator()
                            : const Text('没有更多了', style: TextStyle(color: Colors.grey)),
                      ),
                    );
                  }

                  final topic = topics[topicIndex];
                  final enableLongPress = ref.watch(preferencesProvider).longPressPreview;

                  return buildTopicItem(
                    context: context,
                    topic: topic,
                    isSelected: topic.id == selectedTopicId,
                    onTap: () => _openTopic(topic),
                    enableLongPress: enableLongPress,
                  );
                },
              ),
            ),
          ),
        );
      },
      loading: () => ClipRRect(
        borderRadius: _topBorderRadius,
        child: const TopicListSkeleton(),
      ),
      error: (error, stack) => ClipRRect(
        borderRadius: _topBorderRadius,
        child: ErrorView(
          error: error,
          stackTrace: stack,
          onRetry: () => ref.refresh(topicListProvider(providerKey)),
        ),
      ),
    );
  }

  Widget _buildNewTopicIndicator(BuildContext context, int count, (TopicListFilter, int?) providerKey) {
    final scrollController = PrimaryScrollController.maybeOf(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _isLoadingNewTopics ? null : () async {
            setState(() {
              _isLoadingNewTopics = true;
            });
            try {
              await ref.read(topicListProvider(providerKey).notifier).silentRefresh();
              ref.read(latestChannelProvider.notifier).clearNewTopicsForCategory(providerKey.$2);

              if (mounted) {
                scrollController?.animateTo(
                  0,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                );
              }
            } finally {
              if (mounted) {
                setState(() {
                  _isLoadingNewTopics = false;
                });
              }
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: _isLoadingNewTopics
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.arrow_upward,
                          size: 14,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '有 $count 条新话题，点击刷新',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 忽略按钮（紧凑 chip 样式，参考 CategoryNotificationButton）
class _DismissButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _DismissButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bgColor = theme.colorScheme.primaryContainer.withValues(alpha: 0.3);
    final fgColor = theme.colorScheme.primary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check, size: 14, color: fgColor),
              const SizedBox(width: 4),
              Text(
                '忽略',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: fgColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
