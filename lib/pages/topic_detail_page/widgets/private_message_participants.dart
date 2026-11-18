import 'package:common_ui/common_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/s.dart';
import '../../../models/topic.dart';
import '../../../providers/discourse_providers.dart';
import '../../../services/toast_service.dart';
import '../../../utils/dialog_utils.dart';
import '../../../widgets/common/smart_avatar.dart';
import '../../../widgets/common/error_view.dart';
import '../../../widgets/user/user_card.dart';
import 'invite_private_message_dialog.dart';

class PrivateMessageMemberSummary extends StatelessWidget {
  static bool isAvailable(TopicDetail detail) =>
      detail.isPrivateMessage &&
      (detail.allowedUsers.isNotEmpty ||
          detail.allowedGroups.isNotEmpty ||
          detail.canInviteTo);

  const PrivateMessageMemberSummary({
    super.key,
    required this.detail,
    required this.onTap,
  });

  final TopicDetail detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const previewLimit = 3;
    final users = detail.allowedUsers.take(previewLimit);
    final groups = detail.allowedGroups.take(previewLimit - users.length);
    final names = [
      for (final user in users) user.displayName,
      for (final group in groups) group.displayName,
    ];
    final remaining =
        detail.allowedUsers.length + detail.allowedGroups.length - names.length;
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final l10n = context.l10n;
    return Tooltip(
      message: l10n.pm_conversationMembers,
      child: InkWell(
        onTap: onTap,
        borderRadius: context.shapes.borderRadius(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            children: [
              for (final user in users)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 2),
                  child: SmartAvatar(
                    radius: 10,
                    backgroundColor: theme.colorScheme.secondaryContainer,
                    foregroundColor: theme.colorScheme.onSecondaryContainer,
                    fallbackText: user.username,
                    imageUrl: user.getAvatarUrl(size: 48),
                  ),
                ),
              for (final _ in groups)
                const Padding(
                  padding: EdgeInsetsDirectional.only(end: 2),
                  child: CircleAvatar(
                    radius: 10,
                    child: Icon(Icons.group_rounded, size: 14),
                  ),
                ),
              if (names.isNotEmpty) const SizedBox(width: 6),
              Expanded(
                child: Text(
                  names.isEmpty
                      ? l10n.pm_conversationMembers
                      : names.join(l10n.pm_memberSeparator),
                  style: style,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (remaining > 0) Text('+$remaining', style: style),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PrivateMessageMembersSheet extends ConsumerStatefulWidget {
  const PrivateMessageMembersSheet({super.key, required this.params});
  final TopicDetailParams params;

  @override
  ConsumerState<PrivateMessageMembersSheet> createState() =>
      _PrivateMessageMembersSheetState();
}

class _PrivateMessageMembersSheetState
    extends ConsumerState<PrivateMessageMembersSheet> {
  bool _inviting = false;
  Object? _removing;

  Future<void> _remove({TopicUser? user, TopicGroup? group}) async {
    if (_removing != null) return;
    final provider = topicDetailProvider(widget.params);
    final detail = ref.read(provider).value;
    if (detail == null) return;
    final self =
        user != null && user.id == ref.read(currentUserProvider).value?.id;
    bool allowed(TopicDetail value) =>
        self ? value.canRemoveSelfId == user.id : value.canRemoveAllowedUsers;
    if (!allowed(detail)) return;

    final l10n = context.l10n;
    final action = self ? l10n.pm_leaveConversation : l10n.common_remove;
    final confirmed = await showAppDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => AlertDialog(
        title: Text(action),
        content: Text(
          self
              ? l10n.topicDetail_leavePrivateMessageConfirm
              : user != null
              ? l10n.topicDetail_removePrivateMessageParticipantConfirm(
                  user.username,
                )
              : l10n.topicDetail_removePrivateMessageGroupConfirm(group!.name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final latest = ref.read(provider).value;
    if (latest == null || !allowed(latest)) return;
    setState(() => _removing = user?.id ?? group!.name);
    try {
      final notifier = ref.read(provider.notifier);
      if (user != null) {
        await notifier.removePrivateMessageParticipant(user);
      } else {
        await notifier.removePrivateMessageGroup(group!);
      }
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      if (self) {
        Navigator.pop(context, true);
      } else {
        ToastService.showSuccess(
          user != null
              ? l10n.topicDetail_removedPrivateMessageParticipant(user.username)
              : l10n.topicDetail_removedPrivateMessageGroup(group!.name),
        );
      }
    } catch (error) {
      if (mounted) {
        ToastService.showError(l10n.common_operationFailed('$error'));
      }
    } finally {
      if (mounted) setState(() => _removing = null);
    }
  }

  Widget _menu(Object id, VoidCallback remove) {
    if (_removing == id) return const LoadingSpinner(size: 20);
    return SwipeDismissiblePopupMenuButton<bool>(
      enabled: _removing == null,
      tooltip: context.l10n.common_more,
      icon: const Icon(Icons.more_horiz_rounded),
      itemBuilder: (ctx) => [
        PopupMenuItem(value: true, child: Text(ctx.l10n.common_remove)),
      ],
      onSelected: (_) => remove(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = topicDetailProvider(widget.params);
    final state = ref.watch(provider);
    final detail = state.value;
    final current = ref.watch(currentUserProvider).value;
    final l10n = context.l10n;
    if (detail == null) {
      return AppSheetScaffold(
        title: l10n.pm_conversationMembers,
        child: state.hasError
            ? ErrorView(
                error: state.error!,
                onRetry: () => ref.invalidate(provider),
              )
            : const Center(child: LoadingSpinner()),
      );
    }
    final canInvite = current != null && detail.canInviteTo;
    if (_inviting && canInvite) {
      return PrivateMessageInviteSheet(
        detail: detail,
        currentUsername: current.username,
        onBack: () => setState(() => _inviting = false),
        search: (term) => ref
            .read(discourseServiceProvider)
            .searchUsers(
              term: term,
              includeGroups: false,
              includeMessageableGroups: true,
              throwOnError: true,
              limit: 12,
            ),
        onInvite: ref
            .read(topicDetailProvider(widget.params).notifier)
            .invitePrivateMessageRecipient,
      );
    }
    final self = detail.allowedUsers
        .where((user) => user.id == current?.id)
        .firstOrNull;
    final canManage = current != null && detail.canRemoveAllowedUsers;
    final groups = detail.allowedGroups;
    final users = detail.allowedUsers;
    final canLeave = self != null && detail.canRemoveSelfId == self.id;
    return PopScope(
      canPop: _removing == null,
      child: AppSheetScaffold(
        title: l10n.pm_conversationMembers,
        contentPadding: EdgeInsets.zero,
        actions: [
          if (canInvite)
            TextButton.icon(
              onPressed: _removing != null
                  ? null
                  : () => setState(() => _inviting = true),
              icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
              label: Text(l10n.pm_inviteParticipants),
            ),
        ],
        child: ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 12),
          itemCount: groups.length + users.length + (canLeave ? 1 : 0),
          itemBuilder: (context, index) {
            if (index < groups.length) {
              final group = groups[index];
              return ListTile(
                leading: const CircleAvatar(child: Icon(Icons.group_rounded)),
                title: Text(group.displayName),
                subtitle: Text(
                  group.displayName == group.name
                      ? l10n.mention_group
                      : '${l10n.mention_group} · ${group.name}',
                ),
                trailing: canManage
                    ? _menu(group.name, () => _remove(group: group))
                    : null,
              );
            }
            if (index == groups.length + users.length) {
              return ListTile(
                leading: const Icon(Icons.logout_rounded),
                title: Text(l10n.pm_leaveConversation),
                trailing: _removing == self!.id
                    ? const LoadingSpinner(size: 20)
                    : null,
                onTap: _removing == null ? () => _remove(user: self) : null,
              );
            }
            final user = users[index - groups.length];
            return Builder(
              builder: (tileContext) => ListTile(
                leading: SmartAvatar(
                  imageUrl: user.getAvatarUrl(size: 80),
                  radius: 20,
                  fallbackText: user.username,
                ),
                title: Text(user.displayName),
                subtitle: Text('@${user.username}'),
                trailing: canManage && user.id != current.id
                    ? _menu(user.id, () => _remove(user: user))
                    : null,
                onTap: !canShowUserCardPreview(context) || _removing != null
                    ? null
                    : () {
                        final box =
                            tileContext.findRenderObject() as RenderBox?;
                        if (box == null || !box.hasSize) return;
                        showUserCard(
                          context: tileContext,
                          anchorRect: box.localToGlobal(Offset.zero) & box.size,
                          username: user.username,
                          topicId: detail.id,
                          topicTitle: detail.title,
                          avatarFallbackUrl: user.getAvatarUrl(size: 144),
                          nameFallback: user.name,
                        );
                      },
              ),
            );
          },
        ),
      ),
    );
  }
}
