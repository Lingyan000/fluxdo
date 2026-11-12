import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../models/category.dart';
import '../../models/user.dart';
import '../../models/topic.dart';
import '../../models/user_group.dart';
import '../../providers/selected_topic_provider.dart';
import '../../utils/category_navigation.dart';
import '../../utils/color_utils.dart';
import '../../utils/link_launcher.dart';
import '../../widgets/common/relative_time_text.dart';
import '../../widgets/common/smart_avatar.dart';
import '../../widgets/user/activity_post_card.dart';

/// 表头和成员行共享列宽、间距及断点，排序按钮的反馈区域留在各自列内。
class GroupMemberColumns extends StatelessWidget {
  const GroupMemberColumns({
    super.key,
    required this.children,
    this.cellPadding = const EdgeInsets.symmetric(horizontal: 8),
  }) : assert(children.length == 4);

  final List<Widget> children;
  final EdgeInsetsGeometry cellPadding;

  static bool isWide(BuildContext context, double width) =>
      width >= 680 && MediaQuery.textScalerOf(context).scale(14) < 22;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (var index = 0; index < children.length; index++) ...[
        if (index > 0) const SizedBox(width: 16),
        Expanded(
          flex: index == 0 ? 3 : 1,
          child: Padding(padding: cellPadding, child: children[index]),
        ),
      ],
    ],
  );
}

class GroupMemberTile extends StatelessWidget {
  const GroupMemberTile({
    super.key,
    required this.user,
    required this.owner,
    required this.position,
    this.joinedAt,
  });

  final ({int index, int count}) position;
  final User user;
  final bool owner;
  final DateTime? joinedAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dates = [
      (Symbols.login_rounded, context.l10n.group_joinedAt, joinedAt),
      (
        Symbols.chat_bubble_outline_rounded,
        context.l10n.userProfile_lastPosted,
        user.lastPostedAt,
      ),
      (
        Symbols.schedule_rounded,
        context.l10n.userProfile_lastSeen,
        user.lastSeenAt,
      ),
    ];
    final identity = Row(
      children: [
        SmartAvatar(
          imageUrl: user.getAvatarUrl(size: 96),
          radius: 20,
          fallbackText: user.username,
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
          foregroundColor: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                user.name?.isNotEmpty == true ? user.name! : user.username,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              Text(
                '@${user.username}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (owner)
          Tooltip(
            message: context.l10n.group_owner,
            child: Icon(
              Symbols.shield_person_rounded,
              size: 20,
              color: context.emphasis.accent,
            ),
          ),
      ],
    );
    return InkWell(
      onTap: () => EmbeddedStackScope.openProfile(context, user.username),
      borderRadius: SegmentedCardItem.borderRadiusOf(
        context,
        index: position.index,
        count: position.count,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = GroupMemberColumns.isWide(
              context,
              constraints.maxWidth,
            );
            if (wide) {
              return GroupMemberColumns(
                children: [
                  identity,
                  for (final (_, _, date) in dates)
                    date == null
                        ? Text(
                            context.l10n.common_unknown,
                            style: theme.textTheme.bodySmall,
                          )
                        : RelativeTimeText(
                            dateTime: date,
                            style: theme.textTheme.bodySmall,
                          ),
                ],
              );
            }
            final metadata = [
              for (final (icon, label, date) in dates)
                if (date != null)
                  Tooltip(
                    message: label,
                    child: Semantics(
                      label: label,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            icon,
                            size: 14,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: RelativeTimeText(
                              dateTime: date,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
            ];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                identity,
                if (metadata.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(spacing: 16, runSpacing: 8, children: metadata),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class GroupPostTile extends StatelessWidget {
  const GroupPostTile({
    super.key,
    required this.post,
    required this.position,
    this.category,
    this.categories = const {},
  });

  final ({int index, int count}) position;
  final GroupActivityPost post;
  final Category? category;
  final Map<int, Category> categories;

  @override
  Widget build(BuildContext context) => ActivityPostCard(
    position: position,
    title: post.title,
    author: TopicUser(
      id: post.user.id,
      username: post.user.username,
      name: post.user.name,
      avatarTemplate: post.user.avatarTemplate ?? '',
    ),
    actionLabel: post.postNumber == 1
        ? context.l10n.userProfile_actionCreatedTopic
        : context.l10n.common_reply,
    actionIcon: post.postNumber == 1
        ? Symbols.article_rounded
        : Symbols.reply_rounded,
    occurredAt: post.createdAt,
    postNumber: post.postNumber,
    excerpt: post.excerpt,
    categoryId: post.categoryId,
    categories: {...categories, ?category?.id: ?category},
    onTap: () =>
        launchContentLink(context, '/t/${post.topicId}/${post.postNumber}'),
  );
}

class GroupCategoryLabel extends StatelessWidget {
  const GroupCategoryLabel({super.key, required this.category});
  final Category category;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        Symbols.circle,
        size: 8,
        color: ColorUtils.category(category.color, Theme.of(context)),
      ),
      const SizedBox(width: 8),
      Flexible(
        child: Text(
          category.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelLarge,
        ),
      ),
    ],
  );
}

class GroupPermissionTile extends StatelessWidget {
  const GroupPermissionTile({
    super.key,
    required this.permission,
    required this.position,
  });
  final ({int index, int count}) position;
  final GroupCategoryPermission permission;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = switch (permission.type) {
      1 => context.l10n.group_permissionFull,
      2 => context.l10n.group_permissionReply,
      3 => context.l10n.group_permissionRead,
      _ => context.l10n.group_permissionOther,
    };
    final icon = switch (permission.type) {
      1 => Symbols.edit_note_rounded,
      2 => Symbols.forum_rounded,
      3 => Symbols.visibility_rounded,
      _ => Symbols.folder_open_rounded,
    };
    return InkWell(
      onTap: () => openCategoryPage(
        context,
        permission.category.id,
        useWorkspace: false,
      ),
      borderRadius: SegmentedCardItem.borderRadiusOf(
        context,
        index: position.index,
        count: position.count,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide =
                constraints.maxWidth >= 680 &&
                MediaQuery.textScalerOf(context).scale(14) < 22;
            return Row(
              children: [
                Icon(icon, size: 24, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GroupCategoryLabel(category: permission.category),
                      if (!wide) ...[
                        const SizedBox(height: 6),
                        Text(
                          label,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (wide) ...[
                  const SizedBox(width: 24),
                  Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(width: 12),
                const Icon(Symbols.chevron_right_rounded, size: 20),
              ],
            );
          },
        ),
      ),
    );
  }
}
