import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../pages/bookmarks/bookmarks_models.dart';
import '../../utils/platform_utils.dart';

class BookmarksWorkspaceTabBar extends StatefulWidget {
  const BookmarksWorkspaceTabBar({
    super.key,
    required this.activeTabId,
    required this.topicTabs,
    required this.bookmarksLabel,
    this.onSearchTap,
    this.isSearchMode = false,
    required this.onBookmarksTap,
    required this.onTopicTap,
    required this.onTopicClose,
    this.trailing = const [],
  });

  final String activeTabId;
  final List<BookmarkWorkspaceTopicTab> topicTabs;
  final String bookmarksLabel;
  final VoidCallback? onSearchTap;
  final bool isSearchMode;
  final VoidCallback onBookmarksTap;
  final ValueChanged<int> onTopicTap;
  final ValueChanged<int> onTopicClose;

  /// 注入到搜索按钮右侧的额外控件（如同步按钮）。搜索模式下隐藏。
  final List<Widget> trailing;

  @override
  State<BookmarksWorkspaceTabBar> createState() =>
      _BookmarksWorkspaceTabBarState();
}

class _BookmarksWorkspaceTabBarState extends State<BookmarksWorkspaceTabBar> {
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _tabKeys = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureActiveTabVisible();
    });
  }

  @override
  void didUpdateWidget(covariant BookmarksWorkspaceTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeTabId != widget.activeTabId ||
        oldWidget.topicTabs.length != widget.topicTabs.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _ensureActiveTabVisible();
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  GlobalKey _keyForTab(String tabId) {
    return _tabKeys.putIfAbsent(tabId, GlobalKey.new);
  }

  void _ensureActiveTabVisible() {
    final key = _tabKeys[widget.activeTabId];
    final tabContext = key?.currentContext;
    if (tabContext == null) {
      return;
    }
    Scrollable.ensureVisible(
      tabContext,
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
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface,
      ),
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            Expanded(
              child: Listener(
                key: const ValueKey('bookmark-workspace-tabs-wheel-region'),
                behavior: HitTestBehavior.opaque,
                onPointerSignal: _handlePointerSignal,
                child: ListView(
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    KeyedSubtree(
                      key: _keyForTab(BookmarksWorkspaceState.bookmarksTabId),
                      child: _WorkspaceTabButton(
                        label: widget.bookmarksLabel,
                        active:
                            widget.activeTabId ==
                            BookmarksWorkspaceState.bookmarksTabId,
                        closable: false,
                        onTap: widget.onBookmarksTap,
                      ),
                    ),
                    for (final tab in widget.topicTabs)
                      KeyedSubtree(
                        key: _keyForTab(tab.tabId),
                        child: _WorkspaceTabButton(
                          label: tab.title,
                          active: widget.activeTabId == tab.tabId,
                          closable: true,
                          onTap: () => widget.onTopicTap(tab.topicId),
                          onClose: () => widget.onTopicClose(tab.topicId),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (!widget.isSearchMode && widget.onSearchTap != null)
              IconButton(
                key: const ValueKey('bookmark-workspace-search-button'),
                tooltip: context.l10n.common_search,
                visualDensity: VisualDensity.compact,
                onPressed: widget.onSearchTap,
                icon: const Icon(Icons.search_rounded),
              ),
            if (!widget.isSearchMode) ...widget.trailing,
          ],
        ),
      ),
    );
  }
}

class _WorkspaceTabButton extends StatelessWidget {
  const _WorkspaceTabButton({
    required this.label,
    required this.active,
    required this.closable,
    required this.onTap,
    this.onClose,
  });

  final String label;
  final bool active;
  final bool closable;
  final VoidCallback onTap;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final backgroundColor = active
        ? colorScheme.secondaryContainer
        : colorScheme.surfaceContainerHighest.withValues(alpha: 0.6);
    final foregroundColor = active
        ? colorScheme.onSecondaryContainer
        : colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Material(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.only(
              left: 12,
              right: closable ? 4 : 12,
              top: 8,
              bottom: 8,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foregroundColor,
                      fontWeight: active ? FontWeight.w500 : FontWeight.w500,
                    ),
                  ),
                ),
                if (closable) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: context.l10n.common_close,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    iconSize: 16,
                    color: foregroundColor,
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
