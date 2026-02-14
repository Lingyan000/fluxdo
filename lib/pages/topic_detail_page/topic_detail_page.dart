import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:share_plus/share_plus.dart';
import '../../utils/link_launcher.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';
import '../../models/draft.dart';
import '../../models/topic.dart';
import '../../utils/responsive.dart';
import '../../utils/share_utils.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/selected_topic_provider.dart';
import '../../providers/discourse_providers.dart';
import '../../providers/message_bus_providers.dart';
import '../../providers/topic_sort_provider.dart';
import '../../providers/pinned_categories_provider.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/screen_track.dart';
import '../../widgets/content/lazy_load_scope.dart';
import '../../widgets/post/post_item_skeleton.dart';
import '../../widgets/post/reply_sheet.dart';
import '../../widgets/topic/topic_progress.dart';
import '../../widgets/topic/topic_notification_button.dart';
import '../../widgets/common/emoji_text.dart';
import '../../widgets/common/error_view.dart';
import '../../widgets/content/discourse_html_content/chunked/chunked_html_content.dart';
import 'controllers/topic_detail_controller.dart';
import 'widgets/topic_detail_overlay.dart';
import 'widgets/topic_post_list.dart';
import 'widgets/topic_detail_header.dart';
import '../../widgets/layout/master_detail_layout.dart';
import '../../widgets/share/share_image_preview.dart';
import '../../widgets/share/export_sheet.dart';
import '../../widgets/search/topic_search_view.dart';
import '../../providers/topic_search_provider.dart';
import '../edit_topic_page.dart';

part 'actions/_app_bar.dart';
part 'actions/_scroll_actions.dart';
part 'actions/_user_actions.dart';
part 'actions/_filter_actions.dart';

/// 话题详情页面
class TopicDetailPage extends ConsumerStatefulWidget {
  final int topicId;
  final String? initialTitle;
  final int? scrollToPostNumber; // 外部控制的跳转位置（如从通知跳转到指定楼层）
  final bool embeddedMode; // 嵌入模式（双栏布局中使用，不显示返回按钮）
  final bool autoSwitchToMasterDetail; // 仅在从首页进入时允许自动切换
  final bool autoOpenReply; // 自动打开回复框（从草稿进入时使用）
  final int? autoReplyToPostNumber; // 自动回复的帖子编号（从草稿进入时使用）

  const TopicDetailPage({
    super.key,
    required this.topicId,
    this.initialTitle,
    this.scrollToPostNumber,
    this.embeddedMode = false,
    this.autoSwitchToMasterDetail = false,
    this.autoOpenReply = false,
    this.autoReplyToPostNumber,
  });

  @override
  ConsumerState<TopicDetailPage> createState() => _TopicDetailPageState();
}

class _TopicDetailPageState extends ConsumerState<TopicDetailPage> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  /// 唯一实例 ID，确保每次打开页面都创建新的 provider 实例
  final String _instanceId = const Uuid().v4();

  /// Provider 参数（简化重复创建）
  TopicDetailParams get _params => TopicDetailParams(
    widget.topicId,
    postNumber: _controller.currentPostNumber,
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
  final ValueNotifier<bool> _isScrolledUnderNotifier = ValueNotifier<bool>(false);
  /// 展开头部是否可见（用 ValueNotifier 隔离 UI 更新）
  final ValueNotifier<bool> _isOverlayVisibleNotifier = ValueNotifier<bool>(false);
  bool _isSwitchingMode = false;  // 切换热门回复模式
  // 搜索相关
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  late final AnimationController _expandController;
  late final Animation<Offset> _animation;
  Set<int> _lastReadPostNumbers = {};
  bool? _lastCanShowDetailPane;
  bool _isAutoSwitching = false;
  bool _autoOpenReplyHandled = false; // 是否已处理自动打开回复框
  Orientation? _lastOrientation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _expandController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    
    _animation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _expandController,
      curve: Curves.easeOutCubic,
    ))..addStatusListener((status) {
      if (status == AnimationStatus.forward) {
        _isOverlayVisibleNotifier.value = true;
      } else if (status == AnimationStatus.dismissed) {
        _isOverlayVisibleNotifier.value = false;
      }
    });

    final trackEnabled = ref.read(currentUserProvider).value != null;

    _screenTrack = ScreenTrack(
      DiscourseService(),
      onTimingsSent: (topicId, postNumbers, highestSeen) {
        debugPrint('[TopicDetail] onTimingsSent callback triggered: topicId=$topicId, highestSeen=$highestSeen');
        // 遍历当前排序 + 所有分类 tab，更新所有活跃的 provider 实例
        final currentSort = ref.read(topicSortProvider);
        final pinnedIds = ref.read(pinnedCategoriesProvider);
        final categoryIds = [null, ...pinnedIds];
        for (final categoryId in categoryIds) {
          ref.read(topicListProvider((currentSort, categoryId)).notifier).updateSeen(topicId, highestSeen);
        }
        // unread 列表也需要更新
        if (currentSort != TopicListFilter.unread) {
          for (final categoryId in categoryIds) {
            ref.read(topicListProvider((TopicListFilter.unread, categoryId)).notifier).updateSeen(topicId, highestSeen);
          }
        }
        // 更新会话已读状态，触发 PostItem 消除未读圆点
        ref.read(topicSessionProvider(topicId).notifier).markAsRead(postNumbers);
      },
    );

    if (trackEnabled) {
      _screenTrack.start(widget.topicId);
    }

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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _expandController.dispose();
    _showTitleNotifier.dispose();
    _isScrolledUnderNotifier.dispose();
    _isOverlayVisibleNotifier.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _controller.scrollController.removeListener(_onScroll);
    _screenTrack.stop();
    _controller.dispose();
    // 清理搜索状态，防止重新进入时仍处于搜索模式
    ref.read(topicSearchProvider(widget.topicId).notifier).exitSearchMode();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final hasFocus = state == AppLifecycleState.resumed;
    _screenTrack.setHasFocus(hasFocus);
  }

  @override
  void didChangeMetrics() {
    // 屏幕旋转/折叠屏展开时，重置滚动位置避免 UI 错位
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final orientation = MediaQuery.orientationOf(context);
      if (_lastOrientation != null && _lastOrientation != orientation) {
        if (_controller.scrollController.hasClients) {
          _controller.scrollController.jumpTo(0);
        }
      }
      _lastOrientation = orientation;
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
      if (_hasFirstPost) {
        _showTitleNotifier.value = true;
      }
      _isScrolledUnderNotifier.value = true;
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

    final previous = _lastCanShowDetailPane;
    _lastCanShowDetailPane = canShowDetailPane;

    if (_isAutoSwitching) return;
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

      final currentPostNumber = _controller.currentPostNumber ?? widget.scrollToPostNumber;
      ref.read(selectedTopicProvider.notifier).select(
        topicId: widget.topicId,
        initialTitle: detail?.title ?? widget.initialTitle,
        scrollToPostNumber: currentPostNumber,
      );
      navigator.pop();
    });
  }

  /// 在大屏上为内容添加宽度约束
  Widget _wrapWithConstraint(Widget child) {
    if (Responsive.isMobile(context)) return child;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Breakpoints.maxContentWidth),
        child: child,
      ),
    );
  }

  void _showTimelineSheet(TopicDetail detail) {
    showTopicTimelineSheet(
      context: context,
      currentPostNumber: _controller.postNumberNotifier.value,
      totalPostCount: detail.postsCount,
      onJumpToPostNumber: _scrollToPost,
      title: detail.title,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLoggedIn = ref.watch(currentUserProvider).value != null;
    final canShowDetailPane = MasterDetailLayout.canShowBothPanesFor(context);

    ref.listen<AsyncValue<void>>(authStateProvider, (_, _) {
      if (!mounted) return;
      final stillLoggedIn = ref.read(currentUserProvider).value != null;
      if (!stillLoggedIn && _controller.trackEnabled) {
        _controller.trackEnabled = false;
      }
    });

    final params = _params;
    final detailAsync = ref.watch(topicDetailProvider(params));
    final detail = detailAsync.value;
    final notifier = ref.read(topicDetailProvider(params).notifier);

    _maybeSwitchToMasterDetail(canShowDetailPane, detail);

    // 监听 MessageBus 事件
    ref.listen(topicChannelProvider(widget.topicId), (previous, next) {
      // 1. reload_topic（话题状态变更：关闭/打开/固定等）
      if (next.reloadRequested && !(previous?.reloadRequested ?? false)) {
        ref.read(topicChannelProvider(widget.topicId).notifier).clearReloadRequest();
        _handleReloadTopic(notifier, next.refreshStreamRequested);
        return;
      }

      // 2. notification_level_change（通知级别变更）
      if (next.notificationLevelChange != null && previous?.notificationLevelChange != next.notificationLevelChange) {
        final level = TopicNotificationLevel.fromValue(next.notificationLevelChange!);
        ref.read(topicChannelProvider(widget.topicId).notifier).clearNotificationLevelChange();
        notifier.updateNotificationLevelLocally(level);
        return;
      }

      // 3. stats 更新
      if (next.statsUpdate != null && previous?.statsUpdate != next.statsUpdate) {
        notifier.applyStatsUpdate(next.statsUpdate!);
        ref.read(topicChannelProvider(widget.topicId).notifier).clearStatsUpdate();
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
      final posts = next.value?.postStream.posts;
      if (posts != null && posts.isNotEmpty) {
        final htmlList = posts.map((p) => p.cooked).toList();
        ChunkedHtmlContent.preloadAll(htmlList);

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
                replyToPost = posts.where(
                  (p) => p.postNumber == widget.autoReplyToPostNumber,
                ).firstOrNull;
              }
              _handleReply(replyToPost);
            }
          });
        }
      }
    });

    final searchState = ref.watch(topicSearchProvider(widget.topicId));
    final isSearchMode = searchState.isSearchMode;

    return LazyLoadScope(
      child: PopScope(
        canPop: !isSearchMode,
        onPopInvokedWithResult: (bool didPop, dynamic result) {
          if (!didPop) {
            // 搜索模式下按返回键，退出搜索而不是退出页面
            _searchController.clear();
            ref.read(topicSearchProvider(widget.topicId).notifier).exitSearchMode();
          }
        },
        child: Scaffold(
          appBar: _buildAppBar(
            theme: theme,
            detail: detail,
            notifier: notifier,
          ),
          body: _buildBody(context, detailAsync, detail, notifier, isLoggedIn),
        ),
      ),
    );
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
      final showHeaderSkeleton = widget.scrollToPostNumber == null || widget.scrollToPostNumber == 0;
      return _wrapWithConstraint(PostListSkeleton(withHeader: showHeaderSkeleton));
    }
    
    if (detailAsync.isLoading && detail == null && !detailAsync.hasError) {
      final showHeaderSkeleton = widget.scrollToPostNumber == null || widget.scrollToPostNumber == 0;
      return _wrapWithConstraint(PostListSkeleton(withHeader: showHeaderSkeleton));
    }

    // 跳转中：等待包含目标帖子的新数据 - 显示骨架屏
    final jumpTarget = _controller.jumpTargetPostNumber;
    if (jumpTarget != null && detail != null) {
      final posts = detail.postStream.posts;
      // 检查目标帖子是否在当前加载的范围内
      final hasTarget = posts.isNotEmpty &&
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
          Offstage(
            offstage: isSearchMode,
            child: content,
          ),

          // 搜索视图
          if (isSearchMode)
            TopicSearchView(
              topicId: widget.topicId,
              onJumpToPost: (postNumber) {
                // 退出搜索模式并跳转到指定帖子
                ref.read(topicSearchProvider(widget.topicId).notifier).exitSearchMode();
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
                  valueListenable: _controller.postNumberNotifier,
                  builder: (context, currentPostNumber, _) {
                    return TopicDetailOverlay(
                      showBottomBar: showBottomBar,
                      isLoggedIn: isLoggedIn,
                      currentStreamIndex: currentPostNumber,
                      totalCount: detail.postsCount,
                      detail: detail,
                      onScrollToTop: _scrollToTop,
                      onShare: _shareTopic,
                      onShareAsImage: _shareAsImage,
                      onExport: _showExportSheet,
                      onOpenInBrowser: _openInBrowser,
                      onReply: () => _handleReply(null),
                      onProgressTap: () => _showTimelineSheet(detail),
                      isSummaryMode: notifier.isSummaryMode,
                      isAuthorOnlyMode: notifier.isAuthorOnlyMode,
                      isLoading: _isSwitchingMode,
                      onShowTopReplies: _handleShowTopReplies,
                      onShowAuthorOnly: _handleShowAuthorOnly,
                      onCancelFilter: _handleCancelFilter,
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
                            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
                            clipBehavior: Clip.antiAlias,
                            child: SingleChildScrollView(
                              child: TopicDetailHeader(
                                detail: detail,
                                headerKey: null,
                                onVoteChanged: _handleVoteChanged,
                                onNotificationLevelChanged: (level) => _handleNotificationLevelChanged(notifier, level),
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
      if (_controller.currentPostNumber == null || _controller.currentPostNumber == 0) {
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

    // 使用 Consumer + select 隔离 typingUsers 状态变化，避免整页重建
    Widget scrollView = Consumer(
      builder: (context, ref, _) {
        final typingUsers = ref.watch(
          topicChannelProvider(widget.topicId).select((s) => s.typingUsers),
        );
        return ValueListenableBuilder<int?>(
          valueListenable: _controller.highlightNotifier,
          builder: (context, highlightPostNumber, _) {
            return TopicPostList(
              detail: detail,
              scrollController: _controller.scrollController,
              centerKey: _centerKey,
              headerKey: _headerKey,
              highlightPostNumber: highlightPostNumber,
              typingUsers: typingUsers,
              isLoggedIn: isLoggedIn,
              hasMoreBefore: notifier.hasMoreBefore,
              hasMoreAfter: notifier.hasMoreAfter,
              isLoadingPrevious: notifier.isLoadingPrevious,
              isLoadingMore: notifier.isLoadingMore,
              centerPostIndex: centerPostIndex,
              dividerPostIndex: dividerPostIndex,
              onFirstVisiblePostChanged: _updateStreamIndexForPostNumber,
              onVisiblePostsChanged: _updateVisiblePosts,
              onJumpToPost: _scrollToPost,
              onReply: _handleReply,
              onEdit: _handleEdit,
              onShareAsImage: _sharePostAsImage,
              onRefreshPost: _handleRefreshPost,
              onVoteChanged: _handleVoteChanged,
              onNotificationLevelChanged: (level) => _handleNotificationLevelChanged(notifier, level),
              onSolutionChanged: _handleSolutionChanged,
              onScrollNotification: _controller.handleScrollNotification,
            );
          },
        );
      },
    );

    scrollView = RefreshIndicator(
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
        return Opacity(
          opacity: isPositioned ? 1.0 : 0.0,
          child: child,
        );
      },
      child: scrollView,
    );

  }
}
