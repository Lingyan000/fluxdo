import 'dart:io';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../l10n/s.dart';
import '../models/search_filter.dart';
import '../models/category.dart';
import '../navigation/nav_action_bus.dart';
import '../providers/preferences_provider.dart';
import '../providers/selected_topic_provider.dart';
import '../providers/shortcut_provider.dart';
import '../providers/discourse_providers.dart';
import '../services/dynamic_content_suspension_service.dart';
import '../utils/platform_utils.dart';
import '../utils/blur_config.dart';
import '../utils/responsive.dart';
import '../widgets/layout/auto_restore_master_detail_route.dart';
import '../widgets/layout/master_detail_layout.dart';
import '../widgets/layout/home_workspace_scope.dart';
import 'topics_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'topic_detail_page/topic_detail_page.dart';
import 'user_profile_page.dart';
import 'create_topic_page.dart';
import 'drafts_page.dart';

/// 话题屏幕
/// 在手机上显示单栏列表，平板上显示 Master-Detail 双栏
class TopicsScreen extends ConsumerStatefulWidget {
  const TopicsScreen({super.key, this.isActive = true});

  /// 是否为当前活跃的 tab（IndexedStack 中非活跃时跳过导航）
  final bool isActive;

  @override
  ConsumerState<TopicsScreen> createState() => _TopicsScreenState();
}

class _TopicsScreenState extends ConsumerState<TopicsScreen> {
  bool _showEmbeddedSearch = false;
  SearchFilter? _embeddedSearchFilter;
  Category? _leftCategory;
  String? _leftTag;
  bool? _lastCanShowDetailPane;
  bool _isAutoSwitching = false;

  /// 左栏是不是"列表形态"（信息流 / 草稿列表）。列表给窄栏，内容预览
  /// 才对半分。build 里按当前栈算。
  bool _masterIsListLike = true;

  /// 当前活跃的 provider 实例 ID，布局切换时复用
  String? _activeInstanceId;
  int? _activeTopicId;

  @override
  void didUpdateWidget(covariant TopicsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive) {
      // 非活跃期间可能由通知/深链写入了新选择。重新激活时必须重新投影
      // 当前状态，不能把上一次窄/宽布局判断当成已经处理。
      _lastCanShowDetailPane = null;
    }
  }

  /// 曾经尝试过用持久化的 per-topicId GlobalKey 让话题面板在 master/
  /// detail 槽位间"挪动"而不是销毁重建（意图：避开 TopicDetailPage 内
  /// 部 ref.listen 撞上销毁重建窗口期的竞态）。实测翻车更严重：多切换
  /// 几个私信后直接命中 Flutter 框架级断言
  /// `'_elements.contains(element)': is not true`（GlobalKey 内部记账
  /// 出错，红屏崩溃）——比原来要解决的问题更糟，已回退。槽位切换时
  /// 话题面板销毁重建暂时接受，如果 ref.listen 竞态复现再单独处理。
  Key _keyForTopic(int topicId) => ValueKey('topic_$topicId');

  /// topicId 变化时生成新 instanceId，相同 topicId 复用
  /// 如果提供了 existingInstanceId（如从全屏详情页传回），直接采用
  String _getOrCreateInstanceId(int topicId, {String? existingInstanceId}) {
    if (existingInstanceId != null) {
      _activeTopicId = topicId;
      _activeInstanceId = existingInstanceId;
      return existingInstanceId;
    }
    if (_activeTopicId != topicId) {
      _activeTopicId = topicId;
      _activeInstanceId = const Uuid().v4();
    }
    return _activeInstanceId!;
  }

  /// 侧栏板块导航（切换或重选）时收起深层平行视界与嵌入态，退回列表。
  void _collapseParallelForSidebarNav() {
    final state = ref.read(selectedTopicProvider);
    if (!state.isStacked &&
        !_showEmbeddedSearch &&
        _leftCategory == null &&
        _leftTag == null) {
      return;
    }
    ref.read(selectedTopicProvider.notifier).collapseToTop();
    if (mounted) {
      setState(() {
        _showEmbeddedSearch = false;
        _embeddedSearchFilter = null;
        _leftCategory = null;
        _leftTag = null;
      });
    }
  }

  void _maybePushDetail(
    SelectedTopicState selectedTopic,
    bool canShowDetailPane,
  ) {
    if (_isAutoSwitching) return;

    // IndexedStack 中非活跃 tab 仍需更新状态，避免切回时误触发
    if (!widget.isActive) {
      _lastCanShowDetailPane = canShowDetailPane;
      return;
    }

    // 当前路由不在栈顶时（有其他页面覆盖），根据布局判断是否清除选中
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      // 页面被窄屏临时详情路由或其他内容覆盖时也必须保留选择；否则用户
      // 在小屏打开话题/资料后再放大，平行视界历史已经被后台清空。
      _lastCanShowDetailPane = canShowDetailPane;
      return;
    }

    final previous = _lastCanShowDetailPane;
    _lastCanShowDetailPane = canShowDetailPane;

    // 从双栏切到单栏时自动 push；如果 previous 为空但当前为单栏且有选中，
    // 也执行 push，避免因状态丢失导致无法自动进入详情。
    if (!canShowDetailPane &&
        selectedTopic.hasSelection &&
        (previous == null || previous == true)) {
      final topicId = selectedTopic.topicId;
      if (topicId == null) {
        // 个人资料/设置层：没有可复用的 instanceId/滚动位置，直接全屏 push。
        final username = selectedTopic.username;
        final isSettings = selectedTopic.kind == PaneKind.settings;
        if (username == null && !isSettings) return;
        _isAutoSwitching = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final navigator = Navigator.of(context);
          // 不清空栈状态：只是临时用全屏页面顶替（因为窄屏放不下双栏），
          // 状态还留着——回到宽屏时（这个全屏页面还盖在上面时）
          // "route 不在栈顶"那个分支会把双栏状态原样恢复回去。之前这里
          // 会 clear()，导致缩小后又放大回去，压栈的内容就丢了，只剩
          // 空列表。
          navigator
              .push(
                MaterialPageRoute(
                  builder: (_) => AutoRestoreMasterDetailRoute(
                    child: isSettings
                        ? const SettingsPage()
                        : UserProfilePage(username: username!),
                  ),
                ),
              )
              .whenComplete(() {
                if (mounted) setState(() => _isAutoSwitching = false);
              });
        });
        return;
      }

      // 复用同一个 instanceId，避免重新 fetch
      final instanceId = _getOrCreateInstanceId(topicId);
      // 读取嵌入式详情页的实际浏览位置（在当前 build 中嵌入页还在 tree 中）
      final scrollPosition =
          ref.read(
            detailScrollPositionProvider((
              topicId: topicId,
              instanceId: instanceId,
            )),
          ) ??
          selectedTopic.scrollToPostNumber;

      _isAutoSwitching = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final navigator = Navigator.of(context);
        // 同上：不清空栈状态，回宽屏时自动恢复。
        navigator
            .push(
              MaterialPageRoute(
                builder: (_) => TopicDetailPage(
                  topicId: topicId,
                  initialTitle: selectedTopic.initialTitle,
                  scrollToPostNumber: scrollPosition,
                  autoSwitchToMasterDetail: true,
                  restoreExistingPaneStack: true,
                  instanceId: instanceId,
                  stackProvider: selectedTopicProvider,
                ),
              ),
            )
            .whenComplete(() {
              if (mounted) {
                setState(() => _isAutoSwitching = false);
              }
            });
      });
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedTopic = ref.watch(selectedTopicProvider);
    final canShowDetailPane = MasterDetailLayout.canShowBothPanesFor(context);
    // 左栏本质是不是"列表"（信息流 / 草稿列表）——决定给窄栏还是对半分
    _masterIsListLike = !selectedTopic.isStacked ||
        selectedTopic.stack[selectedTopic.stack.length - 2].kind ==
            PaneKind.drafts;
    final user = ref.watch(currentUserProvider).value;

    // 左侧导航栏的板块快捷入口位于平行视界布局之外。切换板块时除了让
    // TopicsPage 换 Tab，还必须收起“上一层内容”左栏，否则列表虽然已在
    // 后台切换，界面仍被旧话题覆盖，看起来就像点击无响应。
    //
    // 两个来源都要听：高亮状态变化（含置 null 的路径，如打开板块管理），
    // 以及 tap 事件——后者覆盖「重选当前板块」（状态同值被去重，只有
    // tap 事件会到）。普通切换两个都触发，处理器有早退保护，跑两遍无害。
    ref.listen(activeSidebarCategoryIdProvider, (_, _) {
      _collapseParallelForSidebarNav();
    });
    ref.listen(sidebarCategoryTapProvider, (_, _) {
      _collapseParallelForSidebarNav();
    });

    // 监听底栏派发的快捷动作（仅活跃 tab 响应）
    ref.listen(navActionBusProvider, (_, event) {
      if (event == null) return;
      if (event.targetId != NavEntryIds.home) return;
      if (!widget.isActive) return;
      if (_showEmbeddedSearch ||
          _leftCategory != null ||
          _leftTag != null ||
          selectedTopic.isStacked) {
        _showFeed();
        return;
      }
      switch (event.action) {
        case NavAction.scrollToTop:
          ref.read(fabRefreshModeProvider.notifier).state = false;
          ref.read(scrollToTopProvider.notifier).trigger();
          break;
        case NavAction.refresh:
          ref.read(fabRefreshModeProvider.notifier).state = false;
          ref.read(scrollToTopProvider.notifier).trigger();
          ref.read(fabRefreshSignalProvider.notifier).trigger();
          ref.resetNavScrollProgress(NavEntryIds.home);
          break;
      }
    });

    _maybePushDetail(selectedTopic, canShowDetailPane);

    // 统一使用 MasterDetailLayout 处理所有情况
    // 手机/平板单栏：只显示 master
    // 平板双栏：显示 master + detail
    return HomeWorkspaceScope(
      onShowFeed: _showFeed,
      onShowCategory: _showCategory,
      onShowTag: _showTag,
      child: MasterDetailLayout(
        // 压栈时 master 显示的是"上一层"内容而不是列表，才是真正的平行
        // 视界——放宽到接近对半分；master 还是列表时维持列表该有的窄栏。
        //
        // 例外：上一层是**草稿列表**时它本质仍是列表（一列卡片），
        // 对半分太宽、右边话题被挤扁 —— 按列表口径给窄栏。
        maxMasterRatio: selectedTopic.isStacked && !_masterIsListLike
            ? 0.8
            : MasterDetailLayout.defaultMaxMasterRatio,
        preferredMasterRatio:
            selectedTopic.isStacked && !_masterIsListLike ? 0.5 : 0.25,
        master: _wrapPaneTap(
          ActivePane.master,
          _buildMasterPane(selectedTopic),
        ),
        detail: selectedTopic.hasSelection && canShowDetailPane
            ? _wrapPaneTap(
                ActivePane.detail,
                PaneContentWidget(
                  key: selectedTopic.kind == PaneKind.topic
                      ? _keyForTopic(selectedTopic.topicId!)
                      : ValueKey(
                          '${selectedTopic.kind}_${selectedTopic.username}',
                        ),
                  entry: selectedTopic.topEntry!.kind == PaneKind.topic
                      ? PaneEntry.topic(
                          topicId: selectedTopic.topicId!,
                          initialTitle: selectedTopic.initialTitle,
                          scrollToPostNumber: selectedTopic.scrollToPostNumber,
                          instanceId: _getOrCreateInstanceId(
                            selectedTopic.topicId!,
                            existingInstanceId: selectedTopic.instanceId,
                          ),
                          highlightBoostUsername:
                              selectedTopic.highlightBoostUsername,
                          initialRevisionPostNumber:
                              selectedTopic.initialRevisionPostNumber,
                          initialRevisionNumber:
                              selectedTopic.initialRevisionNumber,
                          // 这里是**重建** entry，漏一个字段就等于把它吞掉：
                          // 之前漏了这两个，话题草稿点进来回复框根本不弹。
                          autoOpenReply:
                              selectedTopic.topEntry!.autoOpenReply,
                          autoReplyToPostNumber:
                              selectedTopic.topEntry!.autoReplyToPostNumber,
                        )
                      : selectedTopic.topEntry!,
                  stackProvider: selectedTopicProvider,
                  parentActive: widget.isActive,
                  onBack: selectedTopic.isStacked
                      ? () => ref.read(selectedTopicProvider.notifier).pop()
                      : null,
                ),
              )
            : null,
        // 压栈时 master 显示的是话题预览（不可交互，见
        // TopicDetailPage.truncateOnPush 注释），不是列表——"新建话题"这个
        // FAB 只在 master 真的是列表时才有意义，之前没跟着切换，压栈后
        // 预览一个话题下面还挂着"新建话题"的加号，容易被当成回复按钮。
        masterFloatingActionButton: user != null && !selectedTopic.isStacked
            ? _TopicsFab(
                onCreateTopic: () => _createTopic(context, ref),
                onOpenDrafts: () => _openDrafts(context),
              )
            : null,
      ),
    );
  }

  void _showFeed() {
    ref.read(selectedTopicProvider.notifier).collapseToTop();
    setState(() {
      _showEmbeddedSearch = false;
      _embeddedSearchFilter = null;
      _leftCategory = null;
      _leftTag = null;
    });
  }

  void _showCategory(Category category) {
    ref.read(selectedTopicProvider.notifier).collapseToTop();
    setState(() {
      _showEmbeddedSearch = false;
      _embeddedSearchFilter = null;
      _leftCategory = category;
      _leftTag = null;
    });
  }

  void _showTag(String tag) {
    ref.read(selectedTopicProvider.notifier).collapseToTop();
    setState(() {
      _showEmbeddedSearch = false;
      _embeddedSearchFilter = null;
      _leftCategory = null;
      _leftTag = tag;
    });
  }

  /// 平行视界压栈时（stack.length > 1）：左侧不再显示话题列表，改显示
  /// 栈里"上一层"的话题（当前顶层内容左移那一层），右侧显示新顶替的
  /// 内容——而不是简单隐藏 master。列表用 Offstage 保留而非卸载，退回
  /// 最底层时原样恢复（含滚动位置）。
  Widget _buildMasterPane(SelectedTopicState selectedTopic) {
    final topicsPage = TopicsPage(
      externalCategoryId: _leftCategory?.id,
      externalTag: _leftTag,
      onSearchRequested: (filter) => setState(() {
        _embeddedSearchFilter = filter;
        _showEmbeddedSearch = true;
        _leftCategory = null;
        _leftTag = null;
      }),
    );
    // 信息流始终保活，搜索只是覆盖左栏。退出搜索后滚动位置、Tab 和已加载
    // 数据原样恢复，不能因为一次搜索重新创建整棵信息流。
    final list = Stack(
      children: [
        ExcludeFocus(
          excluding: _showEmbeddedSearch,
          child: Offstage(offstage: _showEmbeddedSearch, child: topicsPage),
        ),
        if (_showEmbeddedSearch)
          SearchPage(
            key: ValueKey(_embeddedSearchFilter),
            initialFilter: _embeddedSearchFilter,
            embeddedMaster: true,
            stackProvider: selectedTopicProvider,
            onClose: _showFeed,
          ),
      ],
    );
    if (!selectedTopic.isStacked) return list;
    final previous = selectedTopic.stack[selectedTopic.stack.length - 2];
    return Stack(
      children: [
        ExcludeFocus(
          excluding: true,
          child: Offstage(offstage: true, child: list),
        ),
        PaneContentWidget(
          key: previous.kind == PaneKind.topic
              ? _keyForTopic(previous.topicId!)
              : ValueKey('master_${previous.kind}_${previous.username}'),
          entry: previous,
          stackProvider: selectedTopicProvider,
          truncateOnPush: true,
          // 左栏预览位也要跟随 tab 活跃态（草稿列表靠它决定何时重拉）
          parentActive: widget.isActive,
        ),
      ],
    );
  }

  /// 包裹面板：点击切换活跃面板 + Tab 切换时短暂高亮顶部指示条
  Widget _wrapPaneTap(ActivePane pane, Widget child) {
    if (!PlatformUtils.isDesktop) return child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        // 点击切换时不显示指示器（鼠标用户不需要）
        if (ref.read(activePaneProvider) != pane) {
          ref.read(activePaneProvider.notifier).state = pane;
        }
      },
      child: _PaneActiveIndicator(pane: pane, child: child),
    );
  }

  void _openDrafts(BuildContext context) {
    // 首页信息流**自己**就是平行视界宿主（左列表 + 右 detail），但这里的
    // context 在栈外（FAB/菜单），拿不到 EmbeddedStackScope —— 之前靠
    // scope 查找必然落空、每次都全屏。直接压首页栈：草稿列表进右栏，
    // 左边信息流不动。
    if (MasterDetailLayout.canShowBothPanesFor(context)) {
      ref.read(selectedTopicProvider.notifier).pushDrafts();
      return;
    }
    // 窄屏没有右栏可承载，照旧全屏
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const DraftsPage()),
    );
  }

  Future<void> _createTopic(BuildContext context, WidgetRef ref) async {
    final categoryId = ref.read(currentTabCategoryIdProvider);
    final tags = ref.read(tabTagsProvider(categoryId));
    final topicId = await Navigator.push<int>(
      context,
      MaterialPageRoute(
        builder: (_) => CreateTopicPage(
          initialCategoryId: categoryId,
          initialTags: tags.isNotEmpty ? tags : null,
        ),
      ),
    );
    if (topicId != null && context.mounted) {
      // 刷新当前 tab 的列表
      ref.invalidate(topicListProvider(null));

      final canShowDetailPane = MasterDetailLayout.canShowBothPanesFor(context);
      if (canShowDetailPane) {
        // 双栏模式：选中新话题，在右侧详情面板显示
        ref.read(selectedTopicProvider.notifier).select(topicId: topicId);
      } else {
        // 单栏模式：push 全屏详情页查看新话题
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TopicDetailPage(
              topicId: topicId,
              autoSwitchToMasterDetail: true,
            ),
          ),
        );
      }
    }
  }
}

/// 首页 FAB：向上滚动时切换为刷新按钮，正常模式下点击展开 Speed Dial 菜单
class _TopicsFab extends ConsumerStatefulWidget {
  const _TopicsFab({required this.onCreateTopic, required this.onOpenDrafts});

  final VoidCallback onCreateTopic;
  final VoidCallback onOpenDrafts;

  @override
  ConsumerState<_TopicsFab> createState() => _TopicsFabState();
}

class _TopicsFabState extends ConsumerState<_TopicsFab>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _expandAnimation;
  final LayerLink _layerLink = LayerLink();
  bool _isExpanded = false;
  OverlayEntry? _overlayEntry;
  DynamicContentSuspensionLease? _dynamicContentLease;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _expandAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _removeOverlay();
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_isExpanded) {
      _close();
    } else {
      setState(() => _isExpanded = true);
      _showOverlay();
      _controller.forward();
      HapticFeedback.lightImpact();
    }
  }

  void _close({bool immediately = false}) {
    if (!_isExpanded) return;
    setState(() => _isExpanded = false);
    if (immediately) {
      _controller.stop();
      _controller.value = 0;
      _removeOverlay();
      return;
    }
    _controller.reverse().then((_) {
      _removeOverlay();
    });
  }

  void _showOverlay() {
    _removeOverlay();
    // 在展开动画和全屏背景模糊开始前先暂停帖子动态内容，避免首帧就与
    // SVG/WebView 纹理提交争抢 UI、raster 和 GPU。
    _acquireDynamicContentSuspension();
    final theme = Theme.of(context);
    final dialogBlur = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(preferencesProvider).dialogBlur;

    // 桌面 acrylic 模式下 NavigationRail 背景透明，
    // BackdropFilter 对其模糊效果异常，需跳过该区域
    final showRail = Responsive.showNavigationRail(context);
    final hasAcrylic = Platform.isMacOS || Platform.isWindows;
    final blurLeftInset = (showRail && hasAcrylic) ? 72.0 : 0.0;
    final barrierColor = dialogBlur
        ? blurBarrierColor(Theme.of(context).brightness)
        : Colors.black26;

    _overlayEntry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // 全屏暗色遮罩 + 点击关闭
          GestureDetector(
            onTap: _close,
            behavior: HitTestBehavior.opaque,
            child: FadeTransition(
              opacity: _expandAnimation,
              child: ColoredBox(
                color: barrierColor,
                child: const SizedBox.expand(),
              ),
            ),
          ),
          // NavigationRail 补底：acrylic 模式下 Rail 背景透明，
          // 用 surface 色填充使遮罩可见
          if (dialogBlur && blurLeftInset > 0)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: blurLeftInset,
              child: IgnorePointer(
                child: FadeTransition(
                  opacity: _expandAnimation,
                  child: ColoredBox(
                    color: Theme.of(context).colorScheme.surfaceDim,
                  ),
                ),
              ),
            ),
          // 模糊层：覆盖 body 区域（跳过透明的 NavigationRail）
          if (dialogBlur)
            Positioned.fill(
              left: blurLeftInset,
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _expandAnimation,
                  builder: (context, child) {
                    final t = _expandAnimation.value;
                    if (t == 0) return child!;
                    return BackdropFilter(
                      filter: createBlurFilter(
                        (blurSigma * t).clamp(0.01, blurSigma),
                      ),
                      child: child,
                    );
                  },
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          // 主 FAB 副本（在模糊层之上，保持清晰）
          if (dialogBlur)
            CompositedTransformFollower(
              link: _layerLink,
              showWhenUnlinked: false,
              targetAnchor: Alignment.center,
              followerAnchor: Alignment.center,
              child: FloatingActionButton(
                heroTag: null,
                onPressed: _close,
                child: AnimatedRotation(
                  turns: 0.125,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Symbols.add_rounded),
                ),
              ),
            ),
          // 子按钮：定位到主 FAB 上方
          CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            targetAnchor: Alignment.topRight,
            followerAnchor: Alignment.bottomRight,
            offset: const Offset(0, -16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _buildMiniAction(
                  icon: Symbols.drafts_rounded,
                  label: context.l10n.topicsScreen_myDrafts,
                  onTap: () {
                    _close(immediately: true);
                    widget.onOpenDrafts();
                  },
                  theme: theme,
                ),
                const SizedBox(height: 12),
                _buildMiniAction(
                  icon: Symbols.edit_rounded,
                  label: context.l10n.topicsScreen_createTopic,
                  onTap: () {
                    _close(immediately: true);
                    widget.onCreateTopic();
                  },
                  theme: theme,
                ),
              ],
            ),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry?.dispose();
    _overlayEntry = null;
    _releaseDynamicContentSuspension();
  }

  void _acquireDynamicContentSuspension() {
    _dynamicContentLease ??= DynamicContentSuspensionService.instance.acquire(
      reason: 'topics_fab_speed_dial',
    );
  }

  void _releaseDynamicContentSuspension() {
    _dynamicContentLease?.release();
    _dynamicContentLease = null;
  }

  void _refreshTopics() {
    ref.read(fabRefreshModeProvider.notifier).state = false;
    ref.read(scrollToTopProvider.notifier).trigger();
    ref.read(fabRefreshSignalProvider.notifier).trigger();
  }

  @override
  Widget build(BuildContext context) {
    final showRefresh = ref.watch(fabRefreshModeProvider);

    // 刷新模式切换时自动收起
    if (showRefresh && _isExpanded) {
      _close();
    }

    final Widget fab;
    if (showRefresh) {
      // 刷新模式：简单的单按钮
      fab = FloatingActionButton(
        heroTag: 'createTopic',
        onPressed: _refreshTopics,
        child: const Icon(Symbols.refresh_rounded),
      );
    } else {
      // 主 FAB（作为锚点，子按钮在 Overlay 中定位到它上方）
      // 模糊开启时，展开后隐藏真实 FAB（overlay 中有 sharp 副本）
      final dialogBlur = ref.watch(
        preferencesProvider.select((p) => p.dialogBlur),
      );
      final hideFab = _isExpanded && dialogBlur;

      fab = CompositedTransformTarget(
        link: _layerLink,
        child: Opacity(
          opacity: hideFab ? 0 : 1,
          child: FloatingActionButton(
            heroTag: 'createTopic',
            onPressed: _toggle,
            child: AnimatedRotation(
              turns: _isExpanded ? 0.125 : 0,
              duration: const Duration(milliseconds: 200),
              child: const Icon(Symbols.add_rounded),
            ),
          ),
        ),
      );
    }

    // 跟随底栏升降：FAB 的 Positioned 锚在系统安全区基线
    // （MasterDetailLayout 用 viewPadding），底栏可见时按可见度把
    // FAB 抬高一个底栏槽高（padding.bottom 是 extendBody 注入的槽高，
    // 与 viewPadding 的差即底栏本体；rail 模式无底栏时差为 0 自动
    // 退化）。paint-only 平移，overlay 里的子按钮经
    // CompositedTransformFollower 跟随主 FAB 一起动。
    return Consumer(
      builder: (context, ref, child) {
        final visibility = ref.watch(barVisibilityProvider);
        final mq = MediaQuery.of(context);
        final barHeight = (mq.padding.bottom - mq.viewPadding.bottom).clamp(
          0.0,
          double.infinity,
        );
        return Transform.translate(
          offset: Offset(0, -barHeight * visibility),
          child: child,
        );
      },
      child: fab,
    );
  }

  Widget _buildMiniAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required ThemeData theme,
  }) {
    return FadeTransition(
      opacity: _expandAnimation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.5),
          end: Offset.zero,
        ).animate(_expandAnimation),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Material(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(8),
              elevation: 2,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Text(
                    label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            FloatingActionButton.small(
              heroTag: 'fab_$label',
              onPressed: onTap,
              child: Icon(icon),
            ),
          ],
        ),
      ),
    );
  }
}

/// 面板活跃 HUD 指示器：Tab 切换时在面板中央短暂显示半透明浮层
class _PaneActiveIndicator extends ConsumerStatefulWidget {
  final ActivePane pane;
  final Widget child;

  const _PaneActiveIndicator({required this.pane, required this.child});

  @override
  ConsumerState<_PaneActiveIndicator> createState() =>
      _PaneActiveIndicatorState();
}

class _PaneActiveIndicatorState extends ConsumerState<_PaneActiveIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      reverseDuration: const Duration(milliseconds: 400),
    );
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 仅监听键盘切换信号，点击切换不触发 HUD
    ref.listen(paneSwitchSignalProvider, (prev, next) {
      if (prev != next && ref.read(activePaneProvider) == widget.pane) {
        _anim.forward(from: 0).then((_) {
          Future.delayed(const Duration(milliseconds: 800), () {
            if (mounted) _anim.reverse();
          });
        });
      }
    });

    final theme = Theme.of(context);
    final label = widget.pane == ActivePane.master
        ? context.l10n.shortcuts_navigation
        : context.l10n.shortcuts_content;
    final icon = widget.pane == ActivePane.master
        ? Symbols.list_rounded
        : Symbols.article_rounded;

    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: Center(
              child: FadeTransition(
                opacity: _anim,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.inverseSurface.withValues(
                      alpha: 0.8,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        icon,
                        size: 18,
                        color: theme.colorScheme.onInverseSurface,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        label,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.onInverseSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 话题详情面板（用于双栏模式，不包含返回按钮）
///
/// 首页话题列表跟私信列表各自有一份独立的平行视界导航栈
/// （[selectedTopicProvider] / [selectedMessageProvider]），这个面板
/// 两边都复用，靠 [stackProvider] 区分内部链接点击该压到哪个栈。
class TopicDetailPane extends ConsumerWidget {
  const TopicDetailPane({
    super.key,
    required this.topicId,
    required this.parentActive,
    this.instanceId,
    this.initialTitle,
    this.scrollToPostNumber,
    this.highlightBoostUsername,
    this.initialRevisionPostNumber,
    this.initialRevisionNumber,
    this.onBack,
    this.stackProvider,
    this.truncateOnPush = false,
    this.autoOpenReply = false,
    this.autoReplyToPostNumber,
  });

  final int topicId;
  final bool parentActive;
  final String? instanceId;
  final String? initialTitle;
  final int? scrollToPostNumber;
  final String? highlightBoostUsername;
  final int? initialRevisionPostNumber;
  final int? initialRevisionNumber;

  /// 平行视界导航栈：非 null 时说明当前层是内部链接跳转堆上来的
  /// （栈深度 > 1），显示返回按钮弹出当前层。
  final VoidCallback? onBack;

  /// 内部链接点击时压栈的目标 provider，默认 [selectedTopicProvider]。
  final SelectedTopicProvider? stackProvider;

  /// true = 这份内容只是 master 面板里的"上一层预览"，不是当前可交互
  /// 的栈顶——内部链接点击应该截断栈顶后压入（替换右侧正显示的那层），
  /// 见 [TopicDetailPage.truncateOnPush] 注释。
  final bool truncateOnPush;

  /// 进入即弹回复框(草稿续写)。
  final bool autoOpenReply;
  final int? autoReplyToPostNumber;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final restoredScrollPosition = instanceId == null
        ? null
        : ref.read(
            detailScrollPositionProvider((
              topicId: topicId,
              instanceId: instanceId!,
            )),
          );
    return TopicDetailPage(
      topicId: topicId,
      instanceId: instanceId,
      stackProvider: stackProvider,
      initialTitle: initialTitle,
      // 面板在 master/detail 槽位之间搬动会重建 Widget，但 provider 与
      // 视口位置都沿用同一个 instanceId，不再退回最初进入时的楼层。
      scrollToPostNumber: restoredScrollPosition ?? scrollToPostNumber,
      highlightBoostUsername: highlightBoostUsername,
      initialRevisionPostNumber: initialRevisionPostNumber,
      initialRevisionNumber: initialRevisionNumber,
      embeddedMode: true, // 嵌入模式，返回按钮由 onEmbeddedBack 控制
      truncateOnPush: truncateOnPush,
      onEmbeddedBack: onBack,
      parentActive: parentActive,
      autoOpenReply: autoOpenReply,
      // 弹过一次就把意图从栈里清掉，否则面板每次重建都会再弹
      onAutoReplyConsumed: () => ref
          .read((stackProvider ?? selectedTopicProvider).notifier)
          .consumeAutoOpenReply(),
      autoReplyToPostNumber: autoReplyToPostNumber,
    );
  }
}

/// 平行视界导航栈某一层的内容——按 [entry.kind] 分发到话题详情或个人
/// 资料页，两者共用同一套栈（[stackProvider]）+ 返回语义（[onBack]）。
class PaneContentWidget extends StatelessWidget {
  const PaneContentWidget({
    super.key,
    required this.entry,
    required this.stackProvider,
    this.onBack,
    this.parentActive = false,
    this.truncateOnPush = false,
  });

  final PaneEntry entry;
  final SelectedTopicProvider stackProvider;
  final VoidCallback? onBack;
  final bool parentActive;

  /// true = master 面板里的"上一层预览"——内部链接点击/列表点击应该
  /// 截断栈顶后压入（替换右侧正显示的那层），而不是在已经很深的栈上
  /// 继续叠层——见 [EmbeddedStackScope.truncateOnPush] 注释。
  final bool truncateOnPush;

  @override
  Widget build(BuildContext context) {
    switch (entry.kind) {
      case PaneKind.topic:
        return TopicDetailPane(
          topicId: entry.topicId!,
          parentActive: parentActive,
          instanceId: entry.instanceId,
          initialTitle: entry.initialTitle,
          scrollToPostNumber: entry.scrollToPostNumber,
          highlightBoostUsername: entry.highlightBoostUsername,
          initialRevisionPostNumber: entry.initialRevisionPostNumber,
          initialRevisionNumber: entry.initialRevisionNumber,
          onBack: onBack,
          stackProvider: stackProvider,
          truncateOnPush: truncateOnPush,
          autoOpenReply: entry.autoOpenReply,
          autoReplyToPostNumber: entry.autoReplyToPostNumber,
        );
      case PaneKind.profile:
        return EmbeddedStackScope(
          stackProvider: stackProvider,
          truncateOnPush: truncateOnPush,
          child: UserProfilePage(
            username: entry.username!,
            embeddedMode: true,
            onEmbeddedBack: onBack,
          ),
        );
      case PaneKind.settings:
        return EmbeddedStackScope(
          stackProvider: stackProvider,
          truncateOnPush: truncateOnPush,
          child: SettingsPage(embeddedMode: true, onEmbeddedBack: onBack),
        );
      case PaneKind.drafts:
        return EmbeddedStackScope(
          stackProvider: stackProvider,
          truncateOnPush: truncateOnPush,
          // 草稿处理完 → 把草稿这一层从栈里抽掉（不是 pop：pop 会连右边
          // 的话题一起关掉）。master 预览位的 onBack 本来就是 null，所以
          // 这条必须独立接线，否则草稿栏永远赖着不走。
          child: Consumer(
            builder: (context, ref, _) => DraftsPage(
              embeddedMode: true,
              // 跟随宿主 tab 的活跃状态：切走再切回来要重新拉一次草稿
              isActive: parentActive,
              // truncateOnPush = 我在左栏预览位 = 我是"处理栏"，空了该撤
              autoCloseWhenEmpty: truncateOnPush,
              onEmbeddedBack: onBack,
              onAllHandled: () => ref
                  .read(stackProvider.notifier)
                  .removeEntriesOfKind(PaneKind.drafts),
            ),
          ),
        );
    }
  }
}
