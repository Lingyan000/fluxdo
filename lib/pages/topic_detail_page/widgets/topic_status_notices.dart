import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../models/topic.dart';
import '../../../providers/category_provider.dart';
import '../../../utils/relative_time_clock.dart';
import '../../../utils/time_utils.dart';

/// 帖子流末尾的慢速模式、定时任务与待审核数量提示。
class TopicStatusNotices extends ConsumerStatefulWidget {
  const TopicStatusNotices({super.key, required this.detail});

  final TopicDetail detail;

  @override
  ConsumerState<TopicStatusNotices> createState() => _TopicStatusNoticesState();
}

class _TopicStatusNoticesState extends ConsumerState<TopicStatusNotices> {
  bool _subscribed = false;

  void _onTick() {
    if (mounted) setState(() {});
  }

  void _subscribe(bool enabled) {
    if (_subscribed == enabled) return;
    _subscribed = enabled;
    if (enabled) {
      RelativeTimeClock.instance.addListener(_onTick);
    } else {
      RelativeTimeClock.instance.removeListener(_onTick);
    }
  }

  @override
  void dispose() {
    _subscribe(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail;
    final l10n = context.l10n;
    final timer = detail.topicTimer;
    final now = DateTime.now();
    final timerText = _timerText(timer, now);
    _subscribe(
      timerText != null &&
          timer?.statusType != 'delete_replies' &&
          timer?.basedOnLastPost != true &&
          TickerMode.valuesOf(context).enabled,
    );
    final notices = <Widget>[
      if (detail.slowModeSeconds > 0 && !detail.closed)
        _NoticeRow(
          icon: Symbols.hourglass_top_rounded,
          text: l10n.topicDetail_slowModeNotice(
            _formatDuration(context, Duration(seconds: detail.slowModeSeconds)),
          ),
        ),
      if (timerText != null)
        Tooltip(
          message: TimeUtils.formatTooltipTime(timer!.executeAt),
          child: _NoticeRow(icon: Symbols.schedule_rounded, text: timerText),
        ),
      // 该字段由服务端按审核权限下发，不能从个人待审回复数量推导。
      if (detail.queuedPostsCount > 0)
        _NoticeRow(
          icon: Symbols.pending_actions_rounded,
          text: l10n.topicDetail_queuedPostsNotice(detail.queuedPostsCount),
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

  String? _timerText(TopicTimer? timer, DateTime now) {
    if (timer?.executeAt == null) return null;
    final l10n = context.l10n;
    final status = timer!.statusType == 'silent_close'
        ? 'close'
        : timer.statusType;
    if ((status == 'close' && widget.detail.closed) ||
        (status == 'open' && !widget.detail.closed)) {
      return null;
    }
    final duration = Duration(seconds: (timer.durationMinutes * 60).round());
    // 回复保留时长和最后回复计时是持续规则，不能按 execute_at 判过期。
    if (status == 'delete_replies') {
      return duration > Duration.zero
          ? l10n.topicDetail_autoDeleteRepliesNotice(
              _formatDuration(context, duration),
            )
          : null;
    }
    if (timer.basedOnLastPost) {
      if (duration <= Duration.zero) return null;
      final text = _formatDuration(context, duration);
      return switch (status) {
        'close' => l10n.topicDetail_closeAfterLastPostNotice(text),
        'delete' => l10n.topicDetail_deleteAfterLastPostNotice(text),
        _ => null,
      };
    }
    if (!timer.executeAt!.isAfter(now)) return null;
    final remaining = timer.executeAt!.difference(now);
    final text = remaining.inSeconds < 60
        ? l10n.topicDetail_lessThanMinute
        : _formatDuration(
            context,
            Duration(minutes: (remaining.inSeconds / 60).ceil()),
          );
    switch (status) {
      case 'close':
        return l10n.topicDetail_autoCloseNotice(text);
      case 'open':
        return l10n.topicDetail_autoOpenNotice(text);
      case 'delete':
        return l10n.topicDetail_autoDeleteNotice(text);
      case 'bump':
        return l10n.topicDetail_autoBumpNotice(text);
      case 'publish_to_category':
        final category = ref
            .watch(categoryMapProvider)
            .value?[timer.categoryId];
        return category == null
            ? l10n.topicDetail_autoPublishNotice(text)
            : l10n.topicDetail_autoPublishToCategoryNotice(text, category.name);
      default:
        return null;
    }
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
