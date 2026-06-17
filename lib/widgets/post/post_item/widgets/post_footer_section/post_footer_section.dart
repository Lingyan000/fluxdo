import 'package:flutter/material.dart';
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
import 'package:dio/dio.dart';
import '../../../../../services/app_error_handler.dart';
import '../../../../../services/discourse/discourse_service.dart';
import '../../../../../services/log/bookmark_edit_trace.dart';
import '../../../../../services/notion/notion_bookmark_auto_sync.dart';
import '../../../../../services/toast_service.dart';
import '../../../post_links.dart';
import '../post_action_bar.dart';
import '../../../../bookmark/bookmark_edit_sheet_launcher.dart';
import '../../../../post/post_boost/boost_list.dart';
import '../../../../post/post_boost/boost_input.dart';
import '../boost_flag_sheet.dart';
import '../post_flag_sheet.dart';
import '../post_reaction_users_sheet.dart';
import '../post_replies_list.dart';
import '../post_solution_banner.dart';
import '../../../../post/post_replies_sheet.dart';
import '../../../../../utils/dialog_utils.dart';

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
        onSuccess: () => ToastService.showSuccess(S.current.boost_flagSubmitted),
      ),
    );
  }

  Future<void> _showBoostActions(Boost boost) => showBoostActions(boost);

  /// 提供给外层(PostItem)的公开入口，方便弹幕浮层复用同一份 boost actions。
  Future<void> showBoostActions(Boost boost) async {
    final currentUsername = ref.read(currentUserProvider).value?.username;
    if (currentUsername == null || currentUsername.isEmpty) {
      return;
    }
    Boost resolvedBoost;
    try {
      resolvedBoost = await _resolveBoostActionState(
        boost: boost,
        currentUsername: currentUsername,
      );
    } catch (_) {
      if (!mounted) return;
      ToastService.showError(S.current.common_loadFailed);
      return;
    }
    if (!mounted) return;
    final canDelete = canDeleteBoostAction(
      boost: resolvedBoost,
      currentUsername: currentUsername,
    );
    if (boostAlreadyReportedByCurrentUser(
          boost: resolvedBoost,
          currentUsername: currentUsername,
        ) &&
        !canDelete) {
      ToastService.showInfo(S.current.boost_flagAlreadyReported);
      return;
    }
    final canFlag = canFlagBoostAction(
      boost: resolvedBoost,
      currentUsername: currentUsername,
    );
    if (!canOpenBoostActionMenu(
      boost: resolvedBoost,
      currentUsername: currentUsername,
    )) {
      return;
    }

    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (canFlag)
                ListTile(
                  leading: const Icon(Icons.flag_outlined, color: Colors.red),
                  title: Text(
                    S.current.common_report,
                    style: const TextStyle(color: Colors.red),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showBoostFlagSheet(resolvedBoost);
                  },
                ),
              if (canDelete)
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.red),
                  title: Text(S.current.common_delete),
                  onTap: () {
                    Navigator.pop(ctx);
                    _deleteBoost(resolvedBoost);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.close),
                title: Text(S.current.common_cancel),
                onTap: () => Navigator.pop(ctx),
              ),
            ],
          ),
        );
      },
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
    return BoostList(
      boosts: _boosts,
      canBoost: _canBoost,
      onAddBoost: _openBoostInput,
      onBoostTap: _showBoostActions,
      highlightUsername: widget.highlightBoostUsername,
    );
  }

  @override
  Widget build(BuildContext context) {
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
            defaultExpanded: ref.watch(preferencesProvider).expandRelatedLinks,
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
            hasBoosts: _boosts.isNotEmpty &&
                !(widget.danmakuActive == true),
          ),
          // Boost 气泡列表 / 弹幕
          if (_boosts.isNotEmpty)
            _buildBoostArea(context),
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
