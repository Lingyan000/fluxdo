import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../services/app_error_handler.dart';
import '../../services/notion/notion_bookmark_auto_sync.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:share_plus/share_plus.dart';
import '../../l10n/s.dart';
import '../../utils/html_text_mapper.dart';
import '../../utils/html_to_markdown.dart';
import '../../utils/code_selection_context.dart';
import '../../utils/link_launcher.dart';
import '../../utils/quote_builder.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';
import 'dart:math' as math;
import '../../models/draft.dart';
import '../../models/topic.dart';
import '../../utils/responsive.dart';
import '../../utils/share_utils.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/theme_provider.dart';
import '../reading_settings_page.dart';
import '../../providers/selected_topic_provider.dart';
import '../../providers/discourse_providers.dart';
import '../../providers/message_bus_providers.dart';
import '../../providers/pinned_categories_provider.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/screen_track.dart';
import '../../services/toast_service.dart';
import '../../services/log/log_writer.dart';
import '../../services/log/bookmark_edit_trace.dart';
import '../../services/navigation/app_route_observer.dart';
import '../../widgets/content/lazy_load_scope.dart';
import '../../widgets/post/post_item_skeleton.dart';
import '../../widgets/post/post_item/widgets/post_flag_sheet.dart';
import '../../widgets/post/post_replies_sheet.dart';
import '../../widgets/post/post_revision/revision_modal.dart';
import '../../widgets/post/reply_sheet.dart';
import '../../widgets/topic/topic_progress.dart';
import '../../widgets/topic/topic_notification_button.dart';
import 'package:common_ui/common_ui.dart';
import '../../widgets/common/emoji_text.dart';
import '../../widgets/common/error_view.dart';
import '../../widgets/content/discourse_html_content/chunked/chunked_html_content.dart';
import '../../widgets/content/discourse_html_content/discourse_html_content_widget.dart';
import '../../providers/nested_topic_provider.dart';
import 'controllers/topic_detail_controller.dart';
import 'widgets/nested_post_list.dart';
import 'widgets/topic_detail_overlay.dart';
import 'widgets/topic_post_list.dart';
import 'widgets/topic_detail_header.dart';
import '../../widgets/layout/master_detail_layout.dart';
import '../../widgets/share/share_image_preview.dart';
import '../../widgets/share/export_sheet.dart';
import '../../widgets/bookmark/bookmark_edit_sheet_launcher.dart';
import '../../widgets/bookmark/mobile_topic_workspace_app_bar.dart';
import '../../widgets/search/topic_search_view.dart';
import '../../providers/read_later_provider.dart';
import '../../models/read_later_item.dart';
import '../../providers/topic_search_provider.dart';
import '../edit_topic_page.dart';
import 'topic_bookmark_edit_target.dart';
import 'topic_more_menu_actions.dart';
import 'widgets/ai_chat_page.dart';
import 'widgets/ai_chat_guide.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/platform_utils.dart';
import '../../models/shortcut_binding.dart';
import '../../providers/shortcut_provider.dart';
import '../../widgets/desktop_refresh_indicator.dart';

part 'actions/_scroll_actions.dart';
part 'actions/_user_actions.dart';
part 'actions/_filter_actions.dart';

/// 话题详情页面
class TopicDetailPage extends ConsumerStatefulWidget {
  final int topicId;
  final String? initialTitle;
  final int? scrollToPostNumber; // 外部控制的跳转位置（如从通知跳转到指定楼层）
  final bool embeddedMode; // 嵌入模式（双栏布局中使用，不显示返回按钮）
  final bool parentActive; // 父容器是否可见（IndexedStack/双栏切 tab 时用）
  final bool autoSwitchToMasterDetail; // 仅在从首页进入时允许自动切换
  final bool autoOpenReply; // 自动打开回复框（从草稿进入时使用）
  final int? autoReplyToPostNumber; // 自动回复的帖子编号（从草稿进入时使用）
  final String? instanceId; // 外部指定的 provider 实例 ID（布局切换时复用）
  final bool autoOpenAiChat; // 自动打开 AI 聊天面板
  final String? initialSessionId; // AI 聊天初始会话 ID
  final String? highlightBoostUsername; // 高亮指定用户的 boost（从 boost 通知跳转时使用）
  final int? initialBookmarkId;
  final String? initialBookmarkName;
  final DateTime? initialBookmarkReminderAt;
  final String? initialBookmarkableType;
  /// 从「编辑通知」跳转时,带上目标帖子的编号 + revision number,
  /// 加载完成并滚动到位后自动弹出历史 modal 到对应版本。
  final int? initialRevisionPostNumber;
  final int? initialRevisionNumber;
  final VoidCallback? onEmbeddedBack;
  final VoidCallback? onEmbeddedClose;
  final int? embeddedTabCount;
  final VoidCallback? onEmbeddedShowTabs;
  final bool hideInlineHeaderTitle;

  const TopicDetailPage({
    super.key,
    required this.topicId,
    this.initialTitle,
    this.scrollToPostNumber,
    this.embeddedMode = false,
    this.parentActive = true,
    this.autoSwitchToMasterDetail = false,
    this.autoOpenReply = false,
    this.autoReplyToPostNumber,
    this.instanceId,
    this.autoOpenAiChat = false,
    this.initialSessionId,
    this.highlightBoostUsername,
    this.initialBookmarkId,
    this.initialBookmarkName,
    this.initialBookmarkReminderAt,
    this.initialBookmarkableType,
    this.initialRevisionPostNumber,
    this.initialRevisionNumber,
    this.onEmbeddedBack,
    this.onEmbeddedClose,
    this.embeddedTabCount,
    this.onEmbeddedShowTabs,
    this.hideInlineHeaderTitle = false,
  });

  @override
  ConsumerState<TopicDetailPage> createState() => _TopicDetailPageState();
}

class _TopicDetailPageState extends ConsumerState<TopicDetailPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin, RouteAware {
  /// 唯一实例 ID，确保每次打开页面都创建新的 provider 实例
  /// 支持外部传入以在布局切换时复用同一个 provider
  late final String _instanceId = widget.instanceId ?? const Uuid().v4();
  late final int? _providerPostNumber;

  /// Provider 参数只携带首次构建所需的定位信息，运行时浏览位置由 controller 单独维护。
  TopicDetailParams get _params => TopicDetailParams(
    widget.topicId,
    postNumber: _providerPostNumber,
    instanceId: _instanceId,
  );

  // Controller
  late final TopicDetailController _controller;
  late final ScreenTrack _screenTrack;

  // UI State
  final GlobalKey _headerKey = GlobalKey();
  final GlobalKey _centerKey = GlobalKey();
  bool _hasFirstPost = false;
  bool _isCheckTitleVisibilityScheduled = false;
  bool _isRefreshing = false;

  /// 标题是否显示（用 ValueNotifier 隔离 AppBar 更新）
  final ValueNotifier<bool> _showTitleNotifier = ValueNotifier<bool>(false);

  /// AppBar 是否有阴影（用 ValueNotifier 隔离 AppBar 更新）
  final ValueNotifier<bool> _isScrolledUnderNotifier = ValueNotifier<bool>(
    false,
  );

  /// 展开头部是否可见（用 ValueNotifier 隔离 UI 更新）
  final ValueNotifier<bool> _isOverlayVisibleNotifier = ValueNotifier<bool>(
    false,
  );
  bool _isSwitchingMode = false; // 切换热门回复模式
  bool _isNestedView = false; // 嵌套视图模式
  bool _defaultNestedViewApplied = false; // 默认嵌套视图配置是否已应用（依赖 detail 加载后判定）
  // 搜索相关
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  late final AnimationController _expandController;
  late final Animation<Offset> _animation;
  Set<int> _lastReadPostNumbers = {};
  bool? _lastCanShowDetailPane;
  bool _isAutoSwitching = false;
  bool _autoOpenReplyHandled = false; // 是否已处理自动打开回复框
  bool _autoOpenRevisionHandled = false; // 是否已处理自动打开编辑历史 modal
  bool _autoOpenAiChatHandled = false; // 是否已处理自动打开 AI 聊天
  late final TopicSearchNotifier _topicSearchNotifier;
  // AI 滑动入口相关
  late final PageController _pageController;
  final ValueNotifier<int> _currentPageNotifier = ValueNotifier<int>(0);
  bool _aiGuideChecked = false;
  late final ShortcutScopeBinding _shortcutScopeBinding = ShortcutScopeBinding(
    ref: ref,
    scope: widget.embeddedMode ? ShortcutScope.detail : ShortcutScope.context,
  );
  late int? _fallbackBookmarkId = widget.initialBookmarkId;
  late String? _fallbackBookmarkName = widget.initialBookmarkName;
  late DateTime? _fallbackBookmarkReminderAt = widget.initialBookmarkReminderAt;
  late String? _fallbackBookmarkableType = widget.initialBookmarkableType;
  // 用户在本页内编辑/删除过书签后置为 true：阻止 didUpdateWidget 把父级
  // 传入的旧 initialBookmark* 写回 fallback，避免已删除的书签被"复活"。
  bool _userMutatedFallback = false;
  ModalRoute<dynamic>? _route;
  bool _isRouteVisible = true;
  bool _isParentActive = true;
  bool _isScreenTrackRunning = false;

  bool get _usesEmbeddedMobileWorkspaceChrome {
    return widget.embeddedMode &&
        PlatformUtils.isMobile &&
        widget.onEmbeddedBack != null &&
        widget.onEmbeddedClose != null &&
        widget.embeddedTabCount != null &&
        widget.onEmbeddedShowTabs != null;
  }

  int? get _resolvedViewportPostNumber =>
      _controller.viewportPostNumber ?? widget.scrollToPostNumber;

  int? get _resolvedShortcutPostNumber =>
      _controller.effectivePostNumberForActions ?? _resolvedViewportPostNumber;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _isParentActive = widget.parentActive;
    _providerPostNumber = widget.scrollToPostNumber;

    _expandController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _animation =
        Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _expandController,
            curve: Curves.easeOutCubic,
          ),
        )..addStatusListener((status) {
          if (status == AnimationStatus.forward) {
            _isOverlayVisibleNotifier.value = true;
          } else if (status == AnimationStatus.dismissed) {
            _isOverlayVisibleNotifier.value = false;
          }
        });

    final trackEnabled = ref.read(currentUserProvider).value != null;
    _topicSearchNotifier = ref.read(
      topicSearchProvider(widget.topicId).notifier,
    );

    _screenTrack = ScreenTrack(
      DiscourseService(),
      debugSourceId: _instanceId,
      onTimingsSent: (topicId, postNumbers, highestSeen) {
        debugPrint(
          '[TopicDetail] onTimingsSent callback triggered: topicId=$topicId, highestSeen=$highestSeen',
        );
        // 遍历所有分类 tab，更新所有活跃的 provider 实例
        final pinnedIds = ref.read(pinnedCategoriesProvider);
        final categoryIds = [null, ...pinnedIds];
        for (final categoryId in categoryIds) {
          ref
              .read(topicListProvider(categoryId).notifier)
              .updateSeen(topicId, highestSeen);
        }
        // 更新会话已读状态，触发 PostItem 消除未读圆点
        ref
            .read(topicSessionProvider(topicId).notifier)
            .markAsRead(postNumbers);
      },
    );

    _controller = TopicDetailController(
      scrollController: AutoScrollController(),
      screenTrack: _screenTrack,
      trackEnabled: trackEnabled,
      initialPostNumber: widget.scrollToPostNumber,
      onScrolled: () {
        if (_controller.trackEnabled) {
          _screenTrack.scrolled();
        }
      },
    );

    _controller.scrollController.addListener(_onScroll);
    _pageController = PageController(initialPage: 0);

    // 桌面端：注册 J/K 帖子导航 + AI 面板切换
    if (PlatformUtils.isDesktop) {
      toggleAiPanelNotifier.addListener(_onToggleAiPanel);
      _schedulePostShortcutRegistration();
    }
  }

  bool _isAiSheetOpen = false;

  void _onToggleAiPanel() {
    if (!mounted) return;
    final swipeMode = ref.read(preferencesProvider).aiSwipeEntry;
    if (swipeMode) {
      // 滑动模式：PageView 切换
      final target = _currentPageNotifier.value == 0 ? 1 : 0;
      _pageController.animateToPage(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    } else {
      // 弹窗模式：切换开关
      if (_isAiSheetOpen) {
        Navigator.of(context).pop();
        _isAiSheetOpen = false;
      } else {
        final detail = ref.read(topicDetailProvider(_params)).value;
        if (detail == null) return;
        _isAiSheetOpen = true;
        _showAiAssistantSheet(detail);
      }
    }
  }

  void _registerPostShortcuts() {
    // 闭包内用 mounted 保护，防止 disposed 后被调用
    final shortcuts = <ShortcutAction, VoidCallback>{
      ShortcutAction.nextItem: () {
        if (mounted) _scrollToNextPost();
      },
      ShortcutAction.previousItem: () {
        if (mounted) _scrollToPreviousPost();
      },
      ShortcutAction.jumpToPost: () {
        if (mounted) _showJumpToPostDialog();
      },
      ShortcutAction.goToUnreadPost: () {
        if (mounted) unawaited(_jumpToUnreadPost());
      },
      ShortcutAction.replyTopic: () {
        if (mounted) unawaited(_handleReply(null));
      },
      ShortcutAction.shareTopic: () {
        if (mounted) _shareTopic();
      },
      ShortcutAction.bookmarkTopic: () {
        if (!mounted) return;
        final traceId = createBookmarkEditTraceId();
        writeBookmarkEditTrace(
          phase: 'shortcut_triggered',
          traceId: traceId,
          source: 'topic_detail_topic_shortcut',
          message: '详情页快捷键触发编辑书签',
          topicId: widget.topicId,
          selectedAction: 'bookmark',
        );
        _handleBookmark(
          ref.read(topicDetailProvider(_params).notifier),
          traceId: traceId,
          source: 'topic_detail_topic_shortcut',
        );
      },
      ShortcutAction.replyPost: () {
        if (!mounted) return;
        final replyTarget = _currentReplyTargetPost();
        unawaited(_handleReply(replyTarget));
      },
      ShortcutAction.quotePost: () {
        if (!mounted) return;
        final post = _currentShortcutPost();
        if (post == null) return;
        unawaited(_handleQuotePost(post));
      },
      ShortcutAction.likePost: () {
        if (!mounted) return;
        final post = _currentShortcutPost();
        if (post == null) return;
        unawaited(_togglePostLike(post));
      },
      ShortcutAction.sharePost: () {
        if (!mounted) return;
        final post = _currentShortcutPost();
        if (post == null) return;
        _sharePost(post);
      },
      ShortcutAction.bookmarkPost: () {
        if (!mounted) return;
        final post = _currentShortcutPost();
        if (post == null) return;
        unawaited(_handlePostBookmark(post));
      },
      ShortcutAction.editPost: () {
        if (!mounted) return;
        final post = _currentShortcutPost();
        if (post == null || !post.canEdit) return;
        unawaited(_handleEdit(post));
      },
      ShortcutAction.flagPost: () {
        if (!mounted) return;
        final post = _currentShortcutPost();
        if (post == null) return;
        _showFlagPostSheet(post);
      },
      ShortcutAction.deletePost: () {
        if (!mounted) return;
        final post = _currentShortcutPost();
        if (post == null || !post.canDelete || post.deletedAt != null) return;
        unawaited(_handleDeletePost(post));
      },
    };
    final registeredShortcuts = widget.embeddedMode
        ? shortcuts
        : {
            ...shortcuts,
            ShortcutAction.closeOverlay: () {
              if (mounted) Navigator.of(context).maybePop();
            },
          };
    _shortcutScopeBinding.register(context, registeredShortcuts);
  }

  void _schedulePostShortcutRegistration() {
    if (!PlatformUtils.isDesktop) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _registerPostShortcuts();
    });
  }

  @override
  void didUpdateWidget(covariant TopicDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_userMutatedFallback &&
        (oldWidget.initialBookmarkId != widget.initialBookmarkId ||
            oldWidget.initialBookmarkName != widget.initialBookmarkName ||
            oldWidget.initialBookmarkReminderAt !=
                widget.initialBookmarkReminderAt ||
            oldWidget.initialBookmarkableType !=
                widget.initialBookmarkableType)) {
      _fallbackBookmarkId = widget.initialBookmarkId;
      _fallbackBookmarkName = widget.initialBookmarkName;
      _fallbackBookmarkReminderAt = widget.initialBookmarkReminderAt;
      _fallbackBookmarkableType = widget.initialBookmarkableType;
    }
    if (oldWidget.parentActive != widget.parentActive) {
      _isParentActive = widget.parentActive;
      _syncScreenTrackState(
        reason: _isParentActive ? 'parent_active' : 'parent_inactive',
      );
    }
    if (oldWidget.topicId == widget.topicId &&
        oldWidget.scrollToPostNumber != widget.scrollToPostNumber &&
        widget.scrollToPostNumber != null &&
        widget.scrollToPostNumber! > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(
          _handleExternalScrollTargetUpdate(widget.scrollToPostNumber!),
        );
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == _route || route == null) return;

    if (_route != null) {
      appRouteObserver.unsubscribe(this);
    }

    _route = route;
    appRouteObserver.subscribe(this, route);
    _isRouteVisible = route.isCurrent;
    _schedulePostShortcutRegistration();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncScreenTrackState(reason: 'route_subscribed');
    });
  }

  @override
  void dispose() {
    if (_route != null) {
      appRouteObserver.unsubscribe(this);
    }
    WidgetsBinding.instance.removeObserver(this);
    _expandController.dispose();
    _showTitleNotifier.dispose();
    _isScrolledUnderNotifier.dispose();
    _isOverlayVisibleNotifier.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _pageController.dispose();
    _currentPageNotifier.dispose();
    _controller.scrollController.removeListener(_onScroll);
    _screenTrack.stop();
    _controller.dispose();
    if (PlatformUtils.isDesktop) {
      toggleAiPanelNotifier.removeListener(_onToggleAiPanel);
      _shortcutScopeBinding.disposeDeferred();
    }
    // 延迟清理搜索状态，避免在 widget tree finalizing 期间修改 provider
    Future(_topicSearchNotifier.exitSearchMode);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final hasFocus = state == AppLifecycleState.resumed;
    _screenTrack.setHasFocus(hasFocus);
  }

  @override
  void didPush() {
    _setRouteVisible(true, 'did_push');
    _schedulePostShortcutRegistration();
  }

  @override
  void didPopNext() {
    _setRouteVisible(true, 'did_pop_next');
    _schedulePostShortcutRegistration();
  }

  @override
  void didPushNext() {
    _setRouteVisible(false, 'did_push_next');
  }

  @override
  void didPop() {
    _setRouteVisible(false, 'did_pop');
  }

  void _setRouteVisible(bool visible, String reason) {
    if (_isRouteVisible == visible) return;
    _isRouteVisible = visible;
    _syncScreenTrackState(reason: reason);
  }

  void _syncScreenTrackState({required String reason}) {
    final shouldRun =
        _controller.trackEnabled && _isRouteVisible && _isParentActive;
    if (shouldRun == _isScreenTrackRunning) return;

    if (shouldRun) {
      _screenTrack.start(widget.topicId);
      // start() 会 reset _onscreen，用 controller 当前已知的可见帖子恢复
      // 避免因 CF 验证等场景 stop→start 后 _onscreen 为空导致无法记录阅读时长
      if (_controller.visiblePostNumbers.isNotEmpty) {
        _screenTrack.setOnscreen(_controller.visiblePostNumbers);
        _screenTrack.scrolled();
      }
    } else {
      _screenTrack.stop();
    }
    _isScreenTrackRunning = shouldRun;

    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'info',
      'type': 'lifecycle',
      'event': 'screen_track_state',
      'message': shouldRun ? 'ScreenTrack 启动' : 'ScreenTrack 停止',
      'topicId': widget.topicId,
      'screenTrackSourceId': _instanceId,
      'routeVisible': _isRouteVisible,
      'parentActive': _isParentActive,
      'reason': reason,
    });
  }

  void _scheduleCheckTitleVisibility() {
    if (_isCheckTitleVisibilityScheduled || !mounted) return;
    _isCheckTitleVisibilityScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isCheckTitleVisibilityScheduled = false;
      if (mounted) {
        _checkTitleVisibility();
      }
    });
  }

  void _checkTitleVisibility() {
    final barHeight = kToolbarHeight + MediaQuery.of(context).padding.top;
    final ctx = _headerKey.currentContext;

    if (ctx == null) {
      // header 不在视图中（未加载或滚动到了远处）
      // 如果滚动位置在顶部附近（比如刚切换视图模式），header 很快就会出现，
      // 先设为不可见状态，等 header 渲染后由滚动事件再次触发更新
      final atTop =
          _controller.scrollController.hasClients &&
          _controller.scrollController.offset <= barHeight;
      if (atTop) {
        _showTitleNotifier.value = false;
        _isScrolledUnderNotifier.value = false;
      } else {
        if (_hasFirstPost) {
          _showTitleNotifier.value = true;
        }
        _isScrolledUnderNotifier.value = true;
      }
    } else {
      final box = ctx.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        final position = box.localToGlobal(Offset.zero);
        final headerVisible = position.dy >= barHeight;
        _showTitleNotifier.value = !headerVisible;
        _isScrolledUnderNotifier.value = !_hasFirstPost || !headerVisible;
      }
    }
  }

  void _toggleExpandedHeader() {
    if (_expandController.status == AnimationStatus.completed ||
        _expandController.status == AnimationStatus.forward) {
      _expandController.reverse();
    } else {
      _expandController.forward();
    }
  }

  void _maybeSwitchToMasterDetail(bool canShowDetailPane, TopicDetail? detail) {
    if (widget.embeddedMode) {
      _lastCanShowDetailPane = canShowDetailPane;
      return;
    }

    if (!widget.autoSwitchToMasterDetail) {
      _lastCanShowDetailPane = canShowDetailPane;
      return;
    }

    if (_isAutoSwitching) return;

    // 当前页面不在栈顶时（有其他页面覆盖），不更新状态也不触发导航
    // 这样返回后能正确检测到布局变化并执行切换
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;

    final previous = _lastCanShowDetailPane;
    _lastCanShowDetailPane = canShowDetailPane;

    if (previous == null) {
      if (canShowDetailPane) {
        _switchToMasterDetail(detail);
      }
      return;
    }
    if (previous == canShowDetailPane) return;
    if (!previous && canShowDetailPane) {
      _switchToMasterDetail(detail);
    }
  }

  void _switchToMasterDetail(TopicDetail? detail) {
    _isAutoSwitching = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (!navigator.canPop()) {
        _isAutoSwitching = false;
        return;
      }

      final currentPostNumber = _resolvedViewportPostNumber;
      ref
          .read(selectedTopicProvider.notifier)
          .select(
            topicId: widget.topicId,
            initialTitle: detail?.title ?? widget.initialTitle,
            scrollToPostNumber: currentPostNumber,
            instanceId: _instanceId,
          );
      navigator.pop();
    });
  }

  Future<void> _handleExternalScrollTargetUpdate(int postNumber) async {
    final detail = ref.read(topicDetailProvider(_params)).value;
    final notifier = ref.read(topicDetailProvider(_params).notifier);
    if (detail == null) {
      _controller.prepareJumpToPost(postNumber);
      if (mounted) setState(() {});
      await notifier.reloadWithPostNumber(postNumber);
      return;
    }
    await _scrollToPost(postNumber);
  }

  /// 在大屏上为内容添加宽度约束
  Widget _wrapWithConstraint(Widget child) {
    if (Responsive.isMobile(context)) return child;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: Breakpoints.maxContentWidth,
        ),
        child: child,
      ),
    );
  }

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
            hintText: context.l10n.topicDetail_searchHint,
            border: InputBorder.none,
            hintStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          style: theme.textTheme.bodyLarge,
          textInputAction: TextInputAction.search,
          onSubmitted: (query) {
            ref
                .read(topicSearchProvider(widget.topicId).notifier)
                .search(query);
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () {
              _searchController.clear();
              ref
                  .read(topicSearchProvider(widget.topicId).notifier)
                  .exitSearchMode();
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
              final currentElevation =
                  targetElevation * (1.0 - _expandController.value);
              final expandProgress = _expandController.value;
              final shouldShowTitle = showTitle || !_hasFirstPost;

              if (_usesEmbeddedMobileWorkspaceChrome) {
                return _buildEmbeddedMobileWorkspaceAppBar(
                  theme: theme,
                  detail: detail,
                  notifier: notifier,
                  elevation: currentElevation,
                );
              }

              return AppBar(
                automaticallyImplyLeading: !widget.embeddedMode,
                elevation: currentElevation,
                scrolledUnderElevation: currentElevation,
                shadowColor: Colors.transparent,
                surfaceTintColor: theme.colorScheme.surfaceTint.withValues(
                  alpha: (1.0 - expandProgress).clamp(0.0, 1.0),
                ),
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
              if (detail?.isPrivateMessage ?? false)
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      Icons.mail_outline,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              if (detail?.closed ?? false)
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      Icons.lock_outline,
                      size: 18,
                      color:
                          theme.textTheme.titleMedium?.color ??
                          theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              if (detail?.hasAcceptedAnswer ?? false)
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(Icons.check_box, size: 18, color: Colors.green),
                  ),
                ),
              ...EmojiText.buildEmojiSpans(
                context,
                detail?.title ?? widget.initialTitle ?? '',
                theme.textTheme.titleMedium,
              ),
            ],
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  bool _canEditTopic(TopicDetail detail) {
    final firstPost = detail.postStream.posts
        .where((p) => p.postNumber == 1)
        .firstOrNull;
    return detail.canEdit || (firstPost?.canEdit ?? false);
  }

  TopicBookmarkEditTarget? _bookmarkEditTarget(TopicDetail detail) {
    return resolveTopicBookmarkEditTarget(
      detail: detail,
      fallbackBookmarkId: _fallbackBookmarkId,
      fallbackBookmarkName: _fallbackBookmarkName,
      fallbackBookmarkReminderAt: _fallbackBookmarkReminderAt,
      fallbackBookmarkableType: _fallbackBookmarkableType,
      scrollToPostNumber: widget.scrollToPostNumber,
    );
  }

  PreferredSizeWidget _buildEmbeddedMobileWorkspaceAppBar({
    required ThemeData theme,
    required TopicDetail? detail,
    required TopicDetailNotifier notifier,
    required double elevation,
  }) {
    return MobileTopicWorkspaceAppBar(
      backButtonKey: const ValueKey('bookmark-workspace-mobile-back'),
      closeButtonKey: const ValueKey('bookmark-workspace-mobile-close'),
      backgroundColor: theme.colorScheme.surface,
      elevation: elevation,
      scrolledUnderElevation: elevation,
      shadowColor: Colors.transparent,
      surfaceTintColor: theme.colorScheme.surfaceTint.withValues(alpha: 1),
      onBack: widget.onEmbeddedBack!,
      onClose: widget.onEmbeddedClose!,
      title: _buildEmbeddedMobileWorkspaceTitle(theme, detail),
      actions: [
        _buildSearchAction(),
        MobileWorkspaceCountButton(
          key: const ValueKey('bookmark-workspace-mobile-count-button'),
          count: widget.embeddedTabCount!,
          tooltip: S.current.bookmarks_workspaceOpenedCount(
            widget.embeddedTabCount!,
          ),
          onPressed: widget.onEmbeddedShowTabs,
        ),
        if (detail != null)
          _buildMoreMenuAction(
            detail: detail,
            notifier: notifier,
            canEditTopic: _canEditTopic(detail),
          ),
      ],
    );
  }

  Widget _buildEmbeddedMobileWorkspaceTitle(
    ThemeData theme,
    TopicDetail? detail,
  ) {
    return GestureDetector(
      onTap: detail == null ? null : _toggleExpandedHeader,
      child: Text.rich(
        TextSpan(
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w500,
          ),
          children: [
            if (detail?.isPrivateMessage ?? false)
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.mail_outline,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            if (detail?.closed ?? false)
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.lock_outline,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (detail?.hasAcceptedAnswer ?? false)
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(Icons.check_box, size: 16, color: Colors.green),
                ),
              ),
            ...EmojiText.buildEmojiSpans(
              context,
              detail?.title ?? widget.initialTitle ?? '',
              theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w500),
            ),
          ],
        ),
        key: const ValueKey('bookmark-workspace-mobile-title-text'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildSearchAction() {
    return IconButton(
      key: _usesEmbeddedMobileWorkspaceChrome
          ? const ValueKey('bookmark-workspace-mobile-search')
          : null,
      icon: const Icon(Icons.search),
      tooltip: context.l10n.topicDetail_searchTopic,
      onPressed: () {
        ref
            .read(topicSearchProvider(widget.topicId).notifier)
            .enterSearchMode();
      },
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

    final canEditTopic = _canEditTopic(detail);

    final useSwipeEntry = ref.watch(
      preferencesProvider.select((p) => p.aiSwipeEntry),
    );
    final hasAiModel = ref.watch(hasAvailableAiModelProvider);
    final isAiGenerating = hasAiModel
        ? ref.watch(
            topicAiChatProvider(
              widget.topicId,
            ).select((state) => state.isGenerating),
          )
        : false;

    return [
      // AI 助手按钮（滑动入口模式下隐藏）
      if (!useSwipeEntry && hasAiModel)
        IconButton(
          icon: _AiAssistantActionIcon(isGenerating: isAiGenerating),
          tooltip: context.l10n.topicDetail_aiAssistant,
          onPressed: () => _showAiAssistantSheet(detail),
        ),
      _buildSearchAction(),
      _buildMoreMenuAction(
        detail: detail,
        notifier: notifier,
        canEditTopic: canEditTopic,
      ),
    ];
  }

  Widget _buildMoreMenuAction({
    required TopicDetail detail,
    required TopicDetailNotifier notifier,
    required bool canEditTopic,
  }) {
    final bookmarkTarget = _bookmarkEditTarget(detail);
    final hasEditableBookmark = bookmarkTarget != null || detail.bookmarked;
    final isInReadLater = ref
        .read(readLaterProvider.notifier)
        .contains(widget.topicId);
    final hasFilter = notifier.isSummaryMode ||
        notifier.isAuthorOnlyMode ||
        notifier.isTopLevelMode ||
        _isNestedView;
    final bool subscribed =
        detail.notificationLevel.value >= TopicNotificationLevel.tracking.value;

    void doBookmark() {
      final traceTarget = _bookmarkEditTarget(detail);
      final traceId = createBookmarkEditTraceId();
      writeBookmarkEditTrace(
        phase: 'menu_selected',
        traceId: traceId,
        source: 'topic_detail_topic_menu',
        message: '详情页更多菜单已选中编辑书签',
        topicId: widget.topicId,
        postId: traceTarget?.postId,
        bookmarkId: traceTarget?.bookmarkId ?? detail.bookmarkId,
        bookmarkName: traceTarget?.initialName ?? detail.bookmarkName,
        bookmarked: detail.bookmarked,
        hasReminder: traceTarget?.initialReminderAt != null ||
            detail.bookmarkReminderAt != null,
        selectedAction: 'bookmark',
      );
      unawaited(_handleBookmark(
        notifier,
        traceId: traceId,
        source: 'topic_detail_topic_menu',
      ));
    }

    void doSubscribe() {
      showNotificationLevelSheet(
        context,
        detail.notificationLevel,
        (level) => _handleNotificationLevelChanged(notifier, level),
      );
    }

    return SwipeDismissiblePopupMenuButton<String>(
      key: _usesEmbeddedMobileWorkspaceChrome
          ? const ValueKey('bookmark-workspace-mobile-more')
          : null,
      icon: const Icon(Icons.more_vert),
      tooltip: context.l10n.topicDetail_moreOptions,
      headerActions: [
        MenuQuickAction(
          icon: hasEditableBookmark ? Icons.bookmark : Icons.bookmark_border,
          tooltip: hasEditableBookmark
              ? context.l10n.topicDetail_editBookmark
              : context.l10n.common_addBookmark,
          active: hasEditableBookmark,
          onTap: doBookmark,
        ),
        MenuQuickAction(
          icon: isInReadLater ? Icons.layers : Icons.layers_outlined,
          tooltip: isInReadLater
              ? context.l10n.topicDetail_removeFromReadLater
              : context.l10n.topicDetail_addToReadLater,
          active: isInReadLater,
          onTap: _handleReadLater,
        ),
        MenuQuickAction(
          icon: TopicNotificationButton.getIcon(detail.notificationLevel),
          tooltip: context.l10n.topic_notificationSettings,
          active: subscribed,
          submenu: MenuQuickActionSubmenu(
            icon: TopicNotificationButton.getIcon(detail.notificationLevel),
            label: context.l10n.topic_notificationSettings,
            iconColor: subscribed
                ? Theme.of(context).colorScheme.primary
                : null,
            children: [
              for (final level in TopicNotificationLevel.values)
                MenuQuickActionSubmenuChild(
                  icon: TopicNotificationButton.getIcon(level),
                  label: level.label,
                  subtitle: level.description,
                  selected: level == detail.notificationLevel,
                  onTap: () =>
                      _handleNotificationLevelChanged(notifier, level),
                ),
            ],
          ),
        ),
        if (!detail.isPrivateMessage)
          MenuQuickAction(
            icon: Icons.link,
            tooltip: context.l10n.topicDetail_shareLink,
            onTap: _shareTopic,
          ),
        MenuQuickAction(
          icon: Icons.filter_list,
          tooltip: context.l10n.topicDetail_filter,
          active: hasFilter,
          submenu: MenuQuickActionSubmenu(
            icon: Icons.filter_list,
            label: context.l10n.topicDetail_filter,
            iconColor: hasFilter
                ? Theme.of(context).colorScheme.primary
                : null,
            children: [
              if (detail.hasSummary)
                MenuQuickActionSubmenuChild(
                  icon: notifier.isSummaryMode
                      ? Icons.local_fire_department
                      : Icons.local_fire_department_outlined,
                  label: context.l10n.topicDetail_hotOnly,
                  selected: notifier.isSummaryMode,
                  onTap: () {
                    if (notifier.isSummaryMode) {
                      _handleCancelFilter();
                    } else {
                      _handleShowTopReplies();
                    }
                  },
                ),
              MenuQuickActionSubmenuChild(
                icon: notifier.isAuthorOnlyMode
                    ? Icons.person
                    : Icons.person_outline,
                label: context.l10n.topicDetail_authorOnly,
                selected: notifier.isAuthorOnlyMode,
                onTap: () {
                  if (notifier.isAuthorOnlyMode) {
                    _handleCancelFilter();
                  } else {
                    _handleShowAuthorOnly();
                  }
                },
              ),
              MenuQuickActionSubmenuChild(
                icon: notifier.isTopLevelMode
                    ? Icons.account_tree
                    : Icons.account_tree_outlined,
                label: context.l10n.topicDetail_topLevelOnly,
                selected: notifier.isTopLevelMode,
                onTap: () {
                  if (notifier.isTopLevelMode) {
                    _handleCancelFilter();
                  } else {
                    _handleShowTopLevelReplies();
                  }
                },
              ),
              MenuQuickActionSubmenuChild(
                icon: _isNestedView ? Icons.forum : Icons.forum_outlined,
                label: context.l10n.nested_title,
                selected: _isNestedView,
                onTap: _toggleNestedView,
              ),
              if (hasFilter)
                MenuQuickActionSubmenuChild(
                  icon: Icons.filter_list_off,
                  label: context.l10n.common_cancel,
                  onTap: _handleCancelFilter,
                ),
            ],
          ),
        ),
      ],
      onSelected: (value) {
        // 行内展开的订阅子项：value 形如 'subscribe_level_<int>'
        const subscribePrefix = 'subscribe_level_';
        if (value.startsWith(subscribePrefix)) {
          final levelValue =
              int.tryParse(value.substring(subscribePrefix.length));
          if (levelValue != null) {
            final level = TopicNotificationLevel.values.firstWhere(
              (e) => e.value == levelValue,
              orElse: () => detail.notificationLevel,
            );
            _handleNotificationLevelChanged(notifier, level);
          }
          return;
        }
        final bookmarkTraceTarget =
            value == 'bookmark' ? _bookmarkEditTarget(detail) : null;
        final bookmarkTraceId =
            value == 'bookmark' ? createBookmarkEditTraceId() : null;
        if (bookmarkTraceId != null) {
          writeBookmarkEditTrace(
            phase: 'menu_selected',
            traceId: bookmarkTraceId,
            source: 'topic_detail_topic_menu',
            message: '详情页更多菜单已选中编辑书签',
            topicId: widget.topicId,
            postId: bookmarkTraceTarget?.postId,
            bookmarkId: bookmarkTraceTarget?.bookmarkId ?? detail.bookmarkId,
            bookmarkName:
                bookmarkTraceTarget?.initialName ?? detail.bookmarkName,
            bookmarked: detail.bookmarked,
            hasReminder:
                bookmarkTraceTarget?.initialReminderAt != null ||
                detail.bookmarkReminderAt != null,
            selectedAction: value,
          );
        }
        handleTopicDetailMoreMenuSelection(
          value,
          onEditTopic: () => unawaited(_handleEditTopic()),
          onBookmark: () => unawaited(
            _handleBookmark(
              notifier,
              traceId: bookmarkTraceId,
              source: 'topic_detail_topic_menu',
            ),
          ),
          onReadLater: _handleReadLater,
          onSubscribe: doSubscribe,
          onShareLink: _shareTopic,
          onShareImage: _shareAsImage,
          onExport: _showExportSheet,
          onOpenInBrowser: _openInBrowser,
          onFilter: _showFilterSheet,
          onReadingSettings: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ReadingSettingsPage()),
            );
          },
        );
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
                Text(context.l10n.topicDetail_editTopic),
              ],
            ),
          ),
        if (!detail.isPrivateMessage)
          PopupMenuItem(
            value: 'share_image',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.image_outlined,
                  size: 20,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                const SizedBox(width: 12),
                Text(context.l10n.topicDetail_generateShareImage),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'export',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.download_outlined,
                size: 20,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              const SizedBox(width: 12),
              Text(context.l10n.topicDetail_exportArticle),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'open_in_browser',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.language,
                size: 20,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              const SizedBox(width: 12),
              Text(context.l10n.topicDetail_openInBrowser),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'reading_settings',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.auto_stories_rounded,
                size: 20,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              const SizedBox(width: 12),
              Text(context.l10n.settings_reading),
            ],
          ),
        ),
      ],
    );
  }

  void _showTimelineSheet(TopicDetail detail) {
    showTopicTimelineSheet(
      context: context,
      currentIndex: _controller.currentVisibleStreamIndex,
      stream: detail.postStream.stream,
      onJumpToPostId: _scrollToPostById,
      title: detail.title,
    );
  }

  /// 路由进度悬浮条手势触发的 [ProgressGestureAction] 到对应业务方法
  void _handleProgressGesture(
    ProgressGestureAction action,
    TopicDetail detail,
    TopicDetailNotifier notifier,
  ) {
    switch (action) {
      case ProgressGestureAction.none:
        return;
      case ProgressGestureAction.openTimeline:
        _showTimelineSheet(detail);
      case ProgressGestureAction.scrollToTop:
        unawaited(_scrollToTop());
      case ProgressGestureAction.jumpToUnread:
        unawaited(_jumpToUnreadPost());
      case ProgressGestureAction.nextPost:
        _scrollToNextPost();
      case ProgressGestureAction.previousPost:
        _scrollToPreviousPost();
      case ProgressGestureAction.reply:
        unawaited(_handleReply(null));
      case ProgressGestureAction.share:
        _shareTopic();
      case ProgressGestureAction.shareImage:
        _shareAsImage();
      case ProgressGestureAction.exportArticle:
        _showExportSheet();
      case ProgressGestureAction.openInBrowser:
        _openInBrowser();
      case ProgressGestureAction.bookmark:
        final traceId = createBookmarkEditTraceId();
        writeBookmarkEditTrace(
          phase: 'gesture_triggered',
          traceId: traceId,
          source: 'topic_detail_progress_gesture',
          message: '进度悬浮条手势触发编辑书签',
          topicId: widget.topicId,
        );
        unawaited(
          _handleBookmark(
            notifier,
            traceId: traceId,
            source: 'topic_detail_progress_gesture',
          ),
        );
      case ProgressGestureAction.readLater:
        _handleReadLater();
      case ProgressGestureAction.notification:
        showNotificationLevelSheet(
          context,
          detail.notificationLevel,
          (level) => _handleNotificationLevelChanged(notifier, level),
        );
      case ProgressGestureAction.filter:
        _showFilterSheet();
      case ProgressGestureAction.toggleNestedView:
        _toggleNestedView();
      case ProgressGestureAction.aiAssistant:
        _onToggleAiPanel();
      case ProgressGestureAction.readingSettings:
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ReadingSettingsPage()),
        );
      case ProgressGestureAction.search:
        ref
            .read(topicSearchProvider(widget.topicId).notifier)
            .enterSearchMode();
      case ProgressGestureAction.refresh:
        unawaited(_handleRefresh());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLoggedIn = ref.watch(currentUserProvider).value != null;
    final canShowDetailPane = MasterDetailLayout.canShowBothPanesFor(context);

    ref.listen<AsyncValue<void>>(authStateProvider, (_, _) {
      if (!context.mounted) return;
      final stillLoggedIn = ref.read(currentUserProvider).value != null;
      if (_controller.trackEnabled != stillLoggedIn) {
        _controller.trackEnabled = stillLoggedIn;
        _syncScreenTrackState(
          reason: stillLoggedIn ? 'auth_logged_in' : 'auth_logged_out',
        );
      }
    });

    final params = _params;
    final detailAsync = ref.watch(topicDetailProvider(params));
    final detail = detailAsync.value;
    final notifier = ref.read(topicDetailProvider(params).notifier);

    _maybeSwitchToMasterDetail(canShowDetailPane, detail);

    // 监听 MessageBus 事件
    ref.listen(topicChannelProvider(widget.topicId), (previous, next) {
      if (!context.mounted) return;
      // 1. reload_topic（话题状态变更：关闭/打开/固定等）
      if (next.reloadRequested && !(previous?.reloadRequested ?? false)) {
        ref
            .read(topicChannelProvider(widget.topicId).notifier)
            .clearReloadRequest();
        _handleReloadTopic(notifier, next.refreshStreamRequested);
        return;
      }

      // 2. notification_level_change（通知级别变更）
      if (next.notificationLevelChange != null &&
          previous?.notificationLevelChange != next.notificationLevelChange) {
        final level = TopicNotificationLevel.fromValue(
          next.notificationLevelChange!,
        );
        ref
            .read(topicChannelProvider(widget.topicId).notifier)
            .clearNotificationLevelChange();
        notifier.updateNotificationLevelLocally(level);
        return;
      }

      // 3. stats 更新
      if (next.statsUpdate != null &&
          previous?.statsUpdate != next.statsUpdate) {
        notifier.applyStatsUpdate(next.statsUpdate!);
        ref
            .read(topicChannelProvider(widget.topicId).notifier)
            .clearStatsUpdate();
      }

      // 3.1 "俺也一样" (shared_issue) 计数更新
      //   - 服务端广播包含 `count` 与 *操作用户的* userCreated
      //   - 接收端只接受 count；userCreated 不能覆写本地状态(因为对所有订阅者一致)
      //   - 自己点击的 toggle 响应已直接写入 detail,所以即便回声也只是同值刷新,幂等
      if (next.sharedIssueUpdate != null &&
          previous?.sharedIssueUpdate != next.sharedIssueUpdate) {
        final currentDetail = ref.read(topicDetailProvider(params)).value;
        if (currentDetail != null) {
          notifier.updateSharedIssue(
            next.sharedIssueUpdate!.count,
            currentDetail.userCreatedSharedIssue,
          );
        }
        ref
            .read(topicChannelProvider(widget.topicId).notifier)
            .clearSharedIssueUpdate();
      }

      // 4. 帖子级别更新（created/revised/deleted/liked 等）
      final prevLen = previous?.postUpdates.length ?? 0;
      final nextLen = next.postUpdates.length;
      if (nextLen > prevLen) {
        final newUpdates = next.postUpdates.sublist(prevLen);
        for (final update in newUpdates) {
          _handlePostUpdate(notifier, update);
        }
      }
    });

    // 预解析帖子 HTML
    ref.listen(topicDetailProvider(params), (previous, next) {
      if (!context.mounted) return;
      final detail = next.value;
      // 记录话题标题到会话状态，供用户卡片「基于话题的私信」预填标题
      if (detail != null) {
        ref.read(topicSessionProvider(widget.topicId).notifier).setTopicTitle(detail.title);
      }
      // 首次拿到 detail 后再决定是否应用默认嵌套视图：
      // 私信场景下树形视图 API 拉不到数据，跳过该配置
      if (!_defaultNestedViewApplied && detail != null) {
        _defaultNestedViewApplied = true;
        if (!detail.isPrivateMessage &&
            ref.read(preferencesProvider).defaultNestedView) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() => _isNestedView = true);
            }
          });
        }
      }
      final posts = detail?.postStream.posts;
      if (posts != null && posts.isNotEmpty) {
        final htmlList = posts.map((p) => p.cooked).toList();
        ChunkedHtmlContent.preloadAll(htmlList);

        // 预热 Pangu 混排处理（在 isolate 中执行）
        if (ref.read(preferencesProvider).displayPanguSpacing) {
          DiscourseHtmlContent.preloadPangu(htmlList);
        }

        final hasFirstPost = posts.first.postNumber == 1;
        if (_hasFirstPost != hasFirstPost) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() => _hasFirstPost = hasFirstPost);
              _scheduleCheckTitleVisibility();
            }
          });
        }

        // 自动打开回复框（从草稿进入时）
        if (widget.autoOpenReply && !_autoOpenReplyHandled) {
          _autoOpenReplyHandled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              // 如果指定了回复帖子编号，找到对应的帖子
              Post? replyToPost;
              if (widget.autoReplyToPostNumber != null) {
                replyToPost = posts
                    .where((p) => p.postNumber == widget.autoReplyToPostNumber)
                    .firstOrNull;
              }
              _handleReply(replyToPost);
            }
          });
        }

        // 自动打开编辑历史 modal(从编辑通知点击进入时)
        if (widget.initialRevisionPostNumber != null &&
            widget.initialRevisionNumber != null &&
            !_autoOpenRevisionHandled) {
          final targetPost = posts
              .where((p) => p.postNumber == widget.initialRevisionPostNumber)
              .firstOrNull;
          if (targetPost != null) {
            _autoOpenRevisionHandled = true;
            WidgetsBinding.instance.addPostFrameCallback((_) async {
              if (!mounted) return;
              await _scrollToPost(widget.initialRevisionPostNumber!);
              if (!mounted) return;
              if (!context.mounted) return;
              await showPostRevisionSheet(
                context: context,
                postId: targetPost.id,
                initialRevision: widget.initialRevisionNumber,
              );
            });
          }
        }

        // 自动打开 AI 聊天面板（从会话历史进入时）
        if (widget.autoOpenAiChat && !_autoOpenAiChatHandled) {
          _autoOpenAiChatHandled = true;
          final topicDetail = next.value!;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            // 如果指定了会话 ID，先切换到该会话
            if (widget.initialSessionId != null) {
              ref
                  .read(topicAiChatProvider(widget.topicId).notifier)
                  .switchSession(widget.initialSessionId!);
            }
            final swipeMode = ref.read(preferencesProvider).aiSwipeEntry;
            if (swipeMode) {
              _pageController.animateToPage(
                1,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
              );
            } else {
              _showAiAssistantSheet(topicDetail);
            }
          });
        }
      }
    });

    final searchState = ref.watch(topicSearchProvider(widget.topicId));
    final isSearchMode = searchState.isSearchMode;
    final hasAiModel = ref.watch(hasAvailableAiModelProvider);
    final useSwipeEntry = ref.watch(
      preferencesProvider.select((p) => p.aiSwipeEntry),
    );

    // 保持当前话题页内的 AI 状态存活，避免 BottomSheet 关闭后丢失
    // 已选模型、文本/生图模式和消息列表。离开话题页后仍由 autoDispose 释放。
    if (hasAiModel) {
      ref.watch(topicAiChatProvider(widget.topicId));
      ref.watch(topicSelectedAiModelProvider(widget.topicId));
      ref.watch(topicChatModeProvider(widget.topicId));
    }

    // 首次引导检查（仅滑动入口模式）
    if (useSwipeEntry && hasAiModel && !_aiGuideChecked && detail != null) {
      _aiGuideChecked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          final prefs = ref.read(sharedPreferencesProvider);
          AiChatGuide.checkAndShow(prefs);
        }
      });
    }

    final topicScaffold = Scaffold(
      appBar: _buildAppBar(theme: theme, detail: detail, notifier: notifier),
      body: _buildBody(context, detailAsync, detail, notifier, isLoggedIn),
    );

    // 无 AI 模型或非滑动入口模式：普通布局
    if (!hasAiModel || !useSwipeEntry) {
      return LazyLoadScope(
        child: PopScope(
          canPop: !isSearchMode,
          onPopInvokedWithResult: (bool didPop, dynamic result) {
            if (!didPop) {
              _searchController.clear();
              ref
                  .read(topicSearchProvider(widget.topicId).notifier)
                  .exitSearchMode();
            }
          },
          child: topicScaffold,
        ),
      );
    }

    // 滑动入口模式：PageView 包裹话题详情和 AI 聊天
    return LazyLoadScope(
      child: ValueListenableBuilder<int>(
        valueListenable: _currentPageNotifier,
        builder: (context, currentPage, _) {
          final isOnAiPage = currentPage != 0;
          return PopScope(
            canPop: !isSearchMode && !isOnAiPage,
            onPopInvokedWithResult: (bool didPop, dynamic result) {
              if (!didPop) {
                if (isOnAiPage) {
                  _pageController.animateToPage(
                    0,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                  );
                } else {
                  _searchController.clear();
                  ref
                      .read(topicSearchProvider(widget.topicId).notifier)
                      .exitSearchMode();
                }
              }
            },
            child: PageView(
              controller: _pageController,
              physics: isSearchMode
                  ? const NeverScrollableScrollPhysics()
                  : const ClampingScrollPhysics(),
              onPageChanged: (page) {
                _currentPageNotifier.value = page;
                // 离开 AI 页面时取消输入框焦点，防止返回时键盘意外弹出
                if (page != 1) {
                  FocusManager.instance.primaryFocus?.unfocus();
                }
              },
              children: [
                _KeepAlivePage(child: topicScaffold),
                _KeepAlivePage(
                  child: AiChatPage(
                    topicId: widget.topicId,
                    detail: detail,
                    embedded: true,
                    onReplyToTopic: detail == null
                        ? null
                        : (imageMarkdown) {
                            _pageController.animateToPage(
                              0,
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeOutCubic,
                            );
                            showReplySheet(
                              context: context,
                              topicId: widget.topicId,
                              categoryId: detail.categoryId,
                              initialContent: '$imageMarkdown\n',
                              topicTitle: detail.title,
                              isPrivateMessageTopic: detail.isPrivateMessage,
                            );
                          },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showAiAssistantSheet(TopicDetail detail) {
    _isAiSheetOpen = true;
    // 在 modal 外部获取状态栏高度，因为 showModalBottomSheet 会清零 padding.top
    final topPadding = MediaQuery.of(context).padding.top;
    showAppBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shortcutSurface: const ShortcutSurfaceConfig(
        id: ShortcutSurfaceIds.topicAiAssistant,
        triggerAction: ShortcutAction.toggleAiPanel,
        repeatBehavior: ShortcutSurfaceRepeatBehavior.toggle,
      ),
      builder: (sheetContext) => AiChatPage(
        topicId: widget.topicId,
        detail: detail,
        topPadding: topPadding,
        onReplyToTopic: (imageMarkdown) {
          // 关闭 AI Sheet（预览页已在内部自行关闭）
          Navigator.pop(sheetContext);
          // 打开回复框，预填上传后的图片 markdown
          showReplySheet(
            context: context,
            topicId: widget.topicId,
            categoryId: detail.categoryId,
            initialContent: '$imageMarkdown\n',
            topicTitle: detail.title,
            isPrivateMessageTopic: detail.isPrivateMessage,
          );
        },
      ),
    ).then((_) => _isAiSheetOpen = false);
  }

  Widget _buildBody(
    BuildContext context,
    AsyncValue<TopicDetail> detailAsync,
    TopicDetail? detail,
    TopicDetailNotifier notifier,
    bool isLoggedIn,
  ) {
    final params = _params;
    final searchState = ref.watch(topicSearchProvider(widget.topicId));
    final isSearchMode = searchState.isSearchMode;

    // 初始加载或切换模式时显示骨架屏
    // 注意：当 hasError 为 true 时，即使 isLoading 也为 true（AsyncLoading.copyWithPrevious 语义），
    // 也应该优先显示错误页面而不是骨架屏
    if (_isSwitchingMode) {
      final showHeaderSkeleton =
          widget.scrollToPostNumber == null || widget.scrollToPostNumber == 0;
      return _wrapWithConstraint(
        PostListSkeleton(withHeader: showHeaderSkeleton),
      );
    }

    if (detailAsync.isLoading && detail == null) {
      final showHeaderSkeleton =
          widget.scrollToPostNumber == null || widget.scrollToPostNumber == 0;
      return _wrapWithConstraint(
        PostListSkeleton(withHeader: showHeaderSkeleton),
      );
    }

    // 跳转中：等待包含目标帖子的新数据 - 显示骨架屏
    final jumpTarget = _controller.jumpTargetPostNumber;
    if (jumpTarget != null && detail != null) {
      final posts = detail.postStream.posts;
      // 检查目标帖子是否在当前加载的范围内
      final hasTarget =
          posts.isNotEmpty &&
          posts.first.postNumber <= jumpTarget &&
          posts.last.postNumber >= jumpTarget;
      if (!hasTarget) {
        return _wrapWithConstraint(const PostListSkeleton(withHeader: false));
      }
    }

    Widget content = const SizedBox();

    if (detailAsync.hasError && detail == null) {
      // 错误页面
      content = CustomScrollView(
        slivers: [
          SliverErrorView(
            error: detailAsync.error!,
            onRetry: () => ref.refresh(topicDetailProvider(params)),
          ),
        ],
      );
    } else if (detail != null) {
      // 正常内容构建 (保持原有逻辑，但简化提取)
      content = _buildPostListContent(context, detail, notifier, isLoggedIn);
    }

    // Stack 组装
    return Stack(
      children: [
        // 使用 Offstage 保持帖子列表存在但在搜索模式下隐藏，保留滚动位置
        Offstage(offstage: isSearchMode, child: content),

        // 搜索视图
        if (isSearchMode)
          TopicSearchView(
            topicId: widget.topicId,
            onJumpToPost: (postNumber) {
              // 退出搜索模式并跳转到指定帖子
              ref
                  .read(topicSearchProvider(widget.topicId).notifier)
                  .exitSearchMode();
              _searchController.clear();
              _scrollToPost(postNumber);
            },
          ),

        // TopicDetailOverlay (Bottom Bar)
        // 使用 ValueListenableBuilder 隔离状态变化，避免整页重建
        if (detail != null && !isSearchMode)
          ValueListenableBuilder<bool>(
            valueListenable: _controller.showBottomBarNotifier,
            builder: (context, showBottomBar, _) {
              return ValueListenableBuilder<int>(
                valueListenable: _controller.streamIndexNotifier,
                builder: (context, currentStreamIndex, _) {
                  return TopicDetailOverlay(
                    showBottomBar: showBottomBar,
                    isLoggedIn: isLoggedIn,
                    currentStreamIndex: currentStreamIndex,
                    totalCount: detail.postStream.stream.length,
                    detail: detail,
                    onScrollToTop: _scrollToTop,
                    onShare: _shareTopic,
                    onShareAsImage: _shareAsImage,
                    onExport: _showExportSheet,
                    onOpenInBrowser: _openInBrowser,
                    onReply: () => _handleReply(null),
                    onProgressTap: () => _showTimelineSheet(detail),
                    onProgressGesture: (action) =>
                        _handleProgressGesture(action, detail, notifier),
                    isSummaryMode: notifier.isSummaryMode,
                    isAuthorOnlyMode: notifier.isAuthorOnlyMode,
                    isTopLevelMode: notifier.isTopLevelMode,
                    isNestedMode: _isNestedView,
                    isLoading: _isSwitchingMode,
                    onShowTopReplies: _handleShowTopReplies,
                    onShowAuthorOnly: _handleShowAuthorOnly,
                    onShowTopLevelReplies: _handleShowTopLevelReplies,
                    onCancelFilter: _handleCancelFilter,
                    onShowNestedView: _toggleNestedView,
                  );
                },
              );
            },
          ),

        // Expanded Header 相关组件（使用 ValueListenableBuilder 隔离状态变化）
        if (!isSearchMode)
          ValueListenableBuilder<bool>(
            valueListenable: _isOverlayVisibleNotifier,
            builder: (context, isOverlayVisible, _) {
              if (!isOverlayVisible) return const SizedBox.shrink();

              return Stack(
                children: [
                  // Expanded Header Barrier
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: _toggleExpandedHeader,
                      child: FadeTransition(
                        opacity: _expandController,
                        child: Container(color: Colors.black54),
                      ),
                    ),
                  ),

                  // Expanded Header
                  if (detail != null)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: SlideTransition(
                        position: _animation,
                        child: Container(
                          constraints: BoxConstraints(
                            maxHeight: MediaQuery.of(context).size.height * 0.7,
                          ),
                          child: Material(
                            color: Theme.of(context).colorScheme.surface,
                            elevation: 0,
                            borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(16),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: SingleChildScrollView(
                              child: TopicDetailHeader(
                                detail: detail,
                                headerKey: null,
                                onVoteChanged: _handleVoteChanged,
                                onNotificationLevelChanged: (level) =>
                                    _handleNotificationLevelChanged(
                                      notifier,
                                      level,
                                    ),
                                onJumpToPost: _scrollToPost,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }

  Widget _buildPostListContent(
    BuildContext context,
    TopicDetail detail,
    TopicDetailNotifier notifier,
    bool isLoggedIn,
  ) {
    final posts = detail.postStream.posts;
    final hasFirstPost = posts.isNotEmpty && posts.first.postNumber == 1;
    final sessionState = ref.watch(topicSessionProvider(widget.topicId));

    if (posts.isNotEmpty) {
      final readPostNumbers = <int>{};
      for (final post in posts) {
        if (post.read) {
          readPostNumbers.add(post.postNumber);
        }
      }
      readPostNumbers.addAll(sessionState.readPostNumbers);
      _updateReadPostNumbers(readPostNumbers);
    }

    // 计算分割线位置（热门回复模式下不显示）
    int? dividerPostIndex;
    if (!notifier.isSummaryMode) {
      final lastRead = detail.lastReadPostNumber;
      final totalPosts = detail.postsCount;
      if (lastRead != null && lastRead > 3 && (totalPosts - lastRead) > 1) {
        for (int i = 0; i < posts.length; i++) {
          if (posts[i].postNumber > lastRead) {
            dividerPostIndex = i;
            break;
          }
        }
      }
    }

    // 初始定位
    if (!_controller.hasInitialScrolled && posts.isNotEmpty) {
      _controller.markInitialScrolled(posts.first.postNumber);
      final initialTargetPostNumber =
          _controller.jumpTargetPostNumber ?? _resolvedViewportPostNumber;
      if (initialTargetPostNumber == null || initialTargetPostNumber == 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_controller.isPositioned) {
            _controller.markPositioned();
          }
        });
      } else {
        _scrollToInitialPosition(posts, dividerPostIndex);
      }
    }

    final centerPostIndex = _controller.findCenterPostIndex(posts);

    // 嵌套视图模式
    if (_isNestedView) {
      final nestedParams = NestedTopicParams(topicId: widget.topicId);
      final nestedAsync = ref.watch(nestedTopicProvider(nestedParams));

      Widget nestedView = nestedAsync.when(
        loading: () => PostListSkeleton(withHeader: true),
        error: (e, s) => ErrorView(
          error: e,
          stackTrace: s,
          onRetry: () => ref.invalidate(nestedTopicProvider(nestedParams)),
        ),
        data: (nestedState) => NestedPostList(
          nestedState: nestedState,
          params: nestedParams,
          detail: detail,
          topicId: widget.topicId,
          scrollController: _controller.scrollController,
          headerKey: _headerKey,
          hideHeaderTitle: widget.hideInlineHeaderTitle,
          isLoggedIn: isLoggedIn,
          onReply: _handleReply,
          onEdit: _handleEdit,
          onRefreshPost: _handleRefreshPost,
          onJumpToPost: _scrollToPost,
          onVoteChanged: _handleVoteChanged,
          onSharedIssueChanged: _handleSharedIssueChanged,
          onNotificationLevelChanged: (level) =>
              _handleNotificationLevelChanged(notifier, level),
          onSolutionChanged: _handleSolutionChanged,
          onScrollNotification: _controller.handleScrollNotification,
          onVisiblePostsChanged: _updateVisiblePosts,
        ),
      );

      return _wrapWithConstraint(nestedView);
    }

    // 使用 Consumer + select 隔离 typingUsers 状态变化，避免整页重建
    Widget scrollView = Consumer(
      builder: (context, ref, _) {
        final typingUsers = ref.watch(
          topicChannelProvider(widget.topicId).select((s) => s.typingUsers),
        );
        return ValueListenableBuilder<int?>(
          valueListenable: _controller.selectedPostNumberNotifier,
          builder: (context, selectedPostNumber, _) {
            return ValueListenableBuilder<int?>(
              valueListenable: _controller.highlightNotifier,
              builder: (context, highlightPostNumber, _) {
                return TopicPostList(
                  detail: detail,
                  scrollController: _controller.scrollController,
                  centerKey: _centerKey,
                  headerKey: _headerKey,
                  hideHeaderTitle: widget.hideInlineHeaderTitle,
                  selectedPostNumber: selectedPostNumber,
                  highlightPostNumber: highlightPostNumber,
                  highlightBoostUsername: widget.highlightBoostUsername,
                  typingUsers: typingUsers,
                  isLoggedIn: isLoggedIn,
                  hasMoreBefore: notifier.hasMoreBefore,
                  hasMoreAfter: notifier.hasMoreAfter,
                  isLoadingPrevious: notifier.isLoadingPrevious,
                  isLoadingMore: notifier.isLoadingMore,
                  isLoadMoreFailed: notifier.isLoadMoreFailed,
                  isLoadPreviousFailed: notifier.isLoadPreviousFailed,
                  onRetryLoadMore: () => notifier.retryLoadMore(),
                  onRetryLoadPrevious: () => notifier.retryLoadPrevious(),
                  centerPostIndex: centerPostIndex,
                  dividerPostIndex: dividerPostIndex,
                  onFirstVisiblePostChanged: _updateStreamIndexForPostNumber,
                  onVisiblePostsChanged: _updateVisiblePosts,
                  onScrollIndexMappingChanged:
                      _controller.updateScrollIndexMapping,
                  onScrollIndexToPostNumberChanged:
                      _controller.updateScrollIndexToPostNumber,
                  onPostSegmentRangesChanged:
                      _controller.updatePostSegmentRanges,
                  onJumpToPost: _scrollToPost,
                  onReply: _handleReply,
                  onEdit: _handleEdit,
                  onShareAsImage: _sharePostAsImage,
                  onRefreshPost: _handleRefreshPost,
                  onVoteChanged: _handleVoteChanged,
                  onSharedIssueChanged: _handleSharedIssueChanged,
                  onNotificationLevelChanged: (level) =>
                      _handleNotificationLevelChanged(notifier, level),
                  onSolutionChanged: _handleSolutionChanged,
                  onQuoteSelection: isLoggedIn ? _handleQuoteSelection : null,
                  onQuoteImage: isLoggedIn ? _handleImageQuote : null,
                  onScrollNotification: _controller.handleScrollNotification,
                  onPointerScroll: _controller.handlePointerScroll,
                  onFillGapBefore: (postId) => notifier.fillGapBefore(postId),
                  onFillGapAfter: (postId) => notifier.fillGapAfter(postId),
                  onExpandHiddenPost: (postId) =>
                      notifier.expandHiddenPost(postId),
                  useReplyDialog: notifier.isTopLevelMode,
                  onShowPostDetail: (post) => showPostRepliesSheet(
                    context: context,
                    post: post,
                    topicId: widget.topicId,
                    topicTitle: detail.title,
                    isPrivateMessageTopic: detail.isPrivateMessage,
                    onJumpToPost: _scrollToPost,
                  ),
                );
              },
            );
          },
        );
      },
    );

    scrollView = DesktopRefreshIndicator(
      refreshNotifier: widget.embeddedMode
          ? detailRefreshNotifier
          : desktopRefreshNotifier,
      onRefresh: _handleRefresh,
      notificationPredicate: (notification) {
        if (!hasFirstPost) return false;
        if (notification.depth != 0) return false;
        return true;
      },
      child: scrollView,
    );

    // 使用 ValueListenableBuilder 隔离定位状态变化，避免整页重建
    // 使用 child 参数避免 scrollView 重建
    return ValueListenableBuilder<bool>(
      valueListenable: _controller.isPositionedNotifier,
      builder: (context, isPositioned, child) {
        return Opacity(opacity: isPositioned ? 1.0 : 0.0, child: child);
      },
      child: scrollView,
    );
  }
}

class _AiAssistantActionIcon extends StatelessWidget {
  const _AiAssistantActionIcon({required this.isGenerating});

  final bool isGenerating;

  @override
  Widget build(BuildContext context) {
    if (!isGenerating) {
      return const Icon(Icons.auto_awesome);
    }

    final color = IconTheme.of(context).color;
    return SizedBox(
      width: 24,
      height: 24,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: color,
            ),
          ),
          Icon(Icons.auto_awesome, size: 13, color: color),
        ],
      ),
    );
  }
}

/// 保持 PageView 子页面存活，防止离屏时 state 被销毁导致滚动位置丢失
class _KeepAlivePage extends StatefulWidget {
  final Widget child;
  const _KeepAlivePage({required this.child});

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
