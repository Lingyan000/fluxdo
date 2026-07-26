import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
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
import '../services/drafts_signal.dart';
import '../providers/selected_topic_provider.dart';
import '../widgets/layout/master_detail_layout.dart';
import 'create_topic_page.dart';
import 'topic_detail_page/topic_detail_page.dart';

/// 草稿列表 Provider
final draftsProvider = FutureProvider.autoDispose<List<Draft>>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  final response = await service.getDrafts();
  return response.drafts;
});

/// 草稿列表页面
class DraftsPage extends ConsumerStatefulWidget {
  const DraftsPage({
    super.key,
    this.isActive = true,
    this.embeddedMode = false,
    this.onEmbeddedBack,
    this.onAllHandled,
    this.autoCloseWhenEmpty = false,
  });

  /// 列表空了就回调 [onAllHandled]（把草稿这一层撤掉）。
  ///
  /// 只有**左栏处理栏**该开：那个位置的草稿栏存在意义就是"还有东西要
  /// 处理"。栈顶（右栏）的草稿栏空了要老实显示空态。
  final bool autoCloseWhenEmpty;

  /// 是否为当前活跃的 tab（嵌入底栏时用于决定是否响应 NavActionBus）
  final bool isActive;

  /// 平行视界嵌入模式：本页是栈里的一层（右栏内容），AppBar 用
  /// [onEmbeddedBack] 关闭当前层而不是 Navigator pop（嵌入面板不在
  /// Navigator 路由栈里）。语义与 [SettingsPage] 一致。
  final bool embeddedMode;
  final VoidCallback? onEmbeddedBack;

  /// 草稿从"有"变成"全部处理完"时回调一次。
  ///
  /// 与 [onEmbeddedBack] 分开是有意的：master 面板里的草稿栏**不该有
  /// 返回按钮**（onEmbeddedBack 为 null），但它恰恰是最需要自动退场的
  /// 那一个 —— 复用同一个回调会把返回按钮一起带出来。
  final VoidCallback? onAllHandled;

  @override
  ConsumerState<DraftsPage> createState() => _DraftsPageState();
}

class _DraftsPageState extends ConsumerState<DraftsPage> {
  final ScrollController _scrollController = ScrollController();


  /// 当前是否有右栏可用（宽屏双栏）。
  ///
  /// **必须在 build 里取**：`canShowBothPanesFor` 内部是
  /// `MediaQuery.sizeOf(context)`，会注册 InheritedWidget 依赖。在点击
  /// 回调里调用 = 在 build 之外注册依赖，而本页所在的面板子树会被
  /// GlobalKey 换父节点（master 预览位 ↔ detail 位），换完这条依赖就
  /// 指向了非后代元素 —— 实测红屏 `check that it really is our descendant`。
  bool _canShowBothPanes = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_publishScrollProgress);
    // 发送/舍弃都会删草稿 → 服务层 bump 信号 → 这里刷新，那一条自动
    // 消失。页面自己看不到回复框里发生了什么，只能靠这个信号。
    DraftsSignal.revision.addListener(_onDraftsChanged);
  }

  @override
  void didUpdateWidget(DraftsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 重新变成活跃 tab → 刷一次。草稿可能是在**别的 tab** 里产生的
    // （典型：跑去私信回了一半），本页一直挂在 IndexedStack 里没重建，
    // 不主动刷就永远停在切走之前那份列表。
    if (!oldWidget.isActive && widget.isActive) {
      // didUpdateWidget 跑在 **build 阶段**，这里直接 ref.invalidate 会在
      // 构建途中改 provider，把元素树搞成不一致状态（实测红屏：
      // `_dependents.isEmpty is not true`）。挪到帧后。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onDraftsChanged();
      });
    }
  }

  @override
  void dispose() {
    DraftsSignal.revision.removeListener(_onDraftsChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onDraftsChanged() {
    if (!mounted) return;
    ref.invalidate(draftsProvider);
  }

  /// 发布"距顶进度"给底栏图标（NavActionBus 的 progress provider）
  void _publishScrollProgress() {
    if (!_scrollController.hasClients) return;
    final raw = _scrollController.offset;
    final progress = raw < 0 ? 0.0 : raw;
    final current = ref.read(navScrollProgressProvider(NavEntryIds.drafts));
    final atZero = progress == 0 && current != 0;
    final crossed = (progress >= navScrollIconThreshold) !=
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
    // 在 build 里取（见字段注释：不能在点击回调里读 MediaQuery）
    _canShowBothPanes = MasterDetailLayout.canShowBothPanesFor(context);

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

    final page = Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.drafts_title),
        // embeddedMode 但 onEmbeddedBack 为空（master 面板"上一层预览"）
        // 时不塞 BackButton——BackButton(onPressed: null) 会退化成默认
        // Navigator.maybePop()，捅穿到应用根导航栈（见 settings_page 同注）。
        automaticallyImplyLeading: !widget.embeddedMode,
        leading: widget.embeddedMode && widget.onEmbeddedBack != null
            ? BackButton(onPressed: widget.onEmbeddedBack)
            : null,
      ),
      body: DesktopRefreshIndicator(
        onRefresh: _onRefresh,
        child: draftsAsync.when(
          data: (drafts) {
            // 草稿处理完 → 这一层自动退场：右边的内容留着，左边回到
            // 信息流 / 私信列表。
            //
            // 判据是**栈位置**，不是"本页见过草稿没有"：
            // - 在栈顶（右栏，随便看看）→ 空了就老实显示空态，自己关掉
            //   会让人以为点击没生效；
            // - 在栈顶之下（左栏处理栏）→ 空了就是没得处理了，撤掉。
            //
            // 早先用的是本地历史标记（_hadDrafts），但左栏那个 DraftsPage
            // 是**另一个实例**，它常常是在列表已经空了之后才建出来的，
            // 标记恒为 false，于是永远不触发 —— 实测"处理完草稿点私信"
            // 停在「左草稿(空) + 右私信」。
            if (drafts.isEmpty && widget.autoCloseWhenEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) widget.onAllHandled?.call();
              });
            }
            if (drafts.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Symbols.drafts_rounded,
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
              // 底部让出 extendBody 注入的底栏高度
              padding: EdgeInsets.fromLTRB(
                12,
                12,
                12,
                12 + MediaQuery.paddingOf(context).bottom,
              ),
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

    return page;
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
    } else if (Draft.isNewPrivateMessageKey(draftKey)) {
      // 私信草稿：沿用原草稿 key 弹出回复框恢复（网页端 key 带时间戳后缀）
      final recipients = draft.data.recipients;
      if (recipients != null && recipients.isNotEmpty) {
        await showReplySheet(
          context: context,
          targetUsername: recipients.first,
          draftKey: draftKey,
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

      if (topicId == null) return; // 不刷新

      // 按**草稿自己的类型**分流到对应的那套栈，摆成 `[草稿, 内容]`：
      // 左栏草稿处理栏、右栏正在处理的那条。处理完草稿层被抽掉，栈剩
      // `[内容]`，左栏自然退回该内容对应的列表（信息流 / 私信列表）。
      //
      // **不能用 `EmbeddedStackScope.maybePushTopic`**：它跟着"当前所处的
      // 作用域"走。草稿栏一旦被摆到私信栈上（处理某条私信草稿时），在它
      // 里面再点一条**普通话题**的草稿，就会把话题压进**私信栈** ——
      // 实测左边私信列表、右边话题。归属得由草稿类型决定，与当前在哪无关。
      if (_canShowBothPanes) {
        final isPm = draft.isPrivateMessage;
        ref.requestNavDestination(
          isPm ? NavEntryIds.messages : NavEntryIds.home,
        );
        ref
            .read(
              (isPm ? selectedMessageProvider : selectedTopicProvider).notifier,
            )
            .openDraftTarget(
              topicId: topicId,
              scrollToPostNumber: replyToPostNumber,
              autoReplyToPostNumber: replyToPostNumber,
            );
        return;
      }
      // 不在任何嵌入面板里（窄屏全屏路由）：照旧 push，回来再刷新
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => TopicDetailPage(
            topicId: topicId!,
            scrollToPostNumber: replyToPostNumber,
            autoOpenReply: true,
            autoReplyToPostNumber: replyToPostNumber,
          ),
        ),
      );
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
      typeIcon = Symbols.add_circle_rounded;
    } else if (Draft.isNewPrivateMessageKey(draft.draftKey)) {
      typeLabel = context.l10n.drafts_privateMessage;
      typeIcon = Symbols.mail_rounded;
    } else if (draft.draftKey.startsWith('topic_')) {
      // 区分回复话题和回复帖子
      if (data.replyToPostNumber != null && data.replyToPostNumber! > 0) {
        typeLabel = context.l10n.drafts_replyToPost(data.replyToPostNumber!);
      } else {
        typeLabel = context.l10n.common_reply;
      }
      typeIcon = Symbols.reply_rounded;
    } else {
      typeLabel = context.l10n.drafts_draft;
      typeIcon = Symbols.drafts_rounded;
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
                            fontWeight: FontWeight.w500,
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
                      Symbols.delete_rounded,
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
                  fontWeight: FontWeight.w500,
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
