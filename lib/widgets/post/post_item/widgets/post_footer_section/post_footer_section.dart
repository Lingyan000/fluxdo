import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:async';
import '../../../../../l10n/s.dart';
import '../../../../../constants.dart';
import '../../../../../models/topic.dart';
import '../../../../../modules/ldc_reward/ldc_reward.dart';
import '../../../../../providers/discourse_providers.dart';
import '../../../../../providers/preferences_provider.dart';
import '../../../../../utils/blocked_user_filter.dart';
import '../../../../../utils/frame_jank_monitor.dart';
import 'package:dio/dio.dart';
import '../../../../../services/app_error_handler.dart';
import '../../../../../services/discourse/discourse_service.dart';
import '../../../../../services/log/bookmark_edit_trace.dart';
import '../../../../../services/notion/notion_bookmark_auto_sync.dart';
import '../../../../../services/toast_service.dart';
import '../../../post_links.dart';
import '../post_action_bar.dart';
import '../../../../bookmark/bookmark_edit_sheet_launcher.dart';
import '../../../../post/post_boost/boost_actions.dart';
import '../../../../post/post_boost/boost_list.dart';
import '../../../../post/post_boost/boost_input.dart';
import '../post_flag_sheet.dart';
import '../post_reaction_users_sheet.dart';
import '../post_replies_list.dart';
import '../post_solution_banner.dart';
import '../../../../post/post_replies_sheet.dart';
import '../../../../../utils/dialog_utils.dart';
import '../../../../common/app_bottom_sheet.dart';

part 'actions/bookmark_actions.dart';
part 'actions/manage_actions.dart';
part 'actions/menu_actions.dart';
part 'actions/reaction_actions.dart';
part 'actions/reply_actions.dart';

class PostFooterSection extends ConsumerStatefulWidget {
  final Post post;
  final int topicId;
  final bool topicHasAcceptedAnswer;
  final List<AcceptedAnswer> acceptedAnswers;
  final EdgeInsetsGeometry padding;
  final void Function({String? initialContent})? onReply;
  final VoidCallback? onEdit;
  final VoidCallback? onShareAsImage;
  final void Function(int postId)? onRefreshPost;
  final void Function(int postNumber)? onJumpToPost;
  final void Function(int postId, bool accepted)? onSolutionChanged;
  final ValueChanged<bool>? onAcceptedAnswerChanged;
  final bool useReplyDialog;
  final String? topicTitle;
  final bool isPrivateMessageTopic;
  final bool isPmWithNonHumanUser;

  /// 隐藏回复列表按钮（弹框内使用时不需要展示）
  final bool hideRepliesButton;

  /// 查看帖子详情回调（菜单中的"查看帖子详情"或"跳转"）
  final VoidCallback? onShowPostDetail;

  /// 自定义帖子详情菜单项文本（默认"帖子详情"，弹框中可用"跳转"）
  final String? postDetailLabel;

  /// 高亮指定用户的 boost（从 boost 通知跳转时使用）
  final String? highlightBoostUsername;

  /// OP 帖专属插槽: 仅在 postNumber == 1 时渲染, 位于 SolutionBanner 与 ActionBar 之间
  /// 当前用于 "俺也一样" 按钮; 其他 post 传 null
  final Widget? opTopSlot;

  /// 当前弹幕是否实际在显示（null = 当前帖子不展示弹幕；true/false = 显示与否）。
  /// true 时隐藏 footer 的 boost 气泡区(由弹幕层接管展示),并让
  /// "+ Boost" 火箭按钮出现在 action bar。
  final bool? danmakuActive;

  const PostFooterSection({
    super.key,
    required this.post,
    required this.topicId,
    required this.topicHasAcceptedAnswer,
    this.acceptedAnswers = const [],
    required this.padding,
    required this.onReply,
    required this.onEdit,
    required this.onShareAsImage,
    required this.onRefreshPost,
    required this.onJumpToPost,
    required this.onSolutionChanged,
    this.onAcceptedAnswerChanged,
    this.useReplyDialog = false,
    this.topicTitle,
    this.isPrivateMessageTopic = false,
    this.isPmWithNonHumanUser = false,
    this.hideRepliesButton = false,
    this.onShowPostDetail,
    this.postDetailLabel,
    this.highlightBoostUsername,
    this.opTopSlot,
    this.danmakuActive,
  });

  @override
  ConsumerState<PostFooterSection> createState() => _PostFooterSectionState();
}

class _PostFooterSectionState extends ConsumerState<PostFooterSection> {
  final DiscourseService _service = DiscourseService();
  final GlobalKey _likeButtonKey = GlobalKey();
  bool _isLiking = false;
  bool _isBookmarked = false;
  int? _bookmarkId;
  String? _bookmarkName;
  DateTime? _bookmarkReminderAt;
  bool _isBookmarking = false;
  late List<PostReaction> _reactions;
  PostReaction? _currentUserReaction;
  late List<Boost> _boosts;
  late bool _canBoost;
  final List<Post> _replies = [];
  final ValueNotifier<bool> _isLoadingRepliesNotifier = ValueNotifier<bool>(
    false,
  );
  final ValueNotifier<bool> _showRepliesNotifier = ValueNotifier<bool>(false);
  bool _isAcceptedAnswer = false;
  bool _isTogglingAnswer = false;
  bool _isDeleting = false;

  bool get _canLoadMoreReplies => _replies.length < widget.post.replyCount;

  @override
  void initState() {
    super.initState();
    _syncState();
  }

  @override
  void didUpdateWidget(PostFooterSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.post != widget.post) {
      _syncState();
    }
  }

  @override
  void dispose() {
    _isLoadingRepliesNotifier.dispose();
    _showRepliesNotifier.dispose();
    super.dispose();
  }

  void _syncState() {
    _reactions = List.from(widget.post.reactions ?? []);
    _currentUserReaction = widget.post.currentUserReaction;
    _isBookmarked = widget.post.bookmarked;
    _bookmarkId = widget.post.bookmarkId;
    _bookmarkName = widget.post.bookmarkName;
    _bookmarkReminderAt = widget.post.bookmarkReminderAt;
    _isAcceptedAnswer = widget.post.acceptedAnswer;
    _boosts = _dedupeBoostsById(widget.post.boosts ?? const []);
    _canBoost = widget.post.canBoost;
  }

  /// boost 变更落回 provider(经活跃实例注册表找回页面 provider;
  /// 无活跃实例时静默跳过,footer 本地 state 仍保证当场显示)。
  /// 弹幕层/action bar 读的是 provider 的 post.boosts —— 此前只写本地
  /// state,弹幕模式下自己刚发的 boost 直接不可见。
  void _syncBoostToProvider(
    void Function(TopicDetailNotifier notifier) apply,
  ) {
    final params = TopicDetailNotifier.activeParamsFor(widget.topicId);
    if (params == null) return;
    try {
      apply(ref.read(topicDetailProvider(params).notifier));
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  Future<void> _handleBoostCreated(Boost boost) async {
    if (!mounted) return;
    setState(() {
      _boosts = _dedupeBoostsById([..._boosts, boost]);
      _canBoost = false;
    });
    _syncBoostToProvider(
      (notifier) => notifier.applyLocalBoostCreated(widget.post.id, boost),
    );
  }

  /// BoostActions 的本地钩子:provider 落地由 BoostActions 统一做,
  /// 这里只同步 footer 自己的 setState(回复弹层/嵌套视图等场景的
  /// post 实例不吃 provider 更新,本地 state 是当场显示的保底)。
  void _onBoostChangedLocal(Boost boost) {
    if (!mounted) return;
    final index = _boosts.indexWhere((b) => b.id == boost.id);
    if (index == -1) return;
    setState(() {
      final updated = [..._boosts];
      updated[index] = boost;
      _boosts = updated;
    });
  }

  void _onBoostDeletedLocal(Boost boost, {required bool restoreCanBoost}) {
    if (!mounted) return;
    setState(() {
      // _boosts 可能来自 _dedupeBoostsById 的固定长度列表,不能原地 removeWhere
      _boosts = _boosts.where((b) => b.id != boost.id).toList();
      if (restoreCanBoost) {
        _canBoost = true;
      }
    });
  }

  List<Boost> _dedupeBoostsById(List<Boost> boosts) {
    final byId = <int, Boost>{};
    for (final boost in boosts) {
      byId[boost.id] = boost;
    }
    return byId.values.toList(growable: false);
  }

  /// boost 操作弹层统一走 BoostActions(弹幕层/列表共用同一实现);
  /// footer 本地 state 经钩子同步。
  Future<void> _showBoostActions(Boost boost, Rect? anchorRect) =>
      BoostActions.show(
        context: context,
        ref: ref,
        post: widget.post,
        topicId: widget.topicId,
        boost: boost,
        anchorRect: anchorRect,
        topicTitle: widget.topicTitle,
        onBoostChanged: _onBoostChangedLocal,
        onBoostDeleted: _onBoostDeletedLocal,
      );

  Future<void> _openBoostInput() async {
    final result = await showBoostInputSheet(context);
    if (result == null || !mounted) return;

    final raw = result.raw;
    if (raw.isEmpty) return;

    if (result is BoostInputReplyResult) {
      // 末尾追加空行，避免与已有草稿粘连
      widget.onReply?.call(initialContent: '$raw\n\n');
      return;
    }

    await _createBoost(raw);
  }

  Future<void> _createBoost(String raw) async {
    try {
      final boost = await _service.createBoost(widget.post.id, raw);
      if (!mounted) return;
      _handleBoostCreated(boost);
      ToastService.showSuccess(S.current.boost_created);
    } catch (e) {
      if (!mounted) return;
      ToastService.showError(S.current.boost_failed);
    }
  }

  Widget _buildBoostArea(BuildContext context) {
    // 弹幕层实际在显示时才隐藏 footer 的 boost 气泡区(由 PostItem 在
    // 帖子内容上叠加渲染)。此前按全局偏好判断:长帖分段/嵌套视图/回复
    // 弹层没有弹幕层,开偏好后这些路径的 boost 两头都不显示。
    if (widget.danmakuActive == true) {
      return const SizedBox.shrink();
    }
    final blockedUsernames = ref.watch(
      preferencesProvider.select((p) => p.normalizedBlockedUsernames),
    );
    return BoostList(
      boosts: BlockedUserFilter.visibleBoosts(_boosts, blockedUsernames),
      canBoost: _canBoost,
      onAddBoost: _openBoostInput,
      onBoostTap: _showBoostActions,
      highlightUsername: widget.highlightBoostUsername,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 帖内构成归因:与 pHdr 配对,点名单帖固定成本的大头(操作栏/boost
    // 列表在 footer;监控关闭零开销)
    FrameJankMonitor.noteBuild('pFtr#${widget.post.postNumber}');
    final theme = Theme.of(context);
    final currentUser = ref.read(currentUserProvider).value;
    final isOwnPost =
        currentUser != null && currentUser.username == widget.post.username;
    final isGuest = currentUser == null;

    return Padding(
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PostLinks(
            linkCounts: widget.post.linkCounts,
            // select:整 provider watch 会让任何偏好变化都重建所有在屏帖脚
            defaultExpanded: ref.watch(
              preferencesProvider.select((p) => p.expandRelatedLinks),
            ),
          ),
          if (widget.post.postNumber == 1 &&
              widget.topicHasAcceptedAnswer &&
              widget.acceptedAnswers.isNotEmpty)
            PostSolutionBanner(
              acceptedAnswers: widget.acceptedAnswers,
              onJumpToPost: widget.onJumpToPost,
            ),
          if (widget.post.postNumber == 1 && widget.opTopSlot != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: widget.opTopSlot,
            ),
          ],
          const SizedBox(height: 12),
          PostActionBar(
            post: widget.post,
            isGuest: isGuest,
            isOwnPost: isOwnPost,
            isLiking: _isLiking,
            reactions: _reactions,
            currentUserReaction: _currentUserReaction,
            likeButtonKey: _likeButtonKey,
            replies: _replies,
            isLoadingRepliesNotifier: _isLoadingRepliesNotifier,
            showRepliesNotifier: _showRepliesNotifier,
            hideRepliesButton: widget.hideRepliesButton,
            onToggleLike: _toggleLike,
            onReactionSelected: _toggleReaction,
            onShowReactionUsers: (reactionId) =>
                _showReactionUsers(context, reactionId: reactionId),
            onReply: widget.onReply == null ? null : () => widget.onReply!(),
            onShowMoreMenu: () => _showMoreMenu(context, theme),
            onToggleReplies: _toggleReplies,
            onAddBoost: _openBoostInput,
            canBoost: _canBoost,
            // 弹幕模式下 BoostList 不显示，把"+ Boost"按钮的位置让给 action bar
            hasBoosts: _boosts.isNotEmpty && !(widget.danmakuActive == true),
          ),
          // Boost 气泡列表 / 弹幕
          if (_boosts.isNotEmpty) _buildBoostArea(context),
          ValueListenableBuilder<bool>(
            valueListenable: _showRepliesNotifier,
            builder: (context, showReplies, _) {
              if (!showReplies) return const SizedBox.shrink();
              return PostRepliesList(
                replies: _replies,
                replyCount: widget.post.replyCount,
                canLoadMore: _canLoadMoreReplies,
                isLoadingRepliesNotifier: _isLoadingRepliesNotifier,
                showRepliesNotifier: _showRepliesNotifier,
                onLoadMore: _loadReplies,
                onJumpToPost: widget.onJumpToPost,
                contentFontScale: ref
                    .watch(preferencesProvider)
                    .contentFontScale,
              );
            },
          ),
        ],
      ),
    );
  }
}
