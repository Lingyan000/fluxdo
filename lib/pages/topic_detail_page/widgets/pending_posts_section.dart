import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../../l10n/s.dart';
import '../../../models/pending_post.dart';
import '../../../widgets/common/relative_time_text.dart';
import '../../../widgets/markdown_editor/markdown_renderer.dart';

/// 主题页帖子流底部的「待审核回复」区块
///
/// 对齐官方 topic 模板的 pending-posts 块:发帖被 NewPostManager 拦截
/// 送审后,本人在主题内能看到自己的待审内容(其他人不可见)。
/// 操作:撤回(DELETE /review/{id})、撤回并重新编辑(撤回后原文带回编辑器)。
class PendingPostsSection extends StatelessWidget {
  final List<PendingPost> pendingPosts;
  final void Function(PendingPost pending) onWithdraw;
  final void Function(PendingPost pending) onWithdrawAndEdit;

  const PendingPostsSection({
    super.key,
    required this.pendingPosts,
    required this.onWithdraw,
    required this.onWithdrawAndEdit,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final pending in pendingPosts)
          _PendingPostCard(
            key: ValueKey('pending-post-${pending.id}'),
            pending: pending,
            onWithdraw: () => onWithdraw(pending),
            onWithdrawAndEdit: () => onWithdrawAndEdit(pending),
          ),
      ],
    );
  }
}

class _PendingPostCard extends StatelessWidget {
  final PendingPost pending;
  final VoidCallback onWithdraw;
  final VoidCallback onWithdrawAndEdit;

  const _PendingPostCard({
    super.key,
    required this.pending,
    required this.onWithdraw,
    required this.onWithdrawAndEdit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onContainer = theme.colorScheme.onTertiaryContainer;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.tertiary.withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 状态行:等待审核 + 提交时间
          Row(
            children: [
              Icon(Symbols.hourglass_top_rounded, size: 16, color: onContainer),
              const SizedBox(width: 6),
              Text(
                context.l10n.review_awaitingApproval,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: onContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (pending.createdAt != null)
                RelativeTimeText(
                  dateTime: pending.createdAt,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: onContainer.withValues(alpha: 0.7),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // 正文预览:本地 cook(raw → cooked html → FluxdoRender),
          // 引擎不可用时 MarkdownBody 自带 Dart 近似降级
          MarkdownBody(data: pending.raw),
          const SizedBox(height: 4),
          // 操作行
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: onWithdraw,
                child: Text(context.l10n.review_withdraw),
              ),
              TextButton(
                onPressed: onWithdrawAndEdit,
                child: Text(context.l10n.review_withdrawAndEdit),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
