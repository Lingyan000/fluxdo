import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../utils/responsive.dart';
import '../topic/topic_card.dart' show TopicCardInteractiveSurface;

/// 活动内容与骨架共用外壳，窄栏使用轻分隔并让正文占满阅读宽度。
class ActivityCardFrame extends StatelessWidget {
  const ActivityCardFrame({
    super.key,
    required this.position,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onPreviewIntent,
  });

  final ({int index, int count}) position;
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onPreviewIntent;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < Breakpoints.mobile;
      final theme = Theme.of(context);
      final style = SegmentedCardStyle.of(context);
      return Theme(
        data: compact
            ? theme.copyWith(
                extensions: [
                  ...theme.extensions.values.where(
                    (extension) => extension is! SegmentedCardStyle,
                  ),
                  style.copyWith(mode: SegmentedCardMode.flat),
                ],
              )
            : theme,
        child: Builder(
          builder: (context) {
            final content = Padding(
              padding: const EdgeInsets.all(16),
              child: child,
            );
            return SegmentedCardItem(
              index: position.index,
              count: position.count,
              gap: 4,
              outerRadius: compact ? 0 : 20,
              color: compact
                  ? Colors.transparent
                  : PageBackgroundScope.contentColor(
                      context,
                      theme.cardTheme.color ??
                          theme.colorScheme.surfaceContainerLow,
                    ),
              child: onTap == null
                  ? content
                  : TopicCardInteractiveSurface(
                      onTap: onTap!,
                      onLongPress: onLongPress,
                      onPreviewIntent: onPreviewIntent,
                      borderRadius: SegmentedCardItem.borderRadiusOf(
                        context,
                        index: position.index,
                        count: position.count,
                        outerRadius: compact ? 0 : 20,
                      ),
                      child: content,
                    ),
            );
          },
        ),
      );
    },
  );
}

/// 头部按实际栏宽和字号排版，大字号下时间回到动作行自然换行。
class ActivityCardHeader extends StatelessWidget {
  const ActivityCardHeader({
    super.key,
    this.avatar,
    this.identity,
    required this.metadata,
    this.timestamp,
  });

  final Widget? avatar;
  final Widget? identity;
  final Widget metadata;
  final Widget? timestamp;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final inlineTime =
          constraints.maxWidth >=
          MediaQuery.textScalerOf(context).scale(14) * 22;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (avatar != null) ...[avatar!, const SizedBox(width: 8)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (identity != null) ...[
                        identity!,
                        const SizedBox(height: 4),
                      ],
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          metadata,
                          if (!inlineTime && timestamp != null) timestamp!,
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (inlineTime && timestamp != null) ...[
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth * .28),
              child: Padding(
                padding: EdgeInsets.only(top: identity == null ? 0 : 4),
                child: timestamp!,
              ),
            ),
          ],
        ],
      );
    },
  );
}
