/// post-voting(问答)「N 个回答」头部:官方 post-voting-answer-header
/// 对齐——标题在左,「按票数/按活动」两个排序 pill 靠右,渲染在第一个
/// 答案帖上方,把问题区与答案区隔开。
library;

import 'package:flutter/material.dart';

import '../../../../l10n/s.dart';

class PostVotingAnswerHeader extends StatelessWidget {
  final int answerCount;
  final bool isActivityMode;
  final ValueChanged<bool> onSortChanged; // true = 按活动

  const PostVotingAnswerHeader({
    super.key,
    required this.answerCount,
    required this.isActivityMode,
    required this.onSortChanged,
  });

  Widget _pill(
    ThemeData theme, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: selected ? null : onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w600 : null,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              S.current.postVoting_answerCount(answerCount),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          _pill(
            theme,
            label: S.current.postVoting_sortVotes,
            selected: !isActivityMode,
            onTap: () => onSortChanged(false),
          ),
          const SizedBox(width: 4),
          _pill(
            theme,
            label: S.current.postVoting_sortActivity,
            selected: isActivityMode,
            onTap: () => onSortChanged(true),
          ),
        ],
      ),
    );
  }
}
