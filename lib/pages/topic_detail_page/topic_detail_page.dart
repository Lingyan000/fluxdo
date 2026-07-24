import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../services/app_error_handler.dart';
import '../../services/notion/notion_bookmark_auto_sync.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderSliver, RenderViewport;
import 'package:flutter/scheduler.dart' show SchedulerBinding, Priority;
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:share_plus/share_plus.dart';
import '../../l10n/s.dart';
import '../../utils/frame_jank_monitor.dart';
import '../../utils/html_text_mapper.dart';
import '../../utils/html_to_markdown.dart';
import '../../utils/code_selection_context.dart';
import '../../utils/link_launcher.dart';
import '../../utils/quote_builder.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show SelectionCoordinator;
import 'package:uuid/uuid.dart';
import 'dart:async';
import 'dart:math' as math;
import '../../models/draft.dart';
import '../../models/topic.dart';
import '../../models/pending_post.dart';
import '../../utils/blocked_user_filter.dart';
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
import '../../utils/hero_visibility_controller.dart';
import '../../widgets/content/lazy_load_scope.dart';
import '../../widgets/post/post_item_skeleton.dart';
import '../../widgets/post/post_item/widgets/post_flag_sheet.dart';
import '../../widgets/post/post_replies_sheet.dart';
import '../../widgets/post/post_revision/revision_modal.dart';
import '../../widgets/post/reply_sheet.dart';
import '../../widgets/topic/topic_progress.dart';
import '../../widgets/topic/topic_notification_button.dart';
import 'package:common_ui/common_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';
import '../../widgets/common/emoji_text.dart';
import '../../widgets/common/error_view.dart';
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
import '../../widgets/common/app_bottom_sheet.dart';
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

  /// 视口 anchor（center 零点在视口内的位置，0 = 顶部）。
  /// 目标帖下方内容不足一屏时由 _updateBottomAnchorIfNeeded 按真实几何
  /// 抬高，使 offset 0 = 底边贴齐，底部空白被排除在滚动范围之外
  double _viewportAnchor = 0.0;
  bool _hasFirstPost = false;
  bool _isCheckTitleVisibilityScheduled = false;
  bool _isRefreshing = false;

  /// 本地屏蔽名单过滤缓存：provider 状态与名单实例都未变时复用同一份
  /// 过滤结果，保证同一帧内多处读取拿到 identical 的 posts 列表
  TopicDetail? _blockedFilterInput;
  Set<String>? _blockedFilterBlocked;
  TopicDetail? _blockedFilterOutput;

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

  /// 滚动中推迟的 msgbus 帖子更新(滚停后回放,防滚动路径上方高度跳变)
  final List<PostUpdate> _deferredPostUpdates = [];
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

  /// 进入转场是否已完成。转场期间物化真实帖子列表(缓存命中时首屏多个
  /// PostItem 的构建 + 中文排版)会把大 build 帧砸在动画中间 —— 换什么
  /// 转场曲线都掉帧。未完成前一律先渲染骨架(与首次加载视觉一致),
  /// completed 后下一帧再物化,把成本挪出动画窗口。无转场进入(动画
  /// 初始即 completed)时保持 true,零影响。
  bool _routeTransitionDone = true;
  bool _isParentActive = true;
  bool _isScreenTrackRunning = false;

  /// 初始定位期间被抑制的 eyeline 上报楼层（定位完成后回放）
  int? _suppressedEyelinePostNumber;

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
        // 更新会话已读状态，触发 PostItem 消除未读圆点
        ref
            .read(topicSessionProvider(topicId).notifier)
            .markAsRead(postNumbers);
        // 遍历所有分类 tab 更新列表页 lastReadPostNumber。会重建栈底的
        // 列表页,推迟到 idle 执行,避免上报回调恰好落在滚动帧内造成掉帧
        SchedulerBinding.instance.scheduleTask(() {
          if (!mounted) return;
          final pinnedIds = ref.read(pinnedCategoriesProvider);
          final categoryIds = [null, ...pinnedIds];
          for (final categoryId in categoryIds) {
            ref
                .read(topicListProvider(categoryId).notifier)
                .updateSeen(topicId, highestSeen);
          }
        }, Priority.idle);
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
    // 滚动停止 → 回放滚动期间推迟的 msgbus 帖子更新
    // (isScrollingNotifier 在 position attach 后才有,帧后挂)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _attachScrollIdleFlush();
    });
    _pageController = PageController(initialPage: 0);

    // 桌面端：注册 J/K 帖子导航 + AI 面板切换
    if (PlatformUtils.isDesktop) {
      toggleAiPanelNotifier.addListener(_onToggleAiPanel);
      _schedulePostShortcutRegistration();
    }

    // 注册"按 heroTag 段级滚动"能力:图片查看器翻页时把源缩略图所在
    // 楼层滚进可视区,保证关闭时 Hero 能飞回原位(缩略图被列表回收时
    // 的粗定位,精确化由 HeroVisibilityController 二次 ensureVisible)
    _heroScrollResolver = _scrollToHeroTagSource;
    HeroVisibilityController.instance.sourceScrollResolver =
        _heroScrollResolver;
  }

  /// 本实例注册的 resolver(dispose 时按 identity 注销,避免叠栈的
  /// 详情页互相覆盖后误清)
  Future<void> Function(String heroTag)? _heroScrollResolver;

  /// 解析 heroTag(`post_<postId>_img_<idx>`)→ 滚动到对应楼层。
  Future<void> _scrollToHeroTagSource(String heroTag) async {
    if (!mounted) return;
    final match = RegExp(r'^post_(\d+)_img_\d+$').firstMatch(heroTag);
    if (match == null) return;
    final postId = int.tryParse(match.group(1)!);
    if (postId == null) return;

    final detail = ref.read(topicDetailProvider(_params)).value;
    final posts = detail?.postStream.posts;
    if (posts == null) return;
    final post = posts.where((p) => p.id == postId).firstOrNull;
    if (post == null) return;

    await _controller.scrollToPost(post.postNumber, posts);
    // 等两帧:让目标段构建、其中的 HeroImage 完成注册,
    // 调用方随后二次 ensureVisible 精确到图片
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
  }

  bool _isAiSheetOpen = false;

  /// 已挂 idle-flush 监听的 ScrollPosition(attach/detach 时换绑)
  ScrollPosition? _idleFlushPosition;

  void _attachScrollIdleFlush() {
    final sc = _controller.scrollController;
    if (!sc.hasClients) {
      // position 尚未 attach(骨架屏期),下一帧再试
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _attachScrollIdleFlush();
      });
      return;
    }
    final position = sc.position;
    if (identical(_idleFlushPosition, position)) return;
    _idleFlushPosition?.isScrollingNotifier.removeListener(_onScrollIdle);
    _idleFlushPosition = position;
    position.isScrollingNotifier.addListener(_onScrollIdle);
  }

  void _onScrollIdle() {
    if (!mounted) return;
    if (_idleFlushPosition?.isScrollingNotifier.value ?? true) return;
    if (_deferredPostUpdates.isEmpty) return;
    // 推迟一帧回放:isScrollingNotifier 翻 false 发生在惯性最后一个 tick
    // 的同一帧,若同帧内直接回放,布局时 pixels 相对上一帧仍在变,
    // AnchorGuardSliver 的"偏移与基线一致"守卫会判为不可比,回放引发的
    // 高度位移就漏掉锚定修正。推一帧让更新落在纯空闲帧,位移被全额补偿。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 帧间隙内可能又开始滚动:保持冻结,等下一次滚停
      if (_idleFlushPosition?.isScrollingNotifier.value ?? true) return;
      if (_deferredPostUpdates.isEmpty) return;
      final notifier = ref.read(topicDetailProvider(_params).notifier);
      _flushDeferredPostUpdates(notifier);
    });
  }

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
    final enterAnim = route.animation;
    if (enterAnim != null && !enterAnim.isCompleted) {
      _routeTransitionDone = false;
      enterAnim.addStatusListener(_onRouteEnterAnimStatus);
    }
    _schedulePostShortcutRegistration();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncScreenTrackState(reason: 'route_subscribed');
    });
  }

  void _onRouteEnterAnimStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _route?.animation?.removeStatusListener(_onRouteEnterAnimStatus);
    if (!mounted) return;
    setState(() => _routeTransitionDone = true);
  }

  @override
  void dispose() {
    _idleFlushPosition?.isScrollingNotifier.removeListener(_onScrollIdle);
    _idleFlushPosition = null;
    // 按 identity 注销:叠栈的详情页可能已覆盖注册,只清自己那份
    if (identical(
      HeroVisibilityController.instance.sourceScrollResolver,
      _heroScrollResolver,
    )) {
      HeroVisibilityController.instance.sourceScrollResolver = null;
    }
    _route?.animation?.removeStatusListener(_onRouteEnterAnimStatus);
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
    // 叠栈的详情页 pop 后,恢复本页的 heroTag 滚动能力
    HeroVisibilityController.instance.sourceScrollResolver =
        _heroScrollResolver;
  }

  @override
  void didPushNext() {
    _setRouteVisible(false, 'did_push_next');
    // 兜底清自研选区(工具栏/托柄是顶层 OverlayEntry,新 push 的页面路由
    // 压不住它们)。常规弹层靠选区层失焦监听自清,这里防御非焦点路径。
    SelectionCoordinator.instance.clearActive();
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

  void _maybeSwitchToMasterDetail(bool canShowDetailPane) {
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
        _switchToMasterDetail();
      }
      return;
    }
    if (previous == canShowDetailPane) return;
    if (!previous && canShowDetailPane) {
      _switchToMasterDetail();
    }
  }

  void _switchToMasterDetail() {
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
            // 切换瞬间现读即可,不需要 build 期持有 detail(顶层已不再
            // watch 完整 detail,见 build 内注释)
            initialTitle:
                ref.read(topicDetailProvider(_params)).value?.title ??
                widget.initialTitle,
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
            icon: const Icon(Symbols.close_rounded),
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
                      Symbols.mail_rounded,
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
                      Symbols.lock_rounded,
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
                    child: Icon(Symbols.check_box_rounded, size: 18, color: Colors.green),
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
                    Symbols.mail_rounded,
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
                    Symbols.lock_rounded,
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
                  child: Icon(Symbols.check_box_rounded, size: 16, color: Colors.green),
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
      icon: const Icon(Symbols.search_rounded),
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
    final hasFilter =
        notifier.isSummaryMode ||
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
        hasReminder:
            traceTarget?.initialReminderAt != null ||
            detail.bookmarkReminderAt != null,
        selectedAction: 'bookmark',
      );
      unawaited(
        _handleBookmark(
          notifier,
          traceId: traceId,
          source: 'topic_detail_topic_menu',
        ),
      );
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
      icon: const Icon(Symbols.more_vert_rounded),
      tooltip: context.l10n.topicDetail_moreOptions,
      headerActions: [
        MenuQuickAction(
          icon: Symbols.bookmark_rounded,
          tooltip: hasEditableBookmark
              ? context.l10n.topicDetail_editBookmark
              : context.l10n.common_addBookmark,
          active: hasEditableBookmark,
          onTap: doBookmark,
        ),
        MenuQuickAction(
          icon: Symbols.layers_rounded,
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
                  onTap: () => _handleNotificationLevelChanged(notifier, level),
                ),
            ],
          ),
        ),
        if (!detail.isPrivateMessage)
          MenuQuickAction(
            icon: Symbols.link_rounded,
            tooltip: context.l10n.topicDetail_shareLink,
            onTap: _shareTopic,
          ),
        MenuQuickAction(
          icon: Symbols.filter_list_rounded,
          tooltip: context.l10n.topicDetail_filter,
          active: hasFilter,
          submenu: MenuQuickActionSubmenu(
            icon: Symbols.filter_list_rounded,
            label: context.l10n.topicDetail_filter,
            iconColor: hasFilter ? Theme.of(context).colorScheme.primary : null,
            children: [
              if (detail.hasSummary)
                MenuQuickActionSubmenuChild(
                  icon: notifier.isSummaryMode
                      ? Symbols.local_fire_department_rounded
                      : Symbols.local_fire_department_rounded,
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
                    ? Symbols.person_rounded
                    : Symbols.person_rounded,
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
                    ? Symbols.account_tree_rounded
                    : Symbols.account_tree_rounded,
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
                icon: Symbols.forum_rounded,
                label: context.l10n.nested_title,
                selected: _isNestedView,
                onTap: _toggleNestedView,
              ),
              if (hasFilter)
                MenuQuickActionSubmenuChild(
                  icon: Symbols.filter_list_off_rounded,
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
          final levelValue = int.tryParse(
            value.substring(subscribePrefix.length),
          );
          if (levelValue != null) {
            final level = TopicNotificationLevel.values.firstWhere(
              (e) => e.value == levelValue,
              orElse: () => detail.notificationLevel,
            );
            _handleNotificationLevelChanged(notifier, level);
          }
          return;
        }
        final bookmarkTraceTarget = value == 'bookmark'
            ? _bookmarkEditTarget(detail)
            : null;
        final bookmarkTraceId = value == 'bookmark'
            ? createBookmarkEditTraceId()
            : null;
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
                  Symbols.edit_rounded,
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
                  Symbols.image_rounded,
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
                Symbols.download_rounded,
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
                Symbols.language_rounded,
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
                Symbols.auto_stories_rounded,
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

  /// 供缓存的 [TopicDetailOverlay] 实例回调:现取最新 detail,
  /// 避免闭包捕获构建时的旧 detail(实例缓存后闭包生命周期变长)。
  void _showTimelineSheetForCurrent() {
    final detail = ref.read(topicDetailProvider(_params)).value;
    if (detail != null) _showTimelineSheet(detail);
  }

  void _handleProgressGestureForCurrent(ProgressGestureAction action) {
    final detail = ref.read(topicDetailProvider(_params)).value;
    if (detail == null) return;
    final notifier = ref.read(topicDetailProvider(_params).notifier);
    _handleProgressGesture(action, detail, notifier);
  }

  /// [TopicDetailOverlay] 的实例缓存(输入签名比对):见调用处注释。
  ({Object signature, Widget widget})? _overlayCache;

  Widget _buildOverlayCached(
    TopicDetail detail,
    TopicDetailNotifier notifier,
    bool isLoggedIn,
  ) {
    // Overlay 及其子树实际消费的全部低频输入;detail 对象本身不入签名
    // (它每次更新都是新实例),只取 Overlay 用到的字段。
    final signature = (
      isLoggedIn: isLoggedIn,
      totalCount: detail.postStream.stream.length,
      hasSummary: detail.hasSummary,
      isPrivateMessage: detail.isPrivateMessage,
      isSummaryMode: notifier.isSummaryMode,
      isAuthorOnlyMode: notifier.isAuthorOnlyMode,
      isTopLevelMode: notifier.isTopLevelMode,
      isNestedMode: _isNestedView,
      isLoading: _isSwitchingMode,
    );
    final cached = _overlayCache;
    if (cached != null && cached.signature == signature) {
      return cached.widget;
    }
    final overlay = TopicDetailOverlay(
      showBottomBarListenable: _controller.showBottomBarNotifier,
      isLoggedIn: isLoggedIn,
      streamIndexListenable: _controller.streamIndexNotifier,
      totalCount: detail.postStream.stream.length,
      detail: detail,
      onScrollToTop: _scrollToTop,
      onShare: _shareTopic,
      onShareAsImage: _shareAsImage,
      onExport: _showExportSheet,
      onOpenInBrowser: _openInBrowser,
      onReply: () => _handleReply(null),
      onProgressTap: _showTimelineSheetForCurrent,
      onProgressGesture: _handleProgressGestureForCurrent,
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
    _overlayCache = (signature: signature, widget: overlay);
    return overlay;
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
      case ProgressGestureAction.goBack:
        if (mounted) {
          unawaited(Navigator.of(context).maybePop());
        }
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
    // 整页 rebuild 解耦:顶层不再 watch 完整 detail —— 生产 STALL-PROF
    // 定案,每次翻页落地/msgbus 更新都从 Scaffold 到浮层全链重建
    // (~60ms UI 阻塞,STALL 主力)。完整 detail 的 watch 下沉到
    // AppBar/body/AI 页各自的 Consumer 边界,落地帧只重建这三块,
    // 页面骨架(LazyLoadScope/PopScope/PageView/Scaffold)整体短路。
    // 顶层只保留"是否已有数据"布尔信号(null↔非null 边界才重建)。
    final hasDetail = ref.watch(
      topicDetailProvider(params).select((a) => a.value != null),
    );
    final notifier = ref.read(topicDetailProvider(params).notifier);

    // 会话已读集合变化(timings 上报成功后 markAsRead)只需推给 controller
    // 供 screenTrack 计算 readOnscreen,不触发 rebuild —— 与
    // _buildPostListContent 里的 ref.read 配对(那里承担 detail 变化时的重算)。
    ref.listen(topicSessionProvider(widget.topicId), (_, next) {
      final currentDetail = ref.read(topicDetailProvider(params)).value;
      if (currentDetail == null) return;
      final readPostNumbers = <int>{
        for (final post in currentDetail.postStream.posts)
          if (post.read) post.postNumber,
        ...next.readPostNumbers,
      };
      _updateReadPostNumbers(readPostNumbers);
    });

    _maybeSwitchToMasterDetail(canShowDetailPane);

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

      // 4. 帖子级别更新（created/revised/deleted/liked 等）:
      // generation 变化 = 新一批(postUpdates 即该批全量,由频道层在
      // 微任务边界攒批)。批入口统一做去重与积压坍缩。
      if (next.postUpdatesGeneration !=
          (previous?.postUpdatesGeneration ?? 0)) {
        _handlePostUpdateBatch(notifier, next.postUpdates);
      }
    });

    // 预解析帖子 HTML
    ref.listen(topicDetailProvider(params), (previous, next) {
      if (!context.mounted) return;
      final detail = next.value;
      // 记录话题标题到会话状态，供用户卡片「基于话题的私信」预填标题
      if (detail != null) {
        ref
            .read(topicSessionProvider(widget.topicId).notifier)
            .setTopicTitle(detail.title);
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
      // 与 _buildPostListContent 一致，用过滤后列表判断 1 楼是否存在
      final posts = detail == null
          ? null
          : _filteredDetail(detail).postStream.posts;
      if (posts != null && posts.isNotEmpty) {
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
    if (useSwipeEntry && hasAiModel && !_aiGuideChecked && hasDetail) {
      _aiGuideChecked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          final prefs = ref.read(sharedPreferencesProvider);
          AiChatGuide.checkAndShow(prefs);
        }
      });
    }

    // AppBar 两个分支高度恒为 kToolbarHeight(搜索 AppBar 无 bottom,
    // 正常分支自身就是 PreferredSize(kToolbarHeight)),外层声明恒定
    // 高度后,内部随 detail 重建不影响 Scaffold 布局
    final topicScaffold = Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: Consumer(
          builder: (context, ref, _) {
            final detail = ref.watch(topicDetailProvider(params)).value;
            return _buildAppBar(
              theme: theme,
              detail: detail,
              notifier: notifier,
            );
          },
        ),
      ),
      body: Consumer(
        builder: (context, ref, _) {
          final detailAsync = ref.watch(topicDetailProvider(params));
          return _buildBody(
            context,
            detailAsync,
            detailAsync.value,
            notifier,
            isLoggedIn,
          );
        },
      ),
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
                  child: Consumer(
                    builder: (context, ref, _) {
                      final detail =
                          ref.watch(topicDetailProvider(params)).value;
                      return AiChatPage(
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
                                  isPrivateMessageTopic:
                                      detail.isPrivateMessage,
                                  isPmWithNonHumanUser:
                                      detail.pmWithNonHumanUser,
                                );
                              },
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
            isPmWithNonHumanUser: detail.pmWithNonHumanUser,
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

    // 进入转场未完成:先骨架(缓存命中时首帧物化真实列表会把大 build 帧
    // 砸进转场动画,见 _routeTransitionDone),completed 后下一帧再物化。
    if (!_routeTransitionDone) {
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
        // 滚动中高频变化的状态(底栏显隐、楼层号)以 ValueListenable 传入
        // 并在 Overlay 内部细粒度下沉;此外整个 Overlay 实例按输入签名
        // 缓存 —— 帖子信息更新(message bus / 分页)触发的整页 rebuild
        // 中,Overlay 消费的字段一般没变,直接复用实例整棵短路
        // (实测全量重建一次 4.5~8ms)。
        if (detail != null && !isSearchMode)
          _buildOverlayCached(detail, notifier, isLoggedIn),

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

  /// 对 detail 应用本地屏蔽名单（带身份缓存）。
  ///
  /// build 与各 action（跳楼、翻页判断等）都要基于同一份过滤后列表做
  /// postIndex 数学，riverpod 状态实例与名单实例都未变时直接复用上次
  /// 结果，避免每次 read 都重新过滤。
  TopicDetail _filteredDetail(TopicDetail detail) {
    final blocked = ref.read(preferencesProvider).normalizedBlockedUsernames;
    if (identical(_blockedFilterInput, detail) &&
        identical(_blockedFilterBlocked, blocked)) {
      return _blockedFilterOutput!;
    }
    final filtered = BlockedUserFilter.filterTopicDetail(detail, blocked);
    _blockedFilterInput = detail;
    _blockedFilterBlocked = blocked;
    _blockedFilterOutput = filtered;
    return filtered;
  }

  Widget _buildPostListContent(
    BuildContext context,
    TopicDetail detail,
    TopicDetailNotifier notifier,
    bool isLoggedIn,
  ) {
    // 本地屏蔽过滤统一在此出口完成：页面内所有 postIndex（centerPostIndex/
    // dividerPostIndex/滚动映射）都基于同一份过滤后列表，语义天然一致。
    // watch 保证名单变化时整页重建。
    final blockedUsernames = ref.watch(
      preferencesProvider.select((p) => p.normalizedBlockedUsernames),
    );
    detail = _filteredDetail(detail);
    final posts = detail.postStream.posts;
    final hasFirstPost = posts.isNotEmpty && posts.first.postNumber == 1;
    // read 而非 watch：sessionState 只用于合成 readPostNumbers 推给 controller,
    // 不驱动任何 UI(未读圆点由 PostItem 内部细粒度 Consumer 自行监听)。
    // watch 会让每次 timings 上报成功(markAsRead)都整页 rebuild;
    // session 变化时的推送由 build() 里的 ref.listen 承担。
    final sessionState = ref.read(topicSessionProvider(widget.topicId));

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

    // 初始定位：center 直接锚在目标帖，首帧布局即 offset 0 = 目标顶对齐，
    // 无爬行、无估算。收尾（贴底 anchor + markPositioned）在帧后完成。
    // _viewportAnchor 不在此处重置：残留值由 _finalizeInitialPosition
    // 按真实几何重新评估（避免刷新场景闪一帧顶对齐）。
    if (!_controller.hasInitialScrolled && posts.isNotEmpty) {
      final target = _resolveInitialTarget(posts, dividerPostIndex);
      _controller.markInitialScrolled(
        target != null
            ? posts[target.index].postNumber
            : posts.first.postNumber,
      );
      if (target == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_controller.isPositioned) {
            _controller.markPositioned();
          }
        });
      } else {
        // 定位前先按目标楼层预置进度条，避免数字从低楼层爬升
        _primeStreamIndexForInitialTarget(detail, posts, dividerPostIndex);
        _finalizeInitialPosition(
          highlightPostNumber: target.shouldHighlight
              ? posts[target.index].postNumber
              : null,
        );
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
          blockedUsernames: blockedUsernames,
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

    // typingUsers 的监听已下沉到 TopicPostList 内部的打字指示器 sliver，
    // presence 消息不再触发整个列表重建
    Widget scrollView = ValueListenableBuilder<int?>(
      valueListenable: _controller.selectedPostNumberNotifier,
      builder: (context, selectedPostNumber, _) {
        return ValueListenableBuilder<int?>(
          valueListenable: _controller.highlightNotifier,
          builder: (context, highlightPostNumber, _) {
            return TopicPostList(
              detail: detail,
              scrollController: _controller.scrollController,
              centerKey: _centerKey,
              viewportAnchor: _viewportAnchor,
              headerKey: _headerKey,
              hideHeaderTitle: widget.hideInlineHeaderTitle,
              selectedPostNumber: selectedPostNumber,
              highlightPostNumber: highlightPostNumber,
              highlightBoostUsername: widget.highlightBoostUsername,
              isLoggedIn: isLoggedIn,
              hasMoreBefore: notifier.hasMoreBefore,
              hasMoreAfter: notifier.hasMoreAfter,
              loadingPreviousListenable: notifier.loadingPreviousListenable,
              loadingMoreListenable: notifier.loadingMoreListenable,
              loadMoreFailedListenable: notifier.loadMoreFailedListenable,
              loadPreviousFailedListenable:
                  notifier.loadPreviousFailedListenable,
              onRetryLoadMore: () => notifier.retryLoadMore(),
              onRetryLoadPrevious: () => notifier.retryLoadPrevious(),
              centerPostIndex: centerPostIndex,
              dividerPostIndex: dividerPostIndex,
              onFirstVisiblePostChanged: _updateStreamIndexForPostNumber,
              onVisiblePostsChanged: _updateVisiblePosts,
              onScrollIndexMappingChanged: _controller.updateScrollIndexMapping,
              onScrollIndexToPostNumberChanged:
                  _controller.updateScrollIndexToPostNumber,
              onPostSegmentRangesChanged: _controller.updatePostSegmentRanges,
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
              onExpandHiddenPost: (postId) => notifier.expandHiddenPost(postId),
              useReplyDialog: notifier.isTopLevelMode,
              onShowPostDetail: (post) => showPostRepliesSheet(
                context: context,
                post: post,
                topicId: widget.topicId,
                topicTitle: detail.title,
                isPrivateMessageTopic: detail.isPrivateMessage,
                isPmWithNonHumanUser: detail.pmWithNonHumanUser,
                onJumpToPost: _scrollToPost,
              ),
              onWithdrawPendingPost: isLoggedIn ? _handleWithdrawPending : null,
              onWithdrawAndEditPendingPost:
                  isLoggedIn ? _handleWithdrawAndEditPending : null,
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
      return const Icon(Symbols.auto_awesome_rounded);
    }

    final color = IconTheme.of(context).color;
    return SizedBox(
      width: 24,
      height: 24,
      child: Stack(
        alignment: Alignment.center,
        children: [
          LoadingSpinner(size: 22, color: color),
          Icon(Symbols.auto_awesome_rounded, size: 13, color: color),
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
