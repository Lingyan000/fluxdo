import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../utils/responsive.dart';
import '../topic/topic_card.dart' show TopicCardInteractiveSurface;

/// 活动列表外壳，按列表栏宽统一决定卡片或平铺形态。卡片带底色，两侧
/// 与栏边留出间距；平铺时正文自带内边距，贴边铺满。
class ActivityCardList extends StatelessWidget {
  const ActivityCardList({super.key, required this.builder});

  /// [padding] 为列表应使用的内边距，已含卡片形态下的两侧间距。
  final Widget Function(BuildContext context, EdgeInsets padding) builder;

  static const double gutter = 16;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < Breakpoints.mobile;
      return _ActivityCardScope(
        compact: compact,
        child: Builder(
          builder: (context) => builder(
            context,
            EdgeInsets.symmetric(
              horizontal: compact ? 0 : gutter,
              vertical: 12,
            ),
          ),
        ),
      );
    },
  );
}

class _ActivityCardScope extends InheritedWidget {
  const _ActivityCardScope({required this.compact, required super.child});

  final bool compact;

  @override
  bool updateShouldNotify(_ActivityCardScope oldWidget) =>
      compact != oldWidget.compact;
}

/// 活动内容与骨架共用外壳，窄栏使用轻分隔并让正文占满阅读宽度。
/// 位于 [ActivityCardList] 内时沿用列表的形态，否则按自身宽度判断。
class ActivityCardFrame extends StatelessWidget {
  const ActivityCardFrame({
    super.key,
    required this.position,
    required this.child,
    this.highlighted = false,
    this.onTap,
    this.onLongPress,
    this.onPreviewIntent,
  });

  final ({int index, int count}) position;
  final Widget child;
  final bool highlighted;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onPreviewIntent;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact =
          context
              .dependOnInheritedWidgetOfExactType<_ActivityCardScope>()
              ?.compact ??
          constraints.maxWidth < Breakpoints.mobile;
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
            final baseColor = compact
                ? Colors.transparent
                : PageBackgroundScope.contentColor(
                    context,
                    theme.cardTheme.color ??
                        theme.colorScheme.surfaceContainerLow,
                  );
            final cardColor = highlighted
                ? Color.alphaBlend(
                    context.emphasis.selected.withValues(
                      alpha: compact ? 0.055 : 0.07,
                    ),
                    baseColor,
                  )
                : baseColor;
            return SegmentedCardItem(
              index: position.index,
              count: position.count,
              gap: 4,
              outerRadius: compact ? 0 : 20,
              color: cardColor,
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
      // 只有头像加单行动作时，时间与该行一起在头像高度内居中
      final centered = avatar != null && identity == null;
      return Row(
        crossAxisAlignment: centered
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
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
