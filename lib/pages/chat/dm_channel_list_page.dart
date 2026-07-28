import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../constants.dart';
import '../../models/chat/chat_channel.dart';
import '../../providers/core_providers.dart';
import '../../providers/message_bus/chat_providers.dart';
import '../../providers/selected_topic_provider.dart';
import '../../utils/time_utils.dart';
import '../../widgets/common/smart_avatar.dart';
import '../../widgets/common/error_view.dart';
import '../../widgets/common/user_status_icon.dart';
import '../../widgets/desktop_refresh_indicator.dart';
import '../../widgets/layout/master_detail_layout.dart';
import '../../widgets/layout/pane_empty_state.dart';
import '../../widgets/post/pm_recipient_field.dart';
import '../topics_screen.dart' show PaneContentWidget;
import 'chat_search_dialog.dart';
import 'dm_channel_detail_page.dart';

/// Chat 插件 DM 频道列表页,与"私信"入口平级。
///
/// 平行视界:宽屏双栏下跟私信列表一样,走独立的 [selectedChatProvider]
/// 导航栈,不再单独弹全屏详情页(对齐 `private_messages_page.dart` 的
/// 做法);窄屏保持原来的 `Navigator.push` 全屏详情页。
class DmChannelListPage extends ConsumerStatefulWidget {
  const DmChannelListPage({super.key, this.isActive = true});

  final bool isActive;

  @override
  ConsumerState<DmChannelListPage> createState() => _DmChannelListPageState();
}

class _DmChannelListPageState extends ConsumerState<DmChannelListPage> {
  Key _keyForChat(int channelId) => ValueKey('chat_$channelId');

  /// 平行视界压栈时:左侧显示栈里"上一层"内容,右侧显示新顶替的内容。
  Widget _buildMasterPane(SelectedTopicState selectedChat, Widget list) {
    if (!selectedChat.isStacked) return list;
    final previous = selectedChat.stack[selectedChat.stack.length - 2];
    return Stack(
      children: [
        Offstage(offstage: true, child: list),
        PaneContentWidget(
          key: previous.kind == PaneKind.chat
              ? _keyForChat(previous.chatChannelId!)
              : ValueKey('master_${previous.kind}_${previous.username}'),
          entry: previous,
          stackProvider: selectedChatProvider,
          truncateOnPush: true,
          parentActive: widget.isActive,
        ),
      ],
    );
  }

  /// 新建聊天:目前只能从某个用户的资料卡"聊天"按钮发起,对方没在可见
  /// 处发过言就完全没有路径。对齐私信列表页 FAB 的入口设计。
  Future<void> _composeNewChat() async {
    final recipients = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => const _NewChatDialog(),
    );
    if (recipients == null || recipients.isEmpty || !mounted) return;
    try {
      final service = ref.read(discourseServiceProvider);
      final channel = await service.createOrGetDirectMessageChannel(recipients);
      if (!mounted) return;
      ref.read(chatChannelListProvider.notifier).refresh();
      final currentUsername = ref.read(currentUserProvider).value?.username;
      final other = currentUsername != null
          ? channel.otherParticipant(currentUsername)
          : channel.participants.firstOrNull;
      final title = channel.isGroup
          ? (channel.title ?? '群聊')
          : (other?.name ?? other?.username);
      _openChannel(channel.id, title);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('创建聊天失败: $e')),
      );
    }
  }

  /// 全局搜索聊天消息(官方 `GET /chat/api/search`,含公共频道和私聊),
  /// 点结果直接进对应频道。
  Future<void> _searchChats() async {
    final picked = await showChatSearchDialog(context);
    if (picked == null || !mounted) return;
    _openChannel(picked.channelId, picked.channelTitle);
  }

  /// 浏览可加入的公共频道:关键词搜索 + 一键加入,加入后整表刷新。
  Future<void> _browsePublicChannels() async {
    final joined = await showDialog<bool>(
      context: context,
      builder: (ctx) => const _BrowseChannelsDialog(),
    );
    if (joined == true && mounted) {
      unawaited(ref.read(chatChannelListProvider.notifier).refresh());
    }
  }

  /// 点列表里的一项(切换到另一个频道):跟私信列表页 `_onItemTap` 同一套
  /// 语义——**替换**当前显示的内容,不是压栈。压栈是"从正文内容里跳转"
  /// 才该有的行为(比如聊天气泡里点头像跳资料);在列表本身点另一项,
  /// 用户心智是"看列表里的另一条",每点一次都多叠一层平行视界的话,
  /// 栈会无限增长,`_buildMasterPane` 只处理得了一层"上一层"缓存,
  /// 栈深超过 2 之后右栏该显示哪层就会错乱。
  void _openChannel(int channelId, String? title) {
    final canShowDetailPane = MasterDetailLayout.canShowBothPanesFor(context);
    if (canShowDetailPane) {
      ref.read(selectedChatProvider.notifier).selectChat(channelId, title: title);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DmChannelDetailPage(channelId: channelId, title: title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 激活全局未读追踪订阅(离开此页仍由导航徽标那侧的 watch 保活)
    ref.watch(chatTrackingChannelProvider);
    final channelsAsync = ref.watch(chatChannelListProvider);
    final currentUsername = ref.watch(
      currentUserProvider.select((s) => s.value?.username),
    );

    final listScaffold = DefaultTabController(
      length: 2,
      // 有私聊在聊、公共频道多数人没加入:默认落在"直接消息"标签
      initialIndex: 1,
      child: Scaffold(
      appBar: AppBar(
        title: const Text('聊天'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: '搜索聊天',
            icon: const Icon(Icons.search_rounded),
            onPressed: _searchChats,
          ),
          IconButton(
            tooltip: '浏览公共频道',
            icon: const Icon(Icons.explore_outlined),
            onPressed: _browsePublicChannels,
          ),
        ],
        // 顶栏 Tab 切换公共频道 / 直接消息(对齐官方网页端的两个分组)
        bottom: const TabBar(
          tabs: [
            Tab(text: '频道'),
            Tab(text: '直接消息'),
          ],
        ),
      ),
      body: channelsAsync.when(
        data: (channels) {
          // 各组内收藏的置顶,组内保持原有(最近消息时间倒序)顺序不变——
          // List.sort 不保证稳定,手动分组拼接才能保住组内原序。
          List<ChatChannel> starredFirst(Iterable<ChatChannel> group) => [
                ...group.where((c) => c.membership.starred),
                ...group.where((c) => !c.membership.starred),
              ];
          final publicChannels =
              starredFirst(channels.where((c) => !c.isDirectMessage));
          final dmChannels =
              starredFirst(channels.where((c) => c.isDirectMessage));

          Widget channelList(List<ChatChannel> group, String emptyHint) {
            if (group.isEmpty) {
              return Center(
                child: Text(emptyHint, style: const TextStyle(color: Colors.grey)),
              );
            }
            return DesktopRefreshIndicator(
              onRefresh: () =>
                  ref.read(chatChannelListProvider.notifier).refresh(),
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
                itemCount: group.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: SegmentedCardItem(
                    index: index,
                    count: group.length,
                    child: _DmChannelTile(
                      channel: group[index],
                      currentUsername: currentUsername,
                      onTap: _openChannel,
                    ),
                  ),
                ),
              ),
            );
          }

          return TabBarView(
            children: [
              channelList(publicChannels, '还没加入任何公共频道\n点右上角的指南针浏览并加入'),
              channelList(dmChannels, '暂无私聊消息'),
            ],
          );
        },
        loading: () => const Center(child: LoadingSpinner()),
        error: (error, stack) => ErrorView(
          error: error,
          stackTrace: stack,
          onRetry: () => ref.read(chatChannelListProvider.notifier).refresh(),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'composeChat',
        onPressed: _composeNewChat,
        tooltip: '新建聊天',
        child: const Icon(Icons.edit_rounded),
      ),
      ),
    );

    final canShowDetailPane = MasterDetailLayout.canShowBothPanesFor(context);
    final selectedChat = ref.watch(selectedChatProvider);
    if (!canShowDetailPane) return listScaffold;

    // 单层(左列表右聊天)时列表窄一点好看;一旦压栈(左边变成话题等
    // 正文内容)就回到 1:1——不然从私聊里点话题、再点新话题后,左栏的
    // 话题被挤成私聊列表那么窄。
    final masterRatio = selectedChat.isStacked ? 0.5 : 0.32;

    return EmbeddedStackScope(
      stackProvider: selectedChatProvider,
      child: MasterDetailLayout(
        preferredMasterRatio: masterRatio,
        master: _buildMasterPane(selectedChat, listScaffold),
        detail: selectedChat.hasSelection
            ? PaneContentWidget(
                key: selectedChat.kind == PaneKind.chat
                    ? _keyForChat(selectedChat.topEntry!.chatChannelId!)
                    : ValueKey('${selectedChat.kind}_${selectedChat.username}'),
                entry: selectedChat.topEntry!,
                stackProvider: selectedChatProvider,
                parentActive: widget.isActive,
                // onBack 也是 Esc 的落点,单层时给 null 等于第一层按 Esc
                // 没反应——单层就关掉右栏(同 private_messages_page.dart)。
                onBack: () {
                  final notifier = ref.read(selectedChatProvider.notifier);
                  selectedChat.isStacked ? notifier.pop() : notifier.clear();
                },
              )
            : null,
        emptyDetail: const PaneEmptyState(
          icon: Icons.chat_bubble_outline_rounded,
          hint: '选择一个聊天查看消息',
        ),
      ),
    );
  }
}

class _DmChannelTile extends StatelessWidget {
  const _DmChannelTile({
    required this.channel,
    this.currentUsername,
    required this.onTap,
  });

  final ChatChannel channel;
  final String? currentUsername;
  final void Function(int channelId, String? title) onTap;

  @override
  Widget build(BuildContext context) {
    // 公共频道没有"对方"概念:标题用频道名,头像画个 # 图标
    if (!channel.isDirectMessage) {
      final name = channel.title ?? channel.slug ?? '频道';
      final unread = channel.membership.unreadCount;
      return ListTile(
        leading: CircleAvatar(
          radius: 22,
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Icon(Icons.tag_rounded,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        title: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: unread > 0 ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        subtitle: Text(
          channel.lastMessage?.message ?? channel.description ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              TimeUtils.formatCompactTime(channel.lastMessage?.createdAt),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (unread > 0) ...[
              const SizedBox(height: 4),
              Badge(label: Text(unread > 99 ? '99+' : '$unread')),
            ],
          ],
        ),
        onTap: () => onTap(channel.id, name),
      );
    }

    final other = currentUsername != null
        ? channel.otherParticipant(currentUsername!)
        : channel.participants.firstOrNull;
    final displayName = channel.isGroup
        ? (channel.title ?? '群聊')
        : (other?.name ?? other?.username ?? channel.title ?? '未知用户');
    final unread = channel.membership.unreadCount;

    return ListTile(
      leading: SmartAvatar(
        imageUrl: other?.getAvatarUrl(AppConstants.baseUrl, size: 48),
        radius: 22,
        fallbackText: displayName.isNotEmpty ? displayName[0] : '?',
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: unread > 0 ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          if (other?.status != null) ...[
            const SizedBox(width: 5),
            // 列表行的状态只展示不可点(手机上点到状态会点不进私聊)
            UserStatusIcon(status: other!.status, size: 14),
          ],
        ],
      ),
      subtitle: Text(
        channel.lastMessage?.message ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            TimeUtils.formatCompactTime(channel.lastMessage?.createdAt),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (unread > 0) ...[
            const SizedBox(height: 4),
            Badge(label: Text(unread > 99 ? '99+' : '$unread')),
          ],
        ],
      ),
      onTap: () => onTap(channel.id, displayName),
    );
  }
}

/// 浏览公共频道弹窗:关键词搜索 + 加入。已加入(following)的显示"已加入"。
/// 关闭时若加入过任意频道,pop(true) 让列表页整表刷新。
class _BrowseChannelsDialog extends ConsumerStatefulWidget {
  const _BrowseChannelsDialog();

  @override
  ConsumerState<_BrowseChannelsDialog> createState() => _BrowseChannelsDialogState();
}

class _BrowseChannelsDialogState extends ConsumerState<_BrowseChannelsDialog> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;
  Future<List<ChatChannel>>? _future;
  final Set<int> _joined = {};
  bool _joinedAny = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<List<ChatChannel>> _load() {
    final service = ref.read(discourseServiceProvider);
    return service.browsePublicChatChannels(filter: _searchController.text.trim());
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _future = _load());
    });
  }

  Future<void> _join(ChatChannel channel) async {
    try {
      final service = ref.read(discourseServiceProvider);
      await service.joinChatChannel(channel.id);
      if (!mounted) return;
      setState(() {
        _joined.add(channel.id);
        _joinedAny = true;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加入频道失败: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('浏览公共频道'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              autofocus: true,
              onChanged: _onSearchChanged,
              decoration: const InputDecoration(
                hintText: '搜索频道…',
                prefixIcon: Icon(Icons.search_rounded),
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: FutureBuilder<List<ChatChannel>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: LoadingSpinner());
                  }
                  if (snapshot.hasError) {
                    return Center(child: Text('加载失败: ${snapshot.error}'));
                  }
                  final channels = snapshot.data ?? const [];
                  if (channels.isEmpty) {
                    return const Center(
                      child: Text('没有找到频道', style: TextStyle(color: Colors.grey)),
                    );
                  }
                  return ListView.builder(
                    itemCount: channels.length,
                    itemBuilder: (context, index) {
                      final channel = channels[index];
                      final following =
                          channel.membership.following || _joined.contains(channel.id);
                      return ListTile(
                        leading: const Icon(Icons.tag_rounded),
                        title: Text(
                          channel.title ?? channel.slug ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: (channel.description ?? '').isEmpty
                            ? null
                            : Text(
                                channel.description!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                        trailing: following
                            ? const Text('已加入', style: TextStyle(color: Colors.grey))
                            : FilledButton.tonal(
                                onPressed: () => _join(channel),
                                child: const Text('加入'),
                              ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_joinedAny),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 新建聊天弹窗:复用私信收件人选择器(用户名搜索 + chip)。
class _NewChatDialog extends StatefulWidget {
  const _NewChatDialog();

  @override
  State<_NewChatDialog> createState() => _NewChatDialogState();
}

class _NewChatDialogState extends State<_NewChatDialog> {
  List<String> _recipients = const [];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建聊天'),
      content: SizedBox(
        width: 360,
        child: PmRecipientField(
          recipients: _recipients,
          onChanged: (value) => setState(() => _recipients = value),
          autofocus: true,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _recipients.isEmpty
              ? null
              : () => Navigator.of(context).pop(_recipients),
          child: const Text('开始聊天'),
        ),
      ],
    );
  }
}
