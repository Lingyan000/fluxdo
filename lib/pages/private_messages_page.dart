import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import '../models/topic.dart';
import '../navigation/nav_action_bus.dart';
import '../providers/user_content_providers.dart';
import '../providers/preferences_provider.dart';
import '../utils/load_more_coordinator.dart';
import '../widgets/common/paged_list_footer.dart';
import '../widgets/topic/topic_item_builder.dart';
import '../widgets/topic/topic_list_skeleton.dart';
import '../widgets/post/reply_sheet.dart';
import '../widgets/common/error_view.dart';
import '../widgets/desktop_refresh_indicator.dart';
import '../l10n/s.dart';
import 'topic_detail_page/topic_detail_page.dart';

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

  static const _filters = [
    PrivateMessageFilter.inbox,
    PrivateMessageFilter.sent,
    PrivateMessageFilter.archive,
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _filters.length, vsync: this);
  }

  @override
  void dispose() {
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

    return NotificationListener<ScrollNotification>(
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
              return buildTopicItem(
                context: context,
                topic: topic,
                isSelected: false,
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
