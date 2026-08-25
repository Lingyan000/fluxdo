import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import '../../../models/topic.dart';
import '../../../l10n/s.dart';
import '../../../providers/preferences_provider.dart';
import '../../../providers/topic_session_provider.dart';
import '../../../services/toast_service.dart';
import '../../../utils/blocked_user_filter.dart';
import '../../../utils/code_selection_context.dart';
import '../../../utils/fluxdo_render_callbacks.dart';
import '../../../utils/frame_jank_monitor.dart';
import '../../common/perf_span_box.dart';
import '../post_boost/boost_actions.dart';
import '../post_boost/boost_danmaku.dart';
import '../post_signature_block.dart';
import '../small_action_item.dart';
import '../../crypto/crypto_decrypt_sheet.dart';
import '../../topic/assign_sheet.dart';
import 'quote_selection_helper.dart';
import '../../../../services/crypto/crypto_cipher_format.dart';
import 'render_parse_cache.dart';
import 'widgets/post_footer_section/post_footer_section.dart';
import 'widgets/post_header_section.dart';
import 'widgets/post_notice_widget.dart';
import 'widgets/post_segment_frame.dart';
import 'widgets/post_voting_control.dart';

class PostItem extends ConsumerStatefulWidget {
  final Post post;
  final int topicId;

  /// 话题分类 id,用于签名的 signatures_show_in_categories 门禁。
  final int? categoryId;
  final void Function({String? initialContent})? onReply;

  /// 头像长按菜单「@用户」回调（null = 不可回复，菜单不显示该项）
  final void Function(String username)? onMentionUser;
  final VoidCallback? onLike;
  final VoidCallback? onEdit;
  final VoidCallback? onShareAsImage;
  final void Function(int postId)? onRefreshPost;
  final void Function(int postNumber)? onJumpToPost;
  final void Function(int postId, bool accepted)? onSolutionChanged;
  final bool selected;
  final bool highlight;
  final bool isTopicOwner;
  final bool topicHasAcceptedAnswer;
  final List<AcceptedAnswer> acceptedAnswers;
  final String? dateSeparatorLabel;
  final String? bottomDateSeparatorLabel;
  final void Function(String selectedText, Post post)? onQuoteSelection;
  final void Function(String quote, Post post)? onQuoteImage;
  final void Function(int postId)? onExpandHiddenPost;
  final bool useReplyDialog;
  final String? topicTitle;
  final bool isPrivateMessageTopic;
  final bool isPmWithNonHumanUser;
  final VoidCallback? onShowPostDetail;
  final bool hideRepliesButton;
  final String? highlightBoostUsername;

  /// OP 帖专属插槽: 仅在 postNumber == 1 时生效, 透传给 PostFooterSection
  final Widget? opTopSlot;

  /// 帖子级指定(discourse-assign 插件 indirectly_assigned_to)信息,
  /// 非 null 时在正文下方/签名上方显示"已指定给 X"标签。
  final PostAssignmentInfo? assignmentInfo;

  /// 当前用户是否有指定权限(discourse-assign can_assign)——控制
  /// "更多"菜单里"指定帖子"这一项是否显示。
  final bool canAssignPost;

  /// post-voting(问答)话题:footer 显示赞成/反对控件与评论区
  final bool isPostVotingTopic;

  /// 话题 closed/archived(问答投票禁投判定)
  final bool topicClosed;

  const PostItem({
    super.key,
    required this.post,
    required this.topicId,
    this.categoryId,
    this.onReply,
    this.onMentionUser,
    this.onLike,
    this.onEdit,
    this.onShareAsImage,
    this.onRefreshPost,
    this.onJumpToPost,
    this.onSolutionChanged,
    this.selected = false,
    this.highlight = false,
    this.highlightBoostUsername,
    this.isTopicOwner = false,
    this.topicHasAcceptedAnswer = false,
    this.acceptedAnswers = const [],
    this.dateSeparatorLabel,
    this.bottomDateSeparatorLabel,
    this.onQuoteSelection,
    this.onQuoteImage,
    this.onExpandHiddenPost,
    this.useReplyDialog = false,
    this.topicTitle,
    this.isPrivateMessageTopic = false,
    this.isPmWithNonHumanUser = false,
    this.onShowPostDetail,
    this.hideRepliesButton = false,
    this.opTopSlot,
    this.assignmentInfo,
    this.canAssignPost = false,
    this.isPostVotingTopic = false,
    this.topicClosed = false,
  });

  @override
  ConsumerState<PostItem> createState() => _PostItemState();
}

class _PostItemState extends ConsumerState<PostItem> {
  _ShortPostNewEngineRenderData? _newEngineRenderData;
  late bool _acceptedAnswer;

  @override
  void initState() {
    super.initState();
    _acceptedAnswer = widget.post.acceptedAnswer;
  }

  @override
  void didUpdateWidget(PostItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.post != widget.post) {
      _acceptedAnswer = widget.post.acceptedAnswer;
    }
    if (!identical(oldWidget.post, widget.post)) {
      _newEngineRenderData = null;
    }
  }

  _ShortPostNewEngineRenderData _newEngineDataFor(Post post) {
    final cached = _newEngineRenderData;
    if (cached != null && identical(cached.post, post)) return cached;

    // 解析产物走全局 LRU(RenderParseCache):item 滚出 cacheExtent 被回收后
    // 再滚回来,preprocess + DOM parse 直接命中,不重付(State 级缓存随
    // dispose 丢失,来回滚动即反复解析 —— 之前滚动卡顿的主要来源之一)
    final parsed = RenderParseCache.shortPost(post);
    final callbacks = FluxdoRenderCallbacks.forPost(
      post: post,
      topicId: widget.topicId,
      onQuoteImage: widget.onQuoteImage,
      preprocessedCooked: parsed.preprocessed,
      parsedNodes: parsed.nodes,
    );
    return _newEngineRenderData = _ShortPostNewEngineRenderData(
      post: post,
      preprocessedCooked: parsed.preprocessed,
      parsedNodes: parsed.nodes,
      callbacks: callbacks,
    );
  }

  /// 问答话题:正文左侧挂竖排投票列(官方 .post-voting-post 形态,
  /// 上箭头/票数/下箭头一列,正文右移让位);普通话题原样返回。
  Widget _withVotingColumn(Post post, Widget body) {
    if (!widget.isPostVotingTopic) return body;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: PostVotingControl(
            post: post,
            topicId: widget.topicId,
            topicClosed: widget.topicClosed,
            axis: Axis.vertical,
          ),
        ),
        Expanded(child: body),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final theme = Theme.of(context);
    // 帧内构建归因:JANK 大帧 detail 会列出本帧构建的帖子与正文大小,
    // 区分"物化新帖成本 / rebuild 风暴 / GC·线程挤占"(监控关闭零开销)
    FrameJankMonitor.noteBuild(
      'post#${post.postNumber}/'
      '${(post.cooked.length / 1000).toStringAsFixed(1)}k',
    );

    // discourse-assign 的指定/取消指定系统帖:SiteSetting.assigns_public
    // 关闭时插件把这些帖子建成 whisper(post_type=4)而不是 small_action
    // (post_type=3)——只按 post_type 判断会漏掉这部分,它们就会落到下面
    // 正常帖子的渲染分支,带点赞/回复/更多按钮,而这些系统帖压根不支持
    // 这些互动,点了就出错。action_code 才是 Discourse 真正用来标记"这是
    // 系统生成的操作记录帖"的字段,不管 post_type 是 3 还是 4 都会带上,
    // 普通用户帖永远不会有这个字段——用它兜底判断更准。
    if (post.postType == PostTypes.smallAction ||
        (post.actionCode?.isNotEmpty ?? false)) {
      return SmallActionItem(
        post: post,
        topicId: widget.topicId,
        selected: widget.selected,
        onEdit: widget.onEdit,
      );
    }

    final danmakuPref = ref.watch(
      preferencesProvider.select((p) => p.boostDanmaku),
    );
    final blockedUsernames = ref.watch(
      preferencesProvider.select((p) => p.normalizedBlockedUsernames),
    );
    final visibleBoosts = BlockedUserFilter.visibleBoosts(
      post.boosts ?? const <Boost>[],
      blockedUsernames,
    );
    final hasBoosts = visibleBoosts.isNotEmpty;
    // 帖级临时关闭在会话层(topicSessionProvider):长帖分段与短帖共享,
    // 且不随 sliver 回收丢失
    final danmakuOff = ref.watch(
      topicSessionProvider(
        widget.topicId,
      ).select((s) => s.danmakuOffPostIds.contains(post.id)),
    );
    final danmakuActive = danmakuPref && !danmakuOff;
    final showDanmaku = danmakuActive && hasBoosts;
    // 仅当全局开关开启且有 boost 时，才展示帖子级 toggle 按钮
    final showDanmakuToggle = danmakuPref && hasBoosts;
    // 按 boost 数量决定轨道数：1 条用 1 轨，2-4 用 2 轨，5+ 用 3 轨
    final boostCount = visibleBoosts.length;
    final danmakuTrackCount = boostCount <= 1
        ? 1
        : boostCount <= 4
        ? 2
        : 3;
    const danmakuTrackHeight = 36.0;

    final isModeratorAction = post.postType == PostTypes.moderatorAction;
    // PerfSpanBox:整帖子树的 layout/paint 账单(lay:post#N / pnt:post#N),
    // 与上面 noteBuild 的在场名单互补(监控关闭零开销,纯代理盒无视觉影响)
    return PerfSpanBox(
      label: 'post#${post.postNumber}',
      child: PostSegmentFrame(
      post: post,
      selected: widget.selected,
      highlight: widget.highlight,
      constraints: const BoxConstraints(minHeight: 80),
      showTopDateSeparator: widget.dateSeparatorLabel != null,
      topDateSeparatorLabel: widget.dateSeparatorLabel,
      showBottomDateSeparator: widget.bottomDateSeparatorLabel != null,
      bottomDateSeparatorLabel: widget.bottomDateSeparatorLabel,
      showBottomBorder: true,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PostHeaderSection(
              post: post,
              topicId: widget.topicId,
              isTopicOwner: widget.isTopicOwner,
              showStamp: _acceptedAnswer,
              padding: EdgeInsets.zero,
              onJumpToPost: widget.onJumpToPost,
              onEditWiki: widget.onEdit,
              onMentionUser: widget.onMentionUser,
              danmakuActive: showDanmakuToggle ? showDanmaku : null,
              onToggleDanmaku: showDanmakuToggle
                  ? () => ref
                        .read(topicSessionProvider(widget.topicId).notifier)
                        .setDanmakuOff(post.id, showDanmaku)
                  : null,
            ),
            const SizedBox(height: 12),
            if (post.notice != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: PostNoticeWidget(
                  notice: post.notice!,
                  username: post.username,
                ),
              ),
            Container(
              decoration: isModeratorAction
                  ? BoxDecoration(
                      color: theme.colorScheme.tertiaryContainer.withValues(
                        alpha: 0.2,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    )
                  : null,
              padding: isModeratorAction
                  ? const EdgeInsets.all(12)
                  : EdgeInsets.zero,
              child: _withVotingColumn(
                post,
                Stack(
                clipBehavior: Clip.none,
                children: [
                  ConstrainedBox(
                    // 弹幕模式下正文至少预留 1 行弹幕高度，避免短帖第一行弹幕被截
                    constraints: BoxConstraints(
                      minHeight: showDanmaku ? danmakuTrackHeight : 0,
                    ),
                    child: Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: (_) =>
                          CodeSelectionContextTracker.instance.clear(),
                      child: Builder(
                        builder: (_) {
                          final data = _newEngineDataFor(post);
                          // 新引擎自带自研逻辑选区(SelectionScope + 手势层 +
                          // toolbar)。引用:toolbar 点「引用」→ onQuoteRequest
                          // (plainText) → QuoteSelectionHelper 在原始 cooked 匹配。
                          return data.callbacks.render(
                            cookedHtml: data.preprocessedCooked,
                            parsedNodes: data.parsedNodes,
                            // 正文字号经 baseTextStyle 注入 contentFontScale
                            // (此前新引擎分支未接入,顺带修复)。
                            baseTextStyle: theme.textTheme.bodyMedium?.copyWith(
                              height: 1.5,
                              fontSize:
                                  (theme.textTheme.bodyMedium?.fontSize ?? 14) *
                                  ref
                                      .watch(preferencesProvider)
                                      .contentFontScale,
                            ),
                            // 自研选区恒开(外层系统 SelectionArea 已拆):
                            // 未登录时 onQuoteRequest 为 null,toolbar 自动
                            // 降级只留「复制/复制引用」。
                            selectionEnabled: true,
                            onQuoteRequest: widget.onQuoteSelection == null
                                ? null
                                : (plainText) =>
                                      widget.onQuoteSelection!(plainText, post),
                            onCopyQuoteRequest: (plainText) =>
                                QuoteSelectionHelper.copyQuoteToClipboard(
                                  selectedText: plainText,
                                  post: post,
                                  topicId: widget.topicId,
                                ),
                            onCopyToast: () => ToastService.showSuccess(
                              context.l10n.common_copiedToClipboard,
                            ),
                            // 划词「解密」:选中文本命中密文特征时 toolbar 显示,
                            // 打开加解密工具箱解密面板(ENC1/OpenSSL/编码)。
                            onDecryptRequest: (plainText) =>
                                showCryptoDecryptSheet(
                              context: context,
                              initialCiphertext: plainText,
                              onQuoteReply: widget.onQuoteSelection == null
                                  ? null
                                  : (plaintext) => widget
                                      .onQuoteSelection!(plaintext, post),
                            ),
                            decryptTextDetector: isDecryptableText,
                          );
                        },
                      ),
                    ),
                  ),
                  if (showDanmaku)
                    Positioned.fill(
                      child: BoostDanmaku(
                        visibilityKey: post.id,
                        boosts: visibleBoosts,
                        maxTrackCount: danmakuTrackCount,
                        trackHeight: danmakuTrackHeight,
                        highlightUsername: widget.highlightBoostUsername,
                        onBoostTap: (boost, anchorRect) {
                          BoostActions.show(
                            context: context,
                            ref: ref,
                            post: post,
                            topicId: widget.topicId,
                            boost: boost,
                            anchorRect: anchorRect,
                            topicTitle: widget.topicTitle,
                          );
                        },
                      ),
                    ),
                ],
              ),
              ),
            ),
            // 帖子级指定标签("已指定给 X"):正文下方、签名上方,
            // 跟官方 Web 端位置一致。点开是编辑/取消的小菜单。
            if (widget.assignmentInfo != null)
              _PostAssignmentBadge(
                info: widget.assignmentInfo!,
                topicId: widget.topicId,
              ),
            // 用户签名
            if (PostSignatureBlock.shouldRender(
              ref,
              post,
              categoryId: widget.categoryId,
            ))
              PostSignatureBlock(post: post, categoryId: widget.categoryId),
            // 举报隐藏帖子：显示展开按钮
            if (post.cookedHidden &&
                post.canSeeHiddenPost &&
                widget.onExpandHiddenPost != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: InkWell(
                  onTap: () => widget.onExpandHiddenPost!(post.id),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 4,
                      horizontal: 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Symbols.visibility_rounded,
                          size: 15,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          context.l10n.post_viewHiddenInfo,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            PostFooterSection(
              post: post,
              danmakuActive: showDanmakuToggle ? showDanmaku : null,
              topicId: widget.topicId,
              topicHasAcceptedAnswer: widget.topicHasAcceptedAnswer,
              acceptedAnswers: widget.acceptedAnswers,
              padding: const EdgeInsets.only(top: 12),
              highlightBoostUsername: widget.highlightBoostUsername,
              onReply: widget.onReply,
              onEdit: widget.onEdit,
              onShareAsImage: widget.onShareAsImage,
              onRefreshPost: widget.onRefreshPost,
              onJumpToPost: widget.onJumpToPost,
              onSolutionChanged: widget.onSolutionChanged,
              useReplyDialog: widget.useReplyDialog,
              topicTitle: widget.topicTitle,
              isPrivateMessageTopic: widget.isPrivateMessageTopic,
              isPmWithNonHumanUser: widget.isPmWithNonHumanUser,
              onShowPostDetail: widget.onShowPostDetail,
              hideRepliesButton: widget.hideRepliesButton,
              opTopSlot: widget.opTopSlot,
              canAssignPost:
                  widget.canAssignPost && widget.assignmentInfo == null,
              onAssignPost: () => showPostAssignDialog(
                context,
                ref,
                topicId: widget.topicId,
                postId: post.id,
              ),
              isPostVotingTopic: widget.isPostVotingTopic,
              topicClosed: widget.topicClosed,
              // 短帖正文左侧已有竖排投票列,footer 不再放横排胶囊
              showVotingControl: false,
              onAcceptedAnswerChanged: (accepted) {
                if (!mounted) return;
                setState(() {
                  _acceptedAnswer = accepted;
                });
              },
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class _ShortPostNewEngineRenderData {
  final Post post;
  final String preprocessedCooked;
  final List<BlockNode> parsedNodes;
  final FluxdoRenderCallbacks callbacks;

  const _ShortPostNewEngineRenderData({
    required this.post,
    required this.preprocessedCooked,
    required this.parsedNodes,
    required this.callbacks,
  });
}

/// "已指定给 X"标签(帖子级)——点开是编辑/取消的小菜单,对齐官方
/// Web 端"正文下方、签名上方"的位置和交互。
class _PostAssignmentBadge extends ConsumerWidget {
  const _PostAssignmentBadge({required this.info, required this.topicId});

  final PostAssignmentInfo info;
  final int topicId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => showPostAssignDialog(
          context,
          ref,
          topicId: topicId,
          postId: info.postId,
          current: info,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.assignment_ind_rounded,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '已指定给 ${info.displayName}',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              PopupMenuButton<String>(
                padding: EdgeInsets.zero,
                icon: Icon(
                  Icons.more_vert_rounded,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                onSelected: (value) {
                  if (value == 'edit') {
                    showPostAssignDialog(
                      context,
                      ref,
                      topicId: topicId,
                      postId: info.postId,
                      current: info,
                    );
                  } else if (value == 'cancel') {
                    unassignPost(ref, topicId: topicId, postId: info.postId);
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'edit', child: Text('编辑指定')),
                  PopupMenuItem(value: 'cancel', child: Text('取消指定')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
