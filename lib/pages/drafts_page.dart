import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/draft.dart';
import '../navigation/nav_action_bus.dart';
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

/// 草稿列表 Provider
final draftsProvider = FutureProvider.autoDispose<List<Draft>>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  final response = await service.getDrafts();
  return response.drafts;
});

/// 草稿列表页面
class DraftsPage extends ConsumerStatefulWidget {
  const DraftsPage({super.key, this.isActive = true});

  /// 是否为当前活跃的 tab（嵌入底栏时用于决定是否响应 NavActionBus）
  final bool isActive;

  @override
  ConsumerState<DraftsPage> createState() => _DraftsPageState();
}

class _DraftsPageState extends ConsumerState<DraftsPage> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_publishScrollProgress);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _publishScrollProgress() {
    if (!_scrollController.hasClients) return;
    final raw = _scrollController.offset;
    final progress = raw < 0 ? 0.0 : raw;
    final current = ref.read(navScrollProgressProvider(NavEntryIds.drafts));
    final atZero = progress == 0 && current != 0;
    final crossed =
        (progress >= navScrollIconThreshold) !=
        (current >= navScrollIconThreshold);
    if (!atZero && !crossed && (progress - current).abs() < 4.0) return;
    ref.read(navScrollProgressProvider(NavEntryIds.drafts).notifier).state =
        progress;
  }

  Future<void> _onRefresh() async {
    ref.invalidate(draftsProvider);
    await ref.read(draftsProvider.future);
  }

  @override
  Widget build(BuildContext context) {
    final draftsAsync = ref.watch(draftsProvider);

    // 嵌入底栏时响应快捷动作（仅活跃 tab 响应）
    ref.listen(navActionBusProvider, (_, event) {
      if (event == null || event.targetId != NavEntryIds.drafts) return;
      if (!widget.isActive) return;
      switch (event.action) {
        case NavAction.scrollToTop:
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
          break;
        case NavAction.refresh:
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
          _onRefresh();
          ref.resetNavScrollProgress(NavEntryIds.drafts);
          break;
      }
    });

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.drafts_title)),
      body: DesktopRefreshIndicator(
        onRefresh: _onRefresh,
        child: draftsAsync.when(
          data: (drafts) {
            if (drafts.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.drafts_outlined,
                      size: 64,
                      color: Colors.grey,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      context.l10n.drafts_empty,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              );
            }

            return ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(12),
              itemCount: drafts.length,
              itemBuilder: (context, index) {
                final draft = drafts[index];
                return _DraftCard(
                  draft: draft,
                  onTap: () => _onDraftTap(draft),
                  onDelete: () => _onDraftDelete(draft),
                );
              },
            );
          },
          loading: () => const _DraftsListSkeleton(),
          error: (error, stack) => ErrorView(
            error: error,
            stackTrace: stack,
            onRetry: () => ref.invalidate(draftsProvider),
          ),
        ),
      ),
    );
  }

  /// 点击草稿
  Future<void> _onDraftTap(Draft draft) async {
    final draftKey = draft.draftKey;

    if (draft.isNewTopicDraft) {
      // 新话题草稿：进入创建话题页面
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CreateTopicPage(draftKey: draft.draftKey),
        ),
      );
    } else if (draftKey == Draft.newPrivateMessageKey) {
      // 私信草稿：直接弹出回复框
      final recipients = draft.data.recipients;
      if (recipients != null && recipients.isNotEmpty) {
        await showReplySheet(
          context: context,
          targetUsername: recipients.first,
        );
      } else {
        ToastService.showInfo(S.current.drafts_pmIncomplete);
        return; // 不刷新
      }
    } else if (draftKey.startsWith('topic_')) {
      // 解析话题 ID 和帖子编号
      int? topicId;
      int? replyToPostNumber;

      if (draft.isPostReply) {
        // 帖子回复草稿：topic_{topicId}_post_{postNumber}
        final match = RegExp(r'^topic_(\d+)_post_(\d+)$').firstMatch(draftKey);
        if (match != null) {
          topicId = int.tryParse(match.group(1)!);
          replyToPostNumber = int.tryParse(match.group(2)!);
        }
      } else {
        // 话题回复草稿：topic_{topicId}
        topicId =
            draft.topicId ?? int.tryParse(draftKey.replaceFirst('topic_', ''));
      }

      if (topicId != null) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TopicDetailPage(
              topicId: topicId!,
              scrollToPostNumber: replyToPostNumber, // 跳转到对应帖子
              autoOpenReply: true,
              autoReplyToPostNumber: replyToPostNumber,
            ),
          ),
        );
      } else {
        return; // 不刷新
      }
    } else {
      return; // 不刷新
    }

    // 返回后刷新草稿列表
    if (mounted) {
      ref.invalidate(draftsProvider);
    }
  }

  /// 删除草稿
  Future<void> _onDraftDelete(Draft draft) async {
    final confirm = await showAppDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        bool isDeleting = false;
        return StatefulBuilder(
          builder: (dialogContext, setState) => AlertDialog(
            title: Text(dialogContext.l10n.drafts_deleteTitle),
            content: Text(dialogContext.l10n.drafts_deleteContent),
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
                          await DiscourseService().deleteDraft(
                            draft.draftKey,
                            sequence: draft.sequence,
                          );
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext, true);
                          }
                        } catch (e) {
                          if (dialogContext.mounted) {
                            setState(() => isDeleting = false);
                            ToastService.showError(
                              S.current.drafts_deleteFailed(e.toString()),
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
                    : Text(dialogContext.l10n.common_delete),
              ),
            ],
          ),
        );
      },
    );

    if (confirm == true && mounted) {
      ref.invalidate(draftsProvider);
      ToastService.showSuccess(S.current.drafts_deleted);
    }
  }
}

/// 草稿卡片
class _DraftCard extends StatelessWidget {
  final Draft draft;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _DraftCard({
    required this.draft,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = draft.data;

    // 确定草稿类型
    String typeLabel;
    IconData typeIcon;

    if (draft.isNewTopicDraft) {
      typeLabel = context.l10n.drafts_newTopic;
      typeIcon = Icons.add_circle_outline;
    } else if (draft.draftKey == Draft.newPrivateMessageKey) {
      typeLabel = context.l10n.drafts_privateMessage;
      typeIcon = Icons.mail_outline;
    } else if (draft.draftKey.startsWith('topic_')) {
      // 区分回复话题和回复帖子
      if (data.replyToPostNumber != null && data.replyToPostNumber! > 0) {
        typeLabel = context.l10n.drafts_replyToPost(data.replyToPostNumber!);
      } else {
        typeLabel = context.l10n.common_reply;
      }
      typeIcon = Icons.reply_outlined;
    } else {
      typeLabel = context.l10n.drafts_draft;
      typeIcon = Icons.drafts_outlined;
    }

    // 使用 displayTitle 获取标题
    final title = draft.displayTitle;
    final content = data.reply;

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
              // 类型标签、时间和删除按钮
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          typeIcon,
                          size: 14,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          typeLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 更新时间
                  if (draft.updatedAt != null)
                    RelativeTimeText(
                      dateTime: draft.updatedAt,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(
                      Icons.delete_outline,
                      size: 20,
                      color: theme.colorScheme.error,
                    ),
                    onPressed: onDelete,
                    visualDensity: VisualDensity.compact,
                    tooltip: context.l10n.drafts_deleteDraft,
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // 标题
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),

              // 内容预览
              if (content != null && content.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  content,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 草稿列表骨架屏
class _DraftsListSkeleton extends StatelessWidget {
  const _DraftsListSkeleton();

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: 5,
        itemBuilder: (context, index) => const _DraftCardSkeleton(),
      ),
    );
  }
}

/// 单个草稿卡片骨架屏
class _DraftCardSkeleton extends StatelessWidget {
  const _DraftCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 类型标签和时间
            Row(
              children: [
                SkeletonBox(width: 60, height: 22, borderRadius: 6),
                const SizedBox(width: 8),
                SkeletonBox(width: 50, height: 14),
                const Spacer(),
                SkeletonBox(width: 24, height: 24, borderRadius: 12),
              ],
            ),
            const SizedBox(height: 12),
            // 标题
            SkeletonBox(width: double.infinity, height: 18),
            const SizedBox(height: 8),
            // 内容预览
            SkeletonBox(width: double.infinity, height: 14),
            const SizedBox(height: 4),
            SkeletonBox(width: 200, height: 14),
          ],
        ),
      ),
    );
  }
}
