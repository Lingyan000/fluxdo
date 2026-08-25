/// post-voting(问答)帖子评论区,对齐官方 post-voting-comments 排版:
/// 每条评论 = 左侧「赞数 + 上箭头」小投票列 + 行内「正文 – 用户名 时间」
/// 小字排布,条间细分隔线;底部「添加评论」与「显示更多 N 条」入口。
///
/// 评论是独立模型(非 post):点赞只有 up 没有 down;加载更多走
/// GET /post_voting/comments 增量。添加评论按平台分流:桌面 = 官方
/// 网页式就地展开 composer(textarea+字数 flash+Ctrl/Cmd+Enter);
/// 移动 = 底部弹层(键盘/emoji 定制,post_voting_comment_sheet)。
/// 状态自持有(预载 5 条为初值,加载/新增在本组件内追加)。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/s.dart';
import '../../../../models/topic.dart';
import '../../../../providers/discourse_providers.dart';
import '../../../../services/app_error_handler.dart';
import '../../../../services/discourse/discourse_service.dart';
import '../../../../services/preloaded_data_service.dart';
import '../../../../services/toast_service.dart';
import '../../../../utils/platform_utils.dart';
import '../../../../utils/time_utils.dart';
import '../../../common/emoji_text.dart';
import '../post_voting_comment_sheet.dart';

class PostVotingCommentsView extends ConsumerStatefulWidget {
  final int postId;

  /// 被评论帖子的作者(弹层上下文提示用)
  final String postUsername;
  final List<PostVotingComment> comments;
  final int commentsCount;

  /// 话题 closed/archived:隐藏「添加评论」
  final bool topicClosed;

  const PostVotingCommentsView({
    super.key,
    required this.postId,
    required this.postUsername,
    required this.comments,
    required this.commentsCount,
    this.topicClosed = false,
  });

  @override
  ConsumerState<PostVotingCommentsView> createState() =>
      _PostVotingCommentsViewState();
}

class _PostVotingCommentsViewState
    extends ConsumerState<PostVotingCommentsView> {
  late List<PostVotingComment> _comments = List.of(widget.comments);
  late int _totalCount = widget.commentsCount;
  bool _isLoadingMore = false;

  // 桌面内联 composer(官方网页式就地展开)
  bool _composerOpen = false;
  bool _isSubmitting = false;
  final TextEditingController _composerController = TextEditingController();
  final FocusNode _composerFocus = FocusNode();

  /// 评论字数上限:站点 post_voting_comment_max_raw_length,缺省 600
  late final int _maxLength = (PreloadedDataService()
              .siteSettingsSync?['post_voting_comment_max_raw_length']
          as num?)
          ?.toInt() ??
      600;

  /// 评论最短长度:站点 min_post_length,缺省 1
  late final int _minLength = (PreloadedDataService()
              .siteSettingsSync?['min_post_length'] as num?)
          ?.toInt() ??
      1;

  @override
  void didUpdateWidget(PostVotingCommentsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.postId != widget.postId) {
      _comments = List.of(widget.comments);
      _totalCount = widget.commentsCount;
      _composerOpen = false;
      _composerController.clear();
    }
  }

  @override
  void dispose() {
    _composerController.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  int get _remaining => (_totalCount - _comments.length).clamp(0, 999999);

  Future<void> _loadMore() async {
    if (_isLoadingMore || _comments.isEmpty) return;
    setState(() => _isLoadingMore = true);
    try {
      final more = await DiscourseService().getPostVotingComments(
        postId: widget.postId,
        lastCommentId: _comments.last.id,
      );
      if (!mounted) return;
      setState(() {
        final seen = _comments.map((c) => c.id).toSet();
        _comments.addAll(more.where((c) => !seen.contains(c.id)));
        // 服务端一次给完剩余;若仍有缺口以实际返回为准防死循环
        if (more.isEmpty) _totalCount = _comments.length;
      });
    } on DioException catch (_) {
      // ErrorInterceptor 已提示
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  /// 添加评论:平台分流。移动端底部弹层(键盘/emoji 定制);桌面端
  /// 官方网页式——就地展开内联 composer(展开前先拉齐剩余评论,
  /// 官方 expandComposer 同款,composer 出现在全部评论之后)。
  Future<void> _openComposer() async {
    final user = ref.read(currentUserProvider).value;
    if (user == null) {
      ToastService.showInfo(S.current.vote_pleaseLogin);
      return;
    }
    if (PlatformUtils.isMobile) {
      final comment = await showPostVotingCommentSheet(
        context,
        postId: widget.postId,
        replyToUsername: widget.postUsername,
      );
      if (comment == null || !mounted) return;
      setState(() {
        _comments.add(comment);
        _totalCount += 1;
      });
      return;
    }
    if (_remaining > 0) await _loadMore();
    if (!mounted) return;
    setState(() => _composerOpen = true);
    _composerFocus.requestFocus();
  }

  /// 桌面内联提交(官方 saveComment 同款);成功清空收起,失败留稿
  Future<void> _submitInline() async {
    final raw = _composerController.text.trim();
    if (raw.length < _minLength || raw.length > _maxLength || _isSubmitting) {
      return;
    }
    setState(() => _isSubmitting = true);
    try {
      final comment = await DiscourseService().createPostVotingComment(
        postId: widget.postId,
        raw: raw,
      );
      if (!mounted) return;
      setState(() {
        _comments.add(comment);
        _totalCount += 1;
        _composerController.clear();
        _composerOpen = false;
      });
    } on DioException catch (_) {
      // ErrorInterceptor 已提示,留在 composer 不丢稿
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _toggleCommentVote(int index) async {
    final user = ref.read(currentUserProvider).value;
    if (user == null) {
      ToastService.showInfo(S.current.vote_pleaseLogin);
      return;
    }
    final comment = _comments[index];
    final newVoted = !comment.userVoted;
    // 乐观更新(官方同款),失败回滚
    setState(() {
      _comments[index] = comment.copyWith(
        userVoted: newVoted,
        voteCount: comment.voteCount + (newVoted ? 1 : -1),
      );
    });
    try {
      await DiscourseService().votePostVotingComment(
        commentId: comment.id,
        vote: newVoted,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _comments[index] = comment);
      if (e is! DioException) {
        AppErrorHandler.handleUnexpected(e, StackTrace.current);
      }
    }
  }

  Widget _commentRow(ThemeData theme, int index) {
    final comment = _comments[index];
    final muted = theme.colorScheme.onSurfaceVariant;
    final displayName = (comment.name?.trim().isNotEmpty == true)
        ? comment.name!
        : comment.username;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧小投票列:赞数 + 上箭头(评论只有赞)
          SizedBox(
            width: 40,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${comment.voteCount}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: comment.voteCount == 0
                        ? muted.withValues(alpha: 0.5)
                        : muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 2),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _toggleCommentVote(index),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(
                      Symbols.arrow_upward_rounded,
                      size: 14,
                      color: comment.userVoted ? Colors.green : muted,
                      weight: comment.userVoted ? 700 : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          // 行内排布:正文 – 用户名 时间(官方 inline 流式)。
          // 正文经 buildEmojiSpans 把 :smile: 类 shortcode 渲染成表情图
          // (评论 cook 白名单含 emoji,输入端弹层同款工具)。
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  ...EmojiText.buildEmojiSpans(
                    context,
                    comment.raw,
                    theme.textTheme.bodySmall,
                  ),
                  TextSpan(
                    text: '  –  ',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                  TextSpan(
                    text: displayName,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (comment.createdAt != null)
                    TextSpan(
                      text:
                          '  ${TimeUtils.formatRelativeTime(comment.createdAt!)}',
                      style: theme.textTheme.labelSmall?.copyWith(color: muted),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 桌面内联 composer(官方网页形态):textarea + 字数/错误 flash +
  /// 「发表/取消」按钮;Ctrl/Cmd+Enter 提交。
  Widget _inlineComposer(ThemeData theme) {
    final length = _composerController.text.length;
    final tooShort = length > 0 && length < _minLength;
    final tooLong = length > _maxLength;
    final canSubmit =
        !_isSubmitting && length >= _minLength && !tooLong && length > 0;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter, control: true):
                  _submitInline,
              const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                  _submitInline,
            },
            child: TextField(
              controller: _composerController,
              focusNode: _composerFocus,
              minLines: 3,
              maxLines: 8,
              style: theme.textTheme.bodySmall,
              decoration: InputDecoration(
                hintText: S.current.postVoting_commentHint,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          // 官方 composer-flash:有输入才显示,超限/过短红色
          if (length > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                tooShort
                    ? S.current.postVoting_commentTooShort(_minLength)
                    : '$length/$_maxLength',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: (tooShort || tooLong)
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              FilledButton.icon(
                onPressed: canSubmit ? _submitInline : null,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                icon: _isSubmitting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Symbols.reply_rounded, size: 16),
                label: Text(S.current.postVoting_commentSubmit),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: _isSubmitting
                    ? null
                    : () => setState(() => _composerOpen = false),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(S.current.common_cancel),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _footer(ThemeData theme) {
    // 桌面内联 composer 展开时替换 actions 行(官方 expanded 同款)
    if (_composerOpen) return _inlineComposer(theme);
    return Row(
      children: [
        if (!widget.topicClosed)
          TextButton(
            onPressed: _openComposer,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text(
              S.current.postVoting_commentAdd,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        const Spacer(),
        if (_remaining > 0)
          TextButton(
            onPressed: _isLoadingMore ? null : _loadMore,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: _isLoadingMore
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    S.current.postVoting_commentsMore(_remaining),
                    style: const TextStyle(fontSize: 12),
                  ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final divider = Divider(
      height: 1,
      thickness: 0.5,
      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
    );
    final hasFooter = !widget.topicClosed || _remaining > 0;
    if (_comments.isEmpty && !hasFooter) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < _comments.length; i++) ...[
            divider,
            _commentRow(theme, i),
          ],
          if (_comments.isNotEmpty || hasFooter) divider,
          if (hasFooter) _footer(theme),
        ],
      ),
    );
  }
}
