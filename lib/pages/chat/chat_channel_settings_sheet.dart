import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../models/chat/chat_models.dart';
import '../../models/emoji.dart';
import '../../models/user.dart';
import '../../providers/chat_providers.dart';
import '../../providers/core_providers.dart';
import '../../services/preloaded_data_service.dart';
import '../../widgets/common/emoji_text.dart';
import '../../widgets/markdown_editor/emoji_sticker_panel.dart';
import 'chat_channel_members_sheet.dart';

/// 聊天频道设置 Sheet 弹窗
class ChatChannelSettingsSheet extends ConsumerStatefulWidget {
  final int channelId;
  final String channelTitle;

  const ChatChannelSettingsSheet({
    super.key,
    required this.channelId,
    required this.channelTitle,
  });

  static void show(BuildContext context, int channelId, String channelTitle) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => ChatChannelSettingsSheet(
        channelId: channelId,
        channelTitle: channelTitle,
      ),
    );
  }

  @override
  ConsumerState<ChatChannelSettingsSheet> createState() =>
      _ChatChannelSettingsSheetState();
}

class _ChatChannelSettingsSheetState
    extends ConsumerState<ChatChannelSettingsSheet> {
  bool _isSaving = false;

  /// 本地乐观覆盖的通知级别（避免 invalidate 前 UI 不刷新）
  String? _localNotificationLevel;
  bool? _localMuted;

  Future<void> _updateMute(ChatChannel channel, bool newMuted) async {
    setState(() {
      _isSaving = true;
      _localMuted = newMuted;
    });
    try {
      final service = ref.read(discourseServiceProvider);
      await service.updateChannelNotificationsSettings(
        widget.channelId,
        muted: newMuted,
      );
      ref.invalidate(chatChannelsProvider);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(newMuted ? '已开启免打扰' : '已关闭免打扰')));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _localMuted = channel.muted);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('设置失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// 通知级别：never / mention / always
  Future<void> _updateNotificationLevel(
    ChatChannel channel,
    String level,
  ) async {
    setState(() {
      _isSaving = true;
      _localNotificationLevel = level;
    });
    try {
      final service = ref.read(discourseServiceProvider);
      final membership = await service.updateChannelNotificationsSettings(
        widget.channelId,
        notificationLevel: level,
      );
      // 若服务端回写了 membership，再对齐一次本地值
      if (membership != null) {
        final serverLevel = membership['notification_level'];
        if (serverLevel is String) {
          _localNotificationLevel = serverLevel;
        } else if (serverLevel is num) {
          _localNotificationLevel = switch (serverLevel.toInt()) {
            0 => 'never',
            1 => 'mention',
            2 => 'always',
            _ => level,
          };
        }
      }
      ref.invalidate(chatChannelsProvider);
      if (mounted) {
        final label = switch (level) {
          'never' => '从不',
          'always' => '全部消息',
          _ => '仅提及',
        };
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('通知级别已设为「$label」')));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _localNotificationLevel = channel.notificationLevel);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('设置失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showNotificationLevelPicker(ChatChannel channel) {
    final current =
        _localNotificationLevel ?? channel.notificationLevel ?? 'mention';
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text(
                  '通知级别',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              for (final entry in const [
                ('never', '从不', '不接收该频道推送'),
                ('mention', '仅提及', '仅在被 @ 时通知'),
                ('always', '全部消息', '该频道每条新消息都通知'),
              ])
                ListTile(
                  leading: Icon(
                    current == entry.$1
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: current == entry.$1
                        ? Theme.of(ctx).colorScheme.primary
                        : null,
                  ),
                  title: Text(entry.$2),
                  subtitle: Text(entry.$3),
                  onTap: () {
                    Navigator.pop(ctx);
                    _updateNotificationLevel(channel, entry.$1);
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _updateThreading(ChatChannel channel, bool newThreading) async {
    setState(() => _isSaving = true);
    // 先乐观更新频道列表，让消息页立刻按消息串风格渲染
    ref
        .read(chatChannelsProvider.notifier)
        .setThreadingEnabledLocally(widget.channelId, newThreading);
    try {
      final service = ref.read(discourseServiceProvider);
      await service.updateChannel(
        widget.channelId,
        threadingEnabled: newThreading,
      );
      // 后台对齐服务端状态（静默刷新，避免 loading 闪一下）
      unawaited(ref.read(chatChannelsProvider.notifier).refreshSilently());
      // 开启后消息序列化才会带 thread / thread_id，需重拉消息列表
      unawaited(
        ref
            .read(chatMessagesProvider(widget.channelId).notifier)
            .loadMessages(preferLatest: true),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(newThreading ? '已开启消息串' : '已关闭消息串')),
        );
      }
    } catch (e) {
      // 失败回滚
      ref
          .read(chatChannelsProvider.notifier)
          .setThreadingEnabledLocally(
            widget.channelId,
            channel.threadingEnabled,
          );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('设置失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showEditChannelDialog(ChatChannel? channel) {
    final titleController = TextEditingController(
      text: channel?.title ?? widget.channelTitle,
    );
    final slugController = TextEditingController(text: channel?.slug ?? '');
    var selectedEmoji = ChatChannel.normalizeEmojiShortcode(channel?.emoji);

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            void openEmojiPicker() {
              showModalBottomSheet<void>(
                context: ctx,
                isScrollControlled: true,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                ),
                builder: (sheetCtx) => SizedBox(
                  height: MediaQuery.of(sheetCtx).size.height * 0.45,
                  child: EmojiStickerPanel(
                    onEmojiSelected: (Emoji emoji) {
                      Navigator.pop(sheetCtx);
                      setDialogState(() {
                        selectedEmoji = ChatChannel.normalizeEmojiShortcode(
                          emoji.name,
                        );
                      });
                    },
                    onStickerSelected: (_) {},
                    onBackspace: null,
                  ),
                ),
              );
            }

            final previewCode = ChatChannel.toEmojiTextCode(selectedEmoji);

            return AlertDialog(
              title: const Text('编辑频道信息'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(
                        labelText: '频道名称',
                        hintText: '请输入频道名称',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: slugController,
                      decoration: const InputDecoration(
                        labelText: '频道缩略名 (Slug)',
                        hintText: '例如: general',
                      ),
                    ),
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '频道表情图标',
                        style: Theme.of(ctx).textTheme.labelLarge,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Material(
                          color: Theme.of(ctx).colorScheme.primaryContainer,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: openEmojiPicker,
                            child: SizedBox(
                              width: 56,
                              height: 56,
                              child: Center(
                                child: previewCode != null
                                    ? EmojiText(
                                        previewCode,
                                        style: const TextStyle(fontSize: 26),
                                      )
                                    : Icon(
                                        Icons.add_reaction_outlined,
                                        color: Theme.of(
                                          ctx,
                                        ).colorScheme.onPrimaryContainer,
                                      ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        if (selectedEmoji != null)
                          IconButton(
                            tooltip: '清除表情',
                            onPressed: () {
                              setDialogState(() => selectedEmoji = null);
                            },
                            icon: Icon(
                              Icons.close_rounded,
                              color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    setState(() => _isSaving = true);
                    try {
                      final service = ref.read(discourseServiceProvider);
                      final emojiToSave = selectedEmoji ?? '';
                      await service.updateChannel(
                        widget.channelId,
                        name: titleController.text.trim(),
                        slug: slugController.text.trim(),
                        emoji: emojiToSave,
                      );
                      ref.invalidate(chatChannelsProvider);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('频道信息已成功更新')),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text('更新失败: $e')));
                      }
                    } finally {
                      if (mounted) setState(() => _isSaving = false);
                    }
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _channelTypeLabel(ChatChannel? channel) {
    if (channel == null) return '未知';
    if (channel.isDirectMessage) {
      return channel.isGroupDm ? '群组直接消息' : '直接消息';
    }
    if (channel.isCategoryChannel) return '公开频道';
    return channel.chatableType ?? '频道';
  }

  String _statusLabel(ChatChannel? channel) {
    if (channel == null) return '';
    if (channel.isArchived) return '已归档';
    if (channel.isClosed) return '已关闭';
    if (channel.isReadOnly) return '只读';
    return '开放';
  }

  /// 设置页「离开」标题：私聊 / 群聊 / 公开频道文案区分。
  String _leaveActionTitle(ChatChannel channel) {
    final l10n = context.l10n;
    if (channel.isDirectMessage) {
      return channel.isGroupDm ? l10n.chat_leave_group : l10n.chat_leave_dm;
    }
    return l10n.chat_leave_channel;
  }

  String _leaveActionSubtitle(ChatChannel channel) {
    if (channel.isDirectMessage) {
      return channel.isGroupDm
          ? '离开后不再是成员，需再次邀请才能加入'
          : '离开后从列表移除；对方再发消息时可能重新出现';
    }
    return '离开后可在浏览频道页重新加入';
  }

  String _leaveConfirmMessage(ChatChannel channel) {
    final l10n = context.l10n;
    if (channel.isDirectMessage) {
      return channel.isGroupDm
          ? l10n.chat_leave_confirm_group
          : l10n.chat_leave_confirm_dm;
    }
    return l10n.chat_leave_confirm_channel;
  }

  /// 对齐 Discourse 设置页 `leaveDestructive=true`：
  /// 统一走 `Chat::LeaveChannel`（`DELETE .../memberships/me`）。
  /// 服务端按频道类型分流：
  /// - 群组 DM：删除 membership + 从 DM 用户列表移除
  /// - 1:1 私聊 / 公开频道：等价于 unfollow（following=false）
  Future<void> _confirmAndLeave(ChatChannel channel) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_leaveActionTitle(channel)),
        content: Text(_leaveConfirmMessage(channel)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.chat_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.chat_leave),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isSaving = true);
    try {
      // 设置页始终 destructive leave API（与 channel-info-settings 一致）
      await ref.read(leaveChannelProvider(widget.channelId).future);

      if (!mounted) return;
      final title = channel.title ?? widget.channelTitle;
      final messenger = ScaffoldMessenger.of(context);
      // 设置 sheet 是 modal route；再 pop 一层回到频道列表（离开消息页）。
      final nav = Navigator.of(context);
      nav.pop(); // 关闭 settings sheet
      if (nav.canPop()) {
        nav.pop(); // 离开 ChatMessagePage
      }
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.chat_leave_success(title))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.chat_leave_failed('$e'))));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentUser = ref.watch(currentUserProvider).value;
    final isStaff = currentUser is User ? currentUser.isStaff : false;

    final channelsAsync = ref.watch(chatChannelsProvider);
    ChatChannel? channel;
    if (channelsAsync.value != null) {
      final all = [
        ...channelsAsync.value!.publicChannels,
        ...channelsAsync.value!.directMessageChannels,
      ];
      try {
        channel = all.firstWhere((c) => c.id == widget.channelId);
      } catch (_) {}
    }

    final canAddMembers = channel?.canAddMembers ?? false;
    final canEdit = channel?.canEditChannel(isStaff: isStaff) ?? isStaff;
    final mutedValue = _localMuted ?? channel?.muted ?? false;
    final notifLevel =
        _localNotificationLevel ?? channel?.notificationLevel ?? 'mention';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(top: 4, bottom: 12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.4,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // 频道标题与类型图标/表情（无权限时不显示编辑按钮）
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: () {
                    final code = channel?.emojiShortcode;
                    if (code != null && code.isNotEmpty) {
                      return EmojiText(
                        code,
                        style: const TextStyle(fontSize: 20),
                      );
                    }
                    return Icon(
                      channel?.isDirectMessage == true
                          ? Icons.alternate_email_rounded
                          : Icons.tag_rounded,
                      color: theme.colorScheme.onPrimaryContainer,
                      size: 22,
                    );
                  }(),
                ),
                title: Text(
                  channel?.title ?? widget.channelTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: Text(
                  [
                    if (channel?.description != null &&
                        channel!.description!.isNotEmpty)
                      channel.description!
                    else
                      null,
                    '类型: ${_channelTypeLabel(channel)}',
                    if (_statusLabel(channel).isNotEmpty)
                      '状态: ${_statusLabel(channel)}',
                    'ID: ${widget.channelId}',
                  ].whereType<String>().join(' · '),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                trailing: canEdit
                    ? IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: '编辑频道信息',
                        onPressed: _isSaving
                            ? null
                            : () => _showEditChannelDialog(channel),
                      )
                    : null,
              ),

              const Divider(height: 1),

              SwitchListTile(
                secondary: Icon(
                  mutedValue
                      ? Icons.notifications_off_rounded
                      : Icons.notifications_none_rounded,
                  color: mutedValue ? theme.colorScheme.error : null,
                ),
                title: const Text('免打扰'),
                subtitle: const Text('开启后静音该频道的提醒推送'),
                value: mutedValue,
                onChanged: _isSaving || channel == null
                    ? null
                    : (val) => _updateMute(channel!, val),
              ),

              ListTile(
                leading: const Icon(Icons.notifications_active_outlined),
                title: const Text('通知级别'),
                subtitle: Text(switch (notifLevel) {
                  'never' => '从不',
                  'always' => '全部消息',
                  'mention' => '仅提及',
                  _ => '仅提及（默认）',
                }),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _isSaving || channel == null
                    ? null
                    : () => _showNotificationLevelPicker(channel!),
              ),

              // 消息串仅对有编辑权限的用户可改；无权限只展示状态
              if (canEdit)
                SwitchListTile(
                  secondary: Icon(
                    Icons.forum_outlined,
                    color: channel?.threadingEnabled == true
                        ? theme.colorScheme.primary
                        : null,
                  ),
                  title: const Text('消息串 (Thread)'),
                  subtitle: const Text('允许针对单条消息开启独立讨论子串'),
                  value: channel?.threadingEnabled ?? false,
                  onChanged: _isSaving || channel == null
                      ? null
                      : (val) => _updateThreading(channel!, val),
                )
              else
                ListTile(
                  leading: const Icon(Icons.forum_outlined),
                  title: const Text('消息串 (Thread)'),
                  trailing: Text(
                    (channel?.threadingEnabled ?? false) ? '已开启' : '已关闭',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),

              const Divider(height: 1),

              Builder(
                builder: (context) {
                  final settings =
                      PreloadedDataService().siteSettingsSync ?? const {};
                  final channelDays =
                      (settings['chat_channel_retention_days'] as num?)
                          ?.toInt();
                  final dmDays = (settings['chat_dm_retention_days'] as num?)
                      ?.toInt();
                  final text =
                      channel?.retentionDisplay(
                        channelRetentionDays: channelDays,
                        dmRetentionDays: dmDays,
                      ) ??
                      '永久保留';
                  return ListTile(
                    leading: const Icon(Icons.history_toggle_off_rounded),
                    title: const Text('历史消息保留时长'),
                    subtitle: const Text('由站点设置控制，超过周期的历史消息将被清理'),
                    trailing: Text(
                      text,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  );
                },
              ),

              // 仅有编辑权限时显示「编辑频道属性」入口；双人私聊无修改权限,不显示
              if (canEdit &&
                  !(channel?.isDirectMessage == true &&
                      channel?.isGroupDm != true))
                ListTile(
                  leading: const Icon(Icons.tune_rounded),
                  title: const Text('编辑频道属性'),
                  subtitle: const Text('修改频道名称、缩略名及自定义图标'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _isSaving
                      ? null
                      : () => _showEditChannelDialog(channel),
                )
              else
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text('频道信息'),
                  subtitle: Text(
                    [
                      '类型: ${_channelTypeLabel(channel)}',
                      '状态: ${_statusLabel(channel)}',
                      if (channel?.slug != null && channel!.slug!.isNotEmpty)
                        '缩略名: ${channel.slug}',
                    ].join(' · '),
                  ),
                ),

              ListTile(
                leading: const Icon(Icons.group_outlined),
                title: Text(context.l10n.chat_channel_members),
                subtitle: Text(() {
                  final count = channel?.membersCount;
                  if (count != null) return '$count 位成员';
                  return '查看并管理频道成员';
                }()),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () {
                  Navigator.pop(context);
                  ChatChannelMembersSheet.show(
                    context,
                    widget.channelId,
                    widget.channelTitle,
                    canAddMembers: canAddMembers,
                    membersCountHint: channel?.membersCount,
                  );
                },
              ),

              if (canAddMembers)
                ListTile(
                  leading: Icon(
                    Icons.person_add_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  title: Text(
                    context.l10n.chat_add_member,
                    style: TextStyle(color: theme.colorScheme.primary),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    ChatChannelMembersSheet.show(
                      context,
                      widget.channelId,
                      widget.channelTitle,
                      canAddMembers: true,
                      membersCountHint: channel?.membersCount,
                    );
                  },
                ),

              // 离开：私聊/群聊/公开频道均可；语义对齐 Discourse toggle-channel-membership
              if (channel != null && channel.isJoined) ...[
                const Divider(height: 1),
                ListTile(
                  leading: Icon(
                    Icons.logout_rounded,
                    color: theme.colorScheme.error,
                  ),
                  title: Text(
                    _leaveActionTitle(channel),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  subtitle: Text(_leaveActionSubtitle(channel)),
                  onTap: _isSaving ? null : () => _confirmAndLeave(channel!),
                ),
              ],

              if (_isSaving)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Center(child: CircularProgressIndicator()),
                ),

              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}
