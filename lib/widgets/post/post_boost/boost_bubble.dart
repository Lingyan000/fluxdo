import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import '../../../models/topic.dart';
import '../../common/emoji_text.dart';
import '../../common/smart_avatar.dart';
import '../../../utils/url_helper.dart';
import 'boost_content.dart';

/// 单个 Boost 气泡
class BoostBubble extends StatelessWidget {
  final Boost? boost;
  final BoostGroup? group;
  final bool expanded;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final void Function(BuildContext bubbleContext)? onTapWithContext;
  final void Function(BuildContext bubbleContext)? onLongPressWithContext;

  const BoostBubble({
    super.key,
    required this.boost,
    this.onTap,
    this.onLongPress,
    this.onTapWithContext,
    this.onLongPressWithContext,
  }) : group = null,
       expanded = false;

  const BoostBubble.group({
    super.key,
    required this.group,
    this.expanded = false,
    this.onTap,
    this.onLongPress,
    this.onTapWithContext,
    this.onLongPressWithContext,
  }) : boost = null;

  @override
  Widget build(BuildContext context) {
    if (group != null) {
      return _GroupedBoostBubble(
        group: group!,
        expanded: expanded,
        onTap: onTap,
        onLongPress: onLongPress,
        onTapWithContext: onTapWithContext,
        onLongPressWithContext: onLongPressWithContext,
      );
    }

    final theme = Theme.of(context);
    final parsed = BoostContentParser.parse(boost!.cooked);
    final displayText = parsed.displayText.isNotEmpty
        ? parsed.displayText
        : 'Boost';

    return Builder(
      builder: (bubbleContext) => GestureDetector(
        onTap: onTapWithContext == null
            ? onTap
            : () => onTapWithContext!(bubbleContext),
        onLongPress: onLongPressWithContext == null
            ? onLongPress
            : () => onLongPressWithContext!(bubbleContext),
        child: Container(
          padding: const EdgeInsets.only(left: 3, top: 3, bottom: 3, right: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.4,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SmartAvatar(
                imageUrl: boost!.user.avatarTemplate.isNotEmpty
                    ? UrlHelper.resolveUrlWithCdn(
                        boost!.user.avatarTemplate.replaceAll('{size}', '48'),
                      )
                    : null,
                radius: 10,
                fallbackText: boost!.user.username,
              ),
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: EmojiText(
                  displayText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                    height: 1.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupedBoostBubble extends StatelessWidget {
  final BoostGroup group;
  final bool expanded;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final void Function(BuildContext bubbleContext)? onTapWithContext;
  final void Function(BuildContext bubbleContext)? onLongPressWithContext;

  const _GroupedBoostBubble({
    required this.group,
    required this.expanded,
    this.onTap,
    this.onLongPress,
    this.onTapWithContext,
    this.onLongPressWithContext,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayText = group.displayText.isNotEmpty
        ? group.displayText
        : 'Boost';
    final avatars = _uniqueUsers(group.boosts);

    return Builder(
      builder: (bubbleContext) => GestureDetector(
        onTap: onTapWithContext == null
            ? onTap
            : () => onTapWithContext!(bubbleContext),
        onLongPress: onLongPressWithContext == null
            ? onLongPress
            : () => onLongPressWithContext!(bubbleContext),
        child: Container(
          padding: const EdgeInsets.only(left: 3, top: 3, bottom: 3, right: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.4,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _AvatarStack(users: avatars),
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: EmojiText(
                  displayText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                    height: 1.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${group.count}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 10,
                    height: 1.1,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                expanded ? Symbols.keyboard_arrow_up_rounded : Symbols.keyboard_arrow_down_rounded,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<BoostUser> _uniqueUsers(List<Boost> boosts) {
    final usersById = <int, BoostUser>{};
    for (final boost in boosts) {
      usersById.putIfAbsent(boost.user.id, () => boost.user);
    }
    return usersById.values.toList(growable: false);
  }
}

class _AvatarStack extends StatelessWidget {
  final List<BoostUser> users;

  const _AvatarStack({required this.users});

  @override
  Widget build(BuildContext context) {
    final visibleUsers = users.take(3).toList(growable: false);
    final avatarCount = visibleUsers.length;
    final totalWidth = avatarCount <= 1
        ? 20.0
        : 20.0 + (avatarCount - 1) * 12.0;

    return SizedBox(
      width: totalWidth,
      height: 20,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < visibleUsers.length; i++)
            Positioned(
              left: i * 12.0,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.surface,
                    width: 1.5,
                  ),
                ),
                child: SmartAvatar(
                  imageUrl: visibleUsers[i].avatarTemplate.isNotEmpty
                      ? UrlHelper.resolveUrlWithCdn(
                          visibleUsers[i].avatarTemplate.replaceAll(
                            '{size}',
                            '48',
                          ),
                        )
                      : null,
                  radius: 10,
                  fallbackText: visibleUsers[i].username,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
