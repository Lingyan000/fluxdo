import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../utils/responsive.dart';

/// 置顶话题分组的形状：标题行与各置顶话题按分段卡片的规则逐项绘制
/// （[SegmentedCardItem]），外观随主题的分段卡片样式切换。
abstract final class PinnedTopicsGroup {
  static const double outerRadius = 12;
  static const double innerRadius = 4;
  static const double gap = 2;

  /// 分组之后与普通话题之间的距离
  static const double trailingGap = 8;
}

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
    // 展开时标题行是分组首项，后面紧跟各置顶话题；折叠时自成一组
    final segments = expanded ? count + 1 : 1;
    final shape = RoundedSuperellipseBorder(
      borderRadius: SegmentedCardItem.borderRadiusOf(
        context,
        index: 0,
        count: segments,
        outerRadius: PinnedTopicsGroup.outerRadius,
        innerRadius: PinnedTopicsGroup.innerRadius,
      ),
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: Breakpoints.maxContentWidth,
        ),
        child: Padding(
          padding: EdgeInsets.only(
            bottom: expanded ? 0 : PinnedTopicsGroup.trailingGap,
          ),
          child: SegmentedCardItem(
            index: 0,
            count: segments,
            outerRadius: PinnedTopicsGroup.outerRadius,
            innerRadius: PinnedTopicsGroup.innerRadius,
            gap: PinnedTopicsGroup.gap,
            color: _baseColor(context),
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
                        ? const LoadingSpinner(size: 20)
                        : const Icon(Symbols.done_all_rounded, size: 20),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 与置顶话题行相同的底色：有页面背景时透出背景，否则按分段卡片样式
  static Color? _baseColor(BuildContext context) =>
      PageBackgroundScope.isActive(context) ? Colors.transparent : null;
}
