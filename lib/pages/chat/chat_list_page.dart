import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../models/chat/chat_channel.dart';
import '../../models/chat/chat_user.dart';
import '../../providers/chat/chat_channels_provider.dart';
import '../../providers/discourse_providers.dart';
import '../../services/toast_service.dart';
import '../../widgets/common/app_bottom_sheet.dart';
import '../../widgets/common/emoji_text.dart';
import '../../widgets/common/error_view.dart';
import '../../widgets/common/relative_time_text.dart';
import '../../widgets/common/skeleton.dart';
import '../../widgets/common/smart_avatar.dart';
import '../../widgets/desktop_refresh_indicator.dart';
import '../../widgets/layout/master_detail_layout.dart';
import 'chat_browse_channels_page.dart';
import 'chat_search_page.dart';
import 'channel/chat_channel_page.dart';
import 'new_chat_sheet.dart';

/// 桌面双栏下当前选中的会话(仅聊天页内部,不进平行视界栈体系——
/// 聊天窗是常驻会话流,不是"层"语义)
final selectedChatChannelProvider = StateProvider<int?>((ref) => null);

/// 会话列表页(私聊/群聊)
///
/// 移动端:单栏列表,点进全屏聊天窗。
/// 桌面端:MasterDetailLayout 左列表右聊天窗。
class ChatListPage extends ConsumerStatefulWidget {
  const ChatListPage({super.key, this.isActive = true});

  /// 底栏 tab 形态时是否活跃(IndexedStack 常驻页快捷键语义)
  final bool isActive;

  @override
  ConsumerState<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends ConsumerState<ChatListPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: 2,
    vsync: this,
  );

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _openNewChat() async {
    final channel = await showNewChatSheet(context);
    if (channel == null || !mounted) return;
    ref.read(chatChannelsProvider.notifier).upsertChannel(channel);
    _openChannel(channel);
  }

  void _openChannel(ChatChannel channel) {
    final canShowDetailPane = MasterDetailLayout.canShowBothPanesFor(context);
    if (canShowDetailPane) {
      ref.read(selectedChatChannelProvider.notifier).state = channel.id;
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatChannelPage(channelId: channel.id)),
    );
  }

  /// tab 徽章数:私信=unread+mention;频道=仅 mention(官方口径)
  (int, int) _tabBadges(ChatChannelsState state) {
    var channelBadge = 0;
    var dmBadge = 0;
    for (final ch in state.publicChannels) {
      if (ch.currentUserMembership?.muted == true) continue;
      channelBadge += state.tracking[ch.id]?.mentionCount ?? 0;
    }
    for (final ch in state.directMessageChannels) {
      if (ch.currentUserMembership?.muted == true) continue;
      final t = state.tracking[ch.id];
      if (t != null) dmBadge += t.unreadCount + t.mentionCount;
    }
    return (channelBadge, dmBadge);
  }

  /// 长按/右键会话:标记已读 / 静音切换 / 退出
  Future<void> _showChannelMenu(ChatChannel channel) async {
    final muted = channel.currentUserMembership?.muted == true;
    final hasUnread =
        (ref
                .read(chatChannelsProvider)
                .value
                ?.tracking[channel.id]
                ?.unreadCount ??
            0) >
        0;
    final starred = channel.currentUserMembership?.starred == true;
    final action = await AppBottomSheet.show<String>(
      context: context,
      showCloseButton: false,
      contentPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(
              starred ? Symbols.star_rounded : Symbols.star_outline_rounded,
              fill: starred ? 1 : 0,
            ),
            title: Text(
              starred
                  ? sheetContext.l10n.chat_unstar
                  : sheetContext.l10n.chat_star,
            ),
            onTap: () => Navigator.pop(sheetContext, 'star'),
          ),
          if (hasUnread)
            ListTile(
              leading: const Icon(Symbols.mark_chat_read_rounded),
              title: Text(sheetContext.l10n.chat_markRead),
              onTap: () => Navigator.pop(sheetContext, 'read'),
            ),
          ListTile(
            leading: Icon(
              muted
                  ? Symbols.notifications_rounded
                  : Symbols.notifications_off_rounded,
            ),
            title: Text(
              muted
                  ? sheetContext.l10n.chat_unmute
                  : sheetContext.l10n.chat_mute,
            ),
            onTap: () => Navigator.pop(sheetContext, 'mute'),
          ),
          ListTile(
            leading: Icon(
              Symbols.logout_rounded,
              color: Theme.of(sheetContext).colorScheme.error,
            ),
            title: Text(
              channel.isDirectMessage
                  ? sheetContext.l10n.chat_leave
                  : sheetContext.l10n.chat_leaveChannel,
              style: TextStyle(color: Theme.of(sheetContext).colorScheme.error),
            ),
            onTap: () => Navigator.pop(sheetContext, 'leave'),
          ),
        ],
      ),
    );
    if (action == null || !mounted) return;
    final service = ref.read(discourseServiceProvider);
    final notifier = ref.read(chatChannelsProvider.notifier);
    try {
      switch (action) {
        case 'star':
          await service.starChatChannel(channel.id, starred: !starred);
          await notifier.refresh();
        case 'read':
          final lastId = channel.lastMessage?.id;
          if (lastId != null) {
            await service.markChatChannelRead(channel.id, messageId: lastId);
          }
        case 'mute':
          await service.updateChatChannelNotificationsSettings(
            channel.id,
            muted: !muted,
          );
          await notifier.refresh();
        case 'leave':
          await service.leaveChatChannel(channel.id);
          await notifier.refresh();
      }
    } catch (e) {
      ToastService.showError(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final channelsAsync = ref.watch(chatChannelsProvider);
    final selectedId = ref.watch(selectedChatChannelProvider);
    final canShowDetailPane = MasterDetailLayout.canShowBothPanesFor(context);
    final (channelBadge, dmBadge) = channelsAsync.value != null
        ? _tabBadges(channelsAsync.value!)
        : (0, 0);

    final listScaffold = Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.chat_title),
        actions: [
          IconButton(
            icon: const Icon(Symbols.search_rounded),
            tooltip: context.l10n.chat_searchAll,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ChatSearchPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Symbols.explore_rounded),
            tooltip: context.l10n.chat_browseChannels,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ChatBrowseChannelsPage()),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              child: _TabLabel(
                label: context.l10n.chat_sectionChannels,
                badge: channelBadge,
              ),
            ),
            Tab(
              child: _TabLabel(
                label: context.l10n.chat_sectionDirect,
                badge: dmBadge,
              ),
            ),
          ],
        ),
      ),
      body: DesktopRefreshIndicator(
        onRefresh: () => ref.read(chatChannelsProvider.notifier).refresh(),
        // 列表在 TabBarView 内(水平 pager 占 depth 0,频道列表是
        // depth 1),默认 predicate 只认 depth 0 → 下拉永远不触发
        notificationPredicate: (notification) =>
            notification.depth == 1 &&
            notification.metrics.axis == Axis.vertical,
        child: channelsAsync.when(
          data: (state) => TabBarView(
            controller: _tabController,
            children: [
              _ChannelListView(
                channels: state.publicChannels,
                tracking: state.tracking,
                selectedId: canShowDetailPane ? selectedId : null,
                emptyMessage: context.l10n.chat_emptyChannels,
                onTap: _openChannel,
                onLongPress: _showChannelMenu,
              ),
              _ChannelListView(
                channels: state.directMessageChannels,
                tracking: state.tracking,
                selectedId: canShowDetailPane ? selectedId : null,
                emptyMessage: context.l10n.chat_empty,
                onTap: _openChannel,
                onLongPress: _showChannelMenu,
              ),
            ],
          ),
          loading: () => const _ChatListSkeleton(),
          error: (error, stack) => ErrorView(
            error: error,
            stackTrace: stack,
            onRetry: () => ref.read(chatChannelsProvider.notifier).refresh(),
          ),
        ),
      ),
      // 新建会话只对私信有意义;频道 tab 隐藏 FAB
      floatingActionButton: AnimatedBuilder(
        animation: _tabController,
        builder: (context, _) => _tabController.index == 1
            ? FloatingActionButton(
                heroTag: 'newChat',
                onPressed: _openNewChat,
                tooltip: context.l10n.chat_newChat,
                child: const Icon(Symbols.add_comment_rounded),
              )
            : const SizedBox.shrink(),
      ),
    );

    if (!canShowDetailPane) return listScaffold;

    return MasterDetailLayout(
      master: listScaffold,
      detail: selectedId != null
          ? ChatChannelPage(
              key: ValueKey('chat_pane_$selectedId'),
              channelId: selectedId,
              embeddedMode: true,
              onEmbeddedBack: () =>
                  ref.read(selectedChatChannelProvider.notifier).state = null,
            )
          : null,
    );
  }
}

/// tab 标签 + 数字徽章
class _TabLabel extends StatelessWidget {
  final String label;
  final int badge;

  const _TabLabel({required this.label, required this.badge});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        if (badge > 0) ...[
          const SizedBox(width: 6),
          _UnreadPill(text: badge > 99 ? '99+' : '$badge'),
        ],
      ],
    );
  }
}

/// 单 tab 频道列表(分段卡)
class _ChannelListView extends StatelessWidget {
  final List<ChatChannel> channels;
  final Map<int, ChatChannelTracking> tracking;
  final int? selectedId;
  final String emptyMessage;
  final void Function(ChatChannel) onTap;
  final void Function(ChatChannel) onLongPress;

  const _ChannelListView({
    required this.channels,
    required this.tracking,
    required this.selectedId,
    required this.emptyMessage,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    if (channels.isEmpty) {
      return MasterDetailEmptyState(
        icon: Symbols.forum_rounded,
        message: emptyMessage,
      );
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        88 + MediaQuery.paddingOf(context).bottom,
      ),
      itemCount: channels.length,
      itemBuilder: (context, index) {
        final channel = channels[index];
        return Padding(
          padding: EdgeInsets.only(top: index == 0 ? 0 : 3),
          child: SegmentedCardItem(
            index: index,
            count: channels.length,
            child: _ChatChannelTile(
              channel: channel,
              tracking: tracking[channel.id] ?? const ChatChannelTracking(),
              selected: selectedId == channel.id,
              onTap: () => onTap(channel),
              onLongPress: () => onLongPress(channel),
            ),
          ),
        );
      },
    );
  }
}

/// 会话列表单元:头像 + 标题 + 最后消息预览 + 时间 + 未读徽章
class _ChatChannelTile extends StatelessWidget {
  final ChatChannel channel;
  final ChatChannelTracking tracking;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ChatChannelTile({
    required this.channel,
    required this.tracking,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = channel.lastMessage;
    final title = channel.title?.isNotEmpty == true
        ? channel.title!
        : channel.dmUsers.map((u) => u.username).join(', ');

    // 未读指示对齐官方 chat-channel-unread-indicator 口径:
    // urgent(DM 任何未读 / 频道 @提及)→ 数字胶囊;
    // 非 urgent(mention 级频道普通新消息)→ 静默小圆点;muted → 无。
    final muted = channel.currentUserMembership?.muted == true;
    final urgent = muted
        ? 0
        : channel.isDirectMessage
        ? tracking.unreadCount + tracking.mentionCount
        : tracking.mentionCount;
    final silentUnread = !muted && urgent == 0 && tracking.unreadCount > 0;
    final hasAnyUnread = urgent > 0 || silentUnread;

    return Material(
      color: selected
          ? theme.colorScheme.surfaceContainerHighest
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTap: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              ChatChannelAvatar(channel: channel, radius: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (muted) ...[
                                const SizedBox(width: 4),
                                Icon(
                                  Symbols.notifications_off_rounded,
                                  size: 14,
                                  color: theme.colorScheme.outline,
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (last?.createdAt != null) ...[
                          const SizedBox(width: 8),
                          RelativeTimeText(
                            dateTime: last!.createdAt!,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: hasAnyUnread
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.outline,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Expanded(
                          child: EmojiText(
                            chatPreviewText(
                              context,
                              last?.excerpt?.isNotEmpty == true
                                  ? last!.excerpt!
                                  : (last?.message ?? ''),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (urgent > 0) ...[
                          const SizedBox(width: 6),
                          _UnreadPill(
                            text: urgent > 99 ? '99+' : '$urgent',
                            error: !channel.isDirectMessage,
                          ),
                        ] else if (silentUnread) ...[
                          const SizedBox(width: 6),
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.7,
                              ),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 会话头像:1:1 用对端头像;群聊叠两个成员头像;自聊用本人头像
class ChatChannelAvatar extends StatelessWidget {
  final ChatChannel channel;
  final double radius;

  const ChatChannelAvatar({
    super.key,
    required this.channel,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    // 公共频道:分类色圆底 + # 号(Discourse 频道即分类聊天室)
    if (channel.isPublicChannel) {
      final theme = Theme.of(context);
      final colorHex = channel.categoryColor;
      final bg = colorHex != null && colorHex.length >= 6
          ? Color(int.parse('FF${colorHex.substring(0, 6)}', radix: 16))
          : theme.colorScheme.primaryContainer;
      // 分类色亮度决定前景黑白
      final fg = bg.computeLuminance() > 0.55 ? Colors.black87 : Colors.white;
      return CircleAvatar(
        radius: radius,
        backgroundColor: bg,
        child: Text(
          '#',
          style: TextStyle(
            color: fg,
            fontSize: radius * 0.95,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    final users = channel.dmUsers;
    if (!channel.isGroupDm || users.length < 2) {
      final ChatUser? peer = users.firstOrNull;
      return SmartAvatar(
        imageUrl: peer?.getAvatarUrl(size: (radius * 4).round()),
        radius: radius,
        fallbackText: peer?.username ?? channel.title,
      );
    }
    // 群聊:左上大 + 右下小 两枚叠加,右下带底色描边分层
    final size = radius * 2;
    final theme = Theme.of(context);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: SmartAvatar(
              imageUrl: users[0].getAvatarUrl(size: (radius * 3).round()),
              radius: radius * 0.62,
              fallbackText: users[0].username,
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: theme.colorScheme.surfaceContainerLow,
                  width: 2,
                ),
              ),
              child: SmartAvatar(
                imageUrl: users[1].getAvatarUrl(size: (radius * 3).round()),
                radius: radius * 0.62,
                fallbackText: users[1].username,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 未读数胶囊(primary 底)/提及胶囊(error 底)
class _UnreadPill extends StatelessWidget {
  final String text;
  final bool error;

  const _UnreadPill({required this.text, this.error = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      constraints: const BoxConstraints(minWidth: 20),
      decoration: ShapeDecoration(
        color: error ? theme.colorScheme.error : theme.colorScheme.primary,
        shape: const StadiumBorder(),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: theme.textTheme.labelSmall?.copyWith(
          color: error
              ? theme.colorScheme.onError
              : theme.colorScheme.onPrimary,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      ),
    );
  }
}

/// excerpt 可能带 HTML 标签/实体,列表预览做一次粗剥离
String stripHtmlForPreview(String html) {
  return html
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&hellip;', '…')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
}

const _imageExts = {
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'avif', 'heic', 'heif', 'svg', 'bmp',
};

/// 消息预览文本(会话列表/回复引用/搜索等单行场景统一口径):
/// 剥 HTML → 图片/附件 markdown 残渣替换为 [图片]/[文件] 标签
/// (excerpt 对上传消息会留 `[文件名.webp]`/`![alt](url)` 残渣);
/// :shortcode: 保留,由 EmojiText 渲染成 emoji 图。
String chatPreviewText(
  BuildContext context,
  String raw,
) {
  final l10n = context.l10n;
  var text = stripHtmlForPreview(raw);

  String labelFor(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
    return _imageExts.contains(ext)
        ? l10n.chat_previewImage
        : l10n.chat_previewFile;
  }

  // ![alt](url) 图片 markdown(raw message 兜底路径)
  text = text.replaceAllMapped(
    RegExp(r'!\[([^\]]*)\]\([^)]*\)'),
    (m) => l10n.chat_previewImage,
  );
  // [文件名.ext](url) 附件 markdown
  text = text.replaceAllMapped(
    RegExp(r'\[([^\[\]]+?\.[A-Za-z0-9]{1,5})(?:\|[^\]]*)?\]\([^)]*\)'),
    (m) => labelFor(m.group(1)!),
  );
  // excerpt 形态的 [文件名.ext](无链接)
  text = text.replaceAllMapped(
    RegExp(r'\[([^\[\]]+?\.[A-Za-z0-9]{1,5})\]'),
    (m) => labelFor(m.group(1)!),
  );
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 会话列表骨架:分段卡里的头像圆 + 双行占位
class _ChatListSkeleton extends StatelessWidget {
  const _ChatListSkeleton();

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        itemCount: 8,
        itemBuilder: (context, index) => Padding(
          padding: EdgeInsets.only(top: index == 0 ? 0 : 3),
          child: SegmentedCardItem(
            index: index,
            count: 8,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  SkeletonCircle(size: 48),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonBox(width: 140, height: 14, borderRadius: 7),
                        SizedBox(height: 8),
                        SkeletonBox(
                          width: double.infinity,
                          height: 12,
                          borderRadius: 6,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
