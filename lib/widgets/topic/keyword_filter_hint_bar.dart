import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../settings/definitions/preferences_defs.dart';

/// 话题列表顶部的「关键词过滤」提示。
///
/// 仅在有话题被隐藏时显示。整行可点击，打开关键词编辑弹窗。
/// 形态与 `_buildNewTopicIndicator` 保持一致（同样的胶囊容器、margin、圆角），
/// 但使用 surfaceVariant 系颜色而非 primaryContainer，刻意做成次要状态层级，
/// 与新话题 CTA 堆叠时形成「主操作 + 次要状态」的视觉层次。
class KeywordFilterHintBar extends ConsumerWidget {
  final int hiddenCount;

  const KeywordFilterHintBar({super.key, required this.hiddenCount});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (hiddenCount <= 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final mutedColor = theme.colorScheme.onSurfaceVariant;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => showTopicFilterKeywordsDialog(context, ref),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.visibility_off_outlined,
                  size: 14,
                  color: mutedColor,
                ),
                const SizedBox(width: 6),
                Text(
                  l10n.topic_keywordFilter_hiddenCount(hiddenCount),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: mutedColor,
                    fontSize: 12,
                  ),
                ),
                Text(
                  '  ·  ',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: mutedColor.withValues(alpha: 0.5),
                    fontSize: 12,
                  ),
                ),
                Text(
                  l10n.topic_keywordFilter_manage,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
