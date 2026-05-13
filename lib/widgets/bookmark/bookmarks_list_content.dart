import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../models/topic.dart';
import '../../pages/bookmarks/bookmarks_models.dart';
import '../../utils/platform_utils.dart';
import '../../utils/time_utils.dart';
import 'bookmark_preview_quick_editor.dart';
import '../common/error_view.dart';
import '../desktop_refresh_indicator.dart';
import '../topic/topic_list_skeleton.dart';
import '../topic/topic_item_builder.dart';
import '../topic/topic_preview_dialog.dart';

class BookmarksListContent extends StatelessWidget {
  const BookmarksListContent({
    super.key,
    required this.bookmarksAsync,
    required this.bookmarkNameSuggestions,
    required this.bookmarkNameSuggestionsLoader,
    required this.scrollController,
    required this.onRefresh,
    required this.onTap,
    required this.onMiddleClick,
    required this.enableLongPress,
    required this.showSummaryBar,
    required this.selectedBookmarkName,
    required this.onSelectedBookmarkName,
    required this.hasMore,
    required this.isLoadMoreFailed,
    required this.isLoadingMore,
    required this.onRetryLoadMore,
    required this.onEditBookmark,
    required this.onQuickRenameBookmark,
    required this.onClearReminder,
    required this.onDeleteBookmark,
  });

  final AsyncValue<List<Topic>> bookmarksAsync;
  final List<String> bookmarkNameSuggestions;
  final Future<List<String>> Function() bookmarkNameSuggestionsLoader;
  final ScrollController scrollController;
  final Future<void> Function() onRefresh;
  final ValueChanged<Topic> onTap;
  final ValueChanged<Topic> onMiddleClick;
  final bool enableLongPress;
  final bool showSummaryBar;
  final String? selectedBookmarkName;
  final ValueChanged<String?> onSelectedBookmarkName;
  final bool hasMore;
  final bool isLoadMoreFailed;
  final bool isLoadingMore;
  final VoidCallback onRetryLoadMore;
  final Future<void> Function(Topic topic) onEditBookmark;
  final Future<bool> Function(Topic topic, String? name) onQuickRenameBookmark;
  final Future<void> Function(Topic topic) onClearReminder;
  final Future<void> Function(Topic topic) onDeleteBookmark;

  @override
  Widget build(BuildContext context) {
    return DesktopRefreshIndicator(
      onRefresh: onRefresh,
      child: bookmarksAsync.when(
        data: (topics) => _buildDataContent(context, topics),
        loading: () => const TopicListSkeleton(),
        error: (error, stack) =>
            ErrorView(error: error, stackTrace: stack, onRetry: onRefresh),
      ),
    );
  }

  Widget _buildDataContent(BuildContext context, List<Topic> topics) {
    if (topics.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.bookmark_border, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              context.l10n.bookmarks_empty,
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    final summaries = buildBookmarkNameSummaries(topics);
    final filteredTopics = filterBookmarksByName(topics, selectedBookmarkName);
    final summaryOffset = showSummaryBar ? 1 : 0;
    final itemCount = filteredTopics.length + 1 + summaryOffset;

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(12),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (showSummaryBar && index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _BookmarkSummaryBar(
              summaries: summaries,
              selectedBookmarkName: selectedBookmarkName,
              onSelectedBookmarkName: onSelectedBookmarkName,
            ),
          );
        }

        final dataIndex = index - summaryOffset;
        if (filteredTopics.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text(
                context.l10n.search_noResults,
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            ),
          );
        }

        if (dataIndex == filteredTopics.length) {
          return _buildFooter(context);
        }

        final topic = filteredTopics[dataIndex];
        return buildTopicItem(
          context: context,
          topic: topic,
          isSelected: false,
          onTap: () => onTap(topic),
          onMiddleClick: () => onMiddleClick(topic),
          enableLongPress: enableLongPress,
          topWidget: _buildBookmarkTopBar(context, topic),
          bottomWidget: _buildBookmarkExcerpt(context, topic),
          previewCustomActionPanelBuilder: topic.bookmarkId != null
              ? (_) => BookmarkPreviewQuickEditor(
                  initialName: topic.bookmarkName,
                  suggestions: bookmarkNameSuggestions,
                  suggestionsLoader: bookmarkNameSuggestionsLoader,
                  onSave: (value) => onQuickRenameBookmark(topic, value),
                )
              : null,
          previewActions: topic.bookmarkId != null
              ? _buildPreviewActions(context, topic)
              : null,
        );
      },
    );
  }

  Widget _buildFooter(BuildContext context) {
    if (isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.all(16.0),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (!hasMore) {
      return Padding(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: Text(
            context.l10n.common_noMore,
            style: const TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    if (isLoadMoreFailed) {
      return Padding(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: GestureDetector(
            onTap: onRetryLoadMore,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.refresh,
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  context.l10n.common_loadFailedTapRetry,
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  List<PreviewAction> _buildPreviewActions(BuildContext context, Topic topic) {
    final theme = Theme.of(context);
    final bookmarkId = topic.bookmarkId;
    if (bookmarkId == null) {
      return [];
    }

    return [
      PreviewAction(
        icon: Icons.edit_outlined,
        label: context.l10n.bookmark_editBookmark,
        onTap: () => onEditBookmark(topic),
      ),
      if (topic.bookmarkReminderAt != null)
        PreviewAction(
          icon: Icons.alarm_off,
          label: context.l10n.bookmarks_cancelReminder,
          onTap: () => onClearReminder(topic),
        ),
      PreviewAction(
        icon: Icons.delete_outline,
        label: context.l10n.common_deleteBookmark,
        color: theme.colorScheme.error,
        onTap: () => onDeleteBookmark(topic),
      ),
    ];
  }

  Widget? _buildBookmarkTopBar(BuildContext context, Topic topic) {
    final bookmarkName = normalizeBookmarkName(topic.bookmarkName);
    final hasName = bookmarkName != null;
    final hasReminder = topic.bookmarkReminderAt != null;
    if (!hasName && !hasReminder) {
      return null;
    }

    final colorScheme = Theme.of(context).colorScheme;
    final isExpired =
        hasReminder && topic.bookmarkReminderAt!.isBefore(DateTime.now());
    final backgroundColor = isExpired
        ? colorScheme.errorContainer.withValues(alpha: 0.5)
        : colorScheme.secondaryContainer.withValues(alpha: 0.6);
    final foregroundColor = isExpired
        ? colorScheme.error
        : colorScheme.onSecondaryContainer;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      color: backgroundColor,
      child: Text.rich(
        TextSpan(
          children: [
            if (hasName) ...[
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Icon(
                  Icons.bookmark_outlined,
                  size: 13,
                  color: foregroundColor,
                ),
              ),
              TextSpan(text: ' $bookmarkName'),
            ],
            if (hasReminder) ...[
              if (hasName)
                TextSpan(
                  text: '  ·  ',
                  style: TextStyle(
                    color: foregroundColor.withValues(alpha: 0.4),
                  ),
                ),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Icon(Icons.alarm, size: 13, color: foregroundColor),
              ),
              TextSpan(
                text: isExpired
                    ? context.l10n.bookmarks_expired
                    : ' ${TimeUtils.formatDetailTime(topic.bookmarkReminderAt!)}',
              ),
            ],
          ],
        ),
        style: TextStyle(fontSize: 12, color: foregroundColor, height: 1.3),
      ),
    );
  }

  Widget? _buildBookmarkExcerpt(BuildContext context, Topic topic) {
    if (topic.excerpt == null) {
      return null;
    }
    final cleaned = _cleanExcerpt(topic.excerpt!);
    if (cleaned.isEmpty) {
      return null;
    }

    final colorScheme = Theme.of(context).colorScheme;
    return Text(
      cleaned,
      style: TextStyle(
        fontSize: 12,
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
        height: 1.4,
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  String _cleanExcerpt(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&hellip;', '...')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

class _BookmarkSummaryBar extends StatefulWidget {
  const _BookmarkSummaryBar({
    required this.summaries,
    required this.selectedBookmarkName,
    required this.onSelectedBookmarkName,
  });

  final List<BookmarkNameSummary> summaries;
  final String? selectedBookmarkName;
  final ValueChanged<String?> onSelectedBookmarkName;

  @override
  State<_BookmarkSummaryBar> createState() => _BookmarkSummaryBarState();
}

class _BookmarkSummaryBarState extends State<_BookmarkSummaryBar> {
  static const double _scrollStep = 240;
  static const String _allSummaryKey = '__bookmark_summary_all__';

  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _summaryKeys = <String, GlobalKey>{};
  bool _canScrollBackward = false;
  bool _canScrollForward = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_syncScrollState);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncScrollState();
      }
    });
  }

  @override
  void didUpdateWidget(covariant _BookmarkSummaryBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncScrollState();
        _ensureSelectedChipVisible();
      }
    });
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_syncScrollState)
      ..dispose();
    super.dispose();
  }

  void _syncScrollState() {
    if (!_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    final canScrollBackward = position.pixels > 0;
    final canScrollForward = position.maxScrollExtent - position.pixels > 1;
    if (canScrollBackward == _canScrollBackward &&
        canScrollForward == _canScrollForward) {
      return;
    }
    setState(() {
      _canScrollBackward = canScrollBackward;
      _canScrollForward = canScrollForward;
    });
  }

  Future<void> _scrollBy(double delta) async {
    if (!_scrollController.hasClients) {
      return;
    }
    final target = (_scrollController.offset + delta).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    await _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  GlobalKey _keyForSummary(String key) {
    return _summaryKeys.putIfAbsent(key, GlobalKey.new);
  }

  String _selectedSummaryKey() {
    return widget.selectedBookmarkName ?? _allSummaryKey;
  }

  void _ensureSelectedChipVisible() {
    final key = _summaryKeys[_selectedSummaryKey()];
    final chipContext = key?.currentContext;
    if (chipContext == null) {
      return;
    }
    Scrollable.ensureVisible(
      chipContext,
      alignment: 0.5,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    );
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (!PlatformUtils.isDesktop ||
        event is! PointerScrollEvent ||
        !_scrollController.hasClients) {
      return;
    }
    final delta = event.scrollDelta;
    final scrollDelta = delta.dy.abs() >= delta.dx.abs() ? delta.dy : delta.dx;
    if (scrollDelta == 0) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final target = (_scrollController.offset + scrollDelta).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.jumpTo(target);
      _syncScrollState();
    });
  }

  ScrollBehavior _desktopFriendlyBehavior(BuildContext context) {
    return ScrollConfiguration.of(context).copyWith(
      dragDevices: {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.unknown,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final chipChildren = <Widget>[
      KeyedSubtree(
        key: _keyForSummary(_allSummaryKey),
        child: ChoiceChip(
          label: Text(context.l10n.common_all),
          selected: widget.selectedBookmarkName == null,
          onSelected: (_) => widget.onSelectedBookmarkName(null),
        ),
      ),
      for (final summary in widget.summaries)
        KeyedSubtree(
          key: _keyForSummary(summary.filterKey),
          child: ChoiceChip(
            label: Text(
              summary.isUnset
                  ? '${context.l10n.common_notSet} (${summary.count})'
                  : summary.label,
            ),
            selected: widget.selectedBookmarkName == summary.filterKey,
            onSelected: (_) => widget.onSelectedBookmarkName(summary.filterKey),
          ),
        ),
    ];

    final scrollableRow = ScrollConfiguration(
      behavior: _desktopFriendlyBehavior(context),
      child: SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var index = 0; index < chipChildren.length; index++) ...[
              if (index > 0) const SizedBox(width: 8),
              chipChildren[index],
            ],
          ],
        ),
      ),
    );

    return Listener(
      key: const ValueKey('bookmark-summary-wheel-region'),
      behavior: HitTestBehavior.opaque,
      onPointerSignal: _handlePointerSignal,
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            if (PlatformUtils.isDesktop)
              IconButton(
                key: const ValueKey('bookmark-summary-scroll-left'),
                visualDensity: VisualDensity.compact,
                onPressed: _canScrollBackward
                    ? () => _scrollBy(-_scrollStep)
                    : null,
                icon: const Icon(Icons.chevron_left_rounded),
              ),
            Expanded(child: scrollableRow),
            if (PlatformUtils.isDesktop)
              IconButton(
                key: const ValueKey('bookmark-summary-scroll-right'),
                visualDensity: VisualDensity.compact,
                onPressed: _canScrollForward
                    ? () => _scrollBy(_scrollStep)
                    : null,
                icon: const Icon(Icons.chevron_right_rounded),
              ),
          ],
        ),
      ),
    );
  }
}
