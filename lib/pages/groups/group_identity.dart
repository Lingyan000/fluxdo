import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../models/user_group.dart';
import '../../widgets/common/flair_badge.dart';

/// 目录与详情共用组标识，缺少徽标时用名称首字帮助区分。
class GroupAvatar extends StatelessWidget {
  const GroupAvatar({super.key, required this.group, this.size = 48});

  final UserGroupDetail group;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = group.displayName.trim();
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          shape: RoundedSuperellipseBorder(
            borderRadius: context.shapes.borderRadius(14),
          ),
        ),
        child: group.flairUrl?.isNotEmpty == true
            ? FlairBadge(
                flairName: group.group.name,
                flairUrl: group.flairUrl,
                flairColor: group.flairColor,
                flairBgColor: group.flairBackground,
                size: size * 0.65,
              )
            : Text(
                name.isEmpty ? '#' : name.characters.first.toUpperCase(),
                style: theme.textTheme.titleLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
      ),
    );
  }
}

class GroupMembershipLabel extends StatelessWidget {
  const GroupMembershipLabel({super.key, required this.group});

  final UserGroupDetail group;

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (group) {
      UserGroupDetail(isOwner: true) => (
        Symbols.shield_person_rounded,
        context.l10n.group_owner,
      ),
      UserGroupDetail(isMember: true) => (
        Symbols.check_circle_rounded,
        context.l10n.group_joined,
      ),
      UserGroupDetail(automatic: true) => (
        Symbols.manage_accounts_rounded,
        context.l10n.group_automaticGroups,
      ),
      UserGroupDetail(publicAdmission: true) => (
        Symbols.group_add_rounded,
        context.l10n.group_openAdmission,
      ),
      UserGroupDetail(allowMembershipRequests: true) => (
        Symbols.person_add_rounded,
        context.l10n.group_request,
      ),
      _ => (Symbols.lock_outline_rounded, context.l10n.group_invitationOnly),
    };
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 16,
          color: group.isMember || group.isOwner
              ? context.emphasis.selected
              : theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Flexible(child: Text(label, style: theme.textTheme.labelMedium)),
      ],
    );
  }
}
