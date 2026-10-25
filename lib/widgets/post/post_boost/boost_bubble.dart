import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import '../../../l10n/s.dart';
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
  /// 选中态:气泡末尾显示「@」回复按钮(参考 Web 端选中 boost 后的
  /// mention 按钮),仅单 boost 气泡支持
  final bool selected;
  final VoidCallback? onMentionTap;

  const BoostBubble({
    super.key,
    required this.boost,
    this.onTap,
    this.onLongPress,
    this.onTapWithContext,
    this.onLongPressWithContext,
    this.selected = false,
    this.onMentionTap,
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
    this.selected = false,
    this.onMentionTap,
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
    final mentionEnabled = selected && onMentionTap != null;

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
            color: selected
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.45)
                : theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.4,
                  ),
            borderRadius: BorderRadius.circular(12),
            border: selected
                ? Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.6))
                : null,
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
              if (mentionEnabled) ...[
                const SizedBox(width: 4),
                _BoostMentionButton(
                  username: boost!.user.username,
                  onTap: onMentionTap!,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 选中 boost 气泡末尾的「@」回复按钮(对应 Web 端选中气泡后追加的
/// mention 按钮):点击后引用该 boost 并 @ 其作者。
class _BoostMentionButton extends StatelessWidget {
  final String username;
  final VoidCallback onTap;

  const _BoostMentionButton({required this.username, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: context.l10n.boost_replyMentionTip(username),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.5),
            ),
          ),
          child: Text(
            '@',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              height: 1,
              color: theme.colorScheme.primary,
            ),
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
