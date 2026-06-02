import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/s.dart';
import '../models/search_filter.dart';
import '../models/topic.dart';
import '../navigation/nav_action_bus.dart';
import '../pages/bookmarks/bookmarks_models.dart';
import '../providers/bookmark_name_suggestions_provider.dart';
import '../providers/discourse_providers.dart';
import '../providers/preferences_provider.dart';
import '../providers/bookmarks_reconciler.dart';
import '../providers/user_content_providers.dart';
import '../providers/user_content_search_provider.dart';
import '../services/app_error_handler.dart';
import '../services/discourse/discourse_service.dart';
import '../services/toast_service.dart';
import '../utils/dialog_utils.dart';
import '../utils/platform_utils.dart';
import '../widgets/bookmark/bookmark_edit_sheet_launcher.dart';
import '../widgets/bookmark/bookmarks_list_content.dart';
import '../widgets/bookmark/bookmarks_workspace_tab_bar.dart';
import '../widgets/bookmark/mobile_topic_workspace_app_bar.dart';
import '../widgets/search/searchable_app_bar.dart';
import '../widgets/search/user_content_search_view.dart';
import 'topics_page.dart';
import 'topic_detail_page/topic_detail_page.dart';

typedef BookmarksWorkspaceTopicPageBuilder =
    Widget Function(
      BuildContext context,
      BookmarkWorkspaceTopicTab tab,
      bool parentActive,
    );

/// 我的书签页面
class BookmarksPage extends ConsumerStatefulWidget {
  const BookmarksPage({
    super.key,
    this.isActive = true,
    this.workspaceTopicPageBuilder,
  });

  /// 是否为当前活跃的 tab（嵌入底栏时用于决定是否响应 NavActionBus）
  final bool isActive;
  final BookmarksWorkspaceTopicPageBuilder? workspaceTopicPageBuilder;

  @override
  ConsumerState<BookmarksPage> createState() => _BookmarksPageState();
}

class _BookmarksPageState extends ConsumerState<BookmarksPage> {
  final ScrollController _scrollController = ScrollController();
  late final UserContentSearchNotifier _searchNotifier;
  late final double Function() _readBarVisibility;
  late final void Function(double value) _writeBarVisibility;
  String? _selectedBookmarkName;
  BookmarksWorkspaceState _workspaceState = const BookmarksWorkspaceState();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _searchNotifier = ref.read(
      userContentSearchProvider(SearchInType.bookmarks).notifier,
    );
    final barVisibilityController = ref.read(barVisibilityProvider.notifier);
    _readBarVisibility = () => barVisibilityController.state;
    _writeBarVisibility = (value) => barVisibilityController.state = value;
  }

  @override
  void didUpdateWidget(covariant BookmarksPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive && !widget.isActive) {
      _workspaceState = const BookmarksWorkspaceState();
      _setMobileBottomBarHidden(false);
    } else if (!oldWidget.isActive && widget.isActive) {
      // 重新切回当前页时，按当前工作区状态恢复底栏可见性。
      _syncMobileBottomBarVisibility(workspaceState: _workspaceState);
    }
  }

  @override
  void dispose() {
    _setMobileBottomBarHidden(false);
    _scrollController.dispose();
    Future.microtask(_searchNotifier.exitSearchMode);
    super.dispose();
  }

  void _onScroll() {
    _publishScrollProgress();
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(bookmarksProvider.notifier).loadMore();
    }
  }

  void _publishScrollProgress() {
    if (!_scrollController.hasClients) return;
    final raw = _scrollController.offset;
    final progress = raw < 0 ? 0.0 : raw;
    final current = ref.read(navScrollProgressProvider(NavEntryIds.bookmarks));
    final atZero = progress == 0 && current != 0;
    final crossed =
        (progress >= navScrollIconThreshold) !=
        (current >= navScrollIconThreshold);
    if (!atZero && !crossed && (progress - current).abs() < 4.0) return;
    ref.read(navScrollProgressProvider(NavEntryIds.bookmarks).notifier).state =
        progress;
  }

  Future<void> _onRefresh() async {
    await ref.read(bookmarksProvider.notifier).refresh();
  }

  Future<void> _onManualSync() async {
    final notifier = ref.read(bookmarksProvider.notifier);
    if (notifier.isReconciling) return;
    final report = await notifier.manualFullReconcile();
    if (!mounted) return;
    if (report == null) {
      ToastService.showError(S.current.bookmarks_syncFailed);
      return;
    }
    if (report.stopReason == ReconcileStopReason.errored) {
      ToastService.showError(S.current.bookmarks_syncFailed);
      return;
    }
    if (report.hasChange) {
      ToastService.showSuccess(
        S.current.bookmarks_syncCompleted(
          report.upserted,
          report.deleted,
        ),
      );
    } else {
      ToastService.showSuccess(S.current.bookmarks_syncUpToDate);
    }
  }

  void _onBookmarkTap(Topic topic) {
    final preferences = ref.read(preferencesProvider);
    if (_useWorkspace(preferences)) {
      _openTopicInWorkspace(
        topic: topic,
        scrollToPostNumber: resolveBookmarkScrollToPostNumber(topic),
      );
      return;
    }
    _openTopicRoute(
      topicId: topic.id,
      initialTitle: topic.title,
      scrollToPostNumber: resolveBookmarkScrollToPostNumber(topic),
      bookmarkId: topic.bookmarkId,
      bookmarkName: topic.bookmarkName,
      bookmarkReminderAt: topic.bookmarkReminderAt,
      bookmarkableType: topic.bookmarkableType,
    );
  }

  void _openTopicRoute({
    required int topicId,
    String? initialTitle,
    int? scrollToPostNumber,
    int? bookmarkId,
    String? bookmarkName,
    DateTime? bookmarkReminderAt,
    String? bookmarkableType,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topicId,
          initialTitle: initialTitle,
          scrollToPostNumber: scrollToPostNumber,
          initialBookmarkId: bookmarkId,
          initialBookmarkName: bookmarkName,
          initialBookmarkReminderAt: bookmarkReminderAt,
          initialBookmarkableType: bookmarkableType,
        ),
      ),
    );
  }

  void _openTopicInWorkspace({required Topic topic, int? scrollToPostNumber}) {
    _openWorkspaceTab(
      topicId: topic.id,
      title: topic.title,
      scrollToPostNumber: scrollToPostNumber,
      bookmarkId: topic.bookmarkId,
      bookmarkName: topic.bookmarkName,
      bookmarkReminderAt: topic.bookmarkReminderAt,
      bookmarkableType: topic.bookmarkableType,
    );
  }

  void _openWorkspaceTab({
    required int topicId,
    required String title,
    int? scrollToPostNumber,
    int? bookmarkId,
    String? bookmarkName,
    DateTime? bookmarkReminderAt,
    String? bookmarkableType,
    bool activate = true,
  }) {
    late final BookmarksWorkspaceState nextState;
    setState(() {
      nextState = activate
          ? _workspaceState.openTopicTab(
              topicId: topicId,
              title: title,
              scrollToPostNumber: scrollToPostNumber,
              bookmarkId: bookmarkId,
              bookmarkName: bookmarkName,
              bookmarkReminderAt: bookmarkReminderAt,
              bookmarkableType: bookmarkableType,
            )
          : _workspaceState.openTopicTabInBackground(
              topicId: topicId,
              title: title,
              scrollToPostNumber: scrollToPostNumber,
              bookmarkId: bookmarkId,
              bookmarkName: bookmarkName,
              bookmarkReminderAt: bookmarkReminderAt,
              bookmarkableType: bookmarkableType,
            );
      _workspaceState = nextState;
    });
    _syncMobileBottomBarVisibility(workspaceState: nextState);
  }

  void _onSearchPressed(bool useTabbedWorkspace) {
    ref
        .read(userContentSearchProvider(SearchInType.bookmarks).notifier)
        .enterSearchMode();
    if (!useTabbedWorkspace) {
      return;
    }
    setState(() {
      _workspaceState = _workspaceState.activateBookmarksTab();
    });
    _setMobileBottomBarHidden(false);
  }

  void _onBookmarkMiddleClick(Topic topic) {
    final preferences = ref.read(preferencesProvider);
    if (!_useDesktopWorkspace(preferences)) {
      return;
    }
    _openWorkspaceTab(
      topicId: topic.id,
      title: topic.title,
      scrollToPostNumber: resolveBookmarkScrollToPostNumber(topic),
      bookmarkId: topic.bookmarkId,
      bookmarkName: topic.bookmarkName,
      bookmarkReminderAt: topic.bookmarkReminderAt,
      bookmarkableType: topic.bookmarkableType,
      activate: false,
    );
  }

  bool _useWorkspace(AppPreferences preferences) {
    return (PlatformUtils.isDesktop || PlatformUtils.isMobile) &&
        preferences.bookmarksOpenMode == BookmarksOpenMode.tabbedWorkspace;
  }

  bool _useDesktopWorkspace(AppPreferences preferences) {
    return PlatformUtils.isDesktop && _useWorkspace(preferences);
  }

  bool _useMobileWorkspace(AppPreferences preferences) {
    return PlatformUtils.isMobile && _useWorkspace(preferences);
  }

  String _workspaceSwitcherLabel(int count) {
    return S.current.bookmarks_workspaceOpenedCount(count);
  }

  void _activateBookmarksTab() {
    setState(() {
      _workspaceState = _workspaceState.activateBookmarksTab();
    });
    _setMobileBottomBarHidden(false);
  }

  void _closeActiveWorkspaceTab() {
    final activeTopic = _workspaceState.activeTopicTab;
    if (activeTopic == null) {
      return;
    }
    late final BookmarksWorkspaceState nextState;
    setState(() {
      nextState = _workspaceState.closeTopicTab(activeTopic.topicId);
      _workspaceState = nextState;
    });
    _syncMobileBottomBarVisibility(workspaceState: nextState);
  }

  bool _shouldHideMobileBottomBar(
    AppPreferences preferences, {
    required BookmarksWorkspaceState workspaceState,
  }) {
    return widget.isActive &&
        _useMobileWorkspace(preferences) &&
        workspaceState.activeTopicTab != null;
  }

  void _syncMobileBottomBarVisibility({
    required BookmarksWorkspaceState workspaceState,
  }) {
    final preferences = ref.read(preferencesProvider);
    _setMobileBottomBarHidden(
      _shouldHideMobileBottomBar(preferences, workspaceState: workspaceState),
    );
  }

  void _setMobileBottomBarHidden(bool hidden) {
    final target = hidden ? 0.0 : 1.0;
    final current = _readBarVisibility();
    if (current == target) {
      return;
    }
    _writeBarVisibility(target);
  }

  Future<void> _showWorkspaceSwitcher() async {
    if (_workspaceState.topicTabs.isEmpty) {
      return;
    }

    await showAppBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return SafeArea(
          child: Padding(
            key: const ValueKey('bookmark-workspace-switcher-sheet'),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(sheetContext).size.height * 0.65,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _workspaceSwitcherLabel(_workspaceState.topicTabs.length),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _workspaceState.topicTabs.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 12, endIndent: 12),
                      itemBuilder: (context, index) {
                        final tab = _workspaceState.topicTabs[index];
                        final selected =
                            _workspaceState.activeTabId == tab.tabId;
                        return ListTile(
                          key: ValueKey(
                            'bookmark-workspace-switcher-item-${tab.topicId}',
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          leading: Icon(
                            selected
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            color: selected
                                ? theme.colorScheme.primary
                                : theme.colorScheme.outline,
                          ),
                          title: Text(
                            tab.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            setState(() {
                              _workspaceState = _workspaceState
                                  .activateTopicTab(tab.topicId);
                            });
                            Navigator.pop(sheetContext);
                          },
                          trailing: IconButton(
                            key: ValueKey(
                              'bookmark-workspace-switcher-close-${tab.topicId}',
                            ),
                            tooltip: context.l10n.common_close,
                            onPressed: () {
                              setState(() {
                                _workspaceState = _workspaceState.closeTopicTab(
                                  tab.topicId,
                                );
                              });
                              Navigator.pop(sheetContext);
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  PreferredSizeWidget? _buildAppBar(
    BuildContext context,
    UserContentSearchState searchState,
    bool useWorkspace,
    bool useMobileWorkspace,
  ) {
    if (searchState.isSearchMode) {
      return SearchableAppBar(
        title: context.l10n.bookmarks_title,
        isSearchMode: true,
        onSearchPressed: () => _onSearchPressed(useWorkspace),
        showSearchButton: !useWorkspace,
        onCloseSearch: () => ref
            .read(userContentSearchProvider(SearchInType.bookmarks).notifier)
            .exitSearchMode(),
        onSearch: (query) => ref
            .read(userContentSearchProvider(SearchInType.bookmarks).notifier)
            .search(query),
        showFilterButton: true,
        filterActive: searchState.filter.isNotEmpty,
        onFilterPressed: () =>
            showSearchFilterPanel(context, ref, SearchInType.bookmarks),
        searchHint: context.l10n.bookmarks_searchHint,
      );
    }

    if (!useWorkspace) {
      return SearchableAppBar(
        title: context.l10n.bookmarks_title,
        isSearchMode: false,
        onSearchPressed: () => _onSearchPressed(false),
        showSearchButton: true,
        onCloseSearch: () => ref
            .read(userContentSearchProvider(SearchInType.bookmarks).notifier)
            .exitSearchMode(),
        onSearch: (query) => ref
            .read(userContentSearchProvider(SearchInType.bookmarks).notifier)
            .search(query),
        showFilterButton: false,
        filterActive: false,
        searchHint: context.l10n.bookmarks_searchHint,
        trailingActions: [_buildSyncAction()],
      );
    }

    if (!useMobileWorkspace) {
      return null;
    }

    final activeTopic = _workspaceState.activeTopicTab;
    final hasOpenedTopics = _workspaceState.topicTabs.isNotEmpty;

    if (activeTopic != null) {
      if (widget.workspaceTopicPageBuilder == null) {
        return null;
      }
      return AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: 0,
        title: Row(
          children: [
            IconButton(
              key: const ValueKey('bookmark-workspace-mobile-back'),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: _activateBookmarksTab,
              icon: const Icon(Icons.arrow_back),
            ),
            IconButton(
              key: const ValueKey('bookmark-workspace-mobile-close'),
              tooltip: context.l10n.common_close,
              onPressed: _closeActiveWorkspaceTab,
              icon: const Icon(Icons.close_rounded),
            ),
            Expanded(
              child: Text(
                activeTopic.title,
                key: const ValueKey('bookmark-workspace-mobile-title-text'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            MobileWorkspaceCountButton(
              key: const ValueKey('bookmark-workspace-mobile-count-button'),
              count: _workspaceState.topicTabs.length,
              tooltip: _workspaceSwitcherLabel(
                _workspaceState.topicTabs.length,
              ),
              onPressed: _showWorkspaceSwitcher,
            ),
          ],
        ),
      );
    }

    return AppBar(
      leading: null,
      title: Text(
        context.l10n.bookmarks_title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          onPressed: () => _onSearchPressed(true),
          tooltip: context.l10n.common_search,
        ),
        _buildSyncAction(),
        if (hasOpenedTopics)
          MobileWorkspaceCountButton(
            key: const ValueKey('bookmark-workspace-mobile-count-button'),
            count: _workspaceState.topicTabs.length,
            tooltip: _workspaceSwitcherLabel(_workspaceState.topicTabs.length),
            onPressed: _showWorkspaceSwitcher,
          ),
      ],
    );
  }

  Widget _buildSyncAction() {
    final notifier = ref.watch(bookmarksProvider.notifier);
    final isReconciling = notifier.isReconciling;
    return IconButton(
      tooltip: context.l10n.bookmarks_syncBookmarks,
      onPressed: isReconciling ? null : _onManualSync,
      icon: isReconciling
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.sync),
    );
  }

  int _workspaceActiveIndex() {
    if (_workspaceState.activeTabId == BookmarksWorkspaceState.bookmarksTabId) {
      return 0;
    }
    final topicIndex = _workspaceState.topicTabs.indexWhere(
      (tab) => tab.tabId == _workspaceState.activeTabId,
    );
    return topicIndex == -1 ? 0 : topicIndex + 1;
  }

  Widget _buildWorkspaceTopicPage(BookmarkWorkspaceTopicTab tab) {
    final showMobileWorkspaceChrome = _useMobileWorkspace(
      ref.read(preferencesProvider),
    );
    final parentActive =
        widget.isActive && _workspaceState.activeTabId == tab.tabId;
    final customBuilder = widget.workspaceTopicPageBuilder;
    if (customBuilder != null) {
      return customBuilder(context, tab, parentActive);
    }
    return TopicDetailPage(
      topicId: tab.topicId,
      initialTitle: tab.title,
      scrollToPostNumber: tab.scrollToPostNumber,
      initialBookmarkId: tab.bookmarkId,
      initialBookmarkName: tab.bookmarkName,
      initialBookmarkReminderAt: tab.bookmarkReminderAt,
      initialBookmarkableType: tab.bookmarkableType,
      embeddedMode: true,
      parentActive: parentActive,
      instanceId: tab.instanceId,
      onEmbeddedBack: showMobileWorkspaceChrome ? _activateBookmarksTab : null,
      onEmbeddedClose: showMobileWorkspaceChrome
          ? _closeActiveWorkspaceTab
          : null,
      embeddedTabCount: showMobileWorkspaceChrome
          ? _workspaceState.topicTabs.length
          : null,
      onEmbeddedShowTabs: showMobileWorkspaceChrome
          ? _showWorkspaceSwitcher
          : null,
      hideInlineHeaderTitle: showMobileWorkspaceChrome,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bookmarksAsync = ref.watch(bookmarksProvider);
    final bookmarksNotifier = ref.watch(bookmarksProvider.notifier);
    final preferences = ref.watch(preferencesProvider);
    final searchState = ref.watch(
      userContentSearchProvider(SearchInType.bookmarks),
    );
    final useWorkspace = _useWorkspace(preferences);
    final useMobileWorkspace = _useMobileWorkspace(preferences);
    final interceptWorkspacePop =
        useMobileWorkspace &&
        !searchState.isSearchMode &&
        _workspaceState.activeTabId != BookmarksWorkspaceState.bookmarksTabId;

    // 切换打开方式（_useMobileWorkspace 受 preferences 控制）时，同步底栏可见性。
    // 其它入口（widget.isActive 变化、工作区 tab 切换）已在 didUpdateWidget /
    // _activateBookmarksTab / openTopicTab 等显式调用 _syncMobileBottomBarVisibility。
    ref.listen<AppPreferences>(preferencesProvider, (previous, next) {
      if (previous == null) return;
      if (_useMobileWorkspace(previous) == _useMobileWorkspace(next)) return;
      _syncMobileBottomBarVisibility(workspaceState: _workspaceState);
    });

    ref.listen<AsyncValue<List<Topic>>>(bookmarksProvider, (_, next) {
      final topics = next.asData?.value;
      if (topics == null) {
        return;
      }
      final notifier = ref.read(bookmarkNameSuggestionsProvider.notifier);
      final bookmarksState = ref.read(bookmarksProvider.notifier);
      final isCompleteSnapshot =
          !bookmarksState.isHydratingAll &&
          !bookmarksState.hasMore &&
          !bookmarksState.isLoadMoreFailed;
      notifier.seedFromTopics(topics, isCompleteSnapshot: isCompleteSnapshot);
    });

    // 嵌入底栏时响应快捷动作（仅活跃 tab 响应）
    ref.listen(navActionBusProvider, (_, event) {
      if (event == null || event.targetId != NavEntryIds.bookmarks) return;
      if (!widget.isActive) return;
      if (interceptWorkspacePop) {
        _activateBookmarksTab();
        return;
      }
      switch (event.action) {
        case NavAction.scrollToTop:
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
          break;
        case NavAction.refresh:
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
          _onRefresh();
          ref.resetNavScrollProgress(NavEntryIds.bookmarks);
          break;
      }
    });

    return PopScope(
      canPop: !searchState.isSearchMode && !interceptWorkspacePop,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (!didPop) {
          if (searchState.isSearchMode) {
            ref
                .read(
                  userContentSearchProvider(SearchInType.bookmarks).notifier,
                )
                .exitSearchMode();
            return;
          }
          if (interceptWorkspacePop) {
            _activateBookmarksTab();
          }
        }
      },
      child: Scaffold(
        appBar: _buildAppBar(
          context,
          searchState,
          useWorkspace,
          useMobileWorkspace,
        ),
        body: useWorkspace
            ? _buildWorkspaceBody(
                context,
                bookmarksAsync,
                bookmarksNotifier,
                searchState,
                preferences,
                showDesktopTabBar: _useDesktopWorkspace(preferences),
              )
            : _buildBookmarksPane(
                context,
                bookmarksAsync,
                bookmarksNotifier,
                searchState,
                preferences,
                workspaceOpenEnabled: false,
              ),
      ),
    );
  }

  Widget _buildWorkspaceBody(
    BuildContext context,
    AsyncValue<List<Topic>> bookmarksAsync,
    BookmarksNotifier bookmarksNotifier,
    UserContentSearchState searchState,
    AppPreferences preferences, {
    required bool showDesktopTabBar,
  }) {
    final workspaceContent = IndexedStack(
      index: _workspaceActiveIndex(),
      children: [
        _buildBookmarksPane(
          context,
          bookmarksAsync,
          bookmarksNotifier,
          searchState,
          preferences,
          workspaceOpenEnabled: true,
        ),
        for (final tab in _workspaceState.topicTabs)
          KeyedSubtree(
            key: ValueKey(tab.instanceId),
            child: _buildWorkspaceTopicPage(tab),
          ),
      ],
    );

    return Column(
      children: [
        if (showDesktopTabBar)
          BookmarksWorkspaceTabBar(
            activeTabId: _workspaceState.activeTabId,
            topicTabs: _workspaceState.topicTabs,
            bookmarksLabel: context.l10n.bookmarks_title,
            isSearchMode: searchState.isSearchMode,
            onSearchTap: () => _onSearchPressed(true),
            onBookmarksTap: () {
              setState(() {
                _workspaceState = _workspaceState.activateBookmarksTab();
              });
            },
            onTopicTap: (topicId) {
              setState(() {
                _workspaceState = _workspaceState.activateTopicTab(topicId);
              });
            },
            onTopicClose: (topicId) {
              setState(() {
                _workspaceState = _workspaceState.closeTopicTab(topicId);
              });
            },
            trailing: [_buildSyncAction()],
          ),
        Expanded(child: workspaceContent),
      ],
    );
  }

  Widget _buildBookmarksPane(
    BuildContext context,
    AsyncValue<List<Topic>> bookmarksAsync,
    BookmarksNotifier bookmarksNotifier,
    UserContentSearchState searchState,
    AppPreferences preferences, {
    required bool workspaceOpenEnabled,
  }) {
    final bookmarkNameSuggestions = ref.watch(bookmarkNameSuggestionsProvider);
    final bookmarkNameSuggestionsLoader = ref
        .read(bookmarkNameSuggestionsProvider.notifier)
        .ensureLoaded;

    return Stack(
      children: [
        Offstage(
          offstage: searchState.isSearchMode,
          child: BookmarksListContent(
            bookmarksAsync: bookmarksAsync,
            bookmarkNameSuggestions: bookmarkNameSuggestions,
            bookmarkNameSuggestionsLoader: bookmarkNameSuggestionsLoader,
            scrollController: _scrollController,
            onRefresh: _onRefresh,
            onTap: _onBookmarkTap,
            onMiddleClick: _onBookmarkMiddleClick,
            enableLongPress: preferences.longPressPreview,
            showSummaryBar: !searchState.isSearchMode,
            selectedBookmarkName: _selectedBookmarkName,
            onSelectedBookmarkName: (value) {
              setState(() {
                _selectedBookmarkName = value;
              });
            },
            hasMore: bookmarksNotifier.hasMore,
            isLoadMoreFailed: bookmarksNotifier.isLoadMoreFailed,
            isLoadingMore: bookmarksNotifier.isHydratingAll,
            onRetryLoadMore: bookmarksNotifier.retryLoadMore,
            onEditBookmark: _editBookmark,
            onQuickRenameBookmark: _quickRenameBookmark,
            onClearReminder: _clearReminder,
            onDeleteBookmark: _deleteBookmark,
          ),
        ),
        if (searchState.isSearchMode)
          UserContentSearchView(
            inType: SearchInType.bookmarks,
            emptySearchHint: context.l10n.bookmarks_emptySearchHint,
            onOpenTopic: workspaceOpenEnabled
                ? ({
                    required int topicId,
                    required String title,
                    int? scrollToPostNumber,
                  }) {
                    ref
                        .read(
                          userContentSearchProvider(
                            SearchInType.bookmarks,
                          ).notifier,
                        )
                        .exitSearchMode();
                    _openWorkspaceTab(
                      topicId: topicId,
                      title: title,
                      scrollToPostNumber: scrollToPostNumber,
                    );
                  }
                : null,
          ),
      ],
    );
  }

  Future<void> _editBookmark(Topic topic) async {
    final bookmarkId = topic.bookmarkId;
    if (bookmarkId == null) return;

    final result = await showBookmarkEditSheetWithCachedNames(
      context,
      ref,
      bookmarkId: bookmarkId,
      initialName: topic.bookmarkName,
      initialReminderAt: topic.bookmarkReminderAt,
      seedTopics: ref.read(bookmarksProvider).value ?? const [],
    );
    if (result == null || !mounted) return;

    final notifier = ref.read(bookmarksProvider.notifier);
    if (result.deleted) {
      notifier.removeBookmarkById(bookmarkId);
    } else {
      notifier.updateBookmarkMeta(
        bookmarkId,
        name: result.name,
        clearName: result.name == null,
        reminderAt: result.reminderAt,
        clearReminderAt: result.reminderAt == null,
      );
    }
  }

  Future<void> _clearReminder(Topic topic) async {
    final bookmarkId = topic.bookmarkId;
    if (bookmarkId == null) return;

    try {
      await DiscourseService().clearBookmarkReminder(bookmarkId);
      if (!mounted) return;
      ref
          .read(bookmarksProvider.notifier)
          .updateBookmarkMeta(bookmarkId, clearReminderAt: true);
      ToastService.showSuccess(S.current.bookmarks_reminderCancelled);
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  Future<void> _deleteBookmark(Topic topic) async {
    final bookmarkId = topic.bookmarkId;
    if (bookmarkId == null) return;

    try {
      await DiscourseService().deleteBookmark(bookmarkId);
      if (!mounted) return;
      ref.read(bookmarksProvider.notifier).removeBookmarkById(bookmarkId);
      ref.read(bookmarkNameSuggestionsProvider.notifier).markDirty();
      ToastService.showSuccess(S.current.bookmarks_deleted);
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  Future<bool> _quickRenameBookmark(Topic topic, String? name) async {
    final bookmarkId = topic.bookmarkId;
    if (bookmarkId == null) return false;

    try {
      await DiscourseService().updateBookmark(
        bookmarkId,
        name: name?.trim() ?? '',
        reminderAt: topic.bookmarkReminderAt,
      );
      if (!mounted) return false;
      ref
          .read(bookmarksProvider.notifier)
          .updateBookmarkMeta(
            bookmarkId,
            name: name?.trim().isNotEmpty == true ? name!.trim() : null,
            clearName: name?.trim().isNotEmpty != true,
            reminderAt: topic.bookmarkReminderAt,
          );
      ref
          .read(bookmarkNameSuggestionsProvider.notifier)
          .markDirty(optimisticName: name);
      ToastService.showSuccess(S.current.common_bookmarkUpdated);
      return true;
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
      return false;
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
      return false;
    }
  }
}
