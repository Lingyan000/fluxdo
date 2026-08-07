import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../models/chat/chat_channel.dart';
import '../../providers/chat/chat_channels_provider.dart';
import '../../providers/chat/chat_messages_provider.dart';
import '../../providers/discourse_providers.dart';
import '../../services/preloaded_data_service.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';
import '../../widgets/common/app_bottom_sheet.dart';
import '../../widgets/common/smart_avatar.dart';
import '../user_profile_page.dart';
import 'chat_list_page.dart' show ChatChannelAvatar;
import 'channel/chat_channel_page.dart';
import 'chat_channel_members_page.dart';
import 'new_chat_sheet.dart' show showUserPickerSheet;

/// 会话详情页:群聊=成员管理;1:1=对端资料入口。
/// 点聊天窗 AppBar 标题进入。
class ChatChannelInfoPage extends ConsumerStatefulWidget {
  final int channelId;

  const ChatChannelInfoPage({super.key, required this.channelId});

  @override
  ConsumerState<ChatChannelInfoPage> createState() =>
      _ChatChannelInfoPageState();
}

class _ChatChannelInfoPageState extends ConsumerState<ChatChannelInfoPage> {
  /// 前几位成员(详情页摘要行头像预览用;完整列表在成员页)
  List<ChatChannelMember>? _members;

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  ChatChannel? get _channel {
    final state = ref.read(chatChannelsProvider).value;
    if (state == null) return null;
    // DM 与公共频道都可能进详情(之前只查 DM,频道详情永远转圈)
    return [
      ...state.directMessageChannels,
      ...state.publicChannels,
    ].where((c) => c.id == widget.channelId).firstOrNull;
  }

  Future<void> _loadMembers() async {
    try {
      final service = ref.read(discourseServiceProvider);
      final members = await service.getChatChannelMembers(widget.channelId);
      if (mounted) setState(() => _members = members);
    } catch (_) {
      // 预览缺席无害
    }
  }

  Future<void> _rename() async {
    final channel = _channel;
    if (channel == null) return;
    final controller = TextEditingController(text: channel.title ?? '');
    final name = await showAppDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.chat_renameGroup),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 100,
          decoration: InputDecoration(
            hintText: dialogContext.l10n.chat_groupNameHint,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(dialogContext.l10n.common_cancel),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: Text(dialogContext.l10n.common_confirm),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final service = ref.read(discourseServiceProvider);
      await service.updateChatChannel(widget.channelId, name: name);
      // 改名广播走 /chat/channel-edits;本地先行更新列表
      await ref.read(chatChannelsProvider.notifier).refresh();
      if (mounted) setState(() {});
    } catch (e) {
      ToastService.showError(e.toString());
    }
  }

  Future<void> _addMembers() async {
    final selected = await showUserPickerSheet(
      context,
      title: S.current.chat_addMembers,
      confirmLabel: (count) => S.current.chat_addMembersConfirm(count),
    );
    if (selected == null || selected.isEmpty || !mounted) return;
    try {
      final service = ref.read(discourseServiceProvider);
      await service.addChatChannelMembers(
        widget.channelId,
        selected.map((u) => u.username).toList(),
      );
      ToastService.showSuccess(S.current.chat_membersAdded);
      await _loadMembers();
    } catch (e) {
      ToastService.showError(e.toString());
    }
  }

  /// 1:1 升级群聊:官方语义是"创建一个新的群 DM 频道"(原对端 + 新人),
  /// 原 1:1 历史不迁移;成功后直接进新群
  Future<void> _upgradeToGroup() async {
    final channel = _channel;
    final peer = channel?.dmUsers.firstOrNull;
    if (peer == null) return;
    final selected = await showUserPickerSheet(
      context,
      title: S.current.chat_addMembers,
      confirmLabel: (count) => S.current.chat_addMembersConfirm(count),
    );
    if (selected == null || selected.isEmpty || !mounted) return;
    try {
      final service = ref.read(discourseServiceProvider);
      final newChannel = await service.createDirectMessageChannel(
        targetUsernames: [peer.username, ...selected.map((u) => u.username)],
      );
      await ref.read(chatChannelsProvider.notifier).refresh();
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ChatChannelPage(channelId: newChannel.id),
        ),
      );
    } catch (e) {
      ToastService.showError(e.toString());
    }
  }

  /// 历史保留时长:DM 走 chat_dm_retention_days,频道走
  /// chat_channel_retention_days(client 可见站点设置);0=永久
  String _retentionLabel(BuildContext context, ChatChannel channel) {
    final settings = PreloadedDataService().siteSettingsSync;
    final key = channel.isDirectMessage
        ? 'chat_dm_retention_days'
        : 'chat_channel_retention_days';
    final raw = settings?[key];
    final days = raw is int ? raw : int.tryParse(raw?.toString() ?? '') ?? 0;
    return days <= 0
        ? context.l10n.chat_retentionForever
        : context.l10n.chat_retentionDays(days);
  }

  Widget _sectionLabel(ThemeData theme, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        label,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Future<void> _setThreading(bool enabled) async {
    // 乐观:channel-edits 广播不带 threading_enabled,等 refresh 有可视延迟;
    // 先本地 patch 立即生效(开关/回复分流马上按新值走),失败回滚
    final notifier = ref.read(chatChannelsProvider.notifier);
    notifier.bumpChannel(
      widget.channelId,
      update: (ch) => ch.copyWith(threadingEnabled: enabled),
    );
    if (mounted) setState(() {});
    try {
      await ref
          .read(discourseServiceProvider)
          .updateChatChannel(widget.channelId, threadingEnabled: enabled);
      // threading 改变消息组织形态(回复归串/平铺),已加载的消息窗口
      // 是旧形态——整流重载,返回聊天窗立即是新形态,不用退出重进
      ref.invalidate(chatMessagesProvider);
    } catch (e) {
      notifier.bumpChannel(
        widget.channelId,
        update: (ch) => ch.copyWith(threadingEnabled: !enabled),
      );
      if (mounted) setState(() {});
      ToastService.showError(e.toString());
    }
  }

  Future<void> _setMuted(bool muted) async {
    try {
      await ref
          .read(discourseServiceProvider)
          .updateChatChannelNotificationsSettings(
            widget.channelId,
            muted: muted,
          );
      await ref.read(chatChannelsProvider.notifier).refresh();
      if (mounted) setState(() {});
    } catch (e) {
      ToastService.showError(e.toString());
    }
  }

  String _levelLabel(BuildContext context, String? level) {
    return switch (level) {
      'never' => context.l10n.chat_levelNever,
      'mention' => context.l10n.chat_levelMention,
      'always' => context.l10n.chat_levelAlways,
      _ => context.l10n.chat_levelMention,
    };
  }

  Future<void> _pickNotificationLevel() async {
    final current = _channel?.currentUserMembership?.notificationLevel;
    final picked = await AppBottomSheet.show<String>(
      context: context,
      title: S.current.chat_notificationLevel,
      showCloseButton: false,
      contentPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final level in const ['never', 'mention', 'always'])
            ListTile(
              title: Text(_levelLabel(sheetContext, level)),
              trailing: current == level
                  ? Icon(
                      Symbols.check_rounded,
                      color: Theme.of(sheetContext).colorScheme.primary,
                    )
                  : null,
              onTap: () => Navigator.pop(sheetContext, level),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    try {
      await ref
          .read(discourseServiceProvider)
          .updateChatChannelNotificationsSettings(
            widget.channelId,
            notificationLevel: picked,
          );
      await ref.read(chatChannelsProvider.notifier).refresh();
      if (mounted) setState(() {});
    } catch (e) {
      ToastService.showError(e.toString());
    }
  }

  Future<void> _leave() async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.chat_leaveConfirm),
        content: Text(dialogContext.l10n.chat_leaveHint),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(dialogContext.l10n.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              dialogContext.l10n.chat_leave,
              style: TextStyle(
                color: Theme.of(dialogContext).colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final service = ref.read(discourseServiceProvider);
      await service.leaveChatChannel(widget.channelId);
      await ref.read(chatChannelsProvider.notifier).refresh();
      if (mounted) {
        // 退到会话列表(弹掉详情页 + 聊天窗)
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (e) {
      ToastService.showError(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // watch 列表使改名/成员数变化实时反映
    ref.watch(chatChannelsProvider);
    final channel = _channel;

    if (channel == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: LoadingSpinner()),
      );
    }

    final title = channel.title?.isNotEmpty == true
        ? channel.title!
        : channel.dmUsers.map((u) => u.username).join(', ');

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.chat_channelInfo)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          // 头部:头像 + 标题
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Column(
              children: [
                ChatChannelAvatar(channel: channel, radius: 40),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (channel.isGroupDm) ...[
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(Symbols.edit_rounded, size: 18),
                        visualDensity: VisualDensity.compact,
                        onPressed: _rename,
                        tooltip: context.l10n.chat_renameGroup,
                      ),
                    ],
                  ],
                ),
                if (channel.isGroupDm || channel.isPublicChannel)
                  Text(
                    context.l10n.chat_memberCount(
                      channel.isPublicChannel
                          ? (channel.membershipsCount ?? 0)
                          : (_members?.length ?? channel.membershipsCount ?? 0),
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                // 公共频道描述
                if (channel.isPublicChannel &&
                    channel.description?.isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                    child: Text(
                      channel.description!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 频道信息:所属类别(公共频道) + 历史保留时长
          SegmentedCardGroup(
            children: [
              if (channel.isPublicChannel &&
                  channel.categoryName?.isNotEmpty == true)
                ListTile(
                  leading: const Icon(Symbols.category_rounded),
                  title: Text(context.l10n.chat_infoCategory),
                  trailing: Text(
                    channel.categoryName!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ListTile(
                leading: const Icon(Symbols.history_rounded),
                title: Text(context.l10n.chat_infoRetention),
                trailing: Text(
                  _retentionLabel(context, channel),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 成员区:摘要行进完整成员页(搜索/分页/踢人在里面),
          // 管理动作独立成行 —— 不再内嵌大列表
          if (channel.isGroupDm || channel.isPublicChannel) ...[
            _sectionLabel(theme, context.l10n.chat_members),
            SegmentedCardGroup(
              children: [
                ListTile(
                  leading: const Icon(Symbols.group_rounded),
                  title: Text(context.l10n.chat_viewMembers),
                  subtitle: Text(
                    context.l10n.chat_memberCount(
                      channel.membershipsCount ?? _members?.length ?? 0,
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 前几位成员头像预览(叠排)
                      if (_members?.isNotEmpty == true)
                        SizedBox(
                          width: 20.0 * (_members!.take(4).length + 1),
                          height: 28,
                          child: Stack(
                            children: [
                              for (var i = 0; i < _members!.take(4).length; i++)
                                Positioned(
                                  left: i * 20.0,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: theme
                                            .colorScheme
                                            .surfaceContainerLow,
                                        width: 2,
                                      ),
                                    ),
                                    child: SmartAvatar(
                                      imageUrl: _members![i].user.getAvatarUrl(
                                        size: 64,
                                      ),
                                      radius: 12,
                                      fallbackText: _members![i].user.username,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      const Icon(Symbols.chevron_right_rounded, size: 20),
                    ],
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChatChannelMembersPage(
                        channelId: widget.channelId,
                        canRemoveMembers:
                            channel.isGroupDm && channel.canRemoveMembers,
                      ),
                    ),
                  ),
                ),
                if (channel.isGroupDm)
                  ListTile(
                    leading: const Icon(Symbols.person_add_rounded),
                    title: Text(context.l10n.chat_addMembers),
                    onTap: _addMembers,
                  ),
              ],
            ),
          ] else if (channel.dmUsers.isNotEmpty) ...[
            // 1:1:对端资料入口 + 拉人升级群
            SegmentedCardGroup(
              children: [
                ListTile(
                  leading: SmartAvatar(
                    imageUrl: channel.dmUsers.first.getAvatarUrl(size: 96),
                    radius: 20,
                    fallbackText: channel.dmUsers.first.username,
                  ),
                  title: Text(channel.dmUsers.first.username),
                  subtitle: channel.dmUsers.first.name?.isNotEmpty == true
                      ? Text(channel.dmUsers.first.name!)
                      : null,
                  trailing: const Icon(Symbols.chevron_right_rounded),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => UserProfilePage(
                        username: channel.dmUsers.first.username,
                      ),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Symbols.group_add_rounded),
                  title: Text(context.l10n.chat_upgradeToGroup),
                  subtitle: Text(
                    context.l10n.chat_upgradeToGroupHint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  onTap: _upgradeToGroup,
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          // 对话设置(网页版同款:免打扰 + 通知级别)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              context.l10n.chat_settingsSection,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SegmentedCardGroup(
            children: [
              SwitchListTile(
                secondary: const Icon(Symbols.notifications_off_rounded),
                title: Text(context.l10n.chat_muteChannel),
                value: channel.currentUserMembership?.muted == true,
                onChanged: (v) => _setMuted(v),
              ),
              // 消息串开关(DM 成员可改;公共频道需管理权限,失败弹错)
              SwitchListTile(
                secondary: const Icon(Symbols.forum_rounded),
                title: Text(context.l10n.chat_threadingEnabled),
                subtitle: Text(
                  context.l10n.chat_threadingHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                value: channel.threadingEnabled,
                onChanged: (v) => _setThreading(v),
              ),
              ListTile(
                leading: const Icon(Symbols.notifications_rounded),
                title: Text(context.l10n.chat_notificationLevel),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _levelLabel(
                        context,
                        channel.currentUserMembership?.notificationLevel,
                      ),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Icon(Symbols.chevron_right_rounded, size: 20),
                  ],
                ),
                onTap: _pickNotificationLevel,
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 危险区:退出会话
          SegmentedCardGroup(
            children: [
              ListTile(
                leading: Icon(
                  Symbols.logout_rounded,
                  color: theme.colorScheme.error,
                ),
                title: Text(
                  context.l10n.chat_leave,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                onTap: _leave,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
