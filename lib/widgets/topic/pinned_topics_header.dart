import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../utils/responsive.dart';

/// 置顶话题分组入口，折叠时仍可查看数量并一键已读。
class PinnedTopicsHeader extends StatelessWidget {
  const PinnedTopicsHeader({
    super.key,
    required this.count,
    required this.unreadCount,
    required this.expanded,
    required this.markingRead,
    required this.onToggle,
    this.onMarkRead,
  });

  final int count;
  final int unreadCount;
  final bool expanded;
  final bool markingRead;
  final VoidCallback onToggle;
  final VoidCallback? onMarkRead;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final shape = RoundedSuperellipseBorder(
      borderRadius: expanded
          ? BorderRadius.only(
              topLeft: context.shapes.radius(12),
              topRight: context.shapes.radius(12),
            )
          : context.shapes.borderRadius(12),
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: Breakpoints.maxContentWidth,
        ),
        child: Padding(
          padding: EdgeInsets.only(bottom: expanded ? 0 : 8),
          child: Material(
            color: theme.cardTheme.color ?? colors.surfaceContainerLow,
            shape: shape,
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    button: true,
                    expanded: expanded,
                    child: InkWell(
                      key: const ValueKey('pinned-topics-toggle'),
                      onTap: onToggle,
                      customBorder: shape,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 14,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                context.l10n.topics_pinnedCount(count),
                                style: theme.textTheme.labelLarge,
                              ),
                            ),
                            if (unreadCount > 0) ...[
                              const SizedBox(width: 4),
                              Badge(
                                label: Text(
                                  '$unreadCount',
                                  semanticsLabel: context.l10n
                                      .topics_viewUnreadTopics(unreadCount),
                                ),
                              ),
                            ],
                            const SizedBox(width: 4),
                            AnimatedRotation(
                              turns: expanded ? 0.5 : 0,
                              duration: MediaQuery.disableAnimationsOf(context)
                                  ? Duration.zero
                                  : const Duration(milliseconds: 180),
                              child: Icon(
                                Symbols.expand_more_rounded,
                                size: 20,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (onMarkRead != null || markingRead)
                  IconButton(
                    key: const ValueKey('pinned-topics-mark-read'),
                    tooltip: context.l10n.topics_markPinnedRead,
                    onPressed: markingRead ? null : onMarkRead,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    icon: markingRead
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Symbols.done_all_rounded, size: 20),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
