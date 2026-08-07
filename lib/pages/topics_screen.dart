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
import '../widgets/layout/master_detail_layout.dart';
import '../widgets/layout/pane_projection_back_scope.dart';
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

  /// 桌面 ESC 两段式:右栏/投影开着→分发落 detail scope(关右栏);空态→
  /// 注册 maybePop(首页是首路由,no-op,注册无害但保持机制一致)。
  late final PaneHostEscBinding _escBinding = PaneHostEscBinding(
    ref: ref,
    enabled: () => widget.isActive,
  );

  @override
  void dispose() {
    _escBinding.dispose();
    super.dispose();
  }

  /// 左栏是不是"列表形态"（信息流 / 草稿列表）。列表给窄栏，内容预览
  /// 才对半分。build 里按当前栈算。
  bool _masterIsListLike = true;

  /// 当前活跃的 provider 实例 ID，布局切换时复用
  String? _activeInstanceId;
  int? _activeTopicId;

  /// 历史注:曾用持久化 per-topicId GlobalKey 让话题面板在 master/detail
  /// 槽位间"挪动",红屏翻车已回退(`'_elements.contains(element)'` 断言)。
  /// 胶片带模型下该问题不存在:格子恒驻,从不跨槽挪动。

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
    // 窄屏投影态:详情全宽盖着列表,collapseToTop 对单层栈是 no-op,
    // 不清就会"点了板块没反应"(列表在投影底下换好了但看不见)——
    // 投影态下切板块语义就是回列表,整栈清空。
    final projecting =
        state.hasSelection && !MasterDetailLayout.canShowBothPanesFor(context);
    if (!state.isStacked &&
        !projecting &&
        !_showEmbeddedSearch &&
        _leftCategory == null &&
        _leftTag == null) {
      return;
    }
    final notifier = ref.read(selectedTopicProvider.notifier);
    if (projecting) {
      notifier.clear();
    } else {
      notifier.collapseToTop();
    }
    if (mounted) {
      setState(() {
        _showEmbeddedSearch = false;
        _embeddedSearchFilter = null;
        _leftCategory = null;
        _leftTag = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedTopic = ref.watch(selectedTopicProvider);
    // 左栏本质是不是"列表"（信息流）——决定给窄栏还是对半分
    _masterIsListLike = !selectedTopic.isStacked;
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
      // 投影态(窄屏详情全宽盖着列表)下点"首页"=回列表,与压栈态同语义
      final projecting =
          selectedTopic.hasSelection &&
          !MasterDetailLayout.canShowBothPanesFor(context);
      if (_showEmbeddedSearch ||
          _leftCategory != null ||
          _leftTag != null ||
          selectedTopic.isStacked ||
          projecting) {
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

    // ESC 语义:栈非空(宽屏右栏开着/窄屏投影着)都让分发落 detail scope
    // (关右栏/关投影);栈空才注册 maybePop 关整页。
    _escBinding.sync(context, paneOpen: selectedTopic.hasSelection);

    // 统一使用 MasterDetailLayout 处理所有情况
    // 手机/平板单栏：只显示 master;栈非空时 detail 在本页体内全宽投影
    // (平行视界栈是唯一真相,不 push 合成路由,宽窄切换 State 原地保留)
    // 平板双栏：显示 master + detail
    return HomeWorkspaceScope(
      onShowFeed: _showFeed,
      onShowCategory: _showCategory,
      onShowTag: _showTag,
      child: PaneProjectionBackScope(
        stackProvider: selectedTopicProvider,
        isActive: widget.isActive,
        child: MasterDetailLayout(
        // 压栈时左栏显示的是"上一层"内容而不是列表，才是真正的平行
        // 视界——放宽到接近对半分；master 还是列表时维持列表该有的窄栏。
        //
        // 例外：上一层是**草稿列表**时它本质仍是列表（一列卡片），
        // 对半分太宽、右边话题被挤扁 —— 按列表口径给窄栏。
        maxMasterRatio: selectedTopic.isStacked && !_masterIsListLike
            ? 0.8
            : MasterDetailLayout.defaultMaxMasterRatio,
        preferredMasterRatio:
            selectedTopic.isStacked && !_masterIsListLike ? 0.5 : 0.25,
        projectDetailWhenNarrow: true,
        // 胶片带:列表也在带上,压栈时被顶出左侧、倒二层格顶上左栏
        // (旧"上一层预览"形态,由容器统一承担,预览格 State 全保)。
        pinMaster: false,
        master: _wrapPaneTap(
          ActivePane.master,
          _buildMasterPane(selectedTopic),
        ),
        panes: [
          for (var i = 0; i < selectedTopic.stack.length; i++)
            _buildPaneCell(selectedTopic, i),
        ],
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
      ),
    );
  }

  /// 平行视界第 [index] 层格(0=栈底)。每层一格、key 稳定,格子在
  /// 胶片带上恒驻:压栈时本格滑去左栏当"上一层预览"(truncateOnPush
  /// 语义),退栈时滑回右栏——同一 Element,滚动位置全保。
  Widget _buildPaneCell(SelectedTopicState selectedTopic, int index) {
    final entry = selectedTopic.stack[index];
    final isTop = index == selectedTopic.stack.length - 1;
    final key = entry.kind == PaneKind.topic
        ? ValueKey('home_pane_${entry.topicId}_${entry.instanceId ?? ''}')
        : ValueKey('home_pane_${entry.kind}_${entry.username}');
    return KeyedSubtree(
      key: key,
      child: _wrapPaneTap(
        ActivePane.detail,
        PaneContentWidget(
          entry: entry.kind == PaneKind.topic && entry.instanceId == null
              ? PaneEntry.topic(
                  topicId: entry.topicId!,
                  initialTitle: entry.initialTitle,
                  scrollToPostNumber: entry.scrollToPostNumber,
                  instanceId: _getOrCreateInstanceId(
                    entry.topicId!,
                    existingInstanceId: entry.instanceId,
                  ),
                  highlightBoostUsername: entry.highlightBoostUsername,
                  initialRevisionPostNumber: entry.initialRevisionPostNumber,
                  initialRevisionNumber: entry.initialRevisionNumber,
                  // 这里是**重建** entry，漏一个字段就等于把它吞掉：
                  // 之前漏了这两个，话题草稿点进来回复框根本不弹。
                  autoOpenReply: entry.autoOpenReply,
                  autoReplyToPostNumber: entry.autoReplyToPostNumber,
                )
              : entry,
          stackProvider: selectedTopicProvider,
          parentActive: widget.isActive,
          // 非顶格 = "上一层预览":内部点击走截断替换语义。
          truncateOnPush: !isTop,
          // 基础层（栈仅一层）也给 clear：ESC/返回按钮清空右栏回到
          // 空态，与 search/seeking 行为一致（平行视界 ESC 统一）。
          // 回调内重读 provider，不闭包捕获 build 时的快照。
          onBack: () {
            final notifier = ref.read(selectedTopicProvider.notifier);
            if (ref.read(selectedTopicProvider).isStacked) {
              notifier.pop();
            } else {
              notifier.clear();
            }
          },
        ),
      ),
    );
  }

  void _showFeed() {
    final notifier = ref.read(selectedTopicProvider.notifier);
    // 投影态下"回信息流"必须整栈清空:collapseToTop 对单层栈是 no-op,
    // 投影会继续盖着列表。宽屏保留右栏基础层(仅收深层)语义不变。
    if (ref.read(selectedTopicProvider).hasSelection &&
        !MasterDetailLayout.canShowBothPanesFor(context)) {
      notifier.clear();
    } else {
      notifier.collapseToTop();
    }
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
  /// master 格:信息流列表(或嵌入搜索覆盖层)。压栈时的"上一层预览"
  /// 不再在这里手工顶替——胶片带模型下由容器统一承担(倒二层格滑到
  /// 左栏,格子恒驻 State 全保),本方法恒返回列表本体。
  Widget _buildMasterPane(SelectedTopicState selectedTopic) {
    final topicsPage = TopicsPage(
      externalCategoryId: _leftCategory?.id,
      externalTag: _leftTag,
      isActive: widget.isActive,
      onSearchRequested: (filter) => setState(() {
        _embeddedSearchFilter = filter;
        _showEmbeddedSearch = true;
        _leftCategory = null;
        _leftTag = null;
      }),
    );
    // 信息流始终保活，搜索只是覆盖左栏。退出搜索后滚动位置、Tab 和已加载
    // 数据原样恢复，不能因为一次搜索重新创建整棵信息流。
    return Stack(
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
    // 草稿页是独立的双栏页（宽屏自带"左列表右话题"），所有入口统一
    // 全屏打开，不再往平行视界栈里塞草稿层。
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
  LocalHistoryEntry? _historyEntry;
  bool _removingHistory = false;
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
    _removeHistoryEntry();
    _removeOverlay();
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_isExpanded) {
      _close();
    } else {
      setState(() => _isExpanded = true);
      _addHistoryEntry();
      _showOverlay();
      _controller.forward();
      HapticFeedback.lightImpact();
    }
  }

  void _close({bool immediately = false, bool fromHistory = false}) {
    if (!fromHistory) _removeHistoryEntry();
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

  void _addHistoryEntry() {
    if (_historyEntry != null) return;
    final route = ModalRoute.of(context);
    if (route == null) return;
    _historyEntry = LocalHistoryEntry(
      impliesAppBarDismissal: false,
      onRemove: () {
        _historyEntry = null;
        if (!_removingHistory && mounted) {
          _close(fromHistory: true);
        }
      },
    );
    route.addLocalHistoryEntry(_historyEntry!);
  }

  void _removeHistoryEntry() {
    final entry = _historyEntry;
    if (entry == null) return;
    _historyEntry = null;
    _removingHistory = true;
    entry.remove();
    _removingHistory = false;
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
            parentActive: parentActive,
          ),
        );
      case PaneKind.settings:
        return EmbeddedStackScope(
          stackProvider: stackProvider,
          truncateOnPush: truncateOnPush,
          child: SettingsPage(
            embeddedMode: true,
            onEmbeddedBack: onBack,
            parentActive: parentActive,
          ),
        );
    }
  }
}
