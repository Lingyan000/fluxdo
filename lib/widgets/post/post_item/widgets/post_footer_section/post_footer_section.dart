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
import '../../../../../pages/user_profile_page.dart';
import '../../../post_links.dart';
import '../post_action_bar.dart';
import '../../../../bookmark/bookmark_edit_sheet_launcher.dart';
import '../../../../post/post_boost/boost_list.dart';
import '../../../../post/post_boost/boost_author_popover.dart';
import '../../../../post/post_boost/boost_input.dart';
import '../boost_flag_sheet.dart';
import '../post_flag_sheet.dart';
import '../post_reaction_users_sheet.dart';
import '../post_replies_list.dart';
import '../post_solution_banner.dart';
import '../../../../post/post_replies_sheet.dart';
import '../../../../user/user_card.dart';
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

  /// Boost 更新回调
  final void Function(Post updatedPost)? onBoostUpdated;

  /// 高亮指定用户的 boost（从 boost 通知跳转时使用）
  final String? highlightBoostUsername;

  /// OP 帖专属插槽: 仅在 postNumber == 1 时渲染, 位于 SolutionBanner 与 ActionBar 之间
  /// 当前用于 "俺也一样" 按钮; 其他 post 传 null
  final Widget? opTopSlot;

  /// 帖子级临时弹幕开关：true=强制按列表显示（覆盖全局弹幕偏好）
  final bool forceShowBoostList;

  /// 当前弹幕是否实际在显示（null = 当前帖子不展示弹幕；true/false = 显示与否），
  /// 用于决定 "+ Boost" 火箭按钮是否出现在 action bar
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
    this.onBoostUpdated,
    this.highlightBoostUsername,
    this.opTopSlot,
    this.forceShowBoostList = false,
    this.danmakuActive,
  });

  @override
  ConsumerState<PostFooterSection> createState() => PostFooterSectionState();
}

// 公开 typedef，供外层(PostItem)通过 GlobalKey 调用 showBoostActions。
typedef PostFooterSectionState = _PostFooterSectionState;

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

  Future<void> _handleBoostCreated(Boost boost) async {
    if (!mounted) return;
    setState(() {
      _boosts = _dedupeBoostsById([..._boosts, boost]);
      _canBoost = false;
    });
    widget.onBoostUpdated?.call(
      widget.post.copyWith(boosts: List.from(_boosts), canBoost: _canBoost),
    );
  }

  void _handleBoostDeleted(Boost boost) {
    if (!mounted) return;
    setState(() {
      _boosts.removeWhere((b) => b.id == boost.id);
      final currentUser = ref.read(currentUserProvider).value;
      if (currentUser != null && boost.user.username == currentUser.username) {
        _canBoost = true;
      }
    });
    widget.onBoostUpdated?.call(
      widget.post.copyWith(boosts: List.from(_boosts), canBoost: _canBoost),
    );
  }

  void _handleBoostChanged(Boost boost) {
    if (!mounted) return;
    final index = _boosts.indexWhere((b) => b.id == boost.id);
    if (index == -1) return;
    setState(() {
      final updated = [..._boosts];
      updated[index] = boost;
      _boosts = updated;
    });
    widget.onBoostUpdated?.call(
      widget.post.copyWith(boosts: List.from(_boosts), canBoost: _canBoost),
    );
  }

  List<Boost> _dedupeBoostsById(List<Boost> boosts) {
    final byId = <int, Boost>{};
    for (final boost in boosts) {
      byId[boost.id] = boost;
    }
    return byId.values.toList(growable: false);
  }

  Future<void> _deleteBoost(Boost boost) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(S.current.boost_deleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(S.current.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              S.current.common_delete,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await _service.deleteBoost(boost.id);
      if (!mounted) return;
      _handleBoostDeleted(boost);
      ToastService.showSuccess(S.current.boost_deleted);
    } catch (_) {
      if (!mounted) return;
      ToastService.showError(S.current.boost_deleteFailed);
    }
  }

  bool _shouldFetchBoostActionState({
    required Boost boost,
    required String currentUsername,
  }) {
    final isOwnBoost = currentUsername == boost.user.username;
    if (isOwnBoost) {
      return false;
    }
    if (boost.canFlag && boost.availableFlags == null) {
      return true;
    }
    return !boost.canDelete &&
        !boost.canFlag &&
        boost.availableFlags == null &&
        boost.userFlagStatus == null;
  }

  Future<Boost> _resolveBoostActionState({
    required Boost boost,
    required String currentUsername,
  }) async {
    if (!_shouldFetchBoostActionState(
      boost: boost,
      currentUsername: currentUsername,
    )) {
      return boost;
    }
    final detailedBoost = await _service.getBoost(boost.id);
    if (mounted) {
      _handleBoostChanged(detailedBoost);
    }
    return detailedBoost;
  }

  Future<void> _refreshBoostAfterFlag(Boost boost) async {
    try {
      final updatedBoost = await _service.getBoost(boost.id);
      if (!mounted) return;
      _handleBoostChanged(updatedBoost);
    } catch (_) {
      if (!mounted) return;
      _handleBoostChanged(
        boost.copyWith(
          canFlag: false,
          userFlagStatus: boost.userFlagStatus ?? 1,
        ),
      );
    }
  }

  void _showBoostFlagSheet(Boost boost) {
    showAppBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      enableDrag: false, // 举报表单(card):禁止下滑误关
      builder: (context) => BoostFlagSheet(
        boost: boost,
        submitFlag: (flagTypeId, message) async {
          await _service.flagBoost(
            boost.id,
            flagTypeId: flagTypeId,
            message: message,
          );
          await _refreshBoostAfterFlag(boost);
        },
        onSuccess: () =>
            ToastService.showSuccess(S.current.boost_flagSubmitted),
      ),
    );
  }

  Future<void> _showBoostActions(Boost boost, Rect? anchorRect) =>
      showBoostActions(boost, anchorRect: anchorRect);

  /// 提供给外层(PostItem)的公开入口，方便弹幕浮层复用同一份 boost actions。
  Future<void> showBoostActions(Boost boost, {Rect? anchorRect}) async {
    final currentUsername = ref.read(currentUserProvider).value?.username;
    Boost resolvedBoost = boost;
    var boostActionStateLoadFailed = false;
    if (currentUsername != null && currentUsername.isNotEmpty) {
      try {
        resolvedBoost = await _resolveBoostActionState(
          boost: boost,
          currentUsername: currentUsername,
        );
      } catch (_) {
        boostActionStateLoadFailed = true;
      }
    }
    if (!mounted) return;

    final canPreviewAuthor =
        canViewBoostAuthor(boost: resolvedBoost) &&
        canShowUserCardPreview(context);
    final canDelete =
        boostActionStateLoadFailed ||
            currentUsername == null ||
            currentUsername.isEmpty
        ? false
        : canDeleteBoostAction(
            boost: resolvedBoost,
            currentUsername: currentUsername,
          );
    final canFlag =
        boostActionStateLoadFailed ||
            currentUsername == null ||
            currentUsername.isEmpty
        ? false
        : canFlagBoostAction(
            boost: resolvedBoost,
            currentUsername: currentUsername,
          );
    final alreadyReported = currentUsername == null || currentUsername.isEmpty
        ? false
        : boostAlreadyReportedByCurrentUser(
            boost: resolvedBoost,
            currentUsername: currentUsername,
          );
    final canShowSheet = canPreviewAuthor || canFlag || canDelete;
    if (boostActionStateLoadFailed) {
      ToastService.showError(S.current.common_loadFailed);
    }
    if (!canShowSheet) {
      return;
    }
    if (alreadyReported && !canDelete) {
      ToastService.showInfo(S.current.boost_flagAlreadyReported);
    }

    final action = await showBoostAuthorPopover(
      context: context,
      anchorRect: anchorRect ?? _fallbackBoostAuthorAnchorRect(),
      boost: resolvedBoost,
      canViewAuthor: canPreviewAuthor,
      canFlag: canFlag,
      canDelete: canDelete,
    );
    if (!mounted || action == null) return;
    switch (action) {
      case BoostAuthorPopoverAction.authorCard:
        _showBoostAuthorCard(resolvedBoost, anchorRect);
      case BoostAuthorPopoverAction.profile:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                UserProfilePage(username: resolvedBoost.user.username),
          ),
        );
      case BoostAuthorPopoverAction.flag:
        _showBoostFlagSheet(resolvedBoost);
      case BoostAuthorPopoverAction.delete:
        _deleteBoost(resolvedBoost);
    }
  }

  Rect _fallbackBoostAuthorAnchorRect() {
    final media = MediaQuery.maybeOf(context);
    final size = media?.size ?? const Size(1, 1);
    return Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.35),
      width: 1,
      height: 1,
    );
  }

  void _showBoostAuthorCard(Boost boost, Rect? anchorRect) {
    showUserCard(
      context: context,
      anchorRect: anchorRect ?? _fallbackBoostAuthorAnchorRect(),
      username: boost.user.username,
      topicId: widget.topicId,
      topicTitle: widget.topicTitle,
      postNumber: widget.post.postNumber,
      avatarFallbackUrl: boost.user.avatarTemplate.isEmpty
          ? null
          : boost.user.getAvatarUrl(size: 144),
      nameFallback: boost.user.name,
      flairUrl: null,
      flairName: null,
      flairBgColor: null,
      flairColor: null,
    );
  }

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
    final isDanmaku = ref.watch(
      preferencesProvider.select((p) => p.boostDanmaku),
    );
    // 弹幕模式下隐藏 footer 中的 boost 气泡区，由 PostItem 在帖子内容上叠加渲染；
    // 但帖子级临时关闭弹幕时需要回退到列表展示。
    if (isDanmaku && !widget.forceShowBoostList) {
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

    // 预热打赏凭证，避免首次打开更多菜单时因 AsyncLoading 导致打赏选项不显示
    ref.watch(ldcRewardCredentialsProvider);

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
