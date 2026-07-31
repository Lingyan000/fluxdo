import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/pending_post.dart';
import '../models/topic.dart';
import '../providers/discourse_providers.dart';
import '../widgets/desktop_refresh_indicator.dart';
import '../services/discourse/discourse_service.dart';
import '../widgets/common/skeleton.dart';
import '../widgets/common/error_view.dart';
import '../widgets/post/reply_sheet.dart';
import '../services/toast_service.dart';
import '../widgets/common/relative_time_text.dart';
import '../l10n/s.dart';
import '../utils/dialog_utils.dart';
import 'topic_detail_page/topic_detail_page.dart';
import 'create_topic_page.dart';

/// 待审核内容列表 Provider
final pendingPostsProvider =
    FutureProvider.autoDispose<List<PendingPost>>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  return service.getMyPendingPosts();
});

/// 我的待审核内容列表页(对齐官方 /u/{me}/activity/pending)
class PendingPostsPage extends ConsumerStatefulWidget {
  const PendingPostsPage({super.key});

  @override
  ConsumerState<PendingPostsPage> createState() => _PendingPostsPageState();
}

class _PendingPostsPageState extends ConsumerState<PendingPostsPage> {
  Future<void> _onRefresh() async {
    ref.invalidate(pendingPostsProvider);
    await ref.read(pendingPostsProvider.future);
  }

  @override
  Widget build(BuildContext context) {
    final pendingAsync = ref.watch(pendingPostsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.review_myPending)),
      body: DesktopRefreshIndicator(
        onRefresh: _onRefresh,
        child: pendingAsync.when(
          data: (pendingPosts) {
            if (pendingPosts.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Symbols.pending_actions_rounded,
                      size: 64,
                      color: Colors.grey,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      context.l10n.review_empty,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              );
            }

            return ListView.builder(
              padding: EdgeInsets.fromLTRB(
                12,
                12,
                12,
                12 + MediaQuery.paddingOf(context).bottom,
              ),
              itemCount: pendingPosts.length,
              itemBuilder: (context, index) {
                final pending = pendingPosts[index];
                return _PendingPostCard(
                  pending: pending,
                  onTap: pending.topicId != null
                      ? () => _openTopic(pending)
                      : null,
                  onWithdraw: () => _onWithdraw(pending),
                  onWithdrawAndEdit: () => _onWithdrawAndEdit(pending),
                );
              },
            );
          },
          loading: () => const _PendingListSkeleton(),
          error: (error, stack) => ErrorView(
            error: error,
            stackTrace: stack,
            onRetry: () => ref.invalidate(pendingPostsProvider),
          ),
        ),
      ),
    );
  }

  void _openTopic(PendingPost pending) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: pending.topicId!,
          initialTitle: pending.title,
        ),
      ),
    );
  }

  /// 撤回确认弹窗 + 删除请求;成功返回 true
  Future<bool> _confirmWithdraw(
    PendingPost pending, {
    required String title,
    required String content,
    required String confirmLabel,
  }) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        bool isDeleting = false;
        return StatefulBuilder(
          builder: (dialogContext, setState) => AlertDialog(
            title: Text(title),
            content: Text(content),
            actions: [
              TextButton(
                onPressed: isDeleting
                    ? null
                    : () => Navigator.pop(dialogContext, false),
                child: Text(dialogContext.l10n.common_cancel),
              ),
              FilledButton(
                onPressed: isDeleting
                    ? null
                    : () async {
                        setState(() => isDeleting = true);
                        try {
                          await DiscourseService()
                              .deleteReviewable(pending.id);
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext, true);
                          }
                        } catch (e) {
                          if (dialogContext.mounted) {
                            setState(() => isDeleting = false);
                            ToastService.showError(
                              S.current.review_withdrawFailed(e.toString()),
                            );
                          }
                        }
                      },
                child: isDeleting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(confirmLabel),
              ),
            ],
          ),
        );
      },
    );

    if (confirmed == true && mounted) {
      ref.invalidate(pendingPostsProvider);
      return true;
    }
    return false;
  }

  Future<void> _onWithdraw(PendingPost pending) async {
    final withdrawn = await _confirmWithdraw(
      pending,
      title: S.current.review_withdrawConfirmTitle,
      content: S.current.review_withdrawConfirmContent,
      confirmLabel: S.current.review_withdraw,
    );
    if (withdrawn && mounted) {
      PendingReplyTargetRegistry.remove(pending.id);
      ToastService.showSuccess(S.current.review_withdrawn);
    }
  }

  Future<void> _onWithdrawAndEdit(PendingPost pending) async {
    // 回复目标只在送审当下的会话里可知(服务端本人可见接口不吐,
    // 见 PendingReplyTargetRegistry);冷场景提示会退化为直接回复话题
    final isReply = !pending.isNewTopic;
    final targetKnown =
        !isReply || PendingReplyTargetRegistry.contains(pending.id);
    final replyToPostNumber = PendingReplyTargetRegistry.lookup(pending.id);
    final confirmContent = targetKnown
        ? S.current.review_withdrawAndEditConfirmContent
        : '${S.current.review_withdrawAndEditConfirmContent}\n\n'
              '${S.current.review_replyTargetUnknownHint}';

    final withdrawn = await _confirmWithdraw(
      pending,
      title: S.current.review_withdrawAndEdit,
      content: confirmContent,
      confirmLabel: S.current.review_withdrawAndEdit,
    );
    if (!withdrawn || !mounted) return;
    PendingReplyTargetRegistry.remove(pending.id);

    if (pending.isNewTopic) {
      // 待审的新主题:原文带回创建话题页
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CreateTopicPage(
            initialCategoryId: pending.categoryId,
            initialTitle: pending.title,
            initialContent: pending.raw,
          ),
        ),
      );
    } else {
      // 待审的回复:原文带回回复编辑器,尽量恢复送审时的回复目标
      Post? replyToPost;
      if (replyToPostNumber != null) {
        try {
          replyToPost = await DiscourseService().getPostByNumber(
            pending.topicId!,
            replyToPostNumber,
          );
        } catch (_) {
          // 目标楼层拉不到(已删除等):退化为直接回复话题
        }
      }
      if (!mounted) return;
      await showReplySheet(
        context: context,
        topicId: pending.topicId,
        categoryId: pending.categoryId,
        replyToPost: replyToPost,
        topicTitle: pending.title,
        initialContent: pending.raw,
      );
    }
    if (mounted) ref.invalidate(pendingPostsProvider);
  }
}

/// 待审内容卡片(布局对齐草稿卡片)
class _PendingPostCard extends StatelessWidget {
  final PendingPost pending;
  final VoidCallback? onTap;
  final VoidCallback onWithdraw;
  final VoidCallback onWithdrawAndEdit;

  const _PendingPostCard({
    required this.pending,
    this.onTap,
    required this.onWithdraw,
    required this.onWithdrawAndEdit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final typeLabel = pending.isNewTopic
        ? context.l10n.review_typeNewTopic
        : context.l10n.review_typeReply;
    final typeIcon = pending.isNewTopic
        ? Symbols.add_circle_rounded
        : Symbols.reply_rounded;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 类型标签、等待审核标识、时间
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.tertiaryContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          typeIcon,
                          size: 14,
                          color: theme.colorScheme.onTertiaryContainer,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          typeLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onTertiaryContainer,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Symbols.hourglass_top_rounded,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Text(
                      context.l10n.review_awaitingApproval,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (pending.createdAt != null)
                    RelativeTimeText(
                      dateTime: pending.createdAt,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),

              // 标题(新主题 = 待审标题,回复 = 所在主题标题)
              if (pending.title != null && pending.title!.isNotEmpty)
                Text(
                  pending.title!,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),

              // 内容预览
              if (pending.raw.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  pending.raw,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],

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
        ),
      ),
    );
  }
}

/// 列表骨架屏
class _PendingListSkeleton extends StatelessWidget {
  const _PendingListSkeleton();

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: 4,
        itemBuilder: (context, index) => Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SkeletonBox(width: 60, height: 22, borderRadius: 6),
                    const SizedBox(width: 8),
                    SkeletonBox(width: 70, height: 14),
                    const Spacer(),
                    SkeletonBox(width: 50, height: 14),
                  ],
                ),
                const SizedBox(height: 12),
                SkeletonBox(width: double.infinity, height: 18),
                const SizedBox(height: 8),
                SkeletonBox(width: double.infinity, height: 14),
                const SizedBox(height: 4),
                SkeletonBox(width: 200, height: 14),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
