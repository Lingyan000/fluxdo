import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';

import '../../../l10n/s.dart';
import '../../../models/topic.dart';

/// 话题当前状态，历史操作记录之外的常驻说明。
class TopicStateSummary extends StatelessWidget {
  const TopicStateSummary({super.key, required this.detail});

  final TopicDetail detail;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final entries = <(IconData, String)>[
      if (detail.archived)
        (Symbols.inventory_2_rounded, l10n.topicDetail_archivedNotice),
      if (!detail.visible)
        (Symbols.visibility_off_rounded, _visibilityText(context)),
      if (detail.isWarning)
        (Symbols.warning_rounded, l10n.topicDetail_officialWarningNotice),
    ];
    if (entries.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          for (final (icon, text) in entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      icon,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      text,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _visibilityText(BuildContext context) {
    final l10n = context.l10n;
    // Discourse TOPIC_VISIBILITY_REASONS 的协议枚举值。
    final reason = switch (detail.visibilityReasonId) {
      0 => l10n.topicDetail_visibilityFlagged,
      1 => l10n.topicDetail_visibilityAuthor,
      2 => l10n.topicDetail_visibilityEmbedded,
      3 => l10n.topicDetail_visibilityStaff,
      4 => l10n.topicDetail_visibilityRelisted,
      5 => l10n.topicDetail_visibilityBulk,
      _ => '',
    };
    return reason.isEmpty
        ? l10n.topicDetail_unlistedNotice
        : '${l10n.topicDetail_unlistedNotice} $reason';
  }
}
