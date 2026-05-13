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
import '../providers/user_content_providers.dart';
import '../providers/user_content_search_provider.dart';
import '../services/app_error_handler.dart';
import '../services/discourse/discourse_service.dart';
import '../services/toast_service.dart';
import '../utils/platform_utils.dart';
import '../widgets/bookmark/bookmark_edit_sheet_launcher.dart';
import '../widgets/bookmark/bookmarks_list_content.dart';
import '../widgets/bookmark/bookmarks_workspace_tab_bar.dart';
import '../widgets/search/searchable_app_bar.dart';
import '../widgets/search/user_content_search_view.dart';
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
  String? _selectedBookmarkName;
  BookmarksWorkspaceState _workspaceState = const BookmarksWorkspaceState();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _searchNotifier = ref.read(
      userContentSearchProvider(SearchInType.bookmarks).notifier,
    );
  }

  @override
  void didUpdateWidget(covariant BookmarksPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive && !widget.isActive) {
      _workspaceState = const BookmarksWorkspaceState();
    }
  }

  @override
  void dispose() {
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

  void _onBookmarkTap(Topic topic) {
    final preferences = ref.read(preferencesProvider);
    if (_useTabbedWorkspace(preferences)) {
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
    );
  }

  void _openTopicRoute({
    required int topicId,
    String? initialTitle,
    int? scrollToPostNumber,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topicId,
          initialTitle: initialTitle,
          scrollToPostNumber: scrollToPostNumber,
        ),
      ),
    );
  }

  void _openTopicInWorkspace({required Topic topic, int? scrollToPostNumber}) {
    _openWorkspaceTab(
      topicId: topic.id,
      title: topic.title,
      scrollToPostNumber: scrollToPostNumber,
    );
  }

  void _openWorkspaceTab({
    required int topicId,
    required String title,
    int? scrollToPostNumber,
    bool activate = true,
  }) {
    setState(() {
      _workspaceState = activate
          ? _workspaceState.openTopicTab(
              topicId: topicId,
              title: title,
              scrollToPostNumber: scrollToPostNumber,
            )
          : _workspaceState.openTopicTabInBackground(
              topicId: topicId,
              title: title,
              scrollToPostNumber: scrollToPostNumber,
            );
    });
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
  }

  void _onBookmarkMiddleClick(Topic topic) {
    final preferences = ref.read(preferencesProvider);
    if (!_useTabbedWorkspace(preferences)) {
      return;
    }
    _openWorkspaceTab(
      topicId: topic.id,
      title: topic.title,
      scrollToPostNumber: resolveBookmarkScrollToPostNumber(topic),
      activate: false,
    );
  }

  bool _useTabbedWorkspace(AppPreferences preferences) {
    return PlatformUtils.isDesktop &&
        preferences.bookmarksOpenMode == BookmarksOpenMode.tabbedWorkspace;
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
      embeddedMode: true,
      parentActive: parentActive,
      instanceId: tab.instanceId,
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
    final useTabbedWorkspace = _useTabbedWorkspace(preferences);

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
      canPop: !searchState.isSearchMode,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (!didPop) {
          ref
              .read(userContentSearchProvider(SearchInType.bookmarks).notifier)
              .exitSearchMode();
        }
      },
      child: Scaffold(
        appBar: useTabbedWorkspace && !searchState.isSearchMode
            ? null
            : SearchableAppBar(
                title: useTabbedWorkspace ? '' : context.l10n.bookmarks_title,
                isSearchMode: searchState.isSearchMode,
                onSearchPressed: () => _onSearchPressed(useTabbedWorkspace),
                showSearchButton: !useTabbedWorkspace,
                onCloseSearch: () => ref
                    .read(
                      userContentSearchProvider(
                        SearchInType.bookmarks,
                      ).notifier,
                    )
                    .exitSearchMode(),
                onSearch: (query) => ref
                    .read(
                      userContentSearchProvider(
                        SearchInType.bookmarks,
                      ).notifier,
                    )
                    .search(query),
                showFilterButton: searchState.isSearchMode,
                filterActive: searchState.filter.isNotEmpty,
                onFilterPressed: () =>
                    showSearchFilterPanel(context, ref, SearchInType.bookmarks),
                searchHint: context.l10n.bookmarks_searchHint,
              ),
        body: useTabbedWorkspace
            ? _buildWorkspaceBody(
                context,
                bookmarksAsync,
                bookmarksNotifier,
                searchState,
                preferences,
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
    AppPreferences preferences,
  ) {
    return Column(
      children: [
        BookmarksWorkspaceTabBar(
          activeTabId: _workspaceState.activeTabId,
          topicTabs: _workspaceState.topicTabs,
          bookmarksLabel: context.l10n.bookmarks_title,
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
        ),
        Expanded(
          child: IndexedStack(
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
          ),
        ),
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
