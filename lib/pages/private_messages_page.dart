import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import '../models/topic.dart';
import '../navigation/nav_action_bus.dart';
import '../providers/selected_topic_provider.dart';
import '../providers/user_content_providers.dart';
import '../providers/preferences_provider.dart';
import '../providers/shortcut_provider.dart';
import '../utils/load_more_coordinator.dart';
import '../widgets/common/paged_list_footer.dart';
import '../widgets/layout/auto_restore_master_detail_route.dart';
import '../widgets/layout/master_detail_layout.dart';
import '../widgets/topic/topic_item_builder.dart';
import '../widgets/topic/topic_list_skeleton.dart';
import '../widgets/post/reply_sheet.dart';
import '../widgets/common/error_view.dart';
import '../widgets/desktop_refresh_indicator.dart';
import '../l10n/s.dart';
import 'settings_page.dart';
import 'topic_detail_page/topic_detail_page.dart';
import 'topics_screen.dart' show PaneContentWidget;
import 'user_profile_page.dart';

/// 内部 tab 动作：外层根据当前激活 filter 派发给对应子 widget。
/// 用 nonce 让连续同类事件也能触发 Riverpod 监听。
enum _PmTabAction { scrollToTop, refresh }

class _PmTabEvent {
  final _PmTabAction action;
  final int nonce;
  const _PmTabEvent(this.action, this.nonce);
}

final _pmTabEventNonceProvider = StateProvider<int>((ref) => 0);

final _pmTabEventProvider =
    StateProvider.family<_PmTabEvent?, PrivateMessageFilter>(
      (ref, filter) => null,
    );

/// 私信列表页面
class PrivateMessagesPage extends ConsumerStatefulWidget {
  const PrivateMessagesPage({super.key, this.isActive = true});

  /// 是否为当前活跃的 tab（嵌入底栏时用于决定是否响应 NavActionBus）
  final bool isActive;

  @override
  ConsumerState<PrivateMessagesPage> createState() =>
      _PrivateMessagesPageState();
}

class _PrivateMessagesPageState extends ConsumerState<PrivateMessagesPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  /// 桌面 ESC 两段式:右栏开着→分发落 detail scope(关右栏);右栏空→
  /// 注册 maybePop。底栏 tab 形态是首路由,maybePop 为 no-op。
  late final PaneHostEscBinding _escBinding = PaneHostEscBinding(
    ref: ref,
    enabled: () => widget.isActive,
  );

  /// 用持久化 GlobalKey 做 master/detail 槽位间的话题面板"挪动"已回退——
  /// 实测多切换几个私信会命中 Flutter 框架级断言
  /// `'_elements.contains(element)': is not true`（红屏崩溃），比原来要
  /// 解决的销毁重建竞态更严重。理由详见 topics_screen.dart 同名注释。
  Key _keyForTopic(int topicId) => ValueKey('topic_$topicId');

  /// 平行视界压栈时：左侧显示栈里"上一层"内容而不是简单隐藏，右侧显示
  /// 新顶替的内容；列表用 Offstage 保留，退回最底层时原样恢复。
  Widget _buildMasterPane(SelectedTopicState selectedMessage, Widget list) {
    if (!selectedMessage.isStacked) return list;
    final previous = selectedMessage.stack[selectedMessage.stack.length - 2];
    return Stack(
      children: [
        Offstage(offstage: true, child: list),
        PaneContentWidget(
          key: previous.kind == PaneKind.topic
              ? _keyForTopic(previous.topicId!)
              : ValueKey('master_${previous.kind}_${previous.username}'),
          entry: previous,
          stackProvider: selectedMessageProvider,
          truncateOnPush: true,
          parentActive: widget.isActive,
        ),
      ],
    );
  }

  static const _filters = [
    PrivateMessageFilter.inbox,
    PrivateMessageFilter.sent,
    PrivateMessageFilter.archive,
  ];

  bool? _lastCanShowDetailPane;
  bool _isAutoSwitching = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _filters.length, vsync: this);
  }

  /// 双栏→单栏（窗口缩小）时自动把当前栈顶层 push 成全屏详情页，而不是
  /// 让选中状态"静默消失"、只剩下私信列表——之前这里完全没做，缩小窗口
  /// 就直接掉回私信列表本身，而不是栈顶（最新压的那层，比如内部链接点
  /// 开的话题）。逻辑对齐 topics_screen.dart 的 `_maybePushDetail`。
  void _maybePushDetail(SelectedTopicState selectedMessage, bool canShowDetailPane) {
    if (_isAutoSwitching) return;
    if (!widget.isActive) {
      _lastCanShowDetailPane = canShowDetailPane;
      return;
    }

    final previous = _lastCanShowDetailPane;
    _lastCanShowDetailPane = canShowDetailPane;

    if (!canShowDetailPane &&
        selectedMessage.hasSelection &&
        (previous == null || previous == true)) {
      final topicId = selectedMessage.topicId;
      if (topicId == null) {
        final username = selectedMessage.username;
        final isSettings = selectedMessage.kind == PaneKind.settings;
        if (username == null && !isSettings) return;
        _isAutoSwitching = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final navigator = Navigator.of(context);
          // 不清空栈状态，回宽屏时自动恢复（理由见 topics_screen.dart
          // 同名方法的注释）。
          navigator
              .push(MaterialPageRoute(
                builder: (_) => AutoRestoreMasterDetailRoute(
                  child: isSettings
                      ? const SettingsPage()
                      : UserProfilePage(username: username!),
                ),
              ))
              .whenComplete(() {
            if (mounted) setState(() => _isAutoSwitching = false);
          });
        });
        return;
      }

      _isAutoSwitching = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final navigator = Navigator.of(context);
        // 同上：不清空栈状态。
        navigator
            .push(MaterialPageRoute(
              builder: (_) => TopicDetailPage(
                topicId: topicId,
                initialTitle: selectedMessage.initialTitle,
                scrollToPostNumber: selectedMessage.scrollToPostNumber,
                autoSwitchToMasterDetail: true,
                restoreExistingPaneStack: true,
                stackProvider: selectedMessageProvider,
              ),
            ))
            .whenComplete(() {
          if (mounted) setState(() => _isAutoSwitching = false);
        });
      });
    }
  }

  @override
  void dispose() {
    _escBinding.dispose();
    _tabController.dispose();
    super.dispose();
  }

  bool _onScrollNotification(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    final raw = n.metrics.pixels;
    final progress = raw < 0 ? 0.0 : raw;
    final current = ref.read(navScrollProgressProvider(NavEntryIds.messages));
    final atZero = progress == 0 && current != 0;
    final crossed =
        (progress >= navScrollIconThreshold) !=
        (current >= navScrollIconThreshold);
    if (!atZero && !crossed && (progress - current).abs() < 4.0) return false;
    ref.read(navScrollProgressProvider(NavEntryIds.messages).notifier).state =
        progress;
    return false;
  }

  /// 新建私信：收件人在编辑器内搜索选择（用户或可发私信的群组）。
  Future<void> _composeNewMessage() async {
    final created = await showReplySheet(
      context: context,
      composePrivateMessage: true,
    );
    if (!mounted || created == null) return;
    // 新私信会同时进「收件箱」与「已发送」，两个都刷新
    ref.read(pmInboxProvider.notifier).refresh();
    ref.read(pmSentProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    // 底栏派发的快捷动作：查询当前激活 tab 的 filter，转发到对应子 widget。
    ref.listen(navActionBusProvider, (_, event) {
      if (event == null) return;
      if (event.targetId != NavEntryIds.messages) return;
      if (!widget.isActive) return;
      final filter = _filters[_tabController.index];
      final nextNonce = ref.read(_pmTabEventNonceProvider) + 1;
      ref.read(_pmTabEventNonceProvider.notifier).state = nextNonce;
      final tabAction = event.action == NavAction.scrollToTop
          ? _PmTabAction.scrollToTop
          : _PmTabAction.refresh;
      ref.read(_pmTabEventProvider(filter).notifier).state = _PmTabEvent(
        tabAction,
        nextNonce,
      );
    });

    final listScaffold = NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: Scaffold(
        appBar: AppBar(
          title: Text(context.l10n.privateMessages_title),
          bottom: TabBar(
            controller: _tabController,
            tabs: [
              Tab(text: context.l10n.privateMessages_inbox),
              Tab(text: context.l10n.privateMessages_sent),
              Tab(text: context.l10n.privateMessages_archive),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            for (final filter in _filters)
              _PrivateMessageTabView(filter: filter),
          ],
        ),
        // 新建私信：此前只能从某个用户的头像菜单发起，对方没在可见处
        // 发过言就完全没有路径。对齐 Discourse 网页版私信列表的入口。
        floatingActionButton: FloatingActionButton(
          heroTag: 'composePm',
          onPressed: _composeNewMessage,
          tooltip: context.l10n.pm_newTitle,
          child: const Icon(Icons.edit_rounded),
        ),
      ),
    );

    // 平行视界：宽屏双栏下私信列表跟话题列表一样，走独立的
    // selectedMessageProvider 导航栈，不再单独弹全屏详情页。
    final canShowDetailPane = MasterDetailLayout.canShowBothPanesFor(context);
    final selectedMessage = ref.watch(selectedMessageProvider);
    _maybePushDetail(selectedMessage, canShowDetailPane);
    _escBinding.sync(
      context,
      paneOpen: canShowDetailPane && selectedMessage.hasSelection,
    );
    if (!canShowDetailPane) return listScaffold;

    // 左栏本质是不是"列表"（私信列表）——决定给窄栏还是对半分。
    final masterIsListLike = !selectedMessage.isStacked;
    return MasterDetailLayout(
      maxMasterRatio: masterIsListLike
          ? MasterDetailLayout.defaultMaxMasterRatio
          : 0.8,
      preferredMasterRatio: masterIsListLike ? 0.25 : 0.5,
      master: _buildMasterPane(selectedMessage, listScaffold),
      detail: selectedMessage.hasSelection
          ? PaneContentWidget(
              key: selectedMessage.kind == PaneKind.topic
                  ? _keyForTopic(selectedMessage.topicId!)
                  : ValueKey('${selectedMessage.kind}_${selectedMessage.username}'),
              entry: selectedMessage.topEntry!,
              stackProvider: selectedMessageProvider,
              parentActive: widget.isActive,
              // 基础层也给 clear：ESC/返回按钮清空右栏回到空态，与
              // search/seeking 一致（平行视界 ESC 统一）。回调内重读
              // provider，不闭包捕获 build 时的快照。
              onBack: () {
                final notifier = ref.read(selectedMessageProvider.notifier);
                if (ref.read(selectedMessageProvider).isStacked) {
                  notifier.pop();
                } else {
                  notifier.clear();
                }
              },
            )
          : null,
    );
  }
}

/// 单个 Tab 的私信列表视图
class _PrivateMessageTabView extends ConsumerStatefulWidget {
  final PrivateMessageFilter filter;

  const _PrivateMessageTabView({required this.filter});

  @override
  ConsumerState<_PrivateMessageTabView> createState() =>
      _PrivateMessageTabViewState();
}

class _PrivateMessageTabViewState extends ConsumerState<_PrivateMessageTabView>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scrollController = ScrollController();
  final LoadMoreCoordinator _loadMoreCoordinator = LoadMoreCoordinator();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 获取当前 tab 对应的数据和 notifier
  (AsyncValue<List<Topic>>, PrivateMessagesNotifier) _watchMessages() {
    return switch (widget.filter) {
      PrivateMessageFilter.inbox => (
        ref.watch(pmInboxProvider),
        ref.watch(pmInboxProvider.notifier),
      ),
      PrivateMessageFilter.sent => (
        ref.watch(pmSentProvider),
        ref.watch(pmSentProvider.notifier),
      ),
      PrivateMessageFilter.archive => (
        ref.watch(pmArchiveProvider),
        ref.watch(pmArchiveProvider.notifier),
      ),
    };
  }

  PrivateMessagesNotifier _readNotifier() {
    return switch (widget.filter) {
      PrivateMessageFilter.inbox => ref.read(pmInboxProvider.notifier),
      PrivateMessageFilter.sent => ref.read(pmSentProvider.notifier),
      PrivateMessageFilter.archive => ref.read(pmArchiveProvider.notifier),
    };
  }

  AsyncValue<List<Topic>> _readMessagesAsync() {
    return switch (widget.filter) {
      PrivateMessageFilter.inbox => ref.read(pmInboxProvider),
      PrivateMessageFilter.sent => ref.read(pmSentProvider),
      PrivateMessageFilter.archive => ref.read(pmArchiveProvider),
    };
  }

  void _onScroll() {
    final distance =
        _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    if (_loadMoreCoordinator.shouldTriggerForDistance(distance)) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    final notifier = _readNotifier();
    await _loadMoreCoordinator.loadMore(
      loadMore: notifier.loadMore,
      hasMore: () => notifier.hasMore,
      isActive: () => mounted,
      progressCount: () => _readMessagesAsync().value?.length ?? 0,
    );
  }

  Future<void> _onRefresh() async {
    _loadMoreCoordinator.resetCooldown();
    await _readNotifier().refresh();
  }

  void _onItemTap(Topic topic) {
    final canShowDetailPane = MasterDetailLayout.canShowBothPanesFor(context);
    if (canShowDetailPane) {
      ref.read(selectedMessageProvider.notifier).select(
            topicId: topic.id,
            initialTitle: topic.title,
            scrollToPostNumber: topic.lastReadPostNumber,
          );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topic.id,
          scrollToPostNumber: topic.lastReadPostNumber,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    // 响应外层派发的快捷动作（只对当前激活 tab 生效：外层按 _tabController.index 派发）
    ref.listen(_pmTabEventProvider(widget.filter), (_, event) {
      if (event == null) return;
      switch (event.action) {
        case _PmTabAction.scrollToTop:
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
          break;
        case _PmTabAction.refresh:
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
          _onRefresh();
          ref.resetNavScrollProgress(NavEntryIds.messages);
          break;
      }
    });

    final (messagesAsync, notifier) = _watchMessages();

    return DesktopRefreshIndicator(
      onRefresh: _onRefresh,
      child: messagesAsync.when(
        data: (topics) {
          if (topics.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Symbols.mail_rounded, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text(
                    context.l10n.privateMessages_empty,
                    style: const TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            controller: _scrollController,
            // 底部让出 extendBody 注入的底栏高度
            padding: EdgeInsets.fromLTRB(
              12,
              12,
              12,
              12 + MediaQuery.paddingOf(context).bottom,
            ),
            itemCount: topics.length + 1,
            itemBuilder: (context, index) {
              if (index == topics.length) {
                return _buildPaginationFooter(notifier);
              }

              final topic = topics[index];
              final enableLongPress = ref
                  .watch(preferencesProvider)
                  .longPressPreview;
              final selectedTopicId = ref.watch(selectedMessageProvider).topicId;
              return buildTopicItem(
                context: context,
                topic: topic,
                isSelected: selectedTopicId == topic.id,
                onTap: () => _onItemTap(topic),
                enableLongPress: enableLongPress,
                // 私信语义同邮件:发件人优先的 Gmail 式布局
                messageStyle: true,
              );
            },
          );
        },
        loading: () => const TopicListSkeleton(messageStyle: true),
        error: (error, stack) =>
            ErrorView(error: error, stackTrace: stack, onRetry: _onRefresh),
      ),
    );
  }

  Widget _buildPaginationFooter(PrivateMessagesNotifier notifier) {
    return PagedListFooter(
      hasMore: notifier.hasMore,
      isLoadingMore: notifier.isLoadingMore,
      isLoadMoreFailed: notifier.isLoadMoreFailed,
      onRetry: notifier.retryLoadMore,
    );
  }
}
