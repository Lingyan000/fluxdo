import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../models/topic.dart';

/// 帖子流末尾的慢速模式与回复保留时长提示。
class TopicStatusNotices extends StatelessWidget {
  const TopicStatusNotices({super.key, required this.detail});

  final TopicDetail detail;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final timer = detail.topicTimer;
    final notices = <Widget>[
      if (detail.slowModeSeconds > 0 && !detail.closed)
        _NoticeRow(
          icon: Symbols.hourglass_top_rounded,
          text: l10n.topicDetail_slowModeNotice(
            _formatDuration(context, Duration(seconds: detail.slowModeSeconds)),
          ),
        ),
      // 自动删除回复是循环任务，execute_at 已经过期时仍须展示保留时长。
      if (timer != null &&
          timer.statusType == 'delete_replies' &&
          timer.executeAt != null &&
          timer.durationMinutes > 0)
        _NoticeRow(
          icon: Symbols.schedule_rounded,
          text: l10n.topicDetail_autoDeleteRepliesNotice(
            _formatDuration(
              context,
              Duration(seconds: (timer.durationMinutes * 60).round()),
            ),
          ),
        ),
    ];
    if (notices.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: SegmentedCardGroup(
        animateChanges: false,
        color: PageBackgroundScope.contentColor(
          context,
          Theme.of(context).colorScheme.surfaceContainerLow,
        ),
        children: notices,
      ),
    );
  }

  String _formatDuration(BuildContext context, Duration duration) {
    final l10n = context.l10n;
    final days = duration.inDays;
    final hours = duration.inHours.remainder(24);
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    return [
      if (days > 0) l10n.topicDetail_noticeDays(days),
      if (hours > 0) l10n.topicDetail_noticeHours(hours),
      if (minutes > 0) l10n.topicDetail_noticeMinutes(minutes),
      if (seconds > 0) l10n.topicDetail_noticeSeconds(seconds),
    ].join(' ');
  }
}

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Icon(
              icon,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
