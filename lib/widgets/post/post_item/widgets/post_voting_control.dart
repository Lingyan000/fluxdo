/// post-voting(问答)帖子赞成/反对控件 + 投票人弹层。
///
/// 横向胶囊 [▲ 12 ▼](对照操作栏回复数按钮样式):点箭头投票/改票,
/// 点已选方向撤票;点票数弹投票人列表。自包含 service 调用(仿
/// SharedIssueButton 范式),成功后经 activeParamsFor 回写 provider,
/// 使弹层/嵌套视图等场景的同帖实例同步。
///
/// 票数变化本地计算(服务端响应只有 success:OK):
/// null→up +1;null→down -1;up→null -1;down→null +1;up↔down ±2。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/s.dart';
import '../../../../models/topic.dart';
import '../../../../models/topic_vote.dart';
import '../../../../providers/discourse_providers.dart';
import '../../../../services/app_error_handler.dart';
import '../../../../services/discourse/discourse_service.dart';
import '../../../../services/toast_service.dart';
import '../../../../utils/dialog_utils.dart';
import '../../../common/app_bottom_sheet.dart';
import '../../../common/smart_avatar.dart';
import '../../../user/user_card.dart';

class PostVotingControl extends ConsumerStatefulWidget {
  final Post post;
  final int topicId;

  /// 话题 closed/archived:禁投但票数与投票人仍可看
  final bool topicClosed;

  /// 竖排 = 官方形态(上箭头/票数/下箭头,挂正文左列);
  /// 横排胶囊用于长帖 footer 等放不下竖列的场景。
  final Axis axis;

  const PostVotingControl({
    super.key,
    required this.post,
    required this.topicId,
    this.topicClosed = false,
    this.axis = Axis.horizontal,
  });

  @override
  ConsumerState<PostVotingControl> createState() => _PostVotingControlState();
}

class _PostVotingControlState extends ConsumerState<PostVotingControl> {
  bool _isVoting = false;
  late int _count = widget.post.postVotingVoteCount;
  late String? _direction = widget.post.postVotingUserVotedDirection;

  @override
  void didUpdateWidget(PostVotingControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.post.id != widget.post.id ||
        oldWidget.post.postVotingVoteCount !=
            widget.post.postVotingVoteCount ||
        oldWidget.post.postVotingUserVotedDirection !=
            widget.post.postVotingUserVotedDirection) {
      _count = widget.post.postVotingVoteCount;
      _direction = widget.post.postVotingUserVotedDirection;
    }
  }

  bool get _isOwnPost {
    final user = ref.read(currentUserProvider).value;
    return user != null && user.username == widget.post.username;
  }

  Future<void> _handleTap(String direction) async {
    if (_isVoting) return;
    final user = ref.read(currentUserProvider).value;
    if (user == null) {
      ToastService.showInfo(S.current.vote_pleaseLogin);
      return;
    }
    if (widget.topicClosed) {
      ToastService.showInfo(S.current.postVoting_topicClosed);
      return;
    }
    if (_isOwnPost) {
      ToastService.showInfo(S.current.postVoting_cannotVoteOwn);
      return;
    }

    HapticFeedback.lightImpact();
    setState(() => _isVoting = true);

    final removing = _direction == direction;
    try {
      final service = DiscourseService();
      if (removing) {
        await service.postVotingRemoveVote(postId: widget.post.id);
      } else {
        await service.postVotingVote(
          postId: widget.post.id,
          direction: direction,
        );
      }
      if (!mounted) return;

      // 本地结算票数(响应无数据)
      final int delta;
      final String? newDirection;
      if (removing) {
        delta = direction == 'up' ? -1 : 1;
        newDirection = null;
      } else if (_direction == null) {
        delta = direction == 'up' ? 1 : -1;
        newDirection = direction;
      } else {
        // 改票:服务端删旧建新,一次 ±2
        delta = direction == 'up' ? 2 : -2;
        newDirection = direction;
      }
      setState(() {
        _count += delta;
        _direction = newDirection;
      });
      _syncToProvider();
    } on DioException catch (_) {
      // 网络/业务错误已由 ErrorInterceptor 统一提示(含撤票超时窗 403)
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isVoting = false);
    }
  }

  /// 经活跃实例注册表找回页面 provider(reaction_actions 同款):
  /// 凭 topicId 直接 new params 只会命中孤儿实例,更新落不到在显示的数据
  void _syncToProvider() {
    final params = TopicDetailNotifier.activeParamsFor(widget.topicId);
    if (params == null) return;
    try {
      ref
          .read(topicDetailProvider(params).notifier)
          .updatePostVoting(widget.post.id, _count, _direction);
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  void _showVoters() {
    if (!widget.post.postVotingHasVotes && _count == 0 && _direction == null) {
      return;
    }
    showAppBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => PostVotingVotersSheet(postId: widget.post.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final upActive = _direction == 'up';
    final downActive = _direction == 'down';
    final muted = theme.colorScheme.onSurfaceVariant;
    // 官方配色:已投上=绿(--success),已投下=红(--danger)
    final upColor = upActive ? Colors.green : muted;
    final downColor = downActive ? theme.colorScheme.error : muted;
    final vertical = widget.axis == Axis.vertical;

    Widget arrow({
      required IconData icon,
      required Color color,
      required bool active,
      required VoidCallback onTap,
    }) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _isVoting ? null : onTap,
        child: Padding(
          padding: vertical
              ? const EdgeInsets.symmetric(vertical: 6, horizontal: 10)
              : const EdgeInsets.symmetric(horizontal: 8),
          child: Icon(
            icon,
            size: vertical ? 22 : 18,
            color: color,
            fill: active ? 1 : 0,
            weight: active ? 700 : null,
          ),
        ),
      );
    }

    final countText = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _showVoters,
      child: Padding(
        padding: vertical
            ? const EdgeInsets.symmetric(vertical: 2)
            : EdgeInsets.zero,
        child: Text(
          '$_count',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelMedium?.copyWith(
            color: _count == 0
                ? muted.withValues(alpha: 0.7)
                : (upActive
                      ? Colors.green
                      : downActive
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurface),
            fontWeight: FontWeight.w600,
            fontSize: vertical ? 14 : null,
          ),
        ),
      ),
    );

    final upArrow = arrow(
      icon: Symbols.arrow_upward_rounded,
      color: upColor,
      active: upActive,
      onTap: () => _handleTap('up'),
    );
    final downArrow = arrow(
      icon: Symbols.arrow_downward_rounded,
      color: downColor,
      active: downActive,
      onTap: () => _handleTap('down'),
    );

    if (vertical) {
      // 官方形态:无底色竖列,上箭头 / 票数 / 下箭头
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [upArrow, countText, downArrow],
      );
    }

    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: _direction != null
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: _direction != null
              ? theme.colorScheme.primary.withValues(alpha: 0.2)
              : Colors.transparent,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [upArrow, countText, downArrow],
      ),
    );
  }
}

/// 投票人列表弹层:up/down 分组展示(服务端最多返回最近 20 条)
class PostVotingVotersSheet extends StatefulWidget {
  final int postId;

  const PostVotingVotersSheet({super.key, required this.postId});

  @override
  State<PostVotingVotersSheet> createState() => _PostVotingVotersSheetState();
}

class _PostVotingVotersSheetState extends State<PostVotingVotersSheet> {
  List<PostVotingVoter>? _voters;
  int _total = 0;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final (voters, total) =
          await DiscourseService().getPostVotingVoters(widget.postId);
      if (!mounted) return;
      setState(() {
        _voters = voters;
        _total = total;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = S.current.common_loadFailed;
        _isLoading = false;
      });
    }
  }

  Widget _voterRow(ThemeData theme, PostVotingVoter voter) {
    final displayName = (voter.name?.trim().isNotEmpty == true)
        ? voter.name!
        : voter.username;
    return Builder(
      builder: (rowContext) => InkWell(
        onTap: () {
          final box = rowContext.findRenderObject() as RenderBox?;
          if (box == null || !box.hasSize) return;
          final anchorRect = box.localToGlobal(Offset.zero) & box.size;
          showUserCard(
            context: rowContext,
            anchorRect: anchorRect,
            username: voter.username,
            avatarFallbackUrl: voter.getAvatarUrl(size: 144),
            nameFallback: voter.name,
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              SmartAvatar(
                imageUrl: voter.getAvatarUrl(size: 96),
                radius: 18,
                fallbackText: voter.username,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  displayName,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(
                voter.direction == 'up'
                    ? Symbols.arrow_upward_rounded
                    : Symbols.arrow_downward_rounded,
                size: 16,
                color: voter.direction == 'up'
                    ? theme.colorScheme.primary
                    : theme.colorScheme.error,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _groupHeader(ThemeData theme, String label, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        '$label · $count',
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget body;
    if (_isLoading) {
      body = const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (_error != null) {
      body = Padding(
        padding: const EdgeInsets.all(32),
        child: Center(child: Text(_error!)),
      );
    } else {
      final voters = _voters ?? const <PostVotingVoter>[];
      final ups = voters.where((v) => v.direction == 'up').toList();
      final downs = voters.where((v) => v.direction != 'up').toList();
      if (voters.isEmpty) {
        body = Padding(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: Text(
              S.current.postVoting_noVoters,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      } else {
        body = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (ups.isNotEmpty) ...[
              _groupHeader(theme, S.current.postVoting_votersUp, ups.length),
              for (final v in ups) _voterRow(theme, v),
            ],
            if (downs.isNotEmpty) ...[
              _groupHeader(
                  theme, S.current.postVoting_votersDown, downs.length),
              for (final v in downs) _voterRow(theme, v),
            ],
            if (_total > voters.length)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  S.current.postVoting_votersMore(_total),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        );
      }
    }

    return AppSheetScaffold(
      showCloseButton: false,
      maxHeightFactor: 0.6,
      contentPadding: EdgeInsets.zero,
      titleWidget: Row(
        children: [
          Icon(Symbols.thumbs_up_down_rounded,
              color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            S.current.postVoting_votersTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: body,
        ),
      ),
    );
  }
}
