import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/chat/chat_models.dart';
import '../../providers/chat_providers.dart';
import '../../providers/core_providers.dart';
import '../../widgets/common/emoji_text.dart';
import '../../widgets/common/error_view.dart';
import 'chat_message_page.dart';

/// 频道浏览页面
///
/// 展示论坛中所有可用的聊天频道，支持按状态（全部/开放/已关闭）筛选，
/// 可搜索频道名称，并支持加入/退出频道。
///
/// 对齐 Discourse chat-channel-card / toggle-channel-membership-button：
/// - 已加入：显示「退出」（unfollow，非破坏性）
/// - 未加入且可加入：显示「加入」
/// - 已关闭/归档：灰色样式，不可新加入
class ChatBrowseChannelsPage extends ConsumerStatefulWidget {
  const ChatBrowseChannelsPage({super.key});

  @override
  ConsumerState<ChatBrowseChannelsPage> createState() =>
      _ChatBrowseChannelsPageState();
}

class _ChatBrowseChannelsPageState
    extends ConsumerState<ChatBrowseChannelsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  /// Tab 对应的 status 值：null=全部, 'open'=开放, 'closed'=已关闭
  static const List<String?> _statusFilters = [null, 'open', 'closed'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this, initialIndex: 1);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('浏览频道'),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '全部'),
            Tab(text: '开放'),
            Tab(text: '已关闭'),
          ],
        ),
      ),
      body: Column(
        children: [
          // 搜索栏
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索频道...',
                prefixIcon: const Icon(Symbols.search_rounded, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Symbols.close_rounded, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHigh,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (val) {
                setState(() => _searchQuery = val.trim());
              },
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: _statusFilters.map((status) {
                return _BrowseChannelListView(
                  status: status,
                  searchQuery: _searchQuery,
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

/// 频道列表视图
class _BrowseChannelListView extends ConsumerWidget {
  final String? status;
  final String searchQuery;

  const _BrowseChannelListView({
    this.status,
    this.searchQuery = '',
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final params = BrowseChannelsParams(
      status: status,
      filter: searchQuery.isNotEmpty ? searchQuery : null,
    );
    final channelsAsync = ref.watch(browseChannelsProvider(params));

    // 我的频道列表中 following 的 id，作为 browse 响应缺 membership 时的兜底
    final followedIds = <int>{};
    final currentChannels = ref.watch(chatChannelsProvider).value;
    if (currentChannels != null) {
      for (final c in currentChannels.publicChannels) {
        if (c.following || c.isJoined) followedIds.add(c.id);
      }
    }

    return channelsAsync.when(
      data: (channels) {
        if (channels.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  searchQuery.isNotEmpty
                      ? Symbols.search_off_rounded
                      : Symbols.forum_rounded,
                  size: 64,
                  color: theme.colorScheme.onSurfaceVariant
                      .withValues(alpha: 0.5),
                ),
                const SizedBox(height: 16),
                Text(
                  searchQuery.isNotEmpty ? '没有找到匹配的频道' : '暂无频道',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(browseChannelsProvider(params));
            ref.invalidate(chatChannelsProvider);
          },
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: channels.length,
            itemBuilder: (context, index) {
              final channel = channels[index];
              // 优先用频道自身 current_user_membership.following
              final isJoined = channel.following || followedIds.contains(channel.id);
              return _BrowseChannelTile(
                key: ValueKey('browse-channel-${channel.id}'),
                channel: channel,
                isJoined: isJoined,
                browseParams: params,
              );
            },
          ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => ErrorView(
        error: error,
        stackTrace: stack,
        onRetry: () {
          ref.invalidate(browseChannelsProvider(params));
        },
      ),
    );
  }
}

/// 频道列表项组件
class _BrowseChannelTile extends ConsumerStatefulWidget {
  final ChatChannel channel;
  final bool isJoined;
  final BrowseChannelsParams browseParams;

  const _BrowseChannelTile({
    super.key,
    required this.channel,
    required this.isJoined,
    required this.browseParams,
  });

  @override
  ConsumerState<_BrowseChannelTile> createState() => _BrowseChannelTileState();
}

class _BrowseChannelTileState extends ConsumerState<_BrowseChannelTile> {
  bool _isBusy = false;
  /// 本地乐观覆盖：null 表示用 widget.isJoined
  bool? _localJoined;

  bool get _isJoined => _localJoined ?? widget.isJoined;

  bool get _isClosedOrArchived =>
      widget.channel.isClosed || widget.channel.isArchived;

  bool get _isJoinable => widget.channel.isJoinable;

  Future<void> _joinChannel() async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    try {
      final service = ref.read(discourseServiceProvider);
      await service.joinChannel(widget.channel.id);
      ref.invalidate(chatChannelsProvider);
      ref.invalidate(browseChannelsProvider(widget.browseParams));
      if (mounted) {
        setState(() => _localJoined = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已加入频道「${widget.channel.title ?? ''}」')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加入失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  /// 浏览页退出对齐官方：非破坏性 unfollow（memberships/me/follows）
  Future<void> _leaveChannel() async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    try {
      final service = ref.read(discourseServiceProvider);
      await service.unfollowChannel(widget.channel.id);
      ref.invalidate(chatChannelsProvider);
      ref.invalidate(browseChannelsProvider(widget.browseParams));
      if (mounted) {
        setState(() => _localJoined = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已退出频道「${widget.channel.title ?? ''}」')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('退出失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  void _openChannel() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatMessagePage(
          channelId: widget.channel.id,
          channelTitle: widget.channel.title ?? '未命名频道',
        ),
      ),
    );
  }

  Widget _buildLeading(BuildContext context, {required bool dimmed}) {
    final theme = Theme.of(context);
    final bg = dimmed
        ? theme.colorScheme.surfaceContainerHighest
        : theme.colorScheme.primaryContainer;
    final fg = dimmed
        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.55)
        : theme.colorScheme.onPrimaryContainer;

    final emojiCode = widget.channel.emojiShortcode;
    if (emojiCode != null && emojiCode.isNotEmpty) {
      return CircleAvatar(
        radius: 22,
        backgroundColor: bg,
        child: Opacity(
          opacity: dimmed ? 0.55 : 1,
          child: EmojiText(
            emojiCode,
            style: const TextStyle(fontSize: 20),
          ),
        ),
      );
    }

    return CircleAvatar(
      radius: 22,
      backgroundColor: bg,
      child: Icon(
        _isClosedOrArchived ? Icons.lock_outline_rounded : AppIcons.forum,
        size: 24,
        color: fg,
      ),
    );
  }

  String _statusLabel() {
    if (widget.channel.isArchived) return '已归档';
    if (widget.channel.isClosed) return '已关闭';
    if (widget.channel.isReadOnly) return '只读';
    return '';
  }

  String _membersLabel() {
    final count = widget.channel.membersCount;
    if (count == null) return '成员数未知';
    return '$count 位成员';
  }

  Widget _buildTrailing(ThemeData theme) {
    if (_isBusy) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    // 对齐 Discourse chat-channel-card：已加入只显示「退出」，点整行进入频道。
    // 切勿同时显示「进入」+「退出」。
    if (_isJoined) {
      return OutlinedButton(
        onPressed: _leaveChannel,
        style: OutlinedButton.styleFrom(
          foregroundColor: theme.colorScheme.error,
          side: BorderSide(
            color: theme.colorScheme.error.withValues(alpha: 0.5),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          visualDensity: VisualDensity.compact,
        ),
        child: const Text('退出'),
      );
    }

    // 未加入：仅 open 且未归档可加入
    if (_isJoinable) {
      return FilledButton(
        onPressed: _joinChannel,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          visualDensity: VisualDensity.compact,
        ),
        child: const Text('加入'),
      );
    }

    // 已关闭/归档/只读：不可加入，但仍可点进只读浏览（若曾加入则走上方分支）
    return Text(
      _statusLabel().isNotEmpty ? _statusLabel() : '不可加入',
      style: theme.textTheme.labelMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final channel = widget.channel;
    final dimmed = _isClosedOrArchived;
    final mutedStyle = dimmed
        ? theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.65),
          )
        : theme.textTheme.titleMedium;
    final subColor = dimmed
        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.55)
        : theme.colorScheme.onSurfaceVariant;

    return Opacity(
      opacity: dimmed ? 0.72 : 1,
      child: ListTile(
        leading: _buildLeading(context, dimmed: dimmed),
        title: Row(
          children: [
            Expanded(
              child: Text(
                channel.title ?? '未命名频道',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mutedStyle,
              ),
            ),
            if (_statusLabel().isNotEmpty) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _statusLabel(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (channel.description != null && channel.description!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  channel.description!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: subColor),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Icon(
                    Icons.people_outline_rounded,
                    size: 14,
                    color: subColor,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _membersLabel(),
                    style: theme.textTheme.labelSmall?.copyWith(color: subColor),
                  ),
                  if (channel.threadingEnabled) ...[
                    const SizedBox(width: 12),
                    Icon(
                      Icons.forum_outlined,
                      size: 14,
                      color: subColor,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '消息串',
                      style:
                          theme.textTheme.labelSmall?.copyWith(color: subColor),
                    ),
                  ],
                  if (_isJoined) ...[
                    const SizedBox(width: 12),
                    Icon(
                      Icons.check_circle_outline_rounded,
                      size: 14,
                      color: theme.colorScheme.primary.withValues(
                        alpha: dimmed ? 0.55 : 1,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '已加入',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary.withValues(
                          alpha: dimmed ? 0.55 : 1,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        trailing: _buildTrailing(theme),
        // 已加入可进入；未加入但可预览的频道（关闭/归档）也允许只读打开
        onTap: (_isJoined || _isClosedOrArchived || widget.channel.isReadOnly)
            ? _openChannel
            : null,
        isThreeLine:
            channel.description != null && channel.description!.isNotEmpty,
      ),
    );
  }
}
